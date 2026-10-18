local _, IOU = ...
local Matching = {}
IOU.TradeMatching = Matching

-- A read-only decision: observing an asset never creates a new loan. Ambiguous
-- transfers retain their full amount for review rather than guessing an order.
local MAX_TOTAL, MAX_QUANTITY, MAX_SLOTS = 999999999000, 999999999, 6
local function public(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function plain(value)
    return public(value) and type(value) == "table" and getmetatable(value) == nil
end
local function integer(value, minimum, maximum)
    return public(value) and type(value) == "number" and value >= minimum
        and value <= maximum and value == math.floor(value)
end
local function text(value, maximum)
    return public(value) and type(value) == "string" and #value <= maximum
        and not value:find("[%z\001-\031\127]")
end
local function array(value, maximum)
    if not plain(value) then return nil end
    local count, highest = 0, 0
    for key in pairs(value) do
        if not integer(key, 1, maximum or MAX_SLOTS) then return nil end
        count, highest = count + 1, math.max(highest, key)
    end
    return count == highest and count or nil
end

-- Match the complete item payload, never its displayed colour or localized
-- name. Empty numeric fields and trailing zero fields are equivalent. Keep
-- every populated field in stored keys. Comparison below can ignore known
-- display context without rewriting old receipt or accepted Shared identities.
local function itemIdentity(value)
    if not text(value, 512) then return nil end
    local namedColor=value:match("^|cn[A-Za-z_][A-Za-z0-9_]*:")
    if namedColor then
        if value:sub(-2)~="|r" then return nil end
        value=value:sub(#namedColor+1,-3)
    elseif value:sub(1, 2) == "|c" then
        if not value:sub(3, 10):match("^%x%x%x%x%x%x%x%x$") or value:sub(-2) ~= "|r" then return nil end
        value = value:sub(11, -3)
    end
    local payload = value:match("^item:([%d:%-]+)$")
        or value:match("^|Hitem:([%d:%-]+)|h%[[^|]*%]|h$")
    if not payload then return nil end
    local fields = {}
    for field in (payload .. ":"):gmatch("(.-):") do
        if field ~= "" and not field:match("^%-?%d+$") then return nil end
        local number = field == "" and 0 or tonumber(field)
        if not integer(number, -4294967295, 4294967295) then return nil end
        fields[#fields+1] = number
        if #fields > 80 then return nil end
    end
    if not integer(fields[1], 1, 2147483647) then return nil end
    while #fields > 1 and fields[#fields] == 0 do fields[#fields] = nil end
    local canonical = {}
    for index, field in ipairs(fields) do canonical[index] = string.format("%.0f", field) end
    return "item:" .. table.concat(canonical, ":"), fields[1], fields
end
local function equivalentItems(left,right)
    local a,aid,af=itemIdentity(left)
    local b,bid,bf=itemIdentity(right)
    if not a or not b or aid~=bid then return false end
    -- Native item-string documentation names payload positions 9 and 10
    -- linkLevel and specializationID. These describe the link's viewer.
    -- Keep enchant/gems/suffix/uniqueID/upgrade/difficulty/bonus and every
    -- remaining field exact. Never normalize these bytes in saved evidence.
    -- Reference: build 70450 Blizzard_PTRFeedback/Blizzard_Reports.lua.
    for index=1,math.max(#af,#bf) do
        if index~=9 and index~=10 and (af[index] or 0)~=(bf[index] or 0) then return false end
    end
    return true
end

function Matching.EquivalentItems(left,right)
    local ok,result=pcall(equivalentItems,left,right)
    return ok and result==true
end

local function asset(row, amount)
    return {asset=row.asset, direction=row.direction, amount=amount or row.amount,
        label=row.label, itemID=row.itemID, itemKey=row.itemKey}
end
local function candidateOrder(a, b)
    if a.source ~= b.source then return a.source == "personal" end
    if a.source == "personal" then return a.entryID < b.entryID end
    return a.offerID < b.offerID
end
local function normalizeSide(side, direction, maximum)
    if not plain(side) then return nil, "Trade contents are unavailable." end
    local money = side.money == nil and 0 or side.money
    local items = side.items == nil and {} or side.items
    if not integer(money, 0, MAX_TOTAL) or not array(items, maximum) then return nil, "Transfer amounts are invalid." end
    local rows, groups = {}, {}
    if money > 0 then rows[#rows+1] = {asset="money", direction=direction, amount=money, label="Gold"} end
    for _, item in ipairs(items) do
        if not plain(item) or not integer(item.itemID, 1, 2147483647)
            or not integer(item.quantity, 1, MAX_QUANTITY)
            or not text(item.name, 512) or item.name == "" or item.name:find("|", 1, true) then
            return nil, "A traded item is incomplete."
        end
        local key, id = itemIdentity(item.link)
        if not key or id ~= item.itemID then return nil, "A traded item link is unavailable or inconsistent." end
        local row = groups[key]
        if not row then
            row = {asset="item", direction=direction, amount=0, label=item.name,
                itemID=id, itemKey=key, names={}}
            groups[key] = row
            rows[#rows+1] = row
        end
        if row.amount > MAX_TOTAL - item.quantity then return nil, "The traded item total is too large." end
        row.amount = row.amount + item.quantity
        row.names[item.name] = true
        if item.name < row.label then row.label = item.name end
    end
    table.sort(rows, function(a, b)
        if a.asset ~= b.asset then return a.asset == "money" end
        return (a.itemKey or "") < (b.itemKey or "")
    end)
    local names = {}
    for _, row in ipairs(rows) do
        for label in pairs(row.names or {}) do names[label] = (names[label] or 0) + 1 end
    end
    return rows, names
end

local function makePlan(db, overview, transfer)
    local L, Summary, Codec = IOU.Ledger, IOU.PlayerSummary, IOU.SharedCodec
    if not plain(transfer) or type(L) ~= "table" or type(Summary) ~= "table" then
        return nil, "Trade matching is unavailable."
    end
    if transfer.service ~= nil and (not public(transfer.service) or type(transfer.service) ~= "boolean") then
        return nil, "The trade service flag is invalid."
    end
    local peerKey, problem = Summary.NameKey(transfer.peer)
    if not peerKey then return nil, problem end
    local valid
    valid, problem = L.Validate(db)
    if not valid then return nil, problem end
    local medium=transfer.medium==nil and "trade" or transfer.medium
    if medium~="trade" and medium~="mail_sent" and medium~="mail_received" then return nil,"Unknown transfer source." end
    local maximum=medium=="trade" and MAX_SLOTS or 12
    local incoming, incomingNames = normalizeSide(transfer.incoming, "owed", maximum)
    if not incoming then return nil, incomingNames end
    local outgoing, outgoingNames = normalizeSide(transfer.outgoing, "owe", maximum)
    if not outgoing then return nil, outgoingNames end
    if medium=="mail_sent" and #incoming>0 or medium=="mail_received" and #outgoing>0
        or medium~="trade" and transfer.service then return nil,"Mail transfer direction is invalid." end
    local summary
    summary, problem = Summary.Build(db, overview, transfer.peer)
    if not summary then return nil, problem end
    local personal = {owed={}, owe={}}
    for _, entry in ipairs(db.entries) do
        if Summary.NameKey(entry.player) == peerKey and entry.kind ~= "favor" then
            local status = L.Status(entry)
            if status == "outstanding" or status == "partial" then
                local key, id = itemIdentity(entry.label)
                personal[entry.direction][#personal[entry.direction]+1] = {
                    source="personal", entryID=entry.id, balance=L.Balance(entry), label=entry.label,
                    kind=entry.kind, itemKey=key, itemID=id,
                }
            end
        end
    end
    local shared = {owed={}, owe={}}
    local links=Summary.LinkedEntries(db,overview)
    if overview ~= nil and not summary.sharedError then
        for _, offer in ipairs(overview.offers) do
            local terms = Codec.ParseTerms(offer.terms)
            local balance = overview.balances[offer.offerId]
            if Codec.IsObligation(terms) and offer.state == "COMMITTED"
                and balance and balance.confirmed and balance.remainingCopper > 0 then
                local peer = offer.role == "proposer" and terms.recipient or terms.proposer
                if Summary.NameKey(peer) == peerKey then
                    local direction = terms.creditor == overview.localName and "owed" or "owe"
                    local asset=Codec.Asset(terms)
                    shared[direction][#shared[direction]+1] = {source="shared", offerID=offer.offerId,
                        balance=balance.remainingCopper,label=asset.label,kind=asset.kind,
                        itemKey=asset.itemKey,itemID=asset.itemID,linkedEntryID=links[offer.offerId]}
                end
            end
        end
    end
    local plan = {peer=transfer.peer, actions={}, pending={}, unmatched={}}
    local mixed = #incoming > 0 and #outgoing > 0
    local function process(rows, names)
        for _, row in ipairs(rows) do
            local candidates, near, ambiguousName, personalCount, sharedCount = {}, {}, false, 0, 0
            for _, entry in ipairs(personal[row.direction]) do
                local match = row.asset == "money" and entry.kind == "money"
                if row.asset == "item" and entry.kind == "item" then
                    if entry.itemKey then
                        match = equivalentItems(entry.itemKey,row.itemKey)
                        if not match and entry.itemID == row.itemID then near[#near+1] = entry end
                    elseif not entry.label:find("|", 1, true) and row.names[entry.label] then
                        match = true
                        if names[entry.label] ~= 1 then ambiguousName = true end
                    end
                end
                if match then candidates[#candidates+1] = entry; personalCount = personalCount + 1 end
            end
            for _,entry in ipairs(shared[row.direction]) do
                local match=row.asset==entry.kind and (row.asset=="money" or equivalentItems(row.itemKey,entry.itemKey))
                local nearMatch=row.asset=="item" and entry.kind=="item" and row.itemID==entry.itemID and not match
                local linked=false
                if match and entry.linkedEntryID then
                    for _,candidate in ipairs(candidates) do
                        if candidate.source=="personal" and candidate.entryID==entry.linkedEntryID then linked=true end
                    end
                end
                if match and not linked then
                    candidates[#candidates+1]=entry; sharedCount=sharedCount+1
                elseif nearMatch then near[#near+1]=entry end
            end
            -- An item with the same ID but a different populated payload needs
            -- review even if a second, generic note would otherwise match.
            for _, entry in ipairs(near) do candidates[#candidates+1] = entry end
            table.sort(candidates, candidateOrder)
            local reason
            local unknownShared = summary.sharedError
            local relevant = #candidates > 0 or unknownShared
            -- An ordinary purchase, barter, or enchant fee is quiet activity
            -- when it has no relation to an existing IOU. Review only protects
            -- balances that could actually be affected by this transfer.
            if transfer.service and relevant then reason = "trade_service"
            elseif mixed and relevant then reason = "mixed_trade"
            elseif unknownShared then reason = "shared_unavailable"
            elseif #near > 0 then reason = "item_identity"
            elseif ambiguousName then reason = "item_ambiguous"
            elseif personalCount > 0 and sharedCount > 0 then reason = "source_conflict"
            elseif sharedCount > 0 then reason = "shared_confirmation"
            elseif personalCount > 1 then reason = "multiple_ious"
            end
            if reason then
                local pending = asset(row)
                pending.reason, pending.candidates = reason, candidates
                plan.pending[#plan.pending+1] = pending
            elseif personalCount == 1 then
                local entry = candidates[1]
                local amount = math.min(row.amount, entry.balance)
                local action = asset(row, amount)
                action.entryID, action.expectedBalance = entry.entryID, entry.balance
                action.label = entry.label
                plan.actions[#plan.actions+1] = action
                if row.amount > amount then plan.unmatched[#plan.unmatched+1] = asset(row, row.amount - amount) end
            else
                plan.unmatched[#plan.unmatched+1] = asset(row)
            end
        end
    end
    process(incoming, incomingNames)
    process(outgoing, outgoingNames)
    table.sort(plan.actions, function(a, b) return a.entryID < b.entryID end)
    return plan
end

function Matching.Plan(db, overview, transfer)
    local ok, result, problem = pcall(makePlan, db, overview, transfer)
    if not ok then return nil, "Trade contents could not be matched safely." end
    return result, problem
end

function Matching.ItemKey(link)
    local ok,key,id=pcall(itemIdentity,link)
    if ok then return key,id end
end
