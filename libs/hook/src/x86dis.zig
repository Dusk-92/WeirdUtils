//! Minimal x86 (32-bit) length disassembler.
//!
//! Faithful port of Vyacheslav Patkov's Hacker Disassembler Engine 32 (HDE32),
//! used by MinHook. Only computes instruction length + flags needed for
//! relocation (F_RELATIVE). ~470 bytes of table data, compiles to ~1-2 KB.

const std = @import("std");

// ── public flags ───────────────────────────────────────────────────────
pub const F_MODRM: u32 = 0x00000001;
pub const F_SIB: u32 = 0x00000002;
pub const F_IMM8: u32 = 0x00000004;
pub const F_IMM16: u32 = 0x00000008;
pub const F_IMM32: u32 = 0x00000010;
pub const F_DISP8: u32 = 0x00000020;
pub const F_DISP16: u32 = 0x00000040;
pub const F_DISP32: u32 = 0x00000080;
pub const F_RELATIVE: u32 = 0x00000100;
pub const F_ERROR: u32 = 0x00001000;

// ── internal cflags ────────────────────────────────────────────────────
const C_MODRM: u8 = 0x01;
const C_IMM8: u8 = 0x02;
const C_IMM16: u8 = 0x04;
const C_IMM_P66: u8 = 0x10;
const C_REL8: u8 = 0x20;
const C_REL32: u8 = 0x40;
const C_GROUP: u8 = 0x80;
const C_ERROR: u8 = 0xff;

const PRE_NONE: u8 = 0x01;
const PRE_66: u8 = 0x08;
const PRE_67: u8 = 0x10;

const DELTA_OPCODES: usize = 0x4a;

// HDE32 opcode table — verbatim from table32.h
const hde32_table = [_]u8{
    0xa3, 0xa8, 0xa3, 0xa8, 0xa3, 0xa8, 0xa3, 0xa8, 0xa3, 0xa8, 0xa3, 0xa8, 0xa3, 0xa8, 0xa3,
    0xa8, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xac, 0xaa, 0xb2, 0xaa, 0x9f, 0x9f,
    0x9f, 0x9f, 0xb5, 0xa3, 0xa3, 0xa4, 0xaa, 0xaa, 0xba, 0xaa, 0x96, 0xaa, 0xa8, 0xaa, 0xc3,
    0xc3, 0x96, 0x96, 0xb7, 0xae, 0xd6, 0xbd, 0xa3, 0xc5, 0xa3, 0xa3, 0x9f, 0xc3, 0x9c, 0xaa,
    0xaa, 0xac, 0xaa, 0xbf, 0x03, 0x7f, 0x11, 0x7f, 0x01, 0x7f, 0x01, 0x3f, 0x01, 0x01, 0x90,
    0x82, 0x7d, 0x97, 0x59, 0x59, 0x59, 0x59, 0x59, 0x7f, 0x59, 0x59, 0x60, 0x7d, 0x7f, 0x7f,
    0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x9a, 0x88, 0x7d,
    0x59, 0x50, 0x50, 0x50, 0x50, 0x59, 0x59, 0x59, 0x59, 0x61, 0x94, 0x61, 0x9e, 0x59, 0x59,
    0x85, 0x59, 0x92, 0xa3, 0x60, 0x60, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59,
    0x59, 0x59, 0x9f, 0x01, 0x03, 0x01, 0x04, 0x03, 0xd5, 0x03, 0xcc, 0x01, 0xbc, 0x03, 0xf0,
    0x10, 0x10, 0x10, 0x10, 0x50, 0x50, 0x50, 0x50, 0x14, 0x20, 0x20, 0x20, 0x20, 0x01, 0x01,
    0x01, 0x01, 0xc4, 0x02, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xc0, 0xc2, 0x10, 0x11,
    0x02, 0x03, 0x11, 0x03, 0x03, 0x04, 0x00, 0x00, 0x14, 0x00, 0x02, 0x00, 0x00, 0xc6, 0xc8,
    0x02, 0x02, 0x02, 0x02, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0xca,
    0x01, 0x01, 0x01, 0x00, 0x06, 0x00, 0x04, 0x00, 0xc0, 0xc2, 0x01, 0x01, 0x03, 0x01, 0xff,
    0xff, 0x01, 0x00, 0x03, 0xc4, 0xc4, 0xc6, 0x03, 0x01, 0x01, 0x01, 0xff, 0x03, 0x03, 0x03,
    0xc8, 0x40, 0x00, 0x0a, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x7f, 0x00, 0x33, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xbf, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0xbf, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x7f, 0x00, 0x00, 0xff, 0x4a, 0x4a, 0x4a, 0x4a, 0x4b, 0x52, 0x4a, 0x4a, 0x4a, 0x4a, 0x4f,
    0x4c, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x55, 0x45, 0x40, 0x4a, 0x4a, 0x4a,
    0x45, 0x59, 0x4d, 0x46, 0x4a, 0x5d, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a,
    0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x61, 0x63, 0x67, 0x4e, 0x4a, 0x4a, 0x6b, 0x6d, 0x4a, 0x4a,
    0x45, 0x6d, 0x4a, 0x4a, 0x44, 0x45, 0x4a, 0x4a, 0x00, 0x00, 0x00, 0x02, 0x0d, 0x06, 0x06,
    0x06, 0x06, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x06, 0x06, 0x06, 0x00, 0x06, 0x06, 0x02, 0x06,
    0x00, 0x0a, 0x0a, 0x07, 0x07, 0x06, 0x02, 0x05, 0x05, 0x02, 0x02, 0x00, 0x00, 0x04, 0x04,
    0x04, 0x04, 0x00, 0x00, 0x00, 0x0e, 0x05, 0x06, 0x06, 0x06, 0x01, 0x06, 0x00, 0x00, 0x08,
    0x00, 0x10, 0x00, 0x18, 0x00, 0x20, 0x00, 0x28, 0x00, 0x30, 0x00, 0x80, 0x01, 0x82, 0x01,
    0x86, 0x00, 0xf6, 0xcf, 0xfe, 0x3f, 0xab, 0x00, 0xb0, 0x00, 0xb1, 0x00, 0xb3, 0x00, 0xba,
    0xf8, 0xbb, 0x00, 0xc0, 0x00, 0xc1, 0x00, 0xc7, 0xbf, 0x62, 0xff, 0x00, 0x8d, 0xff, 0x00,
    0xc4, 0xff, 0x00, 0xc5, 0xff, 0x00,
};

