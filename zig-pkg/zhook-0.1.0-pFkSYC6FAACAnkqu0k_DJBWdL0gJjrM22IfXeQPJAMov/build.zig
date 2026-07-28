const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // x86 length disassembler — standalone, no dependencies
    const x86dis_mod = b.addModule("x86dis", .{
        .root_source_file = b.path("src/x86dis.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zhook — x86-32 inline hooking with auto-sizing trampolines
    const zhook_mod = b.addModule("zhook", .{
        .root_source_file = b.path("src/zhook.zig"),
        .target = target,
        .optimize = optimize,
    });
    zhook_mod.addImport("x86dis", x86dis_mod);
}
