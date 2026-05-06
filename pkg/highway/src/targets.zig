const assert = @import("std").debug.assert;

pub const Targets = packed struct(i64) {
    // x86_64
    _reserved_0_2: u3 = 0,
    avx10_2_512: bool = false,
    avx3_spr: bool = false,
    avx10_2: bool = false,
    avx3_zen4: bool = false,
    avx3_dl: bool = false,
    avx3: bool = false,
    avx2: bool = false,
    _reserved_10: u1 = 0,
    sse4: bool = false,
    ssse3: bool = false,
    _reserved_13: u1 = 0,
    sse2: bool = false,
    _reserved_15_17: u3 = 0,

    // aarch64
    sve2_128: bool = false,
    sve_256: bool = false,
    _reserved_20_22: u3 = 0,
    sve2: bool = false,
    sve: bool = false,
    _reserved_25: u1 = 0,
    neon_bf16: bool = false,
    _reserved_27: u1 = 0,
    neon: bool = false,
    neon_without_aes: bool = false,
    _reserved_30_36: u7 = 0,

    // risc-v
    rvv: bool = false,
    _reserved_38_39: u2 = 0,

    // LoongArch
    lasx: bool = false,
    lsx: bool = false,
    _reserved_42_46: u5 = 0,

    // IBM Power
    ppc10: bool = false,
    ppc9: bool = false,
    ppc8: bool = false,
    z15: bool = false,
    z14: bool = false,
    _reserved_52_57: u6 = 0,

    // WebAssembly
    wasm_emu256: bool = false,
    wasm: bool = false,
    _reserved_60: u1 = 0,

    // Emulation
    emu128: bool = false,
    scalar: bool = false,
    _reserved_63: u1 = 0,

    fn bitPos(comptime field_name: []const u8) comptime_int {
        return @bitOffsetOf(Targets, field_name);
    }

    // Verify at comptime that each flag field matches its Highway bit constant.
    comptime {
        // x86
        assert(bitPos("avx10_2_512") == 3);
        assert(bitPos("avx3_spr") == 4);
        assert(bitPos("avx10_2") == 5);
        assert(bitPos("avx3_zen4") == 6);
        assert(bitPos("avx3_dl") == 7);
        assert(bitPos("avx3") == 8);
        assert(bitPos("avx2") == 9);
        assert(bitPos("sse4") == 11);
        assert(bitPos("ssse3") == 12);
        assert(bitPos("sse2") == 14);

        // aarch64
        assert(bitPos("sve2_128") == 18);
        assert(bitPos("sve_256") == 19);
        assert(bitPos("sve2") == 23);
        assert(bitPos("sve") == 24);
        assert(bitPos("neon_bf16") == 26);
        assert(bitPos("neon") == 28);
        assert(bitPos("neon_without_aes") == 29);

        // risc-v
        assert(bitPos("rvv") == 37);

        // LoongArch
        assert(bitPos("lasx") == 40);
        assert(bitPos("lsx") == 41);

        // IBM Power
        assert(bitPos("ppc10") == 47);
        assert(bitPos("ppc9") == 48);
        assert(bitPos("ppc8") == 49);
        assert(bitPos("z15") == 50);
        assert(bitPos("z14") == 51);

        // WebAssembly
        assert(bitPos("wasm_emu256") == 58);
        assert(bitPos("wasm") == 59);

        // Emulation
        assert(bitPos("emu128") == 61);
        assert(bitPos("scalar") == 62);
    }
};
