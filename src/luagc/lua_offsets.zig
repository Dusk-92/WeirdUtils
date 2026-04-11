//! Hardcoded addresses and struct offsets for WoW 1.12.1's Lua 5.0.
//! All addresses are client-absolute (build 5875).
//!
//! All struct offsets below are verified via fresh Ghidra disassembly
//! of the mark_table (0x6F7590), mark_closure (0x6F77B0), mark_thread
//! (0x6F7860), and mark_proto (0x6F7710) functions. Each offset is
//! annotated with the exact instruction that proves it.
//!
//! DO NOT "correct" offsets based on the Lua 5.0 source without also
//! checking the disasm: WoW's layout diverges in a few places (TValue
//! is 16 bytes including padding; globals table TValue is at thread+0x40
//! rather than +0x38; etc.).

/// ---------------------------------------------------------------------------
// GC function addresses (all confirmed from cross-reference)
/// ---------------------------------------------------------------------------

pub const luaC_collectgarbage: usize = 0x6F7340;
pub const lua_gc_full_collection: usize = 0x6F73E0;
pub const lua_gc_remove_objects: usize = 0x6F7210;
pub const lua_gc_sweep_all_lists: usize = 0x6F72F0;
pub const lua_gc_shrink_memory: usize = 0x6F7370;
pub const luaCallUserDataGC: usize = 0x6F7080;
pub const lua_gc_free_object: usize = 0x6F7260;

/// Walks rootudata list. Moves dead udata with __gc metamethods to tmudata.
/// __fastcall: ECX = global_State*.
pub const luaC_separateudata: usize = 0x6F6FF0;

/// Re-marks tmudata list so __gc-pending userdata survive the sweep.
/// __fastcall: ECX = global_State*.
pub const marktmu: usize = 0x6F7470;

/// Clears weak-value table values in an atomic post-mark pass.
pub const cleartablevalues: usize = 0x6F7A20;

/// Clears weak-key table keys in an atomic post-mark pass.
pub const cleartablekeys: usize = 0x6F7970;

/// Resize string hash table. __fastcall(ECX=L, EDX=new_size).
pub const lua_string_hash_resize: usize = 0x6F9C50;

/// Forward barrier hook targets (Lua C API functions that create cross-object refs).
pub const lua_setmetatable: usize = 0x6F4020;
pub const lua_setupvalue: usize = 0x6F47B0;
pub const lua_pushcclosure: usize = 0x6F3920;
pub const lua_setfenv: usize = 0x6F40D0;
/// OP_SETUPVAL patch point: right after TValue copy, EDX=uv->v.
pub const vm_setupval_patch: usize = 0x6F8A97;

/// Compiler functions that add children to protos (need forward barriers).
/// lua_parser_create_constant: __fastcall(ECX=FuncState, EDX=TValue*, stack=type).
/// FuncState+0x30 = proto pointer. Adds constant to proto->k.
pub const lua_parser_create_constant: usize = 0x6FD400;
/// lua_parser_finish_function: __fastcall(ECX=LexState). Finalizes proto arrays.
pub const lua_parser_finish_function: usize = 0x6FCB00;

/// luaS_newlstr: __fastcall(ECX=L, EDX=str_ptr, stack=len). Returns TString*.
/// Does the intern lookup (may return existing dead string) then calls
/// lua_create_string_object (0x6F9D90) for new strings.
/// Must hook for dead string resurrection during sweep.
pub const luaS_newlstr: usize = 0x6F9D00;

/// lua_create_string_object (inner, creates NEW strings only): 0x6F9D90.
pub const lua_create_string_object: usize = 0x6F9D90;

/// lua_create_open_upvalue (luaF_findupval): __fastcall(ECX=L, EDX=level).
/// Returns UpVal*. Must hook for dead upvalue resurrection during sweep.
pub const lua_create_open_upvalue: usize = 0x6F9F10;

/// Birth mark byte in lua_create_open_upvalue: `MOV byte [EAX+5], 0x01`
/// Encoding: C6 40 05 01 at 0x6F9F47. The immediate 0x01 is at +3 = 0x6F9F4A.
pub const birth_mark_upvalue: usize = 0x6F9F4A;

