local _, IOU = ...
local W = {PREFIX="IOU_SHAREDv1", VERSION=1, MAX_PACKET_BYTES=240, MAX_PARTS=32,
    MAX_LOGICAL_BYTES=4096, MAX_ASSEMBLIES=8, MAX_BUFFER_BYTES=32768,
    MAX_QUEUE_MESSAGES=32, MAX_QUEUE_PACKETS=128, TTL=45, PACE=1,
    MAX_RECEIVE_PACKETS=120, RECEIVE_WINDOW=60}
IOU.SharedWire = W
local MAX_ID, MAX_COMPLETED = 32, 8
local frame, enabled, peer, receiver, assembler, nonce = nil, false, nil, nil, nil, nil
local serial, lastSend, queue, lastError = 0, -1000000, {}, nil
local sent, unknown, received = 0, 0, 0
local receiveTokens,tokenAt,lastRateNotice=0,0,-1000000
local sendNames = {[1]="InvalidPrefix", [2]="InvalidMessage", [3]="AddonMessageThrottle",
    [4]="InvalidChatType", [5]="NotInGroup", [6]="TargetRequired", [7]="InvalidChannel",
    [8]="ChannelThrottle", [9]="GeneralError", [10]="NotInGuild", [11]="AddOnMessageLockdown", [12]="TargetOffline"}

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function integer(value, minimum, maximum)
    return plain(value) and type(value)=="number" and value==value and value>=minimum
        and value<=maximum and value==math.floor(value)
end
local function validID(value)
    return plain(value) and type(value)=="string" and #value>=1 and #value<=MAX_ID
        and value:match("^[A-Za-z0-9_-]+$")~=nil
end
local function asciiLower(value)
    return (value:gsub("[A-Z]",function(letter) return string.char(letter:byte()+32) end))
end
local function clock()
    if type(GetTime)~="function" then return nil end
    local ok, value=pcall(GetTime)
    if ok and plain(value) and type(value)=="number" and value==value and value>=0 and value<math.huge then return value end
end
local function changed()
    if type(IOU.OnSharedWireChanged)=="function" then pcall(IOU.OnSharedWireChanged) end
end
local function identity(value)
    local helper=IOU.Transport
    if type(helper)~="table" or type(helper.CanonicalName)~="function" then return nil end
    local ok, canonical=pcall(helper.CanonicalName,value)
    if ok and plain(value) and type(value)=="string" and canonical==value then return value end
end

