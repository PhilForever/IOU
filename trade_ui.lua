local _, IOU = ...
local UI = IOU.UI
if not UI or not UI.Helpers then return end
local H = UI.Helpers
local GOLD, MUTED = {0.88,0.73,0.42}, {0.65,0.66,0.63}
local PAGE_SIZE, CHOICES = 5, 3
local statuses = {applied="Applied",review="Choose an IOU",unmatched="No matching IOU",
    undone="Undone",ignored="Dismissed",captured="Tracked as IOU"}
local reasons={mixed_trade="An exchange: balances unchanged.",trade_service="Trade included a service: balances unchanged.",
    shared_unavailable="Shared records unavailable; balances unchanged.",item_identity="Item identity needs checking.",
    item_ambiguous="Choose the item IOU repaid.",source_conflict="Personal and Shared records may overlap.",
    shared_confirmation="Shared repayments still need confirmation.",multiple_ious="Choose the IOU repaid.",
    automatic_off="Automatic repayment is off. Apply only if repayment.",
    ledger_changed="This IOU needs checking before repayment."}
local choiceReasons={mixed_trade="Both sides gave something. Apply only if repayment.",
    trade_service="Includes a service. Apply only if repayment.",
    item_identity="Different item variant. Apply only if it repays this IOU.",
    item_ambiguous="Item name matches multiple variants. Choose carefully.",
    source_conflict="Personal and Shared records may overlap. Choose only one.",
    automatic_off="Automatic repayment is off. Choose an IOU to apply.",
    ledger_changed="Balance changed. Check the IOU before applying."}

local function text(value)
    local raw = tostring(value or ""):gsub("|Hitem:[^|]+|h(%[[^|]+%])|h", "%1")
    raw = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        :gsub("[%z\001-\031\127]", " "):gsub("%s+", " ")
    return H.literal(raw)
end
local function label(value,maximum)
    local raw = tostring(value or ""):gsub("|Hitem:[^|]+|h(%[[^|]+%])|h", "%1")
    raw = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        :gsub("[%z\001-\031\127]", " "):gsub("%s+", " ")
    local limit = maximum or 72
    if #raw > limit then
        while limit > 0 and (raw:byte(limit+1) or 0) >= 128 and (raw:byte(limit+1) or 0) <= 191 do limit=limit-1 end
        raw=raw:sub(1,limit).."..."
    end
    return H.literal(raw)
end
local function amount(kind, value, name,maximum)
    if kind == "money" then return H.money(value or 0) end
    return tostring(value or 0).." x "..label(name ~= "" and name or "Item",maximum)
