-- DPSMate CLEU Adapter
-- Replaces the string-parsing CHAT_MSG_* event system with structured COMBAT_LOG_EVENT_UNFILTERED
-- data from the DPSLog module. Registers for COMBAT_LOG_EVENT_UNFILTERED and calls DPSMate.DB
-- functions directly with extracted values.
--
-- Toggle: /dpscleu    (switches between CLEU adapter and original string parser)
-- Requires: DPSLog module (provides COMBAT_LOG_EVENT_UNFILTERED + GetSpellInfo)

if not DPSMate or not DPSMate.DB then return end
if not GetWeirdUtilsVersion or not GetWeirdUtilsVersion("dpslog") then return end

local DB = DPSMate.DB
local Parser = DPSMate.Parser
local GT = GetTime
local AAttack = DPSMate.L and DPSMate.L["autoattack"] or "Attack"

-- ============================================================================
-- Chat event list (original parser registers these)
-- ============================================================================

local chatEvents = {
    "CHAT_MSG_COMBAT_PET_HITS", "CHAT_MSG_COMBAT_PET_MISSES",
    "CHAT_MSG_SPELL_PET_DAMAGE",
    "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
    "CHAT_MSG_SPELL_SELF_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
    "CHAT_MSG_COMBAT_PARTY_HITS", "CHAT_MSG_SPELL_PARTY_DAMAGE",
    "CHAT_MSG_COMBAT_PARTY_MISSES",
    "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS",
    "CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES",
    "CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS",
    "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES",
    "CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
    "CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE",
    "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES",
    "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
    "CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE",
    "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES",
    "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_SELF_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
    "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
    "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS",
    "CHAT_MSG_SPELL_PARTY_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
    "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
    "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS",
    "CHAT_MSG_SPELL_BREAK_AURA",
    "CHAT_MSG_SPELL_AURA_GONE_SELF",
    "CHAT_MSG_SPELL_AURA_GONE_OTHER",
    "CHAT_MSG_SPELL_AURA_GONE_PARTY",
    "CHAT_MSG_COMBAT_FRIENDLY_DEATH",
    "CHAT_MSG_COMBAT_HOSTILE_DEATH",
}

-- ============================================================================
-- Toggle state
-- ============================================================================

local cleuActive = false
local cleuFrame = CreateFrame("Frame")

local function enableCLEU()
    -- Disable string parser
    for _, ev in ipairs(chatEvents) do
        Parser:UnregisterEvent(ev)
    end
    -- Enable CLEU
    cleuFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    cleuActive = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSMate CLEU Adapter|r: |cff00ff00ON|r (structured events)")
end

local function enableOriginal()
    -- Disable CLEU
    cleuFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    -- Re-enable string parser
    for _, ev in ipairs(chatEvents) do
        Parser:RegisterEvent(ev)
    end
    cleuActive = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSMate CLEU Adapter|r: |cffff4444OFF|r (string parser)")
end

local function toggle()
    if cleuActive then
        enableOriginal()
    else
        enableCLEU()
    end
end

SLASH_DPSCLEU1 = "/dpscleu"
SlashCmdList["DPSCLEU"] = function(msg)
    if msg == "on" then
        if not cleuActive then enableCLEU() end
    elseif msg == "off" then
        if cleuActive then enableOriginal() end
    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSMate CLEU Adapter|r: " .. (cleuActive and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    else
        toggle()
    end
end

-- ============================================================================
-- Helper
-- ============================================================================

local function isGroupMember(name)
    if not name or name == "" then return false end
    if name == UnitName("player") then return true end
    for i = 1, GetNumRaidMembers() do
        if name == UnitName("raid" .. i) then return true end
    end
    for i = 1, GetNumPartyMembers() do
        if name == UnitName("party" .. i) then return true end
    end
    return false
end

-- ============================================================================
-- (dead handler removed — real handler is cleuHandler below, wrapped by profiling)
-- ============================================================================

-- ============================================================================
-- Performance profiling
-- ============================================================================

-- debugprofilestop() returns ms since last debugprofilestart().
-- We call debugprofilestart() once at combat start, then use debugprofilestop()
-- as a monotonic clock — taking deltas between before/after each handler call.
-- gcinfo() returns KB.

local profiling = false
local profCLEU = { events = 0, totalMs = 0, gcStart = 0 }
local profOrig = { events = 0, totalMs = 0, gcStart = 0 }
local profCurrent = nil

-- Hook the parser's OnEvent to measure original mode
local origOnEvent = DPSMate.Parser:GetScript("OnEvent")
local function measuredOrigOnEvent()
    if profiling and profCurrent == profOrig then
        local before = debugprofilestop()
        origOnEvent()
        local after = debugprofilestop()
        profOrig.totalMs = profOrig.totalMs + (after - before)
        profOrig.events = profOrig.events + 1
    else
        origOnEvent()
    end
