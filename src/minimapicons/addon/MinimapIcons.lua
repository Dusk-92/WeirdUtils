-- MinimapIcons addon (embedded in DLL, loaded from memory)
-- Takes over the native MiniMapTrackingFrame to add a tracking spell dropdown
-- with Wrath-style NPC tracking categories backed by DLL-side minimap hooks.

MINIMAPICONS_VERSION = 3

-- =============================================================================
-- Tracking spell definitions grouped by category
-- =============================================================================

local SPELL_CATEGORIES = {
    { name = "Hunter Tracking", spells = {
        "Track Beasts", "Track Humanoids", "Track Undead", "Track Hidden",
        "Track Elementals", "Track Demons", "Track Giants", "Track Dragonkin",
    }},
    { name = "Class Abilities", spells = {
        "Sense Undead", "Sense Demons",
    }},
    { name = "Professions", spells = {
        "Find Herbs", "Find Minerals", "Find Treasure",
    }},
}

-- NPC tracking categories (icons embedded from Wrath client)
-- trackingType maps to DLL SetObjectTypeBlip() type names.
-- subnameFilter: substring match on NPC subname/title (e.g. "Druid" matches "Druid Trainer").
--   Filtered entries take priority over unfiltered catch-all entries with the same flag.
--   "dynamic" filter is resolved at runtime via getFilter().
local NPC_CATEGORIES = {
    { name = "Auctioneer",    trackingType = "auctioneer",   icon = "Interface\\Minimap\\Tracking\\Auctioneer" },
    { name = "Banker",        trackingType = "banker",       icon = "Interface\\Minimap\\Tracking\\Banker" },
    { name = "Battle Master", trackingType = "battlemaster", icon = "Interface\\Minimap\\Tracking\\BattleMaster" },
    { name = "Class Trainer", trackingType = "trainer",      icon = "Interface\\Minimap\\Tracking\\Class",
        getFilter = function() return (UnitClass("player")) end },
    { name = "Flight Master", trackingType = "flightmaster", icon = "Interface\\Minimap\\Tracking\\FlightMaster" },
    { name = "Innkeeper",     trackingType = "innkeeper",    icon = "Interface\\Minimap\\Tracking\\Innkeeper" },
    { name = "Mailbox",       trackingType = "mailbox",      icon = "Interface\\Minimap\\Tracking\\Mailbox" },
    { name = "Profession Trainer", trackingType = "trainer", icon = "Interface\\Minimap\\Tracking\\Profession",
        getExclude = function() return UnitClass("player") end },
    { name = "Repair",        trackingType = "repair",       icon = "Interface\\Minimap\\Tracking\\Repair" },
    { name = "Stable Master", trackingType = "stablemaster", icon = "Interface\\Minimap\\Tracking\\StableMaster" },
    { name = "Vendor",        trackingType = "vendor",       icon = "Interface\\Minimap\\Tracking\\Food" },
}

-- =============================================================================
-- NPC tracking state (persists per session, no SavedVariables)
-- =============================================================================

local activeNpcCategories = {} -- name -> 1/nil

-- Sync DLL tracking state with addon toggle state.
-- Each category gets its own DLL call. Categories with a subnameFilter
-- (e.g. Class Trainer filtering by player class) create filtered entries
-- that take priority over unfiltered catch-all entries.
local function updateDllTracking()
    if not SetObjectTypeBlip then return end
    for _, cat in ipairs(NPC_CATEGORIES) do
        local inc = cat.getFilter and cat.getFilter() or nil
        local exc = cat.getExclude and cat.getExclude() or nil
        if activeNpcCategories[cat.name] then
            SetObjectTypeBlip(cat.trackingType, cat.icon, 1.5, inc, exc)
        else
            SetObjectTypeBlip(cat.trackingType, nil, nil, inc, exc)
        end
    end
end

-- =============================================================================
-- Spellbook scanning
-- =============================================================================

local knownSpells = {} -- name -> spellbook index

local function scanSpellbook()
    knownSpells = {}
    local trackable = {}
    for _, cat in ipairs(SPELL_CATEGORIES) do
        for _, s in ipairs(cat.spells) do
            trackable[s] = 1
        end
    end
    local i = 1
    while GetSpellName(i, BOOKTYPE_SPELL) do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if trackable[name] then
            knownSpells[name] = i
        end
        i = i + 1
    end
end

-- =============================================================================
-- Active tracking detection
-- =============================================================================

local DEFAULT_ICON = "Interface\\Minimap\\Tracking\\None"

local function isTrackingActive(spellId)
    local active = GetTrackingTexture()
    if not active then return nil end
    if active == GetSpellTexture(spellId, BOOKTYPE_SPELL) then return 1 end
    return nil
end

-- =============================================================================
-- Dropdown menu
-- =============================================================================

local dropdown = CreateFrame("Frame", "MinimapIconsDropDown", UIParent, "UIDropDownMenuTemplate")

