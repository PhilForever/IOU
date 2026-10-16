local _, IOU = ...
local UI, S, C = IOU.UI, IOU.SharedService, IOU.SharedCodec
local H = UI.Helpers
local GOLD, MUTED = {0.88,0.73,0.42}, {0.65,0.66,0.63}
local function money(value) return IOU.Ledger.FormatMoney(value) end
local function reference(id)
    local number=type(id)=="string" and id:match("%-(%d+)$")
    return number and "#"..number or id
end
local function eventState(event)
    if event.localClosed then return "Paused; reviewed locally" end
    local labels={OFFER_OPEN="Waiting for acceptance",OFFER_RECEIVED="Needs review",
        ACCEPT_PENDING="Waiting for commitment",DECLINE_PENDING="Decline pending",
        COMMITTED="Agreed",DECLINED="Declined",WITHDRAWN="Withdrawn",PAUSED="Paused"}
    return labels[event.state] or event.state
end
local function due(stamp)
    if stamp==0 then return "No deadline" end
    local ok,value=pcall(date,"!%Y-%m-%d %H:%M:%S UTC",stamp)
    return ok and type(value)=="string" and value or "Date unavailable"
end
local function termsOf(offer) return offer and C.ParseTerms(offer.terms) end
local function parentOf(offer)
    local terms = termsOf(offer)
    if not terms then return nil end
    return terms.kind == "GOLD_OBLIGATION" and offer or S.GetOffer(terms.parentOfferId)
