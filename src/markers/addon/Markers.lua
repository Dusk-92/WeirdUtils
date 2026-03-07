-- WorldMarkers addon (embedded in DLL, loaded from memory)

WORLDMARKERS_VERSION = 4

BINDING_HEADER_WORLDMARKERS = "World Markers"

-- =============================================================================
-- Addon message protocol
-- Delimiter is ":" (pipe "|" is WoW's escape char for color codes)
--
-- Messages:
--   P:idx:x:y:z:area    - live placement (everyone processes)
--   C:idx                - clear one marker
--   CA                   - clear all markers
--   SR                   - sync request (non-leader asking leader to send defs)
--   LSR                  - leader sync request (leader asking anyone to send defs)
--   SF:idx:x:y:z:area   - sync fill (only processed by requester in sync mode)
--
-- Permission model: ALL permission checks are enforced DLL-side.
--   WorldMarker/ClearWorldMarker: DLL checks local player is leader/assist.
--   SetMarkerDef/ClearMarkerDef: DLL checks sender name against roster.
--   CanSetWorldMarkers(): DLL returns 1 if local player has permission.
-- =============================================================================

local MSG_PREFIX = "WMark"
local NUM_MARKERS = 5

local function getChannel()
    if GetNumRaidMembers() > 0 then
        return "RAID"
    elseif GetNumPartyMembers() > 0 then
        return "PARTY"
    end
    return nil
end

-- =============================================================================
-- Sync state: after sending SR/LSR, accept SF from the first responder only.
-- Cleared by a 5s timer, or when we send our own placement/clear messages.
-- =============================================================================

local syncing = false
local syncSender = nil

-- General-purpose one-shot timer. Set .delay, .callback, then :Show().
local syncTimer = CreateFrame("Frame")
syncTimer.elapsed = 0
syncTimer.delay = 5
syncTimer.callback = nil
syncTimer:Hide()
syncTimer:SetScript("OnUpdate", function()
    syncTimer.elapsed = syncTimer.elapsed + arg1
    if syncTimer.elapsed >= syncTimer.delay then
        syncTimer:Hide()
        if syncTimer.callback then
            syncTimer.callback()
        end
    end
end)

local function clearSyncState()
    syncing = false
    syncSender = nil
    syncTimer:Hide()
end

local function startSyncing()
    syncing = true
    syncSender = nil
    syncTimer.elapsed = 0
    syncTimer.delay = 5
    syncTimer.callback = function()
        if syncing then
            syncing = false
            syncSender = nil
        end
    end
    syncTimer:Show()
end

-- =============================================================================
-- Broadcast helpers
-- =============================================================================

local function broadcastPlace(index, x, y, z, areaId)
    clearSyncState()
    local ch = getChannel()
    if not ch then return end
    local msg = "P:" .. index .. ":" .. x .. ":" .. y .. ":" .. z .. ":" .. areaId
    SendAddonMessage(MSG_PREFIX, msg, ch)
end

local function broadcastClear(index)
    clearSyncState()
    local ch = getChannel()
    if not ch then return end
    local msg = "C:" .. index
    SendAddonMessage(MSG_PREFIX, msg, ch)
end

local function broadcastClearAll()
    clearSyncState()
    local ch = getChannel()
    if not ch then return end
    SendAddonMessage(MSG_PREFIX, "CA", ch)
end

local function broadcastAllDefs()
    local ch = getChannel()
    if not ch then return end
    for i = 1, NUM_MARKERS do
        local x, y, z, areaId = WorldMarkers.GetMarkerDef(i)
        if x then
            local msg = "SF:" .. i .. ":" .. x .. ":" .. y .. ":" .. z .. ":" .. areaId
            SendAddonMessage(MSG_PREFIX, msg, ch)
        end
    end
end

-- =============================================================================
-- Permission denial feedback (cooldown + max 3 per login, reset on success)
-- =============================================================================

local denyCount = 0
local denyLastTime = 0
local DENY_COOLDOWN = 5
local DENY_MAX = 3

local function showDenyMessage()
    if denyCount >= DENY_MAX then return end
    local now = GetTime()
    if now - denyLastTime < DENY_COOLDOWN then return end
    denyLastTime = now
    denyCount = denyCount + 1
    if GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00You must be leader or assist to use world markers.|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00You must be in a group to use world markers.|r")
    end
end

-- =============================================================================
-- Wrap DLL functions to broadcast on group placement/clear
-- =============================================================================

local RawWorldMarker = WorldMarker
function WorldMarker(index, ...)
    local ok = RawWorldMarker(index, unpack(arg))
    if not ok then
        showDenyMessage()
        return
    end
    denyCount = 0
    local ch = getChannel()
    if ch then
        local x, y, z, areaId = WorldMarkers.GetMarkerDef(index)
        if x then
            broadcastPlace(index, x, y, z, areaId)
        end
    end
end

local RawClearWorldMarker = ClearWorldMarker
function ClearWorldMarker(index)
    local ok = RawClearWorldMarker(index)
    if not ok then
        showDenyMessage()
        return
    end
    denyCount = 0
    local ch = getChannel()
    if ch then
        if index then
            broadcastClear(index)
        else
            broadcastClearAll()
        end
    end
end

-- =============================================================================
-- Addon message handler
-- All mutation commands pass sender name to the DLL for permission check.
-- =============================================================================

local function parseMarkerFields(parts)
    local idx = tonumber(parts[2])
    local x = tonumber(parts[3])
    local y = tonumber(parts[4])
    local z = tonumber(parts[5])
    local areaId = tonumber(parts[6])
    if idx and x and y and z and areaId then
        return idx, x, y, z, areaId
    end
    return nil
end

local function onAddonMessage(prefix, message, channel, sender)
    if prefix ~= MSG_PREFIX then return end
    if sender == UnitName("player") then return end

    -- Parse colon-delimited message
    local parts = {}
    for part in string.gfind(message, "[^:]+") do
        table.insert(parts, part)
    end

    local cmd = parts[1]

    if cmd == "SR" then
        if CanSetWorldMarkers() then
            broadcastAllDefs()
        end
        return
    elseif cmd == "LSR" then
        broadcastAllDefs()
        return
    elseif cmd == "SF" then
        if not syncing then return end
        if syncSender == nil then
            syncSender = sender
        elseif syncSender ~= sender then
            return
        end
        local idx, x, y, z, areaId = parseMarkerFields(parts)
        if idx then
            WorldMarkers.SetMarkerDef(idx, x, y, z, areaId, sender)
        end
        return
    end

    if cmd == "P" then
        local idx, x, y, z, areaId = parseMarkerFields(parts)
        if idx then
            WorldMarkers.SetMarkerDef(idx, x, y, z, areaId, sender)
        end
    elseif cmd == "C" then
        local idx = tonumber(parts[2])
        if idx then
            WorldMarkers.ClearMarkerDef(idx, sender)
        end
    elseif cmd == "CA" then
        WorldMarkers.ClearMarkerDef(sender)
    end
end

-- =============================================================================
-- Event frame
-- =============================================================================

local function broadcastSyncRequest()
    local ch = getChannel()
    if not ch then return end
    startSyncing()
    local cmd = CanSetWorldMarkers() and "LSR" or "SR"
    SendAddonMessage(MSG_PREFIX, cmd, ch)
end

-- Delayed sync request: roster isn't populated at PLAYER_LOGIN/ENTERING_WORLD,
-- so we fire a one-shot 5s timer to request markers after joining the group.
local function scheduleSyncRequest()
    syncTimer.elapsed = 0
    syncTimer.delay = 5
    syncTimer.callback = function()
        broadcastSyncRequest()
    end
    syncTimer:Show()
end

-- =============================================================================
-- Roster change tracking - retriggerable debounce timer
-- Each roster event that increases group size adds 1s to the timer (starts at
-- 5s, caps at 10s). When the timer expires, one broadcast fires. This
-- guarantees delivery after the storm of events settles.
-- =============================================================================

local lastGroupSize = 0
local ROSTER_INITIAL_DELAY = 5
local ROSTER_EXTEND_SEC = 1
local ROSTER_MAX_DELAY = 10

local function getGroupSize()
    local raid = GetNumRaidMembers()
    if raid > 0 then return raid end
    return GetNumPartyMembers()
end

local rosterTimer = CreateFrame("Frame")
rosterTimer.remaining = 0
rosterTimer.pending = false
rosterTimer.extensions = 0
rosterTimer:Hide()
rosterTimer:SetScript("OnUpdate", function()
    rosterTimer.remaining = rosterTimer.remaining - arg1
    if rosterTimer.remaining <= 0 then
        rosterTimer:Hide()
        rosterTimer.pending = false
        rosterTimer.extensions = 0
        if CanSetWorldMarkers() then
            broadcastAllDefs()
        end
    end
end)

local MAX_EXTENSIONS = 5

local function onRosterChange()
    local newSize = getGroupSize()
    local oldSize = lastGroupSize
    lastGroupSize = newSize

    if newSize <= oldSize then return end

    if not rosterTimer.pending then
        rosterTimer.remaining = ROSTER_INITIAL_DELAY
        rosterTimer.pending = true
        rosterTimer.extensions = 0
        rosterTimer:Show()
    elseif rosterTimer.extensions < MAX_EXTENSIONS then
        rosterTimer.remaining = rosterTimer.remaining + ROSTER_EXTEND_SEC
        rosterTimer.extensions = rosterTimer.extensions + 1
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        lastGroupSize = getGroupSize()
        scheduleSyncRequest()
    elseif event == "CHAT_MSG_ADDON" then
        onAddonMessage(arg1, arg2, arg3, arg4)
    elseif event == "RAID_ROSTER_UPDATE" then
        onRosterChange()
    elseif event == "PARTY_MEMBERS_CHANGED" then
        if GetNumRaidMembers() == 0 then
            onRosterChange()
        end
    end
end)

-- =============================================================================
-- Slash commands
-- =============================================================================

SLASH_WORLDMARKER1 = "/worldmarker"
SLASH_WORLDMARKER2 = "/wm"
SlashCmdList["WORLDMARKER"] = function(msg)
    msg = string.lower(msg or "")

    local parts = {}
    for word in string.gfind(msg, "%S+") do
        table.insert(parts, word)
    end

    local index = tonumber(parts[1])
    if not index then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00World Markers|r commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /wm 1-5          - Place marker at cursor")
        DEFAULT_CHAT_FRAME:AddMessage("  /wm 1-5 <unit>   - Place marker at unit")
        DEFAULT_CHAT_FRAME:AddMessage("  /cwm [1-5]       - Clear one or all markers")
        return
    end

    if parts[2] then
        WorldMarker(index, parts[2])
    else
        WorldMarker(index)
    end
end

SLASH_CLEARWORLDMARKER1 = "/clearworldmarker"
SLASH_CLEARWORLDMARKER2 = "/cwm"
SlashCmdList["CLEARWORLDMARKER"] = function(msg)
    local index = tonumber(msg or "")
    if index then
        ClearWorldMarker(index)
    else
        ClearWorldMarker()
    end
end
