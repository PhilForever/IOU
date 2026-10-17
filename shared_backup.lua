local _, IOU = ...
local B = {
    VERSION = 1, HEADER = "IOUS1:", MAX_BYTES = 8388608,
    MAX_RAW_BYTES = 6291450, MAX_DEPTH = 12, MAX_NODES = 100000,
    MAX_INTEGER = 9007199254740991, MAX_TIME = 4102444800,
}
IOU.SharedBackup = B

-- A shared snapshot is data, never executable Lua. The canonical raw grammar is
-- s<byte length>:<bytes>, i<unsigned integer>;, a<count>:<values>, or
-- m<count>:<string key><value>... with keys in byte order. Empty tables use m0:.
-- Base64 armor preserves every string byte across clipboard line wrapping.
-- The 8 MiB armored / just-under-6 MiB raw limits allow retained message evidence
-- for retained offers. Depth and node limits bound work independently of byte size.
-- This module validates the envelope and data tree only. SharedService must
-- validate the full storage wrapper and agreement graph before any restoration.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUES = {}
for index = 1, #ALPHABET do VALUES[ALPHABET:byte(index)] = index - 1 end
local TOO_LARGE = "Shared backup exceeds the 8 MiB text limit."
local BAD_TREE = "Shared backup contains unsupported or invalid data."

local function fail(message) error(message, 0) end
local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function integer(value, maximum)
    return plain(value) and type(value) == "number" and value >= 0
        and value <= maximum and value == math.floor(value)
end
local function tablePlain(value)
    return plain(value) and type(value) == "table" and getmetatable(value) == nil
end
local function envelope(value)
    if not tablePlain(value) then fail("Not a shared backup snapshot.") end
    local required = {version=true, character=true, owner=true, exportedAt=true, entry=true}
    local count = 0
    for key in pairs(value) do
        if not plain(key) or type(key) ~= "string" or not required[key] then
            fail("Shared backup has unexpected envelope fields.")
        end
        count = count + 1
    end
    if count ~= 5 or not plain(value.version) or value.version ~= B.VERSION
        or not plain(value.character) or type(value.character) ~= "string"
        or #value.character < 1 or #value.character > 256
        or not plain(value.owner) or type(value.owner) ~= "string"
        or #value.owner < 1 or #value.owner > 96
        or not integer(value.exportedAt, B.MAX_TIME) or not tablePlain(value.entry)
        or not tablePlain(value.entry.store) or not plain(value.entry.store.localName)
        or value.entry.store.localName ~= value.owner then
        fail("Shared backup envelope or owner is invalid.")
    end
    return true
end

local function decimal(value)
    if value == 0 then return "0" end -- Normalize negative zero too.
    return string.format("%.0f", value)