pub const Insn = struct {
    len: u8,
    flags: u32,
    opcode: u8,
    opcode2: u8,
};

/// Decode the instruction at `code`, returning its length and flags.
pub fn decode(code: [*]const u8) Insn {
    var result = Insn{ .len = 0, .flags = 0, .opcode = 0, .opcode2 = 0 };

    var p: usize = 0;
    var pref: u8 = 0;
    var disp_size: u8 = 0;

    // ── prefixes ──
    var prefix_count: u8 = 16;
    prefix_loop: while (prefix_count > 0) : (prefix_count -= 1) {
        switch (code[p]) {
            0xf3, 0xf2 => pref |= if (code[p] == 0xf3) 0x04 else 0x02,
            0xf0 => pref |= 0x20, // PRE_LOCK
            0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65 => pref |= 0x40, // PRE_SEG
            0x66 => pref |= PRE_66,
            0x67 => pref |= PRE_67,
            else => break :prefix_loop,
        }
        p += 1;
    }

    result.flags = @as(u32, pref) << 23;

    if (pref == 0) pref |= PRE_NONE;

    // ── opcode ──
    var ht_base: usize = 0;
    var c = code[p];
    p += 1;
    result.opcode = c;

    if (c == 0x0f) {
        // two-byte opcode
        result.opcode2 = code[p];
        c = code[p];
        p += 1;
        ht_base = DELTA_OPCODES;
    } else if (c >= 0xa0 and c <= 0xa3) {
        // MOV moffs — address-size prefix swaps operand-size behavior
        if (pref & PRE_67 != 0)
            pref |= PRE_66
        else
            pref &= ~PRE_66;
    }

    const opcode = c;

    // ── two-level table lookup: ht[ht[opcode/4] + (opcode%4)] ──
    var cflags: u8 = blk: {
        const idx1 = ht_base + @as(usize, opcode / 4);
        if (idx1 >= hde32_table.len) break :blk C_ERROR;
        const idx2 = ht_base + @as(usize, hde32_table[idx1]) + @as(usize, opcode % 4);
        if (idx2 >= hde32_table.len) break :blk C_ERROR;
        break :blk hde32_table[idx2];
    };

    if (cflags == C_ERROR) {
        result.flags |= F_ERROR;
        cflags = 0;
        if ((opcode & 0xfd) == 0x24) // (opcode & -3) == 0x24
            cflags +%= 1;
    }

    // ── group resolution ──
    var x: u8 = 0;
    if (cflags & C_GROUP != 0) {
        const group_idx = ht_base + @as(usize, cflags & 0x7f);
        if (group_idx + 1 < hde32_table.len) {
            const t = std.mem.readInt(u16, hde32_table[group_idx..][0..2], .little);
            cflags = @truncate(t);
            x = @truncate(t >> 8);
        }
    }

    // ── modrm ──
    if (cflags & C_MODRM != 0) {
        result.flags |= F_MODRM;
        const modrm = code[p];
        p += 1;
        const m_mod = modrm >> 6;
        const m_rm: u8 = modrm & 7;
        const m_reg: u3 = @truncate((modrm & 0x3f) >> 3);

        // F6 TEST imm8 / F7 TEST imm16/32
        if (m_reg <= 1) {
            if (opcode == 0xf6)
                cflags |= C_IMM8;
            if (opcode == 0xf7)
                cflags |= C_IMM_P66;
        }

        // displacement
        switch (m_mod) {
            0 => {
                if (pref & PRE_67 != 0) {
                    if (m_rm == 6) disp_size = 2;
                } else {
                    if (m_rm == 5) disp_size = 4;
                }
            },
            1 => disp_size = 1,
            2 => {
                disp_size = 2;
                if (pref & PRE_67 == 0)
                    disp_size = 4;
            },
            else => {},
        }

        // SIB byte
        if (m_mod != 3 and m_rm == 4 and (pref & PRE_67 == 0)) {
            result.flags |= F_SIB;
            const sib = code[p];
            p += 1;
            if ((sib & 7) == 5 and (m_mod & 1) == 0)
                disp_size = 4;
        }

        // displacement bytes
        switch (disp_size) {
            1 => {
                result.flags |= F_DISP8;
                p += 1;
            },
            2 => {
                result.flags |= F_DISP16;
                p += 2;
            },
            4 => {
                result.flags |= F_DISP32;
                p += 4;
            },
            else => {},
        }
    }

    // ── immediates ──
    if (cflags & C_IMM_P66 != 0) {
        if (cflags & C_REL32 != 0) {
            if (pref & PRE_66 != 0) {
                result.flags |= F_IMM16 | F_RELATIVE;
                p += 2;
                // disasm_done — skip remaining immediate checks
                result.len = @intCast(p);
                if (result.len > 15) {
                    result.flags |= F_ERROR;
                    result.len = 15;
                }
                return result;
            }
            // fall through to rel32_ok below
        } else {
            if (pref & PRE_66 != 0) {
                result.flags |= F_IMM16;
                p += 2;
            } else {
                result.flags |= F_IMM32;
                p += 4;
            }
        }
    }

    if (cflags & C_IMM16 != 0) {
        if (result.flags & F_IMM32 != 0) {
            result.flags |= F_IMM16;
        } else if (result.flags & F_IMM16 != 0) {
            // F_2IMM16
        } else {
            result.flags |= F_IMM16;
        }
        p += 2;
    }
    if (cflags & C_IMM8 != 0) {
        result.flags |= F_IMM8;
        p += 1;
    }

    if (cflags & C_REL32 != 0) {
        result.flags |= F_IMM32 | F_RELATIVE;
        p += 4;
    } else if (cflags & C_REL8 != 0) {
        result.flags |= F_IMM8 | F_RELATIVE;
        p += 1;
    }

    result.len = @intCast(p);
    if (result.len > 15) {
        result.flags |= F_ERROR;
        result.len = 15;
    }
    return result;
}

