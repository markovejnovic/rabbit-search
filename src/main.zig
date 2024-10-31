const std = @import("std");
const yazap = @import("yazap");
const sys = @import("sys.zig");
const builtin = @import("builtin");
const sysops = @cImport({
    @cInclude("sysops.h");
});
const queue = @import("queue.zig");

extern threadlocal var errno: c_int;

pub fn SpscChannel(T: type) type {
    return struct {
        const Type = T;
        const QueueT = queue.BatchedQueue(Type, 1024);

        queue: QueueT,
        done_flag: std.atomic.Value(bool),
        alloc: std.mem.Allocator,
    };
}

const FilePathChannel = SpscChannel(struct { file_path: [:0]const u8 });
const MemorySearchChannel = SpscChannel(struct { memory: []u8 });

const FsTraverseWorker = struct {
    const Self = @This();
    const EgressT = FilePathChannel;

    _egress: *EgressT,
    _start_path: []const u8,

    pub fn init(
        egress: *EgressT,
        start_path: []const u8,
    ) !Self {
        return Self{
            ._egress = egress,
            ._start_path = start_path,
        };
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

        var fs_walker = try root.walk(self._egress.alloc);

        while (try fs_walker.next()) |inode| {
            switch (inode.kind) {
                .file => {
                    if (std.fs.path.joinZ(self._egress.alloc, &[_][]const u8{
                        root_path,
                        inode.path,
                    })) |file_path| {
                        const x = FilePathChannel.Type{ .file_path = file_path };
                        self._egress.queue.push(x);
                        std.log.debug("FsTraverseWorker.produce {s}", .{x.file_path});
                    } else |err| {
                        std.log.err("Failed to join path: {}", .{err});
                        continue;
                    }
                },
                else => {},
            }
        }

        self._egress.done_flag.store(true, .monotonic);
        std.log.debug("FsTraverseWorker done.", .{});

        // TODO(mvejnovic): Deinit fs_walker, the child thread must be done first.
    }
};

const MemoryLoaderWorker = struct {
    const Self = @This();
    const IngressChannel = FilePathChannel;
    const EgressChannel = MemorySearchChannel;

    _ingress: *IngressChannel,
    _egress: *EgressChannel,

    pub fn init(ingress: *IngressChannel, egress: *EgressChannel) !Self {
        return Self{
            ._ingress = ingress,
            ._egress = egress,
        };
    }

    pub fn run(self: *Self) void {
        // TODO(mvejnovic): This is a hack.
        _ = sysops.pinThreadToCore(@intCast(2));

        // While the producer is not done, keep loading files into memory.
        while (!self._ingress.done_flag.load(.monotonic)) {
            // We read in batches, so let's read the batch and process it.
            const work_unit: IngressChannel.Type = self._ingress.queue.pop();
            defer self._ingress.alloc.free(work_unit.file_path);
            if (self._processJob(work_unit)) |out| {
                self._egress.queue.push(out);
            } else |err| {
                std.log.err("Failed to process job: {}", .{err});
            }
        }

        self._egress.done_flag.store(true, .monotonic);
    }

    fn _processJob(self: *Self, job: IngressChannel.Type) !EgressChannel.Type {
        // This thread is responsible for loading the file into memory.
        std.log.debug("MemoryLoaderWorker._processJob({s})", .{job.file_path});
        const file_path = job.file_path;

        // Open the file in direct mode.
        // TODO(mvejnovic): Figure out if .DIRECT = true is good
        const file_fd = std.c.open(file_path, .{ .ACCMODE = .RDONLY, .DIRECT = false });
        if (file_fd == -1) {
            // TODO(mvejnovic): Write the errno.
            std.log.err("Failed to open file: {s}", .{file_path});
            return error.FailToOpen;
        }
        defer _ = std.c.close(file_fd);

        // fstat the file so we know how much to read.
        var file_stat: std.c.Stat = undefined;
        if (std.c.fstat(file_fd, &file_stat) == -1) {
            // TODO(mvejnovic): Write the errno.
            std.log.err("Failed to fstat file: {s}", .{file_path});
            return error.FailToStat;
        }

        // Allocate a buffer to read the file into memory.
        const memory: []u8 = self._egress.alloc.alloc(u8, @intCast(file_stat.size)) catch |err| {
            std.log.err(
                "Failed to allocate memory for file: {s}: {}",
                .{ file_path, err },
            );
            return error.NotEnoughMemory;
        };

        // Read the file into memory.
        if (std.c.read(file_fd, @ptrCast(memory.ptr), memory.len) == -1) {
            // TODO(mvejnovic): errno
            std.log.err("Failed to read file {s}: {}", .{ file_path, errno });
            return error.FailedToRead;
        }

        return EgressChannel.Type{ .memory = memory };
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
        while (!self._ingress.done_flag.load(.monotonic)) {
            const work_unit: IngressChannel.Type = self._ingress.queue.pop();
            defer self._ingress.alloc.free(work_unit.memory);

            self._processJob(work_unit);
        }
    }

    fn _processJob(self: *Self, job: IngressChannel.Type) void {
        // This thread is responsible for actually searching the memory.
        const memory: []u8 = job.memory;

        _ = self;
        _ = memory;
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

    // Spin up the queues and the workers.
    var file_path_channel = FilePathChannel{
        .queue = try FilePathChannel.QueueT.init("file_path_channel"),
        .done_flag = std.atomic.Value(bool).init(false),
        .alloc = gpa.allocator(),
    };

    var memory_search_channel = MemorySearchChannel{
        .queue = try MemorySearchChannel.QueueT.init("memory_search_channel"),
        .done_flag = std.atomic.Value(bool).init(false),
        .alloc = gpa.allocator(),
    };

    var fs_traverser_worker = try FsTraverseWorker.init(&file_path_channel, search_dir);
    var memory_loader_worker = try MemoryLoaderWorker.init(&file_path_channel, &memory_search_channel);
    var file_searcher_worker = try FileSearcherWorker.init(&memory_search_channel);

    // Spawn the threads.
    const t1 = try std.Thread.spawn(.{}, MemoryLoaderWorker.run, .{&memory_loader_worker});
    const t2 = try std.Thread.spawn(.{}, FileSearcherWorker.run, .{&file_searcher_worker});

    // The current thread will be the filesystem traverser.
    try fs_traverser_worker.run();

    t1.join();
    t2.join();
}
