//! luavm -- Lua VM hotspot optimizations.
//!
//! Targets the top 3 Lua CPU consumers from perf profiling (4.5% combined):
//!
//!   1. lua_table_get_hash_element (0x6FA760, 1.65%) -- hash chain walk with prefetch
//!   2. lua_vm_execute (0x6F8720, 1.50%) -- jump table patches for hot opcodes
//!   3. luaS_newlstr (0x6F9D00, 1.35%) -- hash pre-check before memcmp
//!
//! All three functions verified from disassembly (calling conventions, layouts).

const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "luavm";

var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// 1. lua_table_get_hash_element (0x6FA760)
//    __fastcall(ECX=Table*, EDX=TString*) -> TValue*
//    59 bytes. Pure hash chain walk through 40-byte nodes.
//
//    Optimization: software prefetch of next node while comparing current.
//    On chains of length >= 2, hides ~100 cycle cache miss latency behind
//    the type+key comparison (~5 cycles). Average WoW addon table chains
//    are 1-3 deep; prefetch helps the 2-3 deep cases.
//
//    Node layout (40 bytes / 0x28):
//      +0x00: key type tag (4 = LUA_TSTRING)
//      +0x08: key value (TString pointer -- interned, so pointer equality)
//      +0x10: value (TValue, 16 bytes)
//      +0x20: next chain pointer
//
//    Table layout:
//      +0x07: lsizenode (u8, log2 of hash part size)
//      +0x10: node array base pointer
// =============================================================================

const LUA_TSTRING = 4;
const NIL_OBJECT: u32 = 0x811bc0; // luaO_nilobject sentinel

const HashLookupFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
var hash_lookup_hook: hook.Detour(HashLookupFn) = .{};

fn hashLookupDetour(table: u32, key: u32) callconv(hook.cc.fastcall) u32 {
    // Preserve callee-saved regs the compiler might not know about
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const lsizenode: u5 = @truncate(hook.readMem(u8, table + 7));
    const node_base: u32 = hook.readMem(u32, table + 0x10);
    const key_hash: u32 = hook.readMem(u32, key + 0x08);

    const mask: u32 = (@as(u32, 1) << lsizenode) - 1;
    const bucket: u32 = key_hash & mask;
    var node: u32 = node_base + bucket * 40;

    while (true) {
        // Read next pointer early -- prefetch its cache line while we compare
        const next: u32 = hook.readMem(u32, node + 0x20);
        if (next != 0) {
            asm volatile ("prefetcht0 (%[addr])"
                :
                : [addr] "r" (next),
            );
        }

        // Check: is this node a string key matching our TString?
        const key_type: u32 = hook.readMem(u32, node);
        if (key_type == LUA_TSTRING) {
            const key_value: u32 = hook.readMem(u32, node + 0x08);
            if (key_value == key) {
                return node + 0x10; // &node->i_val
            }
        }

        if (next == 0) return NIL_OBJECT;
        node = next;
    }
}

// =============================================================================
// 2. luaS_newlstr (0x6F9D00)
//    __fastcall(ECX=lua_State*, EDX=str_ptr, stack=len) -> TString*
//    RET 0x4 (cleans 1 stack param)
//
//    Lua 5.0 string interning: hash the string, then walk the intern table
//    chain comparing length + bytes.
//
//    Optimization: add hash pre-check before REPE CMPSB. The original code
//    checks ts->len == len, then immediately does memcmp. But many strings
//    share common lengths (4, 6, 8...) causing false-positive memcmps.
//    Adding ts->hash == our_hash eliminates these -- a 1-cycle comparison
//    that skips an O(len) memcmp.
//
//    This is the Lua 5.0 -> 5.1 optimization that Blizzard never got.
//
//    TString layout:
//      +0x00: next pointer (intern chain)
//      +0x04: tt (type tag)
//      +0x05: marked (GC mark)
//      +0x06: reserved
//      +0x08: hash (u32)
//      +0x0C: len (u32)
//      +0x10: inline char data
//
//    String table (global_State+0x10 -> strt):
//      +0x04: hash bucket array (TString**)
//      +0x0C: size (number of buckets)
// =============================================================================

const NewLStrFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
var newlstr_hook: hook.Detour(NewLStrFn) = .{};

// lua_create_string_object at 0x6F9D90:
// __fastcall(ECX=global_State*, EDX=str_ptr, stack: len, hash)
// Allocates and interns a new TString. We call this on cache miss.
fn luaCreateStringObject(state: u32, str_ptr: u32, len: u32, hash: u32) u32 {
    return hook.call(
        fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32,
        0x6F9D90,
        .{ state, str_ptr, len, hash },
    );
}

