// =============================================================================
// Embedded addon file management
// =============================================================================
//
// Comptime-built table of embedded addon/asset files, plus hooks for addon
// registration (SetupAddonProcessing) and loading (LoadAddonsRecursively).
//
// Modules declare their addon files via embed_modules. The is_active callback
// gates addon loading on mutex ownership — if another DLL instance owns the
// module, we don't load its addon.
//
// =============================================================================

const std = @import("std");
const hook = @import("zhook");
const con = @import("console.zig");
const build_options = @import("build_options");


// Build option convenience aliases
const build_opts = struct {
    const interact = build_options.enable_interact;
    const outline = build_options.enable_outline;
    const worldmarkers = build_options.enable_worldmarkers;
    const logsessions = build_options.enable_logsessions;
    const minimapicons = build_options.enable_minimapicons;
};

// Conditional module imports (only for is_active callbacks)
const interact = if (build_opts.interact) @import("interact/interact.zig") else struct {};
const outline = if (build_opts.outline) @import("outline/api.zig") else struct {};
const markers = if (build_opts.worldmarkers) @import("markers/markers.zig") else struct {};
const logsessions = if (build_opts.logsessions) @import("logsessions/logsessions.zig") else struct {};
const minimapicons = if (build_opts.minimapicons) @import("minimapicons/minimapicons.zig") else struct {};

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
};

/// Module descriptor for compile-time embed generation.
const EmbedModule = struct {
    option: []const u8,
    addon_name: ?[]const u8 = null,
    addon_files_opt: ?[]const u8 = null,
    asset_files_opt: ?[]const u8 = null,
    /// If true, addon is hidden from addon list, always loaded.
    hidden: bool = false,
    /// Runtime check — addon is only loaded if this returns true.
    /// Null means always load (when compiled in).
    is_active: ?*const fn () bool = null,
};

const embed_modules = [_]EmbedModule{
    .{ .option = "interact", .addon_name = "WeirdUtils_Interact", .addon_files_opt = "interact_addon_files", .is_active = if (build_opts.interact) &interact.isActive else null },
    .{ .option = "outline", .addon_name = "WeirdUtils_Outline", .addon_files_opt = "outline_addon_files", .is_active = if (build_opts.outline) &outline.isActive else null },
    .{ .option = "worldmarkers", .addon_name = "WeirdUtils_WorldMarkers", .addon_files_opt = "worldmarkers_addon_files", .asset_files_opt = "worldmarkers_asset_files", .hidden = true, .is_active = if (build_opts.worldmarkers) &markers.isActive else null },
    .{ .option = "logsessions", .addon_name = "WeirdUtils_LogSessions", .addon_files_opt = "logsessions_addon_files", .is_active = if (build_opts.logsessions) &logsessions.isActive else null },
    .{ .option = "minimapicons", .addon_name = "WeirdUtils_MinimapIcons", .addon_files_opt = "minimapicons_addon_files", .asset_files_opt = "minimapicons_asset_files", .is_active = if (build_opts.minimapicons) &minimapicons.isActive else null },
};

// =============================================================================
// Comptime path helpers
// =============================================================================

fn comptimeBasename(comptime path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

/// Extract WoW-style parent directory: "markers/assets/Spells/foo.m2" with
/// assets_prefix="markers/assets/" → "Spells\\"
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

/// Derive the assets/ path prefix from the option name pattern.
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

fn appendAssetPrefixes(result: anytype, start_idx: usize, comptime paths: []const []const u8, comptime assets_prefix: []const u8) usize {
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
            result[idx] = .{ .prefix = dir, .files = &final_files };
            idx += 1;
        }
        return idx;
    }
}