end
DPSMate.Parser:SetScript("OnEvent", measuredOrigOnEvent)

-- Wrap the CLEU handler similarly
local cleuHandler -- forward decl

local function measuredCLEUHandler()
    if profiling and profCurrent == profCLEU then
        local before = debugprofilestop()
        cleuHandler()
        local after = debugprofilestop()
        profCLEU.totalMs = profCLEU.totalMs + (after - before)
        profCLEU.events = profCLEU.events + 1
    else
        cleuHandler()
    end
end

local function profReset(tbl)
    tbl.events = 0
    tbl.totalMs = 0
    tbl.gcStart = gcinfo()
end

-- debugprofilestop() returns microseconds on this client
local lastCLEUAvg = nil
local lastOrigAvg = nil

local function profReport(label, tbl)
    local gcEnd = gcinfo()
    local gcDelta = gcEnd - tbl.gcStart
    local totalMs = tbl.totalMs / 1000
    local avgUs = tbl.events > 0 and (tbl.totalMs / tbl.events) or 0

    -- Store for comparison
    if label == "CLEU" then
        lastCLEUAvg = avgUs
    else
        lastOrigAvg = avgUs
    end

    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00[%s]|r %d events, %.1fms total, %.1f us/event, %+.1f KB gc",
        label, tbl.events, totalMs, avgUs, gcDelta))

    -- If we have both measurements, show comparison
    if lastCLEUAvg and lastOrigAvg and lastOrigAvg > 0 then
        local pct = ((lastCLEUAvg - lastOrigAvg) / lastOrigAvg) * 100
        local sign = pct < 0 and "" or "+"
        local color = pct < 0 and "|cff00ff00" or "|cffff4444"
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s[CLEU vs ORIGINAL]|r %.1f vs %.1f us/event = %s%.1f%%|r %s",
            color, lastCLEUAvg, lastOrigAvg, sign, pct,
            pct < 0 and "(CLEU faster)" or "(ORIGINAL faster)"))
    end
end

-- /dpsbench  -- enables per-combat A/B profiling. Each combat: measure, report, flip.
local benchActive = true

local benchFrame = CreateFrame("Frame")

local function benchCombatStart()
    if not benchActive then return end
    profCurrent = cleuActive and profCLEU or profOrig
    profReset(profCurrent)
    debugprofilestart() -- start the monotonic clock for this combat
    profiling = true
    local label = cleuActive and "CLEU" or "ORIGINAL"
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[DPS Bench]|r combat started, measuring %s", label))
end

local function benchCombatEnd()
    if not benchActive or not profiling then return end
    profiling = false
    local label = cleuActive and "CLEU" or "ORIGINAL"
    profReport(label, profCurrent)
    toggle()
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00[DPS Bench]|r next combat will use: %s", cleuActive and "CLEU" or "ORIGINAL"))
end

benchFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
benchFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
benchFrame:SetScript("OnEvent", function()
    if event == "PLAYER_REGEN_DISABLED" then
        benchCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        benchCombatEnd()
    end
end)

SLASH_DPSBENCH1 = "/dpsbench"
SlashCmdList["DPSBENCH"] = function()
    benchActive = not benchActive
    if benchActive then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cff00ff00[DPS Bench]|r enabled. Current mode: %s. Enter combat to begin.",
            cleuActive and "CLEU" or "ORIGINAL"))
    else
        profiling = false
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[DPS Bench]|r disabled.")
    end
end

-- ============================================================================
-- Wire up CLEU handler with measurement
-- ============================================================================

-- Replace the raw SetScript with the measured wrapper
cleuFrame:SetScript("OnEvent", function()
    -- This outer function gets replaced below
end)

-- The actual CLEU handler (extracted so we can call it directly or measured)
local ShieldFlags = DB.ShieldFlags
local FailDT = DPSMate.Parser.FailDT
local FailDB = DPSMate.Parser.FailDB

