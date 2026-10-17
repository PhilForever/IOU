-- Explicit Activity bundle capture uses one real financial transaction.
local support=assert(IOU_TEST_SUPPORT)
local copy,same=support.Copy,support.Same
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function session(ui)
    local state=support.Session({ui=ui==true,name="Amber",fullName="Amber Stone"})
    local api=state.api
    assert(api.Initialize());assert(api.SharedService.Initialize());assert(api.TradeService.Initialize())
    return state,api,api.TradeService
end
local function side(money,items) return {money=money or 0,items=items or {}} end
local function item(id,name,quantity)
    return {itemID=id,name=name,quantity=quantity or 3,
        link="|cffffffff|Hitem:"..id..":0:0:0|h["..name.."]|h|r"}
end
local function record(S,medium,incoming,outgoing)
    return assert(S.Record({id=assert(S.NewSessionID(medium)),medium=medium,peer="Birch Vale",
        incoming=incoming or side(),outgoing=outgoing or side()}))
end
local function unchanged(api,S,id,before,r)
    equal(assert(api.Export()),before);assert(same(assert(S.Get(id)),r))
end

test("Track all creates native material and gold loans in one commit only after an explicit click",function()
    local state,api,S=session()
    local cloth,ore=item(2589,"Linen Cloth",20),item(2770,"Copper Ore",7)
    local r=record(S,"mail_sent",nil,side(5000,{cloth,ore}))
    equal(#api.GetLedger().entries,0);equal(#r.unmatched,3)
    local commits,changed=0,0
    local commit=api.CommitTradeState
    api.CommitTradeState=function(...) commits=commits+1;return commit(...) end
    api.OnTradeChanged=function() changed=changed+1 end
    r=assert(S.CaptureAll(r.id,copy(r.unmatched)))
    equal(commits,1);equal(changed,1);equal(#r.captures,3);equal(#r.unmatched,0)
    equal(r.status,"captured")
    local byLabel={}
    for _,entry in ipairs(api.GetLedger().entries) do
        equal(entry.player,"Birch Vale");equal(entry.direction,"owed")
        equal(entry.note,"Mail "..r.id);byLabel[entry.label]=entry.amount
    end
    equal(byLabel[""],5000);equal(byLabel[cloth.link],20);equal(byLabel[ore.link],7)
    assert(S.Validate(state.env.IOUDB.tradesByCharacter[api.Character()]))
end)

test("Track all preserves incoming and outgoing loan directions in an ordinary exchange",function()
    local _,api,S=session()
    local cloth,ore=item(2589,"Linen Cloth",20),item(2770,"Copper Ore",7)
    local r=record(S,"trade",side(300,{cloth}),side(500,{ore}))
    equal(#r.unmatched,4)
    r=assert(S.CaptureAll(r.id,copy(r.unmatched)))
    local incoming,outgoing=0,0
    for _,capture in ipairs(r.captures) do
        local entry=assert(api.Ledger.Get(api.GetLedger(),capture.entryID))
        if capture.direction=="owed" then equal(entry.direction,"owe");incoming=incoming+1
        else equal(entry.direction,"owed");outgoing=outgoing+1 end
        if capture.asset=="item" then equal(entry.label,capture.direction=="owed" and cloth.link or ore.link) end
    end
    equal(incoming,2);equal(outgoing,2)
end)

test("Track all binds every displayed amount identity and array position",function()
    for _,mutate in ipairs({
        function(rows) rows[1].amount=rows[1].amount+1 end,
        function(rows) rows[2].itemID=999 end,
        function(rows) rows[2].itemKey="item:999" end,
        function(rows) rows[2].label="Different item" end,
        function(rows) rows[1],rows[2]=rows[2],rows[1] end,
        function(rows) table.remove(rows) end,
        function(rows) rows[5]=copy(rows[1]) end,
    }) do
        local _,api,S=session()
        local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3)}))
        local before=assert(api.Export());local expected=copy(r.unmatched)
        mutate(expected);local captured,err=S.CaptureAll(r.id,expected)
        assert(not captured and type(err)=="string");unchanged(api,S,r.id,before,r)
    end
end)

test("Track all refuses a stale snapshot after one asset was captured",function()
    local _,api,S=session()
    local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3)}))
    local displayed=copy(r.unmatched)
    assert(S.Capture(r.id,1,displayed[1]))
    local before,current=assert(api.Export()),assert(S.Get(r.id))
    equal(S.CaptureAll(r.id,displayed),nil);unchanged(api,S,r.id,before,current)
    assert(S.CaptureAll(r.id,copy(current.unmatched)));equal(#api.GetLedger().entries,2)
end)

test("Track all rolls back a material already staged when the next loan exceeds ledger capacity",function()
    local _,api,S=session()
    local L=api.Ledger;local draft=L.New()
    for index=1,L.MAX_ENTRIES-1 do
        assert(L.Add(draft,{player="Other Person",direction="owed",kind="money",amount=1,label="",note="",due=0},100))
    end
    assert(api.ReplaceLedger(draft))
    local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3)}))
    local before=assert(api.Export())
    local captured,err=S.CaptureAll(r.id,copy(r.unmatched))
    assert(not captured and type(err)=="string");unchanged(api,S,r.id,before,r)
    equal(#api.GetLedger().entries,L.MAX_ENTRIES-1)
end)

test("Track all retains every asset when one amount cannot fit in a single IOU",function()
    local _,api,S=session()
    local r=record(S,"mail_sent",nil,side(api.Ledger.MAX_AMOUNT+1,{item(2589,"Linen Cloth",3)}))
    local before=assert(api.Export())
    equal(S.CaptureAll(r.id,copy(r.unmatched)),nil);unchanged(api,S,r.id,before,r)
end)

