/// Reads from the ELF auxiliary vector (set by the kernel at process
/// start). Does not call into libc.
pub inline fn getauxval(key: usize) usize {
    return @import("std").os.linux.getauxval(key);
}

/// Direct syscall wrapper for prctl(2).
pub inline fn prctl(option: i32, a2: usize, a3: usize, a4: usize, a5: usize) usize {
    return @import("std").os.linux.prctl(option, a2, a3, a4, a5);
}
