-- Complete peers exercise the 1.0 personal/shared bridge. Synthetic native
-- APIs are used, but all terms, framing, consent and ledger writes are real.
local support=assert(IOU_TEST_SUPPORT,"Run through tools/test_iou.py.")
local copy=support.Copy
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b,note) assert(a==b,(note or "unexpected value")..": expected "..tostring(b)..", got "..tostring(a)) end
local cloth="|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"
local function client(name,fullName,db)
    local state=support.Session({ui=true,shared=true,sharing=true,name=name,fullName=fullName,db=db})
    assert(state.api.Initialize()); assert(state.api.SharedService.Initialize())
    if not state.api.Sharing then
        local chunk=assert(loadstring(assert(IOU_SOURCES["sharing.lua"]),"@IOU/sharing.lua"))
        setfenv(chunk,state.env);chunk("IOU",state.api)
    end
    assert(state.api.Sharing,"sharing module was not loaded")
    assert(state.api.Sharing.Initialize())
    return state
end
local function network()
    local sim={groups={},seen={},messages={},serial=0}
    sim.a=client("Amber","Amber Stone")
    sim.b=client("Birch","Birch Vale")
    function sim:route(from,to)
        self.groups[from]=self.groups[from] or {}
        local index=self.seen[from] or 0
        while index<#from.transportSent do
            index=index+1
            local packet=from.transportSent[index]
            local part=assert(from.api.SharedWire.ParsePacket(packet.wire))
            local group=self.groups[from][part.id]
            if not group then group={parts={},packets={},count=part.count,seen=0}; self.groups[from][part.id]=group end
            if not group.parts[part.part] then group.seen=group.seen+1 end
            group.parts[part.part],group.packets[part.part]=part.body,packet.wire
            if group.seen==group.count then
                local message=assert(from.api.SharedCodec.Decode(table.concat(group.parts)))
                local record={from=from,to=to,message=message,packets=copy(group.packets)}
                self.messages[#self.messages+1]=record
                if not self.drop or not self.drop(record) then
                    for pos=#group.packets,1,-1 do
                        to.event("CHAT_MSG_ADDON_LOGGED",packet.prefix,group.packets[pos],packet.channel,
                            assert(from.api.Transport.GetLocalName()))
                    end
                end
                self.groups[from][part.id]=nil
            end
        end
        self.seen[from]=index
    end
    function sim:runUntil(predicate)
        for _=1,180 do
            self.a.advance(1); self.b.advance(1)
            self:route(self.a,self.b); self:route(self.b,self.a)
            if predicate() then return end
        end
        error("personal/shared peers did not reach the expected state")
    end
    function sim:replay(record)
        self.serial=self.serial+1
        local frames=assert(record.from.api.SharedWire.Frame("bridge-replay-"..self.serial,
            assert(record.from.api.SharedCodec.Encode(record.message))))
        for _,packet in ipairs(frames) do record.to.event("CHAT_MSG_ADDON_LOGGED",record.from.api.SharedWire.PREFIX,
            packet,"WHISPER",assert(record.from.api.Transport.GetLocalName())) end
    end
    function sim:received(id)
        self:runUntil(function() return self.b.api.SharedService.GetOffer(id)~=nil end)
        equal(self.b.api.SharedService.GetOffer(id).state,"OFFER_RECEIVED")
    end
    function sim:confirmed(id)
        self:runUntil(function()
            local a,b=self.a.api.SharedService.GetOffer(id),self.b.api.SharedService.GetOffer(id)
            return a and b and a.state=="COMMITTED" and b.state=="COMMITTED" and a.delivery=="PEER_RECEIPT_OBSERVED"
        end)
    end
    function sim:accept(id)
        self:received(id); assert(self.b.api.SharedService.Accept(id)); self:confirmed(id)
    end
    function sim:loan(kind,direction,amount)
        kind,direction,amount=kind or "money",direction or "owed",amount or 1000
        local e=assert(self.a.api.Add({player="Birch Vale",kind=kind,direction=direction,amount=amount,
            label=kind=="item" and cloth or "",note="Crafting loan BjÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¸rn blÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¥bÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦r",due=0}))
        local offer=assert(self.a.api.Sharing.Share(e.id))
        self.id,self.entryID=offer.offerId,e.id
        self:accept(offer.offerId)
        return e,offer
    end
    return sim
end
local function linkFor(state,offerId)
    for _,entry in ipairs(state.api.GetLedger().entries) do
        local link=state.api.Sharing.GetLink(entry.id)
        if link and link.offerId==offerId then return entry,link end
    end
end
local function balance(state,entryID) return state.api.Ledger.Balance(assert(state.api.Ledger.Get(state.api.GetLedger(),entryID))) end
local function receipt(state,peer,kind,amount,outgoing,itemLink)
    local service=state.api.TradeService
    local id=assert(service.NewSessionID("trade"))
    local asset={money=kind=="money" and amount or 0,items={}}
    if kind=="item" then asset.items={{itemID=2589,link=itemLink or cloth,name="Linen Cloth",quantity=amount}} end
    return assert(service.Record({id=id,peer=peer,outgoing=outgoing and asset or {money=0,items={}},
        incoming=outgoing and {money=0,items={}} or asset}))
end

test("1.0 sharing sends an ordinary personal IOU without opening or pairing windows",function()
    local sim=network(); local a,b=sim.a,sim.b
    assert(a.api.SharedService.IsBackground()); assert(b.api.SharedService.IsBackground())
    local e=assert(a.api.Add({player="Birch Vale",kind="money",direction="owed",amount=1000,label="",note=""}))
    local offer=assert(a.api.Sharing.Share(e.id)); sim:received(offer.offerId)
    equal(#b.api.GetLedger().entries,0,"unaccepted offer created a debt")
    equal(a.api.Sharing.GetLink(e.id).state,"pending")
    sim:accept(offer.offerId)
    local remote,link=assert(linkFor(b,offer.offerId))
    equal(remote.player,"Amber Stone"); equal(remote.direction,"owe"); equal(balance(b,remote.id),1000)
    equal(a.api.Sharing.GetLink(e.id).state,"agreed")
    equal(link.state,"agreed")
end)

test("1.0 gold sharing preserves either debtor direction and deduplicates summary totals",function()
    for _,direction in ipairs({"owed","owe"}) do
        local sim=network(); local e=sim:loan("money",direction)
        local remote=assert(linkFor(sim.b,sim.id))
        equal(remote.direction,direction=="owed" and "owe" or "owed")
        local summary=assert(sim.a.api.PlayerSummary.Build(sim.a.api.GetLedger(),sim.a.api.SharedService.GetOverview(),"Birch Vale"))
        equal(summary.personal[direction].money,1000); equal(summary.shared[direction].money,0)
        equal(balance(sim.a,e.id),1000)
    end
end)

test("1.0 native material sharing retains quantity identity and a single recipient ledger entry",function()
    local sim=network(); local e,offer=sim:loan("item","owed",20)
    local remote=assert(linkFor(sim.b,offer.offerId))
    equal(remote.kind,"item"); equal(remote.amount,20)
    assert(sim.a.api.TradeMatching.ItemKey(remote.label)==sim.a.api.TradeMatching.ItemKey(e.label))
    for _,message in ipairs(sim.messages) do sim:replay(message) end
    equal(#sim.b.api.GetLedger().entries,1); equal(balance(sim.b,remote.id),20)
end)

test("1.0 selecting another request peer or closing windows does not pause background offers",function()
    local sim=network(); local a,b=sim.a,sim.b
    local e=assert(a.api.Add({player="Birch Vale",kind="money",direction="owed",amount=1000,label="",note=""}))
    local offer=assert(a.api.Sharing.Share(e.id)); sim:received(offer.offerId)
    a.api.ShowShared("Cedar Leaf"); a.api.UI.shared:Hide()
    b.api.ShowShared("Cedar Leaf"); b.api.UI.shared:Hide()
    equal(a.api.SharedService.GetOffer(offer.offerId).state,"OFFER_OPEN")
    equal(b.api.SharedService.GetOffer(offer.offerId).state,"OFFER_RECEIVED")
    assert(b.api.SharedService.Accept(offer.offerId)); sim:confirmed(offer.offerId)
    equal(#b.api.GetLedger().entries,1)
end)

test("1.0 repeated Share uses the retained offer and declined requests leave personal balances intact",function()
    local sim=network(); local a,b=sim.a,sim.b
    local e=assert(a.api.Add({player="Birch Vale",kind="money",direction="owed",amount=1000,label="",note=""}))
    local offer=assert(a.api.Sharing.Share(e.id))
    local again=assert(a.api.Sharing.Share(e.id)); equal(again.offerId,offer.offerId)
    sim:received(offer.offerId); assert(b.api.SharedService.Decline(offer.offerId))
    sim:runUntil(function() return a.api.SharedService.GetOffer(offer.offerId).state=="DECLINED" end)
    equal(balance(a,e.id),1000); equal(#b.api.GetLedger().entries,0)
end)

test("1.0 observed gold repayment updates personal balances once and auto accepts matching peer evidence",function()
    local sim=network(); local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id))
    receipt(sim.b,"Amber Stone","money",300,true)
    receipt(sim.a,"Birch Vale","money",300,false)
    equal(balance(sim.a,e.id),700); equal(balance(sim.b,remote.id),700)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==700
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==700
    end)
    equal(balance(sim.a,e.id),700); equal(balance(sim.b,remote.id),700)
    for _,message in ipairs(sim.messages) do sim:replay(message) end
    equal(balance(sim.a,e.id),700); equal(balance(sim.b,remote.id),700)
end)

test("1.0 observed crafting delivery follows the shared quantity handshake without double repayment",function()
    local sim=network(); local e=sim:loan("item","owed",20)
    local remote=assert(linkFor(sim.b,sim.id))
    receipt(sim.b,"Amber Stone","item",7,true); receipt(sim.a,"Birch Vale","item",7,false)
    equal(balance(sim.a,e.id),13); equal(balance(sim.b,remote.id),13)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==13
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==13
    end)
    equal(balance(sim.a,e.id),13); equal(balance(sim.b,remote.id),13)
end)

test("1.0 sharing rejects favors and unbound item names without changing the personal ledger",function()
    local sim=network(); local a=sim.a
    for _,value in ipairs({{kind="favor",label="Quest help"},{kind="item",label="Some cloth"}}) do
        local e=assert(a.api.Add({player="Birch Vale",kind=value.kind,direction="owed",amount=2,label=value.label,note=""}))
        local before=assert(a.api.Export())
        local shared,err=a.api.Sharing.Share(e.id)
        assert(not shared and type(err)=="string"); equal(assert(a.api.Export()),before)
        equal(a.api.Sharing.GetLink(e.id),nil)
    end
end)

test("1.0 sharing a partial loan proposes its remaining amount without counting it twice",function()
    local sim=network(); local a,b=sim.a,sim.b
    local e=assert(a.api.Add({player="Birch Vale",kind="money",direction="owed",amount=1000,label="",note=""}))
    assert(a.api.Pay(e.id,300,"Earlier repayment"))
    local offer=assert(a.api.Sharing.Share(e.id)); sim:accept(offer.offerId)
    local remote=assert(linkFor(b,offer.offerId))
    equal(balance(a,e.id),700); equal(balance(b,remote.id),700)
    equal(a.api.SharedService.GetBalance(offer.offerId).remainingCopper,700)
    local overview=assert(a.api.SharedService.GetOverview())
    local summary=assert(a.api.PlayerSummary.Build(a.api.GetLedger(),overview,"Birch Vale"))
    equal(summary.personal.owed.money,700); equal(summary.shared.owed.money,0)
end)

local function pendingEvent(state,parentId,kind)
    for _,offer in ipairs(assert(state.api.SharedService.List())) do
        local terms=assert(state.api.SharedCodec.ParseTerms(offer.terms))
        if terms.parentOfferId==parentId and (kind=="payment" and state.api.SharedCodec.IsPayment(terms)
            or kind=="correction" and state.api.SharedCodec.IsCorrection(terms))
            and offer.state=="OFFER_RECEIVED" then return offer end
    end
end

test("1.0 manual repayment requests explicit peer acceptance before changing their personal balance",function()
    local sim=network(); local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id))
    assert(sim.a.api.Pay(e.id,300,"Paid outside this session"))
    sim:runUntil(function() return pendingEvent(sim.b,sim.id,"payment")~=nil end)
    local payment=assert(pendingEvent(sim.b,sim.id,"payment"))
    equal(balance(sim.a,e.id),700); equal(balance(sim.b,remote.id),1000)
    equal(sim.b.api.SharedService.GetBalance(sim.id).remainingCopper,1000)
    assert(sim.b.api.SharedService.Accept(payment.offerId)); sim:confirmed(payment.offerId)
    equal(balance(sim.b,remote.id),700); equal(balance(sim.a,e.id),700)
    local count=#sim.b.api.GetLedger().entries[remote.id].events
    for _,message in ipairs(sim.messages) do sim:replay(message) end
    equal(#sim.b.api.GetLedger().entries[remote.id].events,count)
end)