UIDropDownMenu_Initialize(dropdown, function()
    -- Spell tracking section
    for _, cat in ipairs(SPELL_CATEGORIES) do
        local found = {}
        for _, spell in ipairs(cat.spells) do
            if knownSpells[spell] then
                table.insert(found, spell)
            end
        end
        if table.getn(found) > 0 then
            local title = {}
            title.text = cat.name
            title.isTitle = 1
            title.notCheckable = 1
            UIDropDownMenu_AddButton(title)

            for _, spell in ipairs(found) do
                local sid = knownSpells[spell]
                local info = {}
                info.text = spell
                info.icon = GetSpellTexture(sid, BOOKTYPE_SPELL)
                info.tCoordLeft = 0.0625
                info.tCoordRight = 0.9
                info.tCoordTop = 0.0625
                info.tCoordBottom = 0.9
                info.checked = isTrackingActive(sid)
                info.func = function()
                    if isTrackingActive(sid) then
                        CancelTrackingBuff()
                    else
                        CastSpell(sid, BOOKTYPE_SPELL)
                    end
                end
                UIDropDownMenu_AddButton(info)
            end
        end
    end

    -- NPC tracking section
    local npcTitle = {}
    npcTitle.text = "NPC Tracking"
    npcTitle.isTitle = 1
    npcTitle.notCheckable = 1
    UIDropDownMenu_AddButton(npcTitle)

    for _, cat in ipairs(NPC_CATEGORIES) do
        local catName = cat.name
        local info = {}
        info.text = catName
        info.icon = cat.icon
        info.checked = activeNpcCategories[catName]
        info.keepShownOnClick = 1
        info.func = function()
            if activeNpcCategories[catName] then
                activeNpcCategories[catName] = nil
            else
                activeNpcCategories[catName] = 1
            end
            updateDllTracking()
        end
        UIDropDownMenu_AddButton(info)
    end

end, "MENU")

-- =============================================================================
-- Take over native MiniMapTrackingFrame
-- =============================================================================

local function updateTrackingIcon()
    local tex = GetTrackingTexture()
    if tex then
        MiniMapTrackingIcon:SetTexture(tex)
    else
        MiniMapTrackingIcon:SetTexture(DEFAULT_ICON)
    end
end

-- Resize to match other minimap button icons (EasyLoot etc.)
-- Native: frame 33x33 at TOPLEFT(-15,0), icon 26x26 at TOPLEFT(7,-6), border 64x64 at TOPLEFT
-- Shrink border 64->52 (diff 12), shift frame right 6 and down 6 to compensate
MiniMapTrackingFrame:SetWidth(32)
MiniMapTrackingFrame:SetHeight(32)
MiniMapTrackingFrame:ClearAllPoints()
MiniMapTrackingFrame:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -9, -6)
MiniMapTrackingIcon:ClearAllPoints()
MiniMapTrackingIcon:SetWidth(18)
MiniMapTrackingIcon:SetHeight(18)
MiniMapTrackingIcon:SetPoint("CENTER", MiniMapTrackingFrame, "CENTER", -1, 1)
MiniMapTrackingBorder:ClearAllPoints()
MiniMapTrackingBorder:SetWidth(52)
MiniMapTrackingBorder:SetHeight(52)
MiniMapTrackingBorder:SetPoint("TOPLEFT", MiniMapTrackingFrame, "TOPLEFT", 0, 0)

-- Always show the tracking frame (native hides it when no tracking active)
MiniMapTrackingFrame:Show()
updateTrackingIcon()

-- Prevent the native OnEvent from hiding the frame
MiniMapTrackingFrame:SetScript("OnEvent", function()
    if event == "PLAYER_AURAS_CHANGED" then
        updateTrackingIcon()
    end
end)

-- Left-click opens dropdown, right-click cancels tracking (native behavior)
MiniMapTrackingFrame:SetScript("OnMouseUp", function()
    if arg1 == "LeftButton" then
        GameTooltip:Hide()
        scanSpellbook()
        ToggleDropDownMenu(1, nil, dropdown, MiniMapTrackingFrame, 0, 0)
    elseif arg1 == "RightButton" then
        CancelTrackingBuff()
    end
end)

-- Tooltip
MiniMapTrackingFrame:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetTrackingSpell()
    if not GetTrackingTexture() then
        GameTooltip:AddLine("Tracking")
    end
    GameTooltip:AddLine("Click to select tracking", 0.5, 0.5, 0.5)
    if GetTrackingTexture() then
        GameTooltip:AddLine("Right-click to cancel", 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
end)

-- =============================================================================
-- Events
-- =============================================================================

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("PLAYER_AURAS_CHANGED")

events:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" or event == "SPELLS_CHANGED" then
        scanSpellbook()
    end
    MiniMapTrackingFrame:Show()
    updateTrackingIcon()
end)

-- =============================================================================
-- Slash command
-- =============================================================================

SLASH_TRACKING1 = "/tracking"
SlashCmdList["TRACKING"] = function()
    scanSpellbook()
    ToggleDropDownMenu(1, nil, dropdown, MiniMapTrackingFrame, 0, 0)
end
