local _, IOU = ...
local Context = {}
IOU.PlayerContext = Context

-- Context reminders are read-only projections. Opening or closing a trade is
-- never evidence that somebody paid an IOU.
local initialized, events, tradeActive, tradePanel, tradeName
local summaries, summaryCount, overview, overviewRead = {}, 0, nil, false
local decorated = setmetatable({}, {__mode="k"})
local tooltipHooks = setmetatable({}, {__mode="k"})
local GOLD = {0.88,0.73,0.42}

local function plain(value)
    if type(issecretvalue) ~= "function" then return true end
    local ok, secret = pcall(issecretvalue, value)
    return ok and not secret
end
local function settings()
    if type(IOU.GetSettings) ~= "function" then return nil end
    local ok, value = pcall(IOU.GetSettings)
    return ok and plain(value) and type(value)=="table" and value or nil
end
local function enabled(option)
    local value=settings()
    if not value then return false end
    local setting=value[option]
    return plain(setting) and (setting==nil or setting==true)
end
local function canonical(value)
    if not plain(value) or type(value)~="string" then return nil end
    local summary=IOU.PlayerSummary
    if not summary or not summary.NameKey(value) then return nil end
    return value:gsub(" +"," "):match("^ *(.-) *$")
end

function Context.UnitName(unit)
    if not plain(unit) or type(unit)~="string" or #unit>64
        or not unit:match("^[A-Za-z][A-Za-z0-9]*$") or type(UnitIsPlayer)~="function" then return nil end
    local ok, player=pcall(UnitIsPlayer,unit)
    if not ok or not plain(player) or player~=true then return nil end
    if type(NameUtil)=="table" and type(NameUtil.GetUnmodifiedUnitFullName)=="function" then
        local safe, value=pcall(NameUtil.GetUnmodifiedUnitFullName,unit)
        if safe then
            local name=canonical(value)
            if name then return name end
        end
    end
    if type(UnitNameUnmodified)=="function" then
        local safe, first, surname=pcall(UnitNameUnmodified,unit)
        if safe and plain(first) and plain(surname) and type(first)=="string" and first~="" then
            if surname==nil or surname=="" then return canonical(first) end
            local separator=Constants and Constants.CharacterNameSeparatorConsts
                and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR
            if type(surname)=="string" and plain(separator) and type(separator)=="string" then
                return canonical(first..separator..surname)
            end
        end
    end
end

function Context.GetSummary(name)
    name=canonical(name)
    if not name or type(IOU.GetLedger)~="function" then return nil end
    local key=IOU.PlayerSummary.NameKey(name)
    if summaries[key] then return summaries[key] end
    if not overviewRead then
        overviewRead=true
        local service=IOU.SharedService
        if type(service)=="table" and type(service.GetOverview)=="function" then
            local ok, value=pcall(service.GetOverview)
            if ok then overview=value end
        end
    end
    local ok, ledger=pcall(IOU.GetLedger)
    if not ok or not ledger then return nil end
    local safe, value=pcall(IOU.PlayerSummary.Build,ledger,overview,name)
    if not safe or not value then return nil end
    -- Only names actually inspected by the player enter this bounded cache.
    if summaryCount>=64 then summaries,summaryCount={},0 end
    summaries[key],summaryCount=value,summaryCount+1
    return value
end

