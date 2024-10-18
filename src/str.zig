const cString = @cImport({
    @cInclude("string.h");
});

const cIntr = @cImport({
    @cInclude("intr.h");
});

const std = @import("std");

pub fn CompiledSearcher(comptime vector_size_bits: usize) type {
    return struct {
        // TODO(mvejnovic): Support processors without AVX512 (which is most things).

        const Self = @This();
        pub const BatchSize = vector_size_bits / 8;

        /// Stores the needle value.
        /// I chose to hold the actual value within the searcher object as each thread
        /// will have its own searcher object. Aiming to improve cache locality.
        /// TODO(mvejnovic): Benchmark this statement.
        _needle: []const u8,
        _needle_params: cIntr.NeedleParameters,

        //_last_buf: std.ArrayList(u8),

        pub fn init(needle: []const u8) !Self {
            if (needle.len > BatchSize) {
                // TODO(mvejnovic): Handle large needles.
                std.log.err("Your needle is too large for this searcher.", .{});
                std.os.linux.exit(1);
            }

            if (needle[0] == needle[needle.len - 1]) {
                // TODO(mvejnovic): Implement better handling for when the needle head
                // and tail are equal.
                std.log.warn(
                    "Your needle's first and last characters are equal. This has a performance penalty.",
                    .{},
                );
            }

            const self = Self{
                ._needle = needle,
                ._needle_params = cIntr.compileNeedle(@ptrCast(needle.ptr), needle.len),
                //._last_buf = std.ArrayList(u8).init(allocator),
            };

            return self;
        }

        pub fn needleLen(self: *const Self) usize {
            return self._needle.len;
        }

        /// Submit a batch of data to the searcher.
        /// The batch represents a unit of work that the searcher will process.
        /// The batch size is determined for the architecture you are compiling for.
        pub fn submitBatch(self: *Self, batch: [Self.BatchSize]u8) bool {
            return cIntr.avx512SearchNeedle(
                @ptrCast(batch[0..]),
                batch.len,
                @ptrCast(&self._needle_params),
            );
        }
    };
}
