-- Exercise the real personal core and trade journal together. All identities,
-- transfers, and saved variables are synthetic; no native trade API is used.
local support=assert(IOU_TEST_SUPPORT,"Run through tools/test_iou.py.")
local copy,same=support.Copy,support.Same
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function session(options)
    options=options or {}; options.name=options.name or "Amber"; options.fullName=options.fullName or "Amber Stone"
    local state=support.Session(options); local api=state.api
    assert(api.Initialize()); assert(api.SharedService.Initialize()); assert(api.TradeService.Initialize())
    return state,api,api.TradeService
end
local function add(api,options)
    options=options or {}
    return assert(api.Add({player=options.player or "Birch Vale",direction=options.direction or "owed",
        kind=options.kind or "money",amount=options.amount or 10000,label=options.label or "",note="",due=0}))
end
local function side(money,items) return {money=money or 0,items=items or {}} end
local function item(quantity,id,name,payload)
    id,name=id or 2589,name or "Linen Cloth"
    return {itemID=id,quantity=quantity or 3,name=name,
        link="|cffffffff|Hitem:"..id..(payload or "").."|h["..name.."]|h|r"}
end
local function raw(incoming,outgoing,peer)
    return {peer=peer or "Birch Vale",incoming=incoming or side(),outgoing=outgoing or side()}
end
local function record(service,data)
    data=data or raw(); data.id=assert(service.NewSessionID()); return assert(service.Record(data)),data
