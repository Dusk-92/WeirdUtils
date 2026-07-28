// RenderComplexGeometry (0x58A3D0) -- 886 bytes
// __fastcall(ECX=vertCount, EDX=xyzPtr, 11 stack params)
//
// Called from InitializeRenderingPipeline (0x58A2A0) which just stores
// vertCount to global [0xC0ED2C] then tail-calls this function.
//
// Purpose: Determine vertex format from which input pointers are non-null,
// create/reuse a pool VB, lock it, interleave all input arrays into the VB
// at the computed stride, unlock, then issue a DrawPrimitive.
//
// Parameters (after fastcall mapping):
//   param_1  = vertCount (ECX)
//   param_2  = xyzPtr (EDX) -- 3 floats per vert, stride in param_3
//   param_3  = xyzStride (stack) -- typically 0x0C (12 bytes)
//   param_4  = defaultTexCoordPtr (stack) -- game constant at 0xCF4CF4, 3 floats/vert
//   param_5  = defaultTexCoordStride (stack) -- 0 means use param_4 as single value
//   param_6  = additionalDataPtr (stack) -- per-vert color (DWORD), or NULL
//   param_7  = additionalDataStride (stack)
//   param_8  = texCoord1Ptr (stack) -- unused in RTQ path
//   param_9  = texCoord1Stride (stack)
//   param_10 = texCoord2Ptr (stack) -- UV coords, 2 floats/vert
//   param_11 = texCoord2Stride (stack) -- typically 8
//
// Vertex format table:
//   Format codes 0-11, determined by which of param_4/6/8/10 are non-null.
//   Stride table at 0x85A7A8: [12,24,28,32,36,40,44,16,24,32,20,28]
//   Element offset table at 0x8097A8: indexed by (format*13 + element)*4
//   Elements: 0=xyz, 3=defaultTC, 4=additional, 5=texcoord1, 6=texcoord2
//
// For RTQ with additionalData (format 4, stride 36):
//   [0-11]  xyz (12 bytes, 3 floats)
//   [12-23] defaultTC (12 bytes, 3 floats from 0xCF4CF4)
//   [24-27] additional (4 bytes, DWORD color)
//   [28-35] texcoord2 (8 bytes, 2 floats UV)
//
// For RTQ without additionalData (format 1, stride 24):
//   [0-11]  xyz (12 bytes)
//   [12-23] defaultTC (12 bytes)
//
// Per-vertex loop:
//   1. Copy xyz (3 dwords) at element offset 0
//   2. Copy defaultTC (3 dwords) at element offset 3 (12 bytes)
//   3. Check lighting flag at CGxDevice+0x258:
//      - If flag == 1: byte-swap color (BGRA -> RGBA or similar)
//      - Else: copy color as-is
//   4. Copy additional data (1 dword) at element offset 4
//   5. Copy texcoord1 (2 dwords) at element offset 5
//   6. Copy texcoord2 (2 dwords) at element offset 6
//   Each pointer advances by its respective stride per vertex.
//   VB write pointer advances by the interleaved stride per vertex.
//
// After loop: UnlockVertexBuffer, then DrawPrimitive(poolHandle, formatCode)
//
// DrawPrimitive (0x58A7C0):
//   Reads from a per-format-code table at 0x809C00 (stride 0x10):
//     +0x00: state array ptr
//     +0x04: state array count
//     +0x08: D3D primitive type table index
//     +0x0C: dirty flags mask
//   Calls UpdateGfxStateArray to apply GxDevice state changes,
//   then MarkStateDirty, then SetRenderingCommand which stores
//   the draw command into CGxDevice+0x27E0..0x27E8 for later
//   submission to D3D9.
//
// Pool VB system (D3D_CreateVertexBuffer at 0x594500):
//   CGxDevice has pool slots at +0x26CC indexed by bufferType.
//   RenderComplexGeometry uses bufferType=0.
//   Pool handle struct:
//     +0x08: D3D9 IDirect3DVertexBuffer9*
//     +0x0C: vertexSize (bytes per vertex for this format)
//     +0x10: vertexCount
//     +0x14: total bytes (vertexSize * vertexCount)
//     +0x1C: dirty flag (cleared by SetDimensionsAndSize)
//   The pool VB is reused across calls. Only recreated if the
//   requested size (vertexSize * vertexCount) exceeds the current
//   allocation at +0x14. This means no D3D9 CreateVertexBuffer
//   overhead on normal frames.
//
// RenderVertexBuffer (0x58A2E0):
//   Called AFTER RenderComplexGeometry returns. Uses a DIFFERENT pool
//   (bufferType=1) for index data. Creates/binds an index VB with
//   the quad indices {0,1,2,0,2,3}, then calls DrawIndexedPrimitive
//   via CallGfxDeviceMethod_Wrapper.

