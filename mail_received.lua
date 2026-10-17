local _, IOU = ...
local Observer = {}
IOU.MailReceived = Observer

-- The inbox exposes indices, not a stable message ID. Only a single observed
-- native collection, a MAIL_SUCCESS and an unambiguous inbox delta may repay an
-- IOU. We never infer collection from opening mail, bag changes or disappearing
-- mail alone, and never call or replace a collection function.
local enabled, attempted, frame, opened, pending
local submitted, rejected, quarantineUntil = 0, 0, 0
local status = "Waiting for collected player mail."
local MAX_MONEY, MAX_QUANTITY, TIMEOUT = 999999999000, 999999999, 8
local EVENTS = {"MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SUCCESS",
    "MAIL_FAILED", "MAIL_SEND_SUCCESS", "MAIL_OPEN_ALL_CANCELED", "UI_ERROR_MESSAGE", "PLAYER_LOGOUT"}

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function integer(value, low, high)
    return plain(value) and type(value)=="number" and value>=low and value<=high
        and value==math.floor(value)
end
local function text(value, maximum)
    return plain(value) and type(value)=="string" and #value<=maximum
        and not value:find("[%z\001-\031\127]")
end
local function clock()
    if type(GetTime)~="function" then return nil end
    local ok, now=pcall(GetTime)
    if ok and plain(now) and type(now)=="number" and now>=0 and now<math.huge then return now end
end
local function scalar(value)
    if not plain(value) then return nil end
    if value==nil then return "n" end
    if value==false then return "f" end
    if value==true then return "t" end
    if integer(value,0,9007199254740991) then return "d"..value end
    if text(value,512) then return "s"..#value..":"..value end
end
local function flag(value) return plain(value) and (value==true or value==1) end
local function noFlag(value) return plain(value) and (value==nil or value==false or value==0) end
local function part(value) return #value..":"..value end
local function itemKey(link)
    local matching=IOU.TradeMatching
    if type(matching)~="table" or type(matching.ItemKey)~="function" then return nil end
    local ok, key, id=pcall(matching.ItemKey,link)
    if ok and text(key,512) and integer(id,1,2147483647) then return key,id end
end
local function nameKey(name)
    local summary=IOU.PlayerSummary
    if not text(name,200) or name=="" or type(summary)~="table" or type(summary.NameKey)~="function" then return nil end
    local ok,key=pcall(summary.NameKey,name)
    if ok and text(key,200) and key~="" then return key end
end
local function readRow(index)
    local ok, package, stationery, sender, subject, money, cod, days, count, read,
        returned, created, reply, gm=pcall(GetInboxHeaderInfo,index)
    if not ok or not text(sender,200) or not text(subject,512)
        or not integer(money,0,MAX_MONEY) or not integer(cod,0,MAX_MONEY)
        or not plain(days) or type(days)~="number" or days<0 or days>=math.huge
        or not plain(count) or not (count==nil or integer(count,0,16)) then return nil end
    -- packageIcon changes when the final attachment is removed; stationery is
    -- stable. Neither mutable icon, read state nor rounded expiry is identity.
    local fields={sender,subject,scalar(stationery),scalar(returned),scalar(reply),scalar(gm)}
    for i=1,6 do if not fields[i] then return nil end end
    local key=""
    for i=1,6 do key=key..part(fields[i]) end
    local row={key=key,peer=sender,money=money,items={},totals={},assets={},eligible=false}
    local allValid, itemCount=true,0
    local fingerprint=part(key)..":"..money..":"..cod..":"..(count or 0)
    for slot=1,16 do
        local safe,name,id,texture,quantity,quality,usable,currency=pcall(GetInboxItem,index,slot)
        local linked,link=pcall(GetInboxItemLink,index,slot)
        if not safe or not linked then return nil end
        for _,value in ipairs({{name},{id},{quantity},{link},{currency}}) do
            if not plain(value[1]) then return nil end
        end
        if name~=nil or id~=nil or link~=nil or (quantity~=nil and quantity~=0) then
            itemCount=itemCount+1
            local a,b,c,d,e=scalar(name),scalar(id),scalar(quantity),scalar(link),scalar(currency)
            if not a or not b or not c or not d or not e then return nil end
            fingerprint=fingerprint.."/"..slot..part(a)..part(b)..part(c)..part(d)..part(e)
            local identity, linkedID=itemKey(link)
            if not identity or linkedID~=id or not text(name,200) or name==""
                or name:find("|") or not integer(quantity,1,MAX_QUANTITY) or not noFlag(currency) then
                allValid=false
            else
                local item={itemID=id,link=link,name=name,quantity=quantity,key=identity}
                row.items[slot]=item
                row.totals[identity]=(row.totals[identity] or 0)+quantity
                row.assets[identity]=item
            end
        end
    end
    row.fingerprint=fingerprint
    local invoiced,invoice=pcall(GetInboxInvoiceInfo,index)
    row.eligible=allValid and itemCount<=12 and itemCount==(count or 0)
        and cod==0 and noFlag(returned) and flag(reply) and noFlag(gm)
        and invoiced and plain(invoice) and invoice==nil and nameKey(sender)~=nil
    return row
