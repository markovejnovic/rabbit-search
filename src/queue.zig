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

pub fn BatchedQueue(comptime T: type, batch_size: comptime_int) type {
    return struct {
        const Self = @This();

        _data: [batch_size]T,
        _has_data: bool,

        // TODO(mvejnovic): This implementation with these condvars kind of sucks
        // because there is dead time. Ideally, _data is treated as a real FIFO queue,
        // blocked only when absolutely necessary. Right now it acts like a mailbox.
        _data_emptied: std.Thread.Condition,
        _data_filled: std.Thread.Condition,

        _mutex: std.Thread.Mutex,

        metrics: QueueMeter,

        _push_batch: [batch_size]T,
        _push_idx: usize,

        _pop_batch: [batch_size]T,
        _pop_idx: usize,

        pub fn init(name: []const u8) !Self {
            var self = Self{
                ._data = undefined,
                ._mutex = .{},
                ._data_emptied = .{},
                ._data_filled = .{},
                ._has_data = false,

                ._push_batch = undefined,
                ._push_idx = 0,

                ._pop_batch = undefined,
                ._pop_idx = 0,

                .metrics = QueueMeter.init(name),
            };

            self._data_emptied.signal();

            return self;
        }

        pub fn deinit(self: *Self) void {
            self._alloc.free(self._data);
        }

        pub fn push(self: *Self, item: T) void {
            std.log.debug("BatchedQueue[{}].push(...)", .{self._push_idx});
            // Attempt to push into the push batch.
            self._push_batch[self._push_idx] = item;
            self._push_idx += 1;

            // When we fill up the queue, then we need to dump it into the shared queue.
            if (self._push_idx != batch_size) {
                std.log.debug("(push-idx = {}) != (batch-size = {})", .{ self._push_idx, batch_size });
                return;
            }

            // First, grab the lock, and attempt to push into the shared queue.
            // Note that the acquisition of this lock MAY block (which is what we
            // want).
            self._mutex.lock();
            defer self._mutex.unlock();

            // If the shared queue is not empty, we need to wait.
            if (self._has_data) {
                std.log.debug(
                    "BatchedQueue[{}].push() waiting for signal.",
                    .{self._push_idx},
                );
                self.metrics.recordSaturation();
                self._data_emptied.wait(&self._mutex);
            }

            // Then, dump the batch into the shared memory real fast.
            for (0..batch_size) |i| {
                self._data[i] = self._push_batch[i];
            }
            self._has_data = true;
            std.log.debug("BatchedQueue._has_data = true", .{});
            self._data_filled.signal();

            self._push_idx = 0;
        }

        pub fn pop(self: *Self) T {
            std.log.debug("BatchedQueue[{}].pop()", .{self._pop_idx});
            // If no elements are currently available in the pop batch, we need to load
            // another batch.
            if (self._pop_idx == 0) {
                self._mutex.lock();
                defer self._mutex.unlock();

                // If there is nothing in the queue, we need to wait for a push.
                if (!self._has_data) {
                    std.log.debug(
                        "BatchedQueue[{}].pop() waiting for signal.",
                        .{self._pop_idx},
                    );
                    self.metrics.recordStarvation();
                    self._data_filled.wait(&self._mutex);
                }

                // Load a new batch from the shared queue.
                for (0..batch_size) |i| {
                    self._pop_batch[i] = self._data[i];
                }

                self._pop_idx = batch_size - 1;
                std.log.debug(
                    "BatchedQueue[{}].pop() loaded new batch",
                    .{self._pop_idx},
                );
                self._has_data = false;
                std.log.debug("BatchedQueue._has_data = false", .{});
                self._data_emptied.signal();
            }

            defer self._pop_idx -= 1;
            return self._pop_batch[self._pop_idx];
        }
    };
}
