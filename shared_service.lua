local _, IOU = ...
local V = {}
IOU.SharedService = V
local S, C, P = IOU.Shared, IOU.SharedCodec, IOU.SharedPayments
local entry, character, localName, failure, notice, peer, notifying, needsPause, handlingWireChange
local background=false
local MAX_COUNTER, MAX_TIME = 2147483647, 4102444800
-- Unaccepted background invitations never consume permanent consent/history
-- capacity. Only an explicit Accept promotes one into the saved store.
local inbox, inboxSerial = {},0
local INBOX_MAX, INBOX_PEER_MAX, INBOX_TTL = 16,12,300

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function tablePlain(value) return type(value) == "table" and getmetatable(value) == nil end
local function integer(value, maximum)
    return plain(value) and type(value) == "number" and value == math.floor(value) and value >= 0 and value <= maximum
end
local function exactKeys(value, required)
    if not tablePlain(value) then return nil end
    local count = 0
    for key in pairs(value) do if not required[key] then return nil end; count = count + 1 end
    local expected = 0
    for key in pairs(required) do expected = expected + 1; if rawget(value, key) == nil then return nil end end
    return count == expected
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end
local function now()
    if type(time) ~= "function" then return nil, "The client clock is unavailable." end
    local ok, value = pcall(time)
    if not ok or not integer(value, MAX_TIME) then return nil, "The client clock is unavailable." end
    return value
end
local function inboxClock()
    if type(GetTime)~="function" then return nil end
    local ok,value=pcall(GetTime)
    if ok and plain(value) and type(value)=="number" and value==value and value>=0 and value<math.huge then return value end
end
local function expireInbox()
    local stamp=inboxClock()
    if not stamp then inbox={} return end
    for id,row in pairs(inbox) do if stamp>=row.expires then inbox[id]=nil end end
end
local function changed()
    if notifying then return end
    notifying = true
    if type(IOU.OnSharedChanged) == "function" then pcall(IOU.OnSharedChanged) end
    notifying = false
end
local function wire() return IOU.SharedWire end
local function wireCall(name, ...)
    local w = wire()
    if type(w) ~= "table" or type(w[name]) ~= "function" then return nil, "Shared transport is unavailable." end
    local ok, result, err = pcall(w[name], ...)
    if not ok then return nil, "Shared transport operation failed." end
    return result, err
end
local function stopWire()
    if peer or background then needsPause = true end
    -- Clear the session identity before Disable invokes its refresh callback.
    peer,background = nil,false
    inbox={}
    local w = wire()
    if type(w) == "table" and type(w.Disable) == "function" then pcall(w.Disable) end
end
local function reject(message)
    notice = tostring(message or "Shared agreement operation failed.")
    changed()
    return nil, notice
end
local function fail(message)
    failure = tostring(message)
    stopWire()
    return reject(failure)
end
local function fullName()
    local t = IOU.Transport
    if type(t) ~= "table" or type(t.GetLocalName) ~= "function" then return nil end
    local ok, name = pcall(t.GetLocalName)
    if ok and plain(name) and type(name) == "string" then return name end
end
local function peerName(value)
    local t = IOU.Transport
    if type(t) ~= "table" or type(t.CanonicalName) ~= "function" then return nil, "Full player names are unavailable." end
    local result, err = t.CanonicalName(value)
    if not result or result ~= value then return nil, err or "Use the exact full name, with single spaces." end
    local terms = {protocol=1, kind="GOLD_OBLIGATION", proposer=localName, recipient=result,
        debtor=result, creditor=localName, amountCopper=1, dueUTC=0, note=""}
    local ok, problem = C.ValidateTerms(terms)
    if not ok then return nil, problem end
    return result
end
local function reasonValid(reason, offer)
    if type(reason) ~= "string" or #reason > 256 or not reason:find("%S") then return nil end
    local terms = C.ParseTerms(offer.terms)
    if not terms then return nil end
    terms.note = reason
    return C.ValidateTerms(terms)
end
local function validateEntry(value, owner)
    if not exactKeys(value, {version=true, store=true, closedPaused=true, nonce=true, counter=true})
        or value.version ~= 1 or type(value.nonce) ~= "string" or #value.nonce < 1 or #value.nonce > 40
        or not value.nonce:match("^[A-Za-z0-9_-]+$") or not integer(value.counter, MAX_COUNTER)
        or not tablePlain(value.closedPaused) then return nil, "Invalid shared storage wrapper." end
    if type(P) ~= "table" or type(P.Views) ~= "function" then return nil, "The shared payment domain is unavailable." end
    local views, err = P.Views(value.store,value.closedPaused)
    if not views then return nil, err end
    if value.store.localName ~= owner then return nil, "Shared records belong to another character; they were left untouched." end
    for _, offer in pairs(value.store.offers) do
        if not integer(offer.createdAt, MAX_TIME) or not integer(offer.updatedAt, MAX_TIME) then return nil, "Shared offer timestamp is outside the client date range." end
        for _, event in ipairs(offer.history) do
            if not integer(event.at, MAX_TIME) then return nil, "Shared history timestamp is outside the client date range." end
        end
    end
    local count = 0
    for id, tombstone in pairs(value.closedPaused) do
        count = count + 1
        local offer = value.store.offers[id]
        if not offer or offer.state ~= "PAUSED" or not exactKeys(tombstone, {at=true, reason=true})
            or not integer(tombstone.at, MAX_TIME) or tombstone.at < offer.updatedAt
            or not reasonValid(tombstone.reason, offer) then return nil, "Invalid closed-offer review record." end
    end
    if count > S.MAX_OFFERS then return nil, "Too many closed-offer records." end
    return true, views
