//! Generic x86 inline hook — no manual prologue size or fixup lists needed.
//!
//! Uses the x86 length disassembler (HDE32 port) to automatically determine
//! how many prologue bytes to steal, and relocates all relative instructions.
//!
//! Combines MinHook's compact disassembler with HadesMem's type-safe approach:
//! declare the function signature once at comptime, get a correctly-typed
//! trampoline and detour with zero manual casting.
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
//!
//! ## Type-safe API (Detour) — HadesMem-inspired
//!
//! ```zig
//! const MyHook = Detour(fn (u32, u32) callconv(.{ .x86_stdcall = .{} }) u32);
//! var hook: MyHook = .{};
//! hook.attach(0x401000, myDetour);
//! // Inside detour: hook.callOriginal(.{arg1, arg2});
//! ```

const std = @import("std");
const x86dis = @import("x86dis");
const hook_base = @import("hook.zig");

const VirtualAlloc = hook_base.VirtualAlloc;
const VirtualFree = hook_base.VirtualFree;
const PAGE_EXECUTE_READWRITE = hook_base.PAGE_EXECUTE_READWRITE;
const MEM_COMMIT = hook_base.MEM_COMMIT;
const MEM_RELEASE = hook_base.MEM_RELEASE;
const writeProtected = hook_base.writeProtected;

const JMP_SIZE: usize = 5; // E9 + rel32
const MAX_STOLEN: usize = 32;
const TRAMPOLINE_BUF: usize = 64;

// ═══════════════════════════════════════════════════════════════════════
// GenericHook — low-level auto-sizing hook
// ═══════════════════════════════════════════════════════════════════════

