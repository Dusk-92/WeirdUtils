
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

void __thiscall
transformMatrix4x4(SceneObject *this,Matrix4x4 *param_2,Matrix4x4 *param_3,Matrix4x4 *param_4,
                  Matrix4x4 *param_5)

{
  AnimationData *animationData;
  float *pfVar1;
  float *pfVar2;
  float fVar3;
  float fVar4;
  float fVar5;
  float fVar6;
  float fVar7;
  short sVar8;
  uint uVar9;
  Matrix4x4 *pMVar10;
  int iVar11;
  float *pfVar12;
  undefined2 *puVar13;
  undefined *puVar14;
  int iVar15;
  char cVar16;
  uint uVar17;
  uint uVar18;
  Matrix4x4 *pMVar19;
  uint *puVar20;
  uint *puVar21;
  int iVar22;
  Matrix4x4 *pMVar23;
  AnimationData *pAVar24;
  float10 fVar25;
  longlong lVar26;
  Matrix4x4 local_1a0;
  undefined4 local_160;
  undefined4 local_15c;
  undefined4 local_158;
  undefined4 local_154;
  undefined4 local_150;
  undefined4 local_14c;
  float local_148;
  float local_144;
  float local_140;
  undefined4 local_13c;
  undefined4 local_138;
  undefined4 local_134;
  float local_130;
  float local_12c;
  undefined4 local_128;
  float local_124;
  float local_120;
  float local_11c;
  float local_118;
  float local_114;
  undefined4 local_110;
  float local_10c;
  float local_108;
  float local_104;
  float local_100;
  float local_fc;
  float local_f8;
  float local_f4;
  float local_f0;
  float local_ec;
  float local_e8;
  float local_e4;
  float local_e0;
  undefined4 local_dc;
  float local_d8;
  float local_d4;
  float local_d0;
  undefined4 local_cc;
  float local_c8;
  float local_c4;
  float local_c0;
  undefined4 local_bc;
  float local_b8;
  float local_b4;
  float local_b0;
  undefined4 local_ac;
  float local_a8;
  float local_a4;
  float local_a0;
  float local_9c;
  float local_98;
  float local_94;
  float local_90;
  float local_8c;
  float local_88;
  float local_84;
  float local_80;
  float local_7c;
  float local_78;
  Matrix4x4 local_74;
  float local_34;
  float local_30;
  float local_2c;
  uint *local_28;
  uint *local_24;
  int local_20;
  float local_1c;
  int local_18;
  float *local_14;
  uint *local_10;
  AnimationData *local_c;
  AnimationData *local_8;
  
  if ((this->model_data_ptr != (void *)0x0) &&
     (this->transform_sync_value != *(int *)((int)this->animation_context_ptr + 0x10))) {
    iVar11 = *(int *)&this->field_0x1cc;
    iVar22 = *(int *)((int)this->ptr_at_2c + 0x130);
    if (iVar11 != 0) {
      if ((*(int *)(iVar11 + 0x50) == 0) || (this->field_0x188 == 0.0)) {
        uVar17 = 0;
      }
      else {
        uVar17 = 1;
      }
      this->emitter_enable_flag = uVar17;
      *(undefined4 *)&this->field_0x17c = *(undefined4 *)(iVar11 + 0x17c);
    }
    fVar3 = param_3->m01;
    fVar4 = param_3->m02;
    this->world_position_x = param_3->m00 * *(float *)&this->field_0x184;
    this->world_position_y = (float)this->current_animation_data * fVar3;
    this->rendering_offset_base = (uint)(this->global_scale_factor * fVar4);
    local_34 = param_4->m00 + (float)this->field_0x17c;
    local_30 = this->render_scale_x + param_4->m01;
    local_2c = this->render_scale_y + param_4->m02;
    this->render_priority = local_34;
    this->world_position_z = local_30;
    this->field_0x180 = local_2c;
    uVar17 = 0;
    this->render_scale_z = (float)param_5 * *(float *)&this->field_0x180;
    if (*(int *)(iVar22 + 0x14) != 0) {
      do {
        uVar18 = *(uint *)(*(int *)(iVar22 + 0x18) + uVar17 * 4);
        if (uVar18 == 0) {
          uVar18 = 0;
        }
        else {
          uVar18 = (uint)(*(int *)((int)this->animation_context_ptr + 0xc) - (int)this->position_x)
                   % uVar18;
        }
        *(uint *)(this->search_data_count + uVar17 * 4) = uVar18;
        uVar17 = uVar17 + 1;
      } while (uVar17 < *(uint *)(iVar22 + 0x14));
    }
    local_18 = iVar22;
    initParticlePixelShaderGeneration();
    iVar11 = *(int *)&this->field_0x1cc;
    if ((iVar11 == 0) || ((*(byte *)(iVar11 + 4) & 1) != 0)) {
      this->child_objects_padding =
           (uint)(this->world_transform_matrix[10] * this->world_transform_matrix[10] +
                 this->world_transform_matrix[9] * this->world_transform_matrix[9] +
                 this->world_transform_matrix[8] * this->world_transform_matrix[8]);
    }
    else {
      this->child_objects_padding = *(uint *)(iVar11 + 0x84);
    }
    local_74.m00 = 1.0;
    local_74.m01 = 0.0;
    local_74.m02 = 0.0;
    local_74.m03 = 0.0;
    local_74.m10 = 0.0;
    local_74.m11 = 1.0;
    local_74.m12 = 0.0;
    local_74.m13 = 0.0;
    local_74.m20 = 0.0;
    local_74.m21 = 0.0;
    local_74.m22 = 1.0;
    local_74.m23 = 0.0;
    local_74.m30 = 0.0;
    local_74.m31 = 0.0;
    local_74.m32 = 0.0;
    local_74.m33 = 1.0;
    local_e8 = 1.0;
    local_e4 = 0.0;
    local_e0 = 0.0;
    local_dc = 0;
    local_d8 = 0.0;
    local_d4 = 1.0;
    local_d0 = 0.0;
    local_cc = 0;
    local_c8 = 0.0;
    local_c4 = 0.0;
    local_c0 = 1.0;
    local_bc = 0;
    local_b8 = 0.0;
    local_b4 = 0.0;
    local_b0 = 0.0;
    local_ac = 0x3f800000;
    local_8 = (AnimationData *)0x0;
    if ((this->search_data_base_ptr != 0) &&
       (uVar17 = *(uint *)((int)this->animation_context_ptr + 0xc), uVar17 != 0)) {
      local_8 = (AnimationData *)(uVar17 - this->search_data_base_ptr);
      this->search_data_base_ptr = uVar17;
    }
    param_5 = *(Matrix4x4 **)(iVar22 + 0x34);
    param_3 = (Matrix4x4 *)0x0;
    if (param_5 != (Matrix4x4 *)0x0) {
      do {
        pMVar23 = (Matrix4x4 *)((int)param_3 * 0x6c + *(int *)(local_18 + 0x38));
        uVar17 = this->unknown_0x80;
        iVar11 = *(int *)((int)param_3 * 0x118 + 0xa4 + uVar17);
        puVar20 = (uint *)((int)param_3 * 0x118 + uVar17);
        param_4 = pMVar23;
        if (iVar11 == -1) {
          if ((Matrix4x4 *)(uint)*(ushort *)&pMVar23->m02 < param_5) {
            iVar11 = (int)(uint)*(ushort *)&pMVar23->m02 * 0x118 + uVar17;
            puVar20[0x26] = *(uint *)(iVar11 + 0x98);
            puVar20[0x27] = *(uint *)(iVar11 + 0x9c);
            puVar20[0x28] = *(uint *)(iVar11 + 0xa0);
          }
          else if (param_3 != (Matrix4x4 *)0x0) {
            puVar20[0x26] = *(uint *)(uVar17 + 0x98);
            puVar20[0x27] = *(uint *)(uVar17 + 0x9c);
            puVar20[0x28] = *(uint *)(uVar17 + 0xa0);
          }
        }
        else {
          if (this->search_data_base_ptr != 0) {
            puVar20[0x2a] = (int)&local_8->interpolationModeAndTimeIndex + puVar20[0x2a];
            puVar20[0x2b] = (int)&local_8->interpolationModeAndTimeIndex + puVar20[0x2b];
          }
          pMVar10 = (Matrix4x4 *)(iVar11 * 0x44 + *(int *)(local_18 + 0x20));
          uVar17 = *(uint *)((int)this->animation_context_ptr + 0xc);
          if (((uint)pMVar10->m10 & 1) == 0) {
LAB_007145f1:
            param_5 = (Matrix4x4 *)pMVar10->m02;
            param_2 = (Matrix4x4 *)pMVar10->m01;
            if ((int)param_2 < (int)param_5) {
              local_1c = (float)(uVar17 - puVar20[0x2a]);
              lVar26 = __ftol();
              param_2 = (Matrix4x4 *)
                        ((int)&param_2->m00 +
                        ((int)lVar26 + puVar20[0x2e]) % (uint)((int)param_5 - (int)param_2));
            }
          }
          else {
            uVar18 = puVar20[0x2b];
            uVar9 = puVar20[0x2a];
            if (uVar18 != uVar17 && -1 < (int)(uVar18 - uVar17)) {
              if (uVar9 != uVar17 && -1 < (int)(uVar9 - uVar17)) {
                uVar17 = puVar20[0x2a];
              }
              goto LAB_007145f1;
            }
            param_2 = (Matrix4x4 *)(uVar18 - uVar9);
            param_5 = pMVar10;
            lVar26 = __ftol();
            iVar11 = (int)lVar26 + puVar20[0x2e];
            if (iVar11 < 0) {
              param_2 = (Matrix4x4 *)param_5->m01;
            }
            else {
              param_2 = (Matrix4x4 *)param_5->m02;
              if (iVar11 <= (int)param_2 - (int)param_5->m01) {
                param_2 = (Matrix4x4 *)(iVar11 + (int)param_5->m01);
              }
            }
          }
          puVar20[0x27] = puVar20[0x29];
          puVar20[0x26] = (uint)param_2;
          puVar20[0x28] = (uint)param_3;
        }
        if (puVar20[0x34] == 0xffffffff) {
          if ((uint)*(ushort *)&pMVar23->m02 < *(uint *)(local_18 + 0x34)) {
            uVar17 = (uint)*(ushort *)&pMVar23->m02 * 0x118 + this->unknown_0x80;
LAB_007147df:
            puVar20[0x31] = *(uint *)(uVar17 + 0xc4);
            puVar20[0x32] = *(uint *)(uVar17 + 200);
          }
          else {
            if (param_3 != (Matrix4x4 *)0x0) {
              uVar17 = this->unknown_0x80;
              goto LAB_007147df;
            }
            puVar20[0x31] = puVar20[0x26];
            puVar20[0x32] = puVar20[0x27];
          }
        }
        else {
          if (this->search_data_base_ptr != 0) {
            puVar20[0x35] = (int)&local_8->interpolationModeAndTimeIndex + puVar20[0x35];
            puVar20[0x36] = (int)&local_8->interpolationModeAndTimeIndex + puVar20[0x36];
          }
          iVar11 = puVar20[0x34] * 0x44;
          pMVar10 = (Matrix4x4 *)(iVar11 + *(int *)(local_18 + 0x20));
          uVar17 = *(uint *)((int)this->animation_context_ptr + 0xc);
          if ((*(byte *)(iVar11 + 0x10 + *(int *)(local_18 + 0x20)) & 1) == 0) {
LAB_00714757:
            param_5 = (Matrix4x4 *)pMVar10->m02;
            param_2 = (Matrix4x4 *)pMVar10->m01;
            if ((int)param_2 < (int)param_5) {
              local_1c = (float)(uVar17 - puVar20[0x35]);
              lVar26 = __ftol();
              param_2 = (Matrix4x4 *)
                        ((int)&param_2->m00 +
                        ((int)lVar26 + puVar20[0x39]) % (uint)((int)param_5 - (int)param_2));
            }
          }
          else {
            uVar18 = puVar20[0x36];
            uVar9 = puVar20[0x35];
            if (uVar18 != uVar17 && -1 < (int)(uVar18 - uVar17)) {
              if (uVar9 != uVar17 && -1 < (int)(uVar9 - uVar17)) {
                uVar17 = puVar20[0x35];
              }
              goto LAB_00714757;
            }
            param_2 = (Matrix4x4 *)(uVar18 - uVar9);
            param_5 = pMVar10;
            lVar26 = __ftol();
            iVar11 = (int)lVar26 + puVar20[0x39];
            if (iVar11 < 0) {
              param_2 = (Matrix4x4 *)param_5->m01;
            }
            else {
              param_2 = (Matrix4x4 *)param_5->m02;
              if (iVar11 <= (int)param_2 - (int)param_5->m01) {
                param_2 = (Matrix4x4 *)(iVar11 + (int)param_5->m01);
              }
            }
          }
          puVar20[0x32] = puVar20[0x34];
          puVar20[0x31] = (uint)param_2;
          if (-1 < (int)(*(int *)((int)this->animation_context_ptr + 0xc) - puVar20[0x40])) {
            puVar20[0x34] = 0xffffffff;
          }
        }
        if ((puVar20[0x29] == 0xffffffff) && (puVar20[0x34] == 0xffffffff)) {
          if ((uint)*(ushort *)&pMVar23->m02 < *(uint *)(local_18 + 0x34)) {
            puVar20[0x43] =
                 *(uint *)((uint)*(ushort *)&pMVar23->m02 * 0x118 + 0x10c + this->unknown_0x80);
          }
          else {
            if (param_3 == (Matrix4x4 *)0x0) goto LAB_00714923;
            puVar20[0x43] = *(uint *)(this->unknown_0x80 + 0x10c);
          }
        }
        else {
          iVar11 = puVar20[0x40] - *(int *)((int)this->animation_context_ptr + 0xc);
          if ((iVar11 < 1) || ((puVar20[0x26] == puVar20[0x31] && (puVar20[0x27] == puVar20[0x32])))
             ) {
LAB_00714923:
            puVar20[0x43] = 0;
          }
          else {
            fVar3 = (float)iVar11 * (float)puVar20[0x41];
            if ((float)COLLISION_PLANE_ZERO_THRESHOLD <= fVar3) {
              if (fVar3 <= StaticFloat1_0) {
                puVar20[0x43] =
                     (uint)((_DAT_0080297c - (fVar3 + fVar3)) * fVar3 * fVar3 * (float)puVar20[0x42]
                           );
              }
              else {
                puVar20[0x43] = (uint)(StaticFloat1_0 * (float)puVar20[0x42]);
              }
            }
            else {
              puVar20[0x43] = (uint)((float)COLLISION_PLANE_ZERO_THRESHOLD * (float)puVar20[0x42]);
            }
          }
        }
        param_5 = (Matrix4x4 *)(puVar20[0x3d] | (uint)pMVar23->m01);
        if (*(ushort *)&pMVar23->m02 == 0xffff) {
          param_2 = (Matrix4x4 *)&this->model_attachment_list1;
        }
        else {
          pMVar10 = (Matrix4x4 *)
                    ((uint)*(ushort *)&pMVar23->m02 * 0x40 + (int)this->transform_vec2_x);
          param_2 = pMVar10;
          if (((uint)param_5 & 7) != 0) {
            iVar11 = (int)&local_74 - (int)pMVar10;
            param_2 = (Matrix4x4 *)&DAT_00000008;
            do {
              *(float *)((int)pMVar10 + iVar11) = pMVar10->m00;
              *(float *)((int)pMVar10 + iVar11 + 4) = pMVar10->m01;
              pMVar10 = (Matrix4x4 *)&pMVar10->m02;
              param_2 = (Matrix4x4 *)((int)&param_2[-1].m33 + 3);
            } while (param_2 != (Matrix4x4 *)0x0);
            param_2 = &local_74;
            uVar17 = (uint)param_5 & 6;
            local_a8 = local_74.m20 * pMVar23[1].m22 +
                       local_74.m00 * pMVar23[1].m20 + local_74.m10 * pMVar23[1].m21 + local_74.m30;
            local_a4 = local_74.m21 * pMVar23[1].m22 +
                       local_74.m11 * pMVar23[1].m21 + local_74.m01 * pMVar23[1].m20 + local_74.m31;
            local_a0 = local_74.m22 * pMVar23[1].m22 +
                       local_74.m12 * pMVar23[1].m21 + local_74.m02 * pMVar23[1].m20 + local_74.m32;
            if (uVar17 == 2) {
              fVar25 = (float10)emptyFunction();
              if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
                fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
                local_74.m00 = (float)((float10)local_74.m00 * fVar25);
                local_74.m01 = (float)((float10)local_74.m01 * fVar25);
                local_74.m02 = (float)(fVar25 * (float10)local_74.m02);
              }
              fVar25 = (float10)emptyFunction();
              if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
                fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
                local_74.m10 = (float)((float10)local_74.m10 * fVar25);
                local_74.m11 = (float)((float10)local_74.m11 * fVar25);
                local_74.m12 = (float)((float10)local_74.m12 * fVar25);
              }
              fVar25 = (float10)emptyFunction();
              if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
                fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
                local_74.m20 = (float)((float10)local_74.m20 * fVar25);
                local_74.m21 = (float)((float10)local_74.m21 * fVar25);
                local_74.m22 = (float)(fVar25 * (float10)local_74.m22);
              }
            }
            else if (uVar17 == 4) {
              fVar3 = (float)this->attachment_list1 * (float)this->attachment_list1 +
                      (float)this->unknown_0xe4 * (float)this->unknown_0xe4 +
                      (float)this->model_attachment_list1 * (float)this->model_attachment_list1;
              fVar4 = StaticFloat1_0;
              if (_DAT_0080c5c8 < fVar3) {
                fVar4 = SQRT((local_74.m01 * local_74.m01 +
                             local_74.m02 * local_74.m02 + local_74.m00 * local_74.m00) / fVar3);
              }
              local_74.m00 = fVar4 * (float)this->model_attachment_list1;
              local_74.m01 = fVar4 * (float)this->unknown_0xe4;
              local_74.m02 = fVar4 * (float)this->attachment_list1;
              fVar3 = this->world_transform_matrix[2] * this->world_transform_matrix[2] +
                      this->world_transform_matrix[1] * this->world_transform_matrix[1] +
                      this->world_transform_matrix[0] * this->world_transform_matrix[0];
              fVar4 = StaticFloat1_0;
              if (_DAT_0080c5c8 < fVar3) {
                fVar4 = SQRT((local_74.m10 * local_74.m10 +
                             local_74.m11 * local_74.m11 + local_74.m12 * local_74.m12) / fVar3);
              }
              local_74.m10 = fVar4 * this->world_transform_matrix[0];
              local_74.m11 = fVar4 * this->world_transform_matrix[1];
              local_74.m12 = fVar4 * this->world_transform_matrix[2];
              fVar3 = this->world_transform_matrix[4] * this->world_transform_matrix[4] +
                      this->world_transform_matrix[6] * this->world_transform_matrix[6] +
                      this->world_transform_matrix[5] * this->world_transform_matrix[5];
              fVar4 = StaticFloat1_0;
              if (_DAT_0080c5c8 < fVar3) {
                fVar4 = SQRT((local_74.m20 * local_74.m20 +
                             local_74.m21 * local_74.m21 + local_74.m22 * local_74.m22) / fVar3);
              }
              local_74.m20 = fVar4 * this->world_transform_matrix[4];
              local_74.m21 = fVar4 * this->world_transform_matrix[5];
              local_74.m22 = fVar4 * this->world_transform_matrix[6];
            }
            else if (uVar17 == 6) {
              local_74.m00 = (float)this->model_attachment_list1;
              local_74.m01 = (float)this->unknown_0xe4;
              local_74.m02 = (float)this->attachment_list1;
              local_74.m10 = this->world_transform_matrix[0];
              local_74.m11 = this->world_transform_matrix[1];
              local_74.m12 = this->world_transform_matrix[2];
              local_74.m20 = this->world_transform_matrix[4];
              local_74.m21 = this->world_transform_matrix[5];
              local_74.m22 = this->world_transform_matrix[6];
            }
            if (((uint)param_5 & 1) == 0) {
              local_74.m30 = local_a8 -
                             (local_74.m20 * pMVar23[1].m22 +
                             local_74.m00 * pMVar23[1].m20 + local_74.m10 * pMVar23[1].m21);
              local_74.m31 = local_a4 -
                             (local_74.m21 * pMVar23[1].m22 +
                             local_74.m11 * pMVar23[1].m21 + local_74.m01 * pMVar23[1].m20);
              local_74.m32 = local_a0 -
                             (local_74.m22 * pMVar23[1].m22 +
                             local_74.m12 * pMVar23[1].m21 + local_74.m02 * pMVar23[1].m20);
            }
            else {
              local_74.m30 = this->world_transform_matrix[8];
              local_74.m31 = this->world_transform_matrix[9];
              local_74.m32 = this->world_transform_matrix[10];
            }
          }
        }
        local_1c = (float)((uint)param_5 & 0x280);
        if (local_1c == 0.0) {
          pMVar19 = (Matrix4x4 *)((int)param_3 * 0x40);
          pfVar12 = (float *)((int)&pMVar19->m00 + (int)this->transform_vec2_x);
          param_4 = (Matrix4x4 *)&DAT_00000008;
          pMVar10 = param_2;
          do {
            *pfVar12 = pMVar10->m00;
            pfVar12[1] = pMVar10->m01;
            pfVar12 = pfVar12 + 2;
            pMVar10 = (Matrix4x4 *)&pMVar10->m02;
            param_4 = (Matrix4x4 *)((int)&param_4[-1].m33 + 3);
          } while (param_4 != (Matrix4x4 *)0x0);
        }
        else {
          if (pMVar23->m31 == 0.0) {
            local_b0 = 0.0;
            local_b4 = 0.0;
            local_b8 = 0.0;
            local_bc = 0;
            local_c4 = 0.0;
            local_c8 = 0.0;
            local_cc = 0;
            local_d0 = 0.0;
            local_d8 = 0.0;
            local_dc = 0;
            local_e0 = 0.0;
            local_e4 = 0.0;
            local_ac = 0x3f800000;
            local_c0 = 1.0;
            local_d4 = 1.0;
            local_e8 = 1.0;
          }
          else {
            if (this->animation_frame_counter < (uint)pMVar23->m31) {
              interpolateAnimationKeyframes
                        (this,(uint)puVar20,(AnimationData *)&pMVar23->m22,
                         (InterpolationOutputBuffer *)(puVar20 + 0xc));
            }
            initPixelShaderDispatcher5();
          }
          cVar16 = (char)param_5;
          if (pMVar23[1].m10 != 0.0) {
            if (this->animation_frame_counter < (uint)pMVar23[1].m10) {
              puVar21 = puVar20 + 0x1a;
              findInterpolationIndices
                        (this,puVar20[0x26],puVar20[0x27],(AnimationData *)&param_4[1].m01,puVar21);
              if (*(short *)&param_4[1].m01 == 0) {
                puVar21 = (uint *)((int)param_4[1].m13 + *puVar21 * 0xc);
                puVar20[0x1d] = *puVar21;
                puVar20[0x1e] = puVar21[1];
                puVar20[0x1f] = puVar21[2];
              }
              else {
                fVar3 = (float)puVar20[0x1c];
                fVar4 = param_4[1].m13;
                iVar11 = (int)fVar4 + puVar20[0x1b] * 0xc;
                pfVar12 = (float *)((int)fVar4 + *puVar21 * 0xc);
                puVar20[0x1d] =
                     (uint)((*(float *)((int)fVar4 + puVar20[0x1b] * 0xc) -
                            *(float *)((int)fVar4 + *puVar21 * 0xc)) * fVar3 + *pfVar12);
                puVar20[0x1e] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
                puVar20[0x1f] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
                if (((float)COLLISION_PLANE_ZERO_THRESHOLD != (float)puVar20[0x43]) &&
                   (*(short *)((int)&param_4[1].m01 + 2) == -1)) {
                  findInterpolationIndices
                            (this,puVar20[0x31],puVar20[0x32],(AnimationData *)&param_4[1].m01,
                             puVar20 + 0x20);
                  fVar3 = (float)puVar20[0x22];
                  fVar4 = param_4[1].m13;
                  iVar11 = (int)fVar4 + puVar20[0x21] * 0xc;
                  pfVar12 = (float *)((int)fVar4 + puVar20[0x20] * 0xc);
                  puVar20[0x23] =
                       (uint)((*(float *)((int)fVar4 + puVar20[0x21] * 0xc) -
                              *(float *)((int)fVar4 + puVar20[0x20] * 0xc)) * fVar3 + *pfVar12);
                  puVar20[0x24] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1])
                  ;
                  puVar20[0x25] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2])
                  ;
                  fVar3 = (float)puVar20[0x43];
                  puVar20[0x1d] =
                       (uint)(((float)puVar20[0x23] - (float)puVar20[0x1d]) * fVar3 +
                             (float)puVar20[0x1d]);
                  puVar20[0x1e] =
                       (uint)(((float)puVar20[0x24] - (float)puVar20[0x1e]) * fVar3 +
                             (float)puVar20[0x1e]);
                  puVar20[0x1f] =
                       (uint)(((float)puVar20[0x25] - (float)puVar20[0x1f]) * fVar3 +
                             (float)puVar20[0x1f]);
                }
              }
            }
            scaleMatrix3x3ByVector(&local_e8,(float *)(puVar20 + 0x1d));
            cVar16 = (char)param_5;
            pMVar23 = param_4;
          }
          if ((cVar16 < '\0') && (puVar20[0x3c] != 0)) {
            initParticlePixelShaderGeneration();
          }
          local_34 = pMVar23[1].m20;
          local_30 = pMVar23[1].m21;
          fVar3 = pMVar23[1].m22;
          local_2c = fVar3;
          if (pMVar23->m12 != 0.0) {
            if (this->animation_frame_counter < (uint)pMVar23->m12) {
              findInterpolationIndices
                        (this,puVar20[0x26],puVar20[0x27],(AnimationData *)&pMVar23->m03,puVar20);
              if (*(short *)&pMVar23->m03 == 0) {
                puVar21 = (uint *)((int)pMVar23->m21 + *puVar20 * 0xc);
                puVar20[3] = *puVar21;
                puVar20[4] = puVar21[1];
                puVar20[5] = puVar21[2];
              }
              else {
                fVar3 = (float)puVar20[2];
                fVar4 = pMVar23->m21;
                iVar11 = (int)fVar4 + puVar20[1] * 0xc;
                pfVar12 = (float *)((int)fVar4 + *puVar20 * 0xc);
                puVar20[3] = (uint)((*(float *)((int)fVar4 + puVar20[1] * 0xc) -
                                    *(float *)((int)fVar4 + *puVar20 * 0xc)) * fVar3 + *pfVar12);
                puVar20[4] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
                puVar20[5] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
                if (((float)COLLISION_PLANE_ZERO_THRESHOLD != (float)puVar20[0x43]) &&
                   (*(short *)((int)&pMVar23->m03 + 2) == -1)) {
                  findInterpolationIndices
                            (this,puVar20[0x31],puVar20[0x32],(AnimationData *)&pMVar23->m03,
                             puVar20 + 6);
                  fVar3 = (float)puVar20[8];
                  fVar4 = pMVar23->m21;
                  iVar11 = (int)fVar4 + puVar20[7] * 0xc;
                  pfVar12 = (float *)((int)fVar4 + puVar20[6] * 0xc);
                  puVar20[9] = (uint)((*(float *)((int)fVar4 + puVar20[7] * 0xc) -
                                      *(float *)((int)fVar4 + puVar20[6] * 0xc)) * fVar3 + *pfVar12)
                  ;
                  puVar20[10] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
                  puVar20[0xb] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
                  fVar3 = (float)puVar20[0x43];
                  puVar20[3] = (uint)(((float)puVar20[9] - (float)puVar20[3]) * fVar3 +
                                     (float)puVar20[3]);
                  puVar20[4] = (uint)(((float)puVar20[10] - (float)puVar20[4]) * fVar3 +
                                     (float)puVar20[4]);
                  puVar20[5] = (uint)(((float)puVar20[0xb] - (float)puVar20[5]) * fVar3 +
                                     (float)puVar20[5]);
                }
              }
            }
            local_34 = local_34 + (float)puVar20[3];
            local_30 = local_30 + (float)puVar20[4];
            fVar3 = local_2c + (float)puVar20[5];
          }
          param_4 = (Matrix4x4 *)((int)param_3 * 0x40);
          local_b8 = local_34 -
                     (local_e8 * pMVar23[1].m20 +
                     local_d8 * pMVar23[1].m21 + local_c8 * pMVar23[1].m22);
          local_b4 = local_30 -
                     (local_e4 * pMVar23[1].m20 +
                     local_d4 * pMVar23[1].m21 + local_c4 * pMVar23[1].m22);
          local_b0 = fVar3 - (local_e0 * pMVar23[1].m20 +
                             local_d0 * pMVar23[1].m21 + local_c0 * pMVar23[1].m22);
          initParticlePixelShaderGeneration();
          pMVar19 = param_4;
        }
        if (((uint)param_5 & 0x78) != 0) {
          fVar3 = *(float *)((int)&pMVar19->m02 + (int)this->transform_vec2_x);
          pfVar12 = (float *)((int)&pMVar19->m00 + (int)this->transform_vec2_x);
          local_9c = SQRT(fVar3 * fVar3 + pfVar12[1] * pfVar12[1] + *pfVar12 * *pfVar12);
          local_98 = SQRT(pfVar12[6] * pfVar12[6] +
                          pfVar12[5] * pfVar12[5] + pfVar12[4] * pfVar12[4]);
          local_94 = SQRT(pfVar12[10] * pfVar12[10] +
                          pfVar12[9] * pfVar12[9] + pfVar12[8] * pfVar12[8]);
          local_a8 = pMVar23[1].m20 * *pfVar12 +
                     pfVar12[4] * pMVar23[1].m21 + pMVar23[1].m22 * pfVar12[8] + pfVar12[0xc];
          local_a4 = pfVar12[5] * pMVar23[1].m21 +
                     pfVar12[9] * pMVar23[1].m22 + pMVar23[1].m20 * pfVar12[1] + pfVar12[0xd];
          local_a0 = pfVar12[6] * pMVar23[1].m21 +
                     pfVar12[10] * pMVar23[1].m22 + pMVar23[1].m20 * pfVar12[2] + pfVar12[0xe];
          switch((uint)param_5 & 0x78) {
          case 8:
            if (local_1c == 0.0) {
              local_13c = 0;
              *pfVar12 = 0.0;
              local_138 = 0;
              pfVar12[1] = 0.0;
              local_134 = 0xbf800000;
              pfVar12[2] = -1.0;
              local_154 = 0x3f800000;
              pfVar12[4] = 1.0;
              local_150 = 0;
              pfVar12[5] = 0.0;
              local_14c = 0;
              pfVar12[6] = 0.0;
              local_160 = 0;
              pfVar12[8] = 0.0;
              local_15c = 0x3f800000;
              local_158 = 0;
              pfVar12[9] = 1.0;
              pfVar12[10] = 0.0;
            }
            else {
              local_f4 = local_e4;
              local_f0 = local_e0;
              local_ec = -local_e8;
              *pfVar12 = local_e4;
              pfVar12[1] = local_e0;
              pfVar12[2] = local_ec;
              fVar25 = (float10)emptyFunction();
              if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
                fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
                *pfVar12 = (float)(fVar25 * (float10)*pfVar12);
                pfVar12[1] = (float)(fVar25 * (float10)pfVar12[1]);
                pfVar12[2] = (float)(fVar25 * (float10)pfVar12[2]);
              }
              local_10c = local_d4;
              local_108 = local_d0;
              pfVar12[4] = local_d4;
              local_104 = -local_d8;
              pfVar12[5] = local_d0;
              pfVar12[6] = local_104;
              fVar25 = (float10)emptyFunction();
              if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
                fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
                pfVar12[4] = (float)(fVar25 * (float10)pfVar12[4]);
                pfVar12[5] = (float)(fVar25 * (float10)pfVar12[5]);
                pfVar12[6] = (float)(fVar25 * (float10)pfVar12[6]);
              }
              local_124 = local_c4;
              local_120 = local_c0;
              pfVar12[8] = local_c4;
              local_11c = -local_c8;
              pfVar12[9] = local_c0;
              pfVar12[10] = local_11c;
              fVar25 = (float10)emptyFunction();
              if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
                fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
                pfVar12[8] = (float)(fVar25 * (float10)pfVar12[8]);
                pfVar12[9] = (float)(fVar25 * (float10)pfVar12[9]);
                pfVar12[10] = (float)(fVar25 * (float10)pfVar12[10]);
              }
            }
            break;
          case 0x10:
            fVar25 = (float10)emptyFunction();
            if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
              fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
              *pfVar12 = (float)(fVar25 * (float10)*pfVar12);
              pfVar12[1] = (float)(fVar25 * (float10)pfVar12[1]);
              pfVar12[2] = (float)(fVar25 * (float10)pfVar12[2]);
            }
            local_118 = pfVar12[1];
            local_114 = -*pfVar12;
            pfVar12[4] = local_118;
            pfVar12[5] = local_114;
            local_110 = 0;
            pfVar12[6] = 0.0;
            fVar25 = (float10)emptyFunction();
            if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
              fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
              pfVar12[4] = (float)(fVar25 * (float10)pfVar12[4]);
              pfVar12[5] = (float)(fVar25 * (float10)pfVar12[5]);
              pfVar12[6] = (float)(fVar25 * (float10)pfVar12[6]);
            }
            local_148 = pfVar12[2] * pfVar12[5] - pfVar12[1] * pfVar12[6];
            local_144 = *pfVar12 * pfVar12[6] - pfVar12[2] * pfVar12[4];
            pfVar12[8] = local_148;
            pfVar12[9] = local_144;
            local_140 = pfVar12[1] * pfVar12[4] - *pfVar12 * pfVar12[5];
            pfVar12[10] = local_140;
            break;
          case 0x20:
            fVar25 = (float10)emptyFunction();
            if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
              fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
              pfVar12[4] = (float)(fVar25 * (float10)pfVar12[4]);
              pfVar12[5] = (float)(fVar25 * (float10)pfVar12[5]);
              pfVar12[6] = (float)(fVar25 * (float10)pfVar12[6]);
            }
            local_130 = -pfVar12[5];
            local_128 = 0;
            local_12c = pfVar12[4];
            *pfVar12 = local_130;
            pfVar12[1] = local_12c;
            pfVar12[2] = 0.0;
            fVar25 = (float10)emptyFunction();
            if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar25))) {
              fVar25 = (float10)StaticFloat1_0 / SQRT(fVar25);
              *pfVar12 = (float)(fVar25 * (float10)*pfVar12);
              pfVar12[1] = (float)(fVar25 * (float10)pfVar12[1]);
              pfVar12[2] = (float)(fVar25 * (float10)pfVar12[2]);
            }
            local_100 = pfVar12[2] * pfVar12[5] - pfVar12[1] * pfVar12[6];
            local_fc = *pfVar12 * pfVar12[6] - pfVar12[2] * pfVar12[4];
            pfVar12[8] = local_100;
            pfVar12[9] = local_fc;
            local_f8 = pfVar12[1] * pfVar12[4] - *pfVar12 * pfVar12[5];
            pfVar12[10] = local_f8;
            break;
          case 0x40:
            fVar3 = SQRT(pfVar12[8] * pfVar12[8] +
                         pfVar12[9] * pfVar12[9] + pfVar12[10] * pfVar12[10]);
            if (_DAT_008029d4 <= ABS(fVar3)) {
              fVar3 = StaticFloat1_0 / fVar3;
              pfVar12[8] = fVar3 * pfVar12[8];
              pfVar12[9] = fVar3 * pfVar12[9];
              pfVar12[10] = fVar3 * pfVar12[10];
            }
            local_84 = pfVar12[9];
            pfVar1 = pfVar12 + 4;
            local_80 = -pfVar12[8];
            *pfVar1 = local_84;
            pfVar12[5] = local_80;
            local_7c = 0.0;
            pfVar12[6] = 0.0;
            fVar3 = SQRT(*pfVar1 * *pfVar1 + pfVar12[5] * pfVar12[5] + pfVar12[6] * pfVar12[6]);
            if (_DAT_008029d4 <= ABS(fVar3)) {
              fVar3 = StaticFloat1_0 / fVar3;
              *pfVar1 = fVar3 * *pfVar1;
              pfVar12[5] = fVar3 * pfVar12[5];
              pfVar12[6] = fVar3 * pfVar12[6];
            }
            local_90 = pfVar12[9] * pfVar12[6] - pfVar12[10] * pfVar12[5];
            local_8c = pfVar12[10] * *pfVar1 - pfVar12[8] * pfVar12[6];
            *pfVar12 = local_90;
            pfVar12[1] = local_8c;
            local_88 = pfVar12[8] * pfVar12[5] - pfVar12[9] * *pfVar1;
            pfVar12[2] = local_88;
          }
          fVar3 = *pfVar12;
          pfVar12[3] = 0.0;
          pfVar12[7] = 0.0;
          pfVar12[0xb] = 0.0;
          *pfVar12 = local_9c * fVar3;
          fVar4 = pfVar12[1];
          pfVar12[1] = local_9c * fVar4;
          local_10 = (uint *)(local_9c * pfVar12[2]);
          pfVar12[2] = (float)local_10;
          fVar5 = pfVar12[4];
          pfVar12[4] = local_98 * fVar5;
          param_4 = (Matrix4x4 *)(local_98 * pfVar12[5]);
          pfVar12[5] = (float)param_4;
          param_2 = (Matrix4x4 *)(local_98 * pfVar12[6]);
          pfVar12[6] = (float)param_2;
          fVar6 = pfVar12[8];
          pfVar12[8] = local_94 * fVar6;
          fVar7 = pfVar12[9];
          pfVar12[9] = local_94 * fVar7;
          local_1c = local_94 * pfVar12[10];
          pfVar12[10] = local_1c;
          pfVar12[0xc] = local_a8 -
                         (local_9c * fVar3 * pMVar23[1].m20 +
                         local_94 * fVar6 * pMVar23[1].m22 + local_98 * fVar5 * pMVar23[1].m21);
          pfVar12[0xd] = local_a4 -
                         (local_9c * fVar4 * pMVar23[1].m20 +
                         local_94 * fVar7 * pMVar23[1].m22 + (float)param_4 * pMVar23[1].m21);
          fVar3 = pMVar23[1].m21;
          fVar4 = pMVar23[1].m22;
          fVar5 = pMVar23[1].m20;
          pfVar12[0xf] = 1.0;
          pfVar12[0xe] = local_a0 -
                         ((float)local_10 * fVar5 + local_1c * fVar4 + (float)param_2 * fVar3);
        }
        param_5 = *(Matrix4x4 **)(local_18 + 0x34);
        param_3 = (Matrix4x4 *)((int)&param_3->m00 + 1);
      } while (param_3 < param_5);
    }
    local_10 = (uint *)0x0;
    if (*(int *)(local_18 + 0x54) != 0) {
      local_24 = (uint *)0x0;
      local_20 = 0;
      do {
        pAVar24 = (AnimationData *)(*(int *)(local_18 + 0x58) + local_20);
        puVar20 = (uint *)((int)this->transform_vec2_y + (int)local_24);
        if (this->animation_frame_counter < *(uint *)(*(int *)(local_18 + 0x58) + 0xc + local_20)) {
          local_8 = (AnimationData *)this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)&local_8[2].field_0x28,*(uint *)&local_8[2].field_0x2c,pAVar24,
                     puVar20);
          if ((short)pAVar24->interpolationModeAndTimeIndex == 0) {
            puVar21 = (uint *)(pAVar24->keyframe_base_ptr + *puVar20 * 0xc);
            puVar20[3] = *puVar21;
            puVar20[4] = puVar21[1];
            puVar20[5] = puVar21[2];
          }
          else {
            fVar3 = (float)puVar20[2];
            uVar17 = pAVar24->keyframe_base_ptr;
            iVar11 = uVar17 + puVar20[1] * 0xc;
            pfVar12 = (float *)(uVar17 + *puVar20 * 0xc);
            puVar20[3] = (uint)((*(float *)(uVar17 + puVar20[1] * 0xc) -
                                *(float *)(uVar17 + *puVar20 * 0xc)) * fVar3 + *pfVar12);
            puVar20[4] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
            puVar20[5] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)&local_8[4].field_0x2c) &&
               (*(short *)((int)&pAVar24->interpolationModeAndTimeIndex + 2) == -1)) {
              findInterpolationIndices
                        (this,*(uint *)&local_8[3].field_0x1c,*(uint *)&local_8[3].field_0x20,
                         pAVar24,puVar20 + 6);
              fVar3 = (float)puVar20[8];
              uVar17 = pAVar24->keyframe_base_ptr;
              iVar11 = uVar17 + puVar20[7] * 0xc;
              pfVar12 = (float *)(uVar17 + puVar20[6] * 0xc);
              puVar20[9] = (uint)((*(float *)(uVar17 + puVar20[7] * 0xc) -
                                  *(float *)(uVar17 + puVar20[6] * 0xc)) * fVar3 + *pfVar12);
              puVar20[10] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
              puVar20[0xb] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
              fVar3 = *(float *)&local_8[4].field_0x2c;
              puVar20[3] = (uint)(((float)puVar20[9] - (float)puVar20[3]) * fVar3 +
                                 (float)puVar20[3]);
              puVar20[4] = (uint)(((float)puVar20[10] - (float)puVar20[4]) * fVar3 +
                                 (float)puVar20[4]);
              puVar20[5] = (uint)(((float)puVar20[0xb] - (float)puVar20[5]) * fVar3 +
                                 (float)puVar20[5]);
            }
          }
        }
        if (this->animation_frame_counter < *(uint *)&pAVar24->field_0x28) {
          local_c = (AnimationData *)&pAVar24->field_0x1c;
          uVar17 = this->unknown_0x80;
          puVar21 = puVar20 + 0xc;
          findInterpolationIndices
                    (this,*(uint *)(uVar17 + 0x98),*(uint *)(uVar17 + 0x9c),local_c,puVar21);
          if ((short)local_c->interpolationModeAndTimeIndex == 0) {
            local_1c = (float)(int)*(short *)(local_c->keyframe_base_ptr + *puVar21 * 2);
            puVar20[0xf] = (uint)((float)(int)local_1c * _DAT_00811610);
          }
          else {
            local_78 = (float)puVar20[0xe];
            local_8 = (AnimationData *)&local_c->_padding;
            puVar13 = (undefined2 *)getIndexOffset(local_8,puVar20[0xd]);
            setShortValue((void *)((int)&param_4 + 2),puVar13);
            puVar13 = (undefined2 *)getIndexOffset(local_8,*puVar21);
            setShortValue((void *)((int)&param_3 + 2),puVar13);
            local_1c = (float)(int)param_4._2_2_;
            puVar20[0xf] = (uint)(((float)(int)local_1c * _DAT_00811610 -
                                  (float)(int)param_3._2_2_ * _DAT_00811610) * local_78 +
                                 (float)(int)param_3._2_2_ * _DAT_00811610);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(uVar17 + 0x10c)) &&
               (*(short *)((int)&local_c->interpolationModeAndTimeIndex + 2) == -1)) {
              findInterpolationIndices
                        (this,*(uint *)(uVar17 + 0xc4),*(uint *)(uVar17 + 200),local_c,
                         puVar20 + 0x10);
              local_14 = (float *)puVar20[0x12];
              puVar13 = (undefined2 *)getIndexOffset(local_8,puVar20[0x11]);
              setShortValue((void *)((int)&param_2 + 2),puVar13);
              puVar13 = (undefined2 *)getIndexOffset(local_8,puVar20[0x10]);
              setShortValue((void *)((int)&param_5 + 2),puVar13);
              local_1c = (float)(int)param_2._2_2_;
              fVar3 = ((float)(int)local_1c * _DAT_00811610 -
                      (float)(int)param_5._2_2_ * _DAT_00811610) * (float)local_14 +
                      (float)(int)param_5._2_2_ * _DAT_00811610;
              puVar20[0x13] = (uint)fVar3;
              puVar20[0xf] = (uint)((fVar3 - (float)puVar20[0xf]) * *(float *)(uVar17 + 0x10c) +
                                   (float)puVar20[0xf]);
            }
          }
        }
        local_10 = (uint *)((int)local_10 + 1);
        local_20 = local_20 + 0x38;
        local_24 = local_24 + 0x14;
      } while (local_10 < *(undefined1 **)(local_18 + 0x54));
    }
    local_c = (AnimationData *)0x0;
    if (*(int *)(local_18 + 100) != 0) {
      local_8 = (AnimationData *)0x0;
      local_20 = 0;
      do {
        pAVar24 = (AnimationData *)(*(int *)(local_18 + 0x68) + local_20);
        puVar20 = (uint *)((int)local_8 + (int)this->transform_vec2_z);
        if (this->animation_frame_counter < pAVar24->keyframe_count) {
          local_24 = (uint *)this->unknown_0x80;
          findInterpolationIndices(this,local_24[0x26],local_24[0x27],pAVar24,puVar20);
          if ((short)pAVar24->interpolationModeAndTimeIndex == 0) {
            local_14 = (float *)(int)*(short *)(pAVar24->keyframe_base_ptr + *puVar20 * 2);
            puVar20[3] = (uint)((float)(int)local_14 * _DAT_00811610);
          }
          else {
            local_78 = (float)puVar20[2];
            local_10 = &pAVar24->_padding;
            puVar13 = (undefined2 *)getIndexOffset(local_10,puVar20[1]);
            setShortValue((void *)((int)&param_4 + 2),puVar13);
            puVar13 = (undefined2 *)getIndexOffset(local_10,*puVar20);
            setShortValue((void *)((int)&param_3 + 2),puVar13);
            local_14 = (float *)(int)param_4._2_2_;
            puVar20[3] = (uint)(((float)(int)local_14 * _DAT_00811610 -
                                (float)(int)param_3._2_2_ * _DAT_00811610) * local_78 +
                               (float)(int)param_3._2_2_ * _DAT_00811610);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != (float)local_24[0x43]) &&
               (*(short *)((int)&pAVar24->interpolationModeAndTimeIndex + 2) == -1)) {
              findInterpolationIndices(this,local_24[0x31],local_24[0x32],pAVar24,puVar20 + 4);
              puVar21 = local_10;
              local_1c = (float)puVar20[6];
              puVar13 = (undefined2 *)getIndexOffset(local_10,puVar20[5]);
              setShortValue((void *)((int)&param_2 + 2),puVar13);
              puVar13 = (undefined2 *)getIndexOffset(puVar21,puVar20[4]);
              setShortValue((void *)((int)&param_5 + 2),puVar13);
              local_14 = (float *)(int)param_2._2_2_;
              fVar3 = ((float)(int)local_14 * _DAT_00811610 -
                      (float)(int)param_5._2_2_ * _DAT_00811610) * local_1c +
                      (float)(int)param_5._2_2_ * _DAT_00811610;
              puVar20[7] = (uint)fVar3;
              puVar20[3] = (uint)((fVar3 - (float)puVar20[3]) * (float)local_24[0x43] +
                                 (float)puVar20[3]);
            }
          }
        }
        local_c = (AnimationData *)((int)local_c + 1);
        local_20 = local_20 + 0x1c;
        local_8 = (AnimationData *)((int)local_8 + 0x20);
      } while (local_c < *(uint *)(local_18 + 100));
    }
    param_2 = (Matrix4x4 *)0x0;
    if (*(int *)(local_18 + 0x6c) != 0) {
      param_4 = (Matrix4x4 *)0x0;
      param_3 = (Matrix4x4 *)0x0;
      do {
        pAVar24 = (AnimationData *)((int)&param_3->m00 + *(int *)(local_18 + 0x70));
        puVar20 = (uint *)((int)&param_4->m00 + (int)this->scale_factor_1);
        if (this->animation_frame_counter < pAVar24->keyframe_count) {
          param_5 = (Matrix4x4 *)this->unknown_0x80;
          findInterpolationIndices(this,(uint)param_5[2].m12,(uint)param_5[2].m13,pAVar24,puVar20);
          uVar17 = pAVar24->interpolationModeAndTimeIndex;
          *(undefined2 *)(puVar20 + 3) = *(undefined2 *)(pAVar24->keyframe_base_ptr + *puVar20 * 2);
          if ((((short)uVar17 != 0) && ((float)COLLISION_PLANE_ZERO_THRESHOLD != param_5[4].m03)) &&
             (*(short *)((int)&pAVar24->interpolationModeAndTimeIndex + 2) == -1)) {
            findInterpolationIndices
                      (this,(uint)param_5[3].m01,(uint)param_5[3].m02,pAVar24,puVar20 + 4);
            *(undefined2 *)(puVar20 + 7) =
                 *(undefined2 *)(pAVar24->keyframe_base_ptr + puVar20[4] * 2);
          }
        }
        param_2 = (Matrix4x4 *)((int)&param_2->m00 + 1);
        param_3 = (Matrix4x4 *)&param_3->m13;
        param_4 = (Matrix4x4 *)&param_4->m20;
      } while (param_2 < *(Matrix4x4 **)(local_18 + 0x6c));
    }
    local_10 = (uint *)0x0;
    if (*(int *)(local_18 + 0x74) != 0) {
      local_20 = 0;
      local_24 = (uint *)0x0;
      param_2 = (Matrix4x4 *)0x0;
      do {
        if ((DAT_00cf04c4 & 1) == 0) {
          DAT_00cf04c4 = DAT_00cf04c4 | 1;
          _DAT_00cf043c = 0.5;
          _DAT_00cf0440 = 0.5;
          _DAT_00cf0444 = 0.0;
          validateMemoryOperation((int *)&DAT_007187e0);
        }
        fVar3 = this->scale_factor_2;
        param_3 = (Matrix4x4 *)((int)&param_2->m00 + *(int *)(local_18 + 0x78));
        pMVar23 = (Matrix4x4 *)((int)this->scale_factor_3 + local_20);
        pMVar23->m33 = 1.0;
        pMVar23->m22 = 1.0;
        pMVar23->m11 = 1.0;
        pMVar23->m00 = 1.0;
        puVar20 = (uint *)((int)fVar3 + (int)local_24);
        pMVar23->m32 = 0.0;
        pMVar23->m31 = 0.0;
        pMVar23->m30 = 0.0;
        pMVar23->m23 = 0.0;
        pMVar23->m21 = 0.0;
        pMVar23->m20 = 0.0;
        pMVar23->m13 = 0.0;
        pMVar23->m12 = 0.0;
        pMVar23->m10 = 0.0;
        pMVar23->m03 = 0.0;
        pMVar23->m02 = 0.0;
        pMVar23->m01 = 0.0;
        param_5 = pMVar23;
        if (param_3->m22 != 0.0) {
          interpolateAnimationKeyframes
                    (this,this->unknown_0x80,(AnimationData *)&param_3->m13,
                     (InterpolationOutputBuffer *)(puVar20 + 0xc));
          ApplyTranslationMatrix(pMVar23,(float *)&DAT_00cf043c);
          rotateMatrixByQuaternion(pMVar23,(float *)(puVar20 + 0xf));
          local_90 = -_DAT_00cf043c;
          local_8c = -_DAT_00cf0440;
          local_88 = -_DAT_00cf0444;
          ApplyTranslationMatrix(pMVar23,&local_90);
        }
        if (param_3[1].m01 != 0.0) {
          param_4 = (Matrix4x4 *)this->unknown_0x80;
          puVar21 = puVar20 + 0x1a;
          findInterpolationIndices
                    (this,(uint)param_4[2].m12,(uint)param_4[2].m13,(AnimationData *)&param_3->m32,
                     puVar21);
          if (*(short *)&param_3->m32 == 0) {
            puVar21 = (uint *)((int)param_3[1].m10 + *puVar21 * 0xc);
            puVar20[0x1d] = *puVar21;
            puVar20[0x1e] = puVar21[1];
            puVar20[0x1f] = puVar21[2];
          }
          else {
            fVar3 = (float)puVar20[0x1c];
            local_14 = &param_3->m32;
            fVar4 = param_3[1].m10;
            iVar11 = (int)fVar4 + puVar20[0x1b] * 0xc;
            pfVar12 = (float *)((int)fVar4 + *puVar21 * 0xc);
            puVar20[0x1d] =
                 (uint)((*(float *)((int)fVar4 + puVar20[0x1b] * 0xc) -
                        *(float *)((int)fVar4 + *puVar21 * 0xc)) * fVar3 + *pfVar12);
            puVar20[0x1e] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
            puVar20[0x1f] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_4[4].m03) &&
               (*(short *)((int)&param_3->m32 + 2) == -1)) {
              findInterpolationIndices
                        (this,(uint)param_4[3].m01,(uint)param_4[3].m02,
                         (AnimationData *)&param_3->m32,puVar20 + 0x20);
              fVar3 = (float)puVar20[0x22];
              fVar4 = param_3[1].m10;
              iVar11 = (int)fVar4 + puVar20[0x21] * 0xc;
              pfVar12 = (float *)((int)fVar4 + puVar20[0x20] * 0xc);
              puVar20[0x23] =
                   (uint)((*(float *)((int)fVar4 + puVar20[0x21] * 0xc) -
                          *(float *)((int)fVar4 + puVar20[0x20] * 0xc)) * fVar3 + *pfVar12);
              puVar20[0x24] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
              puVar20[0x25] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
              fVar3 = param_4[4].m03;
              puVar20[0x1d] =
                   (uint)(((float)puVar20[0x23] - (float)puVar20[0x1d]) * fVar3 +
                         (float)puVar20[0x1d]);
              puVar20[0x1e] =
                   (uint)(((float)puVar20[0x24] - (float)puVar20[0x1e]) * fVar3 +
                         (float)puVar20[0x1e]);
              puVar20[0x1f] =
                   (uint)(((float)puVar20[0x25] - (float)puVar20[0x1f]) * fVar3 +
                         (float)puVar20[0x1f]);
            }
          }
          pMVar23 = param_5;
          ApplyTranslationMatrix(param_5,(float *)&DAT_00cf043c);
          scaleMatrix3x3ByVector(pMVar23,(float *)(puVar20 + 0x1d));
          local_84 = -_DAT_00cf043c;
          local_80 = -_DAT_00cf0440;
          local_7c = -_DAT_00cf0444;
          ApplyTranslationMatrix(pMVar23,&local_84);
        }
        if (param_3->m03 != 0.0) {
          param_4 = (Matrix4x4 *)this->unknown_0x80;
          findInterpolationIndices
                    (this,(uint)param_4[2].m12,(uint)param_4[2].m13,(AnimationData *)param_3,puVar20
                    );
          if (*(short *)&param_3->m00 == 0) {
            param_5 = (Matrix4x4 *)(puVar20 + 3);
            pfVar12 = (float *)((int)param_3->m12 + *puVar20 * 0xc);
            param_5->m00 = *pfVar12;
            puVar20[4] = (uint)pfVar12[1];
            puVar20[5] = (uint)pfVar12[2];
          }
          else {
            fVar3 = (float)puVar20[2];
            fVar4 = param_3->m12;
            iVar11 = (int)fVar4 + puVar20[1] * 0xc;
            pfVar12 = (float *)((int)fVar4 + *puVar20 * 0xc);
            param_5 = (Matrix4x4 *)(puVar20 + 3);
            param_5->m00 = (*(float *)((int)fVar4 + puVar20[1] * 0xc) -
                           *(float *)((int)fVar4 + *puVar20 * 0xc)) * fVar3 + *pfVar12;
            puVar20[4] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
            puVar20[5] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_4[4].m03) &&
               (*(short *)((int)&param_3->m00 + 2) == -1)) {
              findInterpolationIndices
                        (this,(uint)param_4[3].m01,(uint)param_4[3].m02,(AnimationData *)param_3,
                         puVar20 + 6);
              fVar3 = (float)puVar20[8];
              fVar4 = param_3->m12;
              iVar11 = (int)fVar4 + puVar20[7] * 0xc;
              pfVar12 = (float *)((int)fVar4 + puVar20[6] * 0xc);
              puVar20[9] = (uint)((*(float *)((int)fVar4 + puVar20[7] * 0xc) -
                                  *(float *)((int)fVar4 + puVar20[6] * 0xc)) * fVar3 + *pfVar12);
              puVar20[10] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
              puVar20[0xb] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
              fVar3 = param_4[4].m03;
              param_5->m00 = ((float)puVar20[9] - param_5->m00) * fVar3 + param_5->m00;
              param_5->m01 = ((float)puVar20[10] - param_5->m01) * fVar3 + param_5->m01;
              param_5->m02 = ((float)puVar20[0xb] - param_5->m02) * fVar3 + param_5->m02;
            }
          }
          ApplyTranslationMatrix(pMVar23,&param_5->m00);
        }
        local_20 = local_20 + 0x40;
        local_10 = (uint *)((int)local_10 + 1);
        param_2 = (Matrix4x4 *)&param_2[1].m11;
        local_24 = local_24 + 0x26;
      } while (local_10 < *(uint *)(local_18 + 0x74));
    }
    local_10 = (uint *)0x0;
    if (*(int *)(local_18 + 0x11c) != 0) {
      param_2 = (Matrix4x4 *)0x0;
      param_5 = (Matrix4x4 *)0x0;
      do {
        param_3 = (Matrix4x4 *)((int)&param_5->m00 + *(int *)(local_18 + 0x120));
        puVar20 = (uint *)((int)&param_2->m00 + (int)this->field_0x1a4);
        if (puVar20[0x40] == 0) {
LAB_00716506:
          if (this->animation_frame_counter == 0) goto LAB_00716514;
        }
        else {
          if (param_3[3].m01 != 0.0) {
            iVar11 = (uint)*(ushort *)((int)&param_3->m00 + 2) * 0x118;
            iVar22 = iVar11 + this->unknown_0x80;
            findInterpolationIndices
                      (this,*(uint *)(iVar22 + 0x98),*(uint *)(iVar11 + 0x9c + this->unknown_0x80),
                       (AnimationData *)&param_3[2].m32,puVar20 + 0x38);
            puVar14 = COLLISION_PLANE_ZERO_THRESHOLD;
            if (*(short *)&param_3[2].m32 == 0) {
              *(undefined1 *)(puVar20 + 0x3b) = *(undefined1 *)((int)param_3[3].m10 + puVar20[0x38])
              ;
            }
            else {
              *(undefined1 *)(puVar20 + 0x3b) = *(undefined1 *)(puVar20[0x38] + (int)param_3[3].m10)
              ;
              if (((float)puVar14 != *(float *)(iVar22 + 0x10c)) &&
                 (*(short *)((int)&param_3[2].m32 + 2) == -1)) {
                param_4 = (Matrix4x4 *)(puVar20 + 0x3c);
                findInterpolationIndices
                          (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                           (AnimationData *)&param_3[2].m32,(uint *)param_4);
                *(undefined1 *)(puVar20 + 0x3f) =
                     *(undefined1 *)((int)param_4->m00 + (int)param_3[3].m10);
              }
            }
          }
          if ((puVar20[0x40] == 0) || ((char)puVar20[0x3b] == '\0')) goto LAB_00716506;
LAB_00716514:
          if (this->animation_frame_counter < (uint)param_3->m32) {
            iVar11 = (uint)*(ushort *)((int)&param_3->m00 + 2) * 0x118;
            iVar22 = iVar11 + this->unknown_0x80;
            findInterpolationIndices
                      (this,*(uint *)(iVar22 + 0x98),*(uint *)(iVar11 + 0x9c + this->unknown_0x80),
                       (AnimationData *)&param_3->m23,puVar20 + 0xc);
            if (*(short *)&param_3->m23 == 0) {
              puVar20[0xf] = *(uint *)((int)param_3[1].m01 + puVar20[0xc] * 4);
            }
            else {
              fVar3 = *(float *)((int)param_3[1].m01 + puVar20[0xc] * 4);
              puVar20[0xf] = (uint)((*(float *)((int)param_3[1].m01 + puVar20[0xd] * 4) - fVar3) *
                                    (float)puVar20[0xe] + fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(iVar22 + 0x10c)) &&
                 (*(short *)((int)&param_3->m23 + 2) == -1)) {
                param_4 = (Matrix4x4 *)(puVar20 + 0x10);
                findInterpolationIndices
                          (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                           (AnimationData *)&param_3->m23,(uint *)param_4);
                fVar3 = *(float *)((int)param_3[1].m01 + (int)param_4->m00 * 4);
                fVar3 = (*(float *)((int)param_3[1].m01 + puVar20[0x11] * 4) - fVar3) *
                        (float)puVar20[0x12] + fVar3;
                puVar20[0x13] = (uint)fVar3;
                puVar20[0xf] = (uint)((fVar3 - (float)puVar20[0xf]) * *(float *)(iVar22 + 0x10c) +
                                     (float)puVar20[0xf]);
              }
            }
          }
          if (this->animation_frame_counter < (uint)param_3->m13) {
            pfVar12 = &param_3->m10;
            iVar11 = (uint)*(ushort *)((int)&param_3->m00 + 2) * 0x118;
            param_4 = (Matrix4x4 *)(iVar11 + this->unknown_0x80);
            findInterpolationIndices
                      (this,*(uint *)(iVar11 + 0x98 + this->unknown_0x80),(uint)param_4[2].m13,
                       (AnimationData *)pfVar12,puVar20);
            if (*(short *)pfVar12 == 0) {
              puVar21 = (uint *)((int)param_3->m22 + *puVar20 * 0xc);
              puVar20[3] = *puVar21;
              puVar20[4] = puVar21[1];
              puVar20[5] = puVar21[2];
            }
            else {
              fVar3 = (float)puVar20[2];
              fVar4 = param_3->m22;
              iVar11 = (int)fVar4 + puVar20[1] * 0xc;
              pfVar1 = (float *)((int)fVar4 + *puVar20 * 0xc);
              pfVar12 = (float *)(puVar20 + 3);
              *pfVar12 = (*(float *)((int)fVar4 + puVar20[1] * 0xc) -
                         *(float *)((int)fVar4 + *puVar20 * 0xc)) * fVar3 + *pfVar1;
              puVar20[4] = (uint)((*(float *)(iVar11 + 4) - pfVar1[1]) * fVar3 + pfVar1[1]);
              puVar20[5] = (uint)((*(float *)(iVar11 + 8) - pfVar1[2]) * fVar3 + pfVar1[2]);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_4[4].m03) &&
                 (*(short *)((int)&param_3->m10 + 2) == -1)) {
                findInterpolationIndices
                          (this,(uint)param_4[3].m01,(uint)param_4[3].m02,
                           (AnimationData *)&param_3->m10,puVar20 + 6);
                fVar3 = (float)puVar20[8];
                fVar4 = param_3->m22;
                iVar11 = (int)fVar4 + puVar20[7] * 0xc;
                pfVar1 = (float *)((int)fVar4 + puVar20[6] * 0xc);
                puVar20[9] = (uint)((*(float *)((int)fVar4 + puVar20[7] * 0xc) -
                                    *(float *)((int)fVar4 + puVar20[6] * 0xc)) * fVar3 + *pfVar1);
                puVar20[10] = (uint)((*(float *)(iVar11 + 4) - pfVar1[1]) * fVar3 + pfVar1[1]);
                puVar20[0xb] = (uint)((*(float *)(iVar11 + 8) - pfVar1[2]) * fVar3 + pfVar1[2]);
                fVar3 = param_4[4].m03;
                *pfVar12 = ((float)puVar20[9] - *pfVar12) * fVar3 + *pfVar12;
                puVar20[4] = (uint)(((float)puVar20[10] - (float)puVar20[4]) * fVar3 +
                                   (float)puVar20[4]);
                puVar20[5] = (uint)(((float)puVar20[0xb] - (float)puVar20[5]) * fVar3 +
                                   (float)puVar20[5]);
              }
            }
            local_88 = (float)puVar20[0xf] * this->render_scale_z;
            local_90 = local_88 * (float)puVar20[3];
            local_8c = local_88 * (float)puVar20[4];
            local_88 = local_88 * (float)puVar20[5];
            puVar20[0x4d] = (uint)local_90;
            puVar20[0x4e] = (uint)local_8c;
            puVar20[0x4f] = (uint)local_88;
          }
          if (this->animation_frame_counter < (uint)param_3[1].m30) {
            iVar11 = (uint)*(ushort *)((int)&param_3->m00 + 2) * 0x118;
            iVar22 = iVar11 + this->unknown_0x80;
            findInterpolationIndices
                      (this,*(uint *)(iVar11 + 0x98 + this->unknown_0x80),*(uint *)(iVar22 + 0x9c),
                       (AnimationData *)&param_3[1].m21,puVar20 + 0x20);
            if (*(short *)&param_3[1].m21 == 0) {
              puVar20[0x23] = *(uint *)((int)param_3[1].m33 + puVar20[0x20] * 4);
            }
            else {
              fVar3 = *(float *)((int)param_3[1].m33 + puVar20[0x20] * 4);
              puVar20[0x23] =
                   (uint)((*(float *)((int)param_3[1].m33 + puVar20[0x21] * 4) - fVar3) *
                          (float)puVar20[0x22] + fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(iVar22 + 0x10c)) &&
                 (*(short *)((int)&param_3[1].m21 + 2) == -1)) {
                param_4 = (Matrix4x4 *)(puVar20 + 0x24);
                findInterpolationIndices
                          (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                           (AnimationData *)&param_3[1].m21,(uint *)param_4);
                fVar3 = *(float *)((int)param_3[1].m33 + (int)param_4->m00 * 4);
                fVar3 = (*(float *)((int)param_3[1].m33 + puVar20[0x25] * 4) - fVar3) *
                        (float)puVar20[0x26] + fVar3;
                puVar20[0x27] = (uint)fVar3;
                puVar20[0x23] =
                     (uint)((fVar3 - (float)puVar20[0x23]) * *(float *)(iVar22 + 0x10c) +
                           (float)puVar20[0x23]);
              }
            }
          }
          if (this->animation_frame_counter < (uint)param_3[1].m11) {
            pMVar23 = param_3 + 1;
            puVar21 = puVar20 + 0x14;
            param_4 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&param_3->m00 + 2) * 0x118 + this->unknown_0x80);
            param_3 = (Matrix4x4 *)&pMVar23->m02;
            findInterpolationIndices
                      (this,(uint)param_4[2].m12,(uint)param_4[2].m13,(AnimationData *)&pMVar23->m02
                       ,puVar21);
            if (*(short *)&param_3->m00 == 0) {
              puVar21 = (uint *)((int)param_3->m12 + *puVar21 * 0xc);
              puVar20[0x17] = *puVar21;
              puVar20[0x18] = puVar21[1];
              puVar20[0x19] = puVar21[2];
            }
            else {
              fVar4 = param_3->m12;
              fVar3 = (float)puVar20[0x16];
              iVar11 = (int)fVar4 + puVar20[0x15] * 0xc;
              pfVar12 = (float *)((int)fVar4 + *puVar21 * 0xc);
              puVar20[0x17] =
                   (uint)((*(float *)((int)fVar4 + puVar20[0x15] * 0xc) -
                          *(float *)((int)fVar4 + *puVar21 * 0xc)) * fVar3 + *pfVar12);
              puVar20[0x18] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
              puVar20[0x19] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_4[4].m03) &&
                 (*(short *)((int)&param_3->m00 + 2) == -1)) {
                findInterpolationIndices
                          (this,(uint)param_4[3].m01,(uint)param_4[3].m02,(AnimationData *)param_3,
                           puVar20 + 0x1a);
                fVar3 = (float)puVar20[0x1c];
                fVar4 = param_3->m12;
                iVar11 = (int)fVar4 + puVar20[0x1b] * 0xc;
                pfVar12 = (float *)((int)fVar4 + puVar20[0x1a] * 0xc);
                puVar20[0x1d] =
                     (uint)((*(float *)((int)fVar4 + puVar20[0x1b] * 0xc) -
                            *(float *)((int)fVar4 + puVar20[0x1a] * 0xc)) * fVar3 + *pfVar12);
                puVar20[0x1e] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
                puVar20[0x1f] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
                fVar3 = param_4[4].m03;
                puVar20[0x17] =
                     (uint)(((float)puVar20[0x1d] - (float)puVar20[0x17]) * fVar3 +
                           (float)puVar20[0x17]);
                puVar20[0x18] =
                     (uint)(((float)puVar20[0x1e] - (float)puVar20[0x18]) * fVar3 +
                           (float)puVar20[0x18]);
                puVar20[0x19] =
                     (uint)(((float)puVar20[0x1f] - (float)puVar20[0x19]) * fVar3 +
                           (float)puVar20[0x19]);
              }
            }
            local_7c = (float)puVar20[0x23] * this->render_scale_z;
            local_84 = local_7c * (float)puVar20[0x17];
            local_80 = local_7c * (float)puVar20[0x18];
            local_7c = local_7c * (float)puVar20[0x19];
            puVar20[0x50] = (uint)local_84;
            puVar20[0x51] = (uint)local_80;
            puVar20[0x52] = (uint)local_7c;
          }
        }
        local_10 = (uint *)((int)local_10 + 1);
        param_5 = (Matrix4x4 *)&param_5[3].m11;
        param_2 = (Matrix4x4 *)&param_2[5].m30;
      } while (local_10 < (uint)*(float *)(local_18 + 0x11c));
    }
    local_c = (AnimationData *)0x0;
    if (*(int *)(local_18 + 0x124) != 0) {
      local_20 = 0;
      local_24 = (uint *)0x0;
      do {
        pMVar23 = (Matrix4x4 *)(*(int *)(local_18 + 0x128) + (int)local_24);
        puVar20 = (uint *)(this->particle_data_array3 + local_20);
        param_3 = pMVar23;
        if (this->animation_frame_counter < (uint)pMVar23->m13) {
          param_2 = (Matrix4x4 *)this->unknown_0x80;
          pfVar12 = &pMVar23->m10;
          findInterpolationIndices
                    (this,(uint)param_2[2].m12,(uint)param_2[2].m13,(AnimationData *)pfVar12,puVar20
                    );
          fVar3 = pMVar23->m22;
          if (*(short *)pfVar12 == 0) {
            puVar21 = (uint *)((int)fVar3 + *puVar20 * 0x24);
            puVar20[3] = *puVar21;
            puVar20[4] = puVar21[1];
            puVar20[5] = puVar21[2];
          }
          else {
            pfVar1 = (float *)((int)fVar3 + *puVar20 * 0x24);
            pfVar2 = (float *)((int)fVar3 + puVar20[1] * 0x24);
            sVar8 = *(short *)pfVar12;
            if (sVar8 == 1) {
              fVar3 = (float)puVar20[2];
              puVar20[3] = (uint)((*pfVar2 - *pfVar1) * fVar3 + *pfVar1);
              puVar20[4] = (uint)((pfVar2[1] - pfVar1[1]) * fVar3 + pfVar1[1]);
              puVar20[5] = (uint)((pfVar2[2] - pfVar1[2]) * fVar3 + pfVar1[2]);
            }
            else if (sVar8 == 2) {
              fVar3 = (float)puVar20[2];
              fVar4 = fVar3 * fVar3;
              param_4 = (Matrix4x4 *)(fVar4 * fVar3);
              local_10 = (uint *)(_DAT_0080297c * fVar4);
              param_5 = (Matrix4x4 *)
                        ((((float)local_10 - (float)param_4) - fVar3 * _DAT_0080297c) +
                        StaticFloat1_0);
              local_8 = (AnimationData *)((float)param_4 * _DAT_0080297c);
              fVar3 = ((float)local_8 - fVar4 * _DAT_00802990) + fVar3 * _DAT_0080297c;
              fVar4 = (float)local_10 - (float)local_8;
              puVar20[3] = (uint)(fVar4 * pfVar2[3] +
                                 fVar3 * pfVar1[6] +
                                 (float)param_4 * *pfVar2 + (float)param_5 * *pfVar1);
              puVar20[4] = (uint)((float)param_4 * pfVar2[1] +
                                 (float)param_5 * pfVar1[1] + fVar3 * pfVar1[7] + fVar4 * pfVar2[4])
              ;
              puVar20[5] = (uint)((float)param_4 * pfVar2[2] +
                                 (float)param_5 * pfVar1[2] + fVar3 * pfVar1[8] + fVar4 * pfVar2[5])
              ;
            }
            else if (sVar8 == 3) {
              fVar3 = (float)puVar20[2];
              fVar4 = fVar3 * fVar3;
              fVar5 = fVar4 * fVar3;
              local_8 = (AnimationData *)(fVar5 + fVar5);
              local_10 = (uint *)(fVar4 * _DAT_0080297c);
              param_5 = (Matrix4x4 *)(((float)local_8 - (float)local_10) + StaticFloat1_0);
              param_4 = (Matrix4x4 *)((fVar5 - (fVar4 + fVar4)) + fVar3);
              fVar5 = fVar5 - fVar4;
              fVar3 = (float)local_10 - (float)local_8;
              puVar20[3] = (uint)((float)param_4 * pfVar1[6] +
                                 fVar3 * *pfVar2 + (float)param_5 * *pfVar1 + fVar5 * pfVar2[3]);
              puVar20[4] = (uint)((float)param_5 * pfVar1[1] +
                                 fVar3 * pfVar2[1] + (float)param_4 * pfVar1[7] + fVar5 * pfVar2[4])
              ;
              puVar20[5] = (uint)((float)param_5 * pfVar1[2] +
                                 fVar3 * pfVar2[2] + (float)param_4 * pfVar1[8] + fVar5 * pfVar2[5])
              ;
            }
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_2[4].m03) &&
               (*(short *)((int)&pMVar23->m10 + 2) == -1)) {
              findInterpolationIndices
                        (this,(uint)param_2[3].m01,(uint)param_2[3].m02,(AnimationData *)pfVar12,
                         puVar20 + 6);
              pfVar1 = (float *)((int)pMVar23->m22 + puVar20[6] * 0x24);
              pfVar2 = (float *)((int)pMVar23->m22 + puVar20[7] * 0x24);
              sVar8 = *(short *)pfVar12;
              if (sVar8 == 1) {
                fVar3 = (float)puVar20[8];
                puVar20[9] = (uint)((*pfVar2 - *pfVar1) * fVar3 + *pfVar1);
                puVar20[10] = (uint)((pfVar2[1] - pfVar1[1]) * fVar3 + pfVar1[1]);
                puVar20[0xb] = (uint)((pfVar2[2] - pfVar1[2]) * fVar3 + pfVar1[2]);
              }
              else if (sVar8 == 2) {
                fVar3 = (float)puVar20[8];
                fVar4 = fVar3 * fVar3;
                param_4 = (Matrix4x4 *)(fVar4 * fVar3);
                local_10 = (uint *)(_DAT_0080297c * fVar4);
                param_5 = (Matrix4x4 *)
                          ((((float)local_10 - (float)param_4) - fVar3 * _DAT_0080297c) +
                          StaticFloat1_0);
                local_8 = (AnimationData *)((float)param_4 * _DAT_0080297c);
                fVar3 = ((float)local_8 - fVar4 * _DAT_00802990) + fVar3 * _DAT_0080297c;
                fVar4 = (float)local_10 - (float)local_8;
                puVar20[9] = (uint)(fVar3 * pfVar1[6] +
                                   (float)param_4 * *pfVar2 +
                                   (float)param_5 * *pfVar1 + fVar4 * pfVar2[3]);
                puVar20[10] = (uint)((float)param_4 * pfVar2[1] +
                                    (float)param_5 * pfVar1[1] +
                                    fVar3 * pfVar1[7] + fVar4 * pfVar2[4]);
                puVar20[0xb] = (uint)((float)param_4 * pfVar2[2] +
                                     (float)param_5 * pfVar1[2] +
                                     fVar3 * pfVar1[8] + fVar4 * pfVar2[5]);
              }
              else if (sVar8 == 3) {
                fVar3 = (float)puVar20[8];
                fVar4 = fVar3 * fVar3;
                fVar5 = fVar4 * fVar3;
                local_8 = (AnimationData *)(fVar5 + fVar5);
                local_10 = (uint *)(fVar4 * _DAT_0080297c);
                param_5 = (Matrix4x4 *)(((float)local_8 - (float)local_10) + StaticFloat1_0);
                param_4 = (Matrix4x4 *)((fVar5 - (fVar4 + fVar4)) + fVar3);
                fVar5 = fVar5 - fVar4;
                fVar3 = (float)local_10 - (float)local_8;
                puVar20[9] = (uint)(fVar5 * pfVar2[3] +
                                   fVar3 * *pfVar2 +
                                   (float)param_4 * pfVar1[6] + (float)param_5 * *pfVar1);
                puVar20[10] = (uint)((float)param_5 * pfVar1[1] +
                                    fVar3 * pfVar2[1] +
                                    (float)param_4 * pfVar1[7] + fVar5 * pfVar2[4]);
                puVar20[0xb] = (uint)((float)param_5 * pfVar1[2] +
                                     fVar3 * pfVar2[2] +
                                     (float)param_4 * pfVar1[8] + fVar5 * pfVar2[5]);
              }
              fVar3 = param_2[4].m03;
              puVar20[3] = (uint)(((float)puVar20[9] - (float)puVar20[3]) * fVar3 +
                                 (float)puVar20[3]);
              puVar20[4] = (uint)(((float)puVar20[10] - (float)puVar20[4]) * fVar3 +
                                 (float)puVar20[4]);
              puVar20[5] = (uint)(((float)puVar20[0xb] - (float)puVar20[5]) * fVar3 +
                                 (float)puVar20[5]);
            }
          }
        }
        if (this->animation_frame_counter < (uint)param_3[1].m01) {
          param_2 = (Matrix4x4 *)this->unknown_0x80;
          findInterpolationIndices
                    (this,(uint)param_2[2].m12,(uint)param_2[2].m13,(AnimationData *)&param_3->m32,
                     puVar20 + 0xc);
          param_4 = (Matrix4x4 *)(uint)*(ushort *)&param_3->m32;
          uVar17 = puVar20[0xc];
          if (*(ushort *)&param_3->m32 == 0) {
            puVar21 = (uint *)((int)param_3[1].m10 + uVar17 * 0x24);
            puVar20[0xf] = *puVar21;
            puVar20[0x10] = puVar21[1];
            puVar20[0x11] = puVar21[2];
          }
          else {
            pfVar12 = (float *)((int)param_3[1].m10 + uVar17 * 0x24);
            pfVar1 = (float *)((int)param_3[1].m10 + puVar20[0xd] * 0x24);
            if (param_4 == (Matrix4x4 *)0x1) {
              fVar3 = (float)puVar20[0xe];
              puVar20[0xf] = (uint)((*pfVar1 - *pfVar12) * fVar3 + *pfVar12);
              puVar20[0x10] = (uint)((pfVar1[1] - pfVar12[1]) * fVar3 + pfVar12[1]);
              puVar20[0x11] = (uint)((pfVar1[2] - pfVar12[2]) * fVar3 + pfVar12[2]);
            }
            else if (param_4 == (Matrix4x4 *)0x2) {
              fVar3 = (float)puVar20[0xe];
              fVar4 = fVar3 * fVar3;
              param_4 = (Matrix4x4 *)(fVar4 * fVar3);
              local_10 = (uint *)(_DAT_0080297c * fVar4);
              param_5 = (Matrix4x4 *)
                        ((((float)local_10 - (float)param_4) - fVar3 * _DAT_0080297c) +
                        StaticFloat1_0);
              local_8 = (AnimationData *)((float)param_4 * _DAT_0080297c);
              fVar3 = ((float)local_8 - fVar4 * _DAT_00802990) + fVar3 * _DAT_0080297c;
              fVar4 = (float)local_10 - (float)local_8;
              puVar20[0xf] = (uint)((float)param_5 * *pfVar12 +
                                   (float)param_4 * *pfVar1 + fVar4 * pfVar1[3] + fVar3 * pfVar12[6]
                                   );
              puVar20[0x10] =
                   (uint)((float)param_4 * pfVar1[1] +
                         (float)param_5 * pfVar12[1] + fVar3 * pfVar12[7] + fVar4 * pfVar1[4]);
              puVar20[0x11] =
                   (uint)((float)param_4 * pfVar1[2] +
                         (float)param_5 * pfVar12[2] + fVar3 * pfVar12[8] + fVar4 * pfVar1[5]);
            }
            else if (param_4 == (Matrix4x4 *)0x3) {
              fVar3 = (float)puVar20[0xe];
              fVar4 = fVar3 * fVar3;
              fVar5 = fVar4 * fVar3;
              local_8 = (AnimationData *)(fVar5 + fVar5);
              local_10 = (uint *)(fVar4 * _DAT_0080297c);
              param_5 = (Matrix4x4 *)(((float)local_8 - (float)local_10) + StaticFloat1_0);
              param_4 = (Matrix4x4 *)((fVar5 - (fVar4 + fVar4)) + fVar3);
              fVar5 = fVar5 - fVar4;
              fVar3 = (float)local_10 - (float)local_8;
              puVar20[0xf] = (uint)((float)param_5 * *pfVar12 +
                                   fVar5 * pfVar1[3] + (float)param_4 * pfVar12[6] + fVar3 * *pfVar1
                                   );
              puVar20[0x10] =
                   (uint)((float)param_5 * pfVar12[1] +
                         fVar3 * pfVar1[1] + (float)param_4 * pfVar12[7] + fVar5 * pfVar1[4]);
              puVar20[0x11] =
                   (uint)((float)param_5 * pfVar12[2] +
                         fVar3 * pfVar1[2] + (float)param_4 * pfVar12[8] + fVar5 * pfVar1[5]);
            }
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_2[4].m03) &&
               (*(short *)((int)&param_3->m32 + 2) == -1)) {
              findInterpolationIndices
                        (this,(uint)param_2[3].m01,(uint)param_2[3].m02,
                         (AnimationData *)&param_3->m32,puVar20 + 0x12);
              param_4 = (Matrix4x4 *)&param_3->m32;
              pfVar12 = (float *)((int)param_3[1].m10 + puVar20[0x12] * 0x24);
              pfVar1 = (float *)((int)param_3[1].m10 + puVar20[0x13] * 0x24);
              sVar8 = *(short *)param_4;
              if (sVar8 == 1) {
                fVar3 = (float)puVar20[0x14];
                puVar20[0x15] = (uint)((*pfVar1 - *pfVar12) * fVar3 + *pfVar12);
                puVar20[0x16] = (uint)((pfVar1[1] - pfVar12[1]) * fVar3 + pfVar12[1]);
                puVar20[0x17] = (uint)((pfVar1[2] - pfVar12[2]) * fVar3 + pfVar12[2]);
              }
              else if (sVar8 == 2) {
                fVar3 = (float)puVar20[0x14];
                fVar4 = fVar3 * fVar3;
                param_4 = (Matrix4x4 *)(fVar4 * fVar3);
                local_10 = (uint *)(_DAT_0080297c * fVar4);
                param_5 = (Matrix4x4 *)
                          ((((float)local_10 - (float)param_4) - fVar3 * _DAT_0080297c) +
                          StaticFloat1_0);
                local_8 = (AnimationData *)((float)param_4 * _DAT_0080297c);
                fVar3 = ((float)local_8 - fVar4 * _DAT_00802990) + fVar3 * _DAT_0080297c;
                fVar4 = (float)local_10 - (float)local_8;
                puVar20[0x15] =
                     (uint)((float)param_5 * *pfVar12 +
                           (float)param_4 * *pfVar1 + fVar3 * pfVar12[6] + fVar4 * pfVar1[3]);
                puVar20[0x16] =
                     (uint)((float)param_4 * pfVar1[1] +
                           (float)param_5 * pfVar12[1] + fVar3 * pfVar12[7] + fVar4 * pfVar1[4]);
                puVar20[0x17] =
                     (uint)((float)param_4 * pfVar1[2] +
                           (float)param_5 * pfVar12[2] + fVar3 * pfVar12[8] + fVar4 * pfVar1[5]);
              }
              else if (sVar8 == 3) {
                fVar3 = (float)puVar20[0x14];
                fVar4 = fVar3 * fVar3;
                fVar5 = fVar4 * fVar3;
                local_8 = (AnimationData *)(fVar5 + fVar5);
                local_10 = (uint *)(fVar4 * _DAT_0080297c);
                param_5 = (Matrix4x4 *)(((float)local_8 - (float)local_10) + StaticFloat1_0);
                param_4 = (Matrix4x4 *)((fVar5 - (fVar4 + fVar4)) + fVar3);
                fVar5 = fVar5 - fVar4;
                fVar3 = (float)local_10 - (float)local_8;
                puVar20[0x15] =
                     (uint)((float)param_4 * pfVar12[6] +
                           (float)param_5 * *pfVar12 + fVar3 * *pfVar1 + fVar5 * pfVar1[3]);
                puVar20[0x16] =
                     (uint)((float)param_5 * pfVar12[1] +
                           fVar3 * pfVar1[1] + (float)param_4 * pfVar12[7] + fVar5 * pfVar1[4]);
                puVar20[0x17] =
                     (uint)((float)param_5 * pfVar12[2] +
                           fVar3 * pfVar1[2] + (float)param_4 * pfVar12[8] + fVar5 * pfVar1[5]);
              }
              fVar3 = param_2[4].m03;
              puVar20[0xf] = (uint)(((float)puVar20[0x15] - (float)puVar20[0xf]) * fVar3 +
                                   (float)puVar20[0xf]);
              puVar20[0x10] =
                   (uint)(((float)puVar20[0x16] - (float)puVar20[0x10]) * fVar3 +
                         (float)puVar20[0x10]);
              puVar20[0x11] =
                   (uint)(((float)puVar20[0x17] - (float)puVar20[0x11]) * fVar3 +
                         (float)puVar20[0x11]);
            }
          }
        }
        pMVar23 = param_3;
        if (this->animation_frame_counter < (uint)param_3[1].m23) {
          puVar21 = puVar20 + 0x18;
          pfVar12 = &param_3[1].m20;
          param_5 = (Matrix4x4 *)this->unknown_0x80;
          findInterpolationIndices
                    (this,(uint)param_5[2].m12,(uint)param_5[2].m13,(AnimationData *)pfVar12,puVar21
                    );
          sVar8 = *(short *)pfVar12;
          if (sVar8 == 0) {
            puVar20[0x1b] = *(uint *)((int)pMVar23[1].m32 + *puVar21 * 0xc);
          }
          else {
            param_3 = (Matrix4x4 *)((int)pMVar23[1].m32 + *puVar21 * 0xc);
            pfVar1 = (float *)((int)pMVar23[1].m32 + puVar20[0x19] * 0xc);
            if (sVar8 == 1) {
              puVar20[0x1b] = (uint)((*pfVar1 - param_3->m00) * (float)puVar20[0x1a] + param_3->m00)
              ;
            }
            else if (sVar8 == 2) {
              fVar3 = (float)puVar20[0x1a];
              fVar4 = fVar3 * fVar3;
              fVar5 = fVar4 * fVar3;
              param_4 = (Matrix4x4 *)(fVar4 * _DAT_0080297c);
              puVar20[0x1b] =
                   (uint)(((((float)param_4 - fVar5) - fVar3 * _DAT_0080297c) + StaticFloat1_0) *
                          param_3->m00 +
                          ((float)param_4 - _DAT_0080297c * fVar5) * pfVar1[1] +
                          ((_DAT_0080297c * fVar5 - fVar4 * _DAT_00802990) + fVar3 * _DAT_0080297c)
                          * param_3->m02 + *pfVar1 * fVar5);
            }
            else if (sVar8 == 3) {
              fVar3 = (float)puVar20[0x1a];
              fVar4 = fVar3 * fVar3;
              fVar5 = fVar4 * fVar3;
              puVar20[0x1b] =
                   (uint)((fVar4 * _DAT_0080297c - (fVar5 + fVar5)) * *pfVar1 +
                         (((fVar5 + fVar5) - fVar4 * _DAT_0080297c) + StaticFloat1_0) * param_3->m00
                         + (fVar5 - fVar4) * pfVar1[1] +
                           ((fVar5 - (fVar4 + fVar4)) + fVar3) * param_3->m02);
            }
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_5[4].m03) &&
               (*(short *)((int)&pMVar23[1].m20 + 2) == -1)) {
              findInterpolationIndices
                        (this,(uint)param_5[3].m01,(uint)param_5[3].m02,(AnimationData *)pfVar12,
                         puVar20 + 0x1c);
              pfVar1 = (float *)((int)pMVar23[1].m32 + puVar20[0x1c] * 0xc);
              pfVar2 = (float *)((int)pMVar23[1].m32 + puVar20[0x1d] * 0xc);
              sVar8 = *(short *)pfVar12;
              if (sVar8 == 1) {
                puVar20[0x1f] = (uint)((*pfVar2 - *pfVar1) * (float)puVar20[0x1e] + *pfVar1);
              }
              else if (sVar8 == 2) {
                fVar3 = (float)puVar20[0x1e];
                fVar4 = fVar3 * fVar3;
                fVar5 = fVar4 * fVar3;
                param_3 = (Matrix4x4 *)(fVar4 * _DAT_0080297c);
                puVar20[0x1f] =
                     (uint)(((((float)param_3 - fVar5) - fVar3 * _DAT_0080297c) + StaticFloat1_0) *
                            *pfVar1 + ((float)param_3 - _DAT_0080297c * fVar5) * pfVar2[1] +
                                      ((_DAT_0080297c * fVar5 - fVar4 * _DAT_00802990) +
                                      fVar3 * _DAT_0080297c) * pfVar1[2] + *pfVar2 * fVar5);
              }
              else if (sVar8 == 3) {
                fVar3 = (float)puVar20[0x1e];
                fVar4 = fVar3 * fVar3;
                fVar5 = fVar4 * fVar3;
                puVar20[0x1f] =
                     (uint)((fVar4 * _DAT_0080297c - (fVar5 + fVar5)) * *pfVar2 +
                           (((fVar5 + fVar5) - fVar4 * _DAT_0080297c) + StaticFloat1_0) * *pfVar1 +
                           (fVar5 - fVar4) * pfVar2[1] +
                           ((fVar5 - (fVar4 + fVar4)) + fVar3) * pfVar1[2]);
              }
              puVar20[0x1b] =
                   (uint)(((float)puVar20[0x1f] - (float)puVar20[0x1b]) * param_5[4].m03 +
                         (float)puVar20[0x1b]);
            }
          }
        }
        local_c = (AnimationData *)((int)local_c + 1);
        local_24 = local_24 + 0x1f;
        local_20 = local_20 + 0x84;
      } while (local_c < *(uint *)(local_18 + 0x124));
    }
    local_1c = 0.0;
    if (*(int *)(local_18 + 0x134) != 0) {
      local_10 = (uint *)0x0;
      local_20 = 0;
      do {
        local_c = (AnimationData *)(*(int *)(local_18 + 0x138) + local_20);
        puVar20 = (uint *)(this->particle_data_array4 + (int)local_10);
        if (this->animation_frame_counter < *(uint *)((int)local_c + 0xcc)) {
          iVar11 = (uint)*(ushort *)((int)local_c + 4) * 0x118;
          iVar22 = iVar11 + this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)(iVar11 + 0x98 + this->unknown_0x80),*(uint *)(iVar22 + 0x9c),
                     (AnimationData *)((int)local_c + 0xc0),puVar20 + 0x2c);
          puVar14 = COLLISION_PLANE_ZERO_THRESHOLD;
          if (*(short *)((int)local_c + 0xc0) == 0) {
            *(undefined1 *)(puVar20 + 0x2f) =
                 *(undefined1 *)(*(int *)((int)local_c + 0xd8) + puVar20[0x2c]);
          }
          else {
            *(undefined1 *)(puVar20 + 0x2f) =
                 *(undefined1 *)(puVar20[0x2c] + *(int *)((int)local_c + 0xd8));
            if (((float)puVar14 != *(float *)(iVar22 + 0x10c)) &&
               (*(short *)((int)local_c + 0xc2) == -1)) {
              local_14 = (float *)(puVar20 + 0x30);
              findInterpolationIndices
                        (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                         (AnimationData *)((int)local_c + 0xc0),(uint *)local_14);
              *(undefined1 *)(puVar20 + 0x33) =
                   *(undefined1 *)((int)*local_14 + *(int *)((int)local_c + 0xd8));
            }
          }
        }
        if (this->animation_frame_counter < *(uint *)((int)local_c + 0x30)) {
          iVar11 = (uint)*(ushort *)((int)local_c + 4) * 0x118;
          iVar22 = iVar11 + this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)(iVar22 + 0x98),*(uint *)(iVar11 + 0x9c + this->unknown_0x80),
                     (AnimationData *)((int)local_c + 0x24),puVar20);
          if (*(short *)((int)local_c + 0x24) == 0) {
            puVar21 = (uint *)(*(int *)((int)local_c + 0x3c) + *puVar20 * 0xc);
            puVar20[3] = *puVar21;
            puVar20[4] = puVar21[1];
            puVar20[5] = puVar21[2];
          }
          else {
            fVar3 = (float)puVar20[2];
            iVar15 = *(int *)((int)local_c + 0x3c);
            iVar11 = iVar15 + puVar20[1] * 0xc;
            pfVar12 = (float *)(iVar15 + *puVar20 * 0xc);
            puVar20[3] = (uint)((*(float *)(iVar15 + puVar20[1] * 0xc) -
                                *(float *)(iVar15 + *puVar20 * 0xc)) * fVar3 + *pfVar12);
            puVar20[4] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
            puVar20[5] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(iVar22 + 0x10c)) &&
               (*(short *)((int)local_c + 0x26) == -1)) {
              findInterpolationIndices
                        (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                         (AnimationData *)((int)local_c + 0x24),puVar20 + 6);
              fVar3 = (float)puVar20[8];
              iVar15 = *(int *)((int)local_c + 0x3c);
              iVar11 = iVar15 + puVar20[7] * 0xc;
              pfVar12 = (float *)(iVar15 + puVar20[6] * 0xc);
              puVar20[9] = (uint)((*(float *)(iVar15 + puVar20[7] * 0xc) -
                                  *(float *)(iVar15 + puVar20[6] * 0xc)) * fVar3 + *pfVar12);
              puVar20[10] = (uint)((*(float *)(iVar11 + 4) - pfVar12[1]) * fVar3 + pfVar12[1]);
              puVar20[0xb] = (uint)((*(float *)(iVar11 + 8) - pfVar12[2]) * fVar3 + pfVar12[2]);
              fVar3 = *(float *)(iVar22 + 0x10c);
              puVar20[3] = (uint)(((float)puVar20[9] - (float)puVar20[3]) * fVar3 +
                                 (float)puVar20[3]);
              puVar20[4] = (uint)(((float)puVar20[10] - (float)puVar20[4]) * fVar3 +
                                 (float)puVar20[4]);
              puVar20[5] = (uint)(((float)puVar20[0xb] - (float)puVar20[5]) * fVar3 +
                                 (float)puVar20[5]);
            }
          }
        }
        if (this->animation_frame_counter < *(uint *)((int)local_c + 0x4c)) {
          local_8 = (AnimationData *)((int)local_c + 0x40);
          iVar11 = (uint)*(ushort *)((int)local_c + 4) * 0x118 + this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)(iVar11 + 0x98),*(uint *)(iVar11 + 0x9c),local_8,puVar20 + 0xc);
          if ((short)local_8->interpolationModeAndTimeIndex == 0) {
            local_14 = (float *)(int)*(short *)(local_8->keyframe_base_ptr + puVar20[0xc] * 2);
            puVar20[0xf] = (uint)((float)(int)local_14 * _DAT_00811610);
          }
          else {
            local_78 = (float)puVar20[0xe];
            local_24 = &local_8->_padding;
            puVar13 = (undefined2 *)getIndexOffset(local_24,puVar20[0xd]);
            setShortValue((void *)((int)&param_4 + 2),puVar13);
            puVar13 = (undefined2 *)getIndexOffset(local_24,puVar20[0xc]);
            setShortValue((void *)((int)&param_3 + 2),puVar13);
            local_14 = (float *)(int)param_4._2_2_;
            puVar20[0xf] = (uint)(((float)(int)local_14 * _DAT_00811610 -
                                  (float)(int)param_3._2_2_ * _DAT_00811610) * local_78 +
                                 (float)(int)param_3._2_2_ * _DAT_00811610);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(iVar11 + 0x10c)) &&
               (*(short *)((int)&local_8->interpolationModeAndTimeIndex + 2) == -1)) {
              local_14 = (float *)(puVar20 + 0x10);
              findInterpolationIndices
                        (this,*(uint *)(iVar11 + 0xc4),*(uint *)(iVar11 + 200),local_8,
                         (uint *)local_14);
              local_28 = (uint *)puVar20[0x12];
              puVar13 = (undefined2 *)getIndexOffset(local_24,puVar20[0x11]);
              setShortValue((void *)((int)&param_2 + 2),puVar13);
              puVar13 = (undefined2 *)getIndexOffset(local_24,(int)*local_14);
              setShortValue((void *)((int)&param_5 + 2),puVar13);
              local_14 = (float *)(int)param_2._2_2_;
              fVar3 = ((float)(int)local_14 * _DAT_00811610 -
                      (float)(int)param_5._2_2_ * _DAT_00811610) * (float)local_28 +
                      (float)(int)param_5._2_2_ * _DAT_00811610;
              puVar20[0x13] = (uint)fVar3;
              puVar20[0xf] = (uint)((fVar3 - (float)puVar20[0xf]) * *(float *)(iVar11 + 0x10c) +
                                   (float)puVar20[0xf]);
            }
          }
        }
        if (this->animation_frame_counter < *(uint *)((int)local_c + 0x68)) {
          iVar11 = (uint)*(ushort *)((int)local_c + 4) * 0x118;
          iVar22 = iVar11 + this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)(iVar22 + 0x98),*(uint *)(iVar11 + 0x9c + this->unknown_0x80),
                     (AnimationData *)((int)local_c + 0x5c),puVar20 + 0x14);
          if (*(short *)((int)local_c + 0x5c) == 0) {
            puVar20[0x17] = *(uint *)(*(int *)((int)local_c + 0x74) + puVar20[0x14] * 4);
          }
          else {
            fVar3 = *(float *)(*(int *)((int)local_c + 0x74) + puVar20[0x14] * 4);
            puVar20[0x17] =
                 (uint)((*(float *)(*(int *)((int)local_c + 0x74) + puVar20[0x15] * 4) - fVar3) *
                        (float)puVar20[0x16] + fVar3);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(iVar22 + 0x10c)) &&
               (*(short *)((int)local_c + 0x5e) == -1)) {
              local_14 = (float *)(puVar20 + 0x18);
              findInterpolationIndices
                        (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                         (AnimationData *)((int)local_c + 0x5c),(uint *)local_14);
              fVar3 = *(float *)(*(int *)((int)local_c + 0x74) + (int)*local_14 * 4);
              fVar3 = (*(float *)(*(int *)((int)local_c + 0x74) + puVar20[0x19] * 4) - fVar3) *
                      (float)puVar20[0x1a] + fVar3;
              puVar20[0x1b] = (uint)fVar3;
              puVar20[0x17] =
                   (uint)((fVar3 - (float)puVar20[0x17]) * *(float *)(iVar22 + 0x10c) +
                         (float)puVar20[0x17]);
            }
          }
        }
        if (this->animation_frame_counter < *(uint *)((int)local_c + 0x84)) {
          iVar11 = (uint)*(ushort *)((int)local_c + 4) * 0x118;
          iVar22 = iVar11 + this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)(iVar22 + 0x98),*(uint *)(iVar11 + 0x9c + this->unknown_0x80),
                     (AnimationData *)((int)local_c + 0x78),puVar20 + 0x1c);
          if (*(short *)((int)local_c + 0x78) == 0) {
            puVar20[0x1f] = *(uint *)(*(int *)((int)local_c + 0x90) + puVar20[0x1c] * 4);
          }
          else {
            fVar3 = *(float *)(*(int *)((int)local_c + 0x90) + puVar20[0x1c] * 4);
            puVar20[0x1f] =
                 (uint)((*(float *)(*(int *)((int)local_c + 0x90) + puVar20[0x1d] * 4) - fVar3) *
                        (float)puVar20[0x1e] + fVar3);
            if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(iVar22 + 0x10c)) &&
               (*(short *)((int)local_c + 0x7a) == -1)) {
              local_14 = (float *)(puVar20 + 0x20);
              findInterpolationIndices
                        (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),
                         (AnimationData *)((int)local_c + 0x78),(uint *)local_14);
              fVar3 = *(float *)(*(int *)((int)local_c + 0x90) + (int)*local_14 * 4);
              fVar3 = (*(float *)(*(int *)((int)local_c + 0x90) + puVar20[0x21] * 4) - fVar3) *
                      (float)puVar20[0x22] + fVar3;
              puVar20[0x23] = (uint)fVar3;
              puVar20[0x1f] =
                   (uint)((fVar3 - (float)puVar20[0x1f]) * *(float *)(iVar22 + 0x10c) +
                         (float)puVar20[0x1f]);
            }
          }
        }
        pAVar24 = local_c;
        if (this->animation_frame_counter < *(uint *)((int)local_c + 0xb0)) {
          iVar11 = (uint)*(ushort *)((int)local_c + 4) * 0x118;
          local_8 = (AnimationData *)(puVar20 + 0x24);
          animationData = (AnimationData *)((int)local_c + 0xa4);
          iVar22 = iVar11 + this->unknown_0x80;
          findInterpolationIndices
                    (this,*(uint *)(iVar22 + 0x98),*(uint *)(iVar11 + 0x9c + this->unknown_0x80),
                     animationData,(uint *)local_8);
          puVar14 = COLLISION_PLANE_ZERO_THRESHOLD;
          if ((short)animationData->interpolationModeAndTimeIndex == 0) {
            *(undefined2 *)&local_8->keyframe_count =
                 *(undefined2 *)
                  (*(int *)((int)pAVar24 + 0xbc) + local_8->interpolationModeAndTimeIndex * 2);
          }
          else {
            *(undefined2 *)&local_8->keyframe_count =
                 *(undefined2 *)
                  (*(int *)((int)pAVar24 + 0xbc) + local_8->interpolationModeAndTimeIndex * 2);
            if (((float)puVar14 != *(float *)(iVar22 + 0x10c)) &&
               (*(short *)((int)pAVar24 + 0xa6) == -1)) {
              findInterpolationIndices
                        (this,*(uint *)(iVar22 + 0xc4),*(uint *)(iVar22 + 200),animationData,
                         &local_8->timestamps_ptr);
              *(undefined2 *)&local_8->field_0x1c =
                   *(undefined2 *)(*(int *)((int)pAVar24 + 0xbc) + local_8->timestamps_ptr * 2);
            }
          }
        }
        local_1c = (float)((int)local_1c + 1);
        local_20 = local_20 + 0xdc;
        local_10 = (uint *)((int)local_10 + 0xd0);
      } while ((uint)local_1c < *(uint *)(local_18 + 0x134));
    }
    this->additional_remaining_data[0] = 0;
    param_4 = (Matrix4x4 *)0x0;
    if (*(int *)(local_18 + 0x13c) != 0) {
      param_2 = (Matrix4x4 *)0x0;
      param_5 = (Matrix4x4 *)0x0;
      do {
        pMVar23 = param_5;
        iVar11 = *(int *)(local_18 + 0x140);
        puVar20 = (uint *)((int)&param_2->m00 + this->particle_data_array6);
        local_14 = *(float **)(this->particle_data_array7 + (int)param_4 * 4);
        if (this->animation_frame_counter < *(uint *)((int)&param_5[7].m22 + iVar11)) {
          param_3 = (Matrix4x4 *)
                    ((uint)*(ushort *)((int)&param_5->m11 + iVar11) * 0x118 + this->unknown_0x80);
          findInterpolationIndices
                    (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                     (AnimationData *)((int)&param_5[7].m13 + iVar11),puVar20 + 0x50);
          puVar14 = COLLISION_PLANE_ZERO_THRESHOLD;
          if (*(short *)((int)&pMVar23[7].m13 + iVar11) == 0) {
            *(undefined1 *)(puVar20 + 0x53) =
                 *(undefined1 *)(*(int *)((int)&pMVar23[7].m31 + iVar11) + puVar20[0x50]);
          }
          else {
            *(undefined1 *)(puVar20 + 0x53) =
                 *(undefined1 *)(puVar20[0x50] + *(int *)((int)&pMVar23[7].m31 + iVar11));
            if (((float)puVar14 != param_3[4].m03) &&
               (*(short *)((int)&pMVar23[7].m13 + iVar11 + 2) == -1)) {
              local_28 = puVar20 + 0x54;
              findInterpolationIndices
                        (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                         (AnimationData *)((int)&pMVar23[7].m13 + iVar11),local_28);
              *(undefined1 *)(puVar20 + 0x57) =
                   *(undefined1 *)(*(int *)((int)&pMVar23[7].m31 + iVar11) + *local_28);
            }
          }
        }
        if (((char)puVar20[0x53] == '\0') || (this->emitter_enable_flag == 0)) {
          uVar17 = 0;
        }
        else {
          uVar17 = 1;
        }
        puVar20[0x58] = uVar17;
        if ((uVar17 != 0) ||
           (puVar14 = IsParticleBufferEmpty((int)local_14), puVar14 != (undefined *)0x0)) {
          puVar14 = (undefined *)0x1;
        }
        puVar20[0x59] = (uint)puVar14;
        this->additional_remaining_data[0] = this->additional_remaining_data[0] | (uint)puVar14;
        if (((char)puVar20[0x53] != '\0') || (this->animation_frame_counter == 0)) {
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[1].m00 + iVar11)) {
            param_3 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 + this->unknown_0x80);
            findInterpolationIndices
                      (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                       (AnimationData *)((int)&pMVar23->m31 + iVar11),puVar20);
            if (*(short *)((int)&pMVar23->m31 + iVar11) == 0) {
              puVar20[3] = *(uint *)(*(int *)((int)&pMVar23[1].m03 + iVar11) + *puVar20 * 4);
            }
            else {
              iVar22 = *(int *)((int)&pMVar23[1].m03 + iVar11);
              fVar3 = *(float *)(iVar22 + *puVar20 * 4);
              puVar20[3] = (uint)((*(float *)(iVar22 + puVar20[1] * 4) - fVar3) * (float)puVar20[2]
                                 + fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_3[4].m03) &&
                 (*(short *)((int)&pMVar23->m31 + iVar11 + 2) == -1)) {
                findInterpolationIndices
                          (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                           (AnimationData *)((int)&pMVar23->m31 + iVar11),puVar20 + 4);
                iVar22 = *(int *)((int)&pMVar23[1].m03 + iVar11);
                fVar3 = *(float *)(iVar22 + puVar20[4] * 4);
                fVar3 = (*(float *)(iVar22 + puVar20[5] * 4) - fVar3) * (float)puVar20[6] + fVar3;
                puVar20[7] = (uint)fVar3;
                puVar20[3] = (uint)((fVar3 - (float)puVar20[3]) * param_3[4].m03 + (float)puVar20[3]
                                   );
              }
            }
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[1].m13 + iVar11)) {
            param_3 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 + this->unknown_0x80);
            findInterpolationIndices
                      (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                       (AnimationData *)((int)&pMVar23[1].m10 + iVar11),puVar20 + 8);
            if (*(short *)((int)&pMVar23[1].m10 + iVar11) == 0) {
              puVar20[0xb] = *(uint *)(*(int *)((int)&pMVar23[1].m22 + iVar11) + puVar20[8] * 4);
            }
            else {
              iVar22 = *(int *)((int)&pMVar23[1].m22 + iVar11);
              fVar3 = *(float *)(iVar22 + puVar20[8] * 4);
              puVar20[0xb] = (uint)((*(float *)(iVar22 + puVar20[9] * 4) - fVar3) *
                                    (float)puVar20[10] + fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_3[4].m03) &&
                 (*(short *)((int)&pMVar23[1].m10 + iVar11 + 2) == -1)) {
                local_28 = puVar20 + 0xc;
                findInterpolationIndices
                          (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                           (AnimationData *)((int)&pMVar23[1].m10 + iVar11),local_28);
                iVar22 = *(int *)((int)&pMVar23[1].m22 + iVar11);
                fVar3 = *(float *)(iVar22 + *local_28 * 4);
                fVar3 = (*(float *)(iVar22 + puVar20[0xd] * 4) - fVar3) * (float)puVar20[0xe] +
                        fVar3;
                puVar20[0xf] = (uint)fVar3;
                puVar20[0xb] = (uint)((fVar3 - (float)puVar20[0xb]) * param_3[4].m03 +
                                     (float)puVar20[0xb]);
              }
            }
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[1].m32 + iVar11)) {
            param_3 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 + this->unknown_0x80);
            findInterpolationIndices
                      (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                       (AnimationData *)((int)&pMVar23[1].m23 + iVar11),puVar20 + 0x10);
            if (*(short *)((int)&pMVar23[1].m23 + iVar11) == 0) {
              puVar20[0x13] = *(uint *)(*(int *)((int)&pMVar23[2].m01 + iVar11) + puVar20[0x10] * 4)
              ;
            }
            else {
              iVar22 = *(int *)((int)&pMVar23[2].m01 + iVar11);
              fVar3 = *(float *)(iVar22 + puVar20[0x10] * 4);
              puVar20[0x13] =
                   (uint)((*(float *)(iVar22 + puVar20[0x11] * 4) - fVar3) * (float)puVar20[0x12] +
                         fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_3[4].m03) &&
                 (*(short *)((int)&pMVar23[1].m23 + iVar11 + 2) == -1)) {
                local_28 = puVar20 + 0x14;
                findInterpolationIndices
                          (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                           (AnimationData *)((int)&pMVar23[1].m23 + iVar11),local_28);
                iVar22 = *(int *)((int)&pMVar23[2].m01 + iVar11);
                fVar3 = *(float *)(iVar22 + *local_28 * 4);
                fVar3 = (*(float *)(iVar22 + puVar20[0x15] * 4) - fVar3) * (float)puVar20[0x16] +
                        fVar3;
                puVar20[0x17] = (uint)fVar3;
                puVar20[0x13] =
                     (uint)((fVar3 - (float)puVar20[0x13]) * param_3[4].m03 + (float)puVar20[0x13]);
              }
            }
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[2].m11 + iVar11)) {
            param_3 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 + this->unknown_0x80);
            findInterpolationIndices
                      (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                       (AnimationData *)((int)&pMVar23[2].m02 + iVar11),puVar20 + 0x18);
            if (*(short *)((int)&pMVar23[2].m02 + iVar11) == 0) {
              puVar20[0x1b] = *(uint *)(*(int *)((int)&pMVar23[2].m20 + iVar11) + puVar20[0x18] * 4)
              ;
            }
            else {
              iVar22 = *(int *)((int)&pMVar23[2].m20 + iVar11);
              fVar3 = *(float *)(iVar22 + puVar20[0x18] * 4);
              puVar20[0x1b] =
                   (uint)((*(float *)(iVar22 + puVar20[0x19] * 4) - fVar3) * (float)puVar20[0x1a] +
                         fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_3[4].m03) &&
                 (*(short *)((int)&pMVar23[2].m02 + iVar11 + 2) == -1)) {
                local_28 = puVar20 + 0x1c;
                findInterpolationIndices
                          (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                           (AnimationData *)((int)&pMVar23[2].m02 + iVar11),local_28);
                iVar22 = *(int *)((int)&pMVar23[2].m20 + iVar11);
                fVar3 = *(float *)(iVar22 + *local_28 * 4);
                fVar3 = (*(float *)(iVar22 + puVar20[0x1d] * 4) - fVar3) * (float)puVar20[0x1e] +
                        fVar3;
                puVar20[0x1f] = (uint)fVar3;
                puVar20[0x1b] =
                     (uint)((fVar3 - (float)puVar20[0x1b]) * param_3[4].m03 + (float)puVar20[0x1b]);
              }
            }
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[2].m30 + iVar11)) {
            param_3 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 + this->unknown_0x80);
            findInterpolationIndices
                      (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                       (AnimationData *)((int)&pMVar23[2].m21 + iVar11),puVar20 + 0x20);
            if (*(short *)((int)&pMVar23[2].m21 + iVar11) == 0) {
              puVar20[0x23] = *(uint *)(*(int *)((int)&pMVar23[2].m33 + iVar11) + puVar20[0x20] * 4)
              ;
            }
            else {
              iVar22 = *(int *)((int)&pMVar23[2].m33 + iVar11);
              fVar3 = *(float *)(iVar22 + puVar20[0x20] * 4);
              puVar20[0x23] =
                   (uint)((*(float *)(iVar22 + puVar20[0x21] * 4) - fVar3) * (float)puVar20[0x22] +
                         fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_3[4].m03) &&
                 (*(short *)((int)&pMVar23[2].m21 + iVar11 + 2) == -1)) {
                local_28 = puVar20 + 0x24;
                findInterpolationIndices
                          (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                           (AnimationData *)((int)&pMVar23[2].m21 + iVar11),local_28);
                iVar22 = *(int *)((int)&pMVar23[2].m33 + iVar11);
                fVar3 = *(float *)(iVar22 + *local_28 * 4);
                fVar3 = (*(float *)(iVar22 + puVar20[0x25] * 4) - fVar3) * (float)puVar20[0x26] +
                        fVar3;
                puVar20[0x27] = (uint)fVar3;
                puVar20[0x23] =
                     (uint)((fVar3 - (float)puVar20[0x23]) * param_3[4].m03 + (float)puVar20[0x23]);
              }
            }
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[3].m03 + iVar11)) {
            param_3 = (Matrix4x4 *)
                      ((uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 + this->unknown_0x80);
            findInterpolationIndices
                      (this,(uint)param_3[2].m12,(uint)param_3[2].m13,
                       (AnimationData *)((int)&pMVar23[3].m00 + iVar11),puVar20 + 0x28);
            if (*(short *)((int)&pMVar23[3].m00 + iVar11) == 0) {
              puVar20[0x2b] = *(uint *)(*(int *)((int)&pMVar23[3].m12 + iVar11) + puVar20[0x28] * 4)
              ;
            }
            else {
              iVar22 = *(int *)((int)&pMVar23[3].m12 + iVar11);
              fVar3 = *(float *)(iVar22 + puVar20[0x28] * 4);
              puVar20[0x2b] =
                   (uint)((*(float *)(iVar22 + puVar20[0x29] * 4) - fVar3) * (float)puVar20[0x2a] +
                         fVar3);
              if (((float)COLLISION_PLANE_ZERO_THRESHOLD != param_3[4].m03) &&
                 (*(short *)((int)&pMVar23[3].m00 + iVar11 + 2) == -1)) {
                local_28 = puVar20 + 0x2c;
                findInterpolationIndices
                          (this,(uint)param_3[3].m01,(uint)param_3[3].m02,
                           (AnimationData *)((int)&pMVar23[3].m00 + iVar11),local_28);
                iVar22 = *(int *)((int)&pMVar23[3].m12 + iVar11);
                fVar3 = *(float *)(iVar22 + *local_28 * 4);
                fVar3 = (*(float *)(iVar22 + puVar20[0x2d] * 4) - fVar3) * (float)puVar20[0x2e] +
                        fVar3;
                puVar20[0x2f] = (uint)fVar3;
                puVar20[0x2b] =
                     (uint)((fVar3 - (float)puVar20[0x2b]) * param_3[4].m03 + (float)puVar20[0x2b]);
              }
            }
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[3].m22 + iVar11)) {
            getInterpolatedFloat
                      (this,(uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 +
                            this->unknown_0x80,(short *)((int)&pMVar23[3].m13 + iVar11),
                       puVar20 + 0x30);
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[4].m01 + iVar11)) {
            getInterpolatedFloat
                      (this,(uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 +
                            this->unknown_0x80,(short *)((int)&pMVar23[3].m32 + iVar11),
                       puVar20 + 0x38);
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[4].m20 + iVar11)) {
            getInterpolatedFloat
                      (this,(uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 +
                            this->unknown_0x80,(short *)((int)&pMVar23[4].m11 + iVar11),
                       puVar20 + 0x40);
          }
          if (this->animation_frame_counter < *(uint *)((int)&pMVar23[4].m33 + iVar11)) {
            getInterpolatedFloat
                      (this,(uint)*(ushort *)((int)&pMVar23->m11 + iVar11) * 0x118 +
                            this->unknown_0x80,(short *)((int)&pMVar23[4].m30 + iVar11),
                       puVar20 + 0x48);
          }
        }
        param_2 = (Matrix4x4 *)&param_2[5].m23;
        param_4 = (Matrix4x4 *)((int)&param_4->m00 + 1);
        param_5 = (Matrix4x4 *)&param_5[7].m32;
      } while (param_4 < *(Matrix4x4 **)(local_18 + 0x13c));
    }
    iVar11 = 0;
    if (this->final_world_pos_z != 0.0) {
      uVar17 = 0;
      if (*(int *)(local_18 + 0x104) != 0) {
        param_3 = (Matrix4x4 *)0x0;
        iVar22 = local_18;
        do {
          iVar15 = *(int *)(iVar22 + 0x108) + iVar11;
          if (this->animation_frame_counter < *(uint *)(*(int *)(iVar22 + 0x108) + 0x20 + iVar11)) {
            extractAnimationByteFromKeyframes
                      (this,(AnimationState *)
                            ((uint)*(ushort *)(iVar15 + 4) * 0x118 + this->unknown_0x80),
                       (AnimationData *)(iVar15 + 0x14),
                       (InterpolationOutputBuffer *)
                       ((int)&param_3->m00 + (int)this->final_world_pos_z));
            iVar22 = local_18;
          }
          uVar17 = uVar17 + 1;
          param_3 = (Matrix4x4 *)&param_3->m20;
          iVar11 = iVar11 + 0x30;
        } while (uVar17 < *(uint *)(iVar22 + 0x104));
      }
      for (param_3 = (Matrix4x4 *)this->hierarchy_index;
          (SceneObject *)param_3 != (SceneObject *)0x0;
          param_3 = (Matrix4x4 *)((SceneObject *)param_3)->field_0x190) {
        fVar3 = ((SceneObject *)param_3)->field_0x184;
        if ((fVar3 != 9.18341e-41) &&
           (*(char *)((int)fVar3 * 0x20 + 0xc + (int)this->final_world_pos_z) != '\0')) {
          iVar11 = (int)fVar3 * 0x30 + *(int *)(local_18 + 0x108);
          pfVar12 = (float *)((uint)*(ushort *)(iVar11 + 4) * 0x40 + (int)this->transform_vec2_x);
          pMVar23 = &local_1a0;
          for (iVar22 = 0x10; iVar22 != 0; iVar22 = iVar22 + -1) {
            pMVar23->m00 = *pfVar12;
            pfVar12 = pfVar12 + 1;
            pMVar23 = (Matrix4x4 *)&pMVar23->m01;
          }
          local_1a0.m30 =
               local_1a0.m00 * *(float *)(iVar11 + 8) +
               local_1a0.m10 * *(float *)(iVar11 + 0xc) + local_1a0.m20 * *(float *)(iVar11 + 0x10)
               + local_1a0.m30;
          local_1a0.m31 =
               local_1a0.m01 * *(float *)(iVar11 + 8) +
               local_1a0.m11 * *(float *)(iVar11 + 0xc) + local_1a0.m21 * *(float *)(iVar11 + 0x10)
               + local_1a0.m31;
          local_1a0.m32 =
               local_1a0.m02 * *(float *)(iVar11 + 8) +
               local_1a0.m12 * *(float *)(iVar11 + 0xc) + local_1a0.m22 * *(float *)(iVar11 + 0x10)
               + local_1a0.m32;
          transformMatrix4x4((SceneObject *)param_3,&local_1a0,(Matrix4x4 *)&this->world_position_x,
                             (Matrix4x4 *)&this->render_priority,(Matrix4x4 *)this->render_scale_z);
        }
      }
    }
    this->transform_sync_value = *(int *)((int)this->animation_context_ptr + 0x10);
  }
  return;
}

