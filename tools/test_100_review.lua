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
            label=kind=="item" and cloth or "",note="Crafting loan Bjørn blåbær",due=0}))
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
local function receipt(state,peer,kind,amount,outgoing)
    local service=state.api.TradeService
    local id=assert(service.NewSessionID("trade"))
    local asset={money=kind=="money" and amount or 0,items={}}
    if kind=="item" then asset.items={{itemID=2589,link=cloth,name="Linen Cloth",quantity=amount}} end
    return assert(service.Record({id=id,peer=peer,outgoing=outgoing and asset or {money=0,items={}},
        incoming=outgoing and {money=0,items={}} or asset}))
end

local function pendingEvent(state,parentId,kind)
    for _,offer in ipairs(assert(state.api.SharedService.List())) do
        local terms=assert(state.api.SharedCodec.ParseTerms(offer.terms))
        if terms.parentOfferId==parentId and (kind=="payment" and state.api.SharedCodec.IsPayment(terms)
            or kind=="correction" and state.api.SharedCodec.IsCorrection(terms))
            and offer.state=="OFFER_RECEIVED" then return offer end
    end
end

test("review shared correction reconciles a peer whose native repayment grouped two local allocations",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id))
    local first=assert(sim.a.api.Pay(e.id,100,"First allocation"))
    assert(sim.a.api.Pay(e.id,200,"Second allocation"))
    receipt(sim.b,"Amber Stone","money",300,true)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==700
            and sim.b.api.SharedService.GetBalance(sim.id).remainingCopper==700
    end)
    equal(balance(sim.b,remote.id),700)
    assert(sim.a.api.Reverse(e.id,first.id,"Undo first allocation"))
    sim:runUntil(function() return pendingEvent(sim.b,sim.id,"correction")~=nil end)
    local correction=assert(pendingEvent(sim.b,sim.id,"correction"))
    assert(sim.b.api.SharedService.Accept(correction.offerId));sim:confirmed(correction.offerId)
    equal(sim.b.api.SharedService.GetBalance(sim.id).remainingCopper,800)
    equal(balance(sim.b,remote.id),800,"accepted shared correction must reach the peer personal ledger")
end)
test("review native repayment after manually accepted history can auto acknowledge its new evidence",function()
    local sim=network();local e=sim:loan("money","owed",1000)
    local remote=assert(linkFor(sim.b,sim.id))
    assert(sim.a.api.Pay(e.id,300,"Earlier manual repayment"))
    sim:runUntil(function() return pendingEvent(sim.b,sim.id,"payment")~=nil end)
    local payment=assert(pendingEvent(sim.b,sim.id,"payment"))
    assert(sim.b.api.SharedService.Accept(payment.offerId));sim:confirmed(payment.offerId)
    equal(balance(sim.b,remote.id),700)
    receipt(sim.b,"Amber Stone","money",100,true)
    receipt(sim.a,"Birch Vale","money",100,false)
    sim:runUntil(function()
        return sim.a.api.SharedService.GetBalance(sim.id).remainingCopper==600
            or pendingEvent(sim.b,sim.id,"payment")~=nil
    end)
    assert(not pendingEvent(sim.b,sim.id,"payment"),"new observed 100 still needs manual review because earlier accepted 300 was not a native transfer")
end)
test("review imported unrelated ids do not prevent explicit reattachment of an old agreed loan",function()
    local sim=network();sim:loan("money","owed",1000)
    local api=sim.a.api;local imported=api.Ledger.New()
    assert(api.Ledger.Add(imported,{player="Cedar Leaf",direction="owe",kind="money",amount=77,label="",note="",due=0},200))
    assert(api.ReplaceLedger(imported))
    local linked,err=api.Sharing.Adopt(sim.id)
    assert(linked,err)
    equal(linked.id,2);equal(linked.player,"Birch Vale")
    equal(#api.GetLedger().entries,2)
    equal(api.Sharing.GetLink(2).offerId,sim.id)
end)
test("review imported unrelated ids are not treated as the previous shared borrower",function()
    local sim=network();sim:loan("money","owed",1000)
    local api=sim.a.api;local imported=api.Ledger.New()
    local other=assert(api.Ledger.Add(imported,{player="Cedar Leaf",direction="owe",kind="money",amount=77,label="",note="",due=0},200))
    assert(api.ReplaceLedger(imported))
    equal(api.Sharing.GetLink(other.id),nil,"an imported different loan reused an old local id")
    assert(api.Cancel(other.id,"Unrelated imported record"))
end)
return results
