const std = @import("std");

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

        pub fn pushSlice(self: *Self, values: []const T) !void {
            self.lock.lock();
            defer self.lock.unlock();

            try self.els.appendSlice(values);
        }

        pub fn len(self: *const Self) usize {
            return self.els.items.len;
        }
    };
}
