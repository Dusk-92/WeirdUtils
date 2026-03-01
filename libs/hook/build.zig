const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hwbp = b.option(bool, "hwbp", "Use hardware breakpoint hooks instead of inline patching") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "use_hwbp", hwbp);

    const hook_mod = b.addModule("hook", .{
        .root_source_file = b.path("src/hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    hook_mod.addOptions("config", options);

    // x86 length disassembler — standalone, no dependencies
    const x86dis_mod = b.addModule("x86dis", .{
        .root_source_file = b.path("src/x86dis.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Generic hook — uses x86dis + hook for auto-sizing trampolines
    const generic_hook_mod = b.addModule("generic_hook", .{
        .root_source_file = b.path("src/generic_hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    generic_hook_mod.addImport("x86dis", x86dis_mod);
    generic_hook_mod.addImport("hook.zig", hook_mod);
    generic_hook_mod.addOptions("config", options);
}
