// RTQ (RenderTextureQuads) full rendering pipeline
// All functions in the per-item draw call chain
//
// Call chain per item:
//   RenderTextureQuads (0x76FB00) -- the outer loop
//     -> InitializeRenderingPipeline (0x58A2A0) -- stores vertCount, calls RenderComplexGeometry
//       -> RenderComplexGeometry (0x58A3D0) -- format detect, VB create/fill, DrawPrimitive
//         -> CreateVertexBuffer (0x58A140 -> 0x594500) -- pool VB allocation
//         -> LockVertexBuffer (0x58A080) -- vtable call to CGxDevice+0xA8
//         -> [per-vertex interleave loop]
//         -> UnlockVertexBuffer (0x58A0A0) -- vtable call to CGxDevice+0xAC
//         -> DrawPrimitive (0x58A7C0) -- state update + SetRenderingCommand
//     -> RenderVertexBuffer (0x58A2E0) -- creates INDEX VB, issues DrawIndexedPrimitive
//       -> CreateAndBindVertexBuffer (0x58A750) -- index VB (bufferType=1)
//       -> CallGfxDeviceMethod_Wrapper (0x58A830) -- actual D3D9 DrawIndexedPrimitive
//     -> EmptyRenderFunction (0x58A340) -- RET (no-op)

// === InitializeRenderingPipeline (0x58A2A0) -- 54 bytes ===
// __fastcall(ECX=vertCount, EDX=xyzPtr, 11 stack params)
// Stores vertCount to global g_currentPrimitiveType and tail-calls RenderComplexGeometry.
void __fastcall InitializeRenderingPipeline(int vertCount, void** xyzPtr, /* ...11 stack params */)
{
    g_currentPrimitiveType = (void*)vertCount;  // stored at some global
    RenderComplexGeometry(vertCount, xyzPtr, /* forward all params */);
}

// === CreateVertexBuffer wrapper (0x58A140) -- 24 bytes ===
// __fastcall(ECX=bufferType, EDX=vertexSize, stack: vertexCount)
// Thin wrapper: loads CGxDevice from global, calls D3D_CreateVertexBuffer.
void __fastcall CreateVertexBuffer(int bufferType, int vertexSize, int vertexCount)
{
    D3D_CreateVertexBuffer(CGxDeviceD3d__device, bufferType, vertexSize, vertexCount);
}

// === D3D_CreateVertexBuffer (0x594500) -- 75 bytes ===
// __thiscall(ECX=CGxDevice, stack: bufferType, vertexSize, vertexCount)
// Returns a pool handle. The pool is indexed by bufferType at CGxDevice+0x26CC.
// Reuses existing D3D9 VB unless the requested size exceeds current allocation.
int __thiscall D3D_CreateVertexBuffer(void* this, int bufferType, int vertexSize, int vertexCount)
{
    int poolHandle = *(int*)((int)this + bufferType * 4 + 0x26CC);
    int d3dVB = *(int*)(poolHandle + 8);
    if (d3dVB != 0 && *(uint*)(d3dVB + 0x10) < (uint)(vertexSize * vertexCount)) {
        // Existing VB too small -- resize via vtable call
        (*(code**)(*this + 0xA0))(d3dVB, vertexSize * vertexCount);
    }
    SetDimensionsAndSize(poolHandle, vertexSize, vertexCount);
    return poolHandle;
}

// === SetDimensionsAndSize (0x5946F0) -- 32 bytes ===
void SetDimensionsAndSize(int handle, int vertexSize, int vertexCount)
{
    *(int*)(handle + 0x0C) = vertexSize;
    *(int*)(handle + 0x10) = vertexCount;
    *(int*)(handle + 0x14) = vertexSize * vertexCount;
    *(char*)(handle + 0x1C) = 0;  // clear dirty flag
}

// === LockVertexBuffer (0x58A080) -- 18 bytes ===
// __fastcall(ECX=poolHandle)
// Calls CGxDevice vtable[0xA8/4 = 42] to lock the D3D9 VB.
// Returns pointer to locked VB memory.
void* __fastcall LockVertexBuffer(void* poolHandle)
{
    return (*(code**)(*(int*)CGxDeviceD3d__device + 0xA8))(poolHandle);
}

// === UnlockVertexBuffer (0x58A0A0) -- 27 bytes ===
// __fastcall(ECX=poolHandle, EDX=byteCount)
// Calls CGxDevice vtable[0xAC/4 = 43] to unlock, then marks pool handle active.
void __fastcall UnlockVertexBuffer(int poolHandle, int byteCount)
{
    (*(code**)(*(int*)CGxDeviceD3d__device + 0xAC))(poolHandle, byteCount);
    SetObjectActiveFlag(poolHandle);
}