cleuHandler = function()
    if not CombatLogGetCurrentEventInfo then return end
    local sub, srcGUID, srcName, srcFlags, srcRaidFlags,
          dstGUID, dstName, dstFlags, dstRaidFlags = CombatLogGetCurrentEventInfo()
    if not sub then return end

    if not srcName or srcName == "" then srcName = "Unknown" end
    if not dstName or dstName == "" then dstName = "Unknown" end

    -- ========================================================================
    -- DAMAGE events
    -- ========================================================================
    -- SWING_DAMAGE: (base 9), amount, overkill, school, resisted,
    --   blocked, absorbed, critical, glancing, crushing

    if sub == "SWING_DAMAGE" then
        local _, _, _, _, _, _, _, _, _,
              amount, overkill, school, resisted, blocked, absorbed,
              critical, glancing, crushing = CombatLogGetCurrentEventInfo()
        -- numbers always non-nil from CombatLogGetCurrentEventInfo
        local crit  = critical and 1 or 0
        local glanc = glancing and 1 or 0
        local crush = crushing and 1 or 0
        local hit   = (crit == 0 and glanc == 0 and crush == 0) and 1 or 0

        DB:DamageDone(srcName, AAttack, hit, crit, 0, 0, 0, 0, amount, glanc, 0)
        DB:DamageTaken(dstName, AAttack, hit, crit, 0, 0, 0, 0, amount, srcName, crush, 0)
        DB:EnemyDamage(1, DPSMateEDT, dstName, AAttack, hit, crit, 0, 0, 0, 0, amount, srcName, 0, crush)
        DB:EnemyDamage(2, DPSMateEDD, srcName, AAttack, hit, crit, 0, 0, 0, 0, amount, dstName, 0, 0)
        DB:DeathHistory(dstName, srcName, AAttack, amount, hit, crit, "hit", crush)
        if absorbed > 0 then
            DB:SetUnregisterVariables(absorbed, AAttack, srcName)
            DB:Absorb(AAttack, dstName, srcName)
        end

    elseif sub == "SWING_MISSED" then
        local _, _, _, _, _, _, _, _, _,
              missType = CombatLogGetCurrentEventInfo()
        local miss   = (missType == "MISS") and 1 or 0
        local parry  = (missType == "PARRY") and 1 or 0
        local dodge  = (missType == "DODGE") and 1 or 0
        local resist = (missType == "RESIST" or missType == "IMMUNE") and 1 or 0
        local block  = (missType == "BLOCK") and 1 or 0
        local absorb = (missType == "ABSORB") and 1 or 0

        DB:DamageDone(srcName, AAttack, 0, 0, miss + absorb, parry, dodge, resist, 0, 0, block)
        DB:DamageTaken(dstName, AAttack, 0, 0, miss + absorb, parry, dodge, resist, 0, srcName, 0, block)
        if absorb == 1 then
            DB:Absorb(AAttack, dstName, srcName)
        end

    -- SPELL_DAMAGE: (base 9), spellId, spellName, spellSchool,
    --   amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing

    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE"
        or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              amount, overkill, school, resisted, blocked, absorbed,
              critical, glancing, crushing = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        -- numbers always non-nil from CombatLogGetCurrentEventInfo
        local crit  = critical and 1 or 0
        local glanc = glancing and 1 or 0
        local crush = crushing and 1 or 0
        local hit   = (crit == 0 and glanc == 0 and crush == 0) and 1 or 0
        local abilityName = (sub == "SPELL_PERIODIC_DAMAGE") and (spellName .. "(Periodic)") or spellName

        DB:DamageDone(srcName, abilityName, hit, crit, 0, 0, 0, 0, amount, glanc, 0)
        DB:DamageTaken(dstName, abilityName, hit, crit, 0, 0, 0, 0, amount, srcName, crush, 0)
        DB:EnemyDamage(1, DPSMateEDT, dstName, abilityName, hit, crit, 0, 0, 0, 0, amount, srcName, 0, crush)
        DB:EnemyDamage(2, DPSMateEDD, srcName, abilityName, hit, crit, 0, 0, 0, 0, amount, dstName, 0, 0)
        DB:DeathHistory(dstName, srcName, abilityName, amount, hit, crit, "hit", crush)
        if spellSchool then DB:AddSpellSchool(abilityName, spellSchool) end
        if absorbed > 0 then
            DB:SetUnregisterVariables(absorbed, abilityName, srcName)
            DB:Absorb(abilityName, dstName, srcName)
        end
        if FailDT and FailDT[spellName] then
            DB:BuildFail(2, srcName, dstName, abilityName, amount)
        end

    elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED"
        or sub == "SPELL_PERIODIC_MISSED" or sub == "DAMAGE_SHIELD_MISSED" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              missType = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        local miss   = (missType == "MISS") and 1 or 0
        local parry  = (missType == "PARRY") and 1 or 0
        local dodge  = (missType == "DODGE") and 1 or 0
        local resist = (missType == "RESIST" or missType == "IMMUNE") and 1 or 0
        local block  = (missType == "BLOCK") and 1 or 0
        local absorb = (missType == "ABSORB") and 1 or 0
        local isPeriodic = (sub == "SPELL_PERIODIC_MISSED")
        local abilityName = isPeriodic and (spellName .. "(Periodic)") or spellName

        DB:DamageDone(srcName, abilityName, 0, 0, miss + absorb, parry, dodge, resist, 0, 0, block)
        DB:DamageTaken(dstName, abilityName, 0, 0, miss + absorb, parry, dodge, resist, 0, srcName, 0, block)
        if absorb == 1 then
            DB:Absorb(abilityName, dstName, srcName)
        end

    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        local _, _, _, _, _, _, _, _, _,
              envType, amount = CombatLogGetCurrentEventInfo()
        DB:DamageTaken(dstName, envType or "Environment", 1, 0, 0, 0, 0, 0, amount, envType or "Environment", 0, 0)
        DB:DeathHistory(dstName, envType or "Environment", envType or "Environment", amount, 1, 0, "hit", 0)

    -- ========================================================================
    -- HEAL events
    -- ========================================================================

    elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              amount, overheal, absorbed, critical = CombatLogGetCurrentEventInfo()
        local crit = critical and 1 or 0
        local hit  = crit == 0 and 1 or 0
        local effective = amount - overheal
        if effective < 0 then effective = 0 end

        DB:Healing(1, DPSMateHealingTaken, srcName, spellName, hit, crit, effective)
        DB:Healing(2, DPSMateOverhealing, srcName, spellName, hit, crit, overheal)
        DB:HealingTaken(1, DPSMateHealingTaken, srcName, spellName, hit, crit, effective, dstName)
        DB:DeathHistory(dstName, srcName, spellName, effective, hit, crit, "heal", 0)

    -- ========================================================================
    -- AURA events (+ absorb shield lifecycle)
    -- ========================================================================

    elseif sub == "SPELL_AURA_APPLIED" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, auraType = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        if auraType == "DEBUFF" then
            DB:BuildBuffs(srcName, dstName, spellName, false)
            if Parser.CC[spellName] then
                DB:BuildActiveCC(dstName, spellName)
            end
            if FailDB and FailDB[spellName] then
                DB:BuildFail(3, "Environment", dstName, spellName, 0)
            end
        else
            DB:BuildBuffs(srcName, dstName, spellName, true)
            if ShieldFlags[spellName] then
                DB:ConfirmAbsorbApplication(spellName, dstName, GT())
            end
        end

    elseif sub == "SPELL_AURA_REMOVED" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, auraType = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        DB:DestroyBuffs(dstName, spellName)
        if auraType == "DEBUFF" then
            DB:RemoveActiveCC(dstName, spellName)
        else
            if ShieldFlags[spellName] then
                DB:UnregisterAbsorb(spellName, dstName)
            end
        end

    elseif sub == "SPELL_AURA_BROKEN_SPELL" or sub == "SPELL_AURA_BROKEN" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        DB:RemoveActiveCC(dstName, spellName)
        if Parser.CC[spellName] then
            DB:CCBreaker(dstName, spellName, srcName)
        end

    -- ========================================================================
    -- CAST events
    -- ========================================================================

    elseif sub == "SPELL_CAST_SUCCESS" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        if Parser.Kicks and Parser.Kicks[spellName] then
            DB:RegisterPotentialKick(srcName, spellName, GT())
        end
        if ShieldFlags[spellName] then
            DB:AwaitingAbsorbConfirmation(srcName, spellName, dstName, GT())
        end

    -- ========================================================================
    -- INTERRUPT / DISPEL events
    -- ========================================================================

    elseif sub == "SPELL_INTERRUPT" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              extraSpellId, extraSpellName = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        extraSpellName = extraSpellName or "Unknown"
        DB:Kick(srcName, dstName, spellName, extraSpellName)

    elseif sub == "SPELL_DISPEL" then
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              extraSpellId, extraSpellName = CombatLogGetCurrentEventInfo()
        spellName = spellName or "Unknown"
        extraSpellName = extraSpellName or "Unknown"
        if isGroupMember(srcName) then
            DB:Dispels(srcName, spellName, dstName, extraSpellName)
        end

    -- ========================================================================
    -- DEATH events
    -- ========================================================================

    elseif sub == "UNIT_DIED" or sub == "UNIT_DESTROYED" then
        DB:UnregisterDeath(dstName)

    elseif sub == "SPELL_SUMMON" then
        if not Parser.petToOwnerMap then Parser.petToOwnerMap = {} end
        if not Parser.petToOwnerMap[dstName] then Parser.petToOwnerMap[dstName] = {} end
        Parser.petToOwnerMap[dstName][srcName] = true
    end
end

-- Set the measured wrapper as the actual handler
cleuFrame:SetScript("OnEvent", measuredCLEUHandler)

-- ============================================================================
-- Start in CLEU mode by default
-- ============================================================================

enableCLEU()
