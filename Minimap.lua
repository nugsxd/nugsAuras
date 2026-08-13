--------------------------------------------------------------------------------
-- nugsAuras
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsAuras  -  Minimap.lua
-- A self-contained minimap button (no external libraries). Draggable around the
-- minimap edge; its angle persists in SavedVariables. Left click opens the options
-- window, right click unlocks the groups for dragging.
--------------------------------------------------------------------------------
local ADDON_NAME, NAU = ...

-- Place the button on the minimap edge, adapting to the minimap's CURRENT size and
-- shape, so it works with resized/reshaped minimaps and not just the default.
local function PositionButton(btn, angle)
    local a = math.rad(angle)
    local cos, sin = math.cos(a), math.sin(a)
    local w = (Minimap:GetWidth()  / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5
    local shape = (type(GetMinimapShape) == "function") and GetMinimapShape() or "ROUND"
    local x, y
    if shape == "ROUND" then
        x, y = cos * w, sin * h
    else
        -- square / mixed-shape minimaps: clamp the point to the minimap box
        local diag = 1.41421356
        x = math.max(-w, math.min(cos * w * diag, w))
        y = math.max(-h, math.min(sin * h * diag, h))
    end
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging, follow the cursor around the minimap edge.
local function OnDragUpdate(btn)
    local mx, my = Minimap:GetCenter()
    if not mx then return end
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    local angle = math.deg(math.atan2(py - my, px - mx))
    NAU.db.minimapAngle = angle
    PositionButton(btn, angle)
end

function NAU.InitMinimap()
    if NAU.minimapButton or not NAU.db then return end
    NAU.db.minimapAngle = NAU.db.minimapAngle or 200

    local btn = CreateFrame("Button", "nugsAurasMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(31, 31)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- A dark disc behind the icon. The tracking border's hole is slightly wider
    -- than the icon, and without this the gap between the two is see-through - the
    -- world scrolls past in a thin ring around the button. Deliberately sized past
    -- the hole, because the border art draws over the excess.
    local backing = btn:CreateTexture(nil, "BACKGROUND")
    backing:SetSize(23, 23)
    backing:SetPoint("CENTER", 0, 1)
    backing:SetTexture("Interface\\Buttons\\WHITE8X8")
    backing:SetVertexColor(0.05, 0.06, 0.08, 1)
    backing:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(21, 21)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\AddOns\\nugsAuras\\icon")
    -- Circular alpha mask so the square art cannot poke past the round border.
    icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
    btn:SetScript("OnDragStop",  function(self) self:SetScript("OnUpdate", nil) end)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            NAU.Display:ToggleLock(not NAU.db.locked)
        else
            NAU.ToggleOptions()
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("nugsAuras")
        GameTooltip:AddLine("Left click to open the options", 1, 1, 1)
        GameTooltip:AddLine("Right click to lock or unlock the groups", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    NAU.minimapButton = btn
    PositionButton(btn, NAU.db.minimapAngle)
    NAU.SetMinimapShown(not NAU.db.minimapHidden)
end

function NAU.SetMinimapShown(shown)
    if not NAU.minimapButton then return end
    NAU.minimapButton:SetShown(shown and true or false)
end