// ── tests ──────────────────────────────────────────────────────────────

test "push ebp" {
    const d = decode(&[_]u8{ 0x55, 0xCC });
    try std.testing.expectEqual(@as(u8, 1), d.len);
}

test "mov ebp, esp" {
    // 8B EC (or 89 E5)
    const d = decode(&[_]u8{ 0x8B, 0xEC });
    try std.testing.expectEqual(@as(u8, 2), d.len);
    try std.testing.expect(d.flags & F_MODRM != 0);
}

test "call rel32" {
    const d = decode(&[_]u8{ 0xE8, 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u8, 5), d.len);
    try std.testing.expect(d.flags & F_RELATIVE != 0);
    try std.testing.expect(d.flags & F_IMM32 != 0);
}

test "jmp rel32" {
    const d = decode(&[_]u8{ 0xE9, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u8, 5), d.len);
    try std.testing.expect(d.flags & F_RELATIVE != 0);
}

test "sub esp, imm8" {
    // 83 EC 10
    const d = decode(&[_]u8{ 0x83, 0xEC, 0x10 });
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expect(d.flags & F_MODRM != 0);
    try std.testing.expect(d.flags & F_IMM8 != 0);
}

test "mov eax, [ebp+8]" {
    // 8B 45 08
    const d = decode(&[_]u8{ 0x8B, 0x45, 0x08 });
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expect(d.flags & F_MODRM != 0);
    try std.testing.expect(d.flags & F_DISP8 != 0);
}

