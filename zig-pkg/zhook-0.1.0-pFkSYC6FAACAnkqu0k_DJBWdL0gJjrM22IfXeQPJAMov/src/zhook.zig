//! x86-32 inline hooking library for Windows DLL injection.
//!
//! Provides auto-sizing detours with instruction relocation, type-safe
//! `Detour(FnType)` wrappers, memory read/write helpers, rel32 arithmetic,
//! a generic `fastcall` caller, and Windows virtual memory API re-exports.
//!
//! ## Type-safe API (Detour) — recommended
//!
//! ```zig
//! const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
//! const CheckFile = fn (u32, u32, u32) callconv(fc) u32;
//! var hook: Detour(CheckFile) = .{};
//! hook.attach(0x654DD0, &myDetour);
//! // Inside detour: hook.callOriginal(.{ filename, flags, output });
//! hook.detach();
//! ```
//!
//! ## Low-level API (GenericHook)
//!
//! ```zig
//! var my_hook: GenericHook = .{};
//! if (my_hook.install(0x401000, @intFromPtr(&myDetour)) == .ok) {
//!     const orig = my_hook.getTrampoline(OrigFnType);
//!     _ = orig();
//! }
//! my_hook.remove();
//! ```

const std = @import("std");
const x86dis = @import("x86dis");

// =============================================================================
// Windows API
// =============================================================================

const WINAPI = std.builtin.CallingConvention.winapi;

/// Memory protection constant: page is readable, writable, and executable.
pub const PAGE_EXECUTE_READWRITE: u32 = 0x40;
/// Memory allocation type: commit physical storage for the region.
pub const MEM_COMMIT: u32 = 0x1000;
/// Memory free type: release the region (decommit + free address space).
pub const MEM_RELEASE: u32 = 0x8000;

extern "kernel32" fn VirtualProtect(
    lpAddress: *anyopaque,
    dwSize: usize,
    flNewProtect: u32,
    lpflOldProtect: *u32,
) callconv(WINAPI) i32;

/// Allocate or reserve virtual memory. Used to create RWX trampoline pages.
pub extern "kernel32" fn VirtualAlloc(
    lpAddress: ?*anyopaque,
    dwSize: usize,
    flAllocationType: u32,
    flProtect: u32,
) callconv(WINAPI) ?[*]u8;

/// Release virtual memory previously allocated with `VirtualAlloc`.
pub extern "kernel32" fn VirtualFree(
    lpAddress: *anyopaque,
    dwSize: usize,
    dwFreeType: u32,
) callconv(WINAPI) i32;

// =============================================================================
// Memory helpers
// =============================================================================

/// Read a value of type `T` from an arbitrary memory address (unaligned).
pub fn readMem(comptime T: type, addr: usize) T {
    return @as(*align(1) const T, @ptrFromInt(addr)).*;
}

/// Write raw bytes to an arbitrary memory address. No protection change —
/// caller must ensure the page is writable (or use `writeProtected`).
pub fn writeMem(addr: usize, bytes: []const u8) void {
    const dest: [*]u8 = @ptrFromInt(addr);
    for (bytes, 0..) |b, i| {
        dest[i] = b;
    }
}

/// Write bytes to a potentially read-only/executable page. Temporarily sets
/// PAGE_EXECUTE_READWRITE, writes, then restores the original protection.
pub fn writeProtected(addr: usize, bytes: []const u8) void {
    var old: u32 = 0;
    _ = VirtualProtect(@ptrFromInt(addr), bytes.len, PAGE_EXECUTE_READWRITE, &old);
    writeMem(addr, bytes);
    _ = VirtualProtect(@ptrFromInt(addr), bytes.len, old, &old);
}

// =============================================================================
// Rel32 helpers
// =============================================================================

/// Resolve the absolute target of an E8 (CALL) or E9 (JMP) at `addr`.
/// Reads the signed rel32 operand at addr+1 and computes addr+5+offset.
pub fn rel32Target(addr: usize) usize {
    const offset: u32 = @bitCast(@as(*align(1) const i32, @ptrFromInt(addr + 1)).*);
    return (addr + 5) +% offset;
}

/// Write a rel32 displacement into dest[0..4] such that a JMP/CALL
/// from address `from` reaches `to`. Displacement = to - (from + 4).
pub fn writeRel32(dest: [*]u8, from: usize, to: usize) void {
    std.mem.writeInt(u32, dest[0..4], to -% (from + 4), .little);
}

