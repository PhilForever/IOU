local _, IOU = ...
local A = {}
IOU.Sharing = A
local L,C,S=IOU.Ledger,IOU.SharedCodec,IOU.SharedService
local links,failed,busy,frame
local retry,elapsed={},0
local hints,sentHints={},{}
local linkViewCache,refreshingCache
local function cacheOverview(overview)
    if not overview then linkViewCache=nil;return end
    local byID={};for _,offer in ipairs(overview.offers) do byID[offer.offerId]=offer end
    linkViewCache={byID=byID,balances=overview.balances,localName=overview.localName}
end
local function refreshLinkCache()
    if refreshingCache then return end
    refreshingCache=true
    linkViewCache=nil
    local ok,overview=pcall(S.GetOverview)
    if ok then cacheOverview(overview) end
    refreshingCache=false
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local function plain(value) return type(value)=="table" and getmetatable(value)==nil end
local function integer(value,maximum) return type(value)=="number" and value>=0 and value<=maximum and value==math.floor(value) end
local function key(value) return type(value)=="string" and #value<=64 and value:match("^[A-Za-z0-9_-]+$") end
function A.Validate(value)
    if not plain(value) or value.version~=1 or not plain(value.links) or not plain(value.legacy) then return nil,"Shared links are invalid." end
    local seen,count={},0
    for id,row in pairs(value.links) do
        count=count+1
        if not integer(id,L.MAX_ENTRIES) or id<1 or not plain(row) or not key(row.offerId) or seen[row.offerId]
            or type(row.terms)~="string" or #row.terms>C.MAX_BYTES or not integer(row.created,L.MAX_TIMESTAMP)
            or not integer(row.personalAmount,L.MAX_AMOUNT) or row.personalAmount<1
            or not integer(row.basePaid,L.MAX_AMOUNT) or not integer(row.baseEventID,L.MAX_EVENTS)
            or not integer(row.seenPaid,L.MAX_AMOUNT) or type(row.player)~="string" or #row.player>L.MAX_PLAYER
            or type(row.label)~="string" or #row.label>L.MAX_LABEL or (row.kind~="money" and row.kind~="item")
            or row.suspended~=nil and type(row.suspended)~="boolean" then
            return nil,"A shared IOU link is invalid."
        end
        local terms=C.ParseTerms(row.terms);local asset=terms and C.Asset(terms)
        if not terms or not C.IsObligation(terms) or asset.kind~=row.kind
            or row.personalAmount-row.basePaid~=terms.amountCopper then return nil,"Shared link terms do not match the IOU." end
        if row.evidenceRevision~=nil and not integer(row.evidenceRevision,C.MAX_CHAIN_ROWS) then return nil,"Invalid observed repayment baseline." end
        if row.evidenceUsed~=nil then
            if not plain(row.evidenceUsed) then return nil,"Invalid observed repayment evidence." end
            local evidenceCount=0
            for eventID,amount in pairs(row.evidenceUsed) do
                evidenceCount=evidenceCount+1
                if not integer(eventID,L.MAX_EVENTS) or eventID<1 or not integer(amount,L.MAX_AMOUNT) or amount<1 then
                    return nil,"Invalid observed repayment allocation."
                end
            end
            if evidenceCount>L.MAX_EVENTS then return nil,"Too much observed repayment evidence." end
        end
        seen[row.offerId]=true
    end
    if count>L.MAX_ENTRIES then return nil,"Too many shared links." end
    count=0
    for id,value in pairs(value.legacy) do count=count+1;if not key(id) or value~=true then return nil,"Invalid legacy shared reference." end end
    if count>IOU.Shared.MAX_OFFERS then return nil,"Too many legacy shared references." end
    return true
end
local function prefixEntry(entry)
    local prefix=copy(entry);prefix.events={}
    if entry.initial then
        for _,field in ipairs({"player","label","note","due"}) do prefix[field]=entry.initial[field] end
    end
    return prefix
end
local function appendPrefix(prefix,event,index)
    prefix.events[index]=event
    if event.type=="amendment" then
        for _,field in ipairs({"player","label","note","due"}) do prefix[field]=event.after[field] end
    end