fn buildAllPrefixes() []const AddonPrefix {
    @setEvalBranchQuota(50000);
    comptime {
        var count: usize = 0;
        for (embed_modules) |mod| {
            if (!@field(build_options, "enable_" ++ mod.option)) continue;
            if (mod.addon_files_opt) |opt| {
                if (@field(build_options, opt).len > 0) count += 1;
            }
            if (mod.asset_files_opt) |opt| {
                const asset_paths = @field(build_options, opt);
                if (asset_paths.len > 0) {
                    const pfx = assetsPrefixFromOpt(opt);
                    count += countUniqueAssetDirs(asset_paths, pfx);
                }
            }
        }

        var result: [count]AddonPrefix = undefined;
        var idx: usize = 0;
        for (embed_modules) |mod| {
            if (!@field(build_options, "enable_" ++ mod.option)) continue;
            if (mod.addon_files_opt) |opt| {
                const paths = @field(build_options, opt);
                if (paths.len > 0) {
                    const files = embedFiles(paths);
                    result[idx] = .{
                        .prefix = "Interface\\AddOns\\" ++ mod.addon_name.? ++ "\\",
                        .files = &files,
                    };
                    idx += 1;
                }
            }
            if (mod.asset_files_opt) |opt| {
                const asset_paths = @field(build_options, opt);
                if (asset_paths.len > 0) {
                    const pfx = assetsPrefixFromOpt(opt);
                    idx = appendAssetPrefixes(&result, idx, asset_paths, pfx);
                }
            }
        }
        const final = result;
        return &final;
    }
}

const addon_prefixes = buildAllPrefixes();

// =============================================================================
// Embedded file lookup
// =============================================================================

pub fn findEmbeddedFile(path: [*:0]const u8) ?*const FileEntry {
    const path_span = std.mem.span(path);

    for (addon_prefixes) |*addon| {
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

    inline for (embed_modules) |mod| {
        if (comptime mod.addon_name == null) continue;
        if (!@field(build_options, "enable_" ++ mod.option)) continue;

        const active = if (mod.is_active) |f| f() else true;
        if (active) {
            const name: [*:0]const u8 = comptime (mod.addon_name.? ++ "\x00").ptr;
            con.fmt("[addons] registering embedded addon: {s}\n", .{name});
            callLoadAddonTOC(name);

            if (mod.hidden) {
                hideAddonFromList(name);
            }
        }
    }
}

/// Find an addon struct in the linked list by name and set +0x29 to 1,
/// which excludes it from the flat display array built by DeserializeAddonData.
fn hideAddonFromList(name: [*:0]const u8) void {
    // Walk the addon linked list (PTR_00be1b6c). Each node has:
    //   +0x14: name pointer
    //   next: *(PTR_00be1b64 + 4 + node)
    const list_base = hook.readMem(u32, 0x00be1b64);
    var node = hook.readMem(u32, 0x00be1b6c);
    while (node != 0 and (node & 1) == 0) {
        const node_name = hook.readMem([*:0]const u8, node + 0x14);
        if (std.mem.orderZ(u8, node_name, name) == .eq) {
            hook.writeMem(node + 0x29, &[_]u8{1});
            con.fmt("[addons] hidden addon {s} excluded from list (+0x29=1)\n", .{name});
            return;
        }
        node = hook.readMem(u32, list_base + 4 + node);
    }
    con.fmt("[addons] WARNING: could not find {s} in addon list\n", .{name});
}

fn callLoadAddonTOC(addon_name: [*:0]const u8) void {
    hook.call(fn ([*:0]const u8) callconv(hook.cc.fastcall) void, 0x0051c9b0, .{addon_name});
}

// =============================================================================
// Install / Remove
// =============================================================================

/// True if any embed_modules entry has addon files compiled in.
const has_addons = blk: {
    for (embed_modules) |mod| {
        if (mod.addon_name != null and @field(build_options, "enable_" ++ mod.option))
            break :blk true;
    }
    break :blk false;
};

pub fn install() void {
    if (!has_addons) return;
    _ = setup_addons_hook.attach(0x51C740, &setupAddonsDetour);
}

pub fn uninstall() void {
    if (!has_addons) return;
    setup_addons_hook.detach();
}
