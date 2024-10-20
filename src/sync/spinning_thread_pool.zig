const std = @import("std");
const SPMCQueue = @import("./queue.zig").SPMCQueue;
const sys = @import("../sys.zig");
const sysops = @cImport({
    @cInclude("sysops.h");
});

pub fn SpinningThreadPool(
    comptime WorkerT: type,
) type {
    return struct {
        const Self = @This();
        const QUEUE_CAPACITY: usize = 1024;

        const ThreadWorker = struct {
            thread: std.Thread,
            worker: *WorkerT,
        };

        jobs: SPMCQueue(WorkerT.JobType, null, null),

        _alloc: std.mem.Allocator,
        _workers: []ThreadWorker,

        // Signifies whenever the queue is invoked to be terminated. Worker threads must
        // respect this as quickly asp ossible.
        close_event: std.atomic.Value(bool),

        // Counter for the total number of threads that are running. This is useful as
        // it helps us decide which CPU to pin the thread on.
        thread_counter: std.atomic.Value(usize),

        /// Each consumer thread invokes this function to perform work.
        fn consumerStart(self: *Self, worker: *WorkerT) void {
            self.jobs.registerConsumer();

            // TODO(mvejnovic): This fetchAdd adds 2 because the cores on MY machine
            // are clustered into two. This is a hack and should be fixed.
            // My physical cores are every other core.
            const cpu_id = targetCpu(self.thread_counter.fetchAdd(2, .monotonic));
            if (sysops.pinThreadToCore(@intCast(cpu_id)) != 0) {
                std.log.err("Failed to pin thread to core.", .{});
                return;
            }

            // We will spin until the parent thread asks us to shut the hell up.
            while (!self.close_event.load(.unordered)) {
                // Fetch a job and run it if it exists.
                if (self.jobs.tryPop()) |job| {
                    // Run it.
                    worker.work(job);
                }

                // Tell the CPU we're in a spin-wait.
                sys.spinlockYield();
            }
        }

        fn targetCpu(thread_id: usize) usize {
            // Avoid pinning on the first core because that core is responsible for
            // loading into memory.
            const available_cpus = @as(usize, @intCast(sysops.getNumCpus())) - 1;
            return (thread_id % available_cpus) + 1;
        }

        pub fn init(
            alloc: std.mem.Allocator,
            workers: []WorkerT,
        ) !Self {
            const self = Self{
                // Let us initialize the work queue.
                .jobs = try SPMCQueue(WorkerT.JobType, null, null).init(
                    alloc,
                    workers.len,
                    QUEUE_CAPACITY,
                ),

                ._alloc = alloc,
                ._workers = try alloc.alloc(ThreadWorker, workers.len),

                .close_event = std.atomic.Value(bool).init(false),

                // TODO(mvejnovic): This is hacky because the main.zig sets the main
                // core as the first core.
                .thread_counter = std.atomic.Value(usize).init(2),
            };

            for (workers, self._workers) |*worker, *worker_thread| {
                worker_thread.worker = worker;
            }

            return self;
        }

        /// Close-off all threads and deinitialize memory.
        pub fn deinit(self: *Self) void {
            // This would be an unsafe function if we don't terminate it explicitly.
            // Although the intended usage is for the user to call self.terminate, let
            // us call it to make sure this .deinit() would be safe for the rest of the
            // application.
            self.terminate();

            // We can deallocate the worker memory now as nobody depends on it.
            self._alloc.free(self._workers);

            // Now that we have very nicely exited each and every worker, nobody should
            // be contending the jobs and we should be able to free it.
            self.jobs.deinit();
        }

        /// Synchronously start all threads. This blocks until all threads are spawned
        /// and then proceeds.
        pub fn begin(self: *Self) !void {
            for (self._workers) |*worker| {
                const t = try std.Thread.spawn(
                    .{},
                    consumerStart,
                    .{ self, worker.worker },
                );
                worker.thread = t;
            }
        }

        /// Hostage the current thread to perform work too until the job queue empties
        /// out.
        pub fn blockUntilEmpty(self: *Self) !void {
            // Treat self similarly to consumerStart, but instead of guarding on the
            // event, we guard on the size of the queue.
            while (self.jobs.len() > 0) {
                // TODO(mvejnovic): This is kind of crappy because this thread could
                // also be doing real good work.
                try std.Thread.yield();
            }

            self.terminate();
        }

        /// Attempt to terminate the loop as quickly as possible, regardless of the
        /// amount of work left to do.
        pub fn terminate(self: *Self) void {
            // If the close event is already set, that means that this method was
            // already invoked. Invoking this method two times is legal, but joining on
            // a worker multiple times is not. Therefore, we need to exit early.
            if (self.close_event.load(.unordered)) {
                return;
            }

            // Don't forget to send the close event because that is what tells the
            // threads to actually exit.
            self.close_event.store(true, .unordered);

            // Then, join on threads. At this point, this should not block as they
            // should exit early.
            for (self._workers) |*w| {
                w.thread.join();
            }
        }

        pub fn enqueue(self: *Self, task: WorkerT.JobType) !void {
            try self.jobs.push(task, null);
        }
    };
}
