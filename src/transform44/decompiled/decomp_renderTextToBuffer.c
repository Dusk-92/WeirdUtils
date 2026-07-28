// =============================================================================
// renderTextToBuffer @ 0x005CDC20
// Decompiled from WoW.exe 1.12.1 (build 5875) via Ghidra 11.4.2
// Single caller of RenderTextToVertexBuffer (0x5CCBE0)
// =============================================================================

// -----------------------------------------------------------------------------
// CALLING CONVENTION (verified from assembly)
// -----------------------------------------------------------------------------
// __thiscall: ECX = this (text object ptr), saved to EBX immediately
//   0x005cdc20  PUSH EBP
//   0x005cdc21  MOV EBP,ESP
//   0x005cdc23  SUB ESP,0x74
//   0x005cdc26  PUSH EBX
//   0x005cdc27  PUSH ESI
//   0x005cdc28  MOV EBX,ECX          <-- this ptr saved to EBX
//   ...
//   0x005cdee8  RET                  <-- single RET, no stack cleanup = __thiscall (0 stack params)
//
// Signature: void __thiscall renderTextToBuffer(TextObject* this)
// No stack parameters. Single RET (no RET N).

// -----------------------------------------------------------------------------
// XREFS TO (callers)
// -----------------------------------------------------------------------------
// 0x005cd6aa  from validateAndPrepareText  (UNCONDITIONAL_CALL)
// 0x005cd426  from GetVertexBufferData      (UNCONDITIONAL_CALL)
//
// Two callers:
//   1. validateAndPrepareText (0x5cd6aa) -- validation/preparation path
//   2. GetVertexBufferData (0x5cd426)    -- vertex buffer retrieval path

// -----------------------------------------------------------------------------
// XREFS FROM (callees)
// -----------------------------------------------------------------------------
// 0x005c6fa0  ConvertPixelsToScreen
// 0x0040a2b0  __ftol                       (float-to-long)
// 0x005c2810  ParseTextFormatCodes
// 0x005c7260  WrapTextToWidth
// 0x005c7010  ConvertPixelsToScreenAlt
// 0x005ccbe0  RenderTextToVertexBuffer     <<<< the target
// 0x005cd310  AddRectangleToBuffer
// 0x005cdf70  finalizeTextLayout
// 0x005cd4d0  renderFadeEffect

// -----------------------------------------------------------------------------
// TEXT OBJECT FIELD MAP (offsets from this/EBX)
// -----------------------------------------------------------------------------
// +0x1c  float    lineHeight (or spacing-related metric)
// +0x28  float    xOffset (used when bit7 of flags is clear)
// +0x2c  float    color/style data (passed to RenderTextToVertexBuffer)
// +0x34  float    indentOrShadow (used when flags bit0 is set)
// +0x3c  float    maxWidth (passed to WrapTextToWidth)
// +0x40  float    maxHeight (vertical overflow check)
// +0x44  void*    fontObject (passed to WrapTextToWidth as ECX)
// +0x48  char*    textString (the actual text to render)
// +0x54  int      alignment (0=left, 1=center, 2=right)
// +0x58  float    some metric (initial value for local_c / line step)
// +0x5c  uint     flags bitfield:
//                   bit0: has indent/shadow
//                   bit1 (0x02): single-line mode (breaks loop after first line)
//                   bit5 (0x20): has fade effect
//                   bit7 (0x80): pixel mode vs screen mode
// +0x60  uint     resultFlags (OR'd with per-line flags from RenderTextToVertexBuffer)
// +0x68  int      fadeStart (passed to renderFadeEffect)
// +0x6c  int      fadeEnd (passed to renderFadeEffect)
// +0x90  uint     lineCountOutput (zeroed at start, not the dirty flag)
// +0x9c  int      LINE COUNTER / DIRTY FLAG -- THE KEY FIELD
//                   - Checked FIRST: if (this+0x9c != 0) return immediately
//                   - Incremented after each line rendered
//                   - Also incremented for format-code-only lines (ParseTextFormatCodes returns 2)
//                   - Acts as both "already rendered" guard AND line counter

