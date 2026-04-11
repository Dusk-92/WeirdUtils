-- AllocBench: Lua allocation benchmark
-- /allocbench to run, reports best-of-5 timing

local ITERATIONS = 100000

local function bench_strings()
    -- Short strings (interned), medium strings, concatenation
    local t = {}
    for i = 1, ITERATIONS do
        t[i] = "key" .. i
    end
    for i = 1, ITERATIONS do
        local s = t[i] .. "_suffix"
        t[i] = s
    end
    return t
end

local function bench_tables()
    -- Small tables, growing tables, nested tables
    local all = {}
    for i = 1, ITERATIONS do
        local t = {}
        t.name = "entry"
        t.value = i
        t.flag = true
        t.sub = { a = 1, b = 2, c = 3 }
        all[i] = t
    end
    return all
end

local function bench_mixed()
    -- Mixed: tables with string keys, numeric arrays, realloc via growth
    local result = {}
    for i = 1, ITERATIONS do
        local t = {}
        -- Grow array part: triggers realloc at 1, 2, 4, 8, 16...
        for j = 1, 20 do
            t[j] = j * 0.5
        end
        -- Grow hash part: triggers rehash
        t.alpha = "hello"
        t.beta = 42
        t.gamma = true
        t.delta = { i, i + 1, i + 2 }
        result[i] = t
    end
    return result
end

local function bench_table_hash()
    -- Pure hash table lookup/insert stress
    local big = {}
    for i = 1, ITERATIONS do
        big["key_" .. i] = i
    end
    local sum = 0
    for i = 1, ITERATIONS do
        sum = sum + big["key_" .. i]
    end
    return sum
end

local function bench_churn()
    -- Alloc/free churn: create and discard rapidly
    for i = 1, ITERATIONS do
        local t = { a = 1, b = "x", c = { 1, 2, 3 } }
        t = nil
    end
end

local function run_all()
    bench_strings()
    bench_tables()
    bench_mixed()
    bench_table_hash()
    bench_churn()
end

local function run_bench()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00AllocBench|r: running 5 iterations...")

    -- Warmup
    debugprofilestart()
    run_all()
    collectgarbage()

    local best = 999999999
    for trial = 1, 5 do
        collectgarbage()
        debugprofilestart()
        run_all()
        local elapsed = debugprofilestop()
        if elapsed < best then best = elapsed end
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  trial %d: %.1f ms", trial, elapsed))
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00AllocBench|r: best = |cffffd700%.1f ms|r (%d iterations per test)", best, ITERATIONS))
end

SLASH_ALLOCBENCH1 = "/allocbench"
SlashCmdList["ALLOCBENCH"] = run_bench

-- =========================================================================
-- /gccompare: time a forced full GC cycle.
-- Builds a heap first, then times collectgarbage("collect").
-- Run with our GC and with native (DIAG_MODE=1) to compare.
-- =========================================================================

SLASH_GCCOMPARE1 = "/gccompare"
SlashCmdList["GCCOMPARE"] = function(args)
    local size = tonumber(args) or 100
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GC Compare|r: building %dk object heap...", size))

    -- Build a realistic mixed-age heap
    local heap = {}
    local closures = {}
    for i = 1, size * 1000 do
        local mode = math.mod(i, 4)
        if mode == 0 then
            heap[i] = { name = "obj" .. i, value = i, sub = { i, i+1 } }
        elseif mode == 1 then
            heap[i] = "string_key_" .. i
        elseif mode == 2 then
            local captured = i
            closures[i] = function() return captured end
            heap[i] = closures[i]
        else
            heap[i] = { [tostring(i)] = true, flag = i > size * 500 }
        end
    end

    -- Kill half the heap to create garbage
    for i = 1, size * 500 do
        heap[i] = nil
        closures[i] = nil
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "  heap built: %dk live, %dk garbage. Timing GC...", size / 2, size / 2))

    -- Time 5 forced collections
    local times = {}
    for trial = 1, 5 do
        -- Recreate some garbage between trials
        for i = 1, size * 100 do
            local _ = { i, "tmp" .. i }
        end

        debugprofilestart()
        collectgarbage()
        local elapsed = debugprofilestop()
        table.insert(times, elapsed)
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "  trial %d: |cffffd700%.2f ms|r", trial, elapsed))
    end

    -- Find min/max/avg
    local min_t, max_t, sum = 999999, 0, 0
    for _, t in ipairs(times) do
        if t < min_t then min_t = t end
        if t > max_t then max_t = t end
        sum = sum + t
    end
    local avg = sum / table.getn(times)

    local gc_type = "incremental"
    if type(ZGCStats) == "function" then
        local _, mark_steps = ZGCStats()
        if mark_steps <= 1 then gc_type = "atomic" end
    else
        gc_type = "native"
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GC Compare|r [%s]: min=%.2f max=%.2f avg=%.2f ms (%dk heap)",
        gc_type, min_t, max_t, avg, size))

    -- Cleanup
    heap = nil
    closures = nil
    collectgarbage()
