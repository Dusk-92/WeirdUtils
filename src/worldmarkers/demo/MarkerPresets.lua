-- MarkerPresets: save and restore world marker layouts.
-- Demonstrates the WorldMarker / GetWorldMarker / ClearWorldMarker API.
--
-- /mp save <name>    — snapshot all current marker positions
-- /mp place <name>   — restore a saved layout (places all markers at once)
-- /mp clear          — clear all markers
-- /mp list           — list saved presets
-- /mp delete <name>  — delete a preset

local NUM_MARKERS = 5
local PREFIX = "|cff00ccff[Markers]|r "

local function msg(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

local function savePreset(name)
    if not name or name == "" then
        msg("Usage: /mp save <name>")
        return
    end

    local preset = {}
    local count = 0
    for i = 1, NUM_MARKERS do
        local x, y, z, area = GetWorldMarker(i)
        if x then
            preset[i] = { x = x, y = y, z = z, area = area }
            count = count + 1
        end
    end

    if count == 0 then
        msg("No markers to save.")
        return
    end

    MarkerPresets_Saved[name] = preset
    msg("Saved |cffffffff" .. name .. "|r (" .. count .. " marker" .. (count > 1 and "s" or "") .. ")")
end

local function placePreset(name)
    if not name or name == "" then
        msg("Usage: /mp place <name>")
        return
    end

    local preset = MarkerPresets_Saved[name]
    if not preset then
        msg("No preset named |cffffffff" .. name .. "|r")
        return
    end

    if not CanSetWorldMarkers() then
        msg("|cffff4444No permission|r (need leader or assist)")
        return
    end

    -- Clear existing markers, then place the saved ones
    ClearWorldMarker()

    local count = 0
    for i = 1, NUM_MARKERS do
        local m = preset[i]
        if m then
            WorldMarker(i, m.x, m.y, m.z)
            count = count + 1
        end
    end

    msg("Placed |cffffffff" .. name .. "|r (" .. count .. " marker" .. (count > 1 and "s" or "") .. ")")
end

local function clearMarkers()
    if not CanSetWorldMarkers() then
        msg("|cffff4444No permission|r (need leader or assist)")
        return
    end
    ClearWorldMarker()
    msg("Cleared all markers.")
end

local function listPresets()
    local any = false
    for name, preset in pairs(MarkerPresets_Saved) do
        local count = 0
        for i = 1, NUM_MARKERS do
            if preset[i] then count = count + 1 end
        end
        msg("  |cffffffff" .. name .. "|r — " .. count .. " marker" .. (count > 1 and "s" or ""))
        any = true
    end
    if not any then
        msg("No saved presets.")
    end
end

local function deletePreset(name)
    if not name or name == "" then
        msg("Usage: /mp delete <name>")
        return
    end
    if not MarkerPresets_Saved[name] then
        msg("No preset named |cffffffff" .. name .. "|r")
        return
    end
    MarkerPresets_Saved[name] = nil
    msg("Deleted |cffffffff" .. name .. "|r")
end

local f = CreateFrame("Frame")
f:RegisterEvent("VARIABLES_LOADED")
f:SetScript("OnEvent", function()
    MarkerPresets_Saved = MarkerPresets_Saved or {}
end)

SLASH_MARKERPRESETS1 = "/mp"
SLASH_MARKERPRESETS2 = "/markerpreset"
SlashCmdList["MARKERPRESETS"] = function(input)
    local cmd, rest = string.match(input, "^(%S+)%s*(.*)")
    if not cmd then
        msg("Commands: save | place | clear | list | delete")
        return
    end

    cmd = string.lower(cmd)
    local name = rest ~= "" and rest or nil

    if cmd == "save" then
        savePreset(name)
    elseif cmd == "place" or cmd == "load" then
        placePreset(name)
    elseif cmd == "clear" then
        clearMarkers()
    elseif cmd == "list" or cmd == "ls" then
        listPresets()
    elseif cmd == "delete" or cmd == "del" or cmd == "rm" then
        deletePreset(name)
    else
        msg("Unknown command: " .. cmd)
        msg("Commands: save | place | clear | list | delete")
    end
end
