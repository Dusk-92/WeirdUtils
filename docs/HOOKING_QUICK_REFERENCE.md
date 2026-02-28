# Hooking Quick Reference Guide

## 🚨 Critical Rules (Break These = Crash)

### 1. NEVER Use PUSHA/POPA Around C Function Calls
```asm
; ❌ WRONG - Will crash
pusha
call _MyCFunction    ; This modifies EAX/ECX/EDX
popa                 ; This RESTORES old values, breaking everything

; ✅ RIGHT - Only save non-volatile registers
pushl %ebx
pushl %esi
pushl %edi
call _MyCFunction    ; EAX/ECX/EDX flow through naturally
popl %edi
popl %esi
popl %ebx
```

### 2. Match the Calling Convention
```cpp
// __thiscall: ECX = this pointer, stack args, callee cleans
// Hook as __fastcall with dummy EDX:
typedef void (__fastcall *Func_t)(void* thisPtr, void* edx, int arg);

static void __fastcall MyHook(void* thisPtr, void* edx, int arg) {
    // thisPtr from ECX ✅
    // edx is trash ✅
    // arg from stack ✅
}
```

### 3. Steal Complete Instructions Only
```cpp
// ❌ WRONG
#define STOLEN_BYTES 6  // No idea if this splits an instruction

// ✅ RIGHT
// Disassemble: PUSH EBP (1) + MOV EBP,ESP (2) + SUB ESP,0x80 (6) = 9 bytes
#define STOLEN_BYTES 9  // Documented complete instructions
```

### 4. Fix Relative Jumps in Stolen Bytes
```cpp
// If stolen bytes contain:
// JMP rel8/rel32
// CALL rel32
// JE/JNE/JZ/etc rel8/rel32
// Then you MUST relocate them in the trampoline
// Or use a hooking library that does this automatically
```

---

## 📋 Register Preservation Cheat Sheet

| Register | Type | Who Saves It? | Can Hook Modify? |
|----------|------|---------------|------------------|
| EAX | Volatile | Caller | YES - return value |
| ECX | Volatile | Caller | YES - but preserve for __thiscall |
| EDX | Volatile | Caller | YES - but preserve for __fastcall |
| EBX | Non-volatile | Callee | NO - must preserve |
| ESI | Non-volatile | Callee | NO - must preserve |
| EDI | Non-volatile | Callee | NO - must preserve |
| EBP | Non-volatile | Callee | NO - must preserve |
| ESP | Stack pointer | Callee | NO - must balance |

---

## 🎯 Calling Convention Quick Reference

### __stdcall (WINAPI)
- Args: stack (right to left)
- Cleanup: callee pops args
- Example: `BeginScene(device)` → `push device; call BeginScene` (BeginScene pops)

### __cdecl (C default)
- Args: stack (right to left)
- Cleanup: caller pops args
- Example: `printf(fmt, arg)` → `push arg; push fmt; call printf; add esp, 8`

### __fastcall
- Args: ECX, EDX, then stack
- Cleanup: callee pops stack args
- Example: `func(a, b, c)` → `mov ecx, a; mov edx, b; push c; call func`

### __thiscall (C++ methods)
- Args: ECX = this, stack = args
- Cleanup: callee pops args
- Hook trick: Use __fastcall with dummy EDX

---

## 🔧 Safe Hook Templates

### Template 1: VTable Hook (Safest)
```cpp
// For D3D9, COM objects, etc.
typedef HRESULT (WINAPI *EndScene_t)(IDirect3DDevice9*);
static EndScene_t g_original = nullptr;

static HRESULT WINAPI MyHook(IDirect3DDevice9* device) {
    // Your code here
    return g_original(device);
}

// Install:
void** vtable = *(void***)device;
g_original = (EndScene_t)vtable[42];
VirtualProtect(&vtable[42], 4, PAGE_EXECUTE_READWRITE, &old);
vtable[42] = (void*)MyHook;
VirtualProtect(&vtable[42], 4, old, &old);
```