test "jz rel32 (0F 84)" {
    const d = decode(&[_]u8{ 0x0F, 0x84, 0x10, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u8, 6), d.len);
    try std.testing.expect(d.flags & F_RELATIVE != 0);
}

test "nop" {
    const d = decode(&[_]u8{0x90});
    try std.testing.expectEqual(@as(u8, 1), d.len);
}

test "ret" {
    const d = decode(&[_]u8{0xC3});
    try std.testing.expectEqual(@as(u8, 1), d.len);
}

test "short jmp EB" {
    const d = decode(&[_]u8{ 0xEB, 0x05 });
    try std.testing.expectEqual(@as(u8, 2), d.len);
    try std.testing.expect(d.flags & F_RELATIVE != 0);
    try std.testing.expect(d.flags & F_IMM8 != 0);
}

test "short jcc 74 (jz rel8)" {
    const d = decode(&[_]u8{ 0x74, 0x0A });
    try std.testing.expectEqual(@as(u8, 2), d.len);
    try std.testing.expect(d.flags & F_RELATIVE != 0);
}

test "mov eax, imm32" {
    const d = decode(&[_]u8{ 0xB8, 0x44, 0x33, 0x22, 0x11 });
    try std.testing.expectEqual(@as(u8, 5), d.len);
}

test "push imm32" {
    const d = decode(&[_]u8{ 0x68, 0x44, 0x33, 0x22, 0x11 });
    try std.testing.expectEqual(@as(u8, 5), d.len);
}

test "push imm8" {
    // 6A 01
    const d = decode(&[_]u8{ 0x6A, 0x01 });
    try std.testing.expectEqual(@as(u8, 2), d.len);
}

test "mov [ebp-4], eax" {
    // 89 45 FC
    const d = decode(&[_]u8{ 0x89, 0x45, 0xFC });
    try std.testing.expectEqual(@as(u8, 3), d.len);
    try std.testing.expect(d.flags & F_MODRM != 0);
    try std.testing.expect(d.flags & F_DISP8 != 0);
}

test "lea eax, [ecx+edx*4+8]" {
    // 8D 44 91 08
    const d = decode(&[_]u8{ 0x8D, 0x44, 0x91, 0x08 });
    try std.testing.expectEqual(@as(u8, 4), d.len);
    try std.testing.expect(d.flags & F_MODRM != 0);
    try std.testing.expect(d.flags & F_SIB != 0);
    try std.testing.expect(d.flags & F_DISP8 != 0);
}

test "mov [disp32], eax" {
    // A3 xx xx xx xx
    const d = decode(&[_]u8{ 0xA3, 0x00, 0x10, 0x40, 0x00 });
    try std.testing.expectEqual(@as(u8, 5), d.len);
}

test "sub esp, imm32" {
    // 81 EC 00 01 00 00
    const d = decode(&[_]u8{ 0x81, 0xEC, 0x00, 0x01, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u8, 6), d.len);
    try std.testing.expect(d.flags & F_MODRM != 0);
}

test "test eax, imm32 (F7 C0)" {
    // F7 C0 FF 00 00 00 = test eax, 0xFF
    const d = decode(&[_]u8{ 0xF7, 0xC0, 0xFF, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u8, 6), d.len);
}

test "ret imm16" {
    // C2 04 00
    const d = decode(&[_]u8{ 0xC2, 0x04, 0x00 });
    try std.testing.expectEqual(@as(u8, 3), d.len);
}
