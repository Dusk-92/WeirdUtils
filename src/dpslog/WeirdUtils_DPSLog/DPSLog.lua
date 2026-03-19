-- DPS Log Tracker -- WotLK CLEU parity for vanilla 1.12.1
--
-- Event layout matches WotLK 3.3.5 COMBAT_LOG_EVENT_UNFILTERED (see WOTLK_CLEU_SPEC.md).
-- Base: arg1=subevent, arg2=sourceGUID, arg3=sourceName, arg4=destGUID, arg5=destName
-- Spell prefix: spellId, spellName, spellSchool
-- Env prefix: envType (string)
-- Swing prefix: (none)

-- ============================================================================
-- Reference
-- ============================================================================

-- School bitmask: 1=Physical, 2=Holy, 4=Fire, 8=Nature, 16=Frost, 32=Shadow, 64=Arcane
-- Power types: 0=Mana, 1=Rage, 2=Focus, 3=Energy, 4=Combo, -2=Health
-- Miss types: MISS, DODGE, PARRY, BLOCK, EVADE, IMMUNE, DEFLECT, RESIST, ABSORB, REFLECT
-- Aura types: BUFF, DEBUFF
-- Env types: EXHAUSTED, DROWNING, FALLING, LAVA, SLIME, FIRE

local powerNames = { [0]="Mana", "Rage", "Focus", "Energy", "Combo Points" }

-- ============================================================================
-- Helpers
-- ============================================================================

local format = string.format

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

local function displayName(name, guid)
    if name and name ~= "" then return name end
    return guid or "?"
end

-- ============================================================================
-- Arg position constants -- CombatLogGetCurrentEventInfo() layout
-- ============================================================================

-- CombatLogGetCurrentEventInfo() returns:
--   sub, srcGUID, srcName, srcFlags, srcRaidFlags,
--   dstGUID, dstName, dstFlags, dstRaidFlags, p1, p2, p3, ...
--
-- p1.. positions (after 9 base fields):
-- Spell prefix: p1=spellId, p2=spellName, p3=spellSchool, p4+=suffix
-- Swing prefix: (none) p1+=suffix
-- Env prefix: p1=envType, p2+=suffix
--
-- _DAMAGE suffix: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
--   Spell: p4-p12    Swing: p1-p9    Env: p2-p10
-- _MISSED suffix: missType, amountMissed
--   Spell: p4-p5    Swing: p1-p2
-- _HEAL suffix: amount, overheal, absorbed, critical
--   Spell: p4-p7
-- _ENERGIZE suffix: amount, powerType
--   Spell: p4-p5
-- _LEECH/_DRAIN suffix: amount, powerType, extraAmount
--   Spell: p4-p6
-- _EXTRA_ATTACKS suffix: amount
--   Spell: p4
-- _INTERRUPT/_DISPEL_FAILED suffix: extraSpellId, extraSpellName, extraSchool
--   Spell: p4-p6
-- _DISPEL/_AURA_BROKEN_SPELL suffix: extraSpellId, extraSpellName, extraSchool, auraType
--   Spell: p4-p7
-- _AURA_APPLIED/REMOVED/REFRESH/BROKEN: auraType
--   Spell: p4
-- _AURA_DOSE: auraType, amount
--   Spell: p4-p5
-- _CAST_FAILED: failedType
--   Spell: p4

-- ============================================================================
-- Subevent definitions -- variant checklist
-- ============================================================================

-- { displayName, subevent, [variantField], [variantValue] }
-- Variant field indices are positions in the full CombatLogGetCurrentEventInfo() return:
-- 1=sub, 2=srcGUID, 3=srcName, 4=srcFlags, 5=srcRaidFlags,
-- 6=dstGUID, 7=dstName, 8=dstFlags, 9=dstRaidFlags,
-- 10=p1, 11=p2, 12=p3, 13=p4, 14=p5, 15=p6, 16=p7, 17=p8, 18=p9, ...
-- Spell prefix: p1(10)=spellId, p2(11)=spellName, p3(12)=spellSchool
-- Swing prefix: (none), p1(10) is first suffix field
-- Env prefix: p1(10)=envType

