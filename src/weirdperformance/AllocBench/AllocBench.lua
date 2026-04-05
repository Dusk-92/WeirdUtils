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
