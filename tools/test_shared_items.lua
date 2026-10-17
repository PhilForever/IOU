-- Item shared agreements use the same exact-consent state machine as gold.
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={}; for key,item in pairs(value) do result[key]=copy(item) end; return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function reject(run)
    local value,err=run()
    assert(value==nil or value==false,"unsafe item mutation succeeded")
    assert(type(err)=="string" and #err>0,"missing rejection reason")
end
local function forbidden() error("offline item domain invoked a game API") end
local env=setmetatable({CreateFrame=forbidden,SendChatMessage=forbidden,time=forbidden,
    C_ChatInfo={SendAddonMessageLogged=forbidden},IOUDB={sentinel=true}},{__index=_G})
env._G=env
local ns={}
for _,file in ipairs({"shared_codec.lua","shared.lua","shared_payments.lua","shared_view.lua","shared_backup.lua"}) do
    local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file))
    setfenv(chunk,env); chunk("IOU",ns)
end
local C,S,P,V,B=ns.SharedCodec,ns.Shared,ns.SharedPayments,ns.SharedView,ns.SharedBackup
local function terms(changes)
    local value={protocol=3,kind="ITEM_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor="Birch Vale",creditor="Amber Stone",amountCopper=20,dueUTC=0,
        note="Bjørn blåbær",itemKey="item:2589",itemName="Linen Cloth"}
    for key,item in pairs(changes or {}) do value[key]=item end
    return value
