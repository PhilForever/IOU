-- Recovery uses the real backup codec, consent engine, financial domain and
-- persistence service. The transport stub records logical sends without a
-- native client, and all people/storage keys below are synthetic fixtures.
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
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function equal(actual,expected)
    assert(actual==expected,"expected "..tostring(expected)..", got "..tostring(actual))
end
local function rejected(call)
    local value,err=call()
    assert(value==nil or value==false,"invalid recovery action succeeded")
    assert(type(err)=="string" and #err>0,"rejection needs an explanation")
    return err
end
local function peer(name,key,saved,stamp)
    local ctx={name=name or "Amber Stone",key=key or "Amber-LegacyRealm",stamp=stamp or 1000,
        queue={},enabled=false,sendCount=0,enableCount=0}
    if saved==nil then
        saved={version=1,characters={[ctx.key]={marker="personal agreements"},Other={marker="another character"}},
            settings={marker="display preferences"},recovery={marker="personal previous ledger"},migrations={marker=1}}
    end
    local env=setmetatable({IOUDB=saved,time=function() return ctx.stamp end},{__index=_G})
    env._G=env
    local ns={Initialize=function() return true end,Character=function() return ctx.key end,
        Transport={GetLocalName=function() return ctx.name end,
            CanonicalName=function(value)
                if type(value)~="string" or #value>96 or value=="" or value:find("[%z\001-\031\127|]") then
                    return nil,"Invalid full name."
                end
                return value:gsub("%s+"," "):match("^%s*(.-)%s*$")
            end}}
    local wire={}
    function wire.Enable(other,callback)
        ctx.enabled,ctx.other,ctx.receive=true,other,callback
        ctx.enableCount=ctx.enableCount+1; return true
    end
    function wire.Disable()
        ctx.enabled,ctx.other,ctx.receive,ctx.queue=false,nil,nil,{}
        if ns.OnSharedWireChanged then ns.OnSharedWireChanged() end
    end
    function wire.IsEnabled() return ctx.enabled end
    function wire.GetStatus() return "Recovery transport fixture." end
    function wire.CanQueue()
        if not ctx.enabled then return nil,"Shared transport is disabled." end
        return true
    end
    function wire.Send(actions)
        ctx.sendCount=ctx.sendCount+1
        for _,action in ipairs(actions) do ctx.queue[#ctx.queue+1]=copy(action) end
        return true
    end
    ns.SharedWire=wire
    for _,file in ipairs({"shared_codec.lua","shared.lua","shared_payments.lua","shared_backup.lua","shared_service.lua"}) do
        local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file))
        setfenv(chunk,env); chunk("IOU",ns)
    end
    ctx.db,ctx.env,ctx.ns,ctx.service=saved,env,ns,ns.SharedService
    return ctx
end
local function wrapper(ctx) return assert(ctx.db.sharedByCharacter[ctx.key]) end
local function personal(ctx)
    return {characters=copy(ctx.db.characters),settings=copy(ctx.db.settings),
        recovery=copy(ctx.db.recovery),migrations=copy(ctx.db.migrations),version=ctx.db.version}
end
local function deliver(from,to)
    local action=assert(table.remove(from.queue,1),"no queued logical message")
    equal(action.target,to.name)
    return assert(to.receive,"receiver is disconnected")(from.name,action.message)
end
local function finish(a,b,id)
    assert(deliver(a,b)); assert(b.service.Accept(id))
    assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    equal(a.service.GetOffer(id).delivery,"PEER_RECEIPT_OBSERVED")
    equal(b.service.GetOffer(id).state,"COMMITTED")
end
local function pair(aDB,bDB)
    local a=peer("Amber Stone","Amber-LegacyRealm",aDB)
    local b=peer("Birch Vale","Birch-OtherRealm",bDB)
    assert(a.service.Enable(b.name)); assert(b.service.Enable(a.name))
    return a,b
end
local function obligation(a,b,amount)
    local offer=assert(a.service.Propose({peer=b.name,direction="owe",amountCopper=amount or 10000,note="",dueUTC=0}))
    finish(a,b,offer.offerId)
    return offer.offerId