end
local function inbox()
    local ok,count,total=pcall(GetInboxNumItems)
    -- An incomplete inbox can load or evict rows independently of a collection.
    if not ok or not integer(count,0,100) or not integer(total,0,100) or count~=total then return nil end
    local result={rows={},fingerprints={}}
    for index=1,count do
        local row=readRow(index)
        if not row then return nil end
        result.rows[index]=row
        result.fingerprints[row.fingerprint]=(result.fingerprints[row.fingerprint] or 0)+1
    end
    return result
end
local function clear(message, quarantine)
    if pending then rejected=math.min(rejected+1,9999) end
    pending=nil
    if quarantine then quarantineUntil=math.max(quarantineUntil,(clock() or 0)+TIMEOUT) end
    status=message
end
local function expire(now)
    if pending and now>=pending.expires then clear("Mail collection could not be confirmed.",true) end
end
local function others(snapshot,excluded)
    local counts={}
    for _,row in ipairs(snapshot.rows) do
        if row~=excluded then counts[row.fingerprint]=(counts[row.fingerprint] or 0)+1 end
    end
    return counts
end
local function equalMap(a,b)
    for key,value in pairs(a) do if b[key]~=value then return false end end
    for key,value in pairs(b) do if a[key]~=value then return false end end
    return true
