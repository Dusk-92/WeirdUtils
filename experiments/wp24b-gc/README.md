# WeirdPerformance 2.4-B — GC Safe Sweep test

Strict A/B experiment for WoW 1.12.1 build 5875.

## Baseline

Keep the validated 2.4-A binary **unchanged**:

- `weirdperformance.dll`
- SHA-256: `d35168ae06c19087ef9b7c68918a054640396dfbfcef0664e18e9372284b5eef`

## B variant

Add:

- `weirdperformance_gc24b.dll`

The companion changes **only Lua GC behavior**. It does not replace or rebuild the validated 2.4-A DLL.

The implementation is based on the historical pre-generational incremental sweep: WoW keeps its native mark, userdata/string sweep, memory shrink and finalizers. Only the main `rootgc` sweep is split into 50,000-object chunks.

## Safety changes versus the old experiment

- hooks only `luaC_collectgarbage` and `lua_close`;
- no overlap with the lifecycle hooks referenced by the validated 2.4-A binary;
- any fragmented sweep is reconnected before native `lua_close` destroys the Lua state;
- GC calls made from inside `lua_close` stay native;
- the birth-mark byte is ownership checked and restored only while still owned;
- a changed Lua `global_State` forces native fallback rather than reconnecting stale pointers;
- hook installation is transactional;
- no generational age bitmap, no write barriers, no GC tuning, no profiling/RDTSC.

## Installation for the test

Keep both DLLs next to WoW and list both in `dlls.txt`:

```text
weirdperformance.dll
weirdperformance_gc24b.dll
```

Removing `weirdperformance_gc24b.dll` returns you exactly to the validated 2.4-A baseline.
