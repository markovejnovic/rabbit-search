const std = @import("std");
const builtin = @import("builtin");

fn isPowerOfTwo(comptime n: usize) bool {
    if (n == 0) return false; // 0 is not a power of two
    return (n & (n - 1)) == 0;
}

fn intln2(comptime n: anytype) @TypeOf(n) {
    return std.math.log2(n);
}

/// Thread-safe synchronization queue.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        lock: std.Thread.Mutex,
        els: std.ArrayList(T),

        pub fn init(job_queue_allocator: std.mem.Allocator) Queue(T) {
            return .{
                .els = std.ArrayList(T).init(job_queue_allocator),
                .lock = std.Thread.Mutex{},
            };
        }

        pub fn deinit(q: *Self) void {
            q.els.deinit();
        }

        pub fn try_pop(q: *Self) ?T {
            q.lock.lock();
            defer q.lock.unlock();

            return q.els.popOrNull();
        }

        pub fn push(q: *Self, val: T) !void {
            q.lock.lock();
            defer q.lock.unlock();

            try q.els.append(val);
        }

        pub fn len(self: *const Self) usize {
            return self.els.items.len;
        }
    };
}

pub fn SPSCQueue(comptime T: type, comptime comptime_capacity: ?usize) type {
    return struct {
        const Self = @This();

        const CacheLineSize = std.atomic.cache_line;

        // SlotsPadding serves to pad the start and end of self.slots so that false
        // sharing can be avoided between the elements in slots and some other memory
        // that may be present in the system.
        // https://en.wikipedia.org/wiki/False_sharing
        //
        // TODO(mvejnovic): I don't understand this seemingly janky implementation of
        // SlotsPadding.
        const SlotsPadding: usize = (CacheLineSize - 1) / @sizeOf(T) + 1;

        allocator: std.mem.Allocator,
        // Note(mvejnovic): These slots are not line aligned. If you can pin the
        // producer core, that's ideal, if you cannot, you're gonezo.
        // Working with points as a slice is slightly annoying since there is padding
        // in the array so the "capacity" is slightly misleading.
        slots: [*]T,
        capacity: usize,

        // The alignment here is EXTREMELY important as it pushes the
        write_idx: std.atomic.Value(usize) align(std.atomic.cache_line),
        read_idx_cache: usize align(std.atomic.cache_line),
        read_idx: std.atomic.Value(usize) align(std.atomic.cache_line),
        write_idx_cache: usize align(std.atomic.cache_line),

        pub fn init(allocator: std.mem.Allocator, requested_capacity: ?usize) !Self {
            if (comptime_capacity == null and requested_capacity == null) {
                return error.InvalidCapacity;
            }

            if (comptime_capacity != null and requested_capacity != null and comptime_capacity != requested_capacity) {
                return error.InvalidCapacity;
            }

            if (requested_capacity orelse comptime_capacity.? == 0) {
                return error.InvalidCapacity;
            }

            // This is the total number of chunks we plan on allocating.
            const requested_raw_capacity = (requested_capacity orelse comptime_capacity.?) + 1;

            // Simply the maximum number of bytes
            const max_raw_capacity = std.math.maxInt(usize);

            if (requested_raw_capacity > max_raw_capacity - 2 * SlotsPadding) {
                return error.InvalidCapacity;
            }

            const self: Self = .{
                .allocator = allocator,
                .slots = (try allocator.alloc(T, requested_raw_capacity + 2 * SlotsPadding)).ptr,
                .capacity = requested_raw_capacity,
                .write_idx = std.atomic.Value(usize).init(0),
                .read_idx_cache = 0,
                .read_idx = std.atomic.Value(usize).init(0),
                .write_idx_cache = 0,
            };

            std.debug.assert((@intFromPtr(&self.read_idx) - @intFromPtr(&self.write_idx)) >= std.atomic.cache_line);

            // TODO(mvejnovic): add nag if the user doesn't have correct affinity

            return self;
        }

        pub fn deinit(self: *Self) void {
            while (self.front() != null) {
                _ = self.pop();
            }

            self.allocator.free(self.slots[0..(self.capacity + 2 * SlotsPadding)]);
        }

        pub fn capacity(self: *const Self) bool {
            return self.capacity - 1;
        }

        pub fn empty(self: *const Self) bool {
            return self.write_idx.load(.acquire) == self.read_idx.load(.acquire);
        }

        pub fn push(self: *Self, value: T) bool {
            const write_idx = self.write_idx.load(.monotonic);
            const next_write_idx = self.nextIdx(write_idx);

            if (next_write_idx == self.read_idx_cache) {
                // If the indices are the same, the read_idx_cache is now out of date.
                // Let us attempt to read the new read idx, flushing the caches.
                self.read_idx_cache = self.read_idx.load(.acquire);
                if (next_write_idx == self.read_idx_cache) {
                    // If still both the values match, we're looking at a queue for
                    // which the true state is write_idx == read_idx which means the
                    // queue is full.
                    return false;
                }
            }

            self.slots[write_idx + SlotsPadding] = value;
            self.write_idx.store(next_write_idx, .release);

            return true;
        }

        pub fn pop(self: *Self) ?T {
            const val = self.front();
            if (val == null) {
                return val;
            }

            const read_idx = self.read_idx.load(.monotonic);

            // TODO(mvejnovic): Do we need this barrier?
            const write_idx = self.write_idx.load(.acquire);

            // This assertion proves that front() has been invoked.
            std.debug.assert(write_idx != read_idx);

            // The following block computes the next read index.
            // Because capacity may be comptime
            self.read_idx.store(self.nextIdx(read_idx), .release);

            return val;
        }

        pub fn spinPush(self: *Self, value: T, timeout_ns: u64) !void {
            var timer = try std.time.Timer.start();

            while (timer.read() < timeout_ns) {
                if (self.push(value)) {
                    return;
                }

                try std.Thread.yield();
            }

            return error.SpinningTimedOut;
        }

        pub fn spinPop(self: *Self, timeout_ns: u64) !T {
            var timer = try std.time.Timer.start();

            while (timer.read() < timeout_ns) {
                const value = self.pop();
                if (value != null) {
                    return value.?;
                }

                try std.Thread.yield();
            }

            return error.SpinningTimedOut;
        }

        pub fn front(self: *Self) ?T {
            const read_idx = self.read_idx.load(.monotonic);

            if (read_idx == self.write_idx_cache) {
                // If the indices are the same, the write_idx_cache is now out of date.
                // Let us attempt to read the new write idx, flushing the caches.
                self.write_idx_cache = self.write_idx.load(.acquire);
                if (self.write_idx_cache == read_idx) {
                    // If still both the values match, we're looking at a queue for
                    // which the true state is write_idx == read_idx which means the
                    // queue is empty.
                    return null;
                }
            }

            return self.slots[read_idx + SlotsPadding];
        }

        fn nextIdx(self: *const Self, index: usize) usize {
            if (comptime_capacity != null and isPowerOfTwo(comptime_capacity.?)) {
                // This and trick is equivalent to performing the modulo operation for
                // powers of two.
                const mask = comptime_capacity.? - 1;

                return (index + 1) & mask;
            } else {
                var next_read_idx: usize = undefined;
                next_read_idx = index + 1;
                if (next_read_idx == self.capacity) {
                    next_read_idx = 0;
                }

                return next_read_idx;
            }
        }
    };
}

