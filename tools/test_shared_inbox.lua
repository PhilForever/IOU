-- Background invitations are transient until the local player accepts.
-- Engine-generated consent messages and a queue stub exercise service atomicity.
local results={}
local function test(name,run)
    local ok,err=pcall(run);if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,item in pairs(a) do if not same(item,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function count(map) local n=0;for _ in pairs(map) do n=n+1 end;return n end
local function rejected(call)
    local result,err=call();assert(not result and type(err)=="string" and #err>0,"expected a reasoned rejection")
end
local function client()
    local state={name="Birch Vale",stamp=1000,clock=10,queue={}}
    local env=setmetatable({IOUDB={},time=function() return state.stamp end,GetTime=function() return state.clock end},{__index=_G})
    env._G=env;state.env=env
    local api={Initialize=function() return true end,Character=function() return "Birch-Test" end,
        Transport={GetLocalName=function() return state.name end,CanonicalName=function(value)
            if type(value)~="string" or value=="" or value:find("[%z\1-\31\127|]") then return nil,"Invalid name." end
            return value:gsub("%s+"," "):match("^%s*(.-)%s*$")
        end}}
    local wire={}
    function wire.Enable(peer,callback) state.enabled,state.peer,state.receive=true,peer,callback;return true end
    function wire.EnableBackground(callback) state.enabled,state.peer,state.receive=true,nil,callback;return true end
    function wire.IsEnabled() return state.enabled==true end
    function wire.Disable() state.enabled=false;state.peer,state.receive=nil,nil;return true end
    function wire.CanQueue() if state.full then return nil,"Queue is full." end;return true end
    function wire.Send(actions)
        if state.beforeSend then state.beforeSend(actions) end
        if state.sendFailure then return nil,"Send failed." end
        for _,action in ipairs(actions) do state.queue[#state.queue+1]=copy(action) end
        return true
    end
    function wire.GetStatus() return "Synthetic transport" end
    api.SharedWire=wire
    for _,file in ipairs({"shared_codec.lua","shared.lua","shared_payments.lua","shared_service.lua"}) do
        local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file));setfenv(chunk,env);chunk("IOU",api)
    end
    state.api,state.service=api,api.SharedService
    assert(state.service.Initialize());assert(state.service.EnableBackground())
    return state
end
local function proposal(state,id,sender,item)
    sender=sender or "Amber Stone"
    local E=state.api.Shared
    local terms={protocol=item and 3 or 1,kind=item and "ITEM_OBLIGATION" or "GOLD_OBLIGATION",
        proposer=sender,recipient=state.name,debtor=state.name,creditor=sender,
        amountCopper=item and 20 or 10000,dueUTC=0,note="Synthetic invitation"}
    if item then terms.itemKey,terms.itemName="item:2589","Linen Cloth" end
    local store,actions=E.Propose(assert(E.New(sender)),terms,"ag-"..id,id,state.stamp)
    assert(store,actions);return store,actions[1].message,terms
end
local function deliver(state,message,sender)
    return state.receive(sender or "Amber Stone",copy(message))
end

test("background invitation spam cannot consume permanent Shared history",function()
    local state=client();local before=copy(state.service.GetStore())
    for i=1,80 do
        local _,message=proposal(state,"spam-"..i,"Peer "..i)
        deliver(state,message,"Peer "..i)
    end
    equal(#state.service.List(),16);equal(count(state.service.GetStore().offers),0)
    assert(same(before,state.service.GetStore()));equal(#state.queue,0)
    local view=state.service.GetOverview();equal(#view.offers,16);equal(count(view.balances),0)
end)

test("background invitations support twelve-material bundles and bound each sender",function()
    local state=client()
    for i=1,13 do local _,message=proposal(state,"peer-"..i);deliver(state,message) end
    equal(#state.service.List(),12);assert(not state.service.GetOffer("peer-13"))
    equal(count(state.service.GetStore().offers),0)
end)

test("background duplicates keep one request and do not extend its five minute lifetime",function()
    local state=client();local _,message=proposal(state,"duplicate")
    assert(deliver(state,message));local before=state.service.GetOffer("duplicate")
    state.clock=state.clock+299;state.stamp=state.stamp+299
    assert(deliver(state,message));equal(#state.service.List(),1)
    assert(same(before,state.service.GetOffer("duplicate")))
    state.clock=state.clock+2;state.stamp=state.stamp+2
    equal(#state.service.List(),0);assert(not state.service.GetOffer("duplicate"))
    rejected(function() return state.service.Accept("duplicate") end)
    equal(count(state.service.GetStore().offers),0)
end)

test("background conflicting identifiers cannot replace the reviewed terms",function()
    local state=client();local _,message=proposal(state,"conflict")
    assert(deliver(state,message));local before=state.service.GetOffer("conflict")
    local terms=assert(state.api.SharedCodec.ParseTerms(message.terms));terms.note="Different terms"
    local other=copy(message);other.terms=assert(state.api.SharedCodec.CanonicalTerms(terms))
    rejected(function() return deliver(state,other) end)
    assert(same(before,state.service.GetOffer("conflict")))
    local _,otherPeer=proposal(state,"conflict","Cedar Grove")
    rejected(function() return deliver(state,otherPeer,"Cedar Grove") end)
    assert(same(before,state.service.GetOffer("conflict")));equal(count(state.service.GetStore().offers),0)
end)

test("background Accept saves exact original terms and explicit consent before queueing",function()
    local state=client();local _,message=proposal(state,"accept-item",nil,true)
    assert(deliver(state,message));equal(count(state.service.GetStore().offers),0)
    state.beforeSend=function(actions)
        local stored=assert(state.service.GetStore().offers["accept-item"])
        equal(stored.terms,message.terms);equal(stored.state,"ACCEPT_PENDING");equal(stored.consent,"ACCEPT")
        equal(actions[1].message.kind,"ACCEPT")
    end
    local offer=assert(state.service.Accept("accept-item"))
    equal(offer.consent,"ACCEPT");equal(#state.service.List(),1);equal(count(state.service.GetStore().offers),1)
    local snapshot=state.service.GetOffer("accept-item");snapshot.terms="changed detached preview"
    equal(state.service.GetOffer("accept-item").terms,message.terms)
end)

test("background Accept queue preflight failure leaves an undecided transient request",function()
    local state=client();local _,message=proposal(state,"full")
    assert(deliver(state,message));state.full=true
    rejected(function() return state.service.Accept("full") end)
    equal(count(state.service.GetStore().offers),0)
    equal(state.service.GetOffer("full").consent,"NONE");equal(#state.queue,0)
    state.full=false;assert(state.service.Accept("full"));equal(count(state.service.GetStore().offers),1)
end)

test("background Accept retains saved consent when enqueue unexpectedly fails",function()
    local state=client();local _,message=proposal(state,"enqueue")
    assert(deliver(state,message));state.sendFailure=true
    local offer,err,saved=state.service.Accept("enqueue")
    assert(not offer and type(err)=="string" and saved)
    equal(saved.state,"ACCEPT_PENDING");equal(count(state.service.GetStore().offers),1)
    equal(#state.service.List(),1)
    state.sendFailure=false;assert(state.service.Retry("enqueue"))
    equal(state.queue[1].message.kind,"ACCEPT")
end)

test("background Decline and its exact outcome remain transient",function()
    local state=client();local remote,message=proposal(state,"decline")
    assert(deliver(state,message));assert(state.service.Decline("decline"))
    local preview=state.service.GetOffer("decline")
    equal(preview.state,"DECLINE_PENDING");equal(preview.consent,"DECLINE")
    equal(count(state.service.GetStore().offers),0)
    local response=assert(state.queue[1]);equal(response.message.kind,"DECLINE")
    local updated,actions=state.api.Shared.Receive(remote,state.name,response.message,state.stamp)
    assert(updated,actions);equal(updated.offers.decline.state,"DECLINED")
    assert(deliver(state,actions[1].message))
    equal(state.service.GetOffer("decline").state,"DECLINED")
    equal(count(state.service.GetStore().offers),0)
    rejected(function() return state.service.Accept("decline") end)
end)

test("background withdrawn invitations cannot later be accepted",function()
    local state=client();local remote,message=proposal(state,"withdraw")
    assert(deliver(state,message))
    local updated,actions=state.api.Shared.Withdraw(remote,"withdraw",state.stamp)
    assert(updated,actions);assert(deliver(state,actions[1].message))
    equal(state.service.GetOffer("withdraw").state,"WITHDRAWN")
    rejected(function() return state.service.Accept("withdraw") end)
    equal(count(state.service.GetStore().offers),0)
end)

test("manual peer mode retains its existing persistent incoming proposal behavior",function()
    local state=client();assert(state.service.Disable());assert(state.service.Enable("Amber Stone"))
    local _,message=proposal(state,"manual")
    assert(deliver(state,message))
    equal(count(state.service.GetStore().offers),1)
    equal(state.service.GetOffer("manual").state,"OFFER_RECEIVED")
    equal(state.service.GetOffer("manual").consent,"NONE")
end)

test("background invitations disappear on disconnect without touching saved history",function()
    local state=client();local _,message=proposal(state,"disconnect")
    assert(deliver(state,message));local before=state.service.GetStore()
    assert(state.service.Disable());equal(#state.service.List(),0)
    assert(same(before,state.service.GetStore()))
end)

test("unknown financial event proposals never enter the transient inbox or permanent store",function()
    local state=client();local E=state.api.Shared
    local a,message=proposal(state,"unknown-parent",nil,true)
    local b=assert(E.Receive(assert(E.New(state.name)),"Amber Stone",message,state.stamp))
    local actions
    b,actions=E.Accept(b,"unknown-parent",state.stamp);assert(b,actions)
    a,actions=E.Receive(a,state.name,actions[1].message,state.stamp);assert(a,actions)
    b,actions=E.Receive(b,"Amber Stone",actions[1].message,state.stamp);assert(b,actions)
    a=assert(E.Receive(a,state.name,actions[1].message,state.stamp))
    local terms=assert(state.api.SharedPayments.BuildPayment(a,"unknown-parent",3,"Synthetic repayment",{}))
    a,actions=E.Propose(a,terms,"ag-unknown-payment","unknown-payment",state.stamp);assert(a,actions)
    rejected(function() return deliver(state,actions[1].message) end)
    equal(#state.service.List(),0);equal(count(state.service.GetStore().offers),0)
end)

test("transient TTL expiry never removes a request already accepted into saved history",function()
    local state=client();local _,message=proposal(state,"durable")
    assert(deliver(state,message));assert(state.service.Accept("durable"))
    state.clock=state.clock+1000;state.stamp=state.stamp+1000
    equal(#state.service.List(),1);equal(state.service.GetOffer("durable").state,"ACCEPT_PENDING")
    equal(count(state.service.GetStore().offers),1)
end)

return results
