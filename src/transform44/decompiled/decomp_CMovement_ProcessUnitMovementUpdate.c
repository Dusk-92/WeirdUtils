
/* Setting prototype: void CMovement_ProcessUnitMovementUpdate(CMovement *this, ulong timeNow, ulong
   lastUpdate, CGUnit *unitObj) */

void __thiscall
CMovement__ProcessMovementWithCollisionAndServerValidation
          (void *this,ulong timeNow,ulong lastUpdate,CGUnit *unitObj)

{
  int *piVar1;
  undefined *objectManager;
  undefined *puVar2;
  uint uVar3;
  uint stepTime;
  int local_14;
  uint uStack_10;
  undefined *processedTime;
  undefined *deltaTime;
  
                    /* Main movement processing function - handles time-based movement updates,
                       collision detection, and position synchronization. Key offsets: +0x10-0x18
                       (position xyz), +0x1c (facing), +0x40 (movement flags), +0x15c (unit object
                       reference) */
  deltaTime = (undefined *)(timeNow - lastUpdate);
  processedTime = (undefined *)0x0;
  objectManager = GetObjectManagerField();
  if (deltaTime < (undefined *)0xfb) {
    if (deltaTime == (undefined *)0x0) goto LAB_00616789;
  }
  else {
    lastUpdate = (ulong)(deltaTime + -0xfa + lastUpdate);
    UpdatePlayerActionCounter(this,(int)(deltaTime + -0xfa));
    deltaTime = (undefined *)0xfa;
  }
  do {
    stepTime = (int)deltaTime - (int)processedTime;
    puVar2 = CheckNodeExistence((int)this + 0x150);
    if ((char)puVar2 != '\0') {
      uVar3 = ExtractNodeValue((int)this + 0x150);
      uVar3 = *(int *)(uVar3 + 8) - lastUpdate;
      if ((int)uVar3 < 0) {
        uVar3 = 0;
      }
      if (uVar3 < stepTime) {
        stepTime = uVar3;
      }
    }
    piVar1 = *(int **)(*(int *)((int)this + 0x15c) + 8);
    if (((((undefined *)*piVar1 == PTR_00c4da98) && ((undefined *)piVar1[1] == PTR_00c4da9c)) &&
        ((*(int *)((int)this + 0xa4) == 0 ||
         ((*(byte *)(*(int *)((int)this + 0xa4) + 0x18) & 4) != 0)))) &&
       (((*(uint *)((int)this + 0x40) & 0x200f) != 0 &&
        (*(int *)(objectManager + 0x130) - lastUpdate < stepTime)))) {
      stepTime = *(int *)(objectManager + 0x130) - lastUpdate;
    }
    lastUpdate = lastUpdate + stepTime;
    *(ulong *)(objectManager + 300) = lastUpdate;
    if (stepTime != 0) {
      if ((*(uint *)((int)this + 0x40) & 0x20ff) != 0) {
        ProcessPlayerMovementWithServerValidationAndInterpolation(this,(float)lastUpdate,stepTime);
        piVar1 = *(int **)((int)*(void **)((int)this + 0x15c) + 8);
        if (((((undefined *)*piVar1 == PTR_00c4da98) && ((undefined *)piVar1[1] == PTR_00c4da9c)) &&
            ((*(uint *)((int)this + 0x40) & 0x200f) != 0)) &&
           (((*(int *)((int)this + 0xa4) == 0 ||
             ((*(byte *)(*(int *)((int)this + 0xa4) + 0x18) & 4) != 0)) &&
            (-1 < (int)(lastUpdate - *(int *)(objectManager + 0x130)))))) {
          InitiatePlayerSpellCast
                    (*(void **)((int)this + 0x15c),lastUpdate,0xee,(void *)0x0,(void *)0x0);
        }
      }
      processedTime = processedTime + stepTime;
    }
    puVar2 = ProcessPlayerActionQueue(this,(void *)lastUpdate);
    if (puVar2 == (undefined *)0x0) {
      SetAudioChannelSimple30(this,1);
      break;
    }
  } while (processedTime < deltaTime);
LAB_00616789:
  ProcessUnitPositionAndProximity(*(void **)((int)this + 0x15c),(void *)timeNow,0);
  uStack_10 = (uint)((ulonglong)(double)*(float *)((int)this + 0x10) >> 0x20);
  local_14 = SUB84((double)*(float *)((int)this + 0x10),0);
  objectManager = IsInfiniteOrNaN(local_14,uStack_10);
  if (objectManager == (undefined *)0x0) {
    uStack_10 = (uint)((ulonglong)(double)*(float *)((int)this + 0x14) >> 0x20);
    local_14 = SUB84((double)*(float *)((int)this + 0x14),0);
    objectManager = IsInfiniteOrNaN(local_14,uStack_10);
    if (objectManager == (undefined *)0x0) {
      uStack_10 = (uint)((ulonglong)(double)*(float *)((int)this + 0x18) >> 0x20);
      local_14 = SUB84((double)*(float *)((int)this + 0x18),0);
      objectManager = IsInfiniteOrNaN(local_14,uStack_10);
      if (objectManager == (undefined *)0x0) {
        return;
      }
    }
  }
  RotateLogFile((byte *)s_Mover_at_invalid_position_008613fc);
  return;
}