local SUBEVENTS = {
    -- Spell damage: p10(19)=critical
    { "SPELL_DAMAGE",            "SPELL_DAMAGE" },
    { "SPELL_DAMAGE (crit)",     "SPELL_DAMAGE",          19 },  -- p10=critical (truthy)
    { "RANGE_DAMAGE",            "RANGE_DAMAGE" },
    { "RANGE_DAMAGE (crit)",     "RANGE_DAMAGE",          19 },
    { "SPELL_PERIODIC_DAMAGE",   "SPELL_PERIODIC_DAMAGE" },
    { "DAMAGE_SHIELD",           "DAMAGE_SHIELD" },
    { "DAMAGE_SPLIT",            "DAMAGE_SPLIT" },
    -- Swing damage: p7(16)=critical, p8(17)=glancing, p9(18)=crushing
    { "SWING_DAMAGE",            "SWING_DAMAGE" },
    { "SWING_DAMAGE (crit)",     "SWING_DAMAGE",          16 },
    { "SWING_DAMAGE (glancing)", "SWING_DAMAGE",          17 },
    { "SWING_DAMAGE (crushing)", "SWING_DAMAGE",          18 },
    -- Env damage: p1(10)=envType
    { "ENVIRONMENTAL (DROWNING)",  "ENVIRONMENTAL_DAMAGE", 10, "DROWNING" },
    { "ENVIRONMENTAL (FALLING)",   "ENVIRONMENTAL_DAMAGE", 10, "FALLING" },
    { "ENVIRONMENTAL (LAVA)",      "ENVIRONMENTAL_DAMAGE", 10, "LAVA" },
    { "ENVIRONMENTAL (SLIME)",     "ENVIRONMENTAL_DAMAGE", 10, "SLIME" },
    { "ENVIRONMENTAL (FIRE)",      "ENVIRONMENTAL_DAMAGE", 10, "FIRE" },
    { "ENVIRONMENTAL (EXHAUSTED)", "ENVIRONMENTAL_DAMAGE", 10, "EXHAUSTED" },
    -- Swing missed: p1(10)=missType
    { "SWING_MISSED (MISS)",     "SWING_MISSED",    10, "MISS" },
    { "SWING_MISSED (DODGE)",    "SWING_MISSED",    10, "DODGE" },
    { "SWING_MISSED (PARRY)",    "SWING_MISSED",    10, "PARRY" },
    { "SWING_MISSED (BLOCK)",    "SWING_MISSED",    10, "BLOCK" },
    { "SWING_MISSED (EVADE)",    "SWING_MISSED",    10, "EVADE" },
    { "SWING_MISSED (IMMUNE)",   "SWING_MISSED",    10, "IMMUNE" },
    { "SWING_MISSED (RESIST)",   "SWING_MISSED",    10, "RESIST" },
    { "SWING_MISSED (ABSORB)",   "SWING_MISSED",    10, "ABSORB" },
    -- Spell missed: p4(13)=missType
    { "SPELL_MISSED (MISS)",     "SPELL_MISSED",    13, "MISS" },
    { "SPELL_MISSED (DODGE)",    "SPELL_MISSED",    13, "DODGE" },
    { "SPELL_MISSED (PARRY)",    "SPELL_MISSED",    13, "PARRY" },
    { "SPELL_MISSED (IMMUNE)",   "SPELL_MISSED",    13, "IMMUNE" },
    { "SPELL_MISSED (RESIST)",   "SPELL_MISSED",    13, "RESIST" },
    { "SPELL_MISSED (ABSORB)",   "SPELL_MISSED",    13, "ABSORB" },
    { "SPELL_MISSED (DEFLECT)",  "SPELL_MISSED",    13, "DEFLECT" },
    { "SPELL_MISSED (REFLECT)",  "SPELL_MISSED",    13, "REFLECT" },
    { "RANGE_MISSED",            "RANGE_MISSED" },
    { "SPELL_PERIODIC_MISSED",   "SPELL_PERIODIC_MISSED" },
    { "DAMAGE_SHIELD_MISSED",    "DAMAGE_SHIELD_MISSED" },
    -- Heals: p7(16)=critical
    { "SPELL_HEAL",              "SPELL_HEAL" },
    { "SPELL_HEAL (crit)",       "SPELL_HEAL",      16 },
    { "SPELL_PERIODIC_HEAL",     "SPELL_PERIODIC_HEAL" },
    -- Power
    { "SPELL_ENERGIZE",          "SPELL_ENERGIZE" },
    { "SPELL_PERIODIC_ENERGIZE", "SPELL_PERIODIC_ENERGIZE" },
    { "SPELL_PERIODIC_DRAIN",    "SPELL_PERIODIC_DRAIN" },
    { "SPELL_PERIODIC_LEECH",    "SPELL_PERIODIC_LEECH" },
    -- Auras: p4(13)=auraType
    { "SPELL_AURA_APPLIED (BUFF)",   "SPELL_AURA_APPLIED",  13, "BUFF" },
    { "SPELL_AURA_APPLIED (DEBUFF)", "SPELL_AURA_APPLIED",  13, "DEBUFF" },
    { "SPELL_AURA_REMOVED (BUFF)",   "SPELL_AURA_REMOVED",  13, "BUFF" },
    { "SPELL_AURA_REMOVED (DEBUFF)", "SPELL_AURA_REMOVED",  13, "DEBUFF" },
    { "SPELL_AURA_APPLIED_DOSE",     "SPELL_AURA_APPLIED_DOSE" },
    { "SPELL_AURA_REMOVED_DOSE",     "SPELL_AURA_REMOVED_DOSE" },
    { "SPELL_AURA_REFRESH",          "SPELL_AURA_REFRESH" },
    { "SPELL_AURA_BROKEN",           "SPELL_AURA_BROKEN" },
    { "SPELL_AURA_BROKEN_SPELL",     "SPELL_AURA_BROKEN_SPELL" },
    -- Casts
    { "SPELL_CAST_START",        "SPELL_CAST_START" },
    { "SPELL_CAST_SUCCESS",      "SPELL_CAST_SUCCESS" },
    { "SPELL_CAST_FAILED",       "SPELL_CAST_FAILED" },
    -- Misc
    { "SPELL_INTERRUPT",         "SPELL_INTERRUPT" },
    { "SPELL_DISPEL",            "SPELL_DISPEL" },
    { "SPELL_DISPEL_FAILED",     "SPELL_DISPEL_FAILED" },
    { "SPELL_EXTRA_ATTACKS",     "SPELL_EXTRA_ATTACKS" },
    { "SPELL_SUMMON",            "SPELL_SUMMON" },
    { "SPELL_RESURRECT",         "SPELL_RESURRECT" },
    { "SPELL_INSTAKILL",         "SPELL_INSTAKILL" },
    -- Deaths
    { "UNIT_DIED",               "UNIT_DIED" },
    { "UNIT_DESTROYED",          "UNIT_DESTROYED" },
    { "PARTY_KILL",              "PARTY_KILL" },
}

