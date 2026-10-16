local ADDON, IOU = ...
local T = {VERSION = "1", PREFIX = "IOU_LINKv1", MAX_BYTES = 240}
IOU.Transport = T

-- This is an opt-in link experiment, not an agreement protocol. Nothing here
-- reads or writes IOUDB, sends ordinary whispers, or runs automatically at login.
local frame, initialized, initError, registration
local listening, peer, peerKey = false, nil, nil
local active, lastTest, lastAttempt, serial = nil, nil, nil, 0
local echoQueue, observations = {}, {}
local responseWindow, responseSeen, responseUnique = nil, {}, 0
local responseReport = {probes = {}}
local rateLimitNote
local lastSend = -1000000
local PACE, TIMEOUT, WINDOW, UNIQUE_LIMIT = 1, 20, 60, 12
local sendNames = {[0]="Success", [1]="InvalidPrefix", [2]="InvalidMessage",
    [3]="AddonMessageThrottle", [4]="InvalidChatType", [5]="NotInGroup",
    [6]="TargetRequired", [7]="InvalidChannel", [8]="ChannelThrottle",
    [9]="GeneralError", [10]="NotInGuild", [11]="AddOnMessageLockdown", [12]="TargetOffline"}
local registerNames = {[0]="Success", [1]="DuplicatePrefix", [2]="InvalidPrefix", [3]="MaxPrefixes"}
local labels = {"ASCII", "Norwegian UTF-8", "239-byte UTF-8", "240-byte UTF-8"}
-- Literal UTF-8 bytes are deliberate. Padding is ASCII, so neither boundary
-- probe can truncate a multibyte codepoint.
local unicode = "Bj\195\184rn bl\195\165b\195\166r"

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end

local function clock()
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        if ok and plain(value) and type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
    end
    if type(time) == "function" then
        local ok, value = pcall(time)
        if ok and plain(value) and type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
    end
    return 0
end

local function changed()
    if type(IOU.OnTransportChanged) == "function" then pcall(IOU.OnTransportChanged) end
end

function T.CanonicalName(value)
    if not plain(value) or type(value) ~= "string" or #value > 96 then
        return nil, "Enter the other player's full name (at most 96 bytes)."
    end
    if value:find("[%z\001-\031\127|]") then
        return nil, "Enter a plain player name, without chat links or control characters."
    end
    value = value:gsub(" +", " "):match("^ *(.-) *$")
    if value == "" then return nil, "Enter the other player's full name." end
    return value
end

local function key(value)
    local name = T.CanonicalName(value)
    -- Do not infer realm suffixes or turn hyphens into spaces. The experiment
    -- must reveal the client's identity format rather than silently guessing it.
    return name and name:lower()
end

function T.GetUnitName(unit)
    if unit ~= "player" and unit ~= "target" then return nil, "Unsupported unit." end
    if unit == "target" and type(UnitIsPlayer) == "function" then
        local ok, isPlayer = pcall(UnitIsPlayer, unit)
        if not ok or not plain(isPlayer) or isPlayer ~= true then return nil, "Target a player first." end
    end
    if type(NameUtil) == "table" and type(NameUtil.GetUnmodifiedUnitFullName) == "function" then
        local ok, value = pcall(NameUtil.GetUnmodifiedUnitFullName, unit)
        if ok and plain(value) then
            local name = T.CanonicalName(value)
            if name then return name end
        end
    end
    if type(UnitNameUnmodified) == "function" then
        local ok, first, surname = pcall(UnitNameUnmodified, unit)
        if ok and plain(first) and plain(surname) and type(first) == "string" and first ~= "" then
            local separator = Constants and Constants.CharacterNameSeparatorConsts
                and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR
            if surname == nil or surname == "" then return T.CanonicalName(first) end
            if type(surname) == "string" and plain(separator) and type(separator) == "string" then
                return T.CanonicalName(first .. separator .. surname)
            end
        end
    end
    -- UnitFullName's second result is not assumed to be a surname or realm in
    -- this experiment. A guessed separator would hide the very issue we test.
    return nil, "Player name is unavailable."
end

function T.GetLocalName() return T.GetUnitName("player") end

local function validID(id)
    return plain(id) and type(id) == "string" and #id >= 1 and #id <= 32
        and id:match("^[A-Za-z0-9_-]+$") ~= nil
end

