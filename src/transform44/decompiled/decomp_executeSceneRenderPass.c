
undefined * CM2Scene_ExecuteRenderPass(int renderPassIndex)

{
  int renderer;
  int iVar1;
  undefined1 unaff_BP;
  undefined4 *puVar2;
  undefined1 renderContext [352];
  undefined callbackBuffer [12768];
  undefined4 uStackY_20;
  
  StackProbe(unaff_BP);
  if (*(int *)(renderer + 0x148) != *(int *)(*(int *)(renderer + 4) + 8)) {
    puVar2 = (undefined4 *)(renderer + 0x14c);
    for (iVar1 = 0x708; iVar1 != 0; iVar1 = iVar1 + -1) {
      *puVar2 = 0xffffffff;
      puVar2 = puVar2 + 1;
    }
    *(undefined4 *)(renderer + 0x148) = *(undefined4 *)(*(int *)(renderer + 4) + 8);
  }
  initializeRenderContext(renderContext,renderer);
  uStackY_20 = 0x70896e;
  CM2SceneRenderDraw(renderContext,(undefined *)renderPassIndex,*(int *)(renderer + 0x34),
                     *(int *)(renderPassIndex * 0x10 + 0x54 + renderer),
                     *(uint *)((renderPassIndex + 5) * 0x10 + renderer));
  if (renderPassIndex == 0) {
    uStackY_20 = 0x70898a;
    CM2SceneRenderDraw(renderContext,(undefined *)0x0,*(int *)(renderer + 0x34),
                       *(int *)(renderer + 0x44),*(uint *)(renderer + 0x40));
  }
  uStackY_20 = 0x70899f;
  CallbackIteratorDuplicate(callbackBuffer,&DAT_00000010,4,&DAT_0070dbf0);
  return (undefined *)0x1;
}

