
void __thiscall scaleMatrix3x3ByVector(void *this,float *param_1)

{
  float fVar1;
  
  fVar1 = *param_1;
                    /* WARNING: Load size is inaccurate */
  *(float *)this = fVar1 * *this;
  *(float *)((int)this + 4) = fVar1 * *(float *)((int)this + 4);
  *(float *)((int)this + 8) = fVar1 * *(float *)((int)this + 8);
  fVar1 = param_1[1];
  *(float *)((int)this + 0x10) = fVar1 * *(float *)((int)this + 0x10);
  *(float *)((int)this + 0x14) = fVar1 * *(float *)((int)this + 0x14);
  *(float *)((int)this + 0x18) = fVar1 * *(float *)((int)this + 0x18);
  fVar1 = param_1[2];
  *(float *)((int)this + 0x20) = fVar1 * *(float *)((int)this + 0x20);
  *(float *)((int)this + 0x24) = fVar1 * *(float *)((int)this + 0x24);
  *(float *)((int)this + 0x28) = fVar1 * *(float *)((int)this + 0x28);
  return;
}