local function literal(value)
    local text=value:gsub("|Hitem:[^|]+|h(%[[^|]+%])|h", "%1")
    -- Native links can use a named item-quality color (|cnIQ1:) rather
    -- than an eight-digit hex color. Strip both presentation wrappers;
    -- saved labels and the item's identity remain untouched.
    text=text:gsub("|cn[%a_][%w_]*:", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text=text:gsub("[%z\001-\031\127]", " "):gsub("%s+", " ")
    local limit=64
    if #text>limit then
        while limit>0 and (text:byte(limit+1) or 0)>=128 and (text:byte(limit+1) or 0)<=191 do limit=limit-1 end
        text=text:sub(1,limit).."..."
    end
    return (text:gsub("|","||"))
end
local function money(amount)
    local gold=math.floor(amount/10000)
    local silver=math.floor(amount/100)%100
    local copper=amount%100
    local parts={}
    if gold>0 then parts[#parts+1]=gold.."g" end
    if silver>0 then parts[#parts+1]=silver.."s" end
    if copper>0 then parts[#parts+1]=copper.."c" end
    return table.concat(parts," ")
end
local function debt(block)
    local parts={}
    if block.money>0 then parts[#parts+1]=money(block.money) end
    local shown,total=0,#block.items+#block.favors
    for _, rows in ipairs({block.items,block.favors}) do
        for _, row in ipairs(rows) do
            if shown<2 then
                parts[#parts+1]=tostring(row.quantity).." x "..literal(row.label)
                shown=shown+1
            end
        end
    end
    if total>shown then parts[#parts+1]="+"..(total-shown).." more" end
    return table.concat(parts,", ")
end
local function lines(summary)
    local out={}
    if not summary then return out end
    for _, source in ipairs({{summary.personal,"Your notes"},{summary.shared,"Confirmed"}}) do
        local owed,owe=debt(source[1].owed),debt(source[1].owe)
        if owed~="" then out[#out+1]={source=source[2],text="Owes you "..owed} end
        if owe~="" then out[#out+1]={source=source[2],text="You owe "..owe} end
    end
    return out
end
local function usableTooltip(tooltip)
    if not plain(tooltip) or not tooltip then return false end
    if type(tooltip)~="table" and type(tooltip)~="userdata" then return false end
    if type(tooltip.IsForbidden)=="function" then
        local ok, forbidden=pcall(tooltip.IsForbidden,tooltip)
        if not ok or not plain(forbidden) or forbidden then return false end
    end
    return type(tooltip.GetUnit)=="function" and type(tooltip.AddLine)=="function"
end
local function tooltipDebt(tooltip)
    if not enabled("playerTooltips") or not usableTooltip(tooltip) or tooltip~=GameTooltip then return end
    local ok, _, unit=pcall(tooltip.GetUnit,tooltip)
    if not ok then return end
    local name=Context.UnitName(unit)
    if not name then return end
    local key=IOU.PlayerSummary.NameKey(name)
    if decorated[tooltip]==key then return end
    local rows=lines(Context.GetSummary(name))
    if #rows==0 then return end
    decorated[tooltip]=key
    local source
    for _, row in ipairs(rows) do
        if source~=row.source then
            source=row.source
            tooltip:AddLine("IOU - "..source,unpack(GOLD))
        end
        tooltip:AddLine(row.text,0.91,0.89,0.82,true)
    end
end
local function hookTooltip()
    local tooltip=GameTooltip
    if not usableTooltip(tooltip) then return end
    if not tooltipHooks[tooltip] and type(tooltip.HookScript)=="function" then
        pcall(tooltip.HookScript,tooltip,"OnTooltipCleared",function(self) decorated[self]=nil end)
        pcall(tooltip.HookScript,tooltip,"OnHide",function(self) decorated[self]=nil end)
        tooltipHooks[tooltip]=true
    end
    local processor=TooltipDataProcessor
    local unitType=Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
    if type(processor)=="table" and type(processor.AddTooltipPostCall)=="function" and unitType~=nil then
        local ok=pcall(processor.AddTooltipPostCall,unitType,tooltipDebt)
        if ok then return end
    end
    if type(tooltip.HookScript)=="function" then pcall(tooltip.HookScript,tooltip,"OnTooltipSetUnit",tooltipDebt) end
end

local function hideTrade()
    tradeName=nil
    if tradePanel then tradePanel:Hide() end
end
local function refreshTrade()
    if not tradeActive or not enabled("tradeReminders") or not TradeFrame then hideTrade();return end
    -- NPC is the native trade recipient token. The current target can be a
    -- completely different player and must never stand in for this identity.
    local name=Context.UnitName("NPC")
    local rows=name and lines(Context.GetSummary(name)) or {}
    if #rows==0 then hideTrade();return end
    if not tradePanel then
        local helpers=IOU.UI and IOU.UI.Helpers
        if not helpers then return end
        tradePanel=helpers.panel(TradeFrame,290,250,0,0)
        Context.tradeFrame=tradePanel
        tradePanel:ClearAllPoints()
        tradePanel:SetPoint("TOPLEFT",TradeFrame,"TOPRIGHT",4,-26)
        tradePanel:SetClampedToScreen(true)
        tradePanel.title=helpers.font(tradePanel,14,12,-12,266,"",GOLD)
        tradePanel.rows={}
        for index=1,4 do
            local row=helpers.font(tradePanel,12,12,-40-(index-1)*42,266,"")
            row:SetHeight(36)
            row:SetMaxLines(2)
            tradePanel.rows[index]=row
        end
        tradePanel.records=helpers.button(tradePanel,"View IOUs",124,12,-218,function()
            if tradeName and type(IOU.ShowPlayerRecords)=="function" then IOU.ShowPlayerRecords(tradeName) end
        end)
        tradePanel.add=helpers.button(tradePanel,"New IOU",124,150,-218,function()
            if tradeName and type(IOU.ShowAdd)=="function" then IOU.ShowAdd(tradeName) end
        end)
    end
    tradeName=name
    local height=84+#rows*42
    tradePanel:SetSize(290,height)
    tradePanel.records:ClearAllPoints();tradePanel.records:SetPoint("TOPLEFT",12,-height+32)
    tradePanel.add:ClearAllPoints();tradePanel.add:SetPoint("TOPLEFT",150,-height+32)
    tradePanel.title:SetText("IOU - "..literal(name))
    for index=1,4 do
        local row=rows[index]
        tradePanel.rows[index]:SetText(row and row.source..": "..row.text or "")
    end
    tradePanel:Show()
end

function Context.Invalidate(...)
    -- The Shared board may pass its already validated snapshot. Bookkeeping
    -- writes with no arguments discard the source cache completely.
    summaries,summaryCount={},0
    if select("#",...)>0 then overview,overviewRead=select(1,...),true
    else overview,overviewRead=nil,false end
    if initialized and tradeActive then refreshTrade() end
end
function Context.Initialize()
    if initialized then return end
    initialized=true
    hookTooltip()
    if type(CreateFrame)=="function" then
        events=CreateFrame("Frame")
        events:RegisterEvent("TRADE_SHOW")
        events:RegisterEvent("TRADE_UPDATE")
        events:RegisterEvent("TRADE_CLOSED")
        events:SetScript("OnEvent",function(_,event)
            if event=="TRADE_CLOSED" then tradeActive=false;hideTrade()
            else tradeActive=true;refreshTrade() end
        end)
    end
end
