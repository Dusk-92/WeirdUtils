-- Markers addon (embedded in DLL, loaded from memory)
-- Part of WeirdUtils - only loaded when markers module is compiled

MARKERS_VERSION = 2

BINDING_HEADER_MARKERS = "Markers"

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Markers|r v" .. MARKERS_VERSION .. " loaded")
    end
end)

SLASH_MARKERS1 = "/markers"
SLASH_MARKERS2 = "/mark"
SlashCmdList["MARKERS"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "" or msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Markers|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark <1-5>              - Place marker at cursor")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark <1-5> <unit>       - Place marker at unit")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark <1-5> <x> <y> <z>  - Place marker at coords")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark clear [1-5]        - Clear one or all markers")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark pos                - Show player position")

    elseif msg == "clear" then
        ClearWorldMarker()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Markers:|r all cleared")

    elseif msg == "pos" or msg == "position" then
        local x, y, z = GetPlayerPosition()
        if x then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("Position: %.2f, %.2f, %.2f", x, y, z))
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000No player position available|r")
        end

    else
        -- Parse arguments
        local parts = {}
        for word in string.gfind(msg, "%S+") do
            table.insert(parts, word)
        end

        -- /mark clear <index>
        if parts[1] == "clear" then
            local index = tonumber(parts[2])
            if index then
                ClearWorldMarker(index)
            else
                ClearWorldMarker()
            end
            return
        end

        local index = tonumber(parts[1])
        if not index then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Usage:|r /mark <1-5> [unit | x y z] or /mark clear")
            return
        end

        if tonumber(parts[2]) then
            -- /mark 1 x y z
            local x = tonumber(parts[2])
            local y = tonumber(parts[3])
            local z = tonumber(parts[4])
            if x and y and z then
                WorldMarker(index, x, y, z)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Usage:|r /mark <1-5> <x> <y> <z>")
            end
        elseif parts[2] then
            -- /mark 1 target
            WorldMarker(index, parts[2])
        else
            -- /mark 1 (cursor position)
            WorldMarker(index)
        end
    end
end