/// lua_setgcthreshold: __fastcall(ECX=L, EDX=newthreshold).
/// Writes (newthreshold << 10) to g->gcthreshold, then calls luaC_checkGC.
/// WoW calls this on screen transitions with threshold=256 (=262144 bytes).
pub const lua_setgcthreshold: usize = 0x6F4400;

/// lua_close (luaCloseState): __fastcall(ECX=L).
/// Calls luaF_close, luaC_sweep(L,1), frees g and L.
/// Must hook to reset incremental GC state before teardown.
pub const lua_close: usize = 0x6F6EF0;

/// Mark functions (for reference; zluagen reimplements these to support
/// incremental chunking).
pub const markroot: usize = 0x6F7AB0;
pub const propagatemarks: usize = 0x6F7510;
pub const mark_object_gray: usize = 0x6F74A0;

/// ---------------------------------------------------------------------------
// Write barrier hook addresses
/// ---------------------------------------------------------------------------

pub const lua_table_set_value: usize = 0x6FA840;
pub const lua_table_set_int_key: usize = 0x6FAD80;

/// ---------------------------------------------------------------------------
// Birth mark patch addresses
/// ---------------------------------------------------------------------------

/// luaC_link: __fastcall(ECX=L, EDX=obj, stack=tt). RET 0x4.
/// Links object to rootgc, sets marked and tt. Hooked for two-white birth.
pub const luaC_link: usize = 0x6F7B20;

/// `MOV byte [EDX+0x05], 0x00` inside luaC_link. Birth mark patch address.
pub const birth_mark_luaC_link: usize = 0x6F7B37;

/// `MOV byte [EBX+0x05], 0x00` inside lua_create_string_object. Same idea.
pub const birth_mark_string: usize = 0x6F9DC1;

/// ---------------------------------------------------------------------------
// global_State struct offsets
/// ---------------------------------------------------------------------------

/// stringtable struct starts at g+0x04 (after WoW's pool_ptrs at g+0x00).
/// Layout: {hash: GCObject**, nuse: int, size: int} = 12 bytes.
/// Verified: strt+12 = 0x04+12 = 0x10 = rootgc.
pub const GS_strt_hash: u32 = 0x04;     // GCObject** bucket array
pub const GS_strt_nuse: u32 = 0x08;     // int: number of strings
pub const GS_strt_size: u32 = 0x0C;     // int: number of buckets
pub const GS_rootgc: u32 = 0x10;        // main GC list head
pub const GS_rootudata: u32 = 0x14;     // userdata list head
pub const GS_tmudata: u32 = 0x18;       // finalizer-pending udata list
pub const GS_gcthreshold: u32 = 0x24;   // bytes-alive threshold for next GC
pub const GS_totalbytes: u32 = 0x28;    // currently allocated bytes
pub const GS_registry: u32 = 0x38;      // registry table pointer
pub const GS_defaultmeta: u32 = 0x48;   // default metatable pointer
pub const GS_mainthread: u32 = 0x50;    // main lua_State*

/// ---------------------------------------------------------------------------
// GCObject common header (all GC types start with this prefix)
/// ---------------------------------------------------------------------------

pub const OBJ_next: u32 = 0x00;   // linked list next pointer
pub const OBJ_tt: u32 = 0x04;     // type tag (u8)

/// GC mark byte. Lua 5.1-style tri-color layout (ported from lgc.h):
///
///   bit 0: WHITE0 (white color type 0)
///   bit 1: WHITE1 (white color type 1)
///   bit 2: BLACK  (fully traversed)
///   bit 3: KEYWEAK (tables with __mode 'k') / FINALIZED (userdata)
///   bit 4: FIXED  (luaS_fix -- reserved words, tmnames; native writes this)
///   bit 5: VALUEWEAK (tables with __mode 'v')
///   bits 6-7: unused
///
/// Colors: WHITE = either white bit set. GRAY = no white, no black.
///         BLACK = bit 2 set. Dead = has "other white" (opposite of current).
///
/// CRITICAL: upvalues in Lua closures use the WHOLE BYTE as a "processed"
/// flag (TEST AL, AL at 0x6F7828). During mark, we set upval marked = 1
/// (which is WHITE0). The native check sees non-zero and skips. This is
/// compatible because we only need the skip behavior during a single cycle.
pub const OBJ_marked: u32 = 0x05;

