local _, IOU = ...
local S = {VERSION = 1, MAX_OFFERS = 128}
IOU.Shared = S

-- Offline protocol foundation. Every mutation returns a new validated store
-- and explicit message actions; this module never sends, saves, or reads time.
local MAX_INTEGER = 9007199254740991
local MAX_SERIAL = 2147483647
local MAX_HISTORY, MAX_PROCESSED = 16, 32
local terminal = {COMMITTED=true, DECLINED=true, WITHDRAWN=true}
local pending = {OFFER_OPEN=true, OFFER_RECEIVED=true, ACCEPT_PENDING=true, DECLINE_PENDING=true}
local deliveryStates = {NONE=true, QUEUED=true, WAITING_FOR_PEER=true,
    PEER_RECEIPT_OBSERVED=true, RETRY_PAUSED=true}
local messageKinds = {propose="PROPOSE", accept="ACCEPT", commit="COMMIT", ack="ACK",
    decline="DECLINE", withdraw="WITHDRAW", outcome="OUTCOME"}
local historyKinds = {OFFER_SENT=true, OFFER_RECEIVED=true, ACCEPTED_LOCALLY=true,
    DECLINED_LOCALLY=true, COMMITTED=true, PEER_RECEIPT=true, DECLINED=true,
    WITHDRAWN=true, PAUSED=true, RESUMED=true}

local function integer(value)
    return type(value) == "number" and value == math.floor(value)
        and value >= 0 and value <= MAX_INTEGER
end

local function identifier(value)
    return type(value) == "string" and #value >= 1 and #value <= 64
        and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function plainTable(value)
    return type(value) == "table" and getmetatable(value) == nil
end

local function keys(value, allowed)
    if not plainTable(value) then return nil end
    for key in pairs(value) do if not allowed[key] then return nil end end
    return true
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function codec()
    return IOU.SharedCodec
end

local function parseTerms(value)
    local c = codec()
    if type(c) ~= "table" or type(c.ParseTerms) ~= "function" then
        return nil, "The shared agreement codec is unavailable."
    end
    return c.ParseTerms(value)
end

local function canonicalTerms(value)
    local c = codec()
    if type(c) ~= "table" or type(c.CanonicalTerms) ~= "function" then
        return nil, "The shared agreement codec is unavailable."
    end
    return c.CanonicalTerms(value)
end

local function validateMessage(message)
    local c = codec()
    if type(c) ~= "table" or type(c.ValidateMessage) ~= "function" then
        return nil, "The shared agreement codec is unavailable."
    end
    return c.ValidateMessage(message)
end

local function encode(message)
    local c = codec()
    if type(c) ~= "table" or type(c.Encode) ~= "function" then return nil, "The shared agreement codec is unavailable." end
    return c.Encode(message)
end

local function localNameValid(name)
    -- Reuse the strict terms schema rather than introduce another name parser.
    if type(name) ~= "string" then return nil end
    for _, other in ipairs({"IOU Placeholder", "IOU Other"}) do
        if canonicalTerms({protocol=1, kind="GOLD_OBLIGATION", proposer=name,
            recipient=other, debtor=name, creditor=other, amountCopper=1, dueUTC=0, note=""}) then return true end
    end
    return nil
end

local function sameSemantic(left, right)
    if not left or not right then return false end
    for key, value in pairs(left) do
        if key ~= "messageId" and right[key] ~= value then return false end
    end
    for key, value in pairs(right) do
        if key ~= "messageId" and left[key] ~= value then return false end
    end
    return true
end

