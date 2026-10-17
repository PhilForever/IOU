-- No real client, clock, database, inventory, or networking is available here.
local results = {}
local function test(label, run)
    local ok, err = pcall(run)
    if not ok then error(label .. ": " .. tostring(err), 0) end
    results[#results+1] = label
end
local function equal(a, b) assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a)) end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}; for key, child in pairs(value) do out[key] = copy(child) end; return out
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local forbidden = {IOUDB=true, CreateFrame=true, time=true, GetTime=true,
    SendChatMessage=true, SendAddonMessage=true, C_ChatInfo=true, C_Timer=true}
local secret
local env = setmetatable({issecretvalue=function(value) return secret ~= nil and value == secret end},
    {__index=function(_, key) assert(not forbidden[key], "matcher accessed live API " .. key); return _G[key] end})
local ns = {}
for _, file in ipairs({"ledger.lua", "shared_codec.lua", "player_summary.lua", "trade_matching.lua"}) do
    local chunk = assert(loadstring(assert(IOU_SOURCES[file]), "@IOU/" .. file))
    setfenv(chunk, env); chunk("IOU", ns)
end
local L, C, M = ns.Ledger, ns.SharedCodec, ns.TradeMatching
local function link(id, payload, name)
    return "|cffffffff|Hitem:" .. id .. (payload or "") .. "|h[" .. (name or "Linen Cloth") .. "]|h|r"
end
local function item(id, quantity, payload, name)
    return {itemID=id or 2589, quantity=quantity or 3, name=name or "Linen Cloth", link=link(id or 2589, payload, name)}
end
local function side(money, items) return {money=money or 0, items=items or {}} end
local function transfer(incoming, outgoing, peer)
    return {peer=peer or "Birch Vale", incoming=incoming or side(), outgoing=outgoing or side()}
end
local function add(db, direction, kind, amount, label, peer)
    return assert(L.Add(db, {player=peer or "Birch Vale", direction=direction or "owed",
        kind=kind or "money", amount=amount or 10000, label=label}, 100))
