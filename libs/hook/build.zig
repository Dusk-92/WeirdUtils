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
}
