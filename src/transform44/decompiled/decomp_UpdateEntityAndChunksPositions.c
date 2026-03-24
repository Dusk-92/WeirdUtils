
/* WARNING: Globals starting with '_' overlap smaller symbols at the same address */

void __fastcall UpdateEntityAndChunksPositions(int entityPtr)

{
  float *pfVar1;
  int iVar2;
  float fVar3;
  undefined *puVar4;
  int *piVar5;
  uint uVar6;
  int iVar7;
  undefined *local_38;
  undefined *local_34;
  undefined *local_30;
  undefined *local_2c;
  undefined *local_28;
  undefined *local_24;
  undefined *local_18;
  undefined *local_14;
  undefined *local_10;
  undefined *local_c;
  undefined *local_8;
  
  *(float *)(entityPtr + 0x78) =
       (_DAT_00c7bcb0 * *(float *)(entityPtr + 0x5c) +
        _DAT_00c7bcb8 * *(float *)(entityPtr + 100) + _DAT_00c7bcb4 * *(float *)(entityPtr + 0x60) +
       _DAT_00c7bcbc) - *(float *)(entityPtr + 0x68);
  *(undefined **)(entityPtr + 0xb8) = PTR_00867964;
  if ((((byte)g_renderFlags & 4) != 0) && (_DAT_00867960 < *(float *)(entityPtr + 0x78))) {
    *(undefined **)(entityPtr + 0xb8) = PTR_00867968;
  }
  fVar3 = (float)PTR_00c62510 + *(float *)(entityPtr + 0xac);
  *(float *)(entityPtr + 0xac) = fVar3;
  if ((_DAT_0080a1e8 < fVar3) && (*(int *)(entityPtr + 0x14c) != 0)) {
    recycleVertexBuffer((int *)(entityPtr + 0x14c),(undefined **)(entityPtr + 0x150));
  }
  if (*(int *)(entityPtr + 0xc0) != 0) {
    if ((StaticFloat1_0 < *(float *)(entityPtr + 0xac)) &&
       (puVar4 = check_instances_active(*(int *)(entityPtr + 0xc0)), puVar4 != (undefined *)0x0)) {
      store_all_instance_buffers(*(int *)(entityPtr + 0xc0));
    }
    if (_DAT_0080a1e8 < *(float *)(entityPtr + 0xac)) {
      return_object_to_pool(*(undefined ***)(entityPtr + 0xc0));
      *(undefined4 *)(entityPtr + 0xc0) = 0;
    }
  }
  piVar5 = (int *)(entityPtr + 0x118);
  iVar7 = 4;
  local_8 = (undefined *)piVar5;
  do {
    iVar2 = *piVar5;
    if (iVar2 != 0) {
      fVar3 = (float)PTR_00c62510 + *(float *)(iVar2 + 0x30);
      *(float *)(iVar2 + 0x30) = fVar3;
      if ((*(int *)(iVar2 + 0x400) != 0) && (_DAT_0080a1e8 < fVar3)) {
        ReturnChunkBuffers((int *)(iVar2 + 0x400),(undefined **)(iVar2 + 0x404));
      }
    }
    piVar5 = piVar5 + 1;
    iVar7 = iVar7 + -1;
  } while (iVar7 != 0);
  if ((((*(float *)(entityPtr + 0x44) < _DAT_00c7cb68 !=
         (*(float *)(entityPtr + 0x44) == _DAT_00c7cb68)) &&
       (*(float *)(entityPtr + 0x48) < _DAT_00c7cb6c !=
        (*(float *)(entityPtr + 0x48) == _DAT_00c7cb6c))) &&
      (*(float *)(entityPtr + 0x4c) < _DAT_00c7cb70 !=
       (*(float *)(entityPtr + 0x4c) == _DAT_00c7cb70))) &&
     (puVar4 = IsPointInsideBounds((float *)(entityPtr + 0x50),(float *)&PTR_00c7cb5c),
     (char)puVar4 != '\0')) {
    pfVar1 = (float *)(entityPtr + 0x83c + *(int *)(&DAT_0086b580 + (int)PTR_00c7f294 * 4) * 0xc);
    local_c = (undefined *)
              (*(float *)(entityPtr + 0x844 + *(int *)(&DAT_0086b580 + (int)PTR_00c7f294 * 4) * 0xc)
              + *(float *)(entityPtr + 0x74));
    local_10 = (undefined *)(pfVar1[1] + *(float *)(entityPtr + 0x70));
    local_14 = (undefined *)(*pfVar1 + *(float *)(entityPtr + 0x6c));
    AddObjectToSpatialList(entityPtr,(float *)&local_14);
    uVar6 = *(uint *)(entityPtr + 0xe4);
    if (((uVar6 & 1) != 0) || (uVar6 == 0)) {
      uVar6 = 0;
    }
    for (; ((uVar6 & 1) == 0 && (uVar6 != 0));
        uVar6 = *(uint *)(*(int *)(entityPtr + 0xdc) + uVar6 + 4)) {
      iVar7 = *(int *)(uVar6 + 4);
      if ((*(char *)(iVar7 + 0xc) < '\0') &&
         ((*(int *)(iVar7 + 0x88) != 0 || (*(int *)(iVar7 + 0x174) != 0)))) {
        AddToSpatialGrid(iVar7);
      }
    }
  }
  uVar6 = 0;
  piVar5 = (int *)local_8;
  do {
    if ((void *)*piVar5 != (void *)0x0) {
      local_38 = (undefined *)0x0;
      local_34 = (undefined *)0x0;
      local_30 = (undefined *)0x0;
      local_2c = (undefined *)0x0;
      local_28 = (undefined *)0x0;
      local_24 = (undefined *)0x0;
      CopyChunkBounds((void *)*piVar5,&local_38);
      local_18 = (undefined *)((float)local_30 + (float)local_24);
      local_14 = (undefined *)(((float)local_2c + (float)local_38) * StaticFloat0_5);
      local_10 = (undefined *)(((float)local_34 + (float)local_28) * StaticFloat0_5);
      local_c = (undefined *)((float)local_18 * StaticFloat0_5);
      if ((((((float)local_38 < _DAT_00c7cb68 != ((float)local_38 == _DAT_00c7cb68)) &&
            ((float)local_34 < _DAT_00c7cb6c != ((float)local_34 == _DAT_00c7cb6c))) &&
           ((float)local_30 < _DAT_00c7cb70 != ((float)local_30 == _DAT_00c7cb70))) &&
          (((float)PTR_00c7cb5c <= (float)local_2c && (_DAT_00c7cb60 <= (float)local_28)))) &&
         (_DAT_00c7cb64 <= (float)local_24)) {
        AddToLayeredSpatialGrid(*piVar5,uVar6,(float *)&local_14);
      }
    }
    uVar6 = uVar6 + 1;
    piVar5 = piVar5 + 1;
  } while (uVar6 < 4);
  return;
}