end
local function sim(settings)
    settings=settings or {}
    local a={name="Amber Stone",store=assert(S.New("Amber Stone")),queue={}}
    local b={name="Birch Vale",store=assert(S.New("Birch Vale")),queue={}}
    local w={a=a,b=b,stamp=100,serial=0,parent="parent-offer"}
    function w.apply(actor,method,...)
        w.stamp=w.stamp+1
        local args={...}; args[#args+1]=w.stamp
        local updated,actions=method(actor.store,unpack(args))
        assert(updated,actions); assert(P.Validate(updated))
        actor.store=updated
        for _,action in ipairs(actions) do actor.queue[#actor.queue+1]=copy(action.message) end
        return updated,actions
    end
    function w.move(from,to)
        local message=assert(table.remove(from.queue,1))
        w.apply(to,S.Receive,from.name,message)
        return message
    end
    function w.offer(value)
        w.serial=w.serial+1
        local id="event-offer-"..w.serial
        w.apply(a,S.Propose,value,"event-agreement-"..w.serial,id); w.move(a,b)
        return id
    end
    function w.finish(id,stopAck)
        w.apply(b,S.Accept,id); w.move(b,a); w.move(a,b)
        if not stopAck then w.move(b,a) end
    end
    function w.payment(amount,note)
        return w.offer(assert(P.BuildPayment(a.store,w.parent,amount,note)))
    end
    w.apply(a,S.Propose,terms(settings.terms),"parent-agreement",w.parent)
    if settings.stop=="sent" then return w end
    w.move(a,b)
    if settings.stop=="received" then return w end
    w.finish(w.parent,settings.stop=="parentAck")
    return w
end
local function event(parent,changes,rows)
    rows=rows or {}
    local value={protocol=4,kind="ITEM_PAYMENT",proposer=parent.proposer,recipient=parent.recipient,
        debtor=parent.debtor,creditor=parent.creditor,amountCopper=3,dueUTC=0,note="",
        parentAgreementId="parent-agreement",parentOfferId="parent-offer",parentCommitId="parent-commit",
        parentTerms=assert(C.CanonicalTerms(parent)),baseRevision=#rows,
        baseChain=assert(C.CanonicalChain(rows)),reversesId="",itemKey=parent.itemKey,itemName=parent.itemName}
    for key,item in pairs(changes or {}) do value[key]=item end
    return value
end
local function row(kind,id,amount,reverses)
    return {kind=kind,agreementId="ag-"..id,offerId="of-"..id,commitId="cm-"..id,
        amountCopper=amount,note="test",reversesId=reverses or ""}
end

test("item codec canonicalizes native links while preserving all populated variant fields",function()
    local key,id=C.CanonicalItem("|cffffffff|Hitem:02589::0:0:0:0:0:0:0|h[Linen Cloth]|h|r")
    assert(key=="item:2589" and id==2589)
    assert(C.CanonicalItem("item:2589:0:-14")=="item:2589:0:-14")
    assert(C.CanonicalItem("item:2589:0:0:0:0:0:0:42:60")~="item:2589")
    for _,value in ipairs({"2589","item:0","item:2589:1.5","item:2589:abc","item:2589|bad","item:2147483648","item:2589:4294967296"}) do
        assert(C.CanonicalItem(value)==nil)
    end
end)

test("item obligations have canonical protocol 3 bytes and detached asset metadata",function()
    local original=terms()
    local bytes=assert(C.CanonicalTerms(original)); assert(bytes:sub(1,7)=="IOUST3:")
    assert(same(assert(C.ParseTerms(bytes)),original))
    assert(C.IsObligation(original) and not C.IsPayment(original) and not C.IsCorrection(original))
    local asset=C.Asset(original)
    assert(asset.kind=="item" and asset.amount==20 and asset.label=="Linen Cloth" and asset.itemID==2589)
    asset.label="changed"; assert(original.itemName=="Linen Cloth")
end)

test("item schema rejects loose identity names noninteger amounts and unknown fields",function()
    for _,changes in ipairs({{protocol=1},{kind="GOLD_OBLIGATION"},{itemKey="item:02589"},{itemKey="item:2589:0"},
        {itemKey="|Hitem:2589|h[Linen Cloth]|h"},{itemName=""},{itemName="  "},{itemName="Linen|Cloth"},
        {itemName="Linen\nCloth"},{amountCopper=0},{amountCopper=1.5},{amountCopper=1000000000},
        {quantity=20},{proposer="Amber"..string.char(255)},{recipient="Amber Stone"}}) do
        reject(function() return C.CanonicalTerms(terms(changes)) end)
    end
    assert(C.CanonicalTerms(terms({amountCopper=999999999})))
end)

test("old gold obligation wire bytes remain exactly unchanged",function()
    local gold={protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor="Birch Vale",creditor="Amber Stone",amountCopper=10000,dueUTC=0,note=""}
    local function token(value) value=tostring(value); return #value..":"..value.."," end
    local expected="IOUST1:"..token(1)..token("GOLD_OBLIGATION")..token("Amber Stone")..token("Birch Vale")
        ..token("Birch Vale")..token("Amber Stone")..token(10000)..token(0)..token("")
    assert(C.CanonicalTerms(gold)==expected and C.CanonicalTerms(C.ParseTerms(expected))==expected)
    assert(C.Asset(gold).kind=="money" and C.Asset(gold).amount==10000)
    assert(C.CanonicalChain({})=="IOUSC1:1:0,")
end)

test("item event codec binds canonical parent identity name participants and kind",function()
    local value=event(terms())
    local bytes=assert(C.CanonicalTerms(value)); assert(bytes:sub(1,7)=="IOUST4:")
    assert(same(C.ParseTerms(bytes),value) and C.IsPayment(value))
    for _,changes in ipairs({{protocol=2},{kind="GOLD_PAYMENT"},{itemKey="item:2592"},{itemName="Wool Cloth"},
        {debtor="Amber Stone",creditor="Birch Vale"},{dueUTC=1},{baseRevision=1},{amountCopper=21}}) do
        reject(function() return C.CanonicalTerms(event(terms(),changes)) end)
    end
end)

test("item baselines reject gold rows mixed assets and excess quantity",function()
    reject(function() return C.CanonicalTerms(event(terms(),{}, {row("GOLD_PAYMENT","gold",1)})) end)
    reject(function() return C.CanonicalChain({row("ITEM_PAYMENT","item",1),row("GOLD_PAYMENT","gold",1)}) end)
    reject(function() return C.CanonicalTerms(event(terms(),{}, {row("ITEM_PAYMENT","large",21)})) end)
    local paid=row("ITEM_PAYMENT","first",5)
    assert(C.CanonicalTerms(event(terms(),{amountCopper=15},{paid})))
    reject(function() return C.CanonicalTerms(event(terms(),{amountCopper=16},{paid})) end)
end)

test("item two-player acceptance preserves exact item terms in both debt directions",function()
    for _,changes in ipairs({{}, {debtor="Amber Stone",creditor="Birch Vale"}}) do
        local w=sim({terms=changes})
        for _,peer in ipairs({w.a,w.b}) do
            local view=assert(P.View(peer.store,w.parent))
            assert(view.kind=="item" and view.itemID==2589 and view.remainingAmount==20 and view.originalAmount==20)
            assert(view.confirmed and view.remainingCopper==20 and view.asset.label=="Linen Cloth")
            assert(S.Validate(peer.store) and P.Validate(peer.store))
        end
    end
end)

test("item repayments remain pending until commit and peer receipt then support partial and full quantities",function()
    local w=sim(); local a,b=w.a,w.b
    local first=w.payment(7,"partial")
    assert(P.View(a.store,w.parent).remainingAmount==20 and P.View(b.store,w.parent).remainingAmount==20)
    w.finish(first,true)
    assert(P.View(a.store,w.parent).remainingAmount==20 and P.View(a.store,w.parent).awaitingAck)
    assert(P.View(b.store,w.parent).remainingAmount==13)
    reject(function() return P.BuildPayment(a.store,w.parent,1,"") end)
    w.move(b,a)
    assert(P.View(a.store,w.parent).remainingAmount==13)
    local last=w.payment(13,""); w.finish(last)
    assert(P.View(a.store,w.parent).remainingAmount==0 and P.View(b.store,w.parent).state=="SETTLED")
    reject(function() return P.BuildPayment(a.store,w.parent,1,"") end)
end)

test("item correction fully reverses one consented payment and cannot reverse it twice",function()
    local w=sim(); local paid=w.payment(7,"partial"); w.finish(paid)
    local value=assert(P.BuildCorrection(w.a.store,w.parent,paid,""))
    assert(value.protocol==4 and value.kind=="ITEM_CORRECTION" and value.amountCopper==7 and value.note=="No reason provided")
    local fix=w.offer(value); w.finish(fix)
    for _,actor in ipairs({w.a,w.b}) do
        local view=P.View(actor.store,w.parent)
        assert(view.remainingAmount==20 and view.events[1].reversed and view.events[2].effective)
        reject(function() return P.BuildCorrection(actor.store,w.parent,paid,"Again") end)
    end
end)

test("item event duplication is idempotent across exact retained messages",function()
    local w=sim(); local paid=w.payment(4,""); w.finish(paid)
    local before=copy(w.a.store)
    local message=copy(w.b.store.offers[paid].messages.ack)
    w.apply(w.a,S.Receive,w.b.name,message)
    assert(same(w.a.store,before) and P.View(w.a.store,w.parent).remainingAmount==16)
end)

test("item conflicting exact terms and stale event baselines cannot enter a financial chain",function()
    local w=sim(); local stale=assert(P.BuildPayment(w.a.store,w.parent,2,"stale"))
    local paid=w.payment(4,""); w.finish(paid)
    local candidate=assert(S.Propose(w.a.store,stale,"stale-ag","stale-of",w.stamp+1))
    reject(function() return P.Validate(candidate) end)
    local broken=copy(w.a.store)
    local value=C.ParseTerms(broken.offers[paid].terms); value.itemKey="item:2592"
    reject(function() return C.CanonicalTerms(value) end)
end)

test("item backup roundtrip retains exact consent graph and quantities without changing armor version",function()
    local w=sim(); local paid=w.payment(6,""); w.finish(paid)
    local snapshot={version=1,character="Amber Stone-Realm",owner=w.a.name,exportedAt=1000,
        entry={version=1,store=w.a.store,closedPaused={},nonce="sample",counter=0}}
    local bytes=assert(B.Encode(snapshot)); assert(bytes:sub(1,6)=="IOUS1:")
    local decoded=assert(B.Decode(bytes))
    assert(same(decoded,snapshot) and S.Validate(decoded.entry.store) and P.Validate(decoded.entry.store))
    assert(P.View(decoded.entry.store,w.parent).remainingAmount==14)
    decoded.entry.store.offers[paid].terms=decoded.entry.store.offers[w.parent].terms
    reject(function() return S.Validate(decoded.entry.store) end)
end)

test("item projection searches material name and separates current agreements from delivery history",function()
    local w=sim(); local paid=w.payment(6,""); w.finish(paid)
    local offers={}; for _,offer in pairs(w.a.store.offers) do offers[#offers+1]=copy(offer) end
    local overview={localName=w.a.name,offers=offers,balances=assert(P.Views(w.a.store))}
    local projection=assert(V.Build(overview,"agreements","linen cloth"))
    assert(projection.filteredTotal==1 and projection.rows[1].remainingAmount==14)
    assert(projection.rows[1].asset.kind=="item" and projection.rows[1].itemID==2589)
    local history=assert(V.Build(overview,"history","linen"))
    assert(history.filteredTotal==1 and history.rows[1].kind=="ITEM_PAYMENT")
end)

test("paused outgoing item proposal resumes exact same IDs without creating consent",function()
    local w=sim({stop="sent"}); local a=w.a
    a.queue={}; local before=copy(a.store.offers[w.parent])
    w.apply(a,S.Pause)
    local _,actions=w.apply(a,S.Resume,w.parent)
    local offer=a.store.offers[w.parent]
    assert(offer.state=="OFFER_OPEN" and offer.pausedFrom==nil and offer.consent=="PROPOSE")
    assert(same(offer.messages,before.messages) and offer.history[#offer.history].kind=="RESUMED")
    assert(#actions==1 and actions[1].message.messageId==before.messages.propose.messageId)
    assert(offer.messages.accept==nil)
    w.move(a,w.b); w.finish(w.parent)
    assert(P.View(a.store,w.parent).confirmed)
end)

test("paused incoming item proposal resumes to review without accepting or sending",function()
    local w=sim({stop="received"}); local b=w.b
    w.apply(b,S.Pause)
    local _,actions=w.apply(b,S.Resume,w.parent)
    assert(b.store.offers[w.parent].state=="OFFER_RECEIVED" and b.store.offers[w.parent].consent=="NONE")
    assert(b.store.offers[w.parent].messages.accept==nil and #actions==0 and b.store.offers[w.parent].delivery=="NONE")
end)

test("paused accepted item proposal resumes retained acceptance and converges by replay",function()
    local w=sim({stop="received"}); local b=w.b
    w.apply(b,S.Accept,w.parent); local accept=copy(b.queue[1]); b.queue={}
    w.apply(b,S.Pause); local _,actions=w.apply(b,S.Resume,w.parent)
    assert(b.store.offers[w.parent].state=="ACCEPT_PENDING" and b.store.offers[w.parent].consent=="ACCEPT")
    assert(same(actions[1].message,accept))
    w.move(b,w.a); w.move(w.a,b); w.move(b,w.a)
    assert(P.View(w.a.store,w.parent).confirmed and P.View(b.store,w.parent).confirmed)
end)

test("paused declined item proposal resumes retained decline without restoring acceptance",function()
    local w=sim({stop="received"}); local b=w.b
    w.apply(b,S.Decline,w.parent); local decline=copy(b.queue[1]); b.queue={}
    w.apply(b,S.Pause); local _,actions=w.apply(b,S.Resume,w.parent)
    assert(b.store.offers[w.parent].state=="DECLINE_PENDING" and b.store.offers[w.parent].consent=="DECLINE")
    assert(same(actions[1].message,decline) and not b.store.offers[w.parent].messages.accept)
end)

test("resume rejects missing consent invalid paused origin terminal state and time regression atomically",function()
    local w=sim({stop="received"}); local b=w.b
    reject(function() return S.Resume(b.store,w.parent,w.stamp+1) end)
    w.apply(b,S.Accept,w.parent); w.apply(b,S.Pause)
    local before=copy(b.store)
    reject(function() return S.Resume(b.store,w.parent,0) end)
    assert(same(b.store,before))
    for _,mutate in ipairs({function(o) o.messages.accept=nil end,function(o) o.pausedFrom="COMMITTED" end,
        function(o) o.consent="NONE" end}) do
        local corrupt=copy(before); mutate(corrupt.offers[w.parent])
        reject(function() return S.Resume(corrupt,w.parent,w.stamp+1) end)
    end
end)

test("resume history capacity blocks before mutating retained consent",function()
    local w=sim({stop="sent"}); w.apply(w.a,S.Pause)
    local store=copy(w.a.store); local offer=store.offers[w.parent]
    while #offer.history<16 do offer.history[#offer.history+1]={kind="PAUSED",at=offer.updatedAt} end
    assert(S.Validate(store))
    local before=copy(store)
    reject(function() return S.Resume(store,w.parent,w.stamp+1) end)
    assert(same(store,before))
end)

test("item handshake logical byte limits remain bounded before proposals can be committed",function()
    local parent=terms({itemName=string.rep("x",256),note=string.rep("n",512)})
    local value=event(parent,{note=string.rep("p",512)})
    local wire=assert(C.CanonicalTerms(value))
    local message={version=1,kind="COMMIT",messageId=string.rep("m",64),agreementId=string.rep("a",64),
        offerId=string.rep("o",64),revision=1,terms=wire,acceptanceId=string.rep("c",64),commitId=string.rep("d",64)}
    assert(#assert(C.Encode(message))<=C.MAX_BYTES)
    assert(C.ParseTerms(wire)==nil or #wire<=C.MAX_BYTES)
    reject(function() return C.ParseTerms(wire.."trailing") end)
    reject(function() return C.ParseTerms(wire:sub(1,-2)) end)
end)

test("resuming a legacy gold proposal preserves its original canonical bytes and IDs",function()
    local original=terms(); original.protocol,original.kind,original.itemKey,original.itemName=1,"GOLD_OBLIGATION",nil,nil
    local store,actions=assert(S.Propose(assert(S.New("Amber Stone")),original,"gold-ag","gold-of",100))
    local before=copy(store.offers["gold-of"])
    store=assert(S.Pause(store,101)); store,actions=S.Resume(store,"gold-of",102)
    assert(store and S.Validate(store) and same(store.offers["gold-of"].messages,before.messages))
    assert(actions[1].message.terms==before.terms and actions[1].message.messageId==before.messages.propose.messageId)
end)

return results
