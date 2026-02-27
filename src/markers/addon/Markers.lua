-- Markers addon (embedded in DLL, loaded from memory)
-- Part of WeirdUtils - only loaded when markers module is compiled

MARKERS_VERSION = 1

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
        DEFAULT_CHAT_FRAME:AddMessage("  /mark test - Toggle test marker at player position")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark on - Create test marker")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark off - Destroy test marker")
        DEFAULT_CHAT_FRAME:AddMessage("  /mark pos - Show player position")

    elseif msg == "test" or msg == "toggle" then
        TestMarkerToggle()

    elseif msg == "on" or msg == "create" then
        TestMarkerCreate()

    elseif msg == "off" or msg == "destroy" then
        TestMarkerDestroy()

    elseif msg == "pos" or msg == "position" then
        local x, y, z = GetPlayerPosition()
        DEFAULT_CHAT_FRAME:AddMessage(string.format("Position: %.2f, %.2f, %.2f", x, y, z))

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Unknown command:|r " .. msg)
    end
end
