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
-- Arg position constants -- WotLK CLEU parity
-- ============================================================================

-- Base: arg1=subevent, arg2=srcGUID, arg3=srcName, arg4=dstGUID, arg5=dstName
-- Spell prefix events: arg6=spellId, arg7=spellName, arg8=spellSchool
-- Suffix starts at arg9 for spell-prefix events
-- Swing events: suffix starts at arg6 (no prefix)
-- Env events: arg6=envType, suffix starts at arg7

-- _DAMAGE suffix (9 fields): amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
-- Spell damage: arg6-8=prefix, arg9-17=suffix
-- Swing damage: arg6-14=suffix
-- Env damage: arg6=envType, arg7-15=suffix

-- _MISSED suffix: missType, amountMissed
-- Spell missed: arg6-8=prefix, arg9=missType, arg10=amountMissed
-- Swing missed: arg6=missType, arg7=amountMissed

-- _HEAL suffix: amount, overheal, absorbed, critical
-- arg6-8=prefix, arg9-12=suffix

-- _ENERGIZE suffix: amount, powerType
-- arg6-8=prefix, arg9-10=suffix

-- _LEECH/_DRAIN suffix: amount, powerType, extraAmount
-- arg6-8=prefix, arg9-11=suffix

-- _EXTRA_ATTACKS suffix: amount
-- arg6-8=prefix, arg9=amount

-- _INTERRUPT/_DISPEL_FAILED suffix: extraSpellId, extraSpellName, extraSchool
-- arg6-8=prefix, arg9-11=suffix

-- _DISPEL/_STOLEN/_AURA_BROKEN_SPELL suffix: extraSpellId, extraSpellName, extraSchool, auraType
-- arg6-8=prefix, arg9-12=suffix

-- _AURA_APPLIED/REMOVED/REFRESH/BROKEN: auraType
-- arg6-8=prefix, arg9=auraType

-- _AURA_DOSE: auraType, amount
-- arg6-8=prefix, arg9=auraType, arg10=amount

-- _CAST_FAILED: failedType
-- arg6-8=prefix, arg9=failedType

-- ============================================================================
-- Subevent definitions -- variant checklist
-- ============================================================================

