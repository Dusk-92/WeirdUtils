//! luastr -- Lua string pattern optimizations.
//!
//! Two production wins, both measured in real gameplay (see git history for
//! before/after numbers):
//!
//!   1. pattern_match_class (0x7FC930): replace Wine CRT's locale dispatch
//!      (~300+ cyc/call) with a direct 256-entry table lookup (~30 cyc/call).
//!      The table is built once at install time by calling the original
//!      matchclass for every (byte, class_letter) pair, capturing the exact
//!      Wine/locale classification. Zero correctness risk.
//!
//!   2. string.find / string.gfind-iterator / string.gsub literal pre-filter:
//!      extract the longest mandatory literal run from each pattern and short-
//!      circuit with memmem if absent from the subject. Kills the O(n^2)
//!      backtracking that addon combat log parsers (MSBT, WIM, BigWigs, etc.)
//!      inflict on every chat message. Measured impact:
//!        - eliminates ~22-40% of real pattern-engine cycles per frame window
//!        - ~5-17% overhead of its own (inside the real matcher's budget)
//!        - net_if_live consistently positive across all measurement windows
//!
//! Correctness: the prefilter is correct by construction -- we only short-
//! circuit when a REQUIRED literal substring is PROVABLY absent from the
//! subject. Any parse ambiguity, complex construct (%b/%f), or run too short
//! to beat MIN_LITERAL_LEN falls through to the real matcher.

const std = @import("std");
const hook = @import("zhook");
const lua = @import("../lua.zig");
const logging = @import("../logging.zig");

var log: logging.Logger = .{};

// =============================================================================
// pattern_match_class (0x7FC930) -- 256-entry table lookup
//   __fastcall(ECX=character, EDX=class_letter) -> u32 (1=match, 0=no match)
//
// Wine sets DAT_00831710 >= 2, forcing every %d/%a/%s/etc. check through
// CheckCharacterProperties() instead of a direct table lookup. A single
// %d+ match against a 100-char string calls this 100+ times per frame.
// =============================================================================

// Runtime 256-entry classification table. Each entry is a u16 bitfield:
//   bit 0 (  1): %a  -- alpha
//   bit 1 (  2): %c  -- control
//   bit 2 (  4): %d  -- digit
//   bit 3 (  8): %l  -- lowercase
//   bit 4 ( 16): %p  -- punct
//   bit 5 ( 32): %s  -- space
//   bit 6 ( 64): %u  -- uppercase
//   bit 7 (128): %w  -- alnum
//   bit 8 (256): %x  -- xdigit
//
// Populated at installHooks time by calling the original pattern_match_class
// for every (c=0..255, class_letter) pair. Captures the exact Wine/locale
// classification -- correct for ASCII, UTF-8 multibyte bytes, Windows codepage,
// and any locale. 256 * 9 = 2304 calls at load, zero overhead thereafter.
var runtime_table: [256]u16 = [_]u16{0} ** 256;

fn buildRuntimeTable() void {
    const OrigFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
    const orig: *const OrigFn = @ptrFromInt(0x7FC930);
    const Entry = struct { cl: u32, bit: u16 };
    const entries = [_]Entry{
        .{ .cl = 'a', .bit = 1 },
        .{ .cl = 'c', .bit = 2 },
        .{ .cl = 'd', .bit = 4 },
        .{ .cl = 'l', .bit = 8 },
        .{ .cl = 'p', .bit = 16 },
        .{ .cl = 's', .bit = 32 },
        .{ .cl = 'u', .bit = 64 },
        .{ .cl = 'w', .bit = 128 },
        .{ .cl = 'x', .bit = 256 },
    };
    for (entries) |e| {
        for (0..256) |c| {
            if (orig(@intCast(c), e.cl) != 0) {
                runtime_table[c] |= e.bit;
            }
        }
    }
}