// -----------------------------------------------------------------------------
// DIRTY/VALID FLAG ANALYSIS
// -----------------------------------------------------------------------------
//
// The field at +0x9c is the critical gate. The function's VERY FIRST check is:
//
//   if (this->field_0x9c != 0) return;    // already rendered, skip
//   if (this->textString == NULL) return;  // no text
//   if (*this->textString == '\0') return; // empty text
//
// Assembly proof:
//   0x005cdc2a  MOV EAX,dword ptr [EBX + 0x9c]
//   0x005cdc33  CMP EAX,EDI            ; EDI = 0
//   0x005cdc35  JNZ 0x005cdee2          ; bail if non-zero
//   0x005cdc3b  MOV EAX,dword ptr [EBX + 0x48]
//   0x005cdc3e  CMP EAX,EDI
//   0x005cdc40  JZ 0x005cdee2           ; bail if text ptr is NULL
//   0x005cdc46  CMP byte ptr [EAX],0x0
//   0x005cdc49  JZ 0x005cdee2           ; bail if text is empty
//
// Then +0x9c is INCREMENTED after each rendered line:
//   0x005cde55  MOV ECX,dword ptr [EBX + 0x9c]
//   0x005cde5e  INC ECX
//   0x005cde62  MOV dword ptr [EBX + 0x9c],ECX
//
// And also incremented for format-code lines (ParseTextFormatCodes == 2):
//   0x005cdd81  MOV EAX,dword ptr [EBX + 0x9c]
//   0x005cdd8c  INC EAX
//   0x005cdd90  MOV dword ptr [EBX + 0x9c],EAX
//
// CONCLUSION: +0x9c serves as BOTH:
//   1. A "dirty/needs-render" flag (0 = needs render, non-zero = already done)
//   2. A line counter (counts lines processed during rendering)
//
// To force re-render: set this->field_0x9c = 0
// To prevent render: set this->field_0x9c = non-zero
//
// The callers (validateAndPrepareText, GetVertexBufferData) presumably
// reset +0x9c to 0 when text changes, triggering re-render on next call.

// +0x90 is zeroed at entry:
//   0x005cdc4f  MOV dword ptr [EBX + 0x90],EDI   ; = 0
// This appears to be a separate output counter, not the dirty flag.

// -----------------------------------------------------------------------------
// FLOW SUMMARY
// -----------------------------------------------------------------------------
//
// 1. Guard: if +0x9c != 0 || textString is null/empty -> return
// 2. Zero +0x90 (line output counter?)
// 3. Compute vertical layout params from +0x1c, +0x58, flags
// 4. Loop over text lines:
//    a. Check vertical overflow (accumulated height vs +0x40 maxHeight)
//    b. ParseTextFormatCodes -- handle color/format escapes (returns 2 = consumed)
//    c. WrapTextToWidth -- break text at word boundaries for +0x3c width
//    d. Handle alignment (+0x54): left(0), center(1), right(2) via ConvertPixelsToScreenAlt
//    e. CALL RenderTextToVertexBuffer(this, textPtr, charCount, &color, &offset, &flags, &state)
//    f. Increment +0x9c (line counter)
//    g. If state==2, call AddRectangleToBuffer (highlight/selection rect)
//    h. OR per-line flags into +0x60
//    i. If flags bit1 (single-line mode), break
//    j. Advance to next line
// 5. Call finalizeTextLayout(this)
// 6. If flags bit5 (fade), call renderFadeEffect(this, fadeStart, fadeEnd)

// -----------------------------------------------------------------------------
// RenderTextToVertexBuffer CALL SITE DETAIL (at 0x5CDE50)
// -----------------------------------------------------------------------------
// __thiscall: ECX = this (text object)
// Stack args (6, pushed right-to-left):
//   push &state       (EBP-0x74, local_74 area -- tracks render state, value 2 = highlight)
//   push &flags       (EBP-0x24, output flags OR'd into +0x60)
//   push charCount    (EBP-0x18, from WrapTextToWidth output)
//   push &offset      (EBP-0x48, vertical/horizontal position floats)
//   push &color       (EBP-0x30, color/style data)
//   push textPtr      (ESI, current position in text string)
//
// Assembly at call site:
//   0x005cde39  LEA EAX,[EBP + -0x74]
//   0x005cde3c  PUSH EAX              ; &state
//   0x005cde3d  LEA ECX,[EBP + -0x24]
//   0x005cde40  PUSH ECX              ; &flags
//   0x005cde41  MOV ECX,dword ptr [EBP + -0x18]
//   0x005cde44  LEA EDX,[EBP + -0x48]
//   0x005cde47  PUSH EDX              ; &offset
//   0x005cde48  LEA EAX,[EBP + -0x30]
//   0x005cde4b  PUSH EAX              ; &color
//   0x005cde4c  PUSH ECX              ; charCount
//   0x005cde4d  PUSH ESI              ; textPtr
//   0x005cde4e  MOV ECX,EBX           ; this
//   0x005cde50  CALL 0x005ccbe0       ; RenderTextToVertexBuffer