local NUM_SUBEVENTS = table.getn(SUBEVENTS)

local subeventIndices = {}
for i = 1, NUM_SUBEVENTS do
    local name = SUBEVENTS[i][2]
    if not subeventIndices[name] then
        subeventIndices[name] = {}
    end
    table.insert(subeventIndices[name], i)
end

local seen = {}
local seenArgs = {}
local seenCount = 0

-- ============================================================================
-- Arg formatters (summary string for tracker display)
-- ============================================================================
-- Formatters receive p1..p12 (fields after the 9-field base from CombatLogGetCurrentEventInfo)

local function spellPrefix(spellId, spellName, spellSchool)
    return format("[%s] %s %s", s(spellId), s(spellName), schoolName(spellSchool or 0))
end

local function fmtBool(v) return v and "Y" or "" end

local argFormatters = {}

-- Spell-prefix damage: p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=overkill, p6=school, p7=resisted, p8=blocked, p9=absorbed, p10=critical, p11=glancing, p12=crushing
argFormatters["SPELL_DAMAGE"] = function(p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12)
    local ok = (p5 and p5 >= 0) and format(" OK=%s", s(p5)) or ""
    return format("%s amt=%s %s res=%s blk=%s abs=%s%s%s%s%s",
        spellPrefix(p1,p2,p3), s(p4), schoolName(p6 or 0), s(p7), s(p8), s(p9),
        p10 and " CRIT" or "", ok, p11 and " GLANC" or "", p12 and " CRUSH" or "")
end
argFormatters["RANGE_DAMAGE"]          = argFormatters["SPELL_DAMAGE"]
argFormatters["SPELL_PERIODIC_DAMAGE"] = argFormatters["SPELL_DAMAGE"]
argFormatters["DAMAGE_SHIELD"]         = argFormatters["SPELL_DAMAGE"]
argFormatters["DAMAGE_SPLIT"]          = argFormatters["SPELL_DAMAGE"]

