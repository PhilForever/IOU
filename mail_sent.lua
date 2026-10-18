local _, IOU = ...
local Sent = {}
IOU.MailSent = Sent

-- Native setters and draft events expose the attachment state before SendMail.
-- Secure post-hooks observe those calls without replacing or issuing any mail
-- action. Only MAIL_SEND_SUCCESS can commit the immutable outgoing snapshot.
-- No subject/body text, target name, postage or recipient collection is used.
local initialized, enabled, frame, open = false, false, nil, false
local draft, candidate, inFlight, blocked, blockUntil
local status, submitted, ignored = "Waiting for sent mail.", 0, 0
local MAX_MONEY, MAX_ITEM, SEND_TIMEOUT, CLOSE_GRACE = 999999999000, 999999999, 60, 4
local EVENTS = {"MAIL_SHOW", "MAIL_CLOSED", "MAIL_FAILED", "MAIL_SEND_SUCCESS",
    "MAIL_SEND_INFO_UPDATE", "SEND_MAIL_MONEY_CHANGED", "SEND_MAIL_COD_CHANGED", "PLAYER_LOGOUT"}

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function integer(value, maximum)
    return plain(value) and type(value) == "number" and value >= 0
        and value <= maximum and value == math.floor(value)
end
local function clock()
    if type(GetTime) ~= "function" then return nil end
    local ok, value = pcall(GetTime)
    if ok and plain(value) and type(value) == "number" and value >= 0 and value < math.huge then return value end