end
local function namespace()
    if not tablePlain(IOUDB) then return nil, "Saved data is unavailable." end
    local map = rawget(IOUDB, "sharedByCharacter")
    if map ~= nil and not tablePlain(map) then return nil, "Shared character storage is invalid; it was left untouched." end
    return map or false
end
local function persist(candidate, validated)
    -- Only private recovery candidates already validated in this same operation
    -- use the fast path. Live/external records always pass validateEntry.
    if not validated then
        local ok, err = validateEntry(candidate, localName)
        if not ok then return nil, err end
    end
    local map, problem = namespace()
    if map == nil then return nil, problem end
    if entry and (not map or rawget(map, character) ~= entry) then
        return nil, "Shared saved data changed outside this session; reload before continuing."
    end
    if not map then map = {}; IOUDB.sharedByCharacter = map end
    map[character], entry = candidate, candidate
    return true
end
local function pauseLoaded()
    local ok, err = validateEntry(entry, localName)
    if not ok then return nil, err end
    local stamp
    stamp, err = now()
    if not stamp then return nil, err end
    local updated
    updated, err = S.Pause(entry.store, stamp)
    if not updated then return nil, err end
    local candidate = clone(entry)
    candidate.store = updated
    ok, err = persist(candidate)
    if not ok then return nil, err end
    needsPause = false
    return true
end
local function freshNonce(stamp, ownerKey)
    local hash = 5381
    for index=1,#ownerKey do hash = (hash * 33 + ownerKey:byte(index)) % 16777213 end
    return string.format("n%x-%x-%x-%x", stamp, hash, math.random(0,16777215), math.random(0,16777215))
end

function V.Initialize()
    if failure then return nil, failure end
    if entry then return true end
    if type(IOU.Initialize) ~= "function" or type(IOU.Character) ~= "function" then return reject("The personal ledger core is unavailable.") end
    local ok, err = IOU.Initialize()
    if not ok then return reject(err) end
    local name = fullName()
    if not name then return reject("Your full character name is unavailable. Try again after login.") end
    local key = IOU.Character()
    if type(key) ~= "string" or key == "" or #key > 256 then return reject("The existing character storage key is unavailable.") end
    local map, problem = namespace()
    if map == nil then return fail(problem) end
    local candidate
    if map then candidate = rawget(map, key) end
    if candidate ~= nil then
        ok, err = validateEntry(candidate, name)
        if not ok then return fail("Shared saved data was left untouched: " .. tostring(err)) end
    else
        local store
        store, err = S.New(name)
        if not store then return reject(err) end
        local stamp
        stamp, err = now()
        if not stamp then return reject(err) end
        candidate = {version=1, store=store, closedPaused={}, nonce=freshNonce(stamp,key), counter=0}
    end
    local stamp
    stamp, err = now()
    if not stamp then return reject(err) end
    local paused
    paused, err = S.Pause(candidate.store, stamp)
    if not paused then return fail("Shared saved data was left untouched: " .. tostring(err)) end
    candidate = clone(candidate)
    candidate.store = paused
    character, localName = key, name
    -- No prefix registration, network enablement, or queue replay on startup.
    ok, err = persist(candidate)
    if not ok then character, localName = nil, nil; return fail(err) end
    notice = nil
    return true
end

local function current()
    local ok, err = V.Initialize()
    if not ok then return nil, err end
    if IOU.Character() ~= character or fullName() ~= localName then return fail("The current character identity changed; reload before sharing.") end
    local map, problem = namespace()
    if map == nil then return fail(problem) end
    if not map or rawget(map, character) ~= entry then return fail("Shared saved data changed outside this session; it was left untouched.") end
    ok, err = validateEntry(entry, localName)
    if not ok then return fail("Shared saved data was left untouched: " .. tostring(err)) end
    return entry, nil, err
end
function V.IsEnabled()
    local w = wire()
    return (peer ~= nil or background) and type(w) == "table" and type(w.IsEnabled) == "function" and w.IsEnabled() == true
end
function V.IsBackground() return background and V.IsEnabled() end
function V.GetPeer() return V.IsEnabled() and peer or nil end
local function enabled()
    local value, err = current()
    if not value then return nil, err end
    local pending, problem = V.IsRecoveryPending()
    if pending then return reject(problem or "Review the staged Shared recovery before enabling communication.") end
    if not V.IsEnabled() then return reject("Enable sharing for this player first.") end
    return value
end
local function offerPeer(offer)
    local terms = C.ParseTerms(offer.terms)
    return offer.role == "proposer" and terms.recipient or terms.proposer
end
local function unresolved(value, other)
    for id, offer in pairs(value.store.offers) do
        if offer.state == "PAUSED" and not value.closedPaused[id] and offerPeer(offer) == other then return true end
    end
    return false
end
local function offerSnapshot(value, id)
    -- All callers have just validated this entry. Copy each selected record
    -- directly instead of revalidating the entire ledger for every list row.
    local source=value.store.offers[id]
    if not source then return nil,"Unknown shared offer." end
    local offer=clone(source)
    local closed = value.closedPaused[id]
    if closed then offer.localClosed, offer.localClosedAt, offer.localCloseReason = true, closed.at, closed.reason end
    return offer
end
local function inboxSnapshot(id)
    expireInbox()
    local row=inbox[id]
    return row and clone(row.store.offers[id]) or nil