end

-- =========================================================================
-- /gclife [duration]: mixed-age residency stress test
-- Simulates realistic addon memory patterns:
--   - Long-lived config tables (persist entire test)
--   - Medium-lived frame data (replaced every few seconds)
--   - Short-lived closures and strings (created/discarded each frame)
--   - Weak table caches (entries die and get cleared)
--   - Nested tables with upvalue captures
-- Runs per-frame for [duration] seconds (default 20), reports timing.
-- =========================================================================

local gclife_frame = CreateFrame("Frame")
local gclife_running = false
local gclife_end_time = 0
local gclife_frame_times = {}
local gclife_frame_count = 0
local gclife_last_time = 0

-- Long-lived: addon config tables (never replaced during test)
local gclife_config = {}
-- Medium-lived: frame data (replaced every ~2 seconds)
local gclife_frames = {}
local gclife_frames_age = 0
-- Weak cache: entries die when not referenced elsewhere
local gclife_weak_cache = setmetatable({}, { __mode = "v" })
-- Closure registry: closures with upvalue captures
local gclife_closures = {}

local function gclife_build_config()
    -- 2000 addon configs with 20 callbacks each = 40k closures + 2k tables
    for i = 1, 2000 do
        gclife_config["addon_" .. i] = {
            enabled = true,
            settings = { scale = 1.0, alpha = 0.8, x = i, y = i * 2 },
            history = {},
            callbacks = {},
            data = {},
        }
        local cfg = gclife_config["addon_" .. i]
        -- Deep nested data (3 levels)
        for j = 1, 10 do
            cfg.data[j] = {
                entries = {},
                meta = { created = i * 1000 + j, tag = "d" .. j },
            }
            for k = 1, 5 do
                cfg.data[j].entries[k] = { id = k, val = "item_" .. i .. "_" .. j .. "_" .. k }
            end
        end
        -- 20 callback closures capturing different upvalues
        for j = 1, 20 do
            local slot = j
            local data = cfg.data[math.mod(j, 10) + 1]
            cfg.callbacks[j] = function() return cfg.settings.scale * slot + data.meta.created end
        end
    end
end

local function gclife_rebuild_frames()
    -- 800 frames with 20 children each = 16k tables + 1600 closures
    gclife_frames = {}
    for i = 1, 800 do
        gclife_frames[i] = {
            name = "Frame" .. i,
            children = {},
            scripts = {},
            visible = math.mod(i, 3) ~= 0,
            textures = {},
        }
        for j = 1, 20 do
            gclife_frames[i].children[j] = {
                parent = gclife_frames[i],
                id = i * 100 + j,
                text = string.format("child_%d_%d", i, j),
                tooltip = "Tooltip for " .. i .. ":" .. j,
            }
        end
        -- Texture references (string heavy)
        for j = 1, 5 do
            gclife_frames[i].textures[j] = "Interface\\Icons\\Icon_" .. (i * 5 + j)
        end
        local f = gclife_frames[i]
        f.scripts.OnUpdate = function() return f.name end
        f.scripts.OnClick = function() f.visible = not f.visible end
    end
    gclife_frames_age = 0
end

