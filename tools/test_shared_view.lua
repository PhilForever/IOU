-- Pure board projections use synthetic names and canonical protocol terms.
-- No live database, messages, client time, or native frames may be consulted.
local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results+1] = name
end
local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for key, item in pairs(value) do out[key] = copy(item) end; return out
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, item in pairs(a) do if not same(item, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local blocked = {IOUDB=true, CreateFrame=true, time=true, GetTime=true,
    SendAddonMessage=true, SendChatMessage=true, C_ChatInfo=true, C_Timer=true}
local env = setmetatable({}, {__index=function(_, key)
    assert(not blocked[key], "presentation accessed live API " .. key)
    return _G[key]
end})
local ns = {}
for _, name in ipairs({"shared_codec.lua", "shared_view.lua"}) do
    local chunk = assert(loadstring(assert(IOU_SOURCES[name]), "@IOU/" .. name))
    setfenv(chunk, env); chunk("IOU", ns)
end
local C, V = assert(ns.SharedCodec), assert(ns.SharedView)
local function original(changes)
    local terms = {protocol=1, kind="GOLD_OBLIGATION", proposer="Amber Stone", recipient="Birch Vale",
        debtor="Amber Stone", creditor="Birch Vale", amountCopper=10000, dueUTC=0, note=""}
    for key, value in pairs(changes or {}) do terms[key] = value end
    return terms
end
local function event(changes)
    local parent = original()
    local terms = {protocol=2, kind="GOLD_PAYMENT", proposer=parent.proposer, recipient=parent.recipient,
        debtor=parent.debtor, creditor=parent.creditor, amountCopper=4000, dueUTC=0, note="",
        parentAgreementId="g-parent", parentOfferId="o-parent", parentCommitId="c-parent",
        parentTerms=assert(C.CanonicalTerms(parent)), baseRevision=0,
        baseChain=assert(C.CanonicalChain({})), reversesId=""}
    for key, value in pairs(changes or {}) do terms[key] = value end
    return terms
end
local function overview(localName)
    return {offers={}, balances={}, localName=localName or "Amber Stone"}
end
local function add(data, id, state, opts)
    opts = opts or {}
    local terms = opts.terms or original()
    local role = terms.proposer == data.localName and "proposer" or "recipient"
    local offer = {offerId=id, terms=assert(C.CanonicalTerms(terms)), role=role, state=state,
        createdAt=opts.createdAt or 100, updatedAt=opts.updatedAt or opts.createdAt or 100,
        delivery=opts.delivery or "NONE", localClosed=opts.localClosed}
    data.offers[#data.offers+1] = offer
    if terms.kind == "GOLD_OBLIGATION" then
        data.balances[id] = {confirmed=state == "COMMITTED" and
            (role == "recipient" or offer.delivery == "PEER_RECEIPT_OBSERVED"),
            remainingCopper=opts.remainingCopper or terms.amountCopper, pendingOfferId=opts.pendingOfferId}
    end
    return offer
end
local function build(data, filter, search) return assert(V.Build(data, filter or "all", search)) end
local function reject(data, filter, search)
    local value, problem = V.Build(data, filter, search)
    equal(value, nil); assert(type(problem) == "string" and #problem > 0)
end

test("shared view separates review, active agreements, waiting, and history without counting proposed debt", function()
    local data = overview()
    add(data, "incoming", "OFFER_RECEIVED", {terms=original({proposer="Birch Vale", recipient="Amber Stone"})})
    add(data, "active", "COMMITTED", {delivery="PEER_RECEIPT_OBSERVED", remainingCopper=6000})
    add(data, "outgoing", "OFFER_OPEN")
    add(data, "declined", "DECLINED")
    local projection = build(data)
    equal(projection.total, 4); equal(projection.filteredTotal, 4)
    equal(projection.counts.inbox, 1); equal(projection.counts.agreements, 1)
    equal(projection.counts.waiting, 1); equal(projection.counts.history, 1)
    equal(projection.rows[1].remainingCopper, nil); equal(projection.rows[2].remainingCopper, 6000)
    equal(projection.rows[3].remainingCopper, nil)
end)

test("shared view requires a proposer receipt but recognizes a recipient commitment", function()
    local proposer = overview()
    add(proposer, "awaiting", "COMMITTED", {delivery="WAITING_FOR_PEER"})
    local p = build(proposer)
    equal(p.rows[1].category, "waiting"); equal(p.rows[1].remainingCopper, nil)
    local recipient = overview("Birch Vale")
    add(recipient, "received", "COMMITTED", {delivery="QUEUED"})
    local r = build(recipient)
    equal(r.rows[1].category, "agreements"); equal(r.rows[1].remainingCopper, 10000)
end)

test("shared view keeps settled parents with pending corrections active and archives completed balances", function()
    local data = overview()
    add(data, "settled", "COMMITTED", {delivery="PEER_RECEIPT_OBSERVED", remainingCopper=0})
    add(data, "correction-pending", "COMMITTED", {delivery="PEER_RECEIPT_OBSERVED",
        remainingCopper=0, pendingOfferId="correction"})
    local projection = build(data)
    equal(projection.counts.agreements, 1); equal(projection.counts.history, 1)
    equal(projection.rows[1].offer.offerId, "correction-pending")
    equal(projection.rows[1].remainingCopper, 0); equal(projection.rows[2].remainingCopper, 0)
end)

test("shared view preserves original amounts and names while using the confirmed remaining balance", function()
    local data = overview()
    add(data, "owed", "COMMITTED", {delivery="PEER_RECEIPT_OBSERVED", remainingCopper=1250,
        terms=original({debtor="Birch Vale", creditor="Amber Stone"})})
    local row = build(data).rows[1]
    equal(row.amountCopper, 10000); equal(row.remainingCopper, 1250)
    equal(row.peer, "Birch Vale"); equal(row.direction, "Owed to you")
    equal(row.kind, "GOLD_OBLIGATION"); equal(row.label, "Gold agreement")
    equal(row.terms.proposer, "Amber Stone")
end)

test("shared view places committed payment events in history only after local effectiveness", function()
    local proposer = overview()
    add(proposer, "payment-waiting", "COMMITTED", {terms=event(), delivery="WAITING_FOR_PEER"})
    add(proposer, "payment-effective", "COMMITTED", {terms=event(), delivery="PEER_RECEIPT_OBSERVED"})
    local projection = build(proposer)
    equal(projection.counts.waiting, 1); equal(projection.counts.history, 1)
    equal(projection.rows[1].remainingCopper, nil)
    equal(projection.rows[2].label, "Payment")
    local recipient = overview("Birch Vale")
    add(recipient, "received-payment", "COMMITTED", {terms=event(), delivery="QUEUED"})
    equal(build(recipient).rows[1].category, "history")
end)

test("shared view includes interrupted offers from either role in the review inbox", function()
    local data = overview()
    add(data, "paused-outgoing", "PAUSED")
    add(data, "paused-incoming", "PAUSED", {terms=original({proposer="Birch Vale", recipient="Amber Stone"})})
    add(data, "reviewed", "PAUSED", {localClosed=true})
    local projection = build(data)
    equal(projection.counts.inbox, 2); equal(projection.needsReview, 2)
    equal(projection.counts.history, 1)
end)

test("shared view keeps pending acceptance and decline in waiting rather than the review inbox", function()
    local data = overview("Birch Vale")
    add(data, "accept", "ACCEPT_PENDING")
    add(data, "decline", "DECLINE_PENDING")
    local projection = build(data)
    equal(projection.counts.waiting, 2); equal(projection.needsReview, 0)
end)

test("shared view searches literal fields with ASCII folding and trims only outer whitespace", function()
    local data = overview()
    add(data, "literal", "OFFER_OPEN", {terms=original({note="Bring [a+b].  Two spaces"})})
    add(data, "other", "OFFER_OPEN", {terms=original({recipient="Cedar Hill", creditor="Cedar Hill"})})
    equal(build(data, "all", " \tBIRCH VALE\n").filteredTotal, 1)
    equal(build(data, "all", "[a+b].").filteredTotal, 1)
    equal(build(data, "all", ".*").filteredTotal, 0)
    equal(build(data, "all", "Two  spaces").filteredTotal, 0)
    equal(build(data, "all", "gold_obligation").filteredTotal, 2)
    equal(build(data, "all", "Gold agreement").filteredTotal, 2)
    equal(build(data, "all", " ").search, "")
end)

test("shared view preserves Unicode byte identity without claiming Unicode case folding", function()
    local data = overview()
    add(data, "unicode", "OFFER_OPEN", {terms=original({note="Bj\195\184rn bl\195\165b\195\166r"})})
    equal(build(data, "all", "Bj\195\184rn").filteredTotal, 1)
    equal(build(data, "all", "bj\195\184RN").filteredTotal, 1)
    equal(build(data, "all", "BJ\195\152RN").filteredTotal, 0)
end)

test("shared view search never hides global tab counts or the needs review badge", function()
    local data = overview()
    add(data, "incoming", "OFFER_RECEIVED", {terms=original({proposer="Birch Vale", recipient="Amber Stone"})})
    add(data, "outgoing", "OFFER_OPEN", {terms=original({note="specific"})})
    local projection = build(data, "inbox", "specific")
    equal(projection.counts.all, 2); equal(projection.counts.inbox, 1)
    equal(projection.needsReview, 1); equal(projection.filteredTotal, 0)
    equal(projection.matchedCounts.all, 1); equal(projection.matchedCounts.waiting, 1)
end)

test("shared view defaults to the first useful tab without overriding explicit filters", function()
    equal(V.DefaultFilter({counts={inbox=1,agreements=2,waiting=3,history=4}}), "inbox")
    equal(V.DefaultFilter({counts={inbox=0,agreements=2,waiting=3,history=4}}), "agreements")
    equal(V.DefaultFilter({counts={waiting=3,history=4}}), "waiting")
    equal(V.DefaultFilter({counts={history=4}}), "history")
    equal(V.DefaultFilter({counts={}}), "all")
    local data = overview(); add(data, "outgoing", "OFFER_OPEN")
    equal(assert(V.Build(data)).filter, "waiting")
    equal(assert(V.Build(data, "unknown")).filter, "waiting")
    equal(build(data, "inbox").filter, "inbox")
end)

test("shared view sorts oldest reviews first and newer activity first with deterministic ties", function()
    local data = overview()
    local incoming = original({proposer="Birch Vale",recipient="Amber Stone"})
    add(data, "in-z", "OFFER_RECEIVED", {terms=incoming, createdAt=100})
    add(data, "out-old", "OFFER_OPEN", {createdAt=1,updatedAt=2})
    add(data, "in-a", "OFFER_RECEIVED", {terms=incoming, createdAt=100})
    add(data, "in-old", "OFFER_RECEIVED", {terms=incoming, createdAt=1,updatedAt=100})
    add(data, "out-new", "OFFER_OPEN", {createdAt=1,updatedAt=200})
    local projection = build(data)
    local names = {}; for _, row in ipairs(projection.rows) do names[#names+1] = row.offer.offerId end
    equal(table.concat(names, ","), "in-old,in-a,in-z,out-new,out-old")
end)

test("shared view preserves input tables, explicit peer context, and full records across repeated filters", function()
    local data = overview(); data.peer="Cedar Hill"
    add(data, "other-peer", "OFFER_OPEN", {terms=original({note="Complete note remains available"})})
    local before = copy(data)
    for _, filter in ipairs({"inbox","agreements","waiting","history","all"}) do
        build(data, filter, "birch")
    end
    assert(same(data, before), "presentation mutated its source overview")
    local row = build(data).rows[1]
    equal(row.peer, "Birch Vale"); equal(row.terms.note, "Complete note remains available")
    equal(row.offer.terms, data.offers[1].terms)
end)

test("shared view rejects malformed or foreign overviews instead of showing misleading balances", function()
    reject(nil); reject({offers={},balances={}})
    reject(setmetatable(overview(), {})); reject(overview(), "all", false)
    local data = overview(); local offer = add(data, "a", "COMMITTED", {delivery="PEER_RECEIPT_OBSERVED"})
    data.balances.a.confirmed=false; reject(data)
    data.balances.a.confirmed=true; data.balances.a.remainingCopper=10001; reject(data)
    data.balances.a.remainingCopper=10000; offer.role="recipient"; reject(data)
    offer.role="proposer"; offer.terms="broken"; reject(data)
    local duplicate=overview(); add(duplicate,"a","OFFER_OPEN"); add(duplicate,"a","OFFER_OPEN"); reject(duplicate)
    local hole=overview(); add(hole,"a","OFFER_OPEN"); hole.offers[3]=copy(hole.offers[1]); reject(hole)
    local capacity=overview(); for index=1,33 do add(capacity,"offer-"..index,"OFFER_OPEN") end; reject(capacity)
end)

return results
