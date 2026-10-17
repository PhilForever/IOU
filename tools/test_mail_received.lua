-- Synthetic native callbacks only; this harness never collects real mail.
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(a,b) assert(a:find(b,1,true),"missing "..b) end
local function link(id) return "|cffffffff|Hitem:"..(id or 2589)..":0:0:0:0:0:0:0:0|h[Linen Cloth]|h|r" end
local function item(id,quantity) return {name="Linen Cloth",id=id or 2589,quantity=quantity or 5,link=link(id)} end
local function mail(options)
    local row={sender="Birch Vale",subject="Materials",money=0,cod=0,days=29.9,
        items={},reply=true,returned=false,gm=false,stationery=61}
    for key,value in pairs(options or {}) do row[key]=value end
    return row
end
local function session(options)
    options=options or {}
    local s={now=100,mails={},calls={},hooks={},frames={},counter=0,nativeCalls={},
        secret=setmetatable({}, {__tostring=function() error("secret stringify") end})}
    local ns={}
    local env=setmetatable({GetTime=function() return s.now end,
        issecretvalue=function(value) return rawequal(value,s.secret) end,
        CreateFrame=function()
            local f={events={},scripts={}}
            function f:RegisterEvent(event) if options.registrationError then error("unavailable") end;self.events[event]=true end
            function f:UnregisterAllEvents() self.events={} end
            function f:SetScript(name,fn) self.scripts[name]=fn end
            s.frames[#s.frames+1]=f;return f
        end,
        hooksecurefunc=function(name,fn)
            if options.hookError then error("unavailable") end
            s.hooks[name]=fn
        end,
        GetInboxNumItems=function()
            if s.countError then error("unavailable") end
            return s.count or #s.mails,s.total or #s.mails
        end,
        GetInboxHeaderInfo=function(index)
            if s.headerError then error("unavailable") end
            local row=s.mails[index]
            if not row then return end
            local count=0;for _ in pairs(row.items) do count=count+1 end
            if count==0 then count=nil end
            return row.package,row.stationery,row.sender,row.subject,row.money,row.cod,row.days,
                row.count or count,row.read,row.returned,false,row.reply,row.gm
        end,
        GetInboxItem=function(index,slot)
            if s.itemError then error("unavailable") end
            local row=s.mails[index] and s.mails[index].items[slot]
            if row then return row.name,row.id,1,row.quantity,1,true,row.currency end
        end,
        GetInboxItemLink=function(index,slot)
            if s.linkError then error("unavailable") end
            local row=s.mails[index] and s.mails[index].items[slot]
            return row and row.link
        end,
        GetInboxInvoiceInfo=function(index)
            if s.invoiceError then error("unavailable") end
            return s.mails[index] and s.mails[index].invoice
        end,
        GetInboxText=function() error("observer read mail body") end,
        SendChatMessage=function() error("observer sent chat") end,
        TakeInboxMoney=function() error("observer collected money") end,
        TakeInboxItem=function() error("observer collected item") end,
        AutoLootMailItem=function() error("observer auto-looted mail") end,
        DeleteInboxItem=function() error("observer deleted mail") end,
        ReturnInboxItem=function() error("observer returned mail") end,
        TakeInboxTextItem=function() error("observer took mail letter") end,
        CloseMail=function() error("observer closed mail") end,
        SendMail=function() error("observer sent mail") end}, {__index=_G})
    env._G=env
    ns.PlayerSummary={NameKey=function(name)
        if rawequal(name,s.secret) or type(name)~="string" or name=="" then return nil end
        return name:gsub(" +"," "):lower()
    end}
    ns.TradeMatching={ItemKey=function(value)
        if type(value)~="string" then return end
        local id=value:match("|Hitem:(%d+):")
        if id then return "item:"..id,tonumber(id) end
    end}
    ns.TradeService={NewSessionID=function(medium)
        equal(medium,"mail_received")
        if s.reserveError then error("failed") end
        if s.reserveFail then return nil end
        if s.reserveSecret then return s.secret end
        s.counter=s.counter+1;return "tr-"..s.counter
    end,Record=function(value)
        if s.recordError then error("failed") end
        s.calls[#s.calls+1]=value
        if s.recordFail then return nil end
        return {id=value.id}
    end}
    local chunk=assert(loadstring(assert(IOU_SOURCES["mail_received.lua"]),"@IOU/mail_received.lua"))
    setfenv(chunk,env);chunk("IOU",ns)
    s.api,s.env,s.observer=ns,env,ns.MailReceived
    function s:event(event,arg)
        for _,f in ipairs(self.frames) do
            if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f,event,arg) end
        end
    end
    function s:call(name,...) assert(self.hooks[name],"missing hook "..name)(...) end
    function s:ready() assert(self.observer.Initialize());self:event("MAIL_SHOW") end
    function s:update() self:event("MAIL_INBOX_UPDATE") end
    function s:success(id) self:event("MAIL_SUCCESS",id) end
    return s
end

test("mail collection requires a native money call exact removal and success",function()
    local s=session();s.mails={mail({money=50000})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s:update();equal(#s.calls,0);s:success();equal(#s.calls,1)
    equal(s.calls[1].medium,"mail_received");equal(s.calls[1].peer,"Birch Vale")
    equal(s.calls[1].incoming.money,50000);equal(s.calls[1].outgoing.money,0)
    equal(#s.calls[1].outgoing.items,0)
end)
test("mail collection supports success before the inbox update",function()
    local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1);s:success()
    equal(#s.calls,0);s.mails[1].money=0;s:update();equal(#s.calls,1)
end)
test("mail collection native item records final native link ID and quantity",function()
    local s=session();s.mails={mail({items={[4]=item(2589,12)},money=10})};s:ready()
    s:call("TakeInboxItem",1,4);s.mails[1].items[4]=nil;s:update();s:success(2589)
    equal(#s.calls,1);equal(#s.calls[1].incoming.items,1);equal(s.calls[1].incoming.money,0)
    equal(s.calls[1].incoming.items[1].quantity,12);equal(s.calls[1].incoming.items[1].itemID,2589)
    equal(s.calls[1].incoming.items[1].link,link(2589))
end)
test("mail collection follows a unique message after preceding inbox indices shift",function()
    local s=session();s.mails={mail({subject="Other"}),mail({money=500})};s:ready();s:call("TakeInboxMoney",2)
    -- An unrelated deletion is ambiguous even though the target can be located.
    table.remove(s.mails,1);s.mails[1].money=0;s:update();s:success();equal(#s.calls,0)
    local t=session();t.mails={mail({money=500}),mail({subject="Other"})};t:ready();t:call("TakeInboxMoney",1)
    table.remove(t.mails,1);t:update();t:success();equal(#t.calls,1);equal(t.calls[1].incoming.money,500)
end)
test("mail collection never records reading mail alone or mailbox-wide balance differences",function()
    local s=session();s.mails={mail({money=500})};s:ready();s.mails[1].read=true;s:update();s:success()
    s.mails[1].money=0;s:update();s:success();equal(#s.calls,0)
end)
test("mail collection requires actual removal and never treats success alone as receipt",function()
    local s=session();s.mails={mail({money=500,items={[1]=item()}})};s:ready();s:call("AutoLootMailItem",1)
    s:success();s:update();equal(#s.calls,0)
end)
test("mail collection duplicate callbacks cannot record a collected asset twice",function()
    local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s:success();s:update();s:success();s:update();equal(#s.calls,1)
end)
test("mail collection supports automatic collection of money and twelve attachments",function()
    local items={};for i=1,12 do items[i]=item(2588+i,i) end
    local s=session();s.mails={mail({money=321,items=items})};s:ready();s:call("AutoLootMailItem",1)
    s.mails={};s:update();s:success();equal(#s.calls,1)
    equal(s.calls[1].incoming.money,321);equal(#s.calls[1].incoming.items,12)
end)
test("mail collection auto-loot confirms partial assets independently",function()
    local s=session();s.mails={mail({money=500,items={[1]=item(2589,5),[4]=item(2592,7)}})}
    s:ready();s:call("AutoLootMailItem",1);s.mails[1].money=0;s:success();s:update()
    equal(#s.calls,1);equal(s.calls[1].incoming.money,500);equal(#s.calls[1].incoming.items,0)
    s.mails[1].items[1]=nil;s:update();s:success(2589);equal(#s.calls,2)
    equal(s.calls[2].incoming.items[1].quantity,5)
    s.mails[1].items[4]=nil;s:success(2592);equal(#s.calls,3)
    equal(s.calls[3].id,"tr-3")
end)
test("mail collection failed retrieval cannot record a later disappearance",function()
    for _,event in ipairs({"MAIL_FAILED","UI_ERROR_MESSAGE","MAIL_OPEN_ALL_CANCELED","MAIL_SEND_SUCCESS"}) do
        local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1);s:event(event,2589)
        s.mails={};s:update();s:success();equal(#s.calls,0)
    end
end)
test("mail collection full bags and unchanged attachment never repay",function()
    local s=session();s.mails={mail({items={[1]=item()}})};s:ready();s:call("TakeInboxItem",1,1)
    s:event("MAIL_FAILED",2589);s:success(2589);s:update();equal(#s.calls,0)
end)
test("mail collection excludes COD returned system GM and invoice mail",function()
    for _,changes in ipairs({{cod=1},{returned=true},{reply=false},{gm=true},{invoice="seller"}}) do
        changes.money=500
        local s=session();s.mails={mail(changes)};s:ready();s:call("TakeInboxMoney",1)
        s.mails[1].money=0;s:update();s:success();equal(#s.calls,0)
    end
end)
test("mail collection invoice lookup failure cannot be treated as ordinary player mail",function()
    local s=session();s.invoiceError=true;s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
    s.mails={};s:success();s:update();equal(#s.calls,0)
end)
test("mail collection truly indistinguishable original messages fail closed",function()
    local s=session();s.mails={mail({money=500}),mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s:update();s:success();equal(#s.calls,0)
end)
test("mail collection same sender and subject with distinct gold amounts stays automatic",function()
    local s=session();s.mails={mail({money=500}),mail({money=900})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s:update();s:success();equal(#s.calls,1);equal(s.calls[1].incoming.money,500)
    s:call("TakeInboxMoney",2);s.mails[2].money=0;s:success();equal(#s.calls,2)
    equal(s.calls[2].incoming.money,900)
end)
test("mail collection same header distinct attachments supports removal and shifted index",function()
    local s=session();s.mails={mail({items={[1]=item(2589,5)}}),mail({items={[1]=item(2592,7)}})}
    s:ready();s:call("TakeInboxItem",1,1);table.remove(s.mails,1);s:update();s:success(2589)
    equal(#s.calls,1);equal(s.calls[1].incoming.items[1].quantity,5)
    equal(s.calls[1].incoming.items[1].itemID,2589)
    s:call("TakeInboxItem",1,1);s.mails={};s:success(2592);equal(#s.calls,2)
end)
test("mail collection same-header second message changing cannot confirm the requested first message",function()
    local s=session();s.mails={mail({money=500}),mail({money=900})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[2].money=0;s:update();s:success();equal(#s.calls,0)
    local t=session();t.mails={mail({money=500}),mail({money=900})};t:ready();t:call("TakeInboxMoney",1)
    t.mails[1].money=0;t.mails[2].money=0;t:success();equal(#t.calls,0)
end)
test("mail collection unrelated new mail and changed assets invalidate attribution",function()
    local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s.mails[2]=mail({subject="New mail"});s:update();s:success();equal(#s.calls,0)
    local t=session();t.mails={mail({money=500}),mail({subject="Other",money=900})};t:ready();t:call("TakeInboxMoney",1)
    t.mails[1].money=0;t.mails[2].money=0;t:update();t:success();equal(#t.calls,0)
end)
test("mail collection actual inbox reorder preserves unambiguous content matching",function()
    local s=session();local a=mail({money=500});local b=mail({subject="Other",money=900})
    s.mails={a,b};s:ready();s:call("TakeInboxMoney",1);a.money=0;s.mails={b,a};s:update();s:success()
    equal(#s.calls,1);equal(s.calls[1].incoming.money,500)
end)
test("mail collection duplicate native requests quarantine late successes",function()
    local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1);s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s:success();s:update();equal(#s.calls,0)
end)
test("mail collection competing delete return and send commands invalidate pending collection",function()
    for _,name in ipairs({"DeleteInboxItem","ReturnInboxItem","TakeInboxTextItem","CloseMail","SendMail"}) do
        local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1);s:call(name,1)
        s.mails={};s:success();s:update();equal(#s.calls,0)
    end
end)
test("mail collection mismatched item success cannot confirm the pending attachment",function()
    local s=session();s.mails={mail({items={[1]=item()}})};s:ready();s:call("TakeInboxItem",1,1)
    s.mails={};s:update();s:success(2592);equal(#s.calls,0)
end)
test("mail collection single-slot call cannot consume unrequested mail assets",function()
    local s=session();s.mails={mail({money=500,items={[1]=item()}})};s:ready();s:call("TakeInboxItem",1,1)
    s.mails={};s:update();s:success(2589);equal(#s.calls,0)
end)
test("mail collection money call cannot consume an unrequested attachment",function()
    local s=session();s.mails={mail({money=500,items={[1]=item()}})};s:ready();s:call("TakeInboxMoney",1)
    s.mails[1].money=0;s.mails[1].items={};s:update();s:success();equal(#s.calls,0)
end)
test("mail collection combines duplicate item stacks without inventing quantity",function()
    local s=session();s.mails={mail({items={[1]=item(2589,5),[2]=item(2589,7)}})};s:ready()
    s:call("TakeInboxItem",1,1);s.mails[1].items[1]=nil;s:success(2589)
    equal(#s.calls,1);equal(s.calls[1].incoming.items[1].quantity,5)
end)
test("mail collection secret identities headers quantities and success IDs fail closed",function()
    for _,field in ipairs({"sender","money","cod","days","reply","returned","gm","subject"}) do
        local s=session();local row=mail({money=500});row[field]=s.secret;s.mails={row};s:ready()
        s:call("TakeInboxMoney",1);s.mails={};s:update();s:success();equal(#s.calls,0)
    end
    local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
    s.mails={};s:success(s.secret);s:update();equal(#s.calls,0)
end)
test("mail collection malformed currency uncached and mismatched item links fail closed",function()
    for _,changes in ipairs({{currency=true},{quantity=0},{quantity=0.5},{name=""},{link=link(2592)}}) do
        local s=session();local i=item();for key,value in pairs(changes) do i[key]=value end
        s.mails={mail({items={[1]=i}})};s:ready();s:call("TakeInboxItem",1,1)
        s.mails={};s:success(2589);s:update();equal(#s.calls,0)
    end
    local s=session();local i=item();i.link=nil;s.mails={mail({items={[1]=i}})};s:ready()
    s:call("TakeInboxItem",1,1);s.mails={};s:success(2589);equal(#s.calls,0)
end)
test("mail collection refuses more than twelve attachments without partial records",function()
    local items={};for i=1,13 do items[i]=item(2588+i,1) end
    local s=session();s.mails={mail({money=321,items=items})};s:ready();s:call("AutoLootMailItem",1)
    s.mails={};s:success();s:update();equal(#s.calls,0)
end)
test("mail collection incomplete inbox and thrown native APIs fail closed",function()
    for _,flag in ipairs({"countError","headerError","itemError","linkError"}) do
        local s=session();s[flag]=true;s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
        s.mails={};s:success();equal(#s.calls,0)
    end
    local s=session();s.mails={mail({money=500})};s.total=2;s:ready();s:call("TakeInboxMoney",1)
    s.mails={};s.total=0;s:success();equal(#s.calls,0)
end)
test("mail collection close logout and timeout clear uncertain native operations",function()
    for _,event in ipairs({"MAIL_CLOSED","PLAYER_LOGOUT"}) do
        local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1);s:event(event)
        s.mails={};s:success();s:update();equal(#s.calls,0)
    end
    local s=session();s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
    s.now=110;s.mails={};s:success();equal(#s.calls,0)
end)
test("mail collection reservation and recorder failures never retry financial writes",function()
    for _,flag in ipairs({"reserveFail","reserveError","reserveSecret","recordError","recordFail"}) do
        local s=session();s[flag]=true;s.mails={mail({money=500})};s:ready();s:call("TakeInboxMoney",1)
        s.mails={};s:success();s[flag]=false;s:update();s:success()
        equal(#s.calls,flag=="recordFail" and 1 or 0)
    end
end)
test("mail collection ignores hooks outside a mailbox and native functions remain untouched",function()
    local s=session();s.mails={mail({money=500})};local native=s.env.TakeInboxMoney
    assert(s.observer.Initialize());s:call("TakeInboxMoney",1);s.mails={};s:success()
    equal(#s.calls,0);equal(s.env.TakeInboxMoney,native)
end)
test("mail collection secure posthook adapter faults never escape the native collection call",function()
    local s=session();s.mails={mail({items={[1]=item()}})};s:ready()
    local matching=s.api.TradeMatching
    s.api.TradeMatching=setmetatable({}, {__index=function() error("broken item adapter") end})
    assert(pcall(s.hooks.TakeInboxItem,1,1));contains(s.observer.Report(),"paused")
    s.api.TradeMatching=matching;s.mails={};s:success(2589);equal(#s.calls,0)
end)
test("mail collection event adapter faults drop uncertain evidence without breaking mail events",function()
    local s=session();s.mails={mail({money=500,items={[1]=item()}})};s:ready();s:call("TakeInboxMoney",1)
    local matching=s.api.TradeMatching
    s.api.TradeMatching=setmetatable({}, {__index=function() error("broken item adapter") end})
    s.mails[1].money=0;assert(pcall(function() s:success() end))
    contains(s.observer.Report(),"paused");s.api.TradeMatching=matching;s:update();s:success();equal(#s.calls,0)
end)
test("mail collection initialization is idempotent and unsupported clients stay inert",function()
    local s=session();assert(s.observer.Initialize());assert(s.observer.Initialize());equal(#s.frames,1)
    local bad=session({registrationError=true});equal(bad.observer.Initialize(),nil)
    local hooks=session({hookError=true});equal(hooks.observer.Initialize(),nil);equal(hooks.observer.Initialize(),nil)
    contains(hooks.observer.Report(),"unavailable")
    local absent=session();absent.env.TakeInboxMoney=false;equal(absent.observer.Initialize(),nil)
end)

return results
