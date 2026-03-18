-- WSBT CLEU Adapter
-- Replaces MikCEH's CHAT_MSG_* string parsing with structured COMBAT_LOG_EVENT_UNFILTERED.
-- Toggle: /wsbtcleu   (switches between CLEU adapter and original string parser)
-- Requires: DPSLog module (provides COMBAT_LOG_EVENT_UNFILTERED)

-- Require DPSLog module and MikCEH
if not GetWeirdUtilsVersion or not GetWeirdUtilsVersion("dpslog") then return end
if not MikCEH or not MikCEH.SendEvent then return end

local CEH = MikCEH
local SendEvent = MikCEH.SendEvent
local GetDamageData = MikCEH.GetDamageEventData
local GetHealData = MikCEH.GetHealEventData
local GetNotifData = MikCEH.GetNotificationEventData

-- ============================================================================
-- Constants (local refs for speed)
-- ============================================================================

local INCOMING = CEH.DIRECTIONTYPE_PLAYER_INCOMING
local OUTGOING = CEH.DIRECTIONTYPE_PLAYER_OUTGOING
local PET_OUT  = CEH.DIRECTIONTYPE_PET_OUTGOING
local PET_IN   = CEH.DIRECTIONTYPE_PET_INCOMING

local HIT      = CEH.ACTIONTYPE_HIT
local MISS     = CEH.ACTIONTYPE_MISS
local DODGE    = CEH.ACTIONTYPE_DODGE
local PARRY    = CEH.ACTIONTYPE_PARRY
local BLOCK    = CEH.ACTIONTYPE_BLOCK
local RESIST   = CEH.ACTIONTYPE_RESIST
local ABSORB   = CEH.ACTIONTYPE_ABSORB
local IMMUNE   = CEH.ACTIONTYPE_IMMUNE
local EVADE    = CEH.ACTIONTYPE_EVADE
local REFLECT  = CEH.ACTIONTYPE_REFLECT

local HIT_NORMAL = CEH.HITTYPE_NORMAL
local HIT_CRIT   = CEH.HITTYPE_CRIT
local HIT_DOT    = CEH.HITTYPE_OVER_TIME

local HEAL_NORMAL = CEH.HEALTYPE_NORMAL
local HEAL_CRIT   = CEH.HEALTYPE_CRIT
local HEAL_HOT    = CEH.HEALTYPE_OVER_TIME

local DMG_PHYSICAL = CEH.DAMAGETYPE_PHYSICAL
local DMG_UNKNOWN  = CEH.DAMAGETYPE_UNKNOWN

local PARTIAL_ABSORB    = CEH.PARTIALACTIONTYPE_ABSORB
local PARTIAL_BLOCK     = CEH.PARTIALACTIONTYPE_BLOCK
local PARTIAL_RESIST    = CEH.PARTIALACTIONTYPE_RESIST
local PARTIAL_CRUSHING  = CEH.PARTIALACTIONTYPE_CRUSHING
local PARTIAL_GLANCING  = CEH.PARTIALACTIONTYPE_GLANCING
local PARTIAL_OVERHEAL  = CEH.PARTIALACTIONTYPE_OVERHEAL

local NOTIF_DEBUFF     = CEH.NOTIFICATIONTYPE_DEBUFF
local NOTIF_BUFF       = CEH.NOTIFICATIONTYPE_BUFF
local NOTIF_BUFF_FADE  = CEH.NOTIFICATIONTYPE_BUFF_FADE
local NOTIF_POWER_GAIN = CEH.NOTIFICATIONTYPE_POWER_GAIN
local NOTIF_POWER_LOSS = CEH.NOTIFICATIONTYPE_POWER_LOSS

-- Miss type string → MikCEH action type
local missActionMap = {
    MISS    = MISS,
    DODGE   = DODGE,
    PARRY   = PARRY,
    BLOCK   = BLOCK,
    RESIST  = RESIST,
    ABSORB  = ABSORB,
    IMMUNE  = IMMUNE,
    EVADE   = EVADE,
    REFLECT = REFLECT,
    DEFLECT = MISS,  -- no DEFLECT in MSBT, treat as miss
}

