
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */
/* Setting prototype: void __thiscall SetupParticleRendering(ParticleSystemRenderer *this, float10
   *param_1) */

void __thiscall SetupParticleRendering(ParticleSystemRenderer *this,float10 *viewMatrix)

{
  float *pfVar1;
  uint uVar2;
  Matrix4x4 *pMVar3;
  Matrix4x4 *pMVar4;
  uint uVar5;
  uint uVar6;
  char *pcVar7;
  undefined *puVar8;
  undefined *puVar9;
  undefined *puVar10;
  float fVar11;
  undefined **ppuVar12;
  int iVar13;
  int iVar14;
  undefined **ppuVar15;
  float10 fVar16;
  Matrix4x4 tempMatrix1;
  undefined *local_fc;
  undefined *local_f8;
  undefined *local_f4;
  undefined *local_f0;
  undefined *local_ec;
  undefined *local_e8;
  undefined *local_e4;
  undefined *local_e0;
  undefined *local_dc;
  Matrix4x4 vertexShaderMatrix;
  Matrix4x4 translationMatrix;
  Matrix4x4 identityMatrix;
  undefined *local_18;
  undefined *local_14;
  undefined *local_10;
  undefined *local_c;
  undefined *local_8;
  
  vertexShaderMatrix.m00 = 1.0;
  vertexShaderMatrix.m01 = 0.0;
  vertexShaderMatrix.m02 = 0.0;
  vertexShaderMatrix.m03 = 0.0;
  vertexShaderMatrix.m10 = 0.0;
  vertexShaderMatrix.m11 = 1.0;
  vertexShaderMatrix.m12 = 0.0;
  vertexShaderMatrix.m13 = 0.0;
  vertexShaderMatrix.m20 = 0.0;
  vertexShaderMatrix.m21 = 0.0;
  vertexShaderMatrix.m22 = 1.0;
  vertexShaderMatrix.m23 = 0.0;
  vertexShaderMatrix.m30 = 0.0;
  vertexShaderMatrix.m31 = 0.0;
  vertexShaderMatrix.m32 = 0.0;
  vertexShaderMatrix.m33 = 1.0;
  identityMatrix.m00 = 1.0;
  identityMatrix.m01 = 0.0;
  identityMatrix.m02 = 0.0;
  identityMatrix.m03 = 0.0;
  identityMatrix.m10 = 0.0;
  identityMatrix.m11 = 1.0;
  identityMatrix.m12 = 0.0;
  identityMatrix.m13 = 0.0;
  identityMatrix.m20 = 0.0;
  identityMatrix.m21 = 0.0;
  identityMatrix.m22 = 1.0;
  identityMatrix.m23 = 0.0;
  identityMatrix.m30 = 0.0;
  identityMatrix.m31 = 0.0;
  identityMatrix.m32 = 0.0;
  identityMatrix.m33 = 1.0;
  SetTransformMatrix((undefined **)&identityMatrix);
  SetVertexShader((undefined *)&vertexShaderMatrix);
  translationMatrix.m30 = -this->colorPaletteArray[3].colorDeltaB_actual;
  translationMatrix.m31 = -*(float *)&this->colorPaletteArray[3].colorDeltaB_prefix;
  uVar5._0_2_ = this->colorPaletteArray[2].padding_06;
  uVar5._2_2_ = this->colorPaletteArray[2].texCoordDelta2_prefix;
  translationMatrix.m32 = -*(float *)((int)&this->colorPaletteArray[3].colorDeltaB + 2);
  translationMatrix.m00 = 1.0;
  translationMatrix.m01 = 0.0;
  translationMatrix.m02 = 0.0;
  translationMatrix.m03 = 0.0;
  translationMatrix.m10 = 0.0;
  translationMatrix.m11 = 1.0;
  translationMatrix.m12 = 0.0;
  translationMatrix.m13 = 0.0;
  translationMatrix.m20 = 0.0;
  translationMatrix.m21 = 0.0;
  translationMatrix.m22 = 1.0;
  translationMatrix.m23 = 0.0;
  translationMatrix.m33 = 1.0;
  local_10 = (undefined *)translationMatrix.m30;
  local_c = (undefined *)translationMatrix.m31;
  local_8 = (undefined *)translationMatrix.m32;
  if ((uVar5 & 0x100) == 0) {
    if (viewMatrix == (float10 *)0x0) {
      pMVar4 = multiplyMatrix4x4_SSE_Optimized(&tempMatrix1,&translationMatrix,&identityMatrix);
      ppuVar12 = &g_worldMatrix;
      iVar13 = 8;
      do {
        *ppuVar12 = (undefined *)pMVar4->m00;
        ppuVar12[1] = (undefined *)pMVar4->m01;
        ppuVar12 = ppuVar12 + 2;
        pMVar4 = (Matrix4x4 *)&pMVar4->m02;
        iVar13 = iVar13 + -1;
      } while (iVar13 != 0);
    }
    else {
      pMVar4 = &identityMatrix;
      pMVar3 = multiplyMatrix4x4_SSE_Optimized
                         (&tempMatrix1,(Matrix4x4 *)viewMatrix,&translationMatrix);
      pMVar4 = multiplyMatrix4x4_SSE_Optimized((Matrix4x4 *)&stack0xfffffee8,pMVar3,pMVar4);
      ppuVar12 = &g_worldMatrix;
      iVar13 = 8;
      do {
        *ppuVar12 = (undefined *)pMVar4->m00;
        ppuVar12[1] = (undefined *)pMVar4->m01;
        ppuVar12 = ppuVar12 + 2;
        pMVar4 = (Matrix4x4 *)&pMVar4->m02;
        iVar13 = iVar13 + -1;
      } while (iVar13 != 0);
    }
  }
  else {
    pMVar4 = &identityMatrix;
    pMVar3 = multiplyMatrix4x4_SSE_Optimized
                       ((Matrix4x4 *)&stack0xfffffee8,
                        (Matrix4x4 *)(this->colorPaletteArray[2].final_padding + 6),
                        &translationMatrix);
    pMVar4 = multiplyMatrix4x4_SSE_Optimized(&tempMatrix1,pMVar3,pMVar4);
    ppuVar12 = &g_worldMatrix;
    iVar13 = 8;
    do {
      *ppuVar12 = (undefined *)pMVar4->m00;
      ppuVar12[1] = (undefined *)pMVar4->m01;
      ppuVar12 = ppuVar12 + 2;
      pMVar4 = (Matrix4x4 *)&pMVar4->m02;
      iVar13 = iVar13 + -1;
    } while (iVar13 != 0);
  }
  g_lightDirectionX = (undefined *)identityMatrix.m20;
  g_lightDirectionY = (undefined *)identityMatrix.m21;
  g_lightDirectionZ = (undefined *)identityMatrix.m22;
  uVar6._0_2_ = this->colorPaletteArray[2].padding_06;
  uVar6._2_2_ = this->colorPaletteArray[2].texCoordDelta2_prefix;
  if ((uVar6 & 0x2000) != 0) {
    if ((g_renderingInitFlags & 1) == 0) {
      g_renderingInitFlags = g_renderingInitFlags | 1;
      g_spriteVertexTemplate = (undefined *)0xbf800000;
      g_spriteVertex1_X = (undefined *)0x3f800000;
      g_spriteVertex1_Y = (undefined *)0x0;
      g_spriteVertex2_X = (undefined *)0xbf800000;
      g_spriteVertex2_Y = (undefined *)0xbf800000;
      g_spriteVertex2_Z = (undefined *)0x0;
      _g_spriteVertex3_X = 0x3f800000;
      _g_spriteVertex3_Y = 0x3f800000;
      _g_spriteVertex3_Z = 0;
      _g_spriteVertex4_X = 0x3f800000;
      _g_spriteVertex4_Y = 0xbf800000;
      _g_spriteVertex4_Z = 0;
      validateMemoryOperation((int *)&g_spriteTemplateValidator);
    }
    if ((g_renderingInitFlags & 2) == 0) {
      g_renderingInitFlags = g_renderingInitFlags | 2;
      g_billboardMatrix = (undefined *)0x3f800000;
      g_billboardMatrix_M01 = (undefined *)0x0;
      g_billboardMatrix_M02 = (undefined *)0x0;
      g_billboardMatrix_M03 = (undefined *)0x0;
      _g_billboardMatrix_M10 = 0.0;
      _g_billboardMatrix_M11 = 1.0;
      _g_billboardMatrix_M12 = 0.0;
      _g_billboardMatrix_M13 = 0;
      g_billboardMatrix_M20 = (undefined *)0x0;
      g_billboardMatrix_M21 = (undefined *)0x0;
      g_billboardMatrix_M22 = (undefined *)0x3f800000;
      _g_billboardMatrix_M23 = 0;
      _g_billboardMatrix_M30 = 0;
      _g_billboardMatrix_M31 = 0;
      _g_billboardMatrix_M32 = 0;
      _g_billboardMatrix_M33 = 0x3f800000;
      validateMemoryOperation((int *)&g_billboardMatrixValidator);
    }
    uVar2._0_2_ = this->colorPaletteArray[2].padding_06;
    uVar2._2_2_ = this->colorPaletteArray[2].texCoordDelta2_prefix;
    if ((uVar2 & 0x100) == 0) {
      pMVar4 = multiplyMatrix4x4_SSE_Optimized
                         (&tempMatrix1,(Matrix4x4 *)(this->colorPaletteArray[2].final_padding + 6),
                          (Matrix4x4 *)&g_worldMatrix);
      ppuVar12 = &g_billboardMatrix;
      iVar13 = 8;
      do {
        *ppuVar12 = (undefined *)pMVar4->m00;
        ppuVar12[1] = (undefined *)pMVar4->m01;
        ppuVar12 = ppuVar12 + 2;
        pMVar4 = (Matrix4x4 *)&pMVar4->m02;
        iVar13 = iVar13 + -1;
      } while (iVar13 != 0);
    }
    else {
      ppuVar12 = &g_worldMatrix;
      ppuVar15 = &g_billboardMatrix;
      for (iVar13 = 0x10; iVar13 != 0; iVar13 = iVar13 + -1) {
        *ppuVar15 = *ppuVar12;
        ppuVar12 = ppuVar12 + 1;
        ppuVar15 = ppuVar15 + 1;
      }
    }
    uVar5 = 0;
    do {
      uVar6 = uVar5 + 0xc;
      local_10 = (undefined *)
                 ((float)g_billboardMatrix * *(float *)((int)&g_spriteVertexTemplate + uVar5) +
                 (float)g_billboardMatrix_M20 * *(float *)((int)&g_spriteVertex1_Y + uVar5) +
                 _g_billboardMatrix_M10 * *(float *)((int)&g_spriteVertex1_X + uVar5));
      fVar11 = _g_billboardMatrix_M11 * *(float *)((int)&g_spriteVertex1_X + uVar5);
      *(undefined **)((int)&g_transformedVertices + uVar5) = local_10;
      local_c = (undefined *)
                ((float)g_billboardMatrix_M21 * *(float *)((int)&g_spriteVertex1_Y + uVar5) +
                (float)g_billboardMatrix_M01 * *(float *)((int)&g_spriteVertexTemplate + uVar5) +
                fVar11);
      fVar11 = _g_billboardMatrix_M12 * *(float *)((int)&g_spriteVertex1_X + uVar5);
      *(undefined **)((int)&g_transformedVertex1_Y + uVar5) = local_c;
      local_8 = (undefined *)
                ((float)g_billboardMatrix_M02 * *(float *)((int)&g_spriteVertexTemplate + uVar5) +
                (float)g_billboardMatrix_M22 * *(float *)((int)&g_spriteVertex1_Y + uVar5) + fVar11)
      ;
      *(undefined **)((int)&g_transformedVertex1_Z + uVar5) = local_8;
      uVar5 = uVar6;
    } while (uVar6 < 0x30);
    pfVar1 = (float *)((int)&this->colorPaletteArray[4].renderFlags + 2);
    *pfVar1 = (float)g_billboardMatrix_M20;
    *(undefined **)&this->colorPaletteArray[4].colorDeltaG_prefix = g_billboardMatrix_M21;
    *(undefined **)((int)&this->colorPaletteArray[4].colorDeltaB_field + 2) = g_billboardMatrix_M22;
    fVar16 = (float10)emptyFunction();
    if ((float10)_DAT_008029d4 <= ABS(SQRT(fVar16))) {
      fVar16 = (float10)StaticFloat1_0 / SQRT(fVar16);
      *pfVar1 = (float)(fVar16 * (float10)*pfVar1);
      *(float *)&this->colorPaletteArray[4].colorDeltaG_prefix =
           (float)(fVar16 * (float10)*(float *)&this->colorPaletteArray[4].colorDeltaG_prefix);
      *(float *)((int)&this->colorPaletteArray[4].colorDeltaB_field + 2) =
           (float)(fVar16 * (float10)*(float *)((int)&this->colorPaletteArray[4].colorDeltaB_field +
                                               2));
    }
  }
  BeginRender();
  pcVar7 = GetTextureBuffer(*(int *)(this->colorPaletteArray[1].final_padding + 10),0,(int *)0x0);
  if (pcVar7 == (char *)0x0) goto LAB_007b44c4;
  SetTexture(0x17,pcVar7);
  g_maxParticleSprites = (undefined *)(0x4000 / ZEXT48(this->skeletonAttachmentPtr));
  puVar8 = *(undefined **)((int)&this->maxModelParticleSlots + 2);
  if (puVar8 <= g_maxParticleSprites) {
    g_maxParticleSprites = puVar8;
  }
  iVar14 = (-(uint)((*(uint *)(this->colorPaletteArray[1].padding_3E_43 + 4) & 1) != 0) & 0xfffffffc
           ) + 8;
  puVar8 = GetDataPointerByIndex(iVar14);
  puVar9 = (undefined *)
           CreateVertexBuffer(0,(int)puVar8,
                              (int)this->skeletonAttachmentPtr * (int)g_maxParticleSprites);
  iVar13 = LockVertexBuffer(puVar9);
  local_dc = (undefined *)0x0;
  puVar10 = GetMatrixElementPointer(iVar14,0);
  local_fc = puVar10 + iVar13;
  local_ec = puVar8;
  if ((this->colorPaletteArray[1].padding_3E_43[4] & 1) == 0) {
    if ((g_renderingInitFlags & 4) == 0) {
      g_renderingInitFlags = g_renderingInitFlags | 4;
      _g_defaultNormalX = 0;
      _DAT_00cf5864 = 0;
      _DAT_00cf5868 = 0;
      validateMemoryOperation((int *)&g_normalVectorValidator);
    }
    local_f8 = &g_defaultNormalX;
    local_e8 = (undefined *)0x0;
  }
  else {
    puVar10 = GetMatrixElementPointer(iVar14,3);
    local_f8 = puVar10 + iVar13;
    local_e8 = puVar8;
  }
  puVar10 = GetMatrixElementPointer(iVar14,4);
  local_f4 = puVar10 + iVar13;
  local_e4 = puVar8;
  puVar10 = GetMatrixElementPointer(iVar14,5);
  local_f0 = puVar10 + iVar13;
  local_e0 = puVar8;
  RenderParticleSystemSorted(this,(float **)&local_fc);
  UnlockVertexBuffer((int)puVar9,(undefined *)0x0);
  DrawPrimitive((int)puVar9,iVar14);
  if (this->field_0x28 == 6) {
    puVar9 = IsObjectActiveAndValid((int)g_indexBuffer6);
    puVar8 = g_indexBuffer6;
    if (puVar9 == (undefined *)0x0) {
      BuildIndexBuffer((int)g_indexBuffer6,this->field_0x28);
      puVar8 = g_indexBuffer6;
    }
LAB_007b4486:
    SetStreamSource((int)puVar8);
  }
  else if (this->field_0x28 == 0xc) {
    puVar9 = IsObjectActiveAndValid((int)g_indexBuffer12);
    puVar8 = g_indexBuffer12;
    if (puVar9 == (undefined *)0x0) {
      BuildIndexBuffer((int)g_indexBuffer12,this->field_0x28);
      puVar8 = g_indexBuffer12;
    }
    goto LAB_007b4486;
  }
  fVar11 = (float)(this->rendersPerChildSystem * this->field_0x28);
  this->calculatedTextureScaleY = fVar11;
  local_10 = (undefined *)0x0;
  local_c = (undefined *)((uint)fVar11 & 0xffff);
  local_14 = (undefined *)0x3;
  local_8 = (undefined *)CONCAT22(local_8._2_2_,(short)local_dc + -1);
  CallGfxDeviceMethod_Wrapper((undefined *)&local_14,(undefined *)0x1);
LAB_007b44c4:
  EndRender();
  SetVertexShader((undefined *)&identityMatrix);
  return;
}


