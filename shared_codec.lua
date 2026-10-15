local _, IOU = ...
local C = {VERSION=1, MAX_BYTES=4096, MAX_NAME_BYTES=96, MAX_NOTE_BYTES=512,
    MAX_ID_BYTES=64, MAX_AMOUNT=999999999, MAX_TIMESTAMP=4102444800}
IOU.SharedCodec = C

-- Logical messages only. This readable, length-prefixed format is deliberately
-- separate from the 240-byte link experiment and is not packet framing.
local TERMS_HEADER, MESSAGE_HEADER = "IOUST1:", "IOUSM1:"
local termsOrder = {"protocol", "kind", "proposer", "recipient", "debtor", "creditor", "amountCopper", "dueUTC", "note"}
local commonOrder = {"version", "kind", "messageId", "agreementId", "offerId", "revision", "terms"}
local variants = {PROPOSE={}, ACCEPT={"acceptanceId"}, COMMIT={"acceptanceId", "commitId"},
    ACK={"acceptanceId", "commitId"}, DECLINE={}, WITHDRAW={"outcomeId"},
    OUTCOME={"outcomeId", "outcome"}, STATUS={}}

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

function C.ValidateTerms(terms)
    local ok, err = exactKeys(terms, termsOrder)
    if not ok then return nil, err end
    if terms.protocol ~= 1 or terms.kind ~= "GOLD_OBLIGATION" then return nil, "Unsupported shared terms version or kind." end
    for _, field in ipairs({"proposer", "recipient", "debtor", "creditor"}) do
        if not name(terms[field]) then return nil, field .. " must be a plain UTF-8 full name with single spaces (1-96 bytes)." end
    end
    if asciiLower(terms.proposer) == asciiLower(terms.recipient) then return nil, "The two participants must be distinct." end
    if (terms.debtor ~= terms.proposer and terms.debtor ~= terms.recipient)
        or (terms.creditor ~= terms.proposer and terms.creditor ~= terms.recipient)
        or terms.debtor == terms.creditor then return nil, "Debtor and creditor must be the two exact participants." end
    if not integer(terms.amountCopper, 1, C.MAX_AMOUNT) then return nil, "Gold must be positive integer copper within the supported limit." end
    if not integer(terms.dueUTC, 0, C.MAX_TIMESTAMP) then return nil, "Due date must be zero or a supported UTC timestamp." end
    if not text(terms.note, C.MAX_NOTE_BYTES, true) then return nil, "Note must be plain UTF-8 without controls or pipes (up to 512 bytes)." end
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
    return encodeFields(TERMS_HEADER, terms, termsOrder)
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
    local take, finished = reader(bytes, TERMS_HEADER)
    if not take then return nil, finished end
    local terms = {}
    local ok, err = readFields(take, terms, termsOrder)
    if not ok then return nil, err end
    if not finished() then return nil, "Trailing data after shared terms." end
    terms.protocol = decimal(terms.protocol, 1)
    terms.amountCopper = decimal(terms.amountCopper, C.MAX_AMOUNT)
    terms.dueUTC = decimal(terms.dueUTC, C.MAX_TIMESTAMP)
    ok, err = C.ValidateTerms(terms)
    if not ok then return nil, err end
    local canonical
    canonical, err = C.CanonicalTerms(terms)
    if not canonical or canonical ~= bytes then return nil, err or "Terms are not canonical." end
    return terms
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
        elseif not id(message[field]) then return nil, "Invalid " .. field .. "." end
    end
    local terms
    terms, err = C.ParseTerms(message.terms)
    if not terms then return nil, "Invalid bound terms: " .. tostring(err) end
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
    ok, err = C.ValidateMessage(message)
    if not ok then return nil, err end
    local canonical
    canonical, err = C.Encode(message)
    if not canonical or canonical ~= bytes then return nil, err or "Message is not canonical." end
    return message
end
