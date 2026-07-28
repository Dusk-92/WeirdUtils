// ========================================================
// RenderTextToVertexBuffer -- 0x005ccbe0
// Function: RenderTextToVertexBuffer
// Range: 0x005ccbe0 - 0x005cd29d (1726 bytes)
// Ghidra signature: undefined RenderTextToVertexBuffer(void * this, byte * param_1, int param_2, uint * param_3, float * param_4, uint * param_5, int * param_6)
// Calling convention (Ghidra): __thiscall
// ========================================================

// ===================== DECOMPILATION =====================

/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

void __thiscall
RenderTextToVertexBuffer
          (void *this,byte *param_1,int param_2,uint *param_3,float *param_4,uint *param_5,
          int *param_6)

{
  float fVar1;
  uint uVar2;
  undefined *puVar3;
  char *pcVar4;
  float10 *__return_storage_ptr__;
  uint *puVar5;
  undefined4 *puVar6;
  byte bVar7;
  undefined *puVar8;
  uint uVar9;
  int iVar10;
  undefined **ppuVar11;
  uint uVar12;
  undefined4 unaff_ESI;
  char *string1;
  int *piVar13;
  float10 *unaff_EDI;
  int *piVar14;
  float10 extraout_ST0;
  float10 extraout_ST0_00;
  float10 extraout_ST0_01;
  float10 extraout_ST0_02;
  float10 fVar15;
  float10 extraout_ST0_03;
  float10 extraout_ST0_04;
  ulonglong uVar16;
  float in_stack_ffffff3c;
  float in_stack_ffffff40;
  float in_stack_ffffff44;
  float in_stack_ffffff48;
  undefined *local_98;
  undefined *local_94;
  byte local_90;
  undefined *local_8c;
  byte local_88;
  undefined *local_84;
  byte local_80;
  undefined *local_7c;
  undefined4 local_78;
  undefined4 uStack_74;
  uint local_70;
  undefined4 uStack_6c;
  undefined *local_68;
  undefined *local_64;
  undefined *local_60;
  undefined *local_5c;
  undefined *local_58;
  undefined *local_54;
  undefined **ppuStack_50;
  undefined *local_4c;
  undefined *local_48;
  undefined *local_44;
  undefined *local_40;
  undefined *local_3c;
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
  undefined *local_8;
  
  local_18 = (undefined *)this;
  if ((*(byte *)((int)this + 0x5c) & 8) != 0) {
    local_c = (undefined *)((int)this + 0xa0);
    local_10 = &DAT_00000008;
    do {
      iVar10 = *(int *)local_c;
      if (iVar10 != 0) {
        if (*(int *)(iVar10 + 0x1c) != 0) {
          uVar12 = 0;
          do {
            conditionalFree((void *)(*(int *)(iVar10 + 0x20) + uVar12 * 4),0);
            uVar12 = uVar12 + 1;
          } while (uVar12 < *(uint *)(iVar10 + 0x1c));
        }
        *(undefined4 *)(iVar10 + 0x1c) = 0;
      }
      local_c = local_c + 4;
      local_10 = local_10 + -1;
    } while (local_10 != (undefined *)0x0);
  }
  local_38 = (undefined *)*param_4;
  local_34 = (undefined *)param_4[1];
  local_30 = (undefined *)param_4[2];
  local_8 = (undefined *)0x0;
  ConvertPixelsToScreen
            ((void *)(*(uint *)((int)this + 0x5c) >> 7 & 1),*(float10 **)((int)this + 0x1c),
             (float)unaff_EDI);
  local_48 = (undefined *)(float)extraout_ST0;
  local_54 = GetTextureSize(*(int *)((int)this + 0x44));
  ppuStack_50 = (undefined **)0x0;
  local_10 = (undefined *)((float)local_48 / (float)local_54);
  ConvertPixelsToScreen
            ((void *)(*(uint *)((int)this + 0x5c) >> 7 & 1),*(float10 **)((int)this + 0x1c),
             (float)unaff_EDI);
  local_14 = (undefined *)(float)extraout_ST0_00;
  uVar12 = *(uint *)(*(int *)((int)this + 0x44) + 0x180);
  fVar1 = _DAT_0080306c;
  if (((uVar12 & 8) != 0) || (fVar1 = _DAT_00801628, (uVar12 & 1) != 0)) {
    local_14 = (undefined *)((float)local_14 + fVar1);
  }
  if (*param_6 == 2) {
    param_6[4] = (int)local_38;
  }
  if ((DAT_00c2b9f0 & 1) == 0) {
    DAT_00c2b9f0 = DAT_00c2b9f0 | 1;
    _DAT_00c2b9f8 = 0.001953125;
    _DAT_00c2b9fc = 0.001953125;
    _DAT_00c2ba00 = -0.001953125;
    _DAT_00c2ba04 = -0.001953125;
    validateMemoryOperation((int *)&DAT_005cd2c0);
  }
  bVar7 = *param_1;
  local_3c = (undefined *)0x0;
  param_4 = (float *)0x0;
  while ((bVar7 != 0 && (param_2 != 0))) {
    local_40 = (undefined *)0x0;
    puVar3 = ParseTextFormatCodes
                       (param_1,&local_44,(uint *)&local_40,*(uint *)((int)this + 0x5c),
                        (uint *)&local_c);
    param_1 = param_1 + (int)local_44;
    param_2 = param_2 - (int)local_44;
    if (local_8 != (undefined *)0x0) {
      if ((*(byte *)((int)this + 0x5c) & 0x10) == 0) {
        GetOrCreateCharacterGlyph
                  (*(void **)((int)this + 0x44),(float10 *)local_8,(float10 *)local_c,unaff_EDI);
        fVar15 = extraout_ST0_02;
      }
      else {
        GetOrCreateKerningPair
                  (*(void **)((int)this + 0x44),(float10 *)local_8,(float10 *)local_c,unaff_EDI);
        fVar15 = extraout_ST0_01;
      }
      local_3c = (undefined *)(float)fVar15;
    }
    param_4 = (float *)((float)local_3c * (float)local_10);
    switch(puVar3) {
    case (undefined *)0x0:
      if ((*(byte *)((int)this + 0x5c) & 8) == 0) {
        local_40 = (undefined *)CONCAT13(*(undefined1 *)((int)this + 0x2f),local_40._0_3_);
        *param_3 = (uint)local_40;
      }
      break;
    case (undefined *)0x1:
      *param_3 = *(uint *)((int)this + 0x2c);
      break;
    case (undefined *)0x2:
      break;
    default:
      __return_storage_ptr__ =
           (float10 *)GetOrCreateCharacterTexture(*(void **)((int)this + 0x44),(uint)local_c);
      local_1c = (undefined *)__return_storage_ptr__;
      if (__return_storage_ptr__ != (float10 *)0x0) {
        uVar12 = *(uint *)((int)__return_storage_ptr__ + 0x28);
        bVar7 = (byte)uVar12;
        *param_5 = *param_5 | 1 << (bVar7 & 0x1f);
        if (*(int *)((int)this + uVar12 * 4 + 0xa0) == 0) {
          puVar5 = AllocateTextLineTexture();
          *(uint **)((int)this + uVar12 * 4 + 0xa0) = puVar5;
        }
        puVar3 = *(undefined **)((int)this + uVar12 * 4 + 0xa0);
        local_4c = puVar3;
        if ((*(byte *)((int)this + 0x5c) & 8) == 0) {
          local_8 = (undefined *)(*(int *)(puVar3 + 0x1c) + 4);
          if (*(undefined **)(puVar3 + 0x18) < local_8) {
            uVar12 = *(uint *)(puVar3 + 0x24);
            if (uVar12 == 0) {
              uVar12 = CalculateOptimalSize64_2(puVar3 + 0x18,(uint)local_8);
            }
            uVar12 = AlignToMultiple6((uint)local_8,uVar12);
            ResizeVectorArray(puVar3 + 0x18,uVar12);
          }
          uVar12 = 0;
          do {
            puVar5 = (uint *)(*(int *)(puVar3 + 0x20) + (*(int *)(puVar3 + 0x1c) + uVar12) * 4);
            if (puVar5 != (uint *)0x0) {
              *puVar5 = *param_3;
            }
            uVar12 = uVar12 + 1;
          } while (uVar12 < 4);
          puVar8 = *(undefined **)(puVar3 + 0x1c);
          *(undefined **)(puVar3 + 0x1c) = puVar8 + 4;
          __return_storage_ptr__ = (float10 *)local_1c;
          if ((*(byte *)((int)this + 0x5c) & 0x20) != 0) {
            local_98._0_1_ = bVar7;
            local_90 = bVar7;
            local_88 = bVar7;
            local_80 = bVar7;
            local_94 = puVar8;
            puVar5 = (uint *)((int)this + 0x8c);
            local_7c = puVar8 + 3;
            local_84 = puVar8 + 2;
            puVar3 = (undefined *)(*(int *)((int)this + 0x90) + 4);
            local_8c = puVar8 + 1;
            ppuStack_50 = &local_98;
            if ((undefined *)*puVar5 < puVar3) {
              uVar12 = *(uint *)((int)this + 0x98);
              if (uVar12 == 0) {
                uVar12 = findPowerOfTwo(puVar5,(uint)puVar3);
              }
              puVar8 = puVar3;
              if ((uint)puVar3 % uVar12 != 0) {
                puVar8 = puVar3 + (uVar12 - (uint)puVar3 % uVar12);
              }
              local_8 = puVar3;
              resizeGradientBuffer(puVar5,(uint)puVar8);
            }
            uVar12 = 0;
            ppuVar11 = ppuStack_50;
            do {
              puVar6 = (undefined4 *)
                       (*(int *)((int)this + 0x94) + (*(int *)((int)this + 0x90) + uVar12) * 8);
              if (puVar6 != (undefined4 *)0x0) {
                *puVar6 = *ppuVar11;
                puVar6[1] = ppuVar11[1];
              }
              ppuVar11 = ppuVar11 + 2;
              uVar12 = uVar12 + 1;
            } while (uVar12 < 4);
            *(int *)((int)this + 0x90) = *(int *)((int)this + 0x90) + 4;
            __return_storage_ptr__ = (float10 *)local_1c;
          }
        }
        uVar12 = *(uint *)((int)this + 0x5c);
        if (-1 < (char)uVar12) {
          uVar16 = __ftol();
          local_78 = (undefined4)uVar16;
          uStack_74 = 0;
          param_4 = (float *)(float)(uVar16 & 0xffffffff);
        }
        local_68 = (undefined *)((float)param_4 + (float)local_38);
        uVar16 = CONCAT44(*(undefined4 *)((int)this + 0x1c),uVar12 >> 7) & 0xffffffffffffff01;
        local_60 = local_30;
        local_5c = (undefined *)0x0;
        local_58 = (undefined *)0x0;
        local_64 = local_34;
        local_38 = local_68;
        CalculateTextBounds(*(void **)((int)this + 0x44),__return_storage_ptr__,(int)uVar16,
                            (char)(uVar16 >> 0x20),unaff_EDI);
        local_70 = *(uint *)((int)__return_storage_ptr__ + 0x48);
        local_68 = (undefined *)(float)(extraout_ST0_03 + (float10)(float)local_38);
        uStack_6c = 0;
        local_8 = (undefined *)
                  ((float)*(uint *)((int)__return_storage_ptr__ + 0x48) * (float)local_10);
        if (-1 < *(char *)((int)this + 0x5c)) {
          truncateFloatWithValidation
                    (SUB84((double)(float)local_8,0),(double)CONCAT44(unaff_ESI,unaff_EDI));
          local_8 = (undefined *)(float)extraout_ST0_04;
        }
        puVar3 = local_4c;
        if ((*(uint *)(*(int *)((int)this + 0x44) + 0x180) & 8) == 0) {
          if ((*(uint *)(*(int *)((int)this + 0x44) + 0x180) & 1) != 0) {
            local_64 = (undefined *)((float)local_64 - StaticFloat1_0);
          }
        }
        else {
          local_64 = (undefined *)((float)local_64 - _DAT_00801628);
        }
        puVar8 = local_4c + 8;
        uVar12 = *(int *)(local_4c + 0xc) + 4;
        local_64 = (undefined *)
                   ((float)*(int *)(local_1c + 0x58) * (float)local_10 + (float)local_64);
        if (*(uint *)(local_4c + 8) < uVar12) {
          uVar9 = *(uint *)(local_4c + 0x14);
          if (uVar9 == 0) {
            if (uVar12 < 0xc) {
              uVar9 = uVar12;
              for (uVar2 = *(int *)(local_4c + 0xc) + 3U & uVar12; uVar2 != 0;
                  uVar2 = uVar2 - 1 & uVar2) {
                uVar9 = uVar2;
              }
              if (uVar9 == 0) {
                uVar9 = 1;
              }
            }
            else {
              *(undefined4 *)(local_4c + 0x14) = 0xc;
              uVar9 = 0xc;
            }
          }
          uVar12 = alignToNextMultiple(uVar12,uVar9);
          resizeVertexBuffer(puVar8,uVar12);
        }
        uVar12 = 0;
        do {
          puVar6 = (undefined4 *)
                   (*(int *)(puVar3 + 0x10) + (*(int *)(puVar3 + 0xc) + uVar12) * 0x14);
          if (puVar6 != (undefined4 *)0x0) {
            ppuVar11 = &local_68;
            for (iVar10 = 5; iVar10 != 0; iVar10 = iVar10 + -1) {
              *puVar6 = *ppuVar11;
              ppuVar11 = ppuVar11 + 1;
              puVar6 = puVar6 + 1;
            }
          }
          uVar12 = uVar12 + 1;
        } while (uVar12 < 4);
        iVar10 = *(int *)(puVar3 + 0xc);
        *(int *)(puVar3 + 0xc) = iVar10 + 4;
        iVar10 = ((iVar10 + 4) * 5 + -0x14) * 4;
        puVar6 = (undefined4 *)(*(int *)(local_4c + 0x10) + iVar10);
        if ((char)local_18[0x5c] < '\0') {
          fVar1 = (float)puVar6[0xf];
          *puVar6 = puVar6[5];
          puVar6[1] = puVar6[0xb];
          puVar6[0xf] = (float)local_8 + fVar1;
          puVar6[10] = (float)local_8 + fVar1;
          fVar1 = (float)puVar6[0x10];
          puVar6[0x10] = (float)local_48 + fVar1;
          puVar6[6] = (float)local_48 + fVar1;
        }
        else {
          *puVar6 = puVar6[5];
          fVar1 = (float)puVar6[0xf];
          puVar6[0xf] = (float)local_8 + fVar1;
          puVar6[10] = (float)local_8 + fVar1;
          fVar1 = (float)puVar6[0x10];
          puVar6[0x10] = (float)local_14 + fVar1;
          puVar6[6] = (float)local_14 + fVar1;
          puVar6[1] = puVar6[0xb];
        }
        iVar10 = *(int *)(local_4c + 0x10) + iVar10;
        local_2c = *(undefined **)(local_1c + 0x60);
        local_28 = *(undefined **)(local_1c + 100);
        local_24 = *(undefined **)(local_1c + 0x68);
        local_20 = *(undefined **)(local_1c + 0x6c);
        puVar3 = local_20;
        if ((char)local_18[0x5c] < '\0') {
          local_2c = (undefined *)((float)local_2c + _DAT_00c2b9f8);
          local_28 = (undefined *)((float)local_28 + _DAT_00c2b9fc);
          local_24 = (undefined *)((float)local_24 + _DAT_00c2ba00);
          puVar3 = (undefined *)((float)local_20 + _DAT_00c2ba04);
        }
        *(undefined **)(iVar10 + 0x48) = puVar3;
        *(undefined **)(iVar10 + 0x34) = puVar3;
        *(undefined **)(iVar10 + 0x38) = local_24;
        *(undefined **)(iVar10 + 0x10) = local_24;
        *(undefined **)(iVar10 + 0x4c) = local_2c;
        *(undefined **)(iVar10 + 0x24) = local_2c;
        *(undefined **)(iVar10 + 0x20) = local_28;
        *(undefined **)(iVar10 + 0xc) = local_28;
        local_8 = local_c;
        this = local_18;
      }
      break;
    case (undefined *)0x4:
      if (*param_6 != 2) {
        iVar10 = ((int)param_1 - (int)local_44) + 2;
        param_6[10] = (int)(local_44 + -4);
        param_6[6] = (int)(local_44 + -4);
        *param_6 = 2;
        param_6[9] = iVar10;
        param_6[5] = iVar10;
        param_6[7] = (int)param_1 - (int)local_44;
        pcVar4 = FindSubstringInString((char *)param_1,&DAT_0084453c);
        if (pcVar4 == (char *)0x0) {
          param_6[8] = 0;
          param_6[2] = (int)((float)param_4 + (float)local_38);
        }
        else {
          string1 = pcVar4 + 2;
          iVar10 = SafeStringCompareWithLength(string1,&DAT_00844538,2);
          if ((iVar10 == 0) &&
             (iVar10 = SafeStringCompareWithLength((char *)(param_6[7] + -10),&DAT_0085f7ec,2),
             iVar10 == 0)) {
            string1 = pcVar4 + 4;
            param_6[7] = param_6[7] + -10;
          }
          param_6[8] = (int)string1 - param_6[7];
          param_6[2] = (int)((float)param_4 + (float)local_38);
        }
      }
      break;
    case (undefined *)0x5:
      if (*param_6 == 2) {
        param_6[4] = (int)((float)param_4 + (float)local_38);
        piVar14 = (int *)&stack0xffffff3c;
        piVar13 = param_6;
        for (iVar10 = 8; piVar13 = piVar13 + 1, iVar10 != 0; iVar10 = iVar10 + -1) {
          *piVar14 = *piVar13;
          piVar14 = piVar14 + 1;
        }
        *param_6 = 0;
        AddRectangleToBuffer
                  (local_18,in_stack_ffffff3c,in_stack_ffffff40,in_stack_ffffff44,in_stack_ffffff48)
        ;
        this = local_18;
      }
    }
    bVar7 = *param_1;
  }
  param_6[4] = (int)((float)param_4 + (float)local_38);
  return;
}



