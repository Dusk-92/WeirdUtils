const std = @import("std");

const ModuleDesc = struct {
    name: []const u8,
    desc: []const u8,
    version: []const u8 = "1.0",
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
    .{ .name = "pngscreenshots", .version = "1.0", .desc = "Enable screenshot module", .src_dir = "screenshot" },
    .{ .name = "interact", .version = "1.0", .desc = "Enable interact module", .addon_name = "Interact" },
    .{ .name = "outline", .version = "1.0", .desc = "Enable outline module", .default = false, .addon_name = "Outline" },
    .{ .name = "worldmarkers", .version = "1.0", .desc = "Enable world markers module", .addon_name = "WorldMarkers", .addon_hidden = true },
    .{ .name = "framecrash", .version = "1.0", .desc = "Enable framecrash fix", .default = false },
    .{ .name = "logsessions", .version = "1.0", .desc = "Enable log session rotation", .addon_name = "LogSessions" },
    .{ .name = "minimapicons", .version = "1.0", .desc = "Enable custom minimap icons", .addon_name = "MinimapIcons" },
    .{ .name = "transmogfix", .version = "1.0", .desc = "Enable transmog update coalescing" },
    .{ .name = "customassets", .version = "1.0", .desc = "Enable loose file loading & permissive patch glob" },
    .{ .name = "healtextfix", .version = "1.0", .desc = "Enable SuperWoW heal text fix" },
    .{ .name = "bigcursor", .version = "1.0", .desc = "Enable big cursor module" },
    .{ .name = "clickthrough", .version = "1.0", .desc = "Enable GO click-through (enlarge GO model bounds)" },
    .{ .name = "dpslog", .version = "0.1", .desc = "Enable structured combat log events for addons", .default = false },
    .{ .name = "transform44", .version = "1.0", .desc = "Enable transform44 profiling/A/B testing (dev only)", .default = false },
    .{ .name = "addonperf", .version = "1.0", .desc = "Enable addon memory/CPU profiling API", .default = false },
    .{ .name = "ssemaths", .version = "1.0", .desc = "Enable UnitXP x87 math polyfill replacements (SSE)", .default = false },
    .{ .name = "silicon", .version = "1.0", .desc = "Enable SSE2 math replacements (ported from libSiliconPatch)", .default = false },
    .{ .name = "weirdperformance", .version = "1.1", .desc = "Enable production performance optimizations (SSE, inflate, filecache, timer)", .default = true },
};

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
        .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2 }),
    });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    // Resolve module enable flags once (b.option can only be called once per name)
    var module_enabled: [module_list.len]bool = undefined;
    inline for (module_list, 0..) |m, i| {
        module_enabled[i] = b.option(bool, m.name, m.desc) orelse m.default;
    }

    const build_options = b.addOptions();
    addModuleOptionsFromArray(b, build_options, &module_enabled);
    const build_options_module = build_options.createModule();

    const zhook_dep = b.dependency("zhook", .{
        .target = target,
        .optimize = optimize,
    });
    const zhook_mod = zhook_dep.module("zhook");

    // Hot math — separate compilation units, always ReleaseFast.
    // Source lives in src/performance/ — the production SSE module.
    const clip_sse_obj = b.addObject(.{
        .name = "clip_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance/clip_sse.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const cull_sse_obj = b.addObject(.{
        .name = "cull_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance/cull_sse.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const entity_sse_obj = b.addObject(.{
        .name = "entity_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance/entity_sse.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bone_sse_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
        .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2, .sse3, .sse4_1, .fma, .avx }),
    });
    const bone_sse_obj = b.addObject(.{
        .name = "bone_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance/bone_sse.zig"),
            .target = bone_sse_target,
            .optimize = .ReleaseFast,
        }),
    });
    // REF uses x87-only target to match original game code structure.
    // The global target has SSE/SSE2 which generates movss/mulss;
    // the original at 0x714260 uses pure x87 (FLD/FMUL/FSTP).
    const ref_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .abi = .msvc,
        .cpu_features_sub = std.Target.x86.featureSet(&.{ .sse, .sse2 }),
    });
    const bone_sse_ref_obj = b.addObject(.{
        .name = "bone_sse_ref",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transform44/bone_sse_reference.zig"),
            .target = ref_target,
            .optimize = .ReleaseFast,
        }),
    });
    const math_sse_obj = b.addObject(.{
        .name = "math_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ssemaths/math_sse.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const silicon_sse_obj = b.addObject(.{
        .name = "silicon_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance/silicon_sse.zig"),
            .target = bone_sse_target, // SSE4.1+FMA+AVX, same as bone_sse
            .optimize = .ReleaseFast,
        }),
    });

    const particle_sse_obj = b.addObject(.{
        .name = "particle_sse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance/particle_sse.zig"),
            .target = bone_sse_target,
            .optimize = .ReleaseFast,
        }),
    });
    const particle_ref_obj = b.addObject(.{
        .name = "particle_sse_ref",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transform44/particle_sse_reference.zig"),
            .target = bone_sse_target,
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
    // libdeflate (static C lib for inflate_hook)
    const libdeflate = b.addLibrary(.{
        .linkage = .static,
        .name = "deflate",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    libdeflate.root_module.addCSourceFiles(.{
        .files = &.{
            "src/performance/libdeflate/lib/deflate_decompress.c",
            "src/performance/libdeflate/lib/zlib_decompress.c",
            "src/performance/libdeflate/lib/utils.c",
            "src/performance/libdeflate/lib/adler32.c",
            "src/performance/libdeflate/lib/x86/cpu_features.c",
        },
        .flags = &.{"-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI"},
    });
    libdeflate.root_module.addIncludePath(b.path("src/performance/libdeflate/stubs"));
    libdeflate.root_module.addIncludePath(b.path("src/performance/libdeflate"));
    libdeflate.root_module.addIncludePath(b.path("src/performance/libdeflate/lib"));

    // Link module-specific object files into a DLL.
    // Single source of truth for which objects each module needs.
    // Called for both the main weirdutils build and each variant.
    const ModuleObjects = struct {
        clip_sse: *std.Build.Step.Compile,
        cull_sse: *std.Build.Step.Compile,
        entity_sse: *std.Build.Step.Compile,
        bone_sse: *std.Build.Step.Compile,
        bone_sse_ref: *std.Build.Step.Compile,
        math_sse: *std.Build.Step.Compile,
        silicon_sse: *std.Build.Step.Compile,
        particle_sse: *std.Build.Step.Compile,
        particle_ref: *std.Build.Step.Compile,
        libdeflate: *std.Build.Step.Compile,

        fn linkFor(self: @This(), mod: *std.Build.Module, comptime module_name: []const u8) void {
            @setEvalBranchQuota(10000);
            if (comptime std.mem.eql(u8, module_name, "weirdperformance")) {
                mod.addObject(self.clip_sse);
                mod.addObject(self.cull_sse);
                mod.addObject(self.bone_sse);
                mod.addObject(self.silicon_sse);
                mod.addObject(self.particle_sse);
                mod.addObjectFile(self.libdeflate.getEmittedBin());
            }
            if (comptime std.mem.eql(u8, module_name, "transform44")) {
                mod.addObject(self.clip_sse);
                mod.addObject(self.cull_sse);
                mod.addObject(self.entity_sse);
                mod.addObject(self.bone_sse);
                mod.addObject(self.bone_sse_ref);
                mod.addObject(self.particle_sse);
                mod.addObject(self.particle_ref);
            }
            if (comptime std.mem.eql(u8, module_name, "silicon")) {
                mod.addObject(self.silicon_sse);
            }
            if (comptime std.mem.eql(u8, module_name, "ssemaths")) {
                mod.addObject(self.math_sse);
            }
        }
    };
    const objs = ModuleObjects{
        .clip_sse = clip_sse_obj,
        .cull_sse = cull_sse_obj,
        .entity_sse = entity_sse_obj,
        .bone_sse = bone_sse_obj,
        .bone_sse_ref = bone_sse_ref_obj,
        .math_sse = math_sse_obj,
        .silicon_sse = silicon_sse_obj,
        .particle_sse = particle_sse_obj,
        .particle_ref = particle_ref_obj,
        .libdeflate = libdeflate,
    };

    // Main DLL: link all module objects
    inline for (module_list) |mod| {
        objs.linkFor(lib.root_module, mod.name);
    }

    b.installArtifact(lib);

    // Benchmark harness — native x86 Linux executable for profiling SSE replacements
    {
        const bench_target = b.resolveTargetQuery(.{
            .cpu_arch = .x86,
            .os_tag = .linux,
            .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2 }),
        });
        const bench_math_sse = b.addObject(.{
            .name = "bench_math_sse",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ssemaths/math_sse.zig"),
                .target = bench_target,
                .optimize = .ReleaseFast,
            }),
        });
        const bench_optimize = b.option(std.builtin.OptimizeMode, "bench-opt", "Bench optimization (default: ReleaseFast)") orelse .ReleaseFast;
        const bench = b.addExecutable(.{
            .name = "bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bench/main.zig"),
                .target = bench_target,
                .optimize = bench_optimize,
            }),
        });
        // Link at high address so WoW PE sections (0x400000-0xD00000) can be
        // mapped at their original virtual addresses for benchmarking.
        bench.image_base = 0x10000000;
        const bench_silicon_sse = b.addObject(.{
            .name = "bench_silicon_sse",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/performance/silicon_sse.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .x86,
                    .os_tag = .linux,
                    .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2, .sse3, .sse4_1, .fma, .avx }),
                }),
                .optimize = .ReleaseFast,
            }),
        });
        const bench_bone_sse = b.addObject(.{
            .name = "bench_bone_sse",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/performance/bone_sse.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .x86,
                    .os_tag = .linux,
                    .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2, .sse3, .sse4_1, .fma, .avx }),
                }),
                .optimize = .ReleaseFast,
            }),
        });
        const bench_bone_baseline = b.addObject(.{
            .name = "bench_bone_baseline",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/transform44/bone_sse_baseline.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .x86,
                    .os_tag = .linux,
                    .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2, .sse3, .sse4_1, .fma, .avx }),
                }),
                .optimize = .ReleaseFast,
            }),
        });
        const bench_particle_sse = b.addObject(.{
            .name = "bench_particle_sse",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/performance/particle_sse.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = .x86,
                    .os_tag = .linux,
                    .cpu_features_add = std.Target.x86.featureSet(&.{ .sse, .sse2, .sse3, .sse4_1, .fma, .avx }),
                }),
                .optimize = .ReleaseFast,
            }),
        });
        const bench_cull_sse = b.addObject(.{
            .name = "bench_cull_sse",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/performance/cull_sse.zig"),
                .target = bench_target,
                .optimize = .ReleaseFast,
            }),
        });
        bench.root_module.addObject(bench_math_sse);
        bench.root_module.addObject(bench_silicon_sse);
        bench.root_module.addObject(bench_bone_sse);
        bench.root_module.addObject(bench_bone_baseline);
        bench.root_module.addObject(bench_particle_sse);
        bench.root_module.addObject(bench_cull_sse);
        const bench_entity_sse = b.addObject(.{
            .name = "bench_entity_sse",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/performance/entity_sse.zig"),
                .target = bench_target,
                .optimize = .ReleaseFast,
            }),
        });
        bench.root_module.addObject(bench_entity_sse);
        bench.root_module.linkSystemLibrary("m", .{});
        const install_bench = b.addInstallArtifact(bench, .{});
        const bench_step = b.step("bench", "Build math_sse benchmark harness (x86 Linux)");
        bench_step.dependOn(&install_bench.step);

        const run_bench = b.addRunArtifact(bench);
        const run_step = b.step("run-bench", "Build and run math_sse benchmark");
        run_step.dependOn(&run_bench.step);
    }

    // Build combined DLL without performance module
    const noperf_install = noperf_blk: {
        const noperf_step = b.step("noperf", "Build weirdutils_noperf.dll (no performance module)");
        const noperf_opts = b.addOptions();
        var noperf_enabled = module_enabled;
        // Force weirdperformance off
        inline for (module_list, 0..) |m, i| {
            if (comptime std.mem.eql(u8, m.name, "weirdperformance")) noperf_enabled[i] = false;
        }
        addModuleOptionsFromArray(b, noperf_opts, &noperf_enabled);

        const noperf_lib = b.addLibrary(.{
            .name = "weirdutils_noperf",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zhook", .module = zhook_mod },
                    .{ .name = "build_options", .module = noperf_opts.createModule() },
                },
            }),
        });
        const noperf_install = b.addInstallArtifact(noperf_lib, .{
            .dest_dir = .{ .override = .{ .custom = "variants" } },
        });
        noperf_step.dependOn(&noperf_install.step);
        break :noperf_blk noperf_install;
    };

    // Convenience step to build all single-module variants
    const build_all_step = b.step("all-variants", "Build all DLL variants");
    build_all_step.dependOn(&noperf_install.step);

    inline for (module_list) |variant_mod| {
        @setEvalBranchQuota(10000);
        const opts = b.addOptions();
        inline for (module_list) |m| {
            opts.addOption(bool, "enable_" ++ m.name, std.mem.eql(u8, m.name, variant_mod.name));
        }
        addFileListOptions(b, opts);
        // Variant builds also need the module name list for addons.zig
        const names: []const []const u8 = comptime blk: {
            var n: [module_list.len][]const u8 = undefined;
            for (module_list, 0..) |m2, mi| n[mi] = m2.name;
            const final = n;
            break :blk &final;
        };
        opts.addOption([]const []const u8, "all_module_names", names);
        const versions: []const []const u8 = comptime blk: {
            var v: [module_list.len][]const u8 = undefined;
            for (module_list, 0..) |m2, mi| v[mi] = m2.version;
            const final = v;
            break :blk &final;
        };
        opts.addOption([]const []const u8, "all_module_versions", versions);

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

        objs.linkFor(variant_lib.root_module, variant_mod.name);

        const install_variant = b.addInstallArtifact(variant_lib, .{
            .dest_dir = .{ .override = .{ .custom = "variants" } },
        });
        build_all_step.dependOn(&install_variant.step);
    }
}

// =============================================================================
// Build options: enable flags + scanned file lists for each module
// =============================================================================

fn addModuleOptionsFromArray(b: *std.Build, opts: *std.Build.Step.Options, enabled: *const [module_list.len]bool) void {
    inline for (module_list, 0..) |mod, i| {
        opts.addOption(bool, "enable_" ++ mod.name, enabled[i]);
    }
    // Pass full module name/version lists so main.zig/addons.zig can use them at comptime
    const names: []const []const u8 = comptime blk: {
        var n: [module_list.len][]const u8 = undefined;
        for (module_list, 0..) |mod, i| n[i] = mod.name;
        const final = n;
        break :blk &final;
    };
    opts.addOption([]const []const u8, "all_module_names", names);
    const versions: []const []const u8 = comptime blk: {
        var v: [module_list.len][]const u8 = undefined;
        for (module_list, 0..) |mod, i| v[i] = mod.version;
        const final = v;
        break :blk &final;
    };
    opts.addOption([]const []const u8, "all_module_versions", versions);
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