pub const GenericHook = struct {
    mem: ?[*]u8 = null,
    trampoline: usize = 0,
    target: usize = 0,
    stolen_size: usize = 0,
    saved_bytes: [MAX_STOLEN]u8 = undefined,

    pub const Error = enum {
        ok,
        alloc_failed,
        disasm_error,
        prologue_too_short,
        unsupported_relocation,
    };

    /// Analyse target, build trampoline, patch target → detour. One call.
    pub fn install(self: *GenericHook, target: usize, detour_addr: usize) Error {
        const err = self.prepare(target);
        if (err != .ok) return err;
        self.activate(detour_addr);
        return .ok;
    }

    /// Phase 1: disassemble prologue, allocate trampoline, copy + relocate.
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
        const mem = VirtualAlloc(null, TRAMPOLINE_BUF, MEM_COMMIT, PAGE_EXECUTE_READWRITE) orelse return .alloc_failed;

        self.mem = mem;
        self.target = target;
        self.stolen_size = stolen;
        self.trampoline = @intFromPtr(mem);

        @memcpy(self.saved_bytes[0..stolen], src[0..stolen]);

        // ── check if already hooked (E9 at target) — chain through ──
        if (src[0] == 0xE9) {
            const other_detour = hook_base.rel32Target(target);
            mem[0] = 0xE9;
            hook_base.writeRel32(mem + 1, self.trampoline + 1, other_detour);
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
                    const abs = hook_base.rel32Target(src_addr);
                    mem[t_pos] = op;
                    hook_base.writeRel32(mem + t_pos + 1, dst_addr + 1, abs);
                    t_pos += 5;
                } else if (op == 0x0F and insn.opcode2 >= 0x80 and insn.opcode2 <= 0x8F) {
                    // Jcc rel32 (0F 80-8F)
                    const abs = jcc32Target(src_addr);
                    mem[t_pos] = 0x0F;
                    mem[t_pos + 1] = insn.opcode2;
                    hook_base.writeRel32(mem + t_pos + 2, dst_addr + 2, abs);
                    t_pos += 6;
                } else if (op >= 0x70 and op <= 0x7F) {
                    // Short Jcc → expand to near Jcc (0F 8x)
                    const offset = @as(i8, @bitCast(src[s_pos + 1]));
                    const abs: usize = @bitCast(@as(isize, @intCast(src_addr + 2)) + offset);
                    mem[t_pos] = 0x0F;
                    mem[t_pos + 1] = op + 0x10;
                    hook_base.writeRel32(mem + t_pos + 2, dst_addr + 2, abs);
                    t_pos += 6;
                } else if (op == 0xEB) {
                    // Short JMP → expand to near JMP (E9)
                    const offset = @as(i8, @bitCast(src[s_pos + 1]));
                    const abs: usize = @bitCast(@as(isize, @intCast(src_addr + 2)) + offset);
                    mem[t_pos] = 0xE9;
                    hook_base.writeRel32(mem + t_pos + 1, dst_addr + 1, abs);
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
        hook_base.writeRel32(
            mem + t_pos + 1,
            self.trampoline + t_pos + 1,
            target + stolen,
        );

        return .ok;
    }

    /// Phase 2: write the E9 JMP patch at the target.
    pub fn activate(self: *GenericHook, detour_addr: usize) void {
        var patch: [MAX_STOLEN]u8 = .{0x90} ** MAX_STOLEN;
        patch[0] = 0xE9;
        hook_base.writeRel32(patch[1..5], self.target + 1, detour_addr);
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

/// Comptime-generic typed detour. Declare the target function's type once;
/// get type-checked attach/callOriginal with no manual pointer casts.
///
/// ```zig
/// const StdcallU32x2 = fn (u32, u32) callconv(.{ .x86_stdcall = .{} }) u32;
/// const MyHook = generic_hook.Detour(StdcallU32x2);
/// var hook: MyHook = .{};
/// hook.attach(0x401000, &myDetour);
/// // in detour:  hook.callOriginal(.{ a, b });
/// hook.detach();
/// ```
pub fn Detour(comptime FnType: type) type {
    const FnInfo = @typeInfo(FnType).@"fn";
    const FnPtr = *const FnType;
    const ReturnType = FnInfo.return_type orelse void;
    const ParamTypes = FnInfo.params;

    return struct {
        inner: GenericHook = .{},

        const Self = @This();

        /// Hook the function at `target` to redirect to `detour`.
        pub fn attach(self: *Self, target: usize, detour: FnPtr) GenericHook.Error {
            return self.inner.install(target, @intFromPtr(detour));
        }

        /// Call the original (pre-hook) function through the trampoline.
        pub fn callOriginal(self: *const Self, args: anytype) ReturnType {
            const orig: FnPtr = @ptrFromInt(self.inner.trampoline);
            return @call(.auto, orig, coerceArgs(ParamTypes, args));
        }

        /// Unhook: restore original bytes, free trampoline.
        pub fn detach(self: *Self) void {
            self.inner.remove();
        }

        /// Get the trampoline as the correctly-typed function pointer.
        pub fn original(self: *const Self) FnPtr {
            return @ptrFromInt(self.inner.trampoline);
        }
    };
}

/// Coerce a tuple of args into the exact parameter types expected.
fn coerceArgs(comptime params: anytype, args: anytype) CoercedTuple(params) {
    var result: CoercedTuple(params) = undefined;
    inline for (0..params.len) |idx| {
        @field(result, std.fmt.comptimePrint("{d}", .{idx})) = args[idx];
    }
    return result;
}

fn CoercedTuple(comptime params: anytype) type {
    var fields: [params.len]std.builtin.Type.StructField = undefined;
    inline for (0..params.len) |idx| {
        fields[idx] = .{
            .name = std.fmt.comptimePrint("{d}", .{idx}),
            .type = params[idx].type.?,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

/// Resolve absolute target of a Jcc rel32 (0F 8x xx xx xx xx) — 6 byte insn.
fn jcc32Target(addr: usize) usize {
    const disp: u32 = @bitCast(@as(*align(1) const i32, @ptrFromInt(addr + 2)).*);
    return (addr + 6) +% disp;
}
