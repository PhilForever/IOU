-- Shared recovery uses the complete addon UI and real service. Client frames,
-- storage and native chat calls are the same mocks used by other integrations.
local support = assert(IOU_TEST_SUPPORT)
local copy, same = support.Copy, support.Same
local results = {}
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    results[#results+1] = name
end
local function equal(actual, expected, note)
    assert(actual == expected, (note or "unexpected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function contains(text, value) assert(text:find(value, 1, true), "missing review text: " .. value) end
local function session(saved)
    local state = support.Session({ui=true, shared=true, name="Amber", fullName="Amber Stone", db=saved})
    assert(state.api.Initialize()); assert(state.api.SharedService.Initialize())
    return state
end
local function fixture(api, note, paused)
    local engine = api.Shared
    local owner = assert(engine.New("Amber Stone"))
    local peer = assert(engine.New("Birch Vale"))
    local actions
    owner, actions = engine.Propose(owner, {protocol=1,kind="GOLD_OBLIGATION",proposer="Amber Stone",
        recipient="Birch Vale",debtor="Amber Stone",creditor="Birch Vale",amountCopper=10000,
        dueUTC=0,note=note or "Backup original note"}, "ui-agreement", "ui-offer", 100)
    assert(owner, actions)
    if paused then return assert(engine.Pause(owner, 110)) end
    peer = assert(engine.Receive(peer, "Amber Stone", actions[1].message, 101))
    peer, actions = engine.Accept(peer, "ui-offer", 102); assert(peer, actions)
    owner, actions = engine.Receive(owner, "Birch Vale", actions[1].message, 103); assert(owner, actions)
    peer, actions = engine.Receive(peer, "Amber Stone", actions[1].message, 104); assert(peer, actions)
    owner = assert(engine.Receive(owner, "Birch Vale", actions[1].message, 105))
    return owner
end
local function wrapper(store, closed)
    return {version=1,store=copy(store),closedPaused=copy(closed or {}),nonce="backup-ui",counter=0}
end
local function backup(state, store, closed)
    return assert(state.api.SharedBackup.Encode({version=1,owner="Amber Stone",character=state.api.Character(),
        exportedAt=900,entry=wrapper(store,closed)}))
end
local function pasteAndPreview(state, text)
    state.api.ShowSharedBackup("import")
    local form = state.api.UI.sharedBackup
    form.box:SetText(text); state.click(form.preview)
    local review = state.api.UI.sharedRecoveryReview
    assert(review and review:IsShown() and not review.staged)
    return form, review
end
local function stage(state, text)
    local form, review = pasteAndPreview(state, text)
    state.click(review.stage)
    assert(review.staged and state.api.SharedService.IsRecoveryPending())
    return form, review
end

test("personal and Shared entry buttons open separate complete Shared exports without disconnecting", function()
    local state = session()
    local api = state.api
    api.ShowShared("Birch Vale"); state.click(api.UI.shared.enable)
    api.ShowBackup("export")
    contains(api.UI.backup.box:GetText(), "IOU2:")
    local before = copy(api.SharedService.GetStore())
    local personal = copy(api.GetLedger())
    state.click(api.UI.backup.shared)
    local form = api.UI.sharedBackup
    contains(form.box:GetText(), "IOUS1:")
    assert(form.box:HasFocus() and form.box.highlighted)
    assert(api.SharedService.IsEnabled())
    local decoded = assert(api.SharedBackup.Decode(form.box:GetText()))
    equal(decoded.owner, "Amber Stone"); equal(decoded.character, api.Character())
    state.click(api.UI.shared.more); state.click(api.UI.shared.backups)
    assert(api.SharedService.IsEnabled(), "opening a backup window disconnected sharing")
    state.click(form.preview)
    assert(same(before, api.SharedService.GetStore()))
    assert(same(personal, api.GetLedger()))
    equal(#state.transportSent, 0)
    assert(not api.SharedService.IsRecoveryPending())
end)

test("Shared backup preview rejects personal and another character exports without touching records", function()
    local state = session()
    local api = state.api
    api.ShowSharedBackup("import")
    local form = api.UI.sharedBackup
    local before = copy(api.SharedService.GetStore())
    form.box:SetText(assert(api.Export())); state.click(form.preview)
    contains(form.status:GetText(), "Invalid shared backup")
    assert(not api.UI.sharedRecoveryReview)
    local other = assert(api.SharedBackup.Decode(assert(api.SharedService.ExportBackup())))
    other.character = "Another-StorageKey"
    form.box:SetText(assert(api.SharedBackup.Encode(other))); state.click(form.preview)
    contains(form.status:GetText(), "own Shared backup")
    assert(same(before, api.SharedService.GetStore()))
    equal(#state.transportSent, 0)
end)

test("editing the pasted Shared backup invalidates its exact preview before recovery can stage", function()
    local state = session()
    local text = backup(state, fixture(state.api))
    local form, review = pasteAndPreview(state, text)
    assert(review.stage.enabled)
    form.box:SetText(text .. "\n")
    assert(not review.stage.enabled and review.stale)
    -- Even a direct stale callback cannot bypass the disabled button's guard.
    review.stage.scripts.OnClick(review.stage)
    assert(not state.api.SharedService.IsRecoveryPending())
    contains(review.status:GetText(), "Preview it again")
    form.box:SetText(text); state.click(form.preview)
    assert(review.stage.enabled and not review.stale)
    equal(review.backupText, text)
end)

test("Shared record changes after preview require another preview and do not disconnect on rejection", function()
    local state = session()
    local api = state.api
    api.ShowShared("Birch Vale"); state.click(api.UI.shared.enable)
    local _, review = pasteAndPreview(state, backup(state, fixture(api)))
    assert(api.SharedService.Propose({peer="Birch Vale",direction="owed",amountCopper=25,dueUTC=0,note="New current record"}))
    local before = copy(api.SharedService.GetStore())
    state.click(review.stage)
    assert(not api.SharedService.IsRecoveryPending() and api.SharedService.IsEnabled())
    assert(not review.stage.enabled)
    contains(review.status:GetText(), "changed after the preview")
    assert(same(before, api.SharedService.GetStore()))
    state.click(review.refresh)
    assert(review.stage.enabled)
    contains(review.details:GetText(), "Only on this client; kept")
end)

test("staging Shared recovery disconnects and pauses without restoring until Keep is explicitly chosen", function()
    local state = session()
    local api, service = state.api, state.api.SharedService
    api.ShowShared("Birch Vale"); state.click(api.UI.shared.enable)
    local current = assert(service.Propose({peer="Birch Vale",direction="owe",amountCopper=20000,dueUTC=0,note="Current pending record"}))
    local personal = copy(api.GetLedger())
    local _, review = stage(state, backup(state, fixture(api)))
    assert(not service.IsEnabled() and not api.UI.shared.enable.enabled)
    equal(service.GetOffer(current.offerId).state, "PAUSED")
    equal(service.GetOffer("ui-offer"), nil)
    assert(not review.restore.enabled and review.keep.enabled and not review.stage:IsShown())
    contains(review.status:GetText(), "unfinished agreement")
    contains(review.explanation:GetText(), "Sharing is paused")
    local before = copy(service.GetStore())
    review:Hide()
    assert(service.IsRecoveryPending() and same(before, service.GetStore()))
    state.advance(3); equal(#state.transportSent, 0)
    api.ShowSharedBackup(); assert(review:IsShown())
    state.click(review.keep)
    equal(service.GetRecovery().status, "KEPT")
    assert(not service.IsRecoveryPending() and not service.IsEnabled())
    equal(service.GetOffer("ui-offer"), nil)
    assert(same(before, service.GetStore()) and same(personal, api.GetLedger()))
    assert(not review.restore.enabled and not review.keep.enabled)
    state.advance(3); equal(#state.transportSent, 0)
end)

test("explicit Shared restore recovers confirmed balance and retains both downloadable snapshots without traffic", function()
    local state = session()
    local api, service = state.api, state.api.SharedService
    local text = backup(state, fixture(api))
    local personal = copy(api.GetLedger())
    local _, review = stage(state, text)
    equal(service.GetOffer("ui-offer"), nil)
    contains(review.details:GetText(), "After restoring missing history: 1g 00s 00c")
    state.click(review.restore)
    equal(service.GetRecovery().status, "RESTORED")
    equal(service.GetBalance("ui-offer").remainingCopper, 10000)
    assert(not service.IsEnabled() and not service.IsRecoveryPending())
    assert(not review.restore.enabled and not review.keep.enabled)
    contains(review.title:GetText(), "history restored")
    state.click(review.exportBackup)
    equal(api.UI.sharedBackup.box:GetText(), text)
    state.click(review.exportBefore)
    local before = assert(api.SharedBackup.Decode(api.UI.sharedBackup.box:GetText()))
    equal(next(before.entry.store.offers), nil)
    assert(same(personal, api.GetLedger()))
    state.advance(5); equal(#state.transportSent, 0)
end)

test("pending Shared recovery reopens its decision after reload and never resumes sharing", function()
    local state = session()
    stage(state, backup(state, fixture(state.api)))
    local saved = copy(state.env.IOUDB)
    local reloaded = session(saved)
    local api = reloaded.api
    assert(api.SharedService.IsRecoveryPending() and not api.SharedService.IsEnabled())
    api.ShowSharedBackup()
    local review = api.UI.sharedRecoveryReview
    assert(review and review:IsShown() and review.staged and review.restore.enabled)
    assert(not api.UI.sharedBackup, "opening pending recovery replaced review with an export")
    api.ShowShared("Birch Vale")
    assert(not api.UI.shared.enable.enabled)
    reloaded.advance(5); equal(#reloaded.transportSent, 0)
    api.ShowSharedBackup(); reloaded.click(review.restore)
    equal(api.SharedService.GetBalance("ui-offer").remainingCopper, 10000)
    assert(not api.SharedService.IsEnabled())
    reloaded.advance(5); equal(#reloaded.transportSent, 0)
end)

test("different Shared versions display both notes and local review markers while current terms are kept", function()
    local seed = session()
    local localStore = fixture(seed.api, "Current immutable note", true)
    local saved = copy(seed.env.IOUDB)
    saved.sharedByCharacter[seed.api.Character()] = wrapper(localStore, {['ui-offer']={at=120,reason="Current local review reason"}})
    local state = session(saved)
    local imported = fixture(state.api, "Backup immutable note", true)
    local text = backup(state, imported, {['ui-offer']={at=121,reason="Backup local review reason"}})
    local _, review = stage(state, text)
    contains(review.details:GetText(), "Different; current version kept")
    contains(review.details:GetText(), "Current immutable note")
    contains(review.details:GetText(), "Backup immutable note")
    contains(review.details:GetText(), "Current local review reason")
    contains(review.details:GetText(), "Backup local review reason")
    local before = copy(state.api.SharedService.GetOffer("ui-offer"))
    state.click(review.restore)
    assert(same(before, state.api.SharedService.GetOffer("ui-offer")), "conflict restore overwrote current terms or consent")
    equal(#state.transportSent, 0)
end)

test("Shared backup and recovery dialogs focus immediately above complete background frame trees", function()
    local state = session()
    local api = state.api
    api.Toggle(); api.ShowShared("Birch Vale"); api.ShowSharedBackup("import")
    local form = api.UI.sharedBackup
    form.box:SetText(backup(state, fixture(api)))
    local function highest(frame)
        local result = frame:GetFrameLevel()
        for _, child in ipairs({frame:GetChildren()}) do result = math.max(result, highest(child)) end
        return result
    end
    local initialTime = state.now
    state.mouseDown(form.box)
    assert(form.box:HasFocus()); equal(state.now, initialTime)
    assert(form:GetFrameLevel() > highest(api.UI.shared))
    state.click(form.preview)
    local review = api.UI.sharedRecoveryReview
    equal(review:GetFrameStrata(), "DIALOG"); equal(review.backdropColor[4], 1)
    assert(review:GetFrameLevel() > highest(form))
    assert(not form.box:HasFocus(), "background backup editor retained typing focus")
    equal(state.now, initialTime)
    state.mouseDown(form.box); assert(form.box:HasFocus())
    assert(form:GetFrameLevel() > highest(review))
    form:Hide(); assert(not form.box:HasFocus())
end)

return results
