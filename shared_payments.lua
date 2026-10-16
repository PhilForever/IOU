local _, IOU = ...
local P = {}
IOU.SharedPayments = P
local S, C = IOU.Shared, IOU.SharedCodec
local live = {OFFER_OPEN=true, OFFER_RECEIVED=true, ACCEPT_PENDING=true, DECLINE_PENDING=true}

local function eventTerms(terms)
    return terms and (terms.kind == "GOLD_PAYMENT" or terms.kind == "GOLD_CORRECTION")
end
local function handshakeCapacity(terms)
    local canonical, err = C.CanonicalTerms(terms)
    if not canonical then return nil, err end
    -- An offer that fits PROPOSE must also fit every subsequent consent
    -- envelope. Reserve the entire documented identifier budget in advance.
    local id=string.rep("x",C.MAX_ID_BYTES or 64)
    -- COMMIT has both semantic IDs and the longest kind among envelopes with
    -- both IDs; PROPOSE, ACCEPT, ACK and terminal outcomes are strictly smaller.
    local message={version=1,kind="COMMIT",messageId=id,agreementId=id,offerId=id,
        revision=1,terms=canonical,acceptanceId=id,commitId=id}
    local encoded, problem=C.Encode(message)
    if not encoded then return nil,"Shared event history is too large for the complete acceptance handshake: "..tostring(problem) end
    return true
end
local function effective(offer)
    return offer.state == "COMMITTED" and (offer.role == "recipient" or offer.delivery == "PEER_RECEIPT_OBSERVED")
end
local function parentBinding(parent, original, terms)
    return parent and original and original.kind == "GOLD_OBLIGATION" and parent.state == "COMMITTED"
        and parent.messages.commit and terms.parentAgreementId == parent.agreementId
        and terms.parentOfferId == parent.offerId and terms.parentCommitId == parent.messages.commit.commitId
        and terms.parentTerms == parent.terms and terms.proposer == original.proposer
        and terms.recipient == original.recipient and terms.debtor == original.debtor
        and terms.creditor == original.creditor
end
local function row(offer, terms)
    return {kind=terms.kind, agreementId=offer.agreementId, offerId=offer.offerId,
        commitId=offer.messages.commit.commitId, amountCopper=terms.amountCopper,
        note=terms.note, reversesId=terms.reversesId}
end
local function reconstructed(parent, original, item, prefix, base)
    return {protocol=2, kind=item.kind, proposer=original.proposer, recipient=original.recipient,
        debtor=original.debtor, creditor=original.creditor, amountCopper=item.amountCopper,
        dueUTC=0, note=item.note, parentAgreementId=parent.agreementId,
        parentOfferId=parent.offerId, parentCommitId=parent.messages.commit.commitId,
        parentTerms=parent.terms, baseRevision=#prefix, baseChain=base,
        reversesId=item.reversesId}
end
local function addFinancial(terms, remaining, payments, reversed, id)
    if terms.kind == "GOLD_PAYMENT" then
        if terms.amountCopper > remaining then return nil, "A shared payment exceeds the remaining gold." end
        payments[id] = terms.amountCopper
        return remaining - terms.amountCopper
    end
    local amount = payments[terms.reversesId]
    if not amount or reversed[terms.reversesId] or amount ~= terms.amountCopper then
        return nil, "A correction must reverse one uncorrected confirmed payment in full."
    end
    reversed[terms.reversesId] = true
    return remaining + amount
