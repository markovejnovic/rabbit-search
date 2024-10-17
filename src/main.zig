const std = @import("std");
const yazap = @import("yazap");
const sys = @import("sys.zig");
const builtin = @import("builtin");
const sync = @import("sync/sync.zig");
const str = @import("str.zig");
const sysops = @cImport({
    @cInclude("sysops.h");
});

const SearchContext = struct {
    search_needle: []const u8,
    out_file: std.fs.File,
};

const StringSearchJob = struct {
    const Self = @This();

    search_context: *const SearchContext,

    file_path: []u8,

    // TODO(markovejnovic): The worker thread does not need to own this memory, as long
    // as its lifetime is guaranteed to be longer than the worker threads. However, to
    // make life easy on myself and make a correct program, I've decided to add
    // ownership here.
    // Remember, this could simply borrow the already allocated memory coming from the
    // main thread.
    //
    // The main reason this is here is because I do not understand the allocation rules
    // of walker. If I understood that better, we wouldn't need to manually do this.
    alloc: std.mem.Allocator,

    /// Create a new job.
    /// Note that you do not need to manage file_path. It will be deallocated for you.
    /// TODO(markovejnovic): Avoid deallocating it eagerly.
    pub fn init(
        // TODO(markovejnovic): I don't know how I feel passing so much crap down into
        // this constructor. Perhaps these should be done by the caller?
        search_context: *const SearchContext,
        search_start: *const std.fs.Dir,
        walker_entry: *const std.fs.Dir.Walker.Entry,
        alloc: std.mem.Allocator,
    ) ?Self {
        switch (walker_entry.kind) {
            .file => {
                const abs_path = search_start.realpathAlloc(
                    alloc,
                    walker_entry.path,
                ) catch |err| {
                    std.log.err(
                        "Could not determine the full path for {}/{s} due to {}.",
                        .{ search_start, walker_entry.path, err },
                    );
                    return null;
                };
                return Self{
                    .search_context = search_context,
                    .alloc = alloc,
                    .file_path = abs_path,
                };
            },
            else => {
                // TODO(markovejnovic): Do other file types. Could skip based on
                // .gitignore heuristics.
                return null;
            },
        }
    }

    pub fn deinit(self: *const Self) void {
        self.alloc.free(self.file_path);
    }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("StringSearchJob({s})", .{self.file_path});
    }
};

fn file_search(job: StringSearchJob) void {
    // We will need to deallocate the job in the searcher thread.
    defer job.deinit();
    std.log.debug("Searching for {}", .{job});

    // TODO(markovejnovic): There is a significant number of heuristics we could apply
    // to our search attempt that could be applied. Some Ideas:
    //   - Do not search if the file appears to be a binary file.
    //   - Do not search if the file is in a .gitignore

    // Let us query some information about the file.
    const file = std.fs.openFileAbsolute(job.file_path, .{}) catch |err| {
        std.log.err("Could not open {} due to {}", .{ job, err });
        return;
    };
    const file_stats = file.stat() catch |err| {
        std.log.err("Could not stat() {} due to {}", .{ job, err });
        return;
    };

    const file_sz = file_stats.size;

    // Easy-case, exit early, we know we won't find shit here.
    if (file_sz == 0) {
        return;
    }

    // TODO(markovejnovic): Query the system from /proc/meminfo | grep Hugepagesize
    const HUGE_PG_SZ = 2048 * 1024;
    //const use_tlb = file_sz >= HUGE_PG_SZ;
    const use_tlb = false; // TODO(markovejnovic): Figure out why on earth mmap returns
    // einval for use_tlb = True, even though everything looks
    // well populated. Maybe bug in sys.boundary_align
    const alloc_sz = if (use_tlb) sys.boundary_align(file_sz, HUGE_PG_SZ) else file_sz;

    std.log.debug("mmap()ing {s}", .{job.file_path});
    const data = std.posix.mmap(
        null,
        alloc_sz,
        std.posix.PROT.READ,
        .{
            // TODO(markovejnovic): Pull this information from
            // /proc/meminfo | grep Hugepagesize
            .HUGETLB = use_tlb,
            .POPULATE = true,
            .TYPE = .PRIVATE,
        },
        file.handle,
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

    std.log.debug("strsearching {s}", .{job.file_path});
    if (str.strsearch(job.search_context.search_needle, data)) {
        job.search_context.out_file.writer().print("{s}\n", .{job.file_path}) catch {};
    }
}

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

    // Spin up the thread queue.
    var thread_pool = try sync.SpinningThreadPool(StringSearchJob, &file_search).init(
        gpa.allocator(),
        jobs,
    );
    try thread_pool.begin();
    defer thread_pool.deinit();

    // Prepare the searching context.
    const search_context = SearchContext{
        .search_needle = args.getSingleValue("NEEDLE").?,
        .out_file = std.io.getStdOut(),
    };

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
    while (try fs_walker.next()) |file| {
        if (StringSearchJob.init(
            &search_context,
            &fs_start,
            &file,
            gpa.allocator(),
        )) |search_job| {
            try thread_pool.enqueue(search_job);
        }
    }

    // This is critical because we need to prevent the memory allocated by fs_walker to
    // be deallocated prematurely.
    try thread_pool.blockUntilEmpty();
}
