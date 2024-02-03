// https://developer.arm.com/architectures/instruction-sets/intrinsics
// https://llvm.org/docs/LangRef.html#inline-assembler-expressions

const std = @import("std");
const assert = std.debug.assert;

pub inline fn vaddlvq_u8(v: @Vector(16, u8)) u16 {
    const result = asm (
        \\ uaddlv %[ret:h], %[v].16b
        : [ret] "=w" (-> @Vector(8, u16)),
        : [v] "w" (v),
    );

    return result[0];
}

pub inline fn vaddvq_u8(v: @Vector(16, u8)) u8 {
    const result = asm (
        \\ addv %[ret:b], %[v].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [v] "w" (v),
    );

    return result[0];
}

pub inline fn vaddv_u8(v: @Vector(8, u8)) u8 {
    const result = asm (
        \\ addv %[ret:b], %[v].8b
        : [ret] "=w" (-> @Vector(8, u8)),
        : [v] "w" (v),
    );

    return result[0];
}

pub inline fn vandq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ and %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vandq_u16(a: @Vector(8, u16), b: @Vector(8, u16)) @Vector(8, u16) {
    return asm (
        \\ and %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(8, u16)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vandq_u32(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
    return asm (
        \\ and %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(4, u32)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vbicq_u16(a: @Vector(8, u16), b: @Vector(8, u16)) @Vector(8, u16) {
    return asm (
        \\ bic %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(8, u16)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vbslq_u32(
    a: @Vector(4, u32),
    b: @Vector(4, u32),
    c: @Vector(4, u32),
) @Vector(4, u32) {
    return asm (
        \\ mov %[ret].16b, %[a].16b
        \\ bsl %[ret].16b, %[b].16b, %[c].16b
        : [ret] "=&w" (-> @Vector(4, u32)),
        : [a] "w" (a),
          [b] "w" (b),
          [c] "w" (c),
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

pub inline fn vcgtq_s8(a: @Vector(16, i8), b: @Vector(16, i8)) @Vector(16, u8) {
    return asm (
        \\ cmgt %[ret].16b, %[a].16b, %[b].16b
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

pub inline fn vcltq_s8(a: @Vector(16, i8), b: @Vector(16, i8)) @Vector(16, u8) {
    return asm (
        \\ cmgt %[ret].16b, %[b].16b, %[a].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vcnt_u8(v: @Vector(8, u8)) @Vector(8, u8) {
    return asm (
        \\ cnt %[ret].8b, %[v].8b
        : [ret] "=w" (-> @Vector(8, u8)),
        : [v] "w" (v),
    );
}

pub inline fn vcreate_u8(v: u64) @Vector(8, u8) {
    return asm (
        \\ ins %[ret].D[0], %[value]
        : [ret] "=w" (-> @Vector(8, u8)),
        : [value] "r" (v),
    );
}

pub inline fn vdupq_n_s8(v: i8) @Vector(16, i8) {
    return asm (
        \\ dup %[ret].16b, %[value:w]
        : [ret] "=w" (-> @Vector(16, i8)),
        : [value] "r" (v),
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

pub inline fn vgetq_lane_u16(v: @Vector(8, u16), n: u3) u16 {
    return asm (
        \\ umov %[ret:w], %[v].h[%[n]]
        : [ret] "=r" (-> u16),
        : [v] "w" (v),
          [n] "I" (n),
    );
}

pub inline fn vgetq_lane_u64(v: @Vector(2, u64), n: u1) u64 {
    return asm (
        \\ umov %[ret], %[v].d[%[n]]
        : [ret] "=r" (-> u64),
        : [v] "w" (v),
          [n] "I" (n),
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

pub inline fn vmovq_n_u32(v: u32) @Vector(4, u32) {
    return asm (
        \\ dup %[ret].4s, %[value:w]
        : [ret] "=w" (-> @Vector(4, u32)),
        : [value] "r" (v),
    );
}

pub inline fn vmovq_n_u16(v: u16) @Vector(8, u16) {
    return asm (
        \\ dup %[ret].8h, %[value:w]
        : [ret] "=w" (-> @Vector(8, u16)),
        : [value] "r" (v),
    );
}

pub inline fn vorrq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ orr %[ret].16b, %[a].16b, %[b].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

pub inline fn vpaddq_u8(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ addp %[ret].16b, %[a].16b, %[b].16b
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

pub inline fn vqtbl2q_u8(t: [2]@Vector(16, u8), idx: @Vector(16, u8)) @Vector(16, u8) {
    return asm (
        \\ tbl %[ret].16b, { %[t0].16b, %[t1].16b }, %[idx].16b
        : [ret] "=w" (-> @Vector(16, u8)),
        : [idx] "w" (idx),
          [t0] "w" (t[0]),
          [t1] "w" (t[1]),
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

pub inline fn vshrq_n_u32(a: @Vector(4, u32), n: u8) @Vector(4, u32) {
    assert(n <= 32);
    return asm (
        \\ ushr %[ret].4s, %[a].4s, %[n]
        : [ret] "=w" (-> @Vector(4, u32)),
        : [a] "w" (a),
          [n] "I" (n),
    );
}

pub inline fn vsraq_n_u8(a: @Vector(16, u8), b: @Vector(16, u8), n: u8) @Vector(16, u8) {
    assert(n <= 8);
    return asm (
        \\ mov %[ret].16b, %[a].16b
        \\ usra %[ret].16b, %[b].16b, %[n]
        : [ret] "=&w" (-> @Vector(16, u8)),
        : [a] "w" (a),
          [b] "w" (b),
          [n] "I" (n),
    );
}

pub inline fn vsraq_n_u16(a: @Vector(8, u16), b: @Vector(8, u16), n: u4) @Vector(8, u16) {
    assert(n <= 16);

    // note: usra modifies the first operand, but I can't figure out how to
    // specify that without the mov safely.
    return asm (
        \\ mov %[ret].8h, %[a].8h
        \\ usra %[ret].8h, %[b].8h, %[n]
        : [ret] "=&w" (-> @Vector(8, u16)),
        : [a] "w" (a),
          [b] "w" (b),
          [n] "I" (n),
    );
}

pub inline fn vsraq_n_u32(a: @Vector(4, u32), b: @Vector(4, u32), n: u8) @Vector(4, u32) {
    assert(n <= 32);
    return asm (
        \\ mov %[ret].4s, %[a].4s
        \\ usra %[ret].4s, %[b].4s, %[n]
        : [ret] "=&w" (-> @Vector(4, u32)),
        : [a] "w" (a),
          [b] "w" (b),
          [n] "I" (n),
    );
}

pub inline fn vst1q_u8(out: [*]u8, a: @Vector(16, u8)) void {
    asm volatile (
        \\ st1 { %[a].16b }, [%[out]]
        :
        : [out] "r" (out),
          [a] "w" (a),
    );
}

pub inline fn vst1q_u32(out: [*]u32, a: @Vector(4, u32)) void {
    asm volatile (
        \\ st1 { %[a].4s }, [%[out]]
        :
        : [out] "r" (out),
          [a] "w" (a),
    );
}

pub inline fn vst2q_u16(out: [*]u16, vs: [2]@Vector(8, u16)) void {
    asm volatile (
        \\ st2 { %[v1].8h - %[v2].8h }, [%[out]]
        :
        : [out] "r" (out),
          [v1] "w" (vs[0]),
          [v2] "w" (vs[1]),
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
