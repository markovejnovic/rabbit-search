const cString = @cImport({
    @cInclude("string.h");
});

pub fn strsearch(needle: []const u8, haystack: []const u8) bool {
    return cString.memmem(haystack.ptr, haystack.len, needle.ptr, needle.len) != cString.NULL;
}
