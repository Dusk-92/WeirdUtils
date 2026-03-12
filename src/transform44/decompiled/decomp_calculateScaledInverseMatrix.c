
/* WARNING: Variable defined which should be unmapped: local_a4 */
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

undefined ** __thiscall calculateScaledInverseMatrix(void *this,undefined **param_1,float param_2)

{
  int iVar1;
  undefined **ppuVar2;
  undefined **ppuVar3;
  undefined *local_a4;
  undefined *local_98;
  undefined *local_94;
  undefined *local_90;
  undefined *local_8c;
  undefined *local_88;
  undefined *local_84;
  undefined *local_80;
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
  
  if (ABS(param_2 - StaticFloat1_0) < _MOVEMENT_EPSILON) {
    calculateInverseTransformMatrix(this,param_1);
    return param_1;
  }
                    /* WARNING: Load size is inaccurate */
  InitializeStructWith9Pointers
            (&local_74,*this,*(undefined **)((int)this + 4),*(undefined **)((int)this + 8),
             *(undefined **)((int)this + 0x10),*(undefined **)((int)this + 0x14),
             *(undefined **)((int)this + 0x18),*(undefined **)((int)this + 0x20),
             *(undefined **)((int)this + 0x24),*(undefined **)((int)this + 0x28));
  InitializeStructWith9Pointers
            (&local_98,local_74,local_68,local_5c,local_70,local_64,local_58,local_6c,local_60,
             local_54);
  local_4c = local_94;
  local_50 = local_98;
  local_48 = local_90;
  local_3c = local_88;
  local_40 = local_8c;
  local_38 = local_84;
  local_2c = local_7c;
  local_44 = (undefined *)0x0;
  local_34 = (undefined *)0x0;
  local_30 = local_80;
  local_28 = local_78;
  local_24 = (undefined *)0x0;
  local_20 = (undefined *)0x0;
  local_1c = (undefined *)0x0;
  local_18 = (undefined *)0x0;
  local_14 = (undefined *)0x3f800000;
  scaleMatrix3x3ByScalar(&local_50,StaticFloat1_0 / (param_2 * param_2));
  local_10 = (undefined *)-*(float *)((int)this + 0x30);
  local_c = (undefined *)-*(float *)((int)this + 0x34);
  local_8 = (undefined *)-*(float *)((int)this + 0x38);
  ApplyTranslationMatrix(&local_50,(float *)&local_10);
  ppuVar2 = &local_50;
  ppuVar3 = param_1;
  for (iVar1 = 0x10; iVar1 != 0; iVar1 = iVar1 + -1) {
    *ppuVar3 = *ppuVar2;
    ppuVar2 = ppuVar2 + 1;
    ppuVar3 = ppuVar3 + 1;
  }
  return param_1;
}

