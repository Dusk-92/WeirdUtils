//! SuperWoW Heal Text Fix
//!
//! Patches SuperWoWhook.dll at runtime to disable the duplicate floating
//! healing combat text that SuperWoW 1.5.1 adds.
//!
//! Based on:
//!   - https://github.com/MarcelineVQ/SuperWoWHealTextFix
//!   - https://github.com/turtlenips/superwow-patch
//!
//! The turtlenips version adds two extra patches (at file offsets 0x306E and
//! 0x3123) that fix HoT ticks (e.g. Renew) showing in the wrong color by
//! redirecting function pointers.
//!
//! The reference repos patch the DLL on disk before loading, which prevents
//! the hook registration call from executing. Since we patch at runtime (after
//! SuperWoW has already initialized and installed its hooks), we must instead
//! patch the handler function itself to skip its duplicate text creation.
//!
//! Patches applied to SuperWoWhook.dll in memory:
//!
//!   1. 0x3006 (2 bytes) - Skip duplicate heal text in handler
//!      The handler at RVA 0x3BF0 creates floating text, then calls through
//!      to the original wow.exe function (which also creates text = duplicate).
//!      Patch MOV ECX,[EDI] -> JMP +0x7A to skip to the call-through at 0x3C82.
//!      Old: 8B 0F
//!      New: EB 7A
//!
//!   2. 0x306E (4 bytes) - Redirect HoT text handler pointer
//!      Old: 9C D8 C4 00
//!      New: 06 7C 44 00
//!
//!   3. 0x3123 (4 bytes) - Redirect HoT text handler pointer (second site)
//!      Old: 9C D8 C4 00
//!      New: 06 7C 44 00
//!
//! NOTE: These are file offsets, converted to virtual addresses via PE section
//! headers at runtime.

