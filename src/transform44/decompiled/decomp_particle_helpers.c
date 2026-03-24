// ============================================================
// calculateColorValues @ 0x7B9B10
// ============================================================

/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

void __thiscall
calculateParticleColorAndScale
          (OrientationData *this,float particleTime,float colorDeltaG,byte *colorValueOut,
          uint *colorData1Out,uint *colorData2Out,float *spriteScaleOut)

{
  byte alphaChannelValue;
  float10 extendedPrecisionTime;
  undefined *tempVar;
  float timeScaledFactor;
  undefined *puVar1;
  
                    /* Calculates particle color values, texture coordinates, and scale based on
                       particle time and orientation data. Uses time-scaled interpolation between
                       base values and deltas. Handles both standard float and extended precision
                       calculations. */
                    /* Calculate normalized time factor: (current_time - base_time) * time_scale *
                       0.99 + 0.005 */
  timeScaledFactor =
       (particleTime - this->timeBase) * this->timeScale * _DAT_00808aac + _DAT_00807a3c;
                    /* Alpha channel: ((color_delta_alpha * time_factor + base_alpha) *
                       color_delta_g + 512) >> 14 */
  colorValueOut[3] =
       (byte)((uint)(((float)this->colorDelta_R * timeScaledFactor + (float)this->colorBase_A) *
                     colorDeltaG + _DAT_008029cc) >> 0xe);
                    /* Blue channel: (color_delta_blue * time_factor + base_blue + 512) >> 14 */
                    /* Green channel: (color_delta_green * time_factor + base_green + 512) >> 14 */
  colorValueOut[2] =
       (byte)((uint)((float)this->colorDelta_G * timeScaledFactor + (float)this->colorBase_B +
                    _DAT_008029cc) >> 0xe);
                    /* Red channel: (color_delta_red * time_factor + base_red + 512) >> 14 */
  colorValueOut[1] =
       (byte)((uint)((float)this->colorDelta_B * timeScaledFactor + (float)this->colorBase_G +
                    _DAT_008029cc) >> 0xe);
  puVar1 = (undefined *)
           ((uint)((float)this->colorDelta_A * timeScaledFactor + (float)this->colorBase_R +
                  _DAT_008029cc) >> 0xe);
  *colorValueOut = (byte)puVar1;
  *spriteScaleOut = timeScaledFactor * this->scaleDelta + this->scaleBase;
  if (*(int *)&this->field_0x50 == 0x3f800000) {
    *colorData1Out =
         (uint)((float)this->texData1_Delta * timeScaledFactor + (float)this->texData1_Base +
               _DAT_008029cc) >> 0xe & 0xff;
    colorData1Out =
         (uint *)((float)this->texData2_Delta * timeScaledFactor + (float)this->texData2_Base +
                 _DAT_008029cc);
  }
  else {
    extendedPrecisionTime = (float10)callIntrinsicDispatcher(puVar1);
    *colorData1Out =
         (uint)(float)((float10)this->texData1_Delta * extendedPrecisionTime +
                       (float10)this->texData1_Base + (float10)_DAT_008029cc) >> 0xe & 0xff;
    colorData1Out =
         (uint *)(float)((float10)this->texData2_Delta * extendedPrecisionTime +
                         (float10)this->texData2_Base + (float10)_DAT_008029cc);
  }
  *colorData2Out = (uint)colorData1Out >> 0xe & 0xff;
  return;
}


// ============================================================
// matVec3Transform @ 0x7BCA80
// ============================================================

void __fastcall transformVector3ByMatrix4x4(float *param_1,float *param_2,float *param_3)

{
  float fVar1;
  float fVar2;
  float fVar3;
  float fVar4;
  float fVar5;
  float fVar6;
  float fVar7;
  float fVar8;
  float fVar9;
  float fVar10;
  float fVar11;
  float fVar12;
  float fVar13;
  float fVar14;
  
  fVar1 = param_3[10];
  fVar2 = param_2[2];
  fVar3 = param_3[2];
  fVar4 = *param_2;
  fVar5 = param_3[6];
  fVar6 = param_2[1];
  fVar7 = param_3[0xe];
  fVar8 = param_3[9];
  fVar9 = param_2[2];
  fVar10 = param_3[1];
  fVar11 = *param_2;
  fVar12 = param_3[5];
  fVar13 = param_2[1];
  fVar14 = param_3[0xd];
  *param_1 = *param_2 * *param_3 + param_3[4] * param_2[1] + param_3[8] * param_2[2] + param_3[0xc];
  param_1[1] = fVar12 * fVar13 + fVar10 * fVar11 + fVar8 * fVar9 + fVar14;
  param_1[2] = fVar5 * fVar6 + fVar3 * fVar4 + fVar1 * fVar2 + fVar7;
  return;
}