local function gclife_per_frame()
    -- Heavy short-lived: 500 event tables + strings each frame
    local temps = {}
    for i = 1, 500 do
        local msg = "event_" .. math.random(10000) .. "_" .. GetTime()
        temps[i] = {
            type = "CHAT",
            msg = msg,
            time = GetTime(),
            source = "Player" .. math.random(40),
            args = { math.random(100), "spell_" .. math.random(500), math.random() > 0.5 },
        }
    end

    -- 200 short-lived closures (simulates addon callbacks, iterators)
    for i = 1, 200 do
        local val = math.random(1000)
        local name = "cb_" .. i
        local fn = function() return val * 2 + string.len(name) end
        fn()
    end

    -- Heavy weak cache churn: 100 entries, some pinned
    for i = 1, 100 do
        local key = "cache_" .. math.random(2000)
        local entry = {
            data = math.random(),
            ts = GetTime(),
            payload = { math.random(), "str_" .. math.random(1000) },
        }
        gclife_weak_cache[key] = entry
        if math.mod(i, 10) == 0 then
            local cfg_key = "addon_" .. math.random(2000)
            if gclife_config[cfg_key] then
                table.insert(gclife_config[cfg_key].history, entry)
                if table.getn(gclife_config[cfg_key].history) > 20 then
                    table.remove(gclife_config[cfg_key].history, 1)
                end
            end
        end
    end

    -- 50 upvalue mutations on existing closures
    for i = 1, 50 do
        local idx = math.random(2000)
        local cfg = gclife_config["addon_" .. idx]
        if cfg then
            cfg.settings.scale = math.random() * 2
            cfg.settings.alpha = math.random()
        end
    end

    -- String interning pressure: lookup existing + create new
    for i = 1, 200 do
        local _ = "addon_" .. math.random(2000)  -- hits intern table
        local _ = string.format("fmt_%d_%d_%s", i, math.random(100), GetTime())
    end

    -- Medium-lived replacement every ~2 seconds
    gclife_frames_age = gclife_frames_age + 1
    if gclife_frames_age > 120 then
        gclife_rebuild_frames()
    end

    temps = nil
end

local function gclife_start(args)
    local duration = tonumber(args) or 20

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GC Life|r: building mixed-age heap, running %d seconds...", duration))

    -- Build long-lived structures
    gclife_config = {}
    gclife_build_config()
    gclife_rebuild_frames()
    gclife_weak_cache = setmetatable({}, { __mode = "v" })

    -- Reset counters
    gclife_frame_times = {}
    gclife_frame_count = 0
    gclife_last_time = debugprofilestop and 0 or GetTime()
    gclife_end_time = GetTime() + duration
    gclife_running = true

    debugprofilestart()
    gclife_frame:SetScript("OnUpdate", function()
        if not gclife_running then return end
        if GetTime() >= gclife_end_time then
            gclife_running = false
            gclife_frame:SetScript("OnUpdate", nil)

            -- Report results
            local n = gclife_frame_count
            if n == 0 then return end
            table.sort(gclife_frame_times)
            local p50 = gclife_frame_times[math.floor(n * 0.5)] or 0
            local p95 = gclife_frame_times[math.floor(n * 0.95)] or 0
            local p99 = gclife_frame_times[math.floor(n * 0.99)] or 0
            local max_t = gclife_frame_times[n] or 0

            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cff00ff00GC Life|r: %d frames over %ds", n, duration))
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "  p50=|cffffd700%.1f ms|r  p95=|cffffd700%.1f ms|r  p99=|cffffd700%.1f ms|r  max=|cffff0000%.1f ms|r",
                p50, p95, p99, max_t))

            if type(ZGCStats) == "function" then
                local total, mark, sweep, gray, freed, fstr, ph, stepus, atomicus = ZGCStats()
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "  GC: step_max=%dus  atomic=%dus  last_mark=%d  last_sweep=%d",
                    stepus, atomicus, mark, sweep))
            end

            -- Cleanup
            gclife_config = {}
            gclife_frames = {}
            gclife_closures = {}
            gclife_weak_cache = nil
            collectgarbage()
            return
        end

        debugprofilestart()
        gclife_per_frame()
        local elapsed = debugprofilestop()
        gclife_frame_count = gclife_frame_count + 1
        table.insert(gclife_frame_times, elapsed)
    end)
end

SLASH_GCLIFE1 = "/gclife"
SlashCmdList["GCLIFE"] = gclife_start

-- =========================================================================
-- /gcsweep [seconds_per_combo]: auto-tune GC parameters
-- Runs /gclife workload with many (stepsize, stepmul, pause) combinations,
-- reports p99 frame time for each. Finds the empirical best defaults.
-- =========================================================================