// =============================================================================
// Calling convention aliases and call helper
// =============================================================================

/// x86-32 calling convention shorthands for use with `callconv()`.
///
/// Once Zig supports `@Type` for function types, these can be used to build
/// convention-specific wrappers (stdcall/thiscall/fastcall/cdecl) that inject
/// the callconv automatically, removing the need for `callconv(hook.cc.*)`.
///
/// ```zig
/// const result = hook.call(fn (u32, u32) callconv(hook.cc.thiscall) i32, 0x6061E0, .{ player, unit });
/// ```
pub const cc = struct {
    pub const stdcall: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };
    pub const thiscall: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };
    pub const fastcall: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
    pub const cdecl: std.builtin.CallingConvention = .c;
};

/// Call a function at `addr` using a typed function pointer cast.
///
/// The function type `F` must include an explicit `callconv`. Supports all
/// x86-32 conventions (stdcall, thiscall, fastcall, cdecl). Uses `.never_tail`
/// to prevent tail-call optimization that would corrupt callee-cleanup stacks.
///
/// ```zig
/// const result = hook.call(fn (u32, u32) callconv(hook.cc.stdcall) u32, 0x464870, .{ lo, hi });
/// ```
pub fn call(comptime F: type, addr: usize, args: anytype) FnReturnType(F) {
    const func: *const F = @ptrFromInt(addr);
    return @call(.never_tail, func, args);
}

fn FnReturnType(comptime F: type) type {
    return @typeInfo(F).@"fn".return_type orelse void;
}

// ═══════════════════════════════════════════════════════════════════════
// GenericHook — low-level auto-sizing hook
// ═══════════════════════════════════════════════════════════════════════

const JMP_SIZE: usize = 5; // E9 + rel32
const MAX_STOLEN: usize = 32;
const ALLOC_SIZE: usize = 64; // trampoline only

