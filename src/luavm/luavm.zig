//! luavm -- Lua VM hotspot optimizations.
//!
//! luaS_newlstr (0x6F9D00, 1.35% CPU): hash pre-check before memcmp.
//! A/B: alternating calls, per-call rdtsc, periodic dump via OnWorldUpdate.

const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "luavm";

var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// A/B instrumentation
// =============================================================================

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

const AB_DUMP_INTERVAL: u64 = 10000;

const ABStats = struct {
    cycles: u64 = 0,
    calls: u64 = 0,
};

var custom_ab: ABStats = .{};
var baseline_ab: ABStats = .{};

// =============================================================================
// luaS_newlstr (0x6F9D00)
//   __fastcall(ECX=lua_State*, EDX=str_ptr, stack=len) -> TString*
//   RET 0x4
// =============================================================================

const NewLStrFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
var newlstr_hook: hook.Detour(NewLStrFn) = .{};

var call_ctr: u32 = 0;

fn luaCreateStringObject(state: u32, str_ptr: u32, len: u32, hash_val: u32) u32 {
    return hook.call(
        fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32,
        0x6F9D90,
        .{ state, str_ptr, len, hash_val },
    );
}

fn newlstrDetour(state: u32, str_ptr: u32, len: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const use_custom = (call_ctr & 1) == 0;
    call_ctr +%= 1;
    const t0 = rdtsc();

    const result = if (use_custom)
        newlstrImpl(state, str_ptr, len)
    else
        newlstr_hook.callOriginal(.{ state, str_ptr, len });

    const elapsed = rdtsc() - t0;
    if (use_custom) {
        custom_ab.cycles +|= elapsed;
        custom_ab.calls +|= 1;
    } else {
        baseline_ab.cycles +|= elapsed;
        baseline_ab.calls +|= 1;
    }
    return result;
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
// OnWorldUpdate (0x482EA0) -- periodic stats dump
// =============================================================================

const WorldUpdateFn = fn (u32) callconv(hook.cc.fastcall) void;
var world_update_hook: hook.Detour(WorldUpdateFn) = .{};

var frame_count: u64 = 0;

fn worldUpdateDetour(fc: u32) callconv(hook.cc.fastcall) void {
    frame_count +%= 1;

    if (frame_count % AB_DUMP_INTERVAL == 0 and frame_count > 0) {
        dumpStats();
    }

    world_update_hook.callOriginal(.{fc});
}

fn dumpStats() void {
    const ca = custom_ab.calls;
    const ba = baseline_ab.calls;
    const c_avg: u64 = if (ca > 0) custom_ab.cycles / ca else 0;
    const b_avg: u64 = if (ba > 0) baseline_ab.cycles / ba else 0;

    log.fmt("[luavm] {d}f newlstr: c={d} b={d} cyc/call ({d}k calls)\n", .{
        frame_count, c_avg, b_avg, ca / 1000,
    });

    custom_ab = .{};
    baseline_ab = .{};
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);

    if (newlstr_hook.attach(0x6F9D00, &newlstrDetour) == .ok) {
        log.print("  newlstr: A/B hash pre-check vs original\n");
    }

    if (world_update_hook.attach(0x482EA0, &worldUpdateDetour) == .ok) {
        log.print("  OnWorldUpdate: periodic stats dump\n");
    }

    log.print("luavm: active\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        dumpStats();
        world_update_hook.detach();
        newlstr_hook.detach();
        log.close();
    }
    g_is_hook_owner = false;
}
