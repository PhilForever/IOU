-- Cross-source reservation and immutable loan evidence edge cases.
local support=assert(IOU_TEST_SUPPORT)
local copy=support.Copy
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function session()
    local state=support.Session({name="Amber",fullName="Amber Stone"});local api=state.api
    assert(api.Initialize());assert(api.SharedService.Initialize());assert(api.TradeService.Initialize())
    return state,api,api.TradeService
end
local function side(money,items) return {money=money or 0,items=items or {}} end
local function item(id,name,quantity)
    return {itemID=id,name=name,quantity=quantity or 3,link="|cffffffff|Hitem:"..id.."|h["..name.."]|h|r"}
end
local function add(api,direction,amount)
    return assert(api.Add({player="Birch Vale",direction=direction,kind="money",amount=amount,label="",note="",due=0}))
end
local function transfer(S,medium,incoming,outgoing)
    return {id=assert(S.NewSessionID(medium)),medium=medium,peer="Birch Vale",
        incoming=incoming or side(),outgoing=outgoing or side()}
end
local function balance(api,id) return api.Ledger.Balance(api.GetLedger().entries[id]) end
local function saved(state,api) return state.env.IOUDB.tradesByCharacter[api.Character()] end

test("completed mail reservations cannot repay again after later trades trim both source receipts",function()
    local _,api,S=session();add(api,"owe",100000);add(api,"owed",100000)
    local sent=transfer(S,"mail_sent",side(),side(3000));assert(S.Record(sent))
    local received=transfer(S,"mail_received",side(4000),side());assert(S.Record(received))
    for _=1,S.MAX_RECEIPTS do assert(S.Record(transfer(S,"trade"))) end
    equal(S.Get(sent.id),nil);equal(S.Get(received.id),nil)
    local before=assert(api.Export())
    equal(S.Record(sent),nil);equal(S.Record(received),nil)
    equal(assert(api.Export()),before);equal(balance(api,1),97000);equal(balance(api,2),96000)
    equal(#assert(S.List()),S.MAX_RECEIPTS)
end)

test("Record consumes only its own reservation when a notification reserves the next mail",function()
    local _,api,S=session();add(api,"owe",10000)
    local first=transfer(S,"mail_sent",side(),side(1000));local second
    api.OnTradeChanged=function(r)
        if r and r.id==first.id then second=transfer(S,"mail_sent",side(),side(2000)) end
    end
    assert(S.Record(first));assert(second);assert(S.Record(second))
    equal(balance(api,1),7000);equal(#api.GetLedger().entries[1].events,2)
    equal(#assert(S.List()),2)
end)

test("a failed Record commit keeps its reservation available for one successful retry",function()
    local _,api,S=session();add(api,"owe",10000)
    local data=transfer(S,"mail_sent",side(),side(1000));local before=assert(api.Export())
    local commit=api.CommitTradeState
    api.CommitTradeState=function() return nil,"Synthetic commit failure" end
    equal(S.Record(data),nil);equal(assert(api.Export()),before);equal(#assert(S.List()),0)
    api.CommitTradeState=commit
    assert(S.Record(data));equal(balance(api,1),9000);equal(#api.GetLedger().entries[1].events,1)
    assert(S.Record(data));equal(balance(api,1),9000);equal(#assert(S.List()),1)
end)

test("deleted capture evidence cannot create the same observed loan a second time",function()
    local state,api,S=session();local data=transfer(S,"mail_sent",side(),side(5000))
    local r=assert(S.Record(data));assert(S.Capture(r.id,1,r.unmatched[1]))
    local stored=saved(state,api).receipts[1]
    stored.captures={};stored.status="unmatched"
    stored.unmatched={{direction="owe",asset="money",amount=5000,label="Gold"}}
    local before=assert(api.Export())
    equal(S.Capture(r.id,1,copy(stored.unmatched[1])),nil)
    equal(assert(api.Export()),before);equal(#api.GetLedger().entries,1)
end)

test("an imported ledger missing a captured loan cannot allocate another asset from that receipt",function()
    local _,api,S=session();add(api,"owe",10000);api.GetSettings().autoMailRepayments=false
    local data=transfer(S,"mail_sent",side(),side(1000,{item(2589,"Linen Cloth")}))
    local r=assert(S.Record(data));equal(#r.pending,1);equal(#r.unmatched,1)
    local beforeCapture=copy(api.GetLedger());assert(S.Capture(r.id,1,r.unmatched[1]))
    equal(#api.GetLedger().entries,2);assert(api.ReplaceLedger(beforeCapture))
    local before=assert(api.Export())
    equal(S.Resolve(r.id,1,nil,1),nil);equal(assert(api.Export()),before);equal(balance(api,1),10000)
end)

test("capture item identity cannot be reassigned to another asset while retaining its old loan label",function()
    local state,api,S=session()
    local data=transfer(S,"mail_sent",side(),side(0,{item(2589,"Linen Cloth"),item(2770,"Copper Ore")}))
    local r=assert(S.Record(data));equal(r.unmatched[1].itemID,2589)
    assert(S.Capture(r.id,1,r.unmatched[1]));local stored=saved(state,api).receipts[1]
    stored.captures[1].itemID=2770;stored.captures[1].itemKey="item:2770"
    stored.unmatched={{direction="owe",asset="item",amount=3,label="Linen Cloth",itemID=2589,itemKey="item:2589"}}
    local before=assert(api.Export())
    equal(S.Capture(r.id,1,copy(stored.unmatched[1])),nil)
    equal(assert(api.Export()),before);equal(#api.GetLedger().entries,1)
end)

return results