/// Auto-sizing inline hook that uses the x86 length disassembler to determine
/// how many prologue bytes to steal, then copies and relocates them into a
/// trampoline. Handles hook chaining (detects an existing E9 JMP at the target)
/// and expands short jumps to near jumps during relocation.
///
/// For type-safe hooking with automatic calling convention handling, use
/// `Detour(FnType)` instead — it wraps `GenericHook` and adds compile-time
/// type checking.
pub const GenericHook = struct {
    /// Base of the allocated RWX page, or null if not yet prepared.
    mem: ?[*]u8 = null,
    /// Address of the trampoline entry point (calls the original code).
    trampoline: usize = 0,
    /// Address of the hooked function's entry point.
    target: usize = 0,
    /// Number of bytes stolen from the target prologue (>= 5 for E9 JMP).
    stolen_size: usize = 0,
    /// Original prologue bytes, saved for restoration on `remove()`.
    saved_bytes: [MAX_STOLEN]u8 = undefined,

    /// Result of a hook operation.
    pub const Error = enum {
        /// Success.
        ok,
        /// `VirtualAlloc` failed to allocate executable memory.
        alloc_failed,
        /// The length disassembler returned `F_ERROR` or a zero-length instruction.
        disasm_error,
        /// Could not steal enough bytes for a 5-byte JMP before hitting `MAX_STOLEN`.
        prologue_too_short,
        /// Prologue contains a relative instruction that cannot be relocated
        /// (e.g. LOOP, JECXZ — only CALL/JMP/Jcc are supported).
        unsupported_relocation,
    };

    /// Convenience: `prepare` + `activate` in one call.
    pub fn install(self: *GenericHook, target: usize, detour_addr: usize) Error {
        const err = self.prepare(target);
        if (err != .ok) return err;
        self.activate(detour_addr);
        return .ok;
    }

    /// Phase 1: disassemble prologue, allocate trampoline, copy + relocate.
    ///
    /// Walks the target's prologue with `x86dis.decode` until at least 5 bytes
    /// are covered, allocates an RWX page, copies the stolen bytes into a
    /// trampoline, relocates any relative instructions (E8/E9/Jcc/short jumps),
    /// and appends a JMP back to the remainder of the original function.
    ///
    /// If the target already starts with an E9 JMP (another hook), chains
    /// through it: the trampoline jumps to the existing detour rather than
    /// copying the prologue.
    ///
    /// Does NOT patch the target — call `activate()` after to write the JMP.
    pub fn prepare(self: *GenericHook, target: usize) Error {
        if (self.mem != null) return .ok;

        const src: [*]const u8 = @ptrFromInt(target);

        // ── determine how many bytes to steal ──
        var stolen: usize = 0;
        while (stolen < JMP_SIZE) {
            const insn = x86dis.decode(src + stolen);
            if (insn.flags & x86dis.F_ERROR != 0) return .disasm_error;
            if (insn.len == 0) return .disasm_error;
            stolen += insn.len;
            if (stolen > MAX_STOLEN) return .prologue_too_short;
        }

        // ── allocate ──
        const mem = VirtualAlloc(null, ALLOC_SIZE, MEM_COMMIT, PAGE_EXECUTE_READWRITE) orelse return .alloc_failed;

        self.mem = mem;
        self.target = target;
        self.stolen_size = stolen;
        self.trampoline = @intFromPtr(mem);

        @memcpy(self.saved_bytes[0..stolen], src[0..stolen]);

        // ── check if already hooked (E9 at target) — chain through ──
        if (src[0] == 0xE9) {
            const other_detour = rel32Target(target);
            mem[0] = 0xE9;
            writeRel32(mem + 1, self.trampoline + 1, other_detour);
            return .ok;
        }

        // ── build trampoline: copy + relocate ──
        var t_pos: usize = 0;
        var s_pos: usize = 0;

        while (s_pos < stolen) {
            const insn = x86dis.decode(src + s_pos);
            const op = insn.opcode;
            const src_addr = target + s_pos;
            const dst_addr = self.trampoline + t_pos;

            if (insn.flags & x86dis.F_RELATIVE != 0) {
                if (op == 0xE8 or op == 0xE9) {
                    // CALL/JMP rel32
                    const abs = rel32Target(src_addr);
                    mem[t_pos] = op;
                    writeRel32(mem + t_pos + 1, dst_addr + 1, abs);
                    t_pos += 5;
                } else if (op == 0x0F and insn.opcode2 >= 0x80 and insn.opcode2 <= 0x8F) {
                    // Jcc rel32 (0F 80-8F)
                    const abs = jcc32Target(src_addr);
                    mem[t_pos] = 0x0F;
                    mem[t_pos + 1] = insn.opcode2;
                    writeRel32(mem + t_pos + 2, dst_addr + 2, abs);
                    t_pos += 6;
                } else if (op >= 0x70 and op <= 0x7F) {
                    // Short Jcc → expand to near Jcc (0F 8x)
                    const offset = @as(i8, @bitCast(src[s_pos + 1]));
                    const abs: usize = @bitCast(@as(isize, @intCast(src_addr + 2)) + offset);
                    mem[t_pos] = 0x0F;
                    mem[t_pos + 1] = op + 0x10;
                    writeRel32(mem + t_pos + 2, dst_addr + 2, abs);
                    t_pos += 6;
                } else if (op == 0xEB) {
                    // Short JMP → expand to near JMP (E9)
                    const offset = @as(i8, @bitCast(src[s_pos + 1]));
                    const abs: usize = @bitCast(@as(isize, @intCast(src_addr + 2)) + offset);
                    mem[t_pos] = 0xE9;
                    writeRel32(mem + t_pos + 1, dst_addr + 1, abs);
                    t_pos += 5;
                } else {
                    // LOOP/JECXZ or unknown — cannot trivially expand
                    self.cleanup();
                    return .unsupported_relocation;
                }
            } else {
                // Non-relative — copy verbatim
                @memcpy(mem[t_pos .. t_pos + insn.len], src[s_pos .. s_pos + insn.len]);
                t_pos += insn.len;
            }
            s_pos += insn.len;
        }

        // ── JMP back to original code after stolen bytes ──
        mem[t_pos] = 0xE9;
        writeRel32(
            mem + t_pos + 1,
            self.trampoline + t_pos + 1,
            target + stolen,
        );

        return .ok;
    }

    /// Phase 2: write the E9 JMP patch at the target.
    /// Any excess stolen bytes beyond the 5-byte JMP are filled with NOPs.
    pub fn activate(self: *GenericHook, detour_addr: usize) void {
        var patch: [MAX_STOLEN]u8 = .{0x90} ** MAX_STOLEN;
        patch[0] = 0xE9;
        writeRel32(patch[1..5], self.target + 1, detour_addr);
        writeProtected(self.target, patch[0..self.stolen_size]);
    }

    /// Restore original bytes and free trampoline memory.
    pub fn remove(self: *GenericHook) void {
        if (self.mem == null) return;
        writeProtected(self.target, self.saved_bytes[0..self.stolen_size]);
        _ = VirtualFree(@ptrFromInt(@intFromPtr(self.mem.?)), 0, MEM_RELEASE);
        self.mem = null;
    }

    /// Get trampoline as a typed function pointer.
    pub fn getTrampoline(self: *const GenericHook, comptime T: type) T {
        return @ptrFromInt(self.trampoline);
    }

    fn cleanup(self: *GenericHook) void {
        if (self.mem) |m| {
            _ = VirtualFree(@ptrFromInt(@intFromPtr(m)), 0, MEM_RELEASE);
            self.mem = null;
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Detour(FnType) — HadesMem-style type-safe generic hook
// ═══════════════════════════════════════════════════════════════════════

/// Comptime-generic typed detour — the recommended primary API for hooking.
///
/// Declare the target function's type once; get type-checked `attach`,
/// `callOriginal`, and `detach` with no manual pointer casts. Wraps
/// `GenericHook` for auto-sizing and relocation.
///
/// Supports all x86-32 calling conventions: `stdcall`, `cdecl`, `thiscall`,
/// and `fastcall` (requires patched Zig 0.16 with `inreg` fix for correct
/// x86 fastcall codegen). Uses `.never_tail` internally to prevent tail-call
/// optimization that would corrupt the stack with callee-cleanup conventions.
///
/// ```zig
/// const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
/// const CheckFile = fn (u32, u32, u32) callconv(fc) u32;
/// var hook: Detour(CheckFile) = .{};
/// _ = hook.attach(0x654DD0, &myDetour);
/// // in detour:  hook.callOriginal(.{ filename, flags, output });
/// hook.detach();
/// ```
pub fn Detour(comptime TargetFnType: type) type {
    const FnInfo = @typeInfo(TargetFnType).@"fn";
    const TargetFnPtr = *const TargetFnType;
    const ReturnType = FnInfo.return_type orelse void;

    return struct {
        /// The underlying `GenericHook` managing the trampoline and patch.
        inner: GenericHook = .{},

        const Self = @This();

        /// Hook the function at `target` to redirect to `detour`.
        /// The `detour` function pointer must match `TargetFnType` exactly.
        pub fn attach(self: *Self, target: usize, detour: TargetFnPtr) GenericHook.Error {
            const err = self.inner.prepare(target);
            if (err != .ok) return err;
            self.inner.activate(@intFromPtr(detour));
            return .ok;
        }

        /// Call the original (pre-hook) function through the trampoline.
        /// Pass args as a tuple: `.{ arg1, arg2, arg3 }`.
        ///
        /// Uses `.never_tail` to prevent tail-call optimization, which would
        /// corrupt the stack with callee-cleanup conventions (stdcall/fastcall/
        /// thiscall) — a tail call reuses the caller's stack frame, but the
        /// callee pops args itself, leaving ESP pointing at garbage on return.
        pub fn callOriginal(self: *const Self, args: anytype) ReturnType {
            const orig: *const TargetFnType = @ptrFromInt(self.inner.trampoline);
            return @call(.never_tail, orig, args);
        }

        /// Unhook: restore original bytes, free trampoline.
        pub fn detach(self: *Self) void {
            self.inner.remove();
        }

        /// Get the trampoline as a raw function pointer of the target type.
        ///
        /// Unlike `callOriginal`, calling through this pointer does NOT force
        /// `.never_tail` — the compiler may tail-call optimize, which corrupts
        /// the stack for callee-cleanup conventions. Prefer `callOriginal`
        /// unless you specifically need the function pointer (e.g. to pass as
        /// a callback).
        pub fn original(self: *const Self) *const TargetFnType {
            return @ptrFromInt(self.inner.trampoline);
        }
    };
}

/// Resolve absolute target of a Jcc rel32 (0F 8x xx xx xx xx) — 6 byte insn.
fn jcc32Target(addr: usize) usize {
    const disp: u32 = @bitCast(@as(*align(1) const i32, @ptrFromInt(addr + 2)).*);
    return (addr + 6) +% disp;
}
