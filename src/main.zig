const std = @import("std");
const yazap = @import("yazap");
const sys = @import("sys.zig");
const builtin = @import("builtin");
const sync = @import("sync/sync.zig");
const str = @import("str.zig");
const sysops = @cImport({
    @cInclude("sysops.h");
});
const mp_search = @import("mp_search.zig");
const metrics = @import("metrics.zig");

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

    // Figure out the search path.
    const to_search = try std.fs.cwd().realpathAlloc(gpa.allocator(), search_dir);
    std.log.debug("Searching {s}", .{to_search});
    defer gpa.allocator().free(to_search);

    // Prepare the metrics
    var searchBandwidthMeter = metrics.AtomicBandwidth.init();

    // Inintialize workers which will be performing the search.
    const workers = try gpa.allocator().alloc(mp_search.SearchTask(), jobs);
    defer gpa.allocator().free(workers);
    for (workers) |*w| {
        w.* = try mp_search.SearchTask().init(
            args.getSingleValue("NEEDLE").?,
            to_search,
            std.io.getStdOut(),
            &searchBandwidthMeter,
        );
    }
    defer {
        for (workers) |*w| {
            w.deinit();
        }
    }

    // Spin up the thread queue.
    var thread_pool = try sync.SpinningThreadPool(mp_search.SearchTask()).init(
        gpa.allocator(),
        workers,
    );
    searchBandwidthMeter.start();
    try thread_pool.begin();
    defer thread_pool.deinit();

    // To make filesystem traversal faster and easier, we attempt to setrlimit to be a
    // very large limit.
    const max_lim = (try std.posix.getrlimit(.NOFILE)).max;
    try std.posix.setrlimit(.NOFILE, .{ .cur = max_lim, .max = max_lim });

    // Traverse the filesystem and feed each worker with work.
    var fs_start = try std.fs.openDirAbsolute(to_search, .{ .iterate = true });
    defer fs_start.close();

    // Pin the file-tree traversal onto one core to minimize contention between it and
    // the consumers.
    if (sysops.pinThreadToCore(@intCast(0)) != 0) {
        std.log.err("Failed to pin thread to core.", .{});
        return;
    }
    var fs_walker = try fs_start.walk(gpa.allocator());
    defer fs_walker.deinit();

    while (try fs_walker.next()) |inode| {
        thread_pool.enqueue(try mp_search.StringSearchJob.init(&inode, gpa.allocator()));
    }

    // This is critical because we need to prevent the memory allocated by fs_walker to
    // be deallocated prematurely.
    try thread_pool.blockUntilEmpty();

    std.log.err(
        "Search bandwidth {d:.2}MB/sec",
        .{searchBandwidthMeter.get() / 1024 / 1024},
    );
}