test("1.0 reversing a personal repayment creates a full shared correction and restores both after consent",function()
    local sim=network(); local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id))
    local paid=assert(sim.a.api.Pay(e.id,300,"External repayment"))
    sim:runUntil(function() return pendingEvent(sim.b,sim.id,"payment")~=nil end)
    local payment=assert(pendingEvent(sim.b,sim.id,"payment"))
    assert(sim.b.api.SharedService.Accept(payment.offerId)); sim:confirmed(payment.offerId)
    equal(balance(sim.b,remote.id),700)
    assert(sim.a.api.Reverse(e.id,paid.id,"Wrong amount"))
    sim:runUntil(function() return pendingEvent(sim.b,sim.id,"correction")~=nil end)
    local correction=assert(pendingEvent(sim.b,sim.id,"correction"))
    equal(balance(sim.a,e.id),1000); equal(balance(sim.b,remote.id),700)
    assert(sim.b.api.SharedService.Accept(correction.offerId)); sim:confirmed(correction.offerId)
    equal(balance(sim.a,e.id),1000); equal(balance(sim.b,remote.id),1000)
end)

test("1.0 reloading an agreed recipient keeps the same linked entry without creating another debt",function()
    local sim=network(); local e=sim:loan("item","owe",20)
    local remote=assert(linkFor(sim.b,sim.id))
    local saved=copy(sim.b.env.IOUDB)
    sim.b=client("Birch","Birch Vale",saved)
    local current,link=assert(linkFor(sim.b,sim.id))
    equal(current.id,remote.id); equal(link.state,"agreed")
    equal(#sim.b.api.GetLedger().entries,1); equal(balance(sim.b,current.id),20)
    equal(balance(sim.a,e.id),20)
end)

test("1.0 linked personal records reject counterparty replacement and cancellation",function()
    local sim=network(); local e=sim:loan("money","owed",1000)
    local api=sim.a.api
    local before=assert(api.Export())
    local changed,err=api.Amend(e.id,{player="Other Player",label="",note="",due=0},"")
    assert(not changed and type(err)=="string"); equal(assert(api.Export()),before)
    changed,err=api.Cancel(e.id,"")
    assert(not changed and type(err)=="string"); equal(assert(api.Export()),before)
    equal(balance(sim.a,e.id),1000)
end)

test("1.0 turning background requests off preserves a pending offer and resumes the same request",function()
    local sim=network(); local a,b=sim.a,sim.b
    local e=assert(a.api.Add({player="Birch Vale",kind="money",direction="owed",amount=1000,label="",note=""}))
    local offer=assert(a.api.Sharing.Share(e.id)); sim:received(offer.offerId)
    assert(a.api.Sharing.SetEnabled(false)); assert(not a.api.SharedService.IsEnabled())
    equal(balance(a,e.id),1000); equal(#b.api.GetLedger().entries,0)
    assert(a.api.Sharing.SetEnabled(true)); assert(a.api.SharedService.IsBackground())
    equal(a.api.SharedService.GetOffer(offer.offerId).state,"OFFER_OPEN")
    assert(b.api.SharedService.Accept(offer.offerId)); sim:confirmed(offer.offerId)
    equal(#a.api.GetLedger().entries,1); equal(#b.api.GetLedger().entries,1)
end)

test("1.0 relog resumes pending consent without replacing its identity or creating a second loan",function()
    local sim=network(); local a,b=sim.a,sim.b
    local e=assert(a.api.Add({player="Birch Vale",kind="money",direction="owed",amount=1000,label="",note=""}))
    local offer=assert(a.api.Sharing.Share(e.id)); sim:received(offer.offerId)
    sim.a=client("Amber","Amber Stone",copy(a.env.IOUDB))
    equal(sim.a.api.Sharing.GetLink(e.id).offerId,offer.offerId)
    assert(b.api.SharedService.Accept(offer.offerId)); sim:confirmed(offer.offerId)
    equal(#sim.a.api.GetLedger().entries,1); equal(#b.api.GetLedger().entries,1)
    equal(balance(sim.a,e.id),1000)
end)

-- Legacy snapshots intentionally lack the 1.0 link sidecar. Agreements remain
-- available, but adopting one requires an explicit action.
local function legacyPartial(kind,existingPaidEntry)
    local sim=network();local a,b=sim.a,sim.b
    local e,offer=sim:loan(kind,"owed",kind=="item" and 20 or 1000)
    local amount=kind=="item" and 7 or 300
    assert(a.api.Pay(e.id,amount,"Legacy partial repayment"))
    sim:runUntil(function() return pendingEvent(b,offer.offerId,"payment")~=nil end)
    local payment=assert(pendingEvent(b,offer.offerId,"payment"))
    assert(b.api.SharedService.Accept(payment.offerId));sim:confirmed(payment.offerId)
    local saved=copy(b.env.IOUDB)
    saved.sharingByCharacter=nil
    if not existingPaidEntry then saved.characters[b.api.Character()]=b.api.Ledger.New() end
    sim.b=client("Birch","Birch Vale",saved)
    return sim,e,offer,amount
end

test("1.0 explicit legacy adoption links existing partial personal history without paying twice",function()
    for _,kind in ipairs({"money","item"}) do
        local sim,_,offer,paid=legacyPartial(kind,true)
        local b=sim.b;equal(#b.api.GetLedger().entries,1)
        local original=b.api.GetLedger().entries[1];local count=#original.events
        assert(not b.api.Sharing.GetLink(original.id))
        local adopted=assert(b.api.Sharing.Adopt(offer.offerId))
        equal(adopted.id,original.id);equal(balance(b,adopted.id),adopted.amount-paid)
        equal(#b.api.GetLedger().entries,1);equal(#b.api.GetLedger().entries[1].events,count)
        equal(b.api.Sharing.GetLink(adopted.id).state,"agreed")
        b.api.Sharing.OnPersonalChanged();equal(#b.api.GetLedger().entries[1].events,count)
    end
end)

test("1.0 explicit legacy adoption creates original loan plus exactly one confirmed partial payment",function()
    for _,kind in ipairs({"money","item"}) do
        local sim,_,offer,paid=legacyPartial(kind,false)
        local b=sim.b;equal(#b.api.GetLedger().entries,0)
        local adopted=assert(b.api.Sharing.Adopt(offer.offerId))
        equal(adopted.amount,kind=="item" and 20 or 1000)
        equal(balance(b,adopted.id),adopted.amount-paid)
        equal(#b.api.GetLedger().entries,1);equal(#b.api.GetLedger().entries[1].events,1)
        local event=b.api.GetLedger().entries[1].events[1]
        equal(event.type,"payment");equal(event.amount,paid)
        equal(event.note,"Shared "..offer.offerId)
        assert(b.api.Sharing.Adopt(offer.offerId));b.api.Sharing.OnPersonalChanged()
        equal(#b.api.GetLedger().entries[1].events,1)
    end
end)

test("1.0 importing a personal ledger suspends linked synchronization until explicit review",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local a=sim.a;local imported=assert(a.api.Codec.Import(assert(a.api.Export())))
    assert(a.api.Ledger.Pay(imported,e.id,200,"Imported payment",a.env.time()))
    assert(a.api.ReplaceLedger(imported))
    local link=a.api.Sharing.GetLink(e.id)
    assert(link.suspended and link.state=="review" and link.pending)
    equal(a.api.Sharing.GetLinks()[e.id],nil);equal(balance(a,e.id),800)
    local count=#a.api.SharedService.List();a.api.Sharing.OnPersonalChanged()
    equal(#a.api.SharedService.List(),count)
    equal(a.api.SharedService.GetBalance(sim.id).remainingCopper,1000)
    equal(balance(a,e.id),800)
end)

test("1.0 recipient-only observed gold or material repayment synchronizes by hint without a second transfer",function()
    for _,kind in ipairs({"money","item"}) do
        local sim=network();local e=sim:loan(kind,"owed",kind=="item" and 20 or 1000)
        local remote=assert(linkFor(sim.b,sim.id));local paid=kind=="item" and 7 or 300
        local receipt=receipt(sim.b,"Amber Stone",kind,paid,true)
        equal(balance(sim.b,remote.id),remote.amount-paid)
        equal(balance(sim.a,e.id),e.amount)
        sim:runUntil(function()
            return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==e.amount-paid
                and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==e.amount-paid
        end)
        equal(balance(sim.a,e.id),e.amount-paid);equal(balance(sim.b,remote.id),remote.amount-paid)
        assert(sim.b.api.TradeService.Undo(receipt.id))
        equal(balance(sim.b,remote.id),remote.amount)
        sim:runUntil(function()
            return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==e.amount
                and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==e.amount
        end)
        equal(balance(sim.a,e.id),e.amount);equal(balance(sim.b,remote.id),remote.amount)
        local hintCount=0;for _,record in ipairs(sim.messages) do if record.message.kind=="SYNC" then hintCount=hintCount+1 end end
        assert(hintCount>=2,"recipient repayment and Undo did not send synchronization hints")
    end
end)

test("1.0 previously consumed native evidence cannot auto accept another manual repayment",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id))
    receipt(sim.b,"Amber Stone","money",100,true);receipt(sim.a,"Birch Vale","money",100,false)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==900
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==900
    end)
    local link=sim.b.api.Sharing.GetLink(remote.id)
    assert(link.evidenceRevision==1 and next(link.evidenceUsed)~=nil)
    assert(sim.a.api.Pay(e.id,100,"Unobserved manual repayment"))
    sim:runUntil(function() return pendingEvent(sim.b,sim.id,"payment")~=nil end)
    local pending=assert(pendingEvent(sim.b,sim.id,"payment"))
    equal(sim.b.api.SharedService.GetBalance(sim.id).remainingCopper,900)
    equal(balance(sim.b,remote.id),900)
    for _,record in ipairs(sim.messages) do sim:replay(record) end
    equal(sim.b.api.SharedService.GetOffer(pending.offerId).state,"OFFER_RECEIVED")
    equal(balance(sim.b,remote.id),900)
end)

test("1.0 read-only linked status uses detached cache without revalidating Shared history",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local api=sim.a.api;local original=api.SharedPayments.Views;local reads=0
    api.SharedPayments.Views=function(...) reads=reads+1;return original(...) end
    for _=1,100 do equal(api.Sharing.GetLink(e.id).state,"agreed") end
    equal(reads,0,"read-only linked badge revalidated the whole store")
    local detached=api.Sharing.GetLink(e.id);detached.state="changed";detached.evidenceUsed[99]=100
    equal(api.Sharing.GetLink(e.id).state,"agreed");equal(api.Sharing.GetLink(e.id).evidenceUsed[99],nil)
    api.SharedPayments.Views=original
end)

test("1.0 Options Requests toggle controls background traffic without manual setup",function()
    local state=client("Amber","Amber Stone");local api=state.api
    api.ShowSettings();local button=assert(api.UI.settings.requests)
    equal(button:GetText(),"Requests: on");assert(api.SharedService.IsBackground())
    state.click(button)
    assert(not api.GetSettings().sharedRequests and not api.SharedService.IsEnabled())
    equal(button:GetText(),"Requests: off")
    state.click(button)
    assert(api.GetSettings().sharedRequests and api.SharedService.IsBackground())
    equal(button:GetText(),"Requests: on")
end)

test("1.0 native material evidence tolerates different recipient viewer level and specialization",function()
    local sim=network();local e=sim:loan("item","owed",20)
    local remote=assert(linkFor(sim.b,sim.id))
    local left="|cffffffff|Hitem:2589:0:0:0:0:0:0:0:58:252|h[Linen Cloth]|h|r"
    local right="|cffffffff|Hitem:2589:0:0:0:0:0:0:0:23:103|h[Linen Cloth]|h|r"
    local sent=receipt(sim.b,"Amber Stone","item",7,true,right)
    local received=receipt(sim.a,"Birch Vale","item",7,false,left)
    equal(sent.status,"applied");equal(received.status,"applied")
    equal(balance(sim.a,e.id),13);equal(balance(sim.b,remote.id),13)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==13
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==13
    end)
    equal(balance(sim.a,e.id),13);equal(balance(sim.b,remote.id),13)
end)

test("1.0 lost first synchronization hint retries and recipient-only repayment converges",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id));local hints=0
    sim.drop=function(record)
        if record.message.kind=="SYNC" then hints=hints+1;return hints==1 end
    end
    receipt(sim.b,"Amber Stone","money",300,true)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==700
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==700
    end)
    assert(hints>=2 and hints<=3);equal(balance(sim.a,e.id),700);equal(balance(sim.b,remote.id),700)
end)

test("1.0 synchronization hint losses stop after three attempts and explicit review can retry",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id));local hints=0
    sim.drop=function(record) if record.message.kind=="SYNC" then hints=hints+1;return true end end
    receipt(sim.b,"Amber Stone","money",100,true)
    sim:runUntil(function() return hints==3 end)
    for _=1,90 do sim.a.advance(1);sim.b.advance(1);sim:route(sim.a,sim.b);sim:route(sim.b,sim.a) end
    equal(hints,3);equal(balance(sim.a,e.id),1000);equal(balance(sim.b,remote.id),900)
    sim.drop=nil
    assert(sim.b.api.Sharing.PrepareOffer(sim.id))
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==900
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==900
    end)
    equal(balance(sim.a,e.id),900);equal(balance(sim.b,remote.id),900)
end)

test("1.0 declined or withdrawn automatic repayment is retained without reproposal loops",function()
    for _,outcome in ipairs({"DECLINED","WITHDRAWN"}) do
        local sim=network();local e=sim:loan("money","owed",1000)
        assert(sim.a.api.Pay(e.id,100,"Unobserved repayment"))
        sim:runUntil(function() return pendingEvent(sim.b,sim.id,"payment")~=nil end)
        local pending=assert(pendingEvent(sim.b,sim.id,"payment"))
        if outcome=="DECLINED" then assert(sim.b.api.SharedService.Decline(pending.offerId))
        else assert(sim.a.api.SharedService.Withdraw(pending.offerId)) end
        sim:runUntil(function()
            local a,b=sim.a.api.SharedService.GetOffer(pending.offerId),sim.b.api.SharedService.GetOffer(pending.offerId)
            return a and b and a.state==outcome and b.state==outcome
        end)
        local count=#sim.a.api.SharedService.List()
        for _=1,60 do sim.a.advance(1);sim.b.advance(1);sim:route(sim.a,sim.b);sim:route(sim.b,sim.a) end
        equal(#sim.a.api.SharedService.List(),count);equal(#sim.b.api.SharedService.List(),count)
        equal(balance(sim.a,e.id),900);equal(sim.a.api.SharedService.GetBalance(sim.id).remainingCopper,1000)
    end
end)

test("1.0 explicit legacy material adoption recognizes viewer context and preserves partial history",function()
    local sim,_,offer,paid=legacyPartial("item",true)
    local b=sim.b;local saved=copy(b.env.IOUDB);saved.sharingByCharacter=nil
    local ledger=saved.characters[b.api.Character()];local entry=ledger.entries[1]
    local label="|Hitem:2589:0:0:0:0:0:0:0:23:103|h[Linen Cloth]|h"
    assert(b.api.Ledger.Amend(ledger,entry.id,{player=entry.player,label=label,note=entry.note,due=entry.due or 0},
        "Viewer context",b.env.time()))
    sim.b=client("Birch","Birch Vale",saved);b=sim.b
    local count=#b.api.GetLedger().entries[1].events
    local adopted=assert(b.api.Sharing.Adopt(offer.offerId))
    equal(adopted.id,1);equal(#b.api.GetLedger().entries,1);equal(balance(b,adopted.id),20-paid)
    equal(#b.api.GetLedger().entries[1].events,count+1)
    equal(b.api.SharedCodec.CanonicalItem(adopted.label),"item:2589")
    assert(b.api.Ledger.Validate(b.api.GetLedger()))
end)

return results
