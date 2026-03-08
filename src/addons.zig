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

const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

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

var setup_addons_hook: hook.Detour(fn (u32) callconv(fc) void) = .{};

fn setupAddonsDetour(mgr_ptr: u32) callconv(fc) void {
    setup_addons_hook.callOriginal(.{mgr_ptr});

    inline for (embed_modules) |mod| {
        if (comptime mod.addon_name == null) continue;
        if (!@field(build_options, "enable_" ++ mod.option)) continue;

        if (mod.hidden) continue;

        const active = if (mod.is_active) |f| f() else true;
        if (active) {
            const name: [*:0]const u8 = comptime (mod.addon_name.? ++ "\x00").ptr;
            con.fmt("[addons] registering embedded addon: {s}\n", .{name});
            callLoadAddonTOC(name);
        }
    }
}

fn callLoadAddonTOC(addon_name: [*:0]const u8) void {
    asm volatile (
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(addon_name)),
          [func] "{eax}" (@as(u32, 0x0051c9b0)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Hook: LoadAddonsRecursively (0x51F600)
// Non-hidden addons are fully handled by the game's LoadAddonRecursive (which
// respects enabled/disabled state) — the CheckFileExistence hook in main.zig
// makes their embedded files visible to preloadFileWithFlags. Hidden addons
// bypass LoadAddonRecursive, so we load their TOC and bindings explicitly here.
// =============================================================================

var load_addons_hook: hook.Detour(fn (u32) callconv(fc) void) = .{};

fn loadAddonsDetour(error_handler: u32) callconv(fc) void {
    load_addons_hook.callOriginal(.{error_handler});

    var md5ctx = std.mem.zeroes([88]u8);

    inline for (embed_modules) |mod| {
        if (comptime mod.addon_name != null and
            @field(build_options, "enable_" ++ mod.option) and
            mod.hidden)
        {
            const active = if (mod.is_active) |f| f() else true;
            if (active) {
                const addon_name = comptime mod.addon_name.?;
                const paths = comptime @field(build_options, mod.addon_files_opt.?);

                // Hidden addons are not registered via LoadAddonTOC, so the game
                // doesn't know about them. Load their files directly to keep them
                // invisible in the addon list.
                const toc_name = comptime findTocName(paths);
                if (toc_name) |tn| {
                    callLoadFileListWithIncludes(
                        "Interface\\AddOns\\" ++ addon_name ++ "\\" ++ tn,
                        &md5ctx,
                        error_handler,
                    );
                }

                // Hidden addons bypass LoadAddonRecursive, so load bindings
                // explicitly. Non-hidden addons get theirs loaded by the game
                // (which respects addon enabled/disabled state).
                if (comptime hasFile(paths, "Bindings.xml")) {
                    callLoadUIBindingsFromFile(
                        "Interface\\AddOns\\" ++ addon_name ++ "\\Bindings.xml",
                        &md5ctx,
                        error_handler,
                    );
                }
            }
        }
    }
}

fn findTocName(comptime paths: []const []const u8) ?[]const u8 {
    for (paths) |path| {
        const name = comptimeBasename(path);
        if (name.len >= 4 and eqlSlice(name[name.len - 4 ..], ".toc")) return name;
    }
    return null;
}

fn hasFile(comptime paths: []const []const u8, comptime target: []const u8) bool {
    for (paths) |path| {
        if (eqlSlice(comptimeBasename(path), target)) return true;
    }
    return false;
}

fn callLoadFileListWithIncludes(toc_path: [*:0]const u8, md5ctx: *[88]u8, error_handler: u32) void {
    asm volatile (
        \\push %[eh]
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(toc_path)),
          [_] "{edx}" (@intFromPtr(md5ctx)),
          [eh] "r" (error_handler),
          [func] "r" (@as(u32, 0x6EDB90)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

fn callLoadUIBindingsFromFile(path: [*:0]const u8, md5ctx: *[88]u8, callback: u32) void {
    const binding_mgr = hook.readMem(u32, 0xB71290);
    asm volatile (
        \\push %[cb]
        \\push %[md5]
        \\push %[path]
        \\call *%[func]
        :
        : [_] "{ecx}" (binding_mgr),
          [func] "{edx}" (@as(u32, 0x4B6F70)),
          [path] "r" (@intFromPtr(path)),
          [md5] "r" (@intFromPtr(md5ctx)),
          [cb] "r" (callback),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
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
    _ = load_addons_hook.attach(0x51F600, &loadAddonsDetour);
}

pub fn uninstall() void {
    if (!has_addons) return;
    load_addons_hook.detach();
    setup_addons_hook.detach();
}
