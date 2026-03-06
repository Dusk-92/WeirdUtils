const std = @import("std");

const ModuleDesc = struct {
    name: []const u8,
    desc: []const u8,
    default: bool = true,
};

/// Single source of truth for all modules. Adding a module here is enough
/// to wire up the build option, build_options passthrough, and DLL variant.
const module_list = [_]ModuleDesc{
    .{ .name = "screenshot", .desc = "Enable screenshot module" },
    .{ .name = "interact", .desc = "Enable interact module" },
    .{ .name = "outline", .desc = "Enable outline module", .default = false },
    .{ .name = "worldmarkers", .desc = "Enable world markers module" },
    .{ .name = "framecrash", .desc = "Enable framecrash fix", .default = false },
    .{ .name = "logsessions", .desc = "Enable log session rotation" },
    .{ .name = "minimapicons", .desc = "Enable custom minimap icons" },
    .{ .name = "transmogfix", .desc = "Enable transmog update coalescing" },
    .{ .name = "customassets", .desc = "Enable loose file loading & permissive patch glob" },
    .{ .name = "healtextfix", .desc = "Enable SuperWoW heal text fix" },
    .{ .name = "bigcursor", .desc = "Enable big cursor module" },
    .{ .name = "dpslog", .desc = "Enable structured combat log events for addons", .default = false },
};

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{});

    // Build options for conditional module compilation
    const build_options = b.addOptions();
    inline for (module_list) |mod| {
        build_options.addOption(bool, "enable_" ++ mod.name, b.option(bool, mod.name, mod.desc) orelse mod.default);
    }
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

    inline for (module_list) |variant_mod| {
        const opts = b.addOptions();
        inline for (module_list) |m| {
            opts.addOption(bool, "enable_" ++ m.name, std.mem.eql(u8, m.name, variant_mod.name));
        }

        const variant_lib = b.addLibrary(.{
            .name = variant_mod.name,
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
