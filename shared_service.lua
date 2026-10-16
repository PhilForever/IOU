local _, IOU = ...
local V = {}
IOU.SharedService = V
local S, C, P = IOU.Shared, IOU.SharedCodec, IOU.SharedPayments
local entry, character, localName, failure, notice, peer, notifying, needsPause, handlingWireChange
local MAX_COUNTER, MAX_TIME = 2147483647, 4102444800

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
    if peer then needsPause = true end
    -- Clear the session identity before Disable invokes its refresh callback.
    peer = nil
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
    if type(P) ~= "table" or type(P.Validate) ~= "function" then return nil, "The shared payment domain is unavailable." end
    local ok, err = P.Validate(value.store,value.closedPaused)
    if not ok then return nil, err end
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
    return true
end
local function namespace()
    if not tablePlain(IOUDB) then return nil, "Saved data is unavailable." end
    local map = rawget(IOUDB, "sharedByCharacter")
    if map ~= nil and not tablePlain(map) then return nil, "Shared character storage is invalid; it was left untouched." end
    return map or false
end
local function persist(candidate)
    local ok, err = validateEntry(candidate, localName)
    if not ok then return nil, err end
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
    return entry
end
function V.IsEnabled()
    local w = wire()
    return peer ~= nil and type(w) == "table" and type(w.IsEnabled) == "function" and w.IsEnabled() == true
end
function V.GetPeer() return V.IsEnabled() and peer or nil end
local function enabled()
    local value, err = current()
    if not value then return nil, err end
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
function V.GetStore()
    local value, err = current()
    if not value then return nil, err end
    return clone(value.store)
end
function V.GetOffer(id)
    local value, err = current()
    if not value then return nil, err end
    return offerSnapshot(value, id)
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
    table.sort(offers, function(a,b)
        if a.createdAt ~= b.createdAt then return a.createdAt > b.createdAt end
        return a.offerId < b.offerId
    end)
    return offers
end
function V.GetStatus()
    if failure then return failure end
    if needsPause then return "Sharing is off; recovery is pending. Unfinished offers must pause before reconnecting. " .. (notice or "") end
    if notice then return notice end
    if not entry then return "Shared agreements have not been opened." end
    if not V.IsEnabled() then return "Sharing is off. Pending offers are paused when sharing stops." end
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
local function receive(sender, message)
    local value, err = enabled()
    if not value then return nil, err end
    if not plain(sender) or type(sender) ~= "string" or sender ~= peer then return reject("The observed sender does not exactly match the enabled player.") end
    local ok, problem = C.ValidateMessage(message)
    if not ok then return reject(problem) end
    if value.closedPaused[message.offerId] then return reject("A delayed message for a locally closed paused offer was rejected.") end
    if message.kind == "PROPOSE" and not value.store.offers[message.offerId] then
        local terms = C.ParseTerms(message.terms)
        if terms.kind == "GOLD_OBLIGATION" and unresolved(value, sender) then return reject("Review the unresolved paused offer with this player before receiving a replacement.") end
        local count = 0
        for id, offer in pairs(value.store.offers) do
            if offer.role == "recipient" and offerPeer(offer) == sender and not value.closedPaused[id]
                and (offer.state == "OFFER_RECEIVED" or offer.state == "PAUSED") then count = count + 1 end
        end
        if count >= 4 then return reject("This player's pending proposal inbox is full (4 offers).") end
    end
    local stamp
    stamp, err = now()
    if not stamp then return reject(err) end
    local updated, outgoing = S.Receive(value.store, sender, message, stamp)
    if not updated then return reject(outgoing) end
    local candidate = clone(value)
    candidate.store = updated
    return apply(candidate, outgoing, message.offerId)
end

function V.Enable(other)
    local value, err = current()
    if not value then return nil, err end
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
    peer, notice = target, nil
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
    local allowed = {peer=true, direction=true, amountCopper=true, note=true, dueUTC=true}
    for key in pairs(fields) do if not allowed[key] then return reject("Unknown shared proposal field.") end end
    if fields.peer ~= peer then return reject("The proposal player does not exactly match the enabled player.") end
    if fields.direction ~= "owed" and fields.direction ~= "owe" then return reject("Choose who owes the gold.") end
    if unresolved(value, peer) then return reject("Review and close the unresolved paused offer with this player before creating a replacement.") end
    local terms = {protocol=1, kind="GOLD_OBLIGATION", proposer=localName, recipient=peer,
        debtor=fields.direction == "owed" and peer or localName,
        creditor=fields.direction == "owed" and localName or peer,
        amountCopper=fields.amountCopper, dueUTC=fields.dueUTC == nil and 0 or fields.dueUTC,
        note=fields.note == nil and "" or fields.note}
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
    if offerPeer(parent) ~= peer then return reject("Enable sharing with the original agreement's player first.") end
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
local function mutate(method, id)
    local value, err = enabled()
    if not value then return nil, err end
    local offer = value.store.offers[id]
    if not offer then return reject("Unknown shared offer.") end
    if value.closedPaused[id] then return reject("This paused offer was closed locally; its evidence was retained.") end
    if offerPeer(offer) ~= peer then return reject("Enable sharing with this offer's player first.") end
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
function V.ClosePaused(id, reason)
    local value, err = current()
    if not value then return nil, err end
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

-- Wire changes (including asynchronous native send errors) refresh the UI, but
-- a throwing display callback cannot affect persisted consent or processing.
IOU.OnSharedWireChanged = function()
    if handlingWireChange then return end
    handlingWireChange = true
    local w = wire()
    if peer and type(w) == "table" and type(w.IsEnabled) == "function" and not w.IsEnabled() then
        local detail = type(w.GetStatus) == "function" and w.GetStatus() or "Shared communication stopped unexpectedly."
        peer, needsPause = nil, true
        local ok, err = pauseLoaded()
        notice = detail .. (ok and " Unfinished offers were paused." or " Recovery is pending: " .. tostring(err))
    end
    handlingWireChange = false
    changed()
end
