-- Real financial core and Activity sidecar; all transfers are synthetic.
local support=assert(IOU_TEST_SUPPORT)
local results={}
local function test(name,run)
    local ok,err=pcall(run)
    if not ok then error(name..": "..tostring(err),0) end
    results[#results+1]=name
end
local function equal(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function side(money,items) return {money=money or 0,items=items or {}} end
local function item(quantity,id)
    return {itemID=id or 2589,quantity=quantity or 2,name="Linen Cloth",
        link="|cffffffff|Hitem:"..(id or 2589)..":0:0:0|h[Linen Cloth]|h|r"}
end
local function session(options)
    local state=support.Session(options or {})
    local api=state.api
    assert(api.Initialize()); assert(api.SharedService.Initialize()); assert(api.TradeService.Initialize())
    return state,api,api.TradeService
end
local function add(api,direction,kind,amount,label)
    return assert(api.Add({player="Birch Vale",direction=direction or "owe",kind=kind or "money",
        amount=amount or 100000,label=label or "",note="",due=0}))
end
local function balance(api,id) return api.Ledger.Balance(assert(api.Ledger.Get(api.GetLedger(),id))) end
local function transfer(S,medium,incoming,outgoing)
    return {id=assert(S.NewSessionID(medium)),medium=medium,peer="Birch Vale",
        incoming=incoming or side(),outgoing=outgoing or side()}
end

test("mail send success evidence repays the sender immediately without collection or peer messages",function()
    local state,api,S=session(); add(api)
    local data=transfer(S,"mail_sent",nil,side(50000))
    local r=assert(S.Record(data)); equal(r.medium,"mail_sent"); equal(r.status,"applied")
    equal(balance(api,1),50000); equal(#state.transportSent,0)
    equal(api.GetLedger().entries[1].events[1].note,"Mail "..r.id)
    assert(S.Record(data)); equal(balance(api,1),50000)
    assert(S.Undo(r.id)); equal(balance(api,1),100000)
end)

test("mail collection repays only the incoming direction",function()
    local _,api,S=session(); add(api,"owed"); add(api,"owe")
    local r=assert(S.Record(transfer(S,"mail_received",side(25000))))
    equal(balance(api,1),75000); equal(balance(api,2),100000)
    assert(S.Undo(r.id)); equal(balance(api,1),100000)
end)

test("mail and trade reservation channels do not supersede one another",function()
    local _,api,S=session(); add(api,"owed")
    local trade=transfer(S,nil,side(1000)); local send=transfer(S,"mail_sent",nil,side(1000))
    local receive=transfer(S,"mail_received",side(1000))
    assert(S.Record(trade)); assert(S.Record(send)); assert(S.Record(receive))
    equal(#assert(S.List()),3); equal(balance(api,1),98000)
end)

test("mail automatic preference is independent of trade preference",function()
    local _,api,S=session(); add(api)
    api.GetSettings().autoMailRepayments=false
    local r=assert(S.Record(transfer(S,"mail_sent",nil,side(1000))))
    equal(r.status,"review"); equal(balance(api,1),100000)
    assert(S.Resolve(r.id,1,nil,1)); equal(balance(api,1),99000)
    api.GetSettings().autoMailRepayments=true; api.GetSettings().autoTradeRepayments=false
    assert(S.Record(transfer(S,"mail_sent",nil,side(1000)))); equal(balance(api,1),98000)
end)

test("mail supports twelve attachments while trade keeps its six-slot bound",function()
    local _,api,S=session(); add(api,"owe","item",30,"Linen Cloth")
    local items={}; for index=1,12 do items[index]=item(1) end
    local r=assert(S.Record(transfer(S,"mail_sent",nil,side(0,items))))
    equal(balance(api,1),18); equal(#r.applications,1); equal(r.applications[1].amount,12)
    equal(S.Record(transfer(S,nil,nil,side(0,items))),nil)
    items[13]=item(1); equal(S.Record(transfer(S,"mail_sent",nil,side(0,items))),nil)
end)

test("mail source and one-way direction are validated before a financial change",function()
    local _,api,S=session(); add(api)
    equal(S.NewSessionID("mail_unknown"),nil)
    local before=assert(api.Export())
    equal(S.Record(transfer(S,"mail_sent",side(1),side(1000))),nil)
    equal(S.Record(transfer(S,"mail_received",side(1000),side(1))),nil)
    local data=transfer(S,"mail_sent",nil,side(1000)); data.service=true
    equal(S.Record(data),nil); equal(assert(api.Export()),before)
end)

test("legacy 0.8 trade receipts stay valid without optional medium or captures fields",function()
    local state,api,S=session(); add(api,"owed")
    local r=assert(S.Record(transfer(S,nil,side(1000))))
    local saved=state.env.IOUDB.tradesByCharacter[api.Character()]
    saved.receipts[1].medium=nil; equal(saved.receipts[1].captures,nil)
    assert(S.Validate(saved)); assert(S.Undo(r.id)); equal(balance(api,1),100000)
end)

test("ordinary unmatched mail stays activity until explicitly tracked as a loan",function()
    local _,api,S=session()
    local r=assert(S.Record(transfer(S,"mail_sent",nil,side(50000))))
    equal(r.status,"unmatched"); equal(#api.GetLedger().entries,0)
    r=assert(S.Capture(r.id,1,support.Copy(r.unmatched[1])))
    equal(r.status,"captured"); equal(#r.unmatched,0); equal(#r.captures,1)
    local e=api.GetLedger().entries[1]
    equal(e.direction,"owed"); equal(e.player,"Birch Vale"); equal(e.amount,50000)
    equal(r.captures[1].direction,"owe"); equal(r.captures[1].loanDirection,"owed")
    equal(S.Capture(r.id,1),nil); equal(#api.GetLedger().entries,1)
end)

test("tracking incoming items creates an owed-by-me IOU with the exact observed link",function()
    local _,api,S=session(); local raw=item(7)
    local r=assert(S.Record(transfer(S,"mail_received",side(0,{raw}))))
    r=assert(S.Capture(r.id,1,r.unmatched[1]))
    local e=api.GetLedger().entries[1]
    equal(e.direction,"owe"); equal(e.amount,7); equal(e.kind,"item"); equal(e.label,raw.link)
    equal(r.captures[1].label,raw.link); assert(S.Validate({version=1,counter=1,receipts={r}}))
end)

test("tracking trade assets uses the same explicit loan flow",function()
    local _,api,S=session()
    local r=assert(S.Record(transfer(S,nil,nil,side(1234))))
    assert(S.Capture(r.id,1)); equal(api.GetLedger().entries[1].direction,"owed")
    equal(api.GetLedger().entries[1].amount,1234)
end)

test("tracking rejects a stale shifted asset choice without creating another debt",function()
    local _,api,S=session()
    local r=assert(S.Record(transfer(S,"mail_sent",nil,side(3000,{item()}))))
    local old=support.Copy(r.unmatched[1]); assert(S.Capture(r.id,1,old))
    local before=assert(api.Export()); equal(S.Capture(r.id,1,old),nil)
    equal(assert(api.Export()),before); equal(#api.GetLedger().entries,1)
end)

test("capture and repayments remain separate when Undo reverses a partially matched transfer",function()
    local _,api,S=session(); add(api,"owed","money",3000)
    local r=assert(S.Record(transfer(S,"mail_received",side(5000))))
    equal(balance(api,1),0); r=assert(S.Capture(r.id,1))
    equal(balance(api,2),2000); equal(api.GetLedger().entries[2].direction,"owe")
    assert(S.Undo(r.id)); equal(balance(api,1),3000); equal(balance(api,2),2000)
end)

test("failed capture commit leaves both ledger and receipt unchanged",function()
    local _,api,S=session(); local r=assert(S.Record(transfer(S,"mail_sent",nil,side(1000))))
    local before,receipt=assert(api.Export()),assert(S.Get(r.id))
    local original=api.CommitTradeState; api.CommitTradeState=function() return nil,"Synthetic storage failure" end
    equal(S.Capture(r.id,1),nil); api.CommitTradeState=original
    equal(assert(api.Export()),before); assert(support.Same(assert(S.Get(r.id)),receipt))
end)

test("captured receipts persist across reload and do not offer their asset twice",function()
    local state,api,S=session(); local r=assert(S.Record(transfer(S,"mail_sent",nil,side(1000))))
    assert(S.Capture(r.id,1))
    local _,reloaded,R=session({db=state.env.IOUDB})
    equal(#assert(R.Get(r.id)).captures,1); equal(R.Capture(r.id,1),nil)
    equal(#reloaded.GetLedger().entries,1)
end)

return results