void __fastcall
RenderComplexGeometry(
    int vertCount,          // ECX
    void** xyzPtr,          // EDX
    int xyzStride,          // [ebp+0x08]
    void** defaultTCPtr,    // [ebp+0x0C]
    int defaultTCStride,    // [ebp+0x10]
    void** additionalPtr,   // [ebp+0x14]
    int additionalStride,   // [ebp+0x18]
    void** texCoord1Ptr,    // [ebp+0x1C]
    int texCoord1Stride,    // [ebp+0x20]
    void** texCoord2Ptr,    // [ebp+0x24]
    int texCoord2Stride)    // [ebp+0x28]
{
    // Step 1: Format detection -- determine which of the 12 interleaved
    // vertex formats to use based on which input pointers are non-null.
    int formatCode = 1; // default: xyz + defaultTC
    // Complex nested-if tree mapping (defaultTC, additional, tc1, tc2)
    // presence to format codes 0-11. See format table above.

    // Step 2: Get stride and allocate pool VB
    int stride = GetDataPointerByIndex(formatCode);  // stride table lookup
    void* poolHandle = CreateVertexBuffer(0, stride, vertCount);
    char* vbData = LockVertexBuffer(poolHandle);

    // Step 3: Compute write pointers for each element within the VB
    char* xyzDst  = vbData + GetMatrixElementPointer(formatCode, 0);
    char* tcDst   = (defaultTCPtr)  ? vbData + GetMatrixElementPointer(formatCode, 3) : &dummy;
    char* addDst  = (additionalPtr) ? vbData + GetMatrixElementPointer(formatCode, 4) : &dummy;
    char* tc1Dst  = (texCoord1Ptr)  ? vbData + GetMatrixElementPointer(formatCode, 5) : &dummy;
    char* tc2Dst  = (texCoord2Ptr)  ? vbData + GetMatrixElementPointer(formatCode, 6) : &dummy;

    // Per-element advance: stride if present, 0 if writing to dummy
    int tcAdv  = defaultTCPtr  ? stride : 0;
    int addAdv = additionalPtr ? stride : 0;
    int tc1Adv = texCoord1Ptr  ? stride : 0;
    int tc2Adv = texCoord2Ptr  ? stride : 0;

    // Step 4: Per-vertex interleave loop
    for (int v = 0; v < vertCount; v++) {
        // XYZ: always 12 bytes (3 floats)
        *(int*)(xyzDst + 0) = *(int*)(xyzPtr + 0);
        *(int*)(xyzDst + 4) = *(int*)(xyzPtr + 4);
        *(int*)(xyzDst + 8) = *(int*)(xyzPtr + 8);
        xyzDst += stride;
        xyzPtr += xyzStride;

        // DefaultTC: 12 bytes (3 floats)
        *(int*)(tcDst + 0) = *(int*)(defaultTCPtr + 0);
        *(int*)(tcDst + 4) = *(int*)(defaultTCPtr + 4);
        *(int*)(tcDst + 8) = *(int*)(defaultTCPtr + 8);
        tcDst += tcAdv;
        defaultTCPtr += defaultTCStride;

        // Additional (color): conditional byte-swap based on lighting flag
        int lightingInfo = UpdateLightingOffset(); // returns CGxDevice + 0x23C
        if (*(int*)(lightingInfo + 0x1C) == 1) {
            // Byte swap: BGRA -> RGBA (swap bytes 0 and 2)
            *(int*)(addDst) = CONCAT(byte3, byte0, byte1, byte2);
        } else {
            *(int*)(addDst) = *(int*)(additionalPtr);
        }
        addDst += addAdv;
        additionalPtr += additionalStride;

        // TexCoord1: 8 bytes (2 floats)
        *(int*)(tc1Dst + 0) = *(int*)(texCoord1Ptr + 0);
        *(int*)(tc1Dst + 4) = *(int*)(texCoord1Ptr + 4);
        tc1Dst += tc1Adv;
        texCoord1Ptr += texCoord1Stride;

        // TexCoord2: 8 bytes (2 floats)
        *(int*)(tc2Dst + 0) = *(int*)(texCoord2Ptr + 0);
        *(int*)(tc2Dst + 4) = *(int*)(texCoord2Ptr + 4);
        tc2Dst += tc2Adv;
        texCoord2Ptr += texCoord2Stride;
    }

    // Step 5: Finalize
    UnlockVertexBuffer(poolHandle, stride * vertCount);
    DrawPrimitive(poolHandle, formatCode);
}
