
int __thiscall getIndexOffset(void *this,int param_1)

{
  return *(int *)((int)this + 4) + param_1 * 2;
}

