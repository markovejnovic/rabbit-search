const cStringZilla = @cImport({
    @cInclude("broken.h");
});

pub fn strsearch(needle: []const u8, haystack: []const u8) bool {
    return cStringZilla.sz_find(haystack.ptr, haystack.len, needle.ptr, needle.len) != 0;
}
