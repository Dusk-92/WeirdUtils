// =============================================================================
// Embedded addon file management
// =============================================================================
//
// Comptime-built table of embedded addon/asset files, plus hooks for addon
// registration (SetupAddonProcessing) and loading (LoadAddonsRecursively).
//
// All addon configuration is driven by build.zig (single source of truth).
// Build options per module: {name}_addon_name, {name}_addon_hidden,
// {name}_addon_files, {name}_asset_files. This file derives everything from
// those options — no hardcoded module list.
//
// The is_active callback is wired by convention: each module that exports
// pub fn isActive() bool gets called at runtime to gate addon loading.
//
// =============================================================================

const std = @import("std");
const hook = @import("zhook");
const logging = @import("logging.zig");
var log: logging.Logger = .{};
const build_options = @import("build_options");

// =============================================================================
// Module list — derived from build.zig via all_module_names build option.
// Convention: each module's main source is at {name}/{name}.zig.
// =============================================================================

const module_names = build_options.all_module_names;

// =============================================================================
// is_active wiring — runtime registry populated by main.zig during install().
// No per-module imports needed here; adding addon_name in build.zig is enough.
// =============================================================================

const module_active = @import("module_active.zig");

// =============================================================================
// Embedded file types
// =============================================================================

pub const FileEntry = struct {
    name: []const u8,
    data: []const u8,
};

const AddonPrefix = struct {
    prefix: []const u8,
    files: []const FileEntry,
    /// Module name for runtime isActive gating. Null = always serve.
    module_name: ?[*:0]const u8 = null,
};

// =============================================================================
// Comptime helpers
// =============================================================================