end
local function bound(id,row,db,ownName)
    if row.suspended then return nil end
    local entry=L.Get(db or IOU.GetLedger(),id)
    if not entry or entry.created~=row.created or entry.amount~=row.personalAmount or entry.kind~=row.kind
        or entry.player~=row.player or entry.label~=row.label or #entry.events<row.baseEventID then return nil end
    local terms=C.ParseTerms(row.terms)
    if not terms or not ownName or entry.direction~=(terms.creditor==ownName and "owed" or "owe") then return nil end
    local prefix=prefixEntry(entry)
    for index=1,row.baseEventID do appendPrefix(prefix,entry.events[index],index) end
    if L.Balance(prefix)~=row.personalAmount-row.basePaid then return nil end
    return entry
end
local function ready()
    if failed then return nil,failed end
    if not links then return A.Initialize() end
    local namespace=IOUDB.sharingByCharacter
    if not plain(namespace) or namespace[IOU.Character()]~=links or not A.Validate(links) then return nil,"Shared links changed. Reload before sharing." end
    return true
end
local function draftLedger()
    local encoded,err=IOU.Codec.Export(IOU.GetLedger());if not encoded then return nil,err end
    return IOU.Codec.Import(encoded)
end
local function commit(draft,nextLinks)
    local ok,err=IOU.CommitSharingState(IOU.GetLedger(),draft,links,nextLinks)
    if ok then links=IOUDB.sharingByCharacter[IOU.Character()] end
    return ok,err
end
local function linkRow(entry,offer,seenPaid)
    local terms=C.ParseTerms(offer.terms)
    local base=entry.amount-terms.amountCopper
    local prefix=prefixEntry(entry);local baseIndex
    if L.Balance(prefix)==terms.amountCopper then baseIndex=0 end
    for index,event in ipairs(entry.events) do
        appendPrefix(prefix,event,index)
        if L.Balance(prefix)==terms.amountCopper then baseIndex=index end
    end
    if base<0 or baseIndex==nil then return nil,"This personal history cannot be linked without changing its original loan." end
    return {offerId=offer.offerId,terms=offer.terms,created=entry.created,personalAmount=entry.amount,
        basePaid=base,baseEventID=baseIndex,player=entry.player,
        label=entry.label,kind=entry.kind,seenPaid=seenPaid or 0,evidenceRevision=0,evidenceUsed={}}
end
function A.GetLinks()
    local result={}
    if links then for id,row in pairs(links.links) do
        local e=L.Get(IOU.GetLedger(),id)
        if not row.suspended and e and e.created==row.created and e.amount==row.personalAmount and e.kind==row.kind
            and e.player==row.player and e.label==row.label then result[id]=row.offerId end
    end end
    return result
end
function A.GetLinkBases()
    local result={};if links then for id in pairs(A.GetLinks()) do result[id]=links.links[id].basePaid end end;return result
end
function A.GetLink(id)
    if not links or not links.links[id] then return nil end
    local row=links.links[id]
    local current=L.Get(IOU.GetLedger(),id)
    if not current or current.created~=row.created or current.amount~=row.personalAmount or current.kind~=row.kind
        or current.player~=row.player or current.label~=row.label then return nil end
    local offer=linkViewCache and linkViewCache.byID[row.offerId]
    local view=offer and linkViewCache.balances[row.offerId]
    local state=offer and offer.state or "PAUSED"
    local result=copy(row)
    result.state=(state=="COMMITTED" and view and view.confirmed) and "agreed"
        or (state=="DECLINED" or state=="WITHDRAWN") and "declined" or state=="PAUSED" and "review" or "pending"
    result.remaining=view and view.remainingCopper
    result.pending=view and view.pendingOfferId~=nil or false
    if row.suspended then result.state,result.pending="review",true end
    local e=L.Get(IOU.GetLedger(),id)
    if e and view and view.confirmed then
        result.pending=result.pending or e.amount-L.Balance(e)-row.basePaid~=view.paidCopper
    end
    return result
end
function A.Connect(peer)
    local ok,err=ready();if not ok then return nil,err end
    if not IOU.GetSettings().sharedRequests then return nil,"Enable Shared requests in Options first." end
    ok,err=S.EnableBackground();if not ok then return nil,err end
    return S.SelectPeer(peer)
