local _, IOU = ...
local L = IOU.Ledger
local UI = {tab = "owed", page = 1, kind = "all", sort = "newest"}
IOU.UI = UI
local GOLD = {0.88, 0.73, 0.42}
local MUTED = {0.65, 0.66, 0.63}

local function literal(text) return (tostring(text or ""):gsub("|", "||")) end
local function labelText(entry)
    local text = entry.label or ""
    if entry.kind == "item" then
        local label = text:match("|Hitem:[^|]+|h(%[[^|]+%])|h")
        if label then return literal((label:gsub("%s+", " "))) end
    end
    return literal((text:gsub("%s+", " ")))
end
local function notePreview(text)
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local cutoff, breaks = math.min(#normalized, 240), 0
    for index = 1, cutoff do
        if normalized:byte(index) == 10 then
            breaks = breaks + 1
            if breaks == 4 then cutoff = index - 1; break end
        end
    end
    -- Do not split a UTF-8 continuation sequence at the preview boundary.
    while cutoff > 0 do
        local nextByte = normalized:byte(cutoff + 1)
        if not nextByte or nextByte < 128 or nextByte > 191 then break end
        cutoff = cutoff - 1
    end
    if cutoff < #normalized then return literal(normalized:sub(1, cutoff)) .. "...", true end
    return literal(normalized), false
end
local function amount(entry, value)
    if entry.kind == "money" then return L.FormatMoney(value) end
    return tostring(value) .. " x " .. labelText(entry)
end
local function dateText(stamp) return date("%d %b %Y, %H:%M", stamp) end
local function options() return {kind = UI.kind, sort = UI.sort, now = time()} end
local function font(parent, size, x, y, width, text, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size, "")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetTextColor(unpack(color or {0.91, 0.89, 0.82}))
    fs:SetText(text or "")
    return fs
end
local function panel(parent, width, height, x, y)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(width, height)
    frame:SetPoint("TOPLEFT", x, y)
    frame:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3}})
    frame:SetBackdropColor(0.065, 0.074, 0.067, 0.98)
    frame:SetBackdropBorderColor(0.42, 0.37, 0.25, 1)
    return frame
end
local function button(parent, text, width, x, y, action)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 26)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", action)
    return b
end
local function edit(parent, width, x, y, max, numeric)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetSize(width, 26)
    box:SetPoint("TOPLEFT", x, y)
    box:SetMaxLetters(max or 2000)
    box:SetMaxBytes(max or 2000)
    if numeric then box:SetNumeric(true) end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end
local function scroll(parent, width, height, x, y)
    local frame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    frame:SetSize(width, height)
    frame:SetPoint("TOPLEFT", x, y)
    local child = CreateFrame("Frame", nil, frame)
    child:SetSize(width, height)
    frame:SetScrollChild(child)
    return frame, child
end
local function multiline(parent, width, height, x, y, max)
    local shell = panel(parent, width + 14, height + 10, x - 7, y + 5)
    local sf = CreateFrame("ScrollFrame", nil, shell, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 8, -6)
    sf:SetSize(width - 22, height)
    local box = CreateFrame("EditBox", nil, sf)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(ChatFontNormal)
    box:SetSize(width - 22, height)
    box:SetMaxLetters(max)
    box:SetMaxBytes(max)
    box:SetTextInsets(2, 2, 2, 2)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sf:SetScrollChild(box)
    box:SetScript("OnCursorChanged", function(self, _, cursorY, _, cursorHeight)
        local current = sf:GetVerticalScroll()
        local top = -cursorY
        if top < current then sf:SetVerticalScroll(top)
        elseif top + cursorHeight > current + sf:GetHeight() then
            sf:SetVerticalScroll(top + cursorHeight - sf:GetHeight())
        end
    end)
    return box, shell, sf
end
local function fit(frame, width, height)
    local scale = math.min(1, (UIParent:GetWidth() - 32) / width, (UIParent:GetHeight() - 32) / height)
    frame:SetScale(math.max(0.4, scale))
