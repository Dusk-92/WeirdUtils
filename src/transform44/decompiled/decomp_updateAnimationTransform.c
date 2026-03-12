
void __fastcall updateAnimationTransform(SceneObject *param_1)

{
  int iVar1;
  int **ppiVar2;
  Matrix4x4 *pMVar3;
  int iVar4;
  void *pvVar5;
  undefined4 *puVar6;
  int iVar7;
  undefined **ppuVar8;
  undefined *local_5c;
  undefined *local_58;
  undefined *local_54;
  undefined *local_4c;
  undefined *local_48;
  undefined *local_44;
  undefined *local_3c;
  undefined *local_38;
  undefined *local_34;
  undefined *local_2c;
  undefined *local_28;
  undefined *local_24;
  undefined *local_1c;
  undefined *local_18;
  undefined *local_14;
  undefined *local_10;
  undefined *local_c;
  undefined *local_8;
  
  if (param_1->transform_sync_value != *(int *)((int)param_1->animation_context_ptr + 0x10)) {
    if (*(int *)&param_1->field_0x1cc == 0) {
      local_10 = (undefined *)0x0;
      local_c = (undefined *)0x0;
      local_8 = (undefined *)0x0;
      local_1c = (undefined *)0x3f800000;
      local_18 = (undefined *)0x3f800000;
      local_14 = (undefined *)0x3f800000;
      transformMatrix4x4(param_1,(Matrix4x4 *)((int)param_1->animation_context_ptr + 0x9c),
                         (Matrix4x4 *)&local_1c,(Matrix4x4 *)&local_10,(Matrix4x4 *)0x3f800000);
    }
    else {
      updateAnimationTransform();
    }
    pvVar5 = param_1->animation_context_ptr;
    if (param_1->transform_sync_value != *(int *)((int)pvVar5 + 0x10)) {
      iVar7 = *(int *)&param_1->field_0x1cc;
      if ((iVar7 != 0) && (param_1->model_data_ptr != (void *)0x0)) {
        if ((*(int *)(iVar7 + 0x10) == 0) ||
           ((*(int *)(iVar7 + 0x40) != *(int *)((int)pvVar5 + 0x10) ||
            (param_1->field_0x184 == 9.18341e-41)))) {
          transformMatrix4x4(param_1,(Matrix4x4 *)(iVar7 + 0xfc),(Matrix4x4 *)(iVar7 + 0x1a0),
                             (Matrix4x4 *)(iVar7 + 0x1ac),*(Matrix4x4 **)(iVar7 + 0x19c));
        }
        else {
          iVar1 = (int)param_1->field_0x184 * 0x30 +
                  *(int *)(*(int *)(*(int *)(iVar7 + 0x30) + 0x130) + 0x108);
          puVar6 = (undefined4 *)((uint)*(ushort *)(iVar1 + 4) * 0x40 + *(int *)(iVar7 + 0x94));
          ppuVar8 = &local_5c;
          for (iVar4 = 0x10; iVar4 != 0; iVar4 = iVar4 + -1) {
            *ppuVar8 = (undefined *)*puVar6;
            puVar6 = puVar6 + 1;
            ppuVar8 = ppuVar8 + 1;
          }
          local_2c = (undefined *)
                     ((float)local_5c * *(float *)(iVar1 + 8) +
                      (float)local_4c * *(float *)(iVar1 + 0xc) +
                      (float)local_3c * *(float *)(iVar1 + 0x10) + (float)local_2c);
          local_28 = (undefined *)
                     ((float)local_58 * *(float *)(iVar1 + 8) +
                      (float)local_48 * *(float *)(iVar1 + 0xc) +
                      (float)local_38 * *(float *)(iVar1 + 0x10) + (float)local_28);
          local_24 = (undefined *)
                     ((float)local_54 * *(float *)(iVar1 + 8) +
                      (float)local_44 * *(float *)(iVar1 + 0xc) +
                      (float)local_34 * *(float *)(iVar1 + 0x10) + (float)local_24);
          transformMatrix4x4(param_1,(Matrix4x4 *)&local_5c,(Matrix4x4 *)(iVar7 + 0x1a0),
                             (Matrix4x4 *)(iVar7 + 0x1ac),*(Matrix4x4 **)(iVar7 + 0x19c));
        }
        pvVar5 = param_1->animation_context_ptr;
        if (param_1->transform_sync_value == *(int *)((int)pvVar5 + 0x10)) {
          return;
        }
      }
      if (*(int *)&param_1->field_0x1cc != 0) {
        puVar6 = (undefined4 *)(*(int *)&param_1->field_0x1cc + 0xfc);
        ppiVar2 = &param_1->model_attachment_list1;
        iVar7 = 8;
        do {
          *ppiVar2 = (int *)*puVar6;
          ppiVar2[1] = (int *)puVar6[1];
          ppiVar2 = ppiVar2 + 2;
          puVar6 = puVar6 + 2;
          iVar7 = iVar7 + -1;
        } while (iVar7 != 0);
        return;
      }
      pMVar3 = multiplyMatrix4x4_SSE_Optimized
                         ((Matrix4x4 *)&local_5c,(Matrix4x4 *)&param_1->field_a0,
                          (Matrix4x4 *)((int)pvVar5 + 0x9c));
      ppiVar2 = &param_1->model_attachment_list1;
      iVar7 = 8;
      do {
        *ppiVar2 = (int *)pMVar3->m00;
        ppiVar2[1] = (int *)pMVar3->m01;
        ppiVar2 = ppiVar2 + 2;
        pMVar3 = (Matrix4x4 *)&pMVar3->m02;
        iVar7 = iVar7 + -1;
      } while (iVar7 != 0);
    }
  }
  return;
}