function T.BuildProbe(id, index)
    if not validID(id) or not plain(index) or type(index) ~= "number" or index ~= math.floor(index) or index < 1 or index > 4 then
        return nil, "Invalid probe identifier or index."
    end
    local header = "P|1|" .. id .. "|" .. index .. "|"
    local body
    if index == 1 then body = "IOU link test"
    elseif index == 2 then body = unicode
    else
        body = unicode .. " "
        local padding = (index == 3 and 239 or T.MAX_BYTES) - #header - #body
        if padding < 0 then return nil, "Probe header is too long." end
        body = body .. string.rep("x", padding)
    end
    return header .. body
end

function T.Parse(wire)
    if not plain(wire) or type(wire) ~= "string" or #wire > T.MAX_BYTES then
        return nil, "Invalid message size."
    end
    local kind, version, id, rawIndex, body = wire:match("^([PE])|([^|]+)|([^|]+)|([1-4])|(.*)$")
    if not kind or version ~= T.VERSION or not validID(id) then return nil, "Unknown probe format." end
    local index = tonumber(rawIndex)
    local expected = T.BuildProbe(id, index)
    if not expected or wire:sub(2) ~= expected:sub(2) then return nil, "Probe payload is not recognized." end
    return {kind=kind, version=version, id=id, index=index, body=body, wire=wire}
end

local function restrictionSnapshot()
    local snapshot = {}
    for _, name in ipairs({"AreOutgoingAddonChatMessagesRestricted", "InChatMessagingLockdown"}) do
        local value = {state="missing", text="unavailable (API absent)"}
        if type(C_ChatInfo) == "table" and type(C_ChatInfo[name]) == "function" then
            local ok, blocked = pcall(C_ChatInfo[name])
            if not ok then value={state="error",text="unavailable (API error)"}
            elseif not plain(blocked) then value={state="secret",text="unavailable (secret result)"}
            elseif type(blocked) ~= "boolean" then value={state="invalid",text="unavailable (invalid result)"}
            else value={state="known",value=blocked,text=blocked and "true" or "false"} end
        end
        snapshot[name]=value
    end
    return snapshot
end

local function restriction(snapshot)
    if type(C_ChatInfo) ~= "table" then return "Logged addon chat is unavailable in this client." end
    -- The broad realm flag is also true on Forever realms where ordinary
    -- addon comms work. It is diagnostic context, not permission for this API.
    -- The logged native send remains responsible for its actual restrictions.
    local lockdown=(snapshot or restrictionSnapshot()).InChatMessagingLockdown
    if lockdown.state == "missing" then return end
    if lockdown.state ~= "known" then return "Could not check InChatMessagingLockdown." end
    if lockdown.value then return "Client chat restriction: InChatMessagingLockdown." end
end

local function beginAttempt(operation, target)
    lastAttempt={operation=operation,target=target,restrictions=restrictionSnapshot()}
    return lastAttempt
end
local function rejectAttempt(attempt, problem)
    attempt.error=problem
    changed()
    return nil,problem
end

local function resultText(value, names)
    if not plain(value) then return "unavailable result" end
    if value == nil then return "nil (submission result unavailable)" end
    if type(value) == "number" then return (names[value] or "Unknown") .. " (" .. tostring(value) .. ")" end
    return "unsupported result type: " .. type(value)
end

local function send(wire, target)
    local problem = restriction()
    if problem then return nil, problem, false end
    local ok, value = pcall(C_ChatInfo.SendAddonMessageLogged, T.PREFIX, wire, "WHISPER", target)
    if not ok then return nil, "SendAddonMessageLogged raised an error", false end
    local text = resultText(value, sendNames)
    -- Success describes submission only; a nil result is unknown. Neither is
    -- evidence of delivery until an exact echo arrives from the configured peer.
    if plain(value) and value == nil then return value, text, nil end
    return value, text, plain(value) and value == 0
end