end
function A.PrepareOffer(id)
    local offer,err=S.GetOffer(id);if not offer then return nil,err end
    local terms=C.ParseTerms(offer.terms)
    sentHints[terms.parentOfferId or id]=nil
    local own=S.GetOverview().localName
    local ok;ok,err=A.Connect(terms.proposer==own and terms.recipient or terms.proposer)
    if not ok then return nil,err end
    if offer.localClosed then return nil,"This interrupted request was closed locally." end
    if offer.state=="PAUSED" then return S.Resume(id) end
    A.OnPersonalChanged()
    return true
end
local function equivalentItems(left,right)
    local matcher=IOU.TradeMatching
    if matcher and type(matcher.EquivalentItems)=="function" then return matcher.EquivalentItems(left,right) end
    local a,b=C.CanonicalItem(left),C.CanonicalItem(right)
    return a~=nil and a==b
end
local function itemFields(entry)
    local identity,id=C.CanonicalItem(entry.label)
    local link=entry.label
    local name=entry.label:match("|h%[([^|]+)%]|h")
    if not identity and IOU.Crafting then
        for _,item in ipairs(IOU.Crafting.BagItems()) do
            local display=item.link:match("|h%[([^|]+)%]|h")
            if display==entry.label then
                local candidate,number=C.CanonicalItem(item.link)
                if identity and candidate~=identity then return nil,"Choose the exact item link before sharing." end
                identity,id,name,link=candidate,number,display,item.link
            end
        end
    end
    if not identity then return nil,"Shift-click the exact item into this IOU before sharing." end
    return {itemKey=identity,itemName=name or ("Item "..id),link=link}
end
function A.Share(id)
    local ok,err=ready();if not ok then return nil,err end
    local e=L.Get(IOU.GetLedger(),id)
    if not e or e.kind=="favor" or L.Status(e)=="cancelled" or L.Balance(e)<=0 then return nil,"Choose an open gold or item IOU." end
    local previous=A.GetLink(id)
    if previous and previous.state~="declined" then return S.GetOffer(previous.offerId) end
    local fields={peer=e.player,direction=e.direction,amountCopper=L.Balance(e),note=e.note,dueUTC=e.due or 0,kind=e.kind}
    if e.kind=="item" then
        local item;item,err=itemFields(e);if not item then return nil,err end
        if item.link~=e.label then
            local amended;amended,err=IOU.Amend(id,{player=e.player,label=item.link,note=e.note,due=e.due or 0},"Selected item for sharing")
            if not amended then return nil,err end
            e=L.Get(IOU.GetLedger(),id)
        end
        fields.itemKey,fields.itemName=item.itemKey,item.itemName
    end
    ok,err=A.Connect(e.player);if not ok then return nil,err end
    local offer,saved;offer,err,saved=S.Propose(fields)
    offer=offer or saved
    if not offer then return nil,err end
    local row;row,err=linkRow(e,offer);if not row then return nil,err end
    local nextLinks=copy(links);nextLinks.links[id]=row
    local draft;draft,err=draftLedger();if not draft then return nil,err end
    ok,err=commit(draft,nextLinks);if not ok then return nil,err end
    A.OnPersonalChanged()
    return offer
end
local function adopted(offerId)
    for id,row in pairs(links.links) do if row.offerId==offerId then return id end end
