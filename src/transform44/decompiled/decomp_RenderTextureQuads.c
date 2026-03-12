
void __fastcall RenderTextureQuads(RenderBatch *param_1)

{
  int stateValue;
  int itemCount;
  void *pvVar1;
  int itemOffset;
  undefined *local_c;
  undefined *lastTexture;
  char *currentTexture;
  RenderItem *renderItems;
  
  itemCount = param_1->item_count;
  if (itemCount != 0) {
    lastTexture = (undefined *)0xffffffff;
    BeginRender();
    SetRenderState(0xe,0);
    SetRenderState(0xf,0);
    SetRenderState(0x10,0);
    SetRenderState(0x12,0);
    if (itemCount != 0) {
      itemOffset = 0;
      do {
        renderItems = param_1->items_ptr;
        currentTexture = *(char **)((int)&renderItems->texture + itemOffset);
        if (currentTexture != lastTexture) {
          SetTexture(0x17,currentTexture);
          lastTexture = currentTexture;
        }
        if (((*(int *)((int)&renderItems->additionalData + itemOffset) != 0) &&
            (stateValue = 2, *(int *)((int)&renderItems->renderState + itemOffset) < 2)) ||
           (stateValue = *(int *)((int)&renderItems->renderState + itemOffset), stateValue != 0xb))
        {
          SetRenderState(7,stateValue);
        }
        SetTexture(0x3f,*(char **)((int)&renderItems->secondaryTexture + itemOffset));
        InitializeRenderingPipeline
                  (4,*(undefined ***)((int)&renderItems->vertices + itemOffset),0xc,
                   (undefined **)&g_defaultTexCoord_U1,0,
                   *(undefined ***)((int)&renderItems->additionalData + itemOffset),
                   *(int *)((int)&renderItems->dataStride + itemOffset),(undefined *)0x0,
                   (undefined *)0x0,*(undefined ***)((int)&renderItems->textureCoords + itemOffset),
                   8,(undefined **)0x0,0);
        RenderVertexBuffer((undefined *)0x4,4,&g_quadVertexIndices);
        EmptyRenderFunction();
        itemOffset = itemOffset + 0x1c;
        itemCount = itemCount + -1;
      } while (itemCount != 0);
    }
    EndRender();
  }
  if (param_1->text_data != (void *)0x0) {
    DrawString((int)param_1->text_data);
  }
  pvVar1 = param_1->callback_list;
  if ((((uint)pvVar1 & 1) != 0) || (pvVar1 == (void *)0x0)) {
    pvVar1 = (void *)0x0;
  }
  for (; (((uint)pvVar1 & 1) == 0 && (pvVar1 != (void *)0x0)); pvVar1 = *(void **)((int)pvVar1 + 4))
  {
    (**(code **)((int)pvVar1 + 8))();
  }
  return;
}

