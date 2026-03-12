
/* WARNING: Variable defined which should be unmapped: local_18 */

void __fastcall
interpolateAnimationKeyframes
          (void *animationObject,uint animationState,AnimationData *keyframeData,
          InterpolationOutputBuffer *outputBuffer)

{
  int iVar1;
  float *source_keyframe_ptr;
  float *first_keyframe_ptr;
  int second_keyframe_ptr;
  int iVar2;
  undefined *local_18;
  undefined *local_8;
  float interpolation_factor;
  uint keyframe_base_ptr;
  
  findInterpolationIndices
            ((SceneObject *)animationObject,*(uint *)(animationState + 0x98),
             *(uint *)(animationState + 0x9c),keyframeData,&outputBuffer->first_keyframe_index);
  iVar1 = outputBuffer->first_keyframe_index * 0x10;
  if ((short)keyframeData->interpolationModeAndTimeIndex == 0) {
    source_keyframe_ptr = (float *)(iVar1 + keyframeData->keyframe_base_ptr);
    outputBuffer->primary_result[0] = *source_keyframe_ptr;
    outputBuffer->primary_result[1] = source_keyframe_ptr[1];
    outputBuffer->primary_result[2] = source_keyframe_ptr[2];
    outputBuffer->primary_result[3] = source_keyframe_ptr[3];
    return;
  }
  keyframe_base_ptr = keyframeData->keyframe_base_ptr;
  interpolation_factor = (float)outputBuffer->interpolation_factor;
  first_keyframe_ptr = (float *)(iVar1 + keyframe_base_ptr);
  iVar1 = outputBuffer->second_keyframe_index * 0x10;
  second_keyframe_ptr = iVar1 + keyframe_base_ptr;
  source_keyframe_ptr = outputBuffer->primary_result;
  *source_keyframe_ptr =
       (*(float *)(iVar1 + keyframe_base_ptr) - *first_keyframe_ptr) * interpolation_factor +
       *first_keyframe_ptr;
  outputBuffer->primary_result[1] =
       (*(float *)(second_keyframe_ptr + 4) - first_keyframe_ptr[1]) * interpolation_factor +
       first_keyframe_ptr[1];
  outputBuffer->primary_result[2] =
       (*(float *)(second_keyframe_ptr + 8) - first_keyframe_ptr[2]) * interpolation_factor +
       first_keyframe_ptr[2];
  outputBuffer->primary_result[3] =
       (*(float *)(second_keyframe_ptr + 0xc) - first_keyframe_ptr[3]) * interpolation_factor +
       first_keyframe_ptr[3];
  if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(animationState + 0x10c)) &&
     (*(short *)((int)&keyframeData->interpolationModeAndTimeIndex + 2) == -1)) {
    findInterpolationIndices
              ((SceneObject *)animationObject,*(uint *)(animationState + 0xc4),
               *(uint *)(animationState + 200),keyframeData,&outputBuffer->secondary_first_index);
    interpolation_factor = (float)outputBuffer->secondary_factor;
    keyframe_base_ptr = keyframeData->keyframe_base_ptr;
    second_keyframe_ptr = outputBuffer->secondary_second_index * 0x10;
    iVar2 = second_keyframe_ptr + keyframe_base_ptr;
    iVar1 = outputBuffer->secondary_first_index * 0x10;
    first_keyframe_ptr = (float *)(iVar1 + keyframe_base_ptr);
    outputBuffer->secondary_result[0] =
         (*(float *)(second_keyframe_ptr + keyframe_base_ptr) -
         *(float *)(iVar1 + keyframe_base_ptr)) * interpolation_factor + *first_keyframe_ptr;
    outputBuffer->secondary_result[1] =
         (*(float *)(iVar2 + 4) - first_keyframe_ptr[1]) * interpolation_factor +
         first_keyframe_ptr[1];
    outputBuffer->secondary_result[2] =
         (*(float *)(iVar2 + 8) - first_keyframe_ptr[2]) * interpolation_factor +
         first_keyframe_ptr[2];
    outputBuffer->secondary_result[3] =
         (*(float *)(iVar2 + 0xc) - first_keyframe_ptr[3]) * interpolation_factor +
         first_keyframe_ptr[3];
    blendAnimationResults
              ((undefined *)source_keyframe_ptr,(undefined *)source_keyframe_ptr,
               (undefined *)outputBuffer->secondary_result,*(undefined **)(animationState + 0x10c));
  }
  return;
}