// =================== FULL DISASSEMBLY ====================
// 0x005ccbe0  55                        PUSH EBP
// 0x005ccbe1  8b ec                     MOV EBP, ESP
// 0x005ccbe3  81 ec 94 00 00 00         SUB ESP, 0x94
// 0x005ccbe9  53                        PUSH EBX
// 0x005ccbea  56                        PUSH ESI
// 0x005ccbeb  57                        PUSH EDI
// 0x005ccbec  8b f9                     MOV EDI, ECX
// 0x005ccbee  f6 47 5c 08               TEST byte ptr [EDI + 0x5c], 0x8
// 0x005ccbf2  89 7d ec                  MOV dword ptr [EBP + -0x14], EDI
// 0x005ccbf5  74 57                     JZ 0x005ccc4e
// 0x005ccbf7  8d 87 a0 00 00 00         LEA EAX, [EDI + 0xa0]
// 0x005ccbfd  89 45 f8                  MOV dword ptr [EBP + -0x8], EAX
// 0x005ccc00  c7 45 f4 08 00 00 00      MOV dword ptr [EBP + -0xc], 0x8
// 0x005ccc07  8b 4d f8                  MOV ECX, dword ptr [EBP + -0x8]
// 0x005ccc0a  8b 31                     MOV ESI, dword ptr [ECX]
// 0x005ccc0c  85 f6                     TEST ESI, ESI
// 0x005ccc0e  74 2c                     JZ 0x005ccc3c
// 0x005ccc10  8b 46 1c                  MOV EAX, dword ptr [ESI + 0x1c]
// 0x005ccc13  85 c0                     TEST EAX, EAX
// 0x005ccc15  76 1e                     JBE 0x005ccc35
// 0x005ccc17  33 db                     XOR EBX, EBX
// 0x005ccc19  8d a4 24 00 00 00 00      LEA ESP, [ESP]
// 0x005ccc20  8b 56 20                  MOV EDX, dword ptr [ESI + 0x20]
// 0x005ccc23  6a 00                     PUSH 0x0
// 0x005ccc25  8d 0c 9a                  LEA ECX, [EDX + EBX*0x4]
// 0x005ccc28  e8 93 15 00 00            CALL 0x005ce1c0
// 0x005ccc2d  8b 46 1c                  MOV EAX, dword ptr [ESI + 0x1c]
// 0x005ccc30  43                        INC EBX
// 0x005ccc31  3b d8                     CMP EBX, EAX
// 0x005ccc33  72 eb                     JC 0x005ccc20
// 0x005ccc35  c7 46 1c 00 00 00 00      MOV dword ptr [ESI + 0x1c], 0x0
// 0x005ccc3c  8b 4d f8                  MOV ECX, dword ptr [EBP + -0x8]
// 0x005ccc3f  8b 45 f4                  MOV EAX, dword ptr [EBP + -0xc]
// 0x005ccc42  83 c1 04                  ADD ECX, 0x4
// 0x005ccc45  48                        DEC EAX
// 0x005ccc46  89 4d f8                  MOV dword ptr [EBP + -0x8], ECX
// 0x005ccc49  89 45 f4                  MOV dword ptr [EBP + -0xc], EAX
// 0x005ccc4c  75 b9                     JNZ 0x005ccc07
// 0x005ccc4e  8b 45 14                  MOV EAX, dword ptr [EBP + 0x14]
// 0x005ccc51  8b 08                     MOV ECX, dword ptr [EAX]
// 0x005ccc53  8b 50 04                  MOV EDX, dword ptr [EAX + 0x4]
// 0x005ccc56  8b 40 08                  MOV EAX, dword ptr [EAX + 0x8]
// 0x005ccc59  89 4d cc                  MOV dword ptr [EBP + -0x34], ECX
// 0x005ccc5c  8b 4f 1c                  MOV ECX, dword ptr [EDI + 0x1c]
// 0x005ccc5f  51                        PUSH ECX
// 0x005ccc60  8b 4f 5c                  MOV ECX, dword ptr [EDI + 0x5c]
// 0x005ccc63  c1 e9 07                  SHR ECX, 0x7
// 0x005ccc66  33 f6                     XOR ESI, ESI
// 0x005ccc68  83 e1 01                  AND ECX, 0x1
// 0x005ccc6b  89 55 d0                  MOV dword ptr [EBP + -0x30], EDX
// 0x005ccc6e  89 45 d4                  MOV dword ptr [EBP + -0x2c], EAX
// 0x005ccc71  89 75 fc                  MOV dword ptr [EBP + -0x4], ESI
// 0x005ccc74  e8 27 a3 ff ff            CALL 0x005c6fa0
// 0x005ccc79  d9 5d bc                  FSTP float ptr [EBP + -0x44]
// 0x005ccc7c  8b 4f 44                  MOV ECX, dword ptr [EDI + 0x44]
// 0x005ccc7f  e8 0c e2 ff ff            CALL 0x005cae90
// 0x005ccc84  89 45 b0                  MOV dword ptr [EBP + -0x50], EAX
// 0x005ccc87  89 75 b4                  MOV dword ptr [EBP + -0x4c], ESI
// 0x005ccc8a  df 6d b0                  FILD qword ptr [EBP + -0x50]
// 0x005ccc8d  8b 4f 5c                  MOV ECX, dword ptr [EDI + 0x5c]
// 0x005ccc90  8b 57 1c                  MOV EDX, dword ptr [EDI + 0x1c]
// 0x005ccc93  c1 e9 07                  SHR ECX, 0x7
// 0x005ccc96  d8 7d bc                  FDIVR float ptr [EBP + -0x44]
// 0x005ccc99  52                        PUSH EDX
// 0x005ccc9a  83 e1 01                  AND ECX, 0x1
// 0x005ccc9d  d9 5d f4                  FSTP float ptr [EBP + -0xc]
// 0x005ccca0  e8 fb a2 ff ff            CALL 0x005c6fa0
// 0x005ccca5  d9 5d f0                  FSTP float ptr [EBP + -0x10]
// 0x005ccca8  8b 47 44                  MOV EAX, dword ptr [EDI + 0x44]
// 0x005cccab  8b 80 80 01 00 00         MOV EAX, dword ptr [EAX + 0x180]
// 0x005cccb1  a8 08                     TEST AL, 0x8
// 0x005cccb3  74 0b                     JZ 0x005cccc0
// 0x005cccb5  d9 45 f0                  FLD float ptr [EBP + -0x10]
// 0x005cccb8  d8 05 6c 30 80 00         FADD float ptr [0x0080306c]
// 0x005cccbe  eb 0d                     JMP 0x005ccccd
// 0x005cccc0  a8 01                     TEST AL, 0x1
// 0x005cccc2  74 0c                     JZ 0x005cccd0
// 0x005cccc4  d9 45 f0                  FLD float ptr [EBP + -0x10]
// 0x005cccc7  d8 05 28 16 80 00         FADD float ptr [0x00801628]
// 0x005ccccd  d9 5d f0                  FSTP float ptr [EBP + -0x10]
// 0x005cccd0  8b 5d 1c                  MOV EBX, dword ptr [EBP + 0x1c]
// 0x005cccd3  83 3b 02                  CMP dword ptr [EBX], 0x2
// 0x005cccd6  75 06                     JNZ 0x005cccde
// 0x005cccd8  8b 4d cc                  MOV ECX, dword ptr [EBP + -0x34]
// 0x005cccdb  89 4b 10                  MOV dword ptr [EBX + 0x10], ECX
// 0x005cccde  a0 f0 b9 c2 00            MOV AL, [0x00c2b9f0]
// 0x005ccce3  a8 01                     TEST AL, 0x1
// 0x005ccce5  75 40                     JNZ 0x005ccd27
// 0x005ccce7  8a d0                     MOV DL, AL
// 0x005ccce9  80 ca 01                  OR DL, 0x1
// 0x005cccec  68 c0 d2 5c 00            PUSH 0x5cd2c0
// 0x005cccf1  88 15 f0 b9 c2 00         MOV byte ptr [0x00c2b9f0], DL
// 0x005cccf7  c7 05 f8 b9 c2 00 00 00 00 3b  MOV dword ptr [0x00c2b9f8], 0x3b000000
// 0x005ccd01  c7 05 fc b9 c2 00 00 00 00 3b  MOV dword ptr [0x00c2b9fc], 0x3b000000
// 0x005ccd0b  c7 05 00 ba c2 00 00 00 00 bb  MOV dword ptr [0x00c2ba00], 0xbb000000
// 0x005ccd15  c7 05 04 ba c2 00 00 00 00 bb  MOV dword ptr [0x00c2ba04], 0xbb000000
// 0x005ccd1f  e8 cb cd e3 ff            CALL 0x00409aef
// 0x005ccd24  83 c4 04                  ADD ESP, 0x4
// 0x005ccd27  8b 55 08                  MOV EDX, dword ptr [EBP + 0x8]
// 0x005ccd2a  80 3a 00                  CMP byte ptr [EDX], 0x0
// 0x005ccd2d  c7 45 c8 00 00 00 00      MOV dword ptr [EBP + -0x38], 0x0
// 0x005ccd34  c7 45 14 00 00 00 00      MOV dword ptr [EBP + 0x14], 0x0
// 0x005ccd3b  0f 84 4b 05 00 00         JZ 0x005cd28c
// 0x005ccd41  8b 45 0c                  MOV EAX, dword ptr [EBP + 0xc]
// 0x005ccd44  85 c0                     TEST EAX, EAX
// 0x005ccd46  0f 84 40 05 00 00         JZ 0x005cd28c
// 0x005ccd4c  8b 4f 5c                  MOV ECX, dword ptr [EDI + 0x5c]
// 0x005ccd4f  8d 45 f8                  LEA EAX, [EBP + -0x8]
// 0x005ccd52  50                        PUSH EAX
// 0x005ccd53  51                        PUSH ECX
// 0x005ccd54  8b 4d 08                  MOV ECX, dword ptr [EBP + 0x8]
// 0x005ccd57  8d 55 c4                  LEA EDX, [EBP + -0x3c]
// 0x005ccd5a  52                        PUSH EDX
// 0x005ccd5b  8d 55 c0                  LEA EDX, [EBP + -0x40]
// 0x005ccd5e  c7 45 c4 00 00 00 00      MOV dword ptr [EBP + -0x3c], 0x0
// 0x005ccd65  e8 a6 5a ff ff            CALL 0x005c2810
// 0x005ccd6a  8b 55 c0                  MOV EDX, dword ptr [EBP + -0x40]
// 0x005ccd6d  8b 4d 0c                  MOV ECX, dword ptr [EBP + 0xc]
// 0x005ccd70  8b f0                     MOV ESI, EAX
// 0x005ccd72  01 55 08                  ADD dword ptr [EBP + 0x8], EDX
// 0x005ccd75  8b 45 fc                  MOV EAX, dword ptr [EBP + -0x4]
// 0x005ccd78  2b ca                     SUB ECX, EDX
// 0x005ccd7a  85 c0                     TEST EAX, EAX
// 0x005ccd7c  89 4d 0c                  MOV dword ptr [EBP + 0xc], ECX
// 0x005ccd7f  74 2e                     JZ 0x005ccdaf
// 0x005ccd81  f6 47 5c 10               TEST byte ptr [EDI + 0x5c], 0x10
// 0x005ccd85  74 12                     JZ 0x005ccd99
// 0x005ccd87  8b 45 f8                  MOV EAX, dword ptr [EBP + -0x8]
// 0x005ccd8a  8b 4d fc                  MOV ECX, dword ptr [EBP + -0x4]
// 0x005ccd8d  50                        PUSH EAX
// 0x005ccd8e  51                        PUSH ECX
// 0x005ccd8f  8b 4f 44                  MOV ECX, dword ptr [EDI + 0x44]
// 0x005ccd92  e8 19 d7 ff ff            CALL 0x005ca4b0
// 0x005ccd97  eb 10                     JMP 0x005ccda9
// 0x005ccd99  8b 55 f8                  MOV EDX, dword ptr [EBP + -0x8]
// 0x005ccd9c  8b 45 fc                  MOV EAX, dword ptr [EBP + -0x4]
// 0x005ccd9f  8b 4f 44                  MOV ECX, dword ptr [EDI + 0x44]
// 0x005ccda2  52                        PUSH EDX
// 0x005ccda3  50                        PUSH EAX
// 0x005ccda4  e8 27 d5 ff ff            CALL 0x005ca2d0
// 0x005ccda9  8b 55 c0                  MOV EDX, dword ptr [EBP + -0x40]
// 0x005ccdac  d9 5d c8                  FSTP float ptr [EBP + -0x38]
// 0x005ccdaf  83 fe 05                  CMP ESI, 0x5
// 0x005ccdb2  d9 45 c8                  FLD float ptr [EBP + -0x38]
// 0x005ccdb5  d8 4d f4                  FMUL float ptr [EBP + -0xc]
// 0x005ccdb8  d9 5d 14                  FSTP float ptr [EBP + 0x14]
// 0x005ccdbb  0f 87 02 01 00 00         JA 0x005ccec3
// 0x005ccdc1  ff 24 b5 a0 d2 5c 00      JMP dword ptr [ESI*0x4 + 0x5cd2a0]
// 0x005ccdc8  83 3b 02                  CMP dword ptr [EBX], 0x2
// 0x005ccdcb  0f 84 af 04 00 00         JZ 0x005cd280
// 0x005ccdd1  8b 4d 08                  MOV ECX, dword ptr [EBP + 0x8]
// 0x005ccdd4  8b c1                     MOV EAX, ECX
// 0x005ccdd6  2b c2                     SUB EAX, EDX
// 0x005ccdd8  83 c2 fc                  ADD EDX, -0x4
// 0x005ccddb  8d 70 02                  LEA ESI, [EAX + 0x2]
// 0x005ccdde  89 53 28                  MOV dword ptr [EBX + 0x28], EDX
// 0x005ccde1  89 53 18                  MOV dword ptr [EBX + 0x18], EDX
// 0x005ccde4  ba 3c 45 84 00            MOV EDX, 0x84453c
// 0x005ccde9  c7 03 02 00 00 00         MOV dword ptr [EBX], 0x2
// 0x005ccdef  89 73 24                  MOV dword ptr [EBX + 0x24], ESI
// 0x005ccdf2  89 73 14                  MOV dword ptr [EBX + 0x14], ESI
// 0x005ccdf5  89 43 1c                  MOV dword ptr [EBX + 0x1c], EAX
// 0x005ccdf8  e8 a3 e6 07 00            CALL 0x0064b4a0
// 0x005ccdfd  8b f0                     MOV ESI, EAX
// 0x005ccdff  85 f6                     TEST ESI, ESI
// 0x005cce01  74 4d                     JZ 0x005cce50
// 0x005cce03  6a 02                     PUSH 0x2
// 0x005cce05  68 38 45 84 00            PUSH 0x844538
// 0x005cce0a  83 c6 02                  ADD ESI, 0x2
// 0x005cce0d  56                        PUSH ESI
// 0x005cce0e  e8 6d d6 07 00            CALL 0x0064a480
// 0x005cce13  85 c0                     TEST EAX, EAX
// 0x005cce15  75 23                     JNZ 0x005cce3a
// 0x005cce17  8b 4b 1c                  MOV ECX, dword ptr [EBX + 0x1c]
// 0x005cce1a  6a 02                     PUSH 0x2
// 0x005cce1c  68 ec f7 85 00            PUSH 0x85f7ec
// 0x005cce21  83 e9 0a                  SUB ECX, 0xa
// 0x005cce24  51                        PUSH ECX
// 0x005cce25  e8 56 d6 07 00            CALL 0x0064a480
// 0x005cce2a  85 c0                     TEST EAX, EAX
// 0x005cce2c  75 0c                     JNZ 0x005cce3a
// 0x005cce2e  8b 43 1c                  MOV EAX, dword ptr [EBX + 0x1c]
// 0x005cce31  83 c6 02                  ADD ESI, 0x2
// 0x005cce34  83 c0 f6                  ADD EAX, -0xa
// 0x005cce37  89 43 1c                  MOV dword ptr [EBX + 0x1c], EAX
// 0x005cce3a  d9 45 14                  FLD float ptr [EBP + 0x14]
// 0x005cce3d  8b 43 1c                  MOV EAX, dword ptr [EBX + 0x1c]
// 0x005cce40  d8 45 cc                  FADD float ptr [EBP + -0x34]
// 0x005cce43  2b f0                     SUB ESI, EAX
// 0x005cce45  89 73 20                  MOV dword ptr [EBX + 0x20], ESI
// 0x005cce48  d9 5b 08                  FSTP float ptr [EBX + 0x8]
// 0x005cce4b  e9 30 04 00 00            JMP 0x005cd280
// 0x005cce50  d9 45 14                  FLD float ptr [EBP + 0x14]
// 0x005cce53  c7 43 20 00 00 00 00      MOV dword ptr [EBX + 0x20], 0x0
// 0x005cce5a  d8 45 cc                  FADD float ptr [EBP + -0x34]
// 0x005cce5d  d9 5b 08                  FSTP float ptr [EBX + 0x8]
// 0x005cce60  e9 1b 04 00 00            JMP 0x005cd280
// 0x005cce65  83 3b 02                  CMP dword ptr [EBX], 0x2
// 0x005cce68  0f 85 12 04 00 00         JNZ 0x005cd280
// 0x005cce6e  d9 45 14                  FLD float ptr [EBP + 0x14]
// 0x005cce71  83 ec 20                  SUB ESP, 0x20
// 0x005cce74  d8 45 cc                  FADD float ptr [EBP + -0x34]
// 0x005cce77  8b fc                     MOV EDI, ESP
// 0x005cce79  8d 73 04                  LEA ESI, [EBX + 0x4]
// 0x005cce7c  b9 08 00 00 00            MOV ECX, 0x8
// 0x005cce81  d9 5b 10                  FSTP float ptr [EBX + 0x10]
// 0x005cce84  f3 a5                     MOVSD.REP ES:EDI, ESI
// 0x005cce86  8b 4d ec                  MOV ECX, dword ptr [EBP + -0x14]
// 0x005cce89  c7 03 00 00 00 00         MOV dword ptr [EBX], 0x0
// 0x005cce8f  e8 7c 04 00 00            CALL 0x005cd310
// 0x005cce94  e9 e4 03 00 00            JMP 0x005cd27d
// 0x005cce99  8b 57 2c                  MOV EDX, dword ptr [EDI + 0x2c]
// 0x005cce9c  8b 45 10                  MOV EAX, dword ptr [EBP + 0x10]
// 0x005cce9f  89 10                     MOV dword ptr [EAX], EDX
// 0x005ccea1  e9 da 03 00 00            JMP 0x005cd280
// 0x005ccea6  f6 47 5c 08               TEST byte ptr [EDI + 0x5c], 0x8
// 0x005cceaa  0f 85 d0 03 00 00         JNZ 0x005cd280
// 0x005cceb0  8a 4f 2f                  MOV CL, byte ptr [EDI + 0x2f]
// 0x005cceb3  8b 45 10                  MOV EAX, dword ptr [EBP + 0x10]
// 0x005cceb6  88 4d c7                  MOV byte ptr [EBP + -0x39], CL
// 0x005cceb9  8b 55 c4                  MOV EDX, dword ptr [EBP + -0x3c]
// 0x005ccebc  89 10                     MOV dword ptr [EAX], EDX
// 0x005ccebe  e9 bd 03 00 00            JMP 0x005cd280
// 0x005ccec3  8b 4d f8                  MOV ECX, dword ptr [EBP + -0x8]
// 0x005ccec6  51                        PUSH ECX
// 0x005ccec7  8b 4f 44                  MOV ECX, dword ptr [EDI + 0x44]
// 0x005cceca  e8 01 dd ff ff            CALL 0x005cabd0
// 0x005ccecf  8b f0                     MOV ESI, EAX
// 0x005cced1  85 f6                     TEST ESI, ESI
// 0x005cced3  89 75 e8                  MOV dword ptr [EBP + -0x18], ESI
// 0x005cced6  0f 84 a4 03 00 00         JZ 0x005cd280
// 0x005ccedc  8b 5e 28                  MOV EBX, dword ptr [ESI + 0x28]
// 0x005ccedf  8b 45 18                  MOV EAX, dword ptr [EBP + 0x18]
// 0x005ccee2  8b cb                     MOV ECX, EBX
// 0x005ccee4  ba 01 00 00 00            MOV EDX, 0x1
// 0x005ccee9  d3 e2                     SHL EDX, CL
// 0x005cceeb  09 10                     OR dword ptr [EAX], EDX
// 0x005cceed  8b 84 9f a0 00 00 00      MOV EAX, dword ptr [EDI + EBX*0x4 + 0xa0]
// 0x005ccef4  85 c0                     TEST EAX, EAX
// 0x005ccef6  75 0c                     JNZ 0x005ccf04
// 0x005ccef8  e8 33 b7 ff ff            CALL 0x005c8630
// 0x005ccefd  89 84 9f a0 00 00 00      MOV dword ptr [EDI + EBX*0x4 + 0xa0], EAX
// 0x005ccf04  f6 47 5c 08               TEST byte ptr [EDI + 0x5c], 0x8
// 0x005ccf08  8b 84 9f a0 00 00 00      MOV EAX, dword ptr [EDI + EBX*0x4 + 0xa0]
// 0x005ccf0f  89 45 b8                  MOV dword ptr [EBP + -0x48], EAX
// 0x005ccf12  0f 85 21 01 00 00         JNZ 0x005cd039
// 0x005ccf18  8b 48 18                  MOV ECX, dword ptr [EAX + 0x18]
// 0x005ccf1b  8d 70 18                  LEA ESI, [EAX + 0x18]
// 0x005ccf1e  8b 46 04                  MOV EAX, dword ptr [ESI + 0x4]
// 0x005ccf21  83 c0 04                  ADD EAX, 0x4
// 0x005ccf24  3b c1                     CMP EAX, ECX
// 0x005ccf26  89 45 fc                  MOV dword ptr [EBP + -0x4], EAX
// 0x005ccf29  76 26                     JBE 0x005ccf51
// 0x005ccf2b  8b 46 0c                  MOV EAX, dword ptr [ESI + 0xc]
// 0x005ccf2e  85 c0                     TEST EAX, EAX
// 0x005ccf30  75 0b                     JNZ 0x005ccf3d
// 0x005ccf32  8b 45 fc                  MOV EAX, dword ptr [EBP + -0x4]
// 0x005ccf35  50                        PUSH EAX
// 0x005ccf36  8b ce                     MOV ECX, ESI
// 0x005ccf38  e8 53 e0 fc ff            CALL 0x0059af90
// 0x005ccf3d  8b 4d fc                  MOV ECX, dword ptr [EBP + -0x4]
// 0x005ccf40  50                        PUSH EAX
// 0x005ccf41  51                        PUSH ECX
// 0x005ccf42  8b ce                     MOV ECX, ESI
// 0x005ccf44  e8 87 e0 fc ff            CALL 0x0059afd0
// 0x005ccf49  50                        PUSH EAX
// 0x005ccf4a  8b ce                     MOV ECX, ESI
// 0x005ccf4c  e8 bf 6d f3 ff            CALL 0x00503d10
// 0x005ccf51  33 c9                     XOR ECX, ECX
// 0x005ccf53  8b 56 04                  MOV EDX, dword ptr [ESI + 0x4]
// 0x005ccf56  8b 46 08                  MOV EAX, dword ptr [ESI + 0x8]
// 0x005ccf59  03 d1                     ADD EDX, ECX
// 0x005ccf5b  8d 04 90                  LEA EAX, [EAX + EDX*0x4]
// 0x005ccf5e  85 c0                     TEST EAX, EAX
// 0x005ccf60  74 07                     JZ 0x005ccf69
// 0x005ccf62  8b 55 10                  MOV EDX, dword ptr [EBP + 0x10]
// 0x005ccf65  8b 12                     MOV EDX, dword ptr [EDX]
// 0x005ccf67  89 10                     MOV dword ptr [EAX], EDX
// 0x005ccf69  41                        INC ECX
// 0x005ccf6a  83 f9 04                  CMP ECX, 0x4
// 0x005ccf6d  72 e4                     JC 0x005ccf53
// 0x005ccf6f  8b 56 04                  MOV EDX, dword ptr [ESI + 0x4]
// 0x005ccf72  83 c2 04                  ADD EDX, 0x4
// 0x005ccf75  89 56 04                  MOV dword ptr [ESI + 0x4], EDX
// 0x005ccf78  f6 47 5c 20               TEST byte ptr [EDI + 0x5c], 0x20
// 0x005ccf7c  8b f2                     MOV ESI, EDX
// 0x005ccf7e  8d 46 fc                  LEA EAX, [ESI + -0x4]
// 0x005ccf81  0f 84 af 00 00 00         JZ 0x005cd036
// 0x005ccf87  8b b7 90 00 00 00         MOV ESI, dword ptr [EDI + 0x90]
// 0x005ccf8d  8d 50 02                  LEA EDX, [EAX + 0x2]
// 0x005ccf90  8d 48 01                  LEA ECX, [EAX + 0x1]
// 0x005ccf93  88 9d 6c ff ff ff         MOV byte ptr [EBP + 0xffffff6c], BL
// 0x005ccf99  88 9d 74 ff ff ff         MOV byte ptr [EBP + 0xffffff74], BL
// 0x005ccf9f  88 9d 7c ff ff ff         MOV byte ptr [EBP + 0xffffff7c], BL
// 0x005ccfa5  88 5d 84                  MOV byte ptr [EBP + -0x7c], BL
// 0x005ccfa8  89 85 70 ff ff ff         MOV dword ptr [EBP + 0xffffff70], EAX
// 0x005ccfae  83 c0 03                  ADD EAX, 0x3
// 0x005ccfb1  8d 9f 8c 00 00 00         LEA EBX, [EDI + 0x8c]
// 0x005ccfb7  89 45 88                  MOV dword ptr [EBP + -0x78], EAX
// 0x005ccfba  8b 03                     MOV EAX, dword ptr [EBX]
// 0x005ccfbc  89 55 80                  MOV dword ptr [EBP + -0x80], EDX
// 0x005ccfbf  83 c6 04                  ADD ESI, 0x4
// 0x005ccfc2  3b f0                     CMP ESI, EAX
// 0x005ccfc4  8d 95 6c ff ff ff         LEA EDX, [EBP + 0xffffff6c]
// 0x005ccfca  89 8d 78 ff ff ff         MOV dword ptr [EBP + 0xffffff78], ECX
// 0x005ccfd0  89 55 b4                  MOV dword ptr [EBP + -0x4c], EDX
// 0x005ccfd3  76 32                     JBE 0x005cd007
// 0x005ccfd5  8b 4b 0c                  MOV ECX, dword ptr [EBX + 0xc]
// 0x005ccfd8  85 c9                     TEST ECX, ECX
// 0x005ccfda  75 0a                     JNZ 0x005ccfe6
// 0x005ccfdc  56                        PUSH ESI
// 0x005ccfdd  8b cb                     MOV ECX, EBX
// 0x005ccfdf  e8 6c 13 00 00            CALL 0x005ce350
// 0x005ccfe4  8b c8                     MOV ECX, EAX
// 0x005ccfe6  33 d2                     XOR EDX, EDX
// 0x005ccfe8  8b c6                     MOV EAX, ESI
// 0x005ccfea  f7 f1                     DIV ECX
// 0x005ccfec  89 75 fc                  MOV dword ptr [EBP + -0x4], ESI
// 0x005ccfef  85 d2                     TEST EDX, EDX
// 0x005ccff1  74 06                     JZ 0x005ccff9
// 0x005ccff3  2b ca                     SUB ECX, EDX
// 0x005ccff5  03 ce                     ADD ECX, ESI
// 0x005ccff7  eb 03                     JMP 0x005ccffc
// 0x005ccff9  8b 4d fc                  MOV ECX, dword ptr [EBP + -0x4]
// 0x005ccffc  51                        PUSH ECX
// 0x005ccffd  8b cb                     MOV ECX, EBX
// 0x005ccfff  e8 8c 13 00 00            CALL 0x005ce390
// 0x005cd004  8b 55 b4                  MOV EDX, dword ptr [EBP + -0x4c]
// 0x005cd007  33 c0                     XOR EAX, EAX
// 0x005cd009  8d a4 24 00 00 00 00      LEA ESP, [ESP]
// 0x005cd010  8b 4b 04                  MOV ECX, dword ptr [EBX + 0x4]
// 0x005cd013  8b 73 08                  MOV ESI, dword ptr [EBX + 0x8]
// 0x005cd016  03 c8                     ADD ECX, EAX
// 0x005cd018  8d 0c ce                  LEA ECX, [ESI + ECX*0x8]
// 0x005cd01b  85 c9                     TEST ECX, ECX
// 0x005cd01d  74 0a                     JZ 0x005cd029
// 0x005cd01f  8b 32                     MOV ESI, dword ptr [EDX]
// 0x005cd021  89 31                     MOV dword ptr [ECX], ESI
// 0x005cd023  8b 72 04                  MOV ESI, dword ptr [EDX + 0x4]
// 0x005cd026  89 71 04                  MOV dword ptr [ECX + 0x4], ESI
// 0x005cd029  83 c2 08                  ADD EDX, 0x8
// 0x005cd02c  40                        INC EAX
// 0x005cd02d  83 f8 04                  CMP EAX, 0x4
// 0x005cd030  72 de                     JC 0x005cd010
// 0x005cd032  83 43 04 04               ADD dword ptr [EBX + 0x4], 0x4
// 0x005cd036  8b 75 e8                  MOV ESI, dword ptr [EBP + -0x18]
// 0x005cd039  8b 5f 5c                  MOV EBX, dword ptr [EDI + 0x5c]
// 0x005cd03c  84 db                     TEST BL, BL
// 0x005cd03e  78 1e                     JS 0x005cd05e
// 0x005cd040  d9 45 14                  FLD float ptr [EBP + 0x14]
// 0x005cd043  d8 05 24 fa 7f 00         FADD float ptr [0x007ffa24]
// 0x005cd049  e8 62 d2 e3 ff            CALL 0x0040a2b0
// 0x005cd04e  89 45 8c                  MOV dword ptr [EBP + -0x74], EAX
// 0x005cd051  c7 45 90 00 00 00 00      MOV dword ptr [EBP + -0x70], 0x0
// 0x005cd058  df 6d 8c                  FILD qword ptr [EBP + -0x74]
// 0x005cd05b  d9 5d 14                  FSTP float ptr [EBP + 0x14]
// 0x005cd05e  d9 45 14                  FLD float ptr [EBP + 0x14]
// 0x005cd061  8b 4d d4                  MOV ECX, dword ptr [EBP + -0x2c]
// 0x005cd064  d8 45 cc                  FADD float ptr [EBP + -0x34]
// 0x005cd067  8b 45 d0                  MOV EAX, dword ptr [EBP + -0x30]
// 0x005cd06a  c1 eb 07                  SHR EBX, 0x7
// 0x005cd06d  81 e3 01 ff ff ff         AND EBX, 0xffffff01
// 0x005cd073  d9 5d cc                  FSTP float ptr [EBP + -0x34]
// 0x005cd076  8b 55 cc                  MOV EDX, dword ptr [EBP + -0x34]
// 0x005cd079  89 55 9c                  MOV dword ptr [EBP + -0x64], EDX
// 0x005cd07c  8b 57 1c                  MOV EDX, dword ptr [EDI + 0x1c]
// 0x005cd07f  52                        PUSH EDX
// 0x005cd080  53                        PUSH EBX
// 0x005cd081  89 4d a4                  MOV dword ptr [EBP + -0x5c], ECX
// 0x005cd084  8b 4f 44                  MOV ECX, dword ptr [EDI + 0x44]
// 0x005cd087  56                        PUSH ESI
// 0x005cd088  c7 45 a8 00 00 00 00      MOV dword ptr [EBP + -0x58], 0x0
// 0x005cd08f  c7 45 ac 00 00 00 00      MOV dword ptr [EBP + -0x54], 0x0
// 0x005cd096  89 45 a0                  MOV dword ptr [EBP + -0x60], EAX
// 0x005cd099  e8 e2 df ff ff            CALL 0x005cb080
// 0x005cd09e  d8 45 cc                  FADD float ptr [EBP + -0x34]
// 0x005cd0a1  8b 46 48                  MOV EAX, dword ptr [ESI + 0x48]
// 0x005cd0a4  89 45 94                  MOV dword ptr [EBP + -0x6c], EAX
// 0x005cd0a7  8a 47 5c                  MOV AL, byte ptr [EDI + 0x5c]
// 0x005cd0aa  d9 5d 9c                  FSTP float ptr [EBP + -0x64]
// 0x005cd0ad  84 c0                     TEST AL, AL
// 0x005cd0af  c7 45 98 00 00 00 00      MOV dword ptr [EBP + -0x68], 0x0
// 0x005cd0b6  df 6d 94                  FILD qword ptr [EBP + -0x6c]
// 0x005cd0b9  d8 4d f4                  FMUL float ptr [EBP + -0xc]
// 0x005cd0bc  d9 5d fc                  FSTP float ptr [EBP + -0x4]
// 0x005cd0bf  78 14                     JS 0x005cd0d5
// 0x005cd0c1  d9 45 fc                  FLD float ptr [EBP + -0x4]
// 0x005cd0c4  83 ec 08                  SUB ESP, 0x8
// 0x005cd0c7  dd 1c 24                  FSTP double ptr [ESP]
// 0x005cd0ca  e8 70 2e 17 00            CALL 0x0073ff3f
// 0x005cd0cf  d9 5d fc                  FSTP float ptr [EBP + -0x4]
// 0x005cd0d2  83 c4 08                  ADD ESP, 0x8
// 0x005cd0d5  8b 4f 44                  MOV ECX, dword ptr [EDI + 0x44]
// 0x005cd0d8  d9 45 a0                  FLD float ptr [EBP + -0x60]
// 0x005cd0db  8b 81 80 01 00 00         MOV EAX, dword ptr [ECX + 0x180]
// 0x005cd0e1  a8 08                     TEST AL, 0x8
// 0x005cd0e3  74 08                     JZ 0x005cd0ed
// 0x005cd0e5  d8 25 28 16 80 00         FSUB float ptr [0x00801628]
// 0x005cd0eb  eb 0a                     JMP 0x005cd0f7
// 0x005cd0ed  a8 01                     TEST AL, 0x1
// 0x005cd0ef  74 06                     JZ 0x005cd0f7
// 0x005cd0f1  d8 25 d8 f9 7f 00         FSUB float ptr [0x007ff9d8]
// 0x005cd0f7  8b 55 e8                  MOV EDX, dword ptr [EBP + -0x18]
// 0x005cd0fa  db 42 58                  FILD dword ptr [EDX + 0x58]
// 0x005cd0fd  8b 45 b8                  MOV EAX, dword ptr [EBP + -0x48]
// 0x005cd100  8b 48 08                  MOV ECX, dword ptr [EAX + 0x8]
// 0x005cd103  8d 58 08                  LEA EBX, [EAX + 0x8]
// 0x005cd106  d8 4d f4                  FMUL float ptr [EBP + -0xc]
// 0x005cd109  8b 43 04                  MOV EAX, dword ptr [EBX + 0x4]
// 0x005cd10c  83 c0 04                  ADD EAX, 0x4
// 0x005cd10f  3b c1                     CMP EAX, ECX
// 0x005cd111  d8 c1                     FADD ST0, ST1
// 0x005cd113  d9 5d a0                  FSTP float ptr [EBP + -0x60]
// 0x005cd116  dd d8                     FSTP ST0
// 0x005cd118  76 48                     JBE 0x005cd162
// 0x005cd11a  8b 4b 0c                  MOV ECX, dword ptr [EBX + 0xc]
// 0x005cd11d  85 c9                     TEST ECX, ECX
// 0x005cd11f  75 30                     JNZ 0x005cd151
// 0x005cd121  83 f8 0c                  CMP EAX, 0xc
// 0x005cd124  8b c8                     MOV ECX, EAX
// 0x005cd126  73 1d                     JNC 0x005cd145
// 0x005cd128  8d 50 ff                  LEA EDX, [EAX + -0x1]
// 0x005cd12b  23 d0                     AND EDX, EAX
// 0x005cd12d  74 0a                     JZ 0x005cd139
// 0x005cd12f  90                        NOP 
// 0x005cd130  8b ca                     MOV ECX, EDX
// 0x005cd132  8d 51 ff                  LEA EDX, [ECX + -0x1]
// 0x005cd135  23 d1                     AND EDX, ECX
// 0x005cd137  75 f7                     JNZ 0x005cd130
// 0x005cd139  83 f9 01                  CMP ECX, 0x1
// 0x005cd13c  73 13                     JNC 0x005cd151
// 0x005cd13e  b9 01 00 00 00            MOV ECX, 0x1
// 0x005cd143  eb 0c                     JMP 0x005cd151
// 0x005cd145  c7 43 0c 0c 00 00 00      MOV dword ptr [EBX + 0xc], 0xc
// 0x005cd14c  b9 0c 00 00 00            MOV ECX, 0xc
// 0x005cd151  51                        PUSH ECX
// 0x005cd152  50                        PUSH EAX
// 0x005cd153  8b cb                     MOV ECX, EBX
// 0x005cd155  e8 96 10 00 00            CALL 0x005ce1f0
// 0x005cd15a  50                        PUSH EAX
// 0x005cd15b  8b cb                     MOV ECX, EBX
// 0x005cd15d  e8 ae 10 00 00            CALL 0x005ce210
// 0x005cd162  33 d2                     XOR EDX, EDX
// 0x005cd164  8b 43 04                  MOV EAX, dword ptr [EBX + 0x4]
// 0x005cd167  03 c2                     ADD EAX, EDX
// 0x005cd169  8d 0c 80                  LEA ECX, [EAX + EAX*0x4]
// 0x005cd16c  8b 43 08                  MOV EAX, dword ptr [EBX + 0x8]
// 0x005cd16f  8d 3c 88                  LEA EDI, [EAX + ECX*0x4]
// 0x005cd172  85 ff                     TEST EDI, EDI
// 0x005cd174  74 0a                     JZ 0x005cd180
// 0x005cd176  b9 05 00 00 00            MOV ECX, 0x5
// 0x005cd17b  8d 75 9c                  LEA ESI, [EBP + -0x64]
// 0x005cd17e  f3 a5                     MOVSD.REP ES:EDI, ESI
// 0x005cd180  42                        INC EDX
// 0x005cd181  83 fa 04                  CMP EDX, 0x4
// 0x005cd184  72 de                     JC 0x005cd164
// 0x005cd186  8b 7b 04                  MOV EDI, dword ptr [EBX + 0x4]
// 0x005cd189  8b 75 b8                  MOV ESI, dword ptr [EBP + -0x48]
// 0x005cd18c  8b 55 ec                  MOV EDX, dword ptr [EBP + -0x14]
// 0x005cd18f  83 c7 04                  ADD EDI, 0x4
// 0x005cd192  89 7b 04                  MOV dword ptr [EBX + 0x4], EDI
// 0x005cd195  8b 46 10                  MOV EAX, dword ptr [ESI + 0x10]
// 0x005cd198  8b df                     MOV EBX, EDI
// 0x005cd19a  8d 4c 9b ec               LEA ECX, [EBX + EBX*0x4 + -0x14]
// 0x005cd19e  8a 5a 5c                  MOV BL, byte ptr [EDX + 0x5c]
// 0x005cd1a1  c1 e1 02                  SHL ECX, 0x2
// 0x005cd1a4  03 c1                     ADD EAX, ECX
// 0x005cd1a6  84 db                     TEST BL, BL
// 0x005cd1a8  79 25                     JNS 0x005cd1cf
// 0x005cd1aa  d9 45 fc                  FLD float ptr [EBP + -0x4]
// 0x005cd1ad  8b 78 14                  MOV EDI, dword ptr [EAX + 0x14]
// 0x005cd1b0  d8 40 3c                  FADD float ptr [EAX + 0x3c]
// 0x005cd1b3  89 38                     MOV dword ptr [EAX], EDI
// 0x005cd1b5  8b 78 2c                  MOV EDI, dword ptr [EAX + 0x2c]
// 0x005cd1b8  89 78 04                  MOV dword ptr [EAX + 0x4], EDI
// 0x005cd1bb  d9 50 3c                  FST float ptr [EAX + 0x3c]
// 0x005cd1be  d9 58 28                  FSTP float ptr [EAX + 0x28]
// 0x005cd1c1  d9 45 bc                  FLD float ptr [EBP + -0x44]
// 0x005cd1c4  d8 40 40                  FADD float ptr [EAX + 0x40]
// 0x005cd1c7  d9 50 40                  FST float ptr [EAX + 0x40]
// 0x005cd1ca  d9 58 18                  FSTP float ptr [EAX + 0x18]
// 0x005cd1cd  eb 23                     JMP 0x005cd1f2
// 0x005cd1cf  d9 40 14                  FLD float ptr [EAX + 0x14]
// 0x005cd1d2  d9 18                     FSTP float ptr [EAX]
// 0x005cd1d4  d9 45 fc                  FLD float ptr [EBP + -0x4]
// 0x005cd1d7  d8 40 3c                  FADD float ptr [EAX + 0x3c]
// 0x005cd1da  d9 50 3c                  FST float ptr [EAX + 0x3c]
// 0x005cd1dd  d9 58 28                  FSTP float ptr [EAX + 0x28]
// 0x005cd1e0  d9 45 f0                  FLD float ptr [EBP + -0x10]
// 0x005cd1e3  d8 40 40                  FADD float ptr [EAX + 0x40]
// 0x005cd1e6  d9 50 40                  FST float ptr [EAX + 0x40]
// 0x005cd1e9  d9 58 18                  FSTP float ptr [EAX + 0x18]
// 0x005cd1ec  d9 40 2c                  FLD float ptr [EAX + 0x2c]
// 0x005cd1ef  d9 58 04                  FSTP float ptr [EAX + 0x4]
// 0x005cd1f2  8b 46 10                  MOV EAX, dword ptr [ESI + 0x10]
// 0x005cd1f5  03 c1                     ADD EAX, ECX
// 0x005cd1f7  8b 4d e8                  MOV ECX, dword ptr [EBP + -0x18]
// 0x005cd1fa  83 c1 60                  ADD ECX, 0x60
// 0x005cd1fd  8b 31                     MOV ESI, dword ptr [ECX]
// 0x005cd1ff  89 75 d8                  MOV dword ptr [EBP + -0x28], ESI
// 0x005cd202  8b 71 04                  MOV ESI, dword ptr [ECX + 0x4]
// 0x005cd205  89 75 dc                  MOV dword ptr [EBP + -0x24], ESI
// 0x005cd208  8b 71 08                  MOV ESI, dword ptr [ECX + 0x8]
// 0x005cd20b  8b 49 0c                  MOV ECX, dword ptr [ECX + 0xc]
// 0x005cd20e  89 4d e4                  MOV dword ptr [EBP + -0x1c], ECX
// 0x005cd211  8a 4a 5c                  MOV CL, byte ptr [EDX + 0x5c]
// 0x005cd214  84 c9                     TEST CL, CL
// 0x005cd216  89 75 e0                  MOV dword ptr [EBP + -0x20], ESI
// 0x005cd219  79 2f                     JNS 0x005cd24a
// 0x005cd21b  d9 45 d8                  FLD float ptr [EBP + -0x28]
// 0x005cd21e  d8 05 f8 b9 c2 00         FADD float ptr [0x00c2b9f8]
// 0x005cd224  d9 5d d8                  FSTP float ptr [EBP + -0x28]
// 0x005cd227  d9 45 dc                  FLD float ptr [EBP + -0x24]
// 0x005cd22a  d8 05 fc b9 c2 00         FADD float ptr [0x00c2b9fc]
// 0x005cd230  d9 5d dc                  FSTP float ptr [EBP + -0x24]
// 0x005cd233  d9 45 e0                  FLD float ptr [EBP + -0x20]
// 0x005cd236  d8 05 00 ba c2 00         FADD float ptr [0x00c2ba00]
// 0x005cd23c  d9 5d e0                  FSTP float ptr [EBP + -0x20]
// 0x005cd23f  d9 45 e4                  FLD float ptr [EBP + -0x1c]
// 0x005cd242  d8 05 04 ba c2 00         FADD float ptr [0x00c2ba04]
// 0x005cd248  eb 03                     JMP 0x005cd24d
// 0x005cd24a  d9 45 e4                  FLD float ptr [EBP + -0x1c]
// 0x005cd24d  8b 55 e0                  MOV EDX, dword ptr [EBP + -0x20]
// 0x005cd250  d9 50 48                  FST float ptr [EAX + 0x48]
// 0x005cd253  8b 5d 1c                  MOV EBX, dword ptr [EBP + 0x1c]
// 0x005cd256  d9 58 34                  FSTP float ptr [EAX + 0x34]
// 0x005cd259  8b ca                     MOV ECX, EDX
// 0x005cd25b  89 50 38                  MOV dword ptr [EAX + 0x38], EDX
// 0x005cd25e  8b 55 d8                  MOV EDX, dword ptr [EBP + -0x28]
// 0x005cd261  89 48 10                  MOV dword ptr [EAX + 0x10], ECX
// 0x005cd264  8b ca                     MOV ECX, EDX
// 0x005cd266  89 50 4c                  MOV dword ptr [EAX + 0x4c], EDX
// 0x005cd269  8b 55 dc                  MOV EDX, dword ptr [EBP + -0x24]
// 0x005cd26c  89 48 24                  MOV dword ptr [EAX + 0x24], ECX
// 0x005cd26f  8b ca                     MOV ECX, EDX
// 0x005cd271  89 50 20                  MOV dword ptr [EAX + 0x20], EDX
// 0x005cd274  89 48 0c                  MOV dword ptr [EAX + 0xc], ECX
// 0x005cd277  8b 55 f8                  MOV EDX, dword ptr [EBP + -0x8]
// 0x005cd27a  89 55 fc                  MOV dword ptr [EBP + -0x4], EDX
// 0x005cd27d  8b 7d ec                  MOV EDI, dword ptr [EBP + -0x14]
// 0x005cd280  8b 45 08                  MOV EAX, dword ptr [EBP + 0x8]
// 0x005cd283  80 38 00                  CMP byte ptr [EAX], 0x0
// 0x005cd286  0f 85 b5 fa ff ff         JNZ 0x005ccd41
// 0x005cd28c  d9 45 14                  FLD float ptr [EBP + 0x14]
// 0x005cd28f  5f                        POP EDI
// 0x005cd290  d8 45 cc                  FADD float ptr [EBP + -0x34]
// 0x005cd293  5e                        POP ESI
// 0x005cd294  d9 5b 10                  FSTP float ptr [EBX + 0x10]
// 0x005cd297  5b                        POP EBX
// 0x005cd298  8b e5                     MOV ESP, EBP
// 0x005cd29a  5d                        POP EBP
// 0x005cd29b  c2 18 00                  RET 0x18
// Total instructions: 552