-- Swing damage: p1=amount, p2=overkill, p3=school, p4=resisted, p5=blocked, p6=absorbed, p7=critical, p8=glancing, p9=crushing
argFormatters["SWING_DAMAGE"] = function(p1,p2,p3,p4,p5,p6,p7,p8,p9)
    local ok = (p2 and p2 >= 0) and format(" OK=%s", s(p2)) or ""
    return format("amt=%s %s res=%s blk=%s abs=%s%s%s%s%s",
        s(p1), schoolName(p3 or 0), s(p4), s(p5), s(p6),
        p7 and " CRIT" or "", ok, p8 and " GLANC" or "", p9 and " CRUSH" or "")
end

-- Env damage: p1=envType, p2=amount, p3=overkill, p4=school, p5=resisted, p6=blocked, p7=absorbed
argFormatters["ENVIRONMENTAL_DAMAGE"] = function(p1,p2,p3,p4,p5,p6,p7)
    local ok = (p3 and p3 >= 0) and format(" OK=%s", s(p3)) or ""
    return format("env=%s amt=%s %s abs=%s%s", s(p1), s(p2), schoolName(p4 or 0), s(p7), ok)
end

-- Swing missed: p1=missType, p2=amountMissed
argFormatters["SWING_MISSED"] = function(p1,p2) return format("%s amt=%s", s(p1), s(p2)) end

-- Spell missed: p1-p3=prefix, p4=missType, p5=amountMissed
argFormatters["SPELL_MISSED"]          = function(p1,p2,p3,p4,p5) return format("%s %s amt=%s", spellPrefix(p1,p2,p3), s(p4), s(p5)) end
argFormatters["SPELL_PERIODIC_MISSED"] = argFormatters["SPELL_MISSED"]
argFormatters["DAMAGE_SHIELD_MISSED"]  = argFormatters["SPELL_MISSED"]
argFormatters["RANGE_MISSED"]          = argFormatters["SPELL_MISSED"]

-- Spell heal: p1-p3=prefix, p4=amount, p5=overheal, p6=absorbed, p7=critical
argFormatters["SPELL_HEAL"] = function(p1,p2,p3,p4,p5,p6,p7)
    local oh = (p5 and p5 > 0) and format(" OH=%s", s(p5)) or ""
    return format("%s amt=%s abs=%s%s%s", spellPrefix(p1,p2,p3), s(p4), s(p6), p7 and " CRIT" or "", oh)
end
argFormatters["SPELL_PERIODIC_HEAL"] = argFormatters["SPELL_HEAL"]

-- Energize: p1-p3=prefix, p4=amount, p5=powerType
argFormatters["SPELL_ENERGIZE"] = function(p1,p2,p3,p4,p5)
    return format("%s amt=%s type=%s", spellPrefix(p1,p2,p3), s(p4), powerNames[p5] or s(p5))
end
argFormatters["SPELL_PERIODIC_ENERGIZE"] = argFormatters["SPELL_ENERGIZE"]

-- Leech/drain: p1-p3=prefix, p4=amount, p5=powerType, p6=extraAmount
argFormatters["SPELL_PERIODIC_LEECH"] = function(p1,p2,p3,p4,p5,p6)
    return format("%s amt=%s type=%s gain=%s", spellPrefix(p1,p2,p3), s(p4), s(p5), s(p6))
end
argFormatters["SPELL_PERIODIC_DRAIN"] = argFormatters["SPELL_PERIODIC_LEECH"]

-- Extra attacks: p1-p3=prefix, p4=amount
argFormatters["SPELL_EXTRA_ATTACKS"] = function(p1,p2,p3,p4)
    return format("%s amt=%s", spellPrefix(p1,p2,p3), s(p4))
end

-- Aura: p1-p3=prefix, p4=auraType
argFormatters["SPELL_AURA_APPLIED"] = function(p1,p2,p3,p4) return format("%s %s", spellPrefix(p1,p2,p3), s(p4)) end
argFormatters["SPELL_AURA_REMOVED"]  = argFormatters["SPELL_AURA_APPLIED"]
argFormatters["SPELL_AURA_REFRESH"]  = argFormatters["SPELL_AURA_APPLIED"]
argFormatters["SPELL_AURA_BROKEN"]   = argFormatters["SPELL_AURA_APPLIED"]

