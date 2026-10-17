-- Complete synthetic addon sessions: compact presentation must never change
-- consent, hide decision terms, or bypass live checks on financial actions.
local support=assert(IOU_TEST_SUPPORT,"Run after tools/test_iou.lua.")
local copy,same=support.Copy,support.Same
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(text,value) assert(text:find(value,1,true),"missing "..value) end
local function absent(text,value) assert(not text:find(value,1,true),"unexpected "..value) end
local function session()
    local state=support.Session({ui=true,shared=true,name="Amber",fullName="Amber Stone"})
    assert(state.api.Initialize()); assert(state.api.SharedService.Initialize())
    return state
end
local function fixture(state,options)
    options=options or {}
    local api=state.api
    local E=api.Shared
    local a,b=assert(E.New("Amber Stone")),assert(E.New("Birch Vale"))
    local actions,clock=nil,100
    local function now() clock=clock+1; return clock end
    local terms={protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor="Birch Vale",creditor="Amber Stone",amountCopper=10000,dueUTC=options.due or 0,
        note=options.note or ""}
    a,actions=E.Propose(a,terms,"ag-compact-1","compact-1",now()); assert(a,actions)
    b=assert(E.Receive(b,"Amber Stone",actions[1].message,now()))
    local function agree(id)
        b,actions=E.Accept(b,id,now()); assert(b,actions)
        a,actions=E.Receive(a,"Birch Vale",actions[1].message,now()); assert(a,actions)
        b,actions=E.Receive(b,"Amber Stone",actions[1].message,now()); assert(b,actions)
        a=assert(E.Receive(a,"Birch Vale",actions[1].message,now()))
    end
    agree("compact-1")
    if options.payment then
        local event=assert(api.SharedPayments.BuildPayment(a,"compact-1",options.payment,"First repayment Bj\195\184rn",{}))
        a,actions=E.Propose(a,event,"ag-compact-2","compact-2",now()); assert(a,actions)
        b=assert(E.Receive(b,"Amber Stone",actions[1].message,now()))
        agree("compact-2")
    end
    if options.correction then
        local event=assert(api.SharedPayments.BuildCorrection(a,"compact-1","compact-2","Correction note",{}))
        a,actions=E.Propose(a,event,"ag-compact-3","compact-3",now()); assert(a,actions)
        b=assert(E.Receive(b,"Amber Stone",actions[1].message,now()))
    end
    local wrapper=state.env.IOUDB.sharedByCharacter[api.Character()]
    wrapper.store=copy(a); wrapper.closedPaused={}
    api.OnSharedChanged()
    return a,b
end
local function receiver(store)
    local state=support.Session({ui=true,shared=true,name="Birch",fullName="Birch Vale"})
    assert(state.api.Initialize()); assert(state.api.SharedService.Initialize())
    local wrapper=state.env.IOUDB.sharedByCharacter[state.api.Character()]
    wrapper.store=copy(store); wrapper.closedPaused={}
    state.api.OnSharedChanged()
    state.api.ShowShared("Amber Stone","inbox")
    state.click(state.api.UI.shared.enable)
    return state
end