fn newlstrDetour(state: u32, str_ptr: u32, len: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // Phase 1: Hash computation (identical to original Lua 5.0 algorithm)
    // Samples every (len>>5)+1 bytes, seed = len
    const str: [*]const u8 = @ptrFromInt(str_ptr);
    var h: u32 = len;
    const step: u32 = (len >> 5) + 1;
    var l1: u32 = len;
    while (l1 >= step) {
        const c: u32 = str[l1 - 1];
        h = h ^ (c +% (h << 5) +% (h >> 2));
        l1 -= step;
    }

    // Phase 2: Intern table lookup with hash pre-check
    // global_State is at state+0x10 (lua_State -> l_G)
    const global_state: u32 = hook.readMem(u32, state + 0x10);
    const strt_hash: u32 = hook.readMem(u32, global_state + 0x04); // bucket array
    const strt_size: u32 = hook.readMem(u32, global_state + 0x0C); // bucket count

    const bucket: u32 = h & (strt_size - 1);
    var ts: u32 = hook.readMem(u32, strt_hash + bucket * 4);

    while (ts != 0) {
        const ts_len: u32 = hook.readMem(u32, ts + 0x0C);
        if (ts_len == len) {
            // ** THE OPTIMIZATION: check hash before memcmp **
            const ts_hash: u32 = hook.readMem(u32, ts + 0x08);
            if (ts_hash == h) {
                // Length and hash match -- now compare actual bytes
                if (len == 0 or strEqual(str_ptr, ts + 0x10, len)) {
                    return ts;
                }
            }
        }
        ts = hook.readMem(u32, ts); // ts = ts->next
    }

    // Not found -- allocate and intern (ECX = lua_State*, not global_State*)
    return luaCreateStringObject(state, str_ptr, len, h);
}