-- Aura dose: p1-p3=prefix, p4=auraType, p5=stacks
argFormatters["SPELL_AURA_APPLIED_DOSE"] = function(p1,p2,p3,p4,p5) return format("%s %s x%s", spellPrefix(p1,p2,p3), s(p4), s(p5)) end
argFormatters["SPELL_AURA_REMOVED_DOSE"] = argFormatters["SPELL_AURA_APPLIED_DOSE"]

-- Cast: p1-p3=prefix only
argFormatters["SPELL_CAST_START"]   = function(p1,p2,p3) return spellPrefix(p1,p2,p3) end
argFormatters["SPELL_CAST_SUCCESS"] = argFormatters["SPELL_CAST_START"]
argFormatters["SPELL_SUMMON"]       = argFormatters["SPELL_CAST_START"]
argFormatters["SPELL_RESURRECT"]    = argFormatters["SPELL_CAST_START"]
argFormatters["SPELL_INSTAKILL"]    = argFormatters["SPELL_CAST_START"]

-- Cast failed: p1-p3=prefix, p4=failedType
argFormatters["SPELL_CAST_FAILED"] = function(p1,p2,p3,p4) return format("%s reason=%s", spellPrefix(p1,p2,p3), s(p4)) end

-- Interrupt/dispel_failed: p1-p3=prefix, p4=extraSpellId, p5=extraSpellName, p6=extraSchool
argFormatters["SPELL_INTERRUPT"] = function(p1,p2,p3,p4,p5,p6)
    return format("%s -> extra=[%s] %s %s", spellPrefix(p1,p2,p3), s(p4), s(p5), schoolName(p6 or 0))
end
argFormatters["SPELL_DISPEL_FAILED"] = argFormatters["SPELL_INTERRUPT"]

-- Dispel/aura_broken_spell: p1-p3=prefix, p4=extraSpellId, p5=extraSpellName, p6=extraSchool, p7=auraType
argFormatters["SPELL_DISPEL"] = function(p1,p2,p3,p4,p5,p6,p7)
    return format("%s -> extra=[%s] %s %s %s", spellPrefix(p1,p2,p3), s(p4), s(p5), schoolName(p6 or 0), s(p7))
end
argFormatters["SPELL_AURA_BROKEN_SPELL"] = argFormatters["SPELL_DISPEL"]

-- Base (no suffix args)
argFormatters["UNIT_DIED"]      = function() return "" end
argFormatters["PARTY_KILL"]     = function() return "" end
argFormatters["UNIT_DESTROYED"] = function() return "" end

-- ============================================================================
-- Chat output handlers
-- ============================================================================
-- All chatHandlers receive: (src, srcName, dst, dstName, ...) where ... starts at arg6

-- chatHandlers receive: (srcName, dstName, p1, p2, ...) where p1.. are the suffix fields from CombatLogGetCurrentEventInfo

local chatHandlers = {}

-- Spell damage: p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=overkill, p6=school, ..., p10=critical
local function spellDamageChatHandler(sub)
    return function(srcName, dstName, p1,p2,p3,p4,p5,p6,p7,p8,p9,p10)
        DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000%s|r %s -> %s: %s[%d] for %d %s%s%s",
            sub, srcName, dstName, p2 or "", p1, p4, schoolName(p6), p10 and " (CRIT)" or "",
            (p5 and p5 >= 0) and format(" (OK %d)", p5) or ""))
    end
end
chatHandlers["SPELL_DAMAGE"] = spellDamageChatHandler("SPELL_DAMAGE")
chatHandlers["RANGE_DAMAGE"] = spellDamageChatHandler("RANGE_DAMAGE")
chatHandlers["DAMAGE_SPLIT"] = spellDamageChatHandler("DAMAGE_SPLIT")
chatHandlers["SPELL_PERIODIC_DAMAGE"] = spellDamageChatHandler("SPELL_PERIODIC_DAMAGE")
chatHandlers["DAMAGE_SHIELD"] = spellDamageChatHandler("DAMAGE_SHIELD")