// ============================================================
// buildRotationFromAngle @ 0x7BE490
// ============================================================

float * __fastcall
createAxisAngleRotationMatrix3x3(float *param_1,float *param_2,float param_3,char param_4)

{
  float fVar1;
  float fVar2;
  float10 fVar3;
  float fVar4;
  float fVar5;
  float fVar6;
  float10 fVar7;
  undefined *local_1c;
  undefined *local_18;
  undefined *local_14;
  undefined *local_10;
  undefined *local_c;
  undefined *local_8;
  
  local_1c = (undefined *)*param_2;
  local_18 = (undefined *)param_2[1];
  local_14 = (undefined *)param_2[2];
  if (param_4 == '\0') {
    fVar1 = StaticFloat1_0 /
            SQRT((float)local_1c * (float)local_1c +
                 (float)local_18 * (float)local_18 + (float)local_14 * (float)local_14);
    local_1c = (undefined *)((float)local_1c * fVar1);
    local_18 = (undefined *)((float)local_18 * fVar1);
    local_14 = (undefined *)(fVar1 * (float)local_14);
  }
  fVar3 = (float10)fcos((float10)param_3);
  fVar7 = (float10)fsin((float10)param_3);
  fVar1 = (float)fVar3;
  fVar2 = (float)fVar7;
  fVar6 = StaticFloat1_0 - fVar1;
  *param_1 = (float)local_1c * (float)local_1c * fVar6 + fVar1;
  fVar4 = fVar6 * (float)local_18 * (float)local_1c;
  param_1[1] = fVar4 + (float)local_14 * fVar2;
  fVar5 = fVar6 * (float)local_14 * (float)local_1c;
  param_1[2] = fVar5 - (float)local_18 * fVar2;
  param_1[3] = fVar4 - (float)local_14 * fVar2;
  param_1[4] = (float)local_18 * (float)local_18 * fVar6 + fVar1;
  fVar4 = fVar6 * (float)local_14 * (float)local_18;
  param_1[5] = (float)local_1c * fVar2 + fVar4;
  param_1[6] = fVar5 + (float)local_18 * fVar2;
  param_1[7] = fVar4 - (float)local_1c * fVar2;
  param_1[8] = (float)local_14 * (float)local_14 * fVar6 + fVar1;
  return param_1;
}


// ============================================================
// matVec3Transform2 @ 0x7BCB40
// ============================================================

void __fastcall transformVector4ByMatrix4x4(float *param_1,float *param_2,float *param_3)

{
  float fVar1;
  float fVar2;
  float fVar3;
  float fVar4;
  float fVar5;
  float fVar6;
  float fVar7;
  float fVar8;
  float fVar9;
  float fVar10;
  float fVar11;
  float fVar12;
  float fVar13;
  float fVar14;
  float fVar15;
  float fVar16;
  float fVar17;
  float fVar18;
  float fVar19;
  float fVar20;
  float fVar21;
  float fVar22;
  float fVar23;
  float fVar24;
  
  fVar1 = param_3[0xf];
  fVar2 = param_2[3];
  fVar3 = param_3[3];
  fVar4 = *param_2;
  fVar5 = param_3[0xb];
  fVar6 = param_2[2];
  fVar7 = param_3[7];
  fVar8 = param_2[1];
  fVar9 = param_3[0xe];
  fVar10 = param_2[3];
  fVar11 = param_3[2];
  fVar12 = *param_2;
  fVar13 = param_3[10];
  fVar14 = param_2[2];
  fVar15 = param_3[6];
  fVar16 = param_2[1];
  fVar17 = param_3[0xd];
  fVar18 = param_2[3];
  fVar19 = param_3[1];
  fVar20 = *param_2;
  fVar21 = param_3[9];
  fVar22 = param_2[2];
  fVar23 = param_3[5];
  fVar24 = param_2[1];
  *param_1 = *param_2 * *param_3 +
             param_3[4] * param_2[1] + param_3[8] * param_2[2] + param_3[0xc] * param_2[3];
  param_1[1] = fVar23 * fVar24 + fVar21 * fVar22 + fVar19 * fVar20 + fVar17 * fVar18;
  param_1[2] = fVar15 * fVar16 + fVar13 * fVar14 + fVar11 * fVar12 + fVar9 * fVar10;
  param_1[3] = fVar7 * fVar8 + fVar5 * fVar6 + fVar3 * fVar4 + fVar1 * fVar2;
  return;
}


// ============================================================
// setupRenderState @ 0x58A230
// ============================================================

void UpdateLightingOffset(void)

{
  GetLightingOffset((int)CGxDeviceD3d__device);
  return;
}


