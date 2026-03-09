-- MinimapIcons addon (embedded in DLL, loaded from memory)
-- Takes over the native MiniMapTrackingFrame to add a tracking spell dropdown
-- with Wrath-style NPC tracking categories backed by DLL-side minimap hooks.

MINIMAPICONS_VERSION = 3

-- =============================================================================
-- Tracking spell definitions grouped by category
-- =============================================================================

local SPELL_CATEGORIES = {
    { name = UnitClass("player") .. " Tracking", spells = {
        "Track Beasts", "Track Humanoids", "Track Undead", "Track Hidden",
        "Track Elementals", "Track Demons", "Track Giants", "Track Dragonkin",
        "Sense Undead", "Sense Demons",
    }},
    -- { name = "Class Abilities", spells = {
        -- "Sense Undead", "Sense Demons",
    -- }},
    { name = "Professions", spells = {
        "Find Herbs", "Find Minerals", "Find Treasure",
    }},
}

-- =============================================================================
-- Locale-aware vendor subname filters (pipe-delimited exact subnames)
-- DLL matches ANY pipe segment as a substring against the NPC's subname.
-- English subnames always included as fallback for unlocalized custom NPCs.
-- =============================================================================

-- Build a pipe-delimited filter: locale-specific first, then enUS as fallback.
local function getLocaleFilter(filters)
    local locale = GetLocale and GetLocale() or "enUS"
    local extra = locale ~= "enUS" and filters[locale] or nil
    if extra then
        return extra .. "|" .. filters.enUS
    end
    return filters.enUS
end