end
local function agreed()
    local a,b=pair(); local id=obligation(a,b); return a,b,id
end
local function text(ctx,entry,stamp)
    return assert(ctx.ns.SharedBackup.Encode({version=1,character=ctx.key,owner=ctx.name,
        exportedAt=stamp or ctx.stamp,entry=entry or wrapper(ctx)}))
end
local function stage(ctx,backup)
    local preview=assert(ctx.service.PreviewBackup(backup))
    return assert(ctx.service.StageRecovery(backup,preview.currentFingerprint)),preview
end
local function restore(ctx,backup)
    local review=stage(ctx,backup)
    assert(review.canRestore,review.problem)
    assert(ctx.service.ResolveRecovery("restore",review.token))
    return review
end

test("Shared backup round trips exact evidence and preview is detached, silent and read-only",function()
    local a,b,id=agreed()
    local before=copy(a.db); local sends,enabled=a.sendCount,a.enableCount
    local backup=assert(a.service.ExportBackup())
    equal(backup:sub(1,6),"IOUS1:")
    local decoded=assert(a.ns.SharedBackup.Decode(backup))
    equal(decoded.owner,a.name); equal(decoded.character,a.key)
    assert(same(decoded.entry,wrapper(a)))
    equal(assert(a.ns.SharedBackup.Encode(decoded)),backup)
    local preview=assert(a.service.PreviewBackup(backup))
    equal(preview.identical,1); equal(preview.missing,0); equal(preview.different,0)
    assert(preview.canRestore and preview.currentFingerprint,preview.problem)
    preview.rows[1].current.terms="modified detached preview"
    assert(a.service.GetOffer(id).terms~="modified detached preview")
    assert(same(before,a.db)); equal(a.sendCount,sends); equal(a.enableCount,enabled)
end)