-- Swing damage: p1=amount, p2=overkill, p3=school, ..., p7=critical, p8=glancing, p9=crushing
chatHandlers["SWING_DAMAGE"] = function(srcName, dstName, p1,p2,p3,p4,p5,p6,p7,p8,p9)
    local extra = ""
    if p7 then extra = extra .. " CRIT" end
    if p2 and p2 >= 0 then extra = extra .. format(" OK=%d", p2) end
    if p8 then extra = extra .. " GLANCING" end
    if p9 then extra = extra .. " CRUSHING" end
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SWING_DAMAGE|r %s -> %s: %d%s", srcName, dstName, p1, extra))
end

-- Swing missed: p1=missType
chatHandlers["SWING_MISSED"] = function(srcName, dstName, p1)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaSWING_MISSED|r %s -> %s: %s", srcName, dstName, p1))
end

-- Spell missed: p1-p3=prefix, p4=missType
local function spellMissedChatHandler(sub)
    return function(srcName, dstName, p1,p2,p3,p4)
        DEFAULT_CHAT_FRAME:AddMessage(format("|cffa0a0a0%s|r %s -> %s: %s[%d] %s", sub, srcName, dstName, p2 or "", p1, p4))
    end
end
chatHandlers["SPELL_MISSED"]          = spellMissedChatHandler("SPELL_MISSED")
chatHandlers["RANGE_MISSED"]          = spellMissedChatHandler("RANGE_MISSED")
chatHandlers["SPELL_PERIODIC_MISSED"] = spellMissedChatHandler("SPELL_PERIODIC_MISSED")
chatHandlers["DAMAGE_SHIELD_MISSED"]  = spellMissedChatHandler("DAMAGE_SHIELD_MISSED")

-- Env damage: p1=envType, p2=amount
chatHandlers["ENVIRONMENTAL_DAMAGE"] = function(srcName, dstName, p1,p2)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800ENVIRONMENTAL_DAMAGE|r %s: %s for %d", dstName, p1, p2))
end

-- Spell heal: p1-p3=prefix, p4=amount, p5=overheal, p6=absorbed, p7=critical
local function spellHealChatHandler(sub)
    return function(srcName, dstName, p1,p2,p3,p4,p5,p6,p7)
        DEFAULT_CHAT_FRAME:AddMessage(format("|cff00ff00%s|r %s -> %s: %s[%d] for %d%s%s",
            sub, srcName, dstName, p2 or "", p1, p4, p7 and " (CRIT)" or "",
            (p5 and p5 > 0) and format(" (OH %d)", p5) or ""))
    end
end
chatHandlers["SPELL_HEAL"] = spellHealChatHandler("SPELL_HEAL")
chatHandlers["SPELL_PERIODIC_HEAL"] = spellHealChatHandler("SPELL_PERIODIC_HEAL")

-- Energize: p1-p3=prefix, p4=amount, p5=powerType
local function spellEnergizeChatHandler(sub)
    return function(srcName, dstName, p1,p2,p3,p4,p5)
        DEFAULT_CHAT_FRAME:AddMessage(format("|cff4488ff%s|r %s -> %s: %s[%d] +%d %s", sub, srcName, dstName, p2 or "", p1, p4, powerNames[p5] or "?"))
    end
end
chatHandlers["SPELL_ENERGIZE"] = spellEnergizeChatHandler("SPELL_ENERGIZE")
chatHandlers["SPELL_PERIODIC_ENERGIZE"] = spellEnergizeChatHandler("SPELL_PERIODIC_ENERGIZE")

-- Leech: p1-p3=prefix, p4=amount, p5=powerType, p6=extraAmount
chatHandlers["SPELL_PERIODIC_LEECH"] = function(srcName, dstName, p1,p2,p3,p4,p5,p6)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8844ffSPELL_PERIODIC_LEECH|r %s -> %s: %s[%d] drained %d, gained %d", srcName, dstName, p2 or "", p1, p4, p6 or 0))
end

-- Drain: p1-p3=prefix, p4=amount, p5=powerType
chatHandlers["SPELL_PERIODIC_DRAIN"] = function(srcName, dstName, p1,p2,p3,p4,p5)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8844ffSPELL_PERIODIC_DRAIN|r %s -> %s: %s[%d] drained %d %s", srcName, dstName, p2 or "", p1, p4, powerNames[p5] or "?"))
end

