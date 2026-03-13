/*
 * GetOrCreateCharacterGlyph (0x005CA2D0)
 * WoW 1.12.1 (build 5875) -- Font/glyph caching function
 * #2 CPU hotspot at 3.65%
 *
 * Decompiled via Ghidra 11.4.2, with manual analysis annotations.
 *
 * ==========================================================================
 * CALLING CONVENTION (verified from assembly)
 * ==========================================================================
 *
 * Convention: __thiscall
 *   - ECX = this pointer (FontObject*)
 *   - [EBP+0x08] = param1: charCode (uint32 -- used as hash key, loaded into EBX)
 *   - [EBP+0x0C] = param2: secondary key / flags (uint32 -- loaded into ESI initially)
 *   - RET 0x8 => 2 stack params (8 bytes), caller does NOT clean up
 *   - Returns: float in ST(0) (FPU register) -- the glyph width
 *   - Also stores width at entry+0x1C in the glyph hash entry
 *
 * Evidence:
 *   0x005ca2d0  PUSH EBP
 *   0x005ca2d1  MOV EBP,ESP
 *   0x005ca2d7  MOV EBX,dword ptr [EBP + 0x8]    ; param1 = charCode
 *   0x005ca2e0  MOV ESI,dword ptr [EBP + 0xc]    ; param2
 *   0x005ca2ef  MOV EAX,dword ptr [ECX + 0x60]   ; this->hashMask
 *   0x005ca2f9  MOV dword ptr [EBP + -0x4],ECX   ; save this
 *   ...
 *   0x005ca431  RET 0x8                           ; cleans 2 dword params
 *   0x005ca4a0  RET 0x8                           ; early-out path also cleans 8
 *
 * The Ghidra decompiler shows float10 return types and __return_storage_ptr__
 * which is WRONG. The function returns a float via ST(0) and also returns
 * the glyph entry pointer via EDI (used by callers).
 *
 * ==========================================================================
 * STRUCTURE LAYOUT (inferred from assembly)
 * ==========================================================================
 *
 * FontObject (this):
 *   +0x3C: GlyphAllocator (base of allocator struct, size ~0x28)
 *     +0x3C+0x00 = +0x3C: vtable ptr (allocator vtable)
 *     +0x3C+0x04 = +0x40: linked list struct (for KerningListSpliceOperation)
 *     +0x3C+0x14 = +0x50: kerning hash table base
 *     +0x3C+0x1C = +0x58: hash bucket array ptr
 *     +0x3C+0x24 = +0x60: hash mask (0xFFFFFFFF = uninitialized, else power-of-2 minus 1)
 *   +0x70: text string data index/ptr
 *   +0x188: float -- texture scale factor (multiplied with texture size)
 *
 * GlyphHashEntry (returned in EDI, allocated at +0x3C):
 *   +0x00: charCode (uint32 -- the hash key, matches param1)
 *   +0x04: next ptr offset (for chaining in hash bucket)
 *   +0x14: combined key (charCode<<16 ^ param2, masked)
 *   +0x18: flags (bit 1 = "rendered/valid" flag)
 *   +0x1C: glyph width (float, stored from ST(0))
 *
 * Hash bucket entry (0x0C bytes each):
 *   +0x00: next-link offset
 *   +0x04: first entry ptr (low bit set = sentinel/empty)
 *   +0x08: (used by hash lookup)
 *
 * ==========================================================================
 * ALGORITHM SUMMARY
 * ==========================================================================
 *
 * 1. Compute combined hash key: EDX = (charCode << 16) ^ (param2 & 0xFFFF) ^ (charCode << 16)
 *    This creates a hash combining the char code and secondary parameter.
 *
 * 2. If hash table is initialized (mask != -1), search the hash chain:
 *    - bucket = hashBuckets[mask & charCode]
 *    - Walk linked list, comparing entry->charCode == charCode AND entry->combinedKey == EDX
 *    - If found AND flags bit 1 is set: early return with cached width from +0x1C (HOT PATH)
 *    - If found but not rendered: fall through to rendering
 *
 * 3. If not found or hash uninitialized:
 *    - Get font texture data via GetTextStringData(this->+0x70)
 *    - Get driver function info (getCurrentDriverFunction x2)
 *    - Optionally get texture size if flag 0x40 set
 *    - Call FindCharacterInFont(this, charCode) to locate glyph in font
 *    - Compute width: (float)textureSize * this->+0x188 + FindCharacterInFont_result
 *
 * 4. If glyph entry doesn't exist yet:
 *    - Initialize hash table if needed (mask=-1 -> set mask=3, resize to 4 buckets)
 *    - Allocate new entry via AllocateCharacterHashEntry
 *    - Insert into hash chain via vtable call and KerningListSpliceOperation
 *    - Store charCode and combined key in entry
 *
 * 5. Set rendered flag (|= 2), call roundFloatWithValidation on width,
 *    store at entry+0x1C, return via ST(0).
 *
 * ==========================================================================
 * PERFORMANCE NOTES
 * ==========================================================================
 *
 * The hot path is the hash lookup (step 2). When the glyph is already cached
 * and rendered (flags & 2), it returns immediately at 0x5ca497-0x5ca4a0.
 * The hash uses a simple mask-and-chain approach with 0xC-byte bucket entries.
 *
 * At 3.65% CPU, the bottleneck is likely:
 * - Hash chain traversal (cache misses on linked list walk)
 * - Called extremely frequently (6 callers, all text measurement/rendering)
 * - The hash table starts small (4 buckets) and may have long chains
 *
 * ==========================================================================
 * GHIDRA DECOMPILATION (raw, for reference)
 * ==========================================================================
 */