test("Shared restoration recovers missing agreed payments and corrections without touching personal data or sending",function()
    local a,b,id=agreed()
    local payment=assert(a.service.ProposePayment(id,4000,"Synthetic partial payment")); finish(a,b,payment.offerId)
    local correction=assert(a.service.ProposeCorrection(id,payment.offerId,"")); finish(a,b,correction.offerId)
    local settlement=assert(a.service.ProposePayment(id,10000,"")); finish(a,b,settlement.offerId)
    equal(a.service.GetBalance(id).remainingCopper,0)
    local backup=assert(a.service.ExportBackup())
    local target=peer(a.name,a.key)
    assert(target.service.Initialize())
    local originalPersonal=personal(target); local oldNonce=wrapper(target).nonce
    local review,preview=stage(target,backup)
    equal(preview.missing,4); assert(review.canRestore)
    equal(#target.service.List(),0); assert(target.service.IsRecoveryPending())
    assert(target.service.ResolveRecovery("restore",review.token))
    equal(#target.service.List(),4); equal(target.service.GetBalance(id).remainingCopper,0)
    equal(wrapper(target).nonce,oldNonce)
    assert(same(target.service.GetOffer(correction.offerId),a.service.GetOffer(correction.offerId)))
    equal(assert(target.service.ExportRecovery("backup")),backup)
    equal(assert(target.ns.SharedBackup.Decode(target.service.ExportRecovery("before"))).exportedAt,0)
    assert(same(originalPersonal,personal(target))); equal(target.sendCount,0); equal(target.enableCount,0)
    assert(not target.service.IsEnabled() and not target.service.IsRecoveryPending())
    local retained=copy(wrapper(target))
    local repeated=restore(target,backup)
    equal(repeated.preview.identical,4); equal(repeated.preview.missing,0)
    assert(same(retained,wrapper(target))); equal(target.service.GetBalance(id).remainingCopper,0)
    equal(target.sendCount,0)
end)

test("Staged recovery disconnects and gates committed retries and new decisions across reload",function()
    local a,b,id=agreed()
    local backup=assert(a.service.ExportBackup())
    local oldReceiver=a.receive; local oldCommit=copy(b.service.GetOffer(id).messages.ack)
    local sends=a.sendCount; local protected=personal(a)
    local review=stage(a,backup)
    assert(not a.service.IsEnabled() and a.service.IsRecoveryPending())
    equal(#a.queue,0)
    rejected(function() return a.service.Enable(b.name) end)
    rejected(function() return a.service.Retry(id) end)
    rejected(function() return a.service.ProposePayment(id,1,"") end)
    rejected(function() return oldReceiver(b.name,oldCommit) end)
    equal(a.sendCount,sends); assert(same(protected,personal(a)))
    local restarted=peer(a.name,a.key,copy(a.db),1001)
    assert(restarted.service.Initialize()); assert(restarted.service.IsRecoveryPending())
    rejected(function() return restarted.service.Enable(b.name) end)
    rejected(function() return restarted.service.Retry(id) end)
    equal(restarted.sendCount,0); equal(restarted.enableCount,0)
    local current=assert(restarted.service.GetRecovery())
    assert(same(current.token,review.token)); assert(restarted.service.ResolveRecovery("keep",current.token))
    assert(not restarted.service.IsRecoveryPending() and not restarted.service.IsEnabled())
    equal(restarted.sendCount,0); assert(restarted.service.Enable(b.name)); equal(restarted.sendCount,0)
end)

test("Imported unfinished consent pauses on adoption and cannot be retried or accepted automatically",function()
    local a,b=pair()
    local offer=assert(a.service.Propose({peer=b.name,direction="owed",amountCopper=10000,note=""}))
    assert(deliver(a,b)); assert(b.service.Accept(offer.offerId))
    local backup=assert(b.service.ExportBackup())
    local target=peer(b.name,b.key)
    assert(target.service.Initialize()); restore(target,backup)
    local kept=target.service.GetOffer(offer.offerId)
    equal(kept.state,"PAUSED"); equal(kept.pausedFrom,"ACCEPT_PENDING"); equal(kept.consent,"ACCEPT")
    equal(kept.delivery,"RETRY_PAUSED"); equal(target.sendCount,0)
    assert(target.service.Enable(a.name))
    rejected(function() return target.service.Accept(offer.offerId) end)
    rejected(function() return target.service.Retry(offer.offerId) end)
    equal(target.sendCount,0)
end)

test("A later backup cannot reconstruct missing acceptance under an existing locally unaccepted offer",function()
    local a,b=pair()
    local offer=assert(a.service.Propose({peer=b.name,direction="owe",amountCopper=10000,note=""}))
    assert(deliver(a,b))
    local beforeAcceptance=copy(b.db)
    assert(b.service.Accept(offer.offerId)); assert(deliver(b,a)); assert(deliver(a,b)); assert(deliver(b,a))
    local backup=assert(b.service.ExportBackup())
    local target=peer(b.name,b.key,beforeAcceptance)
    assert(target.service.Initialize())
    local retained=copy(target.service.GetOffer(offer.offerId))
    equal(retained.state,"PAUSED"); equal(retained.consent,"NONE")
    local review,preview=stage(target,backup)
    equal(preview.different,1); equal(preview.missing,0)
    assert(review.canRestore); assert(target.service.ResolveRecovery("restore",review.token))
    assert(same(target.service.GetOffer(offer.offerId),retained))
    assert(not target.service.GetBalance(offer.offerId).confirmed)
    equal(target.sendCount,0)
end)

test("The recovery gate blocks paused-offer closure and every explicit consent mutation",function()
    local a,b=pair()
    local offer=assert(a.service.Propose({peer=b.name,direction="owe",amountCopper=10000,note=""}))
    local backup=assert(a.service.ExportBackup())
    local review=stage(a,backup)
    equal(a.service.GetOffer(offer.offerId).state,"PAUSED")
    local before=copy(a.db); local sends=a.sendCount
    for _,call in ipairs({
        function() return a.service.Propose({peer=b.name,direction="owe",amountCopper=1,note=""}) end,
        function() return a.service.Accept(offer.offerId) end,
        function() return a.service.Decline(offer.offerId) end,
        function() return a.service.Withdraw(offer.offerId) end,
        function() return a.service.ClosePaused(offer.offerId,"") end,
        function() return a.service.StageRecovery(backup,review.preview.currentFingerprint) end,
    }) do rejected(call) end
    assert(same(before,a.db)); equal(a.sendCount,sends)
    assert(a.service.ResolveRecovery("keep",review.token))
    equal(a.service.GetOffer(offer.offerId).state,"PAUSED")
    equal(#a.queue,0); equal(a.sendCount,sends)
end)

test("Shared preview fingerprints reject stale current state without disconnecting or staging",function()
    local a,b=agreed()
    local backup=assert(a.service.ExportBackup()); local preview=assert(a.service.PreviewBackup(backup))
    assert(a.service.Propose({peer=b.name,direction="owed",amountCopper=1,note="New local proposal"}))
    local before=copy(a.db); local sends=a.sendCount
    rejected(function() return a.service.StageRecovery(backup,preview.currentFingerprint) end)
    assert(same(before,a.db)); assert(a.service.IsEnabled()); assert(not a.service.IsRecoveryPending())
    equal(a.sendCount,sends)
end)

test("Shared recovery tokens and changed staged baselines reject restoration while Keep remains available",function()
    local a,b,id=agreed(); local backup=assert(a.service.ExportBackup())
    local review=stage(a,backup); local wrong=copy(review.token); wrong.at=wrong.at+1
    local before=copy(a.db)
    rejected(function() return a.service.ResolveRecovery("restore",wrong) end)
    rejected(function() return a.service.ResolveRecovery("invalid",review.token) end)
    assert(same(before,a.db))
    wrapper(a).counter=wrapper(a).counter+1 -- Valid external change invalidates the frozen baseline.
    local changed=copy(wrapper(a)); local current=assert(a.service.GetRecovery())
    assert(not current.canRestore and current.problem)
    rejected(function() return a.service.ResolveRecovery("restore",review.token) end)
    assert(same(changed,wrapper(a)))
    assert(a.service.ResolveRecovery("keep",current.token))
    assert(same(changed,wrapper(a))); equal(a.service.GetRecovery().status,"KEPT")
    rejected(function() return a.service.ResolveRecovery("restore",current.token) end)
    equal(a.service.GetOffer(id).state,"COMMITTED")
end)

test("Shared restoration retains current-only records and never replaces differing same-ID consent",function()
    local a,b,id=agreed()
    local old=assert(a.service.ExportBackup())
    local currentOnly=obligation(a,b,20000)
    local snapshot=assert(a.ns.SharedBackup.Decode(old))
    snapshot.entry.store.offers[id].delivery="WAITING_FOR_PEER"
    local changed=text(a,snapshot.entry)
    local before=copy(wrapper(a)); local sends=a.sendCount
    local review,preview=stage(a,changed)
    equal(preview.different,1); equal(preview.currentOnly,1); equal(preview.missing,0)
    assert(review.canRestore); assert(a.service.ResolveRecovery("restore",review.token))
    equal(a.service.GetOffer(id).delivery,"PEER_RECEIPT_OBSERVED")
    equal(a.service.GetOffer(currentOnly).state,"COMMITTED")
    assert(same(before,wrapper(a))); equal(a.sendCount,sends)
end)

test("Older Shared backups cannot erase closed-offer tombstones and matching closures can be recovered",function()
    local a,b=pair()
    local offer=assert(a.service.Propose({peer=b.name,direction="owe",amountCopper=10000,note=""}))
    local older=assert(a.service.ExportBackup())
    assert(a.service.Disable())
    local pausedDB=copy(a.db)
    assert(a.service.ClosePaused(offer.offerId,""))
    local closed=copy(wrapper(a).closedPaused[offer.offerId]); local closedBackup=assert(a.service.ExportBackup())
    restore(a,older)
    assert(same(wrapper(a).closedPaused[offer.offerId],closed))
    assert(a.service.GetOffer(offer.offerId).localClosed)
    local target=peer(a.name,a.key,pausedDB)
    assert(target.service.Initialize())
    local review,preview=stage(target,closedBackup)
    equal(preview.closedAdded,1); assert(review.canRestore)
    assert(target.service.ResolveRecovery("restore",review.token))
    assert(same(wrapper(target).closedPaused[offer.offerId],closed)); equal(target.sendCount,0)
end)

test("An imported closure cannot suppress a same-ID paused offer with different local consent evidence",function()
    local a,b=pair()
    local offer=assert(a.service.Propose({peer=b.name,direction="owe",amountCopper=10000,note=""}))
    assert(deliver(a,b))
    local beforeAcceptance=copy(b.db)
    assert(b.service.Disable()); assert(b.service.ClosePaused(offer.offerId,"Reviewed the earlier unaccepted offer"))
    local backup=assert(b.service.ExportBackup())
    local accepted=assert(b.ns.Shared.Accept(beforeAcceptance.sharedByCharacter[b.key].store,offer.offerId,1000))
    beforeAcceptance.sharedByCharacter[b.key].store=accepted
    local target=peer(b.name,b.key,beforeAcceptance)
    assert(target.service.Initialize())
    equal(target.service.GetOffer(offer.offerId).consent,"ACCEPT")
    local retained=copy(target.service.GetOffer(offer.offerId))
    local review,preview=stage(target,backup)
    equal(preview.different,1); equal(preview.closedAdded,0)
    assert(review.canRestore); assert(target.service.ResolveRecovery("restore",review.token))
    assert(same(retained,target.service.GetOffer(offer.offerId)))
    equal(wrapper(target).closedPaused[offer.offerId],nil); equal(target.sendCount,0)
end)

test("Unfinished current originals block parallel same-peer backup agreements until explicitly closed",function()
    local source,other,id=agreed()
    local backup=assert(source.service.ExportBackup())
    for _,pause in ipairs({false,true}) do
        local target=peer(source.name,source.key)
        assert(target.service.Enable(other.name))
        local open=assert(target.service.Propose({peer=other.name,direction="owe",amountCopper=10000,note="Unresolved local offer"}))
        if pause then assert(target.service.Disable()) end
        local review,preview=stage(target,backup)
        equal(preview.missing,1); equal(preview.currentOnly,1)
        assert(not preview.canRestore and preview.problem:find("unfinished",1,true))
        assert(not review.canRestore)
        rejected(function() return target.service.ResolveRecovery("restore",review.token) end)
        equal(target.service.GetOffer(id),nil)
        assert(target.service.ResolveRecovery("keep",review.token))
        assert(target.service.ClosePaused(open.offerId,"Separate uncommitted offer reviewed"))
        local sends=target.sendCount
        restore(target,backup)
        equal(target.service.GetOffer(id).state,"COMMITTED")
        equal(target.service.GetBalance(id).remainingCopper,10000)
        assert(target.service.GetOffer(open.offerId).localClosed)
        equal(target.sendCount,sends); assert(not target.service.IsEnabled())
    end
end)

test("Individually valid divergent payment chains cannot be merged into duplicate financial effects",function()
    local a,b,id=agreed()
    local aBase,bBase=copy(a.db),copy(b.db)
    local left,leftPeer=pair(copy(aBase),copy(bBase))
    wrapper(left).nonce="branch-current"
    local first=assert(left.service.ProposePayment(id,4000,"Current history")); finish(left,leftPeer,first.offerId)
    local right,rightPeer=pair(copy(aBase),copy(bBase))
    wrapper(right).nonce="branch-backup"
    local other=assert(right.service.ProposePayment(id,3000,"Divergent history")); finish(right,rightPeer,other.offerId)
    local backup=assert(right.service.ExportBackup())
    local before=copy(wrapper(left)); local sends=left.sendCount
    local review,preview=stage(left,backup)
    equal(preview.missing,1); assert(not preview.canRestore and preview.problem)
    assert(not review.canRestore)
    rejected(function() return left.service.ResolveRecovery("restore",review.token) end)
    assert(same(before,wrapper(left))); equal(left.service.GetBalance(id).remainingCopper,6000)
    equal(left.service.GetOffer(other.offerId),nil); equal(left.sendCount,sends)
    assert(left.service.ResolveRecovery("keep",review.token)); assert(same(before,wrapper(left)))
end)

test("Shared recovery cannot exceed retained-offer capacity or evict current consent to make room",function()
    local target,other,id=agreed()
    local source=peer(target.name,target.key); assert(source.service.Initialize())
    local entry=copy(wrapper(source))
    local terms={protocol=1,kind="GOLD_OBLIGATION",proposer=source.name,recipient=other.name,
        debtor=source.name,creditor=other.name,amountCopper=1,dueUTC=0,note="Capacity fixture"}
    for index=1,source.ns.Shared.MAX_OFFERS do
        entry.store=assert(source.ns.Shared.Propose(entry.store,terms,"capacity-ag-"..index,"capacity-of-"..index,1000))
    end
    local backup=text(source,entry)
    local before=copy(wrapper(target)); local sends=target.sendCount
    local review,preview=stage(target,backup)
    equal(preview.missing,32); equal(preview.currentOnly,1)
    assert(not preview.canRestore and preview.problem)
    rejected(function() return target.service.ResolveRecovery("restore",review.token) end)
    assert(same(before,wrapper(target))); equal(#target.service.List(),1)
    equal(target.service.GetOffer(id).delivery,"PEER_RECEIPT_OBSERVED")
    assert(target.service.ResolveRecovery("keep",review.token)); equal(target.sendCount,sends)
end)

test("Shared imports reject foreign owners, foreign storage keys and missing local acceptance evidence",function()
    local a,b,id=agreed()
    local original=copy(a.db); local sends=a.sendCount
    rejected(function() return a.service.PreviewBackup(b.service.ExportBackup()) end)
    local snapshot=assert(a.ns.SharedBackup.Decode(a.service.ExportBackup()))
    snapshot.character="Amber-AnotherRealm"
    rejected(function() return a.service.PreviewBackup(a.ns.SharedBackup.Encode(snapshot)) end)
    local recipient=assert(b.ns.SharedBackup.Decode(b.service.ExportBackup()))
    recipient.entry.store.offers[id].consent="NONE"
    recipient.entry.store.offers[id].messages.accept=nil
    local malformed=assert(b.ns.SharedBackup.Encode(recipient))
    rejected(function() return b.service.PreviewBackup(malformed) end)
    rejected(function() return b.service.StageRecovery(malformed,"not a current fingerprint") end)
    assert(same(original,a.db)); equal(a.sendCount,sends)
    assert(not a.service.IsRecoveryPending() and not b.service.IsRecoveryPending())
end)

test("Malformed and oversized Shared backup input never mutates records or initiates traffic",function()
    local a=peer(); assert(a.service.Initialize())
    local original=copy(a.db)
    for _,bad in ipairs({"", "IOU2:AAAA", "IOUS1:!AAA", "IOUS1:AAAA", "IOUS1:"..string.rep("A",a.ns.SharedBackup.MAX_BYTES)}) do
        rejected(function() return a.service.PreviewBackup(bad) end)
        rejected(function() return a.service.StageRecovery(bad,"irrelevant fingerprint") end)
    end
    rejected(function() return a.service.PreviewBackup(false) end)
    assert(same(original,a.db)); equal(a.sendCount,0); equal(a.enableCount,0)
end)

test("Future-dated Shared history remains reviewable but cannot restore or invent timestamps",function()
    local a,b,id=agreed()
    local snapshot=assert(a.ns.SharedBackup.Decode(a.service.ExportBackup()))
    local target=peer(a.name,a.key); assert(target.service.Initialize())
    for _,mutate in ipairs({function(s) s.exportedAt=1001 end,
        function(s) s.entry.store.offers[id].updatedAt=1001 end}) do
        local future=copy(snapshot); mutate(future)
        local backup=assert(a.ns.SharedBackup.Encode(future))
        local review,preview=stage(target,backup)
        assert(not preview.canRestore and preview.problem)
        assert(not review.canRestore)
        rejected(function() return target.service.ResolveRecovery("restore",review.token) end)
        equal(#target.service.List(),0); assert(target.service.ResolveRecovery("keep",review.token))
    end
    equal(target.sendCount,0); equal(target.enableCount,0)
end)

test("Shared restoration keeps allocation namespaces and monotonic serial/counter high-water marks",function()
    local a,b,id=agreed()
    local original=copy(wrapper(a)); local imported=copy(original)
    imported.counter=50; imported.store.serial=100
    restore(a,text(a,imported))
    equal(wrapper(a).nonce,original.nonce); equal(wrapper(a).counter,50); equal(wrapper(a).store.serial,100)
    imported.counter=1; imported.store.serial=1
    restore(a,text(a,imported))
    equal(wrapper(a).counter,50); equal(wrapper(a).store.serial,100)
    local target=peer(a.name,a.key); assert(target.service.Initialize())
    local destinationNonce=wrapper(target).nonce
    restore(target,text(a,wrapper(a)))
    equal(wrapper(target).nonce,destinationNonce); equal(wrapper(target).counter,0)
    equal(wrapper(target).store.serial,100); equal(target.sendCount,0)
    assert(a.service.Enable(b.name))
    local nextOffer=assert(a.service.Propose({peer=b.name,direction="owed",amountCopper=1,note=""}))
    equal(nextOffer.offerId,"of-"..original.nonce.."-51")
    assert(nextOffer.offerId~=id); equal(wrapper(a).store.serial,101)
end)

test("Invalid persisted Shared recovery fails closed and retains its evidence",function()
    local a,b,id=agreed(); local backup=assert(a.service.ExportBackup())
    stage(a,backup)
    a.db.sharedRecoveryByCharacter[a.key].status="INVALID"
    local original=copy(a.db); local sends=a.sendCount
    local pending,problem=a.service.IsRecoveryPending()
    assert(pending and problem)
    rejected(function() return a.service.Enable(b.name) end)
    rejected(function() return a.service.GetRecovery() end)
    rejected(function() return a.service.Retry(id) end)
    assert(same(original,a.db)); equal(a.sendCount,sends)
end)

test("Cached Shared snapshots and balance views remain private when returned previews are mutated",function()
    local source,other,id=agreed()
    local older=copy(source.db)
    local payment=assert(source.service.ProposePayment(id,4000,"Cached synthetic payment"))
    finish(source,other,payment.offerId)
    local backup=assert(source.service.ExportBackup())
    local target=peer(source.name,source.key,older); assert(target.service.Initialize())
    local decode=target.ns.SharedBackup.Decode; local decoded=0
    target.ns.SharedBackup.Decode=function(value) decoded=decoded+1; return decode(value) end
    local original=assert(target.service.PreviewBackup(backup))
    equal(decoded,1); equal(original.identical,1); equal(original.missing,1)
    equal(original.balances[1].currentCopper,10000)
    equal(original.balances[1].backupCopper,6000); equal(original.balances[1].candidateCopper,6000)
    local pristine=copy(original)
    local function corruptPreview(preview)
        for _,row in ipairs(preview.rows) do
            for _,offer in ipairs({row.backup,row.current}) do
                offer.terms="mutated detached terms"
                offer.messages.propose.terms="mutated nested proposal"
                offer.history[1].kind="INVALID"
                offer.processed.injected="invalid processed data"
            end
            row.classification="modified classification"
        end
        for _,balance in ipairs(preview.balances) do
            balance.currentCopper=1; balance.backupCopper=2; balance.candidateCopper=3
        end
        preview.owner="Modified Owner"
    end
    corruptPreview(original)
    local nextPreview=assert(target.service.PreviewBackup(backup))
    equal(decoded,1) -- Same immutable text is a cache hit.
    assert(same(nextPreview,pristine))
    equal(target.service.GetBalance(id).remainingCopper,10000)
    local review=stage(target,backup)
    corruptPreview(review.preview)
    local current=assert(target.service.GetRecovery())
    equal(current.preview.balances[1].currentCopper,10000)
    equal(current.preview.balances[1].backupCopper,6000)
    equal(current.preview.balances[1].candidateCopper,6000)
    assert(current.canRestore); assert(target.service.ResolveRecovery("restore",current.token))
    equal(target.service.GetBalance(id).remainingCopper,6000)
    equal(target.service.GetOffer(payment.offerId).terms,source.service.GetOffer(payment.offerId).terms)
    equal(target.sendCount,0); equal(target.enableCount,0)
end)

test("Cached Shared snapshots are checked against the current clock on every preview",function()
    local source,other,id=agreed()
    local initial=assert(source.ns.SharedBackup.Decode(source.service.ExportBackup()))
    for _,historyOnly in ipairs({false,true}) do
        local snapshot=copy(initial)
        if historyOnly then snapshot.exportedAt=900; snapshot.entry.store.offers[id].updatedAt=1100 end
        local backup=assert(source.ns.SharedBackup.Encode(snapshot))
        local target=peer(source.name,source.key,nil,1200); assert(target.service.Initialize())
        local decode=target.ns.SharedBackup.Decode; local decoded=0
        target.ns.SharedBackup.Decode=function(value) decoded=decoded+1; return decode(value) end
        local valid=assert(target.service.PreviewBackup(backup)); assert(valid.canRestore)
        equal(decoded,1)
        local before=copy(target.db)
        target.stamp=historyOnly and 1050 or 999
        local future=assert(target.service.PreviewBackup(backup))
        assert(not future.canRestore and future.problem:find("clock",1,true))
        equal(decoded,1); assert(same(before,target.db))
        target.stamp=1200
        assert(target.service.PreviewBackup(backup).canRestore)
        equal(decoded,1); equal(target.sendCount,0)
    end
end)

test("Cached backup previews still validate live in-place changes and invalidate old fingerprints",function()
    local a,b,id=agreed(); local backup=assert(a.service.ExportBackup())
    local decode=a.ns.SharedBackup.Decode; local decoded=0
    a.ns.SharedBackup.Decode=function(value) decoded=decoded+1; return decode(value) end
    local preview=assert(a.service.PreviewBackup(backup)); equal(decoded,1)
    equal(preview.balances[1].currentCopper,10000)
    wrapper(a).counter=wrapper(a).counter+1
    wrapper(a).store.offers[id].delivery="WAITING_FOR_PEER"
    assert(a.ns.SharedPayments.Validate(wrapper(a).store,wrapper(a).closedPaused))
    local before=copy(a.db); local sends=a.sendCount
    local changed=assert(a.service.PreviewBackup(backup))
    equal(decoded,1); equal(changed.different,1)
    assert(changed.currentFingerprint~=preview.currentFingerprint)
    equal(changed.balances[1].currentCopper,nil)
    equal(changed.balances[1].candidateCopper,nil)
    equal(changed.balances[1].backupCopper,10000)
    rejected(function() return a.service.StageRecovery(backup,preview.currentFingerprint) end)
    assert(same(before,a.db)); assert(a.service.IsEnabled()); equal(a.sendCount,sends)
    assert(not a.service.IsRecoveryPending())
end)

test("Shared recovery status fails closed without throwing when the live SavedVariables root disappears",function()
    for _,kind in ipairs({"nil","string"}) do
        local a=peer(); assert(a.service.Initialize())
        local before=copy(a.db)
        if kind=="nil" then a.env.IOUDB=nil else a.env.IOUDB="unavailable" end
        local ok,pending,problem=pcall(a.service.IsRecoveryPending)
        assert(ok and pending and type(problem)=="string" and #problem>0)
        local statusOK,status=pcall(a.service.GetStatus)
        assert(statusOK and type(status)=="string" and status:find("unavailable",1,true))
        assert(same(before,a.db)); equal(a.sendCount,0); equal(a.enableCount,0)
    end
end)

return results
