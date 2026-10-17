-- Synthetic bookkeeping only: this projection must never touch live client
-- APIs, saved variables, a transport, or a clock.
local results = {}
local function test(label, run)
    local ok, err = pcall(run)
    if not ok then error(label .. ": " .. tostring(err), 0) end
    results[#results+1] = label
end
local function equal(a, b) assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a)) end
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
local forbidden = {IOUDB=true, CreateFrame=true, time=true, GetTime=true,
    SendChatMessage=true, SendAddonMessage=true, C_ChatInfo=true, C_Timer=true}
local secret
local env = setmetatable({issecretvalue=function(value) return value == secret and secret ~= nil end},
    {__index=function(_, key) assert(not forbidden[key], "projection accessed live API " .. key); return _G[key] end})
local ns = {}
for _, file in ipairs({"ledger.lua", "shared_codec.lua", "player_summary.lua"}) do
    local chunk = assert(loadstring(assert(IOU_SOURCES[file]), "@IOU/" .. file))
    setfenv(chunk, env); chunk("IOU", ns)
end
local L, C, P = ns.Ledger, ns.SharedCodec, ns.PlayerSummary
local function add(db, player, direction, kind, amount, label)
    return assert(L.Add(db, {player=player or "Birch Vale", direction=direction or "owed",
        kind=kind or "money", amount=amount or 10000, label=label}, 100))
