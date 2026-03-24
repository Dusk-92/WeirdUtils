
void __thiscall RenderSpriteQuads(void *this,int spriteData,uint spriteCount,int renderMode)

{
  ushort uVar1;
  ushort uVar2;
  int iVar3;
  int iVar4;
  uint uVar5;
  int *piVar6;
  ushort *puVar7;
  bool bVar8;
  undefined *local_8;
  
                    /* Renders sprite quads - validates texture states, calculates rendering
                       metrics, and issues draw calls for each valid sprite */
  if (*(int *)((int)this + 0xf2c) != 0) {
    piVar6 = (int *)((int)this + 0x27a4);
    bVar8 = true;
    uVar5 = 0;
    do {
      if ((*(uint *)((int)this + 0x27d8) & 1 << ((byte)uVar5 & 0x1f)) != 0) {
        iVar3 = *piVar6;
        if ((((iVar3 == 0) || (!bVar8)) || (*(char *)(iVar3 + 0x1c) == '\0')) ||
           (*(char *)(iVar3 + 0x1d) == '\0')) {
          bVar8 = false;
        }
        else {
          bVar8 = true;
        }
      }
      uVar5 = uVar5 + 1;
      piVar6 = piVar6 + 1;
    } while (uVar5 < 0xd);
    if (renderMode == 0) {
      bVar8 = !bVar8;
    }
    else {
      if ((!bVar8) || (*(char *)(*(int *)((int)this + 0x27ec) + 0x1c) == '\0')) goto LAB_005a0fd8;
      bVar8 = *(char *)(*(int *)((int)this + 0x27ec) + 0x1d) == '\0';
    }
    if (bVar8) {
LAB_005a0fd8:
      EmptyStub();
      return;
    }
    CalculateRenderingMetrics(this,spriteData,spriteCount,renderMode);
    getAdapterInfo(this);
    if (spriteCount != 0) {
      puVar7 = (ushort *)(spriteData + 10);
      spriteData = spriteCount;
      do {
        uVar1 = puVar7[-1];
        if (uVar1 != 0) {
          spriteCount = 0;
          if (*(int *)((int)this + 0x24c) == 0) {
            spriteCount = *(uint *)(*(int *)((int)this + 0x27a4) + 0x18) /
                          *(uint *)(*(int *)((int)this + 0x27a4) + 0xc);
          }
          if (renderMode == 0) {
            iVar3 = **(int **)((int)this + 0x38a8);
            iVar4 = DisplayMode_CalculateOffset(*(int *)(puVar7 + -5),(uint)uVar1);
            (**(code **)(iVar3 + 0x144))
                      (*(undefined4 *)((int)this + 0x38a8),
                       *(undefined4 *)(&DAT_0080a14c + *(int *)(puVar7 + -5) * 4),spriteCount,iVar4)
            ;
          }
          else {
            uVar2 = *puVar7;
            iVar3 = **(int **)((int)this + 0x38a8);
            iVar4 = DisplayMode_CalculateOffset(*(int *)(puVar7 + -5),(uint)uVar1);
            (**(code **)(iVar3 + 0x148))
                      (*(undefined4 *)((int)this + 0x38a8),
                       *(undefined4 *)(&DAT_0080a14c + *(int *)(puVar7 + -5) * 4),spriteCount,
                       (uint)uVar2,((uint)puVar7[1] - (uint)uVar2) + 1,
                       (*(uint *)(*(int *)((int)this + 0x27ec) + 0x18) >> 1) + *(int *)(puVar7 + -3)
                       ,iVar4);
          }
        }
        puVar7 = puVar7 + 8;
        spriteData = spriteData + -1;
      } while (spriteData != 0);
    }
  }
  return;
}