// Reimplementation of matchclass() using the runtime-populated table.
// %z/%Z are special-cased (zero-byte semantics, not locale-dependent).
// Unknown class letters fall through to literal match, same as the original.
fn matchClassImpl(c: u32, cl: u32) u32 {
    const lc: u32 = cl | 0x20; // ASCII tolower (safe for A-Z only)
    const is_upper_cl: bool = cl >= 'A' and cl <= 'Z';

    // %z / %Z: zero-byte check -- not a locale concept
    if (lc == 'z') {
        const m = c == 0;
        return if (if (is_upper_cl) !m else m) 1 else 0;
    }

    const bit: u16 = switch (lc) {
        'a' => 1,
        'c' => 2,
        'd' => 4,
        'l' => 8,
        'p' => 16,
        's' => 32,
        'u' => 64,
        'w' => 128,
        'x' => 256,
        else => return if (cl == c) 1 else 0,
    };

    const entry: u16 = if (c < 256) runtime_table[c] else 0;
    const m = (entry & bit) != 0;
    return if (if (is_upper_cl) !m else m) 1 else 0;
}

const MatchClassFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
var matchclass_hook: hook.Detour(MatchClassFn) = .{};

fn matchclassDetour(c: u32, cl: u32) callconv(hook.cc.fastcall) u32 {
    // Preserve ESI/EDI/EBX across our pure-Zig body -- Wine's pattern matcher
    // assumes these are callee-saved across the call.
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    return matchClassImpl(c, cl);
}

// =============================================================================
// String function literal pre-filter
// =============================================================================

const LUA_TSTRING: i32 = 4;

// Minimum literal run length before we bother running memmem. Shorter runs
// produce too many false-positive passes on typical chat/tooltip subjects to
// be worth the scan cost. 4 is empirically a good tradeoff.
const MIN_LITERAL_LEN: usize = 4;

const FnTag = enum { find, match, gsub };

// Pseudo-index constants for the gfind iterator closure body (0x7FCFF0).
// Subject/pattern/position live in upvalues, not arg slots.
//   LUA_GLOBALSINDEX = -10001, upvalue(i) = LUA_GLOBALSINDEX - i
const GFIND_SUBJ_IDX: i32 = -10002; // upvalue 1
const GFIND_PAT_IDX: i32 = -10003; // upvalue 2

/// lua_strlen(L, idx) -> size_t. Address 0x6F36E0. Ghidra and earlier project
/// notes mislabeled this as `lua_tolstring`; disassembly shows it returns
/// `*(TString + 0xC)` which is the `len` field of Lua 5.0's TString header,
/// NOT a data pointer. 2-arg fastcall, ECX=L EDX=idx, `RET` (no stack cleanup).
fn luaStrLen(L: lua.State, idx: i32) usize {
    const f: *const fn (lua.State, i32) callconv(hook.cc.fastcall) usize = @ptrFromInt(0x6F36E0);
    return f(L, idx);
}

