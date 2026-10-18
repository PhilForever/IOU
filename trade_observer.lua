local _, IOU = ...
local Observer = {}
IOU.TradeObserver = Observer

-- TradeFrame's NPC unit is the counterpart. Slots 1..6 transfer ownership;
-- slot 7 is an enchant target and must never become an item repayment.
-- An accepted snapshot is only submitted after the client's typed completion
-- message. Neither acceptance, window closure nor inventory changes prove it.
local initialized, frame, active, closed
local quarantineUntil = 0
local status = "Waiting for a completed trade."
local submitted, ignored = 0, 0
local acceptedSnapshots, unreadableSnapshots, closingSnapshots = 0, 0, 0
local GRACE, MAX_INTEGER = 4, 9007199254740991
local EVENTS = {"TRADE_SHOW", "TRADE_UPDATE", "TRADE_MONEY_CHANGED",
    "PLAYER_TRADE_MONEY", "TRADE_CURRENCY_CHANGED", "PLAYER_TRADE_CURRENCY",
    "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE",
    "TRADE_CLOSED", "TRADE_REQUEST_CANCEL", "UI_INFO_MESSAGE", "UI_ERROR_MESSAGE",
    "PLAYER_LOGOUT"}

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function integer(value, maximum)
    return plain(value) and type(value) == "number" and value >= 0
        and value <= (maximum or MAX_INTEGER) and value == math.floor(value)
end
local function clock()
    if type(GetTime) ~= "function" then return nil end
    local ok, value = pcall(GetTime)
    if ok and plain(value) and type(value) == "number" and value >= 0
        and value < math.huge then return value end
end
local function peer()
    local context = IOU.PlayerContext
    if type(context) ~= "table" or type(context.UnitName) ~= "function" then return nil end
    local ok, value = pcall(context.UnitName, "NPC")
    if not ok or not plain(value) or type(value) ~= "string" then return nil end
    local summary = IOU.PlayerSummary
    if type(summary) ~= "table" or type(summary.NameKey) ~= "function" then return nil end
    local safe, key = pcall(summary.NameKey, value)
    if safe and plain(key) and type(key) == "string" then return value, key end
end
local function expire(now)
    if closed and now >= closed.expires then
        closed = nil
        status = "Trade completion was not confirmed."
    end
end
local function invalidate(message)
    if active then active.snapshot = nil end
    closed = nil
    status = message
