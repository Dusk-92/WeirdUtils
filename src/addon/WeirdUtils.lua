-- WeirdUtils addon (embedded in DLL, loaded from memory)

WEIRDUTILS_VERSION = 1

-- Binding header display name
BINDING_HEADER_WEIRDUTILS = "Weird Utils"

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WeirdUtils|r v" .. WEIRDUTILS_VERSION .. " loaded")
    end
end)

SLASH_WEIRDUTILS1 = "/weirdutils"
SLASH_WEIRDUTILS2 = "/wu"
SlashCmdList["WEIRDUTILS"] = function(msg)
    if msg == "version" then
        DEFAULT_CHAT_FRAME:AddMessage("WeirdUtils v" .. WEIRDUTILS_VERSION)
    elseif msg == "test" then
        local result = WeirdUtilsTest()
        DEFAULT_CHAT_FRAME:AddMessage("C function returned: " .. tostring(result))
    elseif msg == "ss" or msg == "screenshot" then
        local on, level = WeirdUtilsScreenshot()
        DEFAULT_CHAT_FRAME:AddMessage("Screenshots: " .. (on and "ON" or "OFF") .. " (quality " .. level .. ")")
    elseif string.find(msg, "^ss ") or string.find(msg, "^screenshot ") then
        local sub = string.match(msg, "^%S+ (.+)")
        if sub == "on" or sub == "enable" then
            WeirdUtilsScreenshot("enable")
            DEFAULT_CHAT_FRAME:AddMessage("Screenshots enabled")
        elseif sub == "off" or sub == "disable" then
            WeirdUtilsScreenshot("disable")
            DEFAULT_CHAT_FRAME:AddMessage("Screenshots disabled")
        elseif tonumber(sub) then
            WeirdUtilsScreenshot("quality", tonumber(sub))
            DEFAULT_CHAT_FRAME:AddMessage("Screenshot quality: " .. sub)
        end
    elseif msg == "interact" then
        DEFAULT_CHAT_FRAME:AddMessage("Interact: InteractNearest() and LootAllCorpses() available")
        DEFAULT_CHAT_FRAME:AddMessage("  Bind in Key Bindings > Interact, or use /run InteractNearest(0)")
        DEFAULT_CHAT_FRAME:AddMessage("  /run LootAllCorpses() - Loot all nearby corpses")
    elseif msg == "outline" or msg == "outline status" then
        local on = OutlineCommand()
        DEFAULT_CHAT_FRAME:AddMessage("Outlines: " .. (on and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
    elseif msg == "outline on" then
        OutlineCommand("on")
        DEFAULT_CHAT_FRAME:AddMessage("Outlines |cff00ff00enabled|r")
    elseif msg == "outline off" then
        OutlineCommand("off")
        DEFAULT_CHAT_FRAME:AddMessage("Outlines |cffff0000disabled|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00WeirdUtils|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu version - Show version")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu test - Test C function call")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu ss - Screenshot status")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu ss on|off - Enable/disable PNG screenshots")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu ss 0-9 - Set compression level")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu interact - Interact/loot info")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu outline - Outline status")
        DEFAULT_CHAT_FRAME:AddMessage("  /wu outline on|off - Enable/disable outlines")
    end
end
