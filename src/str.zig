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
        // TODO(mvejnovic): Benchmark this statement. Also the current implementation
        // does the opposite LOL.
        needle: []const u8,
        _search_buf: [BatchSize]u8,

        _needle_params: cIntr.NeedleParameters,

        /// Initialize the searcher with a needle.
        ///
        /// Note that this searcher is not thread-safe. Each thread must have its own
        /// searcher object. The searcher object is NOT cheap to create.
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
                .needle = needle,
                ._needle_params = cIntr.compileNeedle(@ptrCast(needle.ptr), needle.len),
                ._search_buf = [_]u8{0} ** BatchSize,
            };

            return self;
        }

        pub fn deinit(self: *const Self) void {
            _ = self;
        }

        /// Reset the internal state of the searcher. This must be used between
        /// subsequent searches.
        pub fn reset(self: *Self) void {
            // 0 out the needle 0..(BatchSize - (needle.len - 1)) bytes to prevent us
            // accidentally finding a substring when no substring really existed.
            @memset(self._search_buf[0..(BatchSize - (self.needle.len - 1))], 0);
        }

        /// Retrieve a pointer to the internal search buffer. This search buffer is
        /// legal to write to after the searcher has been initialized. The caller is
        /// responsible for calling searchInBatch after populating buffer with
        /// batchSize() bytes.
        pub fn writeSlice(self: *Self) []u8 {
            // The first 0..(BatchSize - (needle.len - 1)) bytes are reserved for the
            // previous batch data which may in-fact contain the needle.
            return self._search_buf[(self.needle.len - 1)..];
        }

        /// Submit a batch of data to the searcher.
        /// The batch represents a unit of work that the searcher will process.
        /// The batch size must be equal to the value returned by batchSize.
        pub fn searchInBatch(self: *Self) bool {
            const found: bool = cIntr.avx512SearchNeedle(
                @ptrCast(&self._search_buf),
                self._search_buf.len,
                @ptrCast(&self._needle_params),
            );

            // Take the last (needle.len - 1) bytes from the search buffer and copy
            // them back.
            const out_slice = self._search_buf[0..(self.needle.len - 1)];
            const in_slice = self._search_buf[(BatchSize - (self.needle.len - 1))..];
            @memcpy(out_slice, in_slice);

            return found;
        }
    };
}
