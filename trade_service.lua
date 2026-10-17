local _, IOU = ...
local S = {}
IOU.TradeService = S
local L, C, M = IOU.Ledger, IOU.Codec, IOU.TradeMatching
local store, failure, reserved
local MAX_RECEIPTS, MAX_APPS, MAX_TOTAL = 100, 32, L.MAX_AMOUNT * L.MAX_ENTRIES
S.MAX_RECEIPTS = MAX_RECEIPTS

local function public(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function integer(value, low, high)
    return public(value) and type(value)=="number" and value>=low and value<=high and value==math.floor(value)
end
local function text(value, maximum)
    return public(value) and type(value)=="string" and #value<=maximum
end
local function copy(value)
    if type(value)~="table" then return value end
    local out={}; for key,item in pairs(value) do out[key]=copy(item) end; return out
end
local function array(value, maximum)
    if not public(value) or type(value)~="table" or getmetatable(value) then return nil end
    local count, highest=0,0
    for key in pairs(value) do
        if not integer(key,1,maximum) then return nil end
        count,highest=count+1,math.max(highest,key)
    end
    return count==highest and count or nil
end
local function tree(value, depth, budget, seen)
    if not public(value) then return false end
    local kind=type(value)
    if kind=="string" then budget.bytes=budget.bytes+#value; return #value<=2000 and budget.bytes<=1048576 end
    if kind=="number" then return integer(value,0,MAX_TOTAL) end
    if kind=="boolean" then return true end
    if kind~="table" or depth>9 or getmetatable(value) or seen[value] then return false end
    seen[value]=true
    for key,item in pairs(value) do
        budget.nodes=budget.nodes+1
        if budget.nodes>60000 or not public(key)
                or not (type(key)=="string" and #key<=64 or integer(key,1,L.MAX_ENTRIES+32))
            or not tree(item,depth+1,budget,seen) then return false end
    end
    seen[value]=nil
    return true
end
local function side(value)
    if type(value)~="table" or not integer(value.money,0,MAX_TOTAL) or not array(value.items,6) then return false end
    for _,item in ipairs(value.items) do
        if type(item)~="table" or not integer(item.itemID,1,2147483647)
            or not integer(item.quantity,1,L.MAX_AMOUNT) or not text(item.name,512) or not text(item.link,512) then return false end
    end
    return true
end
local statuses={applied=true,review=true,unmatched=true,undone=true,ignored=true}
local function assetKey(row)
    if row.direction~="owed" and row.direction~="owe" then return nil end
    if row.asset=="money" then return row.direction..":money" end
    if row.asset=="item" and text(row.itemKey,512) then
        local key,id=M.ItemKey(row.itemKey)
        if key and key==row.itemKey and id==row.itemID then return row.direction..":"..key end
    end
end
local function conserved(r)
    local totals={}
    for _,direction in ipairs({"owed","owe"}) do
        local raw=direction=="owed" and r.incoming or r.outgoing
        totals[direction..":money"]=raw.money
        for _,item in ipairs(raw.items) do
            local key,id=M.ItemKey(item.link)
            if not key or id~=item.itemID then return false end
            key=direction..":"..key
            totals[key]=(totals[key] or 0)+item.quantity
        end
    end
    for _,rows in ipairs({r.applications,r.pending,r.unmatched}) do
        for _,row in ipairs(rows) do
            local key=assetKey(row)
            if not key or not integer(row.amount,1,MAX_TOTAL) or not totals[key] or row.amount>totals[key] then return false end
            totals[key]=totals[key]-row.amount
        end
    end
    for _,amount in pairs(totals) do if amount~=0 then return false end end
    return true
end
local function validate(value)
    if not tree(value,0,{bytes=0,nodes=0},{}) or value.version~=1
        or not integer(value.counter,0,999999999) or not array(value.receipts,MAX_RECEIPTS) then return nil,"Trade history is invalid." end
    local ids={}
    for _,r in ipairs(value.receipts) do
        local serial=type(r.id)=="string" and tonumber(r.id:match("^tr%-(%d+)$"))
        if not integer(serial,1,value.counter) or r.id~="tr-"..serial or ids[r.id]
            or not IOU.PlayerSummary.NameKey(r.peer) or not integer(r.at,0,L.MAX_TIMESTAMP)
            or not statuses[r.status] or not side(r.outgoing) or not side(r.incoming)
            or not array(r.applications,MAX_APPS) or not array(r.pending,14) or not array(r.unmatched,14) then
            return nil,"A trade receipt is invalid."
        end
        ids[r.id]=true
        for _,a in ipairs(r.applications) do
            if not integer(a.entryID,1,L.MAX_ENTRIES) or not integer(a.eventID,1,L.MAX_EVENTS)
                or not integer(a.amount,1,L.MAX_AMOUNT) or not integer(a.at,0,L.MAX_TIMESTAMP) or not text(a.label,512)
                or (a.direction~="owed" and a.direction~="owe")
                or (a.asset~="money" and a.asset~="item") then return nil,"A trade repayment is invalid." end
        end
        for _,row in ipairs(r.pending) do
            if not integer(row.amount,1,MAX_TOTAL) or not text(row.label,512) or not text(row.reason,240)
                or (row.direction~="owed" and row.direction~="owe") or (row.asset~="money" and row.asset~="item")
                or not array(row.candidates,L.MAX_ENTRIES+32) then return nil,"A trade allocation is invalid." end
            for _,candidate in ipairs(row.candidates) do
                if not integer(candidate.balance,1,L.MAX_AMOUNT) or not text(candidate.label,512)
                    or not (candidate.source=="personal" and integer(candidate.entryID,1,L.MAX_ENTRIES)
                        or candidate.source=="shared" and text(candidate.offerID,64)) then return nil,"A trade candidate is invalid." end
            end
        end
        if not conserved(r) then return nil,"Trade allocations do not match the captured transfer." end
    end
    return true
end
function S.Validate(value)
    local ok,result,err=pcall(validate,value)
    if not ok then return nil,"Trade history could not be read safely." end
    return result,err
end
function S.Initialize()
    if failure then return nil,failure end
    if store then return true end
    if not IOU.Initialize() then return nil,"The personal ledger is unavailable." end
    local namespace=IOUDB.tradesByCharacter
    if namespace~=nil and (type(namespace)~="table" or getmetatable(namespace)) then
        failure="Trade history is invalid; automatic updates are paused."; return nil,failure
    end
    local candidate=namespace and namespace[IOU.Character()]
    if candidate~=nil and not S.Validate(candidate) then
        failure="Trade history is invalid; automatic updates are paused."; return nil,failure
    end
    if not namespace then namespace={}; IOUDB.tradesByCharacter=namespace end
    store=candidate or {version=1,counter=0,receipts={}}
    namespace[IOU.Character()]=store
    return true
end
local function ready()
    local ok,err=S.Initialize()
    if not ok then return nil,err end
    if not public(IOUDB) or type(IOUDB)~="table" or getmetatable(IOUDB) then
        return nil,"Trade history changed. Reload before recording another trade."
    end
    local namespace=rawget(IOUDB,"tradesByCharacter")
    if not public(namespace) or type(namespace)~="table" or getmetatable(namespace) then
        return nil,"Trade history changed. Reload before recording another trade."
    end
    local current=rawget(namespace,IOU.Character())
    if not public(current) or current~=store or not S.Validate(store) then
        return nil,"Trade history changed. Reload before recording another trade."
    end
    return true
end
local function notify(receipt)
    if type(IOU.RenderTradeAttention)=="function" then pcall(IOU.RenderTradeAttention,S.PendingCount()) end
    if type(IOU.OnTradeChanged)=="function" then pcall(IOU.OnTradeChanged,receipt and copy(receipt)) end
end
function S.PendingCount()
    local count=0
    for _,r in ipairs(store and store.receipts or {}) do if r.status=="review" then count=count+1 end end
    return count
end
function S.NewSessionID()
    local ok,err=ready(); if not ok then return nil,err end
    if store.counter>=999999999 then return nil,"Trade history has reached its identifier limit." end
    local draft=copy(store); draft.counter=draft.counter+1
    IOUDB.tradesByCharacter[IOU.Character()]=draft; store=draft
    reserved="tr-"..draft.counter
    return reserved
end
local function locate(id, candidate)
    for index,r in ipairs((candidate or store).receipts) do if r.id==id then return r,index end end
end
function S.List()
    local ok,err=ready(); if not ok then return nil,err end
    local result={}; for index=#store.receipts,1,-1 do result[#result+1]=copy(store.receipts[index]) end
    return result
end
function S.Get(id)
    local ok,err=ready(); if not ok then return nil,err end
    local r=locate(id); if r then return copy(r) end
    return nil,"Trade not found."
end
local function overview()
    if not IOU.SharedService then return nil end
    local value,err=IOU.SharedService.GetOverview()
    -- An unreadable Shared namespace must block gold allocation, not pretend
    -- that no shared debt exists beside a possible personal duplicate.
    return value or (err and {} or nil)
end
local function timestamp()
    local ok,value=pcall(time)
    if ok and integer(value,0,L.MAX_TIMESTAMP) then return value end
end
local function ledgerDraft()
    local encoded,err=C.Export(IOU.GetLedger()); if not encoded then return nil,err end
    return C.Import(encoded)
end
local function status(r)
    return #r.pending>0 and "review" or #r.applications>0 and "applied" or "unmatched"
end
local function commit(ledgerBefore,ledgerAfter,tradesAfter,receipt)
    local ok,err=IOU.CommitTradeState(ledgerBefore,ledgerAfter,store,tradesAfter)
    if not ok then return nil,err end
    store=IOUDB.tradesByCharacter[IOU.Character()]
    notify(receipt)
    return copy(receipt)
end
local function apply(draft,r,action,at)
    if #r.applications>=MAX_APPS then return nil,"This trade has reached its repayment limit." end
    local entry=L.Get(draft,action.entryID)
    if not entry or L.Balance(entry)~=action.expectedBalance then return nil,"The balance changed. Review this trade." end
    local event,err=L.Pay(draft,entry.id,action.amount,"Trade "..r.id,at)
    if not event then return nil,err end
    r.applications[#r.applications+1]={entryID=entry.id,eventID=event.id,amount=action.amount,
        label=entry.kind=="money" and "Gold" or entry.label,direction=entry.direction,asset=entry.kind,at=at,
        itemID=action.itemID,itemKey=action.itemKey}
    return true
end
local function makeRoom(candidate)
    if #candidate.receipts<MAX_RECEIPTS then return true end
    for index,r in ipairs(candidate.receipts) do
        if r.status~="review" then table.remove(candidate.receipts,index); return true end
    end
    return nil,"Review or dismiss an older trade before recording more."
end
function S.Record(transfer)
    local ok,err=ready(); if not ok then return nil,err end
    if not public(transfer) or type(transfer)~="table" or not public(transfer.id) then return nil,"Trade receipt is unavailable." end
    if not tree(transfer,0,{bytes=0,nodes=0},{}) then return nil,"Trade contents are unavailable or too large." end
    local existing=locate(transfer.id)
    if existing then return copy(existing) end
    if not reserved or transfer.id~=reserved then return nil,"This trade session is no longer current." end
    local before=IOU.GetLedger()
    local plan; plan,err=M.Plan(before,overview(),transfer)
    if not plan then return nil,err end
    local at=timestamp(); if not at then return nil,"The trade timestamp is unavailable." end
    local nextStore=copy(store); ok,err=makeRoom(nextStore); if not ok then return nil,err end
    local r={id=transfer.id,peer=transfer.peer,at=at,status="unmatched",service=transfer.service==true,
        incoming=copy(transfer.incoming),outgoing=copy(transfer.outgoing),applications={},
        pending=copy(plan.pending),unmatched=copy(plan.unmatched)}
    local draft; draft,err=ledgerDraft(); if not draft then return nil,err end
    local actions=plan.actions
    if IOU.GetSettings().autoTradeRepayments==false then actions={} end
    local problem
    for _,action in ipairs(actions) do
        ok,err=apply(draft,r,action,at); if not ok then problem=err; break end
    end
    if not problem and not C.Export(draft) then problem="This ledger has reached its storage limit." end
    if problem or actions~=plan.actions then
        draft,err=ledgerDraft(); if not draft then return nil,err end
        r.applications={}
        for _,action in ipairs(plan.actions) do
            r.pending[#r.pending+1]={asset=action.asset,direction=action.direction,amount=action.amount,
                label=action.label,itemID=action.itemID,itemKey=action.itemKey,
                reason=problem and "ledger_changed" or "automatic_off",
                candidates={{source="personal",entryID=action.entryID,balance=action.expectedBalance,label=action.label}}}
        end
    end
    r.status=status(r); nextStore.receipts[#nextStore.receipts+1]=r
    ok,err=S.Validate(nextStore); if not ok then return nil,err end
    return commit(before,draft,nextStore,r)
end
function S.Resolve(id,entryID,amount,pendingIndex)
    local ok,err=ready(); if not ok then return nil,err end
    local original=locate(id)
    if not original or original.status~="review" then return nil,"This trade no longer needs allocation." end
    if not integer(entryID,1,L.MAX_ENTRIES) then return nil,"Choose an IOU first." end
    local found,boundLabel
    for index,row in ipairs(original.pending) do
        if pendingIndex==nil or pendingIndex==index then
            for _,candidate in ipairs(row.candidates) do
                if candidate.source=="personal" and candidate.entryID==entryID then
                    if found then return nil,"Choose one transferred asset first." end
                    found,boundLabel=index,candidate.label
                end
            end
        end
    end
    if not found then return nil,"This IOU is no longer an allocation choice." end
    local before=IOU.GetLedger(); local entry=L.Get(before,entryID); local row=original.pending[found]
    if not entry or IOU.PlayerSummary.NameKey(entry.player)~=IOU.PlayerSummary.NameKey(original.peer)
        or entry.direction~=row.direction or entry.kind~=row.asset or L.Status(entry)=="cancelled" then
        return nil,"The IOU changed. Check its history before allocating this trade."
    end
    if entry.kind=="item" and entry.label~=boundLabel then return nil,"The item description changed. Review this IOU manually." end
    local balance=L.Balance(entry)
    local probeSide={money=0,items={}}
    if row.asset=="money" then probeSide.money=row.amount
    else
        for _,item in ipairs((row.direction=="owed" and original.incoming or original.outgoing).items) do
            if M.ItemKey(item.link)==row.itemKey then
                probeSide.items[1]=copy(item); probeSide.items[1].quantity=1; break
            end
        end
        if #probeSide.items==0 then return nil,"The traded item is unavailable. Review the IOU manually." end
    end
    local empty={money=0,items={}}
    local probe={peer=original.peer,outgoing=row.direction=="owe" and probeSide or empty,
        incoming=row.direction=="owed" and probeSide or empty}
    local currentPlan; currentPlan,err=M.Plan(before,overview(),probe)
    if not currentPlan then return nil,err end
    local stillMatches=false
    for _,action in ipairs(currentPlan.actions) do if action.entryID==entryID then stillMatches=true end end
    for _,pending in ipairs(currentPlan.pending) do
        for _,candidate in ipairs(pending.candidates) do
            if candidate.source=="personal" and candidate.entryID==entryID then stillMatches=true end
        end
    end
    if not stillMatches then return nil,"The IOU no longer matches this transferred item or gold." end
    -- Receipt conservation alone cannot establish what was already paid after
    -- an import or edited history. Bind earlier allocations to their exact
    -- ledger events before spending any remaining amount from this trade.
    local listed={}
    for _,application in ipairs(original.applications) do
        local key=application.entryID..":"..application.eventID
        if listed[key] then return nil,"An earlier repayment changed. Check its IOU history before allocating more." end
        listed[key]=true
        local appliedEntry=L.Get(before,application.entryID)
        local event=appliedEntry and appliedEntry.events[application.eventID]
        if not appliedEntry or not event or event.type~="payment" or event.amount~=application.amount
            or event.note~="Trade "..id or event.at~=application.at or appliedEntry.direction~=application.direction
            or IOU.PlayerSummary.NameKey(appliedEntry.player)~=IOU.PlayerSummary.NameKey(original.peer) then
            return nil,"An earlier repayment changed. Check its IOU history before allocating more."
        end
    end
    -- A sidecar edit could remove an application entirely and return its funds
    -- to pending. Search only on this explicit allocation path, never on hover
    -- or trade events, and refuse to spend funds already linked to this trade.
    for _,priorEntry in ipairs(before.entries) do
        for _,event in ipairs(priorEntry.events) do
            if event.type=="payment" and event.note=="Trade "..id
                and not listed[priorEntry.id..":"..event.id] then
                return nil,"An earlier repayment changed. Check its IOU history before allocating more."
            end
        end
    end
    amount=amount or math.min(row.amount,balance)
    if not integer(amount,1,math.min(row.amount,balance)) then return nil,"Enter an amount within the remaining trade and IOU balance." end
    local candidate=copy(store); local r=locate(id,candidate)
    local at=timestamp(); if not at then return nil,"The timestamp is unavailable." end
    local draft; draft,err=ledgerDraft(); if not draft then return nil,err end
    ok,err=apply(draft,r,{entryID=entryID,expectedBalance=balance,amount=amount,itemID=row.itemID,itemKey=row.itemKey},at)
    if not ok then return nil,err end
    if amount==r.pending[found].amount then table.remove(r.pending,found)
    else r.pending[found].amount=r.pending[found].amount-amount end
    r.status=status(r)
    ok,err=S.Validate(candidate); if not ok then return nil,err end
    return commit(before,draft,candidate,r)
end
local function dismissPending(r)
    for _,row in ipairs(r.pending) do
        local key=assetKey(row)
        local found
        for _,unmatched in ipairs(r.unmatched) do if assetKey(unmatched)==key then found=unmatched; break end end
        if found then found.amount=found.amount+row.amount
        else r.unmatched[#r.unmatched+1]={asset=row.asset,direction=row.direction,amount=row.amount,
            label=row.label,itemID=row.itemID,itemKey=row.itemKey} end
    end
    r.pending={}
end
function S.Undo(id)
    local ok,err=ready(); if not ok then return nil,err end
    local original=locate(id)
    if not original or #original.applications==0 then return nil,"This trade has no repayments to undo." end
    if original.status=="undone" then return copy(original) end
    local before=IOU.GetLedger(); local draft; draft,err=ledgerDraft(); if not draft then return nil,err end
    local at=timestamp(); if not at then return nil,"The timestamp is unavailable." end
    for _,a in ipairs(original.applications) do
        local entry=L.Get(draft,a.entryID); local event=entry and entry.events[a.eventID]
        if not entry or not event or event.type~="payment" or event.amount~=a.amount or event.note~="Trade "..id
            or event.at~=a.at or entry.direction~=a.direction
            or IOU.PlayerSummary.NameKey(entry.player)~=IOU.PlayerSummary.NameKey(original.peer) then
            return nil,"This repayment changed. Use the IOU history to review it."
        end
        local reversed=false
        for _,e in ipairs(entry.events) do if e.type=="reversal" and e.reverses==a.eventID then reversed=true end end
        if not reversed then
            local result; result,err=L.Reverse(draft,a.entryID,a.eventID,"Undo trade "..id,at)
            if not result then return nil,err end
        end
    end
    local candidate=copy(store); local r=locate(id,candidate)
    dismissPending(r)
    r.status,r.undoneAt="undone",at
    return commit(before,draft,candidate,r)
end
function S.Ignore(id)
    local ok,err=ready(); if not ok then return nil,err end
    local original=locate(id); if not original then return nil,"Trade not found." end
    if original.status=="undone" then return copy(original) end
    local candidate=copy(store); local r=locate(id,candidate)
    dismissPending(r); r.ignoredPending=true
    r.status=#r.applications>0 and "applied" or "ignored"
    return commit(IOU.GetLedger(),IOU.GetLedger(),candidate,r)
end
