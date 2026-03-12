
void __fastcall getInterpolatedFloat(void *param_1,int param_2,short *param_3,uint *param_4)

{
  float fVar1;
  undefined *local_8;
  
  findInterpolationIndices
            ((SceneObject *)param_1,*(uint *)(param_2 + 0x98),*(uint *)(param_2 + 0x9c),
             (AnimationData *)param_3,param_4);
  if (*param_3 == 0) {
    param_4[3] = *(uint *)(*(int *)(param_3 + 0xc) + *param_4 * 4);
    return;
  }
  fVar1 = *(float *)(*(int *)(param_3 + 0xc) + *param_4 * 4);
  param_4[3] = (uint)((*(float *)(*(int *)(param_3 + 0xc) + param_4[1] * 4) - fVar1) *
                      (float)param_4[2] + fVar1);
  if (((float)COLLISION_PLANE_ZERO_THRESHOLD != *(float *)(param_2 + 0x10c)) && (param_3[1] == -1))
  {
    findInterpolationIndices
              ((SceneObject *)param_1,*(uint *)(param_2 + 0xc4),*(uint *)(param_2 + 200),
               (AnimationData *)param_3,param_4 + 4);
    fVar1 = *(float *)(*(int *)(param_3 + 0xc) + param_4[4] * 4);
    fVar1 = (*(float *)(*(int *)(param_3 + 0xc) + param_4[5] * 4) - fVar1) * (float)param_4[6] +
            fVar1;
    param_4[7] = (uint)fVar1;
    param_4[3] = (uint)((fVar1 - (float)param_4[3]) * *(float *)(param_2 + 0x10c) +
                       (float)param_4[3]);
  }
  return;
}