/// Return the longest run of mandatory literal bytes in a Lua 5.0 pattern,
/// as a slice into `pat` itself. Zero-copy: no scratch buffer, no escape
/// translation, no out-parameter.
///
/// Tradeoff: runs break at any `%X` escape item (even escaped punctuation
/// like `%.`). The literal `foo%.bar` yields best run "foo" or "bar" rather
/// than "foo.bar". For prefilter correctness this is fine -- any mandatory
/// literal substring being provably absent from the subject disproves the
/// pattern. A shorter run means slightly weaker filtering, never a wrong
/// answer.
///
/// Parser notes:
///   - `+`, `-`, `*`, `?` at a fresh item-parse position are plain literal
///     bytes, matching Lua 5.0's own matcher. Example: `%d+-%d+` parses as
///     `%d+` class+quantifier, then `-` as literal dash, then `%d+`.
///   - `(` and `)` are zero-width capture delimiters; they break runs without
///     consuming a literal byte.
///   - `[set]` scans past the matching `]` as a non-literal item.
///   - `%b...` and `%f[...]` are complex; we bail.
fn longestLiteral(pat: []const u8) []const u8 {
    var best_start: usize = 0;
    var best_len: usize = 0;
    var cur_start: usize = 0;
    var cur_len: usize = 0;

    var i: usize = 0;
    // Leading `^` is an anchor, skip it -- the rest still defines the literal.
    if (pat.len > 0 and pat[0] == '^') i = 1;

    while (i < pat.len) {
        const c = pat[i];
        var item_bytes: usize = 1;
        var is_literal: bool = true;

        switch (c) {
            '(', ')' => {
                // Zero-width capture delim: break run, advance 1, no quantifier.
                if (cur_len > best_len) {
                    best_start = cur_start;
                    best_len = cur_len;
                }
                cur_len = 0;
                i += 1;
                continue;
            },
            '.', '$' => {
                is_literal = false;
            },
            '[' => {
                // Scan past matching ].
                var j = i + 1;
                if (j < pat.len and pat[j] == '^') j += 1;
                if (j < pat.len and pat[j] == ']') j += 1; // first ] inside set is literal
                while (j < pat.len and pat[j] != ']') : (j += 1) {
                    if (pat[j] == '%' and j + 1 < pat.len) j += 1;
                }
                if (j >= pat.len) break; // unbalanced -- bail
                is_literal = false;
                item_bytes = j + 1 - i;
            },
            '%' => {
                if (i + 1 >= pat.len) break; // trailing % -- bail
                const n = pat[i + 1];
                if (n == 'b' or n == 'B' or n == 'f' or n == 'F') break; // complex
                is_literal = false;
                item_bytes = 2;
            },
            ']' => break, // unbalanced close-bracket -- bail
            else => {}, // plain literal byte (including +/-/*/? at item position)
        }

        // Peek for a quantifier modifying this item.
        const next_i = i + item_bytes;
        var quant: u8 = 0;
        if (next_i < pat.len) {
            const q = pat[next_i];
            if (q == '+' or q == '*' or q == '-' or q == '?') quant = q;
        }

        if (is_literal) {
            if (quant == '*' or quant == '-' or quant == '?') {
                // Optional -- doesn't contribute, break run.
                if (cur_len > best_len) {
                    best_start = cur_start;
                    best_len = cur_len;
                }
                cur_len = 0;
            } else {
                // No quant or `+`: byte required at least once.
                if (cur_len == 0) cur_start = i;
                cur_len += 1;
                if (quant == '+') {
                    // Required once, but run breaks: subject may contain extra
                    // repeats of this byte, so the next pattern byte isn't
                    // guaranteed contiguous in the subject.
                    if (cur_len > best_len) {
                        best_start = cur_start;
                        best_len = cur_len;
                    }
                    cur_len = 0;
                }
            }
        } else {
            // Non-literal item: break run.
            if (cur_len > best_len) {
                best_start = cur_start;
                best_len = cur_len;
            }
            cur_len = 0;
        }

        i = next_i + @intFromBool(quant != 0);
    }

    // Finalize trailing run.
    if (cur_len > best_len) {
        best_start = cur_start;
        best_len = cur_len;
    }

    return pat[best_start..][0..best_len];
}

