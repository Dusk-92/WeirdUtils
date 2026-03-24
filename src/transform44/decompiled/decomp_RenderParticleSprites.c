openjdk version "21.0.10" 2026-01-20
OpenJDK Runtime Environment (build 21.0.10+7)
OpenJDK 64-Bit Server VM (build 21.0.10+7, mixed mode)
// RenderParticleSprites @ 0x7B2A50
// Decompiled by Ghidra


/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

undefined * __thiscall
RenderParticleSprites(ParticleSystemRenderer *this,float *particleData,float **vertexBuffers)

{
  undefined *puVar1;
  int loopIndex;
  uint texLoopIndex;
  float *particleDataPtr;
  int nextLoopIndex;
  undefined **textureOffsetPtr;
  undefined **textureVPtr;
  uint colorDeltaR;
  float10 sinRotation;
  float *rotMatrix_m00;
  float *rotMatrix_m01;
  float *rotMatrix_m02;
  float *rotMatrix_m10;
  float *rotMatrix_m11;
  float *rotMatrix_m12;
  float *rotMatrix_m20;
  float *rotMatrix_m21;
  float *rotMatrix_m22;
  float *transformedVelocityVector;
  float *transformedVertexZ;
  float *negVelocityX;
  float *transformedVertexX;
  float *negVelocityZ;
  float *negVelocityY;
  uint *colorData1;
  uint *colorData2;
  float *textureU;
  float *textureV;
  float *particleTimeIndex;
  float worldPosX;
  float worldPosY;
  float worldPosZ;
  float *vertexX;
  float *vertexY;
  float *vertexZ;
  uint *colorValue;
  float *rotationAngle;
  float spriteScale;
  float *particleFlags;
  float textureUIndex;
  float textureVIndex;
  float clampedParticleTime;
  undefined *clampedTimePtr;
  float10 cosRotation;
  float cosValue;
  float scaleFactor;
  float tempFloat1;
  float textureCoordV;
  float velocityDirection;
  float *vertexBuffer;
  float **vertexBufferPtr;
  float zDepth;
  
  particleDataPtr = particleData;
  colorDeltaR = 0;
                    /* Reading colorDeltaB+2 - likely wrong field mapping */
                    /* Reading texCoordBase1+2 - another +2 offset pattern */
  if (((float)this->colorPaletteArray[2].renderFlags_source < StaticFloat1_0) ||
     (*(float *)&this->colorPaletteArray[2].renderFlags_prefix !=
      (float)COLLISION_PLANE_ZERO_THRESHOLD)) {
    puVar1 = (undefined *)(this->colorPaletteArray[2].texCoordDelta2 * particleData[7]);
    clampedTimePtr = COLLISION_PLANE_ZERO_THRESHOLD;
    if (((float)COLLISION_PLANE_ZERO_THRESHOLD <= (float)puVar1) &&
       (clampedTimePtr = puVar1, (float)_DAT_007ffe58 <= (float)puVar1)) {
      clampedTimePtr = _DAT_007ffe58;
    }
    particleTimeIndex = (float *)((float)clampedTimePtr + _DAT_008029cc);
    colorDeltaR = ((uint)particleTimeIndex >> 0xe) + ((uint)particleData >> 5) & 0x7f;
  }
  if (((float)this->colorPaletteArray[2].renderFlags_source < StaticFloat1_0) &&
     ((float)this->colorPaletteArray[2].renderFlags_source <
      *(float *)(&g_particleDepthBuffer + colorDeltaR * 4))) {
    return (undefined *)0x0;
  }
  colorValue = (uint *)0x0;
  calculateParticleColorAndScale
            ((OrientationData *)
             (this->orientationDataArray + (uint)*(byte *)(particleData + 3) * 0x60 + -0x12),
             particleData[7],*(float *)((int)&this->colorPaletteArray[2].colorDeltaR + 2),
             (byte *)&colorValue,(uint *)&colorData1,(uint *)&colorData2,&spriteScale);
  loopIndex = UpdateLightingOffset();
  if (*(int *)(loopIndex + 0x1c) == 1) {
    colorValue = (uint *)CONCAT31(CONCAT21(CONCAT11((char)((uint)colorValue >> 0x18),
                                                    (char)colorValue),(char)((uint)colorValue >> 8))
                                  ,(char)((uint)colorValue >> 0x10));
    rotationAngle = (float *)colorValue;
  }
  if (*(float *)&this->colorPaletteArray[2].renderFlags_prefix !=
      (float)COLLISION_PLANE_ZERO_THRESHOLD) {
    spriteScale = (*(float *)(&g_particleDepthBuffer + colorDeltaR * 4) *
                   *(float *)&this->colorPaletteArray[2].renderFlags_prefix +
                  *(float *)&this->colorPaletteArray[2].field_0x1e_source) * spriteScale;
  }
  colorDeltaR._0_2_ = this->colorPaletteArray[2].padding_06;
  colorDeltaR._2_2_ = this->colorPaletteArray[2].texCoordDelta2_prefix;
  if ((colorDeltaR & 0x200) != 0) {
    spriteScale = spriteScale * *(float *)(this->colorPaletteArray[3].padding_50_53 + 2);
  }
  transformVector3ByMatrix4x4(&worldPosX,particleDataPtr,(float *)&g_worldMatrix);
  vertexBufferPtr = vertexBuffers;
  texLoopIndex._0_2_ = this->colorPaletteArray[2].padding_06;
  texLoopIndex._2_2_ = this->colorPaletteArray[2].texCoordDelta2_prefix;
  if ((texLoopIndex & 4) != 0) {
    textureUIndex =
         (float)(*(int *)(this->colorPaletteArray[1].final_padding + 6) - 1U & (uint)colorData1);
    textureVIndex = 0.0;
    textureU = (float *)((float)(uint)textureUIndex * this->textureScaleU);
    textureV = (float *)((float)((int)colorData1 >> (SUB41(this->uvCoordinateScale,0) & 0x1f)) *
                        this->textureScaleV);
    if (this->colorPaletteArray[1].texCoordBase1 == (float)COLLISION_PLANE_ZERO_THRESHOLD) {
      if ((texLoopIndex & 0x2000) == 0) {
        loopIndex = 0;
        do {
          vertexBuffer = *vertexBuffers;
          nextLoopIndex = loopIndex + 8;
          vertexX = (float *)(spriteScale * *(float *)((int)&g_billboardVertexOffsetsX + loopIndex)
                             + worldPosX);
          vertexY = (float *)(spriteScale * *(float *)((int)&g_billboardVertexOffsetsY + loopIndex)
                             + worldPosY);
          *vertexBuffer = (float)vertexX;
          vertexBuffer[1] = (float)vertexY;
          vertexZ = (float *)worldPosZ;
          vertexBuffer[2] = worldPosZ;
          vertexBuffer = vertexBuffers[1];
          *vertexBuffer = (float)g_lightDirectionX;
          vertexBuffer[1] = (float)g_lightDirectionY;
          vertexBuffer[2] = (float)g_lightDirectionZ;
          *vertexBuffers[2] = (float)colorValue;
          vertexBuffer = vertexBuffers[3];
          tempFloat1 = *(float *)((int)&g_spriteTextureOffsetsV + loopIndex);
          textureCoordV = this->textureScaleV;
          *vertexBuffer =
               *(float *)((int)&g_spriteTextureOffsetsU + loopIndex) * this->textureScaleU +
               (float)textureU;
          vertexBuffer[1] = tempFloat1 * textureCoordV + (float)textureV;
          vertexBuffers[8] = (float *)((int)vertexBuffers[8] + 1);
          *vertexBuffers = (float *)((int)*vertexBuffers + (int)vertexBuffers[4]);
          vertexBuffers[1] = (float *)((int)vertexBuffers[1] + (int)vertexBuffers[5]);
          vertexBuffers[2] = (float *)((int)vertexBuffers[2] + (int)vertexBuffers[6]);
          vertexBuffers[3] = (float *)((int)vertexBuffers[3] + (int)vertexBuffers[7]);
          loopIndex = nextLoopIndex;
        } while (nextLoopIndex != 0x20);
      }
      else {
        vertexBuffers = (float **)0x4;
        textureVPtr = &g_transformedVertex1_Z;
        textureOffsetPtr = &g_spriteTextureOffsetsV;
        do {
          particleDataPtr = *vertexBufferPtr;
          transformedVertexZ = (float *)(spriteScale * (float)*textureVPtr);
          vertexX = (float *)(spriteScale * (float)textureVPtr[-2] + worldPosX);
          vertexY = (float *)(spriteScale * (float)textureVPtr[-1] + worldPosY);
          vertexZ = (float *)((float)transformedVertexZ + worldPosZ);
          *particleDataPtr = (float)vertexX;
          particleDataPtr[1] = (float)vertexY;
          particleDataPtr[2] = (float)vertexZ;
          particleDataPtr = vertexBufferPtr[1];
          *particleDataPtr = (float)g_lightDirectionX;
          particleDataPtr[1] = (float)g_lightDirectionY;
          particleDataPtr[2] = (float)g_lightDirectionZ;
          *vertexBufferPtr[2] = (float)colorValue;
          particleDataPtr = vertexBufferPtr[3];
          tempFloat1 = this->textureScaleV;
          clampedParticleTime = (float)*textureOffsetPtr;
          *particleDataPtr = (float)textureOffsetPtr[-1] * this->textureScaleU + (float)textureU;
          particleDataPtr[1] = tempFloat1 * clampedParticleTime + (float)textureV;
          vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
          *vertexBufferPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
          vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
          vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
          vertexBuffers = (float **)((int)vertexBuffers + -1);
          vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
          textureVPtr = textureVPtr + 3;
          textureOffsetPtr = textureOffsetPtr + 2;
          particleDataPtr = particleData;
        } while (vertexBuffers != (float **)0x0);
      }
    }
    else {
      rotationAngle = (float *)(this->colorPaletteArray[1].texCoordBase1 * particleDataPtr[7]);
      if (((char)((ushort)(undefined2)texLoopIndex >> 8) < '\0') &&
         (((uint)particleDataPtr & 0x20) != 0)) {
        rotationAngle = (float *)-(float)rotationAngle;
      }
      if ((texLoopIndex & 0x2000) == 0) {
        particleTimeIndex = (float *)&particleData;
        cosRotation = (float10)fcos((float10)(float)rotationAngle);
        sinRotation = (float10)fsin((float10)(float)rotationAngle);
        colorDeltaR = 0;
        do {
          tempFloat1 = *(float *)((int)&g_billboardVertexOffsetsX + colorDeltaR);
          textureCoordV = *(float *)((int)&g_billboardVertexOffsetsY + colorDeltaR);
          texLoopIndex = colorDeltaR + 8;
          **vertexBuffers =
               (tempFloat1 * (float)cosRotation * spriteScale + worldPosX) -
               textureCoordV * (float)sinRotation * spriteScale;
          (*vertexBuffers)[1] =
               textureCoordV * (float)cosRotation * spriteScale +
               tempFloat1 * (float)sinRotation * spriteScale + worldPosY;
          (*vertexBuffers)[2] = worldPosZ;
          vertexBuffer = vertexBuffers[1];
          *vertexBuffer = (float)g_lightDirectionX;
          vertexBuffer[1] = (float)g_lightDirectionY;
          vertexBuffer[2] = (float)g_lightDirectionZ;
          *vertexBuffers[2] = (float)colorValue;
          vertexBuffer = vertexBuffers[3];
          tempFloat1 = *(float *)((int)&g_spriteTextureOffsetsV + colorDeltaR);
          textureCoordV = this->textureScaleV;
          *vertexBuffer =
               *(float *)((int)&g_spriteTextureOffsetsU + colorDeltaR) * this->textureScaleU +
               (float)textureU;
          vertexBuffer[1] = tempFloat1 * textureCoordV + (float)textureV;
          vertexBuffers[8] = (float *)((int)vertexBuffers[8] + 1);
          *vertexBuffers = (float *)((int)*vertexBuffers + (int)vertexBuffers[4]);
          vertexBuffers[1] = (float *)((int)vertexBuffers[1] + (int)vertexBuffers[5]);
          vertexBuffers[2] = (float *)((int)vertexBuffers[2] + (int)vertexBuffers[6]);
          vertexBuffers[3] = (float *)((int)vertexBuffers[3] + (int)vertexBuffers[7]);
          colorDeltaR = texLoopIndex;
        } while (texLoopIndex < 0x20);
      }
      else {
        vertexBuffers = (float **)&g_spriteTextureOffsetsV;
        textureVPtr = &g_transformedVertex1_Y;
        particleTimeIndex = (float *)0x4;
        do {
          createAxisAngleRotationMatrix3x3
                    ((float *)&rotMatrix_m00,
                     (float *)((int)&this->colorPaletteArray[4].renderFlags + 2),
                     (float)rotationAngle,'\x01');
          particleDataPtr = *vertexBufferPtr;
          transformedVertexZ =
               (float *)((float)rotMatrix_m20 * (float)textureVPtr[-1] +
                        (float)rotMatrix_m22 * (float)textureVPtr[1] +
                        (float)rotMatrix_m21 * (float)*textureVPtr);
          transformedVertexX =
               (float *)(((float)rotMatrix_m02 * (float)textureVPtr[1] +
                         (float)rotMatrix_m01 * (float)*textureVPtr +
                         (float)rotMatrix_m00 * (float)textureVPtr[-1]) * spriteScale);
          vertexX = (float *)((float)transformedVertexX + worldPosX);
          vertexY = (float *)(((float)rotMatrix_m10 * (float)textureVPtr[-1] +
                              (float)rotMatrix_m12 * (float)textureVPtr[1] +
                              (float)rotMatrix_m11 * (float)*textureVPtr) * spriteScale + worldPosY)
          ;
          vertexZ = (float *)((float)transformedVertexZ * spriteScale + worldPosZ);
          *particleDataPtr = (float)vertexX;
          particleDataPtr[1] = (float)vertexY;
          particleDataPtr[2] = (float)vertexZ;
          particleDataPtr = vertexBufferPtr[1];
          *particleDataPtr = (float)g_lightDirectionX;
          particleDataPtr[1] = (float)g_lightDirectionY;
          particleDataPtr[2] = (float)g_lightDirectionZ;
          *vertexBufferPtr[2] = (float)colorValue;
          textureUIndex = (float)vertexBuffers[-1] * this->textureScaleU + (float)textureU;
          textureVIndex = (float)*vertexBuffers * this->textureScaleV + (float)textureV;
          particleDataPtr = vertexBufferPtr[3];
          *particleDataPtr = textureUIndex;
          particleDataPtr[1] = textureVIndex;
          vertexBuffers = vertexBuffers + 2;
          textureVPtr = textureVPtr + 3;
          vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
          *vertexBufferPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
          vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
          vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
          particleTimeIndex = (float *)((int)particleTimeIndex + -1);
          vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
        } while (particleTimeIndex != (float *)0x0);
        particleTimeIndex = (float *)0x0;
        particleDataPtr = particleData;
      }
    }
  }
  if ((this->colorPaletteArray[2].padding_06 & 8) != 0) {
    textureUIndex =
         (float)(*(int *)(this->colorPaletteArray[1].final_padding + 6) - 1U & (uint)colorData2);
    textureVIndex = 0.0;
    particleData = (float *)this->childSystemPointers;
    vertexBuffers = (float **)((float)(uint)textureUIndex * this->textureScaleU);
    negVelocityY = (float *)0x0;
    rotationAngle =
         (float *)((float)((int)colorData2 >> (SUB41(this->uvCoordinateScale,0) & 0x1f)) *
                  this->textureScaleV);
    negVelocityX = (float *)-particleDataPtr[4];
    transformedVertexX = (float *)-particleDataPtr[5];
    negVelocityZ = (float *)-particleDataPtr[6];
    if (((this->colorPaletteArray[2].texCoordDelta2_prefix & 1) != 0) &&
       (particleDataPtr[7] < (float)particleData)) {
      particleData = (float *)particleDataPtr[7];
    }
    particleDataPtr =
         (float *)transformVector4ByMatrix4x4
                            ((float *)&transformedVelocityVector,(float *)&negVelocityX,
                             (float *)&g_worldMatrix);
    tempFloat1 = (float)particleData * *particleDataPtr;
    textureCoordV = (float)particleData * particleDataPtr[1];
    cosValue = tempFloat1 * tempFloat1 + textureCoordV * textureCoordV;
    if (_DAT_0080c744 <= cosValue) {
      vertexBuffer = *vertexBufferPtr;
      velocityDirection = (float)particleData * particleDataPtr[2] + worldPosZ;
      cosValue = spriteScale / SQRT(cosValue);
      scaleFactor = tempFloat1 * cosValue;
      cosValue = cosValue * textureCoordV;
      *vertexBuffer = worldPosX - cosValue;
      vertexBuffer[1] = scaleFactor + worldPosY;
      vertexBuffer[2] = worldPosZ;
      particleDataPtr = vertexBufferPtr[1];
      *particleDataPtr = (float)g_lightDirectionX;
      particleDataPtr[1] = (float)g_lightDirectionY;
      particleDataPtr[2] = (float)g_lightDirectionZ;
      *vertexBufferPtr[2] = (float)colorValue;
      particleDataPtr = vertexBufferPtr[3];
      zDepth = (float)g_spriteTextureOffsetsV * this->textureScaleV;
      *particleDataPtr = (float)g_spriteTextureOffsetsU * this->textureScaleU + (float)vertexBuffers
      ;
      particleDataPtr[1] = zDepth + (float)rotationAngle;
      vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
      particleDataPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
      vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
      *vertexBufferPtr = particleDataPtr;
      vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
      vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
      *particleDataPtr = worldPosX + cosValue;
      particleDataPtr[1] = worldPosY - scaleFactor;
      particleDataPtr[2] = worldPosZ;
      particleDataPtr = vertexBufferPtr[1];
      *particleDataPtr = (float)g_lightDirectionX;
      particleDataPtr[1] = (float)g_lightDirectionY;
      particleDataPtr[2] = (float)g_lightDirectionZ;
      *vertexBufferPtr[2] = (float)colorValue;
      particleDataPtr = vertexBufferPtr[3];
      zDepth = (float)g_spriteTextureOffsetsV * this->textureScaleV;
      *particleDataPtr = (float)g_spriteTextureOffsetsU * this->textureScaleU + (float)vertexBuffers
      ;
      particleDataPtr[1] = zDepth + (float)rotationAngle;
      vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
      vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
      particleDataPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
      *vertexBufferPtr = particleDataPtr;
      vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
      vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
      *particleDataPtr = (tempFloat1 + worldPosX) - cosValue;
      particleDataPtr[1] = textureCoordV + worldPosY + scaleFactor;
      particleDataPtr[2] = velocityDirection;
      particleDataPtr = vertexBufferPtr[1];
      *particleDataPtr = (float)g_lightDirectionX;
      particleDataPtr[1] = (float)g_lightDirectionY;
      particleDataPtr[2] = (float)g_lightDirectionZ;
      *vertexBufferPtr[2] = (float)colorValue;
      particleDataPtr = vertexBufferPtr[3];
      zDepth = _DAT_0087d748 * this->textureScaleV;
      *particleDataPtr = _DAT_0087d744 * this->textureScaleU + (float)vertexBuffers;
      particleDataPtr[1] = zDepth + (float)rotationAngle;
      vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
      particleDataPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
      vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
      vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
      *vertexBufferPtr = particleDataPtr;
      vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
      *particleDataPtr = tempFloat1 + worldPosX + cosValue;
      particleDataPtr[1] = (textureCoordV + worldPosY) - scaleFactor;
      particleDataPtr[2] = velocityDirection;
      particleDataPtr = vertexBufferPtr[1];
      *particleDataPtr = (float)g_lightDirectionX;
      particleDataPtr[1] = (float)g_lightDirectionY;
      particleDataPtr[2] = (float)g_lightDirectionZ;
      *vertexBufferPtr[2] = (float)colorValue;
      particleDataPtr = vertexBufferPtr[3];
      tempFloat1 = _DAT_0087d750 * this->textureScaleV;
      *particleDataPtr = _DAT_0087d74c * this->textureScaleU + (float)vertexBuffers;
      particleDataPtr[1] = tempFloat1 + (float)rotationAngle;
      *vertexBufferPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
      vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
      vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
      vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
      vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
      return (undefined *)0x1;
    }
    loopIndex = 0;
    do {
      particleDataPtr = *vertexBufferPtr;
      nextLoopIndex = loopIndex + 8;
      tempFloat1 = *(float *)((int)&g_billboardVertexOffsetsY + loopIndex);
      *particleDataPtr =
           spriteScale * *(float *)((int)&g_billboardVertexOffsetsX + loopIndex) + worldPosX;
      particleDataPtr[1] = spriteScale * tempFloat1 + worldPosY;
      particleDataPtr[2] = worldPosZ;
      particleDataPtr = vertexBufferPtr[1];
      *particleDataPtr = (float)g_lightDirectionX;
      particleDataPtr[1] = (float)g_lightDirectionY;
      particleDataPtr[2] = (float)g_lightDirectionZ;
      *vertexBufferPtr[2] = (float)colorValue;
      particleDataPtr = vertexBufferPtr[3];
      tempFloat1 = *(float *)((int)&g_spriteTextureOffsetsV + loopIndex);
      textureCoordV = this->textureScaleV;
      *particleDataPtr =
           *(float *)((int)&g_spriteTextureOffsetsU + loopIndex) * this->textureScaleU +
           (float)vertexBuffers;
      particleDataPtr[1] = tempFloat1 * textureCoordV + (float)rotationAngle;
      vertexBufferPtr[8] = (float *)((int)vertexBufferPtr[8] + 1);
      *vertexBufferPtr = (float *)((int)*vertexBufferPtr + (int)vertexBufferPtr[4]);
      vertexBufferPtr[1] = (float *)((int)vertexBufferPtr[1] + (int)vertexBufferPtr[5]);
      vertexBufferPtr[2] = (float *)((int)vertexBufferPtr[2] + (int)vertexBufferPtr[6]);
      vertexBufferPtr[3] = (float *)((int)vertexBufferPtr[3] + (int)vertexBufferPtr[7]);
      loopIndex = nextLoopIndex;
    } while (nextLoopIndex != 0x20);
  }
  return (undefined *)0x1;
}


