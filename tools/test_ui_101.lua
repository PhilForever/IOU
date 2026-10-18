-- Regressions from native 1.60 item links and the player-facing request flow.
local support=assert(IOU_TEST_SUPPORT,"Run after test_iou.lua.")
local results={}
local function test(name,run)
    local ok,err=pcall(run); if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(text,value) assert(text:find(value,1,true),"missing "..value.." in "..text) end
local function absent(text,value) assert(not text:find(value,1,true),"unexpected "..value.." in "..text) end
local function visible(state,parent)
    local parts={}
    for _,object in ipairs(state.objects) do
        local current,shown,belongs=object,true,false
        while current do
            if not current:IsShown() then shown=false end
            if current==parent then belongs=true end
            current=current.parent
        end
        if shown and belongs and object.text~="" then parts[#parts+1]=object.text end
    end
    return table.concat(parts,"\n")
end
local function session()
    local state=support.Session({ui=true,shared=true,target="Birch Vale"})
    assert(state.api.Initialize())
    return state,state.api
end
local named="|cnIQ1:|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"
local hex="|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"

test("native named-color shift-click stores the exact item and displays only its name",function()
    local state,api=session()
    api.ShowAdd("Birch Vale")
    local form=api.UI.add
    state.click(form.kindButtons.item); form.label:SetFocus()
    assert(state.env.ChatFrameUtil.InsertLink(named))
    equal(form.label:GetText(),named); equal(state.chatCalls,0)
    form.quantity:SetText("5"); state.click(form.create)
    local saved=assert(api.GetLedger().entries[1])
    equal(saved.label,named); equal(saved.amount,5)
    equal(api.UI.rows[1].balance:GetText(),"5 x [Linen Cloth]")
    equal(api.UI.balance:GetText(),"5 x [Linen Cloth]")
    state.click(api.UI.historyToggle)
    local text=visible(state,api.UI.detailContent)
    contains(text,"5 x [Linen Cloth]"); absent(text,"cnIQ"); absent(text,"|Hitem")
    equal(assert(api.Codec.Import(assert(api.Export()))).entries[1].label,named)
end)

test("trade and tooltip reminders strip native named colors without changing records",function()
    local state,api=session()
    local item=assert(api.Add({player="Birch Vale",direction="owed",kind="item",amount=5,label=named,note=""}))
    assert(api.Add({player="Birch Vale",direction="owe",kind="money",amount=1000,label="",note=""}))
    local before=assert(api.Export())
    local names=state.env.NameUtil.GetUnmodifiedUnitFullName
    state.env.NameUtil.GetUnmodifiedUnitFullName=function(unit)
        if unit=="NPC" or unit=="mouseover" then return "Birch Vale" end
        return names(unit)
    end
    local players=state.env.UnitIsPlayer
    state.env.UnitIsPlayer=function(unit) return unit=="NPC" or unit=="mouseover" or players(unit) end
    state.env.TradeFrame=state.env.CreateFrame("Frame",nil,state.env.UIParent)
    state.env.GameTooltip.GetUnit=function() return "Birch Vale","mouseover" end
    api.PlayerContext.Initialize(); state.event("TRADE_SHOW")
    local trade=api.PlayerContext.tradeFrame
    assert(trade and trade:IsShown())
    contains(trade.rows[1]:GetText(),"Owes you 5 x [Linen Cloth]")
    contains(trade.rows[2]:GetText(),"You owe 10s")
    absent(visible(state,trade),"cnIQ"); absent(visible(state,trade),"|Hitem")
    state.env.GameTooltip.scripts.OnTooltipSetUnit(state.env.GameTooltip)
    local tooltip=table.concat(state.env.GameTooltip.lines,"\n")
    contains(tooltip,"Owes you 5 x [Linen Cloth]"); absent(tooltip,"cnIQ"); absent(tooltip,"|Hitem")
    equal(api.GetLedger().entries[item.id].label,named); equal(assert(api.Export()),before)
end)

test("hex-color item display and literal user text remain readable and safe",function()
    local state,api=session()
    assert(api.Add({player="Birch Vale",direction="owed",kind="item",amount=2,label=hex,note=""}))
    api.Toggle(); equal(api.UI.balance:GetText(),"2 x [Linen Cloth]")
    local favor=assert(api.Add({player="Birch Vale",direction="owed",kind="favor",amount=1,label="Craft |Tbad|t",note=""}))
    api.UI.selected=favor.id; api.Refresh(); contains(api.UI.balance:GetText(),"Craft ||Tbad||t")
    equal(api.GetLedger().entries[1].label,hex)
end)

test("request controls distinguish sending from pending and confirmed IOUs",function()
    local state,api=session()
    local link,sent,opened,selected
    api.Sharing={GetLink=function() return link end,Share=function(id) sent=id; return {offerId="request-1"} end}
    local item=assert(api.Add({player="Birch Vale",direction="owed",kind="money",amount=1000,label="",note=""}))
    api.Toggle(); equal(api.UI.share:GetText(),"Send request")
    state.click(api.UI.share); equal(sent,item.id)
    link={offerId="request-1",state="pending"}; api.Refresh()
    equal(api.UI.share:GetText(),"View request")
    link.state="agreed"; api.Refresh(); equal(api.UI.share:GetText(),"Confirmed")
    api.ShowShared=function(peer) opened=peer end
    api.SelectSharedOffer=function(id) selected=id end
    state.click(api.UI.share); equal(opened,"Birch Vale"); equal(selected,"request-1")
    equal(#api.GetLedger().entries,1); equal(#api.GetLedger().entries[1].events,0)
end)

test("new IOUs ask for player confirmation only when explicitly selected",function()
    local state,api=session()
    local sent={}
    api.Sharing={Share=function(id) sent[#sent+1]=id; return {offerId="request-"..id} end}
    api.ShowAdd("Birch Vale"); local form=api.UI.add
    equal(form.shareToggle:GetText(),"Ask to confirm: off")
    form.money:Fill(1000); state.click(form.create); equal(#sent,0)
    api.ShowAdd("Birch Vale"); state.click(form.shareToggle)
    equal(form.shareToggle:GetText(),"Ask to confirm: on")
    form.money:Fill(2000); state.click(form.create); equal(#sent,1); equal(sent[1],2)
    api.ShowAdd("Birch Vale"); equal(form.shareToggle:GetText(),"Ask to confirm: off")
end)

test("Requests explains confirmation and exposes matching concise entry points",function()
    local state,api=session()
    assert(api.SharedService.Initialize())
    api.ShowSettings(); assert(state.button(api.UI.settings,"IOU requests"))
    api.ShowShared(); local board=api.UI.shared
    contains(visible(state,board),"IOU requests")
    contains(visible(state,board),"Ask a player to confirm an IOU.")
    equal(board.propose:GetText(),"+ New request")
    assert(api.SharedService.Enable("Birch Vale"))
    state.click(board.propose)
    contains(visible(state,api.UI.sharedForm),"Request an IOU")
    equal(api.UI.sharedForm.send:GetText(),"Send request")
    assert(api.UI.sharedForm.send:GetWidth()>=#api.UI.sharedForm.send:GetText()*7)
end)

return results
