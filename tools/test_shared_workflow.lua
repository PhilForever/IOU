-- Shared workflow checks use complete addon sessions, real consent/payment
-- records, and framed incoming packets. All names and notes are synthetic.
local support=assert(IOU_TEST_SUPPORT,"Run through tools/test_iou.py.")
local copy,same=support.Copy,support.Same
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(actual,expected,note)
    assert(actual==expected,(note or "unexpected value")..": expected "..tostring(expected)..", got "..tostring(actual))
end
local function contains(text,value)
    assert(type(text)=="string" and text:find(value,1,true),"missing text: "..value)
end
local function newSession(options)
    options=options or {}
    options.ui,options.shared=true,true
    options.name,options.fullName="Amber","Amber Stone"
    local state=support.Session(options)
    assert(state.api.Initialize()); assert(state.api.SharedService.Initialize())
    return state
end

-- Build records through the actual pure engine; no tests fabricate consent.
local function family(api,id,options)
    options=options or {}
    local E=api.Shared
    local proposer=options.incoming and (options.peer or "Birch Vale") or "Amber Stone"
    local recipient=options.incoming and "Amber Stone" or (options.peer or "Birch Vale")
    local a,b=assert(E.New(proposer)),assert(E.New(recipient))
    local clock=options.at or 100
    local function stamp() clock=clock+1; return clock end
    local actions
    local terms={protocol=1,kind="GOLD_OBLIGATION",proposer=proposer,recipient=recipient,
        debtor="Amber Stone",creditor=options.peer or "Birch Vale",amountCopper=options.amount or 10000,
        dueUTC=0,note=options.note or "Synthetic workflow agreement"}
    a,actions=E.Propose(a,terms,"ag-"..id,id,stamp()); assert(a,actions)
    b=assert(E.Receive(b,proposer,actions[1].message,stamp()))
    local function agree(offerId,phase)
        b,actions=E.Accept(b,offerId,stamp()); assert(b,actions)
        if phase=="accept" then return end
        a,actions=E.Receive(a,recipient,actions[1].message,stamp()); assert(a,actions)
        if phase=="commit" then return end
        b,actions=E.Receive(b,proposer,actions[1].message,stamp()); assert(b,actions)
        if phase=="ack" then return end
        a=assert(E.Receive(a,recipient,actions[1].message,stamp()))
    end
    if options.state=="accepted" then agree(id,"accept")
    elseif options.state=="ack" then agree(id,"ack")
    elseif options.state=="agreed" or options.partial or options.settled or options.pendingCorrection then agree(id)
    elseif options.state=="declined" then
        b,actions=E.Decline(b,id,stamp()); assert(b,actions)
        a,actions=E.Receive(a,recipient,actions[1].message,stamp()); assert(a,actions)
        b=assert(E.Receive(b,proposer,actions[1].message,stamp()))
    elseif options.state=="decline-pending" then
        b,actions=E.Decline(b,id,stamp()); assert(b,actions)
    elseif options.state=="withdrawn" then
        a,actions=E.Withdraw(a,id,stamp()); assert(a,actions)
        b=assert(E.Receive(b,proposer,actions[1].message,stamp()))
    end
    if options.partial or options.settled or options.pendingCorrection then
        local amount=options.settled or options.pendingCorrection and terms.amountCopper or options.partial
        local event=assert(api.SharedPayments.BuildPayment(a,id,amount,"Payment note [raid] 100% Bj\195\184rn",{}))
        a,actions=E.Propose(a,event,"ag-"..id.."-payment",id.."-payment",stamp()); assert(a,actions)
        b=assert(E.Receive(b,proposer,actions[1].message,stamp()))
        agree(id.."-payment")
        if options.pendingCorrection then
            event=assert(api.SharedPayments.BuildCorrection(a,id,id.."-payment","Correction evidence",{}))
            a,actions=E.Propose(a,event,"ag-"..id.."-correction",id.."-correction",stamp()); assert(a,actions)
            b=assert(E.Receive(b,proposer,actions[1].message,stamp()))
        end
    end
    local result=options.incoming and b or a
    if options.paused then result=assert(E.Pause(result,stamp())) end
    assert(E.Validate(result)); assert(api.SharedPayments.Validate(result,{}))
    return result