local function driver()
    if frame then
        frame:SetScript("OnUpdate", (active or #echoQueue > 0) and function() T.Tick() end or nil)
    end
end

local function matches(test)
    local count = 0
    for i=1,4 do if test.probes[i].echoed then count = count + 1 end end
    return count
end

local function finish(state)
    if active then active.state, active.finished = state, clock(); active = nil end
    driver()
    changed()
end

local function short(value)
    if not plain(value) or type(value) ~= "string" then return "(unavailable)" end
    return value:gsub("[%z\001-\031\127|]", "?"):sub(1,120)
end

local function receive(_, event, prefix, wire, channel, sender, target)
    if event ~= "CHAT_MSG_ADDON_LOGGED" or not listening or not plain(prefix) or prefix ~= T.PREFIX
        or not plain(channel) or channel ~= "WHISPER" then return end
    local parsed = T.Parse(wire)
    if not parsed then return end
    local senderKey = key(sender)
    if not senderKey or senderKey ~= peerKey then
        if #observations < 4 then
            observations[#observations+1] = "Ignored sender '" .. short(sender) .. "', event target '"
                .. short(target) .. "': did not exactly match the configured peer."
            changed()
        end
        return
    end
    if parsed.kind == "E" then
        if not active or parsed.id ~= active.id then return end
        local probe = active.probes[parsed.index]
        if not probe.sent or probe.echoed or wire:sub(2) ~= probe.wire:sub(2) then return end
        probe.echoed, probe.sender, probe.eventTarget = true, short(sender), short(target)
        probe.elapsed = math.max(0, clock() - probe.sent)
        if matches(active) == 4 then finish("complete") else changed() end
        return
    end
    local now = clock()
    if not responseWindow or now - responseWindow >= WINDOW then
        responseWindow, responseSeen, responseUnique = now, {}, 0
        rateLimitNote = nil
    end
    local seenKey = parsed.id .. ":" .. parsed.index
    local seen = responseSeen[seenKey]
    if not seen then
        if responseUnique >= UNIQUE_LIMIT then
            if not rateLimitNote then
                rateLimitNote = "Responder rate limit reached (12 unique probes/60 seconds); wait a minute before rerunning."
                changed()
            end
            return
        end
        seen = {count=0}
        responseSeen[seenKey], responseUnique = seen, responseUnique + 1
    end
    if seen.count >= 2 or #echoQueue >= 8 then return end
    seen.count = seen.count + 1
    if responseReport.id ~= parsed.id then responseReport = {probes={}} end
    responseReport.peer, responseReport.id = short(sender), parsed.id
    local record = {bytes=#wire, sender=short(sender), eventTarget=short(target), resultText="Queued"}
    responseReport.probes[parsed.index] = record
    echoQueue[#echoQueue+1] = {wire="E" .. wire:sub(2), target=peer, record=record}
    driver()
    changed()
end

function T.Initialize()
    if initialized then return true end
    if type(C_ChatInfo) ~= "table" or type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function"
        or type(C_ChatInfo.SendAddonMessageLogged) ~= "function" then
        initError = "This client does not provide logged addon whispers."
        return nil, initError
    end
    if type(CreateFrame) ~= "function" then initError = "The client event system is unavailable."; return nil, initError end
    local ok, value = pcall(C_ChatInfo.RegisterAddonMessagePrefix, T.PREFIX)
    registration = ok and resultText(value, registerNames) or "registration raised an error"
    if not ok or not plain(value) or type(value) ~= "number" or (value ~= 0 and value ~= 1) then
        initError = "Could not register the test prefix: " .. registration
        return nil, initError
    end
    local created, newFrame = pcall(CreateFrame, "Frame")
    if not created or not newFrame then initError = "Could not create the test event frame."; return nil, initError end
    frame = newFrame
    local bound = pcall(function()
        frame:RegisterEvent("CHAT_MSG_ADDON_LOGGED")
        frame:SetScript("OnEvent", receive)
    end)
    if not bound then initError = "This client does not support the logged addon event."; return nil, initError end
    initialized, initError = true, nil
    return true
end

function T.EnableListening(enabled, target)
    if enabled ~= true then
        lastAttempt=nil
        listening, peer, peerKey, echoQueue = false, nil, nil, {}
        if active then finish("cancelled") else driver(); changed() end
        return true
    end
    local name, problem = T.CanonicalName(target)
    local attempt=beginAttempt("Listen",name)
    if not name then return rejectAttempt(attempt,problem) end
    local own = T.GetLocalName()
    if not own then return rejectAttempt(attempt,"Your full player name is unavailable. Try again after login.") end
    if own and key(own) == key(name) then return rejectAttempt(attempt,"Choose another player; this test needs two clients.") end
    local ok, err = T.Initialize()
    if not ok then return rejectAttempt(attempt,err) end
    problem = restriction(attempt.restrictions)
    if problem then return rejectAttempt(attempt,problem) end
    if active and key(name) ~= peerKey then finish("cancelled") end
    if key(name) ~= peerKey then
        echoQueue, observations = {}, {}
        responseWindow, responseSeen, responseUnique, rateLimitNote = nil, {}, 0, nil
        responseReport = {probes={}}
    end
    listening, peer, peerKey = true, name, key(name)
    driver()
    changed()
    return true
end

function T.Stop() return T.EnableListening(false) end
function T.IsListening() return listening end
function T.IsRunning() return active ~= nil end

function T.Start(target)
    local name, problem = T.CanonicalName(target)
    local attempt=beginAttempt("Run test",name)
    if not name then return rejectAttempt(attempt,problem) end
    local own = T.GetLocalName()
    if not own then return rejectAttempt(attempt,"Your full player name is unavailable. Try again after login.") end
    if own and key(own) == key(name) then return rejectAttempt(attempt,"Choose another player; this test needs two clients.") end
    if not listening or key(name) ~= peerKey then return rejectAttempt(attempt,"Enable the test for this exact player first.") end
    if active then return rejectAttempt(attempt,"A link test is already running.") end
    problem = restriction(attempt.restrictions)
    if problem then return rejectAttempt(attempt,problem) end
    serial = serial + 1
    local epoch = clock()
    if type(time) == "function" then
        local ok, stamp = pcall(time)
        if ok and plain(stamp) and type(stamp) == "number" and stamp == stamp and math.abs(stamp) < math.huge then epoch = stamp end
    end
    -- A correlation token, not an authentication token or security guarantee.
    local id = string.format("%x-%x-%x", math.floor(epoch % 2147483647), serial % 65536, math.random(0, 16777215))
    local test = {id=id, target=name, started=clock(), state="running", nextIndex=1, probes={}}
    for i=1,4 do
        local wire = T.BuildProbe(id, i)
        test.probes[i] = {wire=wire, bytes=#wire, echoed=false, resultText="Not sent"}
    end
    active, lastTest = test, test
    driver()
    changed()
    T.Tick()
    return test
end

function T.Tick()
    local now = clock()
    if active and now - active.started >= TIMEOUT then finish("timeout") end
    if now - lastSend < PACE then return end
    if #echoQueue > 0 then
        local item = table.remove(echoQueue, 1)
        if listening then
            lastSend = now
            local value, text = send(item.wire, item.target)
            item.record.result, item.record.resultText = value, text
            changed()
        end
    elseif active and active.nextIndex <= 4 then
        local index = active.nextIndex
        local probe = active.probes[index]
        active.nextIndex, lastSend, probe.sent = index + 1, now, now
        local value, text, submitted = send(probe.wire, active.target)
        probe.result, probe.resultText, probe.submitted = value, text, submitted
        changed()
    end
    driver()
end

function T.GetStatus()
    if initError then return initError end
    if active then return "Testing " .. active.target .. ": " .. matches(active) .. "/4 exact round trips." end
    if lastAttempt and lastAttempt.error then return lastAttempt.operation .. " blocked: " .. lastAttempt.error end
    if listening and rateLimitNote and responseWindow and clock() - responseWindow < WINDOW then return rateLimitNote end
    if lastTest and (not listening or key(lastTest.target) == peerKey) then
        local count = matches(lastTest)
        if lastTest.state == "complete" then return "Test complete: 4/4 exact round trips." .. (not listening and " Listening is off." or "") end
        if lastTest.state == "timeout" then return "Test ended: " .. count .. "/4 exact round trips; missing replies timed out."
            .. (not listening and " Listening is off." or "") end
        if lastTest.state == "cancelled" and not listening then return "Test stopped; listening is off." end
    end
    return listening and ("Ready for " .. peer .. ". Listening is on for this session.") or "Listening is off."
end

function T.GetReport()
    local name = T.GetLocalName() or "(unavailable)"
    local lines = {"IOU LINK TEST / diagnostic protocol " .. T.VERSION,
        "Addon: " .. tostring(IOU.VERSION or "development"), "Local name: " .. short(name),
        "Configured peer: " .. short(peer or (lastTest and lastTest.target)),
        "Channel: logged addon WHISPER / prefix: " .. T.PREFIX,
        "Prefix registration: " .. (registration or "not attempted"),
        "Listening: " .. (listening and "ON (until stopped or reload)" or "OFF"),
        "Identity rule: whitespace normalized, ASCII case ignored; hyphens and surnames preserved.",
        "Conservative wire cap: 240 bytes. The actual client maximum is not established by this test.",
        "Unicode sample: " .. unicode,
        "Send API Success means submitted, not delivered; only an exact peer echo proves a round trip."}
    local apiAvailable = type(C_ChatInfo) == "table"
        and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function"
        and type(C_ChatInfo.SendAddonMessageLogged) == "function"
    lines[#lines+1] = "Logged addon whisper API: " .. (apiAvailable and "available locally (delivery untested)" or "UNAVAILABLE in this client")
    local function addRestrictions(label,snapshot)
        lines[#lines+1]=label .. " AreOutgoingAddonChatMessagesRestricted: " .. snapshot.AreOutgoingAddonChatMessagesRestricted.text .. " (advisory only for this logged test)"
        lines[#lines+1]=label .. " InChatMessagingLockdown: " .. snapshot.InChatMessagingLockdown.text
    end
    addRestrictions("Current",restrictionSnapshot())
    if lastAttempt then
        lines[#lines+1]="Last attempt: " .. lastAttempt.operation .. " / target " .. short(lastAttempt.target)
            .. " / " .. (lastAttempt.error and "BLOCKED: " .. lastAttempt.error or "enabled")
        addRestrictions("At last attempt",lastAttempt.restrictions)
    end
    -- Local preflight needs neither a registered prefix nor another player.
    -- These deterministic checks never call any chat API.
    for i=1,4 do
        local wire = T.BuildProbe("local-preflight", i)
        local parsed = wire and T.Parse(wire)
        local echo = wire and T.Parse("E" .. wire:sub(2))
        local valid = parsed and parsed.kind == "P" and parsed.index == i
            and echo and echo.kind == "E" and echo.body == parsed.body
            and (i ~= 2 or parsed.body == unicode)
            and (i ~= 3 or #wire == 239) and (i ~= 4 or #wire == 240)
        lines[#lines+1] = "Local preflight " .. i .. " (" .. labels[i] .. "): "
            .. (valid and "PASS" or "FAIL") .. " / " .. tostring(wire and #wire or 0) .. " wire bytes; no traffic sent."
    end
    if type(GetBuildInfo) == "function" then
        local ok, version, build, _, interface = pcall(GetBuildInfo)
        if ok then lines[#lines+1] = "Client: " .. short(version) .. " / build " .. short(build)
            .. " / interface " .. (plain(interface) and type(interface)=="number" and tostring(interface) or "unavailable") end
    end
    lines[#lines+1] = "Status: " .. T.GetStatus()
    if lastTest then
        lines[#lines+1] = "Outgoing session: " .. lastTest.id .. " / " .. lastTest.state .. " / target " .. lastTest.target
        for i=1,4 do
            local p = lastTest.probes[i]
            lines[#lines+1] = string.format("%d. %s: %d bytes / API %s / %s", i, labels[i], p.bytes,
                p.resultText, p.echoed and "EXACT ECHO" or (p.sent and "no exact echo" or "not sent"))
            if p.echoed then lines[#lines+1] = "   Raw sender: '" .. p.sender .. "'; event target: '" .. p.eventTarget .. "'." end
        end
    end
    if responseReport.id then
        lines[#lines+1] = "Incoming peer: " .. responseReport.peer .. " / session " .. responseReport.id
        for i=1,4 do
            local p = responseReport.probes[i]
            if p then lines[#lines+1] = string.format("Received %d: %d exact bytes; echo API %s; raw sender '%s'; event target '%s'.",
                i, p.bytes, p.resultText, p.sender, p.eventTarget) end
        end
    end
    for _, observation in ipairs(observations) do lines[#lines+1] = observation end
    lines[#lines+1] = "No ledger data is included. Fixed diagnostic text only. No automatic retries."
    lines[#lines+1] = "Responder safety limit: 12 unique probes per 60 seconds, at most two echoes per probe; one-second send pacing."
    lines[#lines+1] = "Responder window: " .. responseUnique .. "/12 unique probes."
    if rateLimitNote then lines[#lines+1] = rateLimitNote end
    return table.concat(lines, "\n"):sub(1,8000)
end
