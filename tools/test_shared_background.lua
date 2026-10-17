-- Real logged-wire background sessions with isolated synthetic clients.
local results={}
local function test(name,run)
    local ok,err=pcall(run); if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,value in pairs(a) do if not same(value,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function reject(run)
    local value,err=run();assert(value==nil or value==false,"unsafe background action succeeded")
    assert(type(err)=="string" and #err>0,"missing rejection explanation")
end
local function simulation()
    local sim={now=100,clients={},packets={}}
    function sim:client(name,service,saved)
        local client={name=name,frames={},received={},sent={},key=name.."-Realm"}
        local env=setmetatable({IOUDB=saved or {version=1,characters={},settings={},recovery={}}},{__index=_G})
        client.env=env;env._G=env
        env.GetTime=function() return sim.now end;env.time=function() return math.floor(sim.now) end
        env.issecretvalue=function() return false end
        env.SendChatMessage=function() error("background used visible chat") end
        env.CreateFrame=function()
            local frame={events={},scripts={}}
            function frame:RegisterEvent(event) self.events[event]=true end
            function frame:SetScript(event,fn) self.scripts[event]=fn end
            client.frames[#client.frames+1]=frame;return frame
        end
        env.C_ChatInfo={RegisterAddonMessagePrefix=function() return 0 end,
            InChatMessagingLockdown=function() return false end,
            AreOutgoingAddonChatMessagesRestricted=function() return true end,
            SendAddonMessageLogged=function(prefix,packet,channel,target)
                local entry={prefix=prefix,packet=packet,channel=channel,target=target,sender=name,at=sim.now}
                client.sent[#client.sent+1]=entry;sim.packets[#sim.packets+1]=entry;return 0
            end}
        local ns={Initialize=function() return true end,Character=function() return client.key end,
            Transport={GetLocalName=function() return name end,CanonicalName=function(value)
                if type(value)~="string" or value=="" or #value>96 or value:find("[%z\001-\031\127|]") then return nil,"Invalid full name." end
                return value:gsub(" +"," "):match("^ *(.-) *$")
            end}}
        local files={"shared_codec.lua","shared_wire.lua"}
        if service then files={"shared_codec.lua","shared.lua","shared_payments.lua","shared_backup.lua","shared_wire.lua","shared_service.lua"} end
        for _,file in ipairs(files) do
            local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file));setfenv(chunk,env);chunk("IOU",ns)
        end
        client.ns,client.wire,client.service=ns,ns.SharedWire,ns.SharedService
        function client:background(callback)
            return self.wire.EnableBackground(callback or function(sender,message)
                self.received[#self.received+1]={sender=sender,message=message}
            end)
        end
        function client:event(packet)
            for _,frame in ipairs(self.frames) do if frame.events.CHAT_MSG_ADDON_LOGGED then
                frame.scripts.OnEvent(frame,"CHAT_MSG_ADDON_LOGGED",packet.prefix,packet.packet,packet.channel,packet.sender)
            end end
        end
        function client:drivers()
            local count=0;for _,frame in ipairs(self.frames) do if frame.scripts.OnUpdate then count=count+1 end end;return count
        end
        function client:packet(sender,packet)
            self:event({sender=sender,packet=packet,prefix=self.wire.PREFIX,channel="WHISPER"})
        end
        sim.clients[#sim.clients+1]=client;return client
    end
    function sim:step(seconds)
        for _=1,seconds do
            self.now=self.now+1
            for _,client in ipairs(self.clients) do client.wire.Tick() end
            local packets=self.packets;self.packets={}
            for _,packet in ipairs(packets) do for _,client in ipairs(self.clients) do
                if client.name==packet.target then client:event(packet) end
            end end
        end
    end
    return sim
end
local function message(client,target,id,note)
    id=id or "one"
    local C=client.ns.SharedCodec
    local terms=assert(C.CanonicalTerms({protocol=1,kind="GOLD_OBLIGATION",proposer=client.name,
        recipient=target,debtor=target,creditor=client.name,amountCopper=1000,dueUTC=0,note=note or ""}))
    return {version=1,kind="PROPOSE",messageId="m-"..id,agreementId="g-"..id,offerId="o-"..id,revision=1,terms=terms}
end
local function packets(client,target,id,note,frameID)
    return assert(client.wire.Frame(frameID or id,assert(client.ns.SharedCodec.Encode(message(client,target,id,note)))))
end
local function propose(a,b)
    return assert(a.service.Propose({peer=b.name,direction="owed",amountCopper=1000,note="test"}))
end

test("background logged wire communicates with several exact peers without selecting one",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale");local c=sim:client("Cedar Hill")
    assert(a:background() and b:background() and c:background())
    assert(a.wire.IsBackground() and a.wire.GetPeer()==nil and a:drivers()==0)
    assert(a.wire.Send({{target=b.name,message=message(a,b.name,"birch")},{target=c.name,message=message(a,c.name,"cedar")}}))
    assert(b.wire.Send({{target=a.name,message=message(b,a.name,"amber-b")}}))
    assert(c.wire.Send({{target=a.name,message=message(c,a.name,"amber-c")}}))
    sim:step(20)
    assert(#a.received==2 and #b.received==1 and #c.received==1)
    assert(a.received[1].sender~=a.received[2].sender)
    for _,packet in ipairs(a.sent) do assert(packet.channel=="WHISPER" and #packet.packet<=240) end
end)

test("same transfer IDs from different background peers have isolated assemblies",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale");local c=sim:client("Cedar Hill")
    assert(a:background())
    local left=packets(b,a.name,"left",string.rep("b",400),"same-id")
    local right=packets(c,a.name,"right",string.rep("c",400),"same-id")
    for index=1,math.max(#left,#right) do
        if left[index] then a:packet(b.name,left[index]) end
        if right[index] then a:packet(c.name,right[index]) end
    end
    assert(#a.received==2 and a.received[1].message.offerId=="o-left" and a.received[2].message.offerId=="o-right")
end)

test("one peer cannot poison another peer's same-ID transfer",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale");local c=sim:client("Cedar Hill")
    assert(a:background())
    local left=packets(b,a.name,"left",string.rep("b",400),"same-id")
    local conflict=packets(b,a.name,"other",string.rep("x",400),"same-id")
    local right=packets(c,a.name,"right",string.rep("c",400),"same-id")
    a:packet(b.name,left[1]);a:packet(b.name,conflict[1])
    for _,packet in ipairs(left) do a:packet(b.name,packet) end
    for _,packet in ipairs(right) do a:packet(c.name,packet) end
    assert(#a.received==1 and a.received[1].sender==c.name)
end)

test("background sender aliases cannot receive or send a request to the local player",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale")
    assert(a:background())
    local logical=packets(b,a.name,"self")
    for _,alias in ipairs({a.name,"AMBER STONE"}) do
        for _,packet in ipairs(logical) do a:packet(alias,packet) end
        assert(#a.received==0)
        reject(function() return a.wire.Send({{target=alias,message=message(a,b.name,"self-send")}}) end)
    end
    assert(a.wire.QueueSize()==0)
end)

test("background assemblies and buffered bytes stay within one global receive budget",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale");local c=sim:client("Cedar Hill")
    assert(a:background())
    local states={};local original=a.wire.Reassemble
    a.wire.Reassemble=function(state,...)
        states[state]=true
        local value,err=original(state,...)
        local active,bytes=0,0
        for store in pairs(states) do
            bytes=bytes+store.bytes
            for _,entry in pairs(store.entries) do if not entry.complete and not entry.conflict then active=active+1 end end
        end
        assert(active<=a.wire.MAX_ASSEMBLIES,"global active assembly budget exceeded")
        assert(bytes<=a.wire.MAX_BUFFER_BYTES,"global receive byte budget exceeded")
        return value,err
    end
    local frames={}
    for index=1,9 do
        local sender=index<=5 and b or c
        frames[index]={sender=sender.name,packets=packets(sender,a.name,"transfer-"..index,string.rep("x",400))}
        a:packet(sender.name,frames[index].packets[1])
    end
    for _,value in ipairs(frames) do for index=2,#value.packets do a:packet(value.sender,value.packets[index]) end end
    assert(#a.received==8)
end)

test("background rate limiting is shared across all peers and recovers without retries",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale");local c=sim:client("Cedar Hill")
    assert(a:background())
    local parsed=0;local original=a.wire.ParsePacket
    a.wire.ParsePacket=function(...) parsed=parsed+1;return original(...) end
    for index=1,500 do a:packet(index%2==0 and b.name or c.name,"invalid") end
    assert(parsed==120 and #a.received==0 and a.wire.GetStatus():find("rate limit",1,true))
    sim.now=sim.now+60
    for _,packet in ipairs(packets(c,a.name,"after-limit")) do a:packet(c.name,packet) end
    assert(#a.received==1)
end)

test("background wire disable removes queue assemblies and the idle driver",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale")
    assert(a:background())
    local framed=packets(b,a.name,"partial",string.rep("x",400));a:packet(b.name,framed[1])
    assert(a.wire.Send({{target=b.name,message=message(a,b.name,"outgoing")}}))
    assert(a:drivers()==1 and a.wire.QueueSize()==1)
    assert(a.wire.Disable() and a:drivers()==0 and a.wire.QueueSize()==0)
    sim:step(60);assert(#a.sent==0)
    assert(a:background() and a:drivers()==0)
    for index=2,#framed do a:packet(b.name,framed[index]) end
    assert(#a.received==0,"disabled partial transfer was retained")
end)

test("background driver sleeps after completed receives expire",function()
    local sim=simulation();local a=sim:client("Amber Stone");local b=sim:client("Birch Vale")
    assert(a:background() and a:drivers()==0)
    for _,packet in ipairs(packets(b,a.name,"complete")) do a:packet(b.name,packet) end
    assert(#a.received==1 and a:drivers()==1)
    sim:step(46);assert(a:drivers()==0)
end)

test("background selection switches preserve pending offers and queued consent",function()
    local sim=simulation();local a=sim:client("Amber Stone",true);local b=sim:client("Birch Vale",true);local c=sim:client("Cedar Hill",true)
    assert(a.service.EnableBackground() and b.service.EnableBackground() and c.service.EnableBackground())
    assert(a.service.SelectPeer(b.name));local first=propose(a,b)
    local original=copy(a.service.GetOffer(first.offerId))
    assert(a.service.SelectPeer(c.name));local second=propose(a,c)
    assert(a.service.GetOffer(first.offerId).state=="OFFER_OPEN" and a.wire.QueueSize()==2)
    assert(same(a.service.GetOffer(first.offerId),original))
    sim:step(15)
    assert(b.service.GetOffer(first.offerId).state=="OFFER_RECEIVED" and c.service.GetOffer(second.offerId).state=="OFFER_RECEIVED")
    assert(b.service.Accept(first.offerId) and c.service.Accept(second.offerId));sim:step(30)
    assert(a.service.GetBalance(first.offerId).confirmed and a.service.GetBalance(second.offerId).confirmed)
end)

test("background receives from other peers while a different player is selected",function()
    local sim=simulation();local a=sim:client("Amber Stone",true);local b=sim:client("Birch Vale",true);local c=sim:client("Cedar Hill",true)
    assert(a.service.EnableBackground() and b.service.EnableBackground() and c.service.EnableBackground())
    assert(a.service.SelectPeer(b.name));local offered=propose(c,a);sim:step(15)
    assert(a.service.GetPeer()==b.name and a.service.GetOffer(offered.offerId).state=="OFFER_RECEIVED")
    assert(a.service.Accept(offered.offerId));sim:step(20)
    assert(c.service.GetBalance(offered.offerId).confirmed)
end)

test("background exact resume keeps retained proposal consent and completes after restart",function()
    local sim=simulation();local a=sim:client("Amber Stone",true);local b=sim:client("Birch Vale",true)
    assert(a.service.EnableBackground() and b.service.EnableBackground())
    local offered=propose(a,b);local original=copy(a.service.GetOffer(offered.offerId))
    assert(a.service.Disable());assert(a.service.GetOffer(offered.offerId).state=="PAUSED")
    assert(a.service.EnableBackground());assert(a.service.Resume(offered.offerId))
    local resumed=a.service.GetOffer(offered.offerId)
    assert(resumed.state=="OFFER_OPEN" and same(resumed.messages,original.messages))
    sim:step(15);assert(b.service.Accept(offered.offerId));sim:step(20)
    assert(a.service.GetBalance(offered.offerId).confirmed)
end)

test("background recovery staging disables traffic and gates explicit resume",function()
    local sim=simulation();local a=sim:client("Amber Stone",true);local b=sim:client("Birch Vale",true)
    assert(a.service.EnableBackground());local offered=propose(a,b)
    local backup=assert(a.service.ExportBackup());local preview=assert(a.service.PreviewBackup(backup))
    local review=assert(a.service.StageRecovery(backup,preview.currentFingerprint))
    assert(a.service.IsRecoveryPending() and not a.service.IsEnabled() and a.wire.QueueSize()==0)
    local before=copy(a.env.IOUDB)
    reject(function() return a.service.EnableBackground() end)
    reject(function() return a.service.Resume(offered.offerId) end)
    assert(same(before,a.env.IOUDB) and #a.sent==0)
    assert(a.service.ResolveRecovery("keep",review.token));assert(a.service.EnableBackground())
    assert(a.service.Resume(offered.offerId))
end)

test("closed paused-offer tombstones prevent background resume and retain exact evidence",function()
    local sim=simulation();local a=sim:client("Amber Stone",true);local b=sim:client("Birch Vale",true)
    assert(a.service.EnableBackground());local offered=propose(a,b)
    assert(a.service.Disable());assert(a.service.ClosePaused(offered.offerId,"Closed"))
    local before=copy(a.service.GetOffer(offered.offerId))
    assert(a.service.EnableBackground())
    reject(function() return a.service.Resume(offered.offerId) end)
    assert(same(a.service.GetOffer(offered.offerId),before) and a.wire.QueueSize()==0 and #a.sent==0)
end)

return results
