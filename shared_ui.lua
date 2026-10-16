local _, IOU = ...
local UI, S, C = IOU.UI, IOU.SharedService, IOU.SharedCodec
local H = UI.Helpers
local font, panel, button, edit, scroll, window, literal = H.font, H.panel, H.button, H.edit, H.scroll, H.window, H.literal
local GOLD, MUTED = {0.88, 0.73, 0.42}, {0.65, 0.66, 0.63}
local stateNames = {OFFER_OPEN="Waiting for acceptance", OFFER_RECEIVED="Needs your review",
    ACCEPT_PENDING="Acceptance sent; awaiting commitment", DECLINE_PENDING="Decline sent; awaiting outcome",
    COMMITTED="Agreed", DECLINED="Declined", WITHDRAWN="Withdrawn", PAUSED="Paused; review needed"}
local refresh

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
    return offer.localClosed and "Paused; reviewed locally" or stateNames[offer.state] or offer.state
end
local function reviewText(offer)
    local terms = termsOf(offer)
    if not terms then return "This agreement's terms could not be read." end
    local text = {"Proposer: " .. terms.proposer, "Recipient: " .. terms.recipient,
        "", "Debtor: " .. terms.debtor, "Creditor: " .. terms.creditor,
        "Amount: " .. IOU.Ledger.FormatMoney(terms.amountCopper),
        "Due: " .. (terms.dueUTC == 0 and "No deadline" or utc("!%Y-%m-%d %H:%M:%S UTC", terms.dueUTC)),
        "", "Note: " .. (terms.note == "" and "(none)" or terms.note),
        "", "Status: " .. summary(offer)}
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
    if IOU.SharedPaymentDetails then text[#text+1] = IOU.SharedPaymentDetails(offer) end
    text[#text+1] = ""
    text[#text+1] = "Agreement: " .. offer.agreementId
    text[#text+1] = "Offer: " .. offer.offerId
    text[#text+1] = ""
    text[#text+1] = "History"
    for _, event in ipairs(offer.history) do
        text[#text+1] = utc("!%Y-%m-%d %H:%M UTC", event.at) .. " / " .. (event.kind:gsub("_", " "))
    end
    return table.concat(text, "\n")
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

function IOU.ShowSharedReview(id, action)
    local offer, err = S.GetOffer(id)
    if not offer then if UI.shared then UI.shared.problem=err; refresh() end; return end
    local valid = action == "accept" and offer.role == "recipient" and offer.state == "OFFER_RECEIVED"
        or action == "decline" and offer.role == "recipient" and offer.state == "OFFER_RECEIVED"
        or action == "withdraw" and offer.role == "proposer" and offer.state == "OFFER_OPEN"
        or action == "close" and offer.state == "PAUSED" and not offer.localClosed and not S.IsEnabled()
    if not valid then return end
    if not UI.sharedReview then
        local f = window("IOUSharedReviewWindow", 650, 666)
        UI.sharedReview = f
        f.title = font(f, 21, 22, -22, 580, "", GOLD)
        f.scroll, f.content = scroll(f, 574, 356, 24, -68)
        f.details = font(f.content, 12, 0, 0, 564, "")
        f.explanation = font(f, 12, 24, -443, 594, "", MUTED)
        f.reasonCaption = font(f, 11, 24, -506, 594, "Reason for local review", MUTED)
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
        button(f, "Back", 148, 470, -617, function() f:Hide() end)
        f.reason:SetScript("OnEscapePressed", function() f:Hide() end)
        f:SetScript("OnHide", function() f.reason:ClearFocus() end)
    end
    local f = UI.sharedReview
    f.offerId, f.terms, f.state, f.action = id, offer.terms, offer.state, action
    local captions = {accept="Accept these terms", decline="Decline this offer", withdraw="Withdraw this proposal", close="Mark reviewed locally"}
    local terms = termsOf(offer)
    f.title:SetText(action == "close" and "Review interrupted offer"
        or terms.kind == "GOLD_PAYMENT" and "Review payment"
        or terms.kind == "GOLD_CORRECTION" and "Review correction" or "Review agreement")
    f.details:SetText(literal(reviewText(offer)))
    f.content:SetHeight(math.max(356, f.details:GetStringHeight() + 16)); f.scroll:SetVerticalScroll(0)
    f.explanation:SetText(action == "close"
        and "This only records your local review. It does not cancel or settle the other player's record. Reconcile with them before proposing a replacement."
        or "Read the full names, amount, note and any payment history or correction target. Confirming records your decision about these exact terms; it does not verify a trade.")
    f.reason:SetShown(action == "close"); f.reasonCaption:SetShown(action == "close")
    f.reason:SetText(""); f.status:SetText(""); f.confirm:SetText(captions[action])
    f.confirm:SetEnabled(not not reviewCurrent(f)); f:Show()
end

function IOU.ShowSharedProposal()
    if not S.IsEnabled() then return end
    if not UI.sharedForm then
        local f = window("IOUSharedProposalWindow", 624, 600)
        UI.sharedForm = f
        font(f, 21, 22, -22, 560, "Propose a gold agreement", GOLD)
        font(f, 11, 24, -63, 560, "Other player's full name", MUTED)
        f.peer = edit(f, 556, 28, -84, 96); f.peer:SetEnabled(false)
        f.dirButtons = {}
        for index, choice in ipairs({{"owe", "I will owe them"}, {"owed", "They will owe me"}}) do
            local key = choice[1]
            f.dirButtons[key] = button(f, choice[2], 270, 24 + (index-1)*286, -130, function()
                f.direction = key
                for direction, b in pairs(f.dirButtons) do b:SetEnabled(direction ~= key) end
            end)
        end
        f.money = H.moneyFields(f, 24, -178)
        font(f, 11, 24, -250, 560, "Due day (YYYY-MM-DD, end of day UTC; optional)", MUTED)
        f.due = edit(f, 556, 28, -271, 10)
        font(f, 11, 24, -317, 560, "Note (plain text; optional)", MUTED)
        f.note = edit(f, 556, 28, -338, 512)
        font(f, 12, 24, -392, 560, "The other player must review and accept these terms. Sending a proposal does not add it to your personal ledger or move any gold.", MUTED)
        f.status = font(f, 12, 24, -463, 560, "", GOLD); f.status:SetHeight(54)
        f.send = button(f, "Send proposal", 276, 24, -550, function()
            if not S.IsEnabled() or S.GetPeer() ~= f.boundPeer then f.status:SetText("The connected player changed. Close this draft and start a new proposal."); return end
            local amount, problem = f.money:Read()
            if not amount then f.status:SetText(problem); return end
            local due, dueError = IOU.ParseSharedDueDate(f.due:GetText())
            if not due then f.status:SetText(dueError); return end
            local offer, err, saved = S.Propose({peer=f.boundPeer, direction=f.direction,
                amountCopper=amount, dueUTC=due, note=f.note:GetText()})
            if not offer then
                if saved then
                    if UI.shared then UI.shared.selected=saved.offerId; UI.shared.page=1; UI.shared.problem=err end
                    f:Hide(); refresh()
                else f.status:SetText(literal(err)) end
                return
            end
            if UI.shared then UI.shared.selected=offer.offerId; UI.shared.page=1 end
            f:Hide(); refresh()
        end)
        button(f, "Back", 148, 442, -550, function() f:Hide() end)
        for _, box in ipairs({f.due, f.note, f.money[1], f.money[2], f.money[3]}) do
            box:SetScript("OnEscapePressed", function() f:Hide() end)
        end
        f:SetScript("OnHide", function()
            f.due:ClearFocus(); f.note:ClearFocus()
            for _, box in ipairs(f.money) do box:ClearFocus() end
        end)
    end
    local f = UI.sharedForm
    f.boundPeer = S.GetPeer(); f.peer:SetText(f.boundPeer); f.direction="owe"
    f.dirButtons.owe:SetEnabled(false); f.dirButtons.owed:SetEnabled(true)
    f.money:Fill(0); f.note:SetText(""); f.due:SetText(""); f.status:SetText(""); f:Show()
end

refresh = function()
    local f = UI.shared
    if not f then return end
    local offers, err = S.List()
    offers = offers or {}
    local enabled = S.IsEnabled()
    f.status:SetText(literal(f.problem or err or S.GetStatus()))
    f.peer:SetEnabled(not enabled); f.target:SetEnabled(not enabled)
    f.enable:SetEnabled(not enabled); f.stop:SetEnabled(enabled); f.propose:SetEnabled(enabled)
    f.page = math.max(1, math.min(f.page or 1, math.max(1, math.ceil(#offers/5))))
    f.pages:SetText("Page " .. f.page .. " / " .. math.max(1, math.ceil(#offers/5)) .. "  -  " .. #offers .. " offers")
    f.previous:SetEnabled(f.page > 1); f.next:SetEnabled(f.page*5 < #offers)
    local selected
    for _, offer in ipairs(offers) do if offer.offerId == f.selected then selected=offer end end
    if not selected and offers[1] then selected=offers[1]; f.selected=selected.offerId end
    for index, row in ipairs(f.rows) do
        local offer = offers[(f.page-1)*5+index]
        if offer then
            local terms = termsOf(offer)
            row.offerId = offer.offerId
            local kind = terms and (terms.kind == "GOLD_PAYMENT" and "Payment: " or terms.kind == "GOLD_CORRECTION" and "Correction: " or "") or ""
            row.title:SetText(literal(terms and kind .. peerOf(offer,terms) or "Unreadable offer"))
            row.amount:SetText(terms and IOU.Ledger.FormatMoney(terms.amountCopper) or "")
            row.state:SetText(literal(summary(offer)))
            row:SetBackdropColor(offer.offerId==f.selected and 0.22 or 0.10, offer.offerId==f.selected and 0.20 or 0.12, 0.08, 1)
            row:Show()
        else row.offerId=nil; row:Hide() end
    end
    f.details:SetText(literal(selected and reviewText(selected) or "Choose a connected player and propose a gold agreement.\n\nReceived offers appear here for your review.\n\nBoth players must enable sharing with each other's full name. Keep this window open during the handshake."))
    f.content:SetHeight(math.max(376, f.details:GetStringHeight()+16))
    local connected = selected and connectedTo(selected) and not selected.localClosed
    local received = selected and selected.role=="recipient" and selected.state=="OFFER_RECEIVED"
    f.accept:SetEnabled(connected and received or false)
    f.decline:SetEnabled(connected and received or false)
    f.withdraw:SetEnabled(connected and selected.role=="proposer" and selected.state=="OFFER_OPEN" or false)
    local retryable = selected and (selected.role=="proposer" and selected.state~="PAUSED"
        or selected.role=="recipient" and (selected.state=="ACCEPT_PENDING" or selected.state=="DECLINE_PENDING" or selected.state=="COMMITTED"))
    f.retry:SetEnabled(connected and retryable or false)
    f.closePaused:SetEnabled(selected and selected.state=="PAUSED" and not selected.localClosed and not enabled or false)
    local review = UI.sharedReview
    if review and review:IsShown() and not reviewCurrent(review) then
        review.confirm:SetEnabled(false); review.status:SetText("This offer or connection changed. Close this review and select it again.")
    end
    if IOU.RefreshSharedPayments then IOU.RefreshSharedPayments(selected) end
end
IOU.RefreshShared = refresh

function IOU.ShowShared(peer)
    if not IOU.Initialize() then return end
    S.Initialize()
    if not UI.shared then
        local f = window("IOUSharedWindow", 960, 730)
        UI.shared = f
        f.page=1
        font(f, 24, 22, -22, 650, "Shared agreements", GOLD)
        font(f, 11, 760, -32, 150, "Experimental alpha", MUTED)
        font(f, 12, 24, -66, 896, "Both players choose each other's full name and enable sharing. Offers require explicit review and acceptance.\nKeep this window open while agreeing; closing it disconnects and pauses unfinished offers.", MUTED)
        f.identity = font(f, 11, 24, -112, 896, "", GOLD)
        f.peer = edit(f, 446, 28, -136, 96)
        f.target = button(f, "Use target", 110, 492, -136, function()
            local name, err = IOU.Transport.GetUnitName("target")
            f.problem=err; if name then f.peer:SetText(name) end; refresh()
        end)
        f.enable = button(f, "Enable for player", 178, 614, -136, function()
            f.peer:ClearFocus(); f.problem=nil
            local ok, err = S.Enable(f.peer:GetText())
            if not ok then f.problem=err end; refresh()
        end)
        f.stop = button(f, "Disconnect", 122, 804, -136, function()
            f.problem=nil; local ok, err = S.Disable(); if not ok then f.problem=err end; refresh()
        end)
        f.status = font(f, 12, 24, -178, 902, "", GOLD); f.status:SetHeight(34)
        f.propose = button(f, "+ Propose gold", 270, 24, -218, IOU.ShowSharedProposal)
        font(f, 11, 24, -260, 270, "This character's shared offers", MUTED)
        f.rows={}
        for index=1,5 do
            local row = CreateFrame("Button",nil,f,"BackdropTemplate")
            row:SetSize(270,62); row:SetPoint("TOPLEFT",24,-282-(index-1)*66)
            row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",edgeSize=8})
            row.title=font(row,13,10,-7,250,"",GOLD)
            row.amount=font(row,11,10,-26,250,"")
            row.state=font(row,10,10,-44,250,"",MUTED)
            row:SetScript("OnClick",function() f.selected=row.offerId; f.scroll:SetVerticalScroll(0); refresh() end)
            f.rows[index]=row
        end
        panel(f,616,406,320,-218)
        f.scroll,f.content=scroll(f,566,376,338,-233)
        f.details=font(f.content,12,0,0,554,"")
        f.previous=button(f,"<",34,24,-632,function() f.page=f.page-1; refresh() end)
        f.next=button(f,">",34,260,-632,function() f.page=f.page+1; refresh() end)
        f.pages=font(f,10,70,-640,184,"",MUTED)
        f.accept=button(f,"Review / accept",178,334,-637,function() IOU.ShowSharedReview(f.selected,"accept") end)
        f.decline=button(f,"Decline",128,522,-637,function() IOU.ShowSharedReview(f.selected,"decline") end)
        f.withdraw=button(f,"Withdraw",128,660,-637,function() IOU.ShowSharedReview(f.selected,"withdraw") end)
        f.retry=button(f,"Retry",128,798,-637,function()
            f.problem=nil; local ok,err=S.Retry(f.selected); if not ok then f.problem=err end; refresh()
        end)
        f.closePaused=button(f,"Review paused offer",270,24,-674,function() IOU.ShowSharedReview(f.selected,"close") end)
        f.payment=button(f,"Record payment",178,334,-674,function() IOU.ShowSharedPayment(f.selected,"payment") end)
        f.settle=button(f,"Settle balance",178,522,-674,function() IOU.ShowSharedPayment(f.selected,"settle") end)
        f.correction=button(f,"Correct payment",216,710,-674,function() IOU.ShowSharedPayment(f.selected,"correction") end)
        f.peer:SetScript("OnEscapePressed",function() f:Hide() end)
        f:SetScript("OnHide",function()
            f.peer:ClearFocus()
            if UI.sharedForm then UI.sharedForm:Hide() end
            if UI.sharedReview then UI.sharedReview:Hide() end
            if UI.sharedPaymentForm then UI.sharedPaymentForm:Hide() end
            S.Disable()
        end)
        IOU.OnSharedChanged=function() f.problem=nil; refresh() end
    end
    local f=UI.shared
    if peer and not S.IsEnabled() then f.peer:SetText(peer) end
    f.identity:SetText("You: " .. literal(IOU.Transport.GetLocalName() or "name unavailable"))
    refresh(); f:Show()
end