-- Reagent vendors: NPCs that sell class reagents (Arcane Powder, Ankh, Candles, Seeds, etc.)
-- enUS = base subnames (always included); other locales = additional localized subnames only.
local REAGENT_FILTERS = {
    enUS = "Apprentice Witch Doctor|Arcane Goods|Arcane Goods Vendor|Arcane Trinkets Vendor|Ered Ruin|Exotic Reagent Merchant|Lorekeeper|Poisons & Reagents|Potions, Scrolls and Reagents|Reagent Supplier|Reagent Supplies|Reagent Vendor|Reagents|Reagents & Poisons|Reagents and Herbs|Reagents Vendor|Scrolls & Potions|Voodoo Hexxer",
    frFR = "Apprentie sorcier-docteur|Fournitures arcaniques|Alchimie & composants|Marchande de bijoux magiques|Marchand de r\195\169actifs exotiques|Gardien du savoir|Poisons & composants|Potions, Parchemins & Composants|Composants|Composants & fournitures pour poisons|Composants, herbes & fournitures pour poisons",
    deDE = "Hexendoktorlehrling|Arkanarien|Alchemiebedarf & Reagenzien|Verk\195\164uferin arkaner Gegenst\195\164nde|H\195\164ndler f\195\188r exotische Reagenzien|Wissensh\195\188ter|Gifte & Reagenzien|Druidenlehrerin|Reagenzien|Reagenzienbedarf|Reagenzien & Gifte|Reagenzien, Kr\195\164uter & Gifte",
    zhCN = "\232\167\129\228\185\160\229\183\171\229\140\187|\233\173\148\230\179\149\232\180\167\231\137\169|\231\130\188\233\135\145\230\156\175\229\146\140\230\157\144\230\150\153\228\190\155\229\186\148\229\149\134|\233\173\148\230\179\149\232\180\167\231\137\169\229\149\134\228\186\186|\233\173\148\230\179\149\233\165\176\229\147\129\229\149\134\228\186\186|\229\159\131\233\155\183\230\157\156\229\155\160|\231\137\185\230\174\138\230\157\144\230\150\153\229\149\134\228\186\186|\229\141\154\229\173\166\232\128\133|\230\175\146\232\141\175\229\146\140\230\157\144\230\150\153|\232\141\175\229\137\130\227\128\129\229\141\183\232\189\180\229\146\140\230\157\144\230\150\153|\232\175\149\232\141\175\228\190\155\229\186\148\229\149\134|\230\150\189\230\179\149\230\157\144\230\150\153\228\190\155\229\186\148\229\149\134|\230\150\189\230\179\149\230\157\144\230\150\153\229\149\134|\230\157\144\230\150\153\229\149\134|\230\150\189\230\179\149\230\157\144\230\150\153|\230\157\144\230\150\153\228\184\142\230\175\146\232\141\175\229\149\134|\232\176\131\233\133\146\229\184\136|\230\150\189\230\179\149\230\157\144\230\150\153\229\146\140\232\141\175\232\141\137\229\149\134|\229\141\183\232\189\180\229\146\140\232\141\175\229\137\130|\229\183\171\230\175\146\229\166\150\230\156\175\229\184\136",
    esES = "Aprendiza m\195\169dico brujo|Art\195\173culos Arcanos|Suministros de alquimia y componentes|Vendedora de abalorios Arcanos|Mercader de componentes ex\195\179ticos|Tradicionalista|Venenos y componentes|Instructora de druidas|Componentes|Suministros de componentes|Suministros de venenos y componentes|Componentes, hierbas y suministros de venenos",
    ruRU = "\208\163\209\135\208\181\208\189\208\184\209\134\208\176 \208\183\208\189\208\176\209\133\208\176\209\128\209\143|\208\167\208\176\209\128\208\190\208\180\208\181\208\185\209\129\208\186\208\184\208\181 \209\130\208\190\208\178\208\176\209\128\209\139|\208\162\208\190\208\178\208\176\209\128\209\139 \208\180\208\187\209\143 \208\176\208\187\209\133\208\184\208\188\208\184\208\186\208\176 \208\184 \209\128\208\181\208\176\208\179\208\181\208\189\209\130\209\139|\208\159\209\128\208\190\208\180\208\176\208\178\208\181\209\134 \209\135\208\176\209\128\208\190\208\180\208\181\208\185\209\129\208\186\208\184\209\133 \208\176\208\186\209\129\208\181\209\129\209\129\209\131\208\176\209\128\208\190\208\178|\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \209\141\208\186\208\183\208\190\209\130\208\184\209\135\208\181\209\129\208\186\208\184\208\188\208\184 \209\128\208\181\208\176\208\179\208\181\208\189\209\130\208\176\208\188\208\184|\208\161\208\186\208\176\208\183\208\184\209\130\208\181\208\187\209\140|\208\175\208\180\209\139 \208\184 \209\128\208\181\208\176\208\179\208\181\208\189\209\130\209\139|\208\151\208\181\208\187\209\140\209\143, \209\129\208\178\208\184\209\130\208\186\208\184 \208\184 \209\128\208\181\208\176\208\179\208\181\208\189\209\130\209\139|\208\160\208\181\208\176\208\179\208\181\208\189\209\130\209\139|\208\160\208\181\208\176\208\179\208\181\208\189\209\130\209\139 \208\184 \209\143\208\180\209\139|\208\160\208\181\208\176\208\179\208\181\208\189\209\130\209\139, \209\130\209\128\208\176\208\178\209\139 \208\184 \209\143\208\180\209\139",
}