/// Fast string comparison. Uses dword-at-a-time for the bulk, then byte tail.
fn strEqual(a_ptr: u32, b_ptr: u32, len: u32) bool {
    const a: [*]const u8 = @ptrFromInt(a_ptr);
    const b: [*]const u8 = @ptrFromInt(b_ptr);

    // Compare 4 bytes at a time
    var i: u32 = 0;
    while (i + 4 <= len) : (i += 4) {
        const va = @as(*align(1) const u32, @ptrCast(a + i)).*;
        const vb = @as(*align(1) const u32, @ptrCast(b + i)).*;
        if (va != vb) return false;
    }
    // Remaining bytes
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

// =============================================================================
// 3. lua_vm_execute (0x6F8720)
//    __fastcall(ECX=lua_State*) -> TValue* (or NULL)
//    4432 bytes, 35 opcodes via jump table at 0x6F9870.
//
//    Strategy: patch individual jump table entries to point at our optimized
//    opcode handlers. This avoids rewriting the entire 4.4KB function while
//    targeting the hot paths.
//
//    At jump table dispatch, the register state is:
//      ESI = instruction word (full 32-bit encoded instruction)
//      EDI = R(A) pointer (base + A*16)
//      EBX = A*16 (A field scaled to TValue offset)
//      [EBP-0x04] = lua_State*
//      [EBP-0x08] = pc (already incremented past this instruction)
//      [EBP-0x0C] = base (L->base)
//      [EBP-0x10] = constants array
//      [EBP-0x14] = closure
//
//    Dispatch loop re-entry: 0x6F8770 (fetch next instruction from [EBP-0x08])
//
//    Optimization targets:
//
//    a) Arithmetic (ADD=0xC, SUB=0xD, MUL=0xE, DIV=0xF):
//       Original uses x87: FLD [src+8] / FADD [src+8] / FSTP [dst+8]
//       Replace with SSE2: MOVSD xmm0,[src+8] / ADDSD xmm0,[src+8] / MOVSD [dst+8],xmm0
//       SSE2 has lower latency and better pipelining on modern CPUs.
//
//    b) TValue copies (~20 sites):
//       Original: 4x MOV (load+store each dword, 8 instructions = 32 bytes)
//       Replace with: MOVDQU xmm0,[src] / MOVDQU [dst],xmm0 (2 instructions)
//       Saves ~12 bytes per site and reduces frontend pressure.
//
//    c) GETGLOBAL (opcode 5):
//       Inlines the hash lookup (currently calls 0x6FA760) to avoid call
//       overhead. The hash lookup is only ~15 instructions; inlining saves
//       the CALL/RET cycle and enables the compiler to keep values in regs.
//
//    Implementation: each patched opcode handler is a naked fn that matches
//    the register convention above, does its work, and JMPs to 0x6F8770.
// =============================================================================

const VM_DISPATCH_LOOP: u32 = 0x6F8770;
const VM_JUMP_TABLE: u32 = 0x6F9870;

// Opcode indices for the jump table
const OP_MOVE: u32 = 0;
const OP_ADD: u32 = 0xC;
const OP_SUB: u32 = 0xD;
const OP_MUL: u32 = 0xE;
const OP_DIV: u32 = 0xF;

// Store original jump table entries so we can restore them
var original_jt_entries: [35]u32 = undefined;
var jt_patched: bool = false;

fn patchJumpTableEntry(opcode: u32, handler: u32) void {
    const entry_addr = VM_JUMP_TABLE + opcode * 4;
    // Save original
    original_jt_entries[opcode] = hook.readMem(u32, entry_addr);
    // Write our handler address
    var addr_bytes: [4]u8 = undefined;
    @as(*align(1) u32, @ptrCast(&addr_bytes)).* = handler;
    hook.writeProtected(entry_addr, &addr_bytes);
}

fn restoreJumpTableEntry(opcode: u32) void {
    const entry_addr = VM_JUMP_TABLE + opcode * 4;
    var addr_bytes: [4]u8 = undefined;
    @as(*align(1) u32, @ptrCast(&addr_bytes)).* = original_jt_entries[opcode];
    hook.writeProtected(entry_addr, &addr_bytes);
}

// ---------------------------------------------------------------------------
// MOVE handler (opcode 0) -- SSE TValue copy
//
// Original (at 0x6F87CD):
//   Decodes B from ESI bits[15:23], computes R(B) = base + B*16,
//   does 4x MOV to copy 16 bytes from R(B) to R(A), then GC barrier.
//
// Our version: MOVDQU copy (2 instructions instead of 8), same GC barrier.
// ---------------------------------------------------------------------------

fn vmMoveHandler() callconv(.naked) void {
    // AT&T syntax: src, dst. Registers prefixed with %%.
    asm volatile (
        // Decode B field: bits [15:23] of ESI
        \\  movl %%esi, %%ecx
        \\  shrl $15, %%ecx
        \\  andl $0x1ff, %%ecx
        \\  shll $4, %%ecx
        \\  addl -0x0c(%%ebp), %%ecx
        // ecx = R(B). SSE 16-byte copy: R(A) = R(B)
        \\  movdqu (%%ecx), %%xmm0
        \\  movdqu %%xmm0, (%%edi)
        // GC write barrier check
        \\  movl 4(%%edi), %%eax
        \\  testl %%eax, %%eax
        \\  jz 1f
        \\  cmpl $0, 0xCEEAC4
        \\  jz 1f
        \\  movl %%eax, 0xCEEAC0
        \\1:
        // Re-enter dispatch loop (EAX = pc, EDX = scratch for jump target)
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        :
        : [dispatch] "i" (VM_DISPATCH_LOOP),
    );
}

// ---------------------------------------------------------------------------
// Arithmetic handlers -- SSE2 ADDSD/SUBSD/MULSD/DIVSD
//
// Each handler: decode B & C with RK check, type-check for LUA_TNUMBER,
// fast path with SSE2, slow path calls lua_arithmetic_operation (0x6F9A80).
//
// Fully inlined per-handler to avoid multiline string concat issues.
// ---------------------------------------------------------------------------

fn vmAddHandler() callconv(.naked) void {
    // Register layout at entry: ESI=instruction, EDI=R(A), [EBP-0x04]=L,
    // [EBP-0x08]=pc, [EBP-0x0C]=base, [EBP-0x10]=constants
    //
    // Decode: ECX=RK(C) ptr, EDX=RK(B) ptr. EDI=R(A) preserved.
    // Fast path: SSE2 addsd. Slow path: __fastcall(ECX=L, EDX=R(A),
    //   stack: opB, opC, TM_ADD=5), callee cleans stack (RET 0xC).
    asm volatile (
        \\  movl %%esi, %%ecx
        \\  shrl $6, %%ecx
        \\  andl $0x1ff, %%ecx
        \\  cmpl $0xfa, %%ecx
        \\  jl 2f
        \\  subl $250, %%ecx
        \\  shll $4, %%ecx
        \\  addl -0x10(%%ebp), %%ecx
        \\  jmp 3f
        \\2: shll $4, %%ecx
        \\  addl -0x0c(%%ebp), %%ecx
        \\3: movl %%esi, %%edx
        \\  shrl $15, %%edx
        \\  andl $0x1ff, %%edx
        \\  cmpl $0xfa, %%edx
        \\  jl 4f
        \\  subl $250, %%edx
        \\  shll $4, %%edx
        \\  addl -0x10(%%ebp), %%edx
        \\  jmp 5f
        \\4: shll $4, %%edx
        \\  addl -0x0c(%%ebp), %%edx
        \\5: cmpl $3, (%%edx)
        \\  jne 6f
        \\  cmpl $3, (%%ecx)
        \\  jne 6f
        \\  movsd 8(%%edx), %%xmm0
        \\  addsd 8(%%ecx), %%xmm0
        \\  movsd %%xmm0, 8(%%edi)
        \\  movl $3, (%%edi)
        \\  movl 0xCEEAC0, %%eax
        \\  movl %%eax, 4(%%edi)
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        \\6:
        // Slow path: __fastcall(ECX=L, EDX=R(A), stack: opB, opC, tm_id)
        // Callee cleans stack (RET 0xC) -- no ESP adjustment after call.
        \\  pushl $5
        \\  pushl %%ecx
        \\  pushl %%edx
        \\  movl -0x04(%%ebp), %%ecx
        \\  movl %%edi, %%edx
        \\  movl %[arith_op], %%eax
        \\  call *%%eax
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        :
        : [dispatch] "i" (VM_DISPATCH_LOOP),
          [arith_op] "i" (@as(u32, 0x6F9A80)),
    );
}

fn vmSubHandler() callconv(.naked) void {
    asm volatile (
        \\  movl %%esi, %%ecx
        \\  shrl $6, %%ecx
        \\  andl $0x1ff, %%ecx
        \\  cmpl $0xfa, %%ecx
        \\  jl 2f
        \\  subl $250, %%ecx
        \\  shll $4, %%ecx
        \\  addl -0x10(%%ebp), %%ecx
        \\  jmp 3f
        \\2: shll $4, %%ecx
        \\  addl -0x0c(%%ebp), %%ecx
        \\3: movl %%esi, %%edx
        \\  shrl $15, %%edx
        \\  andl $0x1ff, %%edx
        \\  cmpl $0xfa, %%edx
        \\  jl 4f
        \\  subl $250, %%edx
        \\  shll $4, %%edx
        \\  addl -0x10(%%ebp), %%edx
        \\  jmp 5f
        \\4: shll $4, %%edx
        \\  addl -0x0c(%%ebp), %%edx
        \\5: cmpl $3, (%%edx)
        \\  jne 6f
        \\  cmpl $3, (%%ecx)
        \\  jne 6f
        \\  movsd 8(%%edx), %%xmm0
        \\  subsd 8(%%ecx), %%xmm0
        \\  movsd %%xmm0, 8(%%edi)
        \\  movl $3, (%%edi)
        \\  movl 0xCEEAC0, %%eax
        \\  movl %%eax, 4(%%edi)
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        \\6:
        \\  pushl $6
        \\  pushl %%ecx
        \\  pushl %%edx
        \\  movl -0x04(%%ebp), %%ecx
        \\  movl %%edi, %%edx
        \\  movl %[arith_op], %%eax
        \\  call *%%eax
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        :
        : [dispatch] "i" (VM_DISPATCH_LOOP),
          [arith_op] "i" (@as(u32, 0x6F9A80)),
    );
}

fn vmMulHandler() callconv(.naked) void {
    asm volatile (
        \\  movl %%esi, %%ecx
        \\  shrl $6, %%ecx
        \\  andl $0x1ff, %%ecx
        \\  cmpl $0xfa, %%ecx
        \\  jl 2f
        \\  subl $250, %%ecx
        \\  shll $4, %%ecx
        \\  addl -0x10(%%ebp), %%ecx
        \\  jmp 3f
        \\2: shll $4, %%ecx
        \\  addl -0x0c(%%ebp), %%ecx
        \\3: movl %%esi, %%edx
        \\  shrl $15, %%edx
        \\  andl $0x1ff, %%edx
        \\  cmpl $0xfa, %%edx
        \\  jl 4f
        \\  subl $250, %%edx
        \\  shll $4, %%edx
        \\  addl -0x10(%%ebp), %%edx
        \\  jmp 5f
        \\4: shll $4, %%edx
        \\  addl -0x0c(%%ebp), %%edx
        \\5: cmpl $3, (%%edx)
        \\  jne 6f
        \\  cmpl $3, (%%ecx)
        \\  jne 6f
        \\  movsd 8(%%edx), %%xmm0
        \\  mulsd 8(%%ecx), %%xmm0
        \\  movsd %%xmm0, 8(%%edi)
        \\  movl $3, (%%edi)
        \\  movl 0xCEEAC0, %%eax
        \\  movl %%eax, 4(%%edi)
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        \\6:
        \\  pushl $7
        \\  pushl %%ecx
        \\  pushl %%edx
        \\  movl -0x04(%%ebp), %%ecx
        \\  movl %%edi, %%edx
        \\  movl %[arith_op], %%eax
        \\  call *%%eax
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        :
        : [dispatch] "i" (VM_DISPATCH_LOOP),
          [arith_op] "i" (@as(u32, 0x6F9A80)),
    );
}

fn vmDivHandler() callconv(.naked) void {
    asm volatile (
        \\  movl %%esi, %%ecx
        \\  shrl $6, %%ecx
        \\  andl $0x1ff, %%ecx
        \\  cmpl $0xfa, %%ecx
        \\  jl 2f
        \\  subl $250, %%ecx
        \\  shll $4, %%ecx
        \\  addl -0x10(%%ebp), %%ecx
        \\  jmp 3f
        \\2: shll $4, %%ecx
        \\  addl -0x0c(%%ebp), %%ecx
        \\3: movl %%esi, %%edx
        \\  shrl $15, %%edx
        \\  andl $0x1ff, %%edx
        \\  cmpl $0xfa, %%edx
        \\  jl 4f
        \\  subl $250, %%edx
        \\  shll $4, %%edx
        \\  addl -0x10(%%ebp), %%edx
        \\  jmp 5f
        \\4: shll $4, %%edx
        \\  addl -0x0c(%%ebp), %%edx
        \\5: cmpl $3, (%%edx)
        \\  jne 6f
        \\  cmpl $3, (%%ecx)
        \\  jne 6f
        \\  movsd 8(%%edx), %%xmm0
        \\  divsd 8(%%ecx), %%xmm0
        \\  movsd %%xmm0, 8(%%edi)
        \\  movl $3, (%%edi)
        \\  movl 0xCEEAC0, %%eax
        \\  movl %%eax, 4(%%edi)
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        \\6:
        \\  pushl $8
        \\  pushl %%ecx
        \\  pushl %%edx
        \\  movl -0x04(%%ebp), %%ecx
        \\  movl %%edi, %%edx
        \\  movl %[arith_op], %%eax
        \\  call *%%eax
        \\  movl -0x08(%%ebp), %%eax
        \\  movl %[dispatch], %%edx
        \\  jmp *%%edx
        :
        : [dispatch] "i" (VM_DISPATCH_LOOP),
          [arith_op] "i" (@as(u32, 0x6F9A80)),
    );
}

fn installVmPatches() u32 {
    // Save ALL original entries first
    for (0..35) |i| {
        original_jt_entries[i] = hook.readMem(u32, VM_JUMP_TABLE + @as(u32, @intCast(i)) * 4);
    }

    var count: u32 = 0;

    // MOVE -- SSE TValue copy
    patchJumpTableEntry(OP_MOVE, @intFromPtr(&vmMoveHandler));
    count += 1;

    // Arithmetic -- SSE2 double ops
    patchJumpTableEntry(OP_ADD, @intFromPtr(&vmAddHandler));
    patchJumpTableEntry(OP_SUB, @intFromPtr(&vmSubHandler));
    patchJumpTableEntry(OP_MUL, @intFromPtr(&vmMulHandler));
    patchJumpTableEntry(OP_DIV, @intFromPtr(&vmDivHandler));
    count += 4;

    jt_patched = true;
    return count;
}

fn removeVmPatches() void {
    if (!jt_patched) return;
    restoreJumpTableEntry(OP_MOVE);
    restoreJumpTableEntry(OP_ADD);
    restoreJumpTableEntry(OP_SUB);
    restoreJumpTableEntry(OP_MUL);
    restoreJumpTableEntry(OP_DIV);
    jt_patched = false;
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    var installed: u32 = 0;

    // Hook 1: hash table lookup with prefetch
    if (hash_lookup_hook.attach(0x6FA760, &hashLookupDetour) == .ok) {
        installed += 1;
        log.print("  lua_table_get_hash_element: prefetch chain walk\n");
    }

    // Hook 2: string interning with hash pre-check
    if (newlstr_hook.attach(0x6F9D00, &newlstrDetour) == .ok) {
        installed += 1;
        log.print("  luaS_newlstr: hash pre-check + dword compare\n");
    }

    // Hook 3: VM opcode patches (jump table)
    installed += installVmPatches();
    log.print("  lua_vm_execute: 5 opcode patches (SSE2 arith + MOVDQU copy)\n");

    log.print("luavm: hooks installed\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        removeVmPatches();
        newlstr_hook.detach();
        hash_lookup_hook.detach();
        log.close();
    }
    g_is_hook_owner = false;
}