end
local function retainClosingSnapshot()
    -- The native TRADE_CLOSED handler hides TradeFrame before later event
    -- listeners run. Its OnHide clears the money input and calls CloseTrade;
    -- those synchronous teardown notifications can precede our TRADE_CLOSED.
    -- Keep only a previously accepted immutable snapshot in that case. A
    -- typed completion is still required, and explicit cancellation clears it.
    if not active or not active.snapshot or not TradeFrame
        or type(TradeFrame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(TradeFrame.IsShown, TradeFrame)
    if not ok or not plain(shown) or shown ~= false then return false end
    if not active.closing then
        closingSnapshots = math.min(closingSnapshots+1, 9999)
        active.closing = true
    end
    return true
end
local function money(fn)
    if type(fn) ~= "function" then return nil end
    local ok, amount = pcall(fn)
    if ok and integer(amount) then return amount end
end
local function readItem(info, linkAPI, slot, target)
    if type(info) ~= "function" or type(linkAPI) ~= "function" then return nil, false end
    local ok, name, _, quantity, _, _, _, seventh, eighth = pcall(info, slot)
    local safe, link = pcall(linkAPI, slot)
    local itemID
    if target then itemID=seventh else itemID=eighth end
    if not ok or not safe or not plain(name) or not plain(quantity)
        or not plain(itemID) or not plain(link) then return nil, false end
    if name == nil and link == nil and (quantity == nil or quantity == 0)
        and (itemID == nil or itemID == 0) then return nil, true end
    if type(name) ~= "string" or name == "" or #name > 200
        or name:find("[%z\001-\031\127|]") or not integer(quantity, 1000000000) or quantity < 1
        or not integer(itemID, 2147483647) or itemID < 1
        or type(link) ~= "string" or #link > 512 or link:find("[%z\001-\031\127]")
        or not link:find("|Hitem:",1,true) then
        return nil, false
    end
    -- Use the same native-link parser as the ledger/matcher. Forever uses
    -- named quality colors (|cnIQ1:) as well as legacy hexadecimal colors.
    local codec = IOU.SharedCodec
    if type(codec) ~= "table" or type(codec.CanonicalItem) ~= "function" then return nil, false end
    local valid, key, linkedID = pcall(codec.CanonicalItem, link)
    if not valid or not key or linkedID ~= itemID then return nil, false end
    return {itemID=itemID, link=link, name=name, quantity=quantity}, true
end
local function serviceSlot(info, linkAPI, target)
    if type(info) ~= "function" or type(linkAPI) ~= "function" then return nil end
    local ok, name, _, _, _, fifth, sixth = pcall(info, 7)
    local safe, link = pcall(linkAPI, 7)
    local enchantment
    if target then enchantment=sixth else enchantment=fifth end
    if not ok or not safe or not plain(name) or not plain(link) or not plain(enchantment) then return nil end
    if name ~= nil and type(name) ~= "string" then return nil end
    if link ~= nil and type(link) ~= "string" then return nil end
    if enchantment ~= nil and type(enchantment) ~= "string" then return nil end
    return (name ~= nil and name ~= "") or (link ~= nil and link ~= "")
        or (enchantment ~= nil and enchantment ~= "")
end
local function snapshot(session)
    local name, key = peer()
    if not name or key ~= session.peerKey then return nil end
    local outgoing, incoming = money(GetPlayerTradeMoney), money(GetTargetTradeMoney)
    if outgoing == nil or incoming == nil then return nil end
    local playerService = serviceSlot(GetTradePlayerItemInfo, GetTradePlayerItemLink, false)
    local targetService = serviceSlot(GetTradeTargetItemInfo, GetTradeTargetItemLink, true)
    if playerService == nil or targetService == nil then return nil end
    local value = {id=session.id, peer=session.peer, service=playerService or targetService,
        outgoing={money=outgoing, items={}}, incoming={money=incoming, items={}}}
    for slot=1,6 do
        local item, ok = readItem(GetTradePlayerItemInfo, GetTradePlayerItemLink, slot, false)
        if not ok then return nil end
        if item then value.outgoing.items[#value.outgoing.items+1] = item end
        item, ok = readItem(GetTradeTargetItemInfo, GetTradeTargetItemLink, slot, true)
        if not ok then return nil end
        if item then value.incoming.items[#value.incoming.items+1] = item end
    end
    return value
end
local function accepted(value)
    return plain(value) and (value == 1 or value == true)
end
local function completeMarker(messageType)
    if not integer(messageType, 2147483647) or messageType < 1 then return false end
    if type(GetGameMessageInfo) == "function" then
        local ok, key = pcall(GetGameMessageInfo, messageType)
        if ok and plain(key) and type(key) == "string" then
            return key == "ERR_TRADE_COMPLETE"
        end
    end
    -- Older clients may expose the same typed numeric constant without the
    -- lookup API. Localized display text is deliberately not parsed.
    return plain(LE_GAME_ERR_TRADE_COMPLETE) and type(LE_GAME_ERR_TRADE_COMPLETE) == "number"
        and messageType == LE_GAME_ERR_TRADE_COMPLETE
end
local function notifySuccess(now)
    local session = active or closed
    if not session or not session.snapshot or now < quarantineUntil then
        if session then invalidate("Trade could not be matched safely.") end
        return
    end
    if active then
        local _, key = peer()
        if key and key ~= active.peerKey then
            invalidate("Trade partner changed; no repayment recorded.")
            return
        end
    end
    -- Clear first: repeated completion events and callback re-entry are inert.
    local value = session.snapshot
    active, closed = nil, nil
    local service = IOU.TradeService
    if type(service) ~= "table" or type(service.Record) ~= "function" then
        status = "Trade recorder is unavailable."
        return
    end
    local ok, result, reason = pcall(service.Record, value)
    if ok and result then
        submitted = math.min(submitted+1, 9999)
        status = "Completed trade recorded."
    else
        ignored = math.min(ignored+1, 9999)
        status = "Completed trade could not be recorded."
        if ok and plain(reason) and type(reason) == "string" and #reason <= 240
            and not reason:find("[%z\001-\031\127|]") then status = status.." "..reason end
    end
end
local function onEvent(_, event, arg1, arg2)
    if not plain(event) or type(event) ~= "string" then return end
    local now = clock()
    if not now then invalidate("Trade observation needs a readable client clock."); active=nil; return end
    expire(now)
    if event == "TRADE_SHOW" then
        -- A delayed completion from the preceding trade must never be applied
        -- to a rapidly opened replacement trade.
        if closed then quarantineUntil = math.max(quarantineUntil, closed.expires) end
        active, closed = nil, nil
        local name, key = peer()
        local service = IOU.TradeService
        if not name or type(service) ~= "table" or type(service.NewSessionID) ~= "function" then
            status = "Trade partner or recorder is unavailable."
            return
        end
        local ok, id = pcall(service.NewSessionID)
        if not ok or not plain(id) or type(id) ~= "string" or id == "" or #id > 96
            or id:find("[%z\001-\031\127|]") then
            status = "Trade could not be reserved."
            return
        end
        active = {peer=name, peerKey=key, id=id}
        status = "Watching this trade."
    elseif event == "TRADE_ACCEPT_UPDATE" then
        if not active then return end
        if retainClosingSnapshot() then return end
        active.snapshot = nil
        active.closing = nil
        if accepted(arg1) and accepted(arg2) then
            active.snapshot = snapshot(active)
            if active.snapshot then acceptedSnapshots=math.min(acceptedSnapshots+1,9999)
            else unreadableSnapshots=math.min(unreadableSnapshots+1,9999) end
            status = active.snapshot and "Waiting for trade completion." or "Trade contents are unavailable."
        end
    elseif event == "TRADE_UPDATE" then
        if active then
            if retainClosingSnapshot() then return end
            local _, key = peer()
            if not key or key ~= active.peerKey then
                invalidate("Trade partner changed; no repayment recorded.")
                active=nil
            end
        end
    elseif event == "TRADE_CLOSED" then
        if active then
            if active.snapshot then
                active.expires = now+GRACE
                closed = active
                status = "Waiting briefly for trade completion."
            else
                status = "Trade closed without a confirmed repayment."
            end
            active=nil
        end
    elseif event == "UI_INFO_MESSAGE" then
        if completeMarker(arg1) then notifySuccess(now) end
    elseif event == "UI_ERROR_MESSAGE" then
        -- Any client error during a final accepted trade makes that snapshot
        -- uncertain. A subsequent fresh acceptance can establish a new one.
        if (active and active.snapshot) or closed then invalidate("Trade interrupted; no repayment recorded.") end
    elseif event == "TRADE_REQUEST_CANCEL" or event == "PLAYER_LOGOUT" then
        active, closed = nil, nil
        status = "Trade cancelled; no repayment recorded."
    else
        -- Money, item and currency changes reset the accepted offer. A new
        -- both-accepted event is required before its contents can be recorded.
        -- After closure these APIs may be cleared by the native TradeFrame;
        -- retain its immutable final snapshot during the completion grace.
        if active and not retainClosingSnapshot() then invalidate("Trade changed; waiting for acceptance.") end
    end
end

function Observer.Initialize()
    if initialized then return true end
    if type(CreateFrame) ~= "function" then return nil, "Trade events are unavailable." end
    local ok, value = pcall(CreateFrame, "Frame")
    if not ok or not value then return nil, "Trade events are unavailable." end
    frame=value
    local success = pcall(function()
        for _, event in ipairs(EVENTS) do frame:RegisterEvent(event) end
        frame:SetScript("OnEvent", onEvent)
    end)
    if not success then
        if type(frame.UnregisterAllEvents) == "function" then pcall(frame.UnregisterAllEvents, frame) end
        status = "Trade events are unavailable."
        return nil, status
    end
    initialized=true
    return true
end
function Observer.Report()
    local now = clock()
    if now then expire(now) end
    return "IOU trade observer\nStatus: "..status
        .."\nCompleted trades submitted: "..submitted.."; recorder failures: "..ignored
        .."\nAccepted snapshots: "..acceptedSnapshots.."; unreadable contents: "..unreadableSnapshots
        .."; native closing snapshots retained: "..closingSnapshots
        .."\nCompletion rule: typed ERR_TRADE_COMPLETE and an unchanged accepted snapshot."
        .."\nRead-only capture; enchant slot excluded."
end