// =============================================================================
// DECOMPILED C (Ghidra raw output, lightly annotated)
// =============================================================================

/* WARNING: Variable defined which should be unmapped: local_88 */
void __fastcall renderTextToBuffer(void *param_1)  // ECX = this
{
    byte bVar1;
    uint uVar2;
    undefined *puVar3;
    int iVar4;
    undefined **ppuVar5;
    byte *pbVar6;
    float unaff_EDI;
    undefined4 *puVar7;
    float10 extraout_ST0;
    float10 fVar8;
    float10 extraout_ST0_00;
    float10 extraout_ST0_01;
    float10 extraout_ST0_02;
    ulonglong uVar9;
    float10 *pfVar10;
    float fVar11;
    undefined *local_88;
    undefined *local_78;
    undefined *local_74;
    undefined *local_70;
    undefined *local_6c;
    undefined *local_68;
    undefined *local_4c;
    undefined *local_48;
    undefined *local_44;
    undefined *local_40;
    uint uStack_3c;
    undefined *local_38;
    undefined *local_34;
    undefined *local_30;
    undefined *local_2c;
    undefined *local_28;
    undefined *local_24;
    undefined *local_20;
    undefined *local_1c;
    undefined *local_18;
    undefined *local_14;
    undefined *local_10;
    undefined *local_c;
    byte local_5;

    // --- GUARD: dirty/valid check ---
    if (((*(int *)((int)param_1 + 0x9c) != 0) ||          // already rendered?
         (*(char **)((int)param_1 + 0x48) == (char *)0x0)) || // no text ptr?
        (**(char **)((int)param_1 + 0x48) == '\0')) {       // empty text?
        return;
    }

    // --- Reset line output counter ---
    *(undefined4 *)((int)param_1 + 0x90) = 0;

    // --- Read fade params ---
    local_2c = *(undefined **)((int)param_1 + 0x6c);  // fadeEnd
    local_38 = *(undefined **)((int)param_1 + 0x68);  // fadeStart

    // --- Convert line height to screen coords ---
    ConvertPixelsToScreen(
        (void *)(*(uint *)((int)param_1 + 0x5c) >> 7 & 1),
        (float10 *)-*(float *)((int)param_1 + 0x1c),
        unaff_EDI);

    uVar2 = *(uint *)((int)param_1 + 0x5c) & 0x80;  // pixel mode flag
    local_4c = (undefined *)0x0;

    if (uVar2 == 0) {
        local_44 = *(undefined **)((int)param_1 + 0x28);  // xOffset
        local_48 = (undefined *)(float)extraout_ST0;
    } else {
        local_48 = (undefined *)0x0;
        local_44 = (undefined *)0x0;
    }

    local_34 = *(undefined **)((int)param_1 + 0x2c);  // color/style
    local_10 = *(undefined **)((int)param_1 + 0x58);  // line step metric
    pbVar6 = *(byte **)((int)param_1 + 0x48);         // text string ptr

    // Init state vars
    local_78 = (undefined *)0x0;
    local_70 = (undefined *)0x0;
    local_68 = (undefined *)0x0;
    local_20 = (undefined *)0x0;
    local_1c = (undefined *)0x0;
    local_14 = (undefined *)0x0;

    // Compute line height (pixel mode vs screen mode)
    if (uVar2 == 0) {
        // Screen mode: round to integer pixels, then back to screen coords
        local_40 = PTR_00c2b9a0;
        uStack_3c = 0;
        uVar9 = __ftol();
        local_40 = (undefined *)uVar9;
        uStack_3c = 0;
        local_18 = (undefined *)(float)(uVar9 & 0xffffffff);
        local_10 = (undefined *)(float)((float10)(uVar9 & 0xffffffff) / extraout_ST0_00);
        ConvertPixelsToScreen((void *)0x0, *(float10 **)((int)param_1 + 0x1c), unaff_EDI);
        fVar8 = extraout_ST0_01 + (float10)(float)local_18;
    } else {
        // Pixel mode: just add
        fVar8 = (float10)(float)local_10 + (float10)*(float *)((int)param_1 + 0x1c);
    }

    local_c = (undefined *)(float)fVar8;  // total line step (height + spacing)
    local_5 = 1;                          // first line flag
    local_74 = (undefined *)((float)local_c + (float)local_48);  // current Y position

    bVar1 = *pbVar6;
    local_18 = (undefined *)0x0;  // accumulated vertical height
    local_6c = local_48;

    // --- MAIN RENDERING LOOP: iterate over lines ---
    do {
        // Check: end of text OR vertical overflow
        if (((bVar1 == 0) ||
             (*(float *)((int)param_1 + 0x40) <= (float)local_18)) ||
            (local_18 = (undefined *)((float)local_18 + *(float *)((int)param_1 + 0x1c) + (float)local_10),
             bVar1 == 0))
            goto LAB_005cdebc;  // done

        // Parse format/color codes
        puVar3 = ParseTextFormatCodes(
            pbVar6, &local_30, (uint *)0x0,
            *(uint *)((int)param_1 + 0x5c), &uStack_3c);

        local_14 = (undefined *)0x0;

        if (puVar3 == (undefined *)0x2) {
            // Format code consumed entire segment -- adjust position, skip render
            local_48 = (undefined *)((float)local_48 - (float)local_c);
            *(int *)((int)param_1 + 0x9c) = *(int *)((int)param_1 + 0x9c) + 1;  // increment line counter
            pbVar6 = pbVar6 + (int)local_30;
        } else {
            // Check word wrap flag
            if (((uint)*(float10 **)((int)param_1 + 0x5c) & 1) == 0) {
                local_24 = (undefined *)0x0;
            } else {
                local_24 = *(undefined **)((int)param_1 + 0x34);  // indent
            }

            pfVar10 = *(float10 **)((int)param_1 + 0x1c);

            // Word-wrap the text to fit maxWidth
            WrapTextToWidth(
                *(float10 **)((int)param_1 + 0x44),  // font
                pbVar6,                                // text
                pfVar10,                               // line height
                *(float *)((int)param_1 + 0x3c),      // maxWidth
                (int *)&local_1c,                      // out: charCount
                (float *)&local_14,                    // out: line width
                &local_20,                             // out: next line ptr
                (float10 *)local_24,                   // indent
                *(float10 **)((int)param_1 + 0x5c),   // flags
                &local_5);                             // first line flag

            // Check if wrapping produced valid output
            if (((local_20 == pbVar6) || (local_20 == (undefined *)0x0)) ||
                ((local_1c == (undefined *)0x0 && (*local_20 == '\0')))) {
LAB_005cdebc:
                // --- FINALIZE ---
                finalizeTextLayout((int)param_1);
                if ((*(byte *)((int)param_1 + 0x5c) & 0x20) == 0) {
                    return;
                }
                // Fade effect
                if ((local_38 == (undefined *)0xffffffff) &&
                    (local_2c == (undefined *)0xffffffff)) {
                    return;
                }
                renderFadeEffect(param_1, (int)local_38, (int)local_2c);
                return;
            }

            // --- ALIGNMENT ---
            puVar3 = local_14;
            if (*(int *)((int)param_1 + 0x54) == 2) {
                // Right-aligned
LAB_005cde14:
                ConvertPixelsToScreenAlt(
                    (void *)(*(uint *)((int)param_1 + 0x5c) >> 7 & 1),
                    (float10 *)-(float)puVar3, unaff_EDI);
                local_4c = (undefined *)(float)extraout_ST0_02;
            } else if (*(int *)((int)param_1 + 0x54) == 1) {
                // Center-aligned
                puVar3 = (undefined *)((float)local_14 * StaticFloat0_5);
                goto LAB_005cde14;
            }
            // else: left-aligned, local_4c stays 0

            local_28 = (undefined *)0x0;
            if (local_78 != (undefined *)0x0) {
                local_70 = local_4c;
            }

            fVar11 = 8.528623e-39;  // junk / uninitialized
            puVar3 = local_1c;

            // --- THE CALL: render this line's glyphs to vertex buffer ---
            RenderTextToVertexBuffer(
                param_1,                // this (ECX)
                pbVar6,                 // textPtr (current line start)
                (int)local_1c,          // charCount
                (uint *)&local_34,      // &color/style
                (float *)&local_4c,     // &position offset
                (uint *)&local_28,      // &output flags
                (int *)&local_78);      // &render state

            // Increment line counter (+0x9c)
            *(int *)((int)param_1 + 0x9c) = *(int *)((int)param_1 + 0x9c) + 1;

            // If state == 2, add highlight/selection rectangle
            if (local_78 == (undefined *)0x2) {
                ppuVar5 = &local_74;
                puVar7 = (undefined4 *)&stack0xffffff5c;
                for (iVar4 = 8; iVar4 != 0; iVar4 = iVar4 + -1) {
                    *puVar7 = *ppuVar5;
                    ppuVar5 = ppuVar5 + 1;
                    puVar7 = puVar7 + 1;
                }
                AddRectangleToBuffer(param_1, (float)pfVar10, fVar11, (float)pbVar6, (float)puVar3);
            }

            // Advance vertical position
            local_48 = (undefined *)((float)local_48 - (float)local_c);

            // Accumulate result flags
            *(uint *)((int)param_1 + 0x60) = *(uint *)((int)param_1 + 0x60) | (uint)local_28;

            // Move to next line
            pbVar6 = local_20;

            // Single-line mode check: if bit1 set, done after first line
            if ((*(byte *)((int)param_1 + 0x5c) & 2) != 0)
                goto LAB_005cdebc;
        }

        bVar1 = *pbVar6;
        local_6c = (undefined *)((float)local_6c - (float)local_c);
        local_74 = (undefined *)((float)local_74 - (float)local_c);
    } while (true);
}