end
local function readMoney(fn)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if ok and integer(value, MAX_MONEY) then return value end
end
local function contents()
    local amount, cod = readMoney(GetSendMailMoney), readMoney(GetSendMailCOD)
    if amount == nil or cod == nil or cod ~= 0 then return nil end
    if type(HasSendMailItem) ~= "function" or type(GetSendMailItem) ~= "function"
        or type(GetSendMailItemLink) ~= "function" then return nil end
    local result = {money=amount, items={}}
    for slot=1,12 do
        local known, present = pcall(HasSendMailItem, slot)
        local ok, name, itemID, _, quantity = pcall(GetSendMailItem, slot)
        local linked, link = pcall(GetSendMailItemLink, slot)
        if not known or not ok or not linked or not plain(present)
            or not plain(name) or not plain(itemID) or not plain(quantity) or not plain(link) then return nil end
        if present == nil or present == false then
            if name ~= nil or link ~= nil or (itemID ~= nil and itemID ~= 0)
                or (quantity ~= nil and quantity ~= 0) then return nil end
        elseif present == true or present == 1 then
            if type(name) ~= "string" or name == "" or #name > 200
                or name:find("[%z\001-\031\127|]") or not integer(itemID, 2147483647) or itemID < 1
                or not integer(quantity, MAX_ITEM) or quantity < 1
                or type(link) ~= "string" or #link > 512 or link:find("[%z\001-\031\127]")
                or not link:find("|Hitem:",1,true) then return nil end
            local codec=IOU.SharedCodec
            if not codec or type(codec.CanonicalItem)~="function" then return nil end
            local key,linkedID=codec.CanonicalItem(link)
            if not key or linkedID~=itemID then return nil end
            result.items[#result.items+1] = {itemID=itemID, link=link, name=name, quantity=quantity}
        else
            return nil
        end
    end
    return result
end
local function same(a, b)
    if not a or not b or a.money ~= b.money or #a.items ~= #b.items then return false end
    for index, row in ipairs(a.items) do
        local other = b.items[index]
        if row.itemID ~= other.itemID or row.link ~= other.link or row.name ~= other.name
            or row.quantity ~= other.quantity then return false end
    end
    return true
end
local function expire(now)
    if inFlight and candidate and now >= candidate.expires then
        candidate, inFlight, draft = nil, nil, nil
        blocked, blockUntil = true, now+CLOSE_GRACE
        status = "Mail completion was not confirmed; reopen the mailbox."
    end
end
local function refreshDraft()
    if enabled and open and not inFlight and not blocked then draft = contents() end
end
local function nameKey(value)
    local summary = IOU.PlayerSummary
    if type(summary) ~= "table" or type(summary.NameKey) ~= "function" then return nil end
    local ok, key = pcall(summary.NameKey, value)
    if ok and plain(key) and type(key) == "string" then return key end
end
local function onSend(recipient)
    if not enabled or not open then return end
    local now = clock()
    if not now then draft, candidate, inFlight = nil, nil, nil; blocked=true; return end
    expire(now)
    if blocked then return end
    if inFlight then
        candidate, draft = {expires=now+SEND_TIMEOUT}, nil
        blocked, blockUntil = true, now+CLOSE_GRACE
        status = "Overlapping mail sends were skipped."
        return
    end
    -- Reserve the completion channel even for unreadable/COD attempts, so a
    -- later success cannot be mistaken for a replacement draft.
    inFlight = true
    local before, current = draft, contents()
    draft = nil
    if not plain(recipient) or type(recipient) ~= "string" or #recipient > 96
        or not nameKey(recipient) or not same(before, current)
        or (current.money == 0 and #current.items == 0) then
        candidate = {expires=now+SEND_TIMEOUT}
        status = "Mail contents were unavailable or excluded."
        return
    end
    local service = IOU.TradeService
    local ok, id
    if type(service) == "table" and type(service.NewSessionID) == "function" then
        ok, id = pcall(service.NewSessionID, "mail_sent")
    end
    if not ok or not plain(id) or type(id) ~= "string" or id == "" or #id > 96
        or id:find("[%z\001-\031\127|]") then
        candidate = {expires=now+SEND_TIMEOUT}
        status = "Sent mail could not be reserved."
        return
    end
    candidate = {expires=now+SEND_TIMEOUT, value={id=id, medium="mail_sent", peer=recipient,
        outgoing=before, incoming={money=0, items={}}}}
    status = "Waiting for mail send confirmation."
end
local function onEvent(_, event)
    if not enabled or not plain(event) or type(event) ~= "string" then return end
    local now = clock()
    if not now then draft, candidate, inFlight = nil, nil, nil; blocked=true; return end
    expire(now)
    if event == "MAIL_SHOW" then
        local reopening = not open
        open = true
        if reopening and not inFlight and (not blockUntil or now >= blockUntil) then blocked=nil end
        refreshDraft()
    elseif event == "MAIL_CLOSED" then
        open, draft = false, nil
        if candidate then candidate.expires = math.min(candidate.expires, now+CLOSE_GRACE) end
        if blocked then blockUntil=now+CLOSE_GRACE end
    elseif event == "MAIL_SEND_SUCCESS" then
        local value = not blocked and candidate and candidate.value
        candidate, inFlight, draft = nil, nil, nil
        if value then
            local service = IOU.TradeService
            local ok, result
            if type(service) == "table" and type(service.Record) == "function" then ok, result=pcall(service.Record,value) end
            if ok and result then
                submitted=math.min(submitted+1,9999);status="Sent mail recorded."
            else
                ignored=math.min(ignored+1,9999);status="Sent mail could not be recorded."
            end
        end
    elseif event == "MAIL_FAILED" then
        candidate, inFlight, draft = nil, nil, nil
        status = "Mail failed; no repayment recorded."
    elseif event == "PLAYER_LOGOUT" then
        open, draft, candidate, inFlight, blocked = false, nil, nil, nil, true
        status = "Mail observation stopped."
    else
        refreshDraft()
    end
end

local function protect(callback)
    return function(...)
        local ok = pcall(callback, ...)
        if not ok then
            draft, candidate, inFlight, blocked = nil, nil, nil, true
            local now = clock()
            blockUntil = now and now+CLOSE_GRACE or nil
            status = "Mail observation was interrupted; no repayment recorded."
        end
    end
end

function Sent.Initialize()
    if initialized then return true end
    if type(CreateFrame) ~= "function" or type(hooksecurefunc) ~= "function"
        or type(SendMail) ~= "function" or type(SetSendMailMoney) ~= "function"
        or type(SetSendMailCOD) ~= "function" then return nil, "Sent mail observation is unavailable." end
    local ok, value = pcall(CreateFrame, "Frame")
    if not ok or not value then return nil, "Sent mail events are unavailable." end
    frame = value
    ok = pcall(function()
        for _, event in ipairs(EVENTS) do frame:RegisterEvent(event) end
        frame:SetScript("OnEvent", protect(onEvent))
        hooksecurefunc("SetSendMailMoney", protect(refreshDraft))
        hooksecurefunc("SetSendMailCOD", protect(refreshDraft))
        hooksecurefunc("SendMail", protect(onSend))
    end)
    if not ok then
        if type(frame.UnregisterAllEvents) == "function" then pcall(frame.UnregisterAllEvents,frame) end
        status = "Sent mail observation is unavailable."
        return nil, status
    end
    initialized, enabled = true, true
    return true
end
function Sent.Report()
    local now = clock()
    if now then expire(now) end
    return "IOU sent mail observer\nStatus: "..status
        .."\nSent mail submitted: "..submitted.."; recorder failures: "..ignored
        .."\nCompletion rule: SendMail recipient, unchanged pre-send draft, MAIL_SEND_SUCCESS."
        .."\nRead-only capture; postage, COD and returned/system mail excluded."
end
