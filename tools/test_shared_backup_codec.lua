-- Pure snapshot codec checks. Fixtures contain invented data only.
local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results + 1] = name
end
local function rejected(value, err)
    assert(value == nil, "malformed snapshot was accepted")
    assert(type(err) == "string" and #err > 0, "missing rejection explanation")
end
local function namespace(env)
    local ns = {}
    local chunk = assert(loadstring(assert(IOU_SOURCES["shared_backup.lua"]), "@IOU/shared_backup.lua"))
    setfenv(chunk, env or _G)
    chunk("IOU", ns)
    return ns.SharedBackup
end
local B = namespace()
local function snapshot()
    return {version=1, character="Amber Stone-Realm", owner="Amber Stone", exportedAt=100,
        entry={version=1, store={version=1, localName="Amber Stone", serial=0, offers={}},
            closedPaused={}, nonce="sample", counter=0}}
end
local function armor(raw)
    local alphabet, chunks = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", {}
    for index = 1, #raw, 3 do
        local a,b,c=raw:byte(index,index+2)
        local hasB,hasC=b,c; b,c=b or 0,c or 0
        local p,q,r,s=math.floor(a/4)+1,(a%4)*16+math.floor(b/16)+1,(b%16)*4+math.floor(c/64)+1,c%64+1
        chunks[#chunks+1]=alphabet:sub(p,p)..alphabet:sub(q,q)
            ..(hasB and alphabet:sub(r,r) or "=")..(hasC and alphabet:sub(s,s) or "=")
    end
    return B.HEADER..table.concat(chunks)
end
local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key,value in pairs(left) do if not same(value,right[key]) then return false end end
    for key in pairs(right) do if left[key]==nil then return false end end
    return true
end

test("Shared backup exact round trip and detached decoded tables", function()
    local value=snapshot()
    value.entry.store.offers={sample={terms="Unicode: Bjørn blåbær | commas,:\n\000\255",
        history={{at=1,kind="SAMPLE"},{at=2,kind="RETAINED"}}, processed={m1="opaque evidence"}}}
    local text=assert(B.Encode(value))
    assert(text:match("^IOUS1:[A-Za-z0-9+/=]+$"))
    local decoded=assert(B.Decode(text))
    assert(same(decoded,value))
    assert(decoded~=value and decoded.entry.store~=value.entry.store)
    assert(B.Encode(decoded)==text)
end)
test("Shared backup canonical ordering ignores table insertion order", function()
    local left,right=snapshot(),snapshot()
    left.entry.extra={z=1,a="first",["å"]=2,["\000"]=3}
    right.entry.extra={["\000"]=3,["å"]=2,a="first",z=1}
    assert(B.Canonical(left)==B.Canonical(right))
end)
test("Shared backup accepts clipboard whitespace without changing string bytes", function()
    local value=snapshot(); value.entry.sample=" leading \r\n trailing "
    local text=assert(B.Encode(value))
    local wrapped=" \r\n"..text:sub(1,6)..text:sub(7):gsub("....","%0\n").."\t"
    assert(same(B.Decode(wrapped),value))
end)
test("Shared backup stores source-like text literally without executing it", function()
    local value=snapshot(); value.entry.note="return (function() error('do not execute') end)()"
    assert(B.Decode(assert(B.Encode(value))).entry.note==value.entry.note)
end)
test("Shared backup accepts exact safe integer and timestamp endpoints", function()
    local value=snapshot(); value.exportedAt=B.MAX_TIME
    value.entry.endpoint={0,B.MAX_INTEGER}
    assert(same(B.Decode(assert(B.Encode(value))),value))
    value.exportedAt=0; assert(B.Encode(value))
end)
test("Shared backup rejects missing unknown and mismatched envelope fields", function()
    local changes={function(v) v.version=2 end,function(v) v.character=nil end,
        function(v) v.extra="x" end,function(v) v.character=string.rep("a",257) end,
        function(v) v.owner="Other Player" end,function(v) v.owner="" end,
        function(v) v.exportedAt=B.MAX_TIME+1 end,function(v) v.entry.store={} end,
        function(v) v.character="" end,function(v) v.entry=false end}
    for _,change in ipairs(changes) do local v=snapshot(); change(v); rejected(B.Encode(v)) end
end)
test("Shared backup envelope validation deliberately leaves domain rules to the service", function()
    local v=snapshot(); v.entry.store.offers={invented={notADomainOffer="retained as data"}}
    assert(B.ValidateEnvelope(v)); assert(B.Decode(assert(B.Encode(v))))
end)
test("Shared backup rejects negative fractional nonfinite and unsupported values", function()
    for _,bad in ipairs({-1,0.5,math.huge,-math.huge,0/0,B.MAX_INTEGER+1,true,false,function() end}) do
        local v=snapshot(); v.entry.bad=bad; rejected(B.Encode(v))
    end
    local v=snapshot(); v.entry.bad=coroutine.create(function() end); rejected(B.Encode(v))
end)
test("Shared backup rejects metatables cycles and shared table references", function()
    local v=snapshot(); setmetatable(v.entry,{__index={}}); rejected(B.Encode(v))
    v=snapshot(); v.entry.loop=v; rejected(B.Encode(v))
    v=snapshot(); v.entry.first={}; v.entry.second=v.entry.first; rejected(B.Encode(v))
    v=snapshot(); setmetatable(v,{__index=function() error("should not run") end}); rejected(B.Encode(v))
end)
test("Shared backup rejects sparse mixed and nonstring map keys", function()
    for _,bad in ipairs({{[2]="sparse"},{[1]="a",text="mixed"},{[0]="zero"},
        {[-1]="negative"},{[0.5]="fraction"},{[true]="boolean"},{[{}]="table"}}) do
        local v=snapshot(); v.entry.bad=bad; rejected(B.Encode(v))
    end
end)
test("Shared backup checks secrets before reading values and keys", function()
    local env=setmetatable({issecretvalue=function(v) return v=="hidden" end},{__index=_G})
    local secret=namespace(env)
    local v=snapshot(); v.entry.bad="hidden"; rejected(secret.Encode(v))
    v=snapshot(); v.entry.hidden="ordinary"; rejected(secret.Encode(v))
    rejected(secret.Decode("hidden"))
    env.issecretvalue=function() error("secret API unavailable") end
    rejected(secret.Encode(snapshot()))
end)
test("Shared backup rejects excessively deep trees without throwing", function()
    local v=snapshot(); local cursor=v.entry
    for _=1,B.MAX_DEPTH do cursor.next={}; cursor=cursor.next end
    rejected(B.Encode(v))
end)
test("Shared backup bounds encoded input before parsing or allocation", function()
    rejected(B.Decode(string.rep("x",B.MAX_BYTES+1)))
    rejected(B.Decode(nil)); rejected(B.Decode({})); rejected(B.Decode(false))
end)
test("Shared backup honors raw bytes and node budgets on encode and decode", function()
    local originalRaw,originalNodes=B.MAX_RAW_BYTES,B.MAX_NODES
    local text=assert(B.Encode(snapshot()))
    local ok,err=pcall(function()
        B.MAX_RAW_BYTES=10; rejected(B.Encode(snapshot())); rejected(B.Decode(text))
        B.MAX_RAW_BYTES=originalRaw; B.MAX_NODES=5
        rejected(B.Encode(snapshot())); rejected(B.Decode(text))
    end)
    B.MAX_RAW_BYTES,B.MAX_NODES=originalRaw,originalNodes
    assert(ok,err)
end)
test("Shared backup rejects malformed and noncanonical base64", function()
    for _,text in ipairs({"IOU2:AAAA","IOUS1:","IOUS1:A","IOUS1:====","IOUS1:AA=A",
        "IOUS1:AB==","IOUS1:AAB=","IOUS1:AA==AAAA","IOUS1:AA$=","IOUS1:AA-_"}) do
        rejected(B.Decode(text))
    end
end)
test("Shared backup rejects duplicate out-of-order and nonstring parsed map keys", function()
    for _,raw in ipairs({"m2:s1:ai1;s1:ai2;","m2:s1:zi1;s1:ai2;","m1:i1;i1;"}) do
        rejected(B.Decode(armor(raw)))
    end
end)
test("Shared backup rejects invalid typed tokens and noncanonical numbers", function()
    for _,raw in ipairs({"a0:","s01:x","s2:x","i01;","i-1;","i1.5;","i9007199254740992;",
        "m01:","m99999999999999999:","t1;","n","s0", "a1:","m1:s1:a"}) do
        rejected(B.Decode(armor(raw)))
    end
end)
test("Shared backup rejects truncated appended and structurally invalid snapshots", function()
    local raw=assert(B.Canonical(snapshot()))
    rejected(B.Decode(armor(raw:sub(1,-2))))
    rejected(B.Decode(armor(raw.."s0:")))
    rejected(B.Decode(armor("m0:")))
    rejected(B.Decode(armor("s0:")))
end)
test("Shared backup decoded complexity and depth limits apply before domain validation", function()
    local raw=string.rep("a1:",B.MAX_DEPTH+1).."i0;"
    rejected(B.Decode(armor(raw)))
    rejected(B.Decode(armor("a100001:")))
end)
test("Shared backup failures do not mutate source trees", function()
    local v=snapshot(); local original=assert(B.Canonical(v))
    assert(B.Encode(v)); assert(B.Canonical(v)==original)
    v.entry.bad=true; rejected(B.Encode(v)); assert(v.entry.bad==true)
    v.entry.bad=nil; assert(B.Canonical(v)==original)
end)
return results
