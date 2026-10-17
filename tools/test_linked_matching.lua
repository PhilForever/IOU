-- Explicit personal/Shared links identify the same debt without guessing.
local results={}
local function test(name,run)
    local ok,err=pcall(run); if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={}; for key,item in pairs(value) do result[key]=copy(item) end; return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function forbidden() error("linked projection invoked a game or persistence API") end
local env=setmetatable({time=forbidden,CreateFrame=forbidden,C_ChatInfo={SendAddonMessageLogged=forbidden}}, {__index=_G})
local ns={}
for _,file in ipairs({"ledger.lua","shared_codec.lua","player_summary.lua","trade_matching.lua"}) do
    local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file)); setfenv(chunk,env); chunk("IOU",ns)
end
local L,C,P,M=ns.Ledger,ns.SharedCodec,ns.PlayerSummary,ns.TradeMatching
local function link(id,payload,label)
    return "|cffffffff|Hitem:"..(id or 2589)..(payload or "").."|h["..(label or "Linen Cloth").."]|h|r"
end
local function add(db,options)
    options=options or {}
    return assert(L.Add(db,{player=options.player or "Birch Vale",kind=options.kind or "money",
        direction=options.direction or "owed",amount=options.amount or 20,label=options.label},100))
end
local function overview() return {localName="Amber Stone",offers={},balances={}} end
local function shared(data,id,options)
    options=options or {}; local item=options.kind=="item"; local peer=options.peer or "Birch Vale"
    local terms={protocol=item and 3 or 1,kind=item and "ITEM_OBLIGATION" or "GOLD_OBLIGATION",
        proposer="Amber Stone",recipient=peer,amountCopper=options.amount or 20,
        debtor=options.direction=="owe" and "Amber Stone" or peer,
        creditor=options.direction=="owe" and peer or "Amber Stone",dueUTC=0,note=""}
    if item then terms.itemKey,terms.itemName=options.itemKey or "item:2589",options.itemName or "Linen Cloth" end
    data.offers[#data.offers+1]={offerId=id,state="COMMITTED",role="proposer",delivery="PEER_RECEIPT_OBSERVED",
        terms=assert(C.CanonicalTerms(terms))}
    data.balances[id]={confirmed=true,remainingCopper=options.remaining or options.amount or 20}
    return terms
end
local function bind(data,entry,id,base)
    data.links=data.links or {}; data.links[entry.id]=id
    if base~=nil then data.linkBases=data.linkBases or {}; data.linkBases[entry.id]=base end
end
local function side(money,items) return {money=money or 0,items=items or {}} end
local function item(id,quantity,payload,label)
    return {itemID=id or 2589,quantity=quantity or 3,link=link(id,payload,label),name=label or "Linen Cloth"}
end
local function transfer(incoming,outgoing)
    return {peer="Birch Vale",incoming=incoming or side(),outgoing=outgoing or side()}
end
local function plan(db,data,value) return assert(M.Plan(db,data,value or transfer(side(3)))) end
local function summary(db,data) return assert(P.Build(db,data,"Birch Vale")) end

