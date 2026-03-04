-- WeirdUtils core addon (embedded in DLL, loaded from memory)
-- This is always loaded - module addons (Outline, Interact, Screenshot) are loaded separately

WEIRDUTILS_VERSION = 1

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WeirdUtils|r v" .. WEIRDUTILS_VERSION .. " core loaded")

        -- Update log path globals to show actual redirected paths (English locale only)
        if GetCombatLogPath and COMBATLOGENABLED == "Combat being logged to Logs\\WoWCombatLog.txt" then
            COMBATLOGENABLED = "Combat being logged to " .. GetCombatLogPath()
        end
        if GetChatLogPath and CHATLOGENABLED == "Chat being logged to Logs\\WoWChatLog.txt" then
            CHATLOGENABLED = "Chat being logged to " .. GetChatLogPath()
        end
    end
end)

SLASH_WEIRDUTILS1 = "/weirdutils"
SLASH_WEIRDUTILS2 = "/wu"
SlashCmdList["WEIRDUTILS"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "" or msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WeirdUtils|r v" .. WEIRDUTILS_VERSION .. " commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu version - Show version")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu test - Test C function call")
        DEFAULT_CHAT_FRAME:AddMessage("Module commands (if compiled):")
        DEFAULT_CHAT_FRAME:AddMessage("  /outline, /ol - Outline controls")
        DEFAULT_CHAT_FRAME:AddMessage("  /interact - Interact/loot info")
        DEFAULT_CHAT_FRAME:AddMessage("  /ss, /screenshot - Screenshot controls")
    elseif msg == "version" then
        DEFAULT_CHAT_FRAME:AddMessage("WeirdUtils v" .. WEIRDUTILS_VERSION)
    elseif msg == "test" then
        local result = WeirdUtilsTest()
        DEFAULT_CHAT_FRAME:AddMessage("C function returned: " .. tostring(result))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Unknown command:|r " .. msg)
    end
end
