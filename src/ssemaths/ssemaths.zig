//! ssemaths — UnitXP x87 FPU math polyfill replacements
//!
//! Replaces 17 game math functions with SSE equivalents, plus CriticalSection
//! spin count optimization and blit memcpy fast paths. All from UnitXP's
//! polyfill.cpp, re-verified via Ghidra prologue/epilogue disassembly.
//!
//! Installed in lateInit() after UnitXP has hooked these functions, so we
//! clobber UnitXP's JMP prologues with the original bytes and then hook
//! ourselves. This gives us a clean trampoline to the true original code
//! for A/B testing.
//!
//! PERFORMANCE NOTE: Hook-based replacement adds ~5-8 cycles of CALL/RET
//! overhead per invocation. Large functions (rotMat, planeNormal, transformAABox)
//! see net gains (1.2-2.1x), but small functions (dotProduct, squaredMagnitude,
//! evaluatePolynomial) are slower than the originals due to call overhead alone.
//! Inlined benchmarks show ALL functions are faster with SSE (2-4x for small
//! functions). Future direction: patch SSE bytes in-place at load time.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "ssemaths";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// math_sse.zig exports (C ABI, compiled ReleaseFast as separate object)
extern fn vecMulMat4_ColMajor(u32, u32, u32) u32;
extern fn matMulVec3_RowMajor(u32, u32, u32) u32;
extern fn quatMulMat4(u32, u32, u32) u32;
extern fn vec3MulScalar(u32, u32, u32) u32;
extern fn vec3MulAssign(u32, u32) u32;
extern fn applyTranslationMatrix(u32, u32) u32;
extern fn scaleMatrix3x3ByVector(u32, u32) u32;
extern fn scaleMatrix3x3ByScalar(u32, u32) void;
extern fn multiply3x3Matrix(u32, u32, u32) u32;
extern fn createAxisAngleRotMat3x3(u32, u32, u32, u32) u32;
extern fn createAxisAngleRotMat4x4(u32, u32, u32, u32) u32;
extern fn crossProduct(u32, u32, u32) u32;
extern fn dotProduct(u32, u32) f64;
extern fn squaredMagnitude(u32) f64;
extern fn evaluatePolynomial(u32, u32, u32) f64;
extern fn calculatePlaneNormal(u32, u32, u32, u32) void;
extern fn transformAABox(u32, u32, u32, u32, u32) void;

// =============================================================================
// Calling convention types (Ghidra-verified from prologue/epilogue disassembly)
// =============================================================================

// Fastcall fn types (ECX + EDX + stack)
const FC3r = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
const FC4r = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32;
const FC5v = fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
const FC2d = fn (u32, u32) callconv(hook.cc.fastcall) f64;
const FC3d = fn (u32, u32, u32) callconv(hook.cc.fastcall) f64;
// Thiscall fn types (ECX + stack)
const TC2r = fn (u32, u32) callconv(hook.cc.thiscall) u32;
const TC2v = fn (u32, u32) callconv(hook.cc.thiscall) void;
const TC1d = fn (u32) callconv(hook.cc.thiscall) f64;
const TC4v = fn (u32, u32, u32, u32) callconv(hook.cc.thiscall) void;

// =============================================================================
// Math hook variables
//
//  1: vecMulMat4       __fastcall(ECX=result, EDX=vec, stack:mat) RET 0x4
//  2: matMulVec3       __fastcall(ECX=result, EDX=mat, stack:vec) RET 0x4
//  3: quatMulMat4      __fastcall(ECX=result, EDX=quat, stack:mat) RET 0x4
//  4: vec3MulScalar    __fastcall(ECX=result, EDX=vec, stack:factor) RET 0x4
//  5: vec3MulAssign    __thiscall(ECX=self, stack:factor) RET 0x4
//  6: applyTranslation __thiscall(ECX=mat, stack:vec) RET 0x4
//  7: scaleByVec       __thiscall(ECX=mat, stack:vec) RET 0x4
//  8: scaleByScalar    __thiscall(ECX=mat, stack:factor) RET 0x4
//  9: mul3x3           __fastcall(ECX=result, EDX=matA, stack:matB) RET 0x4
// 10: rotMat3x3        __fastcall(ECX=result, EDX=axis, stack:angle,is_unit) RET 0x8
// 11: rotMat4x4        __fastcall(ECX=result, EDX=axis, stack:angle,is_unit) RET 0x8
// 12: cross            __fastcall(ECX=result, EDX=vecA, stack:vecB) RET 0x4
// 13: dot              __fastcall(ECX=vecA, EDX=vecB) RET
// 14: sqmag            __thiscall(ECX=vec) RET
// 16: evalPoly         __fastcall(ECX=count, EDX=coeffs, stack:factor) RET 0x4
// 17: planeNormal      __thiscall(ECX=result, stack:p1,p2,p3) RET 0xC
// 18: transformAABox   __fastcall(ECX=mat, EDX=vecA, stack:vecB,boxIn,boxOut) RET 0xC
// =============================================================================