local gcsweep_combos = {
    -- { stepsize, stepmul, pause, label }
    -- Vary stepsize
    { 256,  200, 200, "step=256" },
    { 512,  200, 200, "step=512" },
    { 1024, 200, 200, "step=1024 (5.1 default)" },
    { 2048, 200, 200, "step=2048" },
    { 4096, 200, 200, "step=4096" },
    { 8192, 200, 200, "step=8192" },
    -- Vary stepmul
    { 1024, 100, 200, "mul=100" },
    { 1024, 200, 200, "mul=200 (5.1 default)" },
    { 1024, 400, 200, "mul=400" },
    { 1024, 800, 200, "mul=800" },
    -- Vary pause
    { 1024, 200, 150, "pause=150 (1.5x)" },
    { 1024, 200, 200, "pause=200 (2x, default)" },
    { 1024, 200, 300, "pause=300 (3x)" },
    { 1024, 200, 400, "pause=400 (4x)" },
    -- Promising combos
    { 2048, 400, 200, "step=2k mul=400" },
    { 4096, 400, 200, "step=4k mul=400" },
    { 2048, 200, 150, "step=2k pause=1.5x" },
    { 512,  100, 150, "small+aggressive" },
    { 4096, 800, 300, "big+lazy" },
}

local gcsweep_running = false
local gcsweep_combo_idx = 0
local gcsweep_seconds = 0
local gcsweep_results = {}
local gcsweep_frame = CreateFrame("Frame")

-- Reuse gclife's per-frame workload
local gcsweep_end_time = 0
local gcsweep_frame_times = {}
local gcsweep_frame_count = 0

local function gcsweep_run_next()
    gcsweep_combo_idx = gcsweep_combo_idx + 1
    if gcsweep_combo_idx > table.getn(gcsweep_combos) then
        -- All done, report results
        gcsweep_running = false
        gcsweep_frame:SetScript("OnUpdate", nil)

        -- Restore defaults
        ZGCTune(1024, 200, 200)

        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GC Sweep|r: results (sorted by p99):")
        table.sort(gcsweep_results, function(a, b) return a.p99 < b.p99 end)
        for _, r in ipairs(gcsweep_results) do
            local color = "|cff00ff00"
            if r.p99 > 2.0 then color = "|cffff0000"
            elseif r.p99 > 1.0 then color = "|cffffff00"
            end
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "  %sp50=%.1f p95=%.1f p99=%.1f max=%.1f|r  %s",
                color, r.p50, r.p95, r.p99, r.max, r.label))
        end
        local best = gcsweep_results[1]
        if best then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "|cff00ff00BEST|r: %s (p99=%.1f ms)", best.label, best.p99))
        end

        -- Cleanup
        gclife_config = {}
        gclife_frames = {}
        gclife_closures = {}
        gclife_weak_cache = nil
        collectgarbage()
        return
    end

    local combo = gcsweep_combos[gcsweep_combo_idx]
    ZGCTune(combo[1], combo[2], combo[3])

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GC Sweep|r [%d/%d]: %s ...",
        gcsweep_combo_idx, table.getn(gcsweep_combos), combo[4]))

    -- Rebuild heap fresh for each combo
    gclife_config = {}
    gclife_build_config()
    gclife_rebuild_frames()
    gclife_weak_cache = setmetatable({}, { __mode = "v" })
    collectgarbage()

    gcsweep_frame_times = {}
    gcsweep_frame_count = 0
    gcsweep_end_time = GetTime() + gcsweep_seconds

    gcsweep_frame:SetScript("OnUpdate", function()
        if not gcsweep_running then return end

        if GetTime() >= gcsweep_end_time then
            -- Collect results for this combo
            local n = gcsweep_frame_count
            if n > 0 then
                table.sort(gcsweep_frame_times)
                local combo = gcsweep_combos[gcsweep_combo_idx]
                table.insert(gcsweep_results, {
                    label = combo[4],
                    p50 = gcsweep_frame_times[math.floor(n * 0.5)] or 0,
                    p95 = gcsweep_frame_times[math.floor(n * 0.95)] or 0,
                    p99 = gcsweep_frame_times[math.floor(n * 0.99)] or 0,
                    max = gcsweep_frame_times[n] or 0,
                })
            end
            -- Next combo
            gcsweep_run_next()
            return
        end

        debugprofilestart()
        gclife_per_frame()
        local elapsed = debugprofilestop()
        gcsweep_frame_count = gcsweep_frame_count + 1
        table.insert(gcsweep_frame_times, elapsed)
    end)
end

SLASH_GCSWEEP1 = "/gcsweep"
SlashCmdList["GCSWEEP"] = function(args)
    if gcsweep_running then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000GC Sweep already running|r")
        return
    end
    if type(ZGCTune) ~= "function" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000ZGCTune not available|r")
        return
    end

    gcsweep_seconds = tonumber(args) or 5
    gcsweep_combo_idx = 0
    gcsweep_results = {}
    gcsweep_running = true

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GC Sweep|r: testing %d combos, %ds each (%ds total)...",
        table.getn(gcsweep_combos), gcsweep_seconds,
        table.getn(gcsweep_combos) * gcsweep_seconds))

    gcsweep_run_next()
