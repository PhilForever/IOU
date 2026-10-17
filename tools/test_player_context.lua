-- Synthetic player-context hooks: no game, account, or installed files read.
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(value,text) assert(value:find(text,1,true),"missing "..text.." in "..value) end
local function copy(value)
    if type(value)~="table" then return value end
    local out={};for key,item in pairs(value) do out[key]=copy(item) end;return out
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for key,item in pairs(a) do if not same(item,b[key]) then return false end end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function session(options)
    options=options or {}
    local state={frames={},units={NPC={"Birch","Vale"},target={"Wrong","Person"},mouseover={"Birch","Vale"}},
        settings={},modernCalls=0,overviewCalls=0,secret={},shown={},added={}}
    local function frame()
        local f={scripts={},lines={},shown=false}
        function f:HookScript(event,fn)
            if options.noLegacy and event=="OnTooltipSetUnit" then error("unsupported legacy script") end
            local prior=self.scripts[event]
            self.scripts[event]=function(...) if prior then prior(...) end;fn(...) end
        end
        function f:SetScript(event,fn) self.scripts[event]=fn end
        function f:Fire(event,...) if self.scripts[event] then self.scripts[event](self,...) end end
        function f:Show() self.shown=true end
        function f:Hide() self.shown=false;self:Fire("OnHide") end
        function f:IsShown() return self.shown end
        function f:SetText(text) self.text=text end
        function f:SetSize(w,h) self.width,self.height=w,h end
        function f:SetHeight(h) self.height=h end
        function f:SetMaxLines(count) self.maxLines=count end
        function f:SetPoint(...) self.point={...} end
        function f:ClearAllPoints() self.point=nil end
        function f:SetClampedToScreen(value) self.clamped=value end
        function f:RegisterEvent(event) self[event]=true end
        function f:IsForbidden() return state.forbidden or false end
        function f:GetUnit()
            if state.getUnitError then error("restricted identity") end
            return "Display only",state.tooltipUnit or "mouseover"
        end
        function f:AddLine(text) self.lines[#self.lines+1]=text end
        state.frames[#state.frames+1]=f;return f
    end
    local ns={}
    local env=setmetatable({issecretvalue=function(value) return value==state.secret end,
        UnitIsPlayer=function(unit)
            if state.playerError then error("unavailable") end
            if state.playerResult~=nil then return state.playerResult end
            return state.units[unit]~=nil
        end,
        UnitNameUnmodified=function(unit)
            local who=state.units[unit];if who then return who[1],who[2] end
        end,
        Constants={CharacterNameSeparatorConsts={CHARACTERNAME_SURNAME_SEPARATOR=" "}},
        CreateFrame=function() return frame() end,
        Enum={TooltipDataType={Unit=2}},
        SendChatMessage=function() error("context attempted chat") end,
        C_ChatInfo=setmetatable({},{__index=function() error("context accessed network") end}),
        time=function() error("context accessed clock") end,
        GetTime=function() error("context accessed clock") end,
        C_Timer=setmetatable({},{__index=function() error("context installed a timer") end})}, {__index=_G})
    env.NameUtil={GetUnmodifiedUnitFullName=function(unit)
        if state.nameError then error("unavailable") end
        if state.nameResult~=nil then return state.nameResult end
        local who=state.units[unit]
        if who then return who[1].." "..who[2] end
    end}
    env.GameTooltip=frame();env.TradeFrame=frame()
    if not options.legacy then
        env.TooltipDataProcessor={AddTooltipPostCall=function(kind,fn)
            equal(kind,2)
            if options.modernError then error("unavailable") end
            state.modernCalls=state.modernCalls+1;state.callback=fn
        end}
    end
    ns.UI={Helpers={panel=function(parent,w,h)
        local f=frame();f.parent=parent;f:SetSize(w,h);return f
    end,font=function(_,_,_,_,_,text) local f=frame();f:SetText(text);return f end,
    button=function(_,text,_,_,_,action) local f=frame();f:SetText(text);f.click=action;return f end}}
    for _,name in ipairs({"ledger.lua","shared_codec.lua","player_summary.lua"}) do
        local chunk=assert(loadstring(assert(IOU_SOURCES[name]),"@IOU/"..name));setfenv(chunk,env);chunk("IOU",ns)
    end
    state.ledger=ns.Ledger.New()
    state.overview={localName="Amber Stone",offers={},balances={}}
    ns.GetLedger=function() return state.ledger end
    ns.GetSettings=function() return state.settings end
    ns.SharedService={GetOverview=function() state.overviewCalls=state.overviewCalls+1;return state.overview end}
    ns.ShowPlayerRecords=function(name) state.shown[#state.shown+1]=name end
    ns.ShowAdd=function(name) state.added[#state.added+1]=name end
    local chunk=assert(loadstring(assert(IOU_SOURCES["player_context.lua"]),"@IOU/player_context.lua"))
    setfenv(chunk,env);chunk("IOU",ns)
    state.api,state.env,state.context=ns,env,ns.PlayerContext
    function state:add(direction,kind,amount,label,who)
        return assert(ns.Ledger.Add(self.ledger,{player=who or "Birch Vale",direction=direction or "owed",
            kind=kind or "money",amount=amount or 10000,label=label or "",note=""},100))
    end
    function state:shared(direction,amount,id)
        id=id or "shared"
        local terms={protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",recipient="Birch Vale",
            debtor=direction=="owe" and "Amber Stone" or "Birch Vale",
            creditor=direction=="owe" and "Birch Vale" or "Amber Stone",
            amountCopper=amount,dueUTC=0,note=""}
        self.overview.offers[#self.overview.offers+1]={offerId=id,role="proposer",state="COMMITTED",
            delivery="PEER_RECEIPT_OBSERVED",terms=assert(ns.SharedCodec.CanonicalTerms(terms))}
        self.overview.balances[id]={confirmed=true,remainingCopper=amount}
    end
    function state:tooltip()
        if self.callback then self.callback(env.GameTooltip,{})
        else env.GameTooltip:Fire("OnTooltipSetUnit") end
        return table.concat(env.GameTooltip.lines,"\n")
    end
    function state:event(event)
        for _,f in ipairs(self.frames) do if f[event] then f:Fire("OnEvent",event) end end
    end
    return state
end

test("context summary caches exact full-player projections and invalidates both sources",function()
    local s=session();s:add();s:add("owed","money",90000,"","Birch Other")
    equal(s.context.GetSummary(" birch  VALE ").personal.owed.money,10000)
    equal(s.context.GetSummary("Birch").count,0)
    equal(s.context.GetSummary("Birch-Vale").count,0);equal(s.overviewCalls,1)
    s:add("owed","money",20000);s.context.Invalidate()
    equal(s.context.GetSummary("Birch Vale").personal.owed.money,30000);equal(s.overviewCalls,2)
end)

test("context accepts validated overview cache supplied by the Shared board",function()
    local s=session();s:add();s:shared("owed",6000)
    s.context.Invalidate(s.overview,nil)
    equal(s.context.GetSummary("Birch Vale").shared.owed.money,6000);equal(s.overviewCalls,0)
    s.context.Invalidate(nil,"Shared storage unavailable")
    equal(s.context.GetSummary("Birch Vale").personal.owed.money,10000);equal(s.overviewCalls,0)
    s.context.Invalidate();s.context.GetSummary("Birch Vale");equal(s.overviewCalls,1)
end)

test("context modern tooltip registers once without legacy double-decoration",function()
    local s=session({noLegacy=true});s:add();s.context.Initialize();s.context.Initialize()
    equal(s.modernCalls,1);contains(s:tooltip(),"Owes you 1g")
    local count=#s.env.GameTooltip.lines;s:tooltip();equal(#s.env.GameTooltip.lines,count)
    equal(s.env.GameTooltip.scripts.OnTooltipSetUnit,nil)
    s.env.GameTooltip.lines={};s.env.GameTooltip:Fire("OnTooltipCleared")
    contains(s:tooltip(),"Owes you 1g")
end)

test("context supports guarded legacy tooltip and failed modern registration fallback",function()
    for _,options in ipairs({{legacy=true},{modernError=true}}) do
        local s=session(options);s:add();s.context.Initialize()
        assert(s.env.GameTooltip.scripts.OnTooltipSetUnit);contains(s:tooltip(),"Owes you 1g")
        local count=#s.env.GameTooltip.lines;s:tooltip();equal(#s.env.GameTooltip.lines,count)
    end
end)

test("context tooltips separate both directions and personal versus shared amounts",function()
    local s=session();s:add();s:add("owe","money",5000)
    s:shared("owed",6000,"a");s:shared("owe",2500,"b")
    s.context.Initialize();local text=s:tooltip()
    contains(text,"IOU - Your notes");contains(text,"IOU - Shared")
    contains(text,"Owes you 1g");contains(text,"You owe 50s")
    contains(text,"Owes you 60s");contains(text,"You owe 25s")
    assert(not text:find("1g 60s",1,true),"independent sources were summed")
end)

test("context item labels are readable escaped literals with bounded detail",function()
    local s=session();s:add("owed","item",3,"|cff1eff00|Hitem:123|h[Linen Cloth]|h|r")
    s:add("owe","item",2,"Linen |Tbad|t");s.context.Initialize()
    local text=s:tooltip();contains(text,"3 x [Linen Cloth]");contains(text,"2 x Linen ||Tbad||t")
    assert(not text:find("|Hitem",1,true));assert(not text:find("|cff",1,true))
end)

test("context skips empty and settled summaries without touching tooltips or trade",function()
    local s=session();local item=s:add();assert(s.api.Ledger.Settle(s.ledger,item.id,"",101))
    s.context.Initialize();equal(s:tooltip(),"");s:event("TRADE_SHOW");equal(s.context.tradeFrame,nil)
end)

test("context trade uses actual NPC recipient regardless of current target",function()
    local s=session();s:add();s:add("owed","money",90000,"","Wrong Person")
    s.context.Initialize();s:event("TRADE_SHOW")
    local panel=assert(s.context.tradeFrame);assert(panel.shown);contains(panel.title.text,"Birch Vale")
    contains(panel.rows[1].text,"1g");assert(not panel.rows[1].text:find("9g",1,true))
    equal(panel.parent,s.env.TradeFrame);equal(panel.point[2],s.env.TradeFrame)
    equal(panel.rows[1].maxLines,2);equal(panel.rows[1].height,36);assert(panel.height<150)
    panel.records.click();panel.add.click();equal(s.shown[1],"Birch Vale");equal(s.added[1],"Birch Vale")
end)

test("context trade hides on close and never changes ledger or sends messages",function()
    local s=session();s:add();local before=copy(s.ledger)
    s.context.Initialize();s:event("TRADE_SHOW");assert(s.context.tradeFrame.shown)
    s:event("TRADE_CLOSED");assert(not s.context.tradeFrame.shown)
    s.context.Invalidate();assert(not s.context.tradeFrame.shown);assert(same(before,s.ledger))
    s.context.tradeFrame.records.click();equal(#s.shown,0)
end)

test("context refreshes open trade after bookkeeping and clears stale recipient",function()
    local s=session();local entry=s:add();s.context.Initialize();s:event("TRADE_SHOW")
    assert(s.api.Ledger.Pay(s.ledger,entry.id,4000,"",101));s.context.Invalidate()
    contains(s.context.tradeFrame.rows[1].text,"60s")
    s.env.NameUtil=nil;s.units.NPC=nil;s:event("TRADE_UPDATE")
    assert(not s.context.tradeFrame.shown,"wrong target must not replace absent trade identity")
end)

test("context plain full-name resolver preserves surnames and rejects NPCs or restricted values",function()
    local s=session();equal(s.context.UnitName("NPC"),"Birch Vale")
    s.env.NameUtil=nil;equal(s.context.UnitName("NPC"),"Birch Vale")
    s.units.NPC={"Birch",s.secret};equal(s.context.UnitName("NPC"),nil)
    s.units.NPC={"Birch","Vale"};s.playerResult=s.secret;equal(s.context.UnitName("NPC"),nil)
    s.playerResult=false;equal(s.context.UnitName("NPC"),nil)
    s.playerResult=nil;s.playerError=true;equal(s.context.UnitName("NPC"),nil)
    s.playerError=false;equal(s.context.UnitName(s.secret),nil);equal(s.context.UnitName("Birch Vale"),nil)
    s.playerResult=nil;s.units.NPC={s.secret,"Vale"};equal(s.context.UnitName("NPC"),nil)
    s.units.NPC={"Birch","Vale"};s.env.Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR=s.secret
    equal(s.context.UnitName("NPC"),nil)
end)

test("context fails safely for secret tooltip token security flags and inaccessible identity",function()
    local s=session();s:add();s.context.Initialize()
    s.forbidden=s.secret;equal(s:tooltip(),"")
    s.forbidden=true;equal(s:tooltip(),"")
    s.forbidden=false;s.tooltipUnit=s.secret;equal(s:tooltip(),"")
    s.tooltipUnit="mouseover";s.getUnitError=true;equal(s:tooltip(),"")
    s.getUnitError=false;s.playerResult=s.secret;equal(s:tooltip(),"")
end)

test("context settings default on while explicit off and secret settings suppress reminders",function()
    local s=session();s:add();s.settings.playerTooltips=false;s.settings.tradeReminders=false
    s.context.Initialize();equal(s:tooltip(),"");s:event("TRADE_SHOW");equal(s.context.tradeFrame,nil)
    s.settings.playerTooltips=s.secret;s.settings.tradeReminders=s.secret
    equal(s:tooltip(),"");s:event("TRADE_UPDATE");equal(s.context.tradeFrame,nil)
    s.settings.playerTooltips=nil;s.settings.tradeReminders=nil
    contains(s:tooltip(),"Owes you 1g");s:event("TRADE_UPDATE");assert(s.context.tradeFrame.shown)
end)

return results
