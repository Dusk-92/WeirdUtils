-- Interact addon (embedded in DLL, loaded from memory)
-- Part of WeirdUtils - only loaded when interact module is compiled

INTERACT_VERSION = 1

BINDING_HEADER_INTERACT = "Interact"

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Interact|r v" .. INTERACT_VERSION .. " loaded")
    end
end)

SLASH_INTERACT1 = "/interact"
SlashCmdList["INTERACT"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "" or msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Interact|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /interact - Show this help")
        DEFAULT_CHAT_FRAME:AddMessage("  Key bind: Interact - Interact with nearest NPC/object")
        DEFAULT_CHAT_FRAME:AddMessage("  Key bind: Interact (auto-loot) - Interact and auto-loot")
        DEFAULT_CHAT_FRAME:AddMessage("  Key bind: Loot All Corpses - Loot all nearby corpses")
        DEFAULT_CHAT_FRAME:AddMessage("  /run InteractNearest(0) - Interact without loot")
        DEFAULT_CHAT_FRAME:AddMessage("  /run InteractNearest(1) - Interact with auto-loot")
        DEFAULT_CHAT_FRAME:AddMessage("  /run LootAllCorpses() - Loot all nearby corpses")
    end
end
