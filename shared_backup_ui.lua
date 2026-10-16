local _, IOU = ...
local UI, S, C = IOU.UI, IOU.SharedService, IOU.SharedCodec
local H = UI.Helpers
local font, button, scroll, window, literal = H.font, H.button, H.scroll, H.window, H.literal
local GOLD, MUTED = {0.88, 0.73, 0.42}, {0.65, 0.66, 0.63}
local MAX_TEXT = IOU.SharedBackup.MAX_BYTES
local renderReview, previewBackup

local function timestamp(value)
    if not value then return "Unavailable" end
    local ok, text = pcall(date, "!%Y-%m-%d %H:%M UTC", value)
    return ok and type(text) == "string" and text or "Unavailable"
end

local function balance(copper, state)
    if copper == nil then return "No balance available" end
    return IOU.Ledger.FormatMoney(copper) .. (state and " / " .. state:lower() or "")
end

local function offerLines(lines, caption, offer)
    lines[#lines+1] = caption .. ": " .. (offer and offer.state or "No record")
    if not offer then return end
    lines[#lines+1] = "Role: " .. offer.role .. " / Receipt: " .. (offer.delivery or "Not observed")
    lines[#lines+1] = "Local decision: " .. offer.consent
    if offer.pausedFrom then lines[#lines+1] = "Paused from: " .. offer.pausedFrom end
    local terms = C.ParseTerms(offer.terms)
    if terms then
        lines[#lines+1] = "Proposer: " .. terms.proposer .. " / Recipient: " .. terms.recipient
        lines[#lines+1] = "Debtor: " .. terms.debtor .. " / Creditor: " .. terms.creditor
        lines[#lines+1] = "Amount: " .. IOU.Ledger.FormatMoney(terms.amountCopper)
        if terms.kind == "GOLD_OBLIGATION" then
            lines[#lines+1] = "Due: " .. (terms.dueUTC == 0 and "No deadline" or timestamp(terms.dueUTC))
        else
            lines[#lines+1] = "Event: " .. (terms.kind == "GOLD_CORRECTION" and "Correction" or "Payment")
            lines[#lines+1] = "Original agreement: " .. terms.parentOfferId
            if terms.reversesId ~= "" then lines[#lines+1] = "Reverses payment: " .. terms.reversesId end
        end
        lines[#lines+1] = "Note: " .. (terms.note == "" and "(none)" or terms.note)
    end
    local messages = offer.messages or {}
    if messages.accept then lines[#lines+1] = "Acceptance: " .. messages.accept.acceptanceId end
    if messages.commit then lines[#lines+1] = "Commitment: " .. messages.commit.commitId end
    if messages.ack then lines[#lines+1] = "Acknowledgment retained: " .. messages.ack.messageId end
    for _, event in ipairs(offer.history or {}) do
        lines[#lines+1] = timestamp(event.at) .. " / " .. event.kind:gsub("_", " "):lower()
    end
end

local function closeLines(lines, caption, marker)
    if marker then
        lines[#lines+1] = caption .. " local review: " .. timestamp(marker.at)
        lines[#lines+1] = "Reason: " .. marker.reason
    end
end

local function previewText(preview)
    local lines = {
        "Owner: " .. preview.owner,
        "Character: " .. preview.character,
        "Backup created: " .. timestamp(preview.exportedAt), "",
        "Backup records: " .. preview.total,
        "Missing locally: " .. preview.missing .. " / Identical: " .. preview.identical,
        "Different versions: " .. preview.different .. " / Only on this client: " .. preview.currentOnly,
        "Additional local review markers: " .. preview.closedAdded, "",
        "Restore adds missing history and keeps every existing record. Different versions stay available in the saved backup for comparison; they are never overwritten.",
        "Restored records are historical evidence. They do not prove a new acceptance, delivery or gold transfer."
    }
    if preview.problem then lines[#lines+1] = ""; lines[#lines+1] = "Restore unavailable: " .. preview.problem end
    if #(preview.balances or {}) > 0 then
        lines[#lines+1] = ""; lines[#lines+1] = "Balance comparison"
        for _, item in ipairs(preview.balances) do
            lines[#lines+1] = item.peer .. " / " .. item.offerId
            lines[#lines+1] = "Backup: " .. balance(item.backupCopper, item.backupState)
            lines[#lines+1] = "Current: " .. balance(item.currentCopper, item.currentState)
            lines[#lines+1] = "After restoring missing history: " .. balance(item.candidateCopper, item.candidateState)
        end
    end
    local captions = {missing="Missing locally", identical="Identical", different="Different; current version kept", currentOnly="Only on this client; kept"}
    for _, row in ipairs(preview.rows or {}) do
        lines[#lines+1] = ""; lines[#lines+1] = captions[row.classification] .. " / " .. row.offerId
        if row.classification == "identical" then
            offerLines(lines, "Record", row.current or row.backup)
        else
            offerLines(lines, "Backup", row.backup)
            offerLines(lines, "Current", row.current)
        end
        closeLines(lines, "Backup", row.backupClosed)
        closeLines(lines, "Current", row.currentClosed)
    end
    return table.concat(lines, "\n")
end

local function refreshShared()
    if IOU.RefreshShared then IOU.RefreshShared() end
end

local function buildReview()
    if UI.sharedRecoveryReview then return UI.sharedRecoveryReview end
    local f = window("IOUSharedRecoveryReviewWindow", 820, 730)
    UI.sharedRecoveryReview = f
    f.title = font(f, 22, 24, -24, 746, "Review shared backup", GOLD)
    f.explanation = font(f, 12, 24, -65, 770, "", MUTED)
    f.explanation:SetHeight(69)
    f.scroll, f.content = scroll(f, 742, 400, 26, -143)
    f.details = font(f.content, 12, 0, 0, 730, "")
    f.status = font(f, 12, 24, -561, 770, "", GOLD); f.status:SetHeight(56)
    f.stage = button(f, "Stage recovery", 222, 24, -633, function()
        local source = UI.sharedBackup
        if f.stale or not source or source.box:GetText() ~= f.backupText then
            f.stage:SetEnabled(false)
            f.status:SetText("The pasted backup changed. Preview it again before staging recovery.")
            return
        end
        local review, err = S.StageRecovery(f.backupText, f.currentFingerprint)
        if not review then f.status:SetText(literal(err)); f.stage:SetEnabled(false); return end
        renderReview(review); refreshShared()
    end)
    f.restore = button(f, "Restore missing history", 232, 24, -633, function()
        local ok, err = S.ResolveRecovery("restore", f.token)
        if not ok then f.status:SetText(literal(err)); f.restore:SetEnabled(false); return end
        local review, problem = S.GetRecovery()
        if review then renderReview(review) else f.status:SetText(literal(problem)) end
        refreshShared()
    end)
    f.keep = button(f, "Keep current records", 218, 268, -633, function()
        local ok, err = S.ResolveRecovery("keep", f.token)
        if not ok then f.status:SetText(literal(err)); f.keep:SetEnabled(false); return end
        local review, problem = S.GetRecovery()
        if review then renderReview(review) else f.status:SetText(literal(problem)) end
        refreshShared()
    end)
    f.refresh = button(f, "Refresh review", 154, 498, -633, function()
        if f.staged then IOU.ShowSharedRecoveryReview()
        elseif UI.sharedBackup then previewBackup(UI.sharedBackup) end
    end)
    button(f, "Back", 126, 664, -633, function() f:Hide() end)
    f.exportBackup = button(f, "Copy staged backup", 222, 24, -680, function() IOU.ShowSharedBackup("backup") end)
    f.exportBefore = button(f, "Copy records before recovery", 262, 258, -680, function() IOU.ShowSharedBackup("before") end)
    return f
end

renderReview = function(review, text)
    local f = buildReview()
    local staged = review.status ~= nil
    local pending = review.status == "PENDING"
    local preview = staged and review.preview or review
    f.staged, f.stale = staged, false
    f.backupText, f.currentFingerprint, f.token = text, preview.currentFingerprint, review.token
    f.title:SetText(not staged and "Review shared backup" or pending and "Shared recovery needs a decision"
        or review.status == "RESTORED" and "Shared history restored" or "Current shared records kept")
    f.explanation:SetText(not staged
        and "Review the records and balances below. Stage recovery saves both snapshots, disconnects sharing and pauses unfinished offers. Nothing is restored until you choose Restore missing history."
        or pending
        and "Sharing is paused until you choose Restore missing history or Keep current records. Existing records are preserved. Compare different versions with the other player before creating a replacement agreement."
        or "Sharing remains off. Review restored or differing history with the other player before enabling it again. The staged backup and records from before recovery remain available below.")
    f.details:SetText(literal(previewText(preview)))
    f.content:SetHeight(math.max(400, f.details:GetStringHeight() + 16)); f.scroll:SetVerticalScroll(0)
    f.status:SetText(literal(review.problem or preview.problem or (not staged and "Preview only. Current shared records and connection are unchanged."
        or pending and "Choose how to finish this recovery. Closing this window keeps sharing paused."
        or "Decision saved: " .. timestamp(review.resolvedAt))))
    f.stage:SetShown(not staged); f.stage:SetEnabled(not staged)
    f.restore:SetShown(staged); f.restore:SetEnabled(pending and review.canRestore == true)
    f.keep:SetShown(staged); f.keep:SetEnabled(pending)
    f.exportBackup:SetShown(staged); f.exportBefore:SetShown(staged)
    f:Show()
end

function IOU.ShowSharedRecoveryReview()
    if not IOU.Initialize() then return end
    local review, err = S.GetRecovery()
    if not review then
        if UI.sharedBackup then UI.sharedBackup.status:SetText(literal(err or "No shared recovery has been staged.")) end
        if not UI.sharedBackup and IOU.Message then IOU.Message(err or "No shared recovery has been staged.") end
        return nil, err
    end
    renderReview(review)
end

previewBackup = function(f)
    local text = f.box:GetText()
    local preview, err = S.PreviewBackup(text)
    if not preview then f.status:SetText("Invalid shared backup: " .. literal(err)); return end
    renderReview(preview, text)
end

function IOU.ShowSharedBackup(mode)
    if not IOU.Initialize() then return end
    S.Initialize()
    if not mode and S.IsRecoveryPending() then IOU.ShowSharedRecoveryReview(); return end
    if not UI.sharedBackup then
        local f = window("IOUSharedBackupWindow", 780, 624)
        UI.sharedBackup = f
        font(f, 22, 24, -24, 690, "Shared agreement backups", GOLD)
        font(f, 12, 24, -68, 728, "An IOUS1 snapshot includes this character's shared agreements, payments, corrections and local acceptance history. Personal IOUs use a separate export.", MUTED)
        font(f, 11, 24, -120, 728, "Copy with Ctrl+C and save outside the game, or paste a complete IOUS1 backup to preview.", MUTED)
        f.box, _, f.scroll = H.multiline(f, 704, 288, 29, -159, MAX_TEXT)
        f.status = font(f, 12, 24, -470, 730, "", GOLD); f.status:SetHeight(71)
        f.preview = button(f, "Preview backup", 178, 24, -568, function() previewBackup(f) end)
        f.export = button(f, "Current export", 160, 214, -568, function() IOU.ShowSharedBackup("export") end)
        f.paste = button(f, "Paste backup", 160, 386, -568, function() IOU.ShowSharedBackup("import") end)
        f.recovery = button(f, "Recovery review", 176, 558, -568, IOU.ShowSharedRecoveryReview)
        f.box:SetScript("OnTextChanged", function()
            local review = UI.sharedRecoveryReview
            if review and not review.staged and review.backupText ~= f.box:GetText() then
                review.stale = true; review.stage:SetEnabled(false)
                review.status:SetText("The pasted backup changed. Preview it again before staging recovery.")
            end
        end)
    end
    local f = UI.sharedBackup
    local text, err
    if mode == "import" then text = ""
    elseif mode == "backup" or mode == "before" then text, err = S.ExportRecovery(mode)
    else text, err = S.ExportBackup() end
    if not text then f.status:SetText(literal(err)); f:Show(); return end
    f.box:SetText(text)
    f.status:SetText(mode == "import" and "Paste the complete shared backup, then Preview backup. Preview does not change records or send messages."
        or mode == "before" and "Records saved immediately before this recovery. Copy this snapshot to keep an external copy."
        or mode == "backup" and "The original staged backup. Different versions remain here for comparison."
        or "Shared snapshot selected. Copy it to keep an external backup. It records historical acknowledgments, not a fresh confirmation from the other player.")
    f.recovery:SetEnabled(S.HasRecovery())
    f.scroll:SetVerticalScroll(0); f:Show(); f.box:SetFocus(); f.box:HighlightText()
end
