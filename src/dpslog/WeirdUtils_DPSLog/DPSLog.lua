-- DPS Log Tracker — popup checklist for verifying all 35 COMBAT_LOG_EVENT subevents
--
-- All events share: arg1=subevent, arg2=sourceGUID, arg3=destGUID
-- Remaining args are subevent-specific (see layouts below).

-- ============================================================================
-- Reference tables
-- ============================================================================

-- Spell school bitmask (matches WotLK):
--   0x01 = Physical, 0x02 = Holy, 0x04 = Fire, 0x08 = Nature,
--   0x10 = Frost, 0x20 = Shadow, 0x40 = Arcane
-- Common combos: 0x03 = Holystrike, 0x05 = Flamestrike, 0x1C = Elemental,
--   0x7E = Magic (all non-physical), 0x7F = Chaos (all 7)

-- Power types: 0=Mana, 1=Rage, 2=Focus, 3=Energy, 4=Combo Points
local powerNames = { [0]="Mana", "Rage", "Focus", "Energy", "Combo Points" }

-- Miss types (string): "MISS", "DODGE", "PARRY", "BLOCK", "EVADE", "IMMUNE",
--   "DEFLECT", "RESIST", "ABSORB", "REFLECT"

-- Aura types (string): "BUFF", "DEBUFF"

-- Environmental types (string): "EXHAUSTED", "DROWNING", "FALLING", "LAVA",
--   "SLIME", "FIRE"

-- SWING_DAMAGE arg10 flags bitmask:
--   bit 0 (value 1) = glancing hit
--   bit 1 (value 2) = crushing blow
--   bit 2 (value 4) = offhand swing
-- Extract: glancing = (math.mod(flags, 2) == 1)
--          crushing = (math.mod(math.floor(flags / 2), 2) == 1)
--          offhand  = (math.mod(math.floor(flags / 4), 2) == 1)
-- Combined: offhand glancing = 5, offhand crushing = 6, etc.

-- ============================================================================
-- Helpers
-- ============================================================================

local function schoolName(school)
    if school == 1 then return "Physical"
    elseif school == 2 then return "Holy"
    elseif school == 4 then return "Fire"
    elseif school == 8 then return "Nature"
    elseif school == 16 then return "Frost"
    elseif school == 32 then return "Shadow"
    elseif school == 64 then return "Arcane"
    else return "School:" .. (school or "?") end
end

local function s(v)
    if v == nil then return "nil" end
    return tostring(v)
end

-- ============================================================================
-- Subevent definitions — ordered list of all 34
-- ============================================================================

local SUBEVENTS = {
    -- Pattern A: fireCombatLog (sub, src, dst, n1..n7)
    "SPELL_DAMAGE",
    "RANGE_DAMAGE",
    "SPELL_PERIODIC_DAMAGE",
    "DAMAGE_SHIELD",
    "SWING_DAMAGE",
    "SPELL_HEAL",
    "SPELL_PERIODIC_HEAL",
    "SPELL_ENERGIZE",
    "SPELL_PERIODIC_ENERGIZE",
    "SPELL_PERIODIC_LEECH",
    "SPELL_PERIODIC_DRAIN",
    "SPELL_EXTRA_ATTACKS",
    -- Pattern B: fireSwingMissed (sub, src, dst, missType)
    "SWING_MISSED",
    -- Pattern C: fireSpellStr (sub, src, dst, spellId, school, strArg)
    "SPELL_MISSED",
    "SPELL_PERIODIC_MISSED",
    "DAMAGE_SHIELD_MISSED",
    "RANGE_MISSED",
    "SPELL_AURA_APPLIED",
    "SPELL_AURA_REMOVED",
    "SPELL_AURA_REFRESH",
    "SPELL_AURA_BROKEN",
    "SPELL_CAST_FAILED",
    -- Pattern D: fireSpell (sub, src, dst, spellId, school)
    "SPELL_CAST_START",
    "SPELL_CAST_SUCCESS",
    "SPELL_SUMMON",
    "SPELL_RESURRECT",
    "SPELL_INSTAKILL",
    -- Pattern E: fireBase (sub, src, dst)
    "UNIT_DIED",
    "PARTY_KILL",
    -- Pattern F: fireSpellStrD (sub, src, dst, spellId, school, strArg, amount)
    "SPELL_AURA_APPLIED_DOSE",
    "SPELL_AURA_REMOVED_DOSE",
    -- Pattern G: fireSpellDispel (sub, src, dst, spellId, school, extraId, extraSchool, auraType)
    "SPELL_DISPEL",
    "SPELL_INTERRUPT",
    "SPELL_AURA_BROKEN_SPELL",
    -- Pattern H: fireEnvDamage (sub, src, dst, envStr, amount, school, absorbed, 0, 0)
    "ENVIRONMENTAL_DAMAGE",
    -- New: damage split, dispel failed, unit destroyed
    "DAMAGE_SPLIT",
    "SPELL_DISPEL_FAILED",
    "UNIT_DESTROYED",
}

