
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

undefined * __thiscall renderFrame(void *this,float *cameraPosition)

{
  Matrix4x4 *pMVar1;
  float fVar2;
  short sVar3;
  ushort uVar4;
  SceneObject *pSVar5;
  void *pvVar6;
  uint uVar7;
  undefined *puVar8;
  float *pfVar9;
  uint uVar10;
  undefined4 *puVar11;
  undefined *puVar12;
  uint uVar13;
  int iVar14;
  undefined *puVar15;
  uint uVar16;
  int *piVar17;
  undefined4 *puVar18;
  uint *puVar19;
  byte *pbVar20;
  int iVar21;
  undefined4 *puVar22;
  undefined **ppuVar23;
  float transformedPosition [3];
  float worldPosition [3];
  undefined *local_74;
  undefined *local_70;
  undefined *local_6c;
  undefined *local_64;
  undefined *local_60;
  undefined *local_5c;
  undefined *local_58;
  undefined *local_54;
  undefined *local_50;
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
  
  *(int *)((int)this + 0x10) = *(int *)((int)this + 0x10) + 1;
  if (*(int *)((int)this + 0x148) != *(int *)(*(int *)((int)this + 4) + 8)) {
    puVar11 = (undefined4 *)((int)this + 0x14c);
    for (iVar14 = 0x708; iVar14 != 0; iVar14 = iVar14 + -1) {
      *puVar11 = 0xffffffff;
      puVar11 = puVar11 + 1;
    }
    *(undefined4 *)((int)this + 0x148) = *(undefined4 *)(*(int *)((int)this + 4) + 8);
  }
  pMVar1 = (Matrix4x4 *)((int)this + 0x9c);
  local_8 = (undefined *)this;
  SetTransformMatrix((undefined **)pMVar1);
  *(float *)((int)this + 0xcc) =
       *(float *)((int)this + 0xcc) -
       (pMVar1->m00 * *cameraPosition +
       *(float *)((int)this + 0xbc) * cameraPosition[2] +
       *(float *)((int)this + 0xac) * cameraPosition[1]);
  *(float *)((int)this + 0xd0) =
       *(float *)((int)this + 0xd0) -
       (*(float *)((int)this + 0xc0) * cameraPosition[2] +
       *(float *)((int)this + 0xa0) * *cameraPosition +
       *(float *)((int)this + 0xb0) * cameraPosition[1]);
  *(float *)((int)this + 0xd4) =
       *(float *)((int)this + 0xd4) -
       (*(float *)((int)this + 0xc4) * cameraPosition[2] +
       *(float *)((int)this + 0xa4) * *cameraPosition +
       *(float *)((int)this + 0xb4) * cameraPosition[1]);
  initPixelShaderDispatcher4();
  if ((*(byte *)((int)*(void **)((int)this + 4) + 4) & 4) == 0) {
    for (pSVar5 = *(SceneObject **)((int)this + 0x20); pSVar5 != (SceneObject *)0x0;
        pSVar5 = (SceneObject *)pSVar5->data_offset_base) {
      if (*(int *)&pSVar5->field_0x1cc == 0) {
        local_4c = (undefined *)0x0;
        local_48 = (undefined *)0x0;
        local_44 = (undefined *)0x0;
        local_58 = (undefined *)0x3f800000;
        local_54 = (undefined *)0x3f800000;
        local_50 = (undefined *)0x3f800000;
        transformMatrix4x4(pSVar5,pMVar1,(Matrix4x4 *)&local_58,(Matrix4x4 *)&local_4c,
                           (Matrix4x4 *)0x3f800000);
      }
    }
  }
  else {
    setSessionCallbacks(*(void **)((int)this + 4),processLinkedObjectList,(undefined *)this);
    for (pSVar5 = *(SceneObject **)((int)this + 0x20); pSVar5 != (SceneObject *)0x0;
        pSVar5 = *(SceneObject **)(pSVar5->data_offset_base + 0x48)) {
      if (*(int *)&pSVar5->field_0x1cc == 0) {
        local_58 = (undefined *)0x0;
        local_54 = (undefined *)0x0;
        local_50 = (undefined *)0x0;
        local_4c = (undefined *)0x3f800000;
        local_48 = (undefined *)0x3f800000;
        local_44 = (undefined *)0x3f800000;
        transformMatrix4x4(pSVar5,pMVar1,(Matrix4x4 *)&local_4c,(Matrix4x4 *)&local_58,
                           (Matrix4x4 *)0x3f800000);
      }
      if (pSVar5->data_offset_base == 0) break;
    }
    loadSessionKey(*(int *)((int)this + 4));
  }
  for (pSVar5 = *(SceneObject **)((int)this + 0x20); pSVar5 != (SceneObject *)0x0;
      pSVar5 = (SceneObject *)pSVar5->data_offset_base) {
    renderSceneNode(pSVar5);
  }
  pvVar6 = *(void **)((int)this + 0x20);
  while (pvVar6 != (void *)0x0) {
    *(undefined4 *)((int)this + 0x20) = *(undefined4 *)((int)pvVar6 + 0x48);
    *(undefined4 *)((int)pvVar6 + 0x44) = 0;
    *(undefined4 *)((int)pvVar6 + 0x48) = 0;
    setupSceneRenderState(pvVar6);
    pvVar6 = *(void **)((int)this + 0x20);
  }
  *(undefined4 *)((int)this + 0x40) = 0;
  puVar11 = (undefined4 *)((int)this + 0x50);
  iVar14 = 3;
  do {
    *puVar11 = 0;
    puVar11 = puVar11 + 4;
    iVar14 = iVar14 + -1;
  } while (iVar14 != 0);
  *(undefined4 *)((int)this + 0x30) = 0;
  puVar12 = *(undefined **)((int)this + 0x24);
  cameraPosition = (float *)0x0;
  local_64 = (undefined *)0x0;
  local_18 = puVar12;
  if (puVar12 != (undefined *)0x0) {
    do {
      *(undefined4 *)(local_8 + 0x24) = *(undefined4 *)(puVar12 + 0x58);
      *(undefined4 *)(puVar12 + 0x54) = 0;
      *(undefined4 *)(puVar12 + 0x58) = 0;
      *(undefined4 *)(puVar12 + 0x50) = 0;
      local_18 = puVar12;
      puVar8 = PrepareModelForRender(puVar12,0,0);
      if (puVar8 != (undefined *)0x0) {
        puVar8 = *(undefined **)(*(int *)(puVar12 + 0x30) + 0x130);
        local_5c = *(undefined **)(puVar12 + 0x3b8);
        local_64 = local_64 + 1;
        local_10 = puVar8;
        if (*(int *)(local_5c + 0x19c) == 0) {
          local_28 = (undefined *)0x1;
LAB_00707a17:
          local_24 = (undefined *)0x0;
        }
        else {
          fVar2 = *(float *)(puVar12 + 0xfc);
          local_38 = (undefined *)
                     (*(float *)(puVar12 + 0x104) * *(float *)(puVar12 + 0x104) +
                     *(float *)(puVar12 + 0x100) * *(float *)(puVar12 + 0x100) + fVar2 * fVar2);
          SetVector3((Vector3 *)&local_4c,*(float *)(puVar8 + 0xc0) + *(float *)(puVar8 + 0xb4),
                     *(float *)(puVar8 + 0xc4) + *(float *)(puVar8 + 0xb8),
                     *(float *)(puVar8 + 200) + *(float *)(puVar8 + 0xbc));
          ScaleVector3D((float *)&local_58,(float *)&local_4c,0.5);
          local_c = (undefined *)(SQRT((float)local_38) * *(float *)(puVar8 + 0xcc));
          pfVar9 = (float *)transformVector3ByMatrix4x4
                                      (transformedPosition,(float *)&local_58,
                                       (float *)(puVar12 + 0xfc));
          local_74 = (undefined *)*pfVar9;
          local_70 = (undefined *)pfVar9[1];
          local_6c = (undefined *)pfVar9[2];
          fVar2 = (float)local_74 * *(float *)(local_5c + 0x1a0) +
                  (float)local_70 * *(float *)(local_5c + 0x1a4) +
                  (float)local_6c * *(float *)(local_5c + 0x1a8) + *(float *)(local_5c + 0x1ac);
          if ((*(byte *)(*(int *)(local_8 + 4) + 4) & 2) == 0) {
            local_28 = (undefined *)(uint)((float)COLLISION_PLANE_ZERO_THRESHOLD <= fVar2);
            local_24 = (undefined *)(uint)(local_28 == (undefined *)0x0);
          }
          else {
            local_28 = (undefined *)(uint)(-(float)local_c <= fVar2);
            if (fVar2 < (float)local_c == (fVar2 == (float)local_c)) goto LAB_00707a17;
            local_24 = (undefined *)0x1;
          }
        }
        local_1c = (undefined *)(uint)(*(int *)(puVar12 + 0x404) != 0);
        local_34 = *(undefined **)(*(int *)(puVar12 + 0x30) + 0x138);
        if ((((*(byte *)(*(int *)(local_8 + 4) + 4) & 1) == 0) || ((puVar12[4] & 1) != 0)) ||
           (local_c = (undefined *)0x1, *(int *)(puVar12 + 0x1c4) == 0)) {
          local_c = (undefined *)0x0;
        }
        if (local_1c == (undefined *)0x0) {
          local_38 = *(undefined **)(local_34 + 0x20);
        }
        else {
          local_38 = *(undefined **)(puVar12 + 0x3f0);
        }
        local_2c = (undefined *)0x0;
        if (local_38 != (undefined *)0x0) {
          do {
            puVar15 = local_8;
            pfVar9 = cameraPosition;
            if (local_1c == (undefined *)0x0) {
              uVar16 = (uint)*(ushort *)(*(int *)(local_34 + 0x24) + 4 + (int)local_2c * 0x18);
              pbVar20 = (byte *)(*(int *)(local_34 + 0x24) + (int)local_2c * 0x18);
              local_20 = (undefined *)(uVar16 * 0x20 + *(int *)(*(int *)(puVar12 + 0x30) + 0x158));
              if (*(int *)(*(int *)(puVar12 + 0x98) + uVar16 * 4) != 0) goto LAB_00707aea;
            }
            else {
              pbVar20 = (byte *)(*(int *)(puVar12 + 0x3ec) + (int)local_2c * 0x18);
              local_20 = (undefined *)
                         ((uint)*(ushort *)(pbVar20 + 4) * 0x20 + *(int *)(puVar12 + 0x3f4));
LAB_00707aea:
              local_30 = *(undefined **)(puVar12 + 0x19c);
              if ((uint)*(ushort *)(pbVar20 + 8) < *(uint *)(puVar8 + 0x54)) {
                local_30 = (undefined *)
                           ((float)local_30 *
                           *(float *)((uint)*(ushort *)(pbVar20 + 8) * 0x50 + 0x3c +
                                     *(int *)(puVar12 + 0xa0)));
              }
              if (*(short *)(pbVar20 + 0xe) != 0) {
                local_30 = (undefined *)
                           ((float)local_30 *
                           *(float *)((uint)*(ushort *)
                                             (*(int *)(puVar8 + 0xa8) +
                                             (uint)*(ushort *)(pbVar20 + 0x14) * 2) * 0x20 + 0xc +
                                     *(int *)(puVar12 + 0xa8)));
              }
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD <= (float)local_30) &&
                 ((float)local_30 != (float)COLLISION_PLANE_ZERO_THRESHOLD)) {
                local_60 = (undefined *)
                           (*(int *)(puVar8 + 0x88) + (uint)*(ushort *)(pbVar20 + 10) * 4);
                if (((*pbVar20 & 4) == 0) ||
                   (local_40 = (undefined *)0x1, *(int *)(local_8 + 0x11c) == 0)) {
                  local_40 = (undefined *)0x0;
                }
                if ((1 < *(ushort *)(local_60 + 2)) ||
                   (local_3c = (undefined *)0x0, (float)local_30 < _DAT_00808120)) {
                  local_3c = (undefined *)0x1;
                }
                puVar12 = local_8 + 0x2c;
                uVar16 = *(int *)(local_8 + 0x30) + 1;
                if (*(uint *)(local_8 + 0x2c) < uVar16) {
                  uVar10 = *(uint *)(local_8 + 0x38);
                  if (uVar10 == 0) {
                    uVar10 = CalculateOptimalBlockSize(puVar12,uVar16);
                  }
                  uVar16 = AlignToBlockSize(uVar16,uVar10);
                  SetArrayCapacity(puVar12,uVar16);
                }
                puVar12 = local_8;
                piVar17 = (int *)(*(int *)(puVar15 + 0x30) * 0x40 + *(int *)(puVar15 + 0x34));
                *(int *)(puVar15 + 0x30) = *(int *)(puVar15 + 0x30) + 1;
                if (piVar17 == (int *)0x0) {
                  return (undefined *)0x0;
                }
                iVar14 = 0;
                if (local_40 == (undefined *)0x0) {
                  if ((((local_3c == (undefined *)0x0) && (*(int *)(local_18 + 0xb8) != 0)) &&
                      ((*pbVar20 & 0x10) != 0)) &&
                     ((*(int *)(*(int *)(local_18 + 0x3b8) + 0x180) == 0 &&
                      ((*(byte *)(*(int *)(local_8 + 4) + 4) & 0x20) != 0)))) {
                    *piVar17 = 2;
                  }
                  else {
                    *piVar17 = 0;
                  }
                }
                else {
                  *piVar17 = 1;
                }
                piVar17[1] = (int)local_18;
                piVar17[2] = 0;
                if (((local_3c == (undefined *)0x1) && (local_28 != (undefined *)0x0)) &&
                   ((local_24 != (undefined *)0x0 && (local_40 == (undefined *)0x0)))) {
                  iVar14 = 1;
                }
                piVar17[3] = iVar14;
                piVar17[4] = (int)local_30;
                piVar17[7] = (int)local_2c;
                sVar3 = *(short *)(pbVar20 + 2);
                piVar17[0xc] = (int)local_20;
                piVar17[10] = (int)sVar3;
                piVar17[0xb] = (int)pbVar20;
                piVar17[0xd] = (int)local_1c;
                piVar17[0xe] = -1;
                piVar17[0xf] = -1;
                if (((*(byte *)(*(int *)(local_8 + 4) + 4) & 8) != 0) &&
                   (local_40 == (undefined *)0x0)) {
                  if (local_1c == (undefined *)0x0) {
                    iVar14 = *(int *)((int)local_2c * 4 +
                                     *(int *)(*(int *)(local_18 + 0x30) + 0x150));
                  }
                  else {
                    iVar14 = *(int *)((int)local_2c * 4 + *(int *)(local_18 + 0x408));
                  }
                  iVar21 = (int)local_2c * 4;
                  piVar17[0xe] = iVar14;
                  if ((*local_60 & 1) == 0) {
                    piVar17[0xe] = *(int *)(*(int *)(local_18 + 0x3b8) + 0x180) + iVar14;
                  }
                  uVar16 = calculateDepthValue(local_8,piVar17[0xe]);
                  piVar17[0xe] = uVar16;
                  if ((*(byte *)(*(int *)(puVar12 + 4) + 4) & 0x10) != 0) {
                    if (*(int *)(*(int *)(local_18 + 0x3b8) + 0x1b0) == 0) {
                      piVar17[0xe] = uVar16 - 900;
                    }
                    else if (local_1c == (undefined *)0x0) {
                      piVar17[0xf] = *(int *)(iVar21 + *(int *)(*(int *)(local_18 + 0x30) + 0x154));
                    }
                    else {
                      piVar17[0xf] = *(int *)(iVar21 + *(int *)(local_18 + 0x40c));
                    }
                  }
                }
                puVar8 = local_18;
                puVar12 = local_3c;
                if ((int)local_3c < 1) {
                  piVar17[6] = *(int *)(local_18 + 0x84);
                }
                else {
                  pfVar9 = (float *)transformVector3ByMatrix4x4
                                              (worldPosition,(float *)(local_20 + 0x14),
                                               (float *)((uint)*(ushort *)(local_20 + 0x12) * 0x40 +
                                                        *(int *)(local_18 + 0x94)));
                  piVar17[6] = (int)(pfVar9[2] * pfVar9[2] +
                                    pfVar9[1] * pfVar9[1] + *pfVar9 * *pfVar9);
                }
                puVar15 = local_8;
                if ((local_c == (undefined *)0x0) || (local_40 != (undefined *)0x0)) {
                  piVar17[5] = piVar17[6];
                }
                else {
                  piVar17[5] = *(int *)(puVar8 + 0x84);
                }
                if (*piVar17 == 2) {
                  puVar19 = (uint *)(local_8 + 0x3c);
                  uVar16 = *(int *)(local_8 + 0x40) + 1;
                  if (*(uint *)(local_8 + 0x3c) < uVar16) {
                    uVar10 = *(uint *)(local_8 + 0x48);
                    if (uVar10 == 0) {
                      uVar10 = calculateArrayCapacity(puVar19,uVar16);
                    }
                    uVar16 = alignToMultiple(uVar16,uVar10);
                    resizePointerArray(puVar19,uVar16);
                  }
                  puVar11 = (undefined4 *)(*(int *)(puVar15 + 0x44) + *(int *)(puVar15 + 0x40) * 4);
                  if (puVar11 != (undefined4 *)0x0) {
                    *puVar11 = cameraPosition;
                  }
                  goto LAB_00707f7a;
                }
                if (puVar12 == (undefined *)0x1) {
                  if (local_40 != (undefined *)0x0) {
                    if (*(int *)(local_5c + 0x19c) == 0) {
                      puVar19 = (uint *)(local_8 + 0x5c);
                      goto LAB_00707f3e;
                    }
                    puVar19 = (uint *)(local_8 + 0x6c);
                    uVar16 = *(int *)(local_8 + 0x70) + 1;
                    if (*(uint *)(local_8 + 0x6c) < uVar16) {
                      uVar10 = *(uint *)(local_8 + 0x78);
                      if (uVar10 == 0) {
                        uVar10 = calculateArrayCapacity(puVar19,uVar16);
                      }
                      uVar16 = alignToMultiple(uVar16,uVar10);
                      resizePointerArray(puVar19,uVar16);
                    }
                    puVar11 = (undefined4 *)
                              (*(int *)(puVar15 + 0x74) + *(int *)(puVar15 + 0x70) * 4);
                    if (puVar11 != (undefined4 *)0x0) {
                      *puVar11 = cameraPosition;
                    }
                    goto LAB_00707f7a;
                  }
                  if (local_28 != (undefined *)0x0) {
                    puVar19 = (uint *)(local_8 + 0x5c);
                    uVar16 = *(int *)(local_8 + 0x60) + 1;
                    if (*puVar19 < uVar16) {
                      uVar10 = *(uint *)(local_8 + 0x68);
                      if (uVar10 == 0) {
                        uVar10 = calculateArrayCapacity(puVar19,uVar16);
                      }
                      uVar16 = alignToMultiple(uVar16,uVar10);
                      resizePointerArray(puVar19,uVar16);
                    }
                    puVar11 = (undefined4 *)(*(int *)(puVar15 + 100) + *(int *)(puVar15 + 0x60) * 4)
                    ;
                    if (puVar11 != (undefined4 *)0x0) {
                      *puVar11 = cameraPosition;
                    }
                    *(int *)(puVar15 + 0x60) = *(int *)(puVar15 + 0x60) + 1;
                  }
                  puVar12 = local_8;
                  if (local_24 != (undefined *)0x0) {
                    puVar19 = (uint *)(local_8 + 0x6c);
                    uVar16 = *(int *)(local_8 + 0x70) + 1;
                    if (*(uint *)(local_8 + 0x6c) < uVar16) {
                      uVar10 = *(uint *)(local_8 + 0x78);
                      if (uVar10 == 0) {
                        uVar10 = calculateArrayCapacity(puVar19,uVar16);
                      }
                      uVar16 = alignToMultiple(uVar16,uVar10);
                      resizePointerArray(puVar19,uVar16);
                    }
                    puVar11 = (undefined4 *)
                              (*(int *)(puVar12 + 0x74) + *(int *)(puVar12 + 0x70) * 4);
                    if (puVar11 != (undefined4 *)0x0) {
                      *puVar11 = cameraPosition;
                    }
                    goto LAB_00707f7a;
                  }
                }
                else {
                  puVar19 = (uint *)(local_8 + (int)local_3c * 0x10 + 0x4c);
LAB_00707f3e:
                  uVar16 = puVar19[1] + 1;
                  if (*puVar19 < uVar16) {
                    uVar10 = puVar19[3];
                    if (uVar10 == 0) {
                      uVar10 = calculateArrayCapacity(puVar19,uVar16);
                    }
                    uVar16 = alignToMultiple(uVar16,uVar10);
                    resizePointerArray(puVar19,uVar16);
                  }
                  puVar11 = (undefined4 *)(puVar19[2] + puVar19[1] * 4);
                  if (puVar11 != (undefined4 *)0x0) {
                    *puVar11 = cameraPosition;
                  }
LAB_00707f7a:
                  puVar19[1] = puVar19[1] + 1;
                }
                puVar12 = local_8;
                pfVar9 = (float *)((int)cameraPosition + 1);
                if ((((local_c != (undefined *)0x0) && (local_40 == (undefined *)0x0)) &&
                    (0 < (int)local_3c)) && ((*local_60 & 0x10) == 0)) {
                  piVar17[6] = 0x7f7fffff;
                  ResizeDynamicArray(local_8 + 0x2c,1,1);
                  puVar11 = (undefined4 *)
                            (*(int *)(puVar12 + 0x30) * 0x40 + *(int *)(puVar12 + 0x34));
                  *(int *)(puVar12 + 0x30) = *(int *)(puVar12 + 0x30) + 1;
                  if (puVar11 == (undefined4 *)0x0) {
                    return (undefined *)0x0;
                  }
                  puVar18 = (undefined4 *)((int)pfVar9 * 0x40 + -0x40 + *(int *)(puVar12 + 0x34));
                  puVar22 = puVar11;
                  for (iVar14 = 0x10; iVar14 != 0; iVar14 = iVar14 + -1) {
                    *puVar22 = *puVar18;
                    puVar18 = puVar18 + 1;
                    puVar22 = puVar22 + 1;
                  }
                  puVar11[2] = 1;
                  if (local_28 != (undefined *)0x0) {
                    uVar16 = *(int *)(puVar12 + 0x60) + 1;
                    if (*(uint *)(puVar12 + 0x5c) < uVar16) {
                      uVar10 = *(uint *)(puVar12 + 0x68);
                      if (uVar10 == 0) {
                        uVar10 = calculateArrayCapacity(puVar12 + 0x5c,uVar16);
                      }
                      uVar16 = alignToMultiple(uVar16,uVar10);
                      resizePointerArray(puVar12 + 0x5c,uVar16);
                    }
                    piVar17 = (int *)(*(int *)(puVar12 + 100) + *(int *)(puVar12 + 0x60) * 4);
                    if (piVar17 != (int *)0x0) {
                      *piVar17 = (int)pfVar9;
                    }
                    *(int *)(puVar12 + 0x60) = *(int *)(puVar12 + 0x60) + 1;
                  }
                  if (local_24 != (undefined *)0x0) {
                    expandTimerArray(puVar12 + 0x6c,1,1);
                    piVar17 = (int *)(*(int *)(puVar12 + 0x74) + *(int *)(puVar12 + 0x70) * 4);
                    if (piVar17 != (int *)0x0) {
                      *piVar17 = (int)pfVar9;
                    }
                    *(int *)(puVar12 + 0x70) = *(int *)(puVar12 + 0x70) + 1;
                  }
                  pfVar9 = (float *)((int)cameraPosition + 2);
                }
              }
            }
            cameraPosition = pfVar9;
            local_2c = local_2c + 1;
            puVar8 = local_10;
            puVar12 = local_18;
          } while (local_2c < local_38);
        }
        local_c = (undefined *)0x0;
        if (*(int *)(puVar8 + 0x134) != 0) {
          local_1c = (undefined *)0x0;
          local_20 = (undefined *)0x0;
          do {
            puVar15 = local_8;
            if (local_1c[*(int *)(puVar12 + 0x3c8) + 0xbc] != '\0') {
              local_14 = *(undefined **)(puVar12 + 0x19c);
              if (*(int *)(local_20 + *(int *)(puVar8 + 0x138) + 0x4c) != 0) {
                local_14 = (undefined *)
                           ((float)local_14 *
                           *(float *)(local_1c + *(int *)(puVar12 + 0x3c8) + 0x3c));
              }
              if ((float)local_14 < (float)COLLISION_PLANE_ZERO_THRESHOLD) {
                local_14 = (undefined *)0x0;
              }
              uVar4 = **(ushort **)(local_20 + *(int *)(puVar8 + 0x138) + 0x20);
              iVar14 = *(int *)(local_10 + 0x88);
              puVar12 = local_8 + 0x2c;
              uVar16 = *(int *)(local_8 + 0x30) + 1;
              if (*(uint *)(local_8 + 0x2c) < uVar16) {
                uVar10 = *(uint *)(local_8 + 0x38);
                if (uVar10 == 0) {
                  uVar10 = CalculateOptimalBlockSize(puVar12,uVar16);
                }
                uVar16 = AlignToBlockSize(uVar16,uVar10);
                SetArrayCapacity(puVar12,uVar16);
              }
              puVar12 = local_8;
              puVar11 = (undefined4 *)(*(int *)(puVar15 + 0x30) * 0x40 + *(int *)(puVar15 + 0x34));
              *(int *)(puVar15 + 0x30) = *(int *)(puVar15 + 0x30) + 1;
              if (puVar11 != (undefined4 *)0x0) {
                puVar11[4] = local_14;
                *puVar11 = 3;
                puVar11[1] = local_18;
                puVar11[2] = 0;
                puVar11[3] = 0;
                puVar11[7] = local_c;
                puVar11[10] = 0;
                puVar11[5] = *(undefined4 *)(local_18 + 0x84);
                puVar11[6] = *(undefined4 *)(local_18 + 0x84);
                if ((1 < *(ushort *)(iVar14 + (uint)uVar4 * 4 + 2)) ||
                   ((float)local_14 < _DAT_00808120)) {
                  if (local_28 == (undefined *)0x0) {
                    puVar19 = (uint *)(local_8 + 0x6c);
                    expandTimerArray(puVar19,1,1);
                    puVar11 = (undefined4 *)
                              (*(int *)(puVar12 + 0x74) + *(int *)(puVar12 + 0x70) * 4);
                    if (puVar11 != (undefined4 *)0x0) {
                      *puVar11 = cameraPosition;
                    }
                  }
                  else {
                    puVar19 = (uint *)(local_8 + 0x5c);
                    uVar16 = *(int *)(local_8 + 0x60) + 1;
                    if (*puVar19 < uVar16) {
                      uVar10 = *(uint *)(local_8 + 0x68);
                      if (uVar10 == 0) {
                        uVar10 = calculateArrayCapacity(puVar19,uVar16);
                      }
                      uVar16 = alignToMultiple(uVar16,uVar10);
                      resizePointerArray(puVar19,uVar16);
                    }
                    puVar11 = (undefined4 *)(*(int *)(puVar12 + 100) + *(int *)(puVar12 + 0x60) * 4)
                    ;
                    if (puVar11 != (undefined4 *)0x0) {
                      *puVar11 = cameraPosition;
                    }
                  }
                }
                else {
                  puVar19 = (uint *)(local_8 + 0x4c);
                  uVar16 = *(int *)(local_8 + 0x50) + 1;
                  if (*puVar19 < uVar16) {
                    uVar10 = *(uint *)(local_8 + 0x58);
                    if (uVar10 == 0) {
                      uVar10 = calculateArrayCapacity(puVar19,uVar16);
                    }
                    uVar16 = alignToMultiple(uVar16,uVar10);
                    resizePointerArray(puVar19,uVar16);
                  }
                  puVar11 = (undefined4 *)(*(int *)(puVar12 + 0x54) + *(int *)(puVar12 + 0x50) * 4);
                  if (puVar11 != (undefined4 *)0x0) {
                    *puVar11 = cameraPosition;
                  }
                }
                puVar19[1] = puVar19[1] + 1;
                cameraPosition = (float *)((int)cameraPosition + 1);
              }
            }
            local_20 = local_20 + 0xdc;
            local_c = local_c + 1;
            local_1c = local_1c + 0xd0;
            puVar8 = local_10;
            puVar12 = local_18;
          } while (local_c < *(undefined **)(local_10 + 0x134));
        }
        puVar8 = local_8;
        if (*(int *)(puVar12 + 0x1b8) != 0) {
          puVar19 = (uint *)(local_8 + 0x2c);
          uVar16 = *(int *)(local_8 + 0x30) + 1;
          if (*puVar19 < uVar16) {
            uVar10 = *(uint *)(local_8 + 0x38);
            if (uVar10 == 0) {
              uVar10 = CalculateOptimalBlockSize(puVar19,uVar16);
            }
            uVar16 = AlignToBlockSize(uVar16,uVar10);
            SetArrayCapacity(puVar19,uVar16);
          }
          puVar15 = local_8;
          puVar11 = (undefined4 *)(*(int *)(puVar8 + 0x30) * 0x40 + *(int *)(puVar8 + 0x34));
          *(int *)(puVar8 + 0x30) = *(int *)(puVar8 + 0x30) + 1;
          if (puVar11 != (undefined4 *)0x0) {
            *puVar11 = 5;
            puVar11[1] = puVar12;
            puVar11[2] = 0;
            puVar11[3] = 0;
            puVar11[4] = 0x3f800000;
            puVar11[7] = 0;
            puVar11[10] = 0;
            puVar11[5] = *(undefined4 *)(puVar12 + 0x84);
            puVar11[6] = *(undefined4 *)(puVar12 + 0x84);
            if (*(int *)(puVar12 + 0x1c0) == 0) {
              if (local_28 == (undefined *)0x0) {
                puVar12 = local_8 + 0x6c;
                goto LAB_0070835d;
              }
              puVar12 = local_8 + 0x5c;
              expandTimerArray(puVar12,1,1);
              puVar11 = (undefined4 *)(*(int *)(puVar15 + 100) + *(int *)(puVar15 + 0x60) * 4);
              if (puVar11 != (undefined4 *)0x0) {
                *puVar11 = cameraPosition;
              }
            }
            else {
              puVar12 = local_8 + 0x4c;
LAB_0070835d:
              expandTimerArray(puVar12,1,1);
              puVar11 = (undefined4 *)(*(int *)(puVar12 + 8) + *(int *)(puVar12 + 4) * 4);
              if (puVar11 != (undefined4 *)0x0) {
                *puVar11 = cameraPosition;
              }
            }
            *(int *)(puVar12 + 4) = *(int *)(puVar12 + 4) + 1;
            cameraPosition = (float *)((int)cameraPosition + 1);
          }
        }
      }
      puVar12 = *(undefined **)(local_8 + 0x24);
    } while (puVar12 != (undefined *)0x0);
    local_18 = (undefined *)0x0;
    this = local_8;
  }
  local_14 = *(undefined **)((int)this + 0x28);
  puVar12 = local_8;
  do {
    local_8 = puVar12;
    if (local_14 == (undefined *)0x0) {
      puVar8 = *(undefined **)(puVar12 + 0x40);
      local_14 = (undefined *)0x0;
      if ((undefined *)0x1 < puVar8) {
        ppuVar23 = &PTR_00cefff8;
        for (iVar14 = 0xfb; iVar14 != 0; iVar14 = iVar14 + -1) {
          *ppuVar23 = (undefined *)0xffffffff;
          ppuVar23 = ppuVar23 + 1;
        }
        local_c = (undefined *)0x0;
        if (puVar8 != (undefined *)0x0) {
          do {
            local_38 = *(undefined **)(*(int *)(puVar12 + 0x44) + (int)local_c * 4);
            iVar14 = (int)local_38 * 0x40;
            uVar16 = calculateRenderStateHash(*(int *)(puVar12 + 0x34) + iVar14);
            puVar15 = (undefined *)(uVar16 % 0xfb);
            local_34 = puVar15;
            do {
              puVar15 = puVar15 + 1;
              if ((undefined *)0xfa < puVar15) {
                puVar15 = (undefined *)0x0;
              }
              if (((&PTR_00cefff8)[(int)puVar15] == (undefined *)0xffffffff) ||
                 (puVar15 == local_34)) {
                (&PTR_00cefff8)[(int)puVar15] = local_38;
                break;
              }
              uVar16 = compareRenderStates((int)local_38,(int)(&PTR_00cefff8)[(int)puVar15],
                                           (int)puVar12);
            } while (uVar16 != 0);
            *(undefined **)(*(int *)(puVar12 + 0x34) + 0x24 + iVar14) =
                 (&PTR_00cefff8)[(int)puVar15];
            local_c = local_c + 1;
          } while (local_c < puVar8);
        }
      }
      heapSort(compareRenderPriority,*(void ***)(puVar12 + 0x44),(uint)puVar8,puVar12);
      uVar16 = 0;
      local_10 = (undefined *)0x0;
      if (puVar8 != (undefined *)0x0) {
        do {
          local_c = *(undefined **)(*(int *)(puVar12 + 0x44) + (int)local_10 * 4);
          *(undefined **)(*(int *)(puVar12 + 0x44) + uVar16 * 4) = local_c;
          puVar15 = local_10;
          while( true ) {
            puVar15 = puVar15 + 1;
            uVar10 = uVar16 + 1;
            if ((puVar8 <= puVar15) ||
               (uVar13 = compareRenderPriority
                                   ((int)local_c,
                                    *(int *)(*(int *)(puVar12 + 0x44) + (int)puVar15 * 4),
                                    (int)puVar12), uVar13 != 0)) break;
            *(undefined4 *)(uVar10 * 4 + *(int *)(puVar12 + 0x44)) =
                 *(undefined4 *)(*(int *)(puVar12 + 0x44) + (int)puVar15 * 4);
            uVar16 = uVar10;
          }
          if ((uint)((int)puVar15 - (int)local_10) < 2) {
            *(undefined4 *)((int)local_c * 0x40 + *(int *)(puVar12 + 0x34)) = 0;
            uVar10 = *(uint *)(puVar12 + 0x50) + 1;
            if (*(uint *)(puVar12 + 0x4c) < uVar10) {
              uVar13 = *(uint *)(puVar12 + 0x58);
              if (uVar13 == 0) {
                if (uVar10 < 0x40) {
                  uVar13 = uVar10;
                  for (uVar7 = *(uint *)(puVar12 + 0x50) & uVar10; uVar7 != 0;
                      uVar7 = uVar7 - 1 & uVar7) {
                    uVar13 = uVar7;
                  }
                  if (uVar13 == 0) {
                    uVar13 = 1;
                  }
                }
                else {
                  *(undefined4 *)(puVar12 + 0x58) = 0x40;
                  uVar13 = 0x40;
                }
              }
              uVar10 = alignToMultiple(uVar10,uVar13);
              resizePointerArray(puVar12 + 0x4c,uVar10);
            }
            puVar11 = (undefined4 *)(*(int *)(puVar12 + 0x54) + *(int *)(puVar12 + 0x50) * 4);
            if (puVar11 != (undefined4 *)0x0) {
              *puVar11 = local_c;
            }
            *(int *)(puVar12 + 0x50) = *(int *)(puVar12 + 0x50) + 1;
          }
          else {
            *(int *)((int)local_c * 0x40 + 0x20 + *(int *)(puVar12 + 0x34)) =
                 (int)puVar15 - (int)local_10;
            local_10 = puVar15 + -1;
            uVar16 = uVar10;
          }
          local_10 = local_10 + 1;
        } while (local_10 < puVar8);
      }
      if ((*(uint *)(puVar12 + 0x40) < uVar16) && (*(uint *)(puVar12 + 0x3c) < uVar16)) {
        uVar10 = *(uint *)(puVar12 + 0x48);
        if (uVar10 == 0) {
          if (uVar16 < 0x40) {
            uVar13 = uVar16 - 1 & uVar16;
            uVar10 = uVar16;
            while (uVar7 = uVar13, uVar7 != 0) {
              uVar10 = uVar7;
              uVar13 = uVar7 - 1 & uVar7;
            }
            if (uVar10 == 0) {
              uVar10 = 1;
            }
          }
          else {
            *(undefined4 *)(puVar12 + 0x48) = 0x40;
            uVar10 = 0x40;
          }
        }
        uVar10 = alignToMultiple(uVar16,uVar10);
        resizePointerArray(puVar12 + 0x3c,uVar10);
      }
      *(uint *)(puVar12 + 0x40) = uVar16;
      heapSort(compareRenderItems,*(void ***)(puVar12 + 0x54),*(uint *)(puVar12 + 0x50),puVar12);
      heapSort(compareRenderItemsExtended,*(void ***)(puVar12 + 100),*(uint *)(puVar12 + 0x60),
               puVar12);
      heapSort(compareRenderItemsExtended,*(void ***)(puVar12 + 0x74),*(uint *)(puVar12 + 0x70),
               puVar12);
      return (undefined *)0x1;
    }
    *(undefined4 *)(puVar12 + 0x28) = *(undefined4 *)(local_14 + 0x3e0);
    *(undefined4 *)(local_14 + 0x3dc) = 0;
    *(undefined4 *)(local_14 + 0x3e0) = 0;
    puVar12 = PrepareModelForRender(local_14,0,0);
    if (puVar12 != (undefined *)0x0) {
      iVar14 = *(int *)(local_14 + 0x3b8);
      puVar12 = *(undefined **)(*(int *)(local_14 + 0x30) + 0x130);
      local_24 = puVar12;
      if (*(int *)(iVar14 + 0x19c) == 0) {
LAB_007084dd:
        local_c = (undefined *)0x1;
      }
      else {
        pfVar9 = (float *)(local_14 + 0xfc);
        fVar2 = *pfVar9;
        local_34 = (undefined *)
                   (*(float *)(local_14 + 0x104) * *(float *)(local_14 + 0x104) +
                   *(float *)(local_14 + 0x100) * *(float *)(local_14 + 0x100) + fVar2 * fVar2);
        SetVector3((Vector3 *)&local_4c,*(float *)(puVar12 + 0xc0) + *(float *)(puVar12 + 0xb4),
                   *(float *)(puVar12 + 0xc4) + *(float *)(puVar12 + 0xb8),
                   *(float *)(puVar12 + 200) + *(float *)(puVar12 + 0xbc));
        ScaleVector3D((float *)&local_58,(float *)&local_4c,0.5);
        local_34 = (undefined *)(SQRT((float)local_34) * *(float *)(puVar12 + 0xcc));
        pfVar9 = (float *)transformVector3ByMatrix4x4(worldPosition,(float *)&local_58,pfVar9);
        local_74 = (undefined *)*pfVar9;
        local_70 = (undefined *)pfVar9[1];
        local_6c = (undefined *)pfVar9[2];
        local_c = (undefined *)0x0;
        fVar2 = (float)local_74 * *(float *)(iVar14 + 0x1a0) +
                (float)local_70 * *(float *)(iVar14 + 0x1a4) +
                (float)local_6c * *(float *)(iVar14 + 0x1a8) + *(float *)(iVar14 + 0x1ac);
        if (-(float)local_34 < fVar2 != (-(float)local_34 == fVar2)) goto LAB_007084dd;
      }
      local_20 = (undefined *)0x0;
      if (*(int *)(puVar12 + 0x13c) != 0) {
        local_2c = (undefined *)0x0;
        local_1c = (undefined *)0x0;
        do {
          puVar15 = local_8;
          puVar8 = local_1c;
          iVar14 = *(int *)(puVar12 + 0x140);
          if (((*(int *)(local_2c + *(int *)(local_14 + 0x3d0) + 0x164) != 0) &&
              (local_10 = *(undefined **)(local_14 + 0x19c),
              (float)COLLISION_PLANE_ZERO_THRESHOLD <= (float)local_10)) &&
             ((float)local_10 != (float)COLLISION_PLANE_ZERO_THRESHOLD)) {
            puVar12 = local_8 + 0x2c;
            uVar16 = *(int *)(local_8 + 0x30) + 1;
            if (*(uint *)(local_8 + 0x2c) < uVar16) {
              uVar10 = *(uint *)(local_8 + 0x38);
              if (uVar10 == 0) {
                uVar10 = CalculateOptimalBlockSize(puVar12,uVar16);
              }
              uVar16 = AlignToBlockSize(uVar16,uVar10);
              SetArrayCapacity(puVar12,uVar16);
            }
            puVar11 = (undefined4 *)(*(int *)(puVar15 + 0x30) * 0x40 + *(int *)(puVar15 + 0x34));
            *(int *)(puVar15 + 0x30) = *(int *)(puVar15 + 0x30) + 1;
            if (puVar11 != (undefined4 *)0x0) {
              puVar11[4] = local_10;
              *puVar11 = 4;
              puVar11[1] = local_14;
              puVar11[2] = 0;
              puVar11[3] = 0;
              puVar11[7] = local_20;
              puVar11[10] = (uint)*(ushort *)(puVar8 + iVar14 + 0x2e);
              puVar11[5] = *(undefined4 *)(local_14 + 0x84);
              puVar11[6] = *(undefined4 *)(local_14 + 0x84);
              if ((1 < *(ushort *)(puVar8 + iVar14 + 0x28)) || ((float)local_10 < _DAT_00808120)) {
                puVar19 = (uint *)(local_8 + 0x5c);
                if (local_c == (undefined *)0x0) {
                  puVar19 = (uint *)(local_8 + 0x6c);
                }
              }
              else {
                puVar19 = (uint *)(local_8 + 0x4c);
              }
              uVar16 = puVar19[1] + 1;
              if (*puVar19 < uVar16) {
                uVar10 = puVar19[3];
                if (uVar10 == 0) {
                  uVar10 = calculateArrayCapacity(puVar19,uVar16);
                }
                uVar16 = alignToMultiple(uVar16,uVar10);
                resizePointerArray(puVar19,uVar16);
              }
              puVar11 = (undefined4 *)(puVar19[2] + puVar19[1] * 4);
              if (puVar11 != (undefined4 *)0x0) {
                *puVar11 = cameraPosition;
              }
              puVar19[1] = puVar19[1] + 1;
              cameraPosition = (float *)((int)cameraPosition + 1);
            }
          }
          local_20 = local_20 + 1;
          local_1c = local_1c + 0x1f8;
          local_2c = local_2c + 0x16c;
          puVar12 = local_24;
        } while (local_20 < *(undefined **)(local_24 + 0x13c));
      }
    }
    local_14 = *(undefined **)(local_8 + 0x28);
    puVar12 = local_8;
  } while( true );
}

