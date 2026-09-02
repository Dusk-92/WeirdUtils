# WeirdPerformance 2.4-B — GC Safe Sweep test

This is an A/B test companion for the validated WeirdPerformance 2.4-A DLL.

- `weirdperformance.dll` = unchanged 2.4-A baseline
- `weirdperformance_gc24b.dll` = only experimental delta: incremental Lua `rootgc` sweep

Load both DLLs. Do not replace the 2.4-A DLL with the companion.

WoW's native mark, userdata/string sweep, shrink, finalizers, and the 2.4-A hybrid allocator remain in place. Only the main rootgc sweep is split into 50,000-object chunks.

Restart safety enters native-GC passthrough before `CGGameUI_Shutdown`, reconnects any split list first, and re-enables the experiment only after `Player_LoadScriptFunctions`. The luaC_link birth-mark byte is ownership-checked; if it cannot be acquired, that cycle stays native.

Scope: WoW 1.12.1 build 5875 test only.