local NUM_SUBEVENTS = 37

-- Reverse lookup: subevent name -> index
local subeventIndex = {}
for i = 1, NUM_SUBEVENTS do
    subeventIndex[SUBEVENTS[i]] = i
end

-- Tracking state
local seen = {}       -- [index] = true
local seenArgs = {}   -- [index] = formatted arg string
local seenCount = 0

-- ============================================================================
-- Arg formatters per subevent (return a short summary string)
-- ============================================================================

local function fmtSpellDmg(spellId, amount, school, resisted, absorbed, blocked, critical)
    local c = (critical == 1) and " CRIT" or ""
    return format("spell=%s amt=%s %s res=%s abs=%s blk=%s%s",
        s(spellId), s(amount), schoolName(school or 0), s(resisted), s(absorbed), s(blocked), c)
end

local function fmtSwingDmg(amount, school, resisted, absorbed, blocked, critical, flags)
    local c = (critical == 1) and " CRIT" or ""
    local f = ""
    if flags and flags > 0 then
        if math.mod(flags, 2) == 1 then f = f .. " GLANC" end
        if math.mod(math.floor(flags / 2), 2) == 1 then f = f .. " CRUSH" end
        if math.mod(math.floor(flags / 4), 2) == 1 then f = f .. " OH" end
    end
    return format("amt=%s %s res=%s abs=%s blk=%s%s%s",
        s(amount), schoolName(school or 0), s(resisted), s(absorbed), s(blocked), c, f)
end

local argFormatters = {}

-- Pattern A — numeric args
argFormatters["SPELL_DAMAGE"] = function(a4,a5,a6,a7,a8,a9,a10) return fmtSpellDmg(a4,a5,a6,a7,a8,a9,a10) end
argFormatters["RANGE_DAMAGE"] = function(a4,a5,a6,a7,a8,a9,a10) return fmtSpellDmg(a4,a5,a6,a7,a8,a9,a10) end
argFormatters["SPELL_PERIODIC_DAMAGE"] = function(a4,a5,a6,a7,a8,a9,a10) return fmtSpellDmg(a4,a5,a6,a7,a8,a9,a10) end
argFormatters["DAMAGE_SHIELD"] = function(a4,a5,a6,a7,a8,a9,a10) return fmtSpellDmg(a4,a5,a6,a7,a8,a9,a10) end
argFormatters["SWING_DAMAGE"] = function(a4,a5,a6,a7,a8,a9,a10) return fmtSwingDmg(a4,a5,a6,a7,a8,a9,a10) end
argFormatters["SPELL_HEAL"] = function(a4,a5,a6,a7,a8)
    local c = (a8 == 1) and " CRIT" or ""
    return format("spell=%s amt=%s oh=%s abs=%s%s", s(a4), s(a5), s(a6), s(a7), c)