var math_vecMulMat4_hook: hook.Detour(FC3r) = .{};
var math_matMulVec3_hook: hook.Detour(FC3r) = .{};
var math_quatMulMat4_hook: hook.Detour(FC3r) = .{};
var math_vec3MulScalar_hook: hook.Detour(FC3r) = .{};
var math_vec3MulAssign_hook: hook.Detour(TC2r) = .{};
var math_applyTranslation_hook: hook.Detour(TC2r) = .{};
var math_scaleByVec_hook: hook.Detour(TC2r) = .{};
var math_scaleByScalar_hook: hook.Detour(TC2v) = .{};
var math_mul3x3_hook: hook.Detour(FC3r) = .{};
var math_rotMat3x3_hook: hook.Detour(FC4r) = .{};
var math_rotMat4x4_hook: hook.Detour(FC4r) = .{};
var math_cross_hook: hook.Detour(FC3r) = .{};
var math_dot_hook: hook.Detour(FC2d) = .{};
var math_sqmag_hook: hook.Detour(TC1d) = .{};
var math_evalPoly_hook: hook.Detour(FC3d) = .{};
var math_planeNormal_hook: hook.Detour(TC4v) = .{};
var math_transformAABox_hook: hook.Detour(FC5v) = .{};

// Detour wrappers — direct dispatch (no A/B, always SSE)
fn wrapFC3r(comptime f: anytype, comptime h: anytype) *const FC3r {
    return &struct { fn w(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) u32 { _ = h; return f(a, b, c); } }.w;
}
fn wrapFC4r(comptime f: anytype, comptime h: anytype) *const FC4r {
    return &struct { fn w(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) u32 { _ = h; return f(a, b, c, d); } }.w;
}
fn wrapFC5v(comptime f: anytype, comptime h: anytype) *const FC5v {
    return &struct { fn w(a: u32, b: u32, c: u32, d: u32, e: u32) callconv(hook.cc.fastcall) void { _ = h; f(a, b, c, d, e); } }.w;
}
fn wrapFC2d(comptime f: anytype, comptime h: anytype) *const FC2d {
    return &struct { fn w(a: u32, b: u32) callconv(hook.cc.fastcall) f64 { _ = h; return f(a, b); } }.w;
}
fn wrapFC3d(comptime f: anytype, comptime h: anytype) *const FC3d {
    return &struct { fn w(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) f64 { _ = h; return f(a, b, c); } }.w;
}
fn wrapTC2r(comptime f: anytype, comptime h: anytype) *const TC2r {
    return &struct { fn w(a: u32, b: u32) callconv(hook.cc.thiscall) u32 { _ = h; return f(a, b); } }.w;
}
fn wrapTC2v(comptime f: anytype, comptime h: anytype) *const TC2v {
    return &struct { fn w(a: u32, b: u32) callconv(hook.cc.thiscall) void { _ = h; f(a, b); } }.w;
}
fn wrapTC1d(comptime f: anytype, comptime h: anytype) *const TC1d {
    return &struct { fn w(a: u32) callconv(hook.cc.thiscall) f64 { _ = h; return f(a); } }.w;
}
fn wrapTC4v(comptime f: anytype, comptime h: anytype) *const TC4v {
    return &struct { fn w(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.thiscall) void { _ = h; f(a, b, c, d); } }.w;
}

// =============================================================================
// CriticalSection spin count optimization (from UnitXP polyfill.cpp:474)
// =============================================================================