test("compact Shared board shows remaining debt and keeps history behind Details without changing records",function()
    local state=session(); fixture(state,{payment=3000})
    local api=state.api; api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    local before=copy(api.SharedService.GetStore())
    local text=board.details:GetText()
    contains(text,"Birch Vale"); contains(text,"Owes you 70s")
    contains(text,"Original 1g  /  Paid 30s")
    absent(text,"History"); absent(text,"compact-1"); absent(text,"No deadline"); absent(text,"(none)")
    state.click(board.detailToggle)
    contains(board.details:GetText(),"History")
    contains(board.details:GetText(),"Offer: compact-1")
    contains(board.details:GetText(),"First repayment Bj\195\184rn")
    state.click(board.detailToggle)
    absent(board.details:GetText(),"History")
    assert(same(before,api.SharedService.GetStore())); equal(#state.transportSent,0)
end)

test("compact Shared note preview retains full Unicode text through Details",function()
    local state=session()
    local note=string.rep("Bj\195\184rn bl\195\165b\195\166r ",20)
    fixture(state,{note=note}); state.api.ShowShared(nil,"agreements")
    local board=state.api.UI.shared
    contains(board.details:GetText(),"..."); absent(board.details:GetText(),note)
    state.click(board.detailToggle); contains(board.details:GetText(),note)
    state.click(board.filterButtons.history)
    assert(not board.showDetails and not board.detailToggle.enabled)
end)

test("Shared manual actions and backups stay in More and follow current eligibility",function()
    local state=session(); fixture(state,{payment=3000})
    local api=state.api; api.ShowShared("Birch Vale","agreements")
    local board=api.UI.shared
    assert(not board.payment:IsShown() and not board.settle:IsShown() and not board.correction:IsShown())
    assert(not board.backups:IsShown() and not board.filterButtons.all:IsShown())
    state.click(board.more)
    assert(board.backups:IsShown() and board.filterButtons.all:IsShown())
    assert(not board.payment:IsShown() and not board.correction:IsShown())
    equal(board.moreMenu:GetHeight(),96)
    state.click(board.more); state.click(board.enable); state.click(board.more)
    assert(board.payment:IsShown() and board.payment.enabled)
    assert(board.settle:IsShown() and board.correction:IsShown())
    equal(board.moreMenu:GetHeight(),204)
    state.click(board.payment)
    assert(api.UI.sharedPaymentForm:IsShown() and not board.moreMenu:IsShown())
    equal(api.SharedService.GetBalance("compact-1").remainingCopper,7000)
    equal(#state.transportSent,0)
end)

test("compact Shared decision exposes exact parent and event terms before acceptance",function()
    local source=session()
    local _,remote=fixture(source,{payment=3000,correction=true,note="Original full note",due=1893455999})
    local state=receiver(remote); local api=state.api
    api.ShowSharedReview("compact-3","accept")
    local review=api.UI.sharedReview
    equal(review:GetHeight(),420)
    local text=review.details:GetText()
    contains(text,"Birch Vale owes Amber Stone")
    contains(text,"Undo payment: 30s"); contains(text,"Undo payment #2")
    contains(text,"Payment note: First repayment Bj\195\184rn")
    contains(text,"Original IOU: 1g"); contains(text,"Balance: 70s -> 1g")
    contains(text,"Original full note"); contains(text,"Original due:"); contains(text,"Correction note")
    absent(text,"compact-3"); absent(text,"History"); absent(text,"Previously confirmed")
    equal(api.SharedService.GetOffer("compact-3").consent,"NONE")
    state.click(review.detailToggle)
    equal(review:GetHeight(),666)
    contains(review.details:GetText(),"Previously confirmed payments and corrections")
    contains(review.details:GetText(),"First repayment Bj\195\184rn")
    contains(review.details:GetText(),"Offer: compact-3")
    equal(api.SharedService.GetOffer("compact-3").consent,"NONE")
    state.click(review.detailToggle); state.click(review.confirm)
    equal(api.SharedService.GetOffer("compact-3").state,"ACCEPT_PENDING")
end)

test("Shared proposal optional fields collapse without discarding entered terms",function()
    local state=session(); local api=state.api
    api.ShowShared("Birch Vale"); state.click(api.UI.shared.enable); api.ShowSharedProposal()
    local form=api.UI.sharedForm
    equal(form:GetHeight(),400); assert(not form.due:IsShown() and not form.note:IsShown())
    state.click(form.options); equal(form:GetHeight(),550)
    assert(form.due:IsShown() and form.note:IsShown())
    form.due:SetText("2030-01-01"); form.note:SetText("Optional exact note")
    form.note:SetFocus(); state.click(form.options)
    assert(not form.note:HasFocus()); equal(form.note:GetText(),"Optional exact note")
    form.money:Fill(10000); state.click(form.send)
    local offer=api.SharedService.List()[1]
    local terms=assert(api.SharedCodec.ParseTerms(offer.terms))
    equal(terms.note,"Optional exact note"); equal(terms.dueUTC,assert(api.ParseSharedDueDate("2030-01-01")))
    equal(offer.state,"OFFER_OPEN")
end)

test("compact payment drafts keep their live agreement and peer checks",function()
    local state=session(); fixture(state,{payment=3000})
    local api=state.api; api.ShowShared("Birch Vale","agreements")
    local board=api.UI.shared; state.click(board.enable); state.click(board.more); state.click(board.payment)
    local form=api.UI.sharedPaymentForm
    assert(form:GetHeight()<600,"partial payment still uses an oversized dialog")
    contains(form.context:GetText(),"Remaining 70s")
    absent(form.context:GetText(),"Payment and correction history")
    state.click(form.detailToggle)
    contains(form.context:GetText(),"Payment and correction history")
    form.money:Fill(1000)
    assert(api.SharedService.Disable()); assert(api.SharedService.Enable("Cedar Grove"))
    local before=copy(api.SharedService.GetStore())
    form.send.scripts.OnClick(form.send)
    assert(not form.send.enabled); contains(form.status:GetText(),"changed")
    assert(same(before,api.SharedService.GetStore()))
end)

test("compact request review preserves an exact non-midnight UTC deadline",function()
    local source=session(); local api=source.api; local E=api.Shared
    local due=1893450123
    local terms={protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor="Birch Vale",creditor="Amber Stone",amountCopper=10000,dueUTC=due,note="Exact deadline"}
    local _,actions=E.Propose(assert(E.New("Amber Stone")),terms,"ag-deadline","deadline",100)
    local remote=assert(E.Receive(assert(E.New("Birch Vale")),"Amber Stone",actions[1].message,101))
    local state=receiver(remote); local before=copy(state.api.SharedService.GetStore())
    state.api.ShowSharedReview("deadline","accept")
    local review=state.api.UI.sharedReview
    contains(review.details:GetText(),"Due "..state.env.date("!%d %b %Y %H:%M:%S UTC",due))
    contains(review.details:GetText(),"Exact deadline")
    state.click(review.detailToggle); state.click(review.detailToggle)
    assert(same(before,state.api.SharedService.GetStore()))
    equal(state.api.SharedService.GetOffer("deadline").consent,"NONE")
end)

test("Shared More callbacks cannot redirect an action after the selection changes",function()
    local state=session(); fixture(state,{payment=3000})
    local api=state.api; api.ShowShared("Birch Vale","agreements")
    local board=api.UI.shared; state.click(board.enable); state.click(board.more)
    local action=board.payment.scripts.OnClick
    api.SelectSharedOffer("compact-2")
    local before=copy(api.SharedService.GetStore())
    action(board.payment)
    equal(api.UI.sharedPaymentForm,nil)
    contains(board.status:GetText(),"changed")
    assert(same(before,api.SharedService.GetStore())); equal(#state.transportSent,0)
end)

return results
