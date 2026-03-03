// =============================================================================
// looseassets - Loose file loading & permissive patch glob
// =============================================================================
//
// 1. Patches patch-?.MPQ → patch-*.MPQ so multi-char patch names work
// 2. NOPs two gates in File_FindInArchive so CheckFileExistence runs for
//    all files, not just Interface/AddOns
// 3. Hooks CheckFileExistence with an O(1) hash set of pre-indexed loose
//    files so non-existent files skip GetFileAttributesA entirely
//
// =============================================================================

const std = @import("std");
const hook = @import("zhook");
const con = @import("../console.zig");

// =============================================================================
// Windows API (project-specific — not in hook lib)
// =============================================================================

const WINAPI = std.builtin.CallingConvention.winapi;

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const INVALID_HANDLE: usize = 0xFFFFFFFF;
const MAX_PATH: usize = 260;

extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(WINAPI) u32;
extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(WINAPI) u32;
extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) callconv(WINAPI) usize;
extern "kernel32" fn FindNextFileA(hFindFile: usize, lpFindFileData: *WIN32_FIND_DATAA) callconv(WINAPI) i32;
extern "kernel32" fn FindClose(hFindFile: usize) callconv(WINAPI) i32;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

const FILETIME = extern struct { low: u32, high: u32 };

const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [MAX_PATH]u8,
    cAlternateFileName: [14]u8,
};

// =============================================================================
// Loose file hash map
// =============================================================================

var arena: std.heap.ArenaAllocator = undefined;
var loose_files: std.StringHashMapUnmanaged([]const u8) = .empty;
var wow_dir_len: usize = 0;

fn normalizeCopy(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        out[i] = if (c == '/') '\\' else if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return out;
}

fn normalizeInPlace(buf: []u8) void {
    for (buf) |*c| {
        if (c.* == '/') c.* = '\\' else if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
}

fn isMpq(name: []const u8) bool {
    if (name.len < 4) return false;
    var ext: [4]u8 = undefined;
    for (name[name.len - 4 ..], 0..) |c, i| {
        ext[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return std.mem.eql(u8, &ext, ".mpq");
}

fn cStrLen(ptr: [*]const u8) usize {
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {}
    return i;
}

fn scanDirectory(full_path: []const u8, base_dir_len: usize) void {
    const alloc = arena.allocator();

    var search_buf: [MAX_PATH]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "{s}\\*", .{full_path}) catch return;
    search_buf[search.len] = 0;

    var fd: WIN32_FIND_DATAA = undefined;
    const handle = FindFirstFileA(@ptrCast(search_buf[0..search.len :0]), &fd);
    if (handle == INVALID_HANDLE) return;
    defer _ = FindClose(handle);

    while (true) {
        const name_len = cStrLen(&fd.cFileName);
        const name = fd.cFileName[0..name_len];

        if (!(name.len == 1 and name[0] == '.') and
            !(name.len == 2 and name[0] == '.' and name[1] == '.'))
        {
            var child_buf: [MAX_PATH]u8 = undefined;
            const child = std.fmt.bufPrint(&child_buf, "{s}\\{s}", .{ full_path, name }) catch break;

            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
                scanDirectory(child, base_dir_len);
            } else if (!isMpq(name)) {
                const game_key = child[base_dir_len..];
                const disk_path = child[wow_dir_len..];

                const norm_key = normalizeCopy(alloc, game_key) catch continue;
                const owned_disk = alloc.alloc(u8, disk_path.len + 1) catch continue;
                @memcpy(owned_disk[0..disk_path.len], disk_path);
                owned_disk[disk_path.len] = 0; // null-terminate for C interop

                loose_files.put(alloc, norm_key, owned_disk) catch continue;
            }
        }

        if (FindNextFileA(handle, &fd) == 0) break;
    }
}

fn looseFilesInit() void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var dir_buf: [MAX_PATH]u8 = undefined;
    const len = GetModuleFileNameA(null, &dir_buf, MAX_PATH);
    if (len == 0) return;

    // Truncate to directory (keep trailing backslash)
    var last_slash: usize = 0;
    for (dir_buf[0..len], 0..) |c, i| {
        if (c == '\\') last_slash = i;
    }
    wow_dir_len = last_slash + 1;
    const wow_dir = dir_buf[0..wow_dir_len];

    var data_buf: [MAX_PATH]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}Data", .{wow_dir}) catch return;
    data_buf[data_path.len] = 0;

    const attr = GetFileAttributesA(@ptrCast(data_buf[0..data_path.len :0]));
    if (attr == INVALID_FILE_ATTRIBUTES or attr & FILE_ATTRIBUTE_DIRECTORY == 0) return;

    const base_len = wow_dir_len + 5; // "Data\"
    scanDirectory(data_path, base_len);
}

fn looseFilesCleanup() void {
    loose_files = .empty;
    arena.deinit();
}

