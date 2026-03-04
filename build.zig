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
    const enable_worldmarkers = b.option(bool, "worldmarkers", "Enable world markers module") orelse true;
    const enable_framecrash = b.option(bool, "framecrash", "Enable framecrash fix") orelse false;
    const enable_logsessions = b.option(bool, "logsessions", "Enable log session rotation") orelse true;
    const enable_minimapicons = b.option(bool, "minimapicons", "Enable custom minimap icons") orelse true;
    const enable_transmogfix = b.option(bool, "transmogfix", "Enable transmog update coalescing") orelse true;
    const enable_customassets = b.option(bool, "customassets", "Enable loose file loading & permissive patch glob") orelse true;
    const enable_healtextfix = b.option(bool, "healtextfix", "Enable SuperWoW heal text fix") orelse true;
    const enable_bigcursor = b.option(bool, "bigcursor", "Enable big cursor module") orelse true;

    // Create build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_screenshot", enable_screenshot);
    build_options.addOption(bool, "enable_interact", enable_interact);
    build_options.addOption(bool, "enable_outline", enable_outline);
    build_options.addOption(bool, "enable_worldmarkers", enable_worldmarkers);
    build_options.addOption(bool, "enable_framecrash", enable_framecrash);
    build_options.addOption(bool, "enable_logsessions", enable_logsessions);
    build_options.addOption(bool, "enable_minimapicons", enable_minimapicons);
    build_options.addOption(bool, "enable_transmogfix", enable_transmogfix);
    build_options.addOption(bool, "enable_customassets", enable_customassets);
    build_options.addOption(bool, "enable_healtextfix", enable_healtextfix);
    build_options.addOption(bool, "enable_bigcursor", enable_bigcursor);
    const build_options_module = build_options.createModule();

    const zhook_dep = b.dependency("zhook", .{
        .target = target,
        .optimize = optimize,
    });
    const zhook_mod = zhook_dep.module("zhook");

    const lib = b.addLibrary(.{
        .name = "weirdutils",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhook", .module = zhook_mod },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });

    b.installArtifact(lib);

    // Convenience step to build all single-module variants
    const build_all_step = b.step("all-variants", "Build all DLL variants");

    // Helper to create a single-module build
    const Variant = struct { name: []const u8, screenshot: bool, interact: bool, outline: bool, worldmarkers: bool, framecrash: bool, logsessions: bool, minimapicons: bool, transmogfix: bool, customassets: bool, healtextfix: bool, bigcursor: bool };
    inline for (&[_]Variant{
        .{ .name = "full", .screenshot = true, .interact = true, .outline = true, .worldmarkers = true, .framecrash = true, .logsessions = true, .minimapicons = true, .transmogfix = true, .customassets = true, .healtextfix = true, .bigcursor = true },
        .{ .name = "screenshot", .screenshot = true, .interact = false, .outline = false, .worldmarkers = false, .framecrash = true, .logsessions = true, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "interact", .screenshot = false, .interact = true, .outline = false, .worldmarkers = false, .framecrash = true, .logsessions = true, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "outline", .screenshot = false, .interact = false, .outline = true, .worldmarkers = false, .framecrash = true, .logsessions = true, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "worldmarkers", .screenshot = false, .interact = false, .outline = false, .worldmarkers = true, .framecrash = true, .logsessions = true, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "framecrash", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = true, .logsessions = false, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "logsessions", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = false, .logsessions = true, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "minimapicons", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = true, .logsessions = false, .minimapicons = true, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "transmogfix", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = false, .logsessions = false, .minimapicons = false, .transmogfix = true, .customassets = false, .healtextfix = false, .bigcursor = false },
        .{ .name = "customassets", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = false, .logsessions = false, .minimapicons = false, .transmogfix = false, .customassets = true, .healtextfix = false, .bigcursor = false },
        .{ .name = "healtextfix", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = false, .logsessions = false, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = true, .bigcursor = false },
        .{ .name = "bigcursor", .screenshot = false, .interact = false, .outline = false, .worldmarkers = false, .framecrash = false, .logsessions = false, .minimapicons = false, .transmogfix = false, .customassets = false, .healtextfix = false, .bigcursor = true },
    }) |variant| {
        const opts = b.addOptions();
        opts.addOption(bool, "enable_screenshot", variant.screenshot);
        opts.addOption(bool, "enable_interact", variant.interact);
        opts.addOption(bool, "enable_outline", variant.outline);
        opts.addOption(bool, "enable_worldmarkers", variant.worldmarkers);
        opts.addOption(bool, "enable_framecrash", variant.framecrash);
        opts.addOption(bool, "enable_logsessions", variant.logsessions);
        opts.addOption(bool, "enable_minimapicons", variant.minimapicons);
        opts.addOption(bool, "enable_transmogfix", variant.transmogfix);
        opts.addOption(bool, "enable_customassets", variant.customassets);
        opts.addOption(bool, "enable_healtextfix", variant.healtextfix);
        opts.addOption(bool, "enable_bigcursor", variant.bigcursor);

        const variant_lib = b.addLibrary(.{
            .name = variant.name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zhook", .module = zhook_mod },
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