end
local function eligible(view)
    local result = {}
    for _, event in ipairs(view.events) do
        if event.kind == "GOLD_PAYMENT" and event.effective and not event.reversed then result[#result+1]=event end
    end
    return result
end

function IOU.SharedPaymentDetails(offer)
    local terms = termsOf(offer)
    if not terms then return "" end
    local parent = parentOf(offer)
    if not parent then return "\nOriginal agreement is unavailable." end
    local original = termsOf(parent)
    local view, err = S.GetBalance(parent.offerId)
    local text = {"", "Shared gold balance"}
    if view then
        if view.confirmed then
            text[#text+1] = "Original: " .. money(view.originalCopper) .. " / Paid: " .. money(view.paidCopper)
            text[#text+1] = "Remaining: " .. money(view.remainingCopper) .. (view.remainingCopper==0 and " (settled)" or "")
        else
            text[#text+1]="No confirmed shared balance yet."
        end
        if view.awaitingAck then text[#text+1]="Latest payment awaits peer acknowledgment; it is not included in your balance yet."
        elseif view.pendingOfferId then text[#text+1]="An unfinished payment or correction needs review before another can be recorded." end
    else text[#text+1]=err end
    if terms.kind == "GOLD_OBLIGATION" then
        if view and #view.events>0 then text[#text+1]=""; text[#text+1]="Payment and correction history" end
        for _, event in ipairs(view and view.events or {}) do
            text[#text+1]=(event.kind=="GOLD_PAYMENT" and "Payment " or "Correction ") .. reference(event.offerId) .. ": " .. money(event.amountCopper)
            text[#text+1]=eventState(event) .. (event.effective and " / included in balance" or " / not included in balance")
                .. (event.reversed and " / reversed" or "")
            if event.reversesId ~= "" then text[#text+1]="Reverses payment: " .. reference(event.reversesId) end
            text[#text+1]="Note: " .. (event.note=="" and "(none)" or event.note)
        end
    else
        text[#text+1]=""
        text[#text+1]="Original agreement"
        text[#text+1]="Original debtor: " .. original.debtor .. " / Creditor: " .. original.creditor
        text[#text+1]="Original amount: " .. money(original.amountCopper)
        text[#text+1]="Original due: " .. due(original.dueUTC)
        text[#text+1]="Original note: " .. (original.note=="" and "(none)" or original.note)
        local rows = C.ParseChain(terms.baseChain) or {}
        local remaining = original.amountCopper
        text[#text+1]=""
        if #rows>0 then text[#text+1]="Previously confirmed payments and corrections" end
        for _, event in ipairs(rows) do
            text[#text+1]=(event.kind=="GOLD_PAYMENT" and "Payment " or "Correction ") .. reference(event.offerId)
            text[#text+1]="Amount: " .. money(event.amountCopper) .. " / Note: " .. (event.note=="" and "(none)" or event.note)
            if event.kind=="GOLD_PAYMENT" then remaining=remaining-event.amountCopper
            else remaining=remaining+event.amountCopper; text[#text+1]="Reverses payment: " .. reference(event.reversesId) end
        end
        text[#text+1]="Balance before this event: " .. money(remaining)
        if terms.kind=="GOLD_CORRECTION" then
            text[#text+1]="Full reversal of payment: " .. reference(terms.reversesId)
            text[#text+1]="Balance after acknowledgment: " .. money(remaining+terms.amountCopper)
        else text[#text+1]="Balance after acknowledgment: " .. money(remaining-terms.amountCopper) end
    end
    return table.concat(text,"\n")
end

local function current(f)
    local parent = S.GetOffer(f.parentId)
    if not parent or parent.terms~=f.parentTerms or not S.IsEnabled() or S.GetPeer()~=f.peer then
        return nil,"The agreement or connected player changed. Close this draft and start again."
    end
    local view, err = S.GetBalance(f.parentId)
    if not view then return nil,err end
    if view.baseChain~=f.base or not view.canPropose then
        return nil,"The balance or pending event changed. Close this draft and review the agreement again."
    end
    if f.mode=="correction" and f.paymentId then
        local payment=S.GetOffer(f.paymentId)
        local found=false
        for _, event in ipairs(eligible(view)) do if event.offerId==f.paymentId then found=true end end
        if not found or not payment or payment.terms~=f.paymentTerms then return nil,"The selected payment changed. Review it again." end
    end
    return view
end
local function refreshForm(f)
    local view, err=current(f)
    if not view then f.send:SetEnabled(false); f.status:SetText(H.literal(err)); return end
    local parent=S.GetOffer(f.parentId)
    local text=IOU.SharedPaymentDetails(parent)
    if f.paymentId then
        local payment=S.GetOffer(f.paymentId)
        local terms=termsOf(payment)
        text=text .. "\n\nSelected payment: " .. reference(f.paymentId) .. "\nAmount: " .. money(terms.amountCopper)
            .. "\nFull payment note: " .. (terms.note=="" and "(none)" or terms.note)
    end
    f.context:SetText(H.literal(text))
    f.content:SetHeight(math.max(200,f.context:GetStringHeight()+16))
    local items=eligible(view)
    local correction=f.mode=="correction"
    f.page=math.max(1,math.min(f.page or 1,math.max(1,math.ceil(#items/3))))
    for index,row in ipairs(f.rows) do
        local item=correction and items[(f.page-1)*3+index]
        if item then
            row.paymentId,row.offerId=item.offerId,item.offerId
            row:SetText((item.offerId==f.paymentId and "Selected payment " or "Choose payment ") .. reference(item.offerId) .. " / " .. money(item.amountCopper)); row:Show()
        else row.paymentId=nil; row:Hide() end
    end
    f.previous:SetShown(correction); f.next:SetShown(correction); f.pages:SetShown(correction)
    f.previous:SetEnabled(f.page>1); f.next:SetEnabled(f.page*3<#items)
    f.pages:SetText("Payments " .. f.page .. " / " .. math.max(1,math.ceil(#items/3)))
    f.targetText:SetText(correction and "Select one confirmed payment above to reverse in full."
        or f.mode=="settle" and "Propose the entire remaining balance shown above."
        or "Enter a partial payment. The other player must review it.")
    f.send:SetEnabled(not correction or f.paymentId~=nil)
end

function IOU.RefreshSharedPayments(selected)
    local board=UI.shared
    if not board then return end
    local parent=selected and parentOf(selected)
    local view=parent and S.GetBalance(parent.offerId)
    local ready=view and view.canPropose and S.IsEnabled()
        and S.GetPeer()==termsOf(parent).recipient
    board.payment:SetEnabled(ready and view.remainingCopper>0 or false)
    board.settle:SetEnabled(ready and view.remainingCopper>0 or false)
    board.correction:SetEnabled(ready and #eligible(view)>0 or false)
    local f=UI.sharedPaymentForm
    if f and f:IsShown() then refreshForm(f) end
end

function IOU.ShowSharedPayment(id,mode)
    if mode~="payment" and mode~="settle" and mode~="correction" then return end
    local parent=parentOf(S.GetOffer(id))
    local view,err
    if parent then view,err=S.GetBalance(parent.offerId) end
    if not view or not view.canPropose or not S.IsEnabled() or S.GetPeer()~=termsOf(parent).recipient then
        if UI.shared then UI.shared.problem=err or view and view.blockReason or "Select an acknowledged agreement with the connected player."; IOU.RefreshShared() end
        return
    end
    if mode~="correction" and view.remainingCopper==0 then return end
    if mode=="correction" and #eligible(view)==0 then return end
    if not UI.sharedPaymentForm then
        local f=H.window("IOUSharedPaymentWindow",700,740)
        UI.sharedPaymentForm=f
        f.title=H.font(f,21,22,-22,640,"",GOLD)
        f.scroll,f.content=H.scroll(f,628,200,24,-68)
        f.context=H.font(f.content,12,0,0,616,"")
        f.rows={}
        for index=1,3 do
            local row=H.button(f,"",648,24,-280-(index-1)*44,function()
                local selected=f.rows[index].paymentId
                local payment=selected and S.GetOffer(selected)
                if not payment then return end
                f.paymentId,f.paymentTerms=selected,payment.terms
                f.money:Fill(termsOf(payment).amountCopper)
                f.status:SetText(""); refreshForm(f); f.scroll:SetVerticalScroll(0)
            end)
            f.rows[index]=row
        end
        f.previous=H.button(f,"<",34,24,-414,function() f.page=f.page-1; refreshForm(f) end)
        f.next=H.button(f,">",34,638,-414,function() f.page=f.page+1; refreshForm(f) end)
        f.pages=H.font(f,11,74,-422,540,"",MUTED)
        f.targetText=H.font(f,12,24,-452,648,"",MUTED)
        f.moneyGroup=CreateFrame("Frame",nil,f); f.moneyGroup:SetSize(648,62); f.moneyGroup:SetPoint("TOPLEFT",24,-484)
        f.money=H.moneyFields(f.moneyGroup,0,0)
        f.noteCaption=H.font(f,11,24,-558,648,"",MUTED)
        f.note=H.edit(f,640,28,-580,512)
        f.status=H.font(f,12,24,-623,648,"",GOLD); f.status:SetHeight(46)
        f.send=H.button(f,"Send for acknowledgment",320,24,-690,function()
            local latest,problem=current(f)
            if not latest then f.status:SetText(H.literal(problem)); f.send:SetEnabled(false); return end
            local offer,saved
            if f.mode=="correction" then
                if not f.paymentId then f.status:SetText("Select the payment to reverse."); return end
                offer,problem,saved=S.ProposeCorrection(f.parentId,f.paymentId,f.note:GetText())
            else
                local amount
                amount,problem=f.money:Read()
                if not amount then f.status:SetText(problem); return end
                if f.mode=="settle" and amount~=f.remaining then f.status:SetText("The settlement amount changed. Start a new draft."); return end
                offer,problem,saved=S.ProposePayment(f.parentId,amount,f.note:GetText())
            end
            if not offer and not saved then f.status:SetText(H.literal(problem)); return end
            if UI.shared then UI.shared.selected=(offer or saved).offerId; UI.shared.page=1; UI.shared.problem=not offer and problem or nil end
            f:Hide(); IOU.RefreshShared()
        end)
        H.button(f,"Back",148,524,-690,function() f:Hide() end)
        f.note:SetScript("OnEscapePressed",function() f:Hide() end)
        for _,box in ipairs(f.money) do box:SetScript("OnEscapePressed",function() f:Hide() end) end
        f:SetScript("OnHide",function() f.note:ClearFocus(); for _,box in ipairs(f.money) do box:ClearFocus() end end)
    end
    local f=UI.sharedPaymentForm
    f.parentId,f.parentTerms,f.base,f.peer=parent.offerId,parent.terms,view.baseChain,S.GetPeer()
    f.mode,f.remaining,f.paymentId,f.paymentTerms,f.page=mode,view.remainingCopper,nil,nil,1
    f.title:SetText(mode=="correction" and "Reverse a shared payment" or mode=="settle" and "Settle shared gold balance" or "Record a shared payment")
    f.noteCaption:SetText(mode=="correction" and "Reason (optional; blank records 'No reason provided')" or "Payment note (optional; plain text)")
    f.money:Fill(mode=="settle" and view.remainingCopper or 0)
    for _,box in ipairs(f.money) do box:SetEnabled(mode=="payment") end
    f.note:SetText(""); f.status:SetText(""); f.scroll:SetVerticalScroll(0)
    refreshForm(f); f:Show()
end