-- Aura: p1-p3=prefix, p4=auraType
chatHandlers["SPELL_AURA_APPLIED"] = function(srcName, dstName, p1,p2,p3,p4)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8888ffSPELL_AURA_APPLIED|r %s: %s[%d] (%s)", dstName, p2 or "", p1, p4))
end
chatHandlers["SPELL_AURA_REMOVED"] = function(srcName, dstName, p1,p2,p3,p4)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff6666ccSPELL_AURA_REMOVED|r %s: %s[%d] (%s)", dstName, p2 or "", p1, p4))
end
chatHandlers["SPELL_AURA_REFRESH"] = function(srcName, dstName, p1,p2,p3,p4)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff7777ddSPELL_AURA_REFRESH|r %s: %s[%d] (%s)", dstName, p2 or "", p1, p4))
end
chatHandlers["SPELL_AURA_BROKEN"] = function(srcName, dstName, p1,p2,p3,p4)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_AURA_BROKEN|r %s -> %s: %s[%d] broken (%s)", srcName, dstName, p2 or "", p1, p4))
end
chatHandlers["SPELL_AURA_APPLIED_DOSE"] = function(srcName, dstName, p1,p2,p3,p4,p5)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8888ffSPELL_AURA_APPLIED_DOSE|r %s: %s[%d] x%d (%s)", dstName, p2 or "", p1, p5, p4))
end
chatHandlers["SPELL_AURA_REMOVED_DOSE"] = function(srcName, dstName, p1,p2,p3,p4,p5)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff6666ccSPELL_AURA_REMOVED_DOSE|r %s: %s[%d] x%d (%s)", dstName, p2 or "", p1, p5, p4))
end
chatHandlers["SPELL_AURA_BROKEN_SPELL"] = function(srcName, dstName, p1,p2,p3,p4,p5,p6,p7)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_AURA_BROKEN_SPELL|r %s -> %s: %s[%d] broken by %s[%d]", srcName, dstName, p2 or "", p1, p5 or "", p4))
end

-- Cast: p1-p3=prefix
chatHandlers["SPELL_CAST_START"] = function(srcName, dstName, p1,p2)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffffff00SPELL_CAST_START|r %s: %s[%d]", srcName, p2 or "", p1))
end
chatHandlers["SPELL_CAST_SUCCESS"] = function(srcName, dstName, p1,p2)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffffff00SPELL_CAST_SUCCESS|r %s: %s[%d]", srcName, p2 or "", p1))
end
chatHandlers["SPELL_CAST_FAILED"] = function(srcName, dstName, p1,p2,p3,p4)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff4444SPELL_CAST_FAILED|r %s: %s[%d] (%s)", srcName, p2 or "", p1, p4))
end

-- Interrupt: p1-p3=prefix, p4=extraSpellId, p5=extraSpellName
chatHandlers["SPELL_INTERRUPT"] = function(srcName, dstName, p1,p2,p3,p4,p5)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_INTERRUPT|r %s interrupted %s: %s[%d]", srcName, dstName, p5 or "", p4))
end

-- Dispel: p1-p3=prefix, p4=extraSpellId, p5=extraSpellName, p6=extraSchool, p7=auraType
chatHandlers["SPELL_DISPEL"] = function(srcName, dstName, p1,p2,p3,p4,p5,p6,p7)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ffffSPELL_DISPEL|r %s dispelled %s: %s[%d] (%s)", srcName, dstName, p5 or "", p4, p7))
end

-- Dispel failed: p1-p3=prefix, p4=extraSpellId, p5=extraSpellName
chatHandlers["SPELL_DISPEL_FAILED"] = function(srcName, dstName, p1,p2,p3,p4,p5)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff888888SPELL_DISPEL_FAILED|r %s -> %s: %s[%d] resisted", srcName, dstName, p5 or "", p4))
end

-- Extra attacks: p1-p3=prefix, p4=amount
chatHandlers["SPELL_EXTRA_ATTACKS"] = function(srcName, dstName, p1,p2,p3,p4)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_EXTRA_ATTACKS|r %s: %s[%d] x%d", srcName, p2 or "", p1, p4))
end