// === UpdateBufferData (0x58A0C0) -- 57 bytes ===
// __fastcall(ECX=poolHandle, EDX=srcData, stack: byteCount, unused)
// Used by CreateAndBindVertexBuffer for INDEX buffer filling.
// If byteCount==0, auto-computes from handle's vertexSize*vertexCount.
void __fastcall UpdateBufferData(int poolHandle, void* srcData, int byteCount, void* unused)
{
    if (byteCount == 0) {
        byteCount = *(int*)(poolHandle + 0x10) * *(int*)(poolHandle + 0x0C);
    }
    (*(code**)(*(int*)CGxDeviceD3d__device + 0xB0))(poolHandle, srcData, byteCount, unused);
    SetObjectActiveFlag(poolHandle);
}

// === DrawPrimitive / GxDevice dispatch (0x58A7C0) -- 54 bytes ===
// __fastcall(ECX=poolHandle, EDX=formatCode)
// Reads per-format state from table at 0x809C00 (16 bytes per entry):
//   +0x00: ptr to state array (GxDevice render state descriptors)
//   +0x04: state array element count
//   +0x08: primitive type mapping
//   +0x0C: dirty flags bitmask
// Applies state, marks dirty, stores draw command in CGxDevice for D3D9 submission.
void __fastcall DrawPrimitive(int poolHandle, int formatCode)
{
    int* stateTable = (int*)(0x809C00 + formatCode * 0x10);
    UpdateGfxStateArray(poolHandle, stateTable[0], stateTable[1]);
    MarkStateDirty(stateTable[3]);
    SetRenderingCommand(CGxDeviceD3d__device, poolHandle, formatCode);
}

// === SetRenderingCommand (0x592AA0) -- 40 bytes ===
// __thiscall(ECX=CGxDevice, stack: poolHandle, formatCode)
// Stores the draw command into CGxDevice for later D3D9 submission.
void __thiscall SetRenderingCommand(void* this, void* poolHandle, int formatCode)
{
    *(int*)((int)this + 0x27E0) = formatCode;
    *(void**)((int)this + 0x27E4) = poolHandle;
    *(int*)((int)this + 0x27E8) = *(int*)(0x809C08 + formatCode * 0x10);
}

// === RenderVertexBuffer (0x58A2E0) -- 82 bytes ===
// __fastcall(ECX=primType, EDX=vertCount, stack: indexPtr)
// Creates index VB (bufferType=1), binds it, issues DrawIndexedPrimitive.
void __fastcall RenderVertexBuffer(int primType, int vertCount, void* indexPtr)
{
    if (g_currentPrimitiveType != NULL) {
        CreateAndBindVertexBuffer(vertCount, indexPtr);  // index VB
        short adjustedPrimType = (short)g_currentPrimitiveType - 1;
        // Build draw call struct on stack
        struct { void* primPtr; void* unused; short vertCount; short flags; } call;
        call.primPtr = primType;
        call.unused = NULL;
        call.vertCount = vertCount;
        call.flags = 0;
        CallGfxDeviceMethod_Wrapper(&call, 1);  // -> D3D9 DrawIndexedPrimitive
    }
}

// === CreateAndBindVertexBuffer (0x58A750) -- 44 bytes ===
// __fastcall(ECX=vertCount, EDX=dataPtr)
// Used for INDEX buffer (bufferType=1, vertexSize=2 = sizeof(u16)).
void __fastcall CreateAndBindVertexBuffer(int vertCount, void* dataPtr)
{
    int handle = CreateVertexBuffer(1, 2, vertCount);  // pool slot 1, 2 bytes/index
    UpdateBufferData(handle, dataPtr, 0, NULL);
    SetStreamSource(handle);  // bind as index stream
}

// === Vertex format tables (from game memory) ===
//
// Stride table at 0x85A7A8 (indexed by format code):
//   fmt  0: stride=12   xyz only
//   fmt  1: stride=24   xyz + defaultTC
//   fmt  2: stride=28   xyz + defaultTC + additional(4)
//   fmt  3: stride=32   xyz + defaultTC + texcoord1(8)
//   fmt  4: stride=36   xyz + defaultTC + additional(4) + texcoord1(8)
//   fmt  5: stride=40   xyz + defaultTC + texcoord1(8) + texcoord2(8)
//   fmt  6: stride=44   xyz + defaultTC + additional(4) + texcoord1(8) + texcoord2(8)
//   fmt  7: stride=16   xyz + additional(4)
//   fmt  8: stride=24   xyz + additional(4) + texcoord1(8)
//   fmt  9: stride=32   xyz + additional(4) + texcoord1(8) + texcoord2(8)
//   fmt 10: stride=20   xyz + texcoord1(8)
//   fmt 11: stride=28   xyz + texcoord1(8) + texcoord2(8)
//
// Element offset table at 0x8097A8 (indexed by format*13 + element):
//   Element 0 = xyz position (always at offset 0)
//   Element 3 = defaultTexCoord
//   Element 4 = additionalData (color)
//   Element 5 = texcoord1
//   Element 6 = texcoord2
//   Value -1 = element not present in this format
