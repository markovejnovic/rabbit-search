const cSysinfo = @cImport({
    @cInclude("sys/sysinfo.h");
});

pub fn getNumCpus() u64 {
    return @intCast(cSysinfo.get_nprocs());
}

pub fn boundary_align(val: anytype, boundary: @TypeOf(val)) @TypeOf(val) {
    if (val % boundary == 0) {
        return @intCast(val);
    }

    return ((val / boundary) + 1) * boundary;
}