/* NOTE: Ghidra's decompiled output below is misleading in several ways:
 *   1. float10/__return_storage_ptr__ types are artifacts of FPU return
 *   2. The "param_1" and "param_2" naming doesn't match stack layout
 *   3. Some pointer arithmetic is obfuscated by Ghidra's type inference
 *
 * Corrected prototype:
 *   float __thiscall GetOrCreateCharacterGlyph(FontObject* this, uint32 charCode, uint32 param2)
 *   Returns: float in ST(0), glyph entry ptr in EDI
 */

float10 * __thiscall
GetOrCreateCharacterGlyph
          (void *this,float10 *__return_storage_ptr__,float10 *param_1,float10 *param_2)
{
  float10 **ppfVar1;
  float10 *pfVar2;
  undefined *puVar3;
  undefined *puVar4;
  float10 *pfVar5;
  undefined4 unaff_ESI;
  uint unaff_EDI;
  uint uVar6;
  float10 extraout_ST0;
  float10 extraout_ST0_00;
  undefined *local_18;
  undefined *local_10;
  undefined *local_c;
  undefined *local_8;

  pfVar2 = __return_storage_ptr__;
  local_10 = (undefined *)((uint)param_1 & 0xffff ^ (int)__return_storage_ptr__ << 0x10);
  if (*(uint *)((int)this + 0x60) != 0xffffffff) {
    pfVar5 = *(float10 **)
              (*(int *)((int)this + 0x58) +
               (*(uint *)((int)this + 0x60) & (uint)__return_storage_ptr__) * 0xc + 8);
    if ((((uint)pfVar5 & 1) != 0) || (pfVar5 == (float10 *)0x0)) {
      pfVar5 = (float10 *)0x0;
    }
    for (; (((uint)pfVar5 & 1) == 0 && (pfVar5 != (float10 *)0x0));
        pfVar5 = *(float10 **)
                  ((int)pfVar5 +
                  *(int *)(*(int *)((int)this + 0x58) +
                          (*(uint *)((int)this + 0x60) & (uint)__return_storage_ptr__) * 0xc) + 4))
    {
      if (*(float10 **)pfVar5 == __return_storage_ptr__) {
        ppfVar1 = (float10 **)((int)pfVar5 + 0x14);
        if ((ppfVar1 == &__return_storage_ptr__) || (*ppfVar1 == (float10 *)local_10)) {
          __return_storage_ptr__ = pfVar5;
          if ((*(byte *)((int)pfVar5 + 0x18) & 2) != 0) {
            return (float10 *)ppfVar1;
          }
          goto LAB_005ca30c;
        }
      }
    }
  }
  __return_storage_ptr__ = (float10 *)0x0;
LAB_005ca30c:
  local_8 = (undefined *)this;
  puVar3 = GetTextStringData(*(int *)((int)this + 0x70));
  local_c = getCurrentDriverFunction((int)puVar3);
  puVar4 = getCurrentDriverFunction((int)puVar3);
  local_18 = (undefined *)0x0;
  if ((puVar3[8] & 0x40) != 0) {
    getTextureSize(puVar3,puVar4,2,(uint *)&local_18);
    local_18 = (undefined *)((-1 < (int)local_18) - 1 & (uint)local_18);
  }
  puVar3 = local_8;
  FindCharacterInFont(local_8,pfVar2,unaff_EDI);
  pfVar5 = __return_storage_ptr__;
  local_c = (undefined *)
            (float)((float10)(int)local_18 * (float10)*(float *)(puVar3 + 0x188) + extraout_ST0);
  if (__return_storage_ptr__ == (float10 *)0x0) {
    if (*(int *)((int)this + 0x60) == -1) {
      *(undefined4 *)((int)this + 0x60) = 3;
      ResizeKerningHashTable((void *)((int)this + 0x50),4);
      param_1 = pfVar5;
      uVar6 = 0;
      do {
        ClearAndResizeKerningList((void *)(*(int *)((int)this + 0x58) + (int)param_1),4);
        uVar6 = uVar6 + 1;
        param_1 = (float10 *)((int)param_1 + 0xc);
      } while (uVar6 <= *(uint *)((int)this + 0x60));
    }
    uVar6 = *(uint *)((int)this + 0x60) & (uint)pfVar2;
    puVar3 = AllocateCharacterHashEntry((int *)((int)this + 0x3c),uVar6);
    if (puVar3 != (undefined *)0x0) {
      uVar6 = *(uint *)((int)this + 0x60) & (uint)pfVar2;
    }
    pfVar5 = (float10 *)
             (**(code **)(*(int *)((int)this + 0x3c) + 4))
                       (*(int *)((int)this + 0x58) + uVar6 * 0xc,0);
    KerningListSpliceOperation((void *)((int)this + 0x40),(int *)pfVar5,2,0);
    *(float10 **)pfVar5 = pfVar2;
    __return_storage_ptr__ = pfVar5;
    if ((float10 **)((int)pfVar5 + 0x14) != &param_1) {
      *(float10 **)((int)pfVar5 + 0x14) = (float10 *)local_10;
    }
  }
  pfVar2 = __return_storage_ptr__;
  *(uint *)((int)__return_storage_ptr__ + 0x18) = *(uint *)((int)__return_storage_ptr__ + 0x18) | 2;
  pfVar5 = roundFloatWithValidation
                     (SUB84((double)(float)local_c,0),(double)CONCAT44(unaff_ESI,unaff_EDI));
  *(float *)((int)pfVar2 + 0x1c) = (float)extraout_ST0_00;
  return pfVar5;
}


