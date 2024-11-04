const std = @import("std");
const yazap = @import("yazap");
const sys = @import("sys.zig");
const builtin = @import("builtin");
const sysops = @cImport({
    @cInclude("sysops.h");
});
const stack = @import("stack.zig");

extern threadlocal var errno: c_int;

pub fn SpscChannel(T: type) type {
    return struct {
        const Self = @This();

        const Type = T;
        // We choose to use a stack here because, although a queue would be "more
        // correct", in our particular application we do not care about the order
        // elements are processed as long as they are processed. The stack is slightly
        // faster as the ideal, lock-free implementation only requires one atomic while
        // the Queue requires two atomics. The former allows for slightly less
        // contention.
        const StackT = stack.SPSCChan(Type, 256, 4);

        stack: StackT,
        alloc: std.mem.Allocator,

        _done_flag: std.atomic.Value(bool),

        pub fn isClosed(self: *const Self) bool {
            return self._done_flag.load(.monotonic);
        }

        pub fn close(self: *Self) void {
            self.stack.close();
            self._done_flag.store(true, .release);
        }

        // TODO(mvejnovic): This whole function is a disgusting hack and I'm ashamed of
        // myself. The only reason it exists is so that we can observe the settling in
        // close() .release storage. It would be good if I could wrap this in some sort
        // of context or something, I don't know...
        pub fn consumerPostClose(self: *Self) void {
            _ = self._done_flag.load(.acquire);
        }
    };
}

const FilePathChannel = SpscChannel(struct { file_path: [:0]const u8 });
const MemorySearchChannel = SpscChannel(struct { memory: []u8 });

const FsTraverseWorker = struct {
    const Self = @This();
    const EgressT = FilePathChannel;

    _egress: *EgressT,
    _start_path: []const u8,
    _fs_walker: ?std.fs.Dir.Walker,

    pub fn init(
        egress: *EgressT,
        start_path: []const u8,
    ) !Self {
        return Self{
            ._egress = egress,
            ._start_path = start_path,
            ._fs_walker = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self._fs_walker) |*walker| {
            walker.deinit();
        }
    }

    pub fn run(self: *Self) !void {
        // TODO(mvejnovic): This is a hack.
        _ = sysops.pinThreadToCore(@intCast(0));

        const root_path = try std.fs.cwd().realpathAlloc(
            self._egress.alloc,
            self._start_path,
        );
        defer self._egress.alloc.free(root_path);

        var root = try std.fs.openDirAbsolute(root_path, .{ .iterate = true });
        defer root.close();

        self._fs_walker = try root.walk(self._egress.alloc);

        while (try self._fs_walker.?.next()) |inode| {
            switch (inode.kind) {
                .file => {
                    if (std.fs.path.joinZ(self._egress.alloc, &[_][]const u8{
                        root_path,
                        inode.path,
                    })) |file_path| {
                        const x = FilePathChannel.Type{ .file_path = file_path };
                        self._egress.stack.push(x);
                        std.log.debug("FsTraverseWorker.produce {s}", .{x.file_path});
                    } else |err| {
                        std.log.err("Failed to join path: {}", .{err});
                        continue;
                    }
                },
                else => {},
            }
        }

        self._egress.close();
        std.log.debug("FsTraverseWorker done.", .{});
    }
};

const MemoryLoaderWorker = struct {
    const Self = @This();
    const IngressChannel = FilePathChannel;
    const EgressChannel = MemorySearchChannel;

    _ingress: *IngressChannel,
    _egress: *EgressChannel,
    _needle_len: usize,

    pub fn init(
        ingress: *IngressChannel,
        egress: *EgressChannel,
        needle_len: usize,
    ) !Self {
        return Self{
            ._ingress = ingress,
            ._egress = egress,
            ._needle_len = needle_len,
        };
    }

    pub fn run(self: *Self) void {
        // TODO(mvejnovic): This is a hack.
        _ = sysops.pinThreadToCore(@intCast(2));

        // While the producer is not done, keep loading files into memory.
        while (!self._ingress.isClosed()) {
            // We read in batches, so let's read the batch and process it.
            self._processJob(self._ingress.stack.pop());
        }

        // There might still be some stragglers in the stack, so let's process them.
        self._ingress.consumerPostClose();
        while (true) {
            const maybe_job = self._ingress.stack.tryThreadUnsafePop();
            if (maybe_job) |job| {
                self._processJob(job);
            } else {
                break;
            }
        }

        // Close out the queue.
        self._egress.close();
        // We also need to ensure we unblock any threads that may be waiting on the
        // stack.
        std.log.debug("MemoryLoaderWorker done.", .{});
    }

    fn _processJob(self: *Self, job: IngressChannel.Type) void {
        // We need to make sure after all is set and done that we free the memory.
        defer self._ingress.alloc.free(job.file_path);

        // This thread is responsible for loading the file into memory.
        std.log.debug("MemoryLoaderWorker._processJob({s})", .{job.file_path});
        const file_path = job.file_path;

        // Open the file in direct mode.
        // TODO(mvejnovic): Figure out if .DIRECT = true is good
        const file_fd = std.c.open(file_path, .{ .ACCMODE = .RDONLY, .DIRECT = false });
        if (file_fd == -1) {
            // TODO(mvejnovic): Write the errno.
            std.log.err("Failed to open file: {s}", .{file_path});
            return;
        }
        defer _ = std.c.close(file_fd);

        // fstat the file so we know how much to read.
        var file_stat: std.c.Stat = undefined;
        if (std.c.fstat(file_fd, &file_stat) == -1) {
            // TODO(mvejnovic): Write the errno.
            std.log.err("Failed to fstat file: {s}", .{file_path});
            return;
        }

        if (file_stat.size < self._needle_len) {
            // If the file is smaller than the needle, there is no point in attempting
            // to read it.
            return;
        }

        // Allocate a buffer to read the file into memory.
        var memory: []u8 = undefined;
        while (true) {
            const maybe_mem = self._egress.alloc.alloc(u8, @intCast(file_stat.size));
            if (maybe_mem) |mem| {
                memory = mem;
                break;
            } else |err| {
                std.log.err(
                    "Failed to allocate memory for file: {s}: {}",
                    .{ file_path, err },
                );
            }
        }

        // Read the file into memory.
        if (std.c.read(file_fd, @ptrCast(memory.ptr), memory.len) == -1) {
            // TODO(mvejnovic): errno
            std.log.err("Failed to read file {s}: {}", .{ file_path, errno });
            return;
        }

        std.log.debug("MemoryLoaderWorker.produce {}", .{memory.len});
        self._egress.stack.push(MemorySearchChannel.Type{ .memory = memory });
    }
};