// Tri-color bit positions (matching Lua 5.1 lgc.h)
pub const WHITE0BIT: u3 = 0;
pub const WHITE1BIT: u3 = 1;
pub const BLACKBIT: u3 = 2;
pub const KEYWEAKBIT: u3 = 3;
pub const FINALIZEDBIT: u3 = 3; // shared with KEYWEAK (different types)
pub const FIXEDBIT: u3 = 4;
pub const VALUEWEAKBIT: u3 = 5;

pub const WHITEBITS: u8 = (1 << WHITE0BIT) | (1 << WHITE1BIT); // 0x03
pub const KEYWEAK: u8 = 1 << KEYWEAKBIT; // 0x08
pub const VALUEWEAK: u8 = 1 << VALUEWEAKBIT; // 0x20

/// Mask to clear color bits (WHITE0|WHITE1|BLACK) while preserving flags.
/// Used by makewhite: marked = (marked & MASKMARKS) | currentwhite
pub const MASKMARKS: u8 = ~@as(u8, WHITEBITS | (1 << BLACKBIT)); // ~0x07 = 0xF8

/// ---------------------------------------------------------------------------
// Type tags (from propagate dispatch at 0x6F7510 + standard Lua 5.0)
/// ---------------------------------------------------------------------------

pub const LUA_TNONE: u8 = 0xFF; // -1 as u8, marks dead keys in hash nodes
pub const LUA_TNIL: u8 = 0;
pub const LUA_TBOOLEAN: u8 = 1;
pub const LUA_TLIGHTUSERDATA: u8 = 2;
pub const LUA_TNUMBER: u8 = 3;
pub const LUA_TSTRING: u8 = 4;
pub const LUA_TTABLE: u8 = 5;
pub const LUA_TFUNCTION: u8 = 6;
pub const LUA_TUSERDATA: u8 = 7;
pub const LUA_TTHREAD: u8 = 8;
pub const LUA_TPROTO: u8 = 9;

/// ---------------------------------------------------------------------------
// TValue (16 bytes in WoW Lua 5.0)
//
// Verified from mark_table array loop:
//   0x6F766A: SHL ESI, 0x4      ; count * 16 = TValue stride
//   0x6F7673: SUB ESI, 0x10     ; decrement by 16 per iteration
//   0x6F7680: MOV EAX, [EAX+0x8] ; gcptr at +0x08 (earlier CMP at +0x00 for tt)
/// ---------------------------------------------------------------------------

pub const TVALUE_size: u32 = 16;
pub const TVALUE_tt: u32 = 0x00;
pub const TVALUE_gcptr: u32 = 0x08;

/// ---------------------------------------------------------------------------
// Table struct
//
// Verified from mark_table 0x6F7590:
//   0x6F759D: MOV EDX, [EDI+0x08]    ; metatable
//   0x6F7661: MOV EAX, [EDI+0x1C]    ; sizearray (used as int count)
//   0x6F7670: MOV EAX, [EDI+0x0C]    ; array pointer (dereferenced)
//   0x6F7697: MOV CL, [EDI+0x07]     ; lsizenode (u8)
//   0x6F769A: MOV EAX, 1
//   0x6F769F: SHL EAX, CL             ; sizenode = 1 << lsizenode
//   0x6F76B0: MOV ESI, [EDI+0x10]    ; node pointer
/// ---------------------------------------------------------------------------

pub const TABLE_flags: u32 = 0x06;      // TM cache / weak flags (also in marked byte)
pub const TABLE_lsizenode: u32 = 0x07;  // u8: log2 of sizenode
pub const TABLE_metatable: u32 = 0x08;  // Table* metatable
pub const TABLE_array: u32 = 0x0C;      // TValue* array part
pub const TABLE_node: u32 = 0x10;       // Node*  hash part
pub const TABLE_sizearray: u32 = 0x1C;  // int size of array part

/// ---------------------------------------------------------------------------
// Node (hash bucket, 40 bytes)
//
// Verified from mark_table node loop (0x6F76B0-0x6F76FE):
//   0x6F76A5: LEA EBX, [EAX+EAX*4]   ; count*5
//   0x6F76A8: SHL EBX, 0x3            ; count*40 = Node size * count
//   0x6F76B6: MOV EAX, [ESI+EBX+0x10] ; value.tt at node+0x10
//   0x6F76BC: TEST EAX, EAX           ; skip dead nodes (nil value)
//   0x6F76C0: CMP [ESI], 0x4           ; key.tt at node+0x00
//   0x6F76C5: MOV EDX, [ESI+0x08]     ; key.gcptr at node+0x08
//   0x6F76E3: MOV EDX, [ESI+0x18]     ; value.gcptr at node+0x18
//
// Iteration goes count-1 down to 0 (full 0-indexed range), NOT starting at 1.
/// ---------------------------------------------------------------------------