end
local function window(name, width, height)
    local frame = panel(UIParent, width, height, 0, 0)
    -- All windows remain ordinary, unprotected frames.
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetScript("OnShow", function(self) fit(self, width, height) end)
    local close = button(frame, "X", 26, width - 36, -10, function() frame:Hide() end)
    close:SetFrameLevel(frame:GetFrameLevel() + 5)
    frame:Hide()
    if name then
        _G[name] = frame
        UISpecialFrames[#UISpecialFrames + 1] = name
    end
    return frame
end
local function integer(box, required)
    local text = box:GetText():match("^%s*(.-)%s*$")
    if text == "" and not required then return 0 end
    if not text:match("^%d+$") then return nil end
    local value = tonumber(text)
    if not value or value > L.MAX_AMOUNT then return nil end
    return value
end
local function moneyFields(parent, x, y)
    local fields = {}
    for index, caption in ipairs({"Gold", "Silver", "Copper"}) do
        local offset = (index - 1) * 112
        font(parent, 11, x + offset, y, 100, caption, MUTED)
        fields[index] = edit(parent, 94, x + offset + 4, y - 20, 9, true)
    end
    function fields:Read()
        local g, s, c = integer(self[1]), integer(self[2]), integer(self[3])
        if not g or not s or not c or s > 99 or c > 99 then
            return nil, "Enter whole coins; silver and copper must be 0-99."
        end
        local value = g * 10000 + s * 100 + c
        if value <= 0 or value > L.MAX_AMOUNT then return nil, "Enter a positive amount within the ledger limit." end
        return value
    end
    function fields:Fill(value)
        self[1]:SetText(tostring(math.floor(value / 10000)))
        self[2]:SetText(tostring(math.floor(value / 100) % 100))
        self[3]:SetText(tostring(value % 100))
    end
    return fields
end

local function buildMain()
    if UI.main then return end
    local f = window("IOULedgerWindow", 960, 720)
    UI.main = f
    f:SetFrameStrata("HIGH")
    f:SetScript("OnShow", function(self)
        fit(self, 960, 720)
        local position = IOU.GetSettings().position
        if position then
            self:ClearAllPoints()
            self:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
        end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        if point and relativePoint and type(x) == "number" and type(y) == "number" then
            IOU.GetSettings().position = {point=point, relativePoint=relativePoint, x=x, y=y}
        end
    end)
    font(f, 31, 22, -18, 180, "IOU", GOLD)
    UI.character = font(f, 12, 24, -55, 600, "", MUTED)
    button(f, "Settings", 104, 590, -27, function() IOU.ShowSettings() end)
    button(f, "Backups", 98, 704, -27, function() IOU.ShowBackup("export") end)
    button(f, "+ New IOU", 114, 812, -27, function() IOU.ShowAdd() end)
    UI.cards = {}
    for index, title in ipairs({"OWED TO YOU", "YOU OWE"}) do
        local card = panel(f, 445, 72, 22 + (index - 1) * 471, -82)
        local caption = font(card, 10, 14, -11, 260, title, MUTED)
        local value = font(card, 18, 14, -31, 280, "", GOLD)
        value:SetMaxLines(1); value:SetHeight(26)
        local counts = font(card, 10, 285, -14, 144, "", MUTED)
        UI.cards[index] = {value = value, counts = counts, caption = caption, title = title}
    end
    UI.tabs = {}
    for index, tab in ipairs({{"owed", "Owed to me"}, {"owe", "I owe"}, {"history", "History"}}) do
        local key = tab[1]
        UI.tabs[key] = button(f, tab[2], 114, 22 + (index - 1) * 120, -169, function()
            UI.tab, UI.page, UI.selected = key, 1, nil
            IOU.Refresh()
        end)
    end
    font(f, 11, 523, -177, 110, "Search", MUTED)
    UI.search = edit(f, 260, 630, -168, 200)
    UI.search:SetScript("OnTextChanged", function()
        UI.page, UI.selected = 1, nil
        IOU.Refresh()
    end)
    button(f, "X", 26, 903, -169, function() UI.search:SetText("") end)
    UI.typeButtons = {}
    for index, choice in ipairs({{"all", "All types"}, {"money", "Gold"}, {"item", "Items"}, {"favor", "Favors"}}) do
        local kind = choice[1]
        UI.typeButtons[kind] = button(f, choice[2], 84, 22 + (index - 1) * 92, -207, function()
            UI.kind, UI.page, UI.selected = kind, 1, nil; IOU.Refresh()
        end)
    end
    local sortChoices = {"newest", "oldest", "player", "due"}
    UI.sortButton = button(f, "Sort: newest", 180, 403, -207, function()
        for index, sort in ipairs(sortChoices) do
            if sort == UI.sort then UI.sort = sortChoices[index % #sortChoices + 1]; break end
        end
        UI.page, UI.selected = 1, nil; IOU.Refresh()
    end)
    font(f, 10, 602, -216, 325, "Search player names, descriptions and notes", MUTED)
    UI.rows = {}
    for index = 1, 5 do
        local row = CreateFrame("Button", nil, f, "BackdropTemplate")
        row:SetSize(366, 67)
        row:SetPoint("TOPLEFT", 22, -245 - (index - 1) * 74)
        row:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10})
        row:SetBackdropBorderColor(0.3, 0.3, 0.23, 1)
        row.player = font(row, 14, 12, -10, 340, "", GOLD)
        row.balance = font(row, 12, 12, -32, 340, "")
        row.context = font(row, 10, 12, -50, 340, "", MUTED)
        row.player:SetMaxLines(1); row.player:SetHeight(18)
        row.balance:SetMaxLines(1); row.balance:SetHeight(15)
        row.context:SetMaxLines(1); row.context:SetHeight(13)
        row:SetScript("OnClick", function(self) UI.selected = self.entryID; IOU.Refresh() end)
        UI.rows[index] = row
    end
    UI.empty = font(f, 14, 42, -301, 320, "")
    UI.previous = button(f, "<", 36, 22, -637, function() UI.page = UI.page - 1; UI.selected = nil; IOU.Refresh() end)
    UI.pages = font(f, 11, 71, -645, 250, "", MUTED)
    UI.next = button(f, ">", 36, 352, -637, function() UI.page = UI.page + 1; UI.selected = nil; IOU.Refresh() end)
    UI.detail = panel(f, 535, 426, 403, -245)
    local d = UI.detail
    UI.peer = font(d, 21, 16, -16, 500, "", GOLD)
    UI.peer:SetMaxLines(1); UI.peer:SetHeight(27)
    UI.context = font(d, 11, 16, -46, 500, "", MUTED)
    UI.balance = font(d, 20, 16, -72, 500, "")
    UI.balance:SetHeight(30)
    UI.balance:SetMaxLines(1)
    UI.due = font(d, 11, 16, -108, 500, "", MUTED)
    UI.detailScroll, UI.detailContent = scroll(d, 474, 196, 16, -139)
    UI.pay = button(d, "Record payment", 164, 16, -351, function() IOU.ShowAction("payment") end)
    UI.settle = button(d, "Settle IOU", 140, 190, -351, function() IOU.ShowAction("settle") end)
    UI.edit = button(d, "Edit details", 114, 16, -389, function() IOU.ShowEdit() end)
    UI.cancel = button(d, "Cancel IOU", 190, 140, -389, function()
        local entry = L.Get(IOU.GetLedger(), UI.selected)
        if entry then IOU.ShowAction(L.Status(entry) == "cancelled" and "restore" or "cancel") end
    end)
    UI.historyPrevious = button(d, "<", 30, 360, -389, function()
        UI.historyPage = math.max(1, (UI.historyPage or 1) - 1); IOU.Refresh(); UI.detailScroll:SetVerticalScroll(0)
    end)
    UI.historyPages = font(d, 10, 397, -398, 75, "", MUTED)
    UI.historyNext = button(d, ">", 30, 481, -389, function()
        UI.historyPage = (UI.historyPage or 1) + 1; IOU.Refresh(); UI.detailScroll:SetVerticalScroll(0)
    end)
    font(f, 10, 24, -698, 905, "Personal records only. Gold totals exclude items and favors. Saved automatically on logout or /reload.", MUTED)
