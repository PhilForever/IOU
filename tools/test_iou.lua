-- Execute only local project source in Lua 5.1. These checks exercise the ledger
-- and snapshot parser; they do not claim real WoW UI/API compatibility.
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
    local result = {}
    for key, item in pairs(value) do result[copy(key)] = copy(item) end
    return result
end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, value in pairs(a) do if not same(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local ns = {}
for _, name in ipairs({"ledger.lua", "codec.lua"}) do
    assert(IOU_SOURCES[name], "missing " .. name)
    local chunk = assert(loadstring(IOU_SOURCES[name], "@IOU/" .. name))
    chunk("IOU", ns)
end
local L, C = assert(ns.Ledger), assert(ns.Codec)
local function armor(raw, header)
    local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local parts={header or "IOU1:"}
    for offset=1,#raw,3 do
        local a,b,c=raw:byte(offset,offset+2)
        local number=a*65536+(b or 0)*256+(c or 0)
        local i1=math.floor(number/262144)%64
        local i2=math.floor(number/4096)%64
        local i3=math.floor(number/64)%64
        local i4=number%64
        parts[#parts+1]=alphabet:sub(i1+1,i1+1) .. alphabet:sub(i2+1,i2+1)
            .. (b and alphabet:sub(i3+1,i3+1) or "=")
            .. (c and alphabet:sub(i4+1,i4+1) or "=")
    end
    return table.concat(parts)
end
local function entry(db, options, at)
    options = options or {}
    local values = {player="Astrid", direction="owed", kind="money",
        amount=12345, label="", note=""}
    for key, value in pairs(options) do values[key] = value end
    local result, err = L.Add(db, values, at or 100)
    assert(result, err)
    return result
end
local function legacyLedger()
    return {schema=1,nextID=1,entries={}}
end
local function metadata(e, changes)
    local values={player=e.player,label=e.label,note=e.note,due=e.due}
    for key,value in pairs(changes or {}) do values[key]=value end
    return values
end
local function rejected(db, operation)
    local before = copy(db)
    local value, err = operation()
    assert(value == nil or value == false, "operation unexpectedly succeeded")
    assert(type(err) == "string" and #err > 0, "rejection needs an explanation")
    assert(same(db, before), "rejected operation mutated the ledger")
end
local function invalid(db)
    local ok, err = L.Validate(db)
    assert(ok == nil or ok == false, "invalid ledger accepted")
    assert(type(err) == "string" and #err > 0, "validation needs an explanation")
end
local function invalidSnapshot(text)
    local value, err = C.Import(text)
    assert(value == nil or value == false, "invalid snapshot accepted")
    assert(type(err) == "string" and #err > 0, "import rejection needs an explanation")
end

test("new ledger has a valid empty schema", function()
    local db = L.New()
    equal(db.schema, 2); equal(db.nextID, 1); equal(#db.entries, 0)
    assert(L.Validate(db))
    equal(#L.List(db, "owed", ""), 0)
    equal(L.Summary(db, "owed").money, 0)
end)

test("gold uses integer copper through partial repayment", function()
    local db = L.New()
    local e = entry(db, {amount=12345, note="1 gold, 23 silver, 45 copper"})
    equal(e.id, 1); equal(db.nextID, 2)
    equal(L.Get(db, 1), e); equal(L.Balance(e), 12345)
    equal(L.Status(e), "outstanding")
    local paid = assert(L.Pay(db, e.id, 2345, "23s 45c", 101))
    equal(paid.type, "payment"); equal(paid.amount, 2345)
    equal(paid.id, 1); equal(paid.at, 101)
    equal(L.Balance(e), 10000); equal(L.Status(e), "partial")
    equal(L.Summary(db, "owed").money, 10000)
end)

test("money formatting handles copper, silver, gold and maximum values", function()
    equal(L.FormatMoney(0), "0g 00s 00c")
    equal(L.FormatMoney(1), "0g 00s 01c")
    equal(L.FormatMoney(99), "0g 00s 99c")
    equal(L.FormatMoney(100), "0g 01s 00c")
    equal(L.FormatMoney(9999), "0g 99s 99c")
    equal(L.FormatMoney(10000), "1g 00s 00c")
    equal(L.FormatMoney(12345), "1g 23s 45c")
    equal(L.FormatMoney(999999999), "99999g 99s 99c")
end)

test("overpayment and invalid repayment are atomic", function()
    local db = L.New()
    local e = entry(db, {amount=100})
    for _, amount in ipairs({101, 0, -1, 0.5, 0/0, math.huge, "10"}) do
        rejected(db, function() return L.Pay(db, e.id, amount, "", 102) end)
    end
    rejected(db, function() return L.Pay(db, 9999, 1, "", 102) end)
    rejected(db, function() return L.Settle(db, 9999, "", 102) end)
    equal(L.Balance(e), 100); equal(#e.events, 0)
end)

test("settlement records remaining amount and reversal reopens it", function()
    local db = L.New()
    local e = entry(db, {amount=1000})
    assert(L.Pay(db, e.id, 400, "first", 101))
    local settlement = assert(L.Settle(db, e.id, "final", 102))
    equal(settlement.amount, 600); equal(L.Balance(e), 0)
    equal(L.Status(e), "settled")
    equal(#L.List(db, "owed", ""), 0); equal(#L.List(db, "history", ""), 1)
    rejected(db, function() return L.Settle(db, e.id, "again", 103) end)
    local reversal = assert(L.Reverse(db, e.id, settlement.id, "mistake", 104))
    equal(reversal.type, "reversal"); equal(reversal.reverses, settlement.id)
    equal(reversal.note, "mistake"); equal(reversal.at, 104)
    equal(L.Balance(e), 600); equal(L.Status(e), "partial")
    equal(#L.List(db, "history", ""), 0); equal(#L.List(db, "owed", ""), 1)
    equal(e.events[2].amount, 600, "original payment stays in audit history")
    rejected(db, function() return L.Reverse(db, e.id, settlement.id, "duplicate", 105) end)
    rejected(db, function() return L.Reverse(db, e.id, reversal.id, "reverse reversal", 105) end)
    rejected(db, function() return L.Reverse(db, e.id, 999, "unknown", 105) end)
end)

test("reversing the only repayment restores outstanding status", function()
    local db = L.New()
    local e = entry(db, {amount=50})
    local payment = assert(L.Pay(db, e.id, 10, "", 101))
    assert(L.Reverse(db, e.id, payment.id, "wrong person", 102))
    equal(L.Balance(e), 50); equal(L.Status(e), "outstanding")
    assert(L.Settle(db, e.id, "later", 103))
    equal(L.Status(e), "settled"); assert(L.Validate(db))
end)

test("item and favor obligations support partial fulfillment", function()
    local db = L.New()
    local item = entry(db, {kind="item", amount=20,
        label="|cff1eff00|Hitem:2447:0:0:0:0:0:0:0|h[Peacebloom]|h|r"})
    local favor = entry(db, {kind="favor", amount=3, label="Dungeon run", direction="owe"})
    assert(L.Pay(db, item.id, 7, "7 herbs", 101))
    assert(L.Pay(db, favor.id, 1, "first run", 102))
    equal(L.Balance(item), 13); equal(L.Balance(favor), 2)
    equal(L.Status(item), "partial"); equal(L.Status(favor), "partial")
    assert(L.Settle(db, item.id, "rest returned", 103))
    equal(L.Status(item), "settled"); equal(L.Balance(favor), 2)
end)

test("summary separates directions and active obligation kinds", function()
    local db = L.New()
    local gold = entry(db, {amount=12000})
    entry(db, {amount=5000, direction="owe"})
    entry(db, {kind="item", amount=40, label="Linen Cloth"})
    entry(db, {kind="favor", amount=2, label="Boost", direction="owe"})
    local settled = entry(db, {amount=90000})
    assert(L.Settle(db, settled.id, "", 101))
    assert(L.Pay(db, gold.id, 2000, "", 102))
    local owed, owe = L.Summary(db, "owed"), L.Summary(db, "owe")
    equal(owed.money, 10000); equal(owed.active, 2)
    equal(owed.items, 1); equal(owed.favors, 0)
    equal(owe.money, 5000); equal(owe.active, 2)
    equal(owe.items, 0); equal(owe.favors, 1)
end)

test("list filters by literal search and returns newest first", function()
    local db = L.New()
    local first = entry(db, {player="Alice", note="a.b [raid] 100%"}, 100)
    local second = entry(db, {player="ALICE-Realm", label=""}, 200)
    entry(db, {player="Bob", direction="owe", note="a.b"}, 300)
    entry(db, {player="A.b[raid]100%"}, 400)
    local found = L.List(db, "owed", "alice")
    equal(#found, 2); equal(found[1].id, second.id); equal(found[2].id, first.id)
    equal(#L.List(db, "owed", "a.b"), 2)
    equal(#L.List(db, "owed", "[raid]"), 2)
    equal(#L.List(db, "owed", "100%"), 2)
    equal(#L.List(db, "owed", ".*"), 0, "query must not be a Lua pattern")
    equal(#L.List(db, "owed", "first run"), 0)
    equal(#L.List(db, "owe", "alice"), 0)
    equal(L.Summary(db, "owed", "alice").money, 24690)
    equal(L.Summary(db, "owed", "bob").active, 0)
end)

test("new obligations validate amounts, type, player and labels", function()
    local db = L.New()
    local bad = {
        {player=""}, {player="   "}, {player=10},
        {direction="both"}, {kind="quest"}, {amount=0}, {amount=-1},
        {amount=1.25}, {amount=0/0}, {amount=math.huge}, {amount="100"},
        {amount=1000000000}, {kind="item", label=""},
        {kind="favor", label="  "}, {label="money must not have a label"},
        {player=string.rep("a", 81)}, {note=string.rep("x", 2001)},
        {kind="item", label=string.rep("x", 513)}, {note="bad\000note"},
        {note="bad\001note"}, {extra="unexpected"},
    }
    for _, changes in ipairs(bad) do
        local values = {player="Astrid", direction="owed", kind="money", amount=1,
            label="", note=""}
        for key, value in pairs(changes) do values[key] = value end
        rejected(db, function() return L.Add(db, values, 100) end)
    end
    rejected(db, function() return L.Add(db, nil, 100) end)
    rejected(db, function() return L.Add(db, {}, 100) end)
    equal(#db.entries, 0); equal(db.nextID, 1)
end)

test("timestamp and audit notes are bounded and atomic", function()
    local db = L.New()
    local values = {player="A", direction="owed", kind="money", amount=10, label="", note=""}
    for _, at in ipairs({-1, 0.5, 4102444801, math.huge, 0/0, "100"}) do
        rejected(db, function() return L.Add(db, values, at) end)
    end
    local e = entry(db)
    rejected(db, function() return L.Pay(db, e.id, 1, string.rep("x", 2001), 101) end)
    rejected(db, function() return L.Pay(db, e.id, 1, "bad\000note", 101) end)
    rejected(db, function() return L.Pay(db, e.id, 1, "", -1) end)
    local payment = assert(L.Pay(db, e.id, 1, "ok\twith\nnewlines", 101))
    rejected(db, function() return L.Reverse(db, e.id, payment.id, nil, 102) end)
    rejected(db, function() return L.Reverse(db, e.id, payment.id, "", 102) end)
    rejected(db, function() return L.Reverse(db, e.id, payment.id, " \t\n", 102) end)
    rejected(db, function() return L.Reverse(db, e.id, payment.id, string.rep("x", 2001), 102) end)
    rejected(db, function() return L.Reverse(db, e.id, payment.id, "", -1) end)
end)

test("validation rejects malformed schemas, sparse arrays and bad IDs", function()
    local baseline = L.New(); entry(baseline)
    local mutations = {
        function(d) d.schema=99 end,
        function(d) d.nextID=1 end,
        function(d) d.unknown=true end,
        function(d) d.entries[1].id=2 end,
        function(d) d.entries[1].created=-1 end,
        function(d) d.entries[1].amount=0 end,
        function(d) d.entries[1].extra=true end,
        function(d) d.entries[2]=d.entries[1]; d.entries[1]=nil; d.nextID=3 end,
        function(d) d.entries.foo=true end,
        function(d) d.entries[1].events={ [2]={id=2,type="payment",amount=1,note="",at=101} } end,
    }
    for _, mutate in ipairs(mutations) do local db=copy(baseline); mutate(db); invalid(db) end
    invalid(nil); invalid("not a ledger")
end)

test("validation enforces audit references and net balance", function()
    local baseline = L.New(); local e = entry(baseline, {amount=10})
    assert(L.Pay(baseline, e.id, 4, "", 101))
    local mutations = {
        function(d) d.entries[1].events[1].id=2 end,
        function(d) d.entries[1].events[1].amount=11 end,
        function(d) d.entries[1].events[1].type="edited" end,
        function(d) d.entries[1].events[1].at=-1 end,
        function(d) d.entries[1].events[2]={id=2,type="reversal",reverses=99,note="",at=102} end,
        function(d) d.entries[1].events[2]={id=2,type="reversal",reverses=2,note="",at=102} end,
        function(d)
            d.entries[1].events[2]={id=2,type="reversal",reverses=1,note="",at=102}
            d.entries[1].events[3]={id=3,type="reversal",reverses=1,note="",at=103}
        end,
        function(d) d.entries[1].events[2]={id=2,type="reversal",reverses=1,note="  ",at=102} end,
    }
    for _, mutate in ipairs(mutations) do local db=copy(baseline); mutate(db); invalid(db) end
end)

test("mutations reject a corrupt existing ledger atomically", function()
    local db = L.New(); local e = entry(db)
    db.nextID=100
    rejected(db, function() return L.Pay(db, e.id, 1, "", 101) end)
    rejected(db, function() return L.Settle(db, e.id, "", 101) end)
    rejected(db, function() return L.Reverse(db, e.id, 1, "", 101) end)
    rejected(db, function() return L.Add(db, {player="B",direction="owe",kind="money",
        amount=1,label="",note=""}, 101) end)
end)

test("maximum amount and boundary timestamps are accepted", function()
    local db = L.New()
    local values = {player="A",direction="owed",kind="money",amount=999999999,label="",note=""}
    local e = assert(L.Add(db, values, 0))
    equal(e.created, 0); equal(L.Balance(e), 999999999)
    assert(L.Settle(db, e.id, "", 4102444800))
    equal(L.Balance(e), 0); assert(L.Validate(db))
end)

test("entry and event count limits reject without losing audit data", function()
    local db = L.New()
    entry(db, {amount=1}, 1)
    for index=2,1000 do
        local e=copy(db.entries[1]); e.id=index; e.created=index
        db.entries[index]=e
    end
    db.nextID=1001
    assert(L.Validate(db))
    equal(#db.entries, 1000)
    rejected(db, function() return L.Add(db, {player="A",direction="owed",kind="money",
        amount=1,label="",note=""}, 1001) end)
    local eventsDB = L.New(); local e = entry(eventsDB, {amount=1000})
    for index=1,200 do assert(L.Pay(eventsDB, e.id, 1, "", 100+index)) end
    equal(L.Balance(e), 800); equal(#e.events, 200)
    rejected(eventsDB, function() return L.Pay(eventsDB, e.id, 1, "", 301) end)
    rejected(eventsDB, function() return L.Settle(eventsDB, e.id, "", 301) end)
    rejected(eventsDB, function() return L.Reverse(eventsDB, e.id, 1, "", 301) end)
    assert(L.Validate(eventsDB))
end)

test("empty and populated snapshots roundtrip deterministically", function()
    local db = L.New()
    local empty = assert(C.Export(db)); assert(same(assert(C.Import(empty)), db))
    entry(db, {player="Bjørn-Realm", note="tab\tnewline\nquote \" slash \\ : ; |"})
    local e = entry(db, {kind="item", amount=20,
        label="|cff1eff00|Hitem:2447:0:0:0:0:0:0:0|h[Peacebloom]|h|r",
        note="Takk! ÆØÅ / русский / 日本語"})
    local payment = assert(L.Pay(db, e.id, 3, "første", 200))
    assert(L.Reverse(db, e.id, payment.id, "feil\nretter", 201))
    assert(L.Pay(db, e.id, 2, "andre", 202))
    local encoded = assert(C.Export(db))
    equal(encoded:sub(1,5), "IOU2:")
    assert(not encoded:find("[^\032-\126]"), "backup armor must be ASCII clipboard text")
    assert(not encoded:find("|",1,true), "item links must be armored for EditBox portability")
    local decoded = assert(C.Import(encoded))
    assert(same(db, decoded), "snapshot changed persisted data")
    equal(assert(C.Export(decoded)), encoded)
    local wrapped={" \r\n",encoded:sub(1,5)}
    for offset=6,#encoded,36 do wrapped[#wrapped+1]=encoded:sub(offset,offset+35) .. "\r\n" end
    wrapped[#wrapped+1]=" \t"
    assert(same(assert(C.Import(table.concat(wrapped))),db),"CRLF-wrapped clipboard import changed data")
    decoded.entries[1].note="edited copy"
    assert(db.entries[1].note ~= decoded.entries[1].note, "import returned aliased data")
end)

test("snapshot parser rejects truncated, appended, oversized and executable text", function()
    local db = L.New(); entry(db)
    local encoded = assert(C.Export(db))
    for _, text in ipairs({"", "IOU2\n", "IOU1\n", encoded:sub(1,-2),
        encoded .. "garbage", "garbage" .. encoded, "return {}",
        "IOU1\n0:; _G.IOU_PARSER_EXECUTED=true", string.rep("x", 1024*1024+1)}) do
        invalidSnapshot(text)
    end
    equal(_G.IOU_PARSER_EXECUTED, nil)
    invalidSnapshot(nil); invalidSnapshot({})
    assert(same(assert(C.Import(encoded)), db), "failed import affected later valid import")
end)

test("snapshot export rejects invalid data and total-size overflow", function()
    local db = L.New(); entry(db); db.schema=99
    local value, err = C.Export(db)
    assert(not value and type(err)=="string")
    local large = L.New()
    entry(large, {note=string.rep("x", 2000)}, 1)
    for index=2,600 do
        local e=copy(large.entries[1]); e.id=index; e.created=index
        large.entries[index]=e
    end
    large.nextID=601
    assert(L.Validate(large))
    value, err = C.Export(large)
    assert(not value and type(err)=="string", "export must enforce the same 1MB bound as import")
end)

test("snapshot parser rejects tampered schema, lengths, counts and audit data", function()
    local function encoded(tokens)
        local result={}
        for _, value in ipairs(tokens) do result[#result+1]=#value .. ":" .. value .. "," end
        return armor(table.concat(result))
    end
    local baseline={"1","2","1", "1","A","owed","money","10","","","100","1",
        "1","payment","4","","101"}
    assert(C.Import(encoded(baseline)))
    for _, mutation in ipairs({
        {1,"2"}, {1,"01"}, {2,"1"}, {2,"2.0"}, {3,"1001"},
        {4,"2"}, {6,"both"}, {7,"executable"}, {8,"0"},
        {8,"1e1"}, {8,"11.0"}, {8,"9999999999999999999999999"},
        {12,"201"}, {13,"2"}, {14,"reversal"}, {15,"11"}, {17,"-1"},
    }) do
        local tokens=copy(baseline); tokens[mutation[1]]=mutation[2]
        invalidSnapshot(encoded(tokens))
    end
    invalidSnapshot(armor("01:1,1:1,1:0,"))
    invalidSnapshot(armor("-1:1,1:1,1:0,"))
    invalidSnapshot(armor("999999999999999999999999:1,"))
    invalidSnapshot(armor("1:1;1:1,1:0,"))
    invalidSnapshot("IOU1:AA=A"); invalidSnapshot("IOU1:A===")
    invalidSnapshot("IOU1:____"); invalidSnapshot("IOU1:AB==")
end)

test("legacy IOU1 snapshots retain exact bytes and audit IDs", function()
    local fixture="IOU1:MToxLDE6MiwxOjEsMToxLDEzOkV4YW1wbGUtUmVhbG0sNDpvd2VkLDU6bW9uZXksNToxMDAwMCwwOiw1Okx1bmNoLDM6MTAwLDE6MiwxOjEsNzpwYXltZW50LDQ6MjUwMCw0OlBhcnQsMzoxMDEsMToyLDg6cmV2ZXJzYWwsMToxLDc6TWlzdGFrZSwzOjEwMiw="
    local db=assert(C.Import(fixture))
    equal(db.schema,1); equal(db.entries[1].id,1)
    equal(db.entries[1].events[2].reverses,1)
    equal(L.Balance(db.entries[1]),10000)
    equal(assert(C.Export(db)),fixture)
    assert(L.Validate(db))
end)

test("schema upgrade copies legacy entries and preserves every audit record", function()
    local old=legacyLedger(); local e=entry(old,{amount=100})
    local payment=assert(L.Pay(old,e.id,20,"first",101))
    assert(L.Reverse(old,e.id,payment.id,"wrong",102))
    local before=copy(old); local oldExport=assert(C.Export(old))
    local upgraded=assert(L.Upgrade(old))
    assert(same(old,before)); equal(assert(C.Export(old)),oldExport)
    equal(upgraded.schema,2); equal(upgraded.nextID,old.nextID)
    local new=upgraded.entries[1]
    equal(new.id,e.id); equal(new.created,e.created); equal(new.due,0)
    assert(same(new.events,e.events)); equal(L.Balance(new),L.Balance(e))
    assert(same(new.initial,{player=e.player,label=e.label,note=e.note,due=0}))
    new.events[1].note="copy changed"
    equal(e.events[1].note,"first")
    new.initial.player="copy changed"
    equal(e.player,"Astrid")
    local current=L.New(); local ce=entry(current)
    local recopy=assert(L.Upgrade(current))
    assert(same(current,recopy)); assert(current~=recopy)
    assert(current.entries[1]~=recopy.entries[1]); assert(ce.initial~=recopy.entries[1].initial)
end)

test("invalid upgrades and new metadata on legacy ledgers leave inputs untouched", function()
    local old=legacyLedger(); local e=entry(old)
    rejected(old,function() return L.Add(old,{player="Friend",direction="owed",kind="money",
        amount=1,label="",note="",due=150},100) end)
    rejected(old,function() return L.Amend(old,e.id,{player="Friend",label="",note="",due=0},"fix",101) end)
    rejected(old,function() return L.Cancel(old,e.id,"wrong entry",101) end)
    old.nextID=99
    rejected(old,function() return L.Upgrade(old) end)
end)

test("due dates accept bounded integer timestamps and reject malformed inputs atomically", function()
    local db=L.New()
    local first=entry(db,{due=0}); local last=entry(db,{due=L.MAX_TIMESTAMP})
    equal(first.due,0); equal(last.due,L.MAX_TIMESTAMP)
    for _,due in ipairs({-1,0.5,L.MAX_TIMESTAMP+1,"100",math.huge,0/0,false}) do
        rejected(db,function() return L.Add(db,{player="A",direction="owed",kind="money",
            amount=1,label="",note="",due=due},100) end)
    end
    local malformed=copy(db); malformed.entries[1].due=nil; invalid(malformed)
    malformed=copy(db); malformed.entries[1].initial.due=-1; invalid(malformed)
end)

test("amendments preserve financial terms and record independent metadata snapshots", function()
    local db=L.New(); local e=entry(db,{kind="item",label="Linen Cloth",amount=20,due=500})
    assert(L.Pay(db,e.id,4,"first bundle",101))
    local original=metadata(e)
    local changed={player="Other-Realm",label="Wool Cloth",note="Corrected item",due=900}
    local audit=assert(L.Amend(db,e.id,changed,"Agreed correction",102))
    equal(audit.type,"amendment"); equal(audit.id,2); equal(audit.note,"Agreed correction")
    equal(audit.at,102); assert(same(audit.before,original)); assert(same(audit.after,changed))
    equal(e.player,changed.player); equal(e.label,changed.label); equal(e.note,changed.note); equal(e.due,900)
    equal(e.amount,20); equal(e.direction,"owed"); equal(e.kind,"item"); equal(L.Balance(e),16)
    assert(same(e.initial,original)); assert(L.Validate(db))
    changed.player="caller mutation"
    equal(e.player,"Other-Realm"); equal(audit.after.player,"Other-Realm")
    assert(e.initial~=audit.before); assert(audit.before~=audit.after)
    local second=assert(L.Amend(db,e.id,metadata(e,{note="second correction"}),"More detail",103))
    assert(second.before~=audit.after); equal(audit.after.note,"Corrected item")
    assert(L.Validate(db))
end)

test("invalid amendments are atomic and require a meaningful correction reason", function()
    local db=L.New(); local e=entry(db,{due=500})
    for _,reason in ipairs({""," \t\n",string.rep("x",2001),"bad\000reason"}) do
        rejected(db,function() return L.Amend(db,e.id,metadata(e,{note="changed"}),reason,101) end)
    end
    rejected(db,function() return L.Amend(db,e.id,metadata(e),"No changes",101) end)
    rejected(db,function() return L.Amend(db,e.id,{player="Friend"},"Incomplete",101) end)
    rejected(db,function() return L.Amend(db,e.id,metadata(e,{amount=2}),"Terms",101) end)
    rejected(db,function() return L.Amend(db,e.id,metadata(e,{label="money label"}),"Label",101) end)
    rejected(db,function() return L.Amend(db,e.id,metadata(e,{due=-1}),"Date",101) end)
    rejected(db,function() return L.Amend(db,e.id,metadata(e,{note="changed"}),"Reason",-1) end)
    rejected(db,function() return L.Amend(db,999,metadata(e,{note="changed"}),"Missing",101) end)
end)

test("amendment replay rejects forged current values and discontinuous audit snapshots", function()
    local db=L.New(); local e=entry(db,{due=500})
    assert(L.Amend(db,e.id,metadata(e,{player="Changed",due=700}),"Correction",101))
    assert(L.Amend(db,e.id,metadata(e,{note="New note"}),"More detail",102))
    for _,mutate in ipairs({
        function(d) d.entries[1].player="Forged" end,
        function(d) d.entries[1].initial.player="Forged" end,
        function(d) d.entries[1].events[1].before.due=200 end,
        function(d) d.entries[1].events[1].after.player="Forged" end,
        function(d) d.entries[1].events[2].before.note="Forged" end,
        function(d) d.entries[1].events[1].after.extra=true end,
        function(d) d.entries[1].events[1].note=" " end,
        function(d) d.entries[1].events[1].after.due="700" end,
    }) do local malformed=copy(db); mutate(malformed); invalid(malformed) end
end)

test("cancellation preserves balance and moves obligations into history until restored", function()
    local db=L.New(); local e=entry(db,{amount=100,due=200})
    local payment=assert(L.Pay(db,e.id,30,"part",101))
    local cancelled=assert(L.Cancel(db,e.id,"Created for wrong player",102))
    equal(cancelled.type,"cancel"); equal(cancelled.note,"Created for wrong player"); equal(cancelled.at,102)
    equal(L.Balance(e),70); equal(L.Status(e),"cancelled"); equal(L.Cancelled(e),true)
    equal(#L.List(db,"owed",""),0); equal(#L.List(db,"history",""),1); equal(#L.List(db,"all",""),1)
    equal(L.Summary(db,"owed","",{now=300}).money,0)
    equal(L.Summary(db,"owed","",{now=300}).active,0)
    rejected(db,function() return L.Pay(db,e.id,1,"",103) end)
    rejected(db,function() return L.Settle(db,e.id,"",103) end)
    rejected(db,function() return L.Reverse(db,e.id,payment.id,"Undo",103) end)
    rejected(db,function() return L.Amend(db,e.id,metadata(e,{note="change"}),"Correction",103) end)
    rejected(db,function() return L.Cancel(db,e.id,"Again",103) end)
    local restored=assert(L.Restore(db,e.id,"Keep original agreement",104))
    equal(restored.type,"restore"); equal(L.Cancelled(e),false); equal(L.Status(e),"partial")
    equal(L.Balance(e),70); equal(#L.List(db,"history",""),0); equal(#L.List(db,"owed",""),1)
    equal(L.Summary(db,"owed","",{now=300}).money,70)
    assert(L.Validate(db)); assert(L.Pay(db,e.id,10,"after restore",105))
end)

test("cancellation and restoration enforce lifecycle and nonblank reasons atomically", function()
    local db=L.New(); local e=entry(db,{amount=10})
    rejected(db,function() return L.Restore(db,e.id,"Not cancelled",101) end)
    for _,reason in ipairs({""," \t\n",string.rep("x",2001)}) do
        rejected(db,function() return L.Cancel(db,e.id,reason,101) end)
    end
    rejected(db,function() return L.Cancel(db,999,"Missing",101) end)
    rejected(db,function() return L.Cancel(db,e.id,"Bad clock",-1) end)
    assert(L.Cancel(db,e.id,"Wrong entry",101))
    rejected(db,function() return L.Restore(db,e.id,"",102) end)
    rejected(db,function() return L.Restore(db,e.id,"Bad clock",-1) end)
    assert(L.Restore(db,e.id,"Reconsidered",102)); assert(L.Settle(db,e.id,"Paid",103))
    rejected(db,function() return L.Cancel(db,e.id,"Already paid",104) end)
    equal(L.Status(e),"settled")
end)

test("validation rejects forged cancellation histories and mutations while cancelled", function()
    local db=L.New(); local e=entry(db,{amount=100})
    assert(L.Cancel(db,e.id,"Wrong entry",101)); assert(L.Restore(db,e.id,"Keep",102))
    for _,mutate in ipairs({
        function(d) d.entries[1].events[1].type="restore" end,
        function(d) d.entries[1].events[2].type="cancel" end,
        function(d) d.entries[1].events[1].note=" " end,
        function(d) d.entries[1].events[1].amount=1 end,
        function(d) d.entries[1].events[2]={id=2,type="payment",amount=1,note="",at=102} end,
    }) do local malformed=copy(db); mutate(malformed); invalid(malformed) end
end)

test("query and kind filters agree between lists and dashboard summaries", function()
    local db=L.New()
    entry(db,{player="First",note="Shared [raid].",amount=100,due=200},100)
    local item=entry(db,{player="Second",kind="item",label="Shared [raid]. cloth",amount=20,due=100},101)
    entry(db,{player="Third",kind="favor",label="Shared boost",amount=3,due=300},102)
    entry(db,{player="Other",direction="owe",note="Shared [raid].",amount=700},103)
    local cancelled=entry(db,{player="Cancelled",note="Shared [raid].",amount=900,due=100},104)
    assert(L.Cancel(db,cancelled.id,"Ignore",105))
    local all=L.List(db,"owed","shared"); equal(#all,3)
    equal(#L.List(db,"owed","[raid]."),2); equal(#L.List(db,"owed",".*"),0)
    for _,kind in ipairs({"all","money","item","favor"}) do
        local options={kind=kind,now=201}
        local list=L.List(db,"owed","shared",options)
        local summary=L.Summary(db,"owed","shared",options)
        equal(summary.active,#list)
        equal(summary.money,(kind=="all" or kind=="money") and 100 or 0)
        equal(summary.items,(kind=="all" or kind=="item") and 1 or 0)
        equal(summary.favors,(kind=="all" or kind=="favor") and 1 or 0)
    end
    equal(L.List(db,"owed","",{kind="item"})[1],item)
    equal(L.Summary(db,"owed","shared",{now=200}).overdue,1)
    equal(L.Summary(db,"owed","shared",{now=201}).overdue,2)
end)

test("sorting is deterministic with due dates first and undated agreements last", function()
    local db=L.New()
    local a=entry(db,{player="Zed",due=0},100)
    local b=entry(db,{player="Alice",due=300},100)
    local c=entry(db,{player="Alice",due=200},100)
    local d=entry(db,{player="Bob",due=200},100)
    local function ids(options)
        local result={}
        for _,e in ipairs(L.List(db,"owed","",options)) do result[#result+1]=e.id end
        return table.concat(result,",")
    end
    equal(ids({sort="newest"}),"4,3,2,1")
    equal(ids({sort="oldest"}),"1,2,3,4")
    equal(ids({sort="player"}),"2,3,4,1")
    equal(ids({sort="due"}),"3,4,2,1")
    equal(#db.entries,4); equal(db.entries[1],a); equal(db.entries[2],b)
    equal(db.entries[3],c); equal(db.entries[4],d)
end)

test("IOU2 roundtrip preserves amended and cancelled metadata without aliasing", function()
    local db=L.New(); local e=entry(db,{player="Bjørn",kind="favor",amount=3,label="Dungeon",due=600})
    assert(L.Pay(db,e.id,1,"først",101))
    assert(L.Amend(db,e.id,metadata(e,{label="Quest [raid] | link",note="\tÆØÅ\nРусский",due=800}),"Agreed",102))
    assert(L.Cancel(db,e.id,"Pause",103)); assert(L.Restore(db,e.id,"Continue",104))
    assert(L.Cancel(db,e.id,"Archive",105))
    local encoded=assert(C.Export(db)); equal(encoded:sub(1,5),"IOU2:")
    local decoded=assert(C.Import(encoded)); assert(same(decoded,db))
    equal(assert(C.Export(decoded)),encoded); equal(L.Status(decoded.entries[1]),"cancelled")
    decoded.entries[1].events[2].after.label="changed copy"
    equal(db.entries[1].events[2].after.label,"Quest [raid] | link")
end)

test("IOU2 parser rejects header schema mismatch and every truncated field sequence", function()
    local db=L.New(); local e=entry(db,{due=200})
    assert(L.Amend(db,e.id,metadata(e,{note="corrected"}),"reason",101))
    assert(L.Cancel(db,e.id,"reason",102)); assert(L.Restore(db,e.id,"reason",103))
    local encoded=assert(C.Export(db))
    invalidSnapshot("IOU1:" .. encoded:sub(6))
    local legacy=assert(C.Export(legacyLedger()))
    invalidSnapshot("IOU2:" .. legacy:sub(6))
    for ending=5,#encoded-1 do invalidSnapshot(encoded:sub(1,ending)) end
    invalidSnapshot(encoded .. "AAAA")
    assert(same(assert(C.Import(encoded)),db))
end)

test("IOU2 parser validates due, initial metadata and amendment token contents", function()
    local function encoded(tokens)
        local result={}
        for _,value in ipairs(tokens) do result[#result+1]=#value .. ":" .. value .. "," end
        return armor(table.concat(result),"IOU2:")
    end
    local baseline={"2","2","1", "1","Changed","owed","money","10","","new","100",
        "200","A","","old","0","1", "1","amendment",
        "A","","old","0", "Changed","","new","200", "Reason","101"}
    assert(C.Import(encoded(baseline)))
    for _,mutation in ipairs({
        {1,"1"},{12,"-1"},{12,"0200"},{12,"4102444801"},
        {13,"Wrong initial"},{16,"200"},{17,"201"},{18,"2"},
        {19,"script"},{20,"Forged before"},{24,"Forged after"},
        {27,"1e2"},{28," "},{29,"-1"},
    }) do
        local tokens=copy(baseline); tokens[mutation[1]]=mutation[2]
        invalidSnapshot(encoded(tokens))
    end
end)

test("new audit operations respect the event cap without replacing audit data", function()
    local db=L.New(); local e=entry(db,{amount=1000})
    for index=1,200 do assert(L.Pay(db,e.id,1,"",100+index)) end
    rejected(db,function() return L.Amend(db,e.id,metadata(e,{note="changed"}),"Correction",301) end)
    rejected(db,function() return L.Cancel(db,e.id,"Archive",301) end)
    local cancelledDB=L.New(); local cancelled=entry(cancelledDB,{amount=1000})
    for index=1,199 do assert(L.Pay(cancelledDB,cancelled.id,1,"",100+index)) end
    assert(L.Cancel(cancelledDB,cancelled.id,"Archive",300))
    rejected(cancelledDB,function() return L.Restore(cancelledDB,cancelled.id,"Restore",301) end)
    equal(#cancelled.events,200); equal(L.Status(cancelled),"cancelled")
end)

test("entry helpers reject metatables without evaluating their fields", function()
    local reads=0
    local hostile=setmetatable({}, {__index=function() reads=reads+1; error("unexpected field access") end})
    for _,method in ipairs({L.Balance,L.Status,L.Cancelled}) do
        local ok,result=pcall(method,hostile)
        assert(ok and result==nil,"entry helper evaluated an untrusted metatable")
    end
    equal(L.IsOverdue(hostile,1000),false); equal(reads,0)
end)

test("overdue state changes only after a due timestamp and excludes closed agreements", function()
    local db=L.New(); local e=entry(db,{due=200})
    equal(L.IsOverdue(e,199),false); equal(L.IsOverdue(e,200),false); equal(L.IsOverdue(e,201),true)
    for _,now in ipairs({-1,0.5,math.huge,0/0,"201",L.MAX_TIMESTAMP+1}) do
        equal(L.IsOverdue(e,now),false)
    end
    local undated=entry(db); equal(L.IsOverdue(undated,1000),false)
    assert(L.Cancel(db,e.id,"Wrong entry",201)); equal(L.IsOverdue(e,202),false)
    assert(L.Restore(db,e.id,"Keep",203)); equal(L.IsOverdue(e,204),true)
    assert(L.Settle(db,e.id,"Paid",205)); equal(L.IsOverdue(e,206),false)
end)

local function coreSession(config)
    config=config or {}
    local state={frames={},objects={},messages={},now=1000,hooks={},chatCalls=0,
        transportSent={}}
    local env={}
    for key, value in pairs(_G) do env[key]=value end
    env._G=env; env.SlashCmdList={}; env.IOUDB=config.db
    env.UnitFullName=function()
        return config.name or "Testplayer", config.realm or "Test Realm"
    end
    env.GetRealmName=function() return "Fallback Realm" end
    env.issecretvalue=function(value) return value==config.secret and config.secret~=nil end
    env.time=function(value) return value and os.time(value) or math.floor(state.now) end
    env.GetTime=function() return state.now end
    if not config.noSharedIdentity then
        env.NameUtil={GetUnmodifiedUnitFullName=function(unit)
            if unit=="player" then return config.fullName or ((config.name or "Testplayer").." Surname") end
            if unit=="target" then return config.target end
        end}
        env.UnitIsPlayer=function(unit) return unit=="player" or (unit=="target" and config.target~=nil) end
    end
    if config.connection or config.shared then
        if not config.noConnectionAPI then env.C_ChatInfo={
            RegisterAddonMessagePrefix=function() return 0 end,
            AreOutgoingAddonChatMessagesRestricted=function() return false end,
            InChatMessagingLockdown=function() return false end,
            SendAddonMessageLogged=function(prefix,wire,channel,target)
                state.transportSent[#state.transportSent+1]={prefix=prefix,wire=wire,
                    channel=channel,target=target,at=state.now}
                return 0
            end,
        } end
        env.SendChatMessage=function() error("connection UI must not send ordinary chat") end
    end
    env.print=function(message) state.messages[#state.messages+1]=message end
    local methods={}
    local function object(kind,parent)
        local frame={kind=kind,parent=parent,events={},scripts={},shown=true,
            enabled=true,text="",width=100,height=26,verticalScroll=0}
        setmetatable(frame,{__index=methods})
        state.objects[#state.objects+1]=frame
        return frame
    end
    local noop={"SetFont","SetJustifyH","SetJustifyV","SetTextColor",
        "SetBackdrop","SetBackdropColor","SetBackdropBorderColor","SetAutoFocus",
        "SetMaxLetters","SetNumeric","SetMultiLine","SetFontObject","SetTextInsets",
        "SetFrameStrata","SetFrameLevel","SetMovable","SetClampedToScreen",
        "EnableMouse","RegisterForDrag","StartMoving","StopMovingOrSizing",
        "SetAllPoints","SetMaxLines","SetWordWrap","SetMaxBytes"}
    for _, name in ipairs(noop) do methods[name]=function() end end
    function methods:SetPoint(...) self.point={...} end
    function methods:GetPoint() return unpack(self.point or {"CENTER",env.UIParent,"CENTER",0,0}) end
    function methods:ClearAllPoints() self.point=nil end
    function methods:SetScale(value) self.scale=value end
    function methods:GetEffectiveScale() return self.scale or 1 end
    function methods:GetCenter() return self.centerX or 100,self.centerY or 100 end
    function methods:RegisterForClicks(...) self.clickButtons={...} end
    function methods:SetTexture(value) self.texture=value end
    function methods:SetHighlightTexture(value) self.highlightTexture=value end
    function methods:SetOwner(owner,anchor) self.owner=owner; self.anchor=anchor; self.lines={} end
    function methods:AddLine(text) self.lines[#self.lines+1]=text end
    function methods:RegisterEvent(event) self.events[event]=true end
    function methods:UnregisterEvent(event) self.events[event]=nil end
    function methods:UnregisterAllEvents() self.events={} end
    function methods:SetScript(event, fn) self.scripts[event]=fn end
    function methods:SetSize(w,h) self.width,self.height=w,h end
    function methods:SetWidth(w) self.width=w end
    function methods:SetHeight(h) self.height=h end
    function methods:GetWidth() return self.width end
    function methods:GetHeight() return self.height end
    function methods:SetText(text)
        self.text=tostring(text)
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self,false) end
    end
    function methods:GetText() return self.text end
    function methods:SetEnabled(value) self.enabled=value end
    function methods:Show()
        self.shown=true
        if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function methods:Hide()
        local wasShown=self.shown
        self.shown=false
        if wasShown and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function methods:SetShown(value) if value then self:Show() else self:Hide() end end
    function methods:IsShown() return self.shown end
    function methods:GetFrameLevel() return 1 end
    function methods:SetFocus()
        if state.focused==self then return end
        local previous=state.focused
        state.focused=self
        if previous then
            previous.focus=false
            if previous.scripts.OnEditFocusLost then previous.scripts.OnEditFocusLost(previous) end
        end
        self.focus=true
        if self.scripts.OnEditFocusGained then self.scripts.OnEditFocusGained(self) end
    end
    function methods:ClearFocus()
        if state.focused~=self then return end
        state.focused=nil; self.focus=false
        if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
    end
    function methods:HasFocus() return self.focus==true end
    function methods:HighlightText() self.highlighted=true end
    function methods:SetScrollChild(child) self.scrollChild=child end
    function methods:GetVerticalScroll() return self.verticalScroll end
    function methods:SetVerticalScroll(value) self.verticalScroll=value end
    function methods:GetStringHeight()
        local columns=math.max(1,math.floor(self.width/7))
        local lines=0
        for line in (self.text .. "\n"):gmatch("(.-)\n") do
            lines=lines+math.max(1,math.ceil(#line/columns))
        end
        return lines*14
    end
    function methods:CreateFontString() return object("FontString",self) end
    function methods:CreateTexture() return object("Texture",self) end
    env.CreateFrame=function(kind,name,parent)
        local frame=object(kind,parent)
        if name then env[name]=frame end
        state.frames[#state.frames+1]=frame
        return frame
    end
    env.UIParent=object("UIParent"); env.UIParent:SetSize(1920,1080)
    if not config.noMinimap then
        env.Minimap=object("Minimap",env.UIParent); env.Minimap:SetSize(140,140)
    end
    env.GameTooltip=object("GameTooltip",env.UIParent); env.GameTooltip.lines={}; env.GameTooltip:Hide()
    env.GetCursorPosition=function() return state.cursorX or 200,state.cursorY or 100 end
    env.ChatFontNormal={}; env.UISpecialFrames={}
    env.date=function(format,stamp) return os.date(format,stamp or state.now) end
    state.chat=object("EditBox",env.UIParent)
    state.chat:SetText(config.chatDraft or "Existing chat draft: ")
    local function nativeInsert(link,...)
        state.chatCalls=state.chatCalls+1
        state.chatArgs={link,...}
        state.chat:SetText(state.chat:GetText() .. link)
        -- Native chat insertion can focus a previously active, unfocused draft
        -- before secure post-hooks run. This ordering exposed the regression.
        state.chat:SetFocus()
        return "native-result",nil,"native-tail"
    end
    if not config.legacyLink then env.ChatFrameUtil={InsertLink=nativeInsert} end
    env.ChatEdit_InsertLink=nativeInsert
    env.hooksecurefunc=function(target,method,hook)
        if type(target)=="string" then target,method,hook=env,target,method end
        state.hooks[method]=hook
        local original=target[method]
        local function packed(...) return {n=select("#",...),...} end
        target[method]=function(...)
            local values=packed(original(...))
            hook(...)
            return unpack(values,1,values.n)
        end
    end
    local api={}
    for _, name in ipairs({"ledger.lua","codec.lua","shared_codec.lua","shared.lua",
        "core.lua","transport.lua","shared_wire.lua","shared_service.lua"}) do
        local chunk=assert(loadstring(assert(IOU_SOURCES[name]), "@IOU/" .. name))
        setfenv(chunk, env); chunk("IOU",api)
    end
    if config.ui then
        local chunk=assert(loadstring(assert(IOU_SOURCES["ui.lua"]),"@IOU/ui.lua"))
        setfenv(chunk,env); chunk("IOU",api)
        chunk=assert(loadstring(assert(IOU_SOURCES["shared_ui.lua"]),"@IOU/shared_ui.lua"))
        setfenv(chunk,env); chunk("IOU",api)
    end
    if config.launcher then
        local chunk=assert(loadstring(assert(IOU_SOURCES["launcher.lua"]),"@IOU/launcher.lua"))
        setfenv(chunk,env); chunk("IOU",api)
    end
    state.env=env; state.api=api
    state.binding=function(name)
        local chunk=assert(loadstring(assert(IOU_BINDINGS[name],"missing binding: " .. name),"@Bindings.xml:" .. name))
        setfenv(chunk,env); return chunk()
    end
    state.button=function(parent,text)
        for _, obj in ipairs(state.frames) do
            if obj.kind=="Button" and obj.parent==parent and obj.text==text then return obj end
        end
        error("missing button: " .. text)
    end
    state.click=function(button,mouse)
        assert(button.enabled and button.shown,"button disabled or hidden")
        assert(button.scripts.OnClick,"button has no click handler")
        return button.scripts.OnClick(button,mouse)
    end
    state.advance=function(seconds)
        for _=1,math.ceil(seconds*10) do
            state.now=state.now+0.1
            for _, frame in ipairs(state.frames) do
                if frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame,0.1) end
            end
        end
    end
    state.event=function(event,...)
        for _,frame in ipairs(state.frames) do
            if frame.events[event] and frame.scripts.OnEvent then
                frame.scripts.OnEvent(frame,event,...)
            end
        end
    end
    return state
end

local function sharedPeer(state, options)
    options=options or {}
    local api=state.api
    local name=options.name or "Remote Peer"
    local localName=assert(api.Transport.GetLocalName())
    local peer={name=name,store=assert(api.Shared.New(name)),serial=0}
    local terms={protocol=1,kind="GOLD_OBLIGATION",proposer=name,recipient=localName,
        debtor=localName,creditor=name,amountCopper=12345,dueUTC=1900000000,
        note=options.note or "Exact reviewed terms: Bj\195\184rn bl\195\165b\195\166r"}
    local actions
    peer.store,actions=api.Shared.Propose(peer.store,terms,"remote-agreement","remote-offer",state.now)
    assert(peer.store,actions); peer.proposal=actions[1].message
    function peer:deliver(message)
        self.serial=self.serial+1
        local packets=assert(api.SharedWire.Frame("ui-incoming-"..self.serial,
            assert(api.SharedCodec.Encode(message))))
        for _,packet in ipairs(packets) do
            state.event("CHAT_MSG_ADDON_LOGGED",api.SharedWire.PREFIX,packet,"WHISPER",self.name)
        end
    end
    function peer:withdraw()
        local outgoing
        self.store,outgoing=api.Shared.Withdraw(self.store,"remote-offer",state.now)
        assert(self.store,outgoing); self:deliver(outgoing[1].message)
    end
    return peer
end

local function visibleText(state, parent)
    local text={}
    for _,object in ipairs(state.objects) do
        local ancestor=object
        while ancestor and ancestor~=parent do ancestor=ancestor.parent end
        if ancestor==parent and object.text and object.text~="" then
            text[#text+1]=object.text
        end
    end
    return table.concat(text,"\n")
end

test("core startup keeps each character ledger separate", function()
    local state=coreSession()
    local api=state.api
    equal(state.env.SLASH_IOU1,"/iou")
    assert(state.env.SlashCmdList.IOU)
    equal(state.frames[1].events.PLAYER_LOGIN,true)
    state.frames[1].scripts.OnEvent(state.frames[1],"PLAYER_LOGIN")
    equal(api.Character(),"Testplayer-TestRealm")
    assert(api.GetLedger()); equal(#state.messages,1)
    local e=assert(api.Add({player="Friend",direction="owed",kind="money",amount=100,label="",note=""}))
    equal(e.created,1000)
    local original=api.GetLedger()
    local saved=state.env.IOUDB
    local other=coreSession({db=saved,name="Other"})
    assert(other.api.Initialize())
    assert(other.api.GetLedger()~=original)
    equal(#other.api.GetLedger().entries,0)
    local relog=coreSession({db=saved})
    assert(relog.api.Initialize()); equal(relog.api.GetLedger(),original)
    equal(relog.api.GetLedger().entries[1].amount,100)
end)

test("core repayment wrappers add timestamps and refresh only after success", function()
    local state=coreSession(); local api=state.api
    local refreshed=0; api.Refresh=function() refreshed=refreshed+1 end
    local e=assert(api.Add({player="Friend",direction="owe",kind="money",amount=100,label="",note=""}))
    equal(refreshed,1)
    state.now=1010
    local payment=assert(api.Pay(e.id,40,"partial"))
    equal(payment.at,1010); equal(refreshed,2)
    assert(not api.Pay(e.id,100,"overpayment")); equal(refreshed,2)
    state.now=1020
    local settled=assert(api.Settle(e.id))
    equal(settled.amount,60); equal(settled.at,1020)
    state.now=1030
    local reversal=assert(api.Reverse(e.id,settled.id,"wrong entry"))
    equal(reversal.at,1030); equal(api.Ledger.Balance(api.GetLedger().entries[1]),60)
    equal(refreshed,4)
end)

test("import preview is read-only and replacement preserves recovery snapshot", function()
    local state=coreSession(); local api=state.api
    assert(api.Add({player="Original",direction="owed",kind="money",amount=123,label="",note=""}))
    local old=assert(api.Export())
    local incoming=L.New(); entry(incoming,{player="Imported",amount=456})
    local text=assert(C.Export(incoming))
    local preview=assert(api.PreviewImport(text))
    equal(api.GetLedger().entries[1].player,"Original")
    assert(not api.PreviewImport(text .. "tampered"))
    equal(assert(api.Export()),old)
    assert(api.ReplaceLedger(preview))
    equal(api.GetLedger().entries[1].player,"Imported")
    equal(api.PreviousExport(),old)
    assert(same(assert(C.Import(api.PreviousExport())),assert(C.Import(old))))
    preview.entries[1].player="Aliased mutation"
    equal(api.GetLedger().entries[1].player,"Imported")
    local before=assert(api.Export())
    preview.schema=99
    assert(not api.ReplaceLedger(preview))
    equal(assert(api.Export()),before)
    equal(api.PreviousExport(),old)
end)

test("unsupported or corrupt saved data remains untouched", function()
    for _, saved in ipairs({
        {version=99,characters={},recovery={}},
        {version=1,characters="bad",recovery={}},
        {version=1,characters={},recovery="bad"},
        {version=1,characters={},recovery={},migrations="bad"},
        {version=1,characters={},recovery={},settings="bad"},
        {version=1,characters={["Testplayer-TestRealm"]={schema=99}},recovery={}},
    }) do
        local before=copy(saved)
        local state=coreSession({db=saved})
        local ok,err=state.api.Initialize()
        assert(not ok and type(err)=="string")
        assert(same(saved,before),"initialization rewrote corrupt data")
        assert(not state.api.Add({player="A",direction="owed",kind="money",amount=1,label="",note=""}))
        assert(same(saved,before),"mutation changed corrupt data")
    end
end)

test("core defers secret identity and supports normal realm fallback", function()
    local sentinel={}
    local state=coreSession({name=sentinel,secret=sentinel})
    assert(not state.api.Initialize())
    equal(state.env.IOUDB,nil,"unavailable identity must not create saved data")
    local fallback=coreSession({realm=""})
    assert(fallback.api.Initialize())
    equal(fallback.api.Character(),"Testplayer-FallbackRealm")
end)

test("core stages changes and rejects an unexportable draft atomically", function()
    local state=coreSession(); local api=state.api
    local e=assert(api.Add({player="Original",direction="owed",kind="money",amount=100,label="",note=""}))
    local current=api.GetLedger(); local before=assert(api.Export())
    -- Lower the isolated codec's budget to exercise its real size gate on each
    -- core write without creating a nearly-megabyte fixture for each wrapper.
    api.Codec.MAX_BYTES=#before+50
    local result,err=api.Add({player="Too large",direction="owed",kind="money",amount=1,
        label="",note=string.rep("x",1000)})
    assert(not result and type(err)=="string")
    equal(api.GetLedger(),current); equal(assert(api.Export()),before)
    result,err=api.Pay(e.id,1,string.rep("x",1000))
    assert(not result and type(err)=="string")
    equal(api.GetLedger(),current); equal(assert(api.Export()),before)
    equal(#current.entries[1].events,0)
end)

test("core migrates only the active character and saves its original IOU1 snapshot", function()
    local legacy=legacyLedger(); local e=entry(legacy,{amount=100})
    local pay=assert(L.Pay(legacy,e.id,25,"part",101))
    assert(L.Reverse(legacy,e.id,pay.id,"wrong",102))
    local before=copy(legacy); local original=assert(C.Export(legacy))
    local other=legacyLedger(); entry(other,{player="Other ledger"})
    local saved={version=1,characters={["Testplayer-TestRealm"]=legacy,["Other-TestRealm"]=other},
        recovery={["Other-TestRealm"]="existing backup"},migrations={["Other-TestRealm"]="existing migration"}}
    local state=coreSession({db=saved}); local api=state.api
    assert(api.Initialize()); equal(api.GetLedger().schema,2)
    equal(saved.characters["Other-TestRealm"],other); equal(other.schema,1)
    assert(same(legacy,before)); equal(saved.migrations["Testplayer-TestRealm"],original)
    equal(api.MigrationExport(),original); equal(saved.recovery["Other-TestRealm"],"existing backup")
    equal(saved.migrations["Other-TestRealm"],"existing migration")
    equal(api.GetLedger().entries[1].events[2].reverses,1)
    equal(L.Balance(api.GetLedger().entries[1]),100)
    local current=api.GetLedger()
    local relog=coreSession({db=saved}); assert(relog.api.Initialize())
    equal(relog.api.GetLedger(),current); equal(relog.api.MigrationExport(),original)
end)

test("migration rejects export overflow without altering any saved table", function()
    local legacy=legacyLedger(); entry(legacy,{note="Original"})
    local saved={version=1,characters={["Testplayer-TestRealm"]=legacy},recovery={}}
    local before=copy(saved); local state=coreSession({db=saved})
    state.api.Codec.MAX_BYTES=#assert(C.Export(legacy))
    local ok,err=state.api.Initialize()
    assert(not ok and type(err)=="string")
    assert(same(saved,before),"failed migration changed saved data")
    equal(state.api.GetLedger(),nil)
end)

test("legacy import previews upgrade without mutating the live ledger or backup", function()
    local state=coreSession(); local api=state.api
    assert(api.Add({player="Current",direction="owed",kind="money",amount=100,label="",note=""}))
    local old=assert(api.Export()); local legacy=legacyLedger(); entry(legacy,{player="Legacy"})
    local legacyText=assert(C.Export(legacy)); local before=copy(legacy)
    local preview=assert(api.PreviewImport(legacyText))
    equal(preview.schema,2); equal(preview.entries[1].due,0)
    assert(same(legacy,before)); equal(assert(api.Export()),old); equal(api.PreviousExport(),nil)
    assert(api.ReplaceLedger(preview)); equal(api.GetLedger().schema,2)
    equal(api.GetLedger().entries[1].player,"Legacy"); equal(api.PreviousExport(),old)
    preview.entries[1].initial.player="aliased copy"
    equal(api.GetLedger().entries[1].initial.player,"Legacy")
end)

test("core metadata, cancellation and restoration commit atomically with timestamps", function()
    local state=coreSession(); local api=state.api; local refreshes=0
    api.Refresh=function() refreshes=refreshes+1 end
    local e=assert(api.Add({player="A",direction="owed",kind="money",amount=100,label="",note="",due=500}))
    state.now=1010
    local amended=assert(api.Amend(e.id,metadata(e,{player="B",due=700}),"Corrected"))
    equal(amended.at,1010); equal(api.GetLedger().entries[1].player,"B")
    state.now=1020
    local cancelled=assert(api.Cancel(e.id,"Wrong agreement")); equal(cancelled.at,1020)
    equal(L.Status(api.GetLedger().entries[1]),"cancelled")
    local current=api.GetLedger(); local before=assert(api.Export()); local count=refreshes
    assert(not api.Pay(e.id,1,"")); assert(not api.Amend(e.id,metadata(current.entries[1],{note="change"}),"Reason"))
    equal(api.GetLedger(),current); equal(assert(api.Export()),before); equal(refreshes,count)
    state.now=1030
    local restored=assert(api.Restore(e.id,"Keep agreement")); equal(restored.at,1030)
    equal(L.Status(api.GetLedger().entries[1]),"outstanding"); equal(refreshes,4)
end)

test("core rejects oversized new audit events without changing history or notifications", function()
    local state=coreSession(); local api=state.api; local refreshes=0
    api.Refresh=function() refreshes=refreshes+1 end
    local e=assert(api.Add({player="A",direction="owed",kind="money",amount=100,label="",note=""}))
    local function budgetReject(operation)
        local before=assert(api.Export()); local current=api.GetLedger(); local count=refreshes
        api.Codec.MAX_BYTES=#before+40
        local result,err=operation()
        assert(not result and type(err)=="string")
        equal(api.GetLedger(),current); equal(assert(api.Export()),before); equal(refreshes,count)
        api.Codec.MAX_BYTES=C.MAX_BYTES
    end
    budgetReject(function() return api.Amend(e.id,metadata(api.GetLedger().entries[1],{note=string.rep("x",1000)}),"Reason") end)
    budgetReject(function() return api.Cancel(e.id,string.rep("x",1000)) end)
    assert(api.Cancel(e.id,"Archive"))
    budgetReject(function() return api.Restore(e.id,string.rep("x",1000)) end)
    equal(L.Status(api.GetLedger().entries[1]),"cancelled")
    equal(#api.GetLedger().entries[1].events,1)
end)

test("due date input validates leap days and stores the end of the entered day", function()
    local api=coreSession().api
    equal(api.ParseDueDate(""),0); equal(api.ParseDueDate(" \t"),0)
    local stamp=assert(api.ParseDueDate("2028-02-29"))
    equal(os.date("%Y-%m-%d %H:%M:%S",stamp),"2028-02-29 23:59:59")
    equal(api.FormatDueDate(stamp),"2028-02-29"); equal(api.FormatDueDate(0),"")
    for _,value in ipairs({"2027-02-29","2026-04-31","2026-00-01","2026-13-01",
        "2026-01-00","2026-01-32","26-01-01","2026-1-01","1969-12-31","2100-01-01"}) do
        local result,err=api.ParseDueDate(value)
        assert(not result and type(err)=="string","invalid due date accepted: " .. value)
    end
end)

test("login reminders count overdue open entries and obey the saved toggle", function()
    local db=L.New(); entry(db,{due=200}); entry(db,{direction="owe",due=300})
    local settled=entry(db,{due=100}); assert(L.Settle(db,settled.id,"Paid",101))
    local cancelled=entry(db,{due=100}); assert(L.Cancel(db,cancelled.id,"Wrong",101))
    local saved={version=1,characters={["Testplayer-TestRealm"]=db},recovery={},settings={reminders=true}}
    local state=coreSession({db=saved})
    state.frames[1].scripts.OnEvent(state.frames[1],"PLAYER_LOGIN")
    equal(#state.messages,2); assert(state.messages[2]:find("1 owed to you, 1 you owe",1,true))
    saved.settings.reminders=false
    local quiet=coreSession({db=saved}); quiet.frames[1].scripts.OnEvent(quiet.frames[1],"PLAYER_LOGIN")
    equal(#quiet.messages,1)
end)

test("UI creates gold IOUs and rejects invalid coins without mutation", function()
    local state=coreSession({ui=true}); local api=state.api
    state.env.SlashCmdList.IOU("")
    local ui=api.UI
    assert(ui.main:IsShown()); equal(ui.empty:GetText(),"No open IOUs.\n\nStart with + New IOU.")
    api.ShowAdd(); local form=ui.add
    form.player:SetText("Friend"); form.money[1]:SetText("1")
    form.money[2]:SetText("100"); form.money[3]:SetText("45")
    state.click(state.button(form,"Create IOU"))
    equal(#api.GetLedger().entries,0); assert(form.error:GetText()~="")
    form.money[2]:SetText("23"); form.note:SetText("Raid split |cffff0000literal")
    state.click(state.button(form,"Create IOU"))
    equal(#api.GetLedger().entries,1)
    equal(api.GetLedger().entries[1].amount,12345)
    equal(ui.cards[1].value:GetText(),"1g 23s 45c")
    equal(ui.rows[1].player:GetText(),"Friend")
    assert(not form:IsShown()); assert(ui.main:IsShown())
    local foundEscaped=false
    for _, obj in ipairs(state.objects) do
        if obj.kind=="FontString" and obj.text:find("Raid split ||cffff0000literal",1,true) then foundEscaped=true end
    end
    assert(foundEscaped,"free text pipes should render literally")
end)

test("UI captures item links, changes direction, and records deliveries", function()
    local state=coreSession({ui=true}); local api=state.api
    assert(api.Initialize()); api.ShowAdd()
    local ui,form=api.UI,api.UI.add
    state.click(form.dirButtons.owe); state.click(form.kindButtons.item)
    form.player:SetText("Herbalist"); form.quantity:SetText("20"); form.label:SetFocus()
    local link="|cff1eff00|Hitem:2447:0:0:0:0:0:0:0|h[Peacebloom]|h|r"
    state.env.ChatFrameUtil.InsertLink(link); equal(form.label:GetText(),link)
    state.click(state.button(form,"Create IOU"))
    equal(ui.tab,"owe"); equal(api.GetLedger().entries[1].label,link)
    equal(ui.balance:GetText(),"20 x [Peacebloom]")
    equal(ui.pay:GetText(),"Record delivery")
    state.click(ui.pay); local action=ui.action
    assert(action.unitsGroup:IsShown()); assert(not action.moneyGroup:IsShown())
    action.quantity:SetText("7"); action.note:SetText("First bundle")
    state.click(action.confirm)
    equal(api.Ledger.Balance(api.GetLedger().entries[1]),13)
    equal(ui.balance:GetText(),"13 x [Peacebloom]")
end)

test("UI captures focused item links before chat insertion and forwards other links", function()
    local link="|cff1eff00|Hitem:2447:0:0:0:0:0:0:0|h[Peacebloom]|h|r"
    for _, legacy in ipairs({false,true}) do
        local state=coreSession({ui=true,legacyLink=legacy,chatDraft="/w Friend unfinished draft "})
        local api=state.api
        assert(api.Initialize()); api.ShowAdd()
        local form=api.UI.add
        state.click(form.kindButtons.item)
        form.label:SetFocus()
        local insert=legacy and state.env.ChatEdit_InsertLink or state.env.ChatFrameUtil.InsertLink
        local draft=state.chat:GetText()
        local result=insert(link,"extra",42)
        equal(result,true)
        equal(form.label:GetText(),link)
        equal(state.chat:GetText(),draft,"captured link leaked into active chat draft")
        equal(state.chatCalls,0)
        assert(form.label:HasFocus())
        form.player:SetFocus()
        local first,second,third=insert(link,"forwarded",42)
        equal(first,"native-result"); equal(second,nil); equal(third,"native-tail")
        equal(state.chatCalls,1); equal(state.chat:GetText(),draft .. link)
        equal(state.chatArgs[2],"forwarded"); equal(state.chatArgs[3],42)
        assert(state.chat:HasFocus()); assert(not form.label:HasFocus())
        api.ShowAdd(); api.ShowAdd()
        local after=legacy and state.env.ChatEdit_InsertLink or state.env.ChatFrameUtil.InsertLink
        equal(after,insert,"reopening form repeatedly wrapped native chat insertion")
        state.click(form.kindButtons.item); form.label:SetFocus(); form:Hide()
        local forwarded=after(link)
        equal(forwarded,"native-result"); equal(state.chatCalls,2)
    end
end)

test("UI payment, settlement, history, and reversal actions follow balances", function()
    local state=coreSession({ui=true}); local api=state.api
    local e=assert(api.Add({player="Friend",direction="owed",kind="money",amount=1000,label="",note=""}))
    api.Toggle(); local ui=api.UI
    state.click(ui.pay); local action=ui.action
    action.money:Fill(400); state.click(action.confirm)
    equal(api.Ledger.Balance(api.GetLedger().entries[1]),600)
    state.click(ui.settle); state.click(action.confirm)
    equal(api.Ledger.Balance(api.GetLedger().entries[1]),0)
    equal(ui.tab,"history"); equal(ui.selected,e.id); assert(not ui.pay.enabled)
    equal(ui.selected,e.id); equal(ui.balance:GetText(),"0g 00s 00c")
    api.ShowAction("reverse",e.id,2); action.note:SetText("Receipt was wrong")
    state.click(action.confirm)
    equal(api.Ledger.Balance(api.GetLedger().entries[1]),600)
    equal(ui.tab,"owed")
    equal(ui.selected,e.id); equal(ui.balance:GetText(),"0g 06s 00c")
end)

test("UI search, pagination and timeline reuse stay bounded", function()
    local state=coreSession({ui=true}); local api=state.api
    for index=1,12 do
        assert(api.Add({player="Player" .. index,direction="owed",kind="money",amount=100,label="",note=""}))
    end
    api.Toggle(); local ui=api.UI
    equal(ui.pages:GetText(),"Page 1 / 3  -  12 IOUs")
    state.click(ui.next); equal(ui.page,2); equal(ui.selected,7)
    state.click(ui.next); equal(ui.page,3); equal(ui.selected,2); assert(not ui.next.enabled)
    ui.search:SetText("Player12")
    equal(ui.page,1); equal(ui.selected,12); equal(ui.rows[1].player:GetText(),"Player12")
    equal(ui.pages:GetText(),"Page 1 / 1  -  1 IOUs")
    assert(api.Pay(12,10,"first")); assert(api.Pay(12,20,"second"))
    local objectCount=#state.objects
    for _=1,30 do api.Refresh() end
    equal(#state.objects,objectCount,"refresh leaked new timeline frames or font strings")
    ui.search:SetText("Nobody"); equal(ui.selected,nil); equal(ui.empty:GetText(),"No matching IOUs.")
    api.ShowAdd()
    local form=ui.add
    form.player:SetText("New player"); form.money:Fill(100)
    state.click(state.button(form,"Create IOU"))
    equal(ui.search:GetText(),""); equal(ui.selected,13)
    equal(ui.rows[1].player:GetText(),"New player")
end)

test("UI imports require valid preview and invalidate it when text changes", function()
    local state=coreSession({ui=true}); local api=state.api
    assert(api.Add({player="Original",direction="owe",kind="money",amount=100,label="",note=""}))
    local old=assert(api.Export())
    local incoming=L.New(); entry(incoming,{player="Incoming"})
    local text=assert(C.Export(incoming))
    api.ShowBackup("import"); local backup=api.UI.backup
    equal(backup.box:GetText(),""); assert(not backup.replace:IsShown())
    backup.box:SetText(text); state.click(backup.preview)
    assert(backup.candidate); assert(backup.replace:IsShown())
    equal(api.GetLedger().entries[1].player,"Original")
    backup.box:SetText(text .. "broken")
    equal(backup.candidate,nil); assert(not backup.replace:IsShown())
    state.click(backup.preview)
    assert(not backup.replace:IsShown()); equal(assert(api.Export()),old)
    backup.box:SetText(text); state.click(backup.preview)
    assert(api.Pay(1,1,"Changed after preview"))
    local changed=assert(api.Export())
    state.click(backup.replace)
    equal(assert(api.Export()),changed); equal(backup.candidate,nil)
    assert(not backup.replace:IsShown())
    assert(backup.status:GetText():find("ledger changed",1,true))
    backup.box:SetText(text); state.click(backup.preview); state.click(backup.replace)
    equal(api.GetLedger().entries[1].player,"Incoming")
    equal(api.PreviousExport(),changed)
    assert(not backup.replace:IsShown()); equal(backup.candidate,nil)
end)

test("UI paginates a full audit trail with a fixed object pool", function()
    local db=L.New(); local e=entry(db,{amount=1000,note=string.rep("x",2000)})
    for index=1,200 do
        e.events[index]={id=index,type="payment",amount=1,note=string.rep("x",2000),at=100+index}
    end
    assert(L.Validate(db)); assert(C.Export(db))
    local state=coreSession({ui=true,db={version=1,
        characters={["Testplayer-TestRealm"]=db},recovery={}}})
    assert(state.api.Initialize()); state.api.Toggle()
    local ui=state.api.UI
    equal(ui.historyPages:GetText(),"1 / 20")
    local function undoCount()
        local count=0
        for _, frame in ipairs(state.frames) do
            if frame.parent==ui.detailContent and frame.text=="Undo" and frame.shown then count=count+1 end
        end
        return count
    end
    equal(undoCount(),10)
    state.click(ui.historyNext); equal(ui.historyPage,2); equal(undoCount(),10)
    state.click(ui.historyPrevious); equal(ui.historyPage,1)
    local objectCount=#state.objects
    for page=1,20 do ui.historyPage=page; state.api.Refresh(); equal(undoCount(),10) end
    equal(ui.historyPages:GetText(),"20 / 20")
    assert(not ui.historyNext.enabled)
    equal(#state.objects,objectCount,"history navigation expanded an already-sized object pool")
end)

test("UI bounds newline-heavy previews and preserves full note text", function()
    local note=string.rep("\n",2000)
    local db=L.New(); local e=entry(db,{amount=1000,note=note})
    for index=1,25 do
        e.events[index]={id=index,type="payment",amount=1,note=note,at=100+index}
    end
    local state=coreSession({ui=true,db={version=1,
        characters={["Testplayer-TestRealm"]=db},recovery={}}})
    assert(state.api.Initialize()); state.api.Toggle()
    local api,ui=state.api,state.api.UI
    assert(ui.detailContent:GetHeight()<10000,"newline-heavy notes exceeded timeline geometry budget")
    local function fullNoteButtons()
        local count=0
        for _, frame in ipairs(state.frames) do
            if frame.parent==ui.detailContent and frame.text=="Full note" and frame.shown then count=count+1 end
        end
        return count
    end
    equal(fullNoteButtons(),11,"agreement plus ten notes need full-note controls")
    local objectCount=#state.objects
    for page=1,3 do ui.historyPage=page; api.Refresh() end
    equal(#state.objects,objectCount,"note navigation leaked new controls")
    state.click(state.button(ui.detailContent,"Full note"))
    local full="|cffff0000" .. string.rep("\n",1990)
    api.ShowNote(full)
    local escaped=full:gsub("|","||")
    local found=false
    for _, obj in ipairs(state.objects) do
        if obj.kind=="FontString" and obj.text==escaped then
            found=true
            assert(obj:GetStringHeight()<30000,"full note exceeds client geometry budget")
        end
    end
    assert(found,"full note viewer changed or truncated the stored note")
    equal(api.GetLedger().entries[1].note,note)
    equal(api.GetLedger().entries[1].events[1].note,note)
end)

test("UI rejects stale payment form after ledger replacement", function()
    local state=coreSession({ui=true}); local api=state.api
    local e=assert(api.Add({player="Original",direction="owed",kind="money",amount=100,label="",note=""}))
    api.Toggle(); api.ShowAction("payment",e.id)
    local action=api.UI.action
    assert(api.ReplaceLedger(L.New()))
    state.click(action.confirm)
    equal(#api.GetLedger().entries,0)
    assert(action.error:GetText():find("ledger changed",1,true))
end)

test("UI validates due dates and requires reasons for metadata corrections", function()
    local state=coreSession({ui=true}); local api=state.api
    api.ShowAdd(); local ui,form=api.UI,api.UI.add
    form.player:SetText("Original"); form.money:Fill(100)
    form.due:SetText("2027-02-29")
    state.click(state.button(form,"Create IOU"))
    equal(#api.GetLedger().entries,0); assert(form.error:GetText()~="")
    form.due:SetText("2028-02-29"); state.click(state.button(form,"Create IOU"))
    local e=api.GetLedger().entries[1]
    equal(api.FormatDueDate(e.due),"2028-02-29"); assert(ui.due:GetText():find("2028-02-29",1,true))
    state.click(ui.edit); local edit=ui.editForm
    equal(edit.player:GetText(),"Original"); equal(edit.due:GetText(),"2028-02-29")
    edit.player:SetText("Corrected"); edit.note:SetText("Quest split")
    state.click(edit.save); equal(api.GetLedger().entries[1].player,"Original")
    assert(edit.error:GetText()~="")
    edit.reason:SetText("Correct character"); edit.due:SetText("2028-03-01"); state.click(edit.save)
    e=api.GetLedger().entries[1]
    equal(e.player,"Corrected"); equal(e.note,"Quest split"); equal(e.amount,100)
    equal(api.FormatDueDate(e.due),"2028-03-01"); equal(#e.events,1)
    equal(e.events[1].type,"amendment"); equal(e.events[1].before.player,"Original")
    equal(e.events[1].after.player,"Corrected"); assert(not edit:IsShown())
    equal(ui.peer:GetText(),"Corrected")
end)

test("UI cancellation and restoration keep balances and expose required reasons", function()
    local state=coreSession({ui=true}); local api=state.api
    local e=assert(api.Add({player="Friend",direction="owed",kind="money",amount=100,label="",note=""}))
    assert(api.Pay(e.id,25,"part")); api.Toggle(); local ui=api.UI
    state.click(ui.cancel); local action=ui.action
    equal(action.mode,"cancel"); assert(not action.moneyGroup:IsShown()); assert(not action.unitsGroup:IsShown())
    state.click(action.confirm); equal(#api.GetLedger().entries[1].events,1)
    assert(action.error:GetText()~="")
    action.note:SetText("Wrong agreement"); state.click(action.confirm)
    equal(ui.tab,"history"); equal(ui.selected,e.id); equal(ui.balance:GetText(),"0g 00s 75c")
    equal(L.Status(api.GetLedger().entries[1]),"cancelled")
    assert(not ui.pay.enabled and not ui.settle.enabled and not ui.edit.enabled)
    equal(ui.cancel:GetText(),"Restore IOU"); equal(ui.cards[1].value:GetText(),"0g 00s 00c")
    state.click(ui.cancel); equal(action.mode,"restore")
    action.note:SetText("Agreed to keep"); state.click(action.confirm)
    equal(ui.tab,"owed"); equal(ui.selected,e.id); equal(L.Balance(api.GetLedger().entries[1]),75)
    equal(ui.cancel:GetText(),"Cancel IOU"); assert(ui.pay.enabled and ui.edit.enabled)
    equal(#api.GetLedger().entries[1].events,3)
end)

test("UI type, search and sort controls keep rows and totals consistent", function()
    local state=coreSession({ui=true}); local api=state.api
    assert(api.Add({player="Zed",direction="owed",kind="money",amount=100,label="",note="Raid [42]",due=0}))
    assert(api.Add({player="Alice",direction="owed",kind="item",amount=20,label="Raid cloth",note="Bundle",due=300}))
    assert(api.Add({player="Bob",direction="owed",kind="favor",amount=3,label="Quest help",note="Raid [42]",due=200}))
    api.Toggle(); local ui=api.UI
    equal(ui.rows[1].player:GetText(),"Bob")
    state.click(ui.sortButton); equal(ui.sort,"oldest"); equal(ui.rows[1].player:GetText(),"Zed")
    state.click(ui.sortButton); equal(ui.sort,"player"); equal(ui.rows[1].player:GetText(),"Alice")
    state.click(ui.sortButton); equal(ui.sort,"due"); equal(ui.rows[1].player:GetText(),"Bob")
    state.click(ui.typeButtons.item); equal(ui.kind,"item"); equal(ui.rows[1].player:GetText(),"Alice")
    equal(ui.pages:GetText(),"Page 1 / 1  -  1 IOUs"); equal(ui.cards[1].value:GetText(),"0g 00s 00c")
    assert(ui.cards[1].counts:GetText():find("1 item",1,true))
    state.click(ui.typeButtons.all); ui.search:SetText("[42]")
    equal(ui.pages:GetText(),"Page 1 / 1  -  2 IOUs"); equal(ui.cards[1].value:GetText(),"0g 01s 00c")
    ui.search:SetText("cloth"); equal(ui.selected,2)
    equal(ui.cards[1].value:GetText(),"0g 00s 00c")
    state.click(ui.typeButtons.item); api.ShowAdd()
    local form=ui.add
    form.player:SetText("Visible new gold"); form.money:Fill(500)
    state.click(state.button(form,"Create IOU"))
    equal(ui.kind,"all"); equal(ui.search:GetText(),""); equal(ui.selected,4)
end)

test("UI rejects metadata forms made stale by a committed repayment", function()
    local state=coreSession({ui=true}); local api=state.api
    local e=assert(api.Add({player="Original",direction="owed",kind="money",amount=100,label="",note=""}))
    api.Toggle(); api.ShowEdit(); local form=api.UI.editForm
    form.player:SetText("Stale edit"); form.reason:SetText("Correction")
    assert(api.Pay(e.id,1,"New receipt"))
    state.click(form.save)
    equal(api.GetLedger().entries[1].player,"Original"); equal(L.Balance(api.GetLedger().entries[1]),99)
    assert(form.error:GetText():find("ledger changed",1,true))
    equal(#api.GetLedger().entries[1].events,1)
end)

test("UI metadata corrections preserve an unchanged imported due timestamp", function()
    local state=coreSession({ui=true}); local api=state.api
    local due=os.time({year=2027,month=7,day=12,hour=9,min=4,sec=2})
    assert(api.Add({player="Friend",direction="owed",kind="money",amount=100,label="",note="",due=due}))
    api.Toggle(); api.ShowEdit(); local form=api.UI.editForm
    equal(form.due:GetText(),"2027-07-12")
    form.note:SetText("Corrected note"); form.reason:SetText("More detail")
    state.click(form.save)
    equal(api.GetLedger().entries[1].due,due)
    equal(api.GetLedger().entries[1].events[1].before.due,due)
    equal(api.GetLedger().entries[1].events[1].after.due,due)
end)

test("UI saves dragged window position, restores it on login and resets by slash", function()
    local state=coreSession({ui=true}); local api=state.api
    assert(api.Initialize()); api.Toggle()
    local main=api.UI.main
    main:SetPoint("TOPLEFT",state.env.UIParent,"TOPLEFT",55,-85)
    main.scripts.OnDragStop(main)
    local position=api.GetSettings().position
    equal(position.point,"TOPLEFT"); equal(position.relativePoint,"TOPLEFT")
    equal(position.x,55); equal(position.y,-85)
    local relog=coreSession({ui=true,db=state.env.IOUDB})
    assert(relog.api.Initialize()); relog.api.Toggle()
    local point,relative,relativePoint,x,y=relog.api.UI.main:GetPoint()
    equal(point,"TOPLEFT"); equal(relative,relog.env.UIParent); equal(relativePoint,"TOPLEFT")
    equal(x,55); equal(y,-85)
    relog.env.SlashCmdList.IOU("resetpos")
    equal(relog.api.GetSettings().position,nil); equal(relog.api.UI.main:GetPoint(),"CENTER")
end)

test("minimap launcher and key binding open the ledger and create form", function()
    local state=coreSession({ui=true,launcher=true}); local api=state.api
    equal(state.env.BINDING_HEADER_IOU,"IOU")
    assert(type(state.env.IOU_ToggleLedger)=="function")
    state.frames[1].scripts.OnEvent(state.frames[1],"PLAYER_LOGIN")
    local launcher=assert(api.launcher)
    assert(launcher:IsShown()); equal(launcher.parent,state.env.Minimap)
    equal(launcher.scripts.OnUpdate,nil,"idle launcher must not poll every frame")
    state.click(launcher,"LeftButton"); assert(api.UI.main:IsShown())
    state.binding("IOU_TOGGLE"); assert(not api.UI.main:IsShown())
    state.click(launcher,"RightButton"); assert(api.UI.main:IsShown()); assert(api.UI.add:IsShown())
    assert(api.Add({player="Friend",direction="owed",kind="money",amount=12345,label="",note=""}))
    launcher.scripts.OnEnter(launcher)
    local tooltip=state.env.GameTooltip
    assert(tooltip:IsShown()); equal(tooltip.owner,launcher)
    assert(table.concat(tooltip.lines,"\n"):find("Owed to you: 1g 23s 45c",1,true))
    launcher.scripts.OnLeave(launcher); assert(not tooltip:IsShown())
    local count=#state.objects
    for _=1,10 do api.UpdateLauncher() end
    equal(#state.objects,count,"launcher refresh created duplicate UI objects")
end)

test("minimap dragging stores its angle and removes the update handler when released", function()
    local state=coreSession({ui=true,launcher=true}); local api=state.api
    assert(api.Initialize()); api.UpdateLauncher(); local button=api.launcher
    state.cursorX,state.cursorY=200,100
    button.scripts.OnDragStart(button)
    equal(api.GetSettings().minimapAngle,0); assert(type(button.scripts.OnUpdate)=="function")
    state.cursorX,state.cursorY=100,200
    button.scripts.OnUpdate(button)
    assert(math.abs(api.GetSettings().minimapAngle-90)<0.001)
    local point,parent,relative,x,y=button:GetPoint()
    equal(point,"CENTER"); equal(parent,state.env.Minimap); equal(relative,"CENTER")
    assert(math.abs(x)<0.001 and math.abs(y-76)<0.001)
    button.scripts.OnDragStop(button); equal(button.scripts.OnUpdate,nil)
    api.SetMinimap(false); assert(not button:IsShown()); equal(button.scripts.OnUpdate,nil)
    local relog=coreSession({ui=true,launcher=true,db=state.env.IOUDB})
    assert(relog.api.Initialize()); relog.api.UpdateLauncher()
    assert(not relog.api.launcher:IsShown())
    assert(math.abs(relog.api.GetSettings().minimapAngle-90)<0.001)
end)

test("settings controls persist account preferences and slash commands update launcher", function()
    local state=coreSession({ui=true,launcher=true}); local api=state.api
    assert(api.Initialize()); api.UpdateLauncher(); api.ShowSettings()
    local settings=api.UI.settings
    state.click(settings.minimap)
    equal(api.GetSettings().minimap,false); assert(not api.launcher:IsShown())
    state.click(settings.reminders); equal(api.GetSettings().reminders,false)
    equal(settings.minimap:GetText(),"Minimap button: hidden")
    equal(settings.reminders:GetText(),"Login reminders: off")
    state.env.SlashCmdList.IOU("minimap show"); assert(api.launcher:IsShown())
    state.env.SlashCmdList.IOU("reminders on"); equal(api.GetSettings().reminders,true)
    state.env.SlashCmdList.IOU("minimap hide"); assert(not api.launcher:IsShown())
    local other=coreSession({db=state.env.IOUDB,name="Other"}); assert(other.api.Initialize())
    equal(other.api.GetSettings().minimap,false); equal(other.api.GetSettings().reminders,true)
    equal(#other.api.GetLedger().entries,0)
end)

test("key binding remains usable when the client has no Minimap frame", function()
    local state=coreSession({ui=true,launcher=true,noMinimap=true}); local api=state.api
    assert(api.Initialize()); api.UpdateLauncher(); equal(api.launcher,nil)
    state.env.IOU_ToggleLedger(); assert(api.UI.main:IsShown())
end)

test("editing an existing item captures links before native chat without opening Add", function()
    local state=coreSession({ui=true,chatDraft="/w Friend keep this draft "})
    local api=state.api
    local e=assert(api.Add({player="Friend",direction="owed",kind="item",amount=20,label="Cloth",note="",due=0}))
    api.Toggle(); api.ShowEdit()
    equal(api.UI.add,nil)
    local form=api.UI.editForm
    form.label:SetFocus()
    local draft=state.chat:GetText()
    local link="|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"
    equal(state.env.ChatFrameUtil.InsertLink(link),true)
    equal(form.label:GetText(),link); equal(state.chat:GetText(),draft); equal(state.chatCalls,0)
    form.reason:SetText("Specify the item"); state.click(form.save)
    equal(api.GetLedger().entries[e.id].label,link)
    equal(api.GetLedger().entries[e.id].events[1].before.label,"Cloth")
end)

test("connection UI and slash prefill preserve UTF-8 names and require explicit Listen then Run", function()
    local state=coreSession({ui=true,connection=true})
    local api=state.api
    assert(api.Initialize())
    assert(api.Add({player="Ledger Peer",direction="owed",kind="money",amount=123,label="",note="Private ledger note"}))
    local before=copy(state.env.IOUDB)
    local peer="Bj\195\184Rn \195\152Rn"
    state.env.SlashCmdList.IOU("  TEST "..peer.."  ")
    local form=api.UI.connection
    assert(form:IsShown()); equal(form.peer:GetText(),peer)
    equal(#state.transportSent,0); assert(not api.Transport.IsListening())
    assert(form.listen.enabled and not form.run.enabled and not form.stop.enabled)
    state.click(form.listen)
    assert(api.Transport.IsListening()); equal(#state.transportSent,0)
    assert(not form.listen.enabled and form.run.enabled and form.stop.enabled)
    assert(not form.peer.enabled and not form.target.enabled)
    state.click(form.run); equal(#state.transportSent,1)
    assert(not form.run.enabled,"running connection test allowed a duplicate start")
    state.advance(5); equal(#state.transportSent,4)
    for _,packet in ipairs(state.transportSent) do
        equal(packet.target,peer); equal(packet.channel,"WHISPER")
        equal(packet.prefix,api.Transport.PREFIX)
        assert(api.Transport.Parse(packet.wire)); assert(#packet.wire<=240)
    end
    assert(same(state.env.IOUDB,before),"connection controls changed saved ledger")
    assert(not api.Transport.GetReport():find("Private ledger note",1,true))
    form:Hide(); assert(not api.Transport.IsListening())
end)

test("connection report copy keeps selected text stable and closing the window cancels traffic", function()
    local state=coreSession({ui=true,connection=true})
    local api=state.api
    api.ShowConnectionTest("Peer Surname")
    local form=api.UI.connection
    state.click(form.listen); state.click(form.run)
    state.click(form.copy)
    assert(form.box:HasFocus() and form.box.highlighted)
    assert(form.box:GetText():find("IOU LINK TEST",1,true))
    equal(form.scroll:GetVerticalScroll(),0)
    form.box:SetText("Selected report text")
    state.advance(5)
    equal(form.box:GetText(),"Selected report text","refresh replaced the selected copy buffer")
    state.click(form.copy)
    assert(form.box:GetText():find("4. 240-byte UTF-8",1,true))
    form.box.scripts.OnEscapePressed(form.box)
    assert(not form:IsShown(),"Escape while copying left the listener active")
    assert(not form.box:HasFocus() and not form.peer:HasFocus())
    assert(not api.Transport.IsListening())
    local count=#state.transportSent
    state.advance(60); equal(#state.transportSent,count)
    for _,frame in ipairs(state.frames) do
        assert(not frame.scripts.OnUpdate,"closing the test left an active frame driver")
    end
    api.ShowConnectionTest(); equal(#state.transportSent,count)
    assert(not form.run.enabled and form.listen.enabled)
    form.peer:SetFocus(); state.click(form.listen)
    form.peer.scripts.OnEscapePressed(form.peer)
    assert(not form:IsShown() and not api.Transport.IsListening())
end)

test("connection target helper and slash Stop remain explicit and preserve the live ledger", function()
    local target="N\195\179ra Star"
    local state=coreSession({ui=true,connection=true,target=target})
    local api=state.api
    assert(api.Initialize()); local before=copy(state.env.IOUDB)
    api.ShowSettings()
    state.click(state.button(api.UI.settings,"Connection test"))
    local form=api.UI.connection
    assert(form:IsShown()); assert(not api.UI.settings:IsShown())
    state.click(form.target); equal(form.peer:GetText(),target)
    equal(#state.transportSent,0)
    state.click(form.listen); equal(#state.transportSent,0)
    state.env.SlashCmdList.IOU("test stop")
    assert(not api.Transport.IsListening()); assert(not form.run.enabled)
    equal(#state.transportSent,0)
    assert(same(state.env.IOUDB,before))
end)

test("connection UI handles unavailable APIs without preventing normal ledger actions", function()
    local state=coreSession({ui=true,connection=true,noConnectionAPI=true})
    local api=state.api
    api.ShowConnectionTest("Peer Surname")
    local form=api.UI.connection
    state.click(form.listen)
    assert(not api.Transport.IsListening() and not form.run.enabled)
    assert(form.status:GetText():find("logged addon",1,true))
    assert(form.box:GetText():find("Local preflight",1,true))
    equal(#state.transportSent,0)
    form:Hide()
    assert(api.Add({player="Ledger Peer",direction="owed",kind="money",amount=100,label="",note=""}))
    equal(#api.GetLedger().entries,1)
end)

test("shared UTC due dates validate calendar days without consulting the local clock", function()
    local state=coreSession({ui=true}); local api=state.api
    state.env.time=function() error("UTC calendar parsing used local time") end
    equal(api.ParseSharedDueDate(""),0)
    equal(api.ParseSharedDueDate("  "),0)
    equal(api.ParseSharedDueDate("1970-01-01"),86399)
    equal(api.ParseSharedDueDate("2000-02-29"),951868799)
    equal(api.ParseSharedDueDate("2028-02-29"),1835481599)
    equal(api.ParseSharedDueDate("2099-12-31"),4102444799)
    for _,value in ipairs({"1969-12-31","2100-01-01","2027-02-29",
        "2001-02-29","2026-04-31","2026-00-01","2026-13-01","2026-01-00",
        "2026-01-32","2026-1-01","tomorrow"}) do
        local parsed,err=api.ParseSharedDueDate(value)
        equal(parsed,nil); assert(type(err)=="string" and #err>0)
    end
end)

test("shared UI requires explicit peer enablement and sends only the reviewed proposal draft", function()
    local state=coreSession({ui=true,shared=true}); local api=state.api
    assert(api.Initialize())
    assert(api.Add({player="Personal Peer",direction="owed",kind="money",amount=555,label="",note="Personal-only note"}))
    local ledger=copy(api.GetLedger())
    local peer="Bj\195\184Rn \195\152Rn"
    state.env.SlashCmdList.IOU("  SHARED "..peer.."  ")
    local board=api.UI.shared
    assert(board:IsShown()); equal(board.peer:GetText(),peer)
    assert(not api.SharedService.IsEnabled()); equal(#state.transportSent,0)
    state.click(board.enable); assert(api.SharedService.IsEnabled())
    equal(api.SharedService.GetPeer(),peer); equal(#state.transportSent,0)
    state.click(board.propose)
    local form=api.UI.sharedForm
    assert(form:IsShown()); equal(form.peer:GetText(),peer); equal(form.boundPeer,peer)
    form.money:Fill(12345); form.note:SetText("Gold for Bj\195\184rn")
    form.due:SetText("2028-02-29"); state.click(form.dirButtons.owed)
    equal(#state.transportSent,0); equal(#api.SharedService.List(),0)
    state.click(form.send)
    assert(not form:IsShown()); equal(#api.SharedService.List(),1)
    local offer=api.SharedService.List()[1]
    equal(offer.state,"OFFER_OPEN")
    local terms=assert(api.SharedCodec.ParseTerms(offer.terms))
    equal(terms.recipient,peer); equal(terms.debtor,peer)
    equal(terms.creditor,api.Transport.GetLocalName()); equal(terms.amountCopper,12345)
    equal(terms.note,"Gold for Bj\195\184rn"); equal(terms.dueUTC,1835481599)
    equal(#state.transportSent,0,"service sent before persisting/enqueueing returned")
    state.advance(20); assert(#state.transportSent>0)
    for _,packet in ipairs(state.transportSent) do
        equal(packet.prefix,api.SharedWire.PREFIX); equal(packet.target,peer)
        equal(packet.channel,"WHISPER"); assert(#packet.wire<=240)
    end
    assert(same(api.GetLedger(),ledger),"shared proposal changed the personal ledger")
    board:Hide()
end)

test("shared incoming fragments require full visible term review and a separate acceptance click", function()
    local state=coreSession({ui=true,shared=true}); local api=state.api
    api.ShowShared("Remote Peer"); local board=api.UI.shared
    state.click(board.enable)
    local note=string.rep("Reviewed UTF-8 \195\184. ",20)
    local peer=sharedPeer(state,{note=note})
    peer:deliver(peer.proposal)
    local offer=assert(api.SharedService.GetOffer("remote-offer"))
    equal(offer.state,"OFFER_RECEIVED"); equal(offer.consent,"NONE")
    equal(#state.transportSent,0); assert(board.accept.enabled)
    state.click(board.accept)
    local review=api.UI.sharedReview
    assert(review:IsShown() and review.confirm.enabled)
    equal(review.offerId,offer.offerId); equal(review.terms,offer.terms)
    local shown=visibleText(state,review)
    for _,value in ipairs({"Proposer: Remote Peer","Recipient: Testplayer Surname",
        "Debtor: Testplayer Surname","Creditor: Remote Peer","1g 23s 45c",note,"UTC"}) do
        assert(shown:find(value,1,true),"full review omitted "..value)
    end
    assert(review.content:GetHeight()>=review.details:GetStringHeight())
    equal(api.SharedService.GetOffer("remote-offer").state,"OFFER_RECEIVED")
    equal(#state.transportSent,0)
    state.click(review.confirm)
    assert(not review:IsShown())
    offer=api.SharedService.GetOffer("remote-offer")
    equal(offer.state,"ACCEPT_PENDING"); equal(offer.consent,"ACCEPT")
    equal(#api.GetLedger().entries,0,"shared acceptance entered personal balances")
    board:Hide()
end)

test("shared review rejects a withdrawal arriving while the acceptance dialog is open", function()
    local state=coreSession({ui=true,shared=true}); local api=state.api
    api.ShowShared("Remote Peer"); state.click(api.UI.shared.enable)
    local peer=sharedPeer(state); peer:deliver(peer.proposal)
    state.click(api.UI.shared.accept)
    local review=api.UI.sharedReview
    peer:withdraw()
    equal(api.SharedService.GetOffer("remote-offer").state,"WITHDRAWN")
    assert(not review.confirm.enabled)
    local before=copy(api.SharedService.GetStore())
    review.confirm.scripts.OnClick(review.confirm)
    assert(review.status:GetText():find("changed",1,true))
    assert(same(api.SharedService.GetStore(),before))
    equal(api.SharedService.GetOffer("remote-offer").messages.accept,nil)
    equal(#state.transportSent,0)
    api.UI.shared:Hide()
end)

test("shared draft cannot silently switch recipients when the enabled player changes", function()
    local state=coreSession({ui=true,shared=true}); local api=state.api
    api.ShowShared("First Peer"); local board=api.UI.shared
    state.click(board.enable); state.click(board.propose)
    local form=api.UI.sharedForm
    form.money:Fill(10000); form.note:SetText("Only for the first player")
    state.click(board.stop); board.peer:SetText("Second Peer"); state.click(board.enable)
    local before=copy(api.SharedService.GetStore())
    form.send.scripts.OnClick(form.send)
    assert(form.status:GetText():find("changed",1,true))
    assert(same(api.SharedService.GetStore(),before)); equal(#state.transportSent,0)
    equal(#api.SharedService.List(),0)
    board:Hide()
end)

test("a persisted proposal with failed enqueue closes its draft and retries the same saved offer", function()
    for _,mode in ipairs({"nil","throw"}) do
        local state=coreSession({ui=true,shared=true}); local api=state.api
        api.ShowShared("Remote Peer"); local board=api.UI.shared
        state.click(board.enable); state.click(board.propose)
        local form=api.UI.sharedForm
        form.money:Fill(10000); form.note:SetText("Persist this proposal exactly once")
        local originalSend=api.SharedWire.Send
        api.SharedWire.Send=function()
            if mode=="throw" then error("injected enqueue failure") end
            return nil,"injected enqueue failure"
        end
        state.click(form.send)
        local offers=api.SharedService.List()
        equal(#offers,1); equal(offers[1].state,"OFFER_OPEN")
        assert(not form:IsShown(),"saved proposal left a draft that could create a second offer")
        equal(board.selected,offers[1].offerId)
        assert(board.status:GetText():find("saved",1,true))
        assert(board.status:GetText():find("Retry",1,true))
        equal(#state.transportSent,0); assert(board.retry.enabled)
        local originalProposal=copy(offers[1].messages.propose)
        api.SharedWire.Send=originalSend
        state.click(board.retry)
        state.advance(20)
        offers=api.SharedService.List()
        equal(#offers,1); assert(same(offers[1].messages.propose,originalProposal))
        assert(#state.transportSent>0); equal(#api.GetLedger().entries,0)
        board:Hide()
    end
end)

test("closing shared UI stops queued packets, pauses consent and keeps reload and characters isolated", function()
    local state=coreSession({ui=true,shared=true}); local api=state.api
    api.ShowShared("Remote Peer"); local board=api.UI.shared
    state.click(board.enable); state.click(board.propose)
    local form=api.UI.sharedForm; form.money:Fill(10000); state.click(form.send)
    local offer=api.SharedService.List()[1]
    equal(offer.state,"OFFER_OPEN"); equal(#state.transportSent,0)
    api.ShowSharedReview(offer.offerId,"withdraw")
    board.peer:SetFocus(); board.peer.scripts.OnEscapePressed(board.peer)
    assert(not board:IsShown() and not form:IsShown() and not api.UI.sharedReview:IsShown())
    assert(not api.SharedService.IsEnabled())
    equal(api.SharedService.GetOffer(offer.offerId).state,"PAUSED")
    state.advance(60); equal(#state.transportSent,0)
    for _,frame in ipairs(state.frames) do assert(not frame.scripts.OnUpdate) end
    local saved=state.env.IOUDB
    local reloaded=coreSession({ui=true,shared=true,db=saved})
    reloaded.event("PLAYER_LOGIN")
    assert(not reloaded.api.SharedService.IsEnabled())
    equal(reloaded.api.SharedService.GetOffer(offer.offerId).state,"PAUSED")
    reloaded.advance(60); equal(#reloaded.transportSent,0)
    local original=copy(saved.sharedByCharacter[api.Character()])
    local other=coreSession({ui=true,shared=true,db=saved,name="Otherplayer",fullName="Otherplayer Surname"})
    other.event("PLAYER_LOGIN")
    equal(#other.api.SharedService.List(),0); equal(#other.api.GetLedger().entries,0)
    assert(same(saved.sharedByCharacter[api.Character()],original))
    equal(#other.transportSent,0)
end)

test("corrupt shared storage is left untouched while normal personal ledger actions remain usable", function()
    for _,corrupt in ipairs({"invalid shared namespace",{["Testplayer-TestRealm"]={version=99}}}) do
        local db={version=1,characters={},sharedByCharacter=copy(corrupt)}
        local before=copy(db.sharedByCharacter)
        local state=coreSession({ui=true,shared=true,db=db}); local api=state.api
        state.event("PLAYER_LOGIN")
        assert(api.Initialize()); api.ShowShared("Remote Peer")
        local store,err=api.SharedService.GetStore()
        equal(store,nil); assert(type(err)=="string" and #err>0)
        assert(not api.SharedService.IsEnabled()); equal(#state.transportSent,0)
        assert(same(db.sharedByCharacter,before))
        assert(api.Add({player="Personal Peer",direction="owed",kind="money",amount=100,label="",note=""}))
        equal(#api.GetLedger().entries,1)
        assert(same(db.sharedByCharacter,before))
        api.UI.shared:Hide()
    end
end)

test("shared paused review requires a reason and records only a local decision while disconnected", function()
    local state=coreSession({ui=true,shared=true}); local api=state.api
    api.ShowShared("Remote Peer"); local board=api.UI.shared
    state.click(board.enable)
    local peer=sharedPeer(state); peer:deliver(peer.proposal)
    state.env.SlashCmdList.IOU("shared off")
    assert(not api.SharedService.IsEnabled())
    equal(api.SharedService.GetOffer("remote-offer").state,"PAUSED")
    assert(board.closePaused.enabled)
    state.click(board.closePaused)
    local review=api.UI.sharedReview
    assert(review:IsShown() and review.reason:IsShown())
    assert(review.explanation:GetText():find("local review",1,true))
    local before=copy(api.SharedService.GetStore())
    state.click(review.confirm)
    assert(review.status:GetText()~="")
    assert(not api.SharedService.GetOffer("remote-offer").localClosed)
    review.reason:SetText("Reconciled with the other player; use a fresh proposal")
    state.click(review.confirm)
    local offer=api.SharedService.GetOffer("remote-offer")
    assert(offer.localClosed); equal(offer.state,"PAUSED")
    assert(offer.localCloseReason:find("Reconciled",1,true))
    assert(same(api.SharedService.GetStore(),before),"local review changed shared protocol history")
    equal(#api.GetLedger().entries,0); equal(#state.transportSent,0)
    assert(not board.closePaused.enabled)
    board:Hide()
end)

test("two complete addon sessions agree through framed whispers only after recipient review", function()
    local a=coreSession({ui=true,shared=true,name="Amber",fullName="Amber Stone"})
    local b=coreSession({ui=true,shared=true,name="Birch",fullName="Birch Vale"})
    a.api.ShowShared("Birch Vale"); b.api.ShowShared("Amber Stone")
    a.click(a.api.UI.shared.enable); b.click(b.api.UI.shared.enable)
    local personalA,personalB=copy(a.api.GetLedger()),copy(b.api.GetLedger())
    a.click(a.api.UI.shared.propose)
    local draft=a.api.UI.sharedForm
    draft.money:Fill(54321); draft.note:SetText("Two-peer gold agreement \195\184")
    a.click(draft.send)
    local id=a.api.SharedService.List()[1].offerId
    local deliveredA,deliveredB=0,0
    local function deliverNew(from,to,delivered)
        while delivered<#from.transportSent do
            delivered=delivered+1
            local packet=from.transportSent[delivered]
            to.event("CHAT_MSG_ADDON_LOGGED",packet.prefix,packet.wire,packet.channel,
                assert(from.api.Transport.GetLocalName()))
        end
        return delivered
    end
    local function runUntil(predicate)
        for _=1,900 do
            a.advance(0.1); b.advance(0.1)
            deliveredA=deliverNew(a,b,deliveredA)
            deliveredB=deliverNew(b,a,deliveredB)
            if predicate() then return end
        end
        error("two-client addon simulation did not reach the expected state")
    end
    runUntil(function() return b.api.SharedService.GetOffer(id)~=nil end)
    equal(b.api.SharedService.GetOffer(id).state,"OFFER_RECEIVED")
    equal(#b.transportSent,0,"received proposal sent consent without user review")
    b.click(b.api.UI.shared.accept)
    equal(b.api.SharedService.GetOffer(id).state,"OFFER_RECEIVED")
    b.click(b.api.UI.sharedReview.confirm)
    runUntil(function()
        local left=a.api.SharedService.GetOffer(id)
        local right=b.api.SharedService.GetOffer(id)
        return left and right and left.state=="COMMITTED" and right.state=="COMMITTED"
            and left.delivery=="PEER_RECEIPT_OBSERVED"
    end)
    equal(a.api.SharedService.GetOffer(id).terms,b.api.SharedService.GetOffer(id).terms)
    equal(a.env.IOUDB.sharedByCharacter[a.api.Character()].store.offers[id].state,"COMMITTED")
    equal(b.env.IOUDB.sharedByCharacter[b.api.Character()].store.offers[id].state,"COMMITTED")
    assert(same(a.api.GetLedger(),personalA) and same(b.api.GetLedger(),personalB))
    assert(a.api.UI.shared.details:GetText():find("their IOU acknowledged",1,true))
    a.api.UI.shared:Hide(); b.api.UI.shared:Hide()
    assert(not a.api.SharedService.IsEnabled() and not b.api.SharedService.IsEnabled())
end)

return results
