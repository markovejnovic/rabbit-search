const std = @import("std");
const Queue = @import("./queue.zig").Queue;

pub fn SpinningThreadPool(
    comptime JobT: type,
    comptime work_f: *const fn (JobT) void,
) type {
    return struct {
        const Self = @This();

        jobs: Queue(JobT),
        workers: std.ArrayList(std.Thread),
        worker_count: u16,

        // Signifies whenever the queue is invoked to be terminated. Worker threads must
        // respect this as quickly asp ossible.
        close_event: std.atomic.Value(bool),

        /// Take one job from the work queue and run it.
        fn fetch_and_do_job(self: *Self) void {
            if (self.jobs.try_pop()) |job| {
                // Run it.
                work_f(job);
            }
        }

        /// Callable invoked by the worker threads.
        fn tq_worker(tp: *Self) void {
            // We will spin until the parent thread asks us to shut the hell up.
            while (!tp.close_event.load(.unordered)) {
                // Fetch a job, and if one exists...
                tp.fetch_and_do_job();
            }
        }

        pub fn init(
            alloc: std.mem.Allocator,
            worker_count: u16,
        ) !Self {
            var self = Self{
                // Let us initialize the work queue.
                .jobs = Queue(JobT).init(alloc),

                // Let's create the workers vector.
                .workers = std.ArrayList(std.Thread).init(alloc),

                .worker_count = worker_count,

                .close_event = std.atomic.Value(bool).init(false),
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
        pub fn block_until_empty(self: *Self) void {
            // Treat self similarly to tq_worker, but instead of guarding on the event,
            // we guard on the size of the queue.
            while (self.jobs.len() > 0) {
                self.fetch_and_do_job();
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
            try self.jobs.push(task);
        }
    };
}
