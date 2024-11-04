const std = @import("std");

pub const QueueMeter = struct {
    const Self = @This();

    _name: []const u8,
    starvation_counter: std.atomic.Value(u64),
    saturation_counter: std.atomic.Value(u64),

    pub fn init(name: []const u8) Self {
        return Self{
            ._name = name,
            .starvation_counter = std.atomic.Value(u64).init(0),
            .saturation_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordStarvation(self: *Self) void {
        const starvation = self.starvation_counter.fetchAdd(1, .monotonic);
        if (starvation % 10 == 0) {
            std.log.err("{s} starved", .{self._name});
        }
    }

    pub fn recordSaturation(self: *Self) void {
        const saturated = self.saturation_counter.fetchAdd(1, .monotonic);
        if (saturated % 10 == 0) {
            std.log.err("{s} saturated", .{self._name});
        }
    }
};

fn Stack(comptime T: type, Capacity: comptime_int) type {
    return struct {
        const Self = @This();

        data: [Capacity]T,
        _idx: usize,

        pub fn init() Self {
            return Self{
                .data = undefined,
                ._idx = 0,
            };
        }

        pub fn size(self: *Self) usize {
            return self._idx;
        }

        pub fn capacity(self: *Self) usize {
            _ = self;
            return Capacity;
        }

        pub fn availableSpace(self: *Self) usize {
            return self.capacity() - self.size();
        }

        pub fn full(self: *Self) bool {
            return self.size() == self.capacity();
        }

        pub fn empty(self: *Self) bool {
            return self.size() == 0;
        }

        pub fn pop(self: *Self) !T {
            if (self.size() == 0) {
                return error.QueueEmpty;
            }
            return self.dangerousPop();
        }

        pub fn dangerousPop(self: *Self) T {
            defer self._idx -= 1;
            return self.data[self._idx - 1];
        }

        pub fn dangerousPopMany(self: *Self, into: []T) void {
            @memcpy(into, self.data[(self._idx - into.len)..self._idx]);
            self._idx -= into.len;
        }

        pub fn dangerousPush(self: *Self, item: T) void {
            self.data[self._idx] = item;
            self._idx += 1;
        }

        pub fn push(self: *Self, item: T) !void {
            if (self.size() == Capacity) {
                return error.QueueFull;
            }
            self.dangerousPush(item);
        }

        pub fn dangerousPushMany(self: *Self, items: []const T) void {
            @memcpy(self.data[self._idx..(items.len + self._idx)], items);
            self._idx += items.len;
        }

        pub fn flush(self: *Self) void {
            self._idx = 0;
        }

        pub fn fill(self: *Self) void {
            self.fillWith(self.capacity());
        }

        pub fn fillWith(self: *Self, len: usize) void {
            self._idx = len;
        }
    };
}

pub fn SPSCChan(
    comptime T: type,
    BatchSize: comptime_int,
    SharedScale: comptime_int,
) type {
    return struct {
        const Self = @This();

        _front: Stack(T, BatchSize) align(std.atomic.cache_line),
        _back: Stack(T, BatchSize) align(std.atomic.cache_line),

        // These values need to be ordered as laid out here as we want to maximize the
        // likelyhood of them existing in the same cache line.
        _mutex: std.Thread.Mutex,
        _front_shared_cond: std.Thread.Condition,
        _back_shared_cond: std.Thread.Condition,
        _shared: Stack(T, BatchSize * SharedScale),

        _name: []const u8, // TODO(mvejnovic): Only useful for debugging.

        pub fn init(name: []const u8) Self {
            return Self{
                ._front = Stack(T, BatchSize).init(),
                ._back = Stack(T, BatchSize).init(),
                ._shared = Stack(T, BatchSize * SharedScale).init(),
                ._mutex = .{},
                ._front_shared_cond = .{},
                ._back_shared_cond = .{},
                ._name = name,
            };
        }

        /// Whenever the publisher is done submitting data, it must invoke close which
        /// will propagate whatever data it has down to the consumer, as well as
        /// interrupt the consumer which might be stuck waiting for more data.
        pub fn close(self: *Self) void {
            // Move the front buffer into the shared domain.
            self.shareFront();
        }

        pub fn push(self: *Self, item: T) void {
            self._front.dangerousPush(item);
            if (self._front.full()) {
                // If the front buffer is full, we need to memcpy it into the shared
                // domain. This is potentially expensive as it may force contention
                // between the producer and the consumer.
                self.shareFront();
            }
        }

        pub fn pop(self: *Self) T {
            if (self._back.empty()) {
                // The back buffer is empty so we need to move a part of the shared
                // space into the back buffer. Again, this is potentially expensive.
                self.shareBack();
            }
            return self._back.dangerousPop();
        }

        pub fn tryThreadUnsafePop(self: *Self) ?T {
            if (self._back.empty()) {
                // The back buffer is empty, however, there might be stuff in the
                // shared memory that we need to potentially move to the back buffer.
                // Note that we do not need a mutex since the contract of this function
                // is that it is thread unsafe.

                // If the shared space is in fact empty, there is literally nothing
                // else we can do.
                if (self._shared.empty()) {
                    return null;
                }

                // Otherwise, we can copy as many shared elements as we have into the
                // back buffer.
                const num_elements = @min(self._back.capacity(), self._shared.size());
                self._shared.dangerousPopMany(self._back.data[0..num_elements]);
                self._back.fillWith(num_elements);
            }

            return self._back.dangerousPop();
        }

        fn shareFront(self: *Self) void {
            // This function bangs on the shared domain between the two threads. It
            // therefore needs to be synchronized.
            self._mutex.lock();
            defer self._mutex.unlock();

            while (self._shared.availableSpace() < self._front.size()) {
                // If the shared space does not have sufficient space, we need to make
                // sure that we wait until it ends up having some space.
                self._back_shared_cond.wait(&self._mutex);
            }

            // Otherwise, we can simply tack on this value onto front.
            self._shared.dangerousPushMany(
                self._front.data[0..self._front.size()],
            );
            self._front.flush();
            self._front_shared_cond.signal();
        }

        fn shareBack(self: *Self) void {
            // This function bangs on the shared domain between the two threads. It
            // therefore needs to be synchronized.
            self._mutex.lock();
            defer self._mutex.unlock();

            while (self._shared.size() == 0) {
                // If there aren't enough elements in the shared space, we need to wait
                // until there are enough.
                self._front_shared_cond.wait(&self._mutex);
            }

            // Otherwise, we can simply tack on this value onto back.
            const num_elements = @min(self._back.capacity(), self._shared.size());
            self._shared.dangerousPopMany(self._back.data[0..num_elements]);
            self._back.fillWith(num_elements);
            self._back_shared_cond.signal();
        }
    };
}

test "Ensure that the Stack works" {
    var stack = Stack(u32, 4).init();
    stack.dangerousPush(1);
    stack.dangerousPush(2);
    stack.dangerousPush(3);
    stack.dangerousPush(4);
    try std.testing.expectEqual(4, stack.dangerousPop());
    try std.testing.expectEqual(3, stack.dangerousPop());
    try std.testing.expectEqual(2, stack.dangerousPop());
    try std.testing.expectEqual(1, stack.dangerousPop());
}

test "Ensure that the SPSCChan works" {
    var stack = SPSCChan(u32, 4, 4).init("test");
    stack.push(1);
    stack.push(2);
    stack.push(3);
    stack.push(4);
    try std.testing.expectEqual(4, stack.pop());
    try std.testing.expectEqual(3, stack.pop());
    try std.testing.expectEqual(2, stack.pop());
    try std.testing.expectEqual(1, stack.pop());
}

test "Ensure that the SPSCChan works with small batches" {
    var stack = SPSCChan(u32, 1, 4).init("test");
    stack.push(1);
    stack.push(2);
    stack.push(3);
    stack.push(4);
    try std.testing.expectEqual(4, stack.pop());
    try std.testing.expectEqual(3, stack.pop());
    try std.testing.expectEqual(2, stack.pop());
    try std.testing.expectEqual(1, stack.pop());
}

test "Ensure that the SPSCChan works with partially filled batches." {
    var stack = SPSCChan(u32, 2, 4).init("test");
    stack.push(1);
    stack.push(2);
    stack.push(3);
    try std.testing.expectEqual(2, stack.pop());
    try std.testing.expectEqual(1, stack.pop());
    stack.close();
    try std.testing.expectEqual(3, stack.tryThreadUnsafePop());
    try std.testing.expectEqual(null, stack.tryThreadUnsafePop());
}