fn comptimeBasename(comptime path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

fn comptimeWowDir(comptime path: []const u8, comptime assets_prefix: []const u8) []const u8 {
    const rel = path[assets_prefix.len..];
    var last_slash: usize = 0;
    var found = false;
    for (rel, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found = true;
        }
    }
    if (!found) return "";
    const dir = rel[0..last_slash];
    return comptime blk: {
        var buf: [dir.len + 1]u8 = undefined;
        for (dir, 0..) |c, i| {
            buf[i] = if (c == '/') '\\' else c;
        }
        buf[dir.len] = '\\';
        const final = buf;
        break :blk &final;
    };
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn embedFiles(comptime paths: []const []const u8) [paths.len]FileEntry {
    comptime {
        var entries: [paths.len]FileEntry = undefined;
        for (paths, 0..) |path, i| {
            entries[i] = .{
                .name = comptimeBasename(path),
                .data = @embedFile(path),
            };
        }
        const final = entries;
        return final;
    }
}

fn assetsPrefixFromOpt(comptime opt: []const u8) []const u8 {
    const paths = @field(build_options, opt);
    const first = paths[0];
    for (first, 0..) |_, i| {
        if (i + 8 <= first.len and eqlSlice(first[i .. i + 8], "/assets/")) {
            return first[0 .. i + 8];
        }
    }
    return first;
}

fn countUniqueAssetDirs(comptime paths: []const []const u8, comptime assets_prefix: []const u8) usize {
    var dirs: [paths.len][]const u8 = undefined;
    var n: usize = 0;
    for (paths) |path| {
        const dir = comptimeWowDir(path, assets_prefix);
        if (dir.len == 0) continue;
        var found = false;
        for (dirs[0..n]) |d| {
            if (eqlSlice(d, dir)) {
                found = true;
                break;
            }
        }
        if (!found) {
            dirs[n] = dir;
            n += 1;
        }
    }
    return n;
}

fn appendAssetPrefixes(result: anytype, start_idx: usize, comptime paths: []const []const u8, comptime assets_prefix: []const u8, comptime mod_name: ?[*:0]const u8) usize {
    comptime {
        var dirs: [paths.len][]const u8 = undefined;
        var n_dirs: usize = 0;
        for (paths) |path| {
            const dir = comptimeWowDir(path, assets_prefix);
            if (dir.len == 0) continue;
            var found = false;
            for (dirs[0..n_dirs]) |d| {
                if (eqlSlice(d, dir)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                dirs[n_dirs] = dir;
                n_dirs += 1;
            }
        }

        var idx = start_idx;
        for (dirs[0..n_dirs]) |dir| {
            var file_count: usize = 0;
            for (paths) |path| {
                if (eqlSlice(comptimeWowDir(path, assets_prefix), dir)) file_count += 1;
            }
            var files: [file_count]FileEntry = undefined;
            var fi: usize = 0;
            for (paths) |path| {
                if (eqlSlice(comptimeWowDir(path, assets_prefix), dir)) {
                    files[fi] = .{ .name = comptimeBasename(path), .data = @embedFile(path) };
                    fi += 1;
                }
            }
            const final_files = files;
            result[idx] = .{ .prefix = dir, .files = &final_files, .module_name = mod_name };
            idx += 1;
        }
        return idx;
    }
}

/// Check if a module has an addon (addon_name build option exists and is non-empty).
fn hasAddon(comptime name: []const u8) bool {
    if (!@hasDecl(build_options, name ++ "_addon_name")) return false;
    return @field(build_options, name ++ "_addon_name").len > 0;
}

/// Get addon file paths for a module (empty if no addon or no files).
fn getAddonFiles(comptime name: []const u8) []const []const u8 {
    if (!@hasDecl(build_options, name ++ "_addon_files")) return &.{};
    return @field(build_options, name ++ "_addon_files");
}

/// Get asset file paths for a module (empty if no assets).
fn getAssetFiles(comptime name: []const u8) []const []const u8 {
    if (!@hasDecl(build_options, name ++ "_asset_files")) return &.{};
    return @field(build_options, name ++ "_asset_files");
}

/// Get hidden flag for a module.
fn isHidden(comptime name: []const u8) bool {
    if (!@hasDecl(build_options, name ++ "_addon_hidden")) return false;
    return @field(build_options, name ++ "_addon_hidden");
}

// =============================================================================
// Build the addon prefix table from build options
// =============================================================================

fn buildAllPrefixes() []const AddonPrefix {
    @setEvalBranchQuota(50000);
    comptime {
        // Count entries
        var count: usize = 0;
        for (module_names) |name| {
            if (!@field(build_options, "enable_" ++ name)) continue;
            if (!hasAddon(name)) continue;
            const addon_files = getAddonFiles(name);
            if (addon_files.len > 0) count += 1;
            const asset_files = getAssetFiles(name);
            if (asset_files.len > 0) {
                const pfx = assetsPrefixFromOpt(name ++ "_asset_files");
                count += countUniqueAssetDirs(asset_files, pfx);
            }
        }

        var result: [count]AddonPrefix = undefined;
        var idx: usize = 0;
        for (module_names) |name| {
            if (!@field(build_options, "enable_" ++ name)) continue;
            if (!hasAddon(name)) continue;
            const addon_name = @field(build_options, name ++ "_addon_name");
            const addon_files = getAddonFiles(name);
            const name_z: [*:0]const u8 = (name ++ "\x00").ptr;
            if (addon_files.len > 0) {
                const files = embedFiles(addon_files);
                result[idx] = .{
                    .prefix = "Interface\\AddOns\\" ++ addon_name ++ "\\",
                    .files = &files,
                    .module_name = name_z,
                };
                idx += 1;
            }
            const asset_files = getAssetFiles(name);
            if (asset_files.len > 0) {
                const pfx = assetsPrefixFromOpt(name ++ "_asset_files");
                idx = appendAssetPrefixes(&result, idx, asset_files, pfx, name_z);
            }
        }
        const final = result;
        return &final;
    }
}

const all_prefixes = buildAllPrefixes();

// =============================================================================
// Runtime-pruned prefix table — only includes prefixes for modules that own
// their mutex. Built once in install() after all modules have claimed mutexes.
// findEmbeddedFile searches only this table, no per-lookup isActive checks.
// =============================================================================

var active_prefixes: [all_prefixes.len]*const AddonPrefix = undefined;
var active_count: usize = 0;

pub fn pruneInactivePrefixes() void {
    active_count = 0;
    for (all_prefixes) |*prefix| {
        const active = if (prefix.module_name) |mod_name| module_active.isActive(mod_name) else true;
        if (active) {
            active_prefixes[active_count] = prefix;
            active_count += 1;
        }
    }
    log.fmt("addon prefixes: {d}/{d} active\n", .{ active_count, all_prefixes.len });
}

// =============================================================================
// Embedded file lookup — searches only active (mutex-owning) prefixes.
// =============================================================================

pub fn findEmbeddedFile(path: [*:0]const u8) ?*const FileEntry {
    const path_span = std.mem.span(path);

    for (active_prefixes[0..active_count]) |addon| {
        if (path_span.len <= addon.prefix.len) continue;

        // Case-insensitive prefix check
        var prefix_match = true;
        for (path_span[0..addon.prefix.len], addon.prefix) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) {
                prefix_match = false;
                break;
            }
        }
        if (!prefix_match) continue;

        const relative = path_span[addon.prefix.len..];
        for (addon.files) |*entry| {
            if (relative.len != entry.name.len) continue;
            var match = true;
            for (relative, entry.name) |a, b| {
                const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
                const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (la != lb) {
                    match = false;
                    break;
                }
            }
            if (match) return entry;
        }
    }
    return null;
}