end

function IOU.Refresh(reset)
    if not UI.main then return end
    local db = IOU.GetLedger()
    if not db then return end
    if reset then UI.selected, UI.page = nil, 1 end
    UI.character:SetText(literal(IOU.Character()) .. "  /  Your personal agreement book")
    for index, direction in ipairs({"owed", "owe"}) do
        local sum = L.Summary(db, direction, UI.search:GetText(), options())
        UI.cards[index].caption:SetText(UI.cards[index].title .. ((UI.search:GetText() ~= "" or UI.kind ~= "all") and " / FILTERED" or ""))
        UI.cards[index].value:SetText(L.FormatMoney(sum.money))
        UI.cards[index].counts:SetText(sum.active .. " open IOUs\n" .. sum.items .. " item / " .. sum.favors .. " favor\n" .. (sum.overdue or 0) .. " overdue")
    end
    for tab, b in pairs(UI.tabs) do b:SetEnabled(UI.tab ~= tab) end
    for kind, b in pairs(UI.typeButtons) do b:SetEnabled(UI.kind ~= kind) end
    UI.sortButton:SetText("Sort: " .. UI.sort)
    local entries = L.List(db, UI.tab, UI.search:GetText(), options())
    local pages = math.max(1, math.ceil(#entries / 5))
    UI.page = math.max(1, math.min(UI.page, pages))
    local selected
    for _, e in ipairs(entries) do if e.id == UI.selected then selected = e end end
    if not selected then selected = entries[(UI.page - 1) * 5 + 1] end
    UI.selected = selected and selected.id or nil
    UI.pages:SetText("Page " .. UI.page .. " / " .. pages .. "  -  " .. #entries .. " IOUs")
    UI.previous:SetEnabled(UI.page > 1)
    UI.next:SetEnabled(UI.page < pages)
    for index, row in ipairs(UI.rows) do
        local e = entries[(UI.page - 1) * 5 + index]
        if e then
            row.entryID = e.id
            row.player:SetText(literal(e.player))
            row.balance:SetText(amount(e, L.Balance(e)))
            local overdue = L.IsOverdue(e, time())
            row.context:SetText((e.kind == "money" and "Gold" or e.kind == "item" and "Items" or "Favor")
                .. "  /  " .. L.Status(e) .. "  /  #" .. e.id .. (overdue and "  /  OVERDUE" or ""))
            row.context:SetTextColor(unpack(overdue and {1, 0.4, 0.3} or MUTED))
            row:SetBackdropColor(e.id == UI.selected and 0.19 or 0.10, e.id == UI.selected and 0.18 or 0.12, 0.10, 1)
            row:Show()
        else row:Hide() end
    end
    UI.empty:SetText(#entries == 0 and ((UI.search:GetText() ~= "" or UI.kind ~= "all") and "No matching IOUs." or UI.tab == "history"
        and "Settled and cancelled IOUs appear here." or "No open IOUs.\n\nStart with + New IOU.") or "")
    if IOU.RenderTimeline then IOU.RenderTimeline(selected) end
    local cancelled = selected and L.Status(selected) == "cancelled"
    UI.pay:SetEnabled(selected ~= nil and not cancelled and L.Balance(selected) > 0)
    UI.settle:SetEnabled(selected ~= nil and not cancelled and L.Balance(selected) > 0)
    UI.edit:SetEnabled(selected ~= nil and not cancelled)
    UI.cancel:SetEnabled(selected ~= nil and (cancelled or L.Balance(selected) > 0))
    UI.cancel:SetText(cancelled and "Restore IOU" or "Cancel IOU")
    if not selected then
        UI.peer:SetText("Your agreement book")
        UI.context:SetText("Select an IOU to see its history.")
        UI.balance:SetText("")
        UI.due:SetText("")
        return
    end
    UI.peer:SetText(literal(selected.player))
    UI.context:SetText("#" .. selected.id .. "  /  " .. (selected.direction == "owed" and "Owed to you" or "You owe")
        .. "  /  " .. L.Status(selected))
    UI.balance:SetText(amount(selected, L.Balance(selected)))
    local overdue = L.IsOverdue(selected, time())
    UI.due:SetText((selected.due or 0) > 0 and ((overdue and "OVERDUE / " or "Due / ") .. IOU.FormatDueDate(selected.due)) or "No due date")
    UI.due:SetTextColor(unpack(overdue and {1, 0.4, 0.3} or MUTED))
    UI.pay:SetText(selected.kind == "money" and "Record payment" or "Record delivery")
end

-- A bounded pool avoids leaking UI objects when searching or selecting entries.
local timelinePool, undoPool, notePool = {}, {}, {}
function IOU.RenderTimeline(entry)
    for _, region in ipairs(timelinePool) do region:Hide() end
    for _, b in ipairs(undoPool) do b:Hide() end
    for _, b in ipairs(notePool) do b:Hide() end
    local lineCount, buttonCount, noteCount, y = 0, 0, 0, 0
    local function line(text, color, eventID, fullNote)
        lineCount = lineCount + 1
        local fs = timelinePool[lineCount]
        if not fs then fs = font(UI.detailContent, 11, 0, 0, 469, ""); timelinePool[lineCount] = fs end
        fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", 0, y)
        fs:SetWidth((eventID or fullNote) and 378 or 469)
        fs:SetTextColor(unpack(color or {0.82, 0.82, 0.76}))
        fs:SetText(text); fs:Show()
        local height = math.max(16, fs:GetStringHeight())
        if eventID then
            buttonCount = buttonCount + 1
            local b = undoPool[buttonCount]
            if not b then
                b = button(UI.detailContent, "Undo", 70, 394, 0, function(self) IOU.ShowAction("reverse", self.entryID, self.eventID) end)
                undoPool[buttonCount] = b
            end
            b.entryID, b.eventID = entry.id, eventID
            b:ClearAllPoints(); b:SetPoint("TOPLEFT", 394, y + 2); b:Show()
            height = math.max(height, 26)
        end
        if fullNote then
            noteCount = noteCount + 1
            local b = notePool[noteCount]
            if not b then
                b = button(UI.detailContent, "Full note", 78, 390, 0, function(self) IOU.ShowNote(self.note) end)
                notePool[noteCount] = b
            end
            b.note = fullNote
            b:ClearAllPoints(); b:SetPoint("TOPLEFT", 390, y + (eventID and -27 or 2)); b:Show()
            height = math.max(height, eventID and 55 or 26)
        end
        y = y - height - 12
    end
    local entryID, eventCount = entry and entry.id, entry and #entry.events or 0
    if UI.timelineEntry ~= entryID or UI.timelineEventCount ~= eventCount then UI.historyPage = 1 end
    local pageCount = math.max(1, math.ceil(eventCount / 10))
    UI.historyPage = math.max(1, math.min(UI.historyPage or 1, pageCount))
    UI.historyPrevious:SetEnabled(UI.historyPage > 1)
    UI.historyNext:SetEnabled(UI.historyPage < pageCount)
    UI.historyPages:SetText(UI.historyPage .. " / " .. pageCount)
    if entry then
        local initial = entry.initial or entry
        local original = {kind=entry.kind, label=initial.label}
        line("Player: " .. literal(entry.player), GOLD)
        line("Original agreement: " .. amount(original, entry.amount), GOLD)
        if entry.kind ~= "money" then line("Description: " .. labelText(entry)) end
        if entry.note ~= "" then
            local preview, shortened = notePreview(entry.note)
            line("Agreement notes\n" .. preview, nil, nil, shortened and entry.note or nil)
        end
        line("TRANSACTION HISTORY  /  PAGE " .. UI.historyPage .. " OF " .. pageCount, GOLD)
        local reversed = {}
        for _, event in ipairs(entry.events) do if event.type == "reversal" then reversed[event.reverses] = true end end
        local first = #entry.events - (UI.historyPage - 1) * 10
        for index = first, math.max(1, first - 9), -1 do
            local e = entry.events[index]
            local text, fullNote
            local preview, shortened = notePreview(e.note)
            if shortened then fullNote = e.note end
            if e.type == "reversal" then
                text = dateText(e.at) .. "  /  Reversed payment #" .. e.reverses .. "\nReason: " .. preview
            elseif e.type == "cancel" or e.type == "restore" then
                text = dateText(e.at) .. "  /  " .. (e.type == "cancel" and "IOU cancelled (balance retained)" or "IOU restored")
                    .. "\nReason: " .. preview
            elseif e.type == "amendment" then
                text = dateText(e.at) .. "  /  Details updated #" .. e.id
                if e.before.player ~= e.after.player then text = text .. "\nPlayer: " .. literal(e.before.player) .. " -> " .. literal(e.after.player) end
                if e.before.label ~= e.after.label then
                    text = text .. "\nDescription: " .. labelText({label=e.before.label, kind=entry.kind})
                        .. " -> " .. labelText({label=e.after.label, kind=entry.kind})
                end
                if e.before.due ~= e.after.due then
                    local before, after = IOU.FormatDueDate(e.before.due), IOU.FormatDueDate(e.after.due)
                    text = text .. "\nDue: " .. (before ~= "" and before or "none") .. " -> " .. (after ~= "" and after or "none")
                end
                text = text .. "\nReason: " .. preview
            else
                text = dateText(e.at) .. "  /  " .. (entry.kind == "money" and "Payment" or "Delivery") .. " #" .. e.id
                    .. "\n" .. amount(entry, e.amount) .. (reversed[e.id] and "  (reversed)" or "")
                if e.note ~= "" then text = text .. "\n" .. preview end
            end
            line(text, nil, e.type == "payment" and L.Status(entry) ~= "cancelled" and not reversed[e.id] and e.id or nil, fullNote)
            if e.type == "amendment" and e.before.note ~= e.after.note then
                for _, change in ipairs({{"Previous note", e.before.note}, {"Updated note", e.after.note}}) do
                    local textPreview, cropped = notePreview(change[2])
                    line(change[1] .. ":\n" .. (change[2] == "" and "(empty)" or textPreview), MUTED, nil, cropped and change[2] or nil)
                end
            end
        end
        line(dateText(entry.created) .. "  /  Agreement created for " .. literal(initial.player) .. "\n" .. amount(original, entry.amount), MUTED)
    end
    UI.detailContent:SetHeight(math.max(220, -y))
    if UI.timelineEntry ~= entryID or UI.timelineEventCount ~= eventCount then UI.detailScroll:SetVerticalScroll(0) end
    UI.timelineEntry, UI.timelineEventCount = entryID, eventCount
end

function IOU.ShowNote(text)
    if not UI.noteWindow then
        local f = window("IOUNoteWindow", 620, 438)
        UI.noteWindow = f
        font(f, 21, 22, -22, 550, "Full note", GOLD)
        font(f, 11, 24, -60, 550, "Read-only. The complete original note is retained in your backup.", MUTED)
        f.scroll, f.content = scroll(f, 542, 320, 24, -94)
        f.text = font(f.content, 12, 0, 0, 538, "")
    end
    local f = UI.noteWindow
    f.text:SetText(literal(text:gsub("\r\n", "\n"):gsub("\r", "\n")))
    f.content:SetHeight(math.max(320, f.text:GetStringHeight() + 16))
    f.scroll:SetVerticalScroll(0); f:Show()
end

function IOU.Toggle()
    if not IOU.Initialize() then return end
    buildMain()
    if UI.main:IsShown() then UI.main:Hide() else IOU.Refresh(); UI.main:Show() end
end

local function showMain()
    if not IOU.Initialize() then return end
    buildMain(); IOU.Refresh(); UI.main:Show()
end

local function focusEntry(entry)
    UI.tab = (L.Balance(entry) == 0 or L.Status(entry) == "cancelled") and "history" or entry.direction
    if UI.kind ~= "all" and UI.kind ~= entry.kind then UI.kind = "all" end
    UI.selected, UI.page = entry.id, 1
    local entries = L.List(IOU.GetLedger(), UI.tab, UI.search:GetText(), options())
    local matched
    for index, e in ipairs(entries) do
        if e.id == entry.id then UI.page = math.ceil(index / 5); matched = true; break end
    end
    if not matched and UI.search:GetText() ~= "" then
        UI.search:SetText("")
        UI.selected = entry.id
        for index, e in ipairs(L.List(IOU.GetLedger(), UI.tab, "", options())) do
            if e.id == entry.id then UI.page = math.ceil(index / 5); break end
        end
    end
    IOU.Refresh()
end

local function installLinkCapture()
    if UI.linkCaptureInstalled then return end
    local function capture(link)
        local target
        if UI.add and UI.add:IsShown() and UI.add.kind == "item" and UI.add.label:HasFocus() then target = UI.add.label end
        if UI.editForm and UI.editForm:IsShown() and UI.editForm.entry.kind == "item" and UI.editForm.label:HasFocus() then target = UI.editForm.label end
        if target and not (issecretvalue and issecretvalue(link)) and type(link) == "string" and #link <= 512
            and link:find("|Hitem:", 1, true) then
            target:SetText(link); target:HighlightText(); target:SetFocus()
            return true
        end
    end
    -- Run before native insertion can change a chat draft or steal focus.
    -- Other calls preserve the original function's arguments and return values.
    if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
        local original = ChatFrameUtil.InsertLink
        ChatFrameUtil.InsertLink = function(link, ...)
            if capture(link) then return true end
            return original(link, ...)
        end
        UI.linkCaptureInstalled = true
    elseif type(ChatEdit_InsertLink) == "function" then
        local original = ChatEdit_InsertLink
        ChatEdit_InsertLink = function(link, ...)
            if capture(link) then return true end
            return original(link, ...)
        end
        UI.linkCaptureInstalled = true
    end
end

function IOU.ShowAdd()
    showMain()
    if not UI.add then
        local f = window("IOUAddWindow", 506, 584)
        UI.add = f
        font(f, 21, 22, -21, 440, "New IOU", GOLD)
        font(f, 11, 24, -64, 420, "Player (include realm when needed)", MUTED)
        f.player = edit(f, 445, 29, -84, 80)
        f.direction = "owed"
        f.dirButtons = {}
        for index, choice in ipairs({{"owed", "Owed to me"}, {"owe", "I owe"}}) do
            local key = choice[1]
            f.dirButtons[key] = button(f, choice[2], 140, 23 + (index - 1) * 150, -124, function()
                f.direction = key
                for value, b in pairs(f.dirButtons) do b:SetEnabled(value ~= key) end
            end)
        end
        f.kind, f.kindButtons = "money", {}
        f.moneyGroup = CreateFrame("Frame", nil, f)
        f.moneyGroup:SetAllPoints(f)
        f.money = moneyFields(f.moneyGroup, 25, -210)
        f.unitGroup = CreateFrame("Frame", nil, f)
        f.unitGroup:SetAllPoints(f)
        font(f.unitGroup, 11, 25, -210, 440, "Quantity (whole units)", MUTED)
        f.quantity = edit(f.unitGroup, 100, 29, -230, 9, true)
        f.labelCaption = font(f.unitGroup, 11, 25, -272, 445, "Item name or shift-click an item here", MUTED)
        f.label = edit(f.unitGroup, 445, 29, -292, 512)
        for index, choice in ipairs({{"money", "Gold"}, {"item", "Items"}, {"favor", "Favor"}}) do
            local key = choice[1]
            f.kindButtons[key] = button(f, choice[2], 140, 23 + (index - 1) * 151, -165, function()
                f.kind = key
                for value, b in pairs(f.kindButtons) do b:SetEnabled(value ~= key) end
                f.moneyGroup:SetShown(key == "money")
                f.unitGroup:SetShown(key ~= "money")
                f.labelCaption:SetText(key == "item" and "Item name or shift-click an item here" or "Favor / unit (e.g. minutes of enchanting help)")
            end)
        end
        font(f, 11, 25, -337, 440, "Due date (optional, YYYY-MM-DD)", MUTED)
        f.due = edit(f, 200, 29, -357, 10)
        font(f, 11, 25, -397, 440, "Agreement notes (optional)", MUTED)
        f.note = multiline(f, 442, 66, 29, -419, 2000)
        f.error = font(f, 11, 25, -501, 455, "", {1, 0.4, 0.32})
        button(f, "Create IOU", 145, 332, -540, function()
            local value, err
            if f.kind == "money" then value, err = f.money:Read() else value = integer(f.quantity, true) end
            if not value then f.error:SetText(err or "Enter a positive whole quantity."); return end
            local due
            due, err = IOU.ParseDueDate(f.due:GetText())
            if due == nil then f.error:SetText(err); return end
            local e
            e, err = IOU.Add({player = f.player:GetText(), direction = f.direction, kind = f.kind, amount = value,
                label = f.kind == "money" and "" or f.label:GetText(), note = f.note:GetText(), due = due})
            if not e then f.error:SetText(literal(err)); return end
            UI.search:SetText("")
            focusEntry(e); f:Hide()
        end)
        button(f, "Cancel", 100, 221, -540, function() f:Hide() end)
    end
    installLinkCapture()
    local f = UI.add
    f.player:SetText(""); f.note:SetText(""); f.quantity:SetText("1"); f.label:SetText(""); f.due:SetText(""); f.money:Fill(0)
    f.error:SetText(""); f.direction, f.kind = "owed", "money"
    for key, b in pairs(f.dirButtons) do b:SetEnabled(key ~= f.direction) end
    for key, b in pairs(f.kindButtons) do b:SetEnabled(key ~= f.kind) end
    f.moneyGroup:Show(); f.unitGroup:Hide()
    f:Show(); f.player:SetFocus()
end

function IOU.ShowEdit()
    local entry = L.Get(IOU.GetLedger(), UI.selected)
    if not entry or L.Status(entry) == "cancelled" then return end
    if not UI.editForm then
        local f = window("IOUEditWindow", 520, 615)
        UI.editForm = f
        font(f, 21, 22, -22, 460, "Edit agreement details", GOLD)
        font(f, 11, 25, -64, 460, "Player", MUTED)
        f.player = edit(f, 455, 29, -84, 80)
        font(f, 11, 25, -130, 460, "Item / favor description (gold stays unchanged)", MUTED)
        f.label = edit(f, 455, 29, -150, 512)
        font(f, 11, 25, -196, 460, "Due date (YYYY-MM-DD, blank for none)", MUTED)
        f.due = edit(f, 200, 29, -216, 10)
        font(f, 11, 25, -262, 460, "Agreement notes", MUTED)
        f.note = multiline(f, 455, 88, 29, -284, 2000)
        font(f, 11, 25, -395, 460, "Reason for this change (required)", MUTED)
        f.reason = multiline(f, 455, 65, 29, -417, 2000)
        f.error = font(f, 11, 25, -501, 460, "", {1, 0.4, 0.32})
        f.save = button(f, "Save changes", 150, 340, -565, function()
            local current = L.Get(IOU.GetLedger(), f.entryID)
            if current ~= f.entry then f.error:SetText("The ledger changed. Close and reopen this form."); return end
            local due, err
            if f.due:GetText() == IOU.FormatDueDate(current.due) then due = current.due
            else due, err = IOU.ParseDueDate(f.due:GetText()) end
            if due == nil then f.error:SetText(err); return end
            local result
            result, err = IOU.Amend(current.id, {player=f.player:GetText(), label=current.kind == "money" and "" or f.label:GetText(),
                note=f.note:GetText(), due=due}, f.reason:GetText())
            if not result then f.error:SetText(literal(err)); return end
            focusEntry(L.Get(IOU.GetLedger(), current.id)); f:Hide()
        end)
        button(f, "Cancel", 100, 230, -565, function() f:Hide() end)
    end
    installLinkCapture()
    local f = UI.editForm
    f.entry, f.entryID = entry, entry.id
    f.player:SetText(entry.player); f.label:SetText(entry.label); f.label:SetEnabled(entry.kind ~= "money")
    f.due:SetText(IOU.FormatDueDate(entry.due)); f.note:SetText(entry.note); f.reason:SetText(""); f.error:SetText("")
    f:Show()
end

function IOU.ShowAction(mode, entryID, eventID)
    local entry = L.Get(IOU.GetLedger(), entryID or UI.selected)
    if not entry then return end
    if not UI.action then
        local f = window("IOUActionWindow", 492, 399)
        UI.action = f
        f.title = font(f, 21, 22, -22, 440, "", GOLD)
        f.context = font(f, 12, 24, -62, 440, "")
        f.context:SetHeight(38)
        f.moneyGroup = CreateFrame("Frame", nil, f); f.moneyGroup:SetAllPoints(f)
        f.money = moneyFields(f.moneyGroup, 25, -113)
        f.unitsGroup = CreateFrame("Frame", nil, f); f.unitsGroup:SetAllPoints(f)
        font(f.unitsGroup, 11, 25, -114, 440, "Quantity to record", MUTED)
        f.quantity = edit(f.unitsGroup, 150, 29, -135, 9, true)
        f.explanation = font(f, 12, 25, -115, 440, "", MUTED)
        f.noteCaption = font(f, 11, 25, -185, 440, "", MUTED)
        f.note = multiline(f, 428, 76, 29, -209, 2000)
        f.error = font(f, 11, 25, -305, 440, "", {1, 0.4, 0.32})
        f.confirm = button(f, "Save", 150, 312, -355, function()
            local current = L.Get(IOU.GetLedger(), f.entryID)
            if current ~= f.entry then f.error:SetText("The ledger changed. Close and reopen this action."); return end
            local result, err
            if f.mode == "reverse" then result, err = IOU.Reverse(current.id, f.eventID, f.note:GetText())
            elseif f.mode == "settle" then result, err = IOU.Settle(current.id, f.note:GetText())
            elseif f.mode == "cancel" then result, err = IOU.Cancel(current.id, f.note:GetText())
            elseif f.mode == "restore" then result, err = IOU.Restore(current.id, f.note:GetText())
            else
                local value
                if current.kind == "money" then value, err = f.money:Read() else value = integer(f.quantity, true) end
                if not value then f.error:SetText(err or "Enter a positive whole quantity."); return end
                result, err = IOU.Pay(current.id, value, f.note:GetText())
            end
            if not result then f.error:SetText(literal(err)); return end
            focusEntry(L.Get(IOU.GetLedger(), current.id))
            f:Hide()
        end)
        button(f, "Cancel", 100, 201, -355, function() f:Hide() end)
    end
    local f = UI.action
    f.entry, f.entryID, f.eventID, f.mode = entry, entry.id, eventID, mode
    local remaining = L.Balance(entry)
    f.title:SetText(mode == "cancel" and "Cancel IOU" or mode == "restore" and "Restore IOU" or mode == "reverse" and "Undo payment / delivery"
        or mode == "settle" and "Settle IOU" or entry.kind == "money" and "Record payment" or "Record delivery")
    f.context:SetText(literal(entry.player) .. "  /  #" .. entry.id .. "\nRemaining: " .. amount(entry, remaining))
    f.moneyGroup:SetShown(mode == "payment" and entry.kind == "money")
    f.unitsGroup:SetShown(mode == "payment" and entry.kind ~= "money")
    f.explanation:SetText(mode == "reverse" and "Adds a reversal to the history. The original payment stays visible."
        or mode == "settle" and "Records the entire remaining balance as paid or delivered."
        or mode == "cancel" and "Moves this IOU to History without recording payment. Its balance and audit trail stay intact."
        or mode == "restore" and "Reopens this cancelled IOU with the same balance and history." or "")
    f.noteCaption:SetText((mode == "reverse" or mode == "cancel" or mode == "restore") and "Reason (required)" or "Payment / delivery notes (optional)")
    f.confirm:SetText(mode == "cancel" and "Cancel IOU" or mode == "restore" and "Restore IOU" or mode == "reverse" and "Record reversal" or mode == "settle" and "Settle IOU" or "Record")
    f.note:SetText(""); f.error:SetText(""); f.money:Fill(remaining); f.quantity:SetText(tostring(remaining))
    f:Show()
end

function IOU.ShowBackup(mode)
    showMain()
    if not UI.backup then
        local f = window("IOUBackupWindow", 736, 556)
        UI.backup = f
        font(f, 21, 22, -21, 660, "Ledger backups", GOLD)
        button(f, "Before upgrade", 150, 528, -21, function()
            local previous = IOU.MigrationExport()
            if not previous then f.status:SetText("No older-format ledger was upgraded for this character."); return end
            f.box:SetText(previous); f.box:SetFocus(); f.box:HighlightText()
            f.status:SetText("Original pre-upgrade ledger selected. Copy it, or Preview import to restore its records.")
        end)
        f.context = font(f, 12, 24, -60, 680, "")
        f.context:SetHeight(45)
        f.box, _, f.scroll = multiline(f, 662, 282, 29, -119, 1048576)
        f.status = font(f, 11, 25, -420, 680, "", MUTED)
        f.status:SetHeight(58)
        f.preview = button(f, "Preview import", 142, 25, -499, function()
            local candidate, err = IOU.PreviewImport(f.box:GetText())
            if not candidate then f.status:SetText("Invalid backup: " .. literal(err)); return end
            f.candidate = candidate
            local old = IOU.GetLedger()
            f.previewLedger = old
            local owed, owe = L.Summary(candidate, "owed"), L.Summary(candidate, "owe")
            f.status:SetText("REPLACE " .. literal(IOU.Character()) .. ": " .. #old.entries .. " current IOUs -> " .. #candidate.entries
                .. " imported IOUs (all history).\nOwed to you: " .. L.FormatMoney(owed.money) .. " / You owe: " .. L.FormatMoney(owe.money)
                .. "\nCurrent ledger will be kept under Previous ledger.")
            f.replace:Show()
        end)
        f.replace = button(f, "Confirm replacement", 182, 178, -499, function()
            if not f.candidate then return end
            if IOU.GetLedger() ~= f.previewLedger then
                f.candidate = nil; f.replace:Hide()
                f.status:SetText("The ledger changed after this preview. Preview the import again before replacing it.")
                return
            end
            local ok, err = IOU.ReplaceLedger(f.candidate)
            if not ok then f.status:SetText(literal(err)); return end
            f.candidate = nil; f.replace:Hide()
            f.status:SetText("Ledger restored. The previous ledger is available below. Save an external copy too.")
        end)
        button(f, "Current export", 139, 370, -499, function() IOU.ShowBackup("export") end)
        button(f, "Previous ledger", 155, 519, -499, function()
            local text = IOU.PreviousExport()
            if not text then f.status:SetText("No previous import to recover for this character."); return end
            f.box:SetText(text); f.box:SetFocus(); f.box:HighlightText()
            f.status:SetText("Previous ledger selected. Copy it, or Preview import to restore it.")
        end)
        f.box:SetScript("OnTextChanged", function()
            f.candidate = nil; f.replace:Hide()
        end)
    end
    local f = UI.backup
    f.context:SetText(literal(IOU.Character()) .. "\nExport is a local text snapshot. Copy it with Ctrl+C and save it outside the game.")
    f.candidate = nil; f.replace:Hide()
    if mode == "import" then
        f.box:SetText(""); f.status:SetText("Paste a complete IOU backup. Preview validates it before you can replace this character's ledger.")
    else
        local text, err = IOU.Export()
        if not text then IOU.Message(err); return end
        f.box:SetText(text); f.status:SetText("All IOUs and their history are included. Copy this snapshot to keep an external backup.")
    end
    f.scroll:SetVerticalScroll(0); f:Show(); f.box:SetFocus(); f.box:HighlightText()
end

local function refreshConnection()
    local f, transport = UI.connection, IOU.Transport
    if not f then return end
    local listening = transport.IsListening()
    f.status:SetText(literal(f.problem or transport.GetStatus()))
    f.listen:SetEnabled(not listening)
    f.run:SetEnabled(listening and not transport.IsRunning())
    f.stop:SetEnabled(listening)
    f.peer:SetEnabled(not listening)
    f.target:SetEnabled(not listening)
    if not f.box:HasFocus() then f.box:SetText(transport.GetReport()) end
end

function IOU.ShowConnectionTest(peer)
    if not IOU.Initialize() then return end
    local transport = IOU.Transport
    transport.Initialize()
    if not UI.connection then
        local f = window("IOUConnectionWindow", 720, 610)
        UI.connection = f
        font(f, 21, 22, -22, 660, "Connection test", GOLD)
        font(f, 12, 24, -64, 660, "Both players open this window, enter each other's full name and click Listen.\nOne clicks Run test. Keep both windows open until it finishes.\nIOU checks text and byte sizes automatically; your ledger stays unchanged.", MUTED)
        f.identity = font(f, 12, 24, -126, 660, "", GOLD)
        font(f, 11, 24, -153, 660, "Other player's full name (first name and surname)", MUTED)
        f.peer = edit(f, 488, 28, -173, 96)
        f.target = button(f, "Use target", 144, 548, -173, function()
            local name, err = transport.GetUnitName("target")
            f.problem = err
            if name then f.peer:SetText(name) end
            refreshConnection()
        end)
        f.listen = button(f, "Listen", 144, 24, -218, function()
            f.peer:ClearFocus(); f.box:ClearFocus(); f.problem = nil
            local ok, err = transport.EnableListening(true, f.peer:GetText())
            if not ok then f.problem = err end
            refreshConnection()
        end)
        f.run = button(f, "Run test", 144, 182, -218, function()
            f.box:ClearFocus(); f.problem = nil
            local ok, err = transport.Start(f.peer:GetText())
            if not ok then f.problem = err end
            refreshConnection()
        end)
        f.stop = button(f, "Stop", 144, 340, -218, function()
            f.box:ClearFocus(); f.problem = nil
            transport.Stop(); refreshConnection()
        end)
        f.status = font(f, 12, 24, -262, 660, "", GOLD)
        f.status:SetHeight(46)
        f.box, f.shell, f.scroll = multiline(f, 648, 224, 31, -321, 16000)
        f.peer:SetScript("OnEscapePressed", function() f:Hide() end)
        f.box:SetScript("OnEscapePressed", function() f:Hide() end)
        f.copy = button(f, "Copy report", 164, 24, -566, function()
            f.box:SetText(transport.GetReport()); f.scroll:SetVerticalScroll(0)
            f.box:SetFocus(); f.box:HighlightText()
        end)
        font(f, 11, 204, -572, 480, "Press Ctrl+C after Copy report. Reports include player names.", MUTED)
        f:SetScript("OnHide", function()
            f.box:ClearFocus(); f.peer:ClearFocus(); f.problem = nil
            transport.Stop()
        end)
        IOU.OnTransportChanged = refreshConnection
    end
    local f = UI.connection
    if peer and not transport.IsListening() then f.peer:SetText(peer) end
    f.identity:SetText("You: " .. literal(transport.GetLocalName() or "name unavailable"))
    refreshConnection()
    f:Show()
end

function IOU.ShowSettings()
    showMain()
    if not UI.settings then
        local f = window("IOUSettingsWindow", 476, 358)
        UI.settings = f
        font(f, 21, 22, -22, 410, "IOU settings", GOLD)
        font(f, 11, 24, -63, 420, "These preferences apply across your characters.", MUTED)
        f.minimap = button(f, "", 260, 24, -97, function()
            IOU.SetMinimap(not IOU.GetSettings().minimap); IOU.ShowSettings()
        end)
        f.reminders = button(f, "", 260, 24, -139, function()
            IOU.GetSettings().reminders = not IOU.GetSettings().reminders; IOU.ShowSettings()
        end)
        button(f, "Reset window position", 260, 24, -181, function() IOU.ResetPosition() end)
        button(f, "Connection test", 260, 24, -223, function()
            f:Hide(); IOU.ShowConnectionTest()
        end)
        font(f, 11, 24, -274, 420, "Assign 'Open / close IOU ledger' in the game's Key Bindings.\nYour agreements remain separate for each character.", MUTED)
        font(f, 10, 24, -329, 420, "IOU " .. IOU.VERSION .. " / PhilForever", MUTED)
    end
    local f = UI.settings
    f.minimap:SetText("Minimap button: " .. (IOU.GetSettings().minimap and "shown" or "hidden"))
    f.reminders:SetText("Login reminders: " .. (IOU.GetSettings().reminders and "on" or "off"))
    f:Show()
end