// ============= PROLOGUE (first 30 instructions) ==========
// 0x005ccbe0  55                        PUSH EBP
// 0x005ccbe1  8b ec                     MOV EBP, ESP
// 0x005ccbe3  81 ec 94 00 00 00         SUB ESP, 0x94
// 0x005ccbe9  53                        PUSH EBX
// 0x005ccbea  56                        PUSH ESI
// 0x005ccbeb  57                        PUSH EDI
// 0x005ccbec  8b f9                     MOV EDI, ECX
// 0x005ccbee  f6 47 5c 08               TEST byte ptr [EDI + 0x5c], 0x8
// 0x005ccbf2  89 7d ec                  MOV dword ptr [EBP + -0x14], EDI
// 0x005ccbf5  74 57                     JZ 0x005ccc4e
// 0x005ccbf7  8d 87 a0 00 00 00         LEA EAX, [EDI + 0xa0]
// 0x005ccbfd  89 45 f8                  MOV dword ptr [EBP + -0x8], EAX
// 0x005ccc00  c7 45 f4 08 00 00 00      MOV dword ptr [EBP + -0xc], 0x8
// 0x005ccc07  8b 4d f8                  MOV ECX, dword ptr [EBP + -0x8]
// 0x005ccc0a  8b 31                     MOV ESI, dword ptr [ECX]
// 0x005ccc0c  85 f6                     TEST ESI, ESI
// 0x005ccc0e  74 2c                     JZ 0x005ccc3c
// 0x005ccc10  8b 46 1c                  MOV EAX, dword ptr [ESI + 0x1c]
// 0x005ccc13  85 c0                     TEST EAX, EAX
// 0x005ccc15  76 1e                     JBE 0x005ccc35
// 0x005ccc17  33 db                     XOR EBX, EBX
// 0x005ccc19  8d a4 24 00 00 00 00      LEA ESP, [ESP]
// 0x005ccc20  8b 56 20                  MOV EDX, dword ptr [ESI + 0x20]
// 0x005ccc23  6a 00                     PUSH 0x0
// 0x005ccc25  8d 0c 9a                  LEA ECX, [EDX + EBX*0x4]
// 0x005ccc28  e8 93 15 00 00            CALL 0x005ce1c0
// 0x005ccc2d  8b 46 1c                  MOV EAX, dword ptr [ESI + 0x1c]
// 0x005ccc30  43                        INC EBX
// 0x005ccc31  3b d8                     CMP EBX, EAX
// 0x005ccc33  72 eb                     JC 0x005ccc20

