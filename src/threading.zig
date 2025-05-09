const std = @import("std");

pub fn Thread() type {
    return struct {};
}

pub fn ThreadManager() type {
    return struct {
        const Self = @This();

        _allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                ._allocator = allocator,
            };
        }

        pub fn spawn_thread(thread: anytype) void {
            _ = thread;
        }
    };
}