const FileSearcherWorker = struct {
    const Self = @This();
    const IngressChannel = MemorySearchChannel;

    _ingress: *IngressChannel,

    pub fn init(ingress: *IngressChannel) !Self {
        return Self{ ._ingress = ingress };
    }

    pub fn run(self: *Self) void {
        // TODO(mvejnovic): This is a hack.
        _ = sysops.pinThreadToCore(@intCast(4));

        // While the producer is not done, keep loading files into memory.
        while (!self._ingress.isClosed()) {
            self._processJob(self._ingress.stack.pop());
        }

        self._ingress.consumerPostClose();
        while (true) {
            const maybe_job = self._ingress.stack.tryThreadUnsafePop();
            if (maybe_job) |job| {
                self._processJob(job);
            } else {
                break;
            }
        }

        std.log.debug("FileSearcherWorker done.", .{});
    }

    fn _processJob(self: *Self, job: IngressChannel.Type) void {
        std.log.debug("FileSearcherWorker.consume {}", .{job.memory.len});
        defer self._ingress.alloc.free(job.memory);
    }
};

pub fn main() !void {
    // TODO(markovejnovic): This allocator needs to be sped up.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = yazap.App.init(
        gpa.allocator(),
        "rabbit-search",
        "World's fastest string search.",
    );
    defer app.deinit();
    var rsCmd = app.rootCommand();
    try rsCmd.addArg(yazap.Arg.positional(
        "NEEDLE",
        "The string to search for. \".\" by default.",
        null,
    ));
    try rsCmd.addArg(yazap.Arg.positional("DIR", "The directory to search in.", null));
    try rsCmd.addArg(yazap.Arg.booleanOption(
        "verbose",
        'v',
        "Be verbose about your actions.",
    ));
    try rsCmd.addArg(yazap.Arg.singleValueOption(
        "jobs",
        'j',
        "Use N threads in parallel.",
    ));

    const args = try app.parseProcess();
    if (!args.containsArgs()) {
        try app.displayHelp();
        return;
    }

    // Parse the jobs argument to figure out how many jobs we should use.
    var jobs: u16 = undefined;
    if (args.getSingleValue("jobs")) |jobs_str| {
        jobs = try std.fmt.parseInt(u16, jobs_str, 10);
    } else {
        jobs = @intCast(sys.getNumCpus());
    }

    // Parse the search directory.
    var search_dir: []const u8 = undefined;
    if (args.getSingleValue("DIR")) |dir_str| {
        search_dir = dir_str;
    } else {
        search_dir = ".";
    }

    // To make filesystem traversal faster and easier, we attempt to setrlimit to be a
    // very large limit.
    const max_lim = (try std.posix.getrlimit(.NOFILE)).max;
    try std.posix.setrlimit(.NOFILE, .{ .cur = max_lim, .max = max_lim });

    // Parse out the needle.
    const needle = args.getSingleValue("NEEDLE").?;

    // Spin up the stacks and the workers.
    var file_path_channel = FilePathChannel{
        .stack = FilePathChannel.StackT.init("file_path_channel"),
        ._done_flag = std.atomic.Value(bool).init(false),
        .alloc = gpa.allocator(),
    };

    // 512MB of memory for the memory search channel.
    // TODO(mvejnovic): This is a hack. Make it configurable.
    const file_data_pen = try gpa.allocator().alloc(u8, 4 * 1024 * 1024 * 1024);
    defer gpa.allocator().free(file_data_pen);
    var file_data_alloc = std.heap.FixedBufferAllocator.init(file_data_pen);

    var memory_search_channel = MemorySearchChannel{
        .stack = MemorySearchChannel.StackT.init("memory_search_channel"),
        ._done_flag = std.atomic.Value(bool).init(false),
        .alloc = file_data_alloc.allocator(),
    };

    var fs_traverser_worker = try FsTraverseWorker.init(&file_path_channel, search_dir);
    var memory_loader_worker = try MemoryLoaderWorker.init(
        &file_path_channel,
        &memory_search_channel,
        needle.len,
    );
    var file_searcher_worker = try FileSearcherWorker.init(&memory_search_channel);

    // Spawn the threads.
    const memory_thread = try std.Thread.spawn(.{}, MemoryLoaderWorker.run, .{&memory_loader_worker});
    const searcher_thread = try std.Thread.spawn(.{}, FileSearcherWorker.run, .{&file_searcher_worker});

    // The current thread will be the filesystem traverser.
    try fs_traverser_worker.run();

    std.log.debug("Waiting for threads to finish...", .{});
    searcher_thread.join();
    memory_thread.join();

    fs_traverser_worker.deinit();
}