pub const NODE_size: u32 = 40;
pub const NODE_key_tt: u32 = 0x00;
pub const NODE_key_gcptr: u32 = 0x08;
pub const NODE_value_tt: u32 = 0x10;
pub const NODE_value_gcptr: u32 = 0x18;
pub const NODE_next: u32 = 0x20;

/// ---------------------------------------------------------------------------
// Closure (from mark_closure 0x6F77B0)
//
// Verified:
//   0x6F77B9: MOV AL, [EDI+0x06]    ; isC flag
//   0x6F77C0: MOV AL, [EDI+0x07]    ; nupvalues (u8)
//
// C closure branch (LEA ESI, [EDI+0x18] then [ESI-8]/[ESI] with stride 16):
//   elements start at cl+0x10, each 16 bytes (TValue)
//   tt at element+0x00, gcptr at element+0x08
//
// Lua closure branch (0x6F77F6-0x6F7854):
//   0x6F77F6: MOV EDX, [EDI+0x18]   ; mark this pointer
//   0x6F7804: MOV EDX, [EDI+0x0C]   ; mark this pointer
//   0x6F7820: LEA EBX, [EDI+0x20]   ; upval pointer array start
//   0x6F7823: MOV ESI, [EBX]         ; ESI = upvals[i] (the UpVal* itself)
//   upval ptr array stride = 4 bytes per entry
/// ---------------------------------------------------------------------------

pub const CLOSURE_isC: u32 = 0x06;
pub const CLOSURE_nupvalues: u32 = 0x07;

/// First pointer marked for Lua closures (see disasm above).
pub const CLOSURE_lua_mark1: u32 = 0x18;
/// Second pointer marked for Lua closures.
pub const CLOSURE_lua_mark2: u32 = 0x0C;

/// C closure: upvalue array (inline TValues, each 16 bytes) starts here.
pub const CLOSURE_c_upvals: u32 = 0x10;

/// Lua closure: upvalue POINTER array (each 4 bytes = UpVal*) starts here.
pub const CLOSURE_lua_upval_ptrs: u32 = 0x20;

/// ---------------------------------------------------------------------------
// UpVal (verified from mark_closure's Lua upvalue loop 0x6F7820-0x6F7840)
//
//   0x6F7823: MOV ESI, [EBX]        ; ESI = UpVal* (upvals[i])
//   0x6F7825: MOV AL, [ESI+0x05]    ; marked byte
//   0x6F7828: TEST AL, AL            ; any non-zero = skip (whole byte)
//   0x6F782C: CMP [ESI+0x10], 0x4   ; value.tt at upv+0x10
//   0x6F7832: MOV EDX, [ESI+0x18]   ; value.gcptr at upv+0x18
//   0x6F7840: MOV byte [ESI+0x05], 0x01 ; mark as processed
/// ---------------------------------------------------------------------------

pub const UPVAL_marked: u32 = 0x05;
pub const UPVAL_value_tt: u32 = 0x10;
pub const UPVAL_value_gcptr: u32 = 0x18;

/// ---------------------------------------------------------------------------
// Thread / lua_State (from mark_thread 0x6F7860)
//
// Verified:
//   0x6F7869: CMP [EDI+0x40], 0x4   ; gt.tt at thread+0x40 (TValue)
//   0x6F7872: MOV EDX, [EDI+0x48]   ; gt.gcptr at thread+0x48
//   0x6F7880: MOV EAX, [EDI+0x28]   ; base_ci pointer (CallInfo*)
//   0x6F7883: MOV ESI, [EDI+0x14]   ; ci pointer (CallInfo*)
//   0x6F7888: MOV ECX, [EDI+0x08]   ; top (StkId)
//   0x6F78A6: MOV ESI, [EDI+0x1C]   ; stack base (StkId)
//
// Stack iteration (0x6F78B0-0x6F78CE):
//   stride 16 bytes per slot (TValue)
//   tt at slot+0x00, gcptr at slot+0x08
//   loop: from [thread+0x1C] to [thread+0x08]
//
// CallInfo iteration stride: 24 bytes (0x18) — used to find max stack top.
/// ---------------------------------------------------------------------------