-- WoW spell school bitmask → MSBT damage type
-- 1=Physical, 2=Holy, 4=Fire, 8=Nature, 16=Frost, 32=Shadow, 64=Arcane
local schoolMap = {
    [1]  = 1,  -- Physical
    [2]  = 2,  -- Holy
    [4]  = 4,  -- Fire
    [8]  = 3,  -- Nature
    [16] = 5,  -- Frost
    [32] = 6,  -- Shadow
    [64] = 7,  -- Arcane
}

local function schoolToDamageType(school)
    if not school or school == 0 then return DMG_PHYSICAL end
    return schoolMap[school] or DMG_UNKNOWN
end

-- Power type ID → localized string
local powerTypeNames = {
    [0] = MANA or "Mana",
    [1] = RAGE or "Rage",
    [2] = "Focus",
    [3] = ENERGY or "Energy",
}

-- ============================================================================
-- Player/pet identity
-- ============================================================================

local playerName = UnitName("player")
local petName = UnitName("pet")

local identityFrame = CreateFrame("Frame")
identityFrame:RegisterEvent("UNIT_NAME_UPDATE")
identityFrame:RegisterEvent("PLAYER_PET_CHANGED")
identityFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
identityFrame:SetScript("OnEvent", function()
    playerName = UnitName("player")
    petName = UnitName("pet")
end)

local function getDirection(srcName, dstName)
    -- Returns direction, counterpartName
    if srcName == playerName then
        return OUTGOING, dstName
    elseif dstName == playerName then
        return INCOMING, srcName
    elseif petName and srcName == petName then
        return PET_OUT, dstName
    elseif petName and dstName == petName then
        return PET_IN, srcName
    end
    return nil, nil -- not relevant to player/pet
end

-- ============================================================================
-- Toggle state
-- ============================================================================

local cleuActive = false
local cleuFrame = CreateFrame("Frame")

local function enableCLEU()
    -- Only unregister CHAT_MSG_* events; keep core events (PLAYER_REGEN_*, UNIT_HEALTH, etc.)
    MikCEH.UnregisterCombatParseEvents()
    cleuFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    cleuActive = true
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WSBT CLEU|r: |cff00ff00ON|r (structured events)")
end

local function enableOriginal()
    cleuFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    MikCEH.RegisterCombatParseEvents()
    cleuActive = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WSBT CLEU|r: |cffff4444OFF|r (string parser)")
end

local function toggle()
    if cleuActive then enableOriginal() else enableCLEU() end
end

SLASH_WSBTCLEU1 = "/wsbtcleu"
SlashCmdList["WSBTCLEU"] = function(msg)
    if msg == "on" then
        if not cleuActive then enableCLEU() end
    elseif msg == "off" then
        if cleuActive then enableOriginal() end
    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WSBT CLEU|r: " .. (cleuActive and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    else
        toggle()
    end
end

-- ============================================================================
-- Partial action helpers
-- ============================================================================

local function applyPartials(eventData, resisted, blocked, absorbed, glancing, crushing)
    -- Only one partial action per event in MSBT's model
    if crushing and crushing == 1 then
        eventData.PartialActionType = PARTIAL_CRUSHING
    elseif glancing and glancing == 1 then
        eventData.PartialActionType = PARTIAL_GLANCING
    elseif absorbed and absorbed > 0 then
        eventData.PartialActionType = PARTIAL_ABSORB
        eventData.PartialAmount = absorbed
    elseif blocked and blocked > 0 then
        eventData.PartialActionType = PARTIAL_BLOCK
        eventData.PartialAmount = blocked
    elseif resisted and resisted > 0 then
        eventData.PartialActionType = PARTIAL_RESIST
        eventData.PartialAmount = resisted
    end
end

-- ============================================================================
-- CLEU handler
-- ============================================================================

local envActionMap = {
    DROWNING  = CEH.ACTIONTYPE_DROWNING,
    FALLING   = CEH.ACTIONTYPE_FALLING,
    FATIGUE   = CEH.ACTIONTYPE_FATIGUE,
    FIRE      = CEH.ACTIONTYPE_FIRE,
    LAVA      = CEH.ACTIONTYPE_LAVA,
    SLIME     = CEH.ACTIONTYPE_SLIME,
    EXHAUSTED = CEH.ACTIONTYPE_FATIGUE,
}

local cleuHandler