test("shared item summary separates material quantities from gold and keeps asset variants",function()
    local data=overview()
    shared(data,"gold",{amount=10000,remaining=7000})
    shared(data,"linen",{kind="item",remaining=12})
    shared(data,"linen-again",{kind="item",remaining=4,itemName="Localized linen"})
    shared(data,"variant",{kind="item",remaining=2,itemKey="item:2589:14"})
    shared(data,"owe",{kind="item",direction="owe",remaining=5})
    local value=summary(L.New(),data)
    assert(value.shared.owed.money==7000 and #value.shared.owed.items==2 and value.count==5)
    assert(value.shared.owed.items[1].quantity==16 and value.shared.owed.items[1].itemKey=="item:2589")
    assert(value.shared.owed.items[2].quantity==2 and value.shared.owe.items[1].quantity==5)
end)

test("shared-only item repayments need acknowledgment and never become personal actions",function()
    local data=overview(); shared(data,"cloth",{kind="item"})
    local value=plan(L.New(),data,transfer(side(0,{item()})))
    assert(#value.actions==0 and #value.pending==1 and value.pending[1].reason=="shared_confirmation")
    assert(value.pending[1].candidates[1].offerID=="cloth" and value.pending[1].candidates[1].itemKey=="item:2589")
end)

test("unlinked matching personal and shared items remain an explicit source conflict",function()
    local db=L.New(); add(db,{kind="item",label=link()}); local data=overview(); shared(data,"cloth",{kind="item"})
    local value=plan(db,data,transfer(side(0,{item()})))
    assert(#value.actions==0 and #value.pending==1 and value.pending[1].reason=="source_conflict")
    assert(#value.pending[1].candidates==2)
    local totals=summary(db,data)
    assert(totals.count==2 and totals.personal.owed.items[1].quantity==20 and totals.shared.owed.items[1].quantity==20)
end)

test("a verified gold link applies once to the personal entry and excludes its shared duplicate",function()
    local db=L.New(); local entry=add(db); local data=overview(); shared(data,"gold"); bind(data,entry,"gold")
    local value=plan(db,data)
    assert(#value.actions==1 and value.actions[1].entryID==entry.id and value.actions[1].amount==3)
    assert(#value.pending==0 and #value.unmatched==0)
    local totals=summary(db,data); assert(totals.count==1 and totals.personal.owed.money==20 and totals.shared.owed.money==0)
    assert(L.Pay(db,entry.id,3,"Trade",101))
    totals=summary(db,data); assert(totals.personal.owed.money==17 and totals.shared.owed.money==0)
    assert(data.balances.gold.remainingCopper==20,"the matcher wrote Shared balances")
end)

test("a verified item link uses canonical payload across hyperlink presentation and updates only personal",function()
    local db=L.New(); local entry=add(db,{kind="item",label=link(2589,":0:0","Different name")})
    local data=overview(); shared(data,"cloth",{kind="item"}); bind(data,entry,"cloth")
    local value=plan(db,data,transfer(side(0,{item()})))
    assert(#value.actions==1 and value.actions[1].entryID==entry.id and value.actions[1].amount==3 and #value.pending==0)
    local totals=summary(db,data); assert(totals.count==1 and #totals.shared.owed.items==0)
    assert(totals.personal.owed.items[1].quantity==20)
end)

test("links shared after an earlier partial repayment retain their exact baseline amount",function()
    local db=L.New(); local entry=add(db,{amount=20}); assert(L.Pay(db,entry.id,5,"Earlier",101))
    local data=overview(); shared(data,"remaining",{amount=15}); bind(data,entry,"remaining",5)
    assert(P.LinkedEntries(db,data).remaining==entry.id)
    local value=plan(db,data); assert(#value.actions==1 and #value.pending==0)
    assert(summary(db,data).shared.owed.money==0)
    data.linkBases=nil
    value=plan(db,data); assert(#value.actions==0 and value.pending[1].reason=="source_conflict")
end)

test("a settled linked personal IOU stays settled while its shared receipt is pending",function()
    local db=L.New(); local entry=add(db); local data=overview(); shared(data,"gold"); bind(data,entry,"gold")
    assert(L.Pay(db,entry.id,20,"Trade",101))
    local totals=summary(db,data); assert(totals.count==0 and totals.personal.owed.money==0 and totals.shared.owed.money==0)
    local value=plan(db,data)
    assert(#value.actions==0 and value.pending[1].reason=="shared_confirmation")
end)

test("cancelled linked entries cannot hide a still-active shared debt",function()
    local db=L.New(); local entry=add(db); local data=overview(); shared(data,"gold"); bind(data,entry,"gold")
    assert(L.Cancel(db,entry.id,"Cancelled",101))
    assert(P.LinkedEntries(db,data).gold==nil and summary(db,data).shared.owed.money==20)
    assert(plan(db,data).pending[1].reason=="shared_confirmation")
end)

test("malformed duplicate and stale link maps fail closed without hiding matching shared debt",function()
    for _,mutate in ipairs({
        function(data) data.links=false end,
        function(data) data.links=setmetatable({[1]="gold"},{}) end,
        function(data) data.links={["1"]="gold"} end,
        function(data) data.links={[1]="gold",[2]="gold"} end,
        function(data) data.links={[1000]="gold"} end,
        function(data) data.links={[1]="missing"} end,
        function(data) data.linkBases={[1]=-1} end,
        function(data) data.linkBases={[1]=1.5} end,
        function(data) data.linkBases={[2]=0} end,
        function(data) data.linkBases=setmetatable({[1]=0},{}) end,
    }) do
        local db=L.New(); local entry=add(db); local data=overview(); shared(data,"gold"); bind(data,entry,"gold")
        mutate(data)
        assert(summary(db,data).shared.owed.money==20)
        local value=plan(db,data); assert(#value.actions==0 and value.pending[1].reason=="source_conflict")
    end
end)

test("wrong peer direction amount and item identity bindings cannot suppress unrelated offers",function()
    for _,options in ipairs({{player="Other Player"},{direction="owe"},{amount=19},{kind="item",label=link()},
        {kind="favor",label="Quest help"}}) do
        local db=L.New(); local entry=add(db,options); local data=overview(); shared(data,"gold"); bind(data,entry,"gold")
        assert(P.LinkedEntries(db,data).gold==nil and summary(db,data).shared.owed.money==20)
    end
    for _,label in ipairs({"Linen Cloth",link(2589,":14"),link(2592,nil,"Wool Cloth")}) do
        local db=L.New(); local entry=add(db,{kind="item",label=label}); local data=overview(); shared(data,"cloth",{kind="item"}); bind(data,entry,"cloth")
        assert(P.LinkedEntries(db,data).cloth==nil and #summary(db,data).shared.owed.items==1)
        assert(#plan(db,data,transfer(side(0,{item()}))).actions==0)
    end
end)

test("one linked shared debt does not suppress another same-asset obligation",function()
    local db=L.New(); local entry=add(db); local data=overview(); shared(data,"linked"); shared(data,"separate"); bind(data,entry,"linked")
    local totals=summary(db,data); assert(totals.count==2 and totals.shared.owed.money==20)
    local value=plan(db,data)
    assert(#value.actions==0 and value.pending[1].reason=="source_conflict" and #value.pending[1].candidates==2)
    assert(value.pending[1].candidates[2].offerID=="separate")
end)

test("linked repayment direction remains correct for outgoing trades and successful mail",function()
    local db=L.New(); local entry=add(db,{direction="owe"}); local data=overview(); shared(data,"owed",{direction="owe"}); bind(data,entry,"owed")
    for _,medium in ipairs({"trade","mail_sent"}) do
        local transfer=transfer(nil,side(3)); transfer.medium=medium
        local value=plan(db,data,transfer)
        assert(#value.actions==1 and value.actions[1].direction=="owe" and #value.pending==0)
    end
end)

test("different populated item variants require review even when one linked identity exists",function()
    local db=L.New(); local entry=add(db,{kind="item",label=link()}); local data=overview(); shared(data,"cloth",{kind="item"}); bind(data,entry,"cloth")
    local value=plan(db,data,transfer(side(0,{item(2589,3,":14")})))
    assert(#value.actions==0 and value.pending[1].reason=="item_identity")
    assert(#value.pending[1].candidates==2)
end)

test("unreadable shared material balances block personal auto-repayment instead of guessing",function()
    local db=L.New(); add(db,{kind="item",label=link()})
    local value=plan(db,{},transfer(side(0,{item()})))
    assert(#value.actions==0 and value.pending[1].reason=="shared_unavailable")
end)

test("linked projections remain detached and never mutate either ledger source",function()
    local db=L.New(); local entry=add(db,{kind="item",label=link()}); local data=overview(); shared(data,"cloth",{kind="item"}); bind(data,entry,"cloth")
    local beforeDb,beforeData=copy(db),copy(data)
    local value=plan(db,data,transfer(side(0,{item()}))); value.actions[1].amount=100
    local totals=summary(db,data); totals.personal.owed.items[1].quantity=100
    assert(same(db,beforeDb) and same(data,beforeData))
end)

return results
