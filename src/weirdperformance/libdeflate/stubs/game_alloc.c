/* malloc/free stubs for libdeflate using the Windows process heap. */

#include <stddef.h>

__declspec(dllimport) void *__stdcall GetProcessHeap(void);
__declspec(dllimport) void *__stdcall HeapAlloc(void *hHeap, unsigned long dwFlags, size_t dwBytes);
__declspec(dllimport) int   __stdcall HeapFree(void *hHeap, unsigned long dwFlags, void *lpMem);

void *malloc(size_t size) {
    return HeapAlloc(GetProcessHeap(), 0, size);
}

void free(void *ptr) {
    if (ptr) HeapFree(GetProcessHeap(), 0, ptr);
}
