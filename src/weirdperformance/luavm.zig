//! luavm -- Lua VM hotspot optimizations.
//!
//! luaS_newlstr (0x6F9D00, 1.35% CPU): hash pre-check before memcmp.
//! ~40% win vs original (validated by prior A/B). Production-only, no instrumentation.

const hook = @import("zhook");
const logging = @import("../logging.zig");

var log: logging.Logger = .{};

// =============================================================================
// luaS_newlstr (0x6F9D00)
//   __fastcall(ECX=lua_State*, EDX=str_ptr, stack=len) -> TString*
//   RET 0x4
// =============================================================================

const NewLStrFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
var newlstr_hook: hook.Detour(NewLStrFn) = .{};

fn luaCreateStringObject(state: u32, str_ptr: u32, len: u32, hash_val: u32) u32 {
    return hook.call(
        fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32,
        0x6F9D90,
        .{ state, str_ptr, len, hash_val },
    );
}

fn newlstrDetour(state: u32, str_ptr: u32, len: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    return newlstrImpl(state, str_ptr, len);
}

fn newlstrImpl(state: u32, str_ptr: u32, len: u32) u32 {
    const str: [*]const u8 = @ptrFromInt(str_ptr);
    var h: u32 = len;
    const step: u32 = (len >> 5) + 1;
    var l1: u32 = len;
    while (l1 >= step) {
        const c: u32 = str[l1 - 1];
        h = h ^ (c +% (h << 5) +% (h >> 2));
        l1 -= step;
    }

    const global_state: u32 = hook.readMem(u32, state + 0x10);
    const strt_hash: u32 = hook.readMem(u32, global_state + 0x04);
    const strt_size: u32 = hook.readMem(u32, global_state + 0x0C);

    const bucket: u32 = h & (strt_size - 1);
    var ts: u32 = hook.readMem(u32, strt_hash + bucket * 4);

    while (ts != 0) {
        const ts_len: u32 = hook.readMem(u32, ts + 0x0C);
        if (ts_len == len) {
            const ts_hash: u32 = hook.readMem(u32, ts + 0x08);
            if (ts_hash == h) {
                if (len == 0 or strEqual(str_ptr, ts + 0x10, len)) {
                    return ts;
                }
            }
        }
        ts = hook.readMem(u32, ts);
    }

    return luaCreateStringObject(state, str_ptr, len, h);
}

fn strEqual(a_ptr: u32, b_ptr: u32, len: u32) bool {
    const a: [*]const u8 = @ptrFromInt(a_ptr);
    const b: [*]const u8 = @ptrFromInt(b_ptr);

    var i: u32 = 0;
    while (i + 4 <= len) : (i += 4) {
        const va = @as(*align(1) const u32, @ptrCast(a + i)).*;
        const vb = @as(*align(1) const u32, @ptrCast(b + i)).*;
        if (va != vb) return false;
    }
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn install() u32 {
    log = logging.Logger.open("luavm", .console);

    var installed: u32 = 0;
    if (newlstr_hook.attach(0x6F9D00, &newlstrDetour) == .ok) {
        log.print("  newlstr: hash pre-check active\n");
        installed += 1;
    }

    log.print("luavm: active\n");
    return installed;
}

pub fn remove() void {
    newlstr_hook.detach();
    log.close();
}