-- { displayName, subevent, [variantField], [variantValue] }
local SUBEVENTS = {
    -- Damage (spell prefix: arg9=amount ... arg15=critical, arg16=glancing, arg17=crushing)
    { "SPELL_DAMAGE",            "SPELL_DAMAGE" },
    { "SPELL_DAMAGE (crit)",     "SPELL_DAMAGE",          15, 1 },
    { "RANGE_DAMAGE",            "RANGE_DAMAGE" },
    { "RANGE_DAMAGE (crit)",     "RANGE_DAMAGE",          15, 1 },
    { "SPELL_PERIODIC_DAMAGE",   "SPELL_PERIODIC_DAMAGE" },
    { "DAMAGE_SHIELD",           "DAMAGE_SHIELD" },
    { "DAMAGE_SPLIT",            "DAMAGE_SPLIT" },
    -- Swing damage: arg6=amount ... arg12=critical, arg13=glancing, arg14=crushing
    { "SWING_DAMAGE",            "SWING_DAMAGE" },
    { "SWING_DAMAGE (crit)",     "SWING_DAMAGE",          12, 1 },
    { "SWING_DAMAGE (glancing)", "SWING_DAMAGE",          13, 1 },
    { "SWING_DAMAGE (crushing)", "SWING_DAMAGE",          14, 1 },
    -- Env damage: arg6=envType, arg7=amount ... arg15=crushing
    { "ENVIRONMENTAL (DROWNING)",  "ENVIRONMENTAL_DAMAGE", 6, "DROWNING" },
    { "ENVIRONMENTAL (FALLING)",   "ENVIRONMENTAL_DAMAGE", 6, "FALLING" },
    { "ENVIRONMENTAL (LAVA)",      "ENVIRONMENTAL_DAMAGE", 6, "LAVA" },
    { "ENVIRONMENTAL (SLIME)",     "ENVIRONMENTAL_DAMAGE", 6, "SLIME" },
    { "ENVIRONMENTAL (FIRE)",      "ENVIRONMENTAL_DAMAGE", 6, "FIRE" },
    { "ENVIRONMENTAL (EXHAUSTED)", "ENVIRONMENTAL_DAMAGE", 6, "EXHAUSTED" }, -- twow: no fatigue
    -- Misses -- swing: arg6=missType
    { "SWING_MISSED (MISS)",     "SWING_MISSED",    6, "MISS" },
    { "SWING_MISSED (DODGE)",    "SWING_MISSED",    6, "DODGE" },
    { "SWING_MISSED (PARRY)",    "SWING_MISSED",    6, "PARRY" },
    { "SWING_MISSED (BLOCK)",    "SWING_MISSED",    6, "BLOCK" },
    { "SWING_MISSED (EVADE)",    "SWING_MISSED",    6, "EVADE" },
    { "SWING_MISSED (IMMUNE)",   "SWING_MISSED",    6, "IMMUNE" },
    { "SWING_MISSED (RESIST)",   "SWING_MISSED",    6, "RESIST" },
    { "SWING_MISSED (ABSORB)",   "SWING_MISSED",    6, "ABSORB" },
    -- Misses -- spell: arg9=missType (after prefix)
    { "SPELL_MISSED (MISS)",     "SPELL_MISSED",    9, "MISS" },
    { "SPELL_MISSED (DODGE)",    "SPELL_MISSED",    9, "DODGE" },
    { "SPELL_MISSED (PARRY)",    "SPELL_MISSED",    9, "PARRY" },
    { "SPELL_MISSED (IMMUNE)",   "SPELL_MISSED",    9, "IMMUNE" },
    { "SPELL_MISSED (RESIST)",   "SPELL_MISSED",    9, "RESIST" },
    { "SPELL_MISSED (ABSORB)",   "SPELL_MISSED",    9, "ABSORB" },
    { "SPELL_MISSED (DEFLECT)",  "SPELL_MISSED",    9, "DEFLECT" }, -- dead in vanilla
    { "SPELL_MISSED (REFLECT)",  "SPELL_MISSED",    9, "REFLECT" },
    { "RANGE_MISSED",            "RANGE_MISSED" },
    { "SPELL_PERIODIC_MISSED",   "SPELL_PERIODIC_MISSED" },
    { "DAMAGE_SHIELD_MISSED",    "DAMAGE_SHIELD_MISSED" },
    -- Heals: arg9=amount, arg10=overheal, arg11=absorbed, arg12=critical
    { "SPELL_HEAL",              "SPELL_HEAL" },
    { "SPELL_HEAL (crit)",       "SPELL_HEAL",      12, 1 },
    { "SPELL_PERIODIC_HEAL",     "SPELL_PERIODIC_HEAL" },
    -- Power: arg9=amount, arg10=powerType
    { "SPELL_ENERGIZE",          "SPELL_ENERGIZE" },
    { "SPELL_PERIODIC_ENERGIZE", "SPELL_PERIODIC_ENERGIZE" },
    { "SPELL_PERIODIC_DRAIN",    "SPELL_PERIODIC_DRAIN" },
    { "SPELL_PERIODIC_LEECH",    "SPELL_PERIODIC_LEECH" },
    -- Auras: arg9=auraType
    { "SPELL_AURA_APPLIED (BUFF)",   "SPELL_AURA_APPLIED",  9, "BUFF" },
    { "SPELL_AURA_APPLIED (DEBUFF)", "SPELL_AURA_APPLIED",  9, "DEBUFF" },
    { "SPELL_AURA_REMOVED (BUFF)",   "SPELL_AURA_REMOVED",  9, "BUFF" },
    { "SPELL_AURA_REMOVED (DEBUFF)", "SPELL_AURA_REMOVED",  9, "DEBUFF" },
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
-- Formatters receive args starting from arg6 (after base: sub, srcGUID, srcName, dstGUID, dstName)

-- Spell-prefix damage: spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
local function fmtSpellDmg(spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing)
    local c = (critical == 1) and " CRIT" or ""
    local ok = (overkill and overkill >= 0) and format(" OK=%s", s(overkill)) or ""
    local g = (glancing == 1) and " GLANC" or ""
    local cr = (crushing == 1) and " CRUSH" or ""
    return format("[%s] %s amt=%s %s res=%s blk=%s abs=%s%s%s%s%s",
        s(spellId), s(spellName), s(amount), schoolName(school or 0), s(resisted), s(blocked), s(absorbed), c, ok, g, cr)
end

-- Swing damage: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
local function fmtSwingDmg(amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing)
    local c = (critical == 1) and " CRIT" or ""
    local ok = (overkill and overkill >= 0) and format(" OK=%s", s(overkill)) or ""
    local g = (glancing == 1) and " GLANC" or ""
    local cr = (crushing == 1) and " CRUSH" or ""
    return format("amt=%s %s res=%s blk=%s abs=%s%s%s%s%s",
        s(amount), schoolName(school or 0), s(resisted), s(blocked), s(absorbed), c, ok, g, cr)
end

-- Spell prefix helper
local function spellPrefix(spellId, spellName, spellSchool)
    return format("[%s] %s %s", s(spellId), s(spellName), schoolName(spellSchool or 0))
end

local argFormatters = {}

-- Spell-prefix damage (args start at a6=spellId)
argFormatters["SPELL_DAMAGE"]          = function(...) return fmtSpellDmg(arg[1],arg[2],arg[3],arg[4],arg[5],arg[6],arg[7],arg[8],arg[9],arg[10],arg[11],arg[12]) end
argFormatters["RANGE_DAMAGE"]          = argFormatters["SPELL_DAMAGE"]
argFormatters["SPELL_PERIODIC_DAMAGE"] = argFormatters["SPELL_DAMAGE"]
argFormatters["DAMAGE_SHIELD"]         = argFormatters["SPELL_DAMAGE"]
argFormatters["DAMAGE_SPLIT"]          = argFormatters["SPELL_DAMAGE"]

-- Swing damage (no prefix, args start at a6=amount)
argFormatters["SWING_DAMAGE"] = function(...) return fmtSwingDmg(arg[1],arg[2],arg[3],arg[4],arg[5],arg[6],arg[7],arg[8],arg[9]) end

-- Env damage: a6=envType, a7-a15=damage suffix
argFormatters["ENVIRONMENTAL_DAMAGE"] = function(...)
    local ok = (arg[3] and arg[3] >= 0) and format(" OK=%s", s(arg[3])) or ""
    return format("env=%s amt=%s %s abs=%s%s", s(arg[1]), s(arg[2]), schoolName(arg[4] or 0), s(arg[7]), ok)
end

-- Swing missed: a6=missType, a7=amountMissed
argFormatters["SWING_MISSED"] = function(...) return format("%s amt=%s", s(arg[1]), s(arg[2])) end

-- Spell missed: a6-a8=prefix, a9=missType, a10=amountMissed
argFormatters["SPELL_MISSED"]          = function(...) return format("%s %s amt=%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), s(arg[5])) end
argFormatters["SPELL_PERIODIC_MISSED"] = argFormatters["SPELL_MISSED"]
argFormatters["DAMAGE_SHIELD_MISSED"]  = argFormatters["SPELL_MISSED"]
argFormatters["RANGE_MISSED"]          = argFormatters["SPELL_MISSED"]

-- Spell heal: a6-a8=prefix, a9=amount, a10=overheal, a11=absorbed, a12=critical
argFormatters["SPELL_HEAL"] = function(...)
    local c = (arg[7] == 1) and " CRIT" or ""
    local oh = (arg[5] and arg[5] > 0) and format(" OH=%s", s(arg[5])) or ""
    return format("%s amt=%s abs=%s%s%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), s(arg[6]), c, oh)
end
argFormatters["SPELL_PERIODIC_HEAL"] = argFormatters["SPELL_HEAL"]

-- Spell energize: a6-a8=prefix, a9=amount, a10=powerType
argFormatters["SPELL_ENERGIZE"] = function(...)
    return format("%s amt=%s type=%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), powerNames[arg[5]] or s(arg[5]))
end
argFormatters["SPELL_PERIODIC_ENERGIZE"] = argFormatters["SPELL_ENERGIZE"]

-- Spell leech/drain: a6-a8=prefix, a9=amount, a10=powerType, a11=extraAmount
argFormatters["SPELL_PERIODIC_LEECH"] = function(...)
    return format("%s amt=%s type=%s gain=%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), s(arg[5]), s(arg[6]))
end
argFormatters["SPELL_PERIODIC_DRAIN"] = argFormatters["SPELL_PERIODIC_LEECH"]

-- Extra attacks: a6-a8=prefix, a9=amount
argFormatters["SPELL_EXTRA_ATTACKS"] = function(...)
    return format("%s amt=%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]))
end

-- Aura applied/removed/refresh/broken: a6-a8=prefix, a9=auraType
argFormatters["SPELL_AURA_APPLIED"] = function(...) return format("%s %s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4])) end
argFormatters["SPELL_AURA_REMOVED"]  = argFormatters["SPELL_AURA_APPLIED"]
argFormatters["SPELL_AURA_REFRESH"]  = argFormatters["SPELL_AURA_APPLIED"]
argFormatters["SPELL_AURA_BROKEN"]   = argFormatters["SPELL_AURA_APPLIED"]

-- Aura dose: a6-a8=prefix, a9=auraType, a10=amount
argFormatters["SPELL_AURA_APPLIED_DOSE"] = function(...) return format("%s %s x%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), s(arg[5])) end
argFormatters["SPELL_AURA_REMOVED_DOSE"] = argFormatters["SPELL_AURA_APPLIED_DOSE"]

-- Cast: a6-a8=prefix only
argFormatters["SPELL_CAST_START"]   = function(...) return spellPrefix(arg[1],arg[2],arg[3]) end
argFormatters["SPELL_CAST_SUCCESS"] = argFormatters["SPELL_CAST_START"]
argFormatters["SPELL_SUMMON"]       = argFormatters["SPELL_CAST_START"]
argFormatters["SPELL_RESURRECT"]    = argFormatters["SPELL_CAST_START"]
argFormatters["SPELL_INSTAKILL"]    = argFormatters["SPELL_CAST_START"]

-- Cast failed: a6-a8=prefix, a9=failedType
argFormatters["SPELL_CAST_FAILED"] = function(...) return format("%s reason=%s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4])) end

-- Interrupt/dispel_failed: a6-a8=prefix, a9=extraSpellId, a10=extraSpellName, a11=extraSchool
argFormatters["SPELL_INTERRUPT"] = function(...)
    return format("%s -> extra=[%s] %s %s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), s(arg[5]), schoolName(arg[6] or 0))
end
argFormatters["SPELL_DISPEL_FAILED"] = argFormatters["SPELL_INTERRUPT"]

-- Dispel/stolen/aura_broken_spell: a6-a8=prefix, a9=extraSpellId, a10=extraSpellName, a11=extraSchool, a12=auraType
argFormatters["SPELL_DISPEL"] = function(...)
    return format("%s -> extra=[%s] %s %s %s", spellPrefix(arg[1],arg[2],arg[3]), s(arg[4]), s(arg[5]), schoolName(arg[6] or 0), s(arg[7]))
end
argFormatters["SPELL_AURA_BROKEN_SPELL"] = argFormatters["SPELL_DISPEL"]

-- Base (no args)
argFormatters["UNIT_DIED"]      = function() return "" end
argFormatters["PARTY_KILL"]     = function() return "" end
argFormatters["UNIT_DESTROYED"] = function() return "" end

-- ============================================================================
-- Chat output handlers
-- ============================================================================
-- All chatHandlers receive: (src, srcName, dst, dstName, ...) where ... starts at arg6

local chatHandlers = {}

-- Spell damage: src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical
chatHandlers["SPELL_DAMAGE"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical)
    local crit = critical == 1 and " (CRIT)" or ""
    local ok = (overkill and overkill >= 0) and format(" (OK %d)", overkill) or ""
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SPELL_DAMAGE|r %s -> %s: %s[%d] for %d %s%s%s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, schoolName(school), crit, ok))
end
chatHandlers["RANGE_DAMAGE"] = chatHandlers["SPELL_DAMAGE"]
chatHandlers["DAMAGE_SPLIT"] = chatHandlers["SPELL_DAMAGE"]

chatHandlers["SPELL_PERIODIC_DAMAGE"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overkill, school)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffcc0000SPELL_PERIODIC_DAMAGE|r %s -> %s: %s[%d] for %d %s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, schoolName(school)))
end

chatHandlers["DAMAGE_SHIELD"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overkill, school)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff4400DAMAGE_SHIELD|r %s -> %s: %d %s", displayName(srcName, src), displayName(dstName, dst), amount, schoolName(school)))
end

-- Swing damage: src, srcName, dst, dstName, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
chatHandlers["SWING_DAMAGE"] = function(src, srcName, dst, dstName, amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing)
    local extra = ""
    if critical == 1 then extra = extra .. " CRIT" end
    if overkill and overkill >= 0 then extra = extra .. format(" OK=%d", overkill) end
    if glancing == 1 then extra = extra .. " GLANCING" end
    if crushing == 1 then extra = extra .. " CRUSHING" end
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SWING_DAMAGE|r %s -> %s: %d%s", displayName(srcName, src), displayName(dstName, dst), amount, extra))
end

-- Swing missed: src, srcName, dst, dstName, missType, amountMissed
chatHandlers["SWING_MISSED"] = function(src, srcName, dst, dstName, missType, amountMissed)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaSWING_MISSED|r %s -> %s: %s", displayName(srcName, src), displayName(dstName, dst), missType))
end

-- Spell missed: src, srcName, dst, dstName, spellId, spellName, spellSchool, missType, amountMissed
chatHandlers["SPELL_MISSED"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, missType, amountMissed)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffaaaaaaSPELL_MISSED|r %s -> %s: %s[%d] %s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, missType))
end
chatHandlers["RANGE_MISSED"]          = chatHandlers["SPELL_MISSED"]
chatHandlers["SPELL_PERIODIC_MISSED"] = chatHandlers["SPELL_MISSED"]
chatHandlers["DAMAGE_SHIELD_MISSED"]  = chatHandlers["SPELL_MISSED"]

-- Env damage: src, srcName, dst, dstName, envType, amount, overkill, school, resisted, blocked, absorbed
chatHandlers["ENVIRONMENTAL_DAMAGE"] = function(src, srcName, dst, dstName, envType, amount)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800ENVIRONMENTAL_DAMAGE|r %s: %s for %d", displayName(dstName, dst), envType, amount))
end

-- Spell heal: src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overheal, absorbed, critical
chatHandlers["SPELL_HEAL"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overheal, absorbed, critical)
    local crit = critical == 1 and " (CRIT)" or ""
    local oh = (overheal and overheal > 0) and format(" (OH %d)", overheal) or ""
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff00ff00SPELL_HEAL|r %s -> %s: %s[%d] for %d%s%s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, crit, oh))
end
chatHandlers["SPELL_PERIODIC_HEAL"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, overheal)
    local oh = (overheal and overheal > 0) and format(" (OH %d)", overheal) or ""
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff00cc00SPELL_PERIODIC_HEAL|r %s -> %s: %s[%d] for %d%s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, oh))
end