// =============================================================================
// Hook: SetupAddonProcessing (0x51C740)
// Called during HandleLogin. After the original runs (which scans
// Interface\AddOns\ on the filesystem), we call LoadAddonTOC for each
// DLL-embedded addon to register them in the game's addon hash table.
// =============================================================================

var setup_addons_hook: hook.Detour(fn (u32) callconv(hook.cc.fastcall) void) = .{};

fn setupAddonsDetour(mgr_ptr: u32) callconv(hook.cc.fastcall) void {
    setup_addons_hook.callOriginal(.{mgr_ptr});

    // Register addons only for active (mutex-owning) modules.
    // Use the pruned prefix table — each addon prefix with files corresponds
    // to an Interface\AddOns\ entry. We match by module_name to find which
    // addon_name to register.
    inline for (module_names) |name| {
        if (!@field(build_options, "enable_" ++ name)) continue;
        if (comptime !hasAddon(name)) continue;
        if (comptime getAddonFiles(name).len == 0) continue;

        const module_name_z: [*:0]const u8 = comptime (name ++ "\x00").ptr;
        // Check if this module survived pruning (i.e., owns its mutex)
        const is_active = for (active_prefixes[0..active_count]) |p| {
            if (p.module_name) |mn| {
                if (std.mem.orderZ(u8, mn, module_name_z) == .eq) break true;
            }
        } else false;

        if (is_active) {
            const addon_name = comptime @field(build_options, name ++ "_addon_name");
            const name_z: [*:0]const u8 = comptime (addon_name ++ "\x00").ptr;
            log.fmt("registering embedded addon: {s}\n", .{name_z});
            callLoadAddonTOC(name_z);

            if (comptime isHidden(name)) {
                hideAddonFromList(name_z);
            }
        }
    }
}

/// Find an addon struct in the linked list by name and set +0x29 to 1,
/// which excludes it from the flat display array built by DeserializeAddonData.
fn hideAddonFromList(name: [*:0]const u8) void {
    const list_base = hook.readMem(u32, 0x00be1b64);
    var node = hook.readMem(u32, 0x00be1b6c);
    while (node != 0 and (node & 1) == 0) {
        const node_name = hook.readMem([*:0]const u8, node + 0x14);
        if (std.mem.orderZ(u8, node_name, name) == .eq) {
            hook.writeMem(node + 0x29, &[_]u8{1});
            log.fmt("hidden addon {s} excluded from list (+0x29=1)\n", .{name});
            return;
        }
        node = hook.readMem(u32, list_base + 4 + node);
    }
    log.fmt("WARNING: could not find {s} in addon list\n", .{name});
}

fn callLoadAddonTOC(addon_name: [*:0]const u8) void {
    hook.call(fn ([*:0]const u8) callconv(hook.cc.fastcall) void, 0x0051c9b0, .{addon_name});
}

// =============================================================================
// Install / Remove
// =============================================================================

/// True if any module has embedded addon files compiled in.
const has_addons = blk: {
    for (module_names) |name| {
        if (@field(build_options, "enable_" ++ name) and hasAddon(name) and getAddonFiles(name).len > 0)
            break :blk true;
    }
    break :blk false;
};

pub fn install() void {
    if (!has_addons) return;
    log = logging.Logger.open("addons", .console);
    pruneInactivePrefixes();
    _ = setup_addons_hook.attach(0x51C740, &setupAddonsDetour);
}

pub fn uninstall() void {
    if (!has_addons) return;
    setup_addons_hook.detach();
}