/*
 * ==========================================================================
 * FULL DISASSEMBLY
 * ==========================================================================
 */

/*
0x005ca2d0  PUSH EBP
0x005ca2d1  MOV EBP,ESP
0x005ca2d3  SUB ESP,0x14
0x005ca2d6  PUSH EBX
0x005ca2d7  MOV EBX,dword ptr [EBP + 0x8]       ; EBX = charCode (param1)
0x005ca2da  MOV EAX,EBX
0x005ca2dc  SHL EAX,0x10                         ; EAX = charCode << 16
0x005ca2df  PUSH ESI
0x005ca2e0  MOV ESI,dword ptr [EBP + 0xc]       ; ESI = param2
0x005ca2e3  MOV EDX,EAX
0x005ca2e5  XOR EDX,ESI                          ; EDX = (charCode<<16) ^ param2
0x005ca2e7  AND EDX,0xffff                       ; EDX = low 16 bits
0x005ca2ed  XOR EDX,EAX                          ; EDX = combinedKey = (charCode<<16) | (param2 ^ charCode) & 0xFFFF
0x005ca2ef  MOV EAX,dword ptr [ECX + 0x60]       ; EAX = this->hashMask
0x005ca2f2  CMP EAX,-0x1                         ; if hashMask == -1 (uninitialized)
0x005ca2f5  LEA ESI,[ECX + 0x3c]                 ; ESI = &this->glyphAllocator
0x005ca2f8  PUSH EDI
0x005ca2f9  MOV dword ptr [EBP + -0x4],ECX       ; local_this = ECX
0x005ca2fc  MOV dword ptr [EBP + -0xc],EDX       ; local_combinedKey = EDX
0x005ca2ff  JNZ 0x005ca434                       ; if initialized, jump to hash lookup

; --- Hash not initialized or entry not found: compute glyph ---
0x005ca305  MOV dword ptr [EBP + 0x8],0x0        ; foundEntry = NULL
0x005ca30c  MOV ECX,dword ptr [EBP + -0x4]       ; ECX = this
0x005ca30f  MOV ECX,dword ptr [ECX + 0x70]       ; ECX = this->textStringDataIdx
0x005ca312  CALL 0x005d0370                       ; GetTextStringData(ECX) -> EAX = textData
0x005ca317  MOV EDI,EAX                          ; EDI = textData
0x005ca319  MOV EDX,EBX                          ; EDX = charCode (2nd param for fastcall)
0x005ca31b  MOV ECX,EDI                          ; ECX = textData (this for thiscall)
0x005ca31d  CALL 0x007ce960                       ; getCurrentDriverFunction(textData, charCode) -> EAX
0x005ca322  MOV EDX,dword ptr [EBP + 0xc]        ; EDX = param2
0x005ca325  MOV ECX,EDI                          ; ECX = textData
0x005ca327  MOV dword ptr [EBP + -0x8],EAX       ; local_driverResult1 = EAX
0x005ca32a  CALL 0x007ce960                       ; getCurrentDriverFunction(textData, param2) -> EAX
0x005ca32f  MOV dword ptr [EBP + -0x14],0x0      ; textureSize = 0
0x005ca336  TEST byte ptr [EDI + 0x8],0x40        ; if textData->flags & 0x40
0x005ca33a  JZ 0x005ca35d                        ; skip texture size query

; --- Get texture size (optional) ---
0x005ca33c  LEA EDX,[EBP + -0x14]
0x005ca33f  PUSH EDX                             ; &textureSize (out param)
0x005ca340  MOV EDX,dword ptr [EBP + -0x8]       ; driverResult1
0x005ca343  PUSH 0x2                             ; dimension=2
0x005ca345  PUSH EAX                             ; driverResult2
0x005ca346  MOV ECX,EDI                          ; textData
0x005ca348  CALL 0x007ce830                       ; getTextureSize(textData, dr2, 2, &textureSize)
0x005ca34d  MOV EAX,dword ptr [EBP + -0x14]
0x005ca350  XOR ECX,ECX
0x005ca352  TEST EAX,EAX
0x005ca354  SETGE CL                             ; CL = (textureSize >= 0) ? 1 : 0
0x005ca357  DEC ECX                              ; ECX = (>=0) ? 0 : -1
0x005ca358  AND ECX,EAX                          ; ECX = (>=0) ? 0 : textureSize (clamp negative to 0... wait)
                                                 ; Actually: SETGE+DEC gives 0 if >=0, -1 if <0
                                                 ; AND with EAX: >=0 -> 0&val=0... NO:
                                                 ; SETGE CL: >=0 -> CL=1, DEC -> 0, AND -> 0
                                                 ; <0 -> CL=0, DEC -> -1(0xFFFFFFFF), AND -> EAX
                                                 ; So this CLAMPS POSITIVE TO ZERO, keeps negative?
                                                 ; That seems wrong. Let me re-read...
                                                 ; Actually SETGE = set if SF==OF. For TEST EAX,EAX:
                                                 ;   EAX >= 0 -> SF=0,OF=0 -> GE true -> CL=1
                                                 ;   EAX < 0  -> SF=1,OF=0 -> GE false -> CL=0
                                                 ; So: >=0: CL=1, DEC->0, AND EAX -> 0. WRONG.
                                                 ; <0: CL=0, DEC->0xFFFFFFFF, AND EAX -> EAX.
                                                 ; This clamps positive values to 0 and keeps negative??
                                                 ; More likely: the intent is max(0, textureSize).
                                                 ; Re-examining: TEST EAX,EAX / SETGE CL / DEC ECX / AND ECX,EAX
                                                 ; If EAX >= 0: ECX = (1-1) & EAX = 0 & EAX = 0  -- WRONG for max(0,x)
                                                 ; If EAX < 0:  ECX = (0-1) & EAX = 0xFFFFFFFF & EAX = EAX -- keeps negative
                                                 ; This is actually: (EAX < 0) ? EAX : 0  i.e. min(0, EAX)
                                                 ; Which means textureSize = min(0, textureSize). Clamp positive to 0.
                                                 ; Likely the texture size is a signed delta/offset that should be <= 0.
0x005ca35a  MOV dword ptr [EBP + -0x14],ECX

; --- Find character in font ---
0x005ca35d  MOV EDI,dword ptr [EBP + -0x4]       ; EDI = this
0x005ca360  PUSH EBX                             ; charCode
0x005ca361  MOV ECX,EDI                          ; this
0x005ca363  CALL 0x005ca240                       ; FindCharacterInFont(this, charCode) -> ST(0) = glyph advance
0x005ca368  FILD dword ptr [EBP + -0x14]          ; push (float)textureSize onto FPU
0x005ca36b  FMUL float ptr [EDI + 0x188]          ; * this->textureScale
0x005ca371  MOV EDI,dword ptr [EBP + 0x8]        ; EDI = foundEntry (from hash lookup or NULL)
0x005ca374  TEST EDI,EDI
0x005ca376  FADDP                                ; ST(0) = FindCharacterInFont_result + textureSize * textureScale
0x005ca378  FSTP float ptr [EBP + -0x8]           ; local_width = ST(0)
0x005ca37b  JNZ 0x005ca40e                       ; if foundEntry != NULL, skip allocation

; --- Allocate new hash entry ---
0x005ca381  CMP dword ptr [ESI + 0x24],-0x1      ; this->hashMask == -1?
0x005ca385  JNZ 0x005ca3c0                       ; if initialized, skip init
0x005ca387  PUSH 0x4
0x005ca389  LEA ECX,[ESI + 0x14]                 ; &this->kerningHashTable
0x005ca38c  MOV dword ptr [ESI + 0x24],0x3       ; hashMask = 3 (4 buckets)
0x005ca393  CALL 0x005cc730                       ; ResizeKerningHashTable(&hashTable, 4)
0x005ca398  MOV dword ptr [EBP + 0xc],EDI        ; counter = 0 (EDI was 0)
0x005ca39b  NOP
0x005ca39c  LEA ESP,[ESP]                        ; alignment padding

; --- Initialize each bucket ---
0x005ca3a0  MOV ECX,dword ptr [ESI + 0x1c]       ; bucketArray
0x005ca3a3  MOV EAX,dword ptr [EBP + 0xc]        ; offset
0x005ca3a6  PUSH 0x4
0x005ca3a8  ADD ECX,EAX                          ; &bucketArray[offset]
0x005ca3aa  CALL 0x005cbd50                       ; ClearAndResizeKerningList(bucket, 4)
0x005ca3af  MOV ECX,dword ptr [EBP + 0xc]
0x005ca3b2  MOV EAX,dword ptr [ESI + 0x24]       ; hashMask
0x005ca3b5  INC EDI                              ; counter++
0x005ca3b6  ADD ECX,0xc                          ; offset += 0xC (bucket size)
0x005ca3b9  CMP EDI,EAX                          ; counter <= hashMask
0x005ca3bb  MOV dword ptr [EBP + 0xc],ECX
0x005ca3be  JBE 0x005ca3a0                       ; loop

; --- Allocate entry in hash ---
0x005ca3c0  MOV EDI,dword ptr [ESI + 0x24]       ; hashMask
0x005ca3c3  AND EDI,EBX                          ; bucketIdx = hashMask & charCode
0x005ca3c5  PUSH EDI
0x005ca3c6  MOV ECX,ESI                          ; &glyphAllocator
0x005ca3c8  CALL 0x005cc290                       ; AllocateCharacterHashEntry(&allocator, bucketIdx)
0x005ca3cd  TEST EAX,EAX
0x005ca3cf  JZ 0x005ca3d6
0x005ca3d1  MOV EDI,dword ptr [ESI + 0x24]       ; re-read hashMask (may have changed due to resize)
0x005ca3d4  AND EDI,EBX                          ; bucketIdx = hashMask & charCode

0x005ca3d6  MOV ECX,dword ptr [ESI + 0x1c]       ; bucketArray
0x005ca3d9  MOV EDX,dword ptr [ESI]              ; vtable
0x005ca3db  PUSH 0x0
0x005ca3dd  LEA EAX,[EDI + EDI*0x2]              ; EAX = bucketIdx * 3
0x005ca3e0  LEA EAX,[ECX + EAX*0x4]              ; EAX = &bucketArray[bucketIdx * 0xC]
0x005ca3e3  PUSH 0x0
0x005ca3e5  PUSH EAX                             ; bucket ptr
0x005ca3e6  MOV ECX,ESI                          ; &glyphAllocator
0x005ca3e8  CALL dword ptr [EDX + 0x4]            ; vtable[1](allocator, bucket, 0, 0) -> new entry
0x005ca3eb  PUSH 0x0
0x005ca3ed  MOV EDI,EAX                          ; EDI = newEntry
0x005ca3ef  PUSH 0x2
0x005ca3f1  PUSH EDI
0x005ca3f2  LEA ECX,[ESI + 0x4]                  ; &this->linkedList
0x005ca3f5  CALL 0x005cc4d0                       ; KerningListSpliceOperation(&list, newEntry, 2, 0)
0x005ca3fa  LEA EAX,[EDI + 0x14]                 ; &newEntry->combinedKey
0x005ca3fd  LEA ECX,[EBP + 0xc]                  ; &param2 on stack (self-pointer check)
0x005ca400  CMP EAX,ECX
0x005ca402  MOV dword ptr [EDI],EBX              ; newEntry->charCode = charCode
0x005ca404  JZ 0x005ca40b                        ; skip if self-referencing
0x005ca406  MOV EDX,dword ptr [EBP + -0xc]       ; combinedKey
0x005ca409  MOV dword ptr [EAX],EDX              ; newEntry->combinedKey = combinedKey
0x005ca40b  MOV dword ptr [EBP + 0x8],EDI        ; foundEntry = newEntry

; --- Store width and return ---
0x005ca40e  MOV EDX,dword ptr [EDI + 0x18]       ; entry->flags
0x005ca411  FLD float ptr [EBP + -0x8]            ; load computed width
0x005ca414  OR EDX,0x2                           ; flags |= RENDERED
0x005ca417  SUB ESP,0x8
0x005ca41a  FSTP double ptr [ESP]                 ; push as double (for roundFloatWithValidation)
0x005ca41d  MOV dword ptr [EDI + 0x18],EDX       ; entry->flags = flags | RENDERED
0x005ca420  CALL 0x0073fdf5                       ; roundFloatWithValidation(width_as_double)
0x005ca425  FST float ptr [EDI + 0x1c]            ; entry->width = rounded result
0x005ca428  ADD ESP,0x8                          ; clean up double param
0x005ca42b  POP EDI
0x005ca42c  POP ESI
0x005ca42d  POP EBX
0x005ca42e  MOV ESP,EBP
0x005ca430  POP EBP
0x005ca431  RET 0x8                              ; clean 2 dword params, return ST(0)

; --- Hash lookup (jumped to from 0x5ca2ff when hash is initialized) ---
0x005ca434  MOV ECX,dword ptr [ESI + 0x1c]       ; bucketArray
0x005ca437  AND EAX,EBX                          ; bucketIdx = hashMask & charCode
0x005ca439  LEA EAX,[EAX + EAX*0x2]              ; * 3
0x005ca43c  LEA EAX,[ECX + EAX*0x4 + 0x4]        ; &bucket[idx].firstEntry (skip +0 next-link offset)
                                                  ; Actually: bucket base + idx*0xC + 0x4
0x005ca440  MOV ECX,dword ptr [EAX + 0x4]        ; ECX = bucket[idx]+0x8 = first entry ptr
0x005ca443  TEST CL,0x1                          ; sentinel check (low bit)
0x005ca446  JNZ 0x005ca44c
0x005ca448  TEST ECX,ECX                         ; NULL check
0x005ca44a  JNZ 0x005ca450
0x005ca44c  XOR ECX,ECX                          ; entry = NULL
0x005ca44e  MOV EDI,EDI                          ; NOP (alignment)

; --- Walk hash chain ---
0x005ca450  TEST CL,0x1                          ; sentinel?
0x005ca453  JNZ 0x005ca305                       ; -> not found, go compute
0x005ca459  TEST ECX,ECX                         ; NULL?
0x005ca45b  JZ 0x005ca305                        ; -> not found, go compute
0x005ca461  CMP dword ptr [ECX],EBX              ; entry->charCode == charCode?
0x005ca463  JNZ 0x005ca473                       ; no match, next entry
0x005ca465  LEA EAX,[ECX + 0x14]                 ; &entry->combinedKey
0x005ca468  LEA EDI,[EBP + 0x8]                  ; &param1 on stack (self-ref check)
0x005ca46b  CMP EAX,EDI
0x005ca46d  JZ 0x005ca48a                        ; self-ref -> match
0x005ca46f  CMP dword ptr [EAX],EDX              ; entry->combinedKey == combinedKey?
0x005ca471  JZ 0x005ca48a                        ; match!

; --- Next entry in chain ---
0x005ca473  MOV EAX,dword ptr [ESI + 0x24]       ; hashMask
0x005ca476  MOV EDI,dword ptr [ESI + 0x1c]       ; bucketArray
0x005ca479  AND EAX,EBX                          ; bucketIdx
0x005ca47b  LEA EAX,[EAX + EAX*0x2]              ; * 3
0x005ca47e  LEA EAX,[EDI + EAX*0x4]              ; &bucket[idx]
0x005ca481  MOV EAX,dword ptr [EAX]              ; bucket[idx].nextOffset
0x005ca483  ADD EAX,ECX                          ; entry + nextOffset
0x005ca485  MOV ECX,dword ptr [EAX + 0x4]        ; next entry ptr
0x005ca488  JMP 0x005ca450                       ; continue chain walk

; --- Found cached entry ---
0x005ca48a  TEST byte ptr [ECX + 0x18],0x2        ; entry->flags & RENDERED?
0x005ca48e  MOV dword ptr [EBP + 0x8],ECX        ; foundEntry = entry
0x005ca491  JZ 0x005ca30c                        ; not rendered yet, go compute width
0x005ca497  FLD float ptr [ECX + 0x1c]            ; ST(0) = entry->width (CACHED -- HOT PATH)
0x005ca49a  POP EDI
0x005ca49b  POP ESI
0x005ca49c  POP EBX
0x005ca49d  MOV ESP,EBP
0x005ca49f  POP EBP
0x005ca4a0  RET 0x8                              ; return cached width
*/