end
local function appendInbox(offers,value)
    expireInbox()
    for id,row in pairs(inbox) do
        if not value.store.offers[id] then offers[#offers+1]=clone(row.store.offers[id]) end
    end
end
function V.GetStore()
    local value, err = current()
    if not value then return nil, err end
    return clone(value.store)
end
function V.GetOffer(id)
    local value, err = current()
    if not value then return nil, err end
    if value.store.offers[id] then return offerSnapshot(value,id) end
    local transient=inboxSnapshot(id)
    if transient then return transient end
    return nil,"Unknown shared offer."
end
function V.GetBalance(id)
    local value, err = current()
    if not value then return nil, err end
    return P.View(value.store,id,value.closedPaused)
end
function V.List()
    local value, err = current()
    if not value then return nil, err end
    local offers = {}
    for id in pairs(value.store.offers) do offers[#offers+1] = offerSnapshot(value, id) end
    appendInbox(offers,value)
    table.sort(offers, function(a,b)
        if a.createdAt ~= b.createdAt then return a.createdAt > b.createdAt end
        return a.offerId < b.offerId
    end)
    return offers
end
function V.GetOverview()
    local value, err, views=current()
    if not value then return nil,err end
    local offers={}
    for id in pairs(value.store.offers) do offers[#offers+1]=offerSnapshot(value,id) end
    appendInbox(offers,value)
    table.sort(offers,function(a,b)
        if a.createdAt ~= b.createdAt then return a.createdAt > b.createdAt end
        return a.offerId < b.offerId
    end)
    local result={offers=offers,balances=clone(views),localName=localName,peer=V.GetPeer()}
    if IOU.Sharing and type(IOU.Sharing.GetLinks)=="function" then
        result.links=IOU.Sharing.GetLinks();result.linkBases=IOU.Sharing.GetLinkBases()
    end
    return result
end
function V.GetStatus()
    if failure then return failure end
    if entry then
        local pending, problem = V.IsRecoveryPending()
        if pending then return problem or "Shared recovery needs review. Sharing stays off until you restore missing history or keep current records." end
    end
    if needsPause then return "Sharing is off; recovery is pending. Unfinished offers must pause before reconnecting. " .. (notice or "") end
    if notice then return notice end
    if not entry then return "Shared agreements have not been opened." end
    if not V.IsEnabled() then return "Sharing is off. Pending offers are paused when sharing stops." end
    if background then return "Requests are ready. New IOUs need acceptance." end
    local w = wire()
    return "Sharing with " .. peer .. ". " .. (type(w.GetStatus) == "function" and w.GetStatus() or "")
end

local function apply(candidate, outgoing, id)
    local ok, err = validateEntry(candidate, localName)
    if not ok then return reject(err) end
    ok, err = wireCall("CanQueue", outgoing)
    if not ok then return reject(err or "The shared message queue is full; nothing was changed.") end
    ok, err = persist(candidate)
    if not ok then return fail(err) end
    -- Persist local consent before enqueueing. An unexpected queue failure must
    -- retain the record so explicit Retry can recover that same consent.
    ok, err = wireCall("Send", outgoing)
    if not ok then
        local saved = id and offerSnapshot(entry, id) or nil
        local _, problem = reject("The shared record was saved, but delivery could not be queued. Use Retry. " .. tostring(err or ""))
        return nil, problem, saved
    end
    notice = nil
    changed()
    return id and offerSnapshot(entry, id) or true
end
local function transientApply(id,updated,outgoing)
    local row=inbox[id]
    if not row then return reject("This request expired. Ask the other player to send it again.") end
    local valid,problem=S.Validate(updated)
    if not valid then return reject(problem) end
    local ok,err=wireCall("CanQueue",outgoing)
    if not ok then return reject(err or "The shared message queue is full; nothing was changed.") end
    row.store=updated
    ok,err=wireCall("Send",outgoing)
    local offer=clone(updated.offers[id])
    if not ok then
        reject("Your decision was retained for this session, but delivery could not be queued. Use Retry. "..tostring(err or ""))
        return nil,notice,offer
    end
    notice=nil;changed();return offer
end
local function stageInvitation(sender,message,stamp)
    expireInbox()
    local row=inbox[message.offerId]
    if row then
        local original=row.message
        if row.sender~=sender or original.agreementId~=message.agreementId
            or original.terms~=message.terms or original.revision~=message.revision then
            return reject("A request identifier was reused with different terms.")
        end
        -- Use the engine for semantic replay validation, including duplicate
        -- proposal IDs. It can replay a retained Decline without new consent.
        local updated,outgoing=S.Receive(row.store,sender,message,stamp)
        if not updated then return reject(outgoing) end
        return transientApply(message.offerId,updated,outgoing)
    end
    local clock=inboxClock()
    if not clock then return reject("The client clock is unavailable.") end
    local total,fromPeer=0,0
    for _,item in pairs(inbox) do total=total+1;if item.sender==sender then fromPeer=fromPeer+1 end end
    if total>=INBOX_MAX then return reject("The request inbox is full. Unaccepted requests expire after five minutes.") end
    if fromPeer>=INBOX_PEER_MAX then return reject("This player's request inbox is full (12 requests).") end
    local store,problem=S.New(localName)
    if not store then return reject(problem) end
    local updated,outgoing=S.Receive(store,sender,message,stamp)
    if not updated then return reject(outgoing) end
    -- The first original proposal has no response and no local consent.
    if #outgoing~=0 then return reject("An invitation unexpectedly generated a response.") end
    inboxSerial=inboxSerial+1
    inbox[message.offerId]={sender=sender,message=clone(message),store=updated,expires=clock+INBOX_TTL,serial=inboxSerial}
    notice=nil;changed();return clone(updated.offers[message.offerId])
end
local function receive(sender, message)
    local value, err = enabled()
    if not value then return nil, err end
    if not plain(sender) or type(sender) ~= "string" or (not background and sender ~= peer)
        or sender==localName or not peerName(sender) then return reject("The observed sender does not exactly match the enabled player.") end
    local ok, problem = C.ValidateMessage(message)
    if not ok then return reject(problem) end
    if value.closedPaused[message.offerId] then return reject("A delayed message for a locally closed paused offer was rejected.") end
    if message.kind=="SYNC" then
        local coordinator=IOU.Sharing
        if not background or not coordinator or type(coordinator.ReceiveHint)~="function" then
            return reject("Shared synchronization is unavailable.")
        end
        return coordinator.ReceiveHint(sender,message)
    end
    local stamp
    stamp, err = now()
    if not stamp then return reject(err) end
    expireInbox()
    local transient=inbox[message.offerId]
    if background and not value.store.offers[message.offerId] and transient and message.kind~="PROPOSE" then
        if transient.sender~=sender then return reject("This request belongs to another player.") end
        if message.kind~="WITHDRAW" and message.kind~="OUTCOME" then return reject("Accept this request before receiving a commitment.") end
        local updated,outgoing=S.Receive(transient.store,sender,message,stamp)
        if not updated then return reject(outgoing) end
        return transientApply(message.offerId,updated,outgoing)
    end
    if message.kind == "PROPOSE" and not value.store.offers[message.offerId] then
        local terms = C.ParseTerms(message.terms)
        if C.IsObligation(terms) and unresolved(value, sender) then return reject("Review the unresolved paused offer with this player before receiving a replacement.") end
        if background and C.IsObligation(terms) then return stageInvitation(sender,message,stamp) end
        local count = 0
        for id, offer in pairs(value.store.offers) do
            if offer.role == "recipient" and offerPeer(offer) == sender and not value.closedPaused[id]
                and (offer.state == "OFFER_RECEIVED" or offer.state == "PAUSED") then count = count + 1 end
        end
        if count >= 4 then return reject("This player's pending proposal inbox is full (4 offers).") end
    end
    local updated, outgoing = S.Receive(value.store, sender, message, stamp)
    if not updated then return reject(outgoing) end
    local candidate = clone(value)
    candidate.store = updated
    return apply(candidate, outgoing, message.offerId)
end

function V.EnableBackground()
    local value,err=current(); if not value then return nil,err end
    local pending,problem=V.IsRecoveryPending()
    if pending then return nil,problem or "Review the saved recovery first." end
    if V.IsBackground() then return true end
    if needsPause then local ok; ok,err=pauseLoaded(); if not ok then return nil,err end end
    local ok; ok,err=wireCall("EnableBackground",receive)
    if not ok then return nil,err end
    background,notice=true,nil
    changed(); return true
end
function V.SelectPeer(other)
    local value,err=enabled(); if not value then return nil,err end
    local target,problem=peerName(other); if not target then return nil,problem end
    if not background then return V.Enable(target) end
    peer=target; changed(); return true
end

function V.Enable(other)
    local value, err = current()
    if not value then return nil, err end
    local pending, recoveryError = V.IsRecoveryPending()
    if pending then return reject(recoveryError or "Open Shared backups and review the staged recovery before enabling sharing.") end
    local target, problem = peerName(other)
    if not target then return reject(problem) end
    if peer and not V.IsEnabled() then peer=nil; needsPause=true end
    if needsPause then
        local paused, pauseError = pauseLoaded()
        if not paused then return reject("Recovery is pending; sharing remains off until unfinished offers can pause. " .. tostring(pauseError)) end
    end
    if V.IsEnabled() and peer == target then notice=nil; changed(); return true end
    if V.IsEnabled() then
        local ok
        ok, err = V.Disable()
        if not ok then return nil, err end
    end
    local w = wire()
    if type(w) ~= "table" or type(w.Enable) ~= "function" or type(w.CanQueue) ~= "function"
        or type(w.Send) ~= "function" then return reject("Shared message transport is unavailable.") end
    local ok
    ok, err = w.Enable(target, receive)
    if not ok then return reject(err) end
    peer, notice, background = target, nil, false
    changed()
    return true
end
function V.Disable()
    stopWire()
    local value, err = current()
    if not value then return nil, err end
    needsPause = true
    local ok
    ok, err = pauseLoaded()
    if not ok then return reject("Sharing stopped, but unfinished offers could not pause. Recovery is pending. " .. tostring(err)) end
    notice = nil
    changed()
    return true
end
local function allocate(candidate)
    for _=1,S.MAX_OFFERS+1 do
        if candidate.counter >= MAX_COUNTER then return nil, "Shared proposal identifier capacity reached." end
        candidate.counter = candidate.counter + 1
        local suffix = candidate.nonce .. "-" .. tostring(candidate.counter)
        local agreementId, offerId = "ag-" .. suffix, "of-" .. suffix
        local collision = candidate.store.offers[offerId] ~= nil
        for _, offer in pairs(candidate.store.offers) do if offer.agreementId == agreementId then collision=true end end
        if not collision then return agreementId, offerId end
    end
    return nil, "Could not allocate a unique shared proposal identifier."
end
function V.Propose(fields)
    local value, err = enabled()
    if not value then return nil, err end
    if not tablePlain(fields) then return reject("Enter the proposal fields.") end
    local allowed = {peer=true, direction=true, amountCopper=true, note=true, dueUTC=true,kind=true,itemKey=true,itemName=true}
    for key in pairs(fields) do if not allowed[key] then return reject("Unknown shared proposal field.") end end
    local target=background and peerName(fields.peer) or peer
    if not target or fields.peer ~= target then return reject("The proposal player does not exactly match the enabled player.") end
    if fields.direction ~= "owed" and fields.direction ~= "owe" then return reject("Choose who owes the gold.") end
    if unresolved(value, target) then return reject("Review and close the unresolved paused offer with this player before creating a replacement.") end
    if fields.kind~=nil and fields.kind~="money" and fields.kind~="item" then return reject("Only gold and items can be shared.") end
    local item=fields.kind=="item"
    if not item and (fields.itemKey~=nil or fields.itemName~=nil) then return reject("Gold cannot include an item identity.") end
    local terms = {protocol=item and 3 or 1, kind=item and "ITEM_OBLIGATION" or "GOLD_OBLIGATION", proposer=localName, recipient=target,
        debtor=fields.direction == "owed" and target or localName,
        creditor=fields.direction == "owed" and localName or target,
        amountCopper=fields.amountCopper, dueUTC=fields.dueUTC == nil and 0 or fields.dueUTC,
        note=fields.note == nil and "" or fields.note}
    if item then terms.itemKey,terms.itemName=fields.itemKey,fields.itemName end
    local ok, problem = C.ValidateTerms(terms)
    if not ok then return reject(problem) end
    local candidate = clone(value)
    local agreementId, offerId = allocate(candidate)
    if not agreementId then return reject(offerId) end
    local stamp
    stamp, err = now()
    if not stamp then return reject(err) end
    local updated, outgoing = S.Propose(value.store, terms, agreementId, offerId, stamp)
    if not updated then return reject(outgoing) end
    candidate.store = updated
    return apply(candidate, outgoing, offerId)
end
local function proposeEvent(parentId, method, first, second)
    local value, err = enabled()
    if not value then return nil, err end
    local parent = value.store.offers[parentId]
    if not parent then return reject("Unknown original shared agreement.") end
    if not background and offerPeer(parent) ~= peer then return reject("Enable sharing with the original agreement's player first.") end
    local terms, problem = method(value.store,parentId,first,second,value.closedPaused)
    if not terms then return reject(problem) end
    local candidate = clone(value)
    local agreementId, offerId = allocate(candidate)
    if not agreementId then return reject(offerId) end
    local stamp
    stamp, err = now()
    if not stamp then return reject(err) end
    local updated, outgoing = S.Propose(value.store,terms,agreementId,offerId,stamp)
    if not updated then return reject(outgoing) end
    candidate.store = updated
    return apply(candidate,outgoing,offerId)
end
function V.ProposePayment(parentId,amountCopper,note)
    return proposeEvent(parentId,P.BuildPayment,amountCopper,note)
end
function V.ProposeCorrection(parentId,paymentId,reason)
    return proposeEvent(parentId,P.BuildCorrection,paymentId,reason)
end
function V.SendHint(id,paidAmount)
    local value,err=enabled();if not value then return nil,err end
    local offer=value.store.offers[id]
    local terms=offer and C.ParseTerms(offer.terms)
    local view=offer and P.View(value.store,id,value.closedPaused)
    if not background or not offer or offer.role~="recipient" or offer.state~="COMMITTED"
        or value.closedPaused[id] or not C.IsObligation(terms) or not view or not view.confirmed
        or not integer(paidAmount,terms.amountCopper) then return nil,"Choose an agreed shared IOU." end
    -- This carries no consent and cannot change either ledger. The original
    -- proposer must still offer the exact payment/correction through the normal
    -- commitment protocol; its recipient verifies local evidence or reviews it.
    local message={version=1,kind="SYNC",revision=1,agreementId=offer.agreementId,offerId=id,
        messageId="h-"..value.nonce.."-"..value.store.serial.."-"..paidAmount,
        terms=offer.terms,paidAmount=paidAmount,baseRevision=view.baseRevision,baseChain=view.baseChain}
    local valid,problem=C.ValidateMessage(message);if not valid then return nil,problem end
    local actions={{target=terms.proposer,message=message}}
    local ok;ok,err=wireCall("CanQueue",actions);if not ok then return nil,err end
    return wireCall("Send",actions)
end
local function mutate(method, id)
    local value, err = enabled()
    if not value then return nil, err end
    expireInbox()
    local invitation=inbox[id]
    if background and not value.store.offers[id] and invitation then
        local stamp;stamp,err=now()
        if not stamp then return reject(err) end
        if method==S.Accept then
            local pending=invitation.store.offers[id]
            if pending.state~="OFFER_RECEIVED" or pending.consent~="NONE" then return reject("Only an undecided request can be accepted.") end
            -- Reconstruct the original arrival and local Accept in one staged
            -- candidate. Neither the request nor consent is saved on failure.
            local updated,outgoing=S.Receive(value.store,invitation.sender,invitation.message,pending.createdAt)
            if not updated then return reject(outgoing) end
            updated,outgoing=S.Accept(updated,id,stamp)
            if not updated then return reject(outgoing) end
            local candidate=clone(value);candidate.store=updated
            local result,problem,saved=apply(candidate,outgoing,id)
            if entry.store.offers[id] then inbox[id]=nil end
            return result,problem,saved
        end
        if method~=S.Decline and method~=S.Retry then return reject("Only Accept or Decline is available for this request.") end
        local updated,outgoing=method(invitation.store,id,stamp)
        if not updated then return reject(outgoing) end
        return transientApply(id,updated,outgoing)
    end
    local offer = value.store.offers[id]
    if not offer then return reject("Unknown shared offer.") end
    if value.closedPaused[id] then return reject("This paused offer was closed locally; its evidence was retained.") end
    if not background and offerPeer(offer) ~= peer then return reject("Enable sharing with this offer's player first.") end
    local stamp
    stamp, err = now()
    if not stamp then return reject(err) end
    local updated, outgoing = method(value.store, id, stamp)
    if not updated then return reject(outgoing) end
    local candidate = clone(value)
    candidate.store = updated
    return apply(candidate, outgoing, id)
end
function V.Accept(id) return mutate(S.Accept,id) end
function V.Decline(id) return mutate(S.Decline,id) end
function V.Withdraw(id) return mutate(S.Withdraw,id) end
function V.Retry(id) return mutate(S.Retry,id) end
function V.Resume(id) return mutate(S.Resume,id) end
function V.ClosePaused(id, reason)
    local value, err = current()
    if not value then return nil, err end
    local pending, recoveryError = V.IsRecoveryPending()
    if pending then return reject(recoveryError or "Review the staged Shared recovery before changing paused offers.") end
    if V.IsEnabled() then return reject("Disable sharing before reviewing a paused offer.") end
    local offer = value.store.offers[id]
    if not offer or offer.state ~= "PAUSED" then return reject("Only a paused offer can be closed locally.") end
    if value.closedPaused[id] then return reject("This paused offer is already closed locally.") end
    if reason == nil or (type(reason) == "string" and #reason <= 256
        and not reason:find("[%z\1-\31\127|]") and not reason:find("%S")) then
        reason = "No reason provided"
    end
    if not reasonValid(reason,offer) then return reject("Review notes must be plain UTF-8 text (up to 256 bytes).") end
    local stamp
    stamp, err = now()
    if not stamp or stamp < offer.updatedAt then return reject(err or "The clock precedes this offer's latest event.") end
    local candidate = clone(value)
    candidate.closedPaused[id] = {at=stamp, reason=reason}
    local ok
    ok, err = persist(candidate)
    if not ok then return fail(err) end
    notice = nil
    changed()
    return offerSnapshot(entry,id)
end

-- Shared backups are local snapshots, never wire messages. Recovery is staged
-- separately so even committed records cannot send until the player reviews it.
local function backupCodec()
    local b = IOU.SharedBackup
    if type(b) ~= "table" or type(b.Encode) ~= "function" or type(b.Decode) ~= "function" then
        return nil, "The Shared backup codec is unavailable."
    end
    return b
end
local function snapshotText(value, stamp)
    local b, err = backupCodec()
    if not b then return nil, err end
    return b.Encode({version=1, character=character, owner=localName, exportedAt=stamp, entry=value})
end
-- Only immutable text snapshots are cached, never live SavedVariables. Decoded
-- trees stay private and are cloned before adoption or inclusion in a public
-- preview. Two entries and an 8 MiB total key budget bound retained memory.
local snapshotCache={}
local function cacheSnapshot(text,snapshot,views)
    table.insert(snapshotCache,1,{text=text,snapshot=snapshot,views=views})
    local bytes=0
    for index=#snapshotCache,1,-1 do
        if index>2 then table.remove(snapshotCache,index) end
    end
    for index=1,#snapshotCache do bytes=bytes+#snapshotCache[index].text end
    while bytes>8388608 and #snapshotCache>0 do
        bytes=bytes-#snapshotCache[#snapshotCache].text
        table.remove(snapshotCache)
    end
end
local function readSnapshot(text)
    local b, err = backupCodec()
    if not b then return nil, err end
    if plain(text) and type(text) == "string" then
        for index,item in ipairs(snapshotCache) do
            if item.text == text and item.snapshot.character == character and item.snapshot.owner == localName then
                table.remove(snapshotCache,index); table.insert(snapshotCache,1,item)
                return item.snapshot,nil,item.views
            end
        end
    end
    local snapshot
    snapshot, err = b.Decode(text)
    if not snapshot then return nil, err end
    if snapshot.character ~= character or snapshot.owner ~= localName then
        return nil, "Use this character's own Shared backup. Another character's export cannot supply your consent."
    end
    local ok, views = validateEntry(snapshot.entry, localName)
    if not ok then return nil, "Invalid Shared backup: " .. tostring(views) end
    cacheSnapshot(text,snapshot,views)
    return snapshot, nil, views
end
local function same(a,b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, item in pairs(a) do if not same(item,b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function recoveryMap()
    if not tablePlain(IOUDB) then return nil,"Saved data is unavailable; Shared recovery was left untouched." end
    local map = rawget(IOUDB, "sharedRecoveryByCharacter")
    if map ~= nil and not tablePlain(map) then return nil, "Shared recovery storage is invalid; it was left untouched." end
    return map or false
end
local function recoveryRecord(decode)
    local map, err = recoveryMap()
    if map == nil then return nil, err end
    if not map then return false end
    local record = rawget(map,character)
    if record == nil then return false end
    if not exactKeys(record,{version=true,owner=true,character=true,at=true,resolvedAt=true,status=true,base=true,backup=true})
        or record.version ~= 1 or record.owner ~= localName or record.character ~= character
        or not integer(record.at,MAX_TIME) or not integer(record.resolvedAt,MAX_TIME)
        or (record.status ~= "PENDING" and record.status ~= "RESTORED" and record.status ~= "KEPT")
        or (record.status == "PENDING" and record.resolvedAt ~= 0)
        or (record.status ~= "PENDING" and record.resolvedAt < record.at)
        or type(record.base) ~= "string" or type(record.backup) ~= "string"
        or #record.base > 8388608 or #record.backup > 8388608 then
        return nil, "Shared recovery storage is invalid; it was left untouched."
    end
    -- The hot communication gate only needs the validated status shell. Large
    -- historical snapshots are decoded when opened or acted on, never per frame.
    if not decode then return record end
    local base, problem = readSnapshot(record.base)
    if not base then return nil, "The recovery's previous records are invalid: " .. tostring(problem) end
    local imported, importedViews
    imported, problem, importedViews = readSnapshot(record.backup)
    if not imported then return nil, "The recovery's imported snapshot is invalid: " .. tostring(problem) end
    return record, nil, imported, base, importedViews
end
function V.IsRecoveryPending()
    -- Do not initialize or send while merely checking the recovery gate.
    if not entry then return false end
    local record, err = recoveryRecord()
    if record == nil then return true, err end
    return record and record.status == "PENDING" or false
end
function V.HasRecovery()
    if not entry then return false end
    local record, err=recoveryRecord()
    return record ~= nil and record ~= false, err
end
local function hasPending(store)
    for _,offer in pairs(store.offers) do
        if offer.state == "OFFER_OPEN" or offer.state == "OFFER_RECEIVED"
            or offer.state == "ACCEPT_PENDING" or offer.state == "DECLINE_PENDING" then return true end
    end
    return false
end
local function buildPreview(value, imported, stamp, currentViews, backupViews)
    local other = imported.entry
    local result = {owner=localName, character=character, exportedAt=imported.exportedAt,
        total=0, missing=0, identical=0, different=0, currentOnly=0, closedAdded=0, rows={}, balances={}}
    local candidate = clone(value)
    local unresolvedPeers={}
    for id,offer in pairs(value.store.offers) do
        local terms=C.ParseTerms(offer.terms)
        if C.IsObligation(terms) and (offer.state == "OFFER_OPEN" or offer.state == "OFFER_RECEIVED"
            or offer.state == "ACCEPT_PENDING" or offer.state == "DECLINE_PENDING"
            or offer.state == "PAUSED" and not value.closedPaused[id]) then
            unresolvedPeers[offerPeer(offer)]=true
        end
    end
    local parallelConflict
    for id, offer in pairs(other.store.offers) do
        result.total=result.total+1
        local existing = value.store.offers[id]
        local classification
        if not existing then
            classification="missing"; result.missing=result.missing+1
            candidate.store.offers[id]=clone(offer)
            local terms=C.ParseTerms(offer.terms)
            if C.IsObligation(terms) and unresolvedPeers[offerPeer(offer)] then
                parallelConflict="Review the current unfinished agreement with " .. offerPeer(offer)
                    .. " before adding another original agreement from a backup."
            end
        elseif same(existing,offer) and same(value.closedPaused[id],other.closedPaused[id]) then
            classification="identical"; result.identical=result.identical+1
        else
            classification="different"; result.different=result.different+1
        end
        result.rows[#result.rows+1]={offerId=id,classification=classification,
            backup=clone(offer),current=existing and clone(existing) or nil,
            backupClosed=other.closedPaused[id] and clone(other.closedPaused[id]) or nil,
            currentClosed=value.closedPaused[id] and clone(value.closedPaused[id]) or nil}
        -- Existing closures always win. A missing closure can be recovered only
        -- for the same paused offer/terms, without replacing its retained consent.
        local closed=other.closedPaused[id]
        local kept=candidate.store.offers[id]
        if closed and not candidate.closedPaused[id] and kept.state == "PAUSED"
            and (not existing or same(existing,offer)) and closed.at >= kept.updatedAt then
            candidate.closedPaused[id]=clone(closed)
            result.closedAdded=result.closedAdded+1
        end
    end
    for id, offer in pairs(value.store.offers) do
        if not other.store.offers[id] then
            result.currentOnly=result.currentOnly+1
            result.rows[#result.rows+1]={offerId=id,classification="currentOnly",current=clone(offer),
                currentClosed=value.closedPaused[id] and clone(value.closedPaused[id]) or nil}
        end
    end
    table.sort(result.rows,function(a,b) return a.offerId < b.offerId end)
    candidate.store.serial=math.max(candidate.store.serial,other.store.serial)
    if candidate.nonce == other.nonce then candidate.counter=math.max(candidate.counter,other.counter) end
    local paused, err
    if parallelConflict then err=parallelConflict
    elseif not stamp then err="A valid client clock is required before restoring."
    elseif imported.exportedAt > stamp then err="The backup date is ahead of the client clock. Correct the clock before restoring."
    else
        for _, offer in pairs(other.store.offers) do
            if offer.updatedAt > stamp then err="Backup history is ahead of the client clock. Correct the clock before restoring."; break end
        end
        if not err and hasPending(candidate.store) then
            local problem
            paused,problem=S.Pause(candidate.store,stamp)
            if not paused then err=problem end
        elseif not err then paused=candidate.store
        end
    end
    local candidateViews
    if paused then
        candidate.store=paused
        local ok, problem=validateEntry(candidate,localName)
        if not ok then err=problem else candidateViews=problem end
    end
    if err then result.problem="The combined history cannot be restored: " .. tostring(err) end
    result.canRestore=not result.problem
    currentViews=currentViews or P.Views(value.store,value.closedPaused)
    backupViews=backupViews or P.Views(other.store,other.closedPaused)
    for _, row in ipairs(result.rows) do
        local old=currentViews and currentViews[row.offerId]
        local saved=backupViews and backupViews[row.offerId]
        local merged=candidateViews and candidateViews[row.offerId]
        if old or saved or merged then
            local source=old and row.current or row.backup or row.current
            local terms=C.ParseTerms(source.terms)
            local function amount(view) return view and view.confirmed and view.remainingCopper or nil end
            result.balances[#result.balances+1]={offerId=row.offerId,
                peer=terms.proposer == localName and terms.recipient or terms.proposer,
                currentCopper=amount(old),backupCopper=amount(saved),candidateCopper=amount(merged),
                currentState=old and old.state,backupState=saved and saved.state,candidateState=merged and merged.state}
        end
    end
    result.currentFingerprint=snapshotText(value,0)
    if not result.currentFingerprint then return nil,"The current Shared records could not be snapshotted." end
    return result, candidate
end
function V.ExportBackup()
    local value, err=current()
    if not value then return nil,err end
    local stamp
    stamp,err=now()
    if not stamp then return nil,err end
    return snapshotText(value,stamp)
end
function V.PreviewBackup(text)
    local value, err, currentViews=current()
    if not value then return nil,err end
    local imported, backupViews
    imported,err,backupViews=readSnapshot(text)
    if not imported then return nil,err end
    local preview, problem=buildPreview(value,imported,now(),currentViews,backupViews)
    if not preview then return nil,problem end
    return preview
end
local function reviewRecord(record, imported, currentViews, backupViews)
    local preview, err=buildPreview(entry,imported,now(),currentViews,backupViews)
    if not preview then return nil,err end
    local unchanged=preview.currentFingerprint == record.base
    local problem=record.status == "PENDING" and not unchanged
        and "Current Shared records changed after staging. Keep current records, then preview again." or preview.problem
    return {status=record.status,owner=record.owner,character=record.character,exportedAt=imported.exportedAt,
        at=record.at,resolvedAt=record.resolvedAt,preview=preview,
        token={backup=record.backup,base=record.base,at=record.at},
        canRestore=unchanged and preview.canRestore,problem=problem}
end
function V.GetRecovery()
    local value, err, currentViews=current()
    if not value then return nil,err end
    local record, problem, imported, _, backupViews=recoveryRecord(true)
    if record == nil then return nil,problem end
    if record == false then return nil end
    return reviewRecord(record,imported,currentViews,backupViews)
end
function V.StageRecovery(text, expectedCurrent)
    local value, err=current()
    if not value then return nil,err end
    local pending, problem=V.IsRecoveryPending()
    if pending then return reject(problem or "Review the already staged Shared recovery first.") end
    local imported, backupViews
    imported,err,backupViews=readSnapshot(text)
    if not imported then return nil,err end
    if type(expectedCurrent) ~= "string" or snapshotText(value,0) ~= expectedCurrent then
        return reject("Shared records changed after the preview. Preview this backup again.")
    end
    local stamp
    stamp,err=now()
    if not stamp then return nil,err end
    local paused
    if hasPending(value.store) then paused,err=S.Pause(value.store,stamp) else paused=clone(value.store) end
    if not paused then return nil,err end
    local candidate=clone(value); candidate.store=paused
    local ok, candidateViews
    ok,candidateViews=validateEntry(candidate,localName)
    if not ok then return nil,candidateViews end
    local base, backup=snapshotText(candidate,0),snapshotText(imported.entry,imported.exportedAt)
    if not base or not backup then return reject("The recovery snapshot could not be encoded; nothing was changed.") end
    local map
    map,err=recoveryMap()
    if map == nil then return reject(err) end
    local prior, priorError=recoveryRecord()
    if prior == nil then return reject(priorError) end
    local record={version=1,owner=localName,character=character,at=stamp,resolvedAt=0,
        status="PENDING",base=base,backup=backup}
    -- Everything is validated before disconnecting. There are no queue sends,
    -- callbacks or user code between the two SavedVariables assignments.
    stopWire()
    ok,err=persist(candidate,true)
    if not ok then return fail(err) end
    if not map then map={}; IOUDB.sharedRecoveryByCharacter=map end
    map[character]=record
    needsPause,notice=false,nil
    local review=reviewRecord(record,imported,candidateViews,backupViews)
    changed()
    return review
end
function V.ResolveRecovery(choice, token)
    local value, err, currentViews=current()
    if not value then return nil,err end
    local record, problem, imported, _, backupViews=recoveryRecord(true)
    if not record then return reject(problem or "There is no Shared recovery to review.") end
    if record.status ~= "PENDING" then return reject("This Shared recovery has already been reviewed.") end
    if not exactKeys(token,{backup=true,base=true,at=true}) or token.backup ~= record.backup
        or token.base ~= record.base or token.at ~= record.at then
        return reject("The staged recovery changed. Open its review again.")
    end
    if choice ~= "restore" and choice ~= "keep" then return reject("Choose restore missing history or keep current records.") end
    local stamp
    stamp,err=now()
    if not stamp or stamp < record.at then return reject(err or "The clock precedes the staged recovery.") end
    local candidate=value
    if choice == "restore" then
        if snapshotText(value,0) ~= record.base then return reject("Current Shared records changed after staging. Keep current records and preview again.") end
        local preview
        preview,candidate=buildPreview(value,imported,stamp,currentViews,backupViews)
        if not preview then return reject(candidate) end
        if not preview.canRestore then return reject(preview.problem) end
    end
    local resolved=clone(record)
    resolved.status=choice == "restore" and "RESTORED" or "KEPT"
    resolved.resolvedAt=stamp
    local map
    map,err=recoveryMap()
    if map == nil or not map or map[character] ~= record then return reject(err or "The recovery changed outside this session.") end
    if choice == "restore" then
        local ok
        ok,err=persist(candidate,true)
        if not ok then return fail(err) end
    end
    map[character]=resolved
    notice=nil
    changed()
    return true
end
function V.ExportRecovery(which)
    local value, err=current()
    if not value then return nil,err end
    local record, problem=recoveryRecord()
    if not record then return nil,problem or "No previous Shared recovery is available." end
    if which == "backup" then return record.backup end
    if which == "before" then return record.base end
    return nil,"Choose the imported backup or the records before recovery."
end

-- Wire changes (including asynchronous native send errors) refresh the UI, but
-- a throwing display callback cannot affect persisted consent or processing.
IOU.OnSharedWireChanged = function()
    if handlingWireChange then return end
    handlingWireChange = true
    local w = wire()
    if (peer or background) and type(w) == "table" and type(w.IsEnabled) == "function" and not w.IsEnabled() then
        local detail = type(w.GetStatus) == "function" and w.GetStatus() or "Shared communication stopped unexpectedly."
        peer, background, needsPause = nil, false, true
        local ok, err = pauseLoaded()
        notice = detail .. (ok and " Unfinished offers were paused." or " Recovery is pending: " .. tostring(err))
    end
    handlingWireChange = false
    changed()
end
