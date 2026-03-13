const std = @import("std");

const ModuleDesc = struct {
    name: []const u8,
    desc: []const u8,
    default: bool = true,
    /// Source directory under src/ (defaults to name if null).
    src_dir: ?[]const u8 = null,
    /// WoW addon folder name. Non-null means this module has an addon/ dir.
    addon_name: ?[]const u8 = null,
    /// If true, addon is hidden from the in-game addon list (always loaded).
    addon_hidden: bool = false,
};

/// Single source of truth for all modules. Adding a module here is enough
/// to wire up the build option, build_options passthrough, and DLL variant.
const module_list = [_]ModuleDesc{
    .{ .name = "pngscreenshots", .desc = "Enable screenshot module", .src_dir = "screenshot" },
    .{ .name = "interact", .desc = "Enable interact module", .addon_name = "Interact" },
    .{ .name = "outline", .desc = "Enable outline module", .default = false, .addon_name = "Outline" },
    .{ .name = "worldmarkers", .desc = "Enable world markers module", .src_dir = "markers", .addon_name = "WorldMarkers", .addon_hidden = true },
    .{ .name = "framecrash", .desc = "Enable framecrash fix", .default = false },
    .{ .name = "logsessions", .desc = "Enable log session rotation", .addon_name = "LogSessions" },
    .{ .name = "minimapicons", .desc = "Enable custom minimap icons", .addon_name = "MinimapIcons" },
    .{ .name = "transmogfix", .desc = "Enable transmog update coalescing" },
    .{ .name = "customassets", .desc = "Enable loose file loading & permissive patch glob" },
    .{ .name = "healtextfix", .desc = "Enable SuperWoW heal text fix" },
    .{ .name = "bigcursor", .desc = "Enable big cursor module" },
    .{ .name = "clickthrough", .desc = "Enable GO click-through (enlarge GO model bounds)" },
    .{ .name = "dpslog", .desc = "Enable structured combat log events for addons", .default = false },
    .{ .name = "transform44", .desc = "Enable transformMatrix4x4 hook", .default = false },
};

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
        .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2 }),
    });
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    addModuleOptions(b, build_options);
    const build_options_module = build_options.createModule();

    const zhook_dep = b.dependency("zhook", .{
        .target = target,
        .optimize = optimize,
    });
    const zhook_mod = zhook_dep.module("zhook");

    // Hot math — separate compilation unit, always ReleaseFast
    const clip_sse_obj = b.addObject(.{
        .name = "clip_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transform44/clip_sse.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

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
    lib.root_module.addObject(clip_sse_obj);
    b.installArtifact(lib);

    // Convenience step to build all single-module variants
    const build_all_step = b.step("all-variants", "Build all DLL variants");

    inline for (module_list) |variant_mod| {
        const opts = b.addOptions();
        inline for (module_list) |m| {
            opts.addOption(bool, "enable_" ++ m.name, std.mem.eql(u8, m.name, variant_mod.name));
        }
        addFileListOptions(b, opts);

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

// =============================================================================
// Build options: enable flags + scanned file lists for each module
// =============================================================================

fn addModuleOptions(b: *std.Build, opts: *std.Build.Step.Options) void {
    inline for (module_list) |mod| {
        opts.addOption(bool, "enable_" ++ mod.name, b.option(bool, mod.name, mod.desc) orelse mod.default);
    }
    addFileListOptions(b, opts);
}

fn addFileListOptions(b: *std.Build, opts: *std.Build.Step.Options) void {
    const a = b.allocator;
    const io = b.graph.io;
    const root = b.build_root.handle;

    for (module_list) |mod| {
        const src_dir = mod.src_dir orelse mod.name;

        // Addon: <module>_addon_name, <module>_addon_hidden, <module>_addon_files
        if (mod.addon_name) |aname| {
            const full_name = std.fmt.allocPrint(a, "WeirdUtils_{s}", .{aname}) catch unreachable;
            opts.addOption([]const u8, std.fmt.allocPrint(a, "{s}_addon_name", .{mod.name}) catch unreachable, full_name);
            opts.addOption(bool, std.fmt.allocPrint(a, "{s}_addon_hidden", .{mod.name}) catch unreachable, mod.addon_hidden);
            const addon_rel = std.fmt.allocPrint(a, "src/{s}/addon", .{src_dir}) catch unreachable;
            const files = listDir(a, io, root, addon_rel);
            var paths: std.ArrayList([]const u8) = .empty;
            for (files) |fname| {
                paths.append(a, std.fmt.allocPrint(a, "{s}/addon/{s}", .{ src_dir, fname }) catch unreachable) catch unreachable;
            }
            opts.addOption([]const []const u8, std.fmt.allocPrint(a, "{s}_addon_files", .{mod.name}) catch unreachable, paths.items);
        }

        // Asset files: <module>_asset_files = ["markers/assets/Spells/foo.m2", ...]
        const assets_rel = std.fmt.allocPrint(a, "src/{s}/assets", .{src_dir}) catch unreachable;
        const asset_files = listAssets(a, io, root, assets_rel, src_dir);
        if (asset_files.len > 0) {
            opts.addOption([]const []const u8, std.fmt.allocPrint(a, "{s}_asset_files", .{mod.name}) catch unreachable, asset_files);
        }
    }
}

fn listDir(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, rel_path: []const u8) []const []const u8 {
    var dir = root.openDir(io, rel_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .file) {
            files.append(a, a.dupe(u8, entry.name) catch unreachable) catch unreachable;
        }
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, aa: []const u8, bb: []const u8) bool {
            return std.mem.order(u8, aa, bb) == .lt;
        }
    }.lt);

    return files.items;
}

/// Walk assets/ recursively, return paths like "markers/assets/Spells/foo.m2"
fn listAssets(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, rel_path: []const u8, src_dir: []const u8) []const []const u8 {
    var dir = root.openDir(io, rel_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = dir.walk(a) catch return &.{};
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        // Only include files in subdirectories (not root of assets/)
        if (std.fs.path.dirname(entry.path) == null) continue;
        paths.append(a, std.fmt.allocPrint(a, "{s}/assets/{s}", .{ src_dir, entry.path }) catch unreachable) catch unreachable;
    }

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, aa: []const u8, bb: []const u8) bool {
            return std.mem.order(u8, aa, bb) == .lt;
        }
    }.lt);

    return paths.items;
}
