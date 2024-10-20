const std = @import("std");
const str = @import("str.zig");

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

        _searcher: str.CompiledSearcher(512),
        _working_dir_path: []const u8,
        _out_file: std.fs.File,

        pub fn init(
            search_needle: []const u8,
            working_dir_path: []const u8,
            out_file: std.fs.File,
        ) !Self {
            return Self{
                ._searcher = try str.CompiledSearcher(512).init(search_needle),
                ._working_dir_path = working_dir_path,
                ._out_file = out_file,
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
            // Whatever happens, this consumer is responsible for cleaning up the job.
            defer job.deinit();

            // TODO(mvejnovic): Make this allocator be persistent across work sessions
            // to minimize the overhead of allocation.
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};

            // Perform search operation
            std.log.debug("Searching for {}", .{job});

            // Get the absolute file path if the given job is in fact a file.
            const file_path = self.getFilePath(job, gpa.allocator());
            if (file_path == null) {
                std.log.debug("Skipping non-file entry: {s}", .{job.path});
                return;
            }
            defer gpa.allocator().free(file_path.?);

            // TODO(markovejnovic): There is a significant number of heuristics we
            //                      could apply
            // to our search attempt that could be applied. Some Ideas:
            //   - Do not search if the file appears to be a binary file.
            //   - Do not search if the file is in a .gitignore

            const file = std.fs.openFileAbsolute(file_path.?, .{}) catch |err| {
                std.log.err("Could not open {} due to {}", .{ job, err });
                return;
            };
            const file_stats = file.stat() catch |err| {
                std.log.err("Could not stat() {} due to {}", .{ job, err });
                return;
            };

            const file_sz = file_stats.size;

            // Easy-case, exit early, we know we won't find shit here.
            // TODO(mvejnovic): Mark unlikely
            // TODO(mvejnovic): Does this branch slow down the pipeline?
            if (file_sz < self._searcher.needle.len) {
                return;
            }

            // Traverse the file in chunks equal to the optimal size
            while (true) {
                const batch_size = self._searcher.batchSize();

                const bytes_read = file.read(self._searcher.writePointer()) catch |err| {
                    std.log.err(
                        "Unexpected error occurred reading {any}: {any}",
                        .{ file_path.?, err },
                    );
                    return;
                };

                if (bytes_read < batch_size) {
                    // We read less bytes than the read buffer. If we have not exited the
                    // function by now, let's submit the last batch and call it a day.
                    // TODO(mvejnovic): This block is duplicated.
                    // TODO(mvejnovic): Mark unlikely
                    std.log.debug("Read {} bytes out of {} batch. Terminating search.", .{
                        bytes_read,
                        batch_size,
                    });
                    if (self._searcher.searchInBatch()) {
                        self._out_file.writer().print("{s}\n", .{file_path.?}) catch {};
                    }
                    return;
                }

                // Otherwise, we've read 256 bytes exactly. Lucky us. Let's submit the batch
                // and, if that batch returns anything, means we've found our guy.
                // TODO(mvejnovic): This block is duplicated.
                // TODO(mvejnovic): Mark unlikely
                if (self._searcher.searchInBatch()) {
                    self._out_file.writer().print("{s}\n", .{file_path.?}) catch {};
                    // We found our character, let's exit early.
                    return;
                }

                // If the batch doesn't find anything, read some more in hopes we'll find
                // something.
            }
        }
    };
}
