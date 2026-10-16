local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function copy(value)
    if type(value)~="table" then return value end
    local out={}; for key,item in pairs(value) do out[key]=copy(item) end; return out
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,item in pairs(a) do if not same(item,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function reject(call)
    local result,err=call()
    assert(result==nil and type(err)=="string" and #err>0,"expected explained rejection")
end
local function forbidden() error("payment domain invoked a game or persistence API") end
local env=setmetatable({IOUDB={sentinel=true},time=forbidden,CreateFrame=forbidden,
    C_ChatInfo={SendAddonMessageLogged=forbidden}}, {__index=_G})
env._G=env
local ns={}
for _,file in ipairs({"shared_codec.lua","shared.lua","shared_payments.lua"}) do
    local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file))
    setfenv(chunk,env); chunk("IOU",ns)
end
local C,S,P=ns.SharedCodec,ns.Shared,ns.SharedPayments
local function sim(reverse,stopParentAck,settings)
    settings=settings or {}
    local a={name="Amber Stone",store=assert(S.New("Amber Stone")),queue={},closed={}}
    local b={name="Birch Vale",store=assert(S.New("Birch Vale")),queue={},closed={}}
    local world={a=a,b=b,stamp=100,serial=0,parent=settings.parentId or "parent-offer"}
    function world.apply(actor,method,...)
        world.stamp=world.stamp+1
        local args={...}; args[#args+1]=world.stamp
        local updated,actions=method(actor.store,unpack(args))
        assert(updated,actions); assert(P.Validate(updated,actor.closed))
        actor.store=updated
        for _,action in ipairs(actions) do actor.queue[#actor.queue+1]=copy(action.message) end
        return updated
    end
    function world.move(from,to)
        local message=assert(table.remove(from.queue,1))
        world.apply(to,S.Receive,from.name,message)
        return message
    end
    function world.offer(terms,longIds)
        world.serial=world.serial+1
        local id=longIds and "payment-of-"..string.rep("o",47)..world.serial or "event-offer-"..world.serial
        local agreement=longIds and "payment-ag-"..string.rep("a",47)..world.serial or "event-agreement-"..world.serial
        world.apply(a,S.Propose,terms,agreement,id)
        world.move(a,b)
        return id
    end
    function world.payment(amount,note)
        return world.offer(assert(P.BuildPayment(a.store,world.parent,amount,note,a.closed)))
    end
    function world.finish(id,stopAck)
        world.apply(b,S.Accept,id); world.move(b,a); world.move(a,b)
        if not stopAck then world.move(b,a) end
    end
    local terms={protocol=1,kind="GOLD_OBLIGATION",proposer=a.name,recipient=b.name,
        debtor=reverse and a.name or b.name,creditor=reverse and b.name or a.name,
        amountCopper=10000,dueUTC=0,note=settings.parentNote or "Original gold agreement"}
    world.apply(a,S.Propose,terms,settings.parentAgreementId or "parent-agreement",world.parent); world.move(a,b)
    world.apply(b,S.Accept,world.parent); world.move(b,a); world.move(a,b)
    if not stopParentAck then world.move(b,a) end
    return world
end

test("shared payment balances derive from two-player consent in either original debt direction",function()
    for _,reverse in ipairs({false,true}) do
        local w=sim(reverse); local a,b=w.a,w.b
        local before=copy(a.store)
        local id=w.payment(3000,"First repayment")
        assert(P.View(a.store,w.parent).remainingCopper==10000)
        assert(P.View(b.store,w.parent).remainingCopper==10000)
        w.finish(id)
        assert(P.View(a.store,w.parent).remainingCopper==7000 and P.View(b.store,w.parent).remainingCopper==7000)
        local view=P.View(a.store,w.parent)
        assert(view.paidCopper==3000 and view.events[1].effective and view.baseRevision==1)
        assert(before.offers[w.parent].terms==a.store.offers[w.parent].terms)
        assert(P.Validate(a.store) and P.Validate(b.store))
    end
end)

test("parent and child acknowledgment barriers serialize payments without claiming simultaneous balance knowledge",function()
    local w=sim(false,true); local a,b=w.a,w.b
    reject(function() return P.BuildPayment(a.store,w.parent,1,"Too early") end)
    w.move(b,a)
    local id=w.payment(4000,"Partial repayment"); w.finish(id,true)
    local av,bv=P.View(a.store,w.parent),P.View(b.store,w.parent)
    assert(av.remainingCopper==10000 and av.awaitingAck and av.pendingOfferId==id)
    assert(bv.remainingCopper==6000 and not bv.awaitingAck)
    reject(function() return P.BuildPayment(a.store,w.parent,1000,"Wait for ACK") end)
    local beforeB=copy(b.store); w.apply(a,S.Retry,id); w.move(a,b)
    assert(same(beforeB,b.store),"duplicate commitment must not append payment history")
    w.move(b,a)
    assert(P.View(a.store,w.parent).remainingCopper==6000)
    local beforeA=copy(a.store); w.move(b,a)
    assert(same(beforeA,a.store),"duplicate ACK must not append payment history")
end)

test("partial and final shared repayments settle exactly and reject overpayment without changing stores",function()
    local w=sim(); local a=w.a
    local before=copy(a.store)
    reject(function() return P.BuildPayment(a.store,w.parent,10001,"Too much") end)
    reject(function() return P.BuildPayment(a.store,w.parent,0,"Nothing") end)
    reject(function() return P.BuildPayment(a.store,w.parent,1.5,"Fraction") end)
    reject(function() return P.BuildPayment(a.store,w.parent,100,false) end)
    assert(same(before,a.store))
    w.finish(w.payment(2500,"Partial")); w.finish(w.payment(7500,"Final"))
    local view=P.View(a.store,w.parent)
    assert(view.remainingCopper==0 and view.paidCopper==10000 and view.state=="SETTLED")
    reject(function() return P.BuildPayment(a.store,w.parent,1,"Overpaid") end)
end)

test("full shared corrections retain the payment and need new mutual consent and a reason exactly once",function()
    local w=sim(); local a,b=w.a,w.b
    local payment=w.payment(7000,"Incorrect amount recorded"); w.finish(payment)
    local before=copy(a.store)
    reject(function() return P.BuildCorrection(a.store,w.parent,payment," ") end)
    reject(function() return P.BuildCorrection(a.store,w.parent,"missing","Reason") end)
    assert(same(before,a.store))
    local terms=assert(P.BuildCorrection(a.store,w.parent,payment,"Both agree the record was wrong"))
    assert(terms.amountCopper==7000 and terms.reversesId==payment)
    local correction=w.offer(terms)
    assert(P.View(a.store,w.parent).remainingCopper==3000)
    w.finish(correction)
    local view=P.View(a.store,w.parent)
    assert(view.remainingCopper==10000 and view.paidCopper==0 and view.events[1].reversed)
    assert(view.events[2].kind=="GOLD_CORRECTION" and view.events[2].note==terms.note)
    assert(a.store.offers[payment].state=="COMMITTED" and b.store.offers[payment].state=="COMMITTED")
    reject(function() return P.BuildCorrection(a.store,w.parent,payment,"Again") end)
    reject(function() return P.BuildCorrection(a.store,w.parent,correction,"Reverse reversal") end)
    w.finish(w.payment(10000,"Replacement correct record"))
    assert(P.View(a.store,w.parent).state=="SETTLED")
end)

test("the recipient cannot sequence financial events and a second in-flight event fails validation atomically",function()
    local w=sim(); local a,b=w.a,w.b
    reject(function() return P.BuildPayment(b.store,w.parent,100,"Recipient request") end)
    local terms=assert(P.BuildPayment(a.store,w.parent,1000,"First event"))
    w.payment(2000,"Pending event")
    local before=copy(a.store)
    reject(function() return P.BuildPayment(a.store,w.parent,1000,"Concurrent") end)
    local candidate=assert(S.Propose(a.store,terms,"other-agreement","other-offer",200))
    reject(function() return P.Validate(candidate) end)
    assert(same(before,a.store))
end)

test("exact canonical chain bindings reject stale prefixes, changed event semantics and invented local consent",function()
    local w=sim(); local a,b=w.a,w.b
    local stale=assert(P.BuildPayment(a.store,w.parent,1000,"Stale draft"))
    local payment=w.payment(3000,"Confirmed repayment"); w.finish(payment)
    local before=copy(a.store)
    local candidate=assert(S.Propose(a.store,stale,"stale-agreement","stale-offer",200))
    reject(function() return P.Validate(candidate) end)
    local forged=assert(P.BuildPayment(a.store,w.parent,1000,"Next"))
    local rows=assert(C.ParseChain(forged.baseChain)); rows[1].note="Changed prior note"
    forged.baseChain=assert(C.CanonicalChain(rows))
    candidate=assert(S.Propose(a.store,forged,"forged-agreement","forged-offer",200))
    reject(function() return P.Validate(candidate) end)
    local missing=copy(b.store); missing.offers[payment]=nil
    local current=assert(P.BuildPayment(a.store,w.parent,1000,"Locally missing event"))
    candidate=assert(S.Receive(missing,a.name,{version=1,kind="PROPOSE",messageId="missing-message",
        agreementId="missing-agreement",offerId="missing-offer",revision=1,
        terms=assert(C.CanonicalTerms(current))},200))
    reject(function() return P.Validate(candidate) end)
    assert(same(before,a.store))
end)

test("paused payment consent blocks replacements until reviewed and closed copies never alter the accepted balance",function()
    local w=sim(); local a,b=w.a,w.b
    local id=w.payment(3000,"Interrupted")
    w.apply(a,S.Pause); w.apply(b,S.Pause)
    reject(function() return P.BuildPayment(a.store,w.parent,1000,"Replacement",a.closed) end)
    a.closed[id]={at=200,reason="Reviewed with peer"}
    b.closed[id]={at=200,reason="Reviewed with peer"}
    assert(P.Validate(a.store,a.closed) and P.Validate(b.store,b.closed))
    assert(P.View(a.store,w.parent,a.closed).remainingCopper==10000)
    assert(P.BuildPayment(a.store,w.parent,1000,"Fresh consent",a.closed))
    assert(a.store.offers[id].state=="PAUSED")
end)

test("domain snapshots are independent and orphaned or mismatched payment parents fail closed",function()
    local w=sim(); local a=w.a
    local id=w.payment(1000,"Event"); w.finish(id)
    local view=assert(P.View(a.store,w.parent)); view.events[1].note="Changed snapshot"
    assert(P.View(a.store,w.parent).events[1].note=="Event")
    local corrupted=copy(a.store); corrupted.offers[w.parent]=nil
    reject(function() return P.Validate(corrupted) end)
    local wrong=assert(P.BuildPayment(a.store,w.parent,1000,"Wrong parent"))
    wrong.parentCommitId="different-commit"
    local candidate=assert(S.Propose(a.store,wrong,"wrong-agreement","wrong-offer",300))
    reject(function() return P.Validate(candidate) end)
    assert(env.IOUDB.sentinel)
end)

test("financial proposals reserve the complete handshake envelope before recording boundary-sized consent",function()
    local w=sim(false,false,{parentId="parent-of",parentAgreementId="parent-ag",parentNote=string.rep("X",512)})
    local a,b=w.a,w.b
    for _=1,4 do
        local terms=assert(P.BuildPayment(a.store,w.parent,1,string.rep("P",512)))
        w.finish(w.offer(terms,true))
    end
    local base=assert(P.BuildPayment(a.store,w.parent,1,""))
    base.note=string.rep("P",472)
    assert(C.ValidateTerms(base))
    local id="payment-of-"..string.rep("o",47).."5"
    local ag="payment-ag-"..string.rep("a",47).."5"
    local candidate,actions=S.Propose(a.store,base,ag,id,500)
    assert(candidate,actions)
    local proposed=assert(C.Encode(actions[1].message))
    assert(#proposed<=4096,"fixture must fit the PROPOSE envelope")
    local received=assert(S.Receive(b.store,a.name,actions[1].message,500))
    reject(function() return S.Accept(received,id,501) end)
    local originalA,originalB=copy(a.store),copy(b.store)
    reject(function() return P.BuildPayment(a.store,w.parent,1,base.note) end)
    reject(function() return P.Validate(candidate) end)
    reject(function() return P.Validate(received) end)
    assert(same(originalA,a.store) and same(originalB,b.store))
end)

return results