### Template 2: Inline Hook for __thiscall
```cpp
// Handler: uses __stdcall (or __cdecl)
static void __stdcall MyHandler(void* thisPtr, int arg) {
    // Your logic
}

// Naked wrapper: handles calling convention
__attribute__((naked)) static void NakedHook() {
    __asm__ __volatile__ (
        "pushl %%ecx\n"           // Save ECX (this)
        "pushl 0x04(%%esp)\n"     // Push arg
        "pushl %%ecx\n"           // Push this
        "call %P0\n"              // Call handler (__stdcall cleans up)
        "popl %%ecx\n"            // Restore ECX
        "jmp *%1\n"               // Execute stolen bytes + return
        :
        : "i" (MyHandler), "m" (g_trampoline)
        : "memory"
    );
}
```

### Template 3: Inline Hook for __fastcall
```cpp
// Handler: matches __fastcall
static void __fastcall MyHandler(void* ecx_arg, void* edx_arg, int stack_arg) {
    // Your logic
}

__attribute__((naked)) static void NakedHook() {
    __asm__ __volatile__ (
        "pushl %%ecx\n"           // Save ECX
        "pushl %%edx\n"           // Save EDX
        "pushl 0x08(%%esp)\n"     // Push stack arg
        "pushl %%edx\n"           // Push EDX arg
        "pushl %%ecx\n"           // Push ECX arg
        "call %P0\n"              // Call handler
        "addl $12, %%esp\n"       // Clean up (3 args * 4 bytes)
        "popl %%edx\n"            // Restore EDX
        "popl %%ecx\n"            // Restore ECX
        "jmp *%1\n"
        :
        : "i" (MyHandler), "m" (g_trampoline)
        : "memory"
    );
}
```

---

## 🛡️ Safety Checklist

### Before Installing Hook:
- [ ] Disassemble target to verify prologue
- [ ] Calculate stolen bytes (complete instructions only)
- [ ] Check for relative jumps/calls in stolen bytes
- [ ] Identify calling convention
- [ ] Save original bytes for restoration

### In Hook Handler:
- [ ] Preserve non-volatile registers (EBX, ESI, EDI, EBP)
- [ ] Respect calling convention (ECX/EDX for __thiscall/__fastcall)
- [ ] NO C code in naked functions
- [ ] Validate pointers before dereferencing
- [ ] Use critical sections for shared data

### After Installing Hook:
- [ ] Test with and without hook
- [ ] Check for stack corruption (ESP should match)
- [ ] Verify return values are correct
- [ ] Test multi-threaded scenarios
- [ ] Add error logging for crashes

---

## 🐛 Common Crash Causes

1. **PUSHA/POPA with C calls** → Volatile register corruption
2. **Wrong calling convention** → ECX/EDX clobbered when needed
3. **Partial instruction theft** → Executing incomplete opcodes
4. **Stack misalignment** → ESP not 4-byte aligned before call
5. **Relative jump not fixed** → Jumping to wrong address
6. **TLS not initialized** → Dereferencing null __thread vars
7. **No pointer validation** → Reading invalid memory
8. **Race condition** → Hook fires during another hook

---

## 📚 Research Sources

- [How to Hook Functions - Guided Hacking](https://guidedhacking.com/threads/how-to-hook-functions-code-detouring-guide.14185/)
- [Thiscall Hooking - tresp4sser](https://tresp4sser.wordpress.com/2012/10/06/how-to-hook-thiscall-functions/)
- [X64 Function Hooking - Kyle Halladay](https://kylehalladay.com/blog/2020/11/13/Hooking-By-Example.html)
- [Inline Function Hooking - Securehat](https://blog.securehat.co.uk/process-injection/manually-implementing-inline-function-hooking)
- [Windows Inline Hooking - LRQA](https://www.lrqa.com/en/cyber-labs/windows-inline-function-hooking/)

---

## 💡 Key Insight

**Hooking is NOT about blindly copying bytes.**

It's about understanding:
- How the CPU uses registers (volatile vs non-volatile)
- How functions pass arguments (calling conventions)
- How instructions encode addresses (relative vs absolute)
- How threads share memory (synchronization)

Follow these templates, and your hooks won't crash.
