local _, ns = ...

-- No WoW dependencies. Financial history and corrections are append-only.
local Ledger = {}
ns.Ledger = Ledger

Ledger.MAX_ENTRIES = 1000
Ledger.MAX_EVENTS = 200
Ledger.MAX_AMOUNT = 999999999
Ledger.MAX_TIMESTAMP = 4102444800
Ledger.MAX_PLAYER = 80
Ledger.MAX_LABEL = 512
Ledger.MAX_NOTE = 2000
Ledger.DEFAULT_REASON = "No reason provided"

local floor = math.floor
local dbKeys = { schema = true, nextID = true, entries = true }
local entryKeys1 = {
    id = true, player = true, direction = true, kind = true, amount = true,
    label = true, note = true, created = true, events = true,
}
local entryKeys2 = {
    id = true, player = true, direction = true, kind = true, amount = true,
    label = true, note = true, due = true, initial = true, created = true, events = true,
}
local metadataKeys = { player = true, label = true, note = true, due = true }
local addKeys = {
    player = true, direction = true, kind = true, amount = true,
    label = true, note = true, due = true,
}
local paymentKeys = { id = true, type = true, amount = true, note = true, at = true }
local reversalKeys = { id = true, type = true, reverses = true, note = true, at = true }
local amendmentKeys = { id = true, type = true, before = true, after = true, note = true, at = true }
local lifecycleKeys = { id = true, type = true, note = true, at = true }

local function integer(value, minimum, maximum)
    return type(value) == "number" and value == value and value >= minimum
        and value <= maximum and value == floor(value)
end

local function plainTable(value, keys)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "Expected a plain table."
    end
    for key in pairs(value) do
        if not keys[key] then return nil, "Unexpected field in ledger data." end
    end
    return true
end

local function arrayLength(value, maximum)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, "Expected a plain array."
    end
    local count, highest = 0, 0
    for key in pairs(value) do
        if not integer(key, 1, maximum) then return nil, "Array contains an invalid index." end
        count = count + 1
        if key > highest then highest = key end
    end
    if count ~= highest then return nil, "Array must not contain gaps." end
    return count
end

local function text(value, maximum, required)
    if type(value) ~= "string" or #value > maximum then return false end
    if value:find("[%z\1-\8\11\12\14-\31\127]") then return false end
    return not required or value:find("%S") ~= nil
end

local function playerName(value)
    return text(value, Ledger.MAX_PLAYER, true) and not value:find("[%z\1-\31\127|]")
end

-- New actions may omit an explanation. Keep a neutral, explicit audit entry
-- rather than weakening the validation of existing history records.
local function optionalReason(value)
    if value == nil then return Ledger.DEFAULT_REASON end
    if text(value, Ledger.MAX_NOTE, false) and not value:find("%S") then
        return Ledger.DEFAULT_REASON
    end
    return value
end

local function metadata(record, kind, strict)
    if strict then
        local ok, err = plainTable(record, metadataKeys)
        if not ok then return nil, err end
    end
    if not playerName(record.player) then
        return nil, "Enter a player name of 1-80 bytes without control characters or pipes."
    end
    if not text(record.label, Ledger.MAX_LABEL, kind ~= "money") then
        return nil, "Items and favors need a label of at most 512 bytes."
    end
    if kind == "money" and record.label ~= "" then return nil, "Money entries must have an empty label." end
    if not text(record.note, Ledger.MAX_NOTE, false) then return nil, "Notes must be text of at most 2000 bytes." end
    if strict and not integer(record.due, 0, Ledger.MAX_TIMESTAMP) then
        return nil, "Due date must be a whole timestamp, or zero for no due date."
    end
    return true
end

local function copyMetadata(record)
    return { player = record.player, label = record.label, note = record.note, due = record.due or 0 }
end

local function sameMetadata(a, b)
    return a.player == b.player and a.label == b.label and a.note == b.note and a.due == b.due
end

local function inferredSchema(entry)
    return type(entry) == "table" and getmetatable(entry) == nil
        and (entry.due ~= nil or entry.initial ~= nil) and 2 or 1
end

