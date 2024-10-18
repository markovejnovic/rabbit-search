const TRACE_ENABLED = false;

const Writer = struct {
    pub fn write_u(value: usize) void {
        @import("std").log.err("{}", .{value});
    }
};

pub fn Counter(comptime write_period: usize, WriterT: type) type {
    return struct {
        const Self = @This();

        value: usize = 0,

        pub fn inc(self: *Self) void {
            if (!TRACE_ENABLED) {
                return;
            }

            self.value += 1;
            if (self.value % write_period == 0) {
                self.flush();
            }
        }

        fn flush(self: *const Self) void {
            WriterT.write_u(self.value);
        }
    };
}

const EvtTable = struct {
    worker_wait: Counter(1024, Writer) = .{},
};

var table: EvtTable = .{};

pub fn evt_worker_wait() void {
    table.worker_wait.inc();
}
