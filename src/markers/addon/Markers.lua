-- Markers addon (embedded in DLL, loaded from memory)
-- Part of WeirdUtils - only loaded when markers module is compiled

MARKERS_VERSION = 3

BINDING_HEADER_MARKERS = "Markers"

-- =============================================================================
-- Debug logging
-- =============================================================================

local function log(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff88aaff[WMark]|r " .. msg)
end

-- =============================================================================
-- Addon message protocol
-- Delimiter is ":" (pipe "|" is WoW's escape char for color codes)
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

local function canSetMarkers()
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local name, rank = GetRaidRosterInfo(i)
            if name == UnitName("player") then
                log("canSet: raid rank=" .. rank .. (rank >= 1 and " YES" or " NO"))
                return rank >= 1 -- 1=assist, 2=leader
            end
        end
        log("canSet: not in raid roster")
        return false
    elseif GetNumPartyMembers() > 0 then
        local result = IsPartyLeader()
        log("canSet: party leader=" .. tostring(result))
        return result
    end
    log("canSet: solo YES")
    return true -- solo: always allowed
end

local function senderHasPermission(sender)
    if GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local name, rank = GetRaidRosterInfo(i)
            if name == sender then
                log("perm: " .. sender .. " rank=" .. rank .. (rank >= 1 and " OK" or " NO"))
                return rank >= 1
            end
        end
        log("perm: " .. sender .. " not in roster")
        return false
    elseif GetNumPartyMembers() > 0 then
        -- Find the sender's unit ID to check if they're party leader
        for i = 1, GetNumPartyMembers() do
            if UnitName("party" .. i) == sender then
                local isLeader = UnitIsPartyLeader("party" .. i)
                log("perm: " .. sender .. "=party" .. i .. " ldr=" .. tostring(isLeader))
                return isLeader == 1
            end
        end
        log("perm: " .. sender .. " not in party")
        return false
    end
    log("perm: no group")
    return false
end

local function broadcastPlace(index, x, y, z, areaId)
    local ch = getChannel()
    if not ch then
        log("send: no channel")
        return
    end
    local msg = "P:" .. index .. ":" .. x .. ":" .. y .. ":" .. z .. ":" .. areaId
    log("SEND [" .. ch .. "] " .. msg)
    SendAddonMessage(MSG_PREFIX, msg, ch)
end

local function broadcastClear(index)
    local ch = getChannel()
    if not ch then return end
    local msg = "C:" .. index
    log("SEND [" .. ch .. "] " .. msg)
    SendAddonMessage(MSG_PREFIX, msg, ch)
end

local function broadcastClearAll()
    local ch = getChannel()
    if not ch then return end
    log("SEND [" .. ch .. "] CA")
    SendAddonMessage(MSG_PREFIX, "CA", ch)
end

local function broadcastAllDefs()
    local ch = getChannel()
    if not ch then return end
    local count = 0
    for i = 1, NUM_MARKERS do
        local x, y, z, areaId = GetMarkerDef(i)
        if x then
            local msg = "SF:" .. i .. ":" .. x .. ":" .. y .. ":" .. z .. ":" .. areaId
            log("SEND [" .. ch .. "] " .. msg)
            SendAddonMessage(MSG_PREFIX, msg, ch)
            count = count + 1
        end
    end
    log("syncAll: " .. count .. " on " .. ch)
end

-- =============================================================================
-- Wrap DLL functions to broadcast on group placement/clear
-- =============================================================================

local RawWorldMarker = WorldMarker
function WorldMarker(index, ...)
    log("WorldMarker(" .. tostring(index) .. ")")
    -- Cancel pending sync request — we're actively placing marks
    if syncTimer and syncTimer.pending then
        syncTimer:Hide()
        syncTimer.pending = false
        log("sync timer cancelled (local mark placed)")
    end
    RawWorldMarker(index, unpack(arg))
    local ch = getChannel()
    if ch then
        if canSetMarkers() then
            local x, y, z, areaId = GetMarkerDef(index)
            if x then
                log("def ok, broadcasting")
                broadcastPlace(index, x, y, z, areaId)
            else
                log("GetMarkerDef(" .. index .. ")=nil")
            end
        else
            log("no perm to broadcast")
        end
    else
        log("solo, no broadcast")
    end
end

local RawClearWorldMarker = ClearWorldMarker
function ClearWorldMarker(index)
    log("ClearWorldMarker(" .. tostring(index) .. ")")
    RawClearWorldMarker(index)
    if canSetMarkers() and getChannel() then
        if index then
            broadcastClear(index)
        else
            broadcastClearAll()
        end
    end
end

-- =============================================================================
-- Sync response deduplication
-- Only accept SF from the first responder after we send SR/LSR.
-- =============================================================================

local syncSender = nil -- name of the first SF responder

local function resetSyncSender()
    syncSender = nil
end

-- =============================================================================
-- Addon message handler
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

    log("RECV [" .. channel .. "] " .. tostring(sender) .. ": " .. tostring(message))

    if sender == UnitName("player") then
        log("  own msg, skip")
        return
    end

    -- Parse colon-delimited message
    local parts = {}
    for part in string.gfind(message, "[^:]+") do
        table.insert(parts, part)
    end

    local cmd = parts[1]
    log("  cmd=" .. tostring(cmd) .. " n=" .. table.getn(parts))

    -- SR/LSR/SF don't mutate state — handled before permission check.
    -- P, C, CA mutate state and require sender to have leader/assist permission.
    if cmd == "SR" then
        -- Normal sync request: only leader/assist responds
        log("  sync request from " .. tostring(sender))
        if canSetMarkers() then
            broadcastAllDefs()
        end
        return
    elseif cmd == "LSR" then
        -- Leader sync request: anyone with defs responds (leader relogged)
        log("  leader sync request from " .. tostring(sender))
        broadcastAllDefs()
        return
    elseif cmd == "SF" then
        -- Sync response: only accept from the first responder
        if syncSender == nil then
            syncSender = sender
            log("  sync responder locked: " .. sender)
        elseif syncSender ~= sender then
            log("  ignoring SF from " .. sender .. " (locked to " .. syncSender .. ")")
            return
        end
        local idx, x, y, z, areaId = parseMarkerFields(parts)
        if idx then
            log("  SetMarkerDef(" .. idx .. "," .. x .. "," .. y .. "," .. z .. "," .. areaId .. ")")
            SetMarkerDef(idx, x, y, z, areaId)
        else
            log("  PARSE FAIL")
        end
        return
    end

    -- Mutation commands require permission
    if not senderHasPermission(sender) then
        log("  no perm, skip")
        return
    end

    if cmd == "P" then
        local idx, x, y, z, areaId = parseMarkerFields(parts)
        if idx then
            log("  SetMarkerDef(" .. idx .. "," .. x .. "," .. y .. "," .. z .. "," .. areaId .. ")")
            SetMarkerDef(idx, x, y, z, areaId)
        else
            log("  PARSE FAIL")
        end
    elseif cmd == "C" then
        local idx = tonumber(parts[2])
        if idx then
            log("  ClearMarkerDef(" .. idx .. ")")
            ClearMarkerDef(idx)
        end
    elseif cmd == "CA" then
        log("  ClearAll")
        ClearMarkerDef()
    else
        log("  unknown: " .. tostring(cmd))
    end
end

-- =============================================================================
-- Event frame
-- =============================================================================

local function broadcastSyncRequest()
    local ch = getChannel()
    if not ch then
        log("syncReq: no channel (not in group)")
        return
    end
    -- Reset first-responder lock before requesting
    syncSender = nil
    local cmd = canSetMarkers() and "LSR" or "SR"
    log("SEND [" .. ch .. "] " .. cmd)
    SendAddonMessage(MSG_PREFIX, cmd, ch)
end

-- Delayed sync request: roster isn't populated at PLAYER_LOGIN/ENTERING_WORLD,
-- so we fire a one-shot 5s timer to request markers after joining the group.
syncTimer = CreateFrame("Frame")
syncTimer.elapsed = 0
syncTimer.pending = false
syncTimer:Hide()
syncTimer:SetScript("OnUpdate", function()
    syncTimer.elapsed = syncTimer.elapsed + arg1
    if syncTimer.elapsed >= 5 then
        syncTimer:Hide()
        syncTimer.pending = false
        log("login sync timer fired")
        broadcastSyncRequest()
    end
end)

local function scheduleSyncRequest()
    syncTimer.elapsed = 0
    syncTimer.pending = true
    syncTimer:Show()
    log("sync request scheduled (5s)")
end

-- =============================================================================
-- Roster change tracking — retriggerable debounce timer
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
        log("roster timer fired, broadcasting")
        if canSetMarkers() then
            broadcastAllDefs()
        end
    end
end)

local MAX_EXTENSIONS = 5

local function onRosterChange()
    local newSize = getGroupSize()
    local oldSize = lastGroupSize
    lastGroupSize = newSize

    if newSize <= oldSize then
        log("roster: " .. oldSize .. "->" .. newSize .. " (no increase)")
        return
    end

    log("roster: " .. oldSize .. "->" .. newSize .. " (grew)")

    if not rosterTimer.pending then
        rosterTimer.remaining = ROSTER_INITIAL_DELAY
        rosterTimer.pending = true
        rosterTimer.extensions = 0
        rosterTimer:Show()
        log("roster timer started (" .. ROSTER_INITIAL_DELAY .. "s)")
    elseif rosterTimer.extensions < MAX_EXTENSIONS then
        rosterTimer.remaining = rosterTimer.remaining + ROSTER_EXTEND_SEC
        rosterTimer.extensions = rosterTimer.extensions + 1
        log("roster timer +" .. ROSTER_EXTEND_SEC .. "s (ext " .. rosterTimer.extensions .. "/" .. MAX_EXTENSIONS .. ")")
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:RegisterEvent("RAID_ROSTER_UPDATE")

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Markers|r v" .. MARKERS_VERSION .. " loaded")
        lastGroupSize = getGroupSize()
        scheduleSyncRequest()
    elseif event == "CHAT_MSG_ADDON" then
        onAddonMessage(arg1, arg2, arg3, arg4)
    elseif event == "RAID_ROSTER_UPDATE" then
        onRosterChange()
    elseif event == "PARTY_MEMBERS_CHANGED" then
        -- Skip party events when in a raid (RAID_ROSTER_UPDATE handles it)
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

    -- Parse arguments
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