/*
 * ==========================================================================
 * XREFS TO 0x005CA2D0 (callers -- 6 call sites)
 * ==========================================================================
 *
 * 0x005c73b9 from MeasureTextLine           [UNCONDITIONAL_CALL]
 * 0x005c6be6 from MeasureTextWithFormatting  [UNCONDITIONAL_CALL]
 * 0x005c75cd from WrapTextWithLineBreaks     [UNCONDITIONAL_CALL]
 * 0x005ccda4 from RenderTextToVertexBuffer   [UNCONDITIONAL_CALL]
 * 0x005c6a74 from CalculateTextDimensions    [UNCONDITIONAL_CALL]
 * 0x005c6e44 from MeasureWrappedText         [UNCONDITIONAL_CALL]
 */


/*
 * ==========================================================================
 * XREFS FROM 0x005CA2D0 (callees -- function calls only)
 * ==========================================================================
 *
 * 0x005ca312 -> GetTextStringData            (0x005d0370) [CALL]
 * 0x005ca31d -> getCurrentDriverFunction      (0x007ce960) [CALL]  -- called twice (0x31d, 0x32a)
 * 0x005ca348 -> getTextureSize               (0x007ce830) [CALL]
 * 0x005ca363 -> FindCharacterInFont           (0x005ca240) [CALL]
 * 0x005ca393 -> ResizeKerningHashTable        (0x005cc730) [CALL]
 * 0x005ca3aa -> ClearAndResizeKerningList     (0x005cbd50) [CALL]
 * 0x005ca3c8 -> AllocateCharacterHashEntry    (0x005cc290) [CALL]
 * 0x005ca3e8 -> vtable[1] indirect call       (allocator virtual method)
 * 0x005ca3f5 -> KerningListSpliceOperation    (0x005cc4d0) [CALL]
 * 0x005ca420 -> roundFloatWithValidation      (0x0073fdf5) [CALL]
 */
