-- Complete addon peers with persisted stores and the real logical codec,
-- packet framing, service and UI. Only native client APIs are mocked.
local support=assert(IOU_TEST_SUPPORT,"Run through tools/test_iou.py to initialize addon mocks.")
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
local function rejected(call)
    local value,err=call()
    assert(value==nil or value==false,"invalid action succeeded")
    assert(type(err)=="string" and #err>0,"rejection needs an explanation")
end
local function network()
    local sim={groups={},seen={},messages={},injectSerial=0}
    sim.a=support.Session({ui=true,shared=true,name="Amber",fullName="Amber Stone"})
    sim.b=support.Session({ui=true,shared=true,name="Birch",fullName="Birch Vale"})
    sim.a.api.ShowShared("Birch Vale"); sim.b.api.ShowShared("Amber Stone")
    sim.a.click(sim.a.api.UI.shared.enable); sim.b.click(sim.b.api.UI.shared.enable)
    sim.personalA=copy(sim.a.api.GetLedger()); sim.personalB=copy(sim.b.api.GetLedger())
    function sim:inject(from,to,message,reverse)
        self.injectSerial=self.injectSerial+1
        local packets=assert(from.api.SharedWire.Frame("integration-"..self.injectSerial,
            assert(from.api.SharedCodec.Encode(message))))
        if reverse then
            for index=#packets,1,-1 do
                to.event("CHAT_MSG_ADDON_LOGGED",from.api.SharedWire.PREFIX,packets[index],
                    "WHISPER",assert(from.api.Transport.GetLocalName()))
            end
        else
            for _,packet in ipairs(packets) do
                to.event("CHAT_MSG_ADDON_LOGGED",from.api.SharedWire.PREFIX,packet,
                    "WHISPER",assert(from.api.Transport.GetLocalName()))
            end
        end
    end
    function sim:route(from,to)
        self.groups[from]=self.groups[from] or {}
        local seen=self.seen[from] or 0
        while seen<#from.transportSent do
            seen=seen+1
            local packet=from.transportSent[seen]
            local parsed=assert(from.api.SharedWire.ParsePacket(packet.wire))
            local group=self.groups[from][parsed.id]
            if not group then group={parts={},packets={},seen=0,count=parsed.count}; self.groups[from][parsed.id]=group end
            if not group.parts[parsed.part] then group.seen=group.seen+1 end
            group.parts[parsed.part],group.packets[parsed.part]=parsed.body,packet.wire
            if group.seen==group.count then
                local message=assert(from.api.SharedCodec.Decode(table.concat(group.parts)))
                local record={from=from,to=to,message=message,packets=group.packets}
                self.messages[#self.messages+1]=record
                if not self.drop or not self.drop(record) then
                    -- Deliver each complete message's frames in reverse order
                    -- to exercise the actual reassembly boundary on every step.
                    for index=#group.packets,1,-1 do
                        to.event("CHAT_MSG_ADDON_LOGGED",packet.prefix,group.packets[index],
                            packet.channel,assert(from.api.Transport.GetLocalName()))
                    end
                end
                self.groups[from][parsed.id]=nil
            end
        end
        self.seen[from]=seen
    end
    function sim:runUntil(predicate)
        for _=1,180 do
            self.a.advance(1); self.b.advance(1)
            self:route(self.a,self.b); self:route(self.b,self.a)
            if predicate() then return end
        end
        error("complete addon peers did not reach the expected payment state")
    end
    function sim:review(id)
        self:runUntil(function() return self.b.api.SharedService.GetOffer(id)~=nil end)
        equal(self.b.api.SharedService.GetOffer(id).state,"OFFER_RECEIVED")
        self.b.api.ShowSharedReview(id,"accept")
        local review=self.b.api.UI.sharedReview
        assert(review:IsShown() and review.confirm.enabled)
        self.b.click(review.confirm)
        equal(self.b.api.SharedService.GetOffer(id).state,"ACCEPT_PENDING")
    end
    function sim:confirmed(id)
        self:runUntil(function()
            local a=self.a.api.SharedService.GetOffer(id)
            local b=self.b.api.SharedService.GetOffer(id)
            return a and b and a.state=="COMMITTED" and b.state=="COMMITTED"
                and a.delivery=="PEER_RECEIPT_OBSERVED"
        end)
        equal(self.a.api.SharedService.GetOffer(id).terms,self.b.api.SharedService.GetOffer(id).terms)
        self:unchangedPersonal()
    end
    function sim:agreed(id)
        self:review(id)
        self:confirmed(id)
    end
    function sim:parent(direction)
        local offer=assert(self.a.api.SharedService.Propose({peer="Birch Vale",
            direction=direction or "owed",amountCopper=10000,note="Original immutable gold obligation",dueUTC=0}))
        self.parentId=offer.offerId; self.parentTerms=offer.terms
        assert(offer.terms:find("IOUST1:",1,true)==1)
        self:agreed(offer.offerId)
        return offer
    end
    function sim:balances(expectedA,expectedB)
        local a=assert(self.a.api.SharedService.GetBalance(self.parentId))
        local b=assert(self.b.api.SharedService.GetBalance(self.parentId))
        equal(a.remainingCopper,expectedA); equal(b.remainingCopper,expectedB or expectedA)
        equal(a.originalCopper,10000); equal(b.originalCopper,10000)
        return a,b
    end
    function sim:unchangedPersonal()
        assert(same(self.personalA,self.a.api.GetLedger()),"sequencer changed personal balances")
        assert(same(self.personalB,self.b.api.GetLedger()),"recipient changed personal balances")
    end
    function sim:close()
        self.a.api.UI.shared:Hide(); self.b.api.UI.shared:Hide()
        self:unchangedPersonal()
    end
    return sim
end

local function selectPayment(session,form,id)
    for _=1,11 do
        for _,row in ipairs(form.rows) do
            if row.paymentId==id and row:IsShown() then session.click(row); return end
        end
        if not form.next.enabled then break end
        session.click(form.next)
    end
    error("correction selector omitted the explicit target payment")
end

test("shared payments settle and fully reverse exact events in either original debtor direction",function()
    for _,direction in ipairs({"owed","owe"}) do
        local sim=network(); sim:parent(direction); sim:balances(10000)
        local api=sim.a.api
        local original=assert(api.SharedCodec.ParseTerms(sim.parentTerms))
        equal(original.debtor,direction=="owed" and "Birch Vale" or "Amber Stone")
        local partial=assert(api.SharedService.ProposePayment(sim.parentId,2500,"First partial repayment"))
        sim:balances(10000); sim:agreed(partial.offerId); sim:balances(7500)
        local settlement=assert(api.SharedService.ProposePayment(sim.parentId,7500,"Repay the full remaining amount"))
        sim:agreed(settlement.offerId); local a,b=sim:balances(0)
        equal(a.state,"SETTLED"); equal(b.state,"SETTLED")
        rejected(function() return api.SharedService.ProposeCorrection(sim.parentId,settlement.offerId,"invalid|text") end)
        local correction=assert(api.SharedService.ProposeCorrection(sim.parentId,settlement.offerId,
            "Full settlement was recorded against the wrong trade"))
        sim:balances(0); sim:agreed(correction.offerId); sim:balances(7500)
        rejected(function() return api.SharedService.ProposeCorrection(sim.parentId,settlement.offerId,"Cannot reverse twice") end)
        rejected(function() return api.SharedService.ProposeCorrection(sim.parentId,correction.offerId,"Cannot reverse a correction") end)
        local second=assert(api.SharedService.ProposeCorrection(sim.parentId,partial.offerId,
            "The first repayment was also recorded in error"))
        sim:agreed(second.offerId); a,b=sim:balances(10000)
        equal(a.state,"OPEN"); equal(b.state,"OPEN"); equal(a.paidCopper,0)
        for _,session in ipairs({sim.a,sim.b}) do
            equal(session.api.SharedService.GetOffer(sim.parentId).terms,sim.parentTerms)
            for _,event in ipairs(session.api.SharedService.GetBalance(sim.parentId).events) do
                if event.kind=="GOLD_PAYMENT" then assert(event.reversed) end
            end
        end
        sim:close()
    end
end)

test("shared payment sequencing rejects overpayment, concurrent events and stale incoming baselines atomically",function()
    local sim=network(); sim:parent()
    local service=sim.a.api.SharedService
    local before=copy(service.GetStore())
    rejected(function() return service.ProposePayment(sim.parentId,10001,"Too much") end)
    assert(same(service.GetStore(),before))
    rejected(function() return sim.b.api.SharedService.ProposePayment(sim.parentId,1,"Wrong sequencer") end)
    local partial=assert(service.ProposePayment(sim.parentId,8000,"Current event"))
    before=copy(service.GetStore())
    rejected(function() return service.ProposePayment(sim.parentId,2000,"Concurrent event") end)
    assert(same(service.GetStore(),before))
    sim:agreed(partial.offerId); sim:balances(2000)
    before=copy(service.GetStore())
    rejected(function() return service.ProposePayment(sim.parentId,2001,"Now over the remaining amount") end)
    assert(same(service.GetStore(),before))
    local stale=copy(partial.messages.propose)
    stale.messageId="stale-message"; stale.agreementId="stale-agreement"; stale.offerId="stale-offer"
    local terms=assert(sim.a.api.SharedCodec.ParseTerms(stale.terms))
    terms.amountCopper=1000
    stale.terms=assert(sim.a.api.SharedCodec.CanonicalTerms(terms))
    local beforeB=copy(sim.b.api.SharedService.GetStore())
    sim:inject(sim.a,sim.b,stale,true)
    assert(same(sim.b.api.SharedService.GetStore(),beforeB))
    equal(sim.b.api.SharedService.GetOffer("stale-offer"),nil)
    sim:balances(2000); sim:close()
end)

test("lost payment ACK shows asymmetric confirmation and blocks the next event until exact replay",function()
    local sim=network(); sim:parent()
    local payment=assert(sim.a.api.SharedService.ProposePayment(sim.parentId,4000,"ACK recovery payment"))
    local dropped
    sim.drop=function(record)
        if record.message.kind=="ACK" and record.message.offerId==payment.offerId then
            dropped=record; return true
        end
    end
    sim:review(payment.offerId)
    sim:runUntil(function() return dropped~=nil end)
    local a,b=sim:balances(10000,6000)
    assert(a.awaitingAck and not a.canPropose)
    assert(not b.canPropose)
    equal(sim.a.api.SharedService.GetOffer(payment.offerId).state,"COMMITTED")
    local before=copy(sim.a.api.SharedService.GetStore())
    rejected(function() return sim.a.api.SharedService.ProposePayment(sim.parentId,1000,"Must wait for ACK") end)
    assert(same(sim.a.api.SharedService.GetStore(),before))
    local recipientBefore=copy(sim.b.api.SharedService.GetStore())
    sim.drop=nil
    local commit=sim.a.api.SharedService.GetOffer(payment.offerId).messages.commit
    sim:inject(sim.a,sim.b,commit,true)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetOffer(payment.offerId).delivery=="PEER_RECEIPT_OBSERVED"
    end)
    a,b=sim:balances(6000)
    assert(a.canPropose and not a.awaitingAck)
    assert(same(sim.b.api.SharedService.GetStore(),recipientBefore),"commit replay duplicated payment effects or history")
    local beforeA=copy(sim.a.api.SharedService.GetStore())
    sim:inject(sim.b,sim.a,dropped.message,true)
    assert(same(sim.a.api.SharedService.GetStore(),beforeA),"duplicate ACK changed confirmed event history")
    local nextPayment=assert(sim.a.api.SharedService.ProposePayment(sim.parentId,1000,"Now sequenced after ACK"))
    sim:agreed(nextPayment.offerId); sim:balances(5000); sim:close()
end)

test("reloaded payment consent stays paused and a peer commitment cannot recreate the missing acceptance",function()
    local sim=network(); sim:parent()
    local payment=assert(sim.a.api.SharedService.ProposePayment(sim.parentId,2000,"Interrupted acceptance"))
    sim:runUntil(function() return sim.b.api.SharedService.GetOffer(payment.offerId)~=nil end)
    local beforeAcceptance=copy(sim.b.env.IOUDB)
    sim:review(payment.offerId)
    sim:runUntil(function() return sim.a.api.SharedService.GetOffer(payment.offerId).state=="COMMITTED" end)
    local commit=sim.a.api.SharedService.GetOffer(payment.offerId).messages.commit
    local reloaded=support.Session({ui=true,shared=true,name="Birch",fullName="Birch Vale",db=beforeAcceptance})
    reloaded.now=math.ceil(sim.b.now)+1
    reloaded.event("PLAYER_LOGIN")
    equal(reloaded.api.SharedService.GetOffer(payment.offerId).state,"PAUSED")
    equal(reloaded.api.SharedService.GetOffer(payment.offerId).consent,"NONE")
    assert(not reloaded.api.SharedService.IsEnabled()); equal(#reloaded.transportSent,0)
    assert(reloaded.api.SharedService.Enable("Amber Stone"))
    local before=copy(reloaded.api.SharedService.GetStore())
    sim:inject(sim.a,reloaded,commit,true)
    assert(same(reloaded.api.SharedService.GetStore(),before))
    equal(reloaded.api.SharedService.GetBalance(sim.parentId).remainingCopper,10000)
    rejected(function() return reloaded.api.SharedService.Accept(payment.offerId) end)
    equal(#reloaded.transportSent,0)
    assert(same(reloaded.api.GetLedger(),sim.personalB))
    assert(reloaded.api.SharedService.Disable()); sim:close()
end)

test("payment, settlement and correction forms expose exact amounts and require explicit reversal selection",function()
    local sim=network(); sim:parent()
    local a,b=sim.a,sim.b; local api=a.api
    api.ShowSharedPayment(sim.parentId,"payment")
    local form=api.UI.sharedPaymentForm
    assert(form:IsShown()); equal(form.parentId,sim.parentId); equal(form.peer,"Birch Vale")
    form.money:Fill(2000); form.note:SetText("Partial payment with a full visible note")
    a.click(form.send); assert(not form:IsShown())
    local payment=api.SharedService.GetOffer(api.UI.shared.selected)
    local terms=assert(api.SharedCodec.ParseTerms(payment.terms))
    equal(terms.kind,"GOLD_PAYMENT"); equal(terms.amountCopper,2000)
    sim:runUntil(function() return b.api.SharedService.GetOffer(payment.offerId)~=nil end)
    b.api.ShowSharedReview(payment.offerId,"accept")
    local review=b.api.UI.sharedReview
    local details=review.details:GetText()
    for _,text in ipairs({"Original immutable gold obligation","Partial payment with a full visible note",
        "Original debtor: Birch Vale","Balance before this event: 1g 00s 00c","Balance after acknowledgment: 0g 80s 00c"}) do
        assert(details:find(text,1,true),"payment review omitted "..text)
    end
    equal(b.api.SharedService.GetOffer(payment.offerId).state,"OFFER_RECEIVED")
    b.click(review.confirm); sim:confirmed(payment.offerId); sim:balances(8000)
    api.ShowSharedPayment(sim.parentId,"settle")
    form=api.UI.sharedPaymentForm
    equal(form.money:Read(),8000); equal(form.remaining,8000)
    for _,box in ipairs(form.money) do assert(not box.enabled) end
    local count=#api.SharedService.List()
    form.money:Fill(7999); a.click(form.send)
    equal(#api.SharedService.List(),count); assert(form:IsShown())
    assert(form.status:GetText():find("changed",1,true))
    form.money:Fill(8000); form.note:SetText("Entire remaining balance")
    a.click(form.send)
    local settlement=api.SharedService.GetOffer(api.UI.shared.selected)
    sim:agreed(settlement.offerId); sim:balances(0)
    api.ShowSharedPayment(sim.parentId,"correction")
    form=api.UI.sharedPaymentForm
    equal(form.paymentId,nil); assert(not form.send.enabled)
    selectPayment(a,form,payment.offerId)
    equal(form.paymentId,payment.offerId); equal(form.money:Read(),2000)
    assert(form.context:GetText():find("Partial payment with a full visible note",1,true))
    count=#api.SharedService.List()
    a.click(form.send)
    equal(#api.SharedService.List(),count+1); assert(not form:IsShown())
    local correction=api.SharedService.GetOffer(api.UI.shared.selected)
    terms=assert(api.SharedCodec.ParseTerms(correction.terms))
    equal(terms.kind,"GOLD_CORRECTION"); equal(terms.reversesId,payment.offerId)
    equal(terms.amountCopper,2000)
    equal(terms.note,"No reason provided")
    sim:runUntil(function() return b.api.SharedService.GetOffer(correction.offerId)~=nil end)
    b.api.ShowSharedReview(correction.offerId,"accept")
    review=b.api.UI.sharedReview
    assert(review.details:GetText():find("Full reversal of payment: #"..payment.offerId:match("%-(%d+)$"),1,true))
    assert(review.details:GetText():find(terms.note,1,true))
    b.click(review.confirm); sim:confirmed(correction.offerId); sim:balances(2000)
    sim:close()
end)

test("a stale correction draft preserves its selected payment and rejects changed history or peer",function()
    local sim=network(); sim:parent()
    local a=sim.a; local api=a.api
    local first=assert(api.SharedService.ProposePayment(sim.parentId,3000,"The specifically selected payment"))
    sim:agreed(first.offerId)
    local second=assert(api.SharedService.ProposePayment(sim.parentId,2000,"A different payment"))
    sim:agreed(second.offerId)
    api.ShowSharedPayment(sim.parentId,"correction")
    local form=api.UI.sharedPaymentForm
    selectPayment(a,form,first.offerId)
    form.note:SetText("Reason bound to the first selected payment")
    local other=assert(api.SharedService.ProposeCorrection(sim.parentId,second.offerId,"Separate explicit correction"))
    sim:agreed(other.offerId)
    equal(form.paymentId,first.offerId); assert(not form.send.enabled)
    local before=copy(api.SharedService.GetStore())
    form.send.scripts.OnClick(form.send)
    assert(form.status:GetText():find("changed",1,true))
    assert(same(api.SharedService.GetStore(),before))
    api.ShowSharedPayment(sim.parentId,"correction")
    form=api.UI.sharedPaymentForm
    equal(form.paymentId,nil); assert(not form.send.enabled)
    selectPayment(a,form,first.offerId); form.note:SetText("Still the same explicit target")
    assert(api.SharedService.Disable()); assert(api.SharedService.Enable("Other Peer"))
    before=copy(api.SharedService.GetStore())
    form.send.scripts.OnClick(form.send)
    assert(form.status:GetText():find("changed",1,true))
    equal(form.paymentId,first.offerId); assert(same(api.SharedService.GetStore(),before))
    sim:close()
end)

test("a payment saved before enqueue failure closes its draft and retries the same event",function()
    local sim=network(); sim:parent()
    local a=sim.a; local api=a.api
    api.ShowSharedPayment(sim.parentId,"payment")
    local form=api.UI.sharedPaymentForm
    form.money:Fill(1000); form.note:SetText("Save one payment proposal")
    local originalSend=api.SharedWire.Send
    api.SharedWire.Send=function() return nil,"injected post-persist failure" end
    local count=#api.SharedService.List()
    a.click(form.send)
    assert(not form:IsShown()); equal(#api.SharedService.List(),count+1)
    local event=api.SharedService.GetOffer(api.UI.shared.selected)
    equal(assert(api.SharedCodec.ParseTerms(event.terms)).kind,"GOLD_PAYMENT")
    assert(api.UI.shared.status:GetText():find("saved",1,true))
    local retained=copy(event.messages.propose)
    api.SharedWire.Send=originalSend
    a.click(api.UI.shared.retry)
    sim:agreed(event.offerId); sim:balances(9000)
    equal(#api.SharedService.List(),count+1)
    assert(same(api.SharedService.GetOffer(event.offerId).messages.propose,retained))
    sim:close()
end)

test("malformed persisted payment terms disable shared records while preserving personal data and legacy parent bytes",function()
    local sim=network(); sim:parent()
    local payment=assert(sim.a.api.SharedService.ProposePayment(sim.parentId,1000,"Persisted payment"))
    sim:agreed(payment.offerId)
    local db=copy(sim.a.env.IOUDB)
    local wrapper=db.sharedByCharacter[sim.a.api.Character()]
    wrapper.store.offers[payment.offerId].terms=wrapper.store.offers[payment.offerId].terms.."trailing"
    local original=copy(db.sharedByCharacter)
    local reloaded=support.Session({ui=true,shared=true,name="Amber",fullName="Amber Stone",db=db})
    reloaded.now=math.ceil(sim.a.now)+1; reloaded.event("PLAYER_LOGIN")
    local store,err=reloaded.api.SharedService.GetStore()
    equal(store,nil); assert(type(err)=="string" and #err>0)
    assert(same(db.sharedByCharacter,original)); assert(not reloaded.api.SharedService.IsEnabled())
    assert(reloaded.api.Add({player="Personal Peer",direction="owed",kind="money",amount=1,label="",note=""}))
    equal(#reloaded.api.GetLedger().entries,1)
    equal(db.sharedByCharacter[sim.a.api.Character()].store.offers[sim.parentId].terms,sim.parentTerms)
    equal(#reloaded.transportSent,0); sim:close()
end)

return results