-- Summon/resurrect/instakill: p1-p3=prefix
chatHandlers["SPELL_SUMMON"] = function(srcName, dstName, p1,p2)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ff88SPELL_SUMMON|r %s summoned %s: %s[%d]", srcName, dstName, p2 or "", p1))
end
chatHandlers["SPELL_RESURRECT"] = function(srcName, dstName, p1,p2)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ff88SPELL_RESURRECT|r %s resurrected %s: %s[%d]", srcName, dstName, p2 or "", p1))
end
chatHandlers["SPELL_INSTAKILL"] = function(srcName, dstName, p1,p2)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SPELL_INSTAKILL|r %s killed %s: %s[%d]", srcName, dstName, p2 or "", p1))
end

-- Deaths
chatHandlers["UNIT_DIED"] = function(srcName, dstName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff888888UNIT_DIED|r %s", dstName))
end
chatHandlers["PARTY_KILL"] = function(srcName, dstName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800PARTY_KILL|r %s killed %s", srcName, dstName))
end
chatHandlers["UNIT_DESTROYED"] = function(srcName, dstName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff666666UNIT_DESTROYED|r %s", dstName))
end

-- ============================================================================
-- UI -- Draggable popup tracker
-- ============================================================================

local ROW_HEIGHT = 14
local FRAME_WIDTH = 420
local VISIBLE_ROWS = 25
local FRAME_HEIGHT = ROW_HEIGHT * VISIBLE_ROWS + 52

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

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -10)
title:SetText("DPS Log Tracker")
title:SetTextColor(1, 0.82, 0)

local closeBtn = CreateFrame("Button", nil, main, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", main, "TOPRIGHT", -2, -2)
closeBtn:SetScript("OnClick", function() main:Hide() end)

local counter = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
counter:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
counter:SetTextColor(0.7, 0.7, 0.7)

local function updateCounter()
    counter:SetText(format("Seen: %d/%d", seenCount, NUM_SUBEVENTS))
end
updateCounter()

local scrollFrame = CreateFrame("ScrollFrame", "DPSLogTrackerScroll", main, "FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", main, "TOPLEFT", 8, -48)
scrollFrame:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -28, 8)

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
            local displayN = SUBEVENTS[idx][1]
            if seen[idx] then
                row.check:SetText("|cff00ff00x|r")
                local argStr = seenArgs[idx]
                if argStr and argStr ~= "" then
                    row.nameStr:SetText("|cffffffff" .. displayN .. "|r |cffaaaaaa" .. argStr .. "|r")
                else
                    row.nameStr:SetText("|cffffffff" .. displayN .. "|r")
                end
            else
                row.check:SetText("|cff666666-|r")
                row.nameStr:SetText("|cff666666" .. displayN .. "|r")
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

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

eventFrame:SetScript("OnEvent", function()
    if not CombatLogGetCurrentEventInfo then return end
    local sub, srcGUID, srcName, srcFlags, srcRaidFlags,
          dstGUID, dstName, dstFlags, dstRaidFlags,
          p1, p2, p3, p4, p5, p6, p7, p8, p9,
          p10, p11, p12 = CombatLogGetCurrentEventInfo()
    if not sub then return end

    if not srcName or srcName == "" then srcName = "Unknown" end
    if not dstName or dstName == "" then dstName = "Unknown" end

    local indices = subeventIndices[sub]
    if not indices then return end

    -- Build full args array for variant field checks (1-based, matching CombatLogGetCurrentEventInfo positions)
    local args = { sub, srcGUID, srcName, srcFlags, srcRaidFlags,
                   dstGUID, dstName, dstFlags, dstRaidFlags,
                   p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12 }

    local any_new = false
    for _, idx in ipairs(indices) do
        if not seen[idx] then
            local entry = SUBEVENTS[idx]
            local varField = entry[3]
            local varValue = entry[4]

            local matches = true
            if varField then
                if varValue then
                    matches = (args[varField] == varValue)
                else
                    -- Boolean check (truthy): critical, glancing, crushing
                    matches = (args[varField] ~= nil)
                end
            end

            if matches then
                seen[idx] = true
                seenCount = seenCount + 1
                local formatter = argFormatters[sub]
                if formatter then
                    seenArgs[idx] = formatter(p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
                else
                    seenArgs[idx] = ""
                end
                any_new = true

                local chatHandler = chatHandlers[sub]
                if chatHandler then
                    chatHandler(srcName, dstName, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12)
                end
            end
        end
    end

    if any_new then
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

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00DPSLog Tracker|r loaded -- /dpslog to toggle window")
