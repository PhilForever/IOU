local ADDON, IOU = ...
IOU.VERSION = "0.3.0-alpha.3"
local L, C = IOU.Ledger, IOU.Codec
local ledger, character, failure

function IOU.Message(message)
    print("|cffdfba69IOU:|r " .. tostring(message))
end

local function plain(value)
    return not (issecretvalue and issecretvalue(value))
end

function IOU.Initialize()
    if ledger then return true end
    if failure then return nil, failure end
    local name, realm
    if UnitFullName then name, realm = UnitFullName("player") end
    if not plain(name) or not plain(realm) then return nil, "Character identity is unavailable." end
    if not realm or realm == "" then realm = GetRealmName and GetRealmName() end
    if not plain(realm) or type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then
        return nil, "Character identity is unavailable. Try again after login."
    end
    character = name .. "-" .. realm:gsub("%s+", "")
    if IOUDB == nil then IOUDB = {version = 1, characters = {}, recovery = {}} end
    if type(IOUDB) ~= "table" or IOUDB.version ~= 1 or type(IOUDB.characters) ~= "table"
        or (IOUDB.recovery ~= nil and type(IOUDB.recovery) ~= "table")
        or (IOUDB.migrations ~= nil and type(IOUDB.migrations) ~= "table")
        or (IOUDB.settings ~= nil and type(IOUDB.settings) ~= "table") then
        failure = "Saved data has an unsupported format. IOU left it untouched. Back up IOU.lua in WTF before repairing it."
        return nil, failure
    end
    local candidate = IOUDB.characters[character]
    if candidate ~= nil then
        local ok, err = L.Validate(candidate)
        if not ok then
            failure = "This character's saved ledger is invalid; it was left untouched: " .. err
            return nil, failure
        end
        if candidate.schema == 1 then
            local previous, upgraded, err
            previous, err = C.Export(candidate)
            if previous then upgraded, err = L.Upgrade(candidate) end
            if upgraded then
                local exported
                exported, err = C.Export(upgraded)
                if not exported then upgraded = nil end
            end
            if not upgraded then
                failure = "The ledger could not be upgraded; saved records were left untouched: " .. tostring(err)
                return nil, failure
            end
            IOUDB.migrations = IOUDB.migrations or {}
            IOUDB.migrations[character] = previous
            candidate = upgraded
            IOUDB.characters[character] = candidate
        end
    else
        candidate = L.New()
        IOUDB.characters[character] = candidate
    end
    IOUDB.recovery = IOUDB.recovery or {}
    IOUDB.migrations = IOUDB.migrations or {}
    IOUDB.settings = IOUDB.settings or {}
    local settings = IOUDB.settings
    if type(settings.minimap) ~= "boolean" then settings.minimap = true end
    if type(settings.reminders) ~= "boolean" then settings.reminders = true end
    if type(settings.minimapAngle) ~= "number" or settings.minimapAngle ~= settings.minimapAngle
        or settings.minimapAngle < 0 or settings.minimapAngle > 360 then settings.minimapAngle = 225 end
    local anchors = {TOPLEFT=true, TOP=true, TOPRIGHT=true, LEFT=true, CENTER=true,
        RIGHT=true, BOTTOMLEFT=true, BOTTOM=true, BOTTOMRIGHT=true}
    local pos = settings.position
    if pos ~= nil and (type(pos) ~= "table" or not anchors[pos.point] or not anchors[pos.relativePoint]
        or type(pos.x) ~= "number" or type(pos.y) ~= "number" or pos.x ~= pos.x or pos.y ~= pos.y
        or math.abs(pos.x) > 100000 or math.abs(pos.y) > 100000) then settings.position = nil end
    ledger = candidate
    return true
end

function IOU.GetLedger() return ledger end
function IOU.Character() return character or "Character ledger" end
function IOU.GetSettings() return ledger and IOUDB.settings end

