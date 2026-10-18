-- Real mail observers, financial core and Activity storage; native APIs below
-- are inert synthetic functions. No actual send or collection is performed.
local support=assert(IOU_TEST_SUPPORT,"Run through tools/test_iou.py.")
local results={}
local function test(name,run)
    local ok,err=pcall(run);if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function link(id) return "|cffffffff|Hitem:"..(id or 2589)..":0:0:0:0:0:0:0:0|h[Linen Cloth]|h|r" end
local function item(quantity,id)
    return {name="Linen Cloth",itemID=id or 2589,quantity=quantity or 3,link=link(id)}
end
local function mail(options)
    local row={sender="Birch Vale",subject="Synthetic materials",money=0,cod=0,days=29.9,
        stationery=61,reply=true,returned=false,gm=false,items={}}
    for key,value in pairs(options or {}) do row[key]=value end
    return row
end
local function session(options)
    options=options or {};options.mail=true;options.name="Amber";options.fullName="Amber Stone"
    local state=support.Session(options)
    local env,api=state.env,state.api
    local m={state=state,env=env,api=api,service=api.TradeService,money=0,cod=0,attachments={},mails={},native={}}
    env.GetSendMailMoney=function() return m.money end
    env.GetSendMailCOD=function() return m.cod end
    env.SetSendMailMoney=function(value) m.money=value;return "synthetic setter" end
    env.SetSendMailCOD=function(value) m.cod=value end
    env.HasSendMailItem=function(slot) return m.attachments[slot]~=nil end
    env.GetSendMailItem=function(slot)
        local row=m.attachments[slot];if row then return row.name,row.itemID,1,row.quantity,1 end
    end
    env.GetSendMailItemLink=function(slot) return m.attachments[slot] and m.attachments[slot].link end
    env.GetSendMailPrice=function() error("repayment must exclude postage") end
    env.SendMail=function(recipient,subject,body)
        m.native[#m.native+1]={kind="send",peer=recipient};return "synthetic send",nil,"tail"
    end
    env.GetInboxNumItems=function() return #m.mails,#m.mails end
    env.GetInboxHeaderInfo=function(index)
        local row=m.mails[index];if not row then return end
        local count=0;for _ in pairs(row.items) do count=count+1 end
        return row.package,row.stationery,row.sender,row.subject,row.money,row.cod,row.days,
            count>0 and count or nil,row.read,row.returned,false,row.reply,row.gm
    end
    env.GetInboxItem=function(index,slot)
        local row=m.mails[index] and m.mails[index].items[slot]
        if row then return row.name,row.itemID,1,row.quantity,1,true,row.currency end
    end
    env.GetInboxItemLink=function(index,slot)
        local row=m.mails[index] and m.mails[index].items[slot];return row and row.link
    end
    env.GetInboxInvoiceInfo=function(index) return m.mails[index] and m.mails[index].invoice end
    for _,name in ipairs({"TakeInboxMoney","TakeInboxItem","AutoLootMailItem"}) do
        local operation=name
        env[operation]=function(index,slot)
            m.native[#m.native+1]={kind=operation,index=index,slot=slot};return "synthetic collection"
        end
    end
    for _,name in ipairs({"DeleteInboxItem","ReturnInboxItem","TakeInboxTextItem","CloseMail",
        "GetInboxText","SendChatMessage","AcceptTrade"}) do
        local operation=name;env[operation]=function() error("unexpected native action: "..operation) end
    end
    assert(api.Initialize());assert(api.SharedService.Initialize());assert(api.TradeService.Initialize())
    assert(api.MailSent.Initialize());assert(api.MailReceived.Initialize())
    function m:event(event,...) self.state.event(event,...) end
    function m:open() self:event("MAIL_SHOW") end
    function m:compose(amount,attachments)
        self.attachments=attachments or {};self.env.SetSendMailCOD(0);self.env.SetSendMailMoney(amount or 0)
        self:event("MAIL_SEND_INFO_UPDATE")
    end
    function m:send(peer) return self.env.SendMail(peer or "Birch Vale","Synthetic subject","Synthetic body") end
    m:open()
    return m,api,api.TradeService
end
local function add(api,direction,kind,amount,label,player)
    return assert(api.Add({player=player or "Birch Vale",direction=direction or "owe",kind=kind or "money",
        amount=amount or 10000,label=label or "",note="",due=0}))
end
local function balance(api,id) return assert(api.Ledger.Balance(assert(api.Ledger.Get(api.GetLedger(),id)))) end
local function list(S) return assert(S.List()) end

test("mail integration sent success commits gold and exact crafting items atomically",function()
    local m,api,S=session();local gold=add(api,"owe","money",100000)
    local material=add(api,"owe","item",10,link());local opposite=add(api,"owed","money",50000)
    m:compose(50000,{item(3)});local first,middle,last=m:send()
    equal(first,"synthetic send");equal(middle,nil);equal(last,"tail")
    equal(balance(api,gold.id),100000);equal(balance(api,material.id),10);equal(#list(S),0)
    m:event("MAIL_SEND_SUCCESS");local r=list(S)[1]
    equal(r.medium,"mail_sent");equal(r.status,"applied");equal(#r.applications,2)
    equal(balance(api,gold.id),50000);equal(balance(api,material.id),7);equal(balance(api,opposite.id),50000)
    equal(api.GetLedger().entries[gold.id].events[1].note,"Mail "..r.id)
    equal(#m.state.transportSent,0);equal(#m.native,1)
end)
test("mail integration clicks failure generic success and duplicate send success do not repay",function()
    local m,api,S=session();add(api,"owe","money",100000);local before=assert(api.Export())
    m:compose(25000);m:event("MAIL_SUCCESS");m:event("MAIL_SEND_SUCCESS")
    equal(assert(api.Export()),before);equal(#list(S),0)
    m:compose(25000);m:send();m:event("MAIL_FAILED");m:event("MAIL_SEND_SUCCESS")
    equal(assert(api.Export()),before);equal(#list(S),0)
    m:compose(25000);m:send();m:event("MAIL_SEND_SUCCESS");local after=assert(api.Export())
    m:event("MAIL_SEND_SUCCESS");m:event("MAIL_SUCCESS");equal(assert(api.Export()),after)
    equal(balance(api,1),75000);equal(#list(S),1)
end)
test("mail integration sent receipt Undo restores gold and items once",function()
    local m,api,S=session();add(api,"owe","money",100000);add(api,"owe","item",10,"Linen Cloth")
    m:compose(50000,{item(3)});m:send();m:event("MAIL_SEND_SUCCESS");local r=list(S)[1]
    assert(S.Undo(r.id));equal(balance(api,1),100000);equal(balance(api,2),10)
    local before=assert(api.Export());assert(S.Undo(r.id));m:event("MAIL_SEND_SUCCESS")
    equal(assert(api.Export()),before);equal(#list(S),1);equal(list(S)[1].status,"undone")
end)
test("mail integration unmatched sent assets create IOUs only after Track loan",function()
    local m,api,S=session();m:compose(25000,{item(4)});m:send();m:event("MAIL_SEND_SUCCESS")
    local r=list(S)[1];equal(r.status,"unmatched");equal(#r.unmatched,2);equal(#api.GetLedger().entries,0)
    r=assert(S.Capture(r.id,1));equal(#api.GetLedger().entries,1)
    r=assert(S.Capture(r.id,1));equal(r.status,"captured");equal(#api.GetLedger().entries,2)
    equal(api.GetLedger().entries[1].direction,"owed");equal(api.GetLedger().entries[2].direction,"owed")
    equal(api.GetLedger().entries[1].player,"Birch Vale");equal(#r.captures,2)
    equal(S.Capture(r.id,1),nil);equal(#api.GetLedger().entries,2)
end)
test("mail integration outgoing identity is exact and COD never changes debts",function()
    local m,api,S=session();add(api,"owe","money",100000)
    m:compose(50000);m:send("Birch Other");m:event("MAIL_SEND_SUCCESS")
    equal(balance(api,1),100000);equal(list(S)[1].status,"unmatched")
    m:compose(0,{item(3)});m.env.SetSendMailCOD(50000);m:send();m:event("MAIL_SEND_SUCCESS")
    equal(balance(api,1),100000);equal(#list(S),1)
end)
test("mail integration one mail can repay twelve stacks while retaining excess",function()
    local m,api,S=session();add(api,"owe","item",10,link())
    local attachments={};for slot=1,12 do attachments[slot]=item(1) end
    m:compose(0,attachments);m:send();m:event("MAIL_SEND_SUCCESS")
    local r=list(S)[1];equal(#r.outgoing.items,12);equal(balance(api,1),0)
    equal(r.applications[1].amount,10);equal(r.unmatched[1].amount,2)
end)
test("mail integration collected gold needs native collection exact delta and MAIL_SUCCESS",function()
    local m,api,S=session();add(api,"owed","money",100000);add(api,"owe","money",100000)
    m.mails={mail({money=50000})};m:event("MAIL_INBOX_UPDATE");m:event("MAIL_SUCCESS")
    equal(balance(api,1),100000);equal(#list(S),0)
    equal(m.env.TakeInboxMoney(1),"synthetic collection");m.mails[1].money=0;m:event("MAIL_INBOX_UPDATE")
    equal(balance(api,1),100000);m:event("MAIL_SUCCESS")
    local r=list(S)[1];equal(r.medium,"mail_received");equal(balance(api,1),50000);equal(balance(api,2),100000)
    m:event("MAIL_SUCCESS");m:event("MAIL_INBOX_UPDATE");equal(#list(S),1)
    assert(S.Undo(r.id));equal(balance(api,1),100000);equal(#m.state.transportSent,0)
end)
test("mail integration collected item uses the retained native item identity",function()
    local m,api,S=session();add(api,"owed","item",10,link())
    m.mails={mail({items={[4]=item(3)}})};m:event("MAIL_INBOX_UPDATE")
    m.env.TakeInboxItem(1,4);m.mails[1].items[4]=nil;m:event("MAIL_SUCCESS",2589);m:event("MAIL_INBOX_UPDATE")
    local r=list(S)[1];equal(r.medium,"mail_received");equal(r.incoming.items[1].link,link())
    equal(balance(api,1),7);assert(S.Undo(r.id));equal(balance(api,1),10)
end)
test("mail integration failed or system collection cannot pay a personal IOU",function()
    local m,api,S=session();add(api,"owed","money",100000)
    m.mails={mail({money=50000})};m:event("MAIL_INBOX_UPDATE");m.env.TakeInboxMoney(1)
    m:event("MAIL_FAILED");m.mails[1].money=0;m:event("MAIL_INBOX_UPDATE");m:event("MAIL_SUCCESS")
    equal(balance(api,1),100000);equal(#list(S),0)
    m.state.now=m.state.now+10;m.mails={mail({money=50000,reply=false})};m:event("MAIL_INBOX_UPDATE")
    m.env.TakeInboxMoney(1);m.mails[1].money=0;m:event("MAIL_INBOX_UPDATE");m:event("MAIL_SUCCESS")
    equal(balance(api,1),100000);equal(#list(S),0)
end)
test("mail integration outgoing reservation survives an independent incoming receipt",function()
    local m,api,S=session();add(api,"owe","money",100000);add(api,"owed","money",100000)
    m:compose(25000);m:send();m.mails={mail({money=30000})};m:event("MAIL_INBOX_UPDATE")
    m.env.TakeInboxMoney(1);m.mails[1].money=0;m:event("MAIL_INBOX_UPDATE");m:event("MAIL_SUCCESS")
    equal(balance(api,2),70000);equal(balance(api,1),100000)
    m:event("MAIL_SEND_SUCCESS");equal(balance(api,1),75000);equal(#list(S),2)
    equal(list(S)[1].medium,"mail_sent");equal(list(S)[2].medium,"mail_received")
end)

test("mail integration native named-color materials repay through send and collection",function()
    local native="|cnIQ1:|Hitem:2589:0:0:0:0:0:0:0:13|h[Linen Cloth]|h|r"
    local m,api,S=session();local debt=add(api,"owe","item",5,native)
    local row=item(2);row.link=native
    m:compose(0,{row});m:send();m:event("MAIL_SEND_SUCCESS")
    equal(balance(api,debt.id),3);equal(list(S)[1].outgoing.items[1].link,native)
    local owed=add(api,"owed","item",5,native)
    m.mails={mail({items={[1]=row}})};m:event("MAIL_INBOX_UPDATE")
    m.env.TakeInboxItem(1,1);m.mails[1].items[1]=nil
    m:event("MAIL_SUCCESS");m:event("MAIL_INBOX_UPDATE")
    equal(balance(api,owed.id),3);equal(#list(S),2)
    equal(list(S)[1].incoming.items[1].link,native)
end)

return results
