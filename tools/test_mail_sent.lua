-- Synthetic mail APIs only: no real mailbox is opened and no mail is sent.
local results={}
local function test(name,run)
    local ok,err=pcall(run);if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(a,b) assert(a:find(b,1,true),"missing "..b) end
local function link(id) return "|cffffffff|Hitem:"..id..":0:0:0:0:0:0:0:0|h[Linen Cloth]|h|r" end
local function item(id,quantity) return {name="Linen Cloth",itemID=id or 2589,quantity=quantity or 5,link=link(id or 2589)} end
local function session(options)
    options=options or {}
    local s={now=100,money=0,cod=0,items={},calls={},frames={},hooks={},counter=0,nativeSends=0,
        secret=setmetatable({}, {__tostring=function() error("secret stringify") end})}
    local ns={}
    local env=setmetatable({GetTime=function() return s.now end,
        issecretvalue=function(value) return rawequal(value,s.secret) end,
        GetSendMailMoney=function() if s.moneyError then error("restricted") end;return s.money end,
        GetSendMailCOD=function() return s.cod end,
        HasSendMailItem=function(slot)
            if s.hasError then error("restricted") end
            if s.hasSecret then return s.secret end
            return s.items[slot]~=nil
        end,
        GetSendMailItem=function(slot)
            if s.itemError then error("restricted") end
            local row=s.items[slot];if row then return row.name,row.itemID,1,row.quantity,1 end
        end,
        GetSendMailItemLink=function(slot)
            if s.linkError then error("restricted") end
            return s.items[slot] and s.items[slot].link
        end,
        SetSendMailMoney=function(value) s.money=value;return "setter-result" end,
        SetSendMailCOD=function(value) s.cod=value end,
        SendMail=function(recipient,subject,body,replyID)
            s.nativeSends=s.nativeSends+1;s.nativeArgs={recipient,subject,body,replyID}
            if s.duringSend then s:duringSend() end
            return "native-result",nil,"native-tail"
        end,
        ReturnInboxItem=function() error("observer returned mail") end,
        TakeInboxMoney=function() error("observer collected mail") end,
        SendChatMessage=function() error("observer sent chat") end,
        CreateFrame=function()
            local f={events={},scripts={}}
            function f:RegisterEvent(event) if options.registrationError then error("unsupported") end;self.events[event]=true end
            function f:UnregisterAllEvents() self.events={} end
            function f:SetScript(event,fn) self.scripts[event]=fn end
            s.frames[#s.frames+1]=f;return f
        end}, {__index=_G})
    env.hooksecurefunc=function(name,hook)
        if options.hookError then error("unsupported hook") end
        s.hooks[name]=(s.hooks[name] or 0)+1
        local original=env[name]
        local function pack(...) return {n=select("#",...),...} end
        env[name]=function(...)
            local values=pack(original(...));hook(...);return unpack(values,1,values.n)
        end
    end
    ns.PlayerSummary={NameKey=function(value)
        if s.nameError then error("identity unavailable") end
        if rawequal(value,s.secret) or type(value)~="string" or value=="" or value:find("[%z\001-\031\127|]") then return nil end
        return value:gsub(" +"," "):lower()
    end}
    ns.TradeService={NewSessionID=function(medium)
        equal(medium,"mail_sent")
        if s.reserveError then error("reservation failed") end
        if s.reserveFail then return nil,"unavailable" end
        if s.reserveSecret then return s.secret end
        s.counter=s.counter+1;return "ms-"..s.counter
    end,Record=function(value)
        if s.recordError then error("save failed") end
        s.calls[#s.calls+1]=value
        if s.recordFail then return nil,"failed" end
        return {id=value.id}
    end}
    local chunk=assert(loadstring(assert(IOU_SOURCES["mail_sent.lua"]),"@IOU/mail_sent.lua"))
    setfenv(chunk,env);chunk("IOU",ns)
    s.env,s.api,s.observer=env,ns,ns.MailSent
    function s:event(event,...)
        for _,f in ipairs(self.frames) do if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f,event,...) end end
    end
    function s:ready() assert(self.observer.Initialize());self:event("MAIL_SHOW") end
    function s:compose(amount)
        self.env.SetSendMailCOD(0);self.env.SetSendMailMoney(amount or self.money)
        self:event("MAIL_SEND_INFO_UPDATE")
    end
    function s:send(recipient) return self.env.SendMail(recipient or "Bjørn Vale","private subject","private body",7) end
    function s:success() self:event("MAIL_SEND_SUCCESS") end
    return s
end

test("sent mail counts successful outgoing gold immediately without collection",function()
    local s=session();s:ready();s:compose(50000);s:send("Jogge Bukser");equal(#s.calls,0);s:success()
    equal(#s.calls,1);local r=s.calls[1];equal(r.medium,"mail_sent");equal(r.peer,"Jogge Bukser")
    equal(r.outgoing.money,50000);equal(r.incoming.money,0);equal(#r.incoming.items,0)
    equal(r.subject,nil);equal(r.body,nil);equal(r.id,"ms-1")
end)
test("sent mail secure hooks preserve native function results and only observe sends",function()
    local s=session();s:ready();s:compose(500)
    local first,middle,last=s:send();equal(first,"native-result");equal(middle,nil);equal(last,"native-tail")
    equal(s.nativeSends,1);equal(s.nativeArgs[2],"private subject");equal(s.hooks.SendMail,1)
    equal(s.hooks.SetSendMailMoney,1);equal(s.hooks.SetSendMailCOD,1)
end)
test("sent mail uses actual SendMail recipient including surname and hyphens",function()
    local s=session();s:ready();s:compose(700);s:send("  Bjørn  Vale-Realm  ");s:success()
    equal(s.calls[1].peer,"  Bjørn  Vale-Realm  ")
end)
test("sent mail captures twelve attachments immutable before success UI reset",function()
    local s=session();s:ready();for slot=1,12 do s.items[slot]=item(2589+slot,slot) end
    s:compose(300);s:send();s.items={};s.money=0;s.cod=0;s:event("MAIL_SEND_INFO_UPDATE");s:success()
    equal(#s.calls,1);equal(#s.calls[1].outgoing.items,12);equal(s.calls[1].outgoing.items[12].quantity,12)
    equal(s.calls[1].outgoing.items[12].itemID,2601);equal(s.calls[1].outgoing.money,300)
end)
test("sent mail excludes postage from the transferred amount",function()
    local s=session();s.env.GetSendMailPrice=function() error("postage must not be consulted") end
    s:ready();s:compose(50000);s:send();s:success();equal(s.calls[1].outgoing.money,50000)
end)
test("sent mail compose click bag changes generic mail success never pay",function()
    local s=session();s:ready();s:compose(1000);s:event("MAIL_SUCCESS");s:event("BAG_UPDATE_DELAYED")
    s:success();equal(#s.calls,0);s:send();s:event("MAIL_SUCCESS");equal(#s.calls,0)
end)
test("sent mail failed attempt and duplicate terminal events cannot pay twice",function()
    local s=session();s:ready();s:compose(1000);s:send();s:event("MAIL_FAILED");s:success();equal(#s.calls,0)
    s:compose(900);s:send();s:success();s:success();s:event("MAIL_FAILED");equal(#s.calls,1)
end)
test("sent mail normal sequential sends receive distinct sessions",function()
    local s=session();s:ready();s:compose(100);s:send("One Player");s:success()
    s:compose(200);s:send("Two Players");s:success();equal(#s.calls,2)
    equal(s.calls[1].id,"ms-1");equal(s.calls[2].id,"ms-2");equal(s.calls[2].outgoing.money,200)
end)
test("sent mail overlapping attempts discard both ambiguous completions",function()
    local s=session();s:ready();s:compose(100);s:send();s:send("Other Person");s:success();s:success()
    equal(#s.calls,0);s:event("MAIL_CLOSED");s.now=s.now+5;s:event("MAIL_SHOW")
    s:compose(300);s:send();s:success();equal(#s.calls,1)
end)
test("sent mail abandoned overlapping sends recover after closure and expiry",function()
    local s=session();s:ready();s:compose(100);s:send();s:send("Other Person");s:event("MAIL_CLOSED")
    s.now=s.now+5;s.observer.Report();s.now=s.now+5;s:event("MAIL_SHOW")
    s:compose(300);s:send();s:success();equal(#s.calls,1);equal(s.calls[1].outgoing.money,300)
end)
test("sent mail closure keeps only a short immutable successful-send grace",function()
    local s=session();s:ready();s:compose(1000);s:send();s:event("MAIL_CLOSED")
    s.items={};s.money=0;s.now=s.now+2;s:success();equal(#s.calls,1);equal(s.calls[1].outgoing.money,1000)
    local late=session();late:ready();late:compose(1000);late:send();late:event("MAIL_CLOSED")
    late.now=late.now+5;late:success();equal(#late.calls,0)
end)
test("sent mail closed mailbox and logout cannot start or retain new repayment",function()
    local s=session();s:ready();s:compose(1000);s:event("MAIL_CLOSED");s:send();s:success();equal(#s.calls,0)
    local out=session();out:ready();out:compose(2000);out:send();out:event("PLAYER_LOGOUT");out:success();equal(#out.calls,0)
end)
test("sent mail stale pending attempt blocks replacement until mailbox reopen",function()
    local s=session();s:ready();s:compose(1000);s:send();s.now=s.now+61
    s:compose(2000);s:send();s:success();equal(#s.calls,0)
    s:event("MAIL_CLOSED");s.now=s.now+5;s:event("MAIL_SHOW");s:compose(3000);s:send();s:success()
    equal(#s.calls,1);equal(s.calls[1].outgoing.money,3000)
end)
test("sent mail excludes COD and ordinary letters",function()
    for _,cod in ipairs({1000,math.huge}) do
        local s=session();s:ready();s.items[1]=item();s:compose(0);s.env.SetSendMailCOD(cod);s:send();s:success();equal(#s.calls,0)
    end
    local letter=session();letter:ready();letter:compose(0);letter:send();letter:success();equal(#letter.calls,0)
end)
test("sent mail returned system and inbox events have no send attribution",function()
    local s=session();s:ready();s.money=5000;s.items[1]=item()
    for _,event in ipairs({"MAIL_SUCCESS","MAIL_FAILED","MAIL_INBOX_UPDATE","CLOSE_INBOX_ITEM","MAIL_SEND_SUCCESS"}) do s:event(event) end
    equal(#s.calls,0);equal(s.counter,0)
end)
test("sent mail requires a stable cached draft before the native send",function()
    local s=session();s:ready();s:compose(100);s.money=900;s:send();s:success();equal(#s.calls,0)
    local mutation=session();mutation:ready();mutation.items[1]=item();mutation:compose(0)
    mutation.duringSend=function(self) self.items[1].quantity=10 end
    mutation:send();mutation:success();equal(#mutation.calls,0)
end)
test("sent mail synchronous success before the posthook fails closed",function()
    local s=session();s:ready();s:compose(100);s.duringSend=function(self) self:success() end
    s:send();s:success();equal(#s.calls,0)
end)
test("sent mail unreadable recipient money COD and clock fail closed",function()
    for _,field in ipairs({"money","cod","now"}) do
        local s=session();s:ready();s:compose(100);s[field]=s.secret;s:send();s:success();equal(#s.calls,0)
    end
    for _,recipient in ipairs({"","Bad|Name",string.rep("x",97)}) do
        local s=session();s:ready();s:compose(100);s:send(recipient);s:success();equal(#s.calls,0)
    end
    local secret=session();secret:ready();secret:compose(100);secret:send(secret.secret);secret:success();equal(#secret.calls,0)
end)
test("sent mail secret attachment fields reject the whole transfer",function()
    for _,field in ipairs({"name","itemID","quantity","link"}) do
        local s=session();s:ready();s.items[1]=item();s.items[1][field]=s.secret;s:compose(1000);s:send();s:success();equal(#s.calls,0)
    end
    local s=session();s:ready();s.hasSecret=true;s:compose(100);s:send();s:success();equal(#s.calls,0)
end)
test("sent mail missing cached or inconsistent item APIs never partly pay gold",function()
    for _,row in ipairs({{name="Linen Cloth",itemID=2589,quantity=1},
        {name="Linen Cloth",itemID=2589,quantity=0,link=link(2589)},
        {name="Linen Cloth",itemID=2592,quantity=1,link=link(2589)}}) do
        local s=session();s:ready();s.items[1]=row;s:compose(1000);s:send();s:success();equal(#s.calls,0)
    end
    local s=session();s:ready();s.env.HasSendMailItem=function() return false end;s.items[1]=item()
    s:compose(1000);s:send();s:success();equal(#s.calls,0)
end)
test("sent mail nil empty-slot compatibility still requires fully empty attachment fields",function()
    local s=session();s:ready();s.env.HasSendMailItem=function(slot) if s.items[slot] then return 1 end end
    s.items[12]=item();s:compose(1000);s:send();s:success();equal(#s.calls,1);equal(#s.calls[1].outgoing.items,1)
    local bad=session();bad:ready();bad.env.HasSendMailItem=function() return nil end;bad.items[12]=item()
    bad:compose(1000);bad:send();bad:success();equal(#bad.calls,0)
end)
test("sent mail unexpected public callback errors cannot break native sends",function()
    local s=session();s:ready();s:compose(1000)
    s.api.PlayerSummary=setmetatable({}, {__index=function() error("unexpected identity adapter") end})
    local result=s:send();equal(result,"native-result");s:success();equal(#s.calls,0)
    contains(s.observer.Report(),"observation was interrupted")
end)
test("sent mail thrown observation identity and reservation APIs fail closed",function()
    for _,flag in ipairs({"moneyError","itemError","hasError","linkError","nameError","reserveError","reserveFail","reserveSecret"}) do
        local s=session();s:ready();s[flag]=true;s:compose(100);s:send();s:success();equal(#s.calls,0)
    end
end)
test("sent mail recorder failure does not retry or resubmit on duplicate success",function()
    local s=session();s:ready();s.recordFail=true;s:compose(100);s:send();s:success();s.recordFail=false;s:success()
    equal(#s.calls,1);contains(s.observer.Report(),"recorder failures: 1")
    local thrown=session();thrown:ready();thrown.recordError=true;thrown:compose(100);thrown:send();thrown:success()
    thrown.recordError=false;thrown:success();equal(#thrown.calls,0)
end)
test("sent mail initialization is idempotent and unavailable hooks remain inert",function()
    local s=session();assert(s.observer.Initialize());assert(s.observer.Initialize());equal(#s.frames,1);equal(s.hooks.SendMail,1)
    for _,options in ipairs({{registrationError=true},{hookError=true}}) do
        local bad=session(options);equal(bad.observer.Initialize(),nil);bad:event("MAIL_SHOW");bad:send();bad:success();equal(#bad.calls,0)
    end
end)

return results