-- Replay is also used by read-only helpers so malformed histories cannot affect
-- displayed balances. Schema 1 keeps its original exact set of allowed fields.
local function validateEntry(entry, expectedID, schema)
    schema = schema or inferredSchema(entry)
    local ok, err = plainTable(entry, schema == 2 and entryKeys2 or entryKeys1)
    if not ok then return nil, err end
    if not integer(entry.id, 1, Ledger.MAX_ENTRIES) or (expectedID and entry.id ~= expectedID) then
        return nil, "Entry IDs must follow insertion order."
    end
    if entry.direction ~= "owed" and entry.direction ~= "owe" then return nil, "Direction must be owed or owe." end
    if entry.kind ~= "money" and entry.kind ~= "item" and entry.kind ~= "favor" then
        return nil, "Kind must be money, item, or favor."
    end
    if not integer(entry.amount, 1, Ledger.MAX_AMOUNT) then
        return nil, "Amount must be a whole number from 1 to 999999999."
    end
    ok, err = metadata(entry, entry.kind, false)
    if not ok then return nil, err end
    if not integer(entry.created, 0, Ledger.MAX_TIMESTAMP) then return nil, "Entry timestamp is invalid." end
    local effective
    if schema == 2 then
        if not integer(entry.due, 0, Ledger.MAX_TIMESTAMP) then return nil, "Due date is invalid." end
        ok, err = metadata(entry.initial, entry.kind, true)
        if not ok then return nil, "Original agreement: " .. err end
        effective = entry.initial
    end
    local count
    count, err = arrayLength(entry.events, Ledger.MAX_EVENTS)
    if not count then return nil, err end
    local balance, payments, reversed, cancelled = entry.amount, {}, {}, false
    for index = 1, count do
        local event = entry.events[index]
        if type(event) ~= "table" or getmetatable(event) ~= nil then return nil, "History event must be a plain table." end
        local keys = event.type == "payment" and paymentKeys or event.type == "reversal" and reversalKeys
        if schema == 2 then
            keys = keys or (event.type == "amendment" and amendmentKeys)
                or ((event.type == "cancel" or event.type == "restore") and lifecycleKeys)
        end
        if not keys then return nil, "Unknown history event type." end
        ok, err = plainTable(event, keys)
        if not ok then return nil, err end
        if event.id ~= index then return nil, "History event IDs must be sequential." end
        if not text(event.note, Ledger.MAX_NOTE, event.type ~= "payment") then
            return nil, "History corrections need a reason of at most 2000 bytes."
        end
        if not integer(event.at, 0, Ledger.MAX_TIMESTAMP) then return nil, "History timestamp is invalid." end
        if event.type == "restore" then
            if not cancelled then return nil, "Only a cancelled IOU can be restored." end
            cancelled = false
        elseif cancelled then
            return nil, "A cancelled IOU must be restored before it can change."
        elseif event.type == "payment" then
            if not integer(event.amount, 1, Ledger.MAX_AMOUNT) then return nil, "Payment amount is invalid." end
            if event.amount > balance then return nil, "History contains an overpayment." end
            payments[index] = event.amount
            balance = balance - event.amount
        elseif event.type == "reversal" then
            local reference = event.reverses
            if not integer(reference, 1, index - 1) or not payments[reference] then
                return nil, "A reversal must reference an earlier payment."
            end
            if reversed[reference] then return nil, "A payment may only be reversed once." end
            reversed[reference] = true
            balance = balance + payments[reference]
        elseif event.type == "amendment" then
            ok, err = metadata(event.before, entry.kind, true)
            if not ok then return nil, "Before amendment: " .. err end
            ok, err = metadata(event.after, entry.kind, true)
            if not ok then return nil, "After amendment: " .. err end
            if not sameMetadata(effective, event.before) then return nil, "Amendment does not match the preceding agreement." end
            if sameMetadata(event.before, event.after) then return nil, "Amendment must change the agreement." end
            effective = event.after
        elseif event.type == "cancel" then
            if balance == 0 then return nil, "A settled IOU cannot be cancelled." end
            cancelled = true
        end
    end
    if schema == 2 and not sameMetadata(entry, effective) then
        return nil, "Current agreement does not match its history."
    end
    return true, balance, cancelled
end

function Ledger.New()
    return { schema = 2, nextID = 1, entries = {} }
end

function Ledger.Validate(db)
    local ok, err = plainTable(db, dbKeys)
    if not ok then return nil, err end
    if db.schema ~= 1 and db.schema ~= 2 then return nil, "Unsupported ledger schema." end
    local count
    count, err = arrayLength(db.entries, Ledger.MAX_ENTRIES)
    if not count then return nil, err end
    if not integer(db.nextID, 1, Ledger.MAX_ENTRIES + 1) or db.nextID ~= count + 1 then
        return nil, "The next entry ID is invalid."
    end
    for index = 1, count do
        ok, err = validateEntry(db.entries[index], index, db.schema)
        if not ok then return nil, "Entry " .. index .. ": " .. err end
    end
    return true
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = deepCopy(child) end
    return result
end

function Ledger.Upgrade(db)
    local ok, err = Ledger.Validate(db)
    if not ok then return nil, err end
    local result = deepCopy(db)
    if result.schema == 1 then
        result.schema = 2
        for _, entry in ipairs(result.entries) do
            entry.due = 0
            entry.initial = copyMetadata(entry)
        end
    end
    return result
