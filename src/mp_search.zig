const std = @import("std");
const str = @import("str.zig");
const metrics = @import("metrics.zig");

pub const StringSearchJob = struct {
    const Self = @This();

    // Note that this must have ownership of this memory. The reason is simple -- the
    // publisher will populate this field and then move on with its life. If the
    // consumer doesn't take ownership, we will have a dangling pointer.
    entry_kind: std.fs.Dir.Entry.Kind,
    path: []const u8,
    _alloc: std.mem.Allocator,

    pub fn init(
        fs_entry: *const std.fs.Dir.Walker.Entry,
        alloc: std.mem.Allocator,
    ) !Self {
        return Self{
            .entry_kind = fs_entry.kind,
            .path = try alloc.dupe(u8, fs_entry.path),
            ._alloc = alloc,
        };
    }

    pub fn deinit(self: Self) void {
        self._alloc.free(self.path);
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("StringSearchJob({s})", .{self.path});
    }
};

pub fn SearchTask() type {
    return struct {
        pub const JobType = StringSearchJob;

        const Self = @This();

        _searcher: str.WideCompiledSearcher(),
        _working_dir_path: []const u8,
        _out_file: std.fs.File,
        _bandwidth_meter: *metrics.AtomicBandwidth,

        pub fn init(
            search_needle: []const u8,
            working_dir_path: []const u8,
            out_file: std.fs.File,
            bandwidth_meter: *metrics.AtomicBandwidth,
        ) !Self {
            return Self{
                ._searcher = try str.WideCompiledSearcher().init(search_needle),
                ._working_dir_path = working_dir_path,
                ._out_file = out_file,
                ._bandwidth_meter = bandwidth_meter,
            };
        }

        pub fn deinit(self: *const Self) void {
            self._searcher.deinit();
        }

        fn getFilePath(
            self: *const Self,
            job: StringSearchJob,
            alloc: std.mem.Allocator,
        ) ?[]const u8 {
            switch (job.entry_kind) {
                .file => {
                    const paths = [_][]const u8{
                        self._working_dir_path,
                        job.path,
                    };

                    const joined = std.fs.path.join(alloc, &paths) catch |err| {
                        std.log.err(
                            "Could not determine the full path for {any} due to {}.",
                            .{ paths, err },
                        );
                        return null;
                    };

                    std.log.debug("Joined: {s}|{s} ({}/{}) to {s} ({})", .{
                        self._working_dir_path,
                        job.path,
                        self._working_dir_path.len,
                        job.path.len,
                        joined,
                        joined.len,
                    });

                    return joined;
                },
                else => {
                    return null;
                },
            }
        }

        pub fn work(self: *Self, job: StringSearchJob) void {
            // Perform search operation
            std.log.debug("Searching for {}", .{job});

            // Whatever happens, this consumer is responsible for cleaning up the job.
            defer job.deinit();

            // TODO(mvejnovic): This might not be correct. PATH_MAX is the maximum for
            // a path chunk, not the full path.
            var path_buf_raw: [std.posix.PATH_MAX]u8 = undefined;

            // TODO(mvejnovic): Make this allocator be persistent across work sessions
            // to minimize the overhead of allocation.
            var path_buf = std.heap.FixedBufferAllocator.init(&path_buf_raw);

            // Get the absolute file path if the given job is in fact a file.
            const file_path = self.getFilePath(job, path_buf.allocator());
            if (file_path == null) {
                std.log.debug("Skipping non-file entry: {s}", .{job.path});
                return;
            }
            defer path_buf.allocator().free(file_path.?);

            // TODO(markovejnovic): There is a significant number of heuristics we
            //                      could apply
            // to our search attempt that could be applied. Some Ideas:
            //   - Do not search if the file appears to be a binary file.
            //   - Do not search if the file is in a .gitignore

            const posix_path = std.posix.toPosixPath(file_path.?) catch |err| {
                std.log.err(
                    "Could not convert {s} to posix path due to {}",
                    .{ file_path.?, err },
                );
                return;
            };
            const file_fd = std.c.open(
                &posix_path,
                .{
                    .ACCMODE = .RDONLY,
                    .DIRECT = false,
                },
            );
            if (file_fd == -1) {
                std.log.err("Could not open file {s}", .{file_path.?});
                return;
            }
            defer _ = std.c.close(file_fd);

            var file_stats: std.os.linux.Stat = undefined;
            if (std.c.fstat(file_fd, &file_stats) == -1) {
                std.log.err("Could not fstat() {s}", .{posix_path});
            }

            const file_sz: u64 = @intCast(file_stats.size);
            self._bandwidth_meter.counter.add(file_sz);

            // Easy-case, exit early, we know we won't find shit here.
            // TODO(mvejnovic): Mark unlikely
            // TODO(mvejnovic): Does this branch slow down the pipeline?
            if (file_sz < self._searcher.needle.len) {
                return;
            }

            // TODO(mvejnovic): Is there any benefit in doing an fadvise()?

            const data = std.posix.mmap(
                null,
                file_sz,
                std.posix.PROT.READ,
                .{
                    .HUGETLB = false,
                    .POPULATE = true,
                    .TYPE = .PRIVATE,
                },
                file_fd,
                0,
            ) catch |err| {
                std.log.err("Could not mmap() {} due to {}", .{ job, err });
                return;
            };
            defer std.posix.munmap(data);

            std.posix.madvise(
                data.ptr,
                file_sz,
                std.posix.MADV.SEQUENTIAL | std.posix.MADV.WILLNEED,
            ) catch |err| {
                std.log.warn("Could not madvise() {} due to {}.", .{ job, err });
            };

            // We need to reset the searcher before we proceed as it might contain some
            // garbage from the previous file.
            self._searcher.reset();

            // Traverse the file in chunks equal to the optimal size
            if (self._searcher.search(data)) {
                // TODO(mvejnovic): Output to queue.
                self._out_file.writer().print("{s}\n", .{file_path.?}) catch {};
            }
        }
    };
}