fn looseFilesLookup(game_path_ptr: u32) ?[*]const u8 {
    if (game_path_ptr == 0) return null;
    const raw: [*]const u8 = @ptrFromInt(game_path_ptr);
    const path = raw[0..cStrLen(raw)];

    var norm_buf: [MAX_PATH]u8 = undefined;
    if (path.len > MAX_PATH) return null;
    @memcpy(norm_buf[0..path.len], path);
    normalizeInPlace(norm_buf[0..path.len]);

    const result = loose_files.get(norm_buf[0..path.len]);
    if (result) |disk_path| {
        return disk_path.ptr;
    }
    return null;
}

// =============================================================================
// Hook: CheckFileExistence (0x654DD0)
// =============================================================================
// __fastcall(ECX=filename, EDX=flags, stack=outputBuffer) → EAX

const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const CheckFileExistenceFn = fn (u32, u32, u32) callconv(fc) u32;

var cfe_hook: hook.Detour(CheckFileExistenceFn) = .{};

fn checkFileExistenceDetour(filename_ptr: u32, flags: u32, output_buffer_ptr: u32) callconv(fc) u32 {
    if (filename_ptr != 0) {
        if (looseFilesLookup(filename_ptr)) |disk_path| {
            const raw: [*]const u8 = @ptrFromInt(filename_ptr);
            con.fmt("[looseassets] loose hit: \"{s}\"\n", .{raw[0..cStrLen(raw)]});

            if (output_buffer_ptr != 0) {
                const disk_len = cStrLen(disk_path);
                const out: [*]u8 = @ptrFromInt(output_buffer_ptr);
                if (disk_len < MAX_PATH) {
                    @memcpy(out[0..disk_len], disk_path[0..disk_len]);
                    out[disk_len] = 0;
                }
            }
            return 1;
        }
    }
    return cfe_hook.callOriginal(.{ filename_ptr, flags, output_buffer_ptr });
}

fn installHook() bool {
    return cfe_hook.attach(0x654DD0, &checkFileExistenceDetour) == .ok;
}

// =============================================================================
// Patch 1: Permissive MPQ glob (0x82edc2: '?' → '*')
// =============================================================================

var old_glob_byte: u8 = 0;
var glob_patched: bool = false;

fn applyGlobPatch() void {
    const addr: usize = 0x82edc2;
    if (hook.readMem(u8, addr) != 0x3F) return; // not '?'
    old_glob_byte = 0x3F;
    hook.writeProtected(addr, &[_]u8{0x2A}); // '*'
    glob_patched = true;
}

fn revertGlobPatch() void {
    if (glob_patched) {
        hook.writeProtected(0x82edc2, &[_]u8{old_glob_byte});
        glob_patched = false;
    }
}

// =============================================================================
// Patches 2 & 3: NOP loose file gates in File_FindInArchive
// =============================================================================

var old_jz: [2]u8 = undefined;
var jz_patched: bool = false;
var old_jnz: [2]u8 = undefined;
var jnz_patched: bool = false;

fn applyLooseFilePatches() void {
    const nops = [2]u8{ 0x90, 0x90 };

    // Gate 1: JZ at 0x654b5c (74 25)
    if (hook.readMem(u8, 0x654b5c) == 0x74 and hook.readMem(u8, 0x654b5d) == 0x25) {
        old_jz = .{ 0x74, 0x25 };
        hook.writeProtected(0x654b5c, &nops);
        jz_patched = true;
    }

    // Gate 2: JNZ at 0x654b6a (75 17)
    if (hook.readMem(u8, 0x654b6a) == 0x75 and hook.readMem(u8, 0x654b6b) == 0x17) {
        old_jnz = .{ 0x75, 0x17 };
        hook.writeProtected(0x654b6a, &nops);
        jnz_patched = true;
    }
}

fn revertLooseFilePatches() void {
    if (jz_patched) {
        hook.writeProtected(0x654b5c, &old_jz);
        jz_patched = false;
    }
    if (jnz_patched) {
        hook.writeProtected(0x654b6a, &old_jnz);
        jnz_patched = false;
    }
}

// =============================================================================
// Init / Cleanup
// =============================================================================

var installed: bool = false;
var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

pub fn installHooks() void {
    con.print("[looseassets] Module loaded\n");

    // Multi-DLL safety: only one instance per process should hook
    var mutex_name_buf: [64]u8 = undefined;
    const mutex_name = std.fmt.bufPrint(&mutex_name_buf, "Local\\LooseassetsHook_{d}", .{GetCurrentProcessId()}) catch return;
    mutex_name_buf[mutex_name.len] = 0;

    g_mutex = CreateMutexA(null, 1, @ptrCast(mutex_name_buf[0..mutex_name.len :0]));
    if (g_mutex == null) return;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(g_mutex.?);
        g_mutex = null;
        g_is_hook_owner = false;
        con.print("[looseassets] Another DLL owns hooks (mutex taken), skipping\n");
        return;
    }
    g_is_hook_owner = true;

    applyGlobPatch();
    applyLooseFilePatches();
    looseFilesInit();
    if (!installHook()) return;
    installed = true;
}

pub fn removeHooks() void {
    if (g_is_hook_owner and installed) {
        cfe_hook.detach();
        revertLooseFilePatches();
        revertGlobPatch();
        looseFilesCleanup();
        installed = false;
    }

    if (g_is_hook_owner) {
        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