pub const THREAD_top: u32 = 0x08;              // StkId top
pub const THREAD_ci: u32 = 0x14;               // CallInfo* current
pub const THREAD_stack: u32 = 0x1C;            // StkId base (first slot)
pub const THREAD_base_ci: u32 = 0x28;          // CallInfo* base
pub const THREAD_gt_tt: u32 = 0x40;            // gt.tt (TValue holding globals)
pub const THREAD_gt_gcptr: u32 = 0x48;         // gt.gcptr

/// ---------------------------------------------------------------------------
// Proto (from mark_proto 0x6F7710)
//
// Verified:
//   0x6F7714: MOV EAX, [ESI+0x20]   ; source (TString*)
//   0x6F7727: MOV EAX, [ESI+0x08]   ; k (constants array TValue*)
//   0x6F772A: tt read from EAX + offset (start of TValue)
//   0x6F772F: CMP EBX, 0x4           ; check tt == LUA_TSTRING (stringmark only)
//   0x6F7734: MOV EAX, [EAX+0x08]   ; gcptr at TValue+0x08
//   0x6F773F: ADD EDX, 0x10          ; stride 16 (TValue)
//   0x6F773B: MOV EAX, [ESI+0x28]   ; sizek at proto+0x28
//   0x6F7746: MOV EDX, [ESI+0x24]   ; sizeupvalues at proto+0x24
//   0x6F7750: MOV EDX, [ESI+0x1C]   ; upvalues array (TString*) at proto+0x1C
//   0x6F7762: MOV EAX, [ESI+0x34]   ; sizep at proto+0x34
//   0x6F7770: MOV EAX, [ESI+0x10]   ; p (nested Proto** array) at proto+0x10
//   0x6F7789: MOV EAX, [ESI+0x38]   ; sizelocvars at proto+0x38
//   0x6F7794: MOV EAX, [ESI+0x18]   ; locvars array at proto+0x18
//   0x6F77A2: ADD EDX, 0x0C          ; LocVar stride 12
/// ---------------------------------------------------------------------------

pub const PROTO_k: u32 = 0x08;            // TValue* constants array
pub const PROTO_p: u32 = 0x10;            // Proto** nested protos array
pub const PROTO_locvars: u32 = 0x18;      // LocVar* (12 bytes each)
pub const PROTO_upvalues: u32 = 0x1C;     // TString** upvalue names
pub const PROTO_source: u32 = 0x20;       // TString* source
pub const PROTO_sizeupvalues: u32 = 0x24; // int
pub const PROTO_sizek: u32 = 0x28;        // int
pub const PROTO_sizep: u32 = 0x34;        // int
pub const PROTO_sizelocvars: u32 = 0x38;  // int

pub const LOCVAR_size: u32 = 12;

/// ---------------------------------------------------------------------------
// lua_State non-thread fields (not all threads, just the active L pointer)
/// ---------------------------------------------------------------------------

/// Pointer to global_State (at L + 0x10).
pub const L_global: u32 = 0x10;

/// Check if a lua_State is active. When the state is being destroyed,
/// the game stores 0 in L+0x60.
pub const L_active_check: u32 = 0x60;

/// ---------------------------------------------------------------------------
// Userdata (from reallymarkobject LUA_TUSERDATA case)
//
// Udata layout (Lua 5.0):
//   CommonHeader (next+0x00, tt+0x04, marked+0x05)
//   metatable at +0x08 (same offset as Table.metatable)
//   len at +0x0C
/// ---------------------------------------------------------------------------

pub const UDATA_metatable: u32 = 0x08;

/// ---------------------------------------------------------------------------
// Constants
/// ---------------------------------------------------------------------------

/// Number of objects to process per incremental step.
/// ~200k objects in ~80ms = ~400ns/object → 5000 ≈ 2ms/step.
pub const CHUNK_SIZE: u32 = 5000;

/// Headroom added to totalbytes when setting gcthreshold between steps.
pub const BATCH_HEADROOM: u32 = 128 * 1024;
