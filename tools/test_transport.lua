-- Two isolated Lua 5.1 addon environments, a synthetic clock and an explicit
-- delivery queue. API return values alone never count as observed delivery.
local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results + 1] = name
end
local function equal(actual, expected, note)
    assert(actual == expected, (note or "unexpected value") .. ": expected "
        .. tostring(expected) .. ", got " .. tostring(actual))
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = copy(item) end
    return out
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, item in pairs(a) do if not same(item, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function reject(call)
    local value, err = call()
    assert(value == nil or value == false, "invalid input succeeded")
    assert(type(err) == "string" and #err > 0, "rejection needs an explanation")
end
local function simulation()
    local sim = {now=1000, clients={}, queue={}, sent={}, autoDeliver=true}
    function sim:client(name, options)
        options = options or {}
        local state = {name=name, frames={}, sent={}, messages={}, apiResult=0}
        if options.result ~= nil then state.apiResult=options.result end
        state.nilResult=options.nilResult
        local ledger = {version=1, characters={sample={schema=2,nextID=2,
            entries={{id=1,player="Sample Peer",amount=12345}}}},
            settings={minimap=true},recovery={}}
        state.before=copy(ledger)
        local env = setmetatable({IOUDB=ledger}, {__index=_G})
        state.env=env
        env._G=env
        env.GetTime=function() return sim.now end
        env.time=function() return 1900000000+math.floor(sim.now) end
        env.GetServerTime=env.time
        env.GetUnitName=function(unit)
            if unit=="player" then return name end
            if unit=="target" then return options.target end
        end
        env.UnitFullName=function(unit)
            return env.GetUnitName(unit), "TestRealm"
        end
        env.UnitName=env.GetUnitName
        env.UnitIsPlayer=function(unit) return env.GetUnitName(unit)~=nil end
        env.NameUtil={GetUnmodifiedUnitFullName=env.GetUnitName}
        env.GetRealmName=function() return "TestRealm" end
        env.issecretvalue=function(value)
            return options.secret ~= nil and options.secret==value
        end
        env.SendChatMessage=function() error("ordinary chat must never be sent") end
        env.print=function(...) state.messages[#state.messages+1]={...} end
        env.CreateFrame=function()
            local frame = {scripts={},events={}}
            function frame:RegisterEvent(event) self.events[event]=true end
            function frame:UnregisterEvent(event) self.events[event]=nil end
            function frame:SetScript(event, fn) self.scripts[event]=fn end
            function frame:GetScript(event) return self.scripts[event] end
            function frame:Hide() self.shown=false end
            function frame:Show() self.shown=true end
            state.frames[#state.frames+1]=frame
            return frame
        end
        if not options.noAPI then
            env.C_ChatInfo={
                RegisterAddonMessagePrefix=function(prefix)
                    state.registeredPrefix=prefix
                    if options.registerThrows then error("register unavailable") end
                    if options.registerFails then return false end
                    if options.nilRegistration then return nil end
                    return options.registration or 0
                end,
                AreOutgoingAddonChatMessagesRestricted=function()
                    if options.restrictionThrows then error("restricted API unavailable") end
                    return options.restricted or false
                end,
                InChatMessagingLockdown=function() return options.lockdown or false end,
                SendAddonMessage=function() error("unlogged fallback must never be sent") end,
            }
            if not options.noLoggedAPI then
                env.C_ChatInfo.SendAddonMessageLogged=function(prefix, wire, channel, target)
                    if options.sendThrows then error("mock send failed") end
                    local result=state.apiResult
                    if state.nilResult then result=nil end
                    local packet={from=state,prefix=prefix,wire=wire,channel=channel,
                        target=target,result=result,at=sim.now}
                    state.sent[#state.sent+1]=packet; sim.sent[#sim.sent+1]=packet
                    if result==0 then sim.queue[#sim.queue+1]=packet end
                    return result
                end
            end
        end
        env.Enum={SendAddonMessageResult={Success=0}}
        local api = {OnTransportChanged=options.callback}
        api.Message=function(message) state.messages[#state.messages+1]=message end
        state.api=api
        local chunk = assert(loadstring(assert(IOU_SOURCES["transport.lua"]), "@IOU/transport.lua"))
        setfenv(chunk, env); chunk("IOU", api)
        state.transport=assert(api.Transport)
        state.transport.Initialize()
        function state:event(prefix, wire, channel, sender, target)
            for _, frame in ipairs(self.frames) do
                if frame.events.CHAT_MSG_ADDON_LOGGED and frame.scripts.OnEvent then
                    frame.scripts.OnEvent(frame,"CHAT_MSG_ADDON_LOGGED",prefix,wire,
                        channel or "WHISPER",sender,target or self.name)
                end
            end
        end
        function state:activeDrivers()
            local count=0
            for _, frame in ipairs(self.frames) do
                if frame.scripts.OnUpdate then count=count+1 end
            end
            return count
        end
        function state:listen(peer)
            assert(self.transport.EnableListening(true,peer))
        end
        function state:start(peer)
            self:listen(peer)
            return assert(self.transport.Start(peer))
        end
        function state:unchanged()
            assert(same(self.env.IOUDB,self.before),"transport mutated saved ledger/settings")
        end
        sim.clients[#sim.clients+1]=state
        return state
    end
    function sim:deliver(packet, destination, overrides)
        local to=destination
        if not to then
            for _, client in ipairs(self.clients) do
                if client.name:lower()==packet.target:lower() then to=client; break end
            end
        end
        if to then
            overrides=overrides or {}
            to:event(overrides.prefix or packet.prefix,overrides.wire or packet.wire,
                overrides.channel or packet.channel,overrides.sender or packet.from.name,
                packet.target)
        end
    end
    function sim:pump(reverse)
        local pending=self.queue; self.queue={}
        if reverse then
            for index=#pending,1,-1 do self:deliver(pending[index]) end
        else
            for _, packet in ipairs(pending) do self:deliver(packet) end
        end
    end
    function sim:advance(seconds, reverse)
        for _=1,math.ceil(seconds*10) do
            self.now=self.now+0.1
            for _, client in ipairs(self.clients) do
                for _, frame in ipairs(client.frames) do
                    if frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame,0.1) end
                end
            end
            if self.autoDeliver then self:pump(reverse) end
        end
    end
    function sim:unchanged()
        for _, client in ipairs(self.clients) do client:unchanged() end
    end
    return sim
end
local function pair(options)
    local sim=simulation()
    local a=sim:client("Amber Stone",options)
    local b=sim:client("Birch Vale")
    return sim,a,b
end
local function echoed(session)
    local count=0
    for _, probe in ipairs(session.probes) do if probe.echoed then count=count+1 end end
    return count
end

-- Cases below intentionally exercise observable public behavior instead of
-- duplicating the implementation's private packet queue or clock constants.

test("transport remains idle until the user configures and starts a peer test", function()
    local sim,a,b=pair()
    sim:advance(60)
    equal(#sim.sent,0); equal(a:activeDrivers(),0); equal(b:activeDrivers(),0)
    reject(function() return a.transport.Start(b.name) end)
    reject(function() return a.transport.EnableListening(true,"") end)
    a:listen(b.name)
    sim:advance(60)
    equal(#sim.sent,0,"enabling a listener must not initiate a test")
    equal(a:activeDrivers(),0)
    a.transport.Stop(); sim:advance(60)
    equal(#sim.sent,0); sim:unchanged()
end)

test("transport preserves canonical surnames and UTF-8 while rejecting control text", function()
    local sim,a=pair()
    local T=a.transport
    equal(T.CanonicalName("  Amber   Stone  "),"Amber Stone")
    local unicode="\195\133sa \195\152rn"
    equal(T.CanonicalName(unicode),unicode)
    for _, value in ipairs({"", "   ", "Amber\nStone", "Amber\tStone",
        "Amber\000Stone", "|Hplayer:Amber|h[Amber]|h", string.rep("a",1000)}) do
        reject(function() return T.CanonicalName(value) end)
    end
    reject(function() return T.CanonicalName(nil) end)
    reject(function() return T.CanonicalName({}) end)
    sim:unchanged()
end)

test("four fixed probes and echoes preserve payloads within the encoded byte ceiling", function()
    local sim,a,b=pair()
    local session=a:start(b.name)
    local T=a.transport
    equal(T.MAX_BYTES,240)
    equal(T.VERSION,"2"); equal(T.PREFIX,"IOU_LINKv2")
    local hasUTF8=false
    for index=1,4 do
        local wire=assert(T.BuildProbe(session.id,index))
        assert(#wire<=T.MAX_BYTES)
        assert(not wire:find("[%z\001-\031\127|]"),"logged probe contains controls or pipe markup")
        if index==3 then equal(#wire,239) end
        if index==4 then equal(#wire,240) end
        local parsed=assert(T.Parse(wire))
        equal(parsed.kind,"P"); equal(parsed.id,session.id); equal(parsed.index,index)
        equal(parsed.wire,wire)
        if wire:find("[\128-\255]") then hasUTF8=true end
        local echo="E"..wire:sub(2)
        local answer=assert(T.Parse(echo))
        equal(answer.kind,"E"); equal(answer.body,parsed.body)
        reject(function() return T.Parse(wire.."x") end)
    end
    assert(hasUTF8,"fixed probes must exercise real UTF-8 bytes")
    sim:unchanged()
end)

test("malformed, unknown and oversized frames fail closed without throwing", function()
    local sim,a,b=pair()
    local session=a:start(b.name)
    local T=a.transport
    local wire=assert(T.BuildProbe(session.id,1))
    local bad={"", "P", "E", "P 2", "P 2 ", "Q"..wire:sub(2),
        wire:gsub("^P 2 ","P 9 "), "P 2 x 0 x", "P 2 x 5 x",
        "P 2 x 1 x", "P 2 x 1 x y", "P|1|x|1|IOU link test",
        "P 02 x 1 IOU link test", "P 2 x 01 IOU link test",
        wire.."\000", string.rep("P",1048576)}
    for _, value in ipairs(bad) do reject(function() return T.Parse(value) end) end
    reject(function() return T.Parse(nil) end)
    reject(function() return T.Parse(false) end)
    reject(function() return T.Parse(1) end)
    reject(function() return T.Parse({}) end)
    for length=0,241 do
        reject(function() return T.Parse(string.rep("|",length)) end)
    end
    for index=1,#wire do
        local changed=wire:sub(1,index-1).."\000"..wire:sub(index+1)
        reject(function() return T.Parse(changed) end)
    end
    sim:unchanged()
end)

test("zero send results mean queued locally and require matching remote echoes", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    local session=a:start(b.name)
    sim:advance(10)
    equal(#a.sent,4); equal(echoed(session),0)
    for _, probe in ipairs(session.probes) do equal(probe.result,0) end
    assert(session.state~="complete","API success alone falsely proved delivery")
    assert(type(a.transport.GetReport())=="string")
    sim:advance(60)
    equal(session.state,"timeout"); equal(echoed(session),0)
    equal(a:activeDrivers(),0); sim:unchanged()
end)

test("two independent clients complete only through the logged whisper delivery queue", function()
    local sim,a,b=pair()
    b:listen(a.name)
    local session=a:start(b.name)
    sim:advance(10)
    equal(session.state,"complete"); equal(echoed(session),4)
    equal(#a.sent,4); equal(#b.sent,4)
    equal(a:activeDrivers(),0); equal(b:activeDrivers(),0)
    for _, packet in ipairs(sim.sent) do
        equal(packet.prefix,a.transport.PREFIX); equal(packet.channel,"WHISPER")
        assert(packet.target==a.name or packet.target==b.name)
        assert(#packet.wire<=240)
    end
    local count=#sim.sent; sim:advance(120); equal(#sim.sent,count)
    sim:unchanged()
end)

test("diagnostic protocol two stays exact through a transport that excludes pipe markup", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    b:listen(a.name)
    local session=a:start(b.name)
    for _=1,120 do
        sim:advance(0.1)
        local pending=sim.queue; sim.queue={}
        for _,packet in ipairs(pending) do
            -- This models one possible logged-text filter, not a proven claim
            -- about the live client. Every generated frame must survive it.
            local filtered=packet.wire:gsub("|.","")
            equal(filtered,packet.wire)
            sim:deliver(packet,nil,{wire=filtered})
        end
    end
    equal(session.state,"complete"); equal(echoed(session),4)
    assert(a.transport.GetReport():find("recognized fixed frames: 4",1,true))
    assert(b.transport.GetReport():find("recognized fixed frames: 4",1,true))
    sim:unchanged()
end)

test("receive diagnostics distinguish no event from rejected peer channel and fixed payload", function()
    local sim,a,b=pair()
    b:listen(a.name)
    local T=b.transport
    local wire=assert(T.BuildProbe("observations",1))
    local report=T.GetReport()
    assert(report:find("Matching-prefix receive events: 0",1,true))
    assert(report:find("No matching-prefix event observed",1,true))
    b:event("OTHER_PREFIX",wire,"WHISPER",a.name)
    equal(#sim.sent,0)
    assert(T.GetReport():find("Matching-prefix receive events: 0",1,true))
    b:event(T.PREFIX,wire,"PARTY",a.name)
    b:event(T.PREFIX,wire,"WHISPER",a.name.." Other")
    local private="PRIVATE PAYLOAD TEXT THAT MUST NOT APPEAR IN REPORTS"
    b:event(T.PREFIX,private,"WHISPER",a.name)
    report=T.GetReport()
    assert(report:find("Matching-prefix receive events: 3; exact-peer whispers: 1; recognized fixed frames: 0",1,true))
    assert(report:find("wrong channel 1; wrong peer 1; invalid fixed payload 1",1,true))
    assert(report:find("channel is not WHISPER",1,true))
    assert(report:find("sender does not exactly match the configured peer",1,true))
    assert(report:find("Unknown probe format",1,true))
    assert(not report:find(private,1,true),"diagnostics retained unrecognized payload text")
    sim:advance(10); equal(#sim.sent,0); sim:unchanged()
end)

test("legacy or modified fixed payloads are observable but never echoed", function()
    local sim,a,b=pair()
    b:listen(a.name)
    local T=b.transport
    b:event(T.PREFIX,"P|1|legacy|1|IOU link test","WHISPER",a.name)
    b:event(T.PREFIX,assert(T.BuildProbe("current",1)).." changed","WHISPER",a.name)
    local report=T.GetReport()
    assert(report:find("invalid fixed payload 2",1,true))
    assert(report:find("Unknown probe format",1,true))
    assert(report:find("Probe payload is not recognized",1,true))
    assert(report:find("protocol 1 clients are incompatible",1,true))
    sim:advance(10); equal(#sim.sent,0); equal(b:activeDrivers(),0)
    sim:unchanged()
end)

test("malformed receive metadata stays bounded and cannot flood UI refresh callbacks", function()
    local changes=0
    local sim=simulation()
    local a=sim:client("Amber Stone")
    local b=sim:client("Birch Vale",{callback=function() changes=changes+1 end})
    b:listen(a.name)
    local before=changes
    for index=1,12000 do
        b:event(b.transport.PREFIX,"not fixed "..index,"WHISPER",a.name,"Target "..index)
    end
    local report=b.transport.GetReport()
    assert(report:find("Matching-prefix receive events: 9999",1,true))
    assert(report:find("invalid fixed payload 9999",1,true))
    assert(not report:find("Target 7",1,true),"retained more than six observation records")
    assert(#report<=8000)
    equal(changes-before,6,"malformed flood triggered more than bounded metadata refreshes")
    sim:advance(10); equal(#sim.sent,0); equal(b:activeDrivers(),0)
    sim:unchanged()
end)

test("all documented numeric send errors and unexpected nil fail without claiming delivery", function()
    for code=1,12 do
        local sim,a,b=pair({result=code})
        local session=a:start(b.name)
        sim:advance(60)
        equal(echoed(session),0); assert(session.state~="complete")
        assert(#a.sent>=1 and #a.sent<=4,"error caused missing or unbounded send attempts")
        for _, probe in ipairs(session.probes) do
            if probe.result~=nil then
                equal(probe.result,code)
                assert(probe.resultText:find("("..code..")",1,true))
            end
        end
        equal(a:activeDrivers(),0); sim:unchanged()
    end
    local sim,a,b=pair({nilResult=true})
    local session=a:start(b.name); sim:advance(60)
    equal(echoed(session),0); assert(session.state~="complete")
    assert(#a.sent<=4); equal(a:activeDrivers(),0); sim:unchanged()
end)

test("unsupported boolean and unknown send results cannot be mistaken for numeric success", function()
    for _,value in ipairs({true,false,"0",99}) do
        local sim,a,b=pair({result=value})
        local session=a:start(b.name); sim:advance(60)
        equal(#sim.queue,0); equal(echoed(session),0)
        assert(session.state~="complete"); equal(a:activeDrivers(),0)
        for _,probe in ipairs(session.probes) do
            equal(probe.result,value); equal(probe.submitted,false)
        end
        sim:unchanged()
    end
end)

test("missing Forever identity fails closed and never invents a surname from the realm", function()
    local sim,a,b=pair()
    a.env.NameUtil=nil
    reject(function() return a.transport.GetLocalName() end)
    reject(function() return a.transport.EnableListening(true,b.name) end)
    equal(#sim.sent,0)
    a.env.UnitNameUnmodified=function(unit)
        if unit=="player" then return "Amber","Stone" end
    end
    a.env.Constants={CharacterNameSeparatorConsts={CHARACTERNAME_SURNAME_SEPARATOR=" "}}
    equal(a.transport.GetLocalName(),a.name)
    reject(function() return a.transport.EnableListening(true,"AMBER STONE") end)
    assert(a.transport.EnableListening(true,b.name)); equal(#sim.sent,0)
    sim:unchanged()
end)

test("missing logged APIs and genuine lockdown remain inert with useful errors", function()
    for _, options in ipairs({{noAPI=true},{noLoggedAPI=true},
        {lockdown=true},{registerFails=true},{registerThrows=true}}) do
        local sim=simulation()
        local a=sim:client("Amber Stone",options)
        local ok,err=a.transport.EnableListening(true,"Birch Vale")
        if ok then ok,err=a.transport.Start("Birch Vale") end
        assert(ok==nil or ok==false,"unavailable messaging was enabled")
        assert(type(err)=="string" and #err>0)
        sim:advance(60); equal(#sim.sent,0); equal(a:activeDrivers(),0)
        sim:unchanged()
    end
    local sim,a,b=pair({sendThrows=true})
    local session=a:start(b.name)
    sim:advance(60)
    assert(session.state~="complete"); equal(echoed(session),0)
    equal(a:activeDrivers(),0); sim:unchanged()
end)

test("the general addon restriction flag does not prevent exact logged-whisper round trips", function()
    local sim=simulation()
    local a=sim:client("Amber Stone",{restricted=true})
    local b=sim:client("Birch Vale",{restricted=true})
    b:listen(a.name)
    local session=a:start(b.name)
    sim:advance(10)
    equal(session.state,"complete"); equal(echoed(session),4)
    equal(#a.sent,4); equal(#b.sent,4)
    for _,packet in ipairs(sim.sent) do
        equal(packet.prefix,a.transport.PREFIX); equal(packet.channel,"WHISPER")
    end
    sim:unchanged()
end)

test("unavailable general restriction observations remain advisory without crashing or fallback", function()
    local secret={}
    local cases={
        function() return nil end,
        function() return "unknown" end,
        function() error("private general restriction API exception") end,
        function() return secret end,
        false,
    }
    for _,query in ipairs(cases) do
        local sim,a,b=pair({secret=secret})
        a.env.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted=query or nil
        if query==false then a.env.C_ChatInfo.InChatMessagingLockdown=nil end
        b:listen(a.name)
        local session=a:start(b.name)
        sim:advance(10)
        equal(session.state,"complete"); equal(echoed(session),4)
        local report=a.transport.GetReport()
        assert(report:find("AreOutgoingAddonChatMessagesRestricted",1,true))
        assert(not report:find("private general restriction API exception",1,true))
        sim:unchanged()
    end
end)

test("true or unreadable live lockdown blocks native sends and preserves a readable failure", function()
    local secret={}
    for _,query in ipairs({function() return true end, function() return nil end,
        function() error("private lockdown API exception") end, function() return secret end}) do
        local sim,a,b=pair({secret=secret})
        a.env.C_ChatInfo.InChatMessagingLockdown=query
        local ok,err=a.transport.EnableListening(true,b.name)
        assert(not ok and type(err)=="string")
        sim:advance(30); equal(#a.sent,0); equal(a:activeDrivers(),0)
        local report=a.transport.GetReport()
        assert(report:find("InChatMessagingLockdown",1,true))
        assert(report:find(err,1,true))
        assert(not report:find("private lockdown API exception",1,true))
        sim:unchanged()

        local live,c,d=pair({secret=secret})
        local session=c:start(d.name)
        equal(#c.sent,1)
        c.env.C_ChatInfo.InChatMessagingLockdown=query
        live:advance(30)
        equal(#c.sent,1); assert(session.state~="complete")
        equal(c:activeDrivers(),0); live:unchanged()
    end
end)

test("blocked Listen and Run reports retain attempted peer and restriction evidence without traffic", function()
    local sim,a,b=pair({restricted=true,lockdown=true})
    local ok,err=a.transport.EnableListening(true,"  Birch   Vale  ")
    assert(not ok and type(err)=="string")
    local report=a.transport.GetReport()
    assert(report:find("Last attempt",1,true))
    assert(report:find("Listen",1,true) and report:find(b.name,1,true))
    assert(report:find(err,1,true)); assert(report:find("true",1,true))
    assert(report:find("AreOutgoingAddonChatMessagesRestricted",1,true))
    assert(report:find("InChatMessagingLockdown",1,true))
    assert(a.transport.GetStatus():find(err,1,true))
    a.env.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted=function() return false end
    a.env.C_ChatInfo.InChatMessagingLockdown=function() return false end
    -- Generating a report may read current flags, but may not initialize or send.
    local reportNativeCalls=0
    a.env.C_ChatInfo.RegisterAddonMessagePrefix=function() reportNativeCalls=reportNativeCalls+1; error("report attempted registration") end
    a.env.C_ChatInfo.SendAddonMessageLogged=function() reportNativeCalls=reportNativeCalls+1; error("report attempted send") end
    for _=1,3 do
        report=a.transport.GetReport()
        assert(report:find(err,1,true) and report:find(b.name,1,true))
        assert(report:find("true",1,true) and report:find("false",1,true))
    end
    equal(reportNativeCalls,0)
    equal(#sim.sent,0); equal(a:activeDrivers(),0); assert(not a.transport.IsListening())
    a.transport.Stop()
    assert(not a.transport.GetStatus():find(err,1,true))
    sim:unchanged()

    local live,c,d=pair()
    c:listen(d.name)
    c.env.C_ChatInfo.InChatMessagingLockdown=function() return true end
    local started,startError=c.transport.Start(d.name)
    assert(not started and type(startError)=="string")
    report=c.transport.GetReport()
    assert(report:find("Last attempt",1,true) and report:find("Run",1,true))
    assert(report:find(d.name,1,true) and report:find(startError,1,true))
    assert(c.transport.GetStatus():find(startError,1,true))
    equal(#live.sent,0); equal(c:activeDrivers(),0)
    c.transport.Stop(); assert(not c.transport.GetStatus():find(startError,1,true))
    live:unchanged()
end)

test("prefix registration honors numeric success and duplicate results and rejects other types", function()
    for _,code in ipairs({0,1}) do
        local sim=simulation()
        local a=sim:client("Amber Stone",{registration=code})
        a:listen("Birch Vale")
        assert(a.transport.IsListening()); equal(#sim.sent,0)
        assert(a.transport.GetReport():find("("..code..")",1,true))
        sim:unchanged()
    end
    for _,options in ipairs({{registration=2},{registration=3},{registration=true},
        {nilRegistration=true}}) do
        local sim=simulation()
        local a=sim:client("Amber Stone",options)
        reject(function() return a.transport.EnableListening(true,"Birch Vale") end)
        equal(#sim.sent,0); equal(a:activeDrivers(),0); sim:unchanged()
    end
end)

test("an unavailable send result may still be proven by a later exact peer echo", function()
    local sim,a,b=pair({nilResult=true})
    sim.autoDeliver=false
    local session=a:start(b.name); sim:advance(5)
    equal(#a.sent,4); equal(echoed(session),0)
    for _,probe in ipairs(session.probes) do
        equal(probe.result,nil); equal(probe.submitted,nil)
        assert(probe.resultText:find("nil",1,true))
    end
    for index=4,1,-1 do
        local wire=assert(a.transport.BuildProbe(session.id,index))
        a:event(a.transport.PREFIX,"E"..wire:sub(2),"WHISPER",b.name)
    end
    equal(session.state,"complete"); equal(echoed(session),4)
    equal(a:activeDrivers(),0); sim:unchanged()
end)

test("prefix, channel and exact configured sender filters prevent forged responses", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    local session=a:start(b.name); sim:advance(10)
    for index=1,4 do
        local wire=assert(a.transport.BuildProbe(session.id,index))
        local echo="E"..wire:sub(2)
        a:event("OTHER_PREFIX",echo,"WHISPER",b.name)
        a:event(a.transport.PREFIX,echo,"PARTY",b.name)
        a:event(a.transport.PREFIX,echo,"WHISPER","Unknown Sender")
        a:event(a.transport.PREFIX,echo,"WHISPER",b.name.." Extra")
        a:event(a.transport.PREFIX,"E"..assert(a.transport.BuildProbe("unrelated",index)):sub(2),"WHISPER",b.name)
    end
    equal(echoed(session),0)
    for index=1,4 do
        local wire=assert(a.transport.BuildProbe(session.id,index))
        a:event(a.transport.PREFIX,"E"..wire:sub(2),"WHISPER",b.name:upper())
    end
    equal(echoed(session),4); equal(session.state,"complete")
    sim:unchanged()
end)

test("duplicates and out-of-order echoes count each fixed probe exactly once", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    local session=a:start(b.name); sim:advance(10)
    for _,index in ipairs({4,2,2,1,4,3,3}) do
        local wire=assert(a.transport.BuildProbe(session.id,index))
        a:event(a.transport.PREFIX,"E"..wire:sub(2),"WHISPER",b.name)
    end
    equal(echoed(session),4); equal(session.state,"complete")
    equal(a:activeDrivers(),0); equal(#a.sent,4); sim:unchanged()
end)

test("listener only echoes configured peer probes and bounds duplicates and flood traffic", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    b:listen(a.name)
    local session=a:start(b.name); sim:advance(10)
    local packets={}
    for _, packet in ipairs(a.sent) do packets[#packets+1]=packet end
    for _=1,100 do
        for _, packet in ipairs(packets) do
            b:event(packet.prefix,packet.wire,"WHISPER","Unknown Sender")
            b:event(packet.prefix,packet.wire,"PARTY",a.name)
            b:event("OTHER_PREFIX",packet.wire,"WHISPER",a.name)
        end
    end
    sim:advance(5); equal(#b.sent,0)
    local frameCount=#b.frames
    for _=1,1000 do
        b:event(a.transport.PREFIX,string.rep("x",241),"WHISPER",a.name)
    end
    for _=1,100 do
        for index=#packets,1,-1 do sim:deliver(packets[index],b) end
    end
    sim:advance(10)
    assert(#b.sent>0 and #b.sent<=8,"duplicate flood produced excess echoes")
    equal(#b.frames,frameCount,"incoming flood allocated driver frames")
    for index=2,#b.sent do
        assert(b.sent[index].at>b.sent[index-1].at,"echo queue did not pace sends")
    end
    equal(b:activeDrivers(),0); sim:unchanged()
end)

test("responder rate limits unique sessions and clears its bounded window only after a minute", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    b:listen(a.name)
    for index=1,1000 do
        local wire=assert(a.transport.BuildProbe("burst-"..index,1))
        b:event(a.transport.PREFIX,wire,"WHISPER",a.name)
    end
    sim:advance(10)
    assert(#b.sent<=8,"flood exceeded bounded pending echo queue")
    assert(b.transport.GetReport():find("Responder window: 12/12",1,true))
    assert(b.transport.GetStatus():find("rate limit",1,true))
    local count=#b.sent
    local wire=assert(a.transport.BuildProbe("new-session",1))
    b:event(a.transport.PREFIX,wire,"WHISPER",a.name)
    sim:advance(10); equal(#b.sent,count)
    sim:advance(41)
    b:event(a.transport.PREFIX,wire,"WHISPER",a.name)
    sim:advance(2); equal(#b.sent,count+1)
    assert(b.transport.GetReport():find("Responder window: 1/12",1,true))
    equal(b:activeDrivers(),0); sim:unchanged()
end)

test("simultaneous tests keep independent correlation tokens and complete across reordered delivery", function()
    local sim,a,b=pair()
    a:listen(b.name); b:listen(a.name)
    local first=assert(a.transport.Start(b.name))
    local second=assert(b.transport.Start(a.name))
    assert(first.id~=second.id)
    sim:advance(15,true)
    equal(first.state,"complete"); equal(second.state,"complete")
    equal(echoed(first),4); equal(echoed(second),4)
    equal(#a.sent,8); equal(#b.sent,8)
    equal(a:activeDrivers(),0); equal(b:activeDrivers(),0)
    sim:unchanged()
end)

test("local report preflight checks all wire formats without starting network traffic", function()
    local sim,a,b=pair()
    local report=a.transport.GetReport()
    for index=1,4 do
        assert(report:find("Local preflight "..index,1,true))
    end
    assert(not report:find("FAIL",1,true))
    assert(#report<=8000)
    equal(#sim.sent,0); equal(a:activeDrivers(),0)
    sim:unchanged()
end)

test("UI refresh failures cannot break message processing or strand active drivers", function()
    local calls=0
    local sim,a,b=pair({callback=function() calls=calls+1; error("UI refresh failed") end})
    b:listen(a.name)
    local session=a:start(b.name); sim:advance(10)
    equal(session.state,"complete"); equal(echoed(session),4)
    assert(calls>0); equal(a:activeDrivers(),0); sim:unchanged()
end)

test("stop cancels queued work and a fresh addon environment never resumes transmission", function()
    local sim,a,b=pair()
    sim.autoDeliver=false
    local session=a:start(b.name)
    a.transport.Stop()
    equal(session.state,"cancelled"); equal(a:activeDrivers(),0)
    local count=#sim.sent; sim:advance(60); equal(#sim.sent,count)
    local reloaded=sim:client(a.name)
    sim:advance(60)
    equal(#reloaded.sent,0); equal(reloaded:activeDrivers(),0)
    reject(function() return reloaded.transport.Start(b.name) end)
    sim:unchanged()
end)

return results
