local _, IOU = ...
local Summary = {}
IOU.PlayerSummary = Summary

-- A read-only projection for player tooltips and trade reminders. Personal
-- notes and mutually acknowledged agreements stay separate. Explicit, verified
-- links identify one debt across both sources; its personal balance is primary.
local MAX_NAME, MAX_SHARED, MAX_SAFE = 96, (IOU.Shared and IOU.Shared.MAX_OFFERS or 32)+16, 9007199254740991
local states = {OFFER_OPEN=true, OFFER_RECEIVED=true, ACCEPT_PENDING=true,
    DECLINE_PENDING=true, COMMITTED=true, DECLINED=true, WITHDRAWN=true, PAUSED=true}

local function public(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function plain(value)
    return public(value) and type(value) == "table" and getmetatable(value) == nil
end
local function integer(value, maximum)
    return public(value) and type(value) == "number" and value >= 0
        and value <= maximum and value == math.floor(value)
end
local function text(value, maximum)
    return public(value) and type(value) == "string" and #value <= maximum
end
local function name(value)
    if not text(value, MAX_NAME) then return nil end
    if value:find("[%z\001-\031\127|]") then return nil end
    -- Fold only ASCII spaces and letters. Never infer a surname, remove
    -- a realm suffix, replace hyphens, or use a partial-name match.
    value = value:gsub(" +", " "):match("^ *(.-) *$")
    if value == "" then return nil end
    local key = value:gsub("[A-Z]", function(letter) return string.char(letter:byte() + 32) end)
    return key, value
end

function Summary.NameKey(value)
    local ok, key = pcall(name, value)
    if ok and key then return key end
    return nil, "Use the player's complete, plain name."
end

local function direction()
    return {money=0, items={}, favors={}}
end
local function source()
    return {owed=direction(), owe=direction()}
end
local function add(total, amount)
    if not integer(amount, MAX_SAFE) or total > MAX_SAFE - amount then
        return nil, "The player summary amount is outside the safe range."
    end
    return total + amount
end
local function labels(rows)
    table.sort(rows, function(a,b)
        if a.label~=b.label then return a.label<b.label end
        return (a.itemKey or "")<(b.itemKey or "")
    end)
end

local function personal(db, key)
    local ledger = IOU.Ledger
    if type(ledger) ~= "table" or type(ledger.Validate) ~= "function"
        or type(ledger.Status) ~= "function" or type(ledger.Balance) ~= "function" then
        return nil, "The personal ledger is unavailable."
    end
    local valid, err = ledger.Validate(db)
    if not valid then return nil, err end
    local result, count = source(), 0
    local grouped = {owed={items={}, favors={}}, owe={items={}, favors={}}}
    for _, entry in ipairs(db.entries) do
        if Summary.NameKey(entry.player) == key then
            local status = ledger.Status(entry)
            if status == "outstanding" or status == "partial" then
                local balance, problem = ledger.Balance(entry)
                if not integer(balance, ledger.MAX_AMOUNT) or balance == 0 then
                    return nil, problem or "The personal balance is unavailable."
                end
                local block = result[entry.direction]
                if entry.kind == "money" then
                    block.money, problem = add(block.money, balance)
                    if not block.money then return nil, problem end
                else
                    if not text(entry.label, ledger.MAX_LABEL) then return nil, "The item description is unavailable." end
                    local kind = entry.kind == "item" and "items" or "favors"
                    local row = grouped[entry.direction][kind][entry.label]
                    if not row then
                        -- Keep the complete literal label as the identity.
                        -- Similar item links may have different variants.
                        row = {label=entry.label, quantity=0}
                        grouped[entry.direction][kind][entry.label] = row
                        block[kind][#block[kind]+1] = row
                    end
                    row.quantity, problem = add(row.quantity, balance)
                    if not row.quantity then return nil, problem end
                end
                count = count + 1
            end
        end
    end
    for _, block in pairs(result) do labels(block.items); labels(block.favors) end
    return result, count
end

-- A link is a one-to-one claim, never a guess based on matching balances.
-- Treat malformed or stale maps as absent so they cannot hide Shared debt.
local function linkedEntries(db,overview)
    local result={}
    if not plain(overview) or overview.links==nil then return result end
    if not plain(overview.links) or (overview.linkBases~=nil and not plain(overview.linkBases)) then return result end
    local L,C=IOU.Ledger,IOU.SharedCodec
    if not L or not C or not L.Validate(db) then return result end
    local entries,offers,claimed,count={},{},{},0
    for _,entry in ipairs(db.entries) do entries[entry.id]=entry end
    if not plain(overview.offers) then return result end
    local offerCount=0
    for index in pairs(overview.offers) do
        if not integer(index,MAX_SHARED) or index<1 then return result end
        offerCount=offerCount+1
    end
    if offerCount~=#overview.offers or offerCount>MAX_SHARED then return result end
    for _,offer in ipairs(overview.offers) do
        if not plain(offer) or not text(offer.offerId,64) or offers[offer.offerId] then return {} end
        offers[offer.offerId]=offer
    end
    for id,offerId in pairs(overview.links) do
        if not integer(id,L.MAX_ENTRIES) or id<1 or not text(offerId,64)
            or not offerId:match("^[A-Za-z0-9_-]+$") or claimed[offerId] then return {} end
        claimed[offerId]=true; count=count+1
        if count>L.MAX_ENTRIES then return {} end
    end
    for id,base in pairs(overview.linkBases or {}) do
        if not public(id) or overview.links[id]==nil or not integer(base,L.MAX_AMOUNT) then return {} end
    end
    for id,offerId in pairs(overview.links) do
        local entry,offer=entries[id],offers[offerId]
        local terms=offer and C.ParseTerms(offer.terms)
        local base=(overview.linkBases or {})[id] or 0
        if entry and terms and C.IsObligation(terms) and L.Status(entry)~="cancelled"
            and entry.amount-base==terms.amountCopper and L.Balance(entry)<=terms.amountCopper then
            local role=terms.proposer==overview.localName and "proposer"
                or terms.recipient==overview.localName and "recipient" or nil
            local peer=role=="proposer" and terms.recipient or terms.proposer
            local direction=terms.creditor==overview.localName and "owed" or "owe"
            local asset=C.Asset(terms)
            local sameAsset=asset and (asset.kind=="money" and entry.kind=="money"
                or asset.kind=="item" and entry.kind=="item" and C.CanonicalItem(entry.label)==asset.itemKey)
            if role and offer.role==role and Summary.NameKey(entry.player)==Summary.NameKey(peer)
                and entry.direction==direction and sameAsset then result[offerId]=id end
        end
    end
    return result
end
function Summary.LinkedEntries(db,overview)
    local ok,result=pcall(linkedEntries,db,overview)
    return ok and result or {}
end

local function shared(overview, key, links)
    if not plain(overview) or not plain(overview.offers) or not plain(overview.balances)
        or not Summary.NameKey(overview.localName) then
        return nil, "Shared balances are unavailable."
    end
    local codec = IOU.SharedCodec
    if type(codec) ~= "table" or type(codec.ParseTerms) ~= "function" then
        return nil, "The shared agreement codec is unavailable."
    end
    local count = 0
    for index in pairs(overview.offers) do
        if not integer(index, MAX_SHARED) or index < 1 then return nil, "The shared offer list is invalid." end
        count = count + 1
    end
    if count > MAX_SHARED or count ~= #overview.offers then return nil, "The shared offer list is incomplete." end
    local result, matches, seen = source(), 0, {}
    local grouped={owed={},owe={}}
    for _, offer in ipairs(overview.offers) do
        if not plain(offer) or not text(offer.offerId, 64) or offer.offerId == ""
            or seen[offer.offerId] or not public(offer.state) or not states[offer.state]
            or not public(offer.role) or not public(offer.delivery) then
            return nil, "The shared offer list contains an invalid record."
        end
        seen[offer.offerId] = true
        if not text(offer.terms, codec.MAX_BYTES or 4096) then return nil, "Shared terms are unavailable." end
        local terms, problem = codec.ParseTerms(offer.terms)
        if not terms then return nil, problem end
        local role = terms.proposer == overview.localName and "proposer"
            or (terms.recipient == overview.localName and "recipient" or nil)
        if not role or offer.role ~= role then return nil, "Shared records belong to another character." end
        if codec.IsObligation(terms) and offer.state == "COMMITTED" then
            local balance = overview.balances[offer.offerId]
            local acknowledged = role == "recipient" or offer.delivery == "PEER_RECEIPT_OBSERVED"
            if not plain(balance) or not public(balance.confirmed) or type(balance.confirmed) ~= "boolean"
                or balance.confirmed ~= acknowledged or not integer(balance.remainingCopper, terms.amountCopper) then
                return nil, "The confirmed shared balance is unavailable."
            end
            local peer = role == "proposer" and terms.recipient or terms.proposer
            if acknowledged and balance.remainingCopper > 0 and Summary.NameKey(peer) == key and not links[offer.offerId] then
                local direction=terms.creditor==overview.localName and "owed" or "owe"
                local block=result[direction]
                local asset=codec.Asset(terms)
                if asset.kind=="money" then
                    block.money,problem=add(block.money,balance.remainingCopper)
                    if not block.money then return nil,problem end
                else
                    local row=grouped[direction][asset.itemKey]
                    if not row then
                        row={label=asset.label,quantity=0,itemKey=asset.itemKey,itemID=asset.itemID}
                        grouped[direction][asset.itemKey]=row
                        block.items[#block.items+1]=row
                    end
                    if asset.label<row.label then row.label=asset.label end
                    row.quantity,problem=add(row.quantity,balance.remainingCopper)
                    if not row.quantity then return nil,problem end
                end
                matches=matches+1
            end
        end
    end
    labels(result.owed.items); labels(result.owe.items)
    return result, matches
end

function Summary.Build(db, overview, exactPlayerName)
    local ok, key, display = pcall(name, exactPlayerName)
    if not ok or not key then return nil, "Use the player's complete, plain name." end
    local valid, personalResult, count = pcall(personal, db, key)
    if not valid then return nil, "The personal ledger could not be read safely." end
    if not personalResult then return nil, count end
    local result = {player=display, personal=personalResult, shared=source(), count=count}
    if overview ~= nil then
        local safe, sharedResult, sharedCount = pcall(shared, overview, key, Summary.LinkedEntries(db,overview))
        if safe and sharedResult then
            result.shared = sharedResult
            result.count = result.count + sharedCount
        else
            result.sharedError = safe and sharedCount or "Shared balances could not be read safely."
        end
    end
    return result
end