function IOU.ParseDueDate(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return 0 end
    local year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or year < 1970 or year > 2099 or month < 1 or month > 12 or day < 1 or day > 31 then
        return nil, "Use YYYY-MM-DD for a due date, or leave it blank."
    end
    local ok, stamp = pcall(time, {year=year, month=month, day=day, hour=23, min=59, sec=59})
    if not ok or type(stamp) ~= "number" or stamp < 0 or stamp > L.MAX_TIMESTAMP or date("%Y-%m-%d", stamp) ~= text then
        return nil, "That calendar date is invalid."
    end
    return stamp
end

function IOU.FormatDueDate(stamp)
    return stamp and stamp > 0 and date("%Y-%m-%d", stamp) or ""
end

local function ready()
    local ok, err = IOU.Initialize()
    if not ok then IOU.Message(err) end
    return ok, err
end

local function mutate(method, ...)
    local ok, err = ready()
    if not ok then return nil, err end
    -- Stage every change. A successful write must remain fully exportable,
    -- and a rejected write must leave both balances and history untouched.
    local snapshot, problem = C.Export(ledger)
    if not snapshot then return nil, problem end
    local draft
    draft, problem = C.Import(snapshot)
    if not draft then return nil, problem end
    -- Preserve varargs on Lua 5.1; the timestamp must be the final argument.
    local args = {...}
    args[#args + 1] = time()
    local result
    result, problem = method(draft, unpack(args))
    if not result then return nil, problem end
    snapshot, problem = C.Export(draft)
    if not snapshot then return nil, problem end
    IOUDB.characters[character] = draft
    ledger = draft
    if IOU.Refresh then IOU.Refresh() end
    return result
end

function IOU.Add(fields) return mutate(L.Add, fields) end
function IOU.Pay(id, amount, note) return mutate(L.Pay, id, amount, note or "") end
function IOU.Settle(id, note) return mutate(L.Settle, id, note or "") end
function IOU.Reverse(id, eventID, reason) return mutate(L.Reverse, id, eventID, reason or "") end
function IOU.Amend(id, fields, reason) return mutate(L.Amend, id, fields, reason or "") end
function IOU.Cancel(id, reason) return mutate(L.Cancel, id, reason or "") end
function IOU.Restore(id, reason) return mutate(L.Restore, id, reason or "") end

function IOU.Export()
    local ok, err = ready()
    if not ok then return nil, err end
    return C.Export(ledger)
end

function IOU.PreviewImport(text)
    local ok, err = ready()
    if not ok then return nil, err end
    local candidate, problem = C.Import(text)
    if not candidate then return nil, problem end
    local upgraded
    upgraded, problem = L.Upgrade(candidate)
    if not upgraded then return nil, problem end
    local encoded
    encoded, problem = C.Export(upgraded)
    if not encoded then return nil, problem end
    return upgraded
end

function IOU.ReplaceLedger(candidate)
    local ok, err = ready()
    if not ok then return nil, err end
    local upgraded, upgradeError = L.Upgrade(candidate)
    if not upgraded then return nil, upgradeError end
    candidate = upgraded
    -- Revalidate and copy so the preview object cannot alias the live ledger.
    local imported, problem = C.Export(candidate)
    if not imported then return nil, problem end
    local copy
    copy, problem = C.Import(imported)
    if not copy then return nil, problem end
    local previous
    previous, problem = C.Export(ledger)
    if not previous then return nil, problem end
    IOUDB.recovery[character] = previous
    IOUDB.characters[character] = copy
    ledger = copy
    if IOU.Refresh then IOU.Refresh(true) end
    return true
end

function IOU.PreviousExport()
    if not ready() then return end
    local previous = IOUDB.recovery[character]
    if type(previous) == "string" and #previous <= C.MAX_BYTES then return previous end
end

function IOU.MigrationExport()
    if not ready() then return end
    return IOUDB.migrations[character]
end

function IOU.SetMinimap(visible)
    if not ready() then return end
    IOU.GetSettings().minimap = visible == true
    if IOU.UpdateLauncher then IOU.UpdateLauncher() end
end

function IOU.ResetPosition()
    if not ready() then return end
    IOU.GetSettings().position = nil
    if IOU.UI and IOU.UI.main then
        IOU.UI.main:ClearAllPoints(); IOU.UI.main:SetPoint("CENTER")
    end
end

local function slash(command)
    if not ready() then return end
    local original = (command or ""):match("^%s*(.-)%s*$")
    command = original:lower()
    if command == "" then IOU.Toggle()
    elseif command == "shared off" then
        local ok, err = IOU.SharedService.Disable()
        IOU.Message(ok and "Shared agreements disconnected; unfinished offers are paused." or tostring(err or "Shared agreement recovery is pending."))
    elseif command == "shared" then IOU.ShowShared()
    elseif command:match("^shared%s+") then IOU.ShowShared(original:match("^%S+%s+(.+)$"))
    elseif command == "test stop" then
        IOU.Transport.Stop(); IOU.Message("Connection test stopped; listening is off.")
    elseif command == "test" then IOU.ShowConnectionTest()
    elseif command:match("^test%s+") then IOU.ShowConnectionTest(original:match("^%S+%s+(.+)$"))
    elseif command == "add" then IOU.ShowAdd()
    elseif command == "export" then IOU.ShowBackup("export")
    elseif command == "import" then IOU.ShowBackup("import")
    elseif command == "settings" then IOU.ShowSettings()
    elseif command == "resetpos" or command == "reset" then IOU.ResetPosition(); IOU.Message("Window position reset.")
    elseif command == "minimap show" then IOU.SetMinimap(true)
    elseif command == "minimap hide" then IOU.SetMinimap(false)
    elseif command == "reminders on" or command == "reminders off" then
        IOU.GetSettings().reminders = command == "reminders on"
        IOU.Message("Login reminders " .. (IOU.GetSettings().reminders and "on." or "off."))
    elseif command == "help" then
        IOU.Message("/iou - ledger; /iou add - new agreement; /iou export - backup; /iou import - restore.")
        IOU.Message("/iou settings; /iou resetpos; /iou minimap show|hide; /iou reminders on|off.")
        IOU.Message("/iou test [full player name] - connection test; /iou test stop - stop listening.")
        IOU.Message("/iou shared [full player name] - shared agreements; /iou shared off - disconnect.")
    else IOU.Message("Unknown command. Use /iou help.") end
end

SLASH_IOU1 = "/iou"
SlashCmdList.IOU = slash
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    local ok, err = IOU.Initialize()
    if not ok then IOU.Message(err); return end
    if IOU.SharedService then
        local sharedOK, sharedError = IOU.SharedService.Initialize()
        if not sharedOK then IOU.Message("Shared agreements: " .. tostring(sharedError)) end
    end
    if IOU.UpdateLauncher then IOU.UpdateLauncher() end
    IOU.Message("v" .. IOU.VERSION .. " loaded. /iou opens your ledger.")
    if IOU.GetSettings().reminders then
        local options = {now = time()}
        local owed, owe = L.Summary(ledger, "owed", nil, options), L.Summary(ledger, "owe", nil, options)
        if (owed.overdue or 0) + (owe.overdue or 0) > 0 then
            IOU.Message("Overdue IOUs: " .. (owed.overdue or 0) .. " owed to you, " .. (owe.overdue or 0) .. " you owe. /iou to review.")
        end
    end
end)