const std = @import("std");
const hook = @import("zhook");
const con = @import("../console.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(WINAPI) ?*anyopaque;

const Patch = struct {
    /// File offset into SuperWoWhook.dll
    file_offset: u32,
    old: []const u8,
    new: []const u8,
    /// Optional mask for old-byte verification. 0xFF = must match, 0x00 = skip
    /// (relocated operands). null = check all bytes exactly.
    mask: ?[]const u8 = null,
};

const PatchSet = struct {
    version: []const u8,
    patches: []const Patch,
};

const v1_5_patches = [_]Patch{
    // Patch 0: Skip duplicate heal text in the SuperWoW handler
    // The handler at RVA 0x3BF0 creates floating text then calls the original
    // (which also creates text). JMP from 0x3C06 to the call-through at 0x3C82.
    .{
        .file_offset = 0x3006,
        .old = &.{ 0x8B, 0x0F },
        .new = &.{ 0xEB, 0x7A },
    },
    // Patch 1: Redirect HoT text handler pointer (fixes Renew etc. color)
    .{
        .file_offset = 0x306E,
        .old = &.{ 0x9C, 0xD8, 0xC4, 0x00 },
        .new = &.{ 0x06, 0x7C, 0x44, 0x00 },
    },
    // Patch 2: Redirect HoT text handler pointer (second call site)
    .{
        .file_offset = 0x3123,
        .old = &.{ 0x9C, 0xD8, 0xC4, 0x00 },
        .new = &.{ 0x06, 0x7C, 0x44, 0x00 },
    },
};

const patch_sets = [_]PatchSet{
    .{ .version = "1.5", .patches = &v1_5_patches },
};

fn printHex(prefix: []const u8, bytes: []const u8) void {
    con.print(prefix);
    for (bytes) |b| {
        con.fmt("{x:0>2} ", .{b});
    }
    con.print("\n");
}

/// Convert a file offset to a virtual address by walking PE section headers.
fn fileOffsetToVA(base: [*]const u8, file_offset: u32) ?[*]u8 {
    // DOS header: e_lfanew at offset 0x3C
    const e_lfanew = std.mem.readInt(u32, base[0x3C..0x40], .little);
    const pe_base = base + e_lfanew;

    // PE signature (4) + COFF header (20) = optional header at +24
    // Number of sections at PE+6
    const num_sections = std.mem.readInt(u16, pe_base[6..8], .little);
    // Size of optional header at PE+20
    const opt_hdr_size = std.mem.readInt(u16, pe_base[20..22], .little);

    // Section headers start after optional header
    const sections_start = pe_base + 24 + opt_hdr_size;

    var i: u16 = 0;
    while (i < num_sections) : (i += 1) {
        const sec = sections_start + @as(usize, i) * 40;
        const virt_size = std.mem.readInt(u32, sec[8..12], .little);
        const virt_addr = std.mem.readInt(u32, sec[12..16], .little);
        const raw_offset = std.mem.readInt(u32, sec[20..24], .little);
        const raw_size = std.mem.readInt(u32, sec[16..20], .little);

        _ = virt_size;
        if (file_offset >= raw_offset and file_offset < raw_offset + raw_size) {
            const rva = virt_addr + (file_offset - raw_offset);
            return @ptrFromInt(@intFromPtr(base) + rva);
        }
    }
    return null;
}

const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "healtextfix";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var g_applied_set: ?*const PatchSet = null;

pub fn isActive() bool {
    return g_is_hook_owner;
}

/// Scan the DLL's mapped memory for SUPERWOW_VERSION="..." and extract the version string.
fn detectVersion(base: [*]const u8) ?[]const u8 {
    const scan_len = 0x20000;
    const needle = "SUPERWOW_VERSION=\"";
    const mem = base[0..scan_len];

    const pos = std.mem.indexOf(u8, mem, needle) orelse return null;
    const ver_start = pos + needle.len;
    // Find closing quote
    const remaining = mem[ver_start..];
    const end = std.mem.indexOfScalar(u8, remaining, '"') orelse return null;
    return remaining[0..end];
}

pub fn installHooks() void {
    con.print("[healtextfix] Module loaded\n");

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
}

/// Called from engineInitDetour (GameEngine_MainInitialize hook) - late enough
/// that SuperWoWhook.dll should be loaded if present.
pub fn lateInit() void {
    if (!g_is_hook_owner) return;
    const superwow_base = GetModuleHandleA("SuperWoWhook.dll");
    if (superwow_base == null) {
        con.print("[healtextfix] SuperWoWhook.dll not found, skipping\n");
        return;
    }

    const base: [*]const u8 = @ptrCast(superwow_base.?);
    con.fmt("[healtextfix] SuperWoWhook.dll at 0x{x}\n", .{@intFromPtr(base)});

    // Detect SuperWoW version
    const version = detectVersion(base) orelse {
        con.print("[healtextfix] Could not detect SuperWoW version, skipping\n");
        return;
    };
    con.fmt("[healtextfix] Detected SuperWoW version: {s}\n", .{version});

    // Find matching patch set
    const set: *const PatchSet = blk: {
        for (&patch_sets) |*ps| {
            if (std.mem.eql(u8, ps.version, version)) break :blk ps;
        }
        con.fmt("[healtextfix] No patches for version \"{s}\", skipping\n", .{version});
        return;
    };

    var applied: u32 = 0;
    for (set.patches, 0..) |patch, idx| {
        const va = fileOffsetToVA(base, patch.file_offset) orelse {
            con.fmt("[healtextfix] Patch {d}: failed to resolve file offset 0x{x}\n", .{ idx, patch.file_offset });
            continue;
        };

        // Verify old bytes match (mask skips relocated operands)
        const target: [*]u8 = va;
        var matches = true;
        for (0..patch.old.len) |j| {
            const m: u8 = if (patch.mask) |mask| mask[j] else 0xFF;
            if (target[j] & m != patch.old[j] & m) {
                matches = false;
                break;
            }
        }

        if (!matches) {
            // Check if already patched
            var already = true;
            for (0..patch.new.len) |j| {
                const m: u8 = if (patch.mask) |mask| mask[j] else 0xFF;
                if (target[j] & m != patch.new[j] & m) {
                    already = false;
                    break;
                }
            }
            if (already) {
                con.fmt("[healtextfix] Patch {d}: already applied\n", .{idx});
                applied += 1;
            } else {
                con.fmt("[healtextfix] Patch {d}: unexpected bytes at VA 0x{x}\n", .{ idx, @intFromPtr(target) });
                printHex("[healtextfix]   expected: ", patch.old);
                printHex("[healtextfix]   found:    ", target[0..patch.old.len]);
            }
            continue;
        }

        // Apply patch
        hook.writeProtected(@intFromPtr(target), patch.new);
        applied += 1;
        con.fmt("[healtextfix] Patch {d}: applied at VA 0x{x}\n", .{ idx, @intFromPtr(target) });
    }

    if (applied > 0) g_applied_set = set;
    con.fmt("[healtextfix] {d}/{d} patches applied\n", .{ applied, set.patches.len });
}

pub fn removeHooks() void {
    if (!g_is_hook_owner) return;

    const set = g_applied_set orelse {
        mod_mutex.release(&g_mutex);
        g_is_hook_owner = false;
        return;
    };

    const superwow_base = GetModuleHandleA("SuperWoWhook.dll");
    if (superwow_base == null) return;

    const base: [*]const u8 = @ptrCast(superwow_base.?);

    for (set.patches, 0..) |patch, idx| {
        const va = fileOffsetToVA(base, patch.file_offset) orelse continue;
        const target: [*]u8 = va;

        // Only restore if currently patched
        var is_patched = true;
        for (0..patch.new.len) |j| {
            const m: u8 = if (patch.mask) |mask| mask[j] else 0xFF;
            if (target[j] & m != patch.new[j] & m) {
                is_patched = false;
                break;
            }
        }

        if (is_patched) {
            hook.writeProtected(@intFromPtr(target), patch.old);
            con.fmt("[healtextfix] Patch {d}: restored\n", .{idx});
        }
    }

    g_applied_set = null;
    mod_mutex.release(&g_mutex);
    g_is_hook_owner = false;
    con.print("[healtextfix] All patches restored\n");
}
