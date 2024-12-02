const std = @import("std");

pub const AtomicCounter = struct {
    value: std.atomic.Value(u64),

    pub fn init() AtomicCounter {
        return AtomicCounter{ .value = std.atomic.Value(u64).init(0) };
    }

    pub fn add(self: *AtomicCounter, v: u64) void {
        _ = self.value.fetchAdd(v, .monotonic);
    }
};

pub const AtomicBandwidth = struct {
    counter: AtomicCounter,
    start_time: i128,

    pub fn init() AtomicBandwidth {
        return AtomicBandwidth{
            .counter = AtomicCounter.init(),
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn add(self: *AtomicCounter, value: u64) void {
        self.counter.add(value);
    }

    pub fn start(self: *AtomicBandwidth) void {
        self.start_time = std.time.nanoTimestamp();
    }

    pub fn get(self: *AtomicBandwidth) f64 {
        const value_count: f64 = @floatFromInt(self.counter.value.load(.monotonic));
        const duration: f64 = @floatFromInt(std.time.nanoTimestamp() - self.start_time);
        return value_count / duration * 1_000_000_000;
    }
};