/// Returns nresults if the call was short-circuited (pattern provably can't
/// match), or null if the caller should proceed to the real matcher.
///
/// subj_idx/pat_idx choose where to read subject and pattern from. For
/// string.find/gsub these are arg slots 1 and 2. For the string.gfind
/// iterator closure (0x7FCFF0) they are upvalue pseudo-indices -10002/-10003.
fn tryPrefilter(L: lua.State, tag: FnTag, subj_idx: i32, pat_idx: i32) ?u32 {
    // Require string type (not number) to avoid triggering number -> string
    // coercion side effects inside a detour. typeOf returns LUA_TNONE on
    // invalid indices, which cleanly falls through.
    if (lua.typeOf(L, subj_idx) != LUA_TSTRING) return null;
    if (lua.typeOf(L, pat_idx) != LUA_TSTRING) return null;

    const subj_ptr_sent = lua.tostring(L, subj_idx) orelse return null;
    const pat_ptr_sent = lua.tostring(L, pat_idx) orelse return null;
    const subj_len = luaStrLen(L, subj_idx);
    const pat_len = luaStrLen(L, pat_idx);
    if (pat_len == 0 or subj_len == 0) return null;

    const subj_ptr: [*]const u8 = @ptrCast(subj_ptr_sent);
    const pat_ptr: [*]const u8 = @ptrCast(pat_ptr_sent);
    const pat_slice = pat_ptr[0..pat_len];

    const lit = longestLiteral(pat_slice);
    if (lit.len < MIN_LITERAL_LEN) return null;

    const subj_slice = subj_ptr[0..subj_len];
    if (std.mem.indexOf(u8, subj_slice, lit) != null) return null;

    // Literal provably absent -- pattern cannot match. Short-circuit.
    switch (tag) {
        .find, .match => {
            lua.pushnil(L);
            return 1;
        },
        .gsub => {
            // string.gsub on no match returns (subject_unchanged, 0)
            lua.pushvalue(L, 1);
            lua.pushnumber(L, 0);
            return 2;
        },
    }
}

// =============================================================================
// Hooked functions
//
// 0x7FC3B0 lua_string_find  -- reads subject/pattern from stack args 1, 2
// 0x7FCFF0 lua_string_gfind_iter -- the gfind iterator closure body; reads
//          subject/pattern/position from upvalues. Ghidra mislabels this as
//          "lua_string_match"; Lua 5.0 does NOT have string.match (5.1+).
// 0x7FD0E0 lua_string_gsub  -- reads subject/pattern from stack args 1, 2
// =============================================================================

const StringFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
var strfind_hook: hook.Detour(StringFn) = .{};
var strmatch_hook: hook.Detour(StringFn) = .{};
var strgsub_hook: hook.Detour(StringFn) = .{};

fn strfindDetour(state: u32, edx: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const L: lua.State = @ptrFromInt(state);
    if (tryPrefilter(L, .find, 1, 2)) |nres| return nres;
    return strfind_hook.callOriginal(.{ state, edx });
}

fn strmatchDetour(state: u32, edx: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const L: lua.State = @ptrFromInt(state);
    if (tryPrefilter(L, .match, GFIND_SUBJ_IDX, GFIND_PAT_IDX)) |nres| return nres;
    return strmatch_hook.callOriginal(.{ state, edx });
}

fn strgsubDetour(state: u32, edx: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const L: lua.State = @ptrFromInt(state);
    if (tryPrefilter(L, .gsub, 1, 2)) |nres| return nres;
    return strgsub_hook.callOriginal(.{ state, edx });
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn install() u32 {
    log = logging.Logger.open("luastr", .console);

    buildRuntimeTable();
    log.print("  matchclass: runtime table built\n");

    var installed: u32 = 0;
    if (matchclass_hook.attach(0x7FC930, &matchclassDetour) == .ok) {
        log.print("  matchclass: table lookup active\n");
        installed += 1;
    }
    if (strfind_hook.attach(0x7FC3B0, &strfindDetour) == .ok) {
        log.print("  string.find: literal prefilter active\n");
        installed += 1;
    }
    if (strmatch_hook.attach(0x7FCFF0, &strmatchDetour) == .ok) {
        log.print("  string.gfind: literal prefilter active\n");
        installed += 1;
    }
    if (strgsub_hook.attach(0x7FD0E0, &strgsubDetour) == .ok) {
        log.print("  string.gsub: literal prefilter active\n");
        installed += 1;
    }

    log.print("luastr: active\n");
    return installed;
}

pub fn remove() void {
    strgsub_hook.detach();
    strmatch_hook.detach();
    strfind_hook.detach();
    matchclass_hook.detach();
    log.close();
}
