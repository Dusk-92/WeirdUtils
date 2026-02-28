const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{});

    // Build options for conditional module compilation
    const enable_screenshot = b.option(bool, "screenshot", "Enable screenshot module") orelse true;
    const enable_interact = b.option(bool, "interact", "Enable interact module") orelse true;
    const enable_outline = b.option(bool, "outline", "Enable outline module") orelse true;
    const enable_markers = b.option(bool, "markers", "Enable markers module") orelse true;
    const enable_framecrash = b.option(bool, "framecrash", "Enable framecrash fix") orelse true;
    const enable_combatlog = b.option(bool, "combatlog", "Enable combat log freshness") orelse true;

    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_screenshot", enable_screenshot);
    build_options.addOption(bool, "enable_interact", enable_interact);
    build_options.addOption(bool, "enable_outline", enable_outline);
    build_options.addOption(bool, "enable_markers", enable_markers);
    build_options.addOption(bool, "enable_framecrash", enable_framecrash);
    build_options.addOption(bool, "enable_combatlog", enable_combatlog);
    const build_options_module = build_options.createModule();

    const hook_mod = b.dependency("hook", .{
        .target = target,
        .optimize = optimize,
    }).module("hook");

    const lib = b.addLibrary(.{
        .name = "weirdutils",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hook", .module = hook_mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });

    b.installArtifact(lib);

    // Convenience step to build all single-module variants
    const build_all_step = b.step("all-variants", "Build all DLL variants");

    // Helper to create a single-module build
    inline for (&[_]struct { name: []const u8, screenshot: bool, interact: bool, outline: bool, markers: bool, framecrash: bool, combatlog: bool }{
        .{ .name = "full", .screenshot = true, .interact = true, .outline = true, .markers = true, .framecrash = true, .combatlog = true },
        .{ .name = "screenshot", .screenshot = true, .interact = false, .outline = false, .markers = false, .framecrash = true, .combatlog = true },
        .{ .name = "interact", .screenshot = false, .interact = true, .outline = false, .markers = false, .framecrash = true, .combatlog = true },
        .{ .name = "outline", .screenshot = false, .interact = false, .outline = true, .markers = false, .framecrash = true, .combatlog = true },
        .{ .name = "markers", .screenshot = false, .interact = false, .outline = false, .markers = true, .framecrash = true, .combatlog = true },
        .{ .name = "framecrash", .screenshot = false, .interact = false, .outline = false, .markers = false, .framecrash = true, .combatlog = false },
        .{ .name = "combatlog", .screenshot = false, .interact = false, .outline = false, .markers = false, .framecrash = false, .combatlog = true },
    }) |variant| {
        const opts = b.addOptions();
        opts.addOption(bool, "enable_screenshot", variant.screenshot);
        opts.addOption(bool, "enable_interact", variant.interact);
        opts.addOption(bool, "enable_outline", variant.outline);
        opts.addOption(bool, "enable_markers", variant.markers);
        opts.addOption(bool, "enable_framecrash", variant.framecrash);
        opts.addOption(bool, "enable_combatlog", variant.combatlog);

        const variant_lib = b.addLibrary(.{
            .name = variant.name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hook", .module = hook_mod },
                    .{ .name = "build_options", .module = opts.createModule() },
                },
            }),
        });

        const install_variant = b.addInstallArtifact(variant_lib, .{
            .dest_dir = .{ .override = .{ .custom = "variants" } },
        });
        build_all_step.dependOn(&install_variant.step);
    }
}
