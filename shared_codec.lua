local _, IOU = ...
local C = {VERSION=1, MAX_BYTES=4096, MAX_NAME_BYTES=96, MAX_NOTE_BYTES=512,
    MAX_ID_BYTES=64, MAX_AMOUNT=999999999, MAX_TIMESTAMP=4102444800, MAX_CHAIN_ROWS=31}
IOU.SharedCodec = C

-- Logical messages only. This readable, length-prefixed format is deliberately
-- separate from the 240-byte link experiment and is not packet framing.
local TERMS_HEADER, EVENT_HEADER, CHAIN_HEADER, MESSAGE_HEADER = "IOUST1:", "IOUST2:", "IOUSC1:", "IOUSM1:"
local ITEM_HEADER, ITEM_EVENT_HEADER = "IOUST3:", "IOUST4:"
local termsOrder = {"protocol", "kind", "proposer", "recipient", "debtor", "creditor", "amountCopper", "dueUTC", "note"}
local eventOrder = {"protocol", "kind", "proposer", "recipient", "debtor", "creditor", "amountCopper", "dueUTC", "note",
    "parentAgreementId", "parentOfferId", "parentCommitId", "parentTerms", "baseRevision", "baseChain", "reversesId"}
local function withItemFields(fields)
    local result={}; for _,field in ipairs(fields) do result[#result+1]=field end
    result[#result+1],result[#result+2]="itemKey","itemName"
    return result
end
local itemOrder, itemEventOrder=withItemFields(termsOrder),withItemFields(eventOrder)
local chainOrder = {"kind", "agreementId", "offerId", "commitId", "amountCopper", "note", "reversesId"}
local commonOrder = {"version", "kind", "messageId", "agreementId", "offerId", "revision", "terms"}
local variants = {PROPOSE={}, ACCEPT={"acceptanceId"}, COMMIT={"acceptanceId", "commitId"},
    ACK={"acceptanceId", "commitId"}, DECLINE={}, WITHDRAW={"outcomeId"},
    OUTCOME={"outcomeId", "outcome"}, STATUS={},
    SYNC={"paidAmount", "baseRevision", "baseChain"}}

local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= minimum and value <= maximum
        and value == math.floor(value)
end

local function exactKeys(value, required)
    if type(value) ~= "table" or getmetatable(value) ~= nil then return nil, "Expected a plain table." end
    local allowed, count = {}, 0
    for _, field in ipairs(required) do allowed[field] = true end
    for field in pairs(value) do
        if type(field) ~= "string" or not allowed[field] then return nil, "Unknown field in shared data." end
        count = count + 1
    end
    if count ~= #required then return nil, "Missing field in shared data." end
    for _, field in ipairs(required) do if rawget(value, field) == nil then return nil, "Missing " .. field .. "." end end
    return true
end

local function text(value, maximum, allowEmpty)
    if type(value) ~= "string" or #value > maximum or (not allowEmpty and #value == 0) then return nil end
    local index = 1
    while index <= #value do
        local first = value:byte(index)
        local width, codepoint, minimum
        if first <= 127 then width, codepoint, minimum = 1, first, 0
        elseif first >= 194 and first <= 223 then width, codepoint, minimum = 2, first-192, 128
        elseif first >= 224 and first <= 239 then width, codepoint, minimum = 3, first-224, 2048
        elseif first >= 240 and first <= 244 then width, codepoint, minimum = 4, first-240, 65536
        else return nil end
        if index + width - 1 > #value then return nil end
        for offset=1,width-1 do
            local continuation = value:byte(index+offset)
            if continuation < 128 or continuation > 191 then return nil end
            codepoint = codepoint * 64 + continuation - 128
        end
        if codepoint < minimum or codepoint > 1114111 or (codepoint >= 55296 and codepoint <= 57343)
            or codepoint < 32 or (codepoint >= 127 and codepoint <= 159) or codepoint == 124 then return nil end
        index = index + width
    end
    return true
end

local function name(value)
    return text(value, C.MAX_NAME_BYTES, false) and value:sub(1,1) ~= " " and value:sub(-1) ~= " "
        and not value:find("  ", 1, true)
end

local function id(value)
    return type(value) == "string" and #value >= 1 and #value <= C.MAX_ID_BYTES
        and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function asciiLower(value)
    return (value:gsub("[A-Z]", function(letter) return string.char(letter:byte()+32) end))
end

-- Asset helpers keep quantity separate from money in every caller. The old
-- amountCopper field remains the canonical integer slot for legacy storage.
function C.IsObligation(value)
    return type(value)=="table" and (value.kind=="GOLD_OBLIGATION" or value.kind=="ITEM_OBLIGATION")
end
function C.IsPayment(value)
    return type(value)=="table" and (value.kind=="GOLD_PAYMENT" or value.kind=="ITEM_PAYMENT")
end
function C.IsCorrection(value)
    return type(value)=="table" and (value.kind=="GOLD_CORRECTION" or value.kind=="ITEM_CORRECTION")
end
function C.CanonicalItem(value)
    if type(value)~="string" or #value>512 or value:find("[%z\001-\031\127]") then return nil end
    if value:sub(1,2)=="|c" then
        if not value:sub(3,10):match("^%x%x%x%x%x%x%x%x$") or value:sub(-2)~="|r" then return nil end
        value=value:sub(11,-3)
    end
    local payload=value:match("^item:([%d:%-]+)$") or value:match("^|Hitem:([%d:%-]+)|h%[[^|]*%]|h$")
    if not payload then return nil end
    local fields={}
    for field in (payload..":"):gmatch("(.-):") do
        if field~="" and not field:match("^%-?%d+$") then return nil end
        local number=field=="" and 0 or tonumber(field)
        if not integer(number,-4294967295,4294967295) then return nil end
        fields[#fields+1]=number
        if #fields>80 then return nil end
    end
    if not integer(fields[1],1,2147483647) then return nil end
    while #fields>1 and fields[#fields]==0 do fields[#fields]=nil end
    local canonical={}
    for index,field in ipairs(fields) do canonical[index]=string.format("%.0f",field) end
    return "item:"..table.concat(canonical,":"),fields[1]
end
function C.Asset(value)
    if type(value)~="table" then return nil end
    if value.kind=="ITEM_OBLIGATION" or value.kind=="ITEM_PAYMENT" or value.kind=="ITEM_CORRECTION" then
        local key,itemID=C.CanonicalItem(value.itemKey)
        if not key or key~=value.itemKey then return nil end
        return {kind="item",label=value.itemName,itemKey=key,itemID=itemID,amount=value.amountCopper}
    end
    if C.IsObligation(value) or C.IsPayment(value) or C.IsCorrection(value) then
        return {kind="money",label="Gold",amount=value.amountCopper}
    end
end
local function itemTerms(value) return value.kind=="ITEM_OBLIGATION" or value.kind=="ITEM_PAYMENT" or value.kind=="ITEM_CORRECTION" end
local function termShape(value)
    if value.protocol==1 and value.kind=="GOLD_OBLIGATION" then return TERMS_HEADER,termsOrder,false,false end
    if value.protocol==2 and (value.kind=="GOLD_PAYMENT" or value.kind=="GOLD_CORRECTION") then return EVENT_HEADER,eventOrder,true,false end
    if value.protocol==3 and value.kind=="ITEM_OBLIGATION" then return ITEM_HEADER,itemOrder,false,true end
    if value.protocol==4 and (value.kind=="ITEM_PAYMENT" or value.kind=="ITEM_CORRECTION") then return ITEM_EVENT_HEADER,itemEventOrder,true,true end
end

local function validateChain(rows)
    if type(rows)~="table" or getmetatable(rows)~=nil or #rows>C.MAX_CHAIN_ROWS then return nil,"Invalid shared event chain." end
    local count,offers,agreements,reversed,balance,family=0,{},{},{},0,nil
    for index in pairs(rows) do
        if not integer(index,1,C.MAX_CHAIN_ROWS) then return nil,"Shared event chain must be a dense array." end
        count=count+1
    end
    if count~=#rows then return nil,"Shared event chain must be a dense array." end
    for _,row in ipairs(rows) do
        local ok,err=exactKeys(row,chainOrder)
        if not ok then return nil,err end
        if not C.IsPayment(row) and not C.IsCorrection(row) then return nil,"Invalid shared event kind." end
        local asset=itemTerms(row) and "item" or "money"
        if family and family~=asset then return nil,"A shared event chain cannot mix gold and items." end
        family=asset
        for _,field in ipairs({"agreementId","offerId","commitId"}) do
            if not id(row[field]) then return nil,"Invalid event "..field.."." end
        end
        if offers[row.offerId] or agreements[row.agreementId] then return nil,"Shared event identifiers are reused." end
        if not integer(row.amountCopper,1,C.MAX_AMOUNT) or not text(row.note,C.MAX_NOTE_BYTES,true) then return nil,"Invalid shared event amount or note." end
        if C.IsPayment(row) then
            if row.reversesId~="" then return nil,"A payment cannot reverse an event." end
            balance=balance+row.amountCopper
        else
            local payment=offers[row.reversesId]
            if not id(row.reversesId) or not payment or not C.IsPayment(payment) or reversed[row.reversesId]
                or row.amountCopper~=payment.amountCopper or not row.note:find("%S") then
                return nil,"A correction must fully reverse one earlier, unreversed payment and include a reason."
            end
            reversed[row.reversesId]=true
            balance=balance-row.amountCopper
        end
        offers[row.offerId],agreements[row.agreementId]=row,true
    end
    return true,nil,{offers=offers,reversed=reversed,paid=balance}
end

function C.ValidateChain(rows)
    local ok,err=validateChain(rows)
    return ok,err
end

function C.ValidateTerms(terms)
    if type(terms)~="table" or getmetatable(terms)~=nil then return nil,"Expected a plain terms table." end
    local header,order,event,item=termShape(terms)
    if not header then return nil,"Unsupported shared terms version or kind." end
    local ok, err = exactKeys(terms, order)
    if not ok then return nil, err end
    if item then
        local canonical=C.CanonicalItem(terms.itemKey)
        if not canonical or canonical~=terms.itemKey then return nil,"Item identity must be a canonical item payload." end
        if not text(terms.itemName,256,false) or not terms.itemName:find("%S") then return nil,"Item name must be plain UTF-8 (1-256 bytes)." end
    end
    for _, field in ipairs({"proposer", "recipient", "debtor", "creditor"}) do
        if not name(terms[field]) then return nil, field .. " must be a plain UTF-8 full name with single spaces (1-96 bytes)." end
    end
    if asciiLower(terms.proposer) == asciiLower(terms.recipient) then return nil, "The two participants must be distinct." end
    if (terms.debtor ~= terms.proposer and terms.debtor ~= terms.recipient)
        or (terms.creditor ~= terms.proposer and terms.creditor ~= terms.recipient)
        or terms.debtor == terms.creditor then return nil, "Debtor and creditor must be the two exact participants." end
    if not integer(terms.amountCopper, 1, C.MAX_AMOUNT) then return nil, item and "Item quantity must be a positive supported integer." or "Gold must be positive integer copper within the supported limit." end
    if not integer(terms.dueUTC, 0, C.MAX_TIMESTAMP) then return nil, "Due date must be zero or a supported UTC timestamp." end
    if not text(terms.note, C.MAX_NOTE_BYTES, true) then return nil, "Note must be plain UTF-8 without controls or pipes (up to 512 bytes)." end
    if event then
        if terms.dueUTC~=0 then return nil,"Shared payment events cannot change the deadline." end
        for _,field in ipairs({"parentAgreementId","parentOfferId","parentCommitId"}) do
            if not id(terms[field]) then return nil,"Invalid "..field.."." end
        end
        local parentHeader=item and ITEM_HEADER or TERMS_HEADER
        if type(terms.parentTerms)~="string" or terms.parentTerms:sub(1,#parentHeader)~=parentHeader then
            return nil,"Payment events must bind exact original obligation terms of the same asset."
        end
        local parent,problem=C.ParseTerms(terms.parentTerms)
        if not parent or not C.IsObligation(parent) then return nil,"Invalid original obligation: "..tostring(problem) end
        if item and (terms.itemKey~=parent.itemKey or terms.itemName~=parent.itemName) then
            return nil,"Item payment identity and name must match the original obligation."
        end
        for _,field in ipairs({"proposer","recipient","debtor","creditor"}) do
            if terms[field]~=parent[field] then return nil,"Payment participants and direction must match the original obligation." end
        end
        local rows
        rows,problem=C.ParseChain(terms.baseChain)
        if not rows then return nil,problem end
        if not integer(terms.baseRevision,0,C.MAX_CHAIN_ROWS) or terms.baseRevision~=#rows then return nil,"Shared event baseline revision does not match its chain." end
        local _,_,chain=validateChain(rows)
        local runningPaid=0
        for _,row in ipairs(rows) do
            if row.offerId==terms.parentOfferId or row.agreementId==terms.parentAgreementId then return nil,"An event cannot reuse its parent's identifiers." end
            if itemTerms(row)~=item then return nil,"A baseline event belongs to another asset." end
            runningPaid=runningPaid+(C.IsPayment(row) and row.amountCopper or -row.amountCopper)
            if runningPaid>parent.amountCopper then return nil,"A baseline event exceeds the original obligation." end
        end
        if chain.paid>parent.amountCopper then return nil,"The baseline exceeds the original obligation." end
        if C.IsPayment(terms) then
            if terms.reversesId~="" or terms.amountCopper>parent.amountCopper-chain.paid then return nil,"Payment exceeds the outstanding gold or has a reversal identifier." end
        else
            local payment=chain.offers[terms.reversesId]
            if not id(terms.reversesId) or not payment or not C.IsPayment(payment) or chain.reversed[terms.reversesId]
                or terms.amountCopper~=payment.amountCopper or not terms.note:find("%S") then
                return nil,"Correction must fully reverse one confirmed, unreversed payment and include a reason."
            end
        end
    end
    return true
end

local function token(value)
    if type(value) == "number" then value = string.format("%.0f", value) end
    return tostring(#value) .. ":" .. value .. ","
end

local function encodeFields(header, value, order)
    local parts = {header}
    for _, field in ipairs(order) do parts[#parts+1] = token(value[field]) end
    local bytes = table.concat(parts)
    if #bytes > C.MAX_BYTES then return nil, "Shared logical message exceeds 4096 bytes." end
    return bytes
end

function C.CanonicalTerms(terms)
    local ok, err = C.ValidateTerms(terms)
    if not ok then return nil, err end
    local header,order=termShape(terms)
    return encodeFields(header,terms,order)
end

local function reader(bytes, header)
    if type(bytes) ~= "string" or #bytes > C.MAX_BYTES or bytes:sub(1,#header) ~= header then
        return nil, "Invalid shared format or byte limit."
    end
    local position = #header + 1
    local function take()
        local colon = bytes:find(":", position, true)
        if not colon or colon-position > 4 then return nil, "Invalid shared token length." end
        local rawLength = bytes:sub(position, colon-1)
        if rawLength ~= "0" and not rawLength:match("^[1-9][0-9]*$") then return nil, "Noncanonical shared token length." end
        local length = tonumber(rawLength)
        if not length or length > C.MAX_BYTES then return nil, "Shared token is too large." end
        local first, last = colon + 1, colon + length
        if last + 1 > #bytes or bytes:sub(last+1,last+1) ~= "," then return nil, "Truncated shared token." end
        local value = bytes:sub(first,last)
        position = last + 2
        return value
    end
    return take, function() return position == #bytes + 1 end
end

local function readFields(take, object, fields)
    for _, field in ipairs(fields) do
        local value, err = take()
        if value == nil then return nil, err end
        object[field] = value
    end
    return true
end

local function decimal(raw, maximum)
    if type(raw) ~= "string" or #raw > 10 or (raw ~= "0" and not raw:match("^[1-9][0-9]*$")) then return nil end
    local value = tonumber(raw)
    if not integer(value, 0, maximum) then return nil end
    return value
end

function C.ParseTerms(bytes)
    local header=type(bytes)=="string" and bytes:sub(1,#TERMS_HEADER)
    local order,event,maximum
    if header==TERMS_HEADER then order,event,maximum=termsOrder,false,1
    elseif header==EVENT_HEADER then order,event,maximum=eventOrder,true,2
    elseif header==ITEM_HEADER then order,event,maximum=itemOrder,false,3
    elseif header==ITEM_EVENT_HEADER then order,event,maximum=itemEventOrder,true,4
    else return nil,"Invalid shared terms format." end
    local take, finished = reader(bytes,header)
    if not take then return nil, finished end
    local terms = {}
    local ok, err = readFields(take, terms, order)
    if not ok then return nil, err end
    if not finished() then return nil, "Trailing data after shared terms." end
    terms.protocol = decimal(terms.protocol, maximum)
    terms.amountCopper = decimal(terms.amountCopper, C.MAX_AMOUNT)
    terms.dueUTC = decimal(terms.dueUTC, C.MAX_TIMESTAMP)
    if event then terms.baseRevision=decimal(terms.baseRevision,C.MAX_CHAIN_ROWS) end
    ok, err = C.ValidateTerms(terms)
    if not ok then return nil, err end
    local canonical
    canonical, err = C.CanonicalTerms(terms)
    if not canonical or canonical ~= bytes then return nil, err or "Terms are not canonical." end
    return terms
end

function C.CanonicalChain(rows)
    local ok,err=validateChain(rows)
    if not ok then return nil,err end
    local parts={CHAIN_HEADER,token(#rows)}
    for _,row in ipairs(rows) do for _,field in ipairs(chainOrder) do parts[#parts+1]=token(row[field]) end end
    local bytes=table.concat(parts)
    if #bytes>C.MAX_BYTES then return nil,"Shared event chain exceeds 4096 bytes." end
    return bytes
end

function C.ParseChain(bytes)
    local take,finished=reader(bytes,CHAIN_HEADER)
    if not take then return nil,finished end
    local raw,err=take()
    if raw==nil then return nil,err end
    local count=decimal(raw,C.MAX_CHAIN_ROWS)
    if count==nil then return nil,"Invalid shared event chain count." end
    local rows={}
    for index=1,count do
        local row={}
        local ok,problem=readFields(take,row,chainOrder)
        if not ok then return nil,problem end
        row.amountCopper=decimal(row.amountCopper,C.MAX_AMOUNT)
        rows[index]=row
    end
    if not finished() then return nil,"Trailing data after shared event chain." end
    local canonical,problem=C.CanonicalChain(rows)
    if not canonical or canonical~=bytes then return nil,problem or "Noncanonical shared event chain." end
    return rows
end

local function messageFields(kind)
    local extra = variants[kind]
    if not extra then return nil end
    local fields = {}
    for _, field in ipairs(commonOrder) do fields[#fields+1] = field end
    for _, field in ipairs(extra) do fields[#fields+1] = field end
    return fields
end

function C.ValidateMessage(message)
    if type(message) ~= "table" or getmetatable(message) ~= nil then return nil, "Expected a plain message table." end
    if type(message.kind) ~= "string" then return nil, "Unknown shared message kind." end
    local fields = messageFields(message.kind)
    if not fields then return nil, "Unknown shared message kind." end
    local ok, err = exactKeys(message, fields)
    if not ok then return nil, err end
    if message.version ~= 1 or message.revision ~= 1 then return nil, "Unsupported shared message version or revision." end
    for _, field in ipairs({"messageId", "agreementId", "offerId"}) do
        if not id(message[field]) then return nil, "Invalid " .. field .. "." end
    end
    for _, field in ipairs(variants[message.kind]) do
        if field == "outcome" then
            if message.outcome ~= "DECLINED" and message.outcome ~= "WITHDRAWN" then return nil, "Invalid terminal outcome." end
        elseif message.kind~="SYNC" and not id(message[field]) then return nil, "Invalid " .. field .. "." end
    end
    local terms
    terms, err = C.ParseTerms(message.terms)
    if not terms then return nil, "Invalid bound terms: " .. tostring(err) end
    if message.kind=="SYNC" then
        -- A hint only requests reconciliation. It never supplies acceptance,
        -- commitment, or a replacement financial balance to the state machine.
        if not C.IsObligation(terms) then return nil,"A sync hint must bind an original obligation." end
        if not integer(message.paidAmount,0,C.MAX_AMOUNT) then return nil,"Invalid sync paid amount." end
        local rows,problem=C.ParseChain(message.baseChain)
        if not rows then return nil,problem end
        if not integer(message.baseRevision,0,C.MAX_CHAIN_ROWS) or message.baseRevision~=#rows then
            return nil,"Sync baseline revision does not match its chain."
        end
        local asset=C.Asset(terms)
        local paid=0
        for _,row in ipairs(rows) do
            if (itemTerms(row) and "item" or "money")~=asset.kind then return nil,"A sync baseline belongs to another asset." end
            if row.agreementId==message.agreementId or row.offerId==message.offerId then
                return nil,"A sync event cannot reuse the original identifiers."
            end
            paid=paid+(C.IsPayment(row) and row.amountCopper or -row.amountCopper)
            if paid>terms.amountCopper then return nil,"A sync baseline exceeds the original obligation." end
        end
    end
    local bytes
    bytes, err = encodeFields(MESSAGE_HEADER, message, fields)
    if not bytes then return nil, err end
    return true
end

function C.Encode(message)
    local ok, err = C.ValidateMessage(message)
    if not ok then return nil, err end
    return encodeFields(MESSAGE_HEADER, message, messageFields(message.kind))
end

function C.Decode(bytes)
    local take, finished = reader(bytes, MESSAGE_HEADER)
    if not take then return nil, finished end
    local message = {}
    local ok, err = readFields(take, message, commonOrder)
    if not ok then return nil, err end
    local extra = variants[message.kind]
    if not extra then return nil, "Unknown shared message kind." end
    ok, err = readFields(take, message, extra)
    if not ok then return nil, err end
    if not finished() then return nil, "Trailing data after shared message." end
    message.version, message.revision = decimal(message.version, 1), decimal(message.revision, 1)
    if message.kind=="SYNC" then
        message.paidAmount=decimal(message.paidAmount,C.MAX_AMOUNT)
        message.baseRevision=decimal(message.baseRevision,C.MAX_CHAIN_ROWS)
    end
    ok, err = C.ValidateMessage(message)
    if not ok then return nil, err end
    local canonical
    canonical, err = C.Encode(message)
    if not canonical or canonical ~= bytes then return nil, err or "Message is not canonical." end
    return message
end
