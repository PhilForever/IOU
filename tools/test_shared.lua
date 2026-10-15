-- Offline protocol model checks. Each peer owns a separate immutable store;
-- delivery happens only when this harness explicitly moves an encoded message.
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
    if type(a)=="number" and a~=a and b~=b then return true end
    if type(a) ~= "table" then return a == b end
    for key, item in pairs(a) do if not same(item,b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function reject(call)
    local ok, err = call()
    assert(ok == nil or ok == false, "invalid operation succeeded")
    assert(type(err) == "string" and #err > 0, "rejection needs an explanation")
end
local saved = {version=1,characters={sample={schema=2,nextID=2,
    entries={{id=1,player="Ledger Peer",amount=12345,note="Ledger-only note"}}}},
    settings={minimap=true},recovery={}}
local original = copy(saved)
local function forbidden() error("offline foundation called a live client API") end
local env = setmetatable({IOUDB=saved,SendChatMessage=forbidden,
    SendAddonMessage=forbidden,CreateFrame=forbidden,time=forbidden,
    C_ChatInfo={RegisterAddonMessagePrefix=forbidden,SendAddonMessageLogged=forbidden},
    C_Timer={After=forbidden}}, {__index=_G})
env._G=env
local ns = {}
for _,name in ipairs({"shared_codec.lua","shared.lua"}) do
    local chunk=assert(loadstring(assert(IOU_SOURCES[name]),"@IOU/"..name))
    setfenv(chunk,env); chunk("IOU",ns)
end
local C,S=assert(ns.SharedCodec),assert(ns.Shared)
local function terms(changes)
    local value={protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",
        recipient="Birch Vale",debtor="Birch Vale",creditor="Amber Stone",
        amountCopper=10000,dueUTC=0,note="Bj\195\184rn bl\195\165b\195\166r"}
    for key,item in pairs(changes or {}) do value[key]=item end
    return value
end

local function message(kind, changes)
    local value={version=1,kind=kind or "PROPOSE",messageId="message-1",
        agreementId="agreement-1",offerId="offer-1",revision=1,
        terms=assert(C.CanonicalTerms(terms()))}
    if kind=="ACCEPT" or kind=="COMMIT" or kind=="ACK" then value.acceptanceId="acceptance-1" end
    if kind=="COMMIT" or kind=="ACK" then value.commitId="commit-1" end
    if kind=="WITHDRAW" or kind=="OUTCOME" then value.outcomeId="outcome-1" end
    if kind=="OUTCOME" then value.outcome="WITHDRAWN" end
    for key,item in pairs(changes or {}) do value[key]=item end
    return value
end
local function simulation()
    local sim={now=100,queue={},peers={}}
    local function peer(name)
        local value={name=name,store=assert(S.New(name)),sent={}}
        sim.peers[name]=value
        return value
    end
    sim.a=peer("Amber Stone"); sim.b=peer("Birch Vale")
    function sim:apply(who,method,...)
        local before=copy(who.store)
        local nextStore,actions=S[method](who.store,...)
        assert(same(who.store,before),"engine mutated its input store during "..method)
        assert(nextStore,actions)
        assert(nextStore~=who.store,"successful operation returned its original store")
        assert(S.Validate(nextStore))
        assert(type(actions)=="table")
        who.store=nextStore
        for _,action in ipairs(actions) do
            equal(type(action.target),"string")
            assert(C.ValidateMessage(action.message))
            local wire=assert(C.Encode(action.message))
            local packet={sender=who.name,target=action.target,wire=wire,
                message=assert(C.Decode(wire))}
            who.sent[#who.sent+1]=packet
            self.queue[#self.queue+1]=packet
        end
        assert(same(saved,original),"shared foundation changed IOUDB")
        return actions
    end
    function sim:rejected(who,method,...)
        local before=copy(who.store)
        local args={...}
        reject(function() return S[method](who.store,unpack(args)) end)
        assert(same(who.store,before),"rejected "..method.." changed state")
    end
    function sim:take(kind)
        for index,packet in ipairs(self.queue) do
            if packet.message.kind==kind then return table.remove(self.queue,index) end
        end
        error("missing queued "..kind)
    end
    function sim:deliver(packet)
        local target=assert(self.peers[packet.target],"unknown message target")
        return self:apply(target,"Receive",packet.sender,assert(C.Decode(packet.wire)),self.now)
    end
    function sim:propose(id)
        id=id or "one"
        self:apply(self.a,"Propose",terms(),"agreement-"..id,"offer-"..id,self.now)
        return self:take("PROPOSE")
    end
    function sim:offer(who,id) return assert(who.store.offers[id or "offer-one"]) end
    function sim:accept(id)
        self:apply(self.b,"Accept",id or "offer-one",self.now)
        return self:take("ACCEPT")
    end
    function sim:commit()
        self:deliver(self:propose())
        self:deliver(self:accept())
        local commit=self:take("COMMIT")
        self:deliver(commit)
        local ack=self:take("ACK")
        self:deliver(ack)
        return commit,ack
    end
    return sim
end

test("shared codec canonicalizes complete immutable gold terms without changing input", function()
    local input=terms(); local before=copy(input)
    assert(C.ValidateTerms(input))
    local canonical=assert(C.CanonicalTerms(input))
    assert(canonical:find("IOUST1:",1,true)==1)
    equal(assert(C.CanonicalTerms(copy(input))),canonical)
    assert(same(assert(C.ParseTerms(canonical)),input))
    assert(same(input,before))
    input.note="Changed later"
    assert(not canonical:find(input.note,1,true))
    local longName=string.rep("A",96)
    local boundary=terms({proposer=longName,creditor=longName,note=string.rep("x",512),
        amountCopper=999999999,dueUTC=4102444800})
    assert(C.ValidateTerms(boundary)); assert(C.ParseTerms(assert(C.CanonicalTerms(boundary))))
end)

test("shared codec rejects invalid identity, money, UTC deadline and unknown fields", function()
    for _,changes in ipairs({{protocol=2},{kind="money"},{proposer=""},
        {proposer=" Amber Stone"},{recipient="Birch  Vale"},{creditor="Other Peer"},
        {debtor="birch vale"},{debtor="Amber Stone"},{amountCopper=0},
        {amountCopper=-1},{amountCopper=0.5},{amountCopper="10000"},
        {amountCopper=1000000000},{amountCopper=0/0},{dueUTC=-1},
        {dueUTC=0.5},{dueUTC=4102444801},{dueUTC="0"},{extra=true},
        {proposer=string.rep("A",97)},{note=string.rep("x",513)}}) do
        local input=terms(changes); local before=copy(input)
        reject(function() return C.CanonicalTerms(input) end)
        assert(same(input,before))
    end
    local input=terms(); input.note=nil
    reject(function() return C.ValidateTerms(input) end)
    reject(function() return C.ValidateTerms(false) end)
    reject(function() return C.ValidateTerms(setmetatable({}, {__index=forbidden})) end)
end)

test("shared codec validates real UTF-8 and rejects overlong, surrogate and control encodings", function()
    for _,bad in ipairs({"\000","\001","\009","\010","\013","\031","\127",
        "\194\128","\194\159","|","|cfffffffftext|r","\128","\191",
        "\192\128","\193\191","\224\128\128","\237\160\128",
        "\244\144\128\128","\245\128\128\128","\255","\194","\226\130"}) do
        reject(function() return C.CanonicalTerms(terms({note=bad})) end)
        reject(function() return C.CanonicalTerms(terms({recipient="Peer"..bad,debtor="Peer"..bad})) end)
    end
    for _,good in ipairs({"", "\195\133sa \195\152rn", "\240\159\140\159",
        "\244\143\191\191",string.rep("\195\184",256)}) do
        local input=terms({note=good})
        local output=assert(C.ParseTerms(assert(C.CanonicalTerms(input))))
        equal(output.note,good)
    end
end)

test("all shared message kinds roundtrip with exact variant keysets and byte-bounded IDs", function()
    for _,kind in ipairs({"PROPOSE","ACCEPT","COMMIT","ACK","DECLINE","WITHDRAW","OUTCOME","STATUS"}) do
        local input=message(kind); local before=copy(input)
        assert(C.ValidateMessage(input))
        local encoded=assert(C.Encode(input))
        assert(#encoded<=4096); assert(encoded:find("IOUSM1:",1,true)==1)
        assert(same(assert(C.Decode(encoded)),input)); assert(same(input,before))
        input.extra=true; reject(function() return C.Encode(input) end)
    end
    assert(C.Encode(message("PROPOSE",{messageId=string.rep("a",64)})))
    for _,changes in ipairs({{version=2},{revision=0},{revision=2},{revision="1"},
        {messageId=""},{messageId="bad id"},{messageId=string.rep("a",65)},
        {agreementId="a|b"},{offerId="\195\184"},{kind="PAYMENT"},
        {terms="not canonical terms"}}) do
        reject(function() return C.Encode(message("PROPOSE",changes)) end)
    end
    local accept=message("ACCEPT"); accept.acceptanceId=nil
    reject(function() return C.Encode(accept) end)
    local outcome=message("OUTCOME",{outcome="COMMITTED"})
    reject(function() return C.Encode(outcome) end)
    reject(function() return C.Encode(setmetatable(message("PROPOSE"),{__index=forbidden})) end)
end)

test("shared decoders reject every truncation, trailing data and oversized untrusted input", function()
    for _,case in ipairs({{encode=C.CanonicalTerms,decode=C.ParseTerms,input=terms()},
        {encode=C.Encode,decode=C.Decode,input=message("COMMIT")}}) do
        local wire=assert(case.encode(case.input))
        for _,length in ipairs({"01","+1","-1","1.0","1e0","999999999999999999999999999999"}) do
            local corrupt=wire:gsub("1:1,",length..":1,",1)
            reject(function() return case.decode(corrupt) end)
        end
        for length=0,#wire-1 do
            reject(function() return case.decode(wire:sub(1,length)) end)
        end
        for _,suffix in ipairs({"x","\000",",","0:"}) do
            reject(function() return case.decode(wire..suffix) end)
        end
        reject(function() return case.decode(string.rep("x",4097)) end)
        reject(function() return case.decode(string.rep("x",1048576)) end)
        reject(function() return case.decode(nil) end)
        reject(function() return case.decode({}) end)
        reject(function() return case.decode("return IOUDB.characters={}") end)
        for index=1,#wire do
            local corrupt=wire:sub(1,index-1).."\000"..wire:sub(index+1)
            reject(function() return case.decode(corrupt) end)
        end
    end
    assert(same(saved,original))
end)

test("shared stores start empty, validate strictly and return independent snapshots", function()
    local store=assert(S.New("Amber Stone"))
    equal(store.version,1); equal(store.localName,"Amber Stone")
    equal(next(store.offers),nil); assert(S.Validate(store))
    for _,name in ipairs({"", " Amber Stone", "Amber  Stone", "Peer|Link"}) do
        reject(function() return S.New(name) end)
    end
    reject(function() return S.New({}) end)
    local invalid=copy(store); invalid.version=9
    reject(function() return S.Validate(invalid) end)
    invalid=copy(store); invalid.extra=true
    reject(function() return S.Validate(invalid) end)
    reject(function() return S.Validate(setmetatable(store,{__index=forbidden})) end)
    setmetatable(store,nil)
    local snapshot=assert(S.Snapshot(store)); assert(same(snapshot,store))
    snapshot.localName="Another Peer"; equal(store.localName,"Amber Stone")
end)

test("shared offer review requires explicit acceptance before either client commits", function()
    local sim=simulation(); local proposed=sim:propose()
    equal(sim:offer(sim.a).state,"OFFER_OPEN")
    equal(next(sim.b.store.offers),nil)
    sim:deliver(proposed)
    equal(sim:offer(sim.b).state,"OFFER_RECEIVED")
    equal(#sim.b.sent,0,"receiving an offer silently accepted it")
    local accepted=sim:accept()
    equal(sim:offer(sim.b).state,"ACCEPT_PENDING")
    equal(sim:offer(sim.a).state,"OFFER_OPEN")
    sim:deliver(accepted)
    equal(sim:offer(sim.a).state,"COMMITTED")
    equal(sim:offer(sim.b).state,"ACCEPT_PENDING")
    local commit=sim:take("COMMIT"); sim:deliver(commit)
    equal(sim:offer(sim.b).state,"COMMITTED")
    sim:deliver(sim:take("ACK"))
    equal(sim:offer(sim.a).terms,sim:offer(sim.b).terms)
    assert(same(saved,original))
end)

test("lost proposal, acceptance, commitment and acknowledgment recover by exact retained retry", function()
    for _,lost in ipairs({"PROPOSE","ACCEPT","COMMIT","ACK"}) do
        local sim=simulation()
        local function deliver(packet,who)
            if packet.message.kind==lost then
                sim:apply(who,"Retry","offer-one",sim.now)
                local retried=sim:take(lost)
                equal(retried.wire,packet.wire,"retry changed immutable message identity")
                packet=retried
            end
            sim:deliver(packet)
        end
        deliver(sim:propose(),sim.a)
        deliver(sim:accept(),sim.b)
        deliver(sim:take("COMMIT"),sim.a)
        deliver(sim:take("ACK"),sim.b)
        equal(sim:offer(sim.a).state,"COMMITTED")
        equal(sim:offer(sim.b).state,"COMMITTED")
        equal(sim:offer(sim.a).terms,sim:offer(sim.b).terms)
    end
end)

test("duplicate handshake messages are idempotent after later lifecycle transitions", function()
    local sim=simulation(); local proposal=sim:propose()
    sim:deliver(proposal); sim:deliver(proposal)
    equal(sim:offer(sim.b).state,"OFFER_RECEIVED")
    local accepted=sim:accept(); sim:deliver(accepted)
    local committed=sim:take("COMMIT")
    sim:deliver(accepted)
    local repeated=sim:take("COMMIT"); equal(repeated.wire,committed.wire)
    sim:deliver(committed)
    local ack=sim:take("ACK")
    sim:deliver(committed)
    equal(sim:take("ACK").wire,ack.wire)
    sim:deliver(ack); sim:deliver(ack)
    local before=copy(sim.a.store)
    sim:deliver(accepted); sim:deliver(ack)
    equal(sim:offer(sim.a).state,"COMMITTED")
    equal(#sim:offer(sim.a).history,#before.offers["offer-one"].history)
    equal(sim:offer(sim.b).consent,"ACCEPT")
end)

test("semantic retries with fresh message IDs cannot expand retained consent or history", function()
    local sim=simulation(); local commit,ack=sim:commit()
    local beforeA=copy(sim.a.store); local beforeB=copy(sim.b.store)
    local cases={{peer=sim.a,sender=sim.b.name,message=sim:offer(sim.b).messages.accept},
        {peer=sim.b,sender=sim.a.name,message=commit.message},
        {peer=sim.a,sender=sim.b.name,message=ack.message},
        {peer=sim.b,sender=sim.a.name,message=sim:offer(sim.a).messages.propose}}
    for index=1,64 do
        for _,case in ipairs(cases) do
            local duplicate=copy(case.message); duplicate.messageId="retry-"..index
            local actions=sim:apply(case.peer,"Receive",case.sender,duplicate,sim.now)
            assert(#actions<=1,"a duplicate produced unbounded actions")
            sim.queue={}
        end
    end
    assert(same(sim.a.store,beforeA)); assert(same(sim.b.store,beforeB))
end)

test("status requests replay retained immutable state without becoming new consent", function()
    local sim=simulation(); local commit,ack=sim:commit()
    for _,case in ipairs({{who=sim.a,sender=sim.b.name,kind="COMMIT",wire=commit.wire},
        {who=sim.b,sender=sim.a.name,kind="ACK",wire=ack.wire}}) do
        local request=copy(commit.message)
        request.kind="STATUS"; request.messageId="status-request"
        request.acceptanceId=nil; request.commitId=nil
        local before=copy(case.who.store)
        sim:apply(case.who,"Receive",case.sender,request,sim.now)
        equal(sim:take(case.kind).wire,case.wire)
        assert(same(case.who.store,before))
    end
end)

test("out-of-order echoes, unknown offers and foreign senders cannot create consent", function()
    local sim=simulation()
    local committed=message("COMMIT")
    sim:rejected(sim.b,"Receive",sim.a.name,committed,sim.now)
    sim:rejected(sim.a,"Receive",sim.b.name,message("ACK"),sim.now)
    equal(next(sim.b.store.offers),nil)
    local proposal=sim:propose()
    sim:rejected(sim.b,"Receive","Another Peer",proposal.message,sim.now)
    sim:rejected(sim.a,"Receive",sim.b.name,proposal.message,sim.now)
    sim:deliver(proposal)
    local accept=sim:accept()
    sim:rejected(sim.a,"Receive","Another Peer",accept.message,sim.now)
    sim:rejected(sim.a,"Receive","birch vale",accept.message,sim.now)
    equal(sim:offer(sim.a).state,"OFFER_OPEN")
    sim:deliver(accept); local commit=sim:take("COMMIT")
    sim:rejected(sim.b,"Receive","Another Peer",commit.message,sim.now)
    equal(sim:offer(sim.b).state,"ACCEPT_PENDING")
end)

test("offer and agreement IDs cannot be reused with changed immutable terms", function()
    local sim=simulation(); local proposal=sim:propose(); sim:deliver(proposal)
    for _,changes in ipairs({{amountCopper=10001},{note="Changed terms"},{dueUTC=1000},
        {debtor="Amber Stone",creditor="Birch Vale"}}) do
        local altered=copy(proposal.message)
        altered.terms=assert(C.CanonicalTerms(terms(changes)))
        sim:rejected(sim.b,"Receive",sim.a.name,altered,sim.now)
    end
    sim:rejected(sim.a,"Propose",terms(),"agreement-one","offer-new",sim.now)
    sim:rejected(sim.a,"Propose",terms(),"agreement-new","offer-one",sim.now)
    sim:rejected(sim.a,"Propose",terms({proposer="Birch Vale",recipient="Amber Stone"}),"g-new","o-new",sim.now)
    local snapshot=assert(S.Snapshot(sim.b.store,"offer-one"))
    snapshot.terms="Replaced outside engine"
    equal(sim:offer(sim.b).terms,proposal.message.terms)
end)

test("reused message and acceptance IDs cannot change their original semantics", function()
    local sim=simulation(); local proposed=sim:propose(); sim:deliver(proposed)
    local accepted=sim:accept(); sim:deliver(accepted)
    local changed=copy(accepted.message)
    changed.acceptanceId="different-acceptance"
    sim:rejected(sim.a,"Receive",sim.b.name,changed,sim.now)
    changed=copy(accepted.message); changed.kind="DECLINE"; changed.acceptanceId=nil
    sim:rejected(sim.a,"Receive",sim.b.name,changed,sim.now)
    local commit=sim:take("COMMIT"); sim:deliver(commit)
    changed=copy(commit.message); changed.commitId="different-commit"
    sim:rejected(sim.b,"Receive",sim.a.name,changed,sim.now)
    changed=copy(commit.message); changed.acceptanceId="different-acceptance"
    sim:rejected(sim.b,"Receive",sim.a.name,changed,sim.now)
    equal(sim:offer(sim.a).state,"COMMITTED"); equal(sim:offer(sim.b).state,"COMMITTED")
end)

test("declines converge without recording an accepted or committed agreement", function()
    local sim=simulation(); sim:deliver(sim:propose())
    sim:apply(sim.b,"Decline","offer-one",sim.now)
    equal(sim:offer(sim.b).state,"DECLINE_PENDING")
    local declined=sim:take("DECLINE"); sim:deliver(declined)
    equal(sim:offer(sim.a).state,"DECLINED")
    local outcome=sim:take("OUTCOME"); equal(outcome.message.outcome,"DECLINED")
    sim:deliver(outcome); equal(sim:offer(sim.b).state,"DECLINED")
    sim:deliver(declined); equal(sim:take("OUTCOME").wire,outcome.wire)
    sim:deliver(outcome)
    sim:rejected(sim.b,"Accept","offer-one",sim.now)
    sim:rejected(sim.a,"Withdraw","offer-one",sim.now)
end)

test("terminal recipients never replay stale acceptance or decline through retry or peer messages", function()
    for _,terminalState in ipairs({"WITHDRAWN","DECLINED"}) do
        local sim=simulation(); local proposal=sim:propose(); sim:deliver(proposal)
        if terminalState=="WITHDRAWN" then
            sim:accept()
            sim:apply(sim.a,"Withdraw","offer-one",sim.now)
            sim:deliver(sim:take("WITHDRAW"))
            assert(sim:offer(sim.b).messages.accept,"regression needs retained stale acceptance")
        else
            sim:apply(sim.b,"Decline","offer-one",sim.now)
            sim:deliver(sim:take("DECLINE")); sim:deliver(sim:take("OUTCOME"))
            assert(sim:offer(sim.b).messages.decline,"regression needs retained stale decline")
        end
        equal(sim:offer(sim.b).state,terminalState)
        local before=copy(sim.b.store)
        equal(#sim:apply(sim.b,"Retry","offer-one",sim.now),0)
        local request=copy(proposal.message)
        request.kind="STATUS"; request.messageId="terminal-status"
        equal(#sim:apply(sim.b,"Receive",sim.a.name,request,sim.now),0)
        equal(#sim:apply(sim.b,"Receive",sim.a.name,proposal.message,sim.now),0)
        local semanticDuplicate=copy(proposal.message)
        semanticDuplicate.messageId="terminal-proposal-retry"
        equal(#sim:apply(sim.b,"Receive",sim.a.name,semanticDuplicate,sim.now),0)
        assert(same(sim.b.store,before),"terminal requests grew or changed retained recipient history")
        equal(#sim:apply(sim.a,"Retry","offer-one",sim.now),1)
        local outcome=sim:take("OUTCOME")
        equal(outcome.message.outcome,terminalState)
        equal(outcome.wire,assert(C.Encode(sim:offer(sim.a).messages.outcome)))
        sim:deliver(outcome)
        assert(same(sim.b.store,before),"terminal outcome retry changed recipient history")
    end
end)

test("withdrawal wins an uncommitted crossing acceptance and remains terminal", function()
    local sim=simulation(); sim:deliver(sim:propose())
    local accepted=sim:accept()
    sim:apply(sim.a,"Withdraw","offer-one",sim.now)
    local withdrawal=sim:take("WITHDRAW")
    sim:deliver(accepted)
    local outcome=sim:take("OUTCOME")
    equal(outcome.message.outcome,"WITHDRAWN")
    equal(outcome.message.outcomeId,withdrawal.message.outcomeId)
    sim:deliver(outcome)
    sim:deliver(withdrawal)
    sim:deliver(outcome)
    equal(sim:offer(sim.b).state,"WITHDRAWN")
    equal(sim:offer(sim.a).state,"WITHDRAWN")
    sim:rejected(sim.b,"Accept","offer-one",sim.now)
    sim:rejected(sim.b,"Decline","offer-one",sim.now)
    sim:rejected(sim.a,"Propose",terms(),"agreement-one","offer-one",sim.now)
end)

test("reordered equivalent withdrawal outcomes converge and conflicting outcome IDs fail closed", function()
    for _,first in ipairs({"WITHDRAW","OUTCOME"}) do
        local sim=simulation(); sim:deliver(sim:propose())
        sim:apply(sim.a,"Withdraw","offer-one",sim.now)
        local withdraw=sim:take("WITHDRAW")
        sim:apply(sim.a,"Retry","offer-one",sim.now)
        local outcome=sim:take("OUTCOME")
        sim:deliver(first=="WITHDRAW" and withdraw or outcome)
        sim:deliver(first=="WITHDRAW" and outcome or withdraw)
        equal(sim:offer(sim.b).state,"WITHDRAWN")
        local changed=copy(outcome.message); changed.outcomeId="conflicting-outcome"
        sim:rejected(sim.b,"Receive",sim.a.name,changed,sim.now)
    end
end)

test("commitment wins before withdrawal and no unilateral action rewrites committed terms", function()
    local sim=simulation(); sim:deliver(sim:propose())
    sim:deliver(sim:accept())
    sim:rejected(sim.a,"Withdraw","offer-one",sim.now)
    sim:deliver(sim:take("COMMIT")); sim:deliver(sim:take("ACK"))
    for _,who in ipairs({sim.a,sim.b}) do
        for _,method in ipairs({"Accept","Decline","Withdraw"}) do
            sim:rejected(who,method,"offer-one",sim.now)
        end
        equal(sim:offer(who).state,"COMMITTED")
    end
end)

test("paused pending offers never resume sending or consent after a simulated reload", function()
    for _,pending in ipairs({"OFFER_OPEN","OFFER_RECEIVED","ACCEPT_PENDING","DECLINE_PENDING"}) do
        local sim=simulation(); local proposed=sim:propose()
        local who=sim.a
        if pending~="OFFER_OPEN" then sim:deliver(proposed); who=sim.b end
        if pending=="ACCEPT_PENDING" then sim:accept() end
        if pending=="DECLINE_PENDING" then sim:apply(sim.b,"Decline","offer-one",sim.now) end
        sim:apply(who,"Pause",sim.now)
        equal(sim:offer(who).state,"PAUSED")
        local restored=assert(S.Snapshot(who.store)); assert(S.Validate(restored))
        who.store=restored
        sim:rejected(who,"Retry","offer-one",sim.now)
        sim:rejected(who,"Accept","offer-one",sim.now)
        equal(sim:offer(who).state,"PAUSED")
    end
end)

test("lost local acceptance cannot be reconstructed from an incoming commitment", function()
    local sim=simulation(); sim:deliver(sim:propose())
    local beforeAcceptance=assert(S.Snapshot(sim.b.store))
    sim:deliver(sim:accept()); local commit=sim:take("COMMIT")
    sim.b.store=beforeAcceptance
    sim:rejected(sim.b,"Receive",sim.a.name,commit.message,sim.now)
    equal(sim:offer(sim.b).state,"OFFER_RECEIVED")
    sim.b.store=assert(S.New(sim.b.name))
    sim:rejected(sim.b,"Receive",sim.a.name,commit.message,sim.now)
    equal(next(sim.b.store.offers),nil)
end)

test("committed snapshots retain exactly the original commitment and acknowledgment on retry", function()
    local sim=simulation(); local commit,ack=sim:commit()
    for _,who in ipairs({sim.a,sim.b}) do
        sim:apply(who,"Pause",sim.now)
        equal(sim:offer(who).state,"COMMITTED")
        who.store=assert(S.Snapshot(who.store))
        sim:apply(who,"Retry","offer-one",sim.now)
    end
    equal(sim:take("COMMIT").wire,commit.wire)
    equal(sim:take("ACK").wire,ack.wire)
end)

test("retained offer capacity rejects excess work without evicting earlier history", function()
    local sim=simulation()
    for index=1,32 do
        sim:apply(sim.a,"Propose",terms(),"capacity-g-"..index,"capacity-o-"..index,sim.now)
    end
    local before=copy(sim.a.store)
    sim:rejected(sim.a,"Propose",terms(),"capacity-g-33","capacity-o-33",sim.now)
    assert(same(sim.a.store,before))
    for index=1,32 do assert(sim.a.store.offers["capacity-o-"..index]) end
    assert(same(saved,original))
end)

test("shared mutations reject corrupt stores and exhausted IDs without touching their inputs", function()
    local sim=simulation(); sim:commit()
    for _,change in ipairs({function(store) store.serial=-1 end,
        function(store) store.offers["offer-one"].messages.accept=nil end,
        function(store) store.offers["offer-one"].messages.commit.commitId="altered" end,
        function(store) store.offers["offer-one"].consent="NONE" end,
        function(store) store.offers["offer-one"].history[1].at=-1 end,
        function(store) store.offers["offer-one"].processed.bad="not a message" end}) do
        local broken=copy(sim.b.store); change(broken); local before=copy(broken)
        reject(function() return S.Validate(broken) end)
        reject(function() return S.Retry(broken,"offer-one",sim.now) end)
        assert(same(broken,before))
    end
    local exhausted=assert(S.New("Amber Stone")); exhausted.serial=2147483647
    local before=copy(exhausted); assert(S.Validate(exhausted))
    reject(function() return S.Propose(exhausted,terms(),"new-g","new-o",sim.now) end)
    assert(same(exhausted,before))
    sim:rejected(sim.a,"Propose",terms(),"new-g","new-o",-1)
    sim:rejected(sim.a,"Propose",terms(),"new-g","new-o",0.5)
end)

test("outgoing actions and received messages never alias retained shared records", function()
    local before=assert(S.New("Amber Stone"))
    local proposed,actions=assert(S.Propose(before,terms(),"isolated-g","isolated-o",100))
    -- Lua's assert preserves all returned values, including the action array.
    local wire=assert(C.Encode(actions[1].message))
    actions[1].message.terms="tampered action"; actions[1].target="Different Peer"
    assert(S.Validate(proposed)); equal(next(before.offers),nil)
    local incoming=assert(C.Decode(wire))
    local received=assert(S.Receive(assert(S.New("Birch Vale")),"Amber Stone",incoming,100))
    incoming.terms="tampered after receipt"
    equal(received.offers["isolated-o"].terms,proposed.offers["isolated-o"].terms)
    assert(S.Validate(received)); assert(same(saved,original))
end)

return results