// ================ ALL RET INSTRUCTIONS ===================
// 0x005cd29b  c2 18 00                  RET 0x18

// =========== CALLING CONVENTION ANALYSIS =================
// RET cleans up 0x18 (24) bytes from stack
// This suggests 6 stack parameters (after ECX/EDX if thiscall/fastcall)

// =============== XREFS TO (callers) ======================
// 0x005cde50  from renderTextToBuffer (0x005cdc20)  type=UNCONDITIONAL_CALL
// Total callers: 1

// =============== XREFS FROM (callees) ====================
// CALL 0x005ce1c0  conditionalFree  (from 0x005ccc28)
// CALL 0x005c6fa0  ConvertPixelsToScreen  (from 0x005ccc74)
// CALL 0x005cae90  GetTextureSize  (from 0x005ccc7f)
// CALL 0x00409aef  validateMemoryOperation  (from 0x005ccd1f)
// CALL 0x005c2810  ParseTextFormatCodes  (from 0x005ccd65)
// CALL 0x005ca4b0  GetOrCreateKerningPair  (from 0x005ccd92)
// CALL 0x005ca2d0  GetOrCreateCharacterGlyph  (from 0x005ccda4)
// CALL 0x0064b4a0  FindSubstringInString  (from 0x005ccdf8)
// CALL 0x0064a480  SafeStringCompareWithLength  (from 0x005cce0e)
// CALL 0x005cd310  AddRectangleToBuffer  (from 0x005cce8f)
// CALL 0x005cabd0  GetOrCreateCharacterTexture  (from 0x005cceca)
// CALL 0x005c8630  AllocateTextLineTexture  (from 0x005ccef8)
// CALL 0x0059af90  CalculateOptimalSize64_2  (from 0x005ccf38)
// CALL 0x0059afd0  AlignToMultiple6  (from 0x005ccf44)
// CALL 0x00503d10  ResizeVectorArray  (from 0x005ccf4c)
// CALL 0x005ce350  findPowerOfTwo  (from 0x005ccfdf)
// CALL 0x005ce390  resizeGradientBuffer  (from 0x005ccfff)
// CALL 0x0040a2b0  __ftol  (from 0x005cd049)
// CALL 0x005cb080  CalculateTextBounds  (from 0x005cd099)
// CALL 0x0073ff3f  truncateFloatWithValidation  (from 0x005cd0ca)
// CALL 0x005ce1f0  alignToNextMultiple  (from 0x005cd155)
// CALL 0x005ce210  resizeVertexBuffer  (from 0x005cd15d)
// Total unique callees: 22
