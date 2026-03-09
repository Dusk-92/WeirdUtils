//! WoW 1.12.1 Lua C API wrappers (all __fastcall, L in ECX)

const std = @import("std");
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };

pub const State = *anyopaque;

pub fn getContext() State {
    const f: *const fn () callconv(fc) State = @ptrFromInt(0x7040D0);
    return f();
}

pub fn gettop(L: State) i32 {
    const f: *const fn (State) callconv(fc) i32 = @ptrFromInt(0x6F3070);
    return f(L);
}

pub fn settop(L: State, index: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3080);
    f(L, index);
}

pub fn pop(L: State, n: i32) void {
    settop(L, -n - 1);
}

pub fn pushvalue(L: State, index: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3350);
    f(L, index);
}

pub fn remove(L: State, index: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F30D0);
    f(L, index);
}

pub fn insert(L: State, index: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F31A0);
    f(L, index);
}

pub fn typeOf(L: State, index: i32) i32 {
    const f: *const fn (State, i32) callconv(fc) i32 = @ptrFromInt(0x6F3400);
    return f(L, index);
}

pub fn typeName(L: State, tp: i32) [*:0]const u8 {
    const f: *const fn (State, i32) callconv(fc) [*:0]const u8 = @ptrFromInt(0x6F3480);
    return f(L, tp);
}

pub fn isnumber(L: State, index: i32) bool {
    const f: *const fn (State, i32) callconv(fc) u32 = @ptrFromInt(0x6F34D0);
    return f(L, index) != 0;
}

pub fn isstring(L: State, index: i32) bool {
    const f: *const fn (State, i32) callconv(fc) u32 = @ptrFromInt(0x6F3510);
    return f(L, index) != 0;
}

pub fn pushnil(L: State) void {
    const f: *const fn (State) callconv(fc) void = @ptrFromInt(0x6F37F0);
    f(L);
}

pub fn pushnumber(L: State, n: f64) void {
    // __thiscall: ECX=L, f64 on stack [EBP+8]/[EBP+0xc], ret 8.
    // .never_tail: callee-cleanup pops stack args - tail-call would corrupt the stack.
    const f: *const fn (State, f64) callconv(.{ .x86_thiscall = .{} }) void = @ptrFromInt(0x6F3810);
    @call(.never_tail, f, .{ L, n });
}

pub fn pushstring(L: State, s: [*:0]const u8) void {
    const f: *const fn (State, [*:0]const u8) callconv(fc) void = @ptrFromInt(0x6F3890);
    f(L, s);
}

pub fn pushboolean(L: State, b: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F39F0);
    f(L, b);
}

pub fn pushcclosure(L: State, func: usize, n: i32) void {
    const f: *const fn (State, usize, i32) callconv(fc) void = @ptrFromInt(0x6F3920);
    @call(.never_tail, f, .{ L, func, n });
}

pub fn tonumber(L: State, index: i32) f64 {
    const f: *const fn (State, i32) callconv(fc) f64 = @ptrFromInt(0x6F3620);
    return f(L, index);
}

pub fn tostring(L: State, index: i32) ?[*:0]const u8 {
    const f: *const fn (State, i32) callconv(fc) ?[*:0]const u8 = @ptrFromInt(0x6F3690);
    return f(L, index);
}

pub fn toboolean(L: State, index: i32) i32 {
    const f: *const fn (State, i32) callconv(fc) i32 = @ptrFromInt(0x6F3660);
    return f(L, index);
}

pub fn newtable(L: State) void {
    const f: *const fn (State) callconv(fc) void = @ptrFromInt(0x6F3C90);
    f(L);
}

pub fn settable(L: State, index: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3E20);
    f(L, index);
}

pub fn gettable(L: State, index: i32) void {
    const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3A40);
    f(L, index);
}

pub fn next(L: State, index: i32) i32 {
    const f: *const fn (State, i32) callconv(fc) i32 = @ptrFromInt(0x6F4450);
    return f(L, index);
}

pub fn pcall(L: State, nargs: i32, nresults: i32, errfunc: i32) i32 {
    const f: *const fn (State, i32, i32, i32) callconv(fc) i32 = @ptrFromInt(0x6F41A0);
    return @call(.never_tail, f, .{ L, nargs, nresults, errfunc });
}

pub fn luaError(L: State, msg: [*:0]const u8) void {
    const hook = @import("zhook");
    hook.call(fn (*anyopaque, [*:0]const u8) callconv(.c) void, 0x6F4940, .{ L, msg });
}

pub const LuaReg = extern struct {
    name: ?[*:0]const u8,
    func: usize,
};

pub fn openlib(L: State, libname: ?[*:0]const u8, funcs: [*]const LuaReg, nup: i32) void {
    const f: *const fn (State, ?[*:0]const u8, [*]const LuaReg, i32) callconv(fc) void = @ptrFromInt(0x6F4DC0);
    @call(.never_tail, f, .{ L, libname, funcs, nup });
}

pub fn checknumber(L: State, index: i32) f64 {
    const f: *const fn (State, i32) callconv(fc) f64 = @ptrFromInt(0x6F4C80);
    return f(L, index);
}
