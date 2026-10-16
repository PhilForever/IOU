-- Framing and isolated two-client logged-WHISPER checks. No native client API
-- or saved data is used by this harness.
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(actual,expected)
    assert(actual==expected,"expected "..tostring(expected)..", got "..tostring(actual))
end
local function reject(run)
    local value,err=run()
    assert(value==nil or value==false,"unexpected success")
    assert(type(err)=="string" and #err>0,"rejection needs a readable error")
end
local function namespace(env)
    local ns={}
    for _,name in ipairs({"shared_codec.lua","shared_wire.lua"}) do
        local chunk=assert(loadstring(assert(IOU_SOURCES[name]),"@IOU/"..name))
        setfenv(chunk,env or _G); chunk("IOU",ns)
    end
    return ns
end
local pure=namespace()
local W,C=pure.SharedWire,pure.SharedCodec
local function message(note)
    local terms=assert(C.CanonicalTerms({protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",
        recipient="Birch Vale",debtor="Birch Vale",creditor="Amber Stone",amountCopper=12345,dueUTC=0,note=note or ""}))
    return {version=1,kind="PROPOSE",messageId="m1",agreementId="g1",offerId="o1",revision=1,terms=terms}
end
local function entryCount(state)
    local count=0
    for _ in pairs(state.entries) do count=count+1 end
    return count
end
local function simulation()
    local sim={now=100,clients={},packets={}}
    function sim:client(name,options)
        options=options or {}
        local client={name=name,frames={},sent={},received={},result=0}
        local saved={marker="personal ledger left alone"}
        local env=setmetatable({IOUDB=saved},{__index=_G})
        client.env=env
        env._G=env
        env.GetTime=function() if not sim.noClock then return sim.now end end
        env.issecretvalue=function(value) return options.secret~=nil and value==options.secret end
        env.SendChatMessage=function() error("normal whispers forbidden") end
        env.CreateFrame=function()
            local frame={scripts={},events={}}
            function frame:RegisterEvent(event) self.events[event]=true end
            function frame:SetScript(event,fn) self.scripts[event]=fn end
            client.frames[#client.frames+1]=frame
            return frame
        end
        env.C_ChatInfo={
            RegisterAddonMessagePrefix=function(prefix)
                client.prefix=prefix
                if options.registration~=nil then return options.registration end
                return 0
            end,
            SendAddonMessageLogged=function(prefix,packet,channel,target)
                if options.throws then error("mock failure") end
                local outgoing={prefix=prefix,packet=packet,channel=channel,target=target,sender=name,at=sim.now}
                client.sent[#client.sent+1]=outgoing
                sim.packets[#sim.packets+1]=outgoing
                if options.nilResult then return nil end
                return client.result
            end,
            AreOutgoingAddonChatMessagesRestricted=function() return options.restricted or false end,
            InChatMessagingLockdown=function() return options.lockdown or false end,
            SendAddonMessage=function() error("unlogged fallback forbidden") end,
        }
        if options.noLogged then env.C_ChatInfo.SendAddonMessageLogged=nil end
        client.ns=namespace(env)
        client.ns.Transport={
            CanonicalName=function(value)
                if type(value)~="string" or #value<1 or #value>96 or value:find("[%z\001-\031\127|]") then return nil,"invalid name" end
                return value:gsub(" +"," "):match("^ *(.-) *$")
            end,
            GetLocalName=function() if not options.noIdentity then return name end end,
        }
        client.wire=client.ns.SharedWire
        client.ns.OnSharedWireChanged=options.changed
        function client:enable(peer,callback)
            return self.wire.Enable(peer,callback or function(sender,incoming)
                self.received[#self.received+1]={sender=sender,message=incoming}
            end)
        end
        function client:event(packet,overrides)
            overrides=overrides or {}
            for _,frame in ipairs(self.frames) do
                if frame.events.CHAT_MSG_ADDON_LOGGED and frame.scripts.OnEvent then
                    frame.scripts.OnEvent(frame,"CHAT_MSG_ADDON_LOGGED",overrides.prefix or packet.prefix,
                        overrides.packet or packet.packet,overrides.channel or packet.channel,
                        overrides.sender or packet.sender)
                end
            end
        end
        function client:drivers()
            local count=0
            for _,frame in ipairs(self.frames) do if frame.scripts.OnUpdate then count=count+1 end end
            return count
        end
        function client:untouched() equal(env.IOUDB,saved); equal(saved.marker,"personal ledger left alone") end
        sim.clients[#sim.clients+1]=client
        return client
    end
    function sim:step(seconds,deliver)
        for _=1,seconds do
            sim.now=sim.now+1
            for _,client in ipairs(sim.clients) do client.wire.Tick() end
            local pending=sim.packets; sim.packets={}
            if deliver~=false then
                for _,packet in ipairs(pending) do
                    for _,client in ipairs(sim.clients) do if client.name==packet.target then client:event(packet) end end
                end
            end
        end
    end
    return sim
end

test("shared wire preserves exact printable UTF-8 within every complete 240-byte packet",function()
    for _,logical in ipairs({"a",string.rep("x",4096),string.rep("\240\159\144\137",1024),assert(C.Encode(message(string.rep("\195\184",256))))}) do
        for _,id in ipairs({"x",string.rep("z",32)}) do
            local packets=assert(W.Frame(id,logical)); assert(#packets<=32)
            local state=assert(W.NewAssembler("Amber Stone"))
            local completed
            for index=#packets,1,-1 do
                assert(#packets[index]<=240)
                local parsed=assert(W.ParsePacket(packets[index]))
                equal(parsed.part,index); equal(parsed.count,#packets); equal(parsed.total,#logical)
                completed=W.Reassemble(state,"Amber Stone",packets[index],100) or completed
            end
            equal(completed,logical)
            assert(state.bytes<=W.MAX_BUFFER_BYTES)
        end
    end
end)

test("shared wire rejects malformed frames and invalid UTF-8 without truncating",function()
    for _,bad in ipairs({"",string.rep("x",4097),"a|b","a\n","\192\175","\237\160\128","\244\144\128\128","\195"}) do
        reject(function() return W.Frame("t",bad) end)
    end
    for _,badId in ipairs({"",string.rep("x",33),"a b","a:b","../x"}) do reject(function() return W.Frame(badId,"text") end) end
    local good=assert(W.Frame("t","text"))[1]
    for _,packet in ipairs({good..string.rep("x",240),"SW1 t 00/01 4:text","SW1 t 01/33 4:text",
        "SW1 t 02/01 4:text","SW1 t 01/01 04:text","SW1 t 01/01 0:","SW1 t 01/01 1:\195"}) do
        reject(function() return W.ParsePacket(packet) end)
    end
end)

test("shared reassembly ignores identical duplicates and poisons conflicting content and metadata",function()
    local packets=assert(W.Frame("dup",string.rep("x",400)))
    local state=assert(W.NewAssembler("Amber Stone"))
    equal(W.Reassemble(state,"Amber Stone",packets[1],100),nil)
    reject(function() return W.Reassemble(state,"Amber Stone",packets[1],101) end)
    local changed=packets[1]:sub(1,-2).."z"
    reject(function() return W.Reassemble(state,"Amber Stone",changed,102) end)
    reject(function() return W.Reassemble(state,"Amber Stone",packets[2],103) end)
    equal(state.bytes,0)
    assert(W.Expire(state,146)); equal(entryCount(state),0)
    reject(function() return W.Reassemble(state,"Someone Else",packets[1],147) end)
    local other=assert(W.Frame("meta",string.rep("x",400)))
    W.Reassemble(state,"Amber Stone",other[1],147)
    local conflict=other[2]:gsub("/03 ","/04 ")
    if conflict==other[2] then conflict=other[2]:gsub("/02 ","/03 ") end
    reject(function() return W.Reassemble(state,"Amber Stone",conflict,148) end)
end)

test("shared receive buffers expire from first packet and remain bounded under ID floods",function()
    local state=assert(W.NewAssembler("Amber Stone"))
    for index=1,8 do W.Reassemble(state,"Amber Stone",assert(W.Frame("f"..index,string.rep("x",4096)))[1],100) end
    equal(entryCount(state),8)
    reject(function() return W.Reassemble(state,"Amber Stone",assert(W.Frame("f9",string.rep("x",4096)))[1],101) end)
    assert(state.bytes<=32768)
    W.Expire(state,145); equal(entryCount(state),0); equal(state.bytes,0)
    for index=1,40 do
        local packets=assert(W.Frame("done"..index,string.rep("x",4096)))
        for _,packet in ipairs(packets) do W.Reassemble(state,"Amber Stone",packet,200) end
        assert(entryCount(state)<=8); assert(state.bytes<=32768)
    end
    W.Expire(state,245); equal(entryCount(state),0); equal(state.bytes,0)
end)

test("shared wire has no startup traffic and requires exact peer opt-in and local identity",function()
    local sim=simulation(); local a=sim:client("Amber Stone")
    equal(#a.frames,0); equal(#a.sent,0); equal(a.wire.IsEnabled(),false)
    reject(function() return a.wire.Send({}) end)
    reject(function() return a:enable("Amber Stone") end)
    reject(function() return a:enable("amber stone") end)
    reject(function() return a:enable(" Birch Vale ") end)
    reject(function() return sim:client("Amber Stone",{noIdentity=true}):enable("Birch Vale") end)
    assert(a:enable("Birch Vale")); equal(#a.sent,0); equal(a:drivers(),0)
    a:untouched()
end)

test("shared send preflight is atomic enqueue-only and logged packets deliver exact authoritative sender",function()
    local sim=simulation(); local a,b=sim:client("Amber Stone"),sim:client("Birch Vale")
    assert(a:enable("Birch Vale")); assert(b:enable("Amber Stone"))
    local actions={{target="Birch Vale",message=message("Bjørn blåbær")}}
    for _=1,3 do assert(a.wire.CanQueue(actions)) end
    equal(#a.sent,0); equal(a:drivers(),0)
    assert(a.wire.Send(actions)); equal(#a.sent,0); equal(#b.received,0)
    actions[1].message.terms="tampered after enqueue"
    sim:step(10)
    equal(#b.received,1); equal(b.received[1].sender,"Amber Stone")
    equal(assert(C.ParseTerms(b.received[1].message.terms)).note,"Bjørn blåbær")
    for index,packet in ipairs(a.sent) do
        equal(packet.prefix,"IOU_SHAREDv1"); equal(packet.channel,"WHISPER"); equal(packet.target,"Birch Vale")
        assert(#packet.packet<=240)
        if index>1 then assert(packet.at-a.sent[index-1].at>=1) end
    end
    assert(a.wire.GetStatus():find("Submission is not peer confirmation",1,true))
    a:untouched(); b:untouched()
end)

test("shared packet queues reject whole batches without partial enqueue",function()
    local sim=simulation(); local a=sim:client("Amber Stone"); assert(a:enable("Birch Vale"))
    local batch={}
    for index=1,32 do
        local large=message(string.rep("x",512))
        large.messageId,large.agreementId,large.offerId=string.rep("m",64),string.rep("g",64),string.rep("o",64)
        batch[index]={target="Birch Vale",message=large}
    end
    reject(function() return a.wire.CanQueue(batch) end)
    reject(function() return a.wire.Send(batch) end)
    equal(#a.sent,0); equal(a:drivers(),0)
    reject(function() return a.wire.Send({{target="Birch Vale",message=message()},{target="Other Peer",message=message()}}) end)
    equal(a:drivers(),0)
    local short={}
    for index=1,32 do short[index]={target="Birch Vale",message=message()} end
    assert(a.wire.Send(short))
    reject(function() return a.wire.Send({{target="Birch Vale",message=message()}}) end)
end)

test("shared transport filters channels prefixes senders and stops all work on disable",function()
    local sim=simulation(); local b=sim:client("Birch Vale"); assert(b:enable("Amber Stone"))
    local packets=assert(W.Frame("filtered",assert(C.Encode(message()))))
    for _,override in ipairs({{prefix="IOU_LINKv1"},{channel="PARTY"},{sender="Other Peer"},{sender="amber stone"}}) do
        for _,packet in ipairs(packets) do b:event({prefix=W.PREFIX,packet=packet,channel="WHISPER",sender="Amber Stone"},override) end
    end
    equal(#b.received,0)
    for _,packet in ipairs(packets) do b:event({prefix=W.PREFIX,packet=packet,channel="WHISPER",sender="Amber Stone"}) end
    equal(#b.received,1)
    for _,packet in ipairs(packets) do b:event({prefix=W.PREFIX,packet=packet,channel="WHISPER",sender="Amber Stone"}) end
    equal(#b.received,1)
    assert(b.wire.Send({{target="Amber Stone",message=message()}}))
    b.wire.Disable(); equal(b:drivers(),0); sim:step(50); equal(#b.sent,0)
    for _,packet in ipairs(packets) do b:event({prefix=W.PREFIX,packet=packet,channel="WHISPER",sender="Amber Stone"}) end
    equal(#b.received,1)
end)

test("shared transport fails safely for native registration and all nonzero send enum results",function()
    for _,registration in ipairs({2,3,true,false}) do
        local sim=simulation(); local a=sim:client("Amber Stone",{registration=registration})
        reject(function() return a:enable("Birch Vale") end)
    end
    for _,options in ipairs({{noLogged=true},{lockdown=true}}) do
        local sim=simulation(); reject(function() return sim:client("Amber Stone",options):enable("Birch Vale") end)
    end
    for _,code in ipairs({1,2,3,4,5,6,7,8,9,10,11,12,13,true,false}) do
        local sim=simulation(); local a=sim:client("Amber Stone"); assert(a:enable("Birch Vale")); a.result=code
        assert(a.wire.Send({{target="Birch Vale",message=message()}})); sim:step(10,false)
        equal(#a.sent,1); equal(a:drivers(),0)
        assert(a.wire.GetStatus():find("Record retained; use Retry",1,true))
    end
    local sim=simulation(); local a=sim:client("Amber Stone",{throws=true}); assert(a:enable("Birch Vale"))
    assert(a.wire.Send({{target="Birch Vale",message=message()}})); sim:step(5); equal(a:drivers(),0)
end)

test("shared logged whispers deliver exact terms despite the general addon restriction flag",function()
    local sim=simulation()
    local a=sim:client("Amber Stone",{restricted=true})
    local b=sim:client("Birch Vale",{restricted=true})
    assert(a:enable(b.name)); assert(b:enable(a.name))
    local outgoing=message("Bjørn blåbær")
    assert(a.wire.Send({{target=b.name,message=outgoing}}))
    sim:step(10)
    equal(#b.received,1); equal(b.received[1].sender,a.name)
    equal(assert(C.Encode(b.received[1].message)),assert(C.Encode(outgoing)))
    for _,packet in ipairs(a.sent) do
        equal(packet.prefix,W.PREFIX); equal(packet.channel,"WHISPER"); equal(packet.target,b.name)
    end
    a:untouched(); b:untouched()
end)

test("shared unknown general restriction observations do not replace logged native send results",function()
    local secret={}
    for _,query in ipairs({function() return nil end, function() return "unknown" end,
        function() error("general restriction API exception") end, function() return secret end, false}) do
        local sim=simulation(); local a=sim:client("Amber Stone",{secret=secret})
        local b=sim:client("Birch Vale")
        a.env.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted=query or nil
        if query==false then a.env.C_ChatInfo.InChatMessagingLockdown=nil end
        assert(a:enable(b.name)); assert(b:enable(a.name))
        assert(a.wire.Send({{target=b.name,message=message()}}))
        sim:step(10); equal(#b.received,1)
        a:untouched(); b:untouched()
    end
end)

test("shared true or unreadable lockdown blocks enable and stops a queued native send",function()
    local secret={}
    for _,query in ipairs({function() return true end, function() return nil end,
        function() error("lockdown API exception") end, function() return secret end}) do
        local sim=simulation(); local a=sim:client("Amber Stone",{secret=secret})
        a.env.C_ChatInfo.InChatMessagingLockdown=query
        reject(function() return a:enable("Birch Vale") end)
        equal(#a.sent,0); equal(a:drivers(),0); a:untouched()

        local live=simulation(); local b=live:client("Amber Stone",{secret=secret})
        assert(b:enable("Birch Vale"))
        assert(b.wire.Send({{target="Birch Vale",message=message()}}))
        b.env.C_ChatInfo.InChatMessagingLockdown=query
        live:step(10,false)
        equal(#b.sent,0); equal(b:drivers(),0)
        assert(b.wire.GetStatus():find("Pending sends stopped",1,true)); b:untouched()
    end
end)

test("shared nil send results remain unknown and receiver callbacks are protected",function()
    local sim=simulation(); local a=sim:client("Amber Stone",{nilResult=true,changed=function() error("UI callback failure") end})
    local b=sim:client("Birch Vale"); assert(a:enable("Birch Vale"))
    assert(b:enable("Amber Stone",function() error("receiver failure") end))
    assert(a.wire.Send({{target="Birch Vale",message=message()}})); sim:step(10)
    assert(a.wire.GetStatus():find("unknown API results",1,true))
    assert(b.wire.GetStatus():find("receiver callback failed",1,true))
    sim:step(50); equal(b:drivers(),0)
    a:untouched(); b:untouched()
end)

test("shared selected-peer packet flood is capped before parsing with one bounded notice",function()
    local sim=simulation(); local notices=0
    local b=sim:client("Birch Vale",{changed=function() notices=notices+1 end})
    assert(b:enable("Amber Stone")); notices=0
    local parsed=0
    local original=b.wire.ParsePacket
    b.wire.ParsePacket=function(...) parsed=parsed+1; return original(...) end
    local invalid={prefix=W.PREFIX,packet="malformed packet",channel="WHISPER",sender="Amber Stone"}
    for _=1,500 do b:event(invalid) end
    equal(parsed,120); equal(notices,1); equal(#b.received,0)
    assert(b.wire.GetStatus():find("receive rate limit",1,true))
    sim.now=sim.now+60
    local packets=assert(W.Frame("after-limit",assert(C.Encode(message()))))
    for _,packet in ipairs(packets) do b:event({prefix=W.PREFIX,packet=packet,channel="WHISPER",sender="Amber Stone"}) end
    equal(#b.received,1)
end)

test("shared unavailable clock stops queues and receive expiry driver once without idle loops",function()
    local sim=simulation(); local notices=0
    local b=sim:client("Birch Vale",{changed=function() notices=notices+1 end})
    assert(b:enable("Amber Stone"))
    local packets=assert(W.Frame("clock-loss",assert(C.Encode(message(string.rep("x",512))))))
    b:event({prefix=W.PREFIX,packet=packets[1],channel="WHISPER",sender="Amber Stone"})
    equal(b:drivers(),1)
    assert(b.wire.Send({{target="Amber Stone",message=message()}}))
    notices=0; sim.noClock=true
    b.wire.Tick()
    equal(b:drivers(),0); equal(b.wire.IsEnabled(),false); equal(notices,1)
    for _=1,100 do b.wire.Tick() end
    equal(notices,1); equal(#b.sent,0)
    assert(b.wire.GetStatus():find("clock is unavailable",1,true))
    b:untouched()
end)

return results