-- Energize: src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType
chatHandlers["SPELL_ENERGIZE"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff4488ffSPELL_ENERGIZE|r %s -> %s: %s[%d] +%d %s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, powerNames[powerType] or "?"))
end
chatHandlers["SPELL_PERIODIC_ENERGIZE"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff4488ffSPELL_PERIODIC_ENERGIZE|r %s -> %s: %s[%d] +%d %s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, powerNames[powerType] or "?"))
end

-- Leech: src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType, extraAmount
chatHandlers["SPELL_PERIODIC_LEECH"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType, extraAmount)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8844ffSPELL_PERIODIC_LEECH|r %s -> %s: %s[%d] drained %d, gained %d", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, extraAmount or 0))
end

-- Drain: src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType, extraAmount
chatHandlers["SPELL_PERIODIC_DRAIN"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount, powerType, extraAmount)
    local pname = powerNames[powerType] or "?"
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8844ffSPELL_PERIODIC_DRAIN|r %s -> %s: %s[%d] drained %d %s", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, amount, pname))
end

-- Aura: src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType
chatHandlers["SPELL_AURA_APPLIED"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8888ffSPELL_AURA_APPLIED|r %s: %s[%d] (%s)", displayName(dstName, dst), spellName or "", spellId, auraType))
end
chatHandlers["SPELL_AURA_REMOVED"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff6666ccSPELL_AURA_REMOVED|r %s: %s[%d] (%s)", displayName(dstName, dst), spellName or "", spellId, auraType))
end
chatHandlers["SPELL_AURA_REFRESH"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff7777ddSPELL_AURA_REFRESH|r %s: %s[%d] (%s)", displayName(dstName, dst), spellName or "", spellId, auraType))
end
chatHandlers["SPELL_AURA_BROKEN"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_AURA_BROKEN|r %s -> %s: %s[%d] broken (%s)", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, auraType))
end
chatHandlers["SPELL_AURA_APPLIED_DOSE"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType, stacks)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff8888ffSPELL_AURA_APPLIED_DOSE|r %s: %s[%d] x%d (%s)", displayName(dstName, dst), spellName or "", spellId, stacks, auraType))
end
chatHandlers["SPELL_AURA_REMOVED_DOSE"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, auraType, stacks)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff6666ccSPELL_AURA_REMOVED_DOSE|r %s: %s[%d] x%d (%s)", displayName(dstName, dst), spellName or "", spellId, stacks, auraType))
end
chatHandlers["SPELL_AURA_BROKEN_SPELL"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_AURA_BROKEN_SPELL|r %s -> %s: %s[%d] broken by %s[%d]", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId, extraSpellName or "", extraSpellId))
end

-- Cast
chatHandlers["SPELL_CAST_START"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffffff00SPELL_CAST_START|r %s: %s[%d]", displayName(srcName, src), spellName or "", spellId))
end
chatHandlers["SPELL_CAST_SUCCESS"] = function(src, srcName, dst, dstName, spellId, spellName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffffff00SPELL_CAST_SUCCESS|r %s: %s[%d]", displayName(srcName, src), spellName or "", spellId))
end
chatHandlers["SPELL_CAST_FAILED"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, failedType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff4444SPELL_CAST_FAILED|r %s: %s[%d] (%s)", displayName(srcName, src), spellName or "", spellId, failedType))
end

-- Interrupt: src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool
chatHandlers["SPELL_INTERRUPT"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_INTERRUPT|r %s interrupted %s: %s[%d]", displayName(srcName, src), displayName(dstName, dst), extraSpellName or "", extraSpellId))
end

-- Dispel: src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool, auraType
chatHandlers["SPELL_DISPEL"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool, auraType)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ffffSPELL_DISPEL|r %s dispelled %s: %s[%d] (%s)", displayName(srcName, src), displayName(dstName, dst), extraSpellName or "", extraSpellId, auraType))
end

-- Dispel failed: src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool
chatHandlers["SPELL_DISPEL_FAILED"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, extraSpellId, extraSpellName, extraSchool)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff888888SPELL_DISPEL_FAILED|r %s -> %s: %s[%d] resisted", displayName(srcName, src), displayName(dstName, dst), extraSpellName or "", extraSpellId))
end

-- Extra attacks: src, srcName, dst, dstName, spellId, spellName, spellSchool, amount
chatHandlers["SPELL_EXTRA_ATTACKS"] = function(src, srcName, dst, dstName, spellId, spellName, spellSchool, amount)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800SPELL_EXTRA_ATTACKS|r %s: %s[%d] x%d", displayName(srcName, src), spellName or "", spellId, amount))
end

-- Summon/resurrect/instakill
chatHandlers["SPELL_SUMMON"] = function(src, srcName, dst, dstName, spellId, spellName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ff88SPELL_SUMMON|r %s summoned %s: %s[%d]", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId))
end
chatHandlers["SPELL_RESURRECT"] = function(src, srcName, dst, dstName, spellId, spellName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff88ff88SPELL_RESURRECT|r %s resurrected %s: %s[%d]", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId))
end
chatHandlers["SPELL_INSTAKILL"] = function(src, srcName, dst, dstName, spellId, spellName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff0000SPELL_INSTAKILL|r %s killed %s: %s[%d]", displayName(srcName, src), displayName(dstName, dst), spellName or "", spellId))
end

-- Deaths
chatHandlers["UNIT_DIED"] = function(src, srcName, dst, dstName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff888888UNIT_DIED|r %s", displayName(dstName, dst)))
end
chatHandlers["PARTY_KILL"] = function(src, srcName, dst, dstName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cffff8800PARTY_KILL|r %s killed %s", displayName(srcName, src), displayName(dstName, dst)))
end
chatHandlers["UNIT_DESTROYED"] = function(src, srcName, dst, dstName)
    DEFAULT_CHAT_FRAME:AddMessage(format("|cff666666UNIT_DESTROYED|r %s", displayName(dstName, dst)))
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

-- Expand args table to handle up to 17 args (spell damage has the most: 5 base + 3 prefix + 9 suffix)
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

eventFrame:SetScript("OnEvent", function()
    local subevent = arg1
    if not subevent then return end

    local args = { arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10,
                   arg11, arg12, arg13, arg14, arg15, arg16, arg17 }

    local indices = subeventIndices[subevent]
    if not indices then return end

    local any_new = false
    for _, idx in ipairs(indices) do
        if not seen[idx] then
            local entry = SUBEVENTS[idx]
            local varField = entry[3]
            local varValue = entry[4]

            local matches = true
            if varField then
                matches = (args[varField] == varValue)
            end

            if matches then
                seen[idx] = true
                seenCount = seenCount + 1
                local formatter = argFormatters[subevent]
                if formatter then
                    -- Pass args starting from arg6 (after base: sub, srcGUID, srcName, dstGUID, dstName)
                    seenArgs[idx] = formatter(arg6, arg7, arg8, arg9, arg10, arg11, arg12,
                                              arg13, arg14, arg15, arg16, arg17)
                else
                    seenArgs[idx] = ""
                end
                any_new = true

                local chatHandler = chatHandlers[subevent]
                if chatHandler then
                    chatHandler(arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10,
                                arg11, arg12, arg13, arg14, arg15, arg16, arg17)
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