end
local function assets(value)
    value=type(value)=="table" and value or {}
    local parts, money = {}, value.money or value.copper or 0
    if money > 0 then parts[#parts+1]=H.money(money) end
    for _,item in ipairs(value.items or {}) do
        parts[#parts+1]=amount("item",item.quantity or item.count,item.label or item.name)
    end
    return #parts>0 and table.concat(parts,", ") or "Nothing"
end
local function service()
    return type(IOU.TradeService)=="table" and IOU.TradeService or nil
end
local function call(name,...)
    local s=service()
    if not s or type(s[name])~="function" then return nil,"Activity is unavailable." end
    local ok,value,err=pcall(s[name],...)
    if not ok then return nil,"Could not update this activity. Try again." end
    return value,err
end
local function source(receipt)
    if receipt.medium=="mail_sent" then return "Mail sent" end
    if receipt.medium=="mail_received" then return "Mail collected" end
    return "Trade"
end
local function loanDirection(value)
    return value.loanDirection or (value.direction=="owe" and "owed" or "owe")
end
local function debt(value,direction)
    return (direction=="owed" and "Owes you " or "You owe ")..amount(value.asset,value.amount,value.label,40)
end
local function sameAsset(a,b)
    return a and b and a.direction==b.direction and a.asset==b.asset and a.amount==b.amount
        and a.label==b.label and a.itemID==b.itemID and a.itemKey==b.itemKey
end
local function captureSnapshot(rows)
    local result={}
    for index,row in ipairs(rows or {}) do
        result[index]={direction=row.direction,asset=row.asset,amount=row.amount,
            label=row.label,itemID=row.itemID,itemKey=row.itemKey}
    end
    return result
end
local function dateLabel(at)
    if type(at)~="number" then return "" end
    local ok,value=pcall(date,"%d %b, %H:%M",at)
    return ok and value or ""
end
local function choices(receipt,ledger)
    local rows, shared, changed={},false,false
    ledger=ledger or (type(IOU.GetLedger)=="function" and IOU.GetLedger())
    local L,Summary=IOU.Ledger,IOU.PlayerSummary
    local peerKey=Summary and Summary.NameKey(receipt.peer)
    for pendingIndex,pending in ipairs(receipt.pending or {}) do
        for _,candidate in ipairs(pending.candidates or {}) do
            if candidate.source=="shared" then shared=true
            elseif candidate.source=="personal" and candidate.entryID then
                local entry=L.Get(ledger,candidate.entryID)
                local balance=entry and L.Balance(entry)
                local valid=entry and peerKey and Summary.NameKey(entry.player)==peerKey
                    and entry.direction==pending.direction and entry.kind==pending.asset
                    and (entry.kind~="item" or entry.label==candidate.label)
                    and type(balance)=="number" and balance>0 and L.Status(entry)~="cancelled"
                if valid then
                    rows[#rows+1]={entryID=candidate.entryID,pendingIndex=pendingIndex,
                        pending=pending,candidate=candidate,entry=entry,balance=balance,
                        amount=math.min(balance,pending.amount)}
                else changed=true end
            end
        end
    end
    return rows,shared,changed
end
local function sameChoice(a,b)
    return a and b and a.entryID==b.entryID and a.pendingIndex==b.pendingIndex
        and a.balance==b.balance and a.amount==b.amount and a.candidate.label==b.candidate.label
        and a.pending.asset==b.pending.asset and a.pending.direction==b.pending.direction
        and a.pending.amount==b.pending.amount and a.pending.label==b.pending.label
        and a.pending.itemKey==b.pending.itemKey and a.pending.reason==b.pending.reason
end
local refresh
local function showResult(f,value,err)
    f.message:SetText(value and "" or text(err or "This activity changed. Review it again."))
    refresh(f)
end
local function createActivity()
    local f=H.window("IOUTradeActivity",780,566)
    UI.tradeActivity=f
    f.page,f.choicePage=1,1
    H.font(f,23,22,-22,690,"Activity",GOLD)
    f.empty=H.font(f,12,24,-78,230,"")
    f.rows={}
    for index=1,PAGE_SIZE do
        local row=H.button(f,"",242,22,-76-(index-1)*76,function(self)
            if not self.receiptID then return end
            f.selected,f.choice,f.captureChoice,f.choicePage,f.mode=self.receiptID,nil,nil,1,nil
            f.message:SetText("");f.scroll:SetVerticalScroll(0);refresh(f)
        end)
        row:SetHeight(66)
        row.peer=H.font(row,13,10,-9,222,"",GOLD)
        row.status=H.font(row,11,10,-31,222,"",MUTED)
        row.when=H.font(row,10,10,-47,222,"",MUTED)
        f.rows[index]=row
    end
    f.previous=H.button(f,"<",30,22,-472,function()
        f.page=f.page-1;f.selected=nil;f.choice=nil;f.captureChoice=nil;f.mode=nil;f.choicePage=1;f.scroll:SetVerticalScroll(0);refresh(f)
    end)
    f.pages=H.font(f,11,62,-480,152,"")
    f.next=H.button(f,">",30,234,-472,function()
        f.page=f.page+1;f.selected=nil;f.choice=nil;f.captureChoice=nil;f.mode=nil;f.choicePage=1;f.scroll:SetVerticalScroll(0);refresh(f)
    end)
    local detail=H.panel(f,470,394,286,-76)
    f.scroll,f.content=H.scroll(detail,426,166,14,-12)
    f.summary=H.font(f.content,12,0,0,420,"")
    f.repayMode=H.button(detail,"Repay IOU",132,14,-178,function()
        f.mode="repay";f.choicePage=1;f.choice=nil;f.captureChoice=nil;refresh(f)
    end)
    f.captureMode=H.button(detail,"Track new IOU",132,154,-178,function()
        f.mode="capture";f.choicePage=1;f.choice=nil;f.captureChoice=nil;refresh(f)
    end)
    f.pendingText=H.font(detail,12,14,-204,438,"",GOLD)
    f.pendingText:SetHeight(30);f.pendingText:SetMaxLines(2)
    f.candidates={}
    for index=1,CHOICES do
        local row=H.button(detail,"",438,14,-240-(index-1)*42,function(self)
            if self.capture then f.captureChoice=self.capture
            elseif self.choice then f.choice=self.choice
            else return end
            refresh(f)
        end)
        row:SetHeight(36)
        f.candidates[index]=row
    end
    f.choicePrevious=H.button(detail,"<",30,14,-366,function() f.choicePage=f.choicePage-1;f.choice=nil;f.captureChoice=nil;refresh(f) end)
    f.choicePages=H.font(detail,11,54,-374,190,"")
    f.choiceNext=H.button(detail,">",30,250,-366,function() f.choicePage=f.choicePage+1;f.choice=nil;f.captureChoice=nil;refresh(f) end)
    f.apply=H.button(f,"Apply repayment",156,286,-480,function()
        local c=f.choice
        if not c then return end
        local receipt=call("Get",f.selected)
        local current
        if receipt then
            for _,row in ipairs(choices(receipt)) do
                if row.entryID==c.entryID and row.pendingIndex==c.pendingIndex then current=row;break end
            end
        end
        if not sameChoice(current,c) then
            f.choice=nil;f.message:SetText("This IOU or trade changed. Choose it again.");refresh(f);return
        end
        local value,err=call("Resolve",f.selected,c.entryID,c.amount,c.pendingIndex)
        f.choice=nil;showResult(f,value,err)
    end)
    f.capture=H.button(f,"Track as IOU",156,286,-480,function()
        local c=f.captureChoice
        if not c then return end
        local receipt=call("Get",f.selected)
        local current=receipt and receipt.unmatched and receipt.unmatched[c.index]
        if not sameAsset(current,c.asset) then
            f.captureChoice=nil;f.message:SetText("This activity changed. Choose the asset again.");refresh(f);return
        end
        local value,err=call("Capture",f.selected,c.index,c.asset)
        f.captureChoice=nil;showResult(f,value,err)
    end)
    f.shared=H.button(f,"Shared requests",144,286,-480,function()
        local receipt=call("Get",f.selected)
        if receipt and type(IOU.ShowShared)=="function" then IOU.ShowShared(receipt.peer) end
    end)
    f.records=H.button(f,"View IOUs",144,286,-480,function()
        local receipt=call("Get",f.selected)
        if receipt and type(IOU.ShowPlayerRecords)=="function" then IOU.ShowPlayerRecords(receipt.peer) end
    end)
    f.undo=H.button(f,"Undo",90,450,-480,function()
        local value,err=call("Undo",f.selected);showResult(f,value,err)
    end)
    f.ignore=H.button(f,"Dismiss",100,548,-480,function()
        local value,err=call("Ignore",f.selected);f.choice=nil;showResult(f,value,err)
    end)
    f.captureAll=H.button(f,"Track all",100,656,-480,function()
        local value,err=call("CaptureAll",f.selected,f.captureAllExpected)
        f.captureChoice=nil;showResult(f,value,err)
    end)
    f.message=H.font(f,11,286,-522,470,"")
    return f
end

refresh=function(f)
    local receipts,err=call("List")
    local ledger=type(IOU.GetLedger)=="function" and IOU.GetLedger()
    receipts=type(receipts)=="table" and receipts or {}
    local pages=math.max(1,math.ceil(#receipts/PAGE_SIZE))
    f.page=math.max(1,math.min(f.page or 1,pages))
    local selected
    for _,receipt in ipairs(receipts) do if receipt.id==f.selected then selected=receipt;break end end
    if not selected then
        selected=receipts[(f.page-1)*PAGE_SIZE+1];f.selected=selected and selected.id
        f.choice=nil;f.captureChoice=nil;f.mode=nil
    end
    for index,row in ipairs(f.rows) do
        local receipt=receipts[(f.page-1)*PAGE_SIZE+index]
        row.receiptID=receipt and receipt.id
        row:SetShown(receipt~=nil)
        if receipt then
            row.peer:SetText(text(receipt.peer))
            row.status:SetText((receipt.id==f.selected and "> " or "")..(statuses[receipt.status] or "Recorded"))
            row.when:SetText(source(receipt).." / "..dateLabel(receipt.at))
        end
    end
    f.empty:SetText(#receipts==0 and (err and text(err) or "Trades and mail appear here.") or "")
    f.pages:SetText(f.page.." / "..pages)
    f.previous:SetEnabled(f.page>1);f.next:SetEnabled(f.page<pages)
    local lines={}
    if selected then
        lines={text(selected.peer),source(selected).." / "..(statuses[selected.status] or "Recorded"),"",
            "Given: "..assets(selected.outgoing),"Received: "..assets(selected.incoming)}
        for _,application in ipairs(selected.applications or {}) do
            local entry=ledger and ledger.entries and ledger.entries[application.entryID]
            lines[#lines+1]=(selected.status=="undone" and "Reversed: " or "Applied: ")
                ..amount(application.asset or (entry and entry.kind) or (application.label=="" and "money" or "item"),application.amount,application.label)
        end
        for _,capture in ipairs(selected.captures or {}) do
            lines[#lines+1]="IOU added: "..debt(capture,loanDirection(capture)).." (#"..tostring(capture.entryID)..")"
        end
    end
    f.summary:SetText(table.concat(lines,"\n"))
    f.content:SetHeight(math.max(166,f.summary:GetStringHeight()+12))
    local rows,shared,changed={},false,false
    if selected then rows,shared,changed=choices(selected,ledger) end
    local captureRows={}
    local s=service()
    if selected and s and type(s.Capture)=="function" then
        for index,value in ipairs(selected.unmatched or {}) do
            if (value.asset=="money" or value.asset=="item") and (value.direction=="owe" or value.direction=="owed")
                and type(value.amount)=="number" and value.amount>0 then
                captureRows[#captureRows+1]={index=index,asset=value}
            end
        end
    end
    local pending=selected and #(selected.pending or {})>0
    local firstPending=selected and selected.pending and selected.pending[1]
    local repayAvailable=#rows>0 or pending==true
    local captureAvailable=#captureRows>0
    if f.mode=="capture" and not captureAvailable then f.mode=nil;f.captureChoice=nil end
    if f.mode=="repay" and not repayAvailable then f.mode=nil;f.choice=nil end
    f.mode=f.mode or (repayAvailable and "repay" or captureAvailable and "capture" or "repay")
    local capturing=f.mode=="capture" and captureAvailable
    f.repayMode:SetShown(repayAvailable and captureAvailable);f.captureMode:SetShown(repayAvailable and captureAvailable)
    f.repayMode:SetEnabled(capturing);f.captureMode:SetEnabled(not capturing)
    local visibleRows=capturing and captureRows or rows
    local choicePages=math.max(1,math.ceil(#visibleRows/CHOICES))
    f.choicePage=math.max(1,math.min(f.choicePage or 1,choicePages))
    local currentChoice,currentCapture
    -- A single unassigned asset needs only the explicit Track click.
    if capturing and #captureRows==1 and not f.captureChoice then f.captureChoice=captureRows[1] end
    for index,row in ipairs(f.candidates) do
        local choice=not capturing and rows[(f.choicePage-1)*CHOICES+index] or nil
        local capture=capturing and captureRows[(f.choicePage-1)*CHOICES+index] or nil
        row.choice,row.capture=choice,capture;row:SetShown(choice~=nil or capture~=nil)
        if choice then
            local c,p=choice.candidate,choice.pending
            local selectedChoice=sameChoice(f.choice,choice)
            if selectedChoice then currentChoice=choice end
            local direction=p.direction=="owed" and "Owes you " or "You owe "
            local value,entry=choice.amount,choice.entry
            local note=entry and entry.note and entry.note~="" and " / "..label(entry.note,24) or ""
            local repayment=p.asset=="money" and H.money(value) or tostring(value)
            row:SetText((selectedChoice and "> " or "")..direction..amount(p.asset,choice.balance,c.label or p.label,32)
                .."  (#"..tostring(c.entryID)..")\nRepay "..repayment..note)
        elseif capture then
            local selectedCapture=f.captureChoice and f.captureChoice.index==capture.index
                and sameAsset(f.captureChoice.asset,capture.asset)
            if selectedCapture then currentCapture=capture end
            row:SetText((selectedCapture and "> " or "")..debt(capture.asset,loanDirection(capture.asset)))
        end
    end
    f.choice=currentChoice;f.captureChoice=currentCapture
    local firstChoice=rows[(f.choicePage-1)*CHOICES+1]
    local visiblePending=currentChoice and currentChoice.pending or firstChoice and firstChoice.pending or firstPending
    f.pendingText:SetText(capturing and (#captureRows>1 and "Choose what to track. Gifts and purchases need no IOU." or "Track only if this was a loan.")
        or #rows>0 and (choiceReasons[visiblePending.reason] or "Choose the IOU repaid.")
        or shared and "Shared repayments still need confirmation."
        or changed and "These IOUs changed. Check their current balances."
        or pending and (reasons[firstPending.reason] or "No matching IOU. Balances unchanged.") or "")
    local paging=#visibleRows>CHOICES
    f.choicePrevious:SetShown(paging);f.choiceNext:SetShown(paging);f.choicePages:SetShown(paging)
    f.choicePrevious:SetEnabled(f.choicePage>1);f.choiceNext:SetEnabled(f.choicePage<choicePages)
    f.choicePages:SetText(f.choicePage.." / "..choicePages)
    f.apply:SetShown(not capturing and #rows>0);f.apply:SetEnabled(currentChoice~=nil)
    f.capture:SetShown(capturing);f.capture:SetEnabled(currentCapture~=nil)
    local bundle=capturing and #captureRows>1 and s and type(s.CaptureAll)=="function"
    f.captureAll:SetShown(bundle);f.captureAllExpected=bundle and captureSnapshot(selected.unmatched) or nil
    f.shared:SetShown(not capturing and #rows==0 and shared)
    f.records:SetShown(not capturing and #rows==0 and not shared and (pending==true or selected and #(selected.captures or {})>0))
    f.undo:SetShown(selected and #(selected.applications or {})>0 and selected.status~="undone" or false)
    f.ignore:SetShown(pending==true or (selected and selected.status=="unmatched") or false)
end

function IOU.ShowTradeActivity(receiptID)
    local f=UI.tradeActivity or createActivity()
    if receiptID then
        f.selected,f.choice,f.captureChoice,f.choicePage,f.mode=receiptID,nil,nil,1,nil
        local receipts=call("List") or {}
        for index,receipt in ipairs(receipts) do
            if receipt.id==receiptID then f.page=math.ceil(index/PAGE_SIZE);break end
        end
    end
    f.message:SetText("");refresh(f);f:Show()
end

local function toast(receipt)
    if receipt.status~="applied" and receipt.status~="review" then return end
    local f=UI.tradeToast
    if not f then
        f=H.panel(UIParent,440,80,0,0);UI.tradeToast=f
        f:ClearAllPoints();f:SetPoint("BOTTOM",UIParent,"BOTTOM",0,150)
        f:SetFrameStrata("DIALOG");f:SetClampedToScreen(true)
        f.label=H.font(f,12,12,-12,374,"",GOLD)
        f.label:SetHeight(28);f.label:SetMaxLines(2)
        f.open=H.button(f,"View",110,12,-44,function() if f.receiptID then IOU.ShowTradeActivity(f.receiptID) end;f:Hide() end)
        f.undo=H.button(f,"Undo",76,130,-44,function()
            local value,err=call("Undo",f.receiptID)
            if value then f:Hide() else f.label:SetText(text(err or "Open Activity to review it.")) end
        end)
        H.button(f,"X",24,402,-8,function() f:Hide() end)
        f:SetScript("OnHide",function(self) self:SetScript("OnUpdate",nil) end)
        f:Hide()
    end
    f.receiptID=receipt.id
    local caption="Choose an IOU"
    if receipt.status=="applied" then
        local applications=receipt.applications or {}
        if #applications==1 then
            local a=applications[1]
            local ledger=type(IOU.GetLedger)=="function" and IOU.GetLedger()
            local entry=ledger and ledger.entries and ledger.entries[a.entryID]
            caption=(a.direction=="owe" and "Paid " or "Received ")
                ..amount(a.asset or (entry and entry.kind) or "money",a.amount,a.label,32)
        else caption=tostring(#applications).." IOUs updated" end
    end
    f.label:SetText(label(receipt.peer).." - "..source(receipt)..": "..caption)
    f.open:SetText(receipt.status=="review" and "Review" or "View")
    f.undo:SetShown(#(receipt.applications or {})>0)
    f:Show()
    -- A short notice never opens the ledger or takes keyboard focus.
    f.expires=(type(GetTime)=="function" and GetTime() or 0)+20
    f:SetScript("OnUpdate",function(self,elapsed)
        if type(GetTime)=="function" then
            if GetTime()>=self.expires then self:Hide() end
        else self.expires=self.expires-(elapsed or 0);if self.expires<=0 then self:Hide() end end
    end)
end
local priorChanged=IOU.OnTradeChanged
function IOU.OnTradeChanged(receipt)
    if type(priorChanged)=="function" then priorChanged(receipt) end
    if UI.tradeActivity and UI.tradeActivity:IsShown() then refresh(UI.tradeActivity) end
    if type(receipt)=="table" then
        if receipt.status=="undone" or receipt.status=="ignored" or receipt.ignoredPending then
            if UI.tradeToast and UI.tradeToast.receiptID==receipt.id then UI.tradeToast:Hide() end
        else toast(receipt) end
    end
end