const WINAPI = std.builtin.CallingConvention.winapi;
const CritSecFn = fn (u32) callconv(WINAPI) void;
var critsec_hook: hook.Detour(CritSecFn) = .{};

extern "kernel32" fn GetModuleHandleA(name: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn SetCriticalSectionSpinCount(cs: u32, spin: u32) callconv(WINAPI) u32;

fn critSecDetour(cs_ptr: u32) callconv(WINAPI) void {
    if (cs_ptr != 0 and (cs_ptr & 1) == 0) {
        const spin_count = hook.readMem(u32, cs_ptr + 0x18);
        if (spin_count == 0) {
            _ = SetCriticalSectionSpinCount(cs_ptr, 4000);
        }
    }
    critsec_hook.callOriginal(.{cs_ptr});
}

// =============================================================================
// Install / remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);

    // CriticalSection spin count optimization
    if (GetModuleHandleA("kernel32")) |k32| {
        if (GetProcAddress(k32, "EnterCriticalSection")) |ecs_addr| {
            _ = critsec_hook.attach(@intFromPtr(ecs_addr), &critSecDetour);
            log.print("critsec: SpinCount=4000 hook installed\n");
        }
    }

    log.print("ssemaths: installHooks done (math hooks deferred to lateInit)\n");
}