test("Track all storage failure leaves both the ledger and all capture evidence untouched",function()
    local _,api,S=session()
    local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3)}))
    local before=assert(api.Export());local commit=api.CommitTradeState
    api.CommitTradeState=function() return nil,"Synthetic storage failure" end
    equal(S.CaptureAll(r.id,copy(r.unmatched)),nil);unchanged(api,S,r.id,before,r)
    api.CommitTradeState=commit
    assert(S.CaptureAll(r.id,copy(r.unmatched)));equal(#api.GetLedger().entries,2)
end)

test("Track all cannot spend an earlier repayment missing after a ledger import",function()
    local _,api,S=session()
    assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=100,label="",note="",due=0}))
    local old=copy(api.GetLedger())
    local r=record(S,"mail_received",side(200,{item(2589,"Linen Cloth",3)}))
    equal(#r.applications,1);equal(#r.unmatched,2)
    assert(api.ReplaceLedger(old));local before=assert(api.Export())
    equal(S.CaptureAll(r.id,copy(r.unmatched)),nil);unchanged(api,S,r.id,before,r)
end)

test("Track all cannot duplicate a captured loan missing after a ledger import",function()
    local _,api,S=session()
    local old=copy(api.GetLedger())
    local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3),item(2770,"Copper Ore",2)}))
    r=assert(S.Capture(r.id,1,r.unmatched[1]));equal(#r.unmatched,2)
    assert(api.ReplaceLedger(old));local before=assert(api.Export())
    equal(S.CaptureAll(r.id,copy(r.unmatched)),nil);unchanged(api,S,r.id,before,r)
end)

test("Track all is consumed once and repayment Undo leaves captured material loans intact",function()
    local _,api,S=session()
    local paid=assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=100,label="",note="",due=0}))
    local r=record(S,"mail_received",side(200,{item(2589,"Linen Cloth",3)}))
    local displayed=copy(r.unmatched)
    r=assert(S.CaptureAll(r.id,displayed));equal(#r.captures,2)
    local before=assert(api.Export())
    equal(S.CaptureAll(r.id,displayed),nil);unchanged(api,S,r.id,before,r)
    assert(S.Undo(r.id));equal(api.Ledger.Balance(api.Ledger.Get(api.GetLedger(),paid.id)),100)
    for _,capture in ipairs(r.captures) do
        equal(api.Ledger.Balance(api.Ledger.Get(api.GetLedger(),capture.entryID)),capture.amount)
    end
    equal(#api.GetLedger().entries,3)
end)

test("Activity shows Track all only for multiple unassigned assets and saves the displayed bundle",function()
    local state,api,S=session(true)
    local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3)}))
    api.ShowTradeActivity(r.id);local f=api.UI.tradeActivity
    assert(f.captureAll:IsShown());equal(f.captureAll:GetText(),"Track all")
    assert(f.captureAllExpected~=r.unmatched and f.captureAllExpected[1]~=r.unmatched[1])
    equal(#api.GetLedger().entries,0)
    state.click(f.captureAll);equal(#api.GetLedger().entries,2)
    assert(not f.captureAll:IsShown());equal(#assert(S.Get(r.id)).captures,2)
    r=record(S,"mail_sent",nil,side(100))
    api.ShowTradeActivity(r.id);assert(not f.captureAll:IsShown())
end)

test("Activity passes its detached bundle snapshot so stale displayed amounts cannot create loans",function()
    local state,api,S=session(true)
    local r=record(S,"mail_sent",nil,side(100,{item(2589,"Linen Cloth",3)}))
    api.ShowTradeActivity(r.id);local f=api.UI.tradeActivity
    f.captureAllExpected[1].amount=101
    state.click(f.captureAll);equal(#api.GetLedger().entries,0)
    assert(f.message:GetText():find("changed",1,true));equal(#assert(S.Get(r.id)).unmatched,2)
end)

test("Track all captures the full twelve attachment bundle across Activity choice pages",function()
    local state,api,S=session(true)
    local items={}
    for index=1,12 do items[index]=item(1000+index,"Material "..index,index) end
    local r=record(S,"mail_sent",nil,side(100,items))
    equal(#r.unmatched,13)
    api.ShowTradeActivity(r.id);local f=api.UI.tradeActivity
    assert(f.captureAll:IsShown() and f.choiceNext:IsShown())
    equal(#f.captureAllExpected,13)
    state.click(f.choiceNext);equal(#f.captureAllExpected,13)
    state.click(f.captureAll);equal(#api.GetLedger().entries,13)
    local current=assert(S.Get(r.id));equal(#current.captures,13);equal(#current.unmatched,0)
    assert(S.Validate(state.env.IOUDB.tradesByCharacter[api.Character()]))
end)

test("Activity keeps Track all hidden while reviewing repayments until Track new IOU is selected",function()
    local state,api,S=session(true)
    assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=100,label="",note="",due=0}))
    local r=record(S,"trade",side(200),side(0,{item(2589,"Linen Cloth",3),item(2770,"Copper Ore",2)}))
    equal(#r.pending,1);equal(#r.unmatched,2)
    api.ShowTradeActivity(r.id);local f=api.UI.tradeActivity
    assert(not f.captureAll:IsShown());assert(f.captureMode:IsShown())
    state.click(f.captureMode);assert(f.captureAll:IsShown())
    state.click(f.captureAll);equal(#api.GetLedger().entries,3)
    equal(api.Ledger.Balance(api.Ledger.Get(api.GetLedger(),1)),100)
    equal(#assert(S.Get(r.id)).pending,1)
end)

return results
