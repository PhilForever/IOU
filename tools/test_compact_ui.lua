-- Real addon sessions exercise the compact personal UI without a live client.
local support = assert(IOU_TEST_SUPPORT, "Run through tools/test_iou.py.")
local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results + 1] = name
end
local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function contains(text, needle)
    assert(text:find(needle, 1, true), "missing " .. needle .. " in " .. text)
end
local function session(config)
    config = config or {}; config.ui = true
    local state = support.Session(config)
    assert(state.api.Initialize())
    return state, state.api
end
local function add(api, changes)
    local values = {player="Birch Vale", direction="owed", kind="money", amount=100000, label="", note="", due=0}
    for key, value in pairs(changes or {}) do values[key] = value end
    return assert(api.Add(values))
end
local function shown(state, parent)
    local parts = {}
    for _, object in ipairs(state.objects) do
        local current, visible, belongs = object, true, false
        while current do
            if not current:IsShown() then visible = false end
            if current == parent then belongs = true end
            current = current.parent
        end
        if belongs and visible and object.text and object.text ~= "" then parts[#parts + 1] = object.text end
    end
    return table.concat(parts, "\n")
end
local function more(state, api, button)
    state.click(api.UI.more); assert(api.UI.moreMenu:IsShown())
    state.click(button); assert(not api.UI.moreMenu:IsShown())
end

test("compact money preserves denominations and aggregate precision", function()
    local _, api = session()
    local money, L = api.UI.Helpers.money, api.Ledger
    for _, pair in ipairs({{0,"0g"},{1,"1c"},{100,"1s"},{10000,"1g"},{10001,"1g 1c"},
        {12345,"1g 23s 45c"},{L.MAX_AMOUNT*L.MAX_ENTRIES,"99999999g 90s"}}) do equal(money(pair[1]), pair[2]) end
    for _, value in ipairs({-1, 0.5, math.huge, 0/0, "100"}) do equal(money(value), "?") end
    equal(L.FormatMoney(10000), "1g 00s 00c")
end)

test("main screen keeps Requests accessible without empty counters or audit labels", function()
    local state, api = session()
    add(api); api.Toggle(); local ui = api.UI
    equal(ui.sharedButton:GetText(), "Requests"); assert(ui.sharedButton:IsShown())
    equal(ui.cards[1].value:GetText(), "10g"); equal(ui.cards[2].value:GetText(), "0g")
    equal(ui.cards[1].counts:GetText(), ""); equal(ui.cards[2].counts:GetText(), "")
    equal(ui.rows[1].context:GetText(), ""); equal(ui.context:GetText(), "Owes you")
    equal(ui.due:GetText(), ""); assert(ui.main:GetHeight() < 720)
    local text = shown(state, ui.main)
    assert(not text:find("Record payment", 1, true)); assert(not text:find("Mark paid", 1, true))
    assert(not text:find("#1", 1, true)); assert(not text:find("No due date", 1, true))
end)

test("More menu applies partial payment and preserves collapsed reversible history", function()
    local state, api = session()
    local e = add(api); api.Toggle(); local ui = api.UI
    assert(not ui.historyExpanded); assert(not ui.historyPrevious:IsShown())
    more(state, api, ui.pay)
    ui.action.money:Fill(30000); state.click(ui.action.confirm)
    equal(ui.balance:GetText(), "7g")
    contains(shown(state, ui.detailContent), "Original 10g / Paid 3g")
    assert(not shown(state, ui.detailContent):find("Payment #1", 1, true))
    state.click(ui.historyToggle); assert(ui.historyExpanded)
    contains(shown(state, ui.detailContent), "Payment #1")
    local undo = state.button(ui.detailContent, "Undo")
    state.click(undo); state.click(ui.action.confirm)
    equal(api.Ledger.Balance(api.GetLedger().entries[e.id]), 100000)
    contains(shown(state, ui.detailContent), "Original 10g / Paid 0g")
    contains(shown(state, ui.detailContent), "(reversed)")
    state.click(ui.historyToggle); assert(not ui.historyExpanded)
    assert(not shown(state, ui.detailContent):find("Payment #1", 1, true))
end)

test("More actions reject a stale selected entry after a ledger mutation", function()
    local state, api = session()
    local first = add(api); add(api, {player="Other Person"}); api.Toggle(); local ui = api.UI
    state.click(ui.rows[2]); equal(ui.selected, first.id)
    state.click(ui.more); local oldEntry = ui.moreMenu.entry
    assert(api.Pay(first.id, 10000, "Received")); assert(not ui.moreMenu:IsShown())
    assert(api.GetLedger().entries[first.id] ~= oldEntry)
    state.click(ui.settle)
    equal(api.Ledger.Balance(api.GetLedger().entries[first.id]), 90000)
    equal(ui.action, nil); contains(state.messages[#state.messages], "changed")
    state.click(ui.more); state.click(ui.rows[1]); state.click(ui.cancel)
    equal(api.Ledger.Status(api.GetLedger().entries[first.id]), "partial")
    equal(api.Ledger.Status(api.GetLedger().entries[2]), "outstanding")
end)

test("cancelled records reopen through More without losing their balance", function()
    local state, api = session()
    local e = add(api); api.Toggle(); local ui = api.UI
    more(state, api, ui.cancel); state.click(ui.action.confirm)
    equal(ui.tab, "history"); equal(ui.cancel:GetText(), "Reopen")
    more(state, api, ui.cancel); equal(ui.action.mode, "restore")
    state.click(ui.action.confirm)
    equal(ui.tab, "owed"); equal(api.Ledger.Balance(api.GetLedger().entries[e.id]), 100000)
    equal(#api.GetLedger().entries[e.id].events, 2)
end)

test("switching records collapses history while ordinary refresh reuses controls", function()
    local state, api = session()
    local e = add(api); add(api, {player="Other Person"}); api.Toggle(); local ui = api.UI
    state.click(ui.historyToggle); assert(ui.historyExpanded)
    state.click(ui.rows[2]); equal(ui.selected, e.id); assert(not ui.historyExpanded)
    local count = #state.objects
    for _ = 1, 30 do api.Refresh() end
    equal(#state.objects, count)
end)

test("long current notes remain readable behind Full note without default history", function()
    local state, api = session()
    local note = string.rep("Bjørn blåbær | literal ", 35)
    local e = add(api, {note=note}); api.Toggle(); local ui = api.UI
    assert(not ui.historyExpanded)
    local full = state.button(ui.detailContent, "Full note")
    assert(full and full:IsShown()); state.click(full)
    equal(ui.noteWindow.text:GetText(), note:gsub("|", "||"))
    equal(api.GetLedger().entries[e.id].note, note)
end)

test("new IOU starts small and optional fields survive toggling and type changes", function()
    local state, api = session({target="Bjørn Blue-Berry"})
    api.ShowAdd(); local form = api.UI.add
    equal(form.player:GetText(), "Bjørn Blue-Berry"); assert(form.money[1]:HasFocus())
    assert(not form.optionsExpanded and not form.optionsGroup:IsShown())
    local initialHeight = form:GetHeight()
    state.click(form.moreOptions); assert(form.optionsExpanded and form.optionsGroup:IsShown())
    assert(form:GetHeight() > initialHeight)
    form.due:SetText("2028-02-29"); form.note:SetText("Crafting split")
    state.click(form.moreOptions); state.click(form.kindButtons.item)
    equal(form.note:GetText(), "Crafting split"); equal(form.due:GetText(), "2028-02-29")
    assert(form.quantity:HasFocus()); assert(not form.optionsGroup:IsShown())
    form.quantity:SetText("12"); form.label:SetFocus()
    local link = "|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"
    state.env.ChatFrameUtil.InsertLink(link)
    state.click(form.create)
    local e = api.GetLedger().entries[1]
    equal(e.amount, 12); equal(e.label, link); equal(e.note, "Crafting split")
    equal(api.FormatDueDate(e.due), "2028-02-29")
    api.ShowAdd(); equal(form.note:GetText(), ""); equal(form.due:GetText(), "")
    assert(not form.optionsExpanded and not form.optionsGroup:IsShown())
end)

test("invalid hidden optional dates expand their field instead of failing invisibly", function()
    local state, api = session()
    api.ShowAdd("Birch Vale"); local form = api.UI.add
    form.money:Fill(10000)
    state.click(form.moreOptions); form.due:SetText("2027-02-29"); state.click(form.moreOptions)
    state.click(form.create)
    equal(#api.GetLedger().entries, 0)
    assert(form.optionsExpanded and form.optionsGroup:IsShown() and form.due:HasFocus())
    assert(form.error:GetText() ~= "")
end)

return results