-- Trade goods vendors: NPCs that sell thread, dye, flux, tools, etc.
local TRADE_FILTERS = {
    enUS = "Druid of the Claw|East Oceanic Trading Co|Farmers Market|Flaxwhisker Front|General Trade Goods Merchant|General Trade Goods Vendor|General Trade Supplier|Get Rich Or Die Grinding|Harborage Supplies|Hard Chores|Hard Knocks Society|Schmetterlingsbrigade|SQUAD|Superior Tradesman|Thunderhorn Clan|Trade Goods|Trade Goods Supplier|Trade Goods Supplies|Trade Supplier|Trade Supplies",
    frFR = "Fournitures d'artisanat|Excellent travailleur du cuir|Excellent commer\195\167ant",
    deDE = "Handwerkswaren|\195\156berragender Lederer|\195\156berragender Handwerker",
    zhCN = "\229\136\169\231\136\170\229\190\183\233\178\129\228\188\138|\229\134\156\232\180\184\229\184\130\229\156\186|\229\149\134\228\186\186|\230\157\130\232\180\167\228\190\155\229\186\148\229\149\134|\232\180\184\230\152\147\229\149\134\228\186\186|\230\184\148\229\133\183\228\190\155\229\186\148\229\149\134|\228\184\141\229\175\140\229\176\177\232\130\157|\233\171\152\231\186\167\231\154\174\229\140\160|\232\137\176\232\139\166\231\154\132\229\174\182\229\138\161\230\180\187|\231\161\172\229\135\187\229\141\143\228\188\154|\230\150\189\230\162\133\231\137\185\230\158\151\230\151\133|\229\176\143\231\187\132|\233\171\152\231\186\167\229\149\134\228\186\186|\233\155\183\232\167\146\230\176\143\230\151\143|\229\149\134\229\147\129\228\190\155\229\186\148\229\149\134|\232\180\184\230\152\147\228\190\155\229\186\148\229\149\134",
    esES = "Suministros comerciales|Peletero superior|Mercader superior|Objetos comerciables",
    ruRU = "\208\165\208\190\208\183\209\143\208\185\209\129\209\130\208\178\208\181\208\189\208\189\209\139\208\181 \208\191\209\128\208\184\208\191\208\176\209\129\209\139|\208\158\208\191\209\139\209\130\208\189\209\139\208\185 \208\186\208\190\208\182\208\181\208\178\208\189\208\184\208\186|\208\158\208\191\209\139\209\130\208\189\209\139\208\185 \209\130\208\190\209\128\208\179\208\190\208\178\208\181\209\134|\208\165\208\190\208\183\209\143\208\185\209\129\209\130\208\178\208\181\208\189\208\189\209\139\208\181 \209\130\208\190\208\178\208\176\209\128\209\139",
}