// =============================================================================
// FULL DISASSEMBLY LISTING
// =============================================================================
//
// 0x005cdc20  PUSH EBP
// 0x005cdc21  MOV EBP,ESP
// 0x005cdc23  SUB ESP,0x74
// 0x005cdc26  PUSH EBX
// 0x005cdc27  PUSH ESI
// 0x005cdc28  MOV EBX,ECX
// 0x005cdc2a  MOV EAX,dword ptr [EBX + 0x9c]
// 0x005cdc30  PUSH EDI
// 0x005cdc31  XOR EDI,EDI
// 0x005cdc33  CMP EAX,EDI
// 0x005cdc35  JNZ 0x005cdee2
// 0x005cdc3b  MOV EAX,dword ptr [EBX + 0x48]
// 0x005cdc3e  CMP EAX,EDI
// 0x005cdc40  JZ 0x005cdee2
// 0x005cdc46  CMP byte ptr [EAX],0x0
// 0x005cdc49  JZ 0x005cdee2
// 0x005cdc4f  MOV dword ptr [EBX + 0x90],EDI
// 0x005cdc55  FLD float ptr [EBX + 0x1c]
// 0x005cdc58  MOV ECX,dword ptr [EBX + 0x6c]
// 0x005cdc5b  FCHS
// 0x005cdc5d  MOV EAX,dword ptr [EBX + 0x68]
// 0x005cdc60  PUSH ECX
// 0x005cdc61  MOV dword ptr [EBP + -0x28],ECX
// 0x005cdc64  FSTP float ptr [ESP]
// 0x005cdc67  MOV ECX,dword ptr [EBX + 0x5c]
// 0x005cdc6a  SHR ECX,0x7
// 0x005cdc6d  AND ECX,0x1
// 0x005cdc70  MOV dword ptr [EBP + -0x34],EAX
// 0x005cdc73  CALL 0x005c6fa0
// 0x005cdc78  MOV EAX,dword ptr [EBX + 0x5c]
// 0x005cdc7b  AND EAX,0x80
// 0x005cdc80  MOV dword ptr [EBP + -0x48],EDI
// 0x005cdc83  JZ 0x005cdc8f
// 0x005cdc85  FSTP ST0
// 0x005cdc87  MOV dword ptr [EBP + -0x44],EDI
// 0x005cdc8a  MOV dword ptr [EBP + -0x40],EDI
// 0x005cdc8d  JMP 0x005cdc98
// 0x005cdc8f  MOV EDX,dword ptr [EBX + 0x28]
// 0x005cdc92  FSTP float ptr [EBP + -0x44]
// 0x005cdc95  MOV dword ptr [EBP + -0x40],EDX
// 0x005cdc98  CMP EAX,EDI
// 0x005cdc9a  MOV ECX,dword ptr [EBX + 0x2c]
// 0x005cdc9d  MOV EDX,dword ptr [EBX + 0x58]
// 0x005cdca0  MOV ESI,dword ptr [EBX + 0x48]
// 0x005cdca3  MOV dword ptr [EBP + -0x30],ECX
// 0x005cdca6  MOV dword ptr [EBP + -0x74],EDI
// 0x005cdca9  MOV dword ptr [EBP + -0x6c],0x0
// 0x005cdcb0  MOV dword ptr [EBP + -0x64],0x0
// 0x005cdcb7  MOV dword ptr [EBP + -0x1c],EDI
// 0x005cdcba  MOV dword ptr [EBP + -0x18],EDI
// 0x005cdcbd  MOV dword ptr [EBP + -0x10],0x0
// 0x005cdcc4  MOV dword ptr [EBP + -0xc],EDX
// 0x005cdcc7  JZ 0x005cdcd1
// 0x005cdcc9  FLD float ptr [EBP + -0xc]
// 0x005cdccc  FADD float ptr [EBX + 0x1c]
// 0x005cdccf  JMP 0x005cdd10
// 0x005cdcd1  MOV EAX,[0x00c2b9a0]
// 0x005cdcd6  MOV dword ptr [EBP + -0x3c],EAX
// 0x005cdcd9  MOV dword ptr [EBP + -0x38],EDI
// 0x005cdcdc  FILD qword ptr [EBP + -0x3c]
// 0x005cdcdf  FLD float ptr [EBP + -0xc]
// 0x005cdce2  FMUL ST1
// 0x005cdce4  FADD float ptr [0x00808120]
// 0x005cdcea  CALL 0x0040a2b0
// 0x005cdcef  MOV dword ptr [EBP + -0x3c],EAX
// 0x005cdcf2  MOV dword ptr [EBP + -0x38],EDI
// 0x005cdcf5  FILD qword ptr [EBP + -0x3c]
// 0x005cdcf8  MOV ECX,dword ptr [EBX + 0x1c]
// 0x005cdcfb  PUSH ECX
// 0x005cdcfc  FST float ptr [EBP + -0x14]
// 0x005cdcff  XOR ECX,ECX
// 0x005cdd01  FDIV ST0,ST1
// 0x005cdd03  FSTP float ptr [EBP + -0xc]
// 0x005cdd06  FSTP ST0
// 0x005cdd08  CALL 0x005c6fa0
// 0x005cdd0d  FADD float ptr [EBP + -0x14]
// 0x005cdd10  MOV EDX,dword ptr [EBP + -0x44]
// 0x005cdd13  FSTP float ptr [EBP + -0x8]
// 0x005cdd16  FLD float ptr [EBP + -0x8]
// 0x005cdd19  MOV byte ptr [EBP + -0x1],0x1
// 0x005cdd1d  FADD float ptr [EBP + -0x44]
// 0x005cdd20  MOV CL,byte ptr [ESI]
// 0x005cdd22  TEST CL,CL
// 0x005cdd24  MOV dword ptr [EBP + -0x68],EDX
// 0x005cdd27  FSTP float ptr [EBP + -0x70]
// 0x005cdd2a  MOV dword ptr [EBP + -0x14],0x0
// 0x005cdd31  JZ 0x005cdebc
// 0x005cdd37  FLD float ptr [EBP + -0x14]
// 0x005cdd3a  FCOMP float ptr [EBX + 0x40]
// 0x005cdd3d  FNSTSW AX
// 0x005cdd3f  TEST AH,0x5
// 0x005cdd42  JP 0x005cdebc
// 0x005cdd48  TEST CL,CL
// 0x005cdd4a  FLD float ptr [EBP + -0x14]
// 0x005cdd4d  FADD float ptr [EBX + 0x1c]
// 0x005cdd50  FADD float ptr [EBP + -0xc]
// 0x005cdd53  FSTP float ptr [EBP + -0x14]
// 0x005cdd56  JZ 0x005cdebc
// 0x005cdd5c  MOV ECX,dword ptr [EBX + 0x5c]
// 0x005cdd5f  LEA EAX,[EBP + -0x38]
// 0x005cdd62  PUSH EAX
// 0x005cdd63  PUSH ECX
// 0x005cdd64  PUSH EDI
// 0x005cdd65  LEA EDX,[EBP + -0x2c]
// 0x005cdd68  MOV ECX,ESI
// 0x005cdd6a  CALL 0x005c2810
// 0x005cdd6f  CMP EAX,0x2
// 0x005cdd72  MOV dword ptr [EBP + -0x10],0x0
// 0x005cdd79  JNZ 0x005cdd9b
// 0x005cdd7b  FLD float ptr [EBP + -0x44]
// 0x005cdd7e  MOV ECX,dword ptr [EBP + -0x2c]
// 0x005cdd81  MOV EAX,dword ptr [EBX + 0x9c]
// 0x005cdd87  FSUB float ptr [EBP + -0x8]
// 0x005cdd8a  ADD ESI,ECX
// 0x005cdd8c  INC EAX
// 0x005cdd8d  FSTP float ptr [EBP + -0x44]
// 0x005cdd90  MOV dword ptr [EBX + 0x9c],EAX
// 0x005cdd96  JMP 0x005cdea0
// 0x005cdd9b  MOV EAX,dword ptr [EBX + 0x5c]
// 0x005cdd9e  TEST AL,0x1
// 0x005cdda0  JZ 0x005cddaa
// 0x005cdda2  MOV EDX,dword ptr [EBX + 0x34]
// 0x005cdda5  MOV dword ptr [EBP + -0x20],EDX
// 0x005cdda8  JMP 0x005cddb1
// 0x005cddaa  MOV dword ptr [EBP + -0x20],0x0
// 0x005cddb1  MOV EDX,dword ptr [EBP + -0x20]
// 0x005cddb4  LEA ECX,[EBP + -0x1]
// 0x005cddb7  PUSH ECX
// 0x005cddb8  PUSH EAX
// 0x005cddb9  PUSH EDX
// 0x005cddba  LEA EAX,[EBP + -0x1c]
// 0x005cddbd  PUSH EAX
// 0x005cddbe  MOV EAX,dword ptr [EBX + 0x3c]
// 0x005cddc1  LEA ECX,[EBP + -0x10]
// 0x005cddc4  PUSH ECX
// 0x005cddc5  MOV ECX,dword ptr [EBX + 0x1c]
// 0x005cddc8  LEA EDX,[EBP + -0x18]
// 0x005cddcb  PUSH EDX
// 0x005cddcc  PUSH EAX
// 0x005cddcd  PUSH ECX
// 0x005cddce  MOV ECX,dword ptr [EBX + 0x44]
// 0x005cddd1  MOV EDX,ESI
// 0x005cddd3  CALL 0x005c7260
// 0x005cddd8  MOV EAX,dword ptr [EBP + -0x1c]
// 0x005cdddb  CMP EAX,ESI
// 0x005cdddd  JZ 0x005cdebc
// 0x005cdde3  CMP EAX,EDI
// 0x005cdde5  JZ 0x005cdebc
// 0x005cddeb  CMP dword ptr [EBP + -0x18],EDI
// 0x005cddee  JNZ 0x005cddf9
// 0x005cddf0  CMP byte ptr [EAX],0x0
// 0x005cddf3  JZ 0x005cdebc
// 0x005cddf9  MOV EAX,dword ptr [EBX + 0x54]
// 0x005cddfc  CMP EAX,0x2
// 0x005cddff  JNZ 0x005cde06
// 0x005cde01  FLD float ptr [EBP + -0x10]
// 0x005cde04  JMP 0x005cde14
// 0x005cde06  CMP EAX,0x1
// 0x005cde09  JNZ 0x005cde2b
// 0x005cde0b  FLD float ptr [EBP + -0x10]
// 0x005cde0e  FMUL float ptr [0x007ffa24]
// 0x005cde14  PUSH ECX
// 0x005cde15  FCHS
// 0x005cde17  MOV ECX,dword ptr [EBX + 0x5c]
// 0x005cde1a  FSTP float ptr [ESP]
// 0x005cde1d  SHR ECX,0x7
// 0x005cde20  AND ECX,0x1
// 0x005cde23  CALL 0x005c7010
// 0x005cde28  FSTP float ptr [EBP + -0x48]
// 0x005cde2b  CMP dword ptr [EBP + -0x74],EDI
// 0x005cde2e  MOV dword ptr [EBP + -0x24],EDI
// 0x005cde31  JZ 0x005cde39
// 0x005cde33  MOV EDX,dword ptr [EBP + -0x48]
// 0x005cde36  MOV dword ptr [EBP + -0x6c],EDX
// 0x005cde39  LEA EAX,[EBP + -0x74]
// 0x005cde3c  PUSH EAX
// 0x005cde3d  LEA ECX,[EBP + -0x24]
// 0x005cde40  PUSH ECX
// 0x005cde41  MOV ECX,dword ptr [EBP + -0x18]
// 0x005cde44  LEA EDX,[EBP + -0x48]
// 0x005cde47  PUSH EDX
// 0x005cde48  LEA EAX,[EBP + -0x30]
// 0x005cde4b  PUSH EAX
// 0x005cde4c  PUSH ECX
// 0x005cde4d  PUSH ESI
// 0x005cde4e  MOV ECX,EBX
// 0x005cde50  CALL 0x005ccbe0
// 0x005cde55  MOV ECX,dword ptr [EBX + 0x9c]
// 0x005cde5b  MOV EAX,dword ptr [EBP + -0x74]
// 0x005cde5e  INC ECX
// 0x005cde5f  CMP EAX,0x2
// 0x005cde62  MOV dword ptr [EBX + 0x9c],ECX
// 0x005cde68  JNZ 0x005cde82
// 0x005cde6a  SUB ESP,0x20
// 0x005cde6d  MOV EDI,ESP
// 0x005cde6f  MOV ECX,0x8
// 0x005cde74  LEA ESI,[EBP + -0x70]
// 0x005cde77  MOVSD.REP ES:EDI,ESI
// 0x005cde79  MOV ECX,EBX
// 0x005cde7b  CALL 0x005cd310
// 0x005cde80  XOR EDI,EDI
// 0x005cde82  FLD float ptr [EBP + -0x44]
// 0x005cde85  MOV ECX,dword ptr [EBX + 0x60]
// 0x005cde88  MOV EDX,dword ptr [EBP + -0x24]
// 0x005cde8b  FSUB float ptr [EBP + -0x8]
// 0x005cde8e  MOV AL,byte ptr [EBX + 0x5c]
// 0x005cde91  MOV ESI,dword ptr [EBP + -0x1c]
// 0x005cde94  OR ECX,EDX
// 0x005cde96  FSTP float ptr [EBP + -0x44]
// 0x005cde99  TEST AL,0x2
// 0x005cde9b  MOV dword ptr [EBX + 0x60],ECX
// 0x005cde9e  JNZ 0x005cdebc
// 0x005cdea0  FLD float ptr [EBP + -0x68]
// 0x005cdea3  MOV CL,byte ptr [ESI]
// 0x005cdea5  TEST CL,CL
// 0x005cdea7  FSUB float ptr [EBP + -0x8]
// 0x005cdeaa  FSTP float ptr [EBP + -0x68]
// 0x005cdead  FLD float ptr [EBP + -0x70]
// 0x005cdeb0  FSUB float ptr [EBP + -0x8]
// 0x005cdeb3  FSTP float ptr [EBP + -0x70]
// 0x005cdeb6  JNZ 0x005cdd37
// 0x005cdebc  MOV ECX,EBX
// 0x005cdebe  CALL 0x005cdf70
// 0x005cdec3  TEST byte ptr [EBX + 0x5c],0x20
// 0x005cdec7  JZ 0x005cdee2
// 0x005cdec9  MOV EAX,dword ptr [EBP + -0x34]
// 0x005cdecc  CMP EAX,-0x1
// 0x005cdecf  JNZ 0x005cded6
// 0x005cded1  CMP dword ptr [EBP + -0x28],EAX
// 0x005cded4  JZ 0x005cdee2
// 0x005cded6  MOV ECX,dword ptr [EBP + -0x28]
// 0x005cded9  PUSH ECX
// 0x005cdeda  PUSH EAX
// 0x005cdedb  MOV ECX,EBX
// 0x005cdedd  CALL 0x005cd4d0
// 0x005cdee2  POP EDI
// 0x005cdee3  POP ESI
// 0x005cdee4  POP EBX
// 0x005cdee5  MOV ESP,EBP
// 0x005cdee7  POP EBP
// 0x005cdee8  RET