end

function Ledger.Add(db, data, timestamp)
    local ok, err = Ledger.Validate(db)
    if not ok then return nil, err end
    if #db.entries >= Ledger.MAX_ENTRIES then return nil, "The ledger is full (1000 entries)." end
    ok, err = plainTable(data, addKeys)
    if not ok then return nil, err end
    local entry = {
        id = db.nextID, player = data.player, direction = data.direction,
        kind = data.kind, amount = data.amount, label = data.label == nil and "" or data.label,
        note = data.note == nil and "" or data.note, created = timestamp, events = {},
    }
    if db.schema == 2 then
        entry.due = data.due == nil and 0 or data.due
        entry.initial = copyMetadata(entry)
    elseif data.due ~= nil and data.due ~= 0 then
        return nil, "Upgrade this ledger before adding a due date."
    end
    ok, err = validateEntry(entry, db.nextID, db.schema)
    if not ok then return nil, err end
    db.entries[#db.entries + 1] = entry
    db.nextID = db.nextID + 1
    return entry
end

function Ledger.Get(db, id)
    if type(db) ~= "table" or type(db.entries) ~= "table" or not integer(id, 1, Ledger.MAX_ENTRIES) then return nil end
    local entry = db.entries[id]
    if type(entry) == "table" and entry.id == id then return entry end
end

function Ledger.Balance(entry)
    local ok, balance = validateEntry(entry)
    if not ok then return nil, balance end
    return balance
end

function Ledger.Cancelled(entry)
    local ok, err, cancelled = validateEntry(entry)
    if not ok then return nil, err end
    return cancelled
end

function Ledger.Status(entry)
    local ok, balance, cancelled = validateEntry(entry)
    if not ok then return nil, balance end
    if cancelled then return "cancelled" end
    if balance == 0 then return "settled" end
    if balance < entry.amount then return "partial" end
    return "outstanding"
end

function Ledger.IsOverdue(entry, now)
    if not integer(now, 0, Ledger.MAX_TIMESTAMP) then return false end
    local ok, balance, cancelled = validateEntry(entry)
    return ok and balance > 0 and not cancelled and (entry.due or 0) > 0 and now > entry.due or false
end

local function mutableEntry(db, id, note, timestamp, allowCancelled, requireNewSchema)
    local ok, err = Ledger.Validate(db)
    if not ok then return nil, err end
    if requireNewSchema and db.schema ~= 2 then return nil, "Upgrade this ledger before changing agreement details." end
    local entry = Ledger.Get(db, id)
    if not entry then return nil, "Entry not found." end
    if #entry.events >= Ledger.MAX_EVENTS then return nil, "This entry has reached its history limit (200 events)." end
    if not text(note, Ledger.MAX_NOTE, false) then return nil, "History notes must be text of at most 2000 bytes." end
    if not integer(timestamp, 0, Ledger.MAX_TIMESTAMP) then return nil, "History timestamp is invalid." end
    if not allowCancelled and Ledger.Cancelled(entry) then return nil, "Restore this cancelled IOU before changing it." end
    return entry
end

function Ledger.Pay(db, id, amount, note, timestamp)
    if note == nil then note = "" end
    local entry, err = mutableEntry(db, id, note, timestamp)
    if not entry then return nil, err end
    if not integer(amount, 1, Ledger.MAX_AMOUNT) then return nil, "Payment must be a positive whole number." end
    if amount > Ledger.Balance(entry) then return nil, "Payment exceeds the remaining balance." end
    local event = { id = #entry.events + 1, type = "payment", amount = amount, note = note, at = timestamp }
    entry.events[#entry.events + 1] = event
    return event
end

function Ledger.Settle(db, id, note, timestamp)
    local ok, err = Ledger.Validate(db)
    if not ok then return nil, err end
    local entry = Ledger.Get(db, id)
    if not entry then return nil, "Entry not found." end
    if Ledger.Cancelled(entry) then return nil, "Restore this cancelled IOU before changing it." end
    local balance = Ledger.Balance(entry)
    if balance == 0 then return nil, "This entry is already settled." end
    return Ledger.Pay(db, id, balance, note, timestamp)
end

function Ledger.Reverse(db, id, eventID, reason, timestamp)
    reason = optionalReason(reason)
    local entry, err = mutableEntry(db, id, reason, timestamp)
    if not entry then return nil, err end
    if not integer(eventID, 1, #entry.events) then return nil, "Payment not found." end
    if entry.events[eventID].type ~= "payment" then return nil, "Only payments can be reversed." end
    for _, event in ipairs(entry.events) do
        if event.type == "reversal" and event.reverses == eventID then return nil, "This payment has already been reversed." end
    end
    local event = { id = #entry.events + 1, type = "reversal", reverses = eventID, note = reason, at = timestamp }
    entry.events[#entry.events + 1] = event
    return event
end

function Ledger.Amend(db, id, details, reason, timestamp)
    reason = optionalReason(reason)
    local entry, err = mutableEntry(db, id, reason, timestamp, false, true)
    if not entry then return nil, err end
    local ok
    ok, err = metadata(details, entry.kind, true)
    if not ok then return nil, err end
    if sameMetadata(entry, details) then return nil, "Change at least one agreement detail." end
    local event = {
        id = #entry.events + 1, type = "amendment", before = copyMetadata(entry),
        after = copyMetadata(details), note = reason, at = timestamp,
    }
    entry.player, entry.label, entry.note, entry.due = details.player, details.label, details.note, details.due
    entry.events[#entry.events + 1] = event
    return event
end

local function lifecycle(db, id, reason, timestamp, restoring)
    reason = optionalReason(reason)
    local entry, err = mutableEntry(db, id, reason, timestamp, restoring, true)
    if not entry then return nil, err end
    if restoring then
        if not Ledger.Cancelled(entry) then return nil, "Only a cancelled IOU can be restored." end
    elseif Ledger.Balance(entry) == 0 then
        return nil, "A settled IOU cannot be cancelled."
    end
    local event = { id = #entry.events + 1, type = restoring and "restore" or "cancel", note = reason, at = timestamp }
    entry.events[#entry.events + 1] = event
    return event
end

function Ledger.Cancel(db, id, reason, timestamp)
    return lifecycle(db, id, reason, timestamp, false)
end

function Ledger.Restore(db, id, reason, timestamp)
    return lifecycle(db, id, reason, timestamp, true)
end

local function matches(entry, query, options)
    local kind = options and options.kind
    if kind and kind ~= "all" and kind ~= entry.kind then return false end
    if query == nil or query == "" then return true end
    if type(query) ~= "string" then return false end
    query = query:lower()
    return entry.player:lower():find(query, 1, true) ~= nil
        or entry.label:lower():find(query, 1, true) ~= nil
        or entry.note:lower():find(query, 1, true) ~= nil
end

function Ledger.Summary(db, direction, query, options)
    local result = { money = 0, active = 0, items = 0, favors = 0 }
    if type(options) ~= "table" then options = nil end
    if options and options.now ~= nil then result.overdue = 0 end
    if not Ledger.Validate(db) then return result end
    for _, entry in ipairs(db.entries) do
        if entry.direction == direction and matches(entry, query, options) then
            local _, balance, cancelled = validateEntry(entry)
            if balance > 0 and not cancelled then
                result.active = result.active + 1
                if entry.kind == "money" then result.money = result.money + balance
                elseif entry.kind == "item" then result.items = result.items + 1
                else result.favors = result.favors + 1 end
                if result.overdue and Ledger.IsOverdue(entry, options.now) then result.overdue = result.overdue + 1 end
            end
        end
    end
    return result
end

function Ledger.List(db, tab, query, options)
    local result = {}
    if not Ledger.Validate(db) then return result end
    if type(options) ~= "table" then options = nil end
    tab = tab or "owed"
    for _, entry in ipairs(db.entries) do
        if matches(entry, query, options) then
            local _, balance, cancelled = validateEntry(entry)
            local closed = balance == 0 or cancelled
            if tab == "all" or (tab == "history" and closed) or (entry.direction == tab and not closed) then
                result[#result + 1] = entry
            end
        end
    end
    local sort = options and options.sort or "newest"
    table.sort(result, function(a, b)
        if sort == "player" then
            local left, right = a.player:lower(), b.player:lower()
            if left ~= right then return left < right end
        elseif sort == "due" then
            local left, right = a.due or 0, b.due or 0
            if left ~= right then
                if left == 0 then return false end
                if right == 0 then return true end
                return left < right
            end
        elseif sort == "oldest" then
            if a.created ~= b.created then return a.created < b.created end
        else
            if a.created ~= b.created then return a.created > b.created end
            return a.id > b.id
        end
        return a.id < b.id
    end)
    return result
end

function Ledger.FormatMoney(copper)
    -- Summary totals remain exactly representable in a Lua double.
    if not integer(copper, 0, Ledger.MAX_AMOUNT * Ledger.MAX_ENTRIES) then return "0g 00s 00c" end
    return string.format("%dg %02ds %02dc", floor(copper / 10000), floor(copper / 100) % 100, copper % 100)
end
