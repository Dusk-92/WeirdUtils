# libdeflate Integration Research

## Findings

### WoW Compression Types

Dispatch table at `.rdata` 0x80FA1C, 6 entries (mask, function_ptr):

| Bit | Mask | Address    | Function                          | Type           |
|-----|------|------------|-----------------------------------|----------------|
| 0   | 0x01 | 0x661350   | ProcessCompressionContext         | Huffman/sparse |
| 1   | 0x02 | 0x660800   | Compression_TryDecompress         | **zlib**       |
| 4   | 0x10 | 0x660C10   | BZip2Decompressor_TryDecompress   | bzip2          |
| 5   | 0x20 | 0x660AC0   | PKWare_DecompressData             | PKWare DCL     |
| 6   | 0x40 | 0x660F60   | AudioCodec_DecompressMonoSamples  | ADPCM mono     |
| 7   | 0x80 | 0x6611E0   | AudioCodec_DecompressStereoSamples| ADPCM stereo   |

Type byte is a bitmask — multiple bits can be set for chained compression.
In practice, **100% of observed calls use type 0x02 (pure zlib, no chaining)**.

### Data Format

```
[type_byte=0x02] [zlib_stream: 78 9C ...]
```

Standard zlib header `78 9C` = deflate method, 32K window, default compression.

### Volume (observed during gameplay)

- Loading: 93K calls, 170MB compressed → 380MB decompressed in 2.9s
- Gameplay: ~4-5K calls per 7.5s dump period

### Function Signatures (assembly-verified)

```
DecompressData_WithOptions (0x661A80):
  __stdcall(outBuf, &outSize, inBuf, inSize_VALUE, flags) RET 0x14
  Note: param4 is a VALUE not a pointer. param2 is a POINTER to size.
  The function modifies *param2 to reflect actual decompressed size.

Compression_TryDecompress (0x660800):
  __fastcall(ECX=outBuf, EDX=&outSize, stack=compSize, flags) RET 0x0C

BZip2Decompressor_Decompress (0x660740):
  __stdcall(inBuf, &outSize, &uncompSize, flags) RET 0x10

FreeMemory (0x646430):
  __stdcall(ptr, filename, line, flags) RET 0x10  ← 4 params NOT 3!

ReallocMemory (0x646320):
  __stdcall(ptr, size, filename, line, flags) RET 0x14
  When ptr=NULL, acts as malloc via AllocateBufferWithPowerOfTwo.
```

### libdeflate Status

- **Compiled**: static lib, x86-windows-gnu target, linked into msvc DLL
- **Sanity test PASSES**: decompresses "hello" correctly
- **CPU features**: 0x8000001F = SSE2 + SSSE3 + SSE4.1 + BMI1 + BMI2 (all valid under Wine)
- **AVX-512 disabled** at compile time (not available on 32-bit x86)

### Critical Bug Found

The original `DecompressData_WithOptions` **modifies the input buffer** during
decompression (overlap handling copies data around). When our hook calls the
original first then tries to run libdeflate on the same input, the data has
been corrupted. Fix: save input data before calling original.

### Other Bugs Found During Integration

1. **FreeMemory param count**: RET 0x10 = 4 params, was declared with 3 → stack corruption
2. **Stack overflow**: 64KB stack buffer for output → replaced with heap/static allocation
3. **param4 is VALUE not pointer**: `inSize` is passed by value, not `&inSize`

### Hook Architecture

```
DecompressData_WithOptions hook:
  1. Save input buffer (original modifies it)
  2. Call original → time it
  3. If type==0x02 (pure zlib):
     a. Run libdeflate_zlib_decompress on saved input
     b. Time it, compare results
  4. Return original's result
```

### Next Steps

- Test with saved input buffer fix
- If timing comparison works, implement replacement mode (skip original, use libdeflate only)
- Expected speedup: ~2x based on libdeflate benchmarks (generic C path on 32-bit)