local function countEntries(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function validateOffer(offer, offerId, localName)
    local allowed = {agreementId=true, offerId=true, revision=true, terms=true,
        role=true, state=true, consent=true, delivery=true, createdAt=true,
        updatedAt=true, history=true, messages=true, processed=true, pausedFrom=true}
    if not keys(offer, allowed) or offer.offerId ~= offerId or not identifier(offerId)
        or not identifier(offer.agreementId) or offer.revision ~= 1
        or not integer(offer.createdAt) or not integer(offer.updatedAt)
        or offer.updatedAt < offer.createdAt or not deliveryStates[offer.delivery] then
        return nil, "Invalid shared offer record."
    end
    local terms, err = parseTerms(offer.terms)
    if not terms then return nil, err end
    local role = terms.proposer == localName and "proposer" or (terms.recipient == localName and "recipient" or nil)
    if not role or role ~= offer.role then return nil, "Shared offer belongs to another character." end
    local state = offer.state
    if state == "PAUSED" then
        if not pending[offer.pausedFrom] or offer.delivery ~= "RETRY_PAUSED" then return nil, "Invalid paused shared offer." end
        state = offer.pausedFrom
    elseif offer.pausedFrom ~= nil then return nil, "Unexpected paused state." end
    if not pending[state] and not terminal[state] then return nil, "Unknown shared agreement state." end
    if role == "proposer" and (state == "OFFER_RECEIVED" or state == "ACCEPT_PENDING" or state == "DECLINE_PENDING")
        or role == "recipient" and state == "OFFER_OPEN" then return nil, "Shared role and state disagree." end
    if not keys(offer.messages, messageKinds) then return nil, "Invalid retained shared messages." end
    for name, message in pairs(offer.messages) do
        local ok, problem = validateMessage(message)
        if not ok then return nil, problem end
        if message.kind ~= messageKinds[name] or message.agreementId ~= offer.agreementId
            or message.offerId ~= offerId or message.terms ~= offer.terms or message.revision ~= 1 then
            return nil, "Retained shared message does not match its offer."
        end
    end
    local m = offer.messages
    if not m.propose then return nil, "Shared offer has no original proposal." end
    if m.commit and (not m.accept or m.commit.acceptanceId ~= m.accept.acceptanceId) then
        return nil, "Shared commit has no matching acceptance."
    end
    if m.ack and (not m.commit or m.ack.acceptanceId ~= m.commit.acceptanceId or m.ack.commitId ~= m.commit.commitId) then
        return nil, "Shared acknowledgment has no matching commit."
    end
    if m.accept and m.decline then return nil, "An offer cannot contain both acceptance and decline." end
    if m.commit and (m.withdraw or m.outcome) then return nil, "A committed offer has a conflicting terminal outcome." end
    if role == "proposer" and offer.consent ~= "PROPOSE" then return nil, "Missing local proposal consent." end
    if role == "recipient" and offer.consent ~= "NONE" and offer.consent ~= "ACCEPT" and offer.consent ~= "DECLINE" then
        return nil, "Invalid local shared consent."
    end
    if role == "recipient" and ((m.accept ~= nil) ~= (offer.consent == "ACCEPT")
        or (m.decline ~= nil) ~= (offer.consent == "DECLINE")) then return nil, "Local consent evidence is missing." end
    if state == "OFFER_OPEN" and (m.accept or m.decline or m.commit or m.withdraw or m.outcome)
        or state == "OFFER_RECEIVED" and (m.accept or m.decline or m.commit or m.withdraw or m.outcome)
        or state == "ACCEPT_PENDING" and (not m.accept or m.commit or m.withdraw or m.outcome)
        or state == "DECLINE_PENDING" and (not m.decline or m.commit or m.withdraw or m.outcome) then
        return nil, "Shared pending state has inconsistent messages."
    end
    if state == "COMMITTED" and (not m.accept or not m.commit or (role == "recipient" and not m.ack)) then
        return nil, "Committed state is missing local consent or commit evidence."
    end
    if state == "DECLINED" and (not m.decline or not m.outcome or m.outcome.outcome ~= "DECLINED") then
        return nil, "Declined state has no recorded decline outcome."
    end
    if state == "WITHDRAWN" and not (m.withdraw or (m.outcome and m.outcome.outcome == "WITHDRAWN")) then
        return nil, "Withdrawn state has no recorded withdrawal."
    end
    if m.withdraw and m.outcome and (m.withdraw.outcomeId ~= m.outcome.outcomeId or m.outcome.outcome ~= "WITHDRAWN") then
        return nil, "Conflicting withdrawal outcomes."
    end
    if offer.delivery == "PEER_RECEIPT_OBSERVED" and (role ~= "proposer" or state ~= "COMMITTED" or not m.ack) then
        return nil, "Peer receipt state has no matching acknowledgment."
    end
    if not plainTable(offer.history) or #offer.history < 1 or #offer.history > MAX_HISTORY then
        return nil, "Invalid shared history."
    end
    for index, event in pairs(offer.history) do
        if not integer(index) or index < 1 or index > #offer.history
            or not keys(event, {kind=true, at=true}) or not historyKinds[event.kind]
            or not integer(event.at) or event.at < offer.createdAt or event.at > offer.updatedAt then
            return nil, "Invalid shared history event."
        end
    end
    if countEntries(offer.history) ~= #offer.history then return nil, "Shared history must be a dense array." end
    if not plainTable(offer.processed) or countEntries(offer.processed) > MAX_PROCESSED then return nil, "Invalid shared deduplication records." end
    for messageId, wire in pairs(offer.processed) do
        if not identifier(messageId) or type(wire) ~= "string" then return nil, "Invalid processed shared message." end
        local c = codec()
        if type(c.Decode) ~= "function" then return nil, "The shared agreement codec is unavailable." end
        local message = c.Decode(wire)
        if not message or message.messageId ~= messageId or message.offerId ~= offerId
            or message.agreementId ~= offer.agreementId or message.terms ~= offer.terms then
            return nil, "Processed shared message does not match its offer."
        end
    end
    return true
end

function S.New(localName)
    if not localNameValid(localName) then return nil, "Enter a valid local character name." end
    return {version=1, localName=localName, serial=0, offers={}}
end

function S.Validate(store)
    if not keys(store, {version=true, localName=true, serial=true, offers=true})
        or store.version ~= 1 or not localNameValid(store.localName)
        or not integer(store.serial) or store.serial > MAX_SERIAL or not plainTable(store.offers)
        or countEntries(store.offers) > S.MAX_OFFERS then return nil, "Invalid shared agreement store." end
    local agreements = {}
    for offerId, offer in pairs(store.offers) do
        local ok, err = validateOffer(offer, offerId, store.localName)
        if not ok then return nil, err end
        if agreements[offer.agreementId] then return nil, "Agreement identifier is reused." end
        agreements[offer.agreementId] = true
    end
    return true
end

local function begin(store, now)
    local ok, err = S.Validate(store)
    if not ok then return nil, err end
    if not integer(now) then return nil, "A valid integer timestamp is required." end
    return copy(store)
end

local function checkTime(offer, now)
    if now < offer.updatedAt then return nil, "The timestamp precedes the last shared event." end
    return true
end

local function event(offer, kind, now)
    offer.updatedAt = now
    offer.history[#offer.history+1] = {kind=kind, at=now}
end

local function nextID(store, prefix)
    if store.serial >= MAX_SERIAL then return nil, "Shared identifier capacity reached." end
    store.serial = store.serial + 1
    return prefix .. string.format("%.0f", store.serial)
end

local function message(store, offer, kind, fields)
    local id, err = nextID(store, "m")
    if not id then return nil, err end
    local result = {version=1, kind=kind, messageId=id, agreementId=offer.agreementId,
        offerId=offer.offerId, revision=1, terms=offer.terms}
    for key, value in pairs(fields or {}) do result[key] = value end
    local ok, problem = validateMessage(result)
    if not ok then return nil, problem end
    return result
end

local function actions(store, offer, outgoing)
    if not outgoing then return {} end
    local terms = parseTerms(offer.terms)
    local peer = offer.role == "proposer" and terms.recipient or terms.proposer
    return {{target=peer, message=copy(outgoing)}}
end

local function finish(store, outgoing)
    local ok, err = S.Validate(store)
    if not ok then return nil, err end
    return store, outgoing or {}
end

local function capacity(store, agreementId, offerId)
    if store.offers[offerId] then return nil, "Offer identifier already exists." end
    for _, offer in pairs(store.offers) do
        if offer.agreementId == agreementId then return nil, "Agreement identifier already exists." end
    end
    if countEntries(store.offers) >= S.MAX_OFFERS then return nil, "Shared offer capacity reached; existing records were retained." end
    return true
end

local function newOffer(agreementId, offerId, terms, role, state, consent, now)
    return {agreementId=agreementId, offerId=offerId, revision=1, terms=terms,
        role=role, state=state, consent=consent, delivery="NONE", createdAt=now,
        updatedAt=now, messages={}, history={}, processed={}}
end

function S.Propose(store, terms, agreementId, offerId, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    if not identifier(agreementId) or not identifier(offerId) then return nil, "Invalid agreement or offer identifier." end
    local canonical, problem = canonicalTerms(terms)
    if not canonical then return nil, problem end
    local parsed = parseTerms(canonical)
    if parsed.proposer ~= store.localName then return nil, "Only the named proposer can send this offer." end
    local ok, reason = capacity(result, agreementId, offerId)
    if not ok then return nil, reason end
    local offer = newOffer(agreementId, offerId, canonical, "proposer", "OFFER_OPEN", "PROPOSE", now)
    offer.messages.propose, err = message(result, offer, "PROPOSE")
    if not offer.messages.propose then return nil, err end
    offer.delivery = "QUEUED"
    event(offer, "OFFER_SENT", now)
    result.offers[offerId] = offer
    return finish(result, actions(result, offer, offer.messages.propose))
end

local function getOffer(store, offerId)
    if not identifier(offerId) or not store.offers[offerId] then return nil, "Unknown shared offer." end
    return store.offers[offerId]
end

function S.Accept(store, offerId, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    local offer, problem = getOffer(result, offerId)
    if not offer then return nil, problem end
    if offer.role ~= "recipient" or offer.state ~= "OFFER_RECEIVED" then return nil, "Only a current received offer can be accepted." end
    local ok, reason = checkTime(offer, now)
    if not ok then return nil, reason end
    local acceptanceId
    acceptanceId, err = nextID(result, "a")
    if not acceptanceId then return nil, err end
    offer.messages.accept, err = message(result, offer, "ACCEPT", {acceptanceId=acceptanceId})
    if not offer.messages.accept then return nil, err end
    offer.consent, offer.state, offer.delivery = "ACCEPT", "ACCEPT_PENDING", "QUEUED"
    event(offer, "ACCEPTED_LOCALLY", now)
    return finish(result, actions(result, offer, offer.messages.accept))
end

function S.Decline(store, offerId, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    local offer, problem = getOffer(result, offerId)
    if not offer then return nil, problem end
    if offer.role ~= "recipient" or offer.state ~= "OFFER_RECEIVED" then return nil, "Only a current received offer can be declined." end
    local ok, reason = checkTime(offer, now)
    if not ok then return nil, reason end
    offer.messages.decline, err = message(result, offer, "DECLINE")
    if not offer.messages.decline then return nil, err end
    offer.consent, offer.state, offer.delivery = "DECLINE", "DECLINE_PENDING", "QUEUED"
    event(offer, "DECLINED_LOCALLY", now)
    return finish(result, actions(result, offer, offer.messages.decline))
end

local function makeOutcome(store, offer, outcome, now)
    local outcomeId, err = nextID(store, "o")
    if not outcomeId then return nil, err end
    if outcome == "WITHDRAWN" then
        offer.messages.withdraw, err = message(store, offer, "WITHDRAW", {outcomeId=outcomeId})
        if not offer.messages.withdraw then return nil, err end
    end
    offer.messages.outcome, err = message(store, offer, "OUTCOME", {outcomeId=outcomeId, outcome=outcome})
    if not offer.messages.outcome then return nil, err end
    offer.state, offer.delivery = outcome, "QUEUED"
    event(offer, outcome, now)
    return true
end

function S.Withdraw(store, offerId, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    local offer, problem = getOffer(result, offerId)
    if not offer then return nil, problem end
    if offer.role ~= "proposer" or offer.state ~= "OFFER_OPEN" then return nil, "Only an open uncommitted proposal can be withdrawn." end
    local ok, reason = checkTime(offer, now)
    if not ok then return nil, reason end
    ok, err = makeOutcome(result, offer, "WITHDRAWN", now)
    if not ok then return nil, err end
    return finish(result, actions(result, offer, offer.messages.withdraw))
end

local function response(offer)
    if offer.state == "PAUSED" then return nil end
    local m = offer.messages
    if offer.role == "proposer" then return m.commit or m.outcome or m.propose end
    if offer.state == "COMMITTED" then return m.ack end
    if offer.state == "ACCEPT_PENDING" then return m.accept end
    if offer.state == "DECLINE_PENDING" then return m.decline end
    return nil
end

local function replay(store, offer)
    return finish(store, actions(store, offer, response(offer)))
end

local function remember(offer, incoming)
    local wire, err = encode(incoming)
    if not wire then return nil, err end
    if not offer.processed[incoming.messageId] and countEntries(offer.processed) >= MAX_PROCESSED then
        return nil, "Shared deduplication capacity reached."
    end
    offer.processed[incoming.messageId] = wire
    return true
end

local function validatePeer(offer, localName, sender, incoming)
    local terms = parseTerms(offer.terms)
    local expected = offer.role == "proposer" and terms.recipient or terms.proposer
    if sender ~= expected or sender == localName then return nil, "Message sender is not this offer's peer." end
    if incoming.agreementId ~= offer.agreementId or incoming.revision ~= offer.revision or incoming.terms ~= offer.terms then
        return nil, "Shared offer identifier or exact terms conflict; explicit review is required."
    end
    return true
end

function S.Receive(store, sender, incoming, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    local ok, problem = validateMessage(incoming)
    if not ok then return nil, problem end
    local terms, reason = parseTerms(incoming.terms)
    if not terms then return nil, reason end
    local offer = result.offers[incoming.offerId]
    if not offer then
        if incoming.kind ~= "PROPOSE" then return nil, "Unknown shared offer; local consent cannot be reconstructed from a peer message." end
        if sender ~= terms.proposer or terms.recipient ~= result.localName or sender == result.localName then
            return nil, "Proposal sender or recipient does not match this character."
        end
        ok, err = capacity(result, incoming.agreementId, incoming.offerId)
        if not ok then return nil, err end
        offer = newOffer(incoming.agreementId, incoming.offerId, incoming.terms,
            "recipient", "OFFER_RECEIVED", "NONE", now)
        offer.messages.propose = copy(incoming)
        event(offer, "OFFER_RECEIVED", now)
        ok, err = remember(offer, incoming)
        if not ok then return nil, err end
        result.offers[incoming.offerId] = offer
        return finish(result)
    end
    ok, err = validatePeer(offer, result.localName, sender, incoming)
    if not ok then return nil, err end
    local remoteKind = offer.role == "proposer"
        and (incoming.kind == "ACCEPT" or incoming.kind == "ACK" or incoming.kind == "DECLINE" or incoming.kind == "STATUS")
        or offer.role == "recipient"
        and (incoming.kind == "PROPOSE" or incoming.kind == "COMMIT" or incoming.kind == "WITHDRAW" or incoming.kind == "OUTCOME" or incoming.kind == "STATUS")
    if not remoteKind then return nil, "Message kind is not valid for this peer's role." end
    -- Exact and semantic duplicates are handled before guards for new states.
    local previous = offer.processed[incoming.messageId]
    if previous then
        local wire = encode(incoming)
        if previous ~= wire then return nil, "Message identifier was reused with different contents." end
        if incoming.kind == "ACK" or incoming.kind == "OUTCOME" or incoming.kind == "WITHDRAW" then return finish(result) end
        return replay(result, offer)
    end
    local saved = offer.messages[incoming.kind:lower()]
    if saved then
        if sameSemantic(saved, incoming) then
            if incoming.kind == "ACK" or incoming.kind == "OUTCOME" or incoming.kind == "WITHDRAW" then return finish(result) end
            return replay(result, offer)
        end
        return nil, "A shared semantic identifier or outcome conflicts with the retained record."
    end
    -- WITHDRAW and the OUTCOME sent in response to a crossing ACCEPT express
    -- the same recorded decision, even when those two envelopes are reordered.
    if offer.state == "WITHDRAWN" and (incoming.kind == "WITHDRAW"
        or (incoming.kind == "OUTCOME" and incoming.outcome == "WITHDRAWN")) then
        local outcome = offer.messages.withdraw or offer.messages.outcome
        if outcome and outcome.outcomeId == incoming.outcomeId then return finish(result) end
        return nil, "Withdrawal outcome identifier conflicts with the retained record."
    end
    if incoming.kind == "STATUS" then return replay(result, offer) end
    if offer.state == "PAUSED" then return nil, "Shared offer is paused; review fresh terms and use a new offer identifier." end
    ok, err = checkTime(offer, now)
    if not ok then return nil, err end
    local m, outgoing = offer.messages
    if incoming.kind == "PROPOSE" then
        return nil, "A proposal cannot replace an existing offer."
    elseif incoming.kind == "ACCEPT" then
        if offer.role ~= "proposer" then return nil, "Only the proposer can receive acceptance." end
        if offer.state == "WITHDRAWN" or offer.state == "DECLINED" then return replay(result, offer) end
        if offer.state ~= "OFFER_OPEN" then return nil, "Acceptance is not valid in the current shared state." end
        local commitId
        commitId, err = nextID(result, "c")
        if not commitId then return nil, err end
        m.accept = copy(incoming)
        m.commit, err = message(result, offer, "COMMIT", {acceptanceId=incoming.acceptanceId, commitId=commitId})
        if not m.commit then return nil, err end
        offer.state, offer.delivery = "COMMITTED", "QUEUED"
        event(offer, "COMMITTED", now)
        outgoing = m.commit
    elseif incoming.kind == "COMMIT" then
        if offer.role ~= "recipient" or offer.state ~= "ACCEPT_PENDING" or offer.consent ~= "ACCEPT" or not m.accept
            or incoming.acceptanceId ~= m.accept.acceptanceId then
            return nil, "No matching local acceptance exists; explicit review is required."
        end
        m.commit = copy(incoming)
        m.ack, err = message(result, offer, "ACK", {acceptanceId=incoming.acceptanceId, commitId=incoming.commitId})
        if not m.ack then return nil, err end
        offer.state, offer.delivery = "COMMITTED", "QUEUED"
        event(offer, "COMMITTED", now)
        outgoing = m.ack
    elseif incoming.kind == "ACK" then
        if offer.role ~= "proposer" or offer.state ~= "COMMITTED" or not m.commit
            or incoming.acceptanceId ~= m.commit.acceptanceId or incoming.commitId ~= m.commit.commitId then
            return nil, "Acknowledgment does not match a retained commit."
        end
        m.ack = copy(incoming)
        offer.delivery = "PEER_RECEIPT_OBSERVED"
        event(offer, "PEER_RECEIPT", now)
    elseif incoming.kind == "DECLINE" then
        if offer.role ~= "proposer" then return nil, "Only the proposer can receive a decline." end
        if terminal[offer.state] then return replay(result, offer) end
        if offer.state ~= "OFFER_OPEN" then return nil, "Decline is not valid in the current shared state." end
        m.decline = copy(incoming)
        ok, err = makeOutcome(result, offer, "DECLINED", now)
        if not ok then return nil, err end
        outgoing = m.outcome
    elseif incoming.kind == "WITHDRAW" or incoming.kind == "OUTCOME" then
        if offer.role ~= "recipient" or terminal[offer.state] then return nil, "Terminal shared outcome conflicts with the retained state." end
        if not pending[offer.state] then return nil, "Unexpected terminal shared outcome." end
        local outcome = incoming.kind == "WITHDRAW" and "WITHDRAWN" or incoming.outcome
        if outcome == "DECLINED" and (offer.state ~= "DECLINE_PENDING" or not m.decline) then
            return nil, "Declined outcome has no matching local decline."
        end
        if incoming.kind == "WITHDRAW" then m.withdraw = copy(incoming) else m.outcome = copy(incoming) end
        offer.state, offer.delivery = outcome, "NONE"
        event(offer, outcome, now)
    else return nil, "Unsupported shared message." end
    ok, err = remember(offer, incoming)
    if not ok then return nil, err end
    return finish(result, actions(result, offer, outgoing))
end

function S.Pause(store, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    for _, offer in pairs(result.offers) do
        if pending[offer.state] then
            local ok, problem = checkTime(offer, now)
            if not ok then return nil, problem end
            offer.pausedFrom, offer.state, offer.delivery = offer.state, "PAUSED", "RETRY_PAUSED"
            event(offer, "PAUSED", now)
        end
    end
    return finish(result)
end

-- Resume only the exact pending state already backed by retained local consent.
-- No terms, semantic identifiers, or acceptance decisions are manufactured.
-- Recovery/tombstone gates belong to the service and must be checked first.
function S.Resume(store, offerId, now)
    local result,err=begin(store,now)
    if not result then return nil,err end
    local offer,problem=getOffer(result,offerId)
    if not offer then return nil,problem end
    if offer.state~="PAUSED" then return nil,"Only a paused shared offer can resume." end
    local ok,timeError=checkTime(offer,now)
    if not ok then return nil,timeError end
    if #offer.history>=MAX_HISTORY then return nil,"Shared history capacity reached; the offer remains paused." end
    offer.state,offer.pausedFrom=offer.pausedFrom,nil
    offer.delivery=offer.state=="OFFER_RECEIVED" and "NONE" or "QUEUED"
    event(offer,"RESUMED",now)
    local valid,validationError=S.Validate(result)
    if not valid then return nil,validationError end
    return replay(result,offer)
end

function S.Retry(store, offerId, now)
    local result, err = begin(store, now)
    if not result then return nil, err end
    local offer, problem = getOffer(result, offerId)
    if not offer then return nil, problem end
    if offer.state == "PAUSED" then return nil, "Paused shared offers require fresh explicit review and new identifiers." end
    return replay(result, offer)
end

function S.Snapshot(store, offerId)
    local ok, err = S.Validate(store)
    if not ok then return nil, err end
    if offerId ~= nil then
        local offer, problem = getOffer(store, offerId)
        if not offer then return nil, problem end
        return copy(offer)
    end
    return copy(store)
end