end
argFormatters["SPELL_PERIODIC_HEAL"] = function(a4,a5) return format("spell=%s amt=%s", s(a4), s(a5)) end
argFormatters["SPELL_ENERGIZE"] = function(a4,a5,a6)
    return format("spell=%s amt=%s type=%s", s(a4), s(a5), powerNames[a6] or s(a6))
end
argFormatters["SPELL_PERIODIC_ENERGIZE"] = function(a4,a5,a6,a7)
    return format("spell=%s amt=%s over=%s type=%s", s(a4), s(a5), s(a6), powerNames[a7] or s(a7))
end
argFormatters["SPELL_PERIODIC_LEECH"] = function(a4,a5,a6,a7,a8,a9)
    return format("spell=%s amt=%s %s gain=%s abs=%s res=%s", s(a4), s(a5), schoolName(a6 or 0), s(a7), s(a8), s(a9))
end
argFormatters["SPELL_PERIODIC_DRAIN"] = function(a4,a5,a6,a7)
    return format("spell=%s amt=%s type=%s extra=%s", s(a4), s(a5), powerNames[a6] or s(a6), s(a7))
end
argFormatters["SPELL_EXTRA_ATTACKS"] = function(a4,a5,a6)
    return format("spell=%s school=%s amt=%s", s(a4), s(a5), s(a6))
end

-- Pattern B — swing missed
argFormatters["SWING_MISSED"] = function(a4) return s(a4) end