cleuHandler = function()
    if not CombatLogGetCurrentEventInfo then return end
    local sub, srcGUID, srcName, srcFlags, srcRaidFlags,
          dstGUID, dstName, dstFlags, dstRaidFlags = CombatLogGetCurrentEventInfo()
    if not sub then return end

    if not srcName or srcName == "" then srcName = "Unknown" end
    if not dstName or dstName == "" then dstName = "Unknown" end

    -- ========================================================================
    -- SWING_DAMAGE
    -- (base 9), amount, overkill, school, resisted, blocked,
    --           absorbed, critical, glancing, crushing
    -- ========================================================================

    if sub == "SWING_DAMAGE" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _,
              amount, overkill, school, resisted, blocked, absorbed,
              critical, glancing, crushing = CombatLogGetCurrentEventInfo()
        glancing = glancing and 1 or 0
        crushing = crushing and 1 or 0
        local hitType  = critical and HIT_CRIT or HIT_NORMAL

        local data = GetDamageData(dir, HIT, hitType, DMG_PHYSICAL, amount, nil, name)
        applyPartials(data, resisted, blocked, absorbed, glancing, crushing)
        SendEvent(data)

    -- ========================================================================
    -- SWING_MISSED
    -- args: missType(6), amountMissed(7)
    -- ========================================================================

    elseif sub == "SWING_MISSED" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _, missType = CombatLogGetCurrentEventInfo()
        local action = missActionMap[missType] or MISS
        local data = GetDamageData(dir, action, nil, nil, nil, nil, name)
        SendEvent(data)

    -- ========================================================================
    -- SPELL_DAMAGE / RANGE_DAMAGE / SPELL_PERIODIC_DAMAGE / DAMAGE_SHIELD / DAMAGE_SPLIT
    -- prefix: spellId(6), spellName(7), spellSchool(8)
    -- suffix: amount(9), overkill(10), school(11), resisted(12), blocked(13),
    --         absorbed(14), critical(15), glancing(16), crushing(17)
    -- ========================================================================

    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "DAMAGE_SHIELD"
        or sub == "DAMAGE_SPLIT" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              amount, overkill, school, resisted, blocked, absorbed,
              critical, glancing, crushing = CombatLogGetCurrentEventInfo()
        crushing = crushing and 1 or 0
        local hitType   = critical and HIT_CRIT or HIT_NORMAL
        local dmgType   = schoolToDamageType(school)

        local data = GetDamageData(dir, HIT, hitType, dmgType, amount, spellName, name)
        applyPartials(data, resisted, blocked, absorbed, 0, crushing)
        SendEvent(data)

    elseif sub == "SPELL_PERIODIC_DAMAGE" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              amount, overkill, school, resisted, blocked, absorbed = CombatLogGetCurrentEventInfo()
        -- numbers always non-nil from CombatLogGetCurrentEventInfo
        local dmgType   = schoolToDamageType(school)

        local data = GetDamageData(dir, HIT, HIT_DOT, dmgType, amount, spellName, name)
        applyPartials(data, resisted, 0, absorbed, 0, 0)
        SendEvent(data)

    -- ========================================================================
    -- SPELL_MISSED / RANGE_MISSED / SPELL_PERIODIC_MISSED / DAMAGE_SHIELD_MISSED
    -- prefix: spellId(6), spellName(7), spellSchool(8)
    -- suffix: missType(9), amountMissed(10)
    -- ========================================================================

    elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED"
        or sub == "SPELL_PERIODIC_MISSED" or sub == "DAMAGE_SHIELD_MISSED" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, missType = CombatLogGetCurrentEventInfo()
        local action = missActionMap[missType] or MISS
        local data = GetDamageData(dir, action, nil, nil, nil, spellName, name)
        SendEvent(data)

    -- ========================================================================
    -- ENVIRONMENTAL_DAMAGE
    -- args: envType(6), amount(7), overkill(8), school(9), resisted(10),
    --       blocked(11), absorbed(12), critical(13), glancing(14), crushing(15)
    -- ========================================================================

    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        if dstName ~= playerName then return end
        local _, _, _, _, _, _, _, _, _, envType, amount = CombatLogGetCurrentEventInfo()
        local action = envActionMap[envType] or HIT
        local data = GetDamageData(INCOMING, action, HIT_NORMAL, DMG_PHYSICAL, amount, nil, envType or "Environment")
        SendEvent(data)

    -- ========================================================================
    -- SPELL_HEAL / SPELL_PERIODIC_HEAL
    -- prefix: spellId(6), spellName(7), spellSchool(8)
    -- suffix: amount(9), overheal(10), absorbed(11), critical(12)
    -- ========================================================================

    elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool,
              amount, overheal, absorbed, critical = CombatLogGetCurrentEventInfo()
        local isPeriodic = (sub == "SPELL_PERIODIC_HEAL")

        local healType
        if isPeriodic then
            healType = HEAL_HOT
        elseif critical then
            healType = HEAL_CRIT
        else
            healType = HEAL_NORMAL
        end

        -- For outgoing heals, name = target (dstName); for incoming, name = healer (srcName)
        local data = GetHealData(dir, healType, amount, spellName, name)

        -- Overheal partial
        if overheal > 0 then
            data.PartialActionType = PARTIAL_OVERHEAL
            data.PartialAmount = overheal
        end

        SendEvent(data)

    -- ========================================================================
    -- SPELL_ENERGIZE / SPELL_PERIODIC_ENERGIZE
    -- prefix: spellId(6), spellName(7), spellSchool(8)
    -- suffix: amount(9), powerType(10)
    -- ========================================================================

    elseif sub == "SPELL_ENERGIZE" or sub == "SPELL_PERIODIC_ENERGIZE" then
        if dstName ~= playerName then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, amount, powerType = CombatLogGetCurrentEventInfo()
        local powerName  = powerTypeNames[powerType] or "Mana"
        local data = GetNotifData(NOTIF_POWER_GAIN, amount .. " " .. powerName, spellName)
        SendEvent(data)

    -- ========================================================================
    -- SPELL_PERIODIC_DRAIN / SPELL_PERIODIC_LEECH
    -- prefix: spellId(6), spellName(7), spellSchool(8)
    -- suffix: amount(9), powerType(10), extraAmount(11)
    -- ========================================================================

    elseif sub == "SPELL_PERIODIC_DRAIN" then
        if dstName ~= playerName then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, amount, powerType = CombatLogGetCurrentEventInfo()
        local powerName = powerTypeNames[powerType] or "Mana"
        local data = GetNotifData(NOTIF_POWER_LOSS, amount .. " " .. powerName, spellName)
        SendEvent(data)

    elseif sub == "SPELL_PERIODIC_LEECH" then
        local dir, name = getDirection(srcName, dstName)
        if not dir then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, amount = CombatLogGetCurrentEventInfo()
        local dmgType = schoolToDamageType(spellSchool)
        local data = GetDamageData(dir, HIT, HIT_DOT, dmgType, amount, spellName, name)
        SendEvent(data)

    -- ========================================================================
    -- AURA events
    -- prefix: spellId(6), spellName(7), spellSchool(8)
    -- suffix: auraType(9)
    -- ========================================================================

    elseif sub == "SPELL_AURA_APPLIED" then
        if dstName ~= playerName then return end
        local _, _, _, _, _, _, _, _, _,
              spellId, spellName, spellSchool, auraType = CombatLogGetCurrentEventInfo()
        if auraType == "DEBUFF" then
            local data = GetNotifData(NOTIF_DEBUFF, nil, spellName)
            SendEvent(data)
        else
            local data = GetNotifData(NOTIF_BUFF, nil, spellName)
            SendEvent(data)
        end

    elseif sub == "SPELL_AURA_REMOVED" then
        if dstName ~= playerName then return end
        local _, _, _, _, _, _, _, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
        local data = GetNotifData(NOTIF_BUFF_FADE, nil, spellName)
        SendEvent(data)

    -- ========================================================================
    -- PARTY_KILL — killing blow notification
    -- ========================================================================

    elseif sub == "PARTY_KILL" then
        if srcName ~= playerName then return end
        local notifType = CEH.NOTIFICATIONTYPE_NPC_KILLING_BLOW
        if CEH.recentlySelectedPlayers[dstName] then
            notifType = CEH.NOTIFICATIONTYPE_PC_KILLING_BLOW
        end
        local data = GetNotifData(notifType, nil, dstName)
        SendEvent(data)
    end
