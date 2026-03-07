-- Screenshot addon (embedded in DLL, loaded from memory)

BINDING_HEADER_SCREENSHOT = "Screenshot"

SLASH_SCREENSHOT1 = "/ss"
SLASH_SCREENSHOT2 = "/screenshot"
SlashCmdList["SCREENSHOT"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "" or msg == "status" then
        local on, level = WeirdUtilsScreenshot()
        DEFAULT_CHAT_FRAME:AddMessage("Screenshots: " .. (on and "|cff00ff00ON|r" or "|cffff0000OFF|r") .. " (quality " .. level .. ")")
    elseif msg == "on" or msg == "enable" then
        WeirdUtilsScreenshot("enable")
        DEFAULT_CHAT_FRAME:AddMessage("Screenshots |cff00ff00enabled|r")
    elseif msg == "off" or msg == "disable" then
        WeirdUtilsScreenshot("disable")
        DEFAULT_CHAT_FRAME:AddMessage("Screenshots |cffff0000disabled|r")
    elseif tonumber(msg) then
        local q = tonumber(msg)
        if q >= 0 and q <= 9 then
            WeirdUtilsScreenshot("quality", q)
            DEFAULT_CHAT_FRAME:AddMessage("Screenshot quality: " .. q)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Quality must be 0-9|r")
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Screenshot|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /ss - Show status")
        DEFAULT_CHAT_FRAME:AddMessage("  /ss on|off - Enable/disable PNG screenshots")
        DEFAULT_CHAT_FRAME:AddMessage("  /ss 0-9 - Set compression level (0=fast, 9=small)")
    end
end
