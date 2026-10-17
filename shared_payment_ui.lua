local _, IOU = ...
local UI, S, C = IOU.UI, IOU.SharedService, IOU.SharedCodec
local H = UI.Helpers
local GOLD, MUTED = {0.88,0.73,0.42}, {0.65,0.66,0.63}
local function money(value) return H.money and H.money(value) or IOU.Ledger.FormatMoney(value) end
local function obligation(terms) return terms and (C.IsObligation and C.IsObligation(terms) or terms.kind=="GOLD_OBLIGATION") end
local function payment(terms) return terms and (C.IsPayment and C.IsPayment(terms) or terms.kind=="GOLD_PAYMENT") end
local function correction(terms) return terms and (C.IsCorrection and C.IsCorrection(terms) or terms.kind=="GOLD_CORRECTION") end
local function asset(terms) return C.Asset and C.Asset(terms) or {kind="money",amount=terms.amountCopper,label=""} end
local function amount(terms,value)
    local a=asset(terms)
    return a.kind=="item" and tostring(value or a.amount).." x "..a.label or money(value or a.amount)
end
local function reference(id)
    local number=type(id)=="string" and id:match("%-(%d+)$")
    return number and "#"..number or id
end
local function shortReference(id)
    local number=type(id)=="string" and id:match("%-(%d+)$")
    return number and "#"..number or "(see Details)"
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
local function parentOf(offer,overview)
    local terms = termsOf(offer)
    if not terms then return nil end
    if obligation(terms) then return offer end
    if overview then
        for _,parent in ipairs(overview.offers) do if parent.offerId==terms.parentOfferId then return parent end end
        return nil
    end
    return S.GetOffer(terms.parentOfferId)