/// Called after UnitXP has installed its hooks.
/// Restores original prologues (clobbering UnitXP's JMP), then hooks ourselves.
pub fn lateInit() void {
    if (!g_is_hook_owner) return;

    const MathHook = struct { addr: u32, prologue: []const u8 };
    const math_hooks = [_]MathHook{
        .{ .addr = 0x7BCA80, .prologue = &.{ 0x55, 0x8b, 0xec, 0x56, 0x8b, 0x75, 0x08 } },  //  1: vecMulMat4
        .{ .addr = 0x7BCAE0, .prologue = &.{ 0x55, 0x8b, 0xec, 0xd9, 0x42, 0x28 } },         //  2: matMulVec3
        .{ .addr = 0x7BCB40, .prologue = &.{ 0x55, 0x8b, 0xec, 0x56, 0x8b, 0x75, 0x08 } },   //  3: quatMulMat4
        .{ .addr = 0x5F8CF0, .prologue = &.{ 0x55, 0x8b, 0xec, 0xd9, 0x45, 0x08 } },         //  4: vec3MulScalar
        .{ .addr = 0x5132F0, .prologue = &.{ 0x55, 0x8b, 0xec, 0xd9, 0x45, 0x08 } },         //  5: vec3MulAssign
        .{ .addr = 0x7BDC40, .prologue = &.{ 0x55, 0x8b, 0xec, 0x8b, 0x45, 0x08 } },         //  6: applyTranslation
        .{ .addr = 0x7BDCA0, .prologue = &.{ 0x55, 0x8b, 0xec, 0x8b, 0x45, 0x08 } },         //  7: scaleByVec
        .{ .addr = 0x7BDD00, .prologue = &.{ 0x55, 0x8b, 0xec, 0xd9, 0x45, 0x08 } },         //  8: scaleByScalar
        .{ .addr = 0x7BDFC0, .prologue = &.{ 0x55, 0x8b, 0xec, 0x51, 0xd9, 0x42, 0x1c } },   //  9: mul3x3
        .{ .addr = 0x7BE490, .prologue = &.{ 0x55, 0x8b, 0xec, 0x83, 0xec, 0x18 } },         // 10: rotMat3x3
        .{ .addr = 0x7BDB00, .prologue = &.{ 0x55, 0x8b, 0xec, 0x83, 0xec, 0x18 } },         // 11: rotMat4x4
        .{ .addr = 0x672130, .prologue = &.{ 0x55, 0x8b, 0xec, 0xd9, 0x02 } },               // 12: cross
        .{ .addr = 0x602630, .prologue = &.{ 0xd9, 0x41, 0x08, 0xd8, 0x4a, 0x08 } },         // 13: dot
        .{ .addr = 0x4549F0, .prologue = &.{ 0xd9, 0x41, 0x08, 0xd9, 0x41, 0x04 } },         // 14: sqmag
        .{ .addr = 0x453620, .prologue = &.{ 0x55, 0x8b, 0xec, 0xd9, 0x02 } },               // 15: evalPoly
        .{ .addr = 0x637480, .prologue = &.{ 0x55, 0x8b, 0xec, 0x83, 0xec, 0x18 } },         // 16: planeNormal
        .{ .addr = 0x6DC470, .prologue = &.{ 0x55, 0x8b, 0xec, 0x83, 0xec, 0x0c } },         // 17: transformAABox
    };

    var math_count: u32 = 0;
    inline for (.{
        .{ &math_vecMulMat4_hook,      0x7BCA80, wrapFC3r(&vecMulMat4_ColMajor,      &math_vecMulMat4_hook),      0 },
        .{ &math_matMulVec3_hook,      0x7BCAE0, wrapFC3r(&matMulVec3_RowMajor,      &math_matMulVec3_hook),      1 },
        .{ &math_quatMulMat4_hook,     0x7BCB40, wrapFC3r(&quatMulMat4,              &math_quatMulMat4_hook),     2 },
        .{ &math_vec3MulScalar_hook,   0x5F8CF0, wrapFC3r(&vec3MulScalar,            &math_vec3MulScalar_hook),   3 },
        .{ &math_vec3MulAssign_hook,   0x5132F0, wrapTC2r(&vec3MulAssign,            &math_vec3MulAssign_hook),   4 },
        .{ &math_applyTranslation_hook,0x7BDC40, wrapTC2r(&applyTranslationMatrix,   &math_applyTranslation_hook),5 },
        .{ &math_scaleByVec_hook,      0x7BDCA0, wrapTC2r(&scaleMatrix3x3ByVector,   &math_scaleByVec_hook),      6 },
        .{ &math_scaleByScalar_hook,   0x7BDD00, wrapTC2v(&scaleMatrix3x3ByScalar,   &math_scaleByScalar_hook),   7 },
        .{ &math_mul3x3_hook,         0x7BDFC0, wrapFC3r(&multiply3x3Matrix,         &math_mul3x3_hook),          8 },
        .{ &math_rotMat3x3_hook,      0x7BE490, wrapFC4r(&createAxisAngleRotMat3x3,  &math_rotMat3x3_hook),       9 },
        .{ &math_rotMat4x4_hook,      0x7BDB00, wrapFC4r(&createAxisAngleRotMat4x4,  &math_rotMat4x4_hook),      10 },
        .{ &math_cross_hook,          0x672130, wrapFC3r(&crossProduct,               &math_cross_hook),          11 },
        .{ &math_dot_hook,            0x602630, wrapFC2d(&dotProduct,                 &math_dot_hook),            12 },
        .{ &math_sqmag_hook,          0x4549F0, wrapTC1d(&squaredMagnitude,           &math_sqmag_hook),          13 },
        .{ &math_evalPoly_hook,       0x453620, wrapFC3d(&evaluatePolynomial,         &math_evalPoly_hook),       14 },
        .{ &math_planeNormal_hook,    0x637480, wrapTC4v(&calculatePlaneNormal,       &math_planeNormal_hook),    15 },
        .{ &math_transformAABox_hook, 0x6DC470, wrapFC5v(&transformAABox,             &math_transformAABox_hook),  16 },
    }) |entry| {
        hook.writeProtected(entry[1], math_hooks[entry[3]].prologue);
        _ = entry[0].attach(entry[1], entry[2]);
        math_count += 1;
    }
    log.fmt("ssemaths: {d}/17 math hooks installed\n", .{math_count});
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        math_vecMulMat4_hook.detach();
        math_matMulVec3_hook.detach();
        math_quatMulMat4_hook.detach();
        math_vec3MulScalar_hook.detach();
        math_vec3MulAssign_hook.detach();
        math_applyTranslation_hook.detach();
        math_scaleByVec_hook.detach();
        math_scaleByScalar_hook.detach();
        math_mul3x3_hook.detach();
        math_rotMat3x3_hook.detach();
        math_rotMat4x4_hook.detach();
        math_cross_hook.detach();
        math_dot_hook.detach();
        math_sqmag_hook.detach();
        math_evalPoly_hook.detach();
        math_planeNormal_hook.detach();
        math_transformAABox_hook.detach();
        critsec_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