end
local function viewValidated(store, parentId, closedPaused)
    closedPaused = closedPaused or {}
    local parent = store.offers[parentId]
    local original = parent and C.ParseTerms(parent.terms)
    if not original or original.kind ~= "GOLD_OBLIGATION" then return nil, "Choose an original shared gold agreement." end
    local all, confirmed = {}, {}
    for _, offer in pairs(store.offers) do
        local terms = C.ParseTerms(offer.terms)
        if eventTerms(terms) and terms.parentOfferId == parentId then
            local fits, capacityError=handshakeCapacity(terms)
            if not fits then return nil,capacityError end
            if not parentBinding(parent,original,terms) then return nil, "Shared payment parent identity or exact terms conflict." end
            if not effective(parent) then return nil, "The sequencer has not observed acknowledgment of the parent agreement." end
            local item = {offer=offer, terms=terms}
            all[#all+1]=item
            if effective(offer) then confirmed[#confirmed+1]=item end
        end
    end
    local function order(a,b)
        if a.terms.baseRevision ~= b.terms.baseRevision then return a.terms.baseRevision < b.terms.baseRevision end
        if a.offer.createdAt ~= b.offer.createdAt then return a.offer.createdAt < b.offer.createdAt end
        return a.offer.offerId < b.offer.offerId
    end
    table.sort(all,order); table.sort(confirmed,order)
    local chain, payments, reversed, applied = {}, {}, {}, {}
    local prefixes={[0]=C.CanonicalChain({})}
    local remaining = original.amountCopper
    for _, item in ipairs(confirmed) do
        local offer, terms = item.offer, item.terms
        local base, problem = prefixes[#chain]
        if not base then return nil, problem end
        if terms.baseRevision ~= #chain or terms.baseChain ~= base then return nil, "Confirmed shared events do not form one exact ordered chain." end
        local exact=C.CanonicalTerms(reconstructed(parent,original,row(offer,terms),chain,base))
        if exact~=offer.terms then return nil,"Shared event chain does not match locally acknowledged exact records." end
        local nextBalance
        nextBalance, problem = addFinancial(terms,remaining,payments,reversed,offer.offerId)
        if not nextBalance then return nil, problem end
        remaining = nextBalance
        chain[#chain+1]=row(offer,terms)
        prefixes[#chain],problem=C.CanonicalChain(chain)
        if not prefixes[#chain] then return nil,problem end
        applied[offer.offerId]=true
    end
    local baseChain, problem = prefixes[#chain]
    if not baseChain then return nil, problem end
    local pending, awaitingAck, events = nil, false, {}
    for _, item in ipairs(all) do
        local offer, terms = item.offer, item.terms
        if terms.baseRevision > #chain then return nil, "Shared event history claims locally missing consent." end
        local exactBase = prefixes[terms.baseRevision]
        if exactBase ~= terms.baseChain then return nil, "Shared event base differs from the exact retained history." end
        -- Prefix bytes were built only from locally effective records whose
        -- complete exact terms and commit IDs were reconstructed above.
        local unresolved = not applied[offer.offerId] and (live[offer.state]
            or offer.state == "COMMITTED" or (offer.state == "PAUSED" and not closedPaused[offer.offerId]))
        if unresolved then
            if pending then return nil, "More than one unresolved shared event targets this agreement." end
            if terms.baseChain ~= baseChain then return nil, "An unresolved shared event is based on a stale balance." end
            -- Validate an in-flight event against a copy of the current balance;
            -- proposing or accepting it never changes the effective balance.
            local trialPayments, trialReversed = {}, {}
            for id, amount in pairs(payments) do trialPayments[id]=amount end
            for id, value in pairs(reversed) do trialReversed[id]=value end
            local amount, financialError = addFinancial(terms,remaining,trialPayments,trialReversed,offer.offerId)
            if not amount then return nil, financialError end
            pending=offer.offerId
            awaitingAck=offer.state == "COMMITTED" and offer.role == "proposer"
        end
        events[#events+1]={offerId=offer.offerId, agreementId=offer.agreementId,
            kind=terms.kind, amountCopper=terms.amountCopper, note=terms.note,
            reversesId=terms.reversesId, state=offer.state, delivery=offer.delivery,
            effective=applied[offer.offerId] == true, reversed=reversed[offer.offerId] == true,
            localClosed=closedPaused[offer.offerId] ~= nil, createdAt=offer.createdAt}
    end
    local ready = effective(parent)
    local canPropose = parent.role == "proposer" and ready and pending == nil
    local reason
    if parent.role ~= "proposer" then reason="The original proposer records payments; the other player acknowledges them."
    elseif not ready then reason="Wait for commitment and the other player's acknowledgment of the original agreement."
    elseif pending then reason=awaitingAck and "Wait for the other player's acknowledgment of the latest event."
        or "Resolve or review the unfinished event before proposing another." end
    return {parentOfferId=parentId, originalCopper=original.amountCopper,
        paidCopper=original.amountCopper-remaining, remainingCopper=remaining,
        state=remaining == 0 and "SETTLED" or "OPEN", confirmed=ready,
        canPropose=canPropose, blockReason=reason, events=events,
        baseRevision=#chain, baseChain=baseChain, pendingOfferId=pending, awaitingAck=awaitingAck}
end

function P.View(store,parentId,closedPaused)
    local valid,err=S.Validate(store)
    if not valid then return nil,err end
    if closedPaused ~= nil and (type(closedPaused) ~= "table" or getmetatable(closedPaused) ~= nil) then return nil, "Invalid local review records." end
    return viewValidated(store,parentId,closedPaused)
end

function P.Validate(store, closedPaused)
    local valid, err = S.Validate(store)
    if not valid then return nil, err end
    if closedPaused ~= nil and (type(closedPaused) ~= "table" or getmetatable(closedPaused) ~= nil) then return nil, "Invalid local review records." end
    for _, offer in pairs(store.offers) do
        local terms = C.ParseTerms(offer.terms)
        if eventTerms(terms) then
            local parent = store.offers[terms.parentOfferId]
            local original = parent and C.ParseTerms(parent.terms)
            if not parentBinding(parent,original,terms) then return nil, "A shared financial event has no matching committed parent." end
        end
    end
    for id, offer in pairs(store.offers) do
        local terms = C.ParseTerms(offer.terms)
        if terms.kind == "GOLD_OBLIGATION" then
            local view, problem = viewValidated(store,id,closedPaused)
            if not view then return nil, problem end
        end
    end
    return true
end

local function build(store, parentId, kind, amount, note, reversesId, closedPaused)
    local view, err = P.View(store,parentId,closedPaused)
    if not view then return nil, err end
    if not view.canPropose then return nil, view.blockReason end
    local parent = store.offers[parentId]
    local original = C.ParseTerms(parent.terms)
    local value = {protocol=2, kind=kind, proposer=original.proposer, recipient=original.recipient,
        debtor=original.debtor, creditor=original.creditor, amountCopper=amount, dueUTC=0,
        note=note == nil and "" or note, parentAgreementId=parent.agreementId, parentOfferId=parentId,
        parentCommitId=parent.messages.commit.commitId, parentTerms=parent.terms,
        baseRevision=view.baseRevision, baseChain=view.baseChain, reversesId=reversesId or ""}
    local valid, problem = C.ValidateTerms(value)
    if not valid then return nil, problem end
    valid, problem = handshakeCapacity(value)
    if not valid then return nil, problem end
    return value
end
function P.BuildPayment(store,parentId,amountCopper,note,closedPaused)
    return build(store,parentId,"GOLD_PAYMENT",amountCopper,note,"",closedPaused)
end
function P.BuildCorrection(store,parentId,paymentId,reason,closedPaused)
    local view, err = P.View(store,parentId,closedPaused)
    if not view then return nil, err end
    -- Validate the supplied text before replacing a blank explanation. The
    -- resulting default becomes exact terms that both players must review.
    local original = C.ParseTerms(store.offers[parentId].terms)
    original.note = reason == nil and "" or reason
    local valid, problem = C.ValidateTerms(original)
    if not valid then return nil, problem end
    if not original.note:find("%S") then reason = "No reason provided" end
    local payment
    for _, event in ipairs(view.events) do
        if event.offerId == paymentId and event.kind == "GOLD_PAYMENT" and event.effective and not event.reversed then payment=event end
    end
    if not payment then return nil, "Choose one confirmed payment that has not already been corrected." end
    return build(store,parentId,"GOLD_CORRECTION",payment.amountCopper,reason,paymentId,closedPaused)
end

return P
