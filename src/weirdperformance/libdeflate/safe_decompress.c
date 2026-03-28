/* Wraps libdeflate_deflate_decompress with SEH to catch access violations.
 * libdeflate's fast path on 32-bit can crash on malformed input despite
 * SAFETY_CHECKs. This wrapper catches the crash and returns an error code. */

#include "libdeflate.h"

#ifdef _WIN32
#include <windows.h>

__declspec(dllexport) int safe_deflate_decompress(
    struct libdeflate_decompressor *d,
    const void *in, size_t in_nbytes,
    void *out, size_t out_nbytes_avail,
    size_t *actual_out_nbytes_ret)
{
    int result;
    __try {
        result = libdeflate_deflate_decompress(d, in, in_nbytes,
            out, out_nbytes_avail, actual_out_nbytes_ret);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        result = 1; /* LIBDEFLATE_BAD_DATA */
    }
    return result;
}
#endif
