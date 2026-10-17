-- Sync hints request reconciliation; they are never financial consent.
local results={}
local function test(name,run)
    local ok,err=pcall(run);if not ok then error(name..": "..tostring(err),0) end
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
    local value,err=run();assert(value==nil or value==false,"invalid sync hint succeeded")
    assert(type(err)=="string" and #err>0,"missing sync rejection reason")
end
local ns={}
for _,file in ipairs({"shared_codec.lua","shared.lua"}) do
    local chunk=assert(loadstring(assert(IOU_SOURCES[file]),"@IOU/"..file));chunk("IOU",ns)
end
local C,S=ns.SharedCodec,ns.Shared
local function obligation(item)
    local result={protocol=item and 3 or 1,kind=item and "ITEM_OBLIGATION" or "GOLD_OBLIGATION",
        proposer="Amber Stone",recipient="Birch Vale",debtor="Birch Vale",creditor="Amber Stone",
        amountCopper=20,dueUTC=0,note="Bjørn blåbær"}
    if item then result.itemKey,result.itemName="item:2589","Linen Cloth" end
    return result
end
local function row(item,id,amount,reverse)
    return {kind=item and (reverse and "ITEM_CORRECTION" or "ITEM_PAYMENT") or (reverse and "GOLD_CORRECTION" or "GOLD_PAYMENT"),
        agreementId="event-ag-"..id,offerId="event-of-"..id,commitId="event-cm-"..id,
        amountCopper=amount,note="Observed",reversesId=reverse or ""}
end
local function hint(item,amount,rows)
    rows=rows or {}
    return {version=1,kind="SYNC",messageId="hint-id",agreementId="parent-ag",offerId="parent-of",revision=1,
        terms=assert(C.CanonicalTerms(obligation(item))),paidAmount=amount or 0,
        baseRevision=#rows,baseChain=assert(C.CanonicalChain(rows))}
end
local function token(value) value=tostring(value);return #value..":"..value.."," end
local function raw(message)
    local fields={"version","kind","messageId","agreementId","offerId","revision","terms","paidAmount","baseRevision","baseChain"}
    local out={"IOUSM1:"};for _,field in ipairs(fields) do out[#out+1]=token(message[field]) end;return table.concat(out)
end

test("gold and item sync hints roundtrip zero partial and full local paid amounts",function()
    for _,item in ipairs({false,true}) do
        for _,paid in ipairs({0,3,20,C.MAX_AMOUNT}) do
            local message=hint(item,paid)
            local bytes=assert(C.Encode(message));local decoded=assert(C.Decode(bytes))
            assert(same(message,decoded) and bytes==raw(message) and #bytes<=4096)
            assert(decoded.paidAmount==paid and type(decoded.paidAmount)=="number" and decoded.baseRevision==0)
        end
    end
end)

test("sync canonical baselines include exact payment and correction chain evidence",function()
    for _,item in ipairs({false,true}) do
        local first=row(item,"paid",7)
        local correction=row(item,"fix",7,first.offerId)
        local message=hint(item,20,{first,correction,row(item,"last",20)})
        local decoded=assert(C.Decode(assert(C.Encode(message))))
        assert(decoded.baseRevision==3 and decoded.baseChain==message.baseChain and decoded.paidAmount==20)
    end
end)

test("sync rejects invalid amounts revisions missing extra and noncanonical numeric fields",function()
    for _,changes in ipairs({{paidAmount=-1},{paidAmount=0.5},{paidAmount=0/0},{paidAmount=math.huge},
        {paidAmount=C.MAX_AMOUNT+1},{paidAmount="0"},{baseRevision=-1},{baseRevision=1.5},{baseRevision=32},
        {baseRevision=1},{acceptanceId="not-consent"},{commitId="not-consent"},{other="extra"}}) do
        local message=hint(false)
        for key,value in pairs(changes) do message[key]=value end
        reject(function() return C.Encode(message) end)
    end
    local missing=hint(false);missing.paidAmount=nil;reject(function() return C.Encode(missing) end)
    for _,changes in ipairs({{paidAmount="00"},{paidAmount="-1"},{paidAmount="1.0"},{baseRevision="00"},{baseRevision="+0"}}) do
        local message=hint(false)
        for key,value in pairs(changes) do message[key]=value end
        reject(function() return C.Decode(raw(message)) end)
    end
end)

test("sync baselines cannot mix asset families exceed the original or borrow parent identifiers",function()
    for _,item in ipairs({false,true}) do
        reject(function() return C.Encode(hint(item,0,{row(not item,"wrong-asset",1)})) end)
        reject(function() return C.Encode(hint(item,0,{row(item,"excess",21)})) end)
        local first=row(item,"excess",21);local undone=row(item,"undo",21,first.offerId)
        reject(function() return C.Encode(hint(item,0,{first,undone})) end)
        local collision=row(item,"collision",1);collision.offerId="parent-of"
        reject(function() return C.Encode(hint(item,0,{collision})) end)
        collision=row(item,"collision",1);collision.agreementId="parent-ag"
        reject(function() return C.Encode(hint(item,0,{collision})) end)
    end
end)

test("sync hints reject malformed incomplete or noncanonical chain bytes",function()
    for _,chain in ipairs({"","IOUSC1:1:1,","IOUSC1:2:00,","IOUSC1:1:0,trailing","not a chain"}) do
        local message=hint(false);message.baseChain=chain
        reject(function() return C.Encode(message) end)
    end
    local bytes=assert(C.Encode(hint(true)))
    reject(function() return C.Decode(bytes:sub(1,-2)) end)
    reject(function() return C.Decode(bytes.."trailing") end)
end)

test("sync cannot bind event terms instead of the exact original obligation",function()
    for _,item in ipairs({false,true}) do
        local original=obligation(item)
        local event={protocol=item and 4 or 2,kind=item and "ITEM_PAYMENT" or "GOLD_PAYMENT",
            proposer=original.proposer,recipient=original.recipient,debtor=original.debtor,creditor=original.creditor,
            amountCopper=1,dueUTC=0,note="",parentAgreementId="parent-ag",parentOfferId="parent-of",parentCommitId="parent-cm",
            parentTerms=assert(C.CanonicalTerms(original)),baseRevision=0,baseChain=assert(C.CanonicalChain({})),reversesId=""}
        if item then event.itemKey,event.itemName=original.itemKey,original.itemName end
        local message=hint(item);message.terms=assert(C.CanonicalTerms(event))
        reject(function() return C.Encode(message) end)
    end
end)

test("sync remains outside the financial consent engine and retained message schema",function()
    local original=obligation(false)
    local store=assert(S.Propose(assert(S.New("Amber Stone")),original,"parent-ag","parent-of",100))
    local before=copy(store);local message=hint(false,10)
    reject(function() return S.Receive(store,"Birch Vale",message,101) end)
    assert(same(store,before) and store.offers["parent-of"].messages.accept==nil)
    local corrupt=copy(store);corrupt.offers["parent-of"].messages.sync=message
    reject(function() return S.Validate(corrupt) end)
end)

test("legacy proposal and commit bytes stay identical after adding sync envelopes",function()
    for _,item in ipairs({false,true}) do
        local original=assert(C.CanonicalTerms(obligation(item)))
        for _,kind in ipairs({"PROPOSE","COMMIT"}) do
            local message={version=1,kind=kind,messageId="m",agreementId="g",offerId="o",revision=1,terms=original}
            local expected="IOUSM1:"..token(1)..token(kind)..token("m")..token("g")..token("o")..token(1)..token(original)
            if kind=="COMMIT" then message.acceptanceId,message.commitId="a","c";expected=expected..token("a")..token("c") end
            assert(C.Encode(message)==expected and C.Encode(C.Decode(expected))==expected)
        end
    end
end)

test("sync still respects the complete 4096-byte logical envelope bound",function()
    local rows={};for index=1,31 do rows[index]=row(false,tostring(index),1) end
    local message=hint(false,20,rows)
    -- Prefix overpayment is rejected even though each individual row is legal.
    reject(function() return C.Encode(message) end)
    local original=obligation(false);original.amountCopper=31
    message.terms=assert(C.CanonicalTerms(original))
    if C.Encode(message) then assert(#assert(C.Encode(message))<=4096) end
    local longRows=copy(rows);for _,entry in ipairs(longRows) do entry.note=string.rep("n",512) end
    reject(function() return C.CanonicalChain(longRows) end)
end)

return results
