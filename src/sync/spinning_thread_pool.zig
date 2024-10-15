const std = @import("std");
const SPMCQueue = @import("./queue.zig").SPMCQueue;
const sys = @import("../sys.zig");

pub fn SpinningThreadPool(
    comptime JobT: type,
    comptime work_f: *const fn (JobT) void,
) type {
    return struct {
        const Self = @This();
        const QUEUE_CAPACITY: usize = 1024;

        jobs: SPMCQueue(JobT, null, null),
        workers: std.ArrayList(std.Thread),
        worker_count: u16,

        // Signifies whenever the queue is invoked to be terminated. Worker threads must
        // respect this as quickly asp ossible.
        close_event: std.atomic.Value(bool),

        // Counter for the total number of threads that are running. This is useful as
        // it helps us decide which CPU to pin the thread on.
        thread_counter: std.atomic.Value(usize),

        /// Take one job from the work queue and run it.
        fn fetchAndDo(self: *Self) void {
            if (self.jobs.tryPop()) |job| {
                // Run it.
                work_f(job);
            }
        }

        /// Callable invoked by the worker threads.
        fn tq_worker(self: *Self) void {
            self.jobs.registerConsumer();

            // We will spin until the parent thread asks us to shut the hell up.
            while (!self.close_event.load(.unordered)) {
                // Fetch a job, and if one exists...
                self.fetchAndDo();
            }
        }

        fn targetCpu(thread_id: usize) usize {
            return (thread_id % sys.getNumCpus() - 1) + 1;
        }

        pub fn init(
            alloc: std.mem.Allocator,
            worker_count: u16,
        ) !Self {
            var self = Self{
                // Let us initialize the work queue.
                .jobs = try SPMCQueue(JobT, null, null).init(
                    alloc,
                    worker_count,
                    QUEUE_CAPACITY,
                ),

                // Let's create the workers vector.
                .workers = std.ArrayList(std.Thread).init(alloc),

                .worker_count = worker_count,

                .close_event = std.atomic.Value(bool).init(false),

                .thread_counter = std.atomic.Value(usize).init(0),
            };
            try self.workers.ensureTotalCapacity(worker_count);
            return self;
        }

        pub fn begin(self: *Self) !void {
            for (0..self.worker_count) |_| {
                const thread = try std.Thread.spawn(.{}, tq_worker, .{self});
                try self.workers.append(thread);
            }
        }

        /// Hostage the current thread to perform work too until the job queue empties
        /// out.
        pub fn blockUntilEmpty(self: *Self) !void {
            // Treat self similarly to tq_worker, but instead of guarding on the event,
            // we guard on the size of the queue.
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
            // workers to actually exit.
            self.close_event.store(true, .unordered);

            // Then, join on threads. At this point, this should not block as they
            // should exit early.
            for (self.workers.items) |worker| {
                worker.join();
            }
        }

        /// Close-off all threads and deinitialize memory.
        pub fn deinit(self: *Self) void {
            // This would be an unsafe function if we don't terminate it explicitly.
            // Although the intended usage is for the user to call self.terminate, let
            // us call it to make sure this .deinit() would be safe for the rest of the
            // application.
            self.terminate();

            // We can deallocate the worker memory now as nobody depends on it.
            self.workers.deinit();

            // Now that we have very nicely exited each and every worker, nobody should
            // be contending the jobs and we should be able to free it.
            self.jobs.deinit();
        }

        pub fn enqueue(self: *Self, task: JobT) !void {
            try self.jobs.push(task, 1 * std.time.ns_per_s);
        }
    };
}
