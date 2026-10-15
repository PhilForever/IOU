local _, IOU = ...

BINDING_HEADER_IOU = "IOU"
BINDING_NAME_IOU_TOGGLE = "Open / close IOU ledger"
function IOU_ToggleLedger()
    local ok, err = IOU.Initialize()
    if not ok then IOU.Message(err); return end
    IOU.Toggle()
end

local function position(button)
    local angle = math.rad(IOU.GetSettings().minimapAngle)
    local x = math.cos(angle) * (Minimap:GetWidth() / 2 + 6)
    local y = math.sin(angle) * (Minimap:GetHeight() / 2 + 6)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function drag(button)
    local x, y = GetCursorPosition()
    local cx, cy = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    if not cx or not cy or not scale or scale <= 0 then return end
    local angle = math.deg(math.atan2(y / scale - cy, x / scale - cx)) % 360
    IOU.GetSettings().minimapAngle = angle
    position(button)
end

function IOU.UpdateLauncher()
    local settings = IOU.GetSettings()
    if not settings or not Minimap then return end
    if not IOU.launcher then
        local b = CreateFrame("Button", "IOUMinimapButton", Minimap)
        IOU.launcher = b
        b:SetSize(32, 32)
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:RegisterForDrag("LeftButton")
        b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local background = b:CreateTexture(nil, "BACKGROUND")
        background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
        background:SetSize(24, 24); background:SetPoint("CENTER")
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
        icon:SetSize(20, 20); icon:SetPoint("CENTER", -1, 1)
        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(54, 54); border:SetPoint("TOPLEFT")
        b:SetScript("OnClick", function(_, mouse)
            if mouse == "RightButton" then IOU.ShowAdd() else IOU_ToggleLedger() end
        end)
        b:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", drag); drag(self)
        end)
        b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        b:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("IOU", 0.88, 0.73, 0.42)
            local owed = IOU.Ledger.Summary(IOU.GetLedger(), "owed")
            local owe = IOU.Ledger.Summary(IOU.GetLedger(), "owe")
            GameTooltip:AddLine("Owed to you: " .. IOU.Ledger.FormatMoney(owed.money), 1, 1, 1)
            GameTooltip:AddLine("You owe: " .. IOU.Ledger.FormatMoney(owe.money), 1, 1, 1)
            GameTooltip:AddLine("Left-click: ledger / Right-click: new IOU", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Drag to move / /iou settings", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    IOU.launcher:SetScript("OnUpdate", nil)
    position(IOU.launcher)
    IOU.launcher:SetShown(settings.minimap)
end