end
local function seed(state,cases)
    local api=state.api
    local store=assert(api.Shared.New("Amber Stone"))
    local closed={}
    for _,case in ipairs(cases) do
        local source=family(api,case.id,case)
        store.serial=store.serial+source.serial
        for id,offer in pairs(source.offers) do
            assert(not store.offers[id],"fixture repeated an offer id")
            store.offers[id]=copy(offer)
        end
        if case.closed then closed[case.id]={at=900,reason="Reviewed synthetic interrupted offer"} end
    end
    assert(api.Shared.Validate(store)); assert(api.SharedPayments.Validate(store,closed))
    local entry=assert(state.env.IOUDB.sharedByCharacter[api.Character()])
    entry.store,entry.closedPaused=copy(store),copy(closed)
    api.OnSharedChanged()
    return store
end
local function visibleIds(board)
    local ids={}
    for _,row in ipairs(board.rows) do
        if row:IsShown() and row.offerId then ids[#ids+1]=row.offerId end
    end
    table.sort(ids); return table.concat(ids,",")
end
local function expectIds(state,filter,ids)
    local board=state.api.UI.shared
    if board.filter~=filter then
        if filter=="all" then state.click(board.more) end
        state.click(board.filterButtons[filter])
    end
    while board.previous.enabled do state.click(board.previous) end
    local found={}
    repeat
        for _,row in ipairs(board.rows) do
            if row:IsShown() and row.offerId then found[#found+1]=row.offerId end
        end
        if not board.next.enabled then break end
        state.click(board.next)
    until false
    while board.previous.enabled do state.click(board.previous) end
    table.sort(ids); table.sort(found)
    equal(table.concat(found,","),table.concat(ids,","),filter.." visible offers")
end
local function deliverProposal(state,id,note)
    local api=state.api
    local E=api.Shared
    local remote,actions=E.Propose(assert(E.New("Birch Vale")),
        {protocol=1,kind="GOLD_OBLIGATION",proposer="Birch Vale",recipient="Amber Stone",
            debtor="Amber Stone",creditor="Birch Vale",amountCopper=1234,dueUTC=0,note=note or "Incoming review"},
        "ag-"..id,id,math.floor(state.now))
    assert(remote,actions)
    local frames=assert(api.SharedWire.Frame("workflow-"..id,assert(api.SharedCodec.Encode(actions[1].message))))
    for _,frame in ipairs(frames) do
        state.event("CHAT_MSG_ADDON_LOGGED",api.SharedWire.PREFIX,frame,"WHISPER","Birch Vale")
    end
end

test("workflow overview validates once and returns detached offers and derived balances",function()
    local state=newSession(); local api=state.api
    seed(state,{{id="partial",partial=3500}})
    local P=api.SharedPayments
    local original,calls=P.Views,0
    P.Views=function(...) calls=calls+1; return original(...) end
    local overview=assert(api.SharedService.GetOverview())
    equal(calls,1,"overview repeated whole-store validation")
    P.Views=original
    equal(overview.localName,"Amber Stone"); equal(overview.peer,nil)
    equal(#overview.offers,2); equal(overview.balances.partial.remainingCopper,6500)
    local before=copy(api.SharedService.GetStore())
    overview.offers[1].terms="caller changed detached terms"
    overview.balances.partial.remainingCopper=1
    overview.balances.partial.events[1].note="caller changed detached event"
    assert(same(before,api.SharedService.GetStore()))
    equal(api.SharedService.GetBalance("partial").remainingCopper,6500)
    equal(#state.transportSent,0)
end)

test("workflow first opening selects useful review, agreement, sent and history views",function()
    for _,case in ipairs({
        {id="incoming",incoming=true,expected="inbox"},
        {id="agreed",state="agreed",expected="agreements"},
        {id="ack",state="ack",expected="waiting"},
        {id="withdrawn",state="withdrawn",expected="history"},
    }) do
        local state=newSession(); seed(state,{case})
        state.api.ShowShared()
        equal(state.api.UI.shared.filter,case.expected)
        equal(state.api.UI.shared.selected,case.id)
        assert(not state.api.SharedService.IsEnabled())
        equal(#state.transportSent,0)
    end
end)

test("workflow closing Shared hides drafts and reviews without changing the selected connection or consent",function()
    local state=newSession(); local api=state.api
    seed(state,{{id="incoming",incoming=true},{id="partial",partial=3500}})
    api.ShowShared("Birch Vale","all")
    local board=api.UI.shared
    equal(board.enable:GetText(),"Connect")
    equal(board.filterButtons.waiting:GetText(),"Sent (0)")
    state.click(board.enable)
    api.ShowSharedProposal()
    local proposal=api.UI.sharedForm
    proposal.note:SetText("Unsent draft")
    api.ShowSharedPayment("partial","payment")
    local payment=api.UI.sharedPaymentForm
    assert(payment and payment:IsShown())
    api.ShowSharedReview("incoming","accept")
    local review=api.UI.sharedReview
    assert(proposal:IsShown() and review:IsShown())
    proposal.note:SetFocus()
    local before=copy(api.SharedService.GetStore())
    board:Hide()
    assert(not proposal:IsShown() and not payment:IsShown() and not review:IsShown())
    assert(not proposal.note:HasFocus() and not board.peer:HasFocus() and not board.search:HasFocus())
    assert(api.SharedService.IsEnabled())
    equal(api.SharedService.GetPeer(),"Birch Vale")
    assert(same(before,api.SharedService.GetStore()),"hiding changed retained consent or balances")
    equal(api.SharedService.GetOffer("incoming").state,"OFFER_RECEIVED")
    equal(api.SharedService.GetOffer("incoming").consent,"NONE")
    equal(#state.transportSent,0)
end)

test("workflow a hidden Shared board receives requests and can later accept them without reconnecting",function()
    local state=newSession(); local api=state.api
    api.ShowShared("Birch Vale")
    local board=api.UI.shared
    state.click(board.enable); board:Hide()
    deliverProposal(state,"hidden-incoming")
    assert(not board:IsShown(),"an incoming request opened the hidden board")
    equal(api.GetSharedAttention().count,1)
    local received=assert(api.SharedService.GetOffer("hidden-incoming"))
    equal(received.state,"OFFER_RECEIVED"); equal(received.consent,"NONE")
    state.advance(600)
    equal(api.SharedService.GetOffer("hidden-incoming").state,"OFFER_RECEIVED","time spent outside the board paused the request")
    assert(api.SharedService.IsEnabled())
    api.ShowShared(nil,"inbox")
    assert(board.accept.enabled)
    state.click(board.accept)
    local review=api.UI.sharedReview
    assert(review:IsShown() and review.confirm.enabled)
    board:Hide()
    equal(api.SharedService.GetOffer("hidden-incoming").consent,"NONE","closing a review accepted the request")
    api.ShowShared(nil,"inbox"); state.click(board.accept); state.click(review.confirm)
    equal(api.SharedService.GetOffer("hidden-incoming").state,"ACCEPT_PENDING")
    equal(api.SharedService.GetOffer("hidden-incoming").terms,received.terms)
end)

test("workflow explicit Disconnect and shared off still pause unfinished requests and stop queued packets",function()
    for _,method in ipairs({"button","slash"}) do
        local state=newSession(); local api=state.api
        api.ShowShared("Birch Vale")
        local board=api.UI.shared
        state.click(board.enable); state.click(board.propose)
        local form=api.UI.sharedForm
        form.money:Fill(10000); state.click(form.send)
        local offer=api.SharedService.List()[1]
        equal(offer.state,"OFFER_OPEN")
        board:Hide(); assert(api.SharedService.IsEnabled())
        if method=="button" then
            api.ShowShared(); state.click(board.stop)
        else state.env.SlashCmdList.IOU("shared off") end
        assert(not api.SharedService.IsEnabled())
        local paused=api.SharedService.GetOffer(offer.offerId)
        equal(paused.state,"PAUSED"); equal(paused.consent,"PROPOSE")
        equal(paused.messages.accept,nil); equal(paused.messages.commit,nil)
        state.advance(60); equal(#state.transportSent,0,"explicit disconnection left outgoing packets queued")
    end
end)

test("workflow closing an interrupted request records no acceptance or agreement",function()
    local state=newSession(); local api=state.api
    seed(state,{{id="paused-incoming",incoming=true,paused=true}})
    api.ShowShared(nil,"inbox")
    local board=api.UI.shared
    assert(board.closePaused.enabled)
    state.click(board.closePaused)
    local review=api.UI.sharedReview
    equal(review.title:GetText(),"Close interrupted request")
    equal(review.confirm:GetText(),"Close locally")
    contains(review.explanation:GetText(),"does not accept the request")
    local before=copy(api.SharedService.GetStore())
    state.click(review.confirm)
    local offer=api.SharedService.GetOffer("paused-incoming")
    equal(offer.state,"PAUSED"); equal(offer.consent,"NONE")
    assert(offer.localClosed)
    equal(offer.messages.accept,nil); equal(offer.messages.commit,nil)
    assert(same(before,api.SharedService.GetStore()),"closing invented acceptance or protocol history")
    equal(#state.transportSent,0)
    equal(api.GetSharedAttention().count,0)
end)

test("workflow views separate consent waiting, active agreements, completed events and local reviews",function()
    local state=newSession()
    seed(state,{{id="incoming",incoming=true},{id="paused",paused=true},
        {id="agreed",state="agreed"},{id="partial",partial=3500},
        {id="sent"},{id="ack",state="ack"},{id="accepted",incoming=true,state="accepted"},
        {id="declined",state="declined"},{id="withdrawn",state="withdrawn"},
        {id="closed",paused=true,closed=true},{id="settled",settled=10000}})
    state.api.ShowShared()
    expectIds(state,"inbox",{"incoming","paused"})
    expectIds(state,"agreements",{"agreed","partial"})
    expectIds(state,"waiting",{"sent","ack","accepted"})
    expectIds(state,"history",{"declined","withdrawn","closed","partial-payment","settled","settled-payment"})
    equal(state.api.GetSharedAttention().count,2)
    local before=copy(state.api.SharedService.GetStore())
    state.click(state.api.UI.shared.more); state.click(state.api.UI.shared.filterButtons.all)
    assert(same(before,state.api.SharedService.GetStore()))
    equal(#state.transportSent,0)
end)

test("workflow settled parents with an unfinished correction remain in agreements",function()
    local state=newSession(); seed(state,{{id="reopening",pendingCorrection=true}})
    state.api.ShowShared(nil,"agreements")
    expectIds(state,"agreements",{"reopening"})
    expectIds(state,"waiting",{"reopening-correction"})
    expectIds(state,"history",{"reopening-payment"})
    equal(state.api.SharedService.GetBalance("reopening").remainingCopper,0)
end)

test("workflow literal search preserves global counts and finds full peer, notes and event kinds",function()
    local state=newSession()
    seed(state,{{id="partial",partial=3500,peer="Birch Vale"},
        {id="incoming",incoming=true,peer="Cedar Grove",note="Separate note"}})
    local api=state.api; api.ShowShared(nil,"all")
    local board=api.UI.shared
    local captions={}
    for key,button in pairs(board.filterButtons) do captions[key]=button:GetText() end
    for _,query in ipairs({"[raid]","100%","Bj\195\184rn","payment"}) do
        board.search:SetText(query)
        equal(visibleIds(board),"partial-payment",query)
        for key,button in pairs(board.filterButtons) do equal(button:GetText(),captions[key],"search changed global count") end
    end
    board.search:SetText("bIRCH vALE")
    equal(visibleIds(board),"partial,partial-payment")
    board.search:SetText(".*")
    equal(visibleIds(board),""); contains(board.listEmpty:GetText(),"No")
    state.click(board.clearSearch)
    equal(board.search:GetText(),"")
    equal(visibleIds(board),"incoming,partial,partial-payment")
    equal(api.GetSharedAttention().count,1); equal(#state.transportSent,0)
end)

test("workflow typing and clearing a search over the selected event reuses its validated snapshot",function()
    local state=newSession(); seed(state,{{id="partial",partial=3500}})
    local api=state.api; api.ShowShared(nil,"history")
    local board=api.UI.shared
    equal(board.selected,"partial-payment")
    local overview,views=api.SharedService.GetOverview,api.SharedPayments.Views
    local reads=0
    api.SharedService.GetOverview=function(...) reads=reads+1; return overview(...) end
    api.SharedPayments.Views=function(...) reads=reads+1; return views(...) end
    board.search:SetFocus()
    for _,query in ipairs({"p","pa","pay","payment","Payment note"}) do
        board.search:SetText(query)
        equal(board.selected,"partial-payment")
        assert(board.search:HasFocus())
    end
    state.click(board.clearSearch)
    equal(reads,0,"per-keystroke search repeated Shared storage reads or whole-store validation")
    equal(#state.transportSent,0)
    api.SharedService.GetOverview,api.SharedPayments.Views=overview,views
end)

test("workflow search changes selections and empty results without storage reads while a decision review stays open",function()
    local state=newSession()
    seed(state,{{id="partial",partial=3500},
        {id="incoming",incoming=true,note="Incoming exact decision terms"}})
    local api=state.api; api.ShowShared("Birch Vale","all")
    local board=api.UI.shared
    state.click(board.enable)
    api.ShowSharedReview("incoming","accept")
    local review=api.UI.sharedReview
    assert(review and review:IsShown() and review.confirm.enabled)
    equal(review.offerId,"incoming")
    local before=copy(api.SharedService.GetStore())
    local terms=review.terms
    local methods,reads={},0
    for _,name in ipairs({"GetOverview","GetOffer","GetBalance"}) do
        local key=name
        methods[key]=api.SharedService[key]
        api.SharedService[key]=function(...)
            reads=reads+1; return methods[key](...)
        end
    end
    local views=api.SharedPayments.Views
    api.SharedPayments.Views=function(...) reads=reads+1; return views(...) end
    for _,case in ipairs({
        {query="Payment note",selected="partial-payment"},
        {query="Synthetic workflow agreement",selected="partial"},
        {query="No matching synthetic term"},
        {query="Incoming exact decision terms",selected="incoming"},
    }) do
        board.search:SetText(case.query)
        equal(board.selected,case.selected,"search did not reach the intended selected record")
        assert(review:IsShown() and review.confirm.enabled,"browsing changed the open decision")
        equal(review.offerId,"incoming"); equal(review.terms,terms)
    end
    equal(reads,0,"search revalidated live storage while rendering another selected record or an empty result")
    for name,method in pairs(methods) do api.SharedService[name]=method end
    api.SharedPayments.Views=views
    assert(same(before,api.SharedService.GetStore()))
    equal(#state.transportSent,0)
    -- Confirmation still performs its fresh record/connection check and applies
    -- the exact reviewed incoming offer, not a previous search result.
    local getOffer,calls=api.SharedService.GetOffer,0
    api.SharedService.GetOffer=function(...) calls=calls+1; return getOffer(...) end
    state.click(review.confirm)
    assert(calls>0,"confirmation reused the cached browsing snapshot")
    api.SharedService.GetOffer=getOffer
    equal(api.SharedService.GetOffer("incoming").state,"ACCEPT_PENDING")
    equal(api.SharedService.GetOffer("incoming").terms,terms)
    equal(api.SharedService.GetOffer("partial").state,"COMMITTED")
end)

test("workflow original rows show current remaining while child rows retain event amount",function()
    local state=newSession(); seed(state,{{id="partial",partial=3500}})
    state.api.ShowShared(nil,"all")
    local found={}
    for _,row in ipairs(state.api.UI.shared.rows) do
        if row.offerId and row:IsShown() then found[row.offerId]=row end
    end
    contains(found.partial.amount:GetText(),"65s")
    contains(found["partial-payment"].amount:GetText(),"35s")
    contains(found["partial-payment"].title:GetText(),"Payment")
end)

test("workflow pagination stays bounded and explicit offer selection reveals a hidden event",function()
    local state=newSession(); local cases={}
    for index=1,11 do cases[#cases+1]={id="parent-"..index,state="agreed",at=index*10} end
    cases[#cases+1]={id="partial",partial=3500,at=200}
    seed(state,cases)
    local api=state.api; api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    state.click(board.next); state.click(board.next)
    equal(board.page,3); assert(not board.next.enabled)
    board.search:SetText("No such synthetic note")
    equal(board.page,1); assert(not board.next.enabled and not board.previous.enabled)
    api.SelectSharedOffer("partial-payment")
    equal(board.search:GetText(),"")
    equal(board.selected,"partial-payment")
    local selectedVisible=false
    for _,row in ipairs(board.rows) do if row:IsShown() and row.offerId==board.selected then selectedVisible=true end end
    assert(selectedVisible,"explicitly selected child is hidden on another page or filter")
    equal(#state.transportSent,0)
end)

test("workflow clearing search while revealing an older offer preserves the requested selection and page",function()
    local state=newSession(); local cases={{id="older",partial=3500,at=100}}
    for index=1,6 do cases[#cases+1]={id="newer-"..index,settled=10000,at=200+index*20} end
    seed(state,cases)
    local api=state.api; api.ShowShared(nil,"all")
    local board=api.UI.shared
    board.search:SetText("No matching synthetic term")
    api.SelectSharedOffer("older-payment")
    equal(board.search:GetText(),"")
    equal(board.selected,"older-payment","clearing search replaced the explicit target")
    assert(board.page>1,"older offer was not revealed on its actual page")
    local found=false
    for _,row in ipairs(board.rows) do if row:IsShown() and row.offerId=="older-payment" then found=true end end
    assert(found,"explicit older target remains hidden")
    equal(#state.transportSent,0)
end)

test("workflow selected-peer enable is explicit and never switches an active peer",function()
    local state=newSession(); seed(state,{{id="first",state="agreed"},{id="second",state="agreed",peer="Cedar Grove"}})
    local api=state.api; api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    api.SelectSharedOffer("first")
    assert(not api.SharedService.IsEnabled() and board.connectSelected.enabled)
    state.click(board.connectSelected)
    equal(api.SharedService.GetPeer(),"Birch Vale")
    equal(board.peer:GetText(),"Birch Vale")
    api.SelectSharedOffer("second")
    assert(not board.connectSelected.enabled,"selection permits silently switching the active peer")
    board.connectSelected.scripts.OnClick(board.connectSelected)
    equal(api.SharedService.GetPeer(),"Birch Vale")
    equal(#state.transportSent,0)
end)

test("workflow stale selected-peer callbacks cannot enable a different reviewed offer",function()
    local state=newSession(); seed(state,{{id="first",state="agreed"},{id="second",state="agreed",peer="Cedar Grove"}})
    local api=state.api; api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    api.SelectSharedOffer("first"); assert(board.connectSelected.enabled)
    board.selected="second" -- Deliberate stale callback; no intervening refresh.
    board.connectSelected.scripts.OnClick(board.connectSelected)
    assert(not api.SharedService.IsEnabled(),"stale selected-offer binding enabled a different peer")
    equal(#state.transportSent,0)
end)

test("workflow selected-peer enable rechecks exact retained terms before changing the connection",function()
    local state=newSession(); seed(state,{{id="first",state="agreed"}})
    local api=state.api; api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    api.SelectSharedOffer("first"); assert(board.connectSelected.enabled)
    local entry=state.env.IOUDB.sharedByCharacter[api.Character()]
    entry.store=family(api,"first",{state="agreed",peer="Cedar Grove",note="Changed synthetic exact terms"})
    local changed=copy(entry.store)
    board.connectSelected.scripts.OnClick(board.connectSelected)
    assert(not api.SharedService.IsEnabled(),"stale terms silently enabled the replacement peer")
    assert(same(changed,api.SharedService.GetStore()))
    equal(#state.transportSent,0)
end)

test("workflow a stale selected offer paused without notification cannot enable the wire",function()
    local state=newSession(); seed(state,{{id="incoming",incoming=true}})
    local api=state.api; api.ShowShared(nil,"inbox")
    local board=api.UI.shared
    assert(board.connectSelected.enabled)
    local entry=state.env.IOUDB.sharedByCharacter[api.Character()]
    entry.store=assert(api.Shared.Pause(entry.store,math.floor(state.now)))
    equal(entry.store.offers.incoming.state,"PAUSED")
    local paused=copy(entry.store)
    local enable,calls=api.SharedWire.Enable,0
    api.SharedWire.Enable=function(...) calls=calls+1; return enable(...) end
    -- No service notification refreshed the still-enabled stale UI control.
    state.click(board.connectSelected)
    equal(calls,0,"a stale paused-offer button enabled the transport")
    api.SharedWire.Enable=enable
    assert(not api.SharedService.IsEnabled())
    assert(same(paused,api.SharedService.GetStore()))
    assert(not board.connectSelected.enabled)
    equal(#state.transportSent,0)
end)

test("workflow incoming packets update review counts without stealing a chosen view or input focus",function()
    local state=newSession(); seed(state,{{id="existing",state="agreed"}})
    local api=state.api; api.ShowShared("Birch Vale","all")
    local board=api.UI.shared
    state.click(board.enable)
    api.SelectSharedOffer("existing")
    if board.filter~="all" then state.click(board.more); state.click(board.filterButtons.all) end
    board.search:SetText("Synthetic")
    board.search:SetFocus(); board.scroll:SetVerticalScroll(37)
    local selected,filter=board.selected,board.filter
    local before=copy(api.GetLedger())
    deliverProposal(state,"incoming-packet")
    equal(api.SharedService.GetOffer("incoming-packet").state,"OFFER_RECEIVED")
    equal(board.selected,selected); equal(board.filter,filter)
    equal(board.search:GetText(),"Synthetic")
    assert(board.search:HasFocus(),"incoming message stole typing focus")
    equal(board.scroll:GetVerticalScroll(),37)
    assert(not api.UI.sharedReview or not api.UI.sharedReview:IsShown())
    assert(not api.UI.sharedForm or not api.UI.sharedForm:IsShown())
    equal(api.GetSharedAttention().count,1)
    assert(same(before,api.GetLedger())); equal(#state.transportSent,0)
end)

test("workflow attention works before opening the board and cached getters or tooltip never read storage",function()
    local state=newSession({launcher=true}); local api=state.api
    api.Toggle(); api.UpdateLauncher()
    assert(not api.UI.shared,"personal ledger opening built the Shared board")
    assert(api.SharedService.Enable("Birch Vale"))
    deliverProposal(state,"unopened-incoming")
    assert(not api.UI.shared,"incoming packet opened the Shared board")
    equal(api.GetSharedAttention().count,1)
    contains(api.UI.sharedButton:GetText(),"1")
    equal(api.launcher.sharedBadge:GetText(),"1"); assert(api.launcher.sharedBadge:IsShown())
    local original=api.SharedService.GetOverview
    local reads=0
    api.SharedService.GetOverview=function() reads=reads+1; error("cached attention queried Shared storage") end
    local attention=api.GetSharedAttention(); attention.count=999
    equal(api.GetSharedAttention().count,1,"attention snapshot was not detached")
    api.launcher.scripts.OnEnter(api.launcher)
    contains(table.concat(state.env.GameTooltip.lines,"\n"),"Requests: 1")
    equal(reads,0); equal(#state.transportSent,0)
    api.SharedService.GetOverview=original
    state.env.IsShiftKeyDown=function() return true end
    state.click(api.launcher,"LeftButton")
    equal(api.UI.shared.filter,"inbox"); assert(api.UI.shared:IsShown())
    equal(api.SharedService.GetOffer("unopened-incoming").state,"OFFER_RECEIVED")
end)

test("workflow recovery blocks selected-peer enable and retains a visible recovery notice",function()
    local state=newSession({launcher=true}); seed(state,{{id="agreed",state="agreed"}})
    local api,S=state.api,state.api.SharedService
    local text=assert(S.ExportBackup())
    local preview=assert(S.PreviewBackup(text))
    assert(S.StageRecovery(text,preview.currentFingerprint))
    api.Toggle(); api.UpdateLauncher(); api.ShowShared(nil,"agreements")
    local board=api.UI.shared
    assert(api.GetSharedAttention().recovery)
    contains(api.UI.sharedButton:GetText(),"!")
    equal(api.launcher.sharedBadge:GetText(),"!")
    assert(not board.enable.enabled and not board.connectSelected.enabled)
    board.connectSelected.scripts.OnClick(board.connectSelected)
    assert(S.IsRecoveryPending() and not S.IsEnabled())
    equal(#state.transportSent,0)
end)

test("workflow corrupt Shared storage surfaces an error and leaves personal bookkeeping usable",function()
    local state=newSession({launcher=true}); seed(state,{{id="agreed",state="agreed"}})
    local api=state.api; api.Toggle(); api.UpdateLauncher(); api.ShowShared()
    local entry=state.env.IOUDB.sharedByCharacter[api.Character()]
    entry.store.version=99
    local before=copy(entry)
    api.OnSharedChanged()
    local attention=api.GetSharedAttention()
    assert(type(attention.error)=="string" and #attention.error>0)
    contains(api.UI.sharedButton:GetText(),"!")
    equal(api.launcher.sharedBadge:GetText(),"!")
    assert(not api.UI.shared.enable.enabled and not api.UI.shared.connectSelected.enabled)
    assert(api.Add({player="Cedar",direction="owed",kind="money",amount=500,label="",note="Personal remains available"}))
    equal(#api.GetLedger().entries,1)
    assert(same(entry,before),"workflow display rewrote invalid Shared storage")
    equal(#state.transportSent,0)
end)

return results
