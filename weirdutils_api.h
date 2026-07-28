/*
 * weirdutils_api.h - Runtime Module Control API for WeirdUtils
 *
 * Header-only, no .lib needed. Include this file and call the inline
 * wrappers; they resolve the DLL exports at runtime via GetModuleHandleA
 * and GetProcAddress. Returns 0 / no-ops if WeirdUtils is not loaded.
 *
 * Usage:
 *   #include "weirdutils_api.h"
 *
 *   if (WeirdUtils_IsModuleActive("transmogfix"))
 *       WeirdUtils_DisableModule("transmogfix");
 */

#ifndef WEIRDUTILS_API_H
#define WEIRDUTILS_API_H

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Function pointer typedefs ---- */

typedef int (__cdecl *WeirdUtils_IsModuleActiveFn)(const char *name);
typedef int (__cdecl *WeirdUtils_DisableModuleFn)(const char *name);
typedef int (__cdecl *WeirdUtils_DisableAllFn)(void);

/* ---- DLL auto-discovery ---- */

static const char *const WeirdUtils__DllNames[] = {
    "weirdutils.dll",
    "pngscreenshots.dll",
    "transmogfix.dll",
    "customassets.dll",
    "logsessions.dll",
    "healtextfix.dll",
    "bigcursor.dll",
    "minimapicons.dll",
    NULL
};

static FARPROC WeirdUtils__Resolve(const char *func_name) {
    int i;
    for (i = 0; WeirdUtils__DllNames[i] != NULL; ++i) {
        HMODULE hMod = GetModuleHandleA(WeirdUtils__DllNames[i]);
        if (hMod) {
            FARPROC proc = GetProcAddress(hMod, func_name);
            if (proc) return proc;
        }
    }
    return NULL;
}

/* ---- Inline wrappers (no-op if DLL not loaded) ---- */

static int WeirdUtils_IsModuleActive(const char *name) {
    WeirdUtils_IsModuleActiveFn fn = (WeirdUtils_IsModuleActiveFn)WeirdUtils__Resolve("WeirdUtils_IsModuleActive");
    return fn ? fn(name) : 0;
}

static int WeirdUtils_DisableModule(const char *name) {
    WeirdUtils_DisableModuleFn fn = (WeirdUtils_DisableModuleFn)WeirdUtils__Resolve("WeirdUtils_DisableModule");
    return fn ? fn(name) : 0;
}

static int WeirdUtils_DisableAll(void) {
    WeirdUtils_DisableAllFn fn = (WeirdUtils_DisableAllFn)WeirdUtils__Resolve("WeirdUtils_DisableAll");
    return fn ? fn() : 0;
}

#ifdef __cplusplus
}
#endif

#endif /* WEIRDUTILS_API_H */