end
local function byteLess(left, right)
    for index = 1, math.min(#left, #right) do
        local a, b = left:byte(index), right:byte(index)
        if a ~= b then return a < b end
    end
    return #left < #right
end
local function canonical(snapshot)
    envelope(snapshot)
    local chunks, size, nodes, seen = {}, 0, 0, {}
    local function put(part)
        size = size + #part
        if size > B.MAX_RAW_BYTES then fail(TOO_LARGE) end
        chunks[#chunks + 1] = part
    end
    local function write(value, depth)
        nodes = nodes + 1
        if depth > B.MAX_DEPTH or nodes > B.MAX_NODES then
            fail("Shared backup exceeds its data complexity limit.")
        end
        if not plain(value) then fail(BAD_TREE) end
        local kind = type(value)
        if kind == "string" then
            put("s" .. #value .. ":")
            put(value)
        elseif kind == "number" then
            if not integer(value, B.MAX_INTEGER) then fail(BAD_TREE) end
            put("i" .. decimal(value) .. ";")
        elseif kind == "table" then
            if getmetatable(value) ~= nil or seen[value] then fail(BAD_TREE) end
            seen[value] = true -- Aliases as well as cycles are forbidden.
            local keys, numeric, textual, maximum = {}, 0, 0, 0
            for key in pairs(value) do
                if not plain(key) then fail(BAD_TREE) end
                if type(key) == "string" then textual = textual + 1
                elseif integer(key, B.MAX_NODES) and key >= 1 then
                    numeric = numeric + 1
                    if key > maximum then maximum = key end
                else fail(BAD_TREE) end
                keys[#keys + 1] = key
                if #keys > B.MAX_NODES then fail("Shared backup exceeds its data complexity limit.") end
            end
            if numeric > 0 then
                if textual > 0 or maximum ~= numeric then fail(BAD_TREE) end
                put("a" .. numeric .. ":")
                for index = 1, numeric do write(value[index], depth + 1) end
            else
                table.sort(keys, byteLess)
                put("m" .. textual .. ":")
                for _, key in ipairs(keys) do
                    write(key, depth + 1)
                    write(value[key], depth + 1)
                end
            end
        else fail(BAD_TREE) end
    end
    write(snapshot, 1)
    return table.concat(chunks)
end

local function armor(raw)
    local chunks = {}
    for index = 1, #raw, 3 do
        local a, b, c = raw:byte(index, index + 2)
        local second, third = b, c
        b, c = b or 0, c or 0
        local p, q = math.floor(a / 4) + 1, (a % 4) * 16 + math.floor(b / 16) + 1
        local r, s = (b % 16) * 4 + math.floor(c / 64) + 1, c % 64 + 1
        chunks[#chunks + 1] = ALPHABET:sub(p,p) .. ALPHABET:sub(q,q)
            .. (second and ALPHABET:sub(r,r) or "=") .. (third and ALPHABET:sub(s,s) or "=")
    end
    return B.HEADER .. table.concat(chunks)
end
local function unarmor(text)
    if not plain(text) or type(text) ~= "string" then fail("Paste a shared backup as text.") end
    if #text > B.MAX_BYTES then fail(TOO_LARGE) end
    text = text:gsub("^[ \t\r\n\f\v]+", ""):gsub("[ \t\r\n\f\v]+$", "")
    if text:sub(1, #B.HEADER) ~= B.HEADER then fail("Not an IOUS1 shared backup.") end
    local payload = text:sub(#B.HEADER + 1):gsub("[ \t\r\n\f\v]", "")
    if #payload == 0 or #payload % 4 ~= 0 then fail("Invalid shared backup base64.") end
    local chunks, size = {}, 0
    for index = 1, #payload, 4 do
        local a, b, c, d = payload:byte(index, index + 3)
        local x, y, z, w = VALUES[a], VALUES[b], VALUES[c], VALUES[d]
        if x == nil or y == nil then fail("Invalid shared backup base64.") end
        local first, part = x * 4 + math.floor(y / 16)
        if c == 61 then
            if d ~= 61 or index ~= #payload - 3 or y % 16 ~= 0 then
                fail("Invalid or noncanonical shared backup base64.")
            end
            part = string.char(first)
        else
            if z == nil then fail("Invalid shared backup base64.") end
            local second = (y % 16) * 16 + math.floor(z / 4)
            if d == 61 then
                if index ~= #payload - 3 or z % 4 ~= 0 then
                    fail("Invalid or noncanonical shared backup base64.")
                end
                part = string.char(first, second)
            else
                if w == nil then fail("Invalid shared backup base64.") end
                part = string.char(first, second, (z % 4) * 64 + w)
            end
        end
        size = size + #part
        if size > B.MAX_RAW_BYTES then fail(TOO_LARGE) end
        chunks[#chunks + 1] = part
    end
    return table.concat(chunks)
end
local function parse(raw)
    local position, nodes = 1, 0
    local function number(ending, maximum)
        local start = position
        local stop = raw:find(ending, start, true)
        if not stop or stop - start > 16 then fail("Invalid shared backup token length.") end
        local token = raw:sub(start, stop - 1)
        if not token:match("^%d+$") or (#token > 1 and token:sub(1,1) == "0") then
            fail("Invalid or noncanonical shared backup number.")
        end
        local value = tonumber(token)
        if not integer(value, maximum) then fail("Shared backup number exceeds its limit.") end
        position = stop + 1
        return value
    end
    local function read(depth)
        nodes = nodes + 1
        if depth > B.MAX_DEPTH or nodes > B.MAX_NODES then
            fail("Shared backup exceeds its data complexity limit.")
        end
        local kind = raw:sub(position, position)
        position = position + 1
        if kind == "s" then
            local count = number(":", B.MAX_RAW_BYTES)
            if count > #raw - position + 1 then fail("Truncated shared backup string.") end
            local result = raw:sub(position, position + count - 1)
            position = position + count
            return result
        elseif kind == "i" then
            return number(";", B.MAX_INTEGER)
        elseif kind == "a" or kind == "m" then
            local count = number(":", B.MAX_NODES)
            if (kind == "a" and count == 0) or nodes + count * (kind == "m" and 2 or 1) > B.MAX_NODES then
                fail("Noncanonical or oversized shared backup table.")
            end
            local result, previous = {}, nil
            for index = 1, count do
                if kind == "a" then result[index] = read(depth + 1)
                else
                    local key = read(depth + 1)
                    if type(key) ~= "string" or (previous ~= nil and not byteLess(previous, key)) then
                        fail("Shared backup map keys are duplicated or out of order.")
                    end
                    previous = key
                    result[key] = read(depth + 1)
                end
            end
            return result
        end
        fail("Unknown shared backup data token.")
    end
    local result = read(1)
    if position ~= #raw + 1 then fail("Shared backup has trailing data.") end
    envelope(result)
    return result
end
local function protected(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        -- Known failures are plain strings. Never expose exception objects or
        -- secret client values supplied by an external table or API.
        if plain(result) and type(result) == "string" then return nil, result end
        return nil, BAD_TREE
    end
    return result
end
function B.ValidateEnvelope(snapshot) return protected(envelope, snapshot) end
function B.Canonical(snapshot) return protected(canonical, snapshot) end
function B.Encode(snapshot)
    return protected(function()
        local text = armor(canonical(snapshot))
        if #text > B.MAX_BYTES then fail(TOO_LARGE) end
        return text
    end)
end
function B.Decode(text)
    return protected(function() return parse(unarmor(text)) end)
end