end
local function plan(db, data, overview) return assert(M.Plan(db, overview, data)) end
local function overview() return {localName="Amber Stone", offers={}, balances={}} end
local function shared(data, id, options)
    options = options or {}
    local terms = {protocol=1, kind="GOLD_OBLIGATION", proposer="Amber Stone", recipient="Birch Vale",
        debtor=options.debtor or "Birch Vale", creditor=options.creditor or "Amber Stone",
        amountCopper=10000, dueUTC=0, note=""}
    local offer = {offerId=id, state=options.state or "COMMITTED", role="proposer",
        delivery=options.delivery or "PEER_RECEIPT_OBSERVED", terms=assert(C.CanonicalTerms(terms))}
    data.offers[#data.offers+1] = offer
    data.balances[id] = {confirmed=offer.state=="COMMITTED" and offer.delivery=="PEER_RECEIPT_OBSERVED",
        remainingCopper=options.remaining or 10000}
end

test("trade matcher applies a clear partial incoming gold repayment without changing its inputs", function()
    local db=L.New(); local entry=add(db); local data=transfer(side(3000))
    local beforeDb,beforeData=copy(db),copy(data); local value=plan(db,data)
    equal(#value.actions,1); equal(value.actions[1].entryID,entry.id); equal(value.actions[1].amount,3000)
    equal(value.actions[1].expectedBalance,10000); equal(value.actions[1].direction,"owed")
    equal(#value.pending,0); equal(#value.unmatched,0); assert(same(db,beforeDb) and same(data,beforeData))
end)

test("trade matcher caps repayments and leaves excess unassigned without creating debt", function()
    local db=L.New(); add(db); local value=plan(db,transfer(side(15000)))
    equal(value.actions[1].amount,10000); equal(value.unmatched[1].amount,5000)
    equal(#db.entries,1); equal(#db.entries[1].events,0)
    value=plan(L.New(),transfer(side(15000))); equal(#value.actions,0); equal(value.unmatched[1].amount,15000)
end)

test("trade matcher treats outgoing gold as repayment of you owe and never nets opposing debts", function()
    local db=L.New(); add(db); local entry=add(db,"owe","money",5000)
    local value=plan(db,transfer(nil,side(2000)))
    equal(#value.actions,1); equal(value.actions[1].entryID,entry.id); equal(value.actions[1].direction,"owe")
    equal(value.actions[1].amount,2000); equal(L.Balance(db.entries[1]),10000)
end)

test("trade matcher requires exact full peer names with ASCII normalization only", function()
    local db=L.New(); add(db,nil,nil,7000,nil,"Birch Other"); add(db,nil,nil,6000,nil,"Birch-Vale")
    add(db,nil,nil,5000,nil,"Birch Vale-Realm"); local correct=add(db)
    local value=plan(db,transfer(side(1000),nil,"  BIRCH  Vale "))
    equal(value.actions[1].entryID,correct.id)
    equal(#plan(db,transfer(side(1000),nil,"Birch")).actions,0)
    local unicode="Bj\195\184rn Bl\195\165b\195\166r"; db=L.New(); add(db,nil,nil,nil,nil,unicode)
    equal(#plan(db,transfer(side(1),nil,unicode)).actions,1)
    equal(#plan(db,transfer(side(1),nil,"Bj\195\152rn Bl\195\165b\195\166r")).actions,0)
end)

test("trade matcher replays payments reversals cancellation and amendments before matching", function()
    local db=L.New(); local entry=add(db); assert(L.Pay(db,entry.id,3000,"",101))
    assert(L.Pay(db,entry.id,1000,"",102)); assert(L.Reverse(db,entry.id,2,"",103))
    equal(plan(db,transfer(side(9000))).actions[1].amount,7000)
    assert(L.Cancel(db,entry.id,"",104)); equal(#plan(db,transfer(side(1000))).actions,0)
    assert(L.Restore(db,entry.id,"",105)); assert(L.Amend(db,entry.id,{player="Other Person",label="",note="",due=0},"",106))
    equal(#plan(db,transfer(side(1000))).actions,0)
end)

test("trade matcher excludes settled and favor entries", function()
    local db=L.New(); local entry=add(db); assert(L.Settle(db,entry.id,"",101))
    add(db,"owed","favor",10,"Linen Cloth")
    local value=plan(db,transfer(side(10000,{item()})))
    equal(#value.actions,0); equal(#value.pending,0); equal(#value.unmatched,2)
end)

test("trade matcher makes multiple candidate IOUs an explicit allocation instead of guessing", function()
    local db=L.New(); add(db); add(db,nil,nil,20000)
    local value=plan(db,transfer(side(6000)))
    equal(#value.actions,0); equal(#value.pending,1); equal(value.pending[1].reason,"multiple_ious")
    equal(value.pending[1].amount,6000); equal(#value.pending[1].candidates,2)
    equal(value.pending[1].candidates[1].entryID,1); equal(value.pending[1].candidates[2].entryID,2)
end)

test("trade matcher aggregates identical item stacks before applying one capped payment", function()
    local db=L.New(); add(db,"owed","item",5,"Linen Cloth")
    local value=plan(db,transfer(side(0,{item(2589,3),item(2589,4)})))
    equal(#value.actions,1); equal(value.actions[1].amount,5); equal(value.actions[1].asset,"item")
    equal(value.unmatched[1].amount,2); equal(value.unmatched[1].itemID,2589)
end)

test("trade matcher matches item payload independently of color display name and zero padding", function()
    local db=L.New(); add(db,"owed","item",8,"|Hitem:2589:0::0|h[Original name]|h")
    local value=plan(db,transfer(side(0,{item(2589,3,"::::", "Localized name")})))
    equal(#value.actions,1); equal(value.actions[1].amount,3); equal(value.actions[1].itemKey,"item:2589")
end)

test("trade matcher preserves populated enchant suffix and extended item fields for review", function()
    for _, variant in ipairs({":1", "::::::-7", ":::::::::123", "::::::::::::2:101:102"}) do
        local db=L.New(); add(db,"owed","item",8,link(2589,variant))
        local value=plan(db,transfer(side(0,{item(2589,3)})))
        equal(#value.actions,0); equal(value.pending[1].reason,"item_identity")
        equal(value.pending[1].candidates[1].entryID,1)
    end
end)

test("trade matcher never guesses that different item IDs with the same name repay one plain note", function()
    local db=L.New(); add(db,"owed","item",8,"Linen Cloth")
    local value=plan(db,transfer(side(0,{item(2589,3),item(2590,2)})))
    equal(#value.actions,0); equal(#value.pending,2)
    equal(value.pending[1].reason,"item_ambiguous"); equal(value.pending[2].reason,"item_ambiguous")
    equal(value.pending[1].candidates[1].entryID,1)
end)

test("trade matcher never guesses that multiple variants repay one plain item note", function()
    local db=L.New(); add(db,"owed","item",8,"Linen Cloth")
    local value=plan(db,transfer(side(0,{item(2589,3),item(2589,2,":1")})))
    equal(#value.actions,0); equal(#value.pending,2); equal(value.pending[1].reason,"item_ambiguous")
end)

test("trade matcher exact plain item descriptions do not use substring or ASCII case guesses", function()
    local db=L.New(); add(db,"owed","item",8,"linen cloth"); add(db,"owed","item",8,"Cloth")
    local value=plan(db,transfer(side(0,{item()})))
    equal(#value.actions,0); equal(#value.pending,0); equal(value.unmatched[1].amount,3)
end)

test("trade matcher keeps two-way purchases barter and mixed assets pending in their entirety", function()
    local db=L.New(); add(db); add(db,"owe","item",5,"Linen Cloth")
    local value=plan(db,transfer(side(5000),side(0,{item()})))
    equal(#value.actions,0); equal(#value.pending,2); equal(#value.unmatched,0)
    equal(value.pending[1].reason,"mixed_trade"); equal(value.pending[1].amount,5000)
    equal(value.pending[2].reason,"mixed_trade"); equal(value.pending[2].amount,3)
    value=plan(db,transfer(side(5000),side(5000))); equal(#value.actions,0); equal(#value.pending,1)
    equal(value.pending[1].direction,"owed"); equal(#value.unmatched,1); equal(value.unmatched[1].direction,"owe")
end)

test("trade matcher leaves service and enchantment payments for review even in a one-way trade", function()
    local db=L.New(); add(db); local data=transfer(side(5000)); data.service=true
    local value=plan(db,data); equal(#value.actions,0); equal(value.pending[1].reason,"trade_service")
    data.service="yes"; equal(M.Plan(db,nil,data),nil)
end)

test("trade matcher keeps ordinary purchases barter and service fees quiet without matching IOUs", function()
    local db=L.New(); add(db,nil,nil,nil,nil,"Unrelated Person")
    local purchase=transfer(side(0,{item()}),side(5000))
    local value=plan(db,purchase)
    equal(#value.actions,0); equal(#value.pending,0); equal(#value.unmatched,2)
    equal(value.unmatched[1].asset,"item"); equal(value.unmatched[2].asset,"money")
    local service=transfer(side(5000)); service.service=true
    value=plan(db,service); equal(#value.actions,0); equal(#value.pending,0)
    equal(#value.unmatched,1); equal(value.unmatched[1].amount,5000)
end)

test("trade matcher reviews only matching assets within mixed and service transfers", function()
    local db=L.New(); add(db,"owed","item",5,"Linen Cloth")
    local data=transfer(side(0,{item(),item(2,2,nil,"Other Material")}),side(5000))
    local value=plan(db,data)
    equal(#value.actions,0); equal(#value.pending,1); equal(value.pending[1].itemID,2589)
    equal(value.pending[1].reason,"mixed_trade"); equal(#value.unmatched,2)
    data=transfer(side(5000,{item()})); data.service=true
    value=plan(db,data); equal(#value.actions,0); equal(#value.pending,1)
    equal(value.pending[1].reason,"trade_service"); equal(value.unmatched[1].asset,"money")
end)

test("trade matcher does not silently dismiss mixed or service gold when shared data is unreadable", function()
    local db=L.New(); local data=transfer(side(0,{item()}),side(5000))
    local value=plan(db,data,{})
    equal(#value.actions,0); equal(#value.pending,1); equal(value.pending[1].asset,"money")
    equal(value.pending[1].reason,"mixed_trade"); equal(#value.unmatched,1)
    data=transfer(side(5000)); data.service=true
    value=plan(db,data,{}); equal(#value.pending,1); equal(value.pending[1].reason,"trade_service")
end)

test("trade matcher matches independent one-way gold and item assets without double spending", function()
    local db=L.New(); add(db); add(db,"owed","item",9,"Linen Cloth"); add(db,"owed","item",5,"Copper Ore")
    local value=plan(db,transfer(side(3000,{item(2589,3),item(2770,2,nil,"Copper Ore")})))
    equal(#value.actions,3); equal(value.actions[1].entryID,1); equal(value.actions[2].entryID,2)
    equal(value.actions[3].entryID,3); equal(value.actions[2].amount,3); equal(value.actions[3].amount,2)
end)

test("trade matcher leaves shared-only repayments pending and never mutates the shared overview", function()
    local data=overview(); shared(data,"shared"); local before=copy(data)
    local value=plan(L.New(),transfer(side(3000)),data)
    equal(#value.actions,0); equal(value.pending[1].reason,"shared_confirmation")
    equal(value.pending[1].candidates[1].source,"shared"); equal(value.pending[1].candidates[1].offerID,"shared")
    assert(same(data,before))
end)

test("trade matcher refuses duplicate source assumptions when personal and shared debts coexist", function()
    local db=L.New(); add(db); local data=overview(); shared(data,"shared")
    local value=plan(db,transfer(side(3000)),data)
    equal(#value.actions,0); equal(value.pending[1].reason,"source_conflict")
    equal(#value.pending[1].candidates,2); equal(value.pending[1].candidates[1].source,"personal")
    equal(value.pending[1].candidates[2].source,"shared")
end)

test("trade matcher ignores unaccepted paused settled and unacknowledged original shared offers", function()
    for _, options in ipairs({{state="OFFER_OPEN"},{state="PAUSED"},{remaining=0},{delivery="WAITING_FOR_PEER"}}) do
        local db=L.New(); add(db); local data=overview(); shared(data,"shared",options)
        local value=plan(db,transfer(side(3000)),data)
        equal(#value.actions,1); equal(#value.pending,0)
    end
end)

test("trade matcher only treats confirmed shared gold in the matching direction as a conflict", function()
    local db=L.New(); add(db); local data=overview()
    shared(data,"reverse",{debtor="Amber Stone",creditor="Birch Vale"})
    local value=plan(db,transfer(side(3000)),data); equal(#value.actions,1); equal(#value.pending,0)
    value=plan(db,transfer(nil,side(3000)),data); equal(value.pending[1].reason,"shared_confirmation")
end)

test("trade matcher fails closed for gold when shared data is corrupt but keeps safe item matching", function()
    local db=L.New(); add(db); add(db,"owed","item",5,"Linen Cloth")
    for _, data in ipairs({false,{},overview()}) do
        if type(data)=="table" and data.offers then shared(data,"broken"); data.balances.broken=nil end
        local value=plan(db,transfer(side(3000,{item()})),data)
        equal(#value.actions,1); equal(value.actions[1].asset,"item")
        equal(value.pending[1].reason,"shared_unavailable"); equal(value.pending[1].amount,3000)
    end
end)

test("trade matcher safely rejects malformed identities tables amounts and item links", function()
    local db=L.New(); add(db)
    local invalid={false,{},transfer(side(-1)),transfer(side(1.5)),transfer(side(math.huge)),
        transfer(side(0,{item(2589,0)})),transfer(side(0,{item(2589,-1)})),
        transfer(side(1),nil,"Birch\0Vale"),transfer(side(1),nil,"|Hplayer:Birch Vale|hBirch|h")}
    local bad=transfer(side(0,{item()})); bad.incoming.items[1].link=link(2590); invalid[#invalid+1]=bad
    bad=transfer(side(0,{item()})); bad.incoming.items[1].link="|Hitem:2589:x|h[Cloth]|h"; invalid[#invalid+1]=bad
    bad=transfer(side()); bad.incoming.items[2]=item(); invalid[#invalid+1]=bad
    bad=transfer(side()); bad.incoming.items=setmetatable({},{}) ; invalid[#invalid+1]=bad
    for _, data in ipairs(invalid) do
        local value,err=M.Plan(db,nil,data); equal(value,nil); assert(type(err)=="string")
    end
    local broken=copy(db); broken.entries[1].amount=0/0
    equal(M.Plan(broken,nil,transfer(side(1))),nil)
end)

test("trade matcher rejects secret fields and numeric overflow without leaking partial decisions", function()
    local db=L.New(); add(db)
    secret="Birch Vale"; equal(M.Plan(db,nil,transfer(side(1))),nil); secret=nil
    secret=37; equal(M.Plan(db,nil,transfer(side(37))),nil); secret=nil
    local data=transfer(side(0,{item(2589,9007199254740991),item(2589,1)}))
    equal(M.Plan(db,nil,data),nil)
    data=transfer(side()); for index=1,65 do data.incoming.items[index]=item() end
    equal(M.Plan(db,nil,data),nil)
end)

test("trade matcher produces deterministic detached decisions independent of stack order", function()
    local db=L.New(); add(db,"owed","item",8,"Linen Cloth"); add(db,"owed","item",5,"Copper Ore")
    local first=plan(db,transfer(side(0,{item(2589,3),item(2770,2,nil,"Copper Ore"),item(2589,1)})))
    local second=plan(db,transfer(side(0,{item(2589,1),item(2589,3),item(2770,2,nil,"Copper Ore")})))
    assert(same(first,second)); first.actions[1].amount=999
    equal(second.actions[1].amount,4); equal(L.Balance(db.entries[1]),8)
end)

return results