end
local function assetDelta(command,current)
    local before=command.target
    if current and not current.eligible then return nil end
    local money=before.money-(current and current.money or 0)
    if money<0 or money>command.money then return nil end
    local value={money=money,items={}}
    for key,quantity in pairs(before.totals) do
        local removed=quantity-(current and current.totals[key] or 0)
        if removed<0 or removed>(command.items[key] or 0) or removed>MAX_QUANTITY then return nil end
        if removed>0 then
            local item=before.assets[key]
            value.items[#value.items+1]={itemID=item.itemID,link=item.link,name=item.name,quantity=removed}
        end
    end
    if current then
        for key in pairs(current.totals) do if not before.totals[key] then return nil end end
    end
    -- A deleted/returned message is not collection evidence; only the exact
    -- requested assets may disappear, with a matching successful native call.
    if not current then
        if command.money~=before.money then return nil end
        for key,quantity in pairs(before.totals) do if command.items[key]~=quantity then return nil end end
    end
    return value,current
end
local function delta(command,after)
    local unchanged=others(command.before,command.target)
    local found,foundCurrent,seen
    -- Same sender and subject are common. The selected original must have a
    -- unique full asset fingerprint, then exactly one distinct changed row (or
    -- its removal) must leave every other message's full fingerprint untouched.
    -- Several equivalent after rows represent the same proven multiset delta;
    -- several different possible after fingerprints remain ambiguous.
    local function candidate(current)
        if current and current.key~=command.key then return true end
        local value=assetDelta(command,current)
        if not value or not equalMap(unchanged,others(after,current)) then return true end
        local fingerprint=current and current.fingerprint or "removed"
        if seen and seen~=fingerprint then return false end
        seen,found,foundCurrent=fingerprint,value,current
        return true
    end
    for _,row in ipairs(after.rows) do if not candidate(row) then return nil end end
    if not candidate(nil) then return nil end
    return found,foundCurrent
end
local function finish()
    if not pending or not pending.success then return end
    local after=inbox()
    if not after then return end
    local value,current=delta(pending,after)
    if not value then clear("Inbox changed ambiguously; no repayment recorded.",true);return end
    if value.money==0 and #value.items==0 then return end
    local command=pending
    -- Consume the evidence before invoking the recorder: duplicate events or
    -- UI callback re-entry cannot apply a collection twice.
    command.success=false
    command.money=command.money-value.money
    for _,item in ipairs(value.items) do
        local key=itemKey(item.link)
        command.items[key]=command.items[key]-item.quantity
        if command.items[key]==0 then command.items[key]=nil end
    end
    command.before,command.target=after,current
    if not current or (command.money==0 and next(command.items)==nil)
        or after.fingerprints[current.fingerprint]~=1 then pending=nil end
    local service=IOU.TradeService
    if type(service)~="table" or type(service.NewSessionID)~="function" or type(service.Record)~="function" then
        clear("Mail recorder is unavailable.",true);return
    end
    local ok,id=pcall(service.NewSessionID,"mail_received")
    if not ok or not text(id,96) or id=="" then clear("Collected mail could not be reserved.",true);return end
    local transfer={id=id,medium="mail_received",peer=command.peer,
        outgoing={money=0,items={}},incoming=value}
    local safe,result=pcall(service.Record,transfer)
    if safe and result then
        submitted=math.min(submitted+1,9999)
        status="Collected player mail recorded."
    else
        rejected=math.min(rejected+1,9999)
        clear("Collected player mail could not be recorded.",true)
    end
end
local function collect(kind,index,slot)
    if not enabled or not opened then return end
    local now=clock()
    if not now then clear("Mail observation needs a readable client clock.",true);return end
    expire(now)
    if pending then clear("Overlapping mail operations were not recorded.",true);return end
    if now<quarantineUntil or not integer(index,1,100)
        or (kind=="item" and not integer(slot,1,16)) then return end
    local before=inbox()
    local row=before and before.rows[index]
    if not row or not row.eligible or before.fingerprints[row.fingerprint]~=1 then
        status="This mail cannot be attributed safely."
        return
    end
    local requested={}
    local amount=(kind=="money" or kind=="all") and row.money or 0
    if kind=="all" then for key,quantity in pairs(row.totals) do requested[key]=quantity end
    elseif kind=="item" then
        local item=row.items[slot]
        if not item then return end
        requested[item.key]=item.quantity
    end
    if amount==0 and next(requested)==nil then return end
    pending={key=row.key,peer=row.peer,before=before,target=row,money=amount,items=requested,
        expires=now+TIMEOUT,success=false}
    status="Waiting for mail collection confirmation."
end
local function competing()
    if enabled and pending then clear("Another mail operation interrupted collection tracking.",true) end
end
local function onEvent(_,event,arg)
    if not enabled or not plain(event) or type(event)~="string" then return end
    local now=clock()
    if not now then clear("Mail observation needs a readable client clock.",true);return end
    expire(now)
    if event=="MAIL_SHOW" then
        if pending then clear("Mailbox session changed during collection.",true) end
        opened=true;status="Watching player mail collection."
    elseif event=="MAIL_CLOSED" or event=="PLAYER_LOGOUT" then
        opened=false;clear("Mail observation stopped.",pending~=nil)
    elseif event=="MAIL_FAILED" or event=="MAIL_SEND_SUCCESS" or event=="UI_ERROR_MESSAGE"
        or event=="MAIL_OPEN_ALL_CANCELED" then
        if pending then clear("Mail operation interrupted; no uncertain repayment recorded.",true) end
    elseif event=="MAIL_SUCCESS" and pending then
        if not plain(arg) then clear("Mail success was unreadable.",true);return end
        if arg~=nil then
            if not integer(arg,1,2147483647) then clear("Mail success was unreadable.",true);return end
            local found=false
            local before=pending.target
            for key in pairs(pending.items) do
                if before.assets[key].itemID==arg then found=true end
            end
            if not found then clear("Mail success did not match the requested attachment.",true);return end
        end
        pending.success=true;finish()
    elseif event=="MAIL_INBOX_UPDATE" then finish() end
end
local function guarded(callback,...)
    local ok=pcall(callback,...)
    if not ok then
        -- Adapter faults must not escape a secure post-hook into the native
        -- mail UI. Drop uncertain evidence and wait for a fresh mailbox session.
        pending,opened=nil,false
        rejected=math.min(rejected+1,9999)
        status="Mail observation paused after an unavailable client response."
    end
end
function Observer.Initialize()
    if enabled then return true end
    -- Secure hooks cannot be removed. Never install duplicates after a partial
    -- registration failure; this session remains conservatively inactive.
    if attempted then return nil,status end
    attempted=true
    if type(CreateFrame)~="function" or type(hooksecurefunc)~="function" then
        status="Mail collection observation is unavailable.";return nil,status
    end
    for _,name in ipairs({"GetInboxNumItems","GetInboxHeaderInfo","GetInboxItem","GetInboxItemLink",
        "GetInboxInvoiceInfo","TakeInboxMoney","TakeInboxItem","AutoLootMailItem"}) do
        if type(_G[name])~="function" then status="Mail collection observation is unavailable.";return nil,status end
    end
    local ok,result=pcall(CreateFrame,"Frame")
    if not ok or not result then status="Mail events are unavailable.";return nil,status end
    frame=result
    local safe=pcall(function()
        for _,event in ipairs(EVENTS) do frame:RegisterEvent(event) end
        frame:SetScript("OnEvent",function(...) guarded(onEvent,...) end)
        hooksecurefunc("TakeInboxMoney",function(index) guarded(collect,"money",index) end)
        hooksecurefunc("TakeInboxItem",function(index,slot) guarded(collect,"item",index,slot) end)
        hooksecurefunc("AutoLootMailItem",function(index) guarded(collect,"all",index) end)
        for _,name in ipairs({"DeleteInboxItem","ReturnInboxItem","TakeInboxTextItem","CloseMail","SendMail"}) do
            if type(_G[name])=="function" then hooksecurefunc(name,function(...) guarded(competing,...) end) end
        end
    end)
    if not safe then
        if type(frame.UnregisterAllEvents)=="function" then pcall(frame.UnregisterAllEvents,frame) end
        status="Mail collection hooks are unavailable.";return nil,status
    end
    enabled=true
    return true
end
function Observer.Report()
    local now=clock();if now then expire(now) end
    return "IOU incoming mail observer\nStatus: "..status
        .."\nCollections submitted: "..submitted.."; uncertain operations: "..rejected
        .."\nRule: one native collection, MAIL_SUCCESS and an exact inbox asset delta."
        .."\nPlayer mail only; indistinguishable messages, COD, returns and invoices excluded."
end