end
local function balance(api,id) return assert(api.Ledger.Balance(assert(api.Ledger.Get(api.GetLedger(),id)))) end
local function journal(state,api) return state.env.IOUDB.tradesByCharacter[api.Character()] end
local function fullHistory(api,entryID)
    local db=copy(api.GetLedger()); local entry=db.entries[entryID]
    while #entry.events<api.Ledger.MAX_EVENTS do
        assert(api.Ledger.Amend(db,entryID,{player=entry.player,label=entry.label,
            note="Synthetic history "..(#entry.events+1),due=entry.due or 0},"",1000))
    end
    assert(api.ReplaceLedger(db))
end

test("trade service commits a clear partial repayment and receipt together",function()
    local state,api,S=session(); local entry=add(api)
    local r=record(S,raw(side(3000)))
    equal(r.status,"applied"); equal(balance(api,entry.id),7000); equal(#r.applications,1)
    equal(r.applications[1].amount,3000); equal(r.applications[1].eventID,1)
    equal(api.GetLedger().entries[1].events[1].note,"Trade "..r.id)
    equal(journal(state,api).receipts[1].id,r.id)
    assert(S.Validate(journal(state,api))); equal(#state.transportSent,0)
end)

test("trade service caps gold repayment and retains excess as unmatched",function()
    local _,api,S=session(); add(api)
    local r=record(S,raw(side(15000)))
    equal(balance(api,1),0); equal(r.applications[1].amount,10000)
    equal(r.unmatched[1].amount,5000); equal(#api.GetLedger().entries,1)
end)

test("trade service records ordinary unmatched transfers without inventing an IOU",function()
    local _,api,S=session(); local before=assert(api.Export())
    local r=record(S,raw(side(5000,{item()})))
    equal(r.status,"unmatched"); equal(#r.applications,0); equal(#r.unmatched,2)
    equal(assert(api.Export()),before); equal(#api.GetLedger().entries,0)
end)

test("trade service duplicate completion IDs do not append payments or duplicate receipts",function()
    local _,api,S=session(); add(api)
    local r,data=record(S,raw(side(3000))); local before=assert(api.Export())
    equal(assert(S.Record(data)).id,r.id); equal(assert(api.Export()),before)
    equal(#assert(S.List()),1); equal(#api.GetLedger().entries[1].events,1)
    data.peer="Different Person"; data.incoming.money=9999
    equal(assert(S.Record(data)).peer,"Birch Vale"); equal(balance(api,1),7000)
end)

test("trade service distinct trade sessions with identical contents are separate repayments",function()
    local _,api,S=session(); add(api)
    local first=record(S,raw(side(3000))); local second=record(S,raw(side(3000)))
    assert(first.id~=second.id); equal(balance(api,1),4000); equal(#api.GetLedger().entries[1].events,2)
    equal(#assert(S.List()),2)
end)

test("trade service rejects unreserved and superseded sessions without touching balances",function()
    local _,api,S=session(); add(api); local before=assert(api.Export())
    local fake=raw(side(3000)); fake.id="tr-1"; equal(S.Record(fake),nil)
    fake.id=assert(S.NewSessionID()); assert(S.NewSessionID()); equal(S.Record(fake),nil)
    equal(assert(api.Export()),before); equal(#assert(S.List()),0)
end)

test("trade service rolls back every automatic action when a later IOU history is full",function()
    local _,api,S=session(); add(api); local second=add(api,{kind="item",amount=5,label="Linen Cloth"})
    fullHistory(api,second.id); local before=assert(api.Export())
    local r=record(S,raw(side(3000,{item()})))
    equal(r.status,"review"); equal(#r.applications,0); equal(#r.pending,2)
    equal(r.pending[1].reason,"ledger_changed"); equal(assert(api.Export()),before)
    equal(#api.GetLedger().entries[1].events,0); equal(balance(api,second.id),5)
end)

test("trade service disabled automation creates a review that can be applied without retyping",function()
    local _,api,S=session(); add(api); api.GetSettings().autoTradeRepayments=false
    local r=record(S,raw(side(3000)))
    equal(r.status,"review"); equal(r.pending[1].reason,"automatic_off"); equal(balance(api,1),10000)
    r=assert(S.Resolve(r.id,1,nil,1)); equal(r.status,"applied"); equal(balance(api,1),7000)
    equal(#r.pending,0); equal(r.applications[1].amount,3000)
end)

test("trade service chooses one exact IOU for ambiguous gold and preserves unused transfer amounts",function()
    local _,api,S=session(); add(api,{amount=2000}); add(api,{amount=10000})
    local r=record(S,raw(side(5000))); equal(r.pending[1].reason,"multiple_ious")
    r=assert(S.Resolve(r.id,1,nil,1)); equal(balance(api,1),0); equal(balance(api,2),10000)
    equal(r.pending[1].amount,3000)
    r=assert(S.Resolve(r.id,2,nil,1)); equal(r.status,"applied"); equal(balance(api,2),7000)
    equal(#r.applications,2); equal(r.applications[1].amount+r.applications[2].amount,5000)
end)

test("trade service validates review amount and candidate before changing the ledger",function()
    local _,api,S=session(); add(api); add(api)
    local r=record(S,raw(side(3000))); local before=assert(api.Export())
    for _,amount in ipairs({0,-1,1.5,3001,math.huge}) do equal(S.Resolve(r.id,1,amount,1),nil) end
    equal(S.Resolve(r.id,999,nil,1),nil); equal(S.Resolve(r.id,1,nil,99),nil)
    equal(assert(api.Export()),before); equal(#assert(S.Get(r.id)).applications,0)
end)

test("trade service requires the exact pending row when one entry appears in multiple item variants",function()
    local _,api,S=session(); add(api,{kind="item",amount=10,label="Linen Cloth"})
    local r=record(S,raw(side(0,{item(2),item(3,nil,nil,":1")})))
    equal(#r.pending,2); equal(S.Resolve(r.id,1),nil)
    r=assert(S.Resolve(r.id,1,nil,2)); equal(balance(api,1),7); equal(#r.pending,1)
    equal(r.pending[1].amount,2)
end)

test("trade service rejects a stale allocation after the IOU was renamed to another player",function()
    local _,api,S=session(); add(api); api.GetSettings().autoTradeRepayments=false
    local r=record(S,raw(side(3000)))
    assert(api.Amend(1,{player="Other Person",label="",note="",due=0},""))
    local before=assert(api.Export()); equal(S.Resolve(r.id,1,nil,1),nil)
    equal(assert(api.Export()),before); equal(assert(S.Get(r.id)).status,"review")
end)

test("trade service rejects stale item allocation after its material description changed",function()
    local _,api,S=session(); add(api,{kind="item",amount=10,label="Linen Cloth"})
    api.GetSettings().autoTradeRepayments=false
    local r=record(S,raw(side(0,{item()})))
    assert(api.Amend(1,{player="Birch Vale",label="Copper Ore",note="",due=0},""))
    local before=assert(api.Export()); equal(S.Resolve(r.id,1,nil,1),nil)
    equal(assert(api.Export()),before); equal(balance(api,1),10)
end)

test("trade service keeps unrelated metadata changes compatible with a current allocation",function()
    local _,api,S=session(); add(api,{kind="item",amount=10,label="Linen Cloth"})
    api.GetSettings().autoTradeRepayments=false; local r=record(S,raw(side(0,{item()})))
    assert(api.Amend(1,{player="Birch Vale",label="Linen Cloth",note="New optional note",due=2000},""))
    assert(S.Resolve(r.id,1,nil,1)); equal(balance(api,1),7)
end)

test("trade service recomputes a reduced balance during review instead of using stale candidate amounts",function()
    local _,api,S=session(); add(api); api.GetSettings().autoTradeRepayments=false
    local r=record(S,raw(side(8000))); assert(api.Pay(1,6000,"Other repayment"))
    r=assert(S.Resolve(r.id,1,nil,1)); equal(balance(api,1),0)
    equal(r.applications[1].amount,4000); equal(r.pending[1].amount,4000)
    equal(S.Resolve(r.id,1,nil,1),nil)
end)

test("trade service Undo reverses every payment once and leaves original evidence intact",function()
    local _,api,S=session(); add(api); add(api,{kind="item",amount=8,label="Linen Cloth"})
    local r=record(S,raw(side(3000,{item()}))); equal(#r.applications,2)
    r=assert(S.Undo(r.id)); equal(r.status,"undone"); equal(balance(api,1),10000); equal(balance(api,2),8)
    equal(#api.GetLedger().entries[1].events,2); equal(api.GetLedger().entries[1].events[1].type,"payment")
    equal(api.GetLedger().entries[1].events[2].type,"reversal")
    local before=assert(api.Export()); assert(S.Undo(r.id)); equal(assert(api.Export()),before)
end)

test("trade service Undo recognizes a repayment already reversed through personal history",function()
    local _,api,S=session(); add(api); local r=record(S,raw(side(3000)))
    assert(api.Reverse(1,1,"Manual correction")); local before=assert(api.Export())
    r=assert(S.Undo(r.id)); equal(r.status,"undone"); equal(balance(api,1),10000)
    equal(assert(api.Export()),before)
end)

test("trade service Undo is atomic when a later repayment cannot append its reversal",function()
    local state,api,S=session(); add(api); add(api,{kind="item",amount=8,label="Linen Cloth"})
    local r=record(S,raw(side(3000,{item()}))); fullHistory(api,2)
    local before,receipts=assert(api.Export()),copy(journal(state,api))
    equal(S.Undo(r.id),nil); equal(assert(api.Export()),before); assert(same(journal(state,api),receipts))
    equal(balance(api,1),7000); equal(balance(api,2),5)
end)

test("trade service dismissing pending allocations preserves applied repayment Undo",function()
    local _,api,S=session(); add(api); add(api,{kind="item",amount=8,label="Linen Cloth"})
    add(api,{kind="item",amount=8,label="Linen Cloth"})
    local r=record(S,raw(side(3000,{item()}))); equal(r.status,"review"); equal(#r.applications,1)
    r=assert(S.Ignore(r.id)); equal(r.status,"applied"); equal(#r.pending,0); equal(#r.applications,1)
    r=assert(S.Undo(r.id)); equal(r.status,"undone"); equal(balance(api,1),10000)
end)

test("trade service corrupt sidecar initialization never rewrites personal ledger data",function()
    local state,api=session(); add(api); local saved=copy(state.env.IOUDB)
    saved.tradesByCharacter[api.Character()]={version=99,counter=0,receipts={}}
    local relog=support.Session({name="Amber",fullName="Amber Stone",db=saved})
    assert(relog.api.Initialize()); local before=copy(saved); local encoded=assert(relog.api.Export())
    equal(relog.api.TradeService.Initialize(),nil); equal(relog.api.TradeService.NewSessionID(),nil)
    assert(same(saved,before)); equal(assert(relog.api.Export()),encoded)
    assert(relog.api.Pay(1,1000,"Personal action remains available")); equal(balance(relog.api,1),9000)
end)

test("trade service detects a replaced sidecar and refuses subsequent financial writes",function()
    local state,api,S=session(); add(api); local id=assert(S.NewSessionID())
    state.env.IOUDB.tradesByCharacter[api.Character()]=copy(journal(state,api))
    local before=assert(api.Export()); local data=raw(side(3000)); data.id=id
    equal(S.Record(data),nil); equal(assert(api.Export()),before)
end)

test("trade service fails closed without throwing if its live outer namespace becomes corrupt",function()
    local secret={}
    local hostile=setmetatable({},{__index=function() error("unexpected namespace access") end})
    for _,corrupt in ipairs({false,"broken",42,hostile,secret}) do
        local state,api,S=session(); add(api); local id=assert(S.NewSessionID())
        state.env.issecretvalue=function(value) return value==secret end
        state.env.IOUDB.tradesByCharacter=corrupt
        local before=assert(api.Export()); local data=raw(side(3000)); data.id=id
        local ok,value,err=pcall(S.Record,data)
        assert(ok,"corrupt trade namespace escaped as an error")
        equal(value,nil); assert(type(err)=="string"); equal(assert(api.Export()),before)
    end
end)

test("trade service preserves all one hundred unresolved reviews instead of evicting one",function()
    local state,api,S=session(); add(api); api.GetSettings().autoTradeRepayments=false
    for _=1,S.MAX_RECEIPTS do record(S,raw(side(1))) end
    local first=assert(S.List())[S.MAX_RECEIPTS].id; local before=assert(api.Export())
    local data=raw(side(1)); data.id=assert(S.NewSessionID())
    local retained=copy(journal(state,api).receipts)
    equal(S.Record(data),nil); equal(#assert(S.List()),100)
    assert(same(journal(state,api).receipts,retained)); assert(S.Get(first)); equal(assert(api.Export()),before)
end)

test("trade service a dismissed older review makes room for a new observed trade",function()
    local _,api,S=session(); add(api); api.GetSettings().autoTradeRepayments=false
    for _=1,S.MAX_RECEIPTS do record(S,raw(side(1))) end
    local first=assert(S.List())[S.MAX_RECEIPTS].id; assert(S.Ignore(first))
    local r=record(S,raw(side(2))); equal(r.status,"review"); equal(#assert(S.List()),100)
    equal(S.Get(first),nil); equal(balance(api,1),10000)
end)

test("trade service journal and duplicate protection survive relog while keeping characters isolated",function()
    local state,api,S=session(); add(api); local r,data=record(S,raw(side(3000)))
    local relog,again,T=session({db=state.env.IOUDB}); equal(balance(again,1),7000)
    equal(assert(T.Record(data)).id,r.id); equal(balance(again,1),7000)
    local nextID=assert(T.NewSessionID()); assert(nextID~=r.id)
    local other,otherAPI,U=session({db=state.env.IOUDB,name="Other",fullName="Other Person"})
    equal(#assert(U.List()),0); equal(#otherAPI.GetLedger().entries,0); equal(assert(U.NewSessionID()),"tr-1")
    assert(U.Record({id="tr-1",peer="Birch Vale",incoming=side(100),outgoing=side()}))
    equal(#assert(U.List()),1); equal(#assert(T.List()),1); equal(balance(again,1),7000)
    equal(other.env.IOUDB,relog.env.IOUDB)
end)

test("trade service rejects stale Undo after a personal ledger replacement loses its payment evidence",function()
    local _,api,S=session(); add(api); local old=copy(api.GetLedger()); local r=record(S,raw(side(3000)))
    assert(api.ReplaceLedger(old)); local before=assert(api.Export())
    equal(S.Undo(r.id),nil); equal(assert(api.Export()),before); equal(balance(api,1),10000)
end)

test("trade service rejects stale Undo if imported payment metadata no longer matches its receipt",function()
    local _,api,S=session(); add(api); local r=record(S,raw(side(3000)))
    local imported=copy(api.GetLedger()); imported.entries[1].events[1].note="Unrelated imported repayment"
    assert(api.ReplaceLedger(imported)); local before=assert(api.Export())
    equal(S.Undo(r.id),nil); equal(assert(api.Export()),before); equal(balance(api,1),7000)
end)

test("trade service committed receipts remain successful if UI refresh and notification callbacks throw",function()
    local state,api,S=session(); add(api)
    api.PlayerContext={Invalidate=function() error("Synthetic tooltip failure") end}
    api.Refresh=function() error("Synthetic panel failure") end
    api.OnTradeChanged=function() error("Synthetic notification failure") end
    local r,data=record(S,raw(side(3000))); equal(r.status,"applied"); equal(balance(api,1),7000)
    equal(journal(state,api).receipts[1].status,"applied"); assert(S.Record(data)); equal(balance(api,1),7000)
    assert(S.Undo(r.id)); equal(balance(api,1),10000)
end)

test("trade service list and returned receipts cannot mutate saved bookkeeping by alias",function()
    local _,api,S=session(); add(api); local r=record(S,raw(side(3000)))
    local listed=assert(S.List()); local fetched=assert(S.Get(r.id))
    r.applications[1].amount=9999; listed[1].pending[1]={}; fetched.incoming.money=1
    local saved=assert(S.Get(r.id)); equal(saved.applications[1].amount,3000); equal(saved.incoming.money,3000)
    equal(#saved.pending,0); equal(balance(api,1),7000)
end)

test("trade service rejects inflated pending amounts that exceed the observed transfer",function()
    local state,api,S=session(); add(api); api.GetSettings().autoTradeRepayments=false
    local r=record(S,raw(side(3000))); local saved=journal(state,api).receipts[1]
    saved.pending[1].amount=4000
    local before=assert(api.Export()); local ok,value=pcall(S.Resolve,r.id,1,nil,1)
    assert(ok,"corrupt allocation escaped as an error"); equal(value,nil); equal(assert(api.Export()),before)
end)

test("trade service rejects altered application evidence even when pending totals appear conserved",function()
    local state,api,S=session(); add(api); local r=record(S,raw(side(3000)))
    local saved=journal(state,api).receipts[1]
    saved.applications[1].amount=2000; saved.status="review"
    saved.pending={{asset="money",direction="owed",amount=1000,label="Gold",reason="multiple_ious",
        candidates={{source="personal",entryID=1,balance=7000,label=""}}}}
    local before=assert(api.Export()); local ok,value=pcall(S.Resolve,r.id,1,nil,1)
    assert(ok,"altered application escaped as an error"); equal(value,nil); equal(assert(api.Export()),before)
end)

test("trade service rejects deleted application evidence instead of paying the same observed asset twice",function()
    local state,api,S=session(); add(api); local r=record(S,raw(side(3000)))
    local saved=journal(state,api).receipts[1]
    saved.applications={}; saved.status="review"
    saved.pending={{asset="money",direction="owed",amount=3000,label="Gold",reason="multiple_ious",
        candidates={{source="personal",entryID=1,balance=7000,label=""}}}}
    local before=assert(api.Export()); local ok,value=pcall(S.Resolve,r.id,1,nil,1)
    assert(ok,"deleted application escaped as an error"); equal(value,nil); equal(assert(api.Export()),before)
end)

test("trade observer and real service only apply confirmed trades once and preserve Undo",function()
    local state,api,S=session(); add(api); add(api,{kind="item",amount=8,label="Linen Cloth"})
    local incoming=item(3)
    api.PlayerContext={UnitName=function(unit) equal(unit,"NPC"); return "Birch Vale" end,Invalidate=function() end}
    state.env.GetGameMessageInfo=function(id) return id==42 and "ERR_TRADE_COMPLETE" or "ERR_OTHER" end
    state.env.GetPlayerTradeMoney=function() return 0 end
    state.env.GetTargetTradeMoney=function() return 3000 end
    state.env.GetTradePlayerItemInfo=function() end
    state.env.GetTradePlayerItemLink=function() end
    state.env.GetTradeTargetItemInfo=function(slot)
        if slot==1 then return incoming.name,1,incoming.quantity,1,nil,nil,incoming.itemID end
    end
    state.env.GetTradeTargetItemLink=function(slot) if slot==1 then return incoming.link end end
    local chunk=assert(loadstring(assert(IOU_SOURCES["trade_observer.lua"]),"@IOU/trade_observer.lua"))
    setfenv(chunk,state.env); chunk("IOU",api); assert(api.TradeObserver.Initialize())
    local function accepted()
        state.event("TRADE_SHOW"); state.event("TRADE_ACCEPT_UPDATE",1,1)
    end
    accepted(); state.event("TRADE_REQUEST_CANCEL"); state.event("UI_INFO_MESSAGE",42,"Localized success")
    equal(#assert(S.List()),0); equal(balance(api,1),10000); equal(balance(api,2),8)
    accepted(); state.event("TRADE_CLOSED"); state.now=state.now+5
    state.event("UI_INFO_MESSAGE",99,"Trade complete.")
    equal(#assert(S.List()),0); equal(balance(api,1),10000)
    accepted(); state.event("UI_INFO_MESSAGE",42,"Localized success")
    state.event("UI_INFO_MESSAGE",42,"Localized success"); state.event("TRADE_CLOSED")
    local records=assert(S.List()); equal(#records,1); equal(records[1].status,"applied")
    equal(#records[1].applications,2); equal(balance(api,1),7000); equal(balance(api,2),5)
    assert(S.Undo(records[1].id)); equal(balance(api,1),10000); equal(balance(api,2),8)
    equal(#state.transportSent,0)
end)

return results