end

-- =========================================================================
-- zluagen stats frame -- visible by default, center screen, movable
-- ZGCStats() is registered by zluagen on its first GC tick.
-- Returns: cycles_total, cycles_major, cycles_minor,
--          mark_steps_last, sweep_steps_last,
--          gray_peak, touched_peak, current_phase
-- =========================================================================

local zgc_frame = CreateFrame("Frame", "ZGCStatsFrame", UIParent)
zgc_frame:SetWidth(280)
zgc_frame:SetHeight(120)
zgc_frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
zgc_frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
zgc_frame:SetBackdropColor(0, 0, 0, 0.7)
zgc_frame:EnableMouse(true)
zgc_frame:SetMovable(true)
zgc_frame:RegisterForDrag("LeftButton")
zgc_frame:SetScript("OnDragStart", function() this:StartMoving() end)
zgc_frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

local zgc_title = zgc_frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
zgc_title:SetPoint("TOP", zgc_frame, "TOP", 0, -8)
zgc_title:SetText("|cff00ff00zluagen|r")

local zgc_text = zgc_frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
zgc_text:SetPoint("TOPLEFT", zgc_frame, "TOPLEFT", 12, -28)
zgc_text:SetPoint("BOTTOMRIGHT", zgc_frame, "BOTTOMRIGHT", -12, 8)
zgc_text:SetJustifyH("LEFT")
zgc_text:SetJustifyV("TOP")
zgc_text:SetText("waiting for DLL...")

local zgc_last_update = 0
zgc_frame:SetScript("OnUpdate", function()
    local now = GetTime()
    if now - zgc_last_update < 0.2 then return end  -- ~5Hz refresh
    zgc_last_update = now

    if type(ZGCStats) ~= "function" then
        zgc_text:SetText("|cffff8800ZGCStats() not registered|r\n\n" ..
            "zluagen.dll may not be loaded.\n" ..
            "Try |cffffd700/run collectgarbage()|r to trigger first GC.")
        return
    end

    local total, mark_steps, sweep_steps, gray_peak, freed, freed_str, ph, max_step_us, atomic_us = ZGCStats()
    local phase_name = "?"
    if ph == 0 then phase_name = "idle"
    elseif ph == 1 then phase_name = "marking"
    elseif ph == 2 then phase_name = "atomic"
    elseif ph == 3 then phase_name = "sweep_str"
    elseif ph == 4 then phase_name = "sweeping"
    elseif ph == 5 then phase_name = "finalize"
    end

    local step_color = "|cff00ff00"
    if max_step_us > 2000 then step_color = "|cffff0000"
    elseif max_step_us > 1000 then step_color = "|cffffff00"
    end

    zgc_text:SetText(string.format(
        "cycles: |cffffd700%d|r  phase: %s\n" ..
        "last: |cffffd700%d|r mark / |cffffd700%d|r sweep steps\n" ..
        "freed: %d obj + %d str\n" ..
        "step max: %s%d us|r  atomic: %s%d us|r\n" ..
        "gray peak: %d",
        total, phase_name,
        mark_steps, sweep_steps,
        freed, freed_str,
        step_color, max_step_us, step_color, atomic_us,
        gray_peak))
end)

-- /zgcstats toggles visibility
SLASH_ZGCSTATS1 = "/zgcstats"
SlashCmdList["ZGCSTATS"] = function()
    if zgc_frame:IsVisible() then
        zgc_frame:Hide()
    else
        zgc_frame:Show()
    end
end

-- =========================================================================
-- GC stress test: /gcstress [size_k] [churn_pct] [duration]
-- Builds a large live heap then churns a fraction of it each frame.
-- size_k: thousands of live objects to maintain (default 200 = 200K objects)
-- churn_pct: percent of live set to replace per frame (default 5)
-- duration: seconds to run (default 15)
-- Reports frame times to detect GC stutter.
-- =========================================================================

local gcstress_frame = CreateFrame("Frame")
local gcstress_running = false
local gcstress_end_time = 0
local gcstress_frame_times = {}
local gcstress_frame_count = 0
local gcstress_last_time = 0
local gcstress_heap = {}        -- the live set
local gcstress_heap_size = 0
local gcstress_target_size = 0
local gcstress_churn_count = 0
local gcstress_churn_pct = 5
local gcstress_duration = 15
local gcstress_phase = "idle"   -- "building" or "churning"
local gcstress_build_idx = 0