-- Poison vendors: NPCs that sell poison reagents (Flash Powder, Deathweed, Thieves' Tools, etc.)
local POISON_FILTERS = {
    enUS = "Ered Ruin|Poison Supplier|Poison Supplies|Poison Vendor|Poisons & Reagents|Reagents & Poisons|Shady Dealer|Shady Goods|Tools & Supplies",
    frFR = "Fournitures pour poisons|Poisons & composants|Composants & fournitures pour poisons|Marchand douteux|Fournitures douteuses|Outils & fournitures",
    deDE = "Gifte|Gifte & Reagenzien|Reagenzien & Gifte|Zwielichtiger H\195\164ndler|Zweifelhafte Waren|Giftverk\195\164ufer",
    zhCN = "\229\159\131\233\155\183\230\157\156\229\155\160|\230\175\146\232\141\175\229\149\134|\230\175\146\232\141\175\229\146\140\230\157\144\230\150\153|\230\157\144\230\150\153\228\184\142\230\175\146\232\141\175\229\149\134|\232\176\131\233\133\146\229\184\136|\229\183\165\229\133\183\229\146\140\232\161\165\231\187\153\229\147\129",
    esES = "Suministros de venenos|Venenos y componentes|Suministros de venenos y componentes|Vendedor sospechoso|Art\195\173culos sospechosos|Vendedor de venenos",
    ruRU = "\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \209\143\208\180\208\176\208\188\208\184|\208\175\208\180\209\139 \208\184 \209\128\208\181\208\176\208\179\208\181\208\189\209\130\209\139|\208\160\208\181\208\176\208\179\208\181\208\189\209\130\209\139 \208\184 \209\143\208\180\209\139|\208\161\208\190\208\188\208\189\208\184\209\130\208\181\208\187\209\140\208\189\209\139\208\185 \208\180\208\181\208\187\208\181\209\134|\208\161\208\190\208\188\208\189\208\184\209\130\208\181\208\187\209\140\208\189\209\139\208\181 \209\130\208\190\208\178\208\176\209\128\209\139|\208\152\208\189\209\129\209\130\209\128\209\131\208\188\208\181\208\189\209\130\209\139 \208\184 \208\191\209\128\208\184\208\191\208\176\209\129\209\139",
}

-- Ammunition vendors: NPCs that sell arrows, bullets, and shot
local AMMO_FILTERS = {
    enUS = "Ammunition|Ammunition Vendor|Bow & Arrow Merchant|Bow & Gun Merchant|Bow Merchant|Bowyer|Bowyer & Fletching Goods|Bowyer & Gunsmith|Fletcher|Gun Merchant|Guns and Ammo|Guns and Ammo Merchant|Guns Merchant|Guns Vendor|Gunsmith|Gunsmith & Bowyer|Superior Bowyer|Weaponsmith & Gunsmith",
    frFR = "Vendeur de munitions|Marchand d'arcs et de fl\195\168ches|Marchande d'arcs & de fusils|Marchand d'arcs|Marchande d'arcs|Fabricant d'arcs|Fabricante d'arcs|Fournitures pour arcs et fl\195\168ches|Fabricant d'arcs & armes \195\160 feu|Marchand d'armes \195\160 feu|Marchande d'armes \195\160 feu|Armes \195\160 feu & munitions|Fabricant d'armes \195\160 feu|Fabricante d'armes \195\160 feu|Excellent fabricant d'arcs|Fabricant d'armes & de fusils",
    deDE = "Bogenh\195\164ndler|Bogenh\195\164ndlerin|Bogen- & Schusswaffenh\195\164ndlerin|Bogenmacher|J\195\164gerlehrer & Bogenmacher|Bogenmacherin|Bogen- & Pfeilmacherbedarf|Bogen- & B\195\188chsenmacher|Schusswaffenh\195\164ndler|Schusswaffenh\195\164ndlerin|Verk\195\164uferin f\195\188r B\195\182gen & Gewehre|Schusswaffenverk\195\164ufer|B\195\188chsenmacher|B\195\188chsenmacherin|\195\156berragender Bogenmacher|Waffenschmied & B\195\188chsenmacher",
    zhCN = "\229\188\185\232\141\175|\229\188\185\232\141\175\229\149\134\228\186\186|\229\188\132\231\174\173\229\149\134|\229\188\132\231\174\173\229\146\140\230\158\170\230\162\176|\229\188\132\231\174\173\229\149\134\228\186\186|\233\128\160\231\174\173\229\184\136|\233\128\160\229\137\170\229\184\136|\230\158\170\230\162\176\229\149\134|\230\158\170\230\162\176\229\149\134\228\186\186|\230\158\170\230\162\176\229\146\140\229\188\185\232\141\175\229\149\134|\230\158\170\230\162\176\229\146\140\229\136\182\229\188\132\229\149\134|\233\171\152\231\186\167\229\136\182\229\188\132\229\184\136|\230\173\166\229\153\168\233\148\187\233\128\160\229\146\140\230\158\170\230\162\176\229\149\134",
    esES = "Mercader de arcos|Mercader de arcos y armas de fuego|Fabricante de arcos|Instructor de cazadores y arquero|Arcos, flechas y otros art\195\173culos de tiro con arco|Fabricante de arcos y forjador de armas de fuego|Mercader de armas de fuego|Vendedora de arcos y rifles|Vendedor de armas de fuego|Forjador de armas de fuego|Forjadora de armas de fuego|Forjador de armas de fuego y fabricante de arcos|Fabricante de arcos superior|Forjador de armas de fuego y armas en general",
    ruRU = "\208\159\209\128\208\190\208\180\208\176\208\178\208\181\209\134 \208\177\208\190\208\181\208\191\209\128\208\184\208\191\208\176\209\129\208\190\208\178|\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \208\187\209\131\208\186\208\176\208\188\208\184 \208\184 \209\129\209\130\209\128\208\181\208\187\208\176\208\188\208\184|\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \208\187\209\131\208\186\208\176\208\188\208\184 \208\184 \209\128\209\131\208\182\209\140\209\143\208\188\208\184|\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \208\187\209\131\208\186\208\176\208\188\208\184|\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \209\129\209\130\209\128\208\181\208\187\208\176\208\188\208\184|\208\162\208\190\209\128\208\179\208\190\208\178\208\181\209\134 \208\190\208\179\208\189\208\181\209\129\209\130\209\128\208\181\208\187\209\140\208\189\209\139\208\188 \208\190\209\128\209\131\208\182\208\184\208\181\208\188|\208\160\209\131\208\182\209\140\209\143 \208\184 \208\177\208\190\208\181\208\191\209\128\208\184\208\191\208\176\209\129\209\139|\208\159\209\128\208\190\208\180\208\176\208\178\208\181\209\134 \208\190\208\179\208\189\208\181\209\129\209\130\209\128\208\181\208\187\209\140\208\189\208\190\208\179\208\190 \208\190\209\128\209\131\208\182\208\184\209\143|\208\160\209\131\208\182\208\181\208\185\208\189\208\184\208\186|\208\160\209\131\208\182\209\140\209\143 \208\184 \208\187\209\131\208\186\208\184|\208\158\208\191\209\139\209\130\208\189\209\139\208\185 \208\187\209\131\209\135\208\189\208\184\208\186|\208\165\208\190\208\187\208\190\208\180\208\189\208\190\208\181 \208\184 \208\190\208\179\208\189\208\181\209\129\209\130\209\128\208\181\208\187\209\140\208\189\208\190\208\181 \208\190\209\128\209\131\208\182\208\184\208\181",
}

-- NPC tracking categories (icons embedded from Wrath client)
-- trackingType maps to DLL WeirdUtils.SetObjectTypeBlip() type names.
-- Filter: pipe-delimited exact subname match (DLL matches ANY segment as substring).
--   Filtered entries take priority over unfiltered catch-all entries with the same flag.
--   "dynamic" filter is resolved at runtime via getFilter().
local NPC_CATEGORIES = {
    { name = "Banker",        trackingType = "banker",       icon = "Interface\\Minimap\\Tracking\\Banker", default = 1 },
    { name = "Auctioneer",    trackingType = "auctioneer",   icon = "Interface\\Minimap\\Tracking\\Auctioneer" },
    { name = "Repair",        trackingType = "repair",       icon = "Interface\\Minimap\\Tracking\\Repair", default = 1 },
    { name = "Mailbox",       trackingType = "mailbox",      icon = "Interface\\Minimap\\Tracking\\Mailbox", default = 1 },
    { name = "Brainwasher",   trackingType = "brainwasher",  icon = "Interface\\Minimap\\Tracking\\Brainwasher", scale = 1.8, default = 1 },
    { name = "Innkeeper",     trackingType = "innkeeper",    icon = "Interface\\Minimap\\Tracking\\Innkeeper", default = 1 },
    { name = "Flight Master", trackingType = "flightmaster", icon = "Interface\\Minimap\\Tracking\\FlightMaster" },
    { name = "Reagent Vendor", trackingType = "vendor",      icon = "Interface\\Minimap\\Tracking\\Reagents",
        getFilter = function() return getLocaleFilter(REAGENT_FILTERS) end },
    { name = "Poison Vendor", trackingType = "vendor",       icon = "Interface\\Minimap\\Tracking\\Poison",
        getFilter = function() return getLocaleFilter(POISON_FILTERS) end },
    { name = "Trade Goods",   trackingType = "vendor",       icon = "Interface\\Minimap\\Tracking\\Trade",
        getFilter = function() return getLocaleFilter(TRADE_FILTERS) end },
    { name = "Ammunition",    trackingType = "vendor",       icon = "Interface\\Minimap\\Tracking\\Ammunition",
        getFilter = function() return getLocaleFilter(AMMO_FILTERS) end },
    { name = "General Vendor", trackingType = "vendor",      icon = "Interface\\Minimap\\Tracking\\Food" },
    { name = "Stable Master", trackingType = "stablemaster", icon = "Interface\\Minimap\\Tracking\\StableMaster" },
    { name = "Battle Master", trackingType = "battlemaster", icon = "Interface\\Minimap\\Tracking\\BattleMaster" },
    { name = "Class Trainer", trackingType = "trainer",      icon = "Interface\\Minimap\\Tracking\\Class",
        getFilter = function() return (UnitClass("player")) end },
    { name = "Profession Trainer", trackingType = "trainer", icon = "Interface\\Minimap\\Tracking\\Profession",
        getExclude = function() return UnitClass("player") end },
}

-- =============================================================================
-- NPC tracking state (persisted per-character via SavedVariablesPerCharacter)
-- =============================================================================

local activeNpcCategories = {} -- name -> 1/nil, loaded from WeirdUtils_MinimapIconsSettings

-- Sync DLL tracking state with addon toggle state.
-- Each category gets its own DLL call. Categories with a subnameFilter
-- (e.g. Class Trainer filtering by player class) create filtered entries
-- that take priority over unfiltered catch-all entries.
local function updateDllTracking()
    if not WeirdUtils.SetObjectTypeBlip then return end
    if WeirdUtils.SetMinimapCityToggle then
        WeirdUtils.SetMinimapCityToggle(activeNpcCategories["City Toggle"] and 1 or 0)
    end
    for _, cat in ipairs(NPC_CATEGORIES) do
        local inc = cat.getFilter and cat.getFilter() or nil
        local exc = cat.getExclude and cat.getExclude() or nil
        if activeNpcCategories[cat.name] then
            WeirdUtils.SetObjectTypeBlip(cat.trackingType, cat.icon, cat.scale or 1.5, inc, exc)
        else
            WeirdUtils.SetObjectTypeBlip(cat.trackingType, nil, nil, inc, exc)
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

local dropdown = CreateFrame("Frame", "WeirdUtils_MinimapIconsDropDown", UIParent, "UIDropDownMenuTemplate")

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

    -- City Toggle: suppress NPC/GO tracking in capital cities
    local cityInfo = {}
    cityInfo.text = "Hide in Cities"
    cityInfo.icon = "Interface\\Minimap\\Tracking\\City"
    cityInfo.checked = activeNpcCategories["City Toggle"]
    cityInfo.keepShownOnClick = 1
    cityInfo.func = function()
        if activeNpcCategories["City Toggle"] then
            activeNpcCategories["City Toggle"] = nil
        else
            activeNpcCategories["City Toggle"] = 1
        end
        WeirdUtils_MinimapIconsSettings = activeNpcCategories
        updateDllTracking()
    end
    UIDropDownMenu_AddButton(cityInfo)

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
            WeirdUtils_MinimapIconsSettings = activeNpcCategories
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
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("PLAYER_AURAS_CHANGED")

events:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        if WeirdUtils_MinimapIconsSettings then
            activeNpcCategories = WeirdUtils_MinimapIconsSettings
        else
            for _, cat in ipairs(NPC_CATEGORIES) do
                if cat.default then
                    activeNpcCategories[cat.name] = 1
                end
            end
            WeirdUtils_MinimapIconsSettings = activeNpcCategories
        end
        updateDllTracking()
    elseif event == "PLAYER_LOGIN" or event == "SPELLS_CHANGED" then
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
