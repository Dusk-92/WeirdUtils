-- Outline addon (embedded in DLL, loaded from memory)
-- Part of WeirdUtils - only loaded when outline module is compiled

OUTLINE_VERSION = 40

BINDING_HEADER_OUTLINE = "Outline"

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")

local syncElapsed = 0

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        OutlineSyncTarget()
        local on = OutlineCommand()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Outline|r v" .. OUTLINE_VERSION .. " loaded (" .. (on and "enabled" or "disabled") .. ")")
    elseif event == "PLAYER_TARGET_CHANGED" then
        OutlineSyncTarget()
        syncElapsed = 0
    end
end)

-- AutoFix safety net: republish the current target from the safe Lua/main
-- thread at low frequency so a missed/early target event cannot disable Outline.
frame:SetScript("OnUpdate", function()
    syncElapsed = syncElapsed + arg1
    if syncElapsed >= 0.10 then
        syncElapsed = 0
        OutlineSyncTarget()
    end
end)

SLASH_OUTLINE1 = "/outline"
SLASH_OUTLINE2 = "/ol"
SlashCmdList["OUTLINE"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "" or msg == "status" then
        local on = OutlineCommand()
        DEFAULT_CHAT_FRAME:AddMessage("Outlines: " .. (on and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
    elseif msg == "on" or msg == "enable" then
        OutlineCommand("on")
        DEFAULT_CHAT_FRAME:AddMessage("Outlines |cff00ff00enabled|r")
    elseif msg == "off" or msg == "disable" then
        OutlineCommand("off")
        DEFAULT_CHAT_FRAME:AddMessage("Outlines |cffff0000disabled|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Outline|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /ol - Show status")
        DEFAULT_CHAT_FRAME:AddMessage("  /ol on|off - Toggle outlines")
    end
end