-- Create a varied object to fill the heap
local function make_object(i)
    local mode = math.mod(i, 5)
    if mode == 0 then
        return { name = "obj_" .. i, value = i, flag = true }
    elseif mode == 1 then
        return { i, i+1, i+2, i+3, tag = "array_" .. i }
    elseif mode == 2 then
        return { sub = { a = i, b = i * 0.5 }, id = i }
    elseif mode == 3 then
        return "longstring_padding_" .. i .. "_extra_data_here"
    else
        return { x = i, y = i+1, z = i+2, w = i+3, label = "vec_" .. i, nested = { i } }
    end
end

gcstress_frame:SetScript("OnUpdate", function()
    if not gcstress_running then return end

    local now = GetTime()
    if gcstress_last_time > 0 then
        local dt = (now - gcstress_last_time) * 1000
        gcstress_frame_count = gcstress_frame_count + 1
        gcstress_frame_times[gcstress_frame_count] = dt
    end
    gcstress_last_time = now

    if gcstress_phase == "building" then
        -- Build up the live set over several frames (10K per frame)
        local batch = 10000
        local target = gcstress_target_size
        for i = 1, batch do
            gcstress_build_idx = gcstress_build_idx + 1
            if gcstress_build_idx > target then
                gcstress_phase = "churning"
                gcstress_heap_size = target
                gcstress_frame_count = 0 -- reset frame counter, start measuring
                gcstress_last_time = 0
                gcstress_end_time = GetTime() + gcstress_duration
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cff00ff00GCStress|r: heap built (%dK objects), churning %d%%/frame for %ds...",
                    target / 1000, gcstress_churn_pct, gcstress_duration))
                return
            end
            gcstress_heap[gcstress_build_idx] = make_object(gcstress_build_idx)
        end
        return
    end

    -- Churning phase: replace a random fraction of the live set each frame
    if now >= gcstress_end_time then
        gcstress_running = false
        gcstress_report()
        -- Clean up heap
        gcstress_heap = {}
        collectgarbage()
        return
    end

    local churn = gcstress_churn_count
    for i = 1, churn do
        -- Replace a random slot with a new object (old one becomes garbage)
        local idx = math.random(1, gcstress_heap_size)
        gcstress_heap[idx] = make_object(idx + gcstress_frame_count * 1000)
    end

    -- Also create some pure garbage (temporaries that die this frame)
    for i = 1, churn do
        local t = { a = i, s = "tmp_" .. i }
    end
end)

function gcstress_report()
    local n = gcstress_frame_count
    if n == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000GCStress|r: no frames recorded")
        return
    end

    -- Sort frame times to get percentiles
    table.sort(gcstress_frame_times)

    local sum = 0
    local max_dt = 0
    for i = 1, n do
        sum = sum + gcstress_frame_times[i]
        if gcstress_frame_times[i] > max_dt then
            max_dt = gcstress_frame_times[i]
        end
    end
    local avg = sum / n
    local p50 = gcstress_frame_times[math.floor(n * 0.5)]
    local p95 = gcstress_frame_times[math.floor(n * 0.95)]
    local p99 = gcstress_frame_times[math.floor(n * 0.99)]

    -- Count stutter frames (>2x median)
    local stutter_threshold = p50 * 2
    local stutters = 0
    for i = 1, n do
        if gcstress_frame_times[i] > stutter_threshold then
            stutters = stutters + 1
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GCStress|r: %d frames, %dK heap, %d churn/frame", n, gcstress_heap_size / 1000, gcstress_churn_count))
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "  avg=|cffffd700%.1fms|r  p50=%.1f  p95=%.1f  p99=%.1f  max=|cffff0000%.1fms|r",
        avg, p50, p95, p99, max_dt))
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "  stutters (>%.1fms): |cffff0000%d|r (%.1f%%)",
        stutter_threshold, stutters, stutters * 100 / n))
end