end

-- ============================================================================
-- Performance profiling (A/B per-combat)
-- ============================================================================

local profiling = false
local profCLEU = { events = 0, totalMs = 0, gcStart = 0 }
local profOrig = { events = 0, totalMs = 0, gcStart = 0 }
local profCurrent = nil

-- Hook the original MikCEH.OnEvent to measure original mode
-- Only count events that CLEU replaces (combat parse), not honor/XP/rep/health/etc.
local origOnEvent = MikCEH.OnEvent
local cleuReplacedLookup = CEH.cleuReplacedLookup
local function measuredOrigOnEvent()
    if profiling and profCurrent == profOrig and cleuReplacedLookup[event] then
        local before = debugprofilestop()
        origOnEvent()
        local after = debugprofilestop()
        profOrig.totalMs = profOrig.totalMs + (after - before)
        profOrig.events = profOrig.events + 1
    else
        origOnEvent()
    end
end
-- Patch MikCEH.OnEvent so the XML OnEvent handler calls the measured version
MikCEH.OnEvent = measuredOrigOnEvent

local cleuEventsSkipped = 0

local function measuredCLEUHandler()
    if profiling and profCurrent == profCLEU then
        -- Quick relevance check: is player or pet involved?
        local _, _, srcName, _, _, _, dstName = CombatLogGetCurrentEventInfo()
        srcName = srcName or ""
        dstName = dstName or ""
        local relevant = (srcName == playerName or dstName == playerName
            or (petName and (srcName == petName or dstName == petName)))

        local before = debugprofilestop()
        cleuHandler()
        local after = debugprofilestop()

        if relevant then
            profCLEU.totalMs = profCLEU.totalMs + (after - before)
            profCLEU.events = profCLEU.events + 1
        else
            cleuEventsSkipped = cleuEventsSkipped + 1
        end
    else
        cleuHandler()
    end
