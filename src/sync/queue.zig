const std = @import("std");
const builtin = @import("builtin");

fn isPowerOfTwo(comptime n: usize) bool {
    if (n == 0) return false; // 0 is not a power of two
    return (n & (n - 1)) == 0;
}

fn intln2(comptime n: anytype) @TypeOf(n) {
    return std.math.log2(n);
}

/// Note that this function does not sanitize comptime_capacity nor capacity
fn cyclicalIdx(index: usize, comptime comptime_capacity: ?usize, capacity: ?usize) usize {
    if (comptime_capacity != null and isPowerOfTwo(comptime_capacity.?)) {
        // This and trick is equivalent to performing the modulo operation for
        // powers of two.
        const mask = comptime_capacity.? - 1;

        return (index + 1) & mask;
    } else {
        var next_read_idx: usize = undefined;
        next_read_idx = index + 1;
        if (next_read_idx == capacity) {
            next_read_idx = 0;
        }

        return next_read_idx;
    }
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

            var desired_capacity: usize = 0;

            if (requested_capacity != null) {
                desired_capacity = requested_capacity.?;
                if (requested_capacity.? == 0) {
                    return error.InvalidCapacity;
                }
            }

            if (comptime_capacity != null) {
                desired_capacity = comptime_capacity.?;
                if (comptime_capacity.? == 0) {
                    return error.InvalidCapacity;
                }
            }

            // This is the total number of chunks we plan on allocating.
            const requested_raw_capacity = desired_capacity + 1;

            if (requested_raw_capacity > std.math.maxInt(usize) - 2 * SlotsPadding) {
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

        pub fn len(self: *const Self) usize {
            const diff = @subWithOverflow(
                self.write_idx.load(.monotonic),
                self.read_idx.load(.monotonic),
            );

            if (diff[1] == 1) {
                return @addWithOverflow(diff[0], self.capacity)[0];
            }

            return diff[0];
        }

        pub fn empty(self: *const Self) bool {
            return self.write_idx.load(.acquire) == self.read_idx.load(.acquire);
        }

        pub fn push(self: *Self, value: T) bool {
            const write_idx = self.write_idx.load(.monotonic);
            const next_write_idx = cyclicalIdx(write_idx, comptime_capacity, self.capacity);

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
                return null;
            }

            // TODO(mvejnovic): Do we need this barrier?
            _ = self.write_idx.load(.acquire);

            // The following block computes the next read index.
            // Because capacity may be comptime
            const read_idx = self.read_idx.load(.monotonic);
            self.read_idx.store(
                cyclicalIdx(read_idx, comptime_capacity, self.capacity),
                .release,
            );

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
        const new_recv_counter = try queue.spinPop(std.time.ns_per_ms * 1000);
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

pub fn SPMCQueue(
    comptime T: type,
    comptime comptime_queue_count: ?usize,
    comptime comptime_capacity: ?usize,
) type {
    return struct {
        const Self = @This();
        const SPSC = SPSCQueue(T, comptime_capacity);

        threadlocal var consumer_idx: usize = undefined;

        queues: std.ArrayList(SPSC),
        push_idx: std.atomic.Value(usize),
        rolling_consumer_idx: std.atomic.Value(usize),

        pub fn init(allocator: std.mem.Allocator, queue_count: ?usize, requested_capacity: ?usize) !Self {
            if (comptime_queue_count == null and queue_count == null) {
                return error.InvalidQueueCount;
            }

            if (comptime_queue_count != null and queue_count != null and comptime_queue_count != queue_count) {
                return error.InvalidQueueCount;
            }

            var desired_queue_count: usize = 0;
            if (queue_count != null) {
                desired_queue_count = queue_count.?;
            }
            if (comptime_queue_count != null) {
                desired_queue_count = comptime_queue_count.?;
            }

            if (desired_queue_count == 0) {
                return error.InvalidQueueCount;
            }

            // Allocate enough memory for the array list
            var self: Self = .{
                .queues = try std.ArrayList(SPSC).initCapacity(
                    allocator,
                    desired_queue_count,
                ),
                .push_idx = std.atomic.Value(usize).init(0),
                .rolling_consumer_idx = std.atomic.Value(usize).init(0),
            };

            // Populate the array list with a bunch of queues (however many the user
            // requested).
            for (0..desired_queue_count) |_| {
                try self.queues.append(try SPSC.init(allocator, requested_capacity));
            }

            return self;
        }

        pub fn push(self: *Self, value: T, timeout_ns: u64) !void {
            // Note the semantics of the SPSCQueue are not consistent with the
            // semantics of this queue. That queue returns a boolean indicating whether
            // the push was successful or not, but this queue is responsible for
            // waiting.
            const push_idx = self.push_idx.load(.monotonic);

            var relevant_queue: *SPSC = &self.queues.items[push_idx];
            try relevant_queue.spinPush(value, timeout_ns);
            const new_idx = cyclicalIdx(
                push_idx,
                comptime_queue_count,
                self.queues.capacity,
            );
            self.push_idx.store(new_idx, .monotonic);
        }

        pub fn pop(self: *Self, timeout_ns: u64) !T {
            // Note the semantics of the SPSCQueue are not consistent with the
            // semantics of this queue. That queue returns a boolean indicating whether
            // the push was successful or not, but this queue is responsible for
            // waiting.
            return self.queues.items[consumer_idx].spinPop(timeout_ns);
        }

        pub fn tryPop(self: *Self) ?T {
            // Note the semantics of the SPSCQueue are not consistent with the
            // semantics of this queue. That queue returns a boolean indicating whether
            // the push was successful or not, but this queue is responsible for
            // waiting.
            return self.queues.items[consumer_idx].pop();
        }

        pub fn len(self: *const Self) usize {
            var sum_len: usize = 0;
            for (self.queues.items) |q| {
                sum_len += q.len();
            }
            return sum_len;
        }

        /// Register a new thread as a consumer.
        pub fn registerConsumer(self: *Self) void {
            consumer_idx = self.rolling_consumer_idx.fetchAdd(1, .monotonic);
        }

        pub fn deinit(self: *Self) void {
            for (0..self.queues.items.len) |idx| {
                self.queues.items[idx].deinit();
            }

            self.queues.deinit();
        }
    };
}

test "spmc no data loss underfilled queue" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;
    const thread_count: usize = 4;

    const Q = SPMCQueue(u32, null, null);
    const Runner = struct {
        queue: *Q,
        idx: usize,

        fn init(queue: *Q, idx: usize) @This() {
            return .{
                .queue = queue,
                .idx = idx,
            };
        }

        fn run(self: @This()) !void {
            self.queue.registerConsumer();

            for (0..num_increments) |inc| {
                const popped_el = try self.queue.pop(1000 * std.time.ns_per_ms);
                // Topmost digit is the thread idx.
                const actual_tidx = popped_el / 1000;
                const actual_num = popped_el % 1000;

                try std.testing.expectEqual(actual_tidx, self.idx);
                try std.testing.expectEqual(actual_num, inc);
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, thread_count, 1024);
    defer queue.deinit();

    // Start the consumer threads.
    var threads = std.ArrayList(std.Thread).init(std.testing.allocator);
    defer threads.deinit();
    for (0..thread_count) |i| {
        const runner = Runner.init(&queue, i);
        try threads.append(try std.Thread.spawn(.{}, Runner.run, .{runner}));
    }

    for (0..num_increments) |inc| {
        for (0..thread_count) |tidx| {
            try queue.push(@intCast(tidx * 1000 + inc), 10 * std.time.ns_per_ms);
        }
    }

    for (threads.items) |thread| {
        thread.join();
    }
}

test "spmc no data loss overfilled queue" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;
    const thread_count: usize = 4;

    const Q = SPMCQueue(u32, null, null);
    const Runner = struct {
        queue: *Q,
        idx: usize,

        fn init(queue: *Q, idx: usize) @This() {
            return .{
                .queue = queue,
                .idx = idx,
            };
        }

        fn run(self: @This()) !void {
            self.queue.registerConsumer();

            for (0..num_increments) |inc| {
                const popped_el = try self.queue.pop(1000 * std.time.ns_per_ms);
                // Topmost digit is the thread idx.
                const actual_tidx = popped_el / 1000;
                const actual_num = popped_el % 1000;

                try std.testing.expectEqual(actual_tidx, self.idx);
                try std.testing.expectEqual(actual_num, inc);
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, thread_count, 64);
    defer queue.deinit();

    // Start the consumer threads.
    var threads = std.ArrayList(std.Thread).init(std.testing.allocator);
    defer threads.deinit();
    for (0..thread_count) |i| {
        const runner = Runner.init(&queue, i);
        try threads.append(try std.Thread.spawn(.{}, Runner.run, .{runner}));
    }

    for (0..num_increments) |inc| {
        for (0..thread_count) |tidx| {
            try queue.push(@intCast(tidx * 1000 + inc), 10 * std.time.ns_per_ms);
        }
    }

    for (threads.items) |thread| {
        thread.join();
    }
}

test "comptime spmc no data loss overfilled queue" {
    if (builtin.single_threaded) {
        return error.SkipZigTest;
    }

    const num_increments = 1000;
    const thread_count: usize = 4;

    const Q = SPMCQueue(u32, 4, 64);
    const Runner = struct {
        queue: *Q,
        idx: usize,

        fn init(queue: *Q, idx: usize) @This() {
            return .{
                .queue = queue,
                .idx = idx,
            };
        }

        fn run(self: @This()) !void {
            self.queue.registerConsumer();

            for (0..num_increments) |inc| {
                const popped_el = try self.queue.pop(1000 * std.time.ns_per_ms);
                // Topmost digit is the thread idx.
                const actual_tidx = popped_el / 1000;
                const actual_num = popped_el % 1000;

                try std.testing.expectEqual(actual_tidx, self.idx);
                try std.testing.expectEqual(actual_num, inc);
            }
        }
    };

    var queue = try Q.init(std.testing.allocator, thread_count, null);
    defer queue.deinit();

    // Start the consumer threads.
    var threads = std.ArrayList(std.Thread).init(std.testing.allocator);
    defer threads.deinit();
    for (0..thread_count) |i| {
        const runner = Runner.init(&queue, i);
        try threads.append(try std.Thread.spawn(.{}, Runner.run, .{runner}));
    }

    for (0..num_increments) |inc| {
        for (0..thread_count) |tidx| {
            try queue.push(@intCast(tidx * 1000 + inc), 10 * std.time.ns_per_ms);
        }
    }

    for (threads.items) |thread| {
        thread.join();
    }
}
