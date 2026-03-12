# SuperWoW Event Registration — Ghidra Analysis

Analysis of SuperWoWhook.dll

## CreateEvents Hook (0x100056c0)

1. Calls the original `FrameScript_CreateEvents` via its trampoline — this lets the
   engine (and any earlier hooks like nampower) build the internal event table normally.
2. After the original returns, checks if the count that was passed in was > 200 (0xC8).
   This distinguishes the main event table call (549 events) from the GlueXML call
   (~26 events at `0xB41E70`). If ≤ 200, it does nothing.
3. Reads the internal array pointer from `PTR_00ceef68` (the struct at `0xceef60` has
   `{count, capacity, array_ptr}` at offsets +0, +4, +8).
4. Calls `DuplicateStringWithAllocation` (0x64a620, stdcall) twice — once for
   `"UNIT_CASTEVENT"`, once for `"RAW_COMBATLOG"`. This allocates via `SMemAlloc` and
   copies the string, giving engine-owned memory that won't be freed unexpectedly.
5. Writes each allocated name pointer into the internal table at hardcoded offsets:
   `array + 0x2580` (slot 600 × 16 bytes) and `array + 0x2590` (slot 601 × 16 bytes).
   Each internal table entry is 16 bytes: `{name_ptr, 0, self_ptr, self_ptr|1}` — it
   only writes the name at +0.

## resize_lua_event_array Hook (0x10005710)

1. This is the function that reallocates the internal event table array. It's
   `__thiscall(ECX=0xceef60, stack=new_capacity)`.
2. SuperWoW intercepts every call. If the requested count is > 200 (again, skipping
   GlueXML), it overwrites the count argument with 700 (0x2BC) before calling the
   original.
3. This ensures the internal array is always large enough for slots 600-601, regardless
   of how many base events the engine requests.
4. `RET 0x4` — thiscall cleans the one stack parameter.

## Ordering

`resize_lua_event_array` is called internally by `FrameScript_CreateEvents` as it
processes entries and needs to grow the array. So the resize hook fires during the
original CreateEvents call, expanding capacity to 700 before the CreateEvents hook's
post-processing writes to slots 600/601. By the time SuperWoW writes its events, the
array is already large enough.

## What It Doesn't Do

It doesn't touch the input name array at all, doesn't modify `maxEventId`, and doesn't
fill unused entry fields beyond the name pointer. The engine only needs the name at +0
for `RegisterEvent`/`SignalEvent` lookups.

## Contrast with Nampower

Nampower overwrites entries in the **input name array** (the `ECX` parameter to
`FrameScript_CreateEvents`). The input array at `0xBE1198` has 549 string pointers.
Nampower hooks CreateEvents, bumps `maxEventId` from 549 to 551, and writes its event
names (`SPELL_DAMAGE_EVENT_SELF`, `SPELL_DAMAGE_EVENT_OTHER`) directly into the input
array at slots 549 and 550 (addresses `0xBE1A2C` and `0xBE1A30`). The function then
processes these as normal entries when building the internal table.

Problem: slot 550+ overlap with float globals in the `.data` section — `0xBE1A30` is
actually `float 0.25` (0x3E800000).

## Our Approach

Follows SuperWoW's pattern: post-CreateEvents write into the internal table at slot 650,
with a resize hook to ensure capacity ≥ 700. Compatible with both SuperWoW and nampower
in the hook chain.