end
local function build(db, overview, who) return assert(P.Build(db, overview, who or "Birch Vale")) end
local function overview(owner) return {localName=owner or "Amber Stone", offers={}, balances={}} end
local function original(data, id, options)
    options = options or {}
    local terms = {protocol=1, kind="GOLD_OBLIGATION", proposer="Amber Stone", recipient="Birch Vale",
        debtor=options.debtor or "Birch Vale", creditor=options.creditor or "Amber Stone",
        amountCopper=10000, dueUTC=0, note=""}
    for key, value in pairs(options.terms or {}) do terms[key] = value end
    local role = data.localName == terms.proposer and "proposer" or "recipient"
    local offer = {offerId=id, role=role, state=options.state or "COMMITTED",
        delivery=options.delivery or "PEER_RECEIPT_OBSERVED", terms=assert(C.CanonicalTerms(terms))}
    data.offers[#data.offers+1] = offer
    local confirmed = offer.state == "COMMITTED" and (role == "recipient" or offer.delivery == "PEER_RECEIPT_OBSERVED")
    data.balances[id] = {confirmed=confirmed, remainingCopper=options.remaining or 10000,
        awaitingAck=options.awaitingAck, pendingOfferId=options.pendingOfferId}
    return offer
end

test("player summary matches complete names with only whitespace and ASCII case normalization", function()
    equal(P.NameKey("  BIRCH  Vale "), "birch vale")
    equal(P.NameKey("Birch\tVale"), nil)
    local db = L.New(); add(db, "Birch Vale"); add(db, "Birch Other"); add(db, "Birch-Vale"); add(db, "Birch Vale-Realm")
    local value = build(db, nil, " birch  VALE ")
    equal(value.player, "birch VALE"); equal(value.count, 1); equal(value.personal.owed.money, 10000)
    equal(build(db, nil, "Birch").count, 0)
end)

test("player summary preserves UTF-8 identity instead of guessing Unicode case folds", function()
    local db = L.New(); add(db, "Bj\195\184rn Bl\195\165b\195\166r"); add(db, "Bj\195\152rn Bl\195\165b\195\166r", "owed", "money", 20000)
    equal(build(db, nil, "bj\195\184rn bl\195\165b\195\166r").personal.owed.money, 10000)
end)

test("player summary rejects absent, malformed, linked, long, and secret identity values", function()
    for _, who in ipairs({false, 42, {}, "", "   ", "Birch\0Vale", "|Hplayer:Birch Vale|hBirch|h", string.rep("a", 97)}) do
        local value, err = P.Build(L.New(), nil, who)
        equal(value, nil); assert(type(err) == "string")
        equal(P.NameKey(who), nil)
    end
    secret = "Birch Vale"; equal(P.NameKey(secret), nil); equal(P.Build(L.New(), nil, secret), nil); secret = nil
end)

test("player summary keeps both debt directions and personal versus shared totals separate", function()
    local db = L.New(); add(db, nil, "owed", "money", 10000); add(db, nil, "owe", "money", 5000)
    local data = overview(); original(data, "shared", {remaining=6000})
    local value = build(db, data)
    equal(value.personal.owed.money, 10000); equal(value.personal.owe.money, 5000)
    equal(value.shared.owed.money, 6000); equal(value.shared.owe.money, 0); equal(value.count, 3)
end)

test("player summary replays repayments reversals and cancellations instead of original amounts", function()
    local db = L.New(); local partial = add(db); local cancelled = add(db); local settled = add(db)
    assert(L.Pay(db, partial.id, 4000, "", 101)); assert(L.Pay(db, partial.id, 1000, "", 102))
    assert(L.Reverse(db, partial.id, 1, "", 103)); assert(L.Cancel(db, cancelled.id, "", 104))
    assert(L.Settle(db, settled.id, "", 105))
    local value = build(db); equal(value.count, 1); equal(value.personal.owed.money, 9000)
    assert(L.Restore(db, cancelled.id, "", 106)); equal(build(db).personal.owed.money, 19000)
end)

test("player summary follows amended owner and item labels without matching stale metadata", function()
    local db = L.New(); local entry = add(db, "Other Person", "owed", "item", 4, "Old cloth")
    assert(L.Amend(db, entry.id, {player="Birch Vale", label="New cloth", note="", due=0}, "", 101))
    local value = build(db); equal(value.personal.owed.items[1].label, "New cloth"); equal(value.personal.owed.items[1].quantity, 4)
    equal(build(db, nil, "Other Person").count, 0)
end)

test("player summary aggregates identical item labels but preserves literal item variants and directions", function()
    local db = L.New(); local entry = add(db, nil, "owed", "item", 12, "Linen Cloth")
    assert(L.Pay(db, entry.id, 2, "", 101)); add(db, nil, "owed", "item", 3, "Linen Cloth")
    add(db, nil, "owe", "item", 2, "Linen Cloth")
    add(db, nil, "owed", "item", 1, "|Hitem:123:1|h[Cloth]|h")
    add(db, nil, "owed", "item", 1, "|Hitem:123:2|h[Cloth]|h")
    local value = build(db)
    equal(#value.personal.owed.items, 3); equal(value.personal.owed.items[1].label, "Linen Cloth")
    equal(value.personal.owed.items[1].quantity, 13); equal(value.personal.owe.items[1].quantity, 2)
    assert(value.personal.owed.items[2].label ~= value.personal.owed.items[3].label)
end)

test("player summary keeps favor units separate and label ordering deterministic", function()
    local db = L.New(); add(db, nil, "owed", "favor", 2, "Quest runs"); add(db, nil, "owed", "favor", 3, "Dungeon runs")
    add(db, nil, "owed", "favor", 4, "Quest runs"); add(db, nil, "owed", "item", 1, "Quest runs")
    local value = build(db)
    equal(value.personal.owed.favors[1].label, "Dungeon runs"); equal(value.personal.owed.favors[2].quantity, 6)
    equal(value.personal.owed.items[1].quantity, 1)
end)

test("player summary rejects malformed personal history rather than showing an invented balance", function()
    local db = L.New(); local entry = add(db); entry.events={{id=1, type="payment", amount=10001, note="", at=101}}
    local value, err = P.Build(db, nil, "Birch Vale"); equal(value, nil); assert(type(err) == "string")
end)

test("player summary accumulates maximum legal personal balances without clipping or overflow", function()
    local db = L.New()
    for _=1,3 do add(db, nil, "owed", "money", L.MAX_AMOUNT) end
    equal(build(db).personal.owed.money, L.MAX_AMOUNT * 3)
end)

test("player summary counts only effective shared originals and uses the confirmed remaining balance", function()
    local data = overview()
    original(data, "active", {remaining=6000}); original(data, "settled", {remaining=0})
    for _, state in ipairs({"OFFER_OPEN", "OFFER_RECEIVED", "ACCEPT_PENDING", "DECLINE_PENDING", "DECLINED", "WITHDRAWN", "PAUSED"}) do
        original(data, state, {state=state})
    end
    original(data, "awaiting", {delivery="WAITING_FOR_PEER"})
    local value = build(L.New(), data); equal(value.shared.owed.money, 6000); equal(value.count, 1)
end)

test("player summary recognizes recipient commitment and either original debt direction", function()
    local data = overview("Birch Vale")
    original(data, "owed", {debtor="Amber Stone", creditor="Birch Vale", remaining=7500, delivery="NONE"})
    original(data, "owe", {remaining=2500, delivery="NONE"})
    local value = build(L.New(), data, "Amber Stone")
    equal(value.shared.owed.money, 7500); equal(value.shared.owe.money, 2500); equal(value.count, 2)
end)

test("player summary does not match similar shared surnames or inferred realm identities", function()
    local data = overview(); original(data, "similar", {terms={recipient="Birch Other", debtor="Birch Other"}})
    equal(build(L.New(), data).count, 0); equal(build(L.New(), data, "Birch").count, 0)
end)

test("player summary preserves prior confirmed balance during a pending payment without counting child offers", function()
    local data = overview(); original(data, "parent", {remaining=10000, awaitingAck=true, pendingOfferId="child"})
    local terms = {protocol=2, kind="GOLD_PAYMENT", proposer="Amber Stone", recipient="Birch Vale",
        debtor="Birch Vale", creditor="Amber Stone", amountCopper=4000, dueUTC=0, note="",
        parentAgreementId="g-parent", parentOfferId="parent", parentCommitId="c-parent",
        parentTerms=data.offers[1].terms, baseRevision=0, baseChain=assert(C.CanonicalChain({})), reversesId=""}
    data.offers[#data.offers+1] = {offerId="child", state="COMMITTED", role="proposer", delivery="WAITING_FOR_PEER", terms=assert(C.CanonicalTerms(terms))}
    local value = build(L.New(), data); equal(value.shared.owed.money, 10000); equal(value.count, 1)
end)

test("player summary isolates unavailable or corrupt shared records from valid personal reminders", function()
    local db = L.New(); add(db)
    local variants={false, {}, overview(), overview(), overview(), overview()}
    variants[3].offers[2]={}; original(variants[4], "bad"); variants[4].balances.bad.remainingCopper=0/0
    original(variants[5], "bad"); variants[5].offers[1].role="recipient"
    original(variants[6], "bad", {delivery="NONE"}); variants[6].balances.bad.confirmed=true
    for _, data in ipairs(variants) do
        local value = build(db, data); equal(value.personal.owed.money, 10000); equal(value.shared.owed.money, 0)
        assert(type(value.sharedError) == "string" and #value.sharedError > 0)
    end
end)

test("player summary rejects secret shared amounts and never returns partial shared totals on failure", function()
    local data = overview(); original(data, "good", {remaining=1000}); original(data, "secret", {remaining=6000})
    secret=6000
    local value = build(L.New(), data); equal(value.shared.owed.money, 0); equal(value.count, 0); assert(value.sharedError)
    secret=nil
end)

test("player summary bounds the shared offer list and rejects duplicate record identities", function()
    local data = overview()
    for index=1,32 do original(data, "offer-" .. index) end
    local value = build(L.New(), data); equal(value.shared.owed.money, 320000); equal(value.count, 32)
    original(data, "offer-33")
    value = build(L.New(), data); equal(value.shared.owed.money, 0); assert(value.sharedError)
    data = overview(); original(data, "duplicate"); original(data, "duplicate")
    value = build(L.New(), data); equal(value.shared.owed.money, 0); assert(value.sharedError)
end)

test("player summary rejects invalid shared amounts without borrowing another agreement balance", function()
    for _, amount in ipairs({-1, 1.5, math.huge, 10001}) do
        local data = overview(); original(data, "first"); original(data, "bad")
        data.balances.bad.remainingCopper=amount
        local value = build(L.New(), data); equal(value.shared.owed.money, 0); assert(value.sharedError)
    end
    local data = overview(); original(data, "missing"); data.balances.missing=nil
    local value = build(L.New(), data); equal(value.shared.owed.money, 0); assert(value.sharedError)
end)

test("player summary inputs and returned records are independent and read-only", function()
    local db = L.New(); add(db, nil, "owed", "item", 2, "Cloth"); local data = overview(); original(data, "shared")
    local beforeDb, beforeShared = copy(db), copy(data)
    local first, second = build(db, data), build(db, data)
    first.personal.owed.items[1].quantity=100; first.shared.owed.money=0
    assert(same(db, beforeDb) and same(data, beforeShared)); equal(second.personal.owed.items[1].quantity, 2)
    equal(second.shared.owed.money, 10000)
end)

return results
