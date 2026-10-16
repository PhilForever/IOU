-- Payment/correction serialization must preserve every old obligation byte.
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(actual,expected) assert(actual==expected,"expected "..tostring(expected)..", got "..tostring(actual)) end
local function reject(run)
    local value,err=run()
    assert(value==nil or value==false,"invalid payment data succeeded")
    assert(type(err)=="string" and #err>0,"rejection needs a readable error")
end
local function copy(value)
    if type(value)~="table" then return value end
    local out={}; for key,item in pairs(value) do out[key]=copy(item) end; return out
end
local ns={}
local chunk=assert(loadstring(assert(IOU_SOURCES["shared_codec.lua"]),"@IOU/shared_codec.lua"))
local env=setmetatable({CreateFrame=function() error("codec called native API") end,
    SendChatMessage=function() error("codec called chat") end},{__index=_G})
setfenv(chunk,env); chunk("IOU",ns)
local C=assert(ns.SharedCodec)
local function obligation(changes)
    local t={protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
        debtor="Birch Vale",creditor="Amber Stone",amountCopper=10000,dueUTC=0,note=""}
    for key,value in pairs(changes or {}) do t[key]=value end
    return t
end
local function row(kind,id,amount,note,reverses)
    return {kind=kind,agreementId="g-"..id,offerId="o-"..id,commitId="c-"..id,
        amountCopper=amount,note=note or "",reversesId=reverses or ""}
end
local function event(changes,rows,parent)
    parent=parent or obligation()
    local chain=assert(C.CanonicalChain(rows or {}))
    local t={protocol=2,kind="GOLD_PAYMENT",proposer=parent.proposer,recipient=parent.recipient,
        debtor=parent.debtor,creditor=parent.creditor,amountCopper=1000,dueUTC=0,note="",
        parentAgreementId="parent-g",parentOfferId="parent-o",parentCommitId="parent-c",
        parentTerms=assert(C.CanonicalTerms(parent)),baseRevision=#(rows or {}),baseChain=chain,reversesId=""}
    for key,value in pairs(changes or {}) do t[key]=value end
    return t
end
local function message(terms)
    return {version=1,kind="PROPOSE",messageId="message-1",agreementId="event-g",offerId="event-o",revision=1,
        terms=assert(C.CanonicalTerms(terms))}
end
local function net(value) value=tostring(value); return #value..":"..value.."," end

test("payment codec preserves original obligation canonical bytes exactly",function()
    local expected="IOUST1:"..net(1)..net("GOLD_OBLIGATION")..net("Amber Stone")..net("Birch Vale")
        ..net("Birch Vale")..net("Amber Stone")..net(10000)..net(0)..net("")
    local original=obligation()
    equal(assert(C.CanonicalTerms(original)),expected)
    equal(assert(C.CanonicalTerms(assert(C.ParseTerms(expected)))),expected)
    equal(original.protocol,1); equal(original.amountCopper,10000)
end)

test("payment codec roundtrips exact flat baselines and both debtor directions",function()
    equal(assert(C.CanonicalChain({})),"IOUSC1:1:0,")
    for _,parent in ipairs({obligation(),obligation({debtor="Amber Stone",creditor="Birch Vale"})}) do
        local rows={row("GOLD_PAYMENT","first",3000,"Bj\195\184rn bl\195\165b\195\166r")}
        local terms=event({amountCopper=7000,note="remainder"},rows,parent)
        local canonical=assert(C.CanonicalTerms(terms)); assert(canonical:sub(1,7)=="IOUST2:")
        local decoded=assert(C.ParseTerms(canonical))
        equal(decoded.parentTerms,terms.parentTerms); equal(decoded.baseChain,terms.baseChain)
        equal(decoded.parentCommitId,"parent-c"); equal(decoded.baseRevision,1)
        equal(assert(C.ParseChain(decoded.baseChain))[1].note,rows[1].note)
        equal(assert(C.Decode(assert(C.Encode(message(terms))))).terms,canonical)
    end
end)

test("correction codec permits one exact full reversal with an explicit reason",function()
    local paid=row("GOLD_PAYMENT","paid",3000,"recorded payment")
    local correction=event({kind="GOLD_CORRECTION",amountCopper=3000,note="Recorded twice",reversesId=paid.offerId},{paid})
    local canonical=assert(C.CanonicalTerms(correction))
    equal(assert(C.ParseTerms(canonical)).reversesId,paid.offerId)
    local reversed=row("GOLD_CORRECTION","reversal",3000,"Recorded twice",paid.offerId)
    local chain=assert(C.CanonicalChain({paid,reversed}))
    equal(assert(C.ParseChain(chain))[2].kind,"GOLD_CORRECTION")
    reject(function() return C.CanonicalTerms(event({kind="GOLD_CORRECTION",amountCopper=3000,note="again",reversesId=paid.offerId},{paid,reversed})) end)
    assert(C.CanonicalTerms(event({amountCopper=10000},{paid,reversed})))
end)

test("payment codec rejects changed parent binding participants direction and stale baseline structure",function()
    local one=row("GOLD_PAYMENT","one",3000)
    for _,changes in ipairs({{protocol=1},{kind="OTHER"},{parentCommitId=""},{parentAgreementId="x y"},
        {parentOfferId="bad|id"},{parentTerms="IOUST2:not-a-parent"},{proposer="Birch Vale",recipient="Amber Stone"},
        {debtor="Amber Stone",creditor="Birch Vale"},{dueUTC=1},{baseRevision=2},{baseChain="balance:3000"},
        {reversesId=one.offerId},{amountCopper=7001},{unknown="field"}}) do
        reject(function() return C.CanonicalTerms(event(changes,{one})) end)
    end
    local conflict=event({parentAgreementId=one.agreementId},{one})
    reject(function() return C.CanonicalTerms(conflict) end)
    conflict=event({parentOfferId=one.offerId},{one})
    reject(function() return C.CanonicalTerms(conflict) end)
    local overpaid=row("GOLD_PAYMENT","overpaid",10001)
    local undone=row("GOLD_CORRECTION","undone",10001,"undo",overpaid.offerId)
    reject(function() return C.CanonicalTerms(event({},{overpaid,undone})) end)
end)

test("correction codec rejects partial duplicate unknown and correction-of-correction events",function()
    local paid=row("GOLD_PAYMENT","paid",3000)
    for _,changes in ipairs({{amountCopper=2999},{amountCopper=3001},{reversesId="o-missing"},
        {reversesId=""},{note=""},{note="  "},{note="bad|text"},{note="\195"}}) do
        local t=event({kind="GOLD_CORRECTION",amountCopper=3000,note="Fix mistake",reversesId=paid.offerId},{paid})
        for key,value in pairs(changes) do t[key]=value end
        reject(function() return C.CanonicalTerms(t) end)
    end
    local correction=row("GOLD_CORRECTION","correction",3000,"fix",paid.offerId)
    reject(function() return C.CanonicalTerms(event({kind="GOLD_CORRECTION",amountCopper=3000,note="Undo correction",reversesId=correction.offerId},{paid,correction})) end)
end)

test("flat event chains reject reused identities missing evidence malformed UTF-8 and sparse arrays",function()
    local paid=row("GOLD_PAYMENT","paid",3000)
    for _,rows in ipairs({{paid,copy(paid)}, {[2]=paid}, {row("GOLD_CORRECTION","c",3000,"fix","o-missing")},
        {paid,row("GOLD_CORRECTION","c",3001,"fix",paid.offerId)},
        {paid,row("GOLD_CORRECTION","c",3000,"fix",paid.offerId),row("GOLD_CORRECTION","d",3000,"twice",paid.offerId)}}) do
        reject(function() return C.CanonicalChain(rows) end)
    end
    for _,field in ipairs({"agreementId","offerId","commitId","note","reversesId"}) do
        local broken=copy(paid); broken[field]="\192\175"
        reject(function() return C.CanonicalChain({broken}) end)
    end
    local broken=copy(paid); broken.extra=true; reject(function() return C.CanonicalChain({broken}) end)
    reject(function() return C.CanonicalChain(setmetatable({paid},{})) end)
    reject(function() return C.CanonicalChain({setmetatable(copy(paid),{})}) end)
    local tooMany={}; for index=1,32 do tooMany[index]=row("GOLD_PAYMENT","p"..index,1) end
    reject(function() return C.CanonicalChain(tooMany) end)
end)

test("payment codec rejects truncation noncanonical nesting and oversized logical envelopes",function()
    local rows={row("GOLD_PAYMENT","first",1000)}
    local chain=assert(C.CanonicalChain(rows))
    for length=0,#chain-1 do reject(function() return C.ParseChain(chain:sub(1,length)) end) end
    reject(function() return C.ParseChain(chain.."trailing") end)
    reject(function() return C.ParseChain(chain:gsub("IOUSC1:1:1,","IOUSC1:01:1,",1)) end)
    local canonical=assert(C.CanonicalTerms(event({},rows)))
    for length=0,#canonical-1 do reject(function() return C.ParseTerms(canonical:sub(1,length)) end) end
    reject(function() return C.ParseTerms(canonical.."trailing") end)
    local many={}
    for index=1,31 do
        many[index]=row("GOLD_PAYMENT","p"..index,1,string.rep("x",80))
        local t=event({amountCopper=1},many)
        local raw=C.CanonicalTerms(t)
        if raw then
            local msg={version=1,kind="PROPOSE",messageId=string.rep("m",64),agreementId=string.rep("g",64),offerId=string.rep("o",64),revision=1,terms=raw}
            local encoded,err=C.Encode(msg)
            if not encoded then assert(type(err)=="string"); return end
            assert(#encoded<=4096)
        else return end
    end
    error("expected bounded encoding to reject accumulated history")
end)

return results
