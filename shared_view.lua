local _, IOU = ...
local V = {}
IOU.SharedView = V

-- Presentation only: callers supply a detached, validated service overview.
-- Nothing here reads saved data, the client clock, or a connection.
local categories = {inbox=true, agreements=true, waiting=true, history=true, all=true}
local priority = {inbox=1, agreements=2, waiting=3, history=4}
local states = {OFFER_OPEN=true, OFFER_RECEIVED=true, ACCEPT_PENDING=true,
    DECLINE_PENDING=true, COMMITTED=true, DECLINED=true, WITHDRAWN=true, PAUSED=true}
local labels = {GOLD_OBLIGATION="Gold agreement", GOLD_PAYMENT="Payment", GOLD_CORRECTION="Correction"}

local function plain(value)
    return type(value) == "table" and getmetatable(value) == nil
end
local function integer(value)
    return type(value) == "number" and value >= 0 and value <= 9007199254740991
        and value == math.floor(value)
end
local function asciiLower(value)
    return (value:gsub("[A-Z]", function(letter) return string.char(letter:byte() + 32) end))
end
local function trim(value)
    return (value:gsub("^[ \t\r\n\v\f]+", ""):gsub("[ \t\r\n\v\f]+$", ""))
end
local function emptyCounts()
    return {inbox=0, agreements=0, waiting=0, history=0, all=0}
end
local function effective(offer)
    return offer.state == "COMMITTED"
        and (offer.role == "recipient" or offer.delivery == "PEER_RECEIPT_OBSERVED")
end
local function category(offer, terms, balance)
    if offer.state == "PAUSED" then return offer.localClosed and "history" or "inbox" end
    if offer.state == "OFFER_RECEIVED" then return "inbox" end
    if offer.state == "DECLINED" or offer.state == "WITHDRAWN" then return "history" end
    if offer.state ~= "COMMITTED" or not effective(offer) then return "waiting" end
    if terms.kind ~= "GOLD_OBLIGATION" then return "history" end
    if balance.remainingCopper == 0 and not balance.pendingOfferId then return "history" end
    return "agreements"
end
local function matches(row, query)
    if query == "" then return true end
    -- Match fields independently: a query cannot accidentally span two names.
    -- Only ASCII letters fold; UTF-8 bytes, punctuation, and Lua pattern
    -- characters retain their exact literal meaning.
    local terms = row.terms
    for _, value in ipairs({row.peer, terms.proposer, terms.recipient,
        terms.debtor, terms.creditor, terms.note, terms.kind, row.label}) do
        if asciiLower(value):find(query, 1, true) then return true end
    end
    return false
end
local function order(left, right)
    if left.category ~= right.category then return priority[left.category] < priority[right.category] end
    local a, b = left.offer, right.offer
    if left.category == "inbox" then
        if a.createdAt ~= b.createdAt then return a.createdAt < b.createdAt end
        if a.updatedAt ~= b.updatedAt then return a.updatedAt < b.updatedAt end
    else
        if a.updatedAt ~= b.updatedAt then return a.updatedAt > b.updatedAt end
        if a.createdAt ~= b.createdAt then return a.createdAt > b.createdAt end
    end
    return a.offerId < b.offerId
end

function V.DefaultFilter(projection)
    local counts = plain(projection) and projection.counts
    if plain(counts) then
        for _, name in ipairs({"inbox", "agreements", "waiting", "history"}) do
            if type(counts[name]) == "number" and counts[name] > 0 then return name end
        end
    end
    return "all"
end

function V.Build(overview, filter, search)
    if not plain(overview) or not plain(overview.offers) or not plain(overview.balances)
        or type(overview.localName) ~= "string" or overview.localName == ""
        or (overview.peer ~= nil and type(overview.peer) ~= "string") then
        return nil, "The shared agreement overview is unavailable."
    end
    if search ~= nil and type(search) ~= "string" then return nil, "Enter text to search shared agreements." end
    local codec = IOU.SharedCodec
    if type(codec) ~= "table" or type(codec.ParseTerms) ~= "function" then
        return nil, "The shared agreement codec is unavailable."
    end
    local count = 0
    for index in pairs(overview.offers) do
        if not integer(index) or index < 1 or index > #overview.offers then
            return nil, "The shared overview must contain a complete offer list."
        end
        count = count + 1
    end
    if count ~= #overview.offers or count > (IOU.Shared and IOU.Shared.MAX_OFFERS or 32) then
        return nil, "The shared overview must contain a complete offer list."
    end
    local query = trim(search or "")
    local folded = asciiLower(query)
    local projection = {rows={}, counts=emptyCounts(), matchedCounts=emptyCounts(),
        needsReview=0, total=count, filteredTotal=0, search=query}
    local rows, seen = {}, {}
    for _, offer in ipairs(overview.offers) do
        if not plain(offer) or type(offer.offerId) ~= "string" or offer.offerId == ""
            or seen[offer.offerId] or not states[offer.state]
            or not integer(offer.createdAt) or not integer(offer.updatedAt) or offer.updatedAt < offer.createdAt
            or (offer.localClosed ~= nil and type(offer.localClosed) ~= "boolean") then
            return nil, "The shared overview contains an invalid offer."
        end
        seen[offer.offerId] = true
        local terms, err = codec.ParseTerms(offer.terms)
        if not terms then return nil, err end
        local role = terms.proposer == overview.localName and "proposer"
            or (terms.recipient == overview.localName and "recipient" or nil)
        if not role or offer.role ~= role or (offer.state == "OFFER_RECEIVED" and role ~= "recipient")
            or (offer.localClosed and offer.state ~= "PAUSED") then
            return nil, "The shared overview belongs to another character or has an invalid role."
        end
        local balance = overview.balances[offer.offerId]
        if terms.kind == "GOLD_OBLIGATION" and offer.state == "COMMITTED" then
            if not plain(balance) or type(balance.confirmed) ~= "boolean"
                or balance.confirmed ~= effective(offer) or not integer(balance.remainingCopper)
                or balance.remainingCopper > terms.amountCopper then
                return nil, "The confirmed shared agreement balance is unavailable."
            end
        end
        local kind = labels[terms.kind]
        if not kind then return nil, "The shared overview contains an unknown agreement kind." end
        local row = {offer=offer, terms=terms,
            peer=role == "proposer" and terms.recipient or terms.proposer,
            kind=terms.kind, label=kind, amountCopper=terms.amountCopper,
            direction=terms.debtor == overview.localName and "You owe" or "Owed to you"}
        row.category = category(offer, terms, balance)
        if terms.kind == "GOLD_OBLIGATION" and offer.state == "COMMITTED"
            and balance.confirmed then
            row.remainingCopper = balance.remainingCopper
        end
        projection.counts[row.category] = projection.counts[row.category] + 1
        projection.counts.all = projection.counts.all + 1
        if matches(row, folded) then
            rows[#rows+1] = row
            projection.matchedCounts[row.category] = projection.matchedCounts[row.category] + 1
            projection.matchedCounts.all = projection.matchedCounts.all + 1
        end
    end
    projection.needsReview = projection.counts.inbox
    projection.filter = categories[filter] and filter or V.DefaultFilter(projection)
    for _, row in ipairs(rows) do
        if projection.filter == "all" or projection.filter == row.category then
            projection.rows[#projection.rows+1] = row
        end
    end
    table.sort(projection.rows, order)
    projection.filteredTotal = #projection.rows
    return projection
end