end
local function adopt(id,explicit)
    local ok,err=ready();if not ok then return nil,err end
    local existing=adopted(id)
    if existing and not links.links[existing].suspended then return L.Get(IOU.GetLedger(),existing) end
    local offer;offer,err=S.GetOffer(id);if not offer then return nil,err end
    local terms=C.ParseTerms(offer.terms);local view=S.GetBalance(id)
    if not C.IsObligation(terms) or not view or not view.confirmed or offer.state~="COMMITTED" then return nil,"Accept and synchronize this IOU first." end
    local own=S.GetOverview().localName
    local peer=terms.proposer==own and terms.recipient or terms.proposer
    local direction=terms.creditor==own and "owed" or "owe"
    local asset=C.Asset(terms);local candidates={}
    for _,entry in ipairs(IOU.GetLedger().entries) do
        if (not links.links[entry.id] or entry.id==existing) and entry.player==peer and entry.direction==direction and entry.kind==asset.kind
            and L.Status(entry)~="cancelled" and (L.Balance(entry)==terms.amountCopper or L.Balance(entry)==view.remainingCopper)
            and (asset.kind=="money" or equivalentItems(entry.label,asset.itemKey)) then candidates[#candidates+1]=entry end
    end
    if #candidates>0 and not explicit then return nil,"A matching personal IOU exists. Use Add to ledger in Requests to link it." end
    if #candidates>1 then return nil,"Several personal IOUs match. Review them before adding another." end
    local draft;draft,err=draftLedger();if not draft then return nil,err end
    local entry=candidates[1] and L.Get(draft,candidates[1].id)
    if not entry then
        local label=asset.kind=="item" and ("|H"..asset.itemKey.."|h["..asset.label.."]|h") or ""
        entry,err=L.Add(draft,{player=peer,direction=direction,kind=asset.kind,amount=terms.amountCopper,
            label=label,note=terms.note,due=terms.dueUTC},time())
        if not entry then return nil,err end
    end
    -- The linked personal history may still need to mirror already confirmed
    -- Shared payments. Mark them seen only after reconciliation applies them.
    if asset.kind=="item" and C.CanonicalItem(entry.label)~=asset.itemKey then
        local label="|H"..asset.itemKey.."|h["..asset.label.."]|h"
        local amended;amended,err=L.Amend(draft,entry.id,{player=entry.player,label=label,note=entry.note,due=entry.due or 0},
            "Linked shared item",time())
        if not amended then return nil,err end
    end
    local row;row,err=linkRow(entry,offer,0)
    if not row then return nil,err end
    local nextLinks=copy(links)
    if existing and existing~=entry.id then nextLinks.links[existing]=nil end
    nextLinks.links[entry.id]=row
    ok,err=commit(draft,nextLinks);if not ok then return nil,err end
    return L.Get(IOU.GetLedger(),entry.id)
end
function A.Adopt(id)
    local entry,err=adopt(id,true)
    if not entry then return nil,err end
    A.OnPersonalChanged()
    return L.Get(IOU.GetLedger(),entry.id)
end
function A.CommitImport(candidate)
    local ok,err=ready();if not ok then return nil,err end
    local nextLinks=copy(links)
    for _,row in pairs(nextLinks.links) do row.suspended=true end
    return commit(candidate,nextLinks)
end
local function observedPayments(id,row)
    local journal=IOUDB.tradesByCharacter and IOUDB.tradesByCharacter[IOU.Character()]
    if not journal or not IOU.TradeService.Validate(journal) then return {} end
    local entry=L.Get(IOU.GetLedger(),id)
    if not entry then return {} end
    local reversed={}
    for _,event in ipairs(entry.events) do if event.type=="reversal" then reversed[event.reverses]=true end end
    local events,seen={},{}
    for _,receipt in ipairs(journal.receipts or {}) do
        if receipt.status~="undone" and IOU.PlayerSummary.NameKey(receipt.peer)==IOU.PlayerSummary.NameKey(entry.player) then
            for _,application in ipairs(receipt.applications or {}) do
                local event=entry.events[application.eventID]
                if application.entryID==id and application.eventID>row.baseEventID and not seen[application.eventID]
                    and event and event.type=="payment" and not reversed[event.id]
                    and event.amount==application.amount and event.at==application.at
                    and application.direction==entry.direction and application.asset==entry.kind
                    and (entry.kind~="item" or equivalentItems(application.itemKey,entry.label))
                    and event.note==((receipt.medium=="mail_sent" or receipt.medium=="mail_received") and "Mail " or "Trade ")..receipt.id then
                    events[#events+1]={eventID=event.id,amount=event.amount}
                    seen[event.id]=true
                end
            end
        end
    end
    table.sort(events,function(a,b) return a.eventID<b.eventID end)
    return events
end
local function evidenceAvailable(id,row)
    local total=0
    for _,event in ipairs(observedPayments(id,row)) do
        total=total+math.max(0,event.amount-((row.evidenceUsed or {})[event.eventID] or 0))
    end
    return total
end
local function reconcileEvidence(id,row,view)
    if row.evidenceRevision==view.baseRevision and row.evidenceUsed~=nil then return row end
    if row.evidenceRevision and row.evidenceRevision>view.baseRevision then return nil end
    local events=observedPayments(id,row)
    local used=copy(row.evidenceUsed or {})
    local revision=row.evidenceRevision
    if revision==nil then
        -- An older sidecar has no proof of which native receipts already
        -- backed consent. Keep those unavailable until a new transfer occurs.
        revision=view.baseRevision
        for _,event in ipairs(events) do used[event.eventID]=event.amount end
    else
        local index=0
        for _,event in ipairs(view.events) do
            if event.effective then
                index=index+1
                if index>revision and C.IsPayment(event) then
                    local remaining=event.amountCopper
                    for _,evidence in ipairs(events) do
                        local available=math.max(0,evidence.amount-(used[evidence.eventID] or 0))
                        local amount=math.min(available,remaining)
                        if amount>0 then used[evidence.eventID]=(used[evidence.eventID] or 0)+amount;remaining=remaining-amount end
                        if remaining==0 then break end
                    end
                end
            end
        end
    end
    if row.evidenceRevision~=view.baseRevision or row.evidenceUsed==nil then
        local candidate=copy(links)
        candidate.links[id].evidenceRevision,candidate.links[id].evidenceUsed=view.baseRevision,used
        local draft=draftLedger()
        if not draft or not commit(draft,candidate) then return nil end
        return links.links[id]
    end
    return row
end
local function hintNow()
    local source=type(GetTime)=="function" and GetTime or time
    if type(source)~="function" then return nil end
    local ok,stamp=pcall(source)
    if ok and type(stamp)=="number" and stamp>=0 and stamp<math.huge then return stamp end
end
local function automaticEventBlocked(view,byID,kind,amount)
    for _,event in ipairs(view.events) do
        if not event.effective and (event.state=="DECLINED" or event.state=="WITHDRAWN") then
            local prior=byID[event.offerId]
            local terms=prior and C.ParseTerms(prior.terms)
            if terms and terms.kind==kind and terms.amountCopper==amount
                and terms.baseRevision==view.baseRevision and terms.baseChain==view.baseChain then return true end
        end
    end
    return false
end
local function reconcile(id,row,offer,view,overview,byID)
    local entry=bound(id,row,nil,overview.localName);if not entry or L.Status(entry)=="cancelled" then return end
    row=reconcileEvidence(id,row,view);if not row then return end
    local paid=row.personalAmount-L.Balance(entry)-row.basePaid
    local shared=view.paidCopper
    if shared>paid and shared>row.seenPaid then
        local draft=draftLedger();if not draft then return end
        local event=L.Pay(draft,id,shared-paid,"Shared "..row.offerId,time())
        if not event then return end
        local candidate=copy(links);candidate.links[id].seenPaid=shared
        commit(draft,candidate)
        return
    end
    if shared<row.seenPaid and paid==row.seenPaid then
        local draft=draftLedger();if not draft then return end
        local e=L.Get(draft,id);local remaining=row.seenPaid-shared
        local reversed={};for _,event in ipairs(e.events) do if event.type=="reversal" then reversed[event.reverses]=true end end
        for index=#e.events,1,-1 do
            local event=e.events[index]
            if event.type=="payment" and event.id>row.baseEventID and not reversed[event.id] then
                if not L.Reverse(draft,id,event.id,"Shared correction "..row.offerId,time()) then return end
                if event.amount>remaining then
                    -- Ledger reversals are whole events. Preserve the residual
                    -- as a new audited payment; retaining the original transfer
                    -- note makes an older Activity Undo fail closed as stale.
                    if not L.Pay(draft,id,event.amount-remaining,event.note,time()) then return end
                    remaining=0
                else remaining=remaining-event.amount end
                if remaining==0 then break end
            end
        end
        if remaining~=0 then return end
        local candidate=copy(links);candidate.links[id].seenPaid=shared;commit(draft,candidate);return
    end
    if row.seenPaid~=shared then local candidate=copy(links);candidate.links[id].seenPaid=shared;local draft=draftLedger();if draft then commit(draft,candidate) end end
    if offer.role=="proposer" and view.canPropose then
        local intended=paid
        local hint=hints[row.offerId]
        if hint and hint.baseChain==view.baseChain and hint.baseRevision==view.baseRevision and paid==shared then intended=hint.paidAmount end
        if intended>shared then
            local amount=math.min(intended-shared,view.remainingCopper)
            local kind=C.Asset(C.ParseTerms(offer.terms)).kind=="item" and "ITEM_PAYMENT" or "GOLD_PAYMENT"
            if not automaticEventBlocked(view,byID,kind,amount) then S.ProposePayment(row.offerId,amount,"Observed repayment") end
        elseif intended<shared then
            for index=#view.events,1,-1 do local event=view.events[index]
                if C.IsPayment({kind=event.kind}) and event.effective and not event.reversed and event.amountCopper==shared-intended then
                    local kind=C.Asset(C.ParseTerms(offer.terms)).kind=="item" and "ITEM_CORRECTION" or "GOLD_CORRECTION"
                    if not automaticEventBlocked(view,byID,kind,shared-intended) then
                        S.ProposeCorrection(row.offerId,event.offerId,"Repayment undone")
                    end
                    break
                end
            end
        end
    end
    if view.pendingOfferId then
        local pending=byID[view.pendingOfferId];local terms=pending and C.ParseTerms(pending.terms)
        if pending and pending.role=="recipient" and pending.state=="OFFER_RECEIVED" and C.IsPayment(terms)
            and evidenceAvailable(id,row)>=terms.amountCopper and paid>=terms.amountCopper+shared then S.Accept(pending.offerId) end
        if pending and pending.role=="recipient" and pending.state=="OFFER_RECEIVED" and C.IsCorrection(terms)
            and paid==shared-terms.amountCopper then S.Accept(pending.offerId) end
    end
    if paid==shared then sentHints[row.offerId]=nil end
    if offer.role=="recipient" and paid~=shared and not view.pendingOfferId and S.SendHint then
        local fingerprint=view.baseChain..":"..paid
        local attempt=sentHints[row.offerId]
        if not attempt or attempt.fingerprint~=fingerprint then
            attempt={fingerprint=fingerprint,attempts=0};sentHints[row.offerId]=attempt
        end
        local stamp=hintNow()
        if stamp and attempt.attempts<3 and (not attempt.at or stamp-attempt.at>=15) then
            attempt.attempts,attempt.at=attempt.attempts+1,stamp
            S.SendHint(row.offerId,paid)
        end
    end
end
function A.ReceiveHint(sender,message)
    local ok,err=ready();if not ok then return nil,err end
    local offer=S.GetOffer(message.offerId);local view=offer and S.GetBalance(message.offerId)
    local terms=offer and C.ParseTerms(offer.terms)
    if not offer or offer.role~="proposer" or offer.state~="COMMITTED" or not C.IsObligation(terms)
        or offer.terms~=message.terms or offer.agreementId~=message.agreementId or sender~=terms.recipient
        or not view or not view.confirmed or view.baseRevision~=message.baseRevision or view.baseChain~=message.baseChain
        or message.paidAmount>terms.amountCopper then return nil,"This synchronization hint does not match the agreed IOU." end
    hints[offer.offerId]=copy(message)
    A.OnPersonalChanged();return true
end
local function hintWork()
    local cache=linkViewCache
    if not cache then return false end
    for id,row in pairs(links.links) do
        local offer,view=cache.byID[row.offerId],cache.balances[row.offerId]
        if offer and offer.role=="recipient" and view and view.confirmed and not view.pendingOfferId then
            local entry=bound(id,row,nil,cache.localName)
            if entry and L.Status(entry)~="cancelled" then
                local paid=row.personalAmount-L.Balance(entry)-row.basePaid
                if paid~=view.paidCopper then
                    local attempt=sentHints[row.offerId]
                    local fingerprint=view.baseChain..":"..paid
                    if not attempt or attempt.fingerprint~=fingerprint or attempt.attempts<3 then return true end
                end
            end
        end
    end
    return false
end
local function schedule()
    if not frame or not links then return end
    if not IOU.GetSettings().sharedRequests then frame:SetScript("OnUpdate",nil);return end
    local offers=S.List() or {};local work=false
    for _,offer in ipairs(offers) do
        local state=offer.state
        if not offer.localClosed and (state=="PAUSED" or state=="OFFER_OPEN" or state=="ACCEPT_PENDING"
            or state=="DECLINE_PENDING" or state=="COMMITTED" and offer.role=="proposer" and offer.delivery~="PEER_RECEIPT_OBSERVED") then
            if (retry[offer.offerId] or 0)<3 then work=true end
        end
    end
    work=work or hintWork()
    frame:SetScript("OnUpdate",work and function(_,dt) elapsed=elapsed+dt;if elapsed>=15 then elapsed=0;A.Tick() end end or nil)
end
function A.OnPersonalChanged()
    if busy or not links or failed then return end
    busy=true
    local ok=pcall(function()
        if not ready() then return end
        local overview=S.GetOverview();if not overview then cacheOverview(nil);return end
        cacheOverview(overview)
        for _,offer in ipairs(overview.offers) do
            local terms=C.ParseTerms(offer.terms)
            if C.IsObligation(terms) and offer.state=="COMMITTED" and not links.legacy[offer.offerId]
                and not adopted(offer.offerId) then adopt(offer.offerId,false) end
        end
        overview=S.GetOverview();if not overview then cacheOverview(nil);return end
        cacheOverview(overview)
        local byID={};for _,offer in ipairs(overview.offers) do byID[offer.offerId]=offer end
        for id,row in pairs(links.links) do
            local offer=byID[row.offerId];local view=overview.balances[row.offerId]
            if offer and view and view.confirmed and offer.terms==row.terms and S.IsBackground() then
                reconcile(id,row,offer,view,overview,byID)
            end
        end
        refreshLinkCache()
        schedule()
    end)
    busy=false
    if not ok then failed="Shared synchronization paused. Reload before continuing." end
end
function A.Tick()
    if not ready() or not IOU.GetSettings().sharedRequests or S.IsRecoveryPending() then return end
    if not S.EnableBackground() then return end
    local wire=IOU.SharedWire
    if wire and wire.QueueSize and wire.QueueSize()>0 then schedule();return end
    for _,offer in ipairs(S.List() or {}) do
        local state=offer.state;local count=retry[offer.offerId] or 0
        if not offer.localClosed and count<3 then
            if state=="PAUSED" then retry[offer.offerId]=count+1;S.Resume(offer.offerId)
            elseif state=="OFFER_OPEN" or state=="ACCEPT_PENDING" or state=="DECLINE_PENDING"
                or state=="COMMITTED" and offer.role=="proposer" and offer.delivery~="PEER_RECEIPT_OBSERVED" then
                retry[offer.offerId]=count+1;S.Retry(offer.offerId)
            end
            if wire and wire.QueueSize and wire.QueueSize()>0 then break end
        end
    end
    A.OnPersonalChanged();schedule()
end
function A.SetEnabled(value)
    IOU.GetSettings().sharedRequests=value==true
    if not value then if frame then frame:SetScript("OnUpdate",nil) end;return S.Disable() end
    retry={};local ok,err=S.EnableBackground();if ok then A.Tick() end;return ok,err
end
function A.Initialize()
    if links then return true end
    if not IOU.Initialize() or not S.Initialize() then return nil,"Shared IOUs are unavailable." end
    local namespace=IOUDB.sharingByCharacter
    if namespace~=nil and not plain(namespace) then failed="Shared links are invalid; records were left untouched.";return nil,failed end
    local value=namespace and namespace[IOU.Character()]
    if value~=nil and not A.Validate(value) then failed="Shared links are invalid; records were left untouched.";return nil,failed end
    if not value then
        value={version=1,links={},legacy={}}
        for _,offer in ipairs(S.List() or {}) do value.legacy[offer.offerId]=true end
    end
    if not namespace then namespace={};IOUDB.sharingByCharacter=namespace end
    namespace[IOU.Character()]=value;links=value
    refreshLinkCache()
    if type(CreateFrame)=="function" then frame=CreateFrame("Frame") end
    if IOU.GetSettings().sharedRequests and not S.IsRecoveryPending() then S.EnableBackground();A.Tick() end
    return true
end
local changed=IOU.OnSharedChanged
IOU.OnSharedChanged=function(...)
    refreshLinkCache()
    if changed then pcall(changed,...) end
    A.OnPersonalChanged()
end