-- Validate every scalar and return codepoint ends for safe, lossless slicing.
-- Logical codec strings contain printable UTF-8, with no chat escape pipes.
local function utf8Ends(value)
    if not plain(value) or type(value)~="string" or #value<1 or #value>W.MAX_LOGICAL_BYTES then return nil end
    local ends,index={},1
    while index<=#value do
        local byte=value:byte(index)
        local width,cp,minimum
        if byte<128 then width,cp,minimum=1,byte,0
        elseif byte>=194 and byte<=223 then width,cp,minimum=2,byte-192,128
        elseif byte>=224 and byte<=239 then width,cp,minimum=3,byte-224,2048
        elseif byte>=240 and byte<=244 then width,cp,minimum=4,byte-240,65536
        else return nil end
        if index+width-1>#value then return nil end
        for offset=1,width-1 do
            local continuation=value:byte(index+offset)
            if continuation<128 or continuation>191 then return nil end
            cp=cp*64+continuation-128
        end
        if cp<minimum or cp>1114111 or (cp>=55296 and cp<=57343) or cp<32
            or (cp>=127 and cp<=159) or cp==124 then return nil end
        index=index+width
        ends[#ends+1]=index-1
    end
    return ends
end

local function header(id,part,count,total)
    return "SW1 "..id.." "..string.format("%02d/%02d",part,count).." "..total..":"
end

function W.Frame(id,logical)
    if not validID(id) then return nil,"Invalid shared transfer identifier." end
    local ends=utf8Ends(logical)
    if not ends then return nil,"Shared payload must be printable UTF-8 within 4096 bytes." end
    local capacity=W.MAX_PACKET_BYTES-#header(id,1,1,#logical)
    local chunks,start,last={},1,0
    for _,finish in ipairs(ends) do
        if finish-start+1>capacity then
            if last<start then return nil,"Shared packet header leaves no payload space." end
            chunks[#chunks+1]=logical:sub(start,last)
            start=last+1
        end
        last=finish
    end
    chunks[#chunks+1]=logical:sub(start)
    if #chunks>W.MAX_PARTS then return nil,"Shared logical message needs too many packets." end
    local packets={}
    for index,chunk in ipairs(chunks) do packets[index]=header(id,index,#chunks,#logical)..chunk end
    return packets
end

function W.ParsePacket(packet)
    if not plain(packet) or type(packet)~="string" or #packet>W.MAX_PACKET_BYTES then return nil,"Invalid shared packet size." end
    local id,part,count,total,body=packet:match("^SW1 ([A-Za-z0-9_-]+) (%d%d)/(%d%d) (%d+):(.*)$")
    if not validID(id) or not total or #total>4 or (total~="0" and not total:match("^[1-9][0-9]*$")) then
        return nil,"Invalid shared packet header."
    end
    part,count,total=tonumber(part),tonumber(count),tonumber(total)
    if not integer(count,1,W.MAX_PARTS) or not integer(part,1,count) or not integer(total,1,W.MAX_LOGICAL_BYTES)
        or not utf8Ends(body) or #body>total then return nil,"Invalid shared packet fields or UTF-8 boundary." end
    if header(id,part,count,total)..body~=packet then return nil,"Noncanonical shared packet." end
    return {id=id,part=part,count=count,total=total,body=body}
end

function W.NewAssembler(expectedPeer)
    if not plain(expectedPeer) or type(expectedPeer)~="string" or #expectedPeer<1 or #expectedPeer>96 then return nil,"Invalid assembler peer." end
    return {peer=expectedPeer,entries={},bytes=0}
end
local function removeEntry(state,id)
    local entry=state.entries[id]
    if entry then state.bytes=state.bytes-entry.bytes; state.entries[id]=nil end
end
function W.Expire(state,now)
    if type(state)~="table" or type(state.entries)~="table" or type(now)~="number" or now~=now or now<0 or now>=math.huge then return nil,"Invalid assembler state or clock." end
    for id,entry in pairs(state.entries) do if now-entry.started>=W.TTL then removeEntry(state,id) end end
    return true
end
local function counts(state)
    local active,complete=0,0
    for _,entry in pairs(state.entries) do
        if entry.complete or entry.conflict then complete=complete+1 else active=active+1 end
    end
    return active,complete
end
local function evictCompleted(state,bytesNeeded)
    local _,complete=counts(state)
    while complete>=MAX_COMPLETED or state.bytes+bytesNeeded>W.MAX_BUFFER_BYTES do
        local oldestId,oldest
        for id,entry in pairs(state.entries) do
            if (entry.complete or entry.conflict) and (not oldest or entry.started<oldest) then oldestId,oldest=id,entry.started end
        end
        if not oldestId then break end
        removeEntry(state,oldestId); complete=complete-1
    end
end
local function poison(state,entry)
    state.bytes=state.bytes-entry.bytes
    entry.parts,entry.bytes,entry.conflict={},0,true
end
function W.Reassemble(state,sender,packet,now)
    if type(state)~="table" or type(state.entries)~="table" or type(state.bytes)~="number"
        or not plain(sender) or sender~=state.peer or type(now)~="number" or now~=now or now<0 or now>=math.huge then
        return nil,"Invalid shared sender or assembler state."
    end
    W.Expire(state,now)
    local parsed,err=W.ParsePacket(packet)
    if not parsed then return nil,err end
    local entry=state.entries[parsed.id]
    if entry then
        if entry.conflict then return nil,"Conflicting shared transfer is blocked until expiry." end
        if entry.count~=parsed.count or entry.total~=parsed.total then poison(state,entry); return nil,"Shared transfer metadata conflict." end
        local previous=entry.parts[parsed.part]
        if previous then
            if previous~=parsed.body then poison(state,entry); return nil,"Shared packet content conflict." end
            return nil,"Duplicate shared packet."
        end
    else
        local active=counts(state)
        if active>=W.MAX_ASSEMBLIES then return nil,"Shared receive capacity reached." end
        evictCompleted(state,#parsed.body)
        if state.bytes+#parsed.body>W.MAX_BUFFER_BYTES then return nil,"Shared receive byte limit reached." end
        entry={count=parsed.count,total=parsed.total,parts={},bytes=0,seen=0,started=now}
        state.entries[parsed.id]=entry
    end
    if entry.bytes+#parsed.body>entry.total then poison(state,entry); return nil,"Shared transfer exceeds its declared size." end
    evictCompleted(state,#parsed.body)
    if state.bytes+#parsed.body>W.MAX_BUFFER_BYTES then poison(state,entry); return nil,"Shared receive byte limit reached." end
    entry.parts[parsed.part],entry.bytes,entry.seen=parsed.body,entry.bytes+#parsed.body,entry.seen+1
    state.bytes=state.bytes+#parsed.body
    if entry.seen~=entry.count then return nil end
    if entry.bytes~=entry.total then poison(state,entry); return nil,"Shared transfer has an incorrect final size." end
    local logical=table.concat(entry.parts)
    entry.complete=true
    return logical
end

local function restriction()
    if type(C_ChatInfo)~="table" or type(C_ChatInfo.RegisterAddonMessagePrefix)~="function"
        or type(C_ChatInfo.SendAddonMessageLogged)~="function" then return "Logged addon whispers are unavailable." end
    for _,name in ipairs({"AreOutgoingAddonChatMessagesRestricted","InChatMessagingLockdown"}) do
        if type(C_ChatInfo[name])=="function" then
            local ok,blocked=pcall(C_ChatInfo[name])
            if not ok or not plain(blocked) or type(blocked)~="boolean" then return "Client chat restriction check failed." end
            if blocked then return "Client chat restriction: "..name.."." end
        end
    end
end
local function queuedPackets()
    local count=0
    for _,item in ipairs(queue) do count=count+#item.packets-item.index+1 end
    return count
end
local function needsDriver()
    return enabled and (#queue>0 or (assembler and next(assembler.entries)~=nil))
end
local function driver()
    if frame then frame:SetScript("OnUpdate",needsDriver() and function() W.Tick() end or nil) end
end
local function stopForClock()
    enabled,peer,receiver,assembler,nonce=false,nil,nil,nil,nil
    queue={}
    lastError="Shared monotonic clock is unavailable. Communication stopped; reconnect and use Retry."
    driver(); changed()
end

local function incoming(_,event,prefix,packet,channel,sender)
    if not enabled or event~="CHAT_MSG_ADDON_LOGGED" or not plain(prefix) or prefix~=W.PREFIX
        or not plain(channel) or channel~="WHISPER" or not identity(sender) or sender~=peer then return end
    local now=clock()
    if not now then stopForClock(); return end
    receiveTokens=math.min(W.MAX_RECEIVE_PACKETS,receiveTokens+math.max(0,now-tokenAt)
        *W.MAX_RECEIVE_PACKETS/W.RECEIVE_WINDOW)
    tokenAt=now
    if receiveTokens<1 then
        if now-lastRateNotice>=W.RECEIVE_WINDOW then
            lastRateNotice=now
            lastError="Shared receive rate limit reached (120-packet burst, two per second sustained). Wait before retrying."
            changed()
        end
        return
    end
    receiveTokens=receiveTokens-1
    local logical,err=W.Reassemble(assembler,sender,packet,now)
    driver()
    if not logical then return end
    local codec=IOU.SharedCodec
    local message,problem=codec.Decode(logical)
    if not message then lastError="Rejected invalid shared message: "..tostring(problem); changed(); return end
    received=received+1
    local ok=pcall(receiver,sender,message)
    if not ok then lastError="Shared receiver callback failed; inspect the agreement before retrying." end
    changed()
end

function W.Disable()
    enabled,peer,receiver,assembler,nonce=false,nil,nil,nil,nil
    queue={}
    lastError=nil
    driver(); changed()
    return true
end
function W.IsEnabled() return enabled end
function W.GetPeer() return peer end
function W.Enable(expectedPeer,onReceive)
    if type(onReceive)~="function" then return nil,"A shared message receiver is required." end
    if not identity(expectedPeer) then return nil,"Use the player's exact full name with single spaces." end
    local helper=IOU.Transport
    if type(helper)~="table" or type(helper.GetLocalName)~="function" then return nil,"Local player identity is unavailable." end
    local ok,own=pcall(helper.GetLocalName)
    if not ok or not identity(own) then return nil,"Local player identity is unavailable." end
    if asciiLower(own)==asciiLower(expectedPeer) then return nil,"Choose another player; shared agreements require two clients." end
    if type(IOU.SharedCodec)~="table" or type(IOU.SharedCodec.Encode)~="function" or type(IOU.SharedCodec.Decode)~="function" then return nil,"Shared message codec is unavailable." end
    local problem=restriction()
    if problem then return nil,problem end
    local now=clock()
    if not now then return nil,"Client monotonic clock is unavailable." end
    local registered,result=pcall(C_ChatInfo.RegisterAddonMessagePrefix,W.PREFIX)
    if not registered or not plain(result) or type(result)~="number" or (result~=0 and result~=1) then return nil,"Could not register shared addon prefix." end
    if not frame then
        if type(CreateFrame)~="function" then return nil,"Client event system is unavailable." end
        local created,newFrame=pcall(CreateFrame,"Frame")
        if not created or not newFrame then return nil,"Could not create shared event frame." end
        frame=newFrame
        local bound=pcall(function() frame:RegisterEvent("CHAT_MSG_ADDON_LOGGED"); frame:SetScript("OnEvent",incoming) end)
        if not bound then frame=nil; return nil,"Client logged addon event is unavailable." end
    end
    enabled,peer,receiver=true,expectedPeer,onReceive
    assembler=W.NewAssembler(peer)
    nonce=string.format("%x-%x",math.floor((now%2147483647)*1000)%2147483647,math.random(0,16777215))
    serial,queue,lastError,sent,unknown,received=0,{},nil,0,0,0
    receiveTokens,tokenAt,lastRateNotice=W.MAX_RECEIVE_PACKETS,now,-1000000
    driver(); changed()
    return true
end

local function stage(actions)
    if not enabled then return nil,"Enable shared communication with this player first." end
    if type(actions)~="table" or getmetatable(actions)~=nil then return nil,"Invalid shared action list." end
    local count=0
    for index in pairs(actions) do
        if not integer(index,1,W.MAX_QUEUE_MESSAGES) then return nil,"Invalid shared action index." end
        count=count+1
    end
    if count~=#actions or #queue+count>W.MAX_QUEUE_MESSAGES then return nil,"Shared message queue is full or not a dense list." end
    local staged,packets,nextSerial={},queuedPackets(),serial
    for _,action in ipairs(actions) do
        if type(action)~="table" or getmetatable(action)~=nil then return nil,"Invalid shared action." end
        local fields=0
        for field in pairs(action) do if field~="target" and field~="message" then return nil,"Unknown shared action field." end; fields=fields+1 end
        if fields~=2 or not identity(action.target) or action.target~=peer then return nil,"Shared action target is not the enabled peer." end
        local logical,err=IOU.SharedCodec.Encode(action.message)
        if not logical then return nil,err end
        if nextSerial>=2147483647 then return nil,"Shared transfer identifier capacity reached." end
        nextSerial=nextSerial+1
        local framed
        framed,err=W.Frame(nonce.."-"..string.format("%x",nextSerial),logical)
        if not framed then return nil,err end
        packets=packets+#framed
        if packets>W.MAX_QUEUE_PACKETS then return nil,"Shared packet queue is full; wait before retrying." end
        staged[#staged+1]={target=peer,packets=framed,index=1}
    end
    return staged,nextSerial
end
function W.CanQueue(actions)
    local staged,err=stage(actions)
    if not staged then return nil,err end
    return true
end
function W.Send(actions)
    local staged,nextSerial=stage(actions)
    if not staged then return nil,nextSerial end
    for _,item in ipairs(staged) do queue[#queue+1]=item end
    serial=nextSerial
    lastError=nil
    driver(); changed()
    return true
end
function W.Tick()
    if not enabled then return end
    local now=clock()
    if not now then stopForClock(); return end
    W.Expire(assembler,now)
    if #queue>0 and now-lastSend>=W.PACE then
        local problem=restriction()
        if problem then queue={}; lastError=problem.." Pending sends stopped; use Retry."; driver(); changed(); return end
        local item=queue[1]
        lastSend=now
        local ok,result=pcall(C_ChatInfo.SendAddonMessageLogged,W.PREFIX,item.packets[item.index],"WHISPER",item.target)
        if not ok or not plain(result) or (result~=nil and (type(result)~="number" or result~=0)) then
            queue={}; lastError="Shared send failed: "..(ok and plain(result) and (sendNames[result] or "unsupported API result") or "client API error")..". Record retained; use Retry."
        else
            if result==nil then unknown=unknown+1 else sent=sent+1 end
            item.index=item.index+1
            if item.index>#item.packets then table.remove(queue,1) end
        end
        changed()
    end
    driver()
end
function W.GetStatus()
    if lastError then return lastError end
    if not enabled then return "Shared communication is off." end
    return "Shared peer: "..peer..". "..#queue.." messages / "..queuedPackets().." packets queued; "
        ..sent.." packets submitted, "..unknown.." unknown API results, "..received.." messages received. Submission is not peer confirmation."
end