SLASH_GCSTRESS1 = "/gcstress"
SlashCmdList["GCSTRESS"] = function(msg)
    local args = {}
    for w in string.gfind(msg, "%S+") do
        table.insert(args, tonumber(w))
    end

    local size_k = args[1] or 200
    gcstress_churn_pct = args[2] or 5
    gcstress_duration = args[3] or 15

    gcstress_target_size = size_k * 1000
    gcstress_churn_count = math.floor(gcstress_target_size * gcstress_churn_pct / 100)

    gcstress_heap = {}
    gcstress_frame_times = {}
    gcstress_frame_count = 0
    gcstress_last_time = 0
    gcstress_build_idx = 0
    gcstress_phase = "building"
    gcstress_running = true

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00GCStress|r: building %dK live objects...", size_k))
end

-- =========================================================================
-- Lump allocation test: /lumpaloc [count_k] [obj_size] [hold_secs]
-- Allocates a burst of objects, holds them for N seconds, then releases.
-- Measures frame times during the allocation burst to detect stutter
-- from the allocator itself (not GC).
-- count_k: thousands of objects (default 100)
-- obj_size: approximate bytes per object (default 80)
-- hold_secs: seconds to hold before release (default 10)
-- =========================================================================

local lump_frame = CreateFrame("Frame")
local lump_running = false
local lump_phase = "idle"
local lump_heap = {}
local lump_frame_times = {}
local lump_frame_count = 0
local lump_last_time = 0
local lump_target = 0
local lump_build_idx = 0
local lump_release_time = 0
local lump_hold_secs = 10
local lump_obj_size = 80
local lump_batch = 5000

-- Simulate realistic addon data structures:
-- Combat log entries reference spells, units, auras in cross-linked tables.
-- Damage meters keep per-player tables with per-spell breakdowns.
-- Threat meters keep sorted lists with callbacks.

-- Shared "database" tables that many objects reference (simulates spell/unit caches)
local shared_spells = {}
local shared_units = {}
for i = 1, 200 do
    shared_spells[i] = { id = i, name = "Spell_" .. i, rank = math.mod(i, 5) + 1, school = math.mod(i, 7), icon = "Interface\\Icons\\spell_" .. i }
    shared_units[i] = { guid = "0x" .. i, name = "Unit_" .. i, class = math.mod(i, 9) + 1, level = 60, buffs = {}, debuffs = {} }
end

-- Metatables for "typed" objects (addons use these heavily)
local CombatEvent_mt = { __index = { GetSource = function(self) return self.source end, GetTarget = function(self) return self.target end, GetAmount = function(self) return self.amount end } }
local PlayerData_mt = { __index = { GetDPS = function(self) return self.total / (self.duration or 1) end, AddSpell = function(self, id, amt) self.spells[id] = (self.spells[id] or 0) + amt end } }

local function make_combat_event(i)
    local e = {
        timestamp = GetTime() + i * 0.001,
        event = "SPELL_DAMAGE",
        source = shared_units[math.mod(i, 200) + 1],
        target = shared_units[math.mod(i + 50, 200) + 1],
        spell = shared_spells[math.mod(i, 200) + 1],
        amount = math.random(100, 5000),
        overkill = 0,
        school = math.mod(i, 7),
        critical = math.mod(i, 4) == 0,
        absorbed = math.mod(i, 10) == 0 and math.random(50, 500) or nil,
        blocked = nil,
        resisted = math.mod(i, 8) == 0 and math.random(20, 200) or nil,
    }
    setmetatable(e, CombatEvent_mt)
    return e
end

local function make_player_data(i)
    local p = {
        name = "Player_" .. i,
        class = math.mod(i, 9) + 1,
        unit = shared_units[math.mod(i, 40) + 1],
        total = 0,
        duration = 0,
        spells = {},
        targets = {},
        timeline = {},
        auras = {},
    }
    -- Fill spell breakdown (like a damage meter accumulating data)
    for j = 1, 20 do
        local sp = shared_spells[math.mod(i * 7 + j, 200) + 1]
        p.spells[sp.name] = { hits = math.random(10, 200), total = math.random(5000, 100000), crit = math.random(5, 50), min = math.random(100, 500), max = math.random(2000, 8000) }
        p.total = p.total + p.spells[sp.name].total
    end
    -- Fill target breakdown
    for j = 1, 8 do
        local tgt = shared_units[math.mod(i * 3 + j, 200) + 1]
        p.targets[tgt.name] = math.random(10000, 200000)
    end
    -- Timeline entries (like a graph data series)
    for j = 1, 30 do
        p.timeline[j] = { t = j, dps = math.random(500, 3000), hps = 0 }
    end
    setmetatable(p, PlayerData_mt)
    return p
end