test "spsc no data loss underfilled queue" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;

    const Q = SPSCQueue(u32, null);

    const Runner = struct {
        queue: *Q,

        fn run(self: *@This()) !void {
            var i: u32 = 1;
            while (i <= num_increments) : (i += 1) {
                try std.testing.expect(self.queue.push(i));
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, 1024);
    defer queue.deinit();
    var runner = Runner{ .queue = &queue };

    // Start the tread that pushes data.
    var thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    // Within our thread, pop all elements and assert they are monotonically increasing
    // by +1.
    var recv_counter: u32 = 0;
    var i: usize = 0;
    while (recv_counter < num_increments and i < num_increments) : (i += 1) {
        const new_recv_counter = try queue.spinPop(std.time.ns_per_ms * 10);
        try std.testing.expectEqual(recv_counter + 1, new_recv_counter);
        recv_counter = new_recv_counter;
    }
    try std.testing.expectEqual(num_increments, recv_counter);

    thread.join();
}

test "spsc no data loss overfilled queue" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;

    const Q = SPSCQueue(u32, null);

    const Runner = struct {
        queue: *Q,

        fn run(self: *@This()) !void {
            var i: u32 = 1;
            while (i <= num_increments) : (i += 1) {
                try self.queue.spinPush(i, std.time.ns_per_ms * 10);
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, 64);
    defer queue.deinit();
    var runner = Runner{ .queue = &queue };

    // Start the tread that pushes data.
    var thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    // Within our thread, pop all elements and assert they are monotonically increasing
    // by +1.
    var recv_counter: u32 = 0;
    var i: usize = 0;
    while (recv_counter < num_increments and i < num_increments) : (i += 1) {
        const new_recv_counter = try queue.spinPop(std.time.ns_per_ms * 10);
        try std.testing.expectEqual(recv_counter + 1, new_recv_counter);
        recv_counter = new_recv_counter;
    }
    try std.testing.expectEqual(num_increments, recv_counter);

    thread.join();
}

test "spsc no data loss underfilled queue comptime length" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;

    const Q = SPSCQueue(u32, 1024);

    const Runner = struct {
        queue: *Q,

        fn run(self: *@This()) !void {
            var i: u32 = 1;
            while (i <= num_increments) : (i += 1) {
                try std.testing.expect(self.queue.push(i));
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, 1024);
    defer queue.deinit();
    var runner = Runner{ .queue = &queue };

    // Start the tread that pushes data.
    var thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    // Within our thread, pop all elements and assert they are monotonically increasing
    // by +1.
    var recv_counter: u32 = 0;
    var i: usize = 0;
    while (recv_counter < num_increments and i < num_increments) : (i += 1) {
        const new_recv_counter = try queue.spinPop(std.time.ns_per_ms * 10);
        try std.testing.expectEqual(recv_counter + 1, new_recv_counter);
        recv_counter = new_recv_counter;
    }
    try std.testing.expectEqual(num_increments, recv_counter);

    thread.join();
}

test "spsc no data loss overfilled queue comptime length" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;

    const Q = SPSCQueue(u32, 64);

    const Runner = struct {
        queue: *Q,

        fn run(self: *@This()) !void {
            var i: u32 = 1;
            while (i <= num_increments) : (i += 1) {
                try self.queue.spinPush(i, std.time.ns_per_ms * 10);
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, 64);
    defer queue.deinit();
    var runner = Runner{ .queue = &queue };

    // Start the tread that pushes data.
    var thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    // Within our thread, pop all elements and assert they are monotonically increasing
    // by +1.
    var recv_counter: u32 = 0;
    var i: usize = 0;
    while (recv_counter < num_increments and i < num_increments) : (i += 1) {
        const new_recv_counter = try queue.spinPop(std.time.ns_per_ms * 10);
        try std.testing.expectEqual(recv_counter + 1, new_recv_counter);
        recv_counter = new_recv_counter;
    }
    try std.testing.expectEqual(num_increments, recv_counter);

    thread.join();
}
