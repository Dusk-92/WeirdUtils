
void __thiscall rotateMatrixByQuaternion(void *this,float *param_1)

{
  float fVar1;
  float fVar2;
  float fVar3;
  Matrix4x4 *pMVar4;
  int iVar5;
  undefined *local_7c;
  undefined *local_78;
  undefined *local_74;
  undefined *local_70;
  undefined *local_6c;
  undefined *local_68;
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
  
  fVar1 = *param_1 + *param_1;
  local_54 = (undefined *)0x0;
  fVar3 = param_1[1] + param_1[1];
  local_44 = (undefined *)0x0;
  fVar2 = param_1[2] + param_1[2];
  local_10 = (undefined *)(fVar1 * param_1[3]);
  local_20 = (undefined *)(fVar3 * param_1[3]);
  local_1c = (undefined *)(fVar2 * param_1[3]);
  local_18 = (undefined *)(fVar1 * *param_1);
  local_c = (undefined *)(fVar3 * *param_1);
  local_14 = (undefined *)(fVar2 * *param_1);
  local_8 = (undefined *)(fVar2 * param_1[1]);
  local_60 = (undefined *)(StaticFloat1_0 - (fVar2 * param_1[2] + fVar3 * param_1[1]));
  local_5c = (undefined *)((float)local_c + (float)local_1c);
  local_7c = (undefined *)((float)local_14 - (float)local_20);
  local_78 = (undefined *)((float)local_c - (float)local_1c);
  local_74 = (undefined *)(StaticFloat1_0 - (fVar2 * param_1[2] + (float)local_18));
  local_70 = (undefined *)((float)local_8 + (float)local_10);
  local_6c = (undefined *)((float)local_14 + (float)local_20);
  local_68 = (undefined *)((float)local_8 - (float)local_10);
  local_64 = (undefined *)(StaticFloat1_0 - (fVar3 * param_1[1] + (float)local_18));
  local_34 = (undefined *)0x0;
  local_30 = (undefined *)0x0;
  local_2c = (undefined *)0x0;
  local_28 = (undefined *)0x0;
  local_24 = (undefined *)0x3f800000;
  local_58 = local_7c;
  local_50 = local_78;
  local_4c = local_74;
  local_48 = local_70;
  local_40 = local_6c;
  local_3c = local_68;
  local_38 = local_64;
  pMVar4 = multiplyMatrix4x4_SSE_Optimized
                     ((Matrix4x4 *)&stack0xffffff60,(Matrix4x4 *)&local_60,(Matrix4x4 *)this);
  iVar5 = 8;
  do {
    *(float *)this = pMVar4->m00;
    *(float *)((int)this + 4) = pMVar4->m01;
    this = (void *)((int)this + 8);
    pMVar4 = (Matrix4x4 *)&pMVar4->m02;
    iVar5 = iVar5 + -1;
  } while (iVar5 != 0);
  return;
}