end
local function eligible(view)
    local result = {}
    for _, event in ipairs(view.events) do
        if payment(event) and event.effective and not event.reversed then result[#result+1]=event end
    end
    return result
end

function IOU.SharedPaymentSummary(offer,overview,review)
    local terms=termsOf(offer)
    local parent=parentOf(offer,overview)
    local original=termsOf(parent)
    if not terms or not original then return "Original IOU unavailable." end
    local view=overview and overview.balances[parent.offerId]
    if not overview then view=S.GetBalance(parent.offerId) end
    local text={}
    if obligation(terms) then
        text[#text+1]=original.debtor.." owes "..original.creditor
        text[#text+1]="Remaining "..amount(original,view and view.remainingCopper or original.amountCopper)
        text[#text+1]="Original "..amount(original,original.amountCopper).."  /  Paid "..amount(original,view and view.paidCopper or 0)
    else
        text[#text+1]="Original IOU: "..amount(original,original.amountCopper)
        if not review then text[#text+1]=original.debtor.." owes "..original.creditor end
        local rows=C.ParseChain(terms.baseChain) or {}
        local before=original.amountCopper
        local target
        for _,event in ipairs(rows) do
            before=before+(payment(event) and -event.amountCopper or event.amountCopper)
            if event.offerId==terms.reversesId then target=event end
        end
        if correction(terms) then
            text[#text+1]="Undo payment "..shortReference(terms.reversesId)
            if review and target and target.note~="" then text[#text+1]="Payment note: "..target.note end
        end
        text[#text+1]="Balance: "..amount(original,before).." -> "..amount(original,before+(payment(terms) and -terms.amountCopper or terms.amountCopper))
    end
    if review then
        if original.dueUTC~=0 then text[#text+1]="Original due: "..due(original.dueUTC) end
        if original.note~="" then text[#text+1]="Original note: "..original.note end
    end
    return table.concat(text,"\n")
end

function IOU.SharedPaymentDetails(offer,overview)
    local terms = termsOf(offer)
    if not terms then return "" end
    local parent = parentOf(offer,overview)
    if not parent then return "\nOriginal agreement is unavailable." end
    local original = termsOf(parent)
    local view,err
    if overview then view=overview.balances[parent.offerId] else view,err=S.GetBalance(parent.offerId) end
    local text = {"", "Shared balance"}
    if view then
        if view.confirmed then
            text[#text+1] = "Original: " .. amount(original,view.originalCopper) .. " / Paid: " .. amount(original,view.paidCopper)
            text[#text+1] = "Remaining: " .. amount(original,view.remainingCopper) .. (view.remainingCopper==0 and " (settled)" or "")
        else
            text[#text+1]="No confirmed shared balance yet."
        end
        if view.awaitingAck then text[#text+1]="Latest payment awaits peer acknowledgment; it is not included in your balance yet."
        elseif view.pendingOfferId then text[#text+1]="An unfinished payment or correction needs review before another can be recorded." end
    else text[#text+1]=err end
    if obligation(terms) then
        if view and #view.events>0 then text[#text+1]=""; text[#text+1]="Payment and correction history" end
        for _, event in ipairs(view and view.events or {}) do
            text[#text+1]=(payment(event) and "Payment " or "Correction ") .. reference(event.offerId) .. ": " .. amount(original,event.amountCopper)
            text[#text+1]=eventState(event) .. (event.effective and " / included in balance" or " / not included in balance")
                .. (event.reversed and " / reversed" or "")
            if event.reversesId ~= "" then text[#text+1]="Reverses payment: " .. reference(event.reversesId) end
            text[#text+1]="Note: " .. (event.note=="" and "(none)" or event.note)
        end
    else
        text[#text+1]=""
        text[#text+1]="Original agreement"
        text[#text+1]="Original debtor: " .. original.debtor .. " / Creditor: " .. original.creditor
        text[#text+1]="Original amount: " .. amount(original,original.amountCopper)
        text[#text+1]="Original due: " .. due(original.dueUTC)
        text[#text+1]="Original note: " .. (original.note=="" and "(none)" or original.note)
        local rows = C.ParseChain(terms.baseChain) or {}
        local remaining = original.amountCopper
        text[#text+1]=""
        if #rows>0 then text[#text+1]="Previously confirmed payments and corrections" end
        for _, event in ipairs(rows) do
            text[#text+1]=(payment(event) and "Payment " or "Correction ") .. reference(event.offerId)
            text[#text+1]="Amount: " .. amount(original,event.amountCopper) .. " / Note: " .. (event.note=="" and "(none)" or event.note)
            if payment(event) then remaining=remaining-event.amountCopper
            else remaining=remaining+event.amountCopper; text[#text+1]="Reverses payment: " .. reference(event.reversesId) end
        end
        text[#text+1]="Balance before this event: " .. amount(original,remaining)
        if correction(terms) then
            text[#text+1]="Full reversal of payment: " .. reference(terms.reversesId)
            text[#text+1]="Balance after acknowledgment: " .. amount(original,remaining+terms.amountCopper)
        else text[#text+1]="Balance after acknowledgment: " .. amount(original,remaining-terms.amountCopper) end
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
local function point(frame,x,y)
    frame:ClearAllPoints(); frame:SetPoint("TOPLEFT",x,y)
end
local function formLayout(f)
    local contextHeight=f.showDetails and 200 or 124
    f.scroll:SetHeight(contextHeight)
    local cursor=68+contextHeight+18
    if f.mode=="correction" then
        for index,row in ipairs(f.rows) do point(row,24,-cursor-(index-1)*44) end
        point(f.previous,24,-cursor-134); point(f.next,638,-cursor-134); point(f.pages,74,-cursor-142)
        point(f.targetText,24,-cursor-174); cursor=cursor+214
    else
        point(f.targetText,24,-cursor); cursor=cursor+40
    end
    local moneyShown=f.mode=="payment" and not f.isItem
    f.moneyGroup:SetShown(moneyShown)
    for _,box in ipairs(f.money) do box:SetShown(moneyShown) end
    local quantityShown=f.mode=="payment" and f.isItem
    f.quantityGroup:SetShown(quantityShown)
    if moneyShown or quantityShown then
        point(moneyShown and f.moneyGroup or f.quantityGroup,24,-cursor); cursor=cursor+76
    end
    point(f.noteCaption,24,-cursor); point(f.note,28,-cursor-22)
    point(f.status,24,-cursor-64); point(f.send,24,-cursor-118); point(f.back,524,-cursor-118)
    local height=cursor+168
    f:SetHeight(height)
    f:SetScale(math.max(0.4,math.min(1,(UIParent:GetWidth()-32)/700,(UIParent:GetHeight()-32)/height)))
end
local function refreshForm(f)
    local view, err=current(f)
    if not view then f.send:SetEnabled(false); f.status:SetText(H.literal(err)); return end
    local parent=S.GetOffer(f.parentId)
    local text=f.showDetails and IOU.SharedPaymentDetails(parent) or IOU.SharedPaymentSummary(parent)
    if f.paymentId then
        local payment=S.GetOffer(f.paymentId)
        local terms=termsOf(payment)
        text=text .. "\n\nUndo payment " .. shortReference(f.paymentId) .. ": " .. amount(terms,terms.amountCopper)
        if terms.note~="" then text=text.."\n"..terms.note end
    end
    f.context:SetText(H.literal(text))
    f.content:SetHeight(math.max(f.showDetails and 200 or 124,f.context:GetStringHeight()+16))
    local items=eligible(view)
    local correction=f.mode=="correction"
    f.page=math.max(1,math.min(f.page or 1,math.max(1,math.ceil(#items/3))))
    for index,row in ipairs(f.rows) do
        local item=correction and items[(f.page-1)*3+index]
        if item then
            row.paymentId,row.offerId=item.offerId,item.offerId
            row:SetText((item.offerId==f.paymentId and "Selected " or "Payment ") .. shortReference(item.offerId) .. " / " .. amount(termsOf(parent),item.amountCopper)); row:Show()
        else row.paymentId=nil; row:Hide() end
    end
    f.previous:SetShown(correction); f.next:SetShown(correction); f.pages:SetShown(correction)
    f.previous:SetEnabled(f.page>1); f.next:SetEnabled(f.page*3<#items)
    f.pages:SetText("Payments " .. f.page .. " / " .. math.max(1,math.ceil(#items/3)))
    f.targetText:SetText(correction and "Choose the payment to undo."
        or f.mode=="settle" and "They must confirm this balance is paid."
        or "They must confirm this payment.")
    f.send:SetEnabled(not correction or f.paymentId~=nil)
    formLayout(f)
end

function IOU.RefreshSharedPayments(selected,overview)
    local board=UI.shared
    if not board then return end
    local parent,view
    if overview and selected then
        local terms=termsOf(selected)
        local parentId=terms and (obligation(terms) and selected.offerId or terms.parentOfferId)
        for _,offer in ipairs(overview.offers) do if offer.offerId==parentId then parent=offer; break end end
        view=parent and overview.balances[parent.offerId]
    elseif not overview then
        parent=selected and parentOf(selected)
        view=parent and S.GetBalance(parent.offerId)
    end
    local automatic=IOU.Sharing and type(IOU.Sharing.PrepareOffer)=="function"
    local ready=view and view.canPropose and (automatic or S.IsEnabled()
        and S.GetPeer()==termsOf(parent).recipient)
    board.payment:SetEnabled(ready and view.remainingCopper>0 or false)
    board.settle:SetEnabled(ready and view.remainingCopper>0 or false)
    board.correction:SetEnabled(ready and #eligible(view)>0 or false)
    local menuOpen=board.moreOpen==true
    board.payment:SetShown(menuOpen and ready and view.remainingCopper>0 or false)
    board.settle:SetShown(menuOpen and ready and view.remainingCopper>0 or false)
    board.correction:SetShown(menuOpen and ready and #eligible(view)>0 or false)
    if board.adopt then
        local adopt=automatic and IOU.Sharing.Adopt and selected and parent
            and selected.offerId==parent.offerId and view and view.confirmed
        board.adopt:SetEnabled(not not adopt); board.adopt:SetShown(menuOpen and adopt or false)
    end
    if board.moreMenu then
        local y=-12
        local entries={board.payment,board.settle,board.correction,board.filterButtons.all,board.backups}
        if board.adopt then entries[#entries+1]=board.adopt end
        if automatic and board.connection then entries[#entries+1]=board.connection end
        if board.connection then board.connection:SetShown(menuOpen and automatic or false) end
        for _,entry in ipairs(entries) do
            local show=menuOpen and (entry==board.filterButtons.all or entry==board.backups or entry==board.connection or entry:IsShown())
            entry:SetShown(show)
            if show then entry:ClearAllPoints(); entry:SetPoint("TOPLEFT",12,y); y=y-36 end
        end
        local height=math.max(60,12-y)
        board.moreMenu:SetHeight(height); board.moreMenu:ClearAllPoints()
        board.moreMenu:SetPoint("TOPLEFT",686,-(594-height)); board.moreMenu:SetShown(menuOpen)
    end
    local f=UI.sharedPaymentForm
    if f and f:IsShown() and (not overview or board.paymentOverview ~= overview) then refreshForm(f) end
    board.paymentOverview=overview
end

function IOU.ShowSharedPayment(id,mode)
    if mode~="payment" and mode~="settle" and mode~="correction" then return end
    if IOU.Sharing and IOU.Sharing.PrepareOffer then
        local ok,problem=IOU.Sharing.PrepareOffer(id)
        if not ok then if UI.shared then UI.shared.problem=problem; IOU.RefreshShared() end; return end
    end
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
        local f=H.window("IOUSharedPaymentWindow",700,494)
        UI.sharedPaymentForm=f
        f.title=H.font(f,21,22,-22,490,"",GOLD)
        f.detailToggle=H.button(f,"Details",116,536,-22,function()
            f.showDetails=not f.showDetails
            f.detailToggle:SetText(f.showDetails and "Hide details" or "Details")
            refreshForm(f); f.scroll:SetVerticalScroll(0)
        end)
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
        f.quantityGroup=CreateFrame("Frame",nil,f); f.quantityGroup:SetSize(648,62)
        H.font(f.quantityGroup,11,0,0,300,"Quantity",MUTED)
        f.quantity=H.edit(f.quantityGroup,180,4,-20,9,true)
        f.noteCaption=H.font(f,11,24,-558,648,"",MUTED)
        f.note=H.edit(f,640,28,-580,512)
        f.status=H.font(f,12,24,-623,648,"",GOLD); f.status:SetHeight(46)
        f.send=H.button(f,"Send request",320,24,-690,function()
            local latest,problem=current(f)
            if not latest then f.status:SetText(H.literal(problem)); f.send:SetEnabled(false); return end
            local offer,saved
            if f.mode=="correction" then
                if not f.paymentId then f.status:SetText("Select the payment to reverse."); return end
                offer,problem,saved=S.ProposeCorrection(f.parentId,f.paymentId,f.note:GetText())
            else
                local amount
                if f.mode=="settle" then
                    if f.isItem then amount=f.remaining else amount,problem=f.money:Read() end
                elseif f.isItem then
                    amount=tonumber(f.quantity:GetText())
                    if not amount or amount<1 or amount~=math.floor(amount) or amount>IOU.Ledger.MAX_AMOUNT then f.status:SetText("Enter a whole quantity above zero."); return end
                else amount,problem=f.money:Read() end
                if not amount then f.status:SetText(problem); return end
                if f.mode=="settle" and amount~=f.remaining then f.status:SetText("The settlement amount changed. Start a new draft."); return end
                offer,problem,saved=S.ProposePayment(f.parentId,amount,f.note:GetText())
            end
            if not offer and not saved then f.status:SetText(H.literal(problem)); return end
            IOU.SelectSharedOffer((offer or saved).offerId,not offer and problem or nil)
            f:Hide(); IOU.RefreshShared()
        end)
        f.back=H.button(f,"Back",148,524,-690,function() f:Hide() end)
        f.note:SetScript("OnEscapePressed",function() f:Hide() end)
        for _,box in ipairs(f.money) do box:SetScript("OnEscapePressed",function() f:Hide() end) end
        f.quantity:SetScript("OnEscapePressed",function() f:Hide() end)
        f:SetScript("OnHide",function() f.note:ClearFocus(); f.quantity:ClearFocus(); for _,box in ipairs(f.money) do box:ClearFocus() end end)
        f:HookScript("OnShow",function() formLayout(f) end)
    end
    local f=UI.sharedPaymentForm
    f.parentId,f.parentTerms,f.base,f.peer=parent.offerId,parent.terms,view.baseChain,S.GetPeer()
    f.mode,f.remaining,f.paymentId,f.paymentTerms,f.page=mode,view.remainingCopper,nil,nil,1
    f.isItem=asset(termsOf(parent)).kind=="item"; f.quantity:SetText("1")
    f.showDetails=false; f.detailToggle:SetText("Details")
    f.title:SetText(mode=="correction" and "Undo shared payment" or mode=="settle" and "Mark shared IOU paid" or "Adjust shared payment")
    f.noteCaption:SetText(mode=="correction" and "Reason (optional)" or "Note (optional)")
    f.money:Fill(mode=="settle" and view.remainingCopper or 0)
    for _,box in ipairs(f.money) do box:SetEnabled(mode=="payment") end
    f.note:SetText(""); f.status:SetText(""); f.scroll:SetVerticalScroll(0)
    refreshForm(f); f:Show()
end
