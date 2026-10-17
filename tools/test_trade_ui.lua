-- Activity uses the real addon widgets and a detached service fixture. Native
-- trade completion is covered by the separate observer/service checks.
local support=assert(IOU_TEST_SUPPORT)
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(actual,expected)
    assert(actual==expected,"expected "..tostring(expected)..", got "..tostring(actual))
end
local function contains(value,part) assert(value:find(part,1,true),"missing "..part.." in "..value) end
local function fixture(changes)
    local receipt={id="trade-1",peer="Birch Vale",at=1000,status="review",
        outgoing={money=0,items={}},incoming={money=30000,items={}},applications={},
        pending={{reason="ambiguous",direction="owed",asset="money",amount=30000,label="",
            candidates={{source="personal",entryID=1,balance=100000,label=""},
                {source="personal",entryID=2,balance=50000,label=""}}}}}
    for key,value in pairs(changes or {}) do receipt[key]=value end
    return receipt
end
local function session(receipts)
    local state=support.Session({ui=true,fullName="Amber Stone"})
    local api=state.api
    assert(api.Initialize())
    assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=100000,label="",note="",due=0}))
    assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=50000,label="",note="",due=0}))
    state.receipts=receipts or {fixture()};state.calls={}
    local function find(id)
        for _,receipt in ipairs(state.receipts) do if receipt.id==id then return receipt end end
    end
    api.TradeService={
        List=function() return support.Copy(state.receipts) end,
        Get=function(id) return support.Copy(find(id)) end,
        Resolve=function(id,entryID,amount,pendingIndex)
            state.calls[#state.calls+1]={method="Resolve",id=id,entryID=entryID,amount=amount,pendingIndex=pendingIndex}
            if state.fail then return nil,state.fail end
            local r=assert(find(id));r.status="applied";r.pending={}
            r.applications={{entryID=entryID,eventID=1,amount=30000,label="",direction="owed"}}
            api.OnTradeChanged(support.Copy(r));return support.Copy(r)
        end,
        Undo=function(id)
            state.calls[#state.calls+1]={method="Undo",id=id}
            if state.fail then return nil,state.fail end
            local r=assert(find(id));r.status="undone";r.pending={}
            api.OnTradeChanged(support.Copy(r));return support.Copy(r)
        end,
        Ignore=function(id)
            state.calls[#state.calls+1]={method="Ignore",id=id}
            local r=assert(find(id));r.status="ignored";r.pending={}
            api.OnTradeChanged(support.Copy(r));return support.Copy(r)
        end,
    }
    if not api.ShowTradeActivity then
        local chunk=assert(loadstring(assert(IOU_SOURCES["trade_ui.lua"]),"@IOU/trade_ui.lua"))
        setfenv(chunk,state.env);chunk("IOU",api)
    end
    return state,api
end

test("trade review opens only on request and requires an allocation choice",function()
    local state,api=session()
    api.ShowAdd("Birch Vale");local focused=state.focused
    api.OnTradeChanged(support.Copy(state.receipts[1]))
    equal(api.UI.tradeActivity,nil);equal(state.focused,focused)
    local toast=api.UI.tradeToast
    assert(toast:IsShown());equal(toast.open:GetText(),"Review trade")
    state.click(toast.open)
    local f=api.UI.tradeActivity
    assert(f:IsShown() and not toast:IsShown())
    contains(f.summary:GetText(),"Received: 3g")
    assert(not f.apply.enabled);equal(#state.calls,0)
    state.click(f.candidates[2]);assert(f.apply.enabled)
    state.click(f.apply)
    equal(#state.calls,1);equal(state.calls[1].method,"Resolve")
    equal(state.calls[1].entryID,2);equal(state.calls[1].pendingIndex,1)
    equal(state.calls[1].amount,30000)
    contains(f.summary:GetText(),"Applied: 3g")
end)

test("trade allocation failure stays local and preserves the review",function()
    local state,api=session();api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    state.click(f.candidates[1]);state.fail="This IOU changed. Choose it again."
    state.click(f.apply)
    contains(f.message:GetText(),"This IOU changed")
    equal(state.receipts[1].status,"review")
    equal(#state.receipts[1].applications,0);equal(#state.messages,0)
    assert(f:IsShown())
end)

test("applied trade notification offers one Undo without opening a window",function()
    local r=fixture({status="applied",pending={},applications={{entryID=1,eventID=1,amount=30000,label="",direction="owed"}}})
    local state,api=session({r})
    api.OnTradeChanged(support.Copy(r))
    local toast=api.UI.tradeToast
    assert(toast:IsShown() and toast.undo:IsShown());equal(api.UI.tradeActivity,nil)
    contains(toast.label:GetText(),"Received 3g")
    state.click(toast.undo)
    equal(state.calls[1].method,"Undo");equal(state.calls[1].id,"trade-1")
    equal(r.status,"undone");assert(not toast:IsShown() and not toast.scripts.OnUpdate)
end)

test("trade notice expires and leaves no idle frame driver",function()
    local state,api=session()
    api.OnTradeChanged(support.Copy(state.receipts[1]))
    local toast=api.UI.tradeToast
    state.advance(19);assert(toast:IsShown())
    state.advance(2);assert(not toast:IsShown() and not toast.scripts.OnUpdate)
    local count=#state.objects
    for _=1,20 do api.OnTradeChanged(support.Copy(state.receipts[1])) end
    equal(#state.objects,count)
    state.click(state.button(toast,"X"));assert(not toast:IsShown() and not toast.scripts.OnUpdate)
end)

test("unmatched trades stay quiet and can be dismissed without changing debts",function()
    local r=fixture({status="unmatched",pending={},applications={}})
    local state,api=session({r})
    local ledger=support.Copy(api.GetLedger())
    api.OnTradeChanged(support.Copy(r));equal(api.UI.tradeToast,nil)
    api.ShowTradeActivity();local f=api.UI.tradeActivity
    assert(not f.apply:IsShown() and f.ignore:IsShown() and not f.undo:IsShown())
    state.click(f.ignore);equal(r.status,"ignored")
    assert(not f.ignore:IsShown());assert(support.Same(api.GetLedger(),ledger))
end)

test("Shared-only matching offers Requests without applying or acknowledging",function()
    local r=fixture({pending={{direction="owed",asset="money",amount=30000,label="",reason="shared",
        candidates={{source="shared",offerID="offer-1",balance=100000,label=""}}}}})
    local state,api=session({r})
    local requested
    api.ShowShared=function(peer) requested=peer end
    api.ShowTradeActivity();local f=api.UI.tradeActivity
    assert(f.shared:IsShown() and not f.apply:IsShown())
    state.click(f.shared);equal(requested,"Birch Vale")
    equal(#state.calls,0);equal(#state.transportSent,0)
    contains(f.pendingText:GetText(),"confirmation")
end)

test("mixed trade summaries preserve both directions and literal Unicode item names",function()
    local r=fixture({incoming={money=30000,items={{itemID=2589,quantity=12,label="Linen Cloth"}}},
        outgoing={money=50000,items={{itemID=999,quantity=2,label="Bjørn |Tbad:16|t blåbær"}}}})
    local state,api=session({r});api.ShowTradeActivity()
    local summary=api.UI.tradeActivity.summary:GetText()
    contains(summary,"Given: 5g, 2 x Bjørn ||Tbad:16||t blåbær")
    contains(summary,"Received: 3g, 12 x Linen Cloth")
    equal(r.incoming.money,30000);equal(r.outgoing.money,50000)
end)

test("unallocated exchanges explain the exception and open the player's IOUs",function()
    local r=fixture({pending={{direction="owed",asset="money",amount=30000,label="",reason="mixed_trade",candidates={}}}})
    local state,api=session({r});local requested
    api.ShowPlayerRecords=function(peer) requested=peer end
    api.ShowTradeActivity();local f=api.UI.tradeActivity
    contains(f.pendingText:GetText(),"An exchange")
    assert(not f.apply:IsShown() and f.records:IsShown())
    state.click(f.records);equal(requested,"Birch Vale");equal(#state.calls,0)
end)

test("activity paging keeps selected receipt and refresh reuses all frames",function()
    local receipts={}
    for index=1,12 do receipts[index]=fixture({id="trade-"..index,peer="Player "..index}) end
    local state,api=session(receipts);api.ShowTradeActivity("trade-12")
    local f=api.UI.tradeActivity
    equal(f.page,3);equal(f.selected,"trade-12");contains(f.summary:GetText(),"Player 12")
    local count=#state.objects
    for _=1,30 do api.OnTradeChanged(nil) end
    equal(#state.objects,count);equal(f.selected,"trade-12")
    state.click(f.previous);equal(f.page,2)
    state.click(f.rows[1]);equal(f.selected,"trade-6")
    assert(not f.apply.enabled)
end)

test("allocation candidate paging binds pending index and entry separately",function()
    local pending={}
    for index=1,5 do pending[index]={direction="owed",asset="item",amount=index,label="Material "..index,
        candidates={{source="personal",entryID=index+2,balance=12,label="Material "..index}}} end
    local state,api=session({fixture({pending=pending})})
    for index=1,5 do
        assert(api.Add({player="Birch Vale",direction="owed",kind="item",amount=12,label="Material "..index,note="",due=0}))
    end
    api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    assert(f.choiceNext:IsShown());state.click(f.candidates[1]);assert(f.apply.enabled)
    state.click(f.choiceNext);assert(not f.apply.enabled)
    state.click(f.candidates[2]);state.click(f.apply)
    equal(state.calls[1].entryID,7);equal(state.calls[1].pendingIndex,5)
end)

test("allocation choices use current balances and clear selection when repayment changes",function()
    local r=fixture({pending={{reason="multiple_ious",direction="owed",asset="money",amount=60000,label="",
        candidates={{source="personal",entryID=1,balance=100000,label=""}}}}})
    local state,api=session({r});api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    contains(f.candidates[1]:GetText(),"Owes you 10g")
    contains(f.candidates[1]:GetText(),"Repay 6g")
    state.click(f.candidates[1]);assert(f.apply.enabled)
    assert(api.Pay(1,80000,"Earlier repayment"))
    api.OnTradeChanged(nil)
    contains(f.candidates[1]:GetText(),"Owes you 2g")
    contains(f.candidates[1]:GetText(),"Repay 2g")
    assert(not f.apply.enabled and not f.choice)
    state.click(f.candidates[1]);state.click(f.apply)
    equal(state.calls[1].amount,20000)
end)

test("a stale Apply callback rejects intervening balance changes before calling the service",function()
    local state,api=session();api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    state.click(f.candidates[1]);assert(f.apply.enabled)
    assert(api.Pay(1,95000,"Another repayment"))
    state.click(f.apply)
    equal(#state.calls,0);assert(not f.apply.enabled and not f.choice)
    contains(f.message:GetText(),"changed")
    contains(f.candidates[1]:GetText(),"Owes you 50s")
    contains(f.candidates[1]:GetText(),"Repay 50s")
end)

test("settled cancelled moved and relabelled IOUs are excluded from allocation",function()
    local state,api=session();api.ShowTradeActivity()
    assert(api.Pay(1,100000,"Paid elsewhere"))
    assert(api.Cancel(2,"Cancelled"))
    api.OnTradeChanged(nil)
    local f=api.UI.tradeActivity
    assert(not f.candidates[1]:IsShown() and not f.apply:IsShown())
    contains(f.pendingText:GetText(),"IOUs changed")

    local item=assert(api.Add({player="Birch Vale",direction="owed",kind="item",amount=12,label="Linen Cloth",note="",due=0}))
    local r=state.receipts[1]
    r.pending={{reason="item_identity",direction="owed",asset="item",amount=4,label="Linen Cloth",
        candidates={{source="personal",entryID=item.id,balance=12,label="Linen Cloth"}}}}
    api.OnTradeChanged(nil);assert(f.candidates[1]:IsShown())
    assert(api.Amend(item.id,{player="Birch Vale",label="Wool Cloth",note="",due=0},"Changed item"))
    api.OnTradeChanged(nil);assert(not f.candidates[1]:IsShown())
    assert(api.Amend(item.id,{player="Other Person",label="Linen Cloth",note="",due=0},"Changed player"))
    api.OnTradeChanged(nil);assert(not f.candidates[1]:IsShown())
end)

test("mixed exchanges and item variants keep their reason visible beside allocation choices",function()
    local r=fixture();r.pending[1].reason="mixed_trade"
    local state,api=session({r});api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    assert(f.candidates[1]:IsShown());contains(f.pendingText:GetText(),"Both sides gave something")
    contains(f.pendingText:GetText(),"only if repayment")
    local item=assert(api.Add({player="Birch Vale",direction="owed",kind="item",amount=12,label="Linen Cloth",note="",due=0}))
    r.pending={{reason="item_identity",direction="owed",asset="item",amount=4,label="Other item variant",
        candidates={{source="personal",entryID=item.id,balance=12,label="Linen Cloth"}}}}
    api.OnTradeChanged(nil)
    assert(f.candidates[1]:IsShown());contains(f.pendingText:GetText(),"Different item variant")
    contains(f.candidates[1]:GetText(),"Linen Cloth")
    assert(not f.apply.enabled)
end)

test("empty and unavailable Activity remain readable without financial actions",function()
    local state,api=session({});api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    contains(f.empty:GetText(),"Completed trades")
    assert(not f.apply:IsShown() and not f.undo:IsShown() and not f.ignore:IsShown())
    api.TradeService=nil;api.ShowTradeActivity()
    contains(f.empty:GetText(),"unavailable");equal(#state.calls,0)
end)

test("partly applied review retains Undo after dismissing its unallocated remainder",function()
    local r=fixture({applications={{entryID=1,eventID=1,amount=10000,label="",direction="owed"}}})
    local state,api=session({r});api.ShowTradeActivity()
    local f=api.UI.tradeActivity
    assert(f.ignore:IsShown() and f.undo:IsShown())
    state.click(f.ignore);assert(f.undo:IsShown())
    state.click(f.undo);equal(state.calls[2].method,"Undo")
    assert(not f.undo:IsShown())
end)

return results