-- Pattern C — spell + string
argFormatters["SPELL_MISSED"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["SPELL_PERIODIC_MISSED"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["DAMAGE_SHIELD_MISSED"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["RANGE_MISSED"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["SPELL_AURA_APPLIED"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["SPELL_AURA_REMOVED"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["SPELL_AURA_REFRESH"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["SPELL_AURA_BROKEN"] = function(a4,a5,a6) return format("spell=%s %s %s", s(a4), schoolName(a5 or 0), s(a6)) end
argFormatters["SPELL_CAST_FAILED"] = function(a4,a5,a6) return format("spell=%s %s reason=%s", s(a4), schoolName(a5 or 0), s(a6)) end

-- Pattern D — spell only
argFormatters["SPELL_CAST_START"] = function(a4,a5) return format("spell=%s %s", s(a4), schoolName(a5 or 0)) end
argFormatters["SPELL_CAST_SUCCESS"] = function(a4,a5) return format("spell=%s %s", s(a4), schoolName(a5 or 0)) end
argFormatters["SPELL_SUMMON"] = function(a4,a5) return format("spell=%s %s", s(a4), schoolName(a5 or 0)) end
argFormatters["SPELL_RESURRECT"] = function(a4,a5) return format("spell=%s %s", s(a4), schoolName(a5 or 0)) end
argFormatters["SPELL_INSTAKILL"] = function(a4,a5) return format("spell=%s %s", s(a4), schoolName(a5 or 0)) end

-- Pattern E — base (no extra args)
argFormatters["UNIT_DIED"] = function() return "" end
argFormatters["PARTY_KILL"] = function() return "" end

-- Pattern F — spell + string + amount
argFormatters["SPELL_AURA_APPLIED_DOSE"] = function(a4,a5,a6,a7) return format("spell=%s %s %s x%s", s(a4), schoolName(a5 or 0), s(a6), s(a7)) end
argFormatters["SPELL_AURA_REMOVED_DOSE"] = function(a4,a5,a6,a7) return format("spell=%s %s %s x%s", s(a4), schoolName(a5 or 0), s(a6), s(a7)) end

-- Pattern G — dispel/interrupt
argFormatters["SPELL_DISPEL"] = function(a4,a5,a6,a7,a8)
    return format("spell=%s extra=%s %s %s", s(a4), s(a6), schoolName(a7 or 0), s(a8))
end
argFormatters["SPELL_INTERRUPT"] = function(a4,a5,a6,a7)
    return format("spell=%s extra=%s %s", s(a4), s(a6), schoolName(a7 or 0))
end
argFormatters["SPELL_AURA_BROKEN_SPELL"] = function(a4,a5,a6,a7,a8)
    return format("spell=%s extra=%s %s %s", s(a4), s(a6), schoolName(a7 or 0), s(a8))
end

-- Pattern H — environmental
argFormatters["ENVIRONMENTAL_DAMAGE"] = function(a4,a5,a6,a7)
    return format("env=%s amt=%s %s abs=%s", s(a4), s(a5), schoolName(a6 or 0), s(a7))
end

-- New subevents
argFormatters["DAMAGE_SPLIT"] = function(a4,a5,a6,a7,a8,a9,a10) return fmtSpellDmg(a4,a5,a6,a7,a8,a9,a10) end
argFormatters["SPELL_DISPEL_FAILED"] = function(a4,a5) return format("spell=%s %s", s(a4), schoolName(a5 or 0)) end
argFormatters["UNIT_DESTROYED"] = function() return "" end

-- ============================================================================
-- Chat output handlers (preserved from original)
-- ============================================================================

local chatHandlers = {}

chatHandlers["SPELL_DAMAGE"] = function(src, dst, spellId, amount, school, resisted, absorbed, blocked, critical)
    local crit = critical == 1 and " (CRIT)" or ""
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SPELL_DAMAGE|r %s -> %s: spell %d for %d %s%s", src, dst, spellId, amount, schoolName(school), crit))
end
chatHandlers["RANGE_DAMAGE"] = function(src, dst, spellId, amount, school, resisted, absorbed, blocked, critical)
    local crit = critical == 1 and " (CRIT)" or ""
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000RANGE_DAMAGE|r %s -> %s: spell %d for %d %s%s", src, dst, spellId, amount, schoolName(school), crit))
end
chatHandlers["SWING_DAMAGE"] = function(src, dst, amount, school, resisted, absorbed, blocked, critical, flags)
    local extra = ""
    if critical == 1 then extra = extra .. " CRIT" end
    if flags then
        if math.mod(flags, 2) == 1 then extra = extra .. " GLANCING" end
        if math.mod(math.floor(flags / 2), 2) == 1 then extra = extra .. " CRUSHING" end
        if math.mod(math.floor(flags / 4), 2) == 1 then extra = extra .. " (OH)" end
    end
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SWING_DAMAGE|r %s -> %s: %d%s", src, dst, amount, extra))
end
chatHandlers["SWING_MISSED"] = function(src, dst, missType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaSWING_MISSED|r %s -> %s: %s", src, dst, missType))
end
chatHandlers["SPELL_MISSED"] = function(src, dst, spellId, spellSchool, missType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaSPELL_MISSED|r %s -> %s: spell %d %s", src, dst, spellId, missType))
end
chatHandlers["RANGE_MISSED"] = function(src, dst, spellId, spellSchool, missType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cfffaaaaaaRANGE_MISSED|r %s -> %s: spell %d %s", src, dst, spellId, missType))
end
chatHandlers["ENVIRONMENTAL_DAMAGE"] = function(src, dst, envType, amount, school, absorbed)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800ENVIRONMENTAL_DAMAGE|r %s: %s for %d", dst, envType, amount))
end
chatHandlers["DAMAGE_SHIELD"] = function(src, dst, spellId, amount, school)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff4400DAMAGE_SHIELD|r %s -> %s: %d %s", src, dst, amount, schoolName(school)))
end
chatHandlers["SPELL_HEAL"] = function(src, dst, spellId, amount, overheal, absorbed, critical)
    local crit = critical == 1 and " (CRIT)" or ""
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff00ff00SPELL_HEAL|r %s -> %s: spell %d for %d%s", src, dst, spellId, amount, crit))
end
chatHandlers["SPELL_PERIODIC_HEAL"] = function(src, dst, spellId, amount)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff00cc00SPELL_PERIODIC_HEAL|r %s -> %s: spell %d for %d", src, dst, spellId, amount))
end
chatHandlers["SPELL_PERIODIC_DAMAGE"] = function(src, dst, spellId, amount, school)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffcc0000SPELL_PERIODIC_DAMAGE|r %s -> %s: spell %d for %d %s", src, dst, spellId, amount, schoolName(school)))
end
chatHandlers["SPELL_ENERGIZE"] = function(src, dst, spellId, amount, powerType)
    local pname = powerNames[powerType] or "Unknown"
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff4488ffSPELL_ENERGIZE|r %s -> %s: spell %d +%d %s", src, dst, spellId, amount, pname))
end
chatHandlers["SPELL_PERIODIC_ENERGIZE"] = function(src, dst, spellId, amount, overEnergize, powerType)
    local pname = powerNames[powerType] or "Unknown"
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff4488ffSPELL_PERIODIC_ENERGIZE|r %s -> %s: spell %d +%d %s", src, dst, spellId, amount, pname))
end
chatHandlers["SPELL_PERIODIC_LEECH"] = function(src, dst, spellId, amount, school, gained)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8844ffSPELL_PERIODIC_LEECH|r %s -> %s: spell %d drained %d, gained %d", src, dst, spellId, amount, gained or 0))
end
chatHandlers["SPELL_PERIODIC_DRAIN"] = function(src, dst, spellId, amount, powerType, extraAmount)
    local pname = powerNames[powerType] or "Unknown"
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8844ffSPELL_PERIODIC_DRAIN|r %s -> %s: spell %d drained %d %s, gained %d", src, dst, spellId, amount, pname, extraAmount or 0))
end
chatHandlers["SPELL_AURA_APPLIED"] = function(src, dst, spellId, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8888ffSPELL_AURA_APPLIED|r %s: spell %d (%s, %s)", dst, spellId, auraType, schoolName(spellSchool)))
end
chatHandlers["SPELL_AURA_REMOVED"] = function(src, dst, spellId, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff6666ccSPELL_AURA_REMOVED|r %s: spell %d (%s)", dst, spellId, auraType))
end
chatHandlers["SPELL_AURA_APPLIED_DOSE"] = function(src, dst, spellId, spellSchool, auraType, stacks)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8888ffSPELL_AURA_APPLIED_DOSE|r %s: spell %d x%d (%s)", dst, spellId, stacks, auraType))
end
chatHandlers["SPELL_AURA_REMOVED_DOSE"] = function(src, dst, spellId, spellSchool, auraType, stacks)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff6666ccSPELL_AURA_REMOVED_DOSE|r %s: spell %d x%d (%s)", dst, spellId, stacks, auraType))
end
chatHandlers["SPELL_AURA_REFRESH"] = function(src, dst, spellId, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff7777ddSPELL_AURA_REFRESH|r %s: spell %d (%s)", dst, spellId, auraType))
end
chatHandlers["SPELL_AURA_BROKEN"] = function(src, dst, spellId, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_AURA_BROKEN|r %s -> %s: spell %d broken by melee (%s)", src, dst, spellId, auraType))
end
chatHandlers["SPELL_AURA_BROKEN_SPELL"] = function(src, dst, spellId, spellSchool, extraSpellId, extraSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_AURA_BROKEN_SPELL|r %s -> %s: spell %d broken by spell %d (%s)", src, dst, spellId, extraSpellId, auraType))
end
chatHandlers["SPELL_CAST_START"] = function(src, dst, spellId, spellSchool)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffffff00SPELL_CAST_START|r %s: spell %d (%s)", src, spellId, schoolName(spellSchool)))
end
chatHandlers["SPELL_CAST_SUCCESS"] = function(src, dst, spellId)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffffff00SPELL_CAST_SUCCESS|r %s: spell %d", src, spellId))
end
chatHandlers["SPELL_CAST_FAILED"] = function(src, dst, spellId, spellSchool, failedType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff4444SPELL_CAST_FAILED|r %s: spell %d (%s)", src, spellId, failedType))
end
chatHandlers["SPELL_INTERRUPT"] = function(src, dst, spellId, spellSchool, extraSpellId, extraSchool)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_INTERRUPT|r %s interrupted %s: spell %d (%s)", src, dst, extraSpellId, schoolName(extraSchool)))
end
chatHandlers["SPELL_DISPEL"] = function(src, dst, spellId, spellSchool, extraSpellId, extraSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ffffSPELL_DISPEL|r %s dispelled %s: spell %d (%s, %s)", src, dst, extraSpellId, auraType, schoolName(extraSchool)))
end
chatHandlers["SPELL_EXTRA_ATTACKS"] = function(src, dst, spellId)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_EXTRA_ATTACKS|r %s: spell %d", src, spellId))
end
chatHandlers["SPELL_SUMMON"] = function(src, dst, spellId)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ff88SPELL_SUMMON|r %s summoned %s: spell %d", src, dst, spellId))
end
chatHandlers["SPELL_RESURRECT"] = function(src, dst, spellId)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ff88SPELL_RESURRECT|r %s resurrected %s: spell %d", src, dst, spellId))
end
chatHandlers["SPELL_INSTAKILL"] = function(src, dst, spellId)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SPELL_INSTAKILL|r %s killed %s: spell %d", src, dst, spellId))
end
chatHandlers["UNIT_DIED"] = function(src, dst)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff888888UNIT_DIED|r %s", dst))
end
chatHandlers["PARTY_KILL"] = function(src, dst)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800PARTY_KILL|r %s killed %s", src, dst))
end
chatHandlers["SPELL_PERIODIC_MISSED"] = function(src, dst, spellId, spellSchool, missType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaSPELL_PERIODIC_MISSED|r %s -> %s: spell %d %s", src, dst, spellId, missType))
end
chatHandlers["DAMAGE_SHIELD_MISSED"] = function(src, dst, spellId, spellSchool, missType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaDAMAGE_SHIELD_MISSED|r %s -> %s: spell %d %s", src, dst, spellId, missType))
end
chatHandlers["DAMAGE_SPLIT"] = function(src, dst, spellId, amount, school)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff6600DAMAGE_SPLIT|r %s -> %s: spell %d for %d %s", src, dst, spellId, amount, schoolName(school)))
end
chatHandlers["SPELL_DISPEL_FAILED"] = function(src, dst, spellId, spellSchool)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff888888SPELL_DISPEL_FAILED|r %s -> %s: spell %d resisted", src, dst, spellId))
end
chatHandlers["UNIT_DESTROYED"] = function(src, dst)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff666666UNIT_DESTROYED|r %s", dst))
end

-- ============================================================================
-- UI — Draggable popup tracker
-- ============================================================================

local ROW_HEIGHT = 14
local FRAME_WIDTH = 420
local VISIBLE_ROWS = 20
local FRAME_HEIGHT = ROW_HEIGHT * VISIBLE_ROWS + 52  -- title + counter + padding

local main = CreateFrame("Frame", "DPSLogTracker", UIParent)
main:SetWidth(FRAME_WIDTH)
main:SetHeight(FRAME_HEIGHT)
main:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
main:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
main:SetBackdropColor(0, 0, 0, 0.85)
main:EnableMouse(true)
main:SetMovable(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", function() main:StartMoving() end)
main:SetScript("OnDragStop", function() main:StopMovingOrSizing() end)
main:SetFrameStrata("DIALOG")
main:SetClampedToScreen(true)

-- Title
local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -10)
title:SetText("DPS Log Tracker")
title:SetTextColor(1, 0.82, 0)

-- Close button
local closeBtn = CreateFrame("Button", nil, main, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", main, "TOPRIGHT", -2, -2)
closeBtn:SetScript("OnClick", function() main:Hide() end)

-- Counter
local counter = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
counter:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
counter:SetTextColor(0.7, 0.7, 0.7)

local function updateCounter()
    counter:SetText(format("Seen: %d/%d", seenCount, NUM_SUBEVENTS))
end
updateCounter()

-- Scroll frame
local scrollFrame = CreateFrame("ScrollFrame", "DPSLogTrackerScroll", main, "FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", main, "TOPLEFT", 8, -48)
scrollFrame:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -28, 8)

-- Row frames
local rows = {}
for i = 1, VISIBLE_ROWS do
    local row = CreateFrame("Frame", nil, main)
    row:SetWidth(FRAME_WIDTH - 40)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 2, -((i - 1) * ROW_HEIGHT))

    local check = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    check:SetPoint("LEFT", row, "LEFT", 0, 0)
    check:SetWidth(20)
    check:SetJustifyH("LEFT")

    local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameStr:SetPoint("LEFT", check, "RIGHT", 0, 0)
    nameStr:SetWidth(FRAME_WIDTH - 60)
    nameStr:SetJustifyH("LEFT")

    row.check = check
    row.nameStr = nameStr
    rows[i] = row
end

local function updateRows()
    local offset = FauxScrollFrame_GetOffset(scrollFrame)
    for i = 1, VISIBLE_ROWS do
        local idx = offset + i
        local row = rows[i]
        if idx <= NUM_SUBEVENTS then
            row:Show()
            if seen[idx] then
                row.check:SetText("|cff00ff00x|r")
                local argStr = seenArgs[idx]
                if argStr and argStr ~= "" then
                    row.nameStr:SetText("|cffffffff" .. SUBEVENTS[idx] .. "|r |cffaaaaaa" .. argStr .. "|r")
                else
                    row.nameStr:SetText("|cffffffff" .. SUBEVENTS[idx] .. "|r")
                end
            else
                row.check:SetText("|cff666666-|r")
                row.nameStr:SetText("|cff666666" .. SUBEVENTS[idx] .. "|r")
            end
        else
            row:Hide()
        end
    end
    FauxScrollFrame_Update(scrollFrame, NUM_SUBEVENTS, VISIBLE_ROWS, ROW_HEIGHT)
end

scrollFrame:SetScript("OnVerticalScroll", function()
    FauxScrollFrame_OnVerticalScroll(ROW_HEIGHT, updateRows)
end)

updateRows()

-- Reset button
local resetBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
resetBtn:SetWidth(60)
resetBtn:SetHeight(18)
resetBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, -6)
resetBtn:SetText("Reset")
resetBtn:SetScript("OnClick", function()
    for i = 1, NUM_SUBEVENTS do
        seen[i] = nil
        seenArgs[i] = nil
    end
    seenCount = 0
    updateCounter()
    updateRows()
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSLog Tracker|r reset.")
end)

-- ============================================================================
-- Event dispatcher
-- ============================================================================

local function print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT")

eventFrame:SetScript("OnEvent", function()
    -- if event == "PLAYER_LOGIN" then
    --     eventFrame:RegisterEvent("COMBAT_LOG_EVENT")
    --     DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSLog|r registered COMBAT_LOG_EVENT")
    --     return
    -- end
    
    local subevent = arg1
    if not subevent then return end

    -- Tracker update (first encounter only)
    local idx = subeventIndex[subevent]
    if idx and not seen[idx] then
        -- Chat output (first occurrence only)
        local chatHandler = chatHandlers[subevent]
        if chatHandler then
            chatHandler(arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10)
        else
            DEFAULT_CHAT_FRAME:AddMessage(format("|cffccccccUNHANDLED|r %s", subevent))
        end
        seen[idx] = true
        seenCount = seenCount + 1
        local formatter = argFormatters[subevent]
        if formatter then
            seenArgs[idx] = formatter(arg4, arg5, arg6, arg7, arg8, arg9, arg10)
        else
            seenArgs[idx] = ""
        end
        updateCounter()
        updateRows()
    end
end)

-- ============================================================================
-- Slash command
-- ============================================================================

SLASH_DPSLOG1 = "/dpslog"
SlashCmdList["DPSLOG"] = function(msg)
    if main:IsVisible() then
        main:Hide()
    else
        main:Show()
    end
end

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSLog Tracker|r loaded — /dpslog to toggle window")
