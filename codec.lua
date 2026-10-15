local _, ns = ...

local Codec = {}
ns.Codec = Codec
Codec.MAX_BYTES = 1048576

-- IOU1/IOU2 are ASCII-armored fixed-field formats. Each token is a netstring:
-- decimal byte length, colon, literal bytes, comma. Names, labels, and notes
-- never become Lua source, and punctuation/newlines inside them are unambiguous.
-- Base64 armor keeps Unicode, item pipes, and newlines intact when copied from
-- an EditBox or moved through a clipboard that converts line endings.
-- Root tokens: schema, nextID, entryCount.
-- IOU1 entries/events retain their original byte-for-byte representation.
-- IOU2 entry tokens extend the prefix through created with due, initial metadata
-- (player,label,note,due), then eventCount. Amendments encode before and after
-- metadata; payment/reversal keep their numeric token; cancel/restore need none.
-- All event variants end in note, at.
local HEADERS = { [1] = "IOU1:", [2] = "IOU2:" }
local TOO_LARGE = "Backup exceeds the 1 MB limit."
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUES = {}
for index = 1, #ALPHABET do VALUES[ALPHABET:byte(index)] = index - 1 end

local function encode(raw)
    local chunks = {}
    for index = 1, #raw, 3 do
        local a, b, c = raw:byte(index, index + 2)
        local second, third = b, c
        b, c = b or 0, c or 0
        local p = math.floor(a / 4) + 1
        local q = (a % 4) * 16 + math.floor(b / 16) + 1
        local r = (b % 16) * 4 + math.floor(c / 64) + 1
        local s = c % 64 + 1
        chunks[#chunks + 1] = ALPHABET:sub(p, p) .. ALPHABET:sub(q, q)
            .. (second and ALPHABET:sub(r, r) or "=")
            .. (third and ALPHABET:sub(s, s) or "=")
    end
    return table.concat(chunks)
end

local function decode(payload)
    local function fail() error("Invalid or noncanonical base64 backup.", 0) end
    if #payload % 4 ~= 0 then fail() end
    local chunks, size = {}, 0
    for index = 1, #payload, 4 do
        local a, b, c, d = payload:byte(index, index + 3)
        local x, y, z, w = VALUES[a], VALUES[b], VALUES[c], VALUES[d]
        if x == nil or y == nil then fail() end
        local first = x * 4 + math.floor(y / 16)
        local part
        if c == 61 then -- Two padding bytes: the unused four bits must be zero.
            if d ~= 61 or index ~= #payload - 3 or y % 16 ~= 0 then fail() end
            part = string.char(first)
        else
            if z == nil then fail() end
            local second = (y % 16) * 16 + math.floor(z / 4)
            if d == 61 then -- One padding byte: the unused two bits must be zero.
                if index ~= #payload - 3 or z % 4 ~= 0 then fail() end
                part = string.char(first, second)
            else
                if w == nil then fail() end
                part = string.char(first, second, (z % 4) * 64 + w)
            end
        end
        size = size + #part
        if size > Codec.MAX_BYTES then error(TOO_LARGE, 0) end
        chunks[#chunks + 1] = part
    end
    return table.concat(chunks)
end

function Codec.Export(db)
    local Ledger = ns.Ledger
    local ok, err = Ledger.Validate(db)
    if not ok then return nil, err end
    local header = HEADERS[db.schema]
    local rawLimit = math.floor((Codec.MAX_BYTES - #header) / 4) * 3
    local chunks, size, overflow = {}, 0, false
    local function put(value)
        if overflow then return end
        if type(value) == "number" then value = string.format("%.0f", value) end
        local token = #value .. ":" .. value .. ","
        size = size + #token
        if size > rawLimit then overflow = true; return end
        chunks[#chunks + 1] = token
    end
    local function putMetadata(record)
        put(record.player)
        put(record.label)
        put(record.note)
        put(record.due)
    end
    put(db.schema)
    put(db.nextID)
    put(#db.entries)
    if overflow then return nil, TOO_LARGE end
    for _, entry in ipairs(db.entries) do
        put(entry.id)
        put(entry.player)
        put(entry.direction)
        put(entry.kind)
        put(entry.amount)
        put(entry.label)
        put(entry.note)
        put(entry.created)
        if db.schema == 2 then
            put(entry.due)
            putMetadata(entry.initial)
        end
        put(#entry.events)
        if overflow then return nil, TOO_LARGE end
        for _, event in ipairs(entry.events) do
            put(event.id)
            put(event.type)
            if event.type == "payment" then
                put(event.amount)
            elseif event.type == "reversal" then
                put(event.reverses)
            elseif event.type == "amendment" then
                putMetadata(event.before)
                putMetadata(event.after)
            end
            put(event.note)
            put(event.at)
            if overflow then return nil, TOO_LARGE end
        end
    end
    return header .. encode(table.concat(chunks))
end

function Codec.Import(input)
    if type(input) ~= "string" then return nil, "Paste an IOU backup as text." end
    if #input > Codec.MAX_BYTES then return nil, TOO_LARGE end
    -- Accept wrapping whitespace, but the format marker itself must stay intact.
    input = input:gsub("^[ \t\r\n\f\v]+", ""):gsub("[ \t\r\n\f\v]+$", "")
    local header = input:sub(1, 5)
    local version = header == HEADERS[1] and 1 or header == HEADERS[2] and 2
    if not version then return nil, "Not an IOU1 or IOU2 backup." end
    local payload = input:sub(#header + 1):gsub("[ \t\r\n\f\v]", "")
    local Ledger = ns.Ledger
    local function parse()
        local raw = decode(payload)
        local position = 1
        local function fail(message) error(message, 0) end
        local function read(maximum)
            local colon = raw:find(":", position, true)
            if not colon or colon - position > 7 then fail("Invalid token length.") end
            local prefix = raw:sub(position, colon - 1)
            if not prefix:match("^%d+$") or (#prefix > 1 and prefix:sub(1, 1) == "0") then
                fail("Invalid token length.")
            end
            local length = tonumber(prefix)
            if not length or length > maximum then fail("Backup field exceeds its limit.") end
            local ending = colon + length + 1
            if ending > #raw or raw:sub(ending, ending) ~= "," then
                fail("Truncated or invalid backup token.")
            end
            local value = raw:sub(colon + 1, ending - 1)
            position = ending + 1
            return value
        end
        local function number(maximum)
            local token = read(10)
            if not token:match("^%d+$") or (#token > 1 and token:sub(1, 1) == "0") then
                fail("Backup numbers must be unsigned whole numbers.")
            end
            local value = tonumber(token)
            if not value or value > maximum then fail("Backup number exceeds its limit.") end
            return value
        end
        local function readMetadata()
            return {
                player = read(Ledger.MAX_PLAYER), label = read(Ledger.MAX_LABEL),
                note = read(Ledger.MAX_NOTE), due = number(Ledger.MAX_TIMESTAMP),
            }
        end
        local db = { schema = number(2), nextID = number(Ledger.MAX_ENTRIES + 1), entries = {} }
        if db.schema ~= version then fail("Backup header and schema do not match.") end
        local count = number(Ledger.MAX_ENTRIES)
        for index = 1, count do
            local entry = {
                id = number(Ledger.MAX_ENTRIES),
                player = read(Ledger.MAX_PLAYER),
                direction = read(4),
                kind = read(5),
                amount = number(Ledger.MAX_AMOUNT),
                label = read(Ledger.MAX_LABEL),
                note = read(Ledger.MAX_NOTE),
                created = number(Ledger.MAX_TIMESTAMP),
                events = {},
            }
            if version == 2 then
                entry.due = number(Ledger.MAX_TIMESTAMP)
                entry.initial = readMetadata()
            end
            local eventCount = number(Ledger.MAX_EVENTS)
            for eventIndex = 1, eventCount do
                local event = { id = number(Ledger.MAX_EVENTS), type = read(version == 2 and 9 or 8) }
                if event.type == "payment" then
                    event.amount = number(Ledger.MAX_AMOUNT)
                elseif event.type == "reversal" then
                    event.reverses = number(Ledger.MAX_EVENTS)
                elseif version == 2 and event.type == "amendment" then
                    event.before = readMetadata()
                    event.after = readMetadata()
                elseif version == 2 and (event.type == "cancel" or event.type == "restore") then
                    -- No additional payload before the common note/timestamp.
                else
                    fail("Unknown history event type.")
                end
                event.note = read(Ledger.MAX_NOTE)
                event.at = number(Ledger.MAX_TIMESTAMP)
                entry.events[eventIndex] = event
            end
            db.entries[index] = entry
        end
        if position ~= #raw + 1 then fail("Unexpected data after the backup.") end
        local valid, err = Ledger.Validate(db)
        if not valid then fail(err) end
        return db
    end
    local ok, result = pcall(parse)
    if not ok then return nil, result end
    return result
end
