const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
        .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2 }),
    });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .small;

    const zhook_dep = b.dependency("zhook", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "weirdperformance_gc24b",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhook", .module = zhook_dep.module("zhook") },
            },
        }),
    });
    b.installArtifact(lib);
}
