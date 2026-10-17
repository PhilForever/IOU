local _, IOU = ...
local UI, S, C, M = IOU.UI, IOU.SharedService, IOU.SharedCodec, IOU.SharedView
local H = UI.Helpers
local font, panel, button, edit, scroll, window, literal = H.font, H.panel, H.button, H.edit, H.scroll, H.window, H.literal
local GOLD, MUTED = {0.88, 0.73, 0.42}, {0.65, 0.66, 0.63}
local stateNames = {OFFER_OPEN="Sent", OFFER_RECEIVED="Needs review",
    ACCEPT_PENDING="Accepting", DECLINE_PENDING="Declining",
    COMMITTED="Agreed", DECLINED="Declined", WITHDRAWN="Withdrawn", PAUSED="Interrupted"}
local refresh
local attention={count=0,recovery=false}
function IOU.GetSharedAttention()
    return {count=attention.count,recovery=attention.recovery,error=attention.error}
end

local function utc(format, stamp)
    local ok, value = pcall(date, format, stamp)
    return ok and type(value)=="string" and value or "Date unavailable"
end

function IOU.ParseSharedDueDate(value)
    value = (value or ""):match("^%s*(.-)%s*$")
    if value == "" then return 0 end
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or year < 1970 or year > 2099 or month < 1 or month > 12 or day < 1 then
        return nil, "Enter a due day as YYYY-MM-DD, or leave it blank."
    end
    local function leap(y) return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) end
    local months = {31, leap(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if day > months[month] then return nil, "That calendar day is invalid." end
    local days = day - 1
    for y=1970,year-1 do days = days + (leap(y) and 366 or 365) end
    for m=1,month-1 do days = days + months[m] end
    return days * 86400 + 86399
end

local function termsOf(offer) return offer and C.ParseTerms(offer.terms) end
local function peerOf(offer, terms)
    return offer.role == "proposer" and terms.recipient or terms.proposer
end
local function summary(offer)
    if offer.localClosed then return "Closed locally" end
    if offer.state=="COMMITTED" and offer.role=="proposer" and offer.delivery~="PEER_RECEIPT_OBSERVED" then
        return "Pending sync"
    end
    return stateNames[offer.state] or offer.state
end
local function money(value) return H.money and H.money(value) or IOU.Ledger.FormatMoney(value) end
local function preview(value)
    local cutoff=math.min(#value,180)
    local newline=value:find("\n",1,true)
    if newline and newline<=cutoff then cutoff=newline-1 end
    while cutoff>0 and value:byte(cutoff+1) and value:byte(cutoff+1)>=128 and value:byte(cutoff+1)<=191 do cutoff=cutoff-1 end
    return value:sub(1,cutoff)..(cutoff<#value and "..." or "")
end
local function fullReviewText(offer,overview)
    local terms = termsOf(offer)
    if not terms then return "This agreement's terms could not be read." end
    local text = {"Proposer: " .. terms.proposer, "Recipient: " .. terms.recipient,
        "", "Debtor: " .. terms.debtor, "Creditor: " .. terms.creditor,
        "Amount: " .. IOU.Ledger.FormatMoney(terms.amountCopper)}
    if terms.kind=="GOLD_OBLIGATION" then
        text[#text+1]="Due: " .. (terms.dueUTC == 0 and "No deadline" or utc("!%Y-%m-%d %H:%M:%S UTC", terms.dueUTC))
    end
    text[#text+1]=""; text[#text+1]="Note: " .. (terms.note == "" and "(none)" or terms.note)
    text[#text+1]=""; text[#text+1]="Status: " .. summary(offer)
    if offer.state == "COMMITTED" then
        text[#text+1] = offer.delivery == "PEER_RECEIPT_OBSERVED"
            and "Peer receipt: their IOU acknowledged this commitment."
            or (offer.role == "recipient" and "Commitment received; acknowledgment queued/sent."
                or "Commitment recorded; peer acknowledgment not yet observed.")
        text[#text+1] = "IOU records player acknowledgment; it does not verify a gold transfer."
    elseif offer.state == "PAUSED" then
        text[#text+1] = "An interrupted offer cannot resume automatically. Reconcile the old offer with the other player before replacing it."
    end
    if offer.localClosed then text[#text+1] = "Local review: " .. offer.localCloseReason end
    if IOU.SharedPaymentDetails then text[#text+1] = IOU.SharedPaymentDetails(offer,overview) end
    text[#text+1]=""; text[#text+1]="Agreement: "..offer.agreementId
    text[#text+1]="Offer: "..offer.offerId
    text[#text+1] = ""
    text[#text+1] = "History"
    for _, event in ipairs(offer.history) do
        local label=event.kind:gsub("_", " "):lower():gsub("^%l",string.upper)
        text[#text+1] = utc("!%Y-%m-%d %H:%M UTC", event.at) .. " / " .. label
    end
    return table.concat(text, "\n")
end
local function compactText(offer,overview,review)
    local terms=termsOf(offer)
    if not terms then return "This IOU is unavailable." end
    local localName=overview and overview.localName or IOU.Transport.GetLocalName()
    local text={}
    if review then
        text[#text+1]=terms.debtor.." owes "..terms.creditor
    else
        text[#text+1]=peerOf(offer,terms)
    end
    if terms.kind=="GOLD_OBLIGATION" then
        local balance=overview and overview.balances[offer.offerId]
        local value=balance and balance.confirmed and balance.remainingCopper or terms.amountCopper
        local direction=terms.debtor==localName and "You owe " or "Owes you "
        text[#text+1]=(review and "Amount: " or direction)..money(review and terms.amountCopper or value)
        if balance and balance.confirmed then
            text[#text+1]="Original "..money(balance.originalCopper).."  /  Paid "..money(balance.paidCopper)
        end
        text[#text+1]=balance and balance.confirmed and balance.remainingCopper==0 and "Settled" or summary(offer)
        if terms.dueUTC~=0 then text[#text+1]="Due "..utc(review and "!%d %b %Y %H:%M:%S UTC" or "!%d %b %Y",terms.dueUTC) end
        if balance and balance.awaitingAck then text[#text+1]="Payment pending sync"
        elseif balance and balance.pendingOfferId then text[#text+1]="Payment needs review" end
    else
        text[#text+1]=(terms.kind=="GOLD_CORRECTION" and "Undo payment: " or "Payment: ")..money(terms.amountCopper)
        text[#text+1]=summary(offer)
        if IOU.SharedPaymentSummary then text[#text+1]=IOU.SharedPaymentSummary(offer,overview,review) end
    end
    if terms.note~="" then text[#text+1]=""; text[#text+1]=review and terms.note or preview(terms.note) end
    if offer.state=="PAUSED" then text[#text+1]=""; text[#text+1]=offer.localClosed and "Local review only; not accepted." or "Review with the other player before replacing." end
    return table.concat(text,"\n")
end

local function connectedTo(offer)
    local terms = termsOf(offer)
    return terms and S.IsEnabled() and S.GetPeer() == peerOf(offer, terms)
end

local function reviewCurrent(f)
    local offer = S.GetOffer(f.offerId)
    if not offer or offer.terms ~= f.terms or offer.state ~= f.state or offer.localClosed then return nil end
    if f.action == "close" then return not S.IsEnabled() and offer.state == "PAUSED" and offer end
    return connectedTo(offer) and offer
end
local function fit(frame,width,height)
    frame:SetHeight(height)
    frame:SetScale(math.max(0.4,math.min(1,(UIParent:GetWidth()-32)/width,(UIParent:GetHeight()-32)/height)))
end
local function point(frame,x,y)
    frame:ClearAllPoints(); frame:SetPoint("TOPLEFT",x,y)
end
local function renderReview(f)
    local height=f.showDetails and 666 or f.action=="close" and 500 or 420
    local scrollHeight=f.showDetails and 356 or 220
    f.scroll:SetHeight(scrollHeight)
    point(f.explanation,24,f.showDetails and -443 or -302)
    f.explanation:SetHeight(f.action=="close" and 44 or 30)
    point(f.reasonCaption,24,f.showDetails and -506 or -352)
    point(f.reason,28,f.showDetails and -525 or -372)
    point(f.status,24,f.showDetails and -562 or f.action=="close" and -408 or -338)
    f.status:SetHeight(f.showDetails and 40 or 32)
    point(f.confirm,24,-height+49); point(f.back,470,-height+49)
    fit(f,650,height)
    local text=f.showDetails and fullReviewText(f.offer,f.sourceOverview) or compactText(f.offer,f.sourceOverview,true)
    f.details:SetText(literal(text))
    f.content:SetHeight(math.max(scrollHeight,f.details:GetStringHeight()+16)); f.scroll:SetVerticalScroll(0)
    f.detailToggle:SetText(f.showDetails and "Hide details" or "Details")
end

function IOU.ShowSharedReview(id, action)
    local offer, err = S.GetOffer(id)
    if not offer then if UI.shared then UI.shared.problem=err; refresh() end; return end
    local valid = action == "accept" and offer.role == "recipient" and offer.state == "OFFER_RECEIVED"
        or action == "decline" and offer.role == "recipient" and offer.state == "OFFER_RECEIVED"
        or action == "withdraw" and offer.role == "proposer" and offer.state == "OFFER_OPEN"
        or action == "close" and offer.state == "PAUSED" and not offer.localClosed and not S.IsEnabled()
    if not valid then return end
    if not UI.sharedReview then
        local f = window("IOUSharedReviewWindow", 650, 420)
        UI.sharedReview = f
        f.title = font(f, 21, 22, -22, 410, "", GOLD)
        f.detailToggle=button(f,"Details",116,486,-22,function()
            f.showDetails=not f.showDetails; renderReview(f)
        end)
        f.scroll, f.content = scroll(f, 574, 356, 24, -68)
        f.details = font(f.content, 12, 0, 0, 564, "")
        f.explanation = font(f, 12, 24, -443, 594, "", MUTED)
        f.reasonCaption = font(f, 11, 24, -506, 594, "Reason for closing (optional)", MUTED)
        f.reason = edit(f, 584, 28, -525, 256)
        f.status = font(f, 12, 24, -562, 594, "", GOLD)
        f.status:SetHeight(40)
        f.confirm = button(f, "", 288, 24, -617, function()
            if not reviewCurrent(f) then f.status:SetText("This offer or connection changed. Close this review and select it again."); f.confirm:SetEnabled(false); return end
            local result, problem
            if f.action == "close" then result, problem = S.ClosePaused(f.offerId, f.reason:GetText())
            else
                local methods = {accept="Accept", decline="Decline", withdraw="Withdraw"}
                result, problem = S[methods[f.action]](f.offerId)
            end
            if not result then f.status:SetText(literal(problem)); return end
            f:Hide(); refresh()
        end)
        f.back=button(f, "Back", 148, 470, -617, function() f:Hide() end)
        f.reason:SetScript("OnEscapePressed", function() f:Hide() end)
        f:SetScript("OnHide", function() f.reason:ClearFocus() end)
        f:HookScript("OnShow",function() renderReview(f) end)
    end
    local f = UI.sharedReview
    f.offerId, f.terms, f.state, f.action = id, offer.terms, offer.state, action
    f.sourceOverview=UI.shared and UI.shared.overview or S.GetOverview()
    f.offer,f.showDetails=offer,false
    local captions = {accept="Accept", decline="Decline", withdraw="Withdraw", close="Close locally"}
    local terms = termsOf(offer)
    f.title:SetText(action == "close" and "Close interrupted request"
        or terms.kind == "GOLD_PAYMENT" and "Review payment"
        or terms.kind == "GOLD_CORRECTION" and "Undo payment" or "Review IOU")
    renderReview(f)
    f.explanation:SetText(action == "close"
        and "This does not accept the request or change the other player's record."
        or "Confirm these terms. No gold moves when you accept.")
    f.reason:SetShown(action == "close"); f.reasonCaption:SetShown(action == "close")
    f.reason:SetText(""); f.status:SetText(""); f.confirm:SetText(captions[action])
    f.confirm:SetEnabled(not not reviewCurrent(f)); f:Show()
end

local function renderProposal(f)
    local expanded=f.showOptions==true
    local height=expanded and 550 or 400
    f.options:SetText(expanded and "Hide options" or "Optional details")
    for _,field in ipairs({f.dueCaption,f.due,f.noteCaption,f.note}) do field:SetShown(expanded) end
    if not expanded then f.due:ClearFocus(); f.note:ClearFocus() end
    point(f.status,24,expanded and -445 or -300)
    point(f.send,24,-height+49); point(f.back,442,-height+49)
    fit(f,624,height)
end

function IOU.ShowSharedProposal()
    if not S.IsEnabled() then return end
    if not UI.sharedForm then
        local f = window("IOUSharedProposalWindow", 624, 400)
        UI.sharedForm = f
        font(f, 21, 22, -22, 560, "Share a gold IOU", GOLD)
        font(f, 11, 24, -63, 560, "Other player's full name", MUTED)
        f.peer = edit(f, 556, 28, -84, 96); f.peer:SetEnabled(false)
        f.dirButtons = {}
        for index, choice in ipairs({{"owe", "I owe them"}, {"owed", "They owe me"}}) do
            local key = choice[1]
            f.dirButtons[key] = button(f, choice[2], 270, 24 + (index-1)*286, -130, function()
                f.direction = key
                for direction, b in pairs(f.dirButtons) do b:SetEnabled(direction ~= key) end
            end)
        end
        f.money = H.moneyFields(f, 24, -178)
        f.options=button(f,"Optional details",150,24,-258,function() f.showOptions=not f.showOptions; renderProposal(f) end)
        f.dueCaption=font(f, 11, 24, -306, 560, "Due date (YYYY-MM-DD, optional)", MUTED)
        f.due = edit(f, 556, 28, -327, 10)
        f.noteCaption=font(f, 11, 24, -374, 560, "Note (optional)", MUTED)
        f.note = edit(f, 556, 28, -395, 512)
        f.status = font(f, 12, 24, -445, 560, "", GOLD); f.status:SetHeight(40)
        f.send = button(f, "Send request", 276, 24, -550, function()
            if not S.IsEnabled() or S.GetPeer() ~= f.boundPeer then f.status:SetText("The connected player changed. Close this draft and start a new proposal."); return end
            local amount, problem = f.money:Read()
            if not amount then f.status:SetText(problem); return end
            local due, dueError = IOU.ParseSharedDueDate(f.due:GetText())
            if not due then
                f.showOptions=true; renderProposal(f); f.due:SetFocus(); f.status:SetText(dueError); return
            end
            local offer, err, saved = S.Propose({peer=f.boundPeer, direction=f.direction,
                amountCopper=amount, dueUTC=due, note=f.note:GetText()})
            if not offer then
                if saved then
                    IOU.SelectSharedOffer(saved.offerId,err)
                    f:Hide(); refresh()
                else f.status:SetText(literal(err)) end
                return
            end
            IOU.SelectSharedOffer(offer.offerId)
            f:Hide(); refresh()
        end)
        f.back=button(f, "Back", 148, 442, -550, function() f:Hide() end)
        for _, box in ipairs({f.due, f.note, f.money[1], f.money[2], f.money[3]}) do
            box:SetScript("OnEscapePressed", function() f:Hide() end)
        end
        f:SetScript("OnHide", function()
            f.due:ClearFocus(); f.note:ClearFocus()
            for _, box in ipairs(f.money) do box:ClearFocus() end
        end)
        f:HookScript("OnShow",function() renderProposal(f) end)
    end
    local f = UI.sharedForm
    f.boundPeer = S.GetPeer(); f.peer:SetText(f.boundPeer); f.direction="owe"
    f.dirButtons.owe:SetEnabled(false); f.dirButtons.owed:SetEnabled(true)
    f.money:Fill(0); f.note:SetText(""); f.due:SetText(""); f.status:SetText("")
    f.showOptions=false; renderProposal(f); f:Show()
end

local viewCaptions={inbox="Requests",agreements="Active",waiting="Sent",history="History",all="All requests"}
local emptyMessages={inbox="Nothing needs your review.",agreements="No active shared agreements.",
    waiting="No sent requests awaiting a reply.",history="No completed or locally reviewed offers.",all="No shared offers yet."}
refresh = function(overview, problem)
    local f = UI.shared
    if not f then return end
    if overview then f.overview,f.overviewError=overview,nil
    elseif problem then f.overview,f.overviewError=nil,problem
    elseif not f.overview and not f.overviewError then f.overview,f.overviewError=S.GetOverview() end
    local all,err
    if f.overview then all,err=M.Build(f.overview,"all","") end
    err=f.overviewError or err
    local query=f.search and f.search:GetText() or ""
    if not f.filterInitialized and all and all.total>0 then
        f.filter=M.DefaultFilter(all); f.filterInitialized=true
    end
    local projection=all and M.Build(f.overview,f.filter or "all",query)
    local offers=projection and projection.rows or {}
    f.currentprojection=projection
    local counts=all and all.counts or {inbox=0,agreements=0,waiting=0,history=0,all=0}
    for key,b in pairs(f.filterButtons) do
        b:SetText(viewCaptions[key] .. " (" .. counts[key] .. ")")
        b:SetEnabled(not err and key ~= (projection and projection.filter))
    end
    local enabled = S.IsEnabled()
    local status=S.GetStatus()
    if enabled and IOU.SharedWire and IOU.SharedWire.GetStatus then
        local wireStatus=IOU.SharedWire.GetStatus()
        local name=S.GetPeer()
        if wireStatus:sub(1,13)=="Shared peer: " and status=="Sharing with "..name..". "..wireStatus then
            status="Connected to "..name
        end
    end
    if status=="Sharing is off. Pending offers are paused when sharing stops." then status="Connect to exchange requests." end
    f.status:SetText(literal(f.problem or err or status))
    f.peer:SetEnabled(not enabled); f.target:SetEnabled(not enabled)
    local recoveryPending = S.IsRecoveryPending and S.IsRecoveryPending()
    f.enable:SetEnabled(not enabled and not recoveryPending and not err and f.peer:GetText():find("%S") ~= nil)
    f.stop:SetEnabled(enabled); f.propose:SetEnabled(enabled and not recoveryPending and not err)
    f.page = math.max(1, math.min(f.page or 1, math.max(1, math.ceil(#offers/5))))
    f.pages:SetText("Page " .. f.page .. " / " .. math.max(1, math.ceil(#offers/5)) .. "  -  " .. #offers .. (query ~= "" and " matches" or " offers"))
    f.previous:SetEnabled(f.page > 1); f.next:SetEnabled(f.page*5 < #offers)
    local selected
    for index,item in ipairs(offers) do
        if item.offer.offerId == f.selected then
            selected=item.offer
            if f.reveal then f.page=math.ceil(index/5) end
        end
    end
    f.reveal=nil
    if not selected then
        local item=offers[(f.page-1)*5+1]
        selected=item and item.offer; f.selected=selected and selected.offerId or nil
    end
    f.pages:SetText("Page " .. f.page .. " / " .. math.max(1, math.ceil(#offers/5)) .. "  -  " .. #offers .. (query ~= "" and " matches" or " offers"))
    f.previous:SetEnabled(f.page > 1); f.next:SetEnabled(f.page*5 < #offers)
    for index, row in ipairs(f.rows) do
        local item = offers[(f.page-1)*5+index]
        local offer=item and item.offer
        if item then
            row.offerId = offer.offerId
            local kind=item.kind == "GOLD_PAYMENT" and "Payment: " or item.kind == "GOLD_CORRECTION" and "Correction: " or ""
            row.title:SetText(literal(kind .. item.peer))
            row.amount:SetText((item.kind=="GOLD_OBLIGATION" and (item.direction=="You owe" and "You owe " or "Owes you ") or "")..money(item.remainingCopper or item.amountCopper))
            local state=summary(offer)
            if item.remainingCopper==0 and item.category=="history" then state="Settled" end
            row.state:SetText(literal(state))
            row:SetBackdropColor(offer.offerId==f.selected and 0.22 or 0.10, offer.offerId==f.selected and 0.20 or 0.12, 0.08, 1)
            row:Show()
        else row.offerId=nil; row:Hide() end
    end
    f.listEmpty:SetText(literal(err or (query ~= "" and "No matching offers. Clear search or choose another view."
        or emptyMessages[projection and projection.filter or "all"])))
    f.listEmpty:SetShown(#offers==0)
    if f.detailId ~= f.selected then
        f.showDetails=false; f.moreOpen=false
        f.moreId,f.moreTerms,f.moreState,f.morePeer=nil,nil,nil,nil
        f.moreMenu:Hide(); f.detailToggle:SetText("Details")
    end
    f.detailToggle:SetEnabled(selected~=nil and not err)
    if f.detailId ~= f.selected or f.detailSource ~= f.overview or err then
        if f.detailId ~= f.selected then f.scroll:SetVerticalScroll(0) end
        f.details:SetText(literal(selected and (f.showDetails and fullReviewText(selected,f.overview) or compactText(selected,f.overview)) or err
            or "Choose a player, connect, then send an IOU request."))
        f.content:SetHeight(math.max(292, f.details:GetStringHeight()+16))
        f.detailId,f.detailSource=f.selected,f.overview
    end
    local connected = selected and connectedTo(selected) and not selected.localClosed
    local received = selected and selected.role=="recipient" and selected.state=="OFFER_RECEIVED"
    f.accept:SetEnabled(connected and received or false)
    f.accept:SetShown(received or false)
    f.decline:SetEnabled(connected and received or false)
    f.decline:SetShown(received or false)
    f.withdraw:SetEnabled(connected and selected.role=="proposer" and selected.state=="OFFER_OPEN" or false)
    f.withdraw:SetShown(selected and selected.role=="proposer" and selected.state=="OFFER_OPEN" or false)
    local retryable = selected and (selected.role=="proposer" and selected.state~="PAUSED"
        or selected.role=="recipient" and (selected.state=="ACCEPT_PENDING" or selected.state=="DECLINE_PENDING" or selected.state=="COMMITTED"))
    f.retry:SetEnabled(connected and retryable or false)
    f.retry:SetShown(connected and retryable and not (selected.state=="COMMITTED" and selected.delivery=="PEER_RECEIPT_OBSERVED") or false)
    local paused=selected and selected.state=="PAUSED" and not selected.localClosed
    f.closePaused:SetShown(paused or false)
    f.closePaused:SetEnabled(paused and not enabled and not recoveryPending or false)
    local selectedTerms=termsOf(selected)
    f.connectId,f.connectTerms,f.connectState,f.connectPeer=selected and selected.offerId,selected and selected.terms,selected and selected.state,
        selectedTerms and peerOf(selected,selectedTerms)
    f.connectSelected:SetShown(selected and not paused and not enabled or false)
    f.connectSelected:SetEnabled(selected and not paused and not enabled and not recoveryPending and not err or false)
    local hint
    if err then hint=err
    elseif recoveryPending then hint="Recovery needs review. Open More > Backups."
    elseif paused then hint=enabled and "Disconnect to close this interrupted request." or "Close locally after checking with the other player."
    elseif selected and not connected then hint=enabled and "Disconnect to switch players." or "Connect to this player to continue."
    elseif received then hint="Review, then accept or decline."
    elseif selected and selected.state=="OFFER_OPEN" then hint="Waiting for their acceptance."
    else hint="" end
    f.primaryHint:SetText(literal(hint))
    local review = UI.sharedReview
    if review and review:IsShown() and review.sourceOverview ~= f.overview then
        if not reviewCurrent(review) then
            review.confirm:SetEnabled(false); review.status:SetText("This offer or connection changed. Close this review and select it again.")
        end
        review.sourceOverview=f.overview
    end
    if IOU.RefreshSharedPayments then IOU.RefreshSharedPayments(selected,f.overview) end
end
IOU.RefreshShared = refresh

function IOU.SelectSharedOffer(id,problem)
    local f=UI.shared
    if not f then return end
    local all=f.overview and M.Build(f.overview,"all","")
    if all then
        for _,item in ipairs(all.rows) do if item.offer.offerId==id then f.filter=item.category; break end end
    end
    if f.search:GetText() ~= "" then f.search:SetText("") end
    f.filterInitialized=true; f.selected=id; f.reveal=true; f.page=1; f.problem=problem
    refresh()
end

function IOU.UpdateSharedOverview()
    local overview,err=S.GetOverview()
    local projection,problem
    if overview then projection,problem=M.Build(overview,"all","") end
    local pending,recoveryError=S.IsRecoveryPending()
    attention={count=projection and projection.needsReview or 0,recovery=pending,error=err or problem or recoveryError}
    if IOU.RenderSharedAttention then IOU.RenderSharedAttention(IOU.GetSharedAttention()) end
    if IOU.PlayerContext and type(IOU.PlayerContext.Invalidate)=="function" then
        IOU.PlayerContext.Invalidate(overview,err or problem)
    end
    refresh(overview,err or problem)
    return overview,err or problem
end
IOU.OnSharedChanged=function()
    if UI.shared then UI.shared.problem=nil end
    IOU.UpdateSharedOverview()
end

function IOU.ShowShared(peer,view)
    if not IOU.Initialize() then return end
    S.Initialize()
    if not UI.shared then
        local f = window("IOUSharedWindow", 960, 780)
        UI.shared = f
        f.page=1
        font(f, 24, 22, -22, 650, "Shared IOUs", GOLD)
        f.detailToggle=button(f,"Details",116,794,-24,function()
            f.showDetails=not f.showDetails
            f.detailToggle:SetText(f.showDetails and "Hide details" or "Details")
            f.detailSource=nil; f.scroll:SetVerticalScroll(0); refresh()
        end)
        font(f, 12, 24, -66, 896, "Connect to each other. Send an IOU; they accept or decline.", MUTED)
        f.identity = font(f, 11, 24, -112, 896, "", GOLD)
        f.peer = edit(f, 446, 28, -136, 96)
        f.target = button(f, "Use target", 110, 492, -136, function()
            local name, err = IOU.Transport.GetUnitName("target")
            f.problem=err; if name then f.peer:SetText(name) end; refresh()
        end)
        f.enable = button(f, "Connect", 178, 614, -136, function()
            f.peer:ClearFocus(); f.problem=nil
            local ok, err = S.Enable(f.peer:GetText())
            if not ok then f.problem=err end; refresh()
        end)
        f.stop = button(f, "Disconnect", 122, 804, -136, function()
            f.problem=nil; local ok, err = S.Disable(); if not ok then f.problem=err end; refresh()
        end)
        f.status = font(f, 12, 24, -178, 902, "", GOLD); f.status:SetHeight(34)
        f.filterButtons={}
        local x=24
        for _,choice in ipairs({{"inbox",214},{"agreements",214},{"waiting",214},{"history",214}}) do
            local key,width=choice[1],choice[2]
            f.filterButtons[key]=button(f,viewCaptions[key],width,x,-220,function()
                f.filter=key; f.filterInitialized=true; f.selected=nil; f.page=1; refresh()
            end)
            x=x+width+8
        end
        f.propose = button(f, "+ Share gold IOU", 270, 24, -264, IOU.ShowSharedProposal)
        font(f,10,334,-252,100,"Search",MUTED)
        f.search=edit(f,492,398,-264,200)
        f.search:SetScript("OnTextChanged",function()
            f.filterInitialized=true; f.page=1; f.selected=nil; refresh()
        end)
        f.clearSearch=button(f,"X",26,904,-264,function() f.search:SetText("") end)
        font(f, 11, 24, -306, 270, "Shared IOUs", MUTED)
        f.listEmpty=font(f,12,34,-348,250,"",MUTED); f.listEmpty:SetHeight(150)
        f.rows={}
        for index=1,5 do
            local row = CreateFrame("Button",nil,f,"BackdropTemplate")
            row:SetSize(270,56); row:SetPoint("TOPLEFT",24,-328-(index-1)*60)
            row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",edgeSize=8})
            row.title=font(row,13,10,-7,250,"",GOLD)
            row.amount=font(row,11,10,-24,250,"")
            row.state=font(row,10,10,-40,250,"",MUTED)
            row.state:SetMaxLines(1); row.state:SetHeight(12)
            row:SetScript("OnClick",function() f.selected=row.offerId; f.scroll:SetVerticalScroll(0); refresh() end)
            f.rows[index]=row
        end
        panel(f,616,322,320,-306)
        f.scroll,f.content=scroll(f,566,292,338,-321)
        f.details=font(f.content,12,0,0,554,"")
        f.previous=button(f,"<",34,24,-646,function() f.page=f.page-1; f.selected=nil; refresh() end)
        f.next=button(f,">",34,260,-646,function() f.page=f.page+1; f.selected=nil; refresh() end)
        f.pages=font(f,10,70,-654,184,"",MUTED)
        f.primaryHint=font(f,11,334,-644,592,"",MUTED); f.primaryHint:SetHeight(28)
        f.accept=button(f,"Review",178,334,-678,function() IOU.ShowSharedReview(f.selected,"accept") end)
        f.decline=button(f,"Decline",128,522,-678,function() IOU.ShowSharedReview(f.selected,"decline") end)
        f.withdraw=button(f,"Withdraw",128,660,-678,function() IOU.ShowSharedReview(f.selected,"withdraw") end)
        f.retry=button(f,"Retry delivery",128,798,-678,function()
            f.problem=nil; local ok,err=S.Retry(f.selected); if not ok then f.problem=err end; refresh()
        end)
        f.closePaused=button(f,"Close locally",270,24,-715,function() IOU.ShowSharedReview(f.selected,"close") end)
        f.connectSelected=button(f,"Connect selected player",270,24,-715,function()
            local offer=S.GetOffer(f.connectId)
            local terms=termsOf(offer)
            if not offer or f.selected ~= f.connectId or offer.terms ~= f.connectTerms or offer.state ~= f.connectState
                or offer.state == "PAUSED" or offer.localClosed
                or not terms or peerOf(offer,terms) ~= f.connectPeer then
                f.problem="The selected offer changed. Select it again before enabling sharing."
                IOU.UpdateSharedOverview(); return
            end
            if S.IsEnabled() or S.IsRecoveryPending() then
                f.problem="Disconnect or finish the recovery review before enabling this player."; refresh(); return
            end
            f.peer:SetText(f.connectPeer)
            local ok,err=S.Enable(f.connectPeer)
            f.problem=not ok and err or nil; refresh()
        end)
        f.moreMenu=panel(f,240,204,686,-490)
        f.moreMenu:SetFrameLevel(f:GetFrameLevel()+12); f.moreMenu:EnableMouse(true); f.moreMenu:Hide()
        local function action(mode)
            local id=f.moreId
            local offer=id and S.GetOffer(id)
            f.moreOpen=false; f.moreMenu:Hide()
            if f.selected~=id or not offer or offer.terms~=f.moreTerms or offer.state~=f.moreState or S.GetPeer()~=f.morePeer then
                f.problem="This IOU changed. Open More again."
                IOU.UpdateSharedOverview(); return
            end
            IOU.ShowSharedPayment(id,mode); refresh()
        end
        f.payment=button(f.moreMenu,"Adjust payment",216,12,-12,function() action("payment") end)
        f.settle=button(f.moreMenu,"Mark paid",216,12,-48,function() action("settle") end)
        f.correction=button(f.moreMenu,"Undo payment",216,12,-84,function() action("correction") end)
        f.filterButtons.all=button(f.moreMenu,viewCaptions.all,216,12,-120,function()
            f.moreOpen=false; f.moreMenu:Hide()
            f.filter="all"; f.filterInitialized=true; f.selected=nil; f.page=1; refresh()
        end)
        f.backups=button(f.moreMenu,"Backups",216,12,-156,function()
            f.moreOpen=false; f.moreMenu:Hide(); refresh(); IOU.ShowSharedBackup()
        end)
        f.more=button(f,"More",128,798,-715,function()
            f.moreOpen=not f.moreOpen; f.moreMenu:SetShown(f.moreOpen)
            f.moreId,f.moreTerms,f.moreState,f.morePeer=nil,nil,nil,S.GetPeer()
            if f.moreOpen and f.overview then
                for _,offer in ipairs(f.overview.offers) do
                    if offer.offerId==f.selected then f.moreId,f.moreTerms,f.moreState=offer.offerId,offer.terms,offer.state; break end
                end
            end
            refresh()
        end)
        f.peer:SetScript("OnTextChanged",function()
            f.enable:SetEnabled(not S.IsEnabled() and not S.IsRecoveryPending()
                and not f.overviewError and f.peer:GetText():find("%S") ~= nil)
        end)
        f.peer:SetScript("OnEscapePressed",function() f:Hide() end)
        f:SetScript("OnHide",function()
            f.peer:ClearFocus()
            f.search:ClearFocus()
            if UI.sharedForm then UI.sharedForm:Hide() end
            if UI.sharedReview then UI.sharedReview:Hide() end
            if UI.sharedPaymentForm then UI.sharedPaymentForm:Hide() end
            f.moreOpen=false; f.moreMenu:Hide()
            -- Hiding the board does not end an explicitly enabled session.
            -- Disconnect, reload and logout retain their existing stop rules.
        end)
    end
    local f=UI.shared
    if peer and not S.IsEnabled() then f.peer:SetText(peer) end
    if view and viewCaptions[view] then
        f.filter=view; f.filterInitialized=true; f.page=1; f.selected=nil
        if f.search:GetText() ~= "" then f.search:SetText("") end
    end
    f.identity:SetText("You: " .. literal(IOU.Transport.GetLocalName() or "name unavailable"))
    IOU.UpdateSharedOverview(); f:Show()
end
