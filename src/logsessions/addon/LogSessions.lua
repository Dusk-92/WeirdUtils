-- LogSessions addon: update log path globals to show actual redirected paths

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    if GetCombatLogPath and COMBATLOGENABLED == "Combat being logged to Logs\\WoWCombatLog.txt" then
        COMBATLOGENABLED = "Combat being logged to " .. GetCombatLogPath()
    end
    if GetChatLogPath and CHATLOGENABLED == "Chat being logged to Logs\\WoWChatLog.txt" then
        CHATLOGENABLED = "Chat being logged to " .. GetChatLogPath()
    end
end)
