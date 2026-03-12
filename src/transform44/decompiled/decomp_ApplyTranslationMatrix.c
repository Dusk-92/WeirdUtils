
void __thiscall ApplyTranslationMatrix(void *this,float *param_1)

{
                    /* WARNING: Load size is inaccurate */
  *(float *)((int)this + 0x30) =
       *param_1 * *this +
       *(float *)((int)this + 0x10) * param_1[1] + *(float *)((int)this + 0x20) * param_1[2] +
       *(float *)((int)this + 0x30);
  *(float *)((int)this + 0x34) =
       *(float *)((int)this + 4) * *param_1 +
       *(float *)((int)this + 0x14) * param_1[1] + *(float *)((int)this + 0x24) * param_1[2] +
       *(float *)((int)this + 0x34);
  *(float *)((int)this + 0x38) =
       *(float *)((int)this + 8) * *param_1 +
       *(float *)((int)this + 0x18) * param_1[1] + *(float *)((int)this + 0x28) * param_1[2] +
       *(float *)((int)this + 0x38);
  return;
}

