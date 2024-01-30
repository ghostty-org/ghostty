// https://developer.arm.com/architectures/instruction-sets/intrinsics
// https://llvm.org/docs/LangRef.html#inline-assembler-expressions

const std = @import("std");
const assert = std.debug.assert;

pub inline fn vandq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ and %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vceqq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ cmeq %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vcgeq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ cmhs %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vcgtq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ cmhi %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vdupq_n_u8(v: u8) @Vector(16, u8) {
    return asm (
        \\ dup %[ret].16b, %[value:w]
        : [ret] "=w" (-> @Vector(16, u8)),
        : [value] "r" (v),
    );
}

pub inline fn veorq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ eor %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vextq_u8(a: @Vector(16, u8), b: @Vector(16, u8), n: u8) @Vector(16, u8) {
    assert(n <= 16);
    return asm (
        \\ ext %[ret].16b, %[a].16b, %[b].16b, %[n]
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
          [n] "I" (n),
    );
}

pub inline fn vget_lane_u64(v: @Vector(1, u64)) u64 {
    return asm (
        \\ umov %[ret], %[v].d[0]
        : [ret] "=r" (-> u64),
        : [v] "w" (v),
    );
}

pub inline fn vld1q_u8(v: []const u8) @Vector(16, u8) {
    return asm (
        \\ ld1 { %[ret].16b }, [%[value]]
        : [ret] "=w" (-> @Vector(16, u8)),
        : [value] "r" (v.ptr),
    );
}

pub inline fn vmaxvq_u8(v: @Vector(16, u8)) u8 {
    const result = asm (
        \\ umaxv %[ret:b], %[v].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [v] "w" (v),
    );

    return result[0];
}

pub inline fn vorrq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ orr %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vqtbl1q_u8(t: @Vector(16, u8), idx: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ tbl %[ret].16b, { %[t].16b }, %[idx].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [idx] "w" (idx),
          [t] "w" (t),
    );
}

pub inline fn vshrn_n_u16(a: @Vector(8, u16), n: u4) @Vector(8, u8) {
    assert(n <= 8);
    return asm (
        \\ shrn %[ret].8b, %[a].8h, %[n]
        : [ret] "=w" (-> @Vector(8, u8)),
        : [a] "w" (a),
          [n] "I" (n),
    );
}

pub inline fn vshrq_n_u8(a: @Vector(16, u8), n: u8) @Vector(16, u8) {
    assert(n <= 8);
    return asm (
        \\ ushr %[ret].16b, %[a].16b, %[n]
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [n] "I" (n),
    );
}

pub inline fn rbit(comptime T: type, v: T) T {
    assert(T == u32 or T == u64);
    return asm (
        \\ rbit %[ret], %[v]
        : [ret] "=r" (-> T),
        : [v] "r" (v),
    );
}

pub inline fn clz(comptime T: type, v: T) T {
    assert(T == u32 or T == u64);
    return asm (
        \\ clz %[ret], %[v]
        : [ret] "=r" (-> T),
        : [v] "r" (v),
    );
}
