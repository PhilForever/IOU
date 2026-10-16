local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results+1] = name
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function same(a,b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function rejected(call)
    local result, err = call()
    assert(result == nil and type(err) == "string" and #err > 0, "operation must reject with an explanation")
    return err
end
local function peer(name, key, saved)
    local ctx = {name=name, key=key, stamp=100, queue={}, enabled=false, enableCount=0, sendCount=0}
    if saved == nil then saved = {version=1, characters={[key]={marker="private personal ledger"}}, settings={marker=true}, recovery={}} end
    local env = setmetatable({IOUDB=saved, time=function() return ctx.stamp end}, {__index=_G})
    env._G=env
    ctx.env, ctx.db = env, saved
    local ns = {
        Initialize=function() return true end,
        Character=function() return ctx.key end,
        Transport={
            GetLocalName=function() return ctx.name end,
            CanonicalName=function(value)
                if type(value) ~= "string" or #value > 96 or value == "" or value:find("[%z\001-\031\127|]") then return nil,"Invalid full name." end
                return value:gsub("%s+"," "):match("^%s*(.-)%s*$")
            end,
        },
    }
    local wire = {}
    function wire.Enable(other, callback)
        ctx.enabled, ctx.other, ctx.receive = true, other, callback
        ctx.enableCount=ctx.enableCount+1
        return true
    end
    function wire.Disable()
        ctx.enabled,ctx.other,ctx.receive,ctx.queue=false,nil,nil,{}
        if ns.OnSharedWireChanged then ns.OnSharedWireChanged() end
    end
    function wire.IsEnabled() return ctx.enabled end
    function wire.GetStatus() return ctx.wireError or "Wire test stub." end
    function wire.CanQueue(actions)
        if ctx.throwQueue then error("queue preflight failed") end
        if not ctx.enabled or ctx.full then return nil,"Wire queue full or disabled." end
        return true
    end
    function wire.Send(actions)
        if ctx.beforeSend then ctx.beforeSend(actions) end
        if ctx.throwSend then error("enqueue failed") end
        if ctx.sendFail then return nil,"Enqueue failed." end
        ctx.sendCount=ctx.sendCount+1
        for _,action in ipairs(actions) do ctx.queue[#ctx.queue+1]=copy(action) end
        return true
    end
    ns.SharedWire=wire
    for _,file in ipairs({"shared_codec.lua","shared.lua","shared_payments.lua","shared_service.lua"}) do
        local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file))
        setfenv(chunk,env); chunk("IOU",ns)
    end
    ctx.ns,ctx.service=ns,ns.SharedService
    return ctx
end
local function pair()
    local a=peer("Amber Stone","Amber-ExistingStorage")
    local b=peer("Birch Vale","Birch-AnotherStorage")
    assert(a.service.Enable(b.name)); assert(b.service.Enable(a.name))
    return a,b
end
local function propose(a,b,changes)
    local fields={peer=b.name,direction="owed",amountCopper=10000,note="Mount training",dueUTC=0}
    for key,value in pairs(changes or {}) do fields[key]=value end
    return a.service.Propose(fields)
end
local function deliver(a,b)
    local action=assert(table.remove(a.queue,1),"no queued message")
    assert(action.target==b.name and b.receive,"wrong delivery target or disabled receiver")
    return b.receive(a.name,action.message)
end

test("shared service initializes under the existing character key without enabling traffic or changing personal records",function()
    local a=peer("Amber Stone","Legacy-Key")
    local personal,settings,recovery=copy(a.db.characters),copy(a.db.settings),copy(a.db.recovery)
    assert(a.service.Initialize())
    assert(a.enableCount==0 and not a.service.IsEnabled() and #a.queue==0)
    assert(a.db.sharedByCharacter["Legacy-Key"].store.localName==a.name)
    assert(same(personal,a.db.characters) and same(settings,a.db.settings) and same(recovery,a.db.recovery))
    local store=assert(a.service.GetStore()); store.localName="Mutated Copy"
    assert(a.service.GetStore().localName==a.name)
end)

test("two persistent services record consent before enqueue and complete one exact shared handshake",function()
    local a,b=pair()
    a.beforeSend=function(actions)
        for _,action in ipairs(actions) do
            local saved=a.db.sharedByCharacter[a.key].store.offers[action.message.offerId]
            assert(saved and saved.messages[action.message.kind:lower()],"outgoing record must already be saved")
        end
    end
    b.beforeSend=function(actions)
        for _,action in ipairs(actions) do
            local saved=b.db.sharedByCharacter[b.key].store.offers[action.message.offerId]
            assert(saved and saved.messages[action.message.kind:lower()],"local consent must precede enqueue")
        end
    end
    local offer=assert(propose(a,b)); local id=offer.offerId
    assert(deliver(a,b)); assert(b.service.GetOffer(id).state=="OFFER_RECEIVED")
    assert(b.service.Accept(id)); assert(b.service.GetOffer(id).state=="ACCEPT_PENDING")
    assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    assert(a.service.GetOffer(id).state=="COMMITTED" and b.service.GetOffer(id).state=="COMMITTED")
    assert(a.service.GetOffer(id).delivery=="PEER_RECEIPT_OBSERVED")
    local listed=a.service.List(); listed[1].messages.commit.commitId="changed"
    assert(a.service.GetOffer(id).messages.commit.commitId~="changed")
    assert(#a.service.List()==1 and #b.service.List()==1)
end)

test("shared queue preflight failures reject atomically before proposal or consent persistence",function()
    local a,b=pair()
    local before=copy(a.db)
    a.full=true; rejected(function() return propose(a,b) end)
    assert(same(before,a.db) and #a.queue==0)
    a.full=false; local offer=assert(propose(a,b)); assert(deliver(a,b))
    local beforeB=copy(b.db)
    b.full=true; rejected(function() return b.service.Accept(offer.offerId) end)
    assert(same(beforeB,b.db) and b.service.GetOffer(offer.offerId).state=="OFFER_RECEIVED")
    b.full=false; b.throwQueue=true
    rejected(function() return b.service.Accept(offer.offerId) end)
    assert(same(beforeB,b.db))
end)

test("a failed enqueue after persistence preserves exact local consent for explicit retry",function()
    local a,b=pair()
    a.sendFail=true
    local result,proposalError,offer=propose(a,b)
    assert(not result and proposalError:find("saved",1,true) and offer.state=="OFFER_OPEN")
    assert(a.service.GetOffer(offer.offerId).state=="OFFER_OPEN" and #a.service.List()==1 and #a.queue==0)
    a.sendFail=false; assert(a.service.Retry(offer.offerId)); assert(deliver(a,b))
    b.sendFail=true
    local failed,err,saved=b.service.Accept(offer.offerId)
    assert(not failed and saved and saved.state=="ACCEPT_PENDING")
    assert(err:find("saved",1,true) and b.service.GetOffer(offer.offerId).state=="ACCEPT_PENDING")
    local accepted=copy(b.db.sharedByCharacter[b.key].store.offers[offer.offerId].messages.accept)
    b.sendFail=false; assert(b.service.Retry(offer.offerId))
    assert(same(accepted,b.queue[1].message))
    assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    assert(a.service.GetOffer(offer.offerId).state=="COMMITTED")
end)

test("reload pauses each incomplete handshake stage and never resumes traffic or missing consent",function()
    for step=1,4 do
        local a,b=pair()
        local offer=assert(propose(a,b)); local id=offer.offerId
        if step>=2 then assert(deliver(a,b)) end
        if step>=3 then assert(b.service.Accept(id)) end
        if step>=4 then assert(deliver(b,a)) end
        local aa=peer(a.name,a.key,copy(a.db)); aa.stamp=200
        local bb=peer(b.name,b.key,copy(b.db)); bb.stamp=200
        assert(aa.service.Initialize()); assert(bb.service.Initialize())
        assert(aa.enableCount==0 and bb.enableCount==0 and #aa.queue==0 and #bb.queue==0)
        local oa=aa.service.GetOffer(id)
        assert(oa.state==(step==4 and "COMMITTED" or "PAUSED"))
        if step>=2 then assert(bb.service.GetOffer(id).state=="PAUSED") end
        assert(aa.service.Enable(bb.name))
        if step<4 then rejected(function() return aa.service.Retry(id) end) end
        if step>=2 then
            assert(bb.service.Enable(aa.name))
            rejected(function() return bb.service.Accept(id) end)
        end
    end
end)

test("closing paused offers keeps local tombstones, blocks delayed packets and requires reviewed replacements",function()
    local a,b=pair()
    local offer=assert(propose(a,b)); local proposal=copy(a.queue[1].message)
    assert(deliver(a,b)); assert(b.service.Accept(offer.offerId))
    local acceptance=copy(b.queue[1].message)
    assert(a.service.Disable()); assert(a.service.GetOffer(offer.offerId).state=="PAUSED" and #a.queue==0)
    assert(a.service.Enable(b.name)); rejected(function() return propose(a,b) end)
    rejected(function() return a.service.ClosePaused(offer.offerId,"Reviewed") end)
    assert(a.service.Disable())
    rejected(function() return a.service.ClosePaused(offer.offerId,"  ") end)
    local closed=assert(a.service.ClosePaused(offer.offerId,"Reviewed both local records with peer"))
    assert(closed.localClosed and closed.messages.propose and closed.localCloseReason~="")
    assert(a.service.Enable(b.name)); local before=copy(a.db)
    rejected(function() return a.receive(b.name,acceptance) end)
    assert(same(before,a.db))
    local replacement=assert(propose(a,b)); assert(replacement.offerId~=offer.offerId)
    assert(#a.service.List()==2)
    assert(b.service.Disable()); assert(b.service.Enable(a.name))
    local nextMessage=copy(a.queue[1].message)
    rejected(function() return b.receive(a.name,nextMessage) end)
    assert(b.service.Disable()); assert(b.service.ClosePaused(offer.offerId,"Reviewed separately"))
    assert(b.service.Enable(a.name)); assert(b.receive(a.name,nextMessage))
    rejected(function() return b.receive(a.name,proposal) end)
end)

test("invalid or foreign shared storage is retained while the personal ledger remains usable",function()
    local base=peer("Amber Stone","Legacy-Key"); assert(base.service.Initialize())
    local bads={false,{version=99},copy(base.db.sharedByCharacter[base.key])}
    bads[3].store.localName="Another Character"
    for _,bad in ipairs(bads) do
        local db={version=1,characters={marker="personal"},sharedByCharacter={["Legacy-Key"]=bad}}
        local original=copy(db); local a=peer(base.name,base.key,db)
        rejected(function() return a.service.Initialize() end)
        assert(same(original,db) and a.ns.Initialize() and not a.service.IsEnabled())
    end
    local db={version=1,characters={marker="personal"},sharedByCharacter="bad"}
    local original=copy(db); local a=peer(base.name,base.key,db)
    rejected(function() return a.service.GetStore() end); assert(same(original,db))
    local b=peer(base.name,base.key,copy(base.db)); b.name=nil
    rejected(function() return b.service.Initialize() end)
    assert(same(base.db,b.db))
end)

test("incoming offer limits, foreign senders and queue rejection preserve retained evidence",function()
    local a,b=pair()
    for _=1,4 do assert(propose(a,b)); assert(deliver(a,b)) end
    local fifth=assert(propose(a,b)); local message=copy(a.queue[1].message)
    local before=copy(b.db)
    rejected(function() return deliver(a,b) end); assert(same(before,b.db) and #b.service.List()==4)
    rejected(function() return b.receive("Other Player",message) end); assert(same(before,b.db))
    local altered=copy(message); altered.terms=altered.terms.."garbage"
    rejected(function() return b.receive(a.name,altered) end); assert(same(before,b.db))
    local first=b.service.List()[1]; assert(b.service.Accept(first.offerId))
    assert(deliver(b,a))
    b.full=true; local pending=copy(b.db)
    rejected(function() return deliver(a,b) end)
    assert(same(pending,b.db) and b.service.GetOffer(first.offerId).state=="ACCEPT_PENDING")
    assert(fifth.offerId~=first.offerId)
end)

test("shared callbacks are protected and reentrant errors cannot overwrite saved consent",function()
    local a,b=pair()
    a.ns.OnSharedChanged=function() error("UI failed") end
    local offer=assert(propose(a,b)); assert(a.service.GetOffer(offer.offerId))
    a.ns.OnSharedChanged=function() a.service.List() end
    a.db.sharedByCharacter[a.key]={invalid=true}
    rejected(function() return a.service.GetStore() end)
    assert(a.db.sharedByCharacter[a.key].invalid and not a.service.IsEnabled())
    local c=peer(nil,"Unknown")
    c.ns.OnSharedChanged=function() c.service.GetStore() end
    rejected(function() return c.service.Initialize() end)
end)

test("out-of-range terminal timestamps and changed live character identity leave shared and personal storage untouched",function()
    local a,b=pair()
    local offer=assert(propose(a,b)); assert(deliver(a,b)); assert(b.service.Accept(offer.offerId))
    assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    local db=copy(a.db)
    local corrupt=db.sharedByCharacter[a.key].store.offers[offer.offerId]
    corrupt.createdAt,corrupt.updatedAt=4102444801,4102444801
    for _,event in ipairs(corrupt.history) do event.at=4102444801 end
    local before=copy(db); local reloaded=peer(a.name,a.key,db)
    rejected(function() return reloaded.service.Initialize() end)
    assert(same(before,db) and reloaded.ns.Initialize())
    local unchanged=copy(a.db)
    a.key="Different-Legacy-Key"
    rejected(function() return a.service.GetStore() end)
    assert(same(unchanged,a.db) and not a.service.IsEnabled())
end)

test("unexpected wire stops pause persisted offers and preserve the communication error",function()
    local a,b=pair()
    local offer=assert(propose(a,b))
    a.enabled,a.queue,a.wireError=false,{},"Shared monotonic clock is unavailable."
    a.ns.OnSharedWireChanged()
    assert(not a.service.IsEnabled() and a.service.GetOffer(offer.offerId).state=="PAUSED")
    assert(a.service.GetStatus():find("monotonic clock",1,true))
    assert(a.service.Enable(b.name))
    rejected(function() return a.service.Retry(offer.offerId) end)
    local stopped=copy(a.db)
    assert(a.service.Disable())
    assert(same(stopped,a.db),"repeated disable must not duplicate pause history")
end)

test("a failed pause latches recovery until a valid wall clock allows reconnection safely",function()
    for _,unexpected in ipairs({false,true}) do
        local a,b=pair()
        local offer=assert(propose(a,b)); local before=copy(a.db)
        a.stamp=nil
        if unexpected then
            a.enabled,a.queue,a.wireError=false,{},"Shared monotonic clock is unavailable."
            a.ns.OnSharedWireChanged()
        else rejected(function() return a.service.Disable() end) end
        assert(not a.service.IsEnabled() and #a.queue==0 and same(before,a.db))
        assert(a.service.GetStatus():lower():find("recovery",1,true))
        rejected(function() return a.service.Enable(b.name) end)
        assert(same(before,a.db) and not a.service.IsEnabled())
        a.stamp=99
        rejected(function() return a.service.Enable(b.name) end)
        assert(same(before,a.db) and not a.service.IsEnabled())
        a.stamp=200
        assert(a.service.Enable(b.name))
        assert(a.service.GetOffer(offer.offerId).state=="PAUSED")
        rejected(function() return a.service.Retry(offer.offerId) end)
        assert(#a.queue==0)
    end
end)

test("shared payment service persists consent, enforces ACK sequencing and derives the agreed remaining gold",function()
    local a,b=pair()
    local parent=assert(propose(a,b))
    assert(deliver(a,b)); assert(b.service.Accept(parent.offerId)); assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    local unchanged=copy(a.db)
    a.full=true
    rejected(function() return a.service.ProposePayment(parent.offerId,2500,"Partial repayment") end)
    assert(same(unchanged,a.db))
    a.full=false
    local payment=assert(a.service.ProposePayment(parent.offerId,2500,"Partial repayment"))
    assert(deliver(a,b)); assert(b.service.Accept(payment.offerId)); assert(deliver(b,a)); assert(deliver(a,b))
    assert(a.service.GetBalance(parent.offerId).remainingCopper==10000)
    assert(b.service.GetBalance(parent.offerId).remainingCopper==7500)
    rejected(function() return a.service.ProposePayment(parent.offerId,1000,"Wait for ACK") end)
    assert(deliver(b,a)); assert(a.service.GetBalance(parent.offerId).remainingCopper==7500)
    rejected(function() return b.service.ProposePayment(parent.offerId,1000,"Recipient cannot sequence") end)
    rejected(function() return a.service.ProposePayment(parent.offerId,7501,"Overpayment") end)
    assert(a.db.characters[a.key].marker=="private personal ledger")
end)

test("shared full corrections require both clients and leave their original payment and parent audit intact",function()
    local a,b=pair()
    local parent=assert(propose(a,b))
    assert(deliver(a,b)); assert(b.service.Accept(parent.offerId)); assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    local payment=assert(a.service.ProposePayment(parent.offerId,4000,"Recorded payment"))
    assert(deliver(a,b)); assert(b.service.Accept(payment.offerId)); assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    rejected(function() return a.service.ProposeCorrection(parent.offerId,payment.offerId,"") end)
    local correction=assert(a.service.ProposeCorrection(parent.offerId,payment.offerId,"Both players reviewed the wrong amount"))
    assert(a.service.GetBalance(parent.offerId).remainingCopper==6000)
    assert(deliver(a,b)); assert(b.service.Accept(correction.offerId)); assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    local view=a.service.GetBalance(parent.offerId)
    assert(view.remainingCopper==10000 and view.events[1].reversed)
    assert(a.service.GetOffer(payment.offerId).state=="COMMITTED")
    assert(a.service.GetOffer(parent.offerId).messages.commit)
    rejected(function() return a.service.ProposeCorrection(parent.offerId,payment.offerId,"Again") end)
end)

test("reloaded paused financial proposals cannot duplicate or silently change an established balance",function()
    local a,b=pair()
    local parent=assert(propose(a,b))
    assert(deliver(a,b)); assert(b.service.Accept(parent.offerId)); assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    local payment=assert(a.service.ProposePayment(parent.offerId,3000,"Interrupted"))
    local pending=copy(a.queue[1].message)
    local restored=peer(a.name,a.key,copy(a.db)); restored.stamp=200
    assert(restored.service.Initialize()); assert(restored.service.GetOffer(payment.offerId).state=="PAUSED")
    assert(restored.service.Enable(b.name))
    rejected(function() return restored.service.ProposePayment(parent.offerId,3000,"Duplicate") end)
    assert(restored.service.Disable()); assert(restored.service.ClosePaused(payment.offerId,"Reconciled with peer"))
    assert(restored.service.Enable(b.name))
    local fresh=assert(restored.service.ProposePayment(parent.offerId,3000,"Fresh explicit offer"))
    assert(fresh.offerId~=payment.offerId and restored.service.GetBalance(parent.offerId).remainingCopper==10000)
    rejected(function() return restored.receive(b.name,pending) end)
end)

return results
