const cString = @cImport({
    @cInclude("string.h");
});

const std = @import("std");
const sz_cptr_t = [*]const u8;
const sz_size_t = usize;

extern fn sz_find(
    haystack: sz_cptr_t,
    h_length: sz_size_t,
    needle: sz_cptr_t,
    n_length: sz_size_t,
) ?*anyopaque;

pub fn strsearch(needle: []const u8, haystack: []const u8) bool {
    return sz_find(haystack.ptr, haystack.len, needle.ptr, needle.len) != cString.NULL;
}
