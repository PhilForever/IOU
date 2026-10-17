-- Synthetic native events only. This harness never opens or accepts a trade.
local results={}
local function test(name, run)
    local ok, err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(a,b) assert(a:find(b,1,true),"missing "..b) end
local function link(id, suffix) return "|cffffffff|Hitem:"..id..":"..(suffix or "0:0:0:0:0:0:0:0").."|h[Linen Cloth]|h|r" end
local function item(id, quantity)
    return {name="Linen Cloth",itemID=id or 2589,quantity=quantity or 5,link=link(id or 2589)}
end
local function session(options)
    options=options or {}
    local s={now=100,peer="Birch Vale",outgoing=0,incoming=0,player={},target={},
        calls={},frames={},counter=0,secret=setmetatable({}, {__tostring=function() error("secret stringify") end}),
        infoCalls={player={},target={}}}
    local ns={}
    local env=setmetatable({GetTime=function() return s.now end,
        issecretvalue=function(value) return rawequal(value,s.secret) end,
        CreateFrame=function()
            local f={events={},scripts={}}
            function f:RegisterEvent(event)
                if options.registrationError then error("unsupported") end
                self.events[event]=true
            end
            function f:UnregisterAllEvents() self.events={} end
            function f:SetScript(event,fn) self.scripts[event]=fn end
            s.frames[#s.frames+1]=f
            return f
        end,
        GetGameMessageInfo=function(id)
            if s.lookupError then error("unavailable") end
            if s.lookupSecret then return s.secret end
            if id==42 then return "ERR_TRADE_COMPLETE" end
            return "ERR_OTHER"
        end,
        GetPlayerTradeMoney=function() if s.moneyError then error("restricted") end;return s.outgoing end,
        GetTargetTradeMoney=function() return s.incoming end,
        GetTradePlayerItemInfo=function(slot)
            s.infoCalls.player[#s.infoCalls.player+1]=slot
            if s.infoError then error("restricted") end
            local row=s.player[slot]
            if row then return row.name,1,row.quantity,1,row.enchantment,false,false,row.itemID end
        end,
        GetTradeTargetItemInfo=function(slot)
            s.infoCalls.target[#s.infoCalls.target+1]=slot
            local row=s.target[slot]
            if row then return row.name,1,row.quantity,1,false,row.enchantment,row.itemID end
        end,
        GetTradePlayerItemLink=function(slot)
            if s.linkError then error("restricted") end
            return s.player[slot] and s.player[slot].link
        end,
        GetTradeTargetItemLink=function(slot) return s.target[slot] and s.target[slot].link end,
        SendChatMessage=function() error("observer sent chat") end,
        AcceptTrade=function() error("observer accepted a trade") end,
        CloseTrade=function() error("observer closed a trade") end,
        C_ChatInfo=setmetatable({}, {__index=function() error("observer accessed network") end})}, {__index=_G})
    ns.PlayerContext={UnitName=function(unit) equal(unit,"NPC");return s.peer end}
    ns.PlayerSummary={NameKey=function(name)
        if rawequal(name,s.secret) or type(name)~="string" or name=="" then return nil end
        return name:gsub(" +"," "):lower()
    end}
    ns.TradeService={NewSessionID=function()
        if s.reserveError then error("reservation failed") end
        if s.reserveFail then return nil,"unavailable" end
        if s.reserveSecret then return s.secret end
        s.counter=s.counter+1
        return "tr-"..s.counter
    end,Record=function(value)
        if s.recordError then error("save failed") end
        s.calls[#s.calls+1]=value
        if s.recordFail then return nil,"invalid" end
        return {id=value.id}
    end}
    local chunk=assert(loadstring(assert(IOU_SOURCES["trade_observer.lua"]),"@IOU/trade_observer.lua"))
    setfenv(chunk,env);chunk("IOU",ns)
    s.api,s.env,s.observer=ns,env,ns.TradeObserver
    function s:event(event,...)
        for _,f in ipairs(self.frames) do
            if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f,event,...) end
        end
    end
    function s:show() self:event("TRADE_SHOW") end
    function s:accept() self:event("TRADE_ACCEPT_UPDATE",1,1) end
    function s:success() self:event("UI_INFO_MESSAGE",42,"Localized completion text") end
    function s:ready() assert(self.observer.Initialize());self:show();self:accept() end
    return s
end

test("trade observer submits typed completed gold transfer once",function()
    local s=session();s.outgoing=30000;s.incoming=70000;s:ready();s:success();s:success();s:event("TRADE_CLOSED")
    equal(#s.calls,1);equal(s.calls[1].id,"tr-1");equal(s.calls[1].peer,"Birch Vale")
    equal(s.calls[1].outgoing.money,30000);equal(s.calls[1].incoming.money,70000)
    contains(s.observer.Report(),"Completed trades submitted: 1")
end)
test("trade observer carries final links quantities and both native itemID positions",function()
    local s=session();s.player[1]=item(2589,12);s.target[6]=item(2592,9);s:ready();s:success()
    equal(#s.calls,1);equal(s.calls[1].outgoing.items[1].itemID,2589)
    equal(s.calls[1].outgoing.items[1].quantity,12);equal(s.calls[1].outgoing.items[1].link,link(2589))
    equal(s.calls[1].incoming.items[1].itemID,2592);equal(s.calls[1].incoming.items[1].quantity,9)
end)
test("trade observer waits for completion after closing with cleared APIs",function()
    local s=session();s.incoming=50000;s.target[1]=item();s:ready();s:event("TRADE_CLOSED")
    s.peer=nil;s.incoming=0;s.target={};s.now=s.now+1;s:success()
    equal(#s.calls,1);equal(s.calls[1].incoming.money,50000);equal(#s.calls[1].incoming.items,1)
end)
test("trade observer rejects closure acceptance and bag changes as completion evidence",function()
    local s=session();s.incoming=10000;s:ready();s:event("BAG_UPDATE_DELAYED");s:event("TRADE_CLOSED")
    equal(#s.calls,0);s.now=s.now+5;s:success();equal(#s.calls,0)
end)
test("trade observer duplicate close does not extend the completion grace",function()
    local s=session();s:ready();s:event("TRADE_CLOSED");s.now=s.now+3;s:event("TRADE_CLOSED")
    s.now=s.now+2;s:success();equal(#s.calls,0)
end)
test("trade observer native teardown changes cannot rewrite a closed final snapshot",function()
    local s=session();s.outgoing=25000;s.player[1]=item();s:ready();s:event("TRADE_CLOSED")
    s.outgoing=0;s.player={};s.peer=nil
    s:event("PLAYER_TRADE_MONEY");s:event("TRADE_MONEY_CHANGED");s:event("TRADE_PLAYER_ITEM_CHANGED",1)
    s:success();equal(#s.calls,1);equal(s.calls[1].outgoing.money,25000)
    equal(s.calls[1].outgoing.items[1].quantity,5)
end)
test("trade observer cancellation clears accepted and closed candidates",function()
    for _,closed in ipairs({false,true}) do
        local s=session();s:ready();if closed then s:event("TRADE_CLOSED") end
        s:event("TRADE_REQUEST_CANCEL");s:success();equal(#s.calls,0)
    end
end)
test("trade observer errors invalidate final snapshots",function()
    for _,closed in ipairs({false,true}) do
        local s=session();s:ready();if closed then s:event("TRADE_CLOSED") end
        s:event("UI_ERROR_MESSAGE",999,s.secret);s:success();equal(#s.calls,0)
    end
end)
test("trade observer money item and currency edits require fresh acceptance",function()
    for _,event in ipairs({"TRADE_MONEY_CHANGED","PLAYER_TRADE_MONEY","TRADE_PLAYER_ITEM_CHANGED",
        "TRADE_TARGET_ITEM_CHANGED","TRADE_CURRENCY_CHANGED","PLAYER_TRADE_CURRENCY"}) do
        local s=session();s:ready();s:event(event,1);s:success();equal(#s.calls,0)
        s.incoming=40000;s:accept();s:success();equal(#s.calls,1);equal(s.calls[1].incoming.money,40000)
    end
end)
test("trade observer acceptance reset discards prior contents",function()
    local s=session();s:ready();s:event("TRADE_ACCEPT_UPDATE",0,1);s:success();equal(#s.calls,0)
    s.incoming=900;s:accept();s:success();equal(s.calls[1].incoming.money,900)
end)
test("trade observer requires both accepted and treats readable boolean compatibility safely",function()
    local s=session();assert(s.observer.Initialize());s:show();s:event("TRADE_ACCEPT_UPDATE",1,0)
    s:success();equal(#s.calls,0);s:event("TRADE_ACCEPT_UPDATE",true,true);s:success();equal(#s.calls,1)
end)
test("trade observer refuses unreadable accepted states",function()
    local s=session();s:ready();s:event("TRADE_ACCEPT_UPDATE",s.secret,1);s:success();equal(#s.calls,0)
end)
test("trade observer partner changes cannot use the target player",function()
    local s=session();s:ready();s.peer="Other Player";s:event("TRADE_UPDATE");s:success();equal(#s.calls,0)
    s:show();s:accept();s:success();equal(s.calls[1].peer,"Other Player")
end)
test("trade observer rechecks peer at acceptance and completion",function()
    local s=session();assert(s.observer.Initialize());s:show();s.peer="Other Player";s:accept();s:success();equal(#s.calls,0)
    s:show();s:accept();s.peer="Third Player";s:success();equal(#s.calls,0)
end)
test("trade observer quarantines delayed completion during a rapidly replaced trade",function()
    local s=session();s:ready();s:event("TRADE_CLOSED");s.now=s.now+1;s:show();s:accept();s:success();equal(#s.calls,0)
    s.now=s.now+4;s:accept();s:success();equal(#s.calls,1);equal(s.calls[1].id,"tr-2")
end)
test("trade observer ignores localized or player-supplied success text",function()
    local s=session();s:ready();s:event("UI_INFO_MESSAGE",99,"Trade complete.")
    s:event("CHAT_MSG_SYSTEM","Trade complete.");s:event("UI_ERROR_MESSAGE",42,"Trade complete.")
    s:success();equal(#s.calls,0)
end)
test("trade observer supports typed numeric completion constant without lookup",function()
    local s=session();s.env.GetGameMessageInfo=nil;s.env.LE_GAME_ERR_TRADE_COMPLETE=42;s:ready();s:success();equal(#s.calls,1)
end)
test("trade observer unknown typed mapping never guesses from display text",function()
    local s=session();s.env.GetGameMessageInfo=nil;s.env.LE_GAME_ERR_TRADE_COMPLETE=nil;s:ready();s:success();equal(#s.calls,0)
end)
test("trade observer secret completion types and API values fail closed",function()
    local s=session();s:ready();s:event("UI_INFO_MESSAGE",s.secret,"Trade complete.");equal(#s.calls,0)
    s.outgoing=s.secret;s:accept();s:success();equal(#s.calls,0)
    s.outgoing=0;s.target[1]=item();s.target[1].quantity=s.secret;s:accept();s:success();equal(#s.calls,0)
end)
test("trade observer secret player identity item names and links fail closed",function()
    for _,field in ipairs({"name","link","itemID"}) do
        local s=session();s.player[1]=item();s.player[1][field]=s.secret;s:ready();s:success();equal(#s.calls,0)
    end
    local s=session();s.peer=s.secret;s:ready();s:success();equal(#s.calls,0)
end)
test("trade observer malformed item identity and missing cache never create partial transfers",function()
    for _,bad in ipairs({{name="Linen Cloth",quantity=1,itemID=2589},
        {name="Linen Cloth",quantity=1,itemID=2589,link=link(2592)},
        {name="Linen Cloth",quantity=0,itemID=2589,link=link(2589)},
        {name="Linen Cloth",quantity=0.5,itemID=2589,link=link(2589)},
        {name="Bad|name",quantity=1,itemID=2589,link=link(2589)}}) do
        local s=session();s.incoming=10000;s.target[1]=bad;s:ready();s:success();equal(#s.calls,0)
    end
end)
test("trade observer invalid and thrown money APIs fail closed",function()
    for _,bad in ipairs({-1,0.5,math.huge}) do
        local s=session();s.incoming=bad;s:ready();s:success();equal(#s.calls,0)
    end
    local s=session();s.moneyError=true;s:ready();s:success();equal(#s.calls,0)
end)
test("trade observer enchant slot is service evidence never a transferred item",function()
    local s=session();s.target[7]=item(19019,1);s.target[7].enchantment="Enchant";s.incoming=10000
    s.player[1]=item();s:ready();s:success();equal(#s.calls,1)
    equal(s.calls[1].service,true);equal(#s.calls[1].incoming.items,0);equal(#s.calls[1].outgoing.items,1)
end)
test("trade observer empty enchant slot leaves ordinary transfers eligible",function()
    local s=session();s:ready();s:success();equal(s.calls[1].service,false)
end)
test("trade observer secret enchant slot occupancy fails closed",function()
    local s=session();s.target[7]=item();s.target[7].name=s.secret;s:ready();s:success();equal(#s.calls,0)
end)
test("trade observer reservation failures never record untracked events",function()
    for _,flag in ipairs({"reserveFail","reserveError","reserveSecret"}) do
        local s=session();s[flag]=true;s:ready();s:success();equal(#s.calls,0)
    end
end)
test("trade observer callback failure does not retry a completed trade",function()
    local s=session();s.recordFail=true;s:ready();s:success();s.recordFail=false;s:success();equal(#s.calls,1)
    contains(s.observer.Report(),"recorder failures: 1")
    local s2=session();s2.recordError=true;s2:ready();s2:success();s2.recordError=false;s2:success();equal(#s2.calls,0)
end)
test("trade observer logout and unreadable client clock discard candidates",function()
    local s=session();s:ready();s:event("PLAYER_LOGOUT");s:success();equal(#s.calls,0)
    local s2=session();s2:ready();s2.now=s2.secret;s2:success();s2.now=100;s2:success();equal(#s2.calls,0)
end)
test("trade observer initialization is idempotent and registration failure is bounded",function()
    local s=session();assert(s.observer.Initialize());assert(s.observer.Initialize());equal(#s.frames,1)
    local bad=session({registrationError=true});equal(bad.observer.Initialize(),nil)
    contains(bad.observer.Report(),"events are unavailable")
end)

return results