local function make_aura_tracker(i)
    local a = {
        unit = shared_units[math.mod(i, 200) + 1],
        buffs = {},
        debuffs = {},
        callbacks = {},
    }
    for j = 1, 10 do
        a.buffs[j] = { spell = shared_spells[math.mod(i + j, 200) + 1], stacks = math.mod(j, 3) + 1, expires = GetTime() + math.random(5, 30), source = shared_units[math.mod(i + j + 20, 200) + 1] }
    end
    for j = 1, 6 do
        a.debuffs[j] = { spell = shared_spells[math.mod(i * 2 + j, 200) + 1], stacks = 1, expires = GetTime() + math.random(3, 18) }
    end
    -- Closures referencing upvalues (common in addon callbacks)
    local unit_ref = a.unit
    a.callbacks.onApply = function(spell) return unit_ref.name .. " gained " .. spell.name end
    a.callbacks.onFade = function(spell) return unit_ref.name .. " lost " .. spell.name end
    return a
end

local function make_sized_object(i, size)
    local mode = math.mod(i, 3)
    if mode == 0 then
        return make_combat_event(i)
    elseif mode == 1 then
        return make_player_data(i)
    else
        return make_aura_tracker(i)
    end
end

lump_frame:SetScript("OnUpdate", function()
    if not lump_running then return end

    local now = GetTime()
    if lump_last_time > 0 then
        local dt = (now - lump_last_time) * 1000
        lump_frame_count = lump_frame_count + 1
        lump_frame_times[lump_frame_count] = dt
    end
    lump_last_time = now

    if lump_phase == "allocating" then
        -- Allocate a batch per frame
        for j = 1, lump_batch do
            lump_build_idx = lump_build_idx + 1
            if lump_build_idx > lump_target then
                lump_phase = "holding"
                lump_release_time = GetTime() + lump_hold_secs
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cff00ff00LumpAlloc|r: allocated %dK objects, holding for %ds...",
                    lump_target / 1000, lump_hold_secs))
                return
            end
            lump_heap[lump_build_idx] = make_sized_object(lump_build_idx, lump_obj_size)
        end

    elseif lump_phase == "holding" then
        if now >= lump_release_time then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LumpAlloc|r: releasing all objects...")
            lump_heap = {}
            lump_phase = "released"
            -- Let GC deal with it, keep measuring for a few more seconds
            lump_release_time = GetTime() + 5
        end

    elseif lump_phase == "released" then
        if now >= lump_release_time then
            lump_running = false
            lump_report()
            collectgarbage()
        end
    end
end)

function lump_report()
    local n = lump_frame_count
    if n == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000LumpAlloc|r: no frames recorded")
        return
    end

    table.sort(lump_frame_times)

    local sum = 0
    local max_dt = 0
    for i = 1, n do
        sum = sum + lump_frame_times[i]
        if lump_frame_times[i] > max_dt then max_dt = lump_frame_times[i] end
    end
    local avg = sum / n
    local p50 = lump_frame_times[math.floor(n * 0.5)]
    local p95 = lump_frame_times[math.floor(n * 0.95)]
    local p99 = lump_frame_times[math.floor(n * 0.99)]

    local stutter_threshold = p50 * 2
    local stutters = 0
    for i = 1, n do
        if lump_frame_times[i] > stutter_threshold then stutters = stutters + 1 end
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00LumpAlloc|r: %d frames, %dK objects at ~%dB each",
        n, lump_target / 1000, lump_obj_size))
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "  avg=|cffffd700%.1fms|r  p50=%.1f  p95=%.1f  p99=%.1f  max=|cffff0000%.1fms|r",
        avg, p50, p95, p99, max_dt))
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "  stutters (>%.1fms): %d (%.1f pct)",
        stutter_threshold, stutters, stutters * 100 / n))
end

SLASH_LUMPALOC1 = "/lumpaloc"
SlashCmdList["LUMPALOC"] = function(msg)
    local args = {}
    for w in string.gfind(msg, "%S+") do
        table.insert(args, tonumber(w))
    end

    local count_k = args[1] or 50
    lump_obj_size = args[2] or 80
    lump_hold_secs = args[3] or 5

    lump_target = count_k * 1000
    lump_heap = {}
    lump_frame_times = {}
    lump_frame_count = 0
    lump_last_time = 0
    lump_build_idx = 0
    lump_phase = "allocating"
    lump_running = true

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00LumpAlloc|r: allocating %dK objects (~%dB each), hold %ds...",
        count_k, lump_obj_size, lump_hold_secs))
end