end

cleuFrame:SetScript("OnEvent", measuredCLEUHandler)

local function profReset(tbl)
    tbl.events = 0
    tbl.totalMs = 0
    tbl.gcStart = gcinfo()
end

local lastCLEUAvg = nil
local lastOrigAvg = nil

local function profReport(label, tbl)
    local gcEnd = gcinfo()
    local gcDelta = gcEnd - tbl.gcStart
    local totalMs = tbl.totalMs / 1000
    local avgUs = tbl.events > 0 and (tbl.totalMs / tbl.events) or 0

    if label == "CLEU" then
        lastCLEUAvg = avgUs
    else
        lastOrigAvg = avgUs
    end

    local skipMsg = ""
    if label == "CLEU" then
        skipMsg = string.format(" (%d skipped)", cleuEventsSkipped)
        cleuEventsSkipped = 0
    end
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00[WSBT %s]|r %d events%s, %.1fms total, %.1f us/event, %+.1f KB gc",
        label, tbl.events, skipMsg, totalMs, avgUs, gcDelta))

    if lastCLEUAvg and lastOrigAvg and lastOrigAvg > 0 then
        local pct = ((lastCLEUAvg - lastOrigAvg) / lastOrigAvg) * 100
        local sign = pct < 0 and "" or "+"
        local color = pct < 0 and "|cff00ff00" or "|cffff4444"
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "%s[WSBT CLEU vs ORIGINAL]|r %.1f vs %.1f us/event = %s%.1f%%|r %s",
            color, lastCLEUAvg, lastOrigAvg, sign, pct,
            pct < 0 and "(CLEU faster)" or "(ORIGINAL faster)"))
    end
end

local benchActive = true
local benchFrame = CreateFrame("Frame")

local function benchCombatStart()
    if not benchActive then return end
    profCurrent = cleuActive and profCLEU or profOrig
    profReset(profCurrent)
    debugprofilestart()
    profiling = true
    local label = cleuActive and "CLEU" or "ORIGINAL"
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[WSBT Bench]|r combat started, measuring %s", label))
end

local function benchCombatEnd()
    if not benchActive or not profiling then return end
    profiling = false
    local label = cleuActive and "CLEU" or "ORIGINAL"
    profReport(label, profCurrent)
    toggle()
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cff00ff00[WSBT Bench]|r next combat will use: %s", cleuActive and "CLEU" or "ORIGINAL"))
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

SLASH_WSBTBENCH1 = "/wsbtbench"
SlashCmdList["WSBTBENCH"] = function()
    benchActive = not benchActive
    if benchActive then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cff00ff00[WSBT Bench]|r enabled. Current mode: %s. Enter combat to begin.",
            cleuActive and "CLEU" or "ORIGINAL"))
    else
        profiling = false
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[WSBT Bench]|r disabled.")
    end
end

-- ============================================================================
-- Start in CLEU mode by default
-- ============================================================================

enableCLEU()
