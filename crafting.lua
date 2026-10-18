local _, IOU = ...
local C = {}
IOU.Crafting = C
C.MAX_MATERIALS = 12
local MAX = IOU.Ledger.MAX_AMOUNT

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function whole(value, limit)
    return plain(value) and type(value) == "number" and value == value
        and value > 0 and value <= (limit or MAX) and value % 1 == 0
end
local function itemKey(link)
    if not plain(link) or type(link) ~= "string" or #link > 512 then return end
    if IOU.TradeMatching and type(IOU.TradeMatching.ItemKey) == "function" then
        return IOU.TradeMatching.ItemKey(link)
    end
end
local function display(link)
    return link:match("|Hitem:[^|]+|h(%[[^|]+%])|h") or link
end

-- Item capacity is read from the native item cache, never inferred from the
-- number currently in a bag slot. Uncached items continue to accept units.
function C.StackSize(link)
    if not itemKey(link) then return nil, "Choose an item first." end
    local get = C_Item and C_Item.GetItemInfo or GetItemInfo
    if type(get) ~= "function" then return nil, "Stack size is unavailable. Use units." end
    local values = {pcall(get, link)}
    if values[1] and whole(values[9]) then return values[9] end
    return nil, "Stack size is unavailable. Use units."
end

function C.Quantity(link, count, stacks)
    if not whole(count) then return nil, "Enter a positive whole quantity." end
    if not stacks then return count end
    local size, err = C.StackSize(link)
    if not size then return nil, err end
    if count > math.floor(MAX / size) then return nil, "That quantity is too large." end
    return count * size
end

function C.BagItems()
    local api = C_Container
    if type(api) ~= "table" or type(api.GetContainerNumSlots) ~= "function"
        or type(api.GetContainerItemInfo) ~= "function" then
        return {}, "Bag items are unavailable. Shift-click an item instead."
    end
    local items, byKey, readError = {}, {}, false
    for bag = 0, 4 do
        local ok, slots = pcall(api.GetContainerNumSlots, bag)
        if ok and plain(slots) and type(slots) == "number" and slots >= 0 and slots <= 100 and slots % 1 == 0 then
            for slot = 1, slots do
                local good, info = pcall(api.GetContainerItemInfo, bag, slot)
                if good and plain(info) and type(info) == "table" then
                    local key, id = itemKey(info.hyperlink)
                    if key and whole(info.stackCount) and whole(info.itemID) and id == info.itemID then
                        local current = byKey[key]
                        if current then
                            if current.quantity <= MAX - info.stackCount then current.quantity = current.quantity + info.stackCount end
                        else
                            current = {link=info.hyperlink, label=info.hyperlink, name=display(info.hyperlink),
                                itemID=id, quantity=info.stackCount, bag=bag, slot=slot}
                            byKey[key], items[#items + 1] = current, current
                        end
                    else
                        readError = true
                    end
                elseif not good or not plain(info) or info ~= nil then
                    readError = true
                end
            end
        else
            readError = true
        end
    end
    table.sort(items, function(a,b)
        if a.name ~= b.name then return a.name < b.name end
        return a.link < b.link
    end)
    return items, readError and "Some bag items could not be read. Shift-click an item instead." or nil
end

-- Stage a small material bundle without touching the ledger. Repeated links
-- combine; variants remain separate so automatic repayment retains identity.
function C.Stage(bundle, label, amount)
    if type(bundle) ~= "table" or #bundle > C.MAX_MATERIALS then return nil, "Too many materials." end
    if not plain(label) or type(label) ~= "string" or #label > 512
        or label:find("[%z\1-\31]") or not label:find("%S") or not whole(amount) then
        return nil, "Choose an item and a positive whole quantity."
    end
    local result, key = {}, itemKey(label) or label
    local combined = false
    for index, row in ipairs(bundle) do
        if type(row) ~= "table" or not plain(row.label) or type(row.label) ~= "string" or not whole(row.amount) then
            return nil, "That material list is unavailable."
        end
        local rowKey = itemKey(row.label) or row.label
        local value = row.amount
        if rowKey == key then
            if combined or value > MAX - amount then return nil, "That quantity is too large." end
            value, combined = value + amount, true
        end
        result[index] = {label=row.label, amount=value}
    end
    if not combined then
        if #result >= C.MAX_MATERIALS then return nil, "A bundle can contain up to 12 materials." end
        result[#result + 1] = {label=label, amount=amount}
    end
    return result
end
