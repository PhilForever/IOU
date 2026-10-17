-- Requests presentation uses real consent records. The coordinator stub only
-- performs the documented connection selection; it never fabricates consent.
local support=assert(IOU_TEST_SUPPORT,"Run after test_iou.lua.")
local copy,same=support.Copy,support.Same
local results={}
local function test(name,run)
    local ok,err=pcall(run); if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(text,value) assert(text:find(value,1,true),"missing "..value) end
local function absent(text,value) assert(not text:find(value,1,true),"unexpected "..value) end
local function session(name)
    local state=support.Session({ui=true,shared=true,name=name=="Birch Vale" and "Birch" or "Amber",fullName=name or "Amber Stone"})
    local api=state.api
    assert(api.Initialize()); assert(api.SharedService.Initialize())
    state.prepared={}
    api.Sharing={
        Connect=function(peer)
            if api.SharedService.IsEnabled() and api.SharedService.GetPeer()==peer then return true end
            if api.SharedService.IsEnabled() then assert(api.SharedService.Disable()) end
            return api.SharedService.Enable(peer)
        end,
        PrepareOffer=function(id)
            local offer=api.SharedService.GetOffer(id)
            if not offer then return nil,"Request unavailable." end
            local terms=assert(api.SharedCodec.ParseTerms(offer.terms))
            state.prepared[#state.prepared+1]=id
            return api.Sharing.Connect(offer.role=="proposer" and terms.recipient or terms.proposer)
        end,
    }
    return state
end
local function family(api,kind,agree,payment)
    local E=api.Shared
    local a,b=assert(E.New("Amber Stone")),assert(E.New("Birch Vale"))
    local terms={protocol=kind=="item" and 3 or 1,kind=kind=="item" and "ITEM_OBLIGATION" or "GOLD_OBLIGATION",
        proposer="Amber Stone",recipient="Birch Vale",debtor="Birch Vale",creditor="Amber Stone",
        amountCopper=kind=="item" and 20 or 10000,dueUTC=0,note="Cloth for Bj\195\184rn"}
    if kind=="item" then terms.itemKey,terms.itemName="item:2589","Linen Cloth" end
    local actions
    local clock=100
    local function now() clock=clock+1; return clock end
    a,actions=E.Propose(a,terms,"ag-request-1","request-1",now()); assert(a,actions)
    b=assert(E.Receive(b,"Amber Stone",actions[1].message,now()))
    local function commit(id)
        b,actions=E.Accept(b,id,now()); assert(b,actions)
        a,actions=E.Receive(a,"Birch Vale",actions[1].message,now()); assert(a,actions)
        b,actions=E.Receive(b,"Amber Stone",actions[1].message,now()); assert(b,actions)
        a=assert(E.Receive(a,"Birch Vale",actions[1].message,now()))
    end
    if agree then commit("request-1") end
    if payment then
        terms=assert(api.SharedPayments.BuildPayment(a,"request-1",payment,"Native item repayment",{}))
        a,actions=E.Propose(a,terms,"ag-request-2","request-2",now()); assert(a,actions)
        b=assert(E.Receive(b,"Amber Stone",actions[1].message,now()))
        commit("request-2")
    end
    return a,b
end
local function seed(state,store)
    local api=state.api
    local wrapper=state.env.IOUDB.sharedByCharacter[api.Character()]
    wrapper.store,wrapper.closedPaused=copy(store),{}
    api.OnSharedChanged()
end
local function realCoordinator(state)
    local chunk=assert(loadstring(assert(IOU_SOURCES["sharing.lua"]),"@IOU/sharing.lua"))
    setfenv(chunk,state.env); chunk("IOU",state.api)
    assert(state.api.Sharing.Initialize())
    assert(state.api.SharedService.IsBackground())
end

test("1.0 Requests opens compactly without connection chores, focus or consent",function()
    local state=session(); local api=state.api
    local before=copy(api.SharedService.GetStore())
    api.ShowShared()
    local board=api.UI.shared
    assert(board:GetHeight()<=650)
    assert(not board.connectionPanel:IsShown())
    assert(board.propose.enabled)
    assert(not board.peer:HasFocus() and not board.search:HasFocus())
    assert(same(before,api.SharedService.GetStore())); equal(#state.transportSent,0)
    state.click(board.more); state.click(board.connection)
    assert(board.connectionPanel:IsShown())
end)

test("1.0 incoming item request selects its player and exposes exact terms before Accept",function()
    local state=session("Birch Vale"); local api=state.api
    local _,remote=family(api,"item")
    seed(state,remote); api.ShowShared(nil,"inbox")
    local board=api.UI.shared
    assert(board.accept.enabled and board.decline.enabled)
    contains(board.details:GetText(),"You owe 20 x Linen Cloth")
    state.click(board.accept)
    local review=api.UI.sharedReview
    equal(state.prepared[1],"request-1")
    contains(review.details:GetText(),"Birch Vale owes Amber Stone")
    contains(review.details:GetText(),"Amount: 20 x Linen Cloth")
    contains(review.details:GetText(),"Cloth for Bj\195\184rn")
    absent(review.details:GetText(),"00c"); absent(review.details:GetText(),"request-1")
    equal(api.SharedService.GetOffer("request-1").consent,"NONE")
    state.click(review.confirm)
    equal(api.SharedService.GetOffer("request-1").state,"ACCEPT_PENDING")
end)

test("1.0 Decline connects automatically but changes consent only on confirmation",function()
    local state=session("Birch Vale"); local api=state.api
    local _,remote=family(api,"money")
    seed(state,remote); api.ShowShared(nil,"inbox")
    state.click(api.UI.shared.decline)
    equal(api.SharedService.GetOffer("request-1").consent,"NONE")
    state.click(api.UI.sharedReview.confirm)
    equal(api.SharedService.GetOffer("request-1").state,"DECLINE_PENDING")
    equal(#api.GetLedger().entries,0)
end)

test("1.0 stale item acceptance cannot accept a withdrawn request",function()
    local state=session("Birch Vale"); local api=state.api
    local remote,localStore=family(api,"item")
    seed(state,localStore); api.ShowShared(nil,"inbox"); state.click(api.UI.shared.accept)
    local review=api.UI.sharedReview
    local _,actions=api.Shared.Withdraw(remote,"request-1",120)
    localStore=assert(api.Shared.Receive(localStore,"Amber Stone",actions[1].message,121))
    seed(state,localStore)
    local before=copy(api.SharedService.GetStore())
    review.confirm.scripts.OnClick(review.confirm)
    assert(not review.confirm.enabled); contains(review.status:GetText(),"changed")
    assert(same(before,api.SharedService.GetStore()))
end)

test("1.0 closing Requests leaves the selected background session alone",function()
    local state=session(); local api=state.api
    assert(api.Sharing.Connect("Birch Vale")); api.ShowShared()
    local board=api.UI.shared
    board.peer:SetFocus(); board.search:SetFocus(); board:Hide()
    assert(api.SharedService.IsEnabled()); equal(api.SharedService.GetPeer(),"Birch Vale")
    assert(not board.peer:HasFocus() and not board.search:HasFocus())
end)

test("1.0 shared item proposal uses a quantity and full native identity",function()
    local state=session(); local api=state.api
    api.ShowShared("Birch Vale"); state.click(api.UI.shared.propose)
    local form=api.UI.sharedForm
    assert(form:IsShown() and form.peer.enabled)
    state.click(form.kindButtons.item)
    assert(form.itemGroup:IsShown() and not form.moneyGroup:IsShown())
    form.item:SetText("|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r")
    form.quantity:SetText("12"); state.click(form.send)
    local offer=assert(api.SharedService.List()[1])
    local terms=assert(api.SharedCodec.ParseTerms(offer.terms))
    equal(terms.kind,"ITEM_OBLIGATION"); equal(terms.amountCopper,12)
    equal(terms.itemKey,"item:2589"); equal(terms.itemName,"Linen Cloth")
    equal(terms.recipient,"Birch Vale"); equal(offer.consent,"PROPOSE")
end)

test("1.0 shared item balance and correction details never render quantity as gold",function()
    local state=session(); local api=state.api
    local localStore=family(api,"item",true,7)
    seed(state,localStore); api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    contains(board.details:GetText(),"Owes you 13 x Linen Cloth")
    state.click(board.detailToggle)
    contains(board.details:GetText(),"Remaining: 13 x Linen Cloth")
    contains(board.details:GetText(),"Payment #2: 7 x Linen Cloth")
    absent(board.details:GetText(),"00c")
    api.ShowSharedPayment("request-1","payment")
    local form=api.UI.sharedPaymentForm
    assert(form.isItem and form.quantityGroup:IsShown() and not form.moneyGroup:IsShown())
    contains(form.context:GetText(),"Remaining 13 x Linen Cloth")
    form.quantity:SetText("2"); state.click(form.send)
    local offers=api.SharedService.List(); local found
    for _,offer in ipairs(offers) do
        local terms=api.SharedCodec.ParseTerms(offer.terms)
        if terms.kind=="ITEM_PAYMENT" and terms.amountCopper==2 then found=offer end
    end
    assert(found,"quantity payment was not proposed")
end)

test("1.0 item review Details is read only and keeps the original native identity",function()
    local state=session("Birch Vale"); local api=state.api
    local _,remote=family(api,"item")
    seed(state,remote); api.ShowShared(nil,"inbox"); state.click(api.UI.shared.accept)
    local before=copy(api.SharedService.GetStore())
    local review=api.UI.sharedReview
    state.click(review.detailToggle)
    contains(review.details:GetText(),"Amount: 20 x Linen Cloth")
    contains(review.details:GetText(),"Offer: request-1")
    contains(review.details:GetText(),"Item: item:2589")
    state.click(review.detailToggle)
    assert(same(before,api.SharedService.GetStore()))
    equal(api.SharedService.GetOffer("request-1").consent,"NONE")
end)

test("1.0 older confirmed shared IOUs have a deliberate Add to ledger action",function()
    local state=session(); local api=state.api
    local localStore=family(api,"item",true)
    seed(state,localStore)
    local adopted
    api.Sharing.Adopt=function(id) adopted=id; return true end
    api.ShowShared(nil,"agreements"); state.click(api.UI.shared.more)
    local board=api.UI.shared
    assert(board.adopt:IsShown() and board.adopt.enabled)
    state.click(board.adopt); equal(adopted,"request-1")
    contains(board.status:GetText(),"Added to your ledger")
    adopted=nil
    local callback=board.adopt.scripts.OnClick
    state.click(board.more); state.click(board.filterButtons.history)
    callback(board.adopt); equal(adopted,nil)
end)

test("1.0 real background coordinator prepares an incoming item decision without setup",function()
    local state=session("Birch Vale"); local api=state.api
    realCoordinator(state)
    local _,remote=family(api,"item")
    seed(state,remote); api.ShowShared(nil,"inbox")
    assert(not api.UI.shared.connectionPanel:IsShown())
    equal(api.SharedService.GetOffer("request-1").consent,"NONE")
    state.click(api.UI.shared.accept)
    local review=api.UI.sharedReview
    assert(review.confirm.enabled); contains(review.details:GetText(),"20 x Linen Cloth")
    state.click(review.confirm)
    equal(api.SharedService.GetOffer("request-1").state,"ACCEPT_PENDING")
    api.UI.shared:Hide()
    assert(api.SharedService.IsBackground())
end)

test("1.0 real background coordinator sends a new item request from an unconnected board",function()
    local state=session(); local api=state.api
    realCoordinator(state)
    api.ShowShared("Birch Vale"); state.click(api.UI.shared.propose)
    local form=api.UI.sharedForm
    state.click(form.kindButtons.item)
    form.item:SetText("|Hitem:2589|h[Linen Cloth]|h"); form.quantity:SetText("8")
    state.click(form.send)
    assert(not form:IsShown(),form.status:GetText())
    local offers=assert(api.SharedService.List()); equal(#offers,1)
    local terms=assert(api.SharedCodec.ParseTerms(offers[1].terms))
    equal(terms.kind,"ITEM_OBLIGATION"); equal(terms.amountCopper,8)
    equal(terms.recipient,"Birch Vale"); assert(api.SharedService.IsBackground())
end)

return results
