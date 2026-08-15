--------------------------------------------------------------------------------
-- nugsAuras
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsAuras  -  Options.lua
-- The settings window.
--
-- Laid out as a list of groups on the left and that group's settings on the right,
-- rather than the tab-per-thing the other nugs addons use. Groups are created and
-- deleted by the player, so there is no fixed number of tabs to build - and the
-- list has to be visible anyway, because reordering it is what decides which group
-- an icon lands in.
--
-- The Spells tab carries the one piece of honesty this addon cannot do without:
-- every spell you add is marked with whether the client will actually let it be
-- read, and when. A tracker that silently shows nothing in a raid is worse than
-- one that says up front which of your spells will survive the pull.
--
-- Shared namespace: the second vararg is the same table across every Lua file in
-- this addon, so all state and functions hang off of it.
--------------------------------------------------------------------------------

local ADDON_NAME, NAU = ...

local C = {
    bg     = { 0.07, 0.07, 0.07, 0.96 },
    header = { 0.10, 0.10, 0.10, 1.00 },
    panel  = { 0.10, 0.10, 0.10, 0.90 },
    input  = { 0.14, 0.14, 0.14, 1.00 },
    btn    = { 0.16, 0.16, 0.16, 1.00 },
    btnHi  = { 0.24, 0.24, 0.24, 1.00 },
    accent = { 0.35, 0.72, 1.00, 1.00 },
    rowA   = { 1, 1, 1, 0.025 },
    rowB   = { 1, 1, 1, 0.055 },
    text   = { 0.82, 0.82, 0.82 },
    faint  = { 0.50, 0.50, 0.50 },
    gold   = { 1.00, 0.84, 0.42 },
}

local ADDON_ICON = "Interface\\AddOns\\nugsAuras\\icon"

local WIDTH, HEIGHT = 860, 660
local LEFT_W    = 236
local CONTENT_W = WIDTH - LEFT_W - 56
local COL_GAP   = 20
local COL_W     = math.floor((CONTENT_W - COL_GAP) / 2)
local ROW_H     = 22

local window, tabStrip, unlockBtn, groupList, emptyLabel
local panels     = {}
local currentKey = "filter"
local selectedID                    -- which group the right-hand side is showing
local sink                          -- where newly built widgets register themselves
local RelayoutAll, RebuildGroupList

-- The group the settings columns are acting on. Every getter and setter closes
-- over this rather than a captured group table, so selecting a different group in
-- the list does not need the panels rebuilt.
-- SetPropagateKeyboardInput is protected during combat, and a blocked call is not a
-- Lua error: pcall does not contain it, it raises ADDON_ACTION_BLOCKED and taints the
-- addon for the rest of the session. So it is never called inside a lockdown, and the
-- next key pressed after combat ends restores propagation on its own.
local function SafePropagate(frame, value)
    if InCombatLockdown() then return end
    frame:SetPropagateKeyboardInput(value)
end

local function G()
    return NAU.db and NAU.db.groups[selectedID]
end

local function Apply()
    if NAU.Display then NAU.Display:ApplySettings() end
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local function Backdrop(frame, color, borderAlpha)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(color))
    frame.bgTex = bg
    if borderAlpha then
        for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }) do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetPoint(p[1]); t:SetPoint(p[2]); t:SetHeight(1)
            t:SetColorTexture(0, 0, 0, borderAlpha)
        end
        for _, p in ipairs({ { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetPoint(p[1]); t:SetPoint(p[2]); t:SetWidth(1)
            t:SetColorTexture(0, 0, 0, borderAlpha)
        end
    end
    return bg
end

local function Panel(parent, color)
    local f = CreateFrame("Frame", nil, parent)
    Backdrop(f, color or C.panel, 1)
    return f
end

local function Label(parent, text, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(unpack(color or C.text))
    return fs
end

local function SectionHeader(parent, text)
    return Label(parent, text, "GameFontNormal", C.accent)
end

local function Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    Backdrop(b, C.btn, 1)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(text)
    b.text:SetTextColor(unpack(C.text))
    b:SetScript("OnEnter", function(self) self.bgTex:SetColorTexture(unpack(C.btnHi)) end)
    b:SetScript("OnLeave", function(self) self.bgTex:SetColorTexture(unpack(C.btn)) end)
    b:SetScript("OnClick", onClick)
    b.SetLabel = function(self, t) self.text:SetText(t) end
    b.SetGrey = function(self, grey)
        self.text:SetTextColor(unpack(grey and C.faint or C.text))
        if grey then self:Disable() else self:Enable() end
    end
    return b
end

-- Deliberately built to match RaidReady's header so the suite reads as one thing:
-- a 30px bar with a storm-blue underline, the addon icon on the left, a gold title
-- with a blue tail, and a small flat close button.
local function HeaderBar(f, titleText, tailText)
    local header = CreateFrame("Frame", nil, f)
    Backdrop(header, C.header, 1)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(30)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local accent = header:CreateTexture(nil, "OVERLAY")
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", 0, 0)
    accent:SetHeight(3)
    accent:SetColorTexture(unpack(C.accent))

    local icon = header:CreateTexture(nil, "OVERLAY")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 10, 0)
    icon:SetTexture(ADDON_ICON)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(titleText .. (tailText and (" |cff8cd2ff" .. tailText .. "|r") or ""))
    title:SetTextColor(unpack(C.gold))

    local close = Button(header, "x", 22, 18, function() f:Hide() end)
    close:SetPoint("RIGHT", -6, 0)

    -- Shown only when nugsSuite is absent. _G.nugsSuite is the suite's own handle,
    -- so this also reads correctly when it is installed but switched off - a
    -- disabled suite is no more use than a missing one.
    --
    -- A note, never a warning, and never a dependency: this addon works perfectly
    -- well on its own and the suite is only worth having once you run more than one.
    if not _G.nugsSuite then
        local suite = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        suite:SetPoint("RIGHT", close, "LEFT", -10, 0)
        suite:SetText("Part of the |cff8cd2ffnugs suite|r")
        suite:SetTextColor(unpack(C.faint))
    end

    return header
end

local function Check(parent, text, getter, setter, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(ROW_H)

    local box = CreateFrame("Frame", nil, b)
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    Backdrop(box, C.input, 1)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetColorTexture(unpack(C.accent))

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", box, "RIGHT", 6, 0)
    fs:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(unpack(C.text))

    b:SetScript("OnClick", function()
        setter(not getter())
        Apply()
        NAU.RefreshOptions()
    end)
    b:SetScript("OnEnter", function(self)
        fs:SetTextColor(1, 1, 1)
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        fs:SetTextColor(unpack(C.text))
        GameTooltip:Hide()
    end)

    b.Refresh = function() fill:SetShown(getter() and true or false) end
    sink[#sink + 1] = b
    return b
end

local sliderIndex = 0
local function Slider(parent, title, minV, maxV, step, getter, setter, fmt)
    sliderIndex = sliderIndex + 1
    local name = "nugsAurasSlider" .. sliderIndex

    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(40)

    local titleFS = Label(holder, title, "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT", 0, 0)

    local valueFS = Label(holder, "", "GameFontHighlightSmall", C.accent)
    valueFS:SetPoint("TOPRIGHT", 0, 0)
    valueFS:SetJustifyH("RIGHT")

    local sl
    local ok = pcall(function()
        sl = CreateFrame("Slider", name, holder, "OptionsSliderTemplate")
    end)
    if not ok or not sl then
        -- Template missing on this client: fall back to a bare slider we skin ourselves.
        sl = CreateFrame("Slider", name, holder)
        sl:SetOrientation("HORIZONTAL")
        local track = sl:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT"); track:SetPoint("RIGHT")
        track:SetHeight(4)
        track:SetColorTexture(0.25, 0.25, 0.25, 1)
        sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    sl:SetPoint("TOPLEFT", 2, -18)
    sl:SetPoint("TOPRIGHT", -2, -18)
    sl:SetHeight(16)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end

    -- The template ships Low/High/Text labels we do not want.
    for _, suffix in ipairs({ "Low", "High", "Text" }) do
        local fs = sl[suffix] or _G[name .. suffix]
        if fs and fs.SetText then fs:SetText("") end
    end

    local applying = false
    sl:SetScript("OnValueChanged", function(self, value)
        if applying then return end
        -- SetValueStep does not round for us on every path, and the leftover float
        -- noise would end up in saved variables.
        value = tonumber(string.format("%.4f", math.floor(value / step + 0.5) * step))
        setter(value)
        valueFS:SetText(string.format(fmt or "%.2f", value))
        Apply()
    end)

    holder.Refresh = function()
        applying = true
        local v = getter()
        sl:SetValue(v)
        valueFS:SetText(string.format(fmt or "%.2f", v))
        applying = false
    end
    sink[#sink + 1] = holder
    return holder
end

-- Cycling choice button. A dropdown would be the obvious widget, but Blizzard has
-- renamed that one twice in two expansions, and with three or four options a
-- click-to-cycle button is fewer motions anyway.
local function Choice(parent, prefix, options, getter, setter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(ROW_H)

    local function keyOf(o) return type(o) == "table" and o.key or o end
    local function labelOf(o) return type(o) == "table" and o.label or o end

    local btn
    btn = Button(holder, "", 100, ROW_H, function()
        local list = type(options) == "function" and options() or options
        local index = 1
        for i, o in ipairs(list) do
            if keyOf(o) == getter() then index = i break end
        end
        setter(keyOf(list[(index % #list) + 1]))
        Apply()
        NAU.RefreshOptions()
    end)
    btn:SetPoint("LEFT", 0, 0)
    btn:SetPoint("RIGHT", 0, 0)

    holder.Refresh = function()
        local list = type(options) == "function" and options() or options
        local text = tostring(getter())
        for _, o in ipairs(list) do
            if keyOf(o) == getter() then text = labelOf(o) end
        end
        btn:SetLabel(prefix .. ": " .. text)
    end
    sink[#sink + 1] = holder
    return holder
end

-- Colour swatch. Opens the game's own picker, which knows how to be a colour
-- picker better than anything hand-rolled would.
local function ShowColorPicker(r, g, b, a, hasAlpha, apply)
    local function currentAlpha()
        if ColorPickerFrame.GetColorAlpha then
            local ok, v = pcall(ColorPickerFrame.GetColorAlpha, ColorPickerFrame)
            if ok and type(v) == "number" then return v end
        end
        if _G.OpacitySliderFrame then return 1 - _G.OpacitySliderFrame:GetValue() end
        return a or 1
    end
    local function onChange()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        apply(nr, ng, nb, hasAlpha and currentAlpha() or a)
    end

    local info = {
        r = r, g = g, b = b,
        hasOpacity  = hasAlpha,
        opacity     = hasAlpha and (a or 1) or nil,
        swatchFunc  = onChange,
        opacityFunc = onChange,
        cancelFunc  = function() apply(r, g, b, a) end,
    }

    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow(info)
    else
        -- Pre-11.x shape, kept so the window is never dead on an older client.
        ColorPickerFrame.func        = info.swatchFunc
        ColorPickerFrame.opacityFunc = info.opacityFunc
        ColorPickerFrame.cancelFunc  = info.cancelFunc
        ColorPickerFrame.hasOpacity  = hasAlpha
        ColorPickerFrame.opacity     = hasAlpha and (1 - (a or 1)) or nil
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end
end

local function Swatch(parent, text, getter, hasAlpha)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(ROW_H)

    local well = CreateFrame("Frame", nil, b)
    well:SetSize(30, 14)
    well:SetPoint("LEFT", 0, 0)
    Backdrop(well, { 0, 0, 0, 1 }, 1)

    local fill = well:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)

    local fs = Label(b, text, "GameFontHighlightSmall")
    fs:SetPoint("LEFT", well, "RIGHT", 8, 0)

    b:SetScript("OnClick", function()
        local c = getter()
        if not c then return end
        ShowColorPicker(c[1], c[2], c[3], c[4], hasAlpha, function(r, g, bb, a)
            -- Mutated in place: the colour array is handed out by reference to the
            -- display, and replacing the table would leave it holding the old one.
            c[1], c[2], c[3] = r, g, bb
            if hasAlpha then c[4] = a end
            fill:SetColorTexture(r, g, bb, hasAlpha and a or 1)
            Apply()
        end)
    end)
    b:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(unpack(C.text)) end)

    b.Refresh = function()
        local c = getter()
        if c then fill:SetColorTexture(c[1], c[2], c[3], hasAlpha and (c[4] or 1) or 1) end
    end
    sink[#sink + 1] = b
    return b
end

-- `onChanged` is a parameter rather than something the caller attaches afterwards,
-- because the placeholder needs OnTextChanged too and whichever of the two was set
-- last would silently win.
local function EditBox(parent, h, onEnter, placeholder, onChanged)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetHeight(h or 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(6, 6, 0, 0)
    Backdrop(eb, C.input, 1)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onEnter then onEnter(self:GetText()) end
    end)

    local ph
    if placeholder then
        ph = Label(eb, placeholder, "GameFontDisableSmall", C.faint)
        ph:SetPoint("LEFT", 7, 0)
    end

    -- The placeholder is updated on every change, user-driven or not, so clearing
    -- the box from code brings it back. `onChanged` only fires for real typing.
    local function update(self, user)
        if ph then ph:SetShown(eb:GetText() == "") end
        if user and onChanged then onChanged(eb:GetText()) end
    end
    eb:SetScript("OnTextChanged", update)
    eb:SetScript("OnShow", update)
    update()

    return eb
end

-- Wheel-scrolled area: no Blizzard scroll template, just a child frame we shift
-- plus a thin position indicator on the right edge.
local function ScrollArea(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll.content = content

    -- Frames, not textures. The bar used to be two textures, and a texture cannot
    -- take mouse input - so it showed you where you were and gave you no way to act
    -- on it. On a long list that left the wheel as the only option.
    --
    -- BAR_W is the grab area and is wider than the 3px line you can see: a 3px
    -- target is not something anybody can reliably hit. It overlaps the right edge of
    -- the rows underneath, which is why it is hidden outright when everything fits -
    -- an invisible strip that eats row clicks would be worse than no bar at all.
    local BAR_W = 9

    local bar = CreateFrame("Frame", nil, scroll)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar:SetWidth(BAR_W)
    bar:EnableMouse(true)

    local track = bar:CreateTexture(nil, "ARTWORK")
    track:SetPoint("TOPRIGHT", 0, 0)
    track:SetPoint("BOTTOMRIGHT", 0, 0)
    track:SetWidth(3)
    track:SetColorTexture(1, 1, 1, 0.05)

    local thumb = CreateFrame("Frame", nil, bar)
    thumb:SetWidth(BAR_W)
    thumb:EnableMouse(true)
    local thumbTex = thumb:CreateTexture(nil, "OVERLAY")
    thumbTex:SetPoint("TOPRIGHT", 0, 0)
    thumbTex:SetPoint("BOTTOMRIGHT", 0, 0)
    thumbTex:SetWidth(3)
    thumbTex:SetColorTexture(unpack(C.accent))

    local function MaxScroll()
        return math.max(0, (content:GetHeight() or 1) - (scroll:GetHeight() or 1))
    end

    local function ScrollTo(value)
        local maxScrol = MaxScroll()
        scroll:SetVerticalScroll(math.max(0, math.min(maxScrol, value)))
        scroll:UpdateBar()
    end

    function scroll:UpdateBar()
        local viewH    = self:GetHeight() or 1
        local totalH   = content:GetHeight() or 1
        local maxScrol = math.max(0, totalH - viewH)
        if self:GetVerticalScroll() > maxScrol then self:SetVerticalScroll(maxScrol) end
        if maxScrol <= 0 then
            bar:Hide()
            return
        end
        bar:Show()
        local frac   = math.min(1, viewH / totalH)
        local thumbH = math.max(20, viewH * frac)
        local travel = viewH - thumbH
        local pos    = (self:GetVerticalScroll() / maxScrol) * travel
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -pos)
        -- Kept for the drag maths below, which needs the travel distance and cannot
        -- recompute it from a frame mid-drag without fighting its own SetPoint.
        self.thumbTravel = travel
    end

    -- Cursor position comes back in screen pixels at the *root* scale, so it has to
    -- be divided by the frame's effective scale before it can be compared with
    -- anything measured off the frame itself. Skipping that makes dragging track the
    -- cursor at the wrong speed on any UI scale other than 1.
    local function CursorY()
        local _, y = GetCursorPosition()
        return y / (thumb:GetEffectiveScale() or 1)
    end

    local function OnDrag(self)
        local travel = scroll.thumbTravel or 0
        if travel <= 0 then return end
        -- Cursor down is a decreasing y, and scrolling down is an increasing scroll
        -- value, hence grab minus now rather than the other way round.
        local delta = (self.grabY - CursorY()) * (MaxScroll() / travel)
        ScrollTo(self.grabScroll + delta)
    end

    thumb:SetScript("OnMouseDown", function(self)
        self.grabY      = CursorY()
        self.grabScroll = scroll:GetVerticalScroll()
        thumbTex:SetColorTexture(1, 1, 1, 0.9)
        self:SetScript("OnUpdate", OnDrag)
    end)
    -- OnHide as well as OnMouseUp: releasing the button outside the frame does not
    -- always deliver OnMouseUp, and an OnUpdate left running would drag the list
    -- around with the cursor forever.
    local function EndDrag(self)
        self:SetScript("OnUpdate", nil)
        thumbTex:SetColorTexture(unpack(C.accent))
    end
    thumb:SetScript("OnMouseUp", EndDrag)
    thumb:SetScript("OnHide", EndDrag)

    -- Clicking the track pages toward the click rather than jumping to it. A jump
    -- would be a guess at where in the list that pixel means; a page is the same
    -- thing the wheel does, only faster.
    bar:SetScript("OnMouseDown", function(self)
        local viewH = scroll:GetHeight() or 1
        local top   = thumb:GetTop()
        local bot   = thumb:GetBottom()
        local y     = CursorY()
        if top and bot and y <= top and y >= bot then return end   -- on the thumb
        ScrollTo(scroll:GetVerticalScroll() + ((top and y > top) and -viewH or viewH))
    end)

-- If the content frame is still sitting at zero when the scroll frame gets its
    -- real size, give it that size. A frame positioned by anchors measures 0 until a
    -- layout pass has run, so a caller that sized its content from scroll:GetWidth()
    -- on the very first call built every row zero-wide - which is the "the list is
    -- empty until I click a second time" bug, and it has now been found three times.
    --
    -- Only when it is zero: several callers set a deliberate width, and clobbering
    -- those would trade this bug for a layout one. Rows are anchored to the content's
    -- edges, so they take the corrected width with them.
    --
    -- The width of the *scroll frame* is checked too, and that is not belt and braces.
    -- This handler also fires during the first layout pass, while the scroll frame
    -- itself still measures 0. Without the check it copies that 0 onto the content, the
    -- content is then no longer "unset" - 0 is still <= 1 - and no further size change
    -- arrives to correct it. Rows anchored to the content's two top corners come out
    -- zero-wide, which still *draws*, because a FontString does not clip to its parent,
    -- but a zero-wide Button has no hit rectangle: a list you can read and cannot click.
    -- Every list here also sets an explicit content width at its call site, which is the
    -- primary mechanism; this stays a backstop for the next one that does not.
    scroll:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth() or 0
        if w > 1 and (self.content:GetWidth() or 0) <= 1 then
            self.content:SetWidth(w)
        end
        if self.UpdateBar then self:UpdateBar() end
    end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local viewH    = self:GetHeight() or 1
        local maxScrol = math.max(0, (content:GetHeight() or 1) - viewH)
        local new = math.max(0, math.min(maxScrol, self:GetVerticalScroll() - delta * 34))
        self:SetVerticalScroll(new)
        self:UpdateBar()
    end)

    return scroll
end

--------------------------------------------------------------------------------
-- Media picker
--
-- A scrolling list, not a cycling button. The font control used to step through the
-- list one press at a time, which is fine for four options and unusable for the
-- hundred-odd a LibSharedMedia user has - there is no way to see what is available,
-- and reaching the end means clicking past everything in front of it.
--
-- Every name is drawn IN ITS OWN FACE, because a font list written in one font tells
-- you nothing about any of them.
--
-- Ported from nugsBuffAlert, which already had this. The behaviour it brings with it
-- was worked out the hard way and is the same in every nugs window: closes on a click
-- away, closes on Escape without also closing the window behind it, opens upwards
-- when there is no room below, and never outlives the panel that owns it.
--------------------------------------------------------------------------------

local POPUP_BG = { 0.06, 0.07, 0.09, 0.97 }

local function PopupChrome(frame)
    Backdrop(frame, POPUP_BG, 1)
    for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                         { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
        local edge = frame:CreateTexture(nil, "OVERLAY")
        edge:SetPoint(p[1]); edge:SetPoint(p[2])
        if p[3] == "h" then edge:SetHeight(1) else edge:SetWidth(1) end
        edge:SetColorTexture(0.35, 0.72, 1.00, 0.55)
    end
end

-- Shared behaviour for every floating list: closes when you click away from it,
-- closes on Escape, and never outlives the window it belongs to.
--
-- There is no "clicked anywhere" event, so the outside click is caught by a full
-- screen button underneath the popup, shown and hidden with it. It swallows the click
-- that dismisses - first click closes, second one acts - which is how every dropdown
-- in the game behaves, Blizzard's included.
local function AttachPopupBehaviour(popup)
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:RegisterForClicks("AnyUp")
    catcher:Hide()
    catcher:SetScript("OnClick", function() popup:Hide() end)

    -- Escape closes the list rather than the window behind it. Propagation is left on
    -- for every other key, so this never swallows movement or typing; it is turned off
    -- only for the Escape actually being handled.
    popup:EnableKeyboard(true)
    SafePropagate(popup, true)
    popup:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and not InCombatLockdown() then
            SafePropagate(self, false)
            self:Hide()
        else
            SafePropagate(self, true)
        end
    end)

    -- The owner is read back from the popup's own SetPoint rather than passed in, so
    -- this works for every caller without any of them having to remember to say who
    -- owns them. IsVisible is false when any ancestor is hidden, which is exactly the
    -- case being watched for - a popup orphaned by its panel closing underneath it.
    local function WatchOwner(self)
        if self.owner and not self.owner:IsVisible() then self:Hide() end
    end

    popup:HookScript("OnShow", function(self)
        local _, relativeTo = self:GetPoint(1)
        self.owner = relativeTo
        self:SetScript("OnUpdate", WatchOwner)
        catcher:SetFrameStrata(self:GetFrameStrata())
        catcher:SetFrameLevel(110)
        self:SetFrameLevel(120)
        catcher:Show()
    end)
    popup:HookScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        SafePropagate(self, true)
        catcher:Hide()
    end)
    return popup
end

-- Drops down if there is room and opens upwards if there is not. Clamping alone would
-- slide the list over the button that opened it, hiding the thing being changed.
local function PlacePopup(popup, anchorTo)
    popup:ClearAllPoints()
    local below = (anchorTo:GetBottom() or 0) - popup:GetHeight()
    if below < 20 then
        popup:SetPoint("BOTTOMLEFT", anchorTo, "TOPLEFT", 0, 2)
    else
        popup:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -2)
    end
    popup:Show()
end

local function EnsurePopup(existing, width, height)
    if existing then return existing end
    local popup = CreateFrame("Frame", nil, UIParent)
    popup:SetSize(width, height)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:EnableMouse(true)
    popup:SetClampedToScreen(true)
    PopupChrome(popup)
    popup.scroll = ScrollArea(popup)
    popup.scroll:SetPoint("TOPLEFT", 5, -5)
    popup.scroll:SetPoint("BOTTOMRIGHT", -5, 5)
    popup.rows = {}
    AttachPopupBehaviour(popup)
    return popup
end

-- `style` is handed each row so the font list can draw every name in its own face.
local function FillPopup(popup, entries, onPick, style)
    local content = popup.scroll.content
    -- Width from the popup's own SetSize, NOT from scroll:GetWidth(). The scroll is
    -- sized by anchors, so on the very first call - the frame having been created
    -- microseconds earlier with no layout pass yet - it measures 0, every row is built
    -- zero-wide, and the list looks empty until you click a second time.
    content:SetWidth(popup:GetWidth() - 10)

    for index, entry in ipairs(entries) do
        local row = popup.rows[index]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * 22)
            row:SetPoint("TOPRIGHT", 0, -(index - 1) * 22)
            row.stripe = row:CreateTexture(nil, "BACKGROUND")
            row.stripe:SetAllPoints()
            row.stripe:SetColorTexture(1, 1, 1, 0)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", 6, 0)
            row.label:SetPoint("RIGHT", -6, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row:SetScript("OnEnter", function(self) self.stripe:SetColorTexture(unpack(C.rowB)) end)
            row:SetScript("OnLeave", function(self) self.stripe:SetColorTexture(1, 1, 1, 0) end)
            popup.rows[index] = row
        end

        row.label:SetFontObject("GameFontHighlightSmall")
        row.label:SetText(entry.name)
        if style then style(row, entry) end
        row:SetScript("OnClick", function()
            onPick(entry)
            popup:Hide()
        end)
        row:Show()
    end

    for index = #entries + 1, #popup.rows do popup.rows[index]:Hide() end

    content:SetHeight(math.max(1, #entries * 22))
    popup.scroll:SetVerticalScroll(0)
    popup.scroll:UpdateBar()
end

local fontPopup

local function ToggleFontPicker(anchorTo, onPick)
    if fontPopup and fontPopup:IsShown() then fontPopup:Hide() return end
    fontPopup = EnsurePopup(fontPopup, 232, 268)
    FillPopup(fontPopup, NAU.FontList(), function(entry) onPick(entry.name) end,
        function(row, entry)
            -- Previewed in the font itself, and named as unavailable rather than
            -- silently drawn in the default face if the file will not load - a name
            -- you can pick that then does not draw is worse than not offering it.
            local ok, applied = pcall(row.label.SetFont, row.label, entry.path, 13, "")
            if not ok or applied == false then
                row.label:SetFontObject("GameFontHighlightSmall")
                row.label:SetText(entry.name .. " |cff888888(unavailable)|r")
            end
        end)
    PlacePopup(fontPopup, anchorTo)
end

-- A button that reads "Font: Friz Quadrata TT" and opens the list.
local function MediaButton(parent, prefix, getter, onOpen)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(ROW_H)

    local btn
    btn = Button(holder, "", 100, ROW_H, function() onOpen(btn) end)
    btn:SetPoint("LEFT", 0, 0)
    btn:SetPoint("RIGHT", 0, 0)

    holder.Refresh = function()
        local v = getter()
        if v == nil or v == "" then v = "none" end
        btn:SetLabel(prefix .. ": " .. tostring(v))
    end
    sink[#sink + 1] = holder
    return holder
end

--------------------------------------------------------------------------------
-- Column layout
-- Widgets declare when they are relevant (`show`), and the column re-flows around
-- whatever is hidden. That is what lets one panel serve a group driven by tokens
-- and a group driven by a spell list without leaving holes where the other one's
-- controls would have been.
--------------------------------------------------------------------------------

local function NewColumn(parent, xOffset, width)
    local col = { parent = parent, x = xOffset, width = width, items = {} }

    function col:Add(region, height, show, indent)
        local isText = region.GetObjectType and region:GetObjectType() == "FontString"
        self.items[#self.items + 1] = {
            region = region, h = height, show = show,
            indent = indent or 0, stretch = not isText,
        }
        return region
    end

    -- The leading gap carries the section's own visibility, so a section that does
    -- not apply leaves no hole where it would have been.
    function col:Header(text, show)
        self:Gap(6, show)
        return self:Add(SectionHeader(self.parent, text), 22, show)
    end

    function col:Hint(text, show)
        local fs = Label(self.parent, text, "GameFontDisableSmall", C.faint)
        fs:SetWordWrap(true)
        local _, lines = text:gsub("\n", "")
        return self:Add(fs, 16 + lines * 12, show)
    end

    function col:Gap(h, show)
        self.items[#self.items + 1] = { h = h, show = show }
    end

    function col:Layout()
        local y = 0
        for _, item in ipairs(self.items) do
            local visible = (not item.show) or item.show()
            if item.region then
                if visible then
                    item.region:Show()
                    item.region:ClearAllPoints()
                    item.region:SetPoint("TOPLEFT", self.parent, "TOPLEFT",
                        self.x + item.indent, -y)
                    if item.stretch then
                        item.region:SetPoint("TOPRIGHT", self.parent, "TOPLEFT",
                            self.x + self.width, -y)
                    else
                        item.region:SetWidth(self.width - item.indent)
                    end
                    y = y + item.h
                else
                    item.region:Hide()
                end
            elseif visible then
                y = y + item.h
            end
        end
        return y
    end

    return col
end

--------------------------------------------------------------------------------
-- Group list
--------------------------------------------------------------------------------

local function SelectGroup(id)
    selectedID = id
    if NAU.char then NAU.char.lastGroup = id end
    RebuildGroupList()
    NAU.RefreshOptions()
end

RebuildGroupList = function()
    if not groupList then return end
    local db = NAU.db
    local content = groupList.content
    groupList.rows = groupList.rows or {}

    local y = 0
    for i, id in ipairs(db.groupOrder) do
        local g = db.groups[id]
        local row = groupList.rows[i]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(30)
            Backdrop(row, C.rowA, nil)

            row.name = Label(row, "", "GameFontHighlightSmall")
            row.name:SetPoint("TOPLEFT", 8, -4)
            row.name:SetPoint("RIGHT", -26, 0)

            row.sub = Label(row, "", "GameFontDisableSmall", C.faint)
            row.sub:SetPoint("BOTTOMLEFT", 8, 4)

            row.mark = row:CreateTexture(nil, "OVERLAY")
            row.mark:SetSize(3, 22)
            row.mark:SetPoint("LEFT", 0, 0)
            row.mark:SetColorTexture(unpack(C.accent))

            -- Right-click enables or disables rather than opening a menu: it is the
            -- only per-row action worth a click of its own, and a menu for one item
            -- is a menu nobody reads.
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            groupList.rows[i] = row
        end

        row.groupID = id
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.name:SetText(g.name)
        row.name:SetTextColor(unpack(g.enabled and C.text or C.faint))
        row.sub:SetText(string.format("%s  |cff666666%s%s|r", g.unit,
            g.mineOnly and "mine " or "",
            g.kind == "HARMFUL" and "debuffs" or "buffs"))
        row.mark:SetShown(id == selectedID)
        row.bgTex:SetColorTexture(unpack(id == selectedID and C.rowB or C.rowA))

        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                local grp = NAU.db.groups[self.groupID]
                grp.enabled = not grp.enabled
                NAU.Display:Rebuild()
            end
            SelectGroup(self.groupID)
        end)
        row:Show()

        y = y + 31
    end

    for i = #db.groupOrder + 1, #groupList.rows do
        groupList.rows[i]:Hide()
    end

    content:SetHeight(math.max(1, y))
    groupList:UpdateBar()
end

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------

local TABS = {
    { key = "filter", label = "What to show" },
    { key = "layout", label = "Layout"       },
    { key = "look",   label = "Look"         },
    { key = "spells", label = "Spells"       },
}

local BUILDERS = {}

function BUILDERS.filter(p)
    sink = p.widgets
    local content = p.content
    local L = NewColumn(content, 0, COL_W)
    local R = NewColumn(content, COL_W + COL_GAP, COL_W)
    p.cols = { L, R }

    ------------------------------------------------------------------ left column
    L:Header("Group")

    local nameBox = EditBox(content, 22, function(text)
        local g = G()
        if g and text ~= "" then
            g.name = text
            Apply()
            RebuildGroupList()
        end
        NAU.RefreshOptions()
    end)
    nameBox.Refresh = function()
        local g = G()
        if g and not nameBox:HasFocus() then nameBox:SetText(g.name) end
    end
    sink[#sink + 1] = nameBox
    L:Add(nameBox, 26)

    L:Add(Check(content, "Enabled",
        function() return G() and G().enabled end,
        function(v) G().enabled = v; NAU.Display:Rebuild() end), ROW_H)

    L:Header("Source")

    L:Add(Choice(content, "Unit", NAU.UNITS,
        function() return G() and G().unit end,
        function(v) G().unit = v; NAU.Display:Rebuild() end), 26)

    L:Add(Choice(content, "Type",
        { { key = "HARMFUL", label = "Debuffs" }, { key = "HELPFUL", label = "Buffs" } },
        function() return G() and G().kind end,
        function(v) G().kind = v end), 26)

    L:Add(Check(content, "Only auras I applied",
        function() return G() and G().mineOnly end,
        function(v) G().mineOnly = v end,
        "Adds the PLAYER filter, which the client evaluates. Works in combat."), ROW_H)

    L:Header("Sorting")

    L:Add(Choice(content, "Order",
        { { key = "default",    label = "Mine first"      },
          { key = "expiration", label = "Mine, then time" },
          { key = "expiryonly", label = "Time remaining"  },
          { key = "name",       label = "Name"            },
          { key = "unsorted",   label = "As they come"    } },
        function() return G() and (G().sort or "default") end,
        function(v) G().sort = v end), 26)

    L:Add(Check(content, "Reverse order",
        function() return G() and G().sortReverse end,
        function(v) G().sortReverse = v end), ROW_H)

    L:Hint("Sorting happens in the client. The addon is not allowed to compare\ntwo expiry times itself, so these are the orders that exist.")

    ----------------------------------------------------------------- right column
    R:Header("Categories")
    R:Hint("Blizzard's own classifications, evaluated by the game. Use these when you\n" ..
           "cannot know in advance what will be applied - a boss, or anything you have\n" ..
           "not seen yet.")

    -- Said where the controls are, not in a tab somebody has to go and find. A group
    -- set to "Only these" ignores everything below, and a category silently vetoing a
    -- spell the player named would be impossible to work out from the screen.
    R:Hint("|cffffd479Not used while the Spells tab is set to 'Only these'.|r\n" ..
           "That mode means only the spells you listed, so these are ignored rather\n" ..
           "than narrowing it further - a category and a named spell together would\n" ..
           "match only auras that are both, which is usually nothing.",
        function() local g = G() return g and g.spellMode == "only" end)

    for _, entry in ipairs(NAU.TOKENS) do
        local key   = entry.key
        local modes = NAU.TokenModes(entry)
        R:Add(Choice(content, entry.label, modes,
            function()
                local g = G()
                return g and (g.tokens[key] or "off")
            end,
            function(v)
                local g = G()
                g.tokens[key] = (v ~= "off") and v or nil
            end), 26)
        R:Hint("   " .. entry.hint)
    end

    R:Gap(8)
    local filterFS = Label(content, "", "GameFontDisableSmall", C.faint)
    filterFS.Refresh = function()
        local g = G()
        filterFS:SetText(g and ("Filter sent to the client:  |cff8cd2ff" .. NAU.BuildFilter(g) .. "|r") or "")
    end
    sink[#sink + 1] = filterFS
    R:Add(filterFS, 30)
end

function BUILDERS.layout(p)
    sink = p.widgets
    local content = p.content
    local L = NewColumn(content, 0, COL_W)
    local R = NewColumn(content, COL_W + COL_GAP, COL_W)
    p.cols = { L, R }

    L:Header("Arrangement")

    L:Add(Choice(content, "Grows", NAU.GROWTH,
        function() return G() and G().growth end,
        function(v) G().growth = v end), 26)

    L:Add(Slider(content, "Icon size", 12, 96, 1,
        function() return G() and G().size or 36 end,
        function(v) G().size = v end, "%d px"), 42)

    L:Add(Slider(content, "Spacing", 0, 24, 1,
        function() return G() and G().spacing or 4 end,
        function(v) G().spacing = v end, "%d px"), 42)

    L:Add(Slider(content, "Scale", 0.5, 2.0, 0.05,
        function() return G() and G().scale or 1 end,
        function(v) G().scale = v end, "%.2fx"), 42)

    R:Header("How many")

    R:Add(Slider(content, "Most icons shown", 1, 40, 1,
        function() return G() and G().maxCount or 8 end,
        function(v) G().maxCount = v end, "%d"), 42)

    R:Add(Slider(content, "Wrap after", 1, 20, 1,
        function() return G() and G().perRow or 8 end,
        function(v) G().perRow = v end, "%d"), 42)

    R:Hint("Icons past the wrap start a new line, offset in the direction\nthe group grows.")

    R:Header("When to show")

    -- Spell lists only, and shown as unavailable rather than quietly ignored on the
    -- other modes. Emptiness is worked out by asking the game about the spells you
    -- named; a category group has no named spells to ask about, and the icons
    -- themselves belong to the game and cannot be counted.
    R:Add(Check(content, "Hide the group when it is empty",
        function() return G() and G().hideWhenEmpty end,
        function(v) G().hideWhenEmpty = v end,
        "Works on groups set to |cffffd479Only these|r. The icons are drawn by the game and cannot be counted, so an empty group is worked out from the spells you listed - and a category group has none to ask about."),
        ROW_H, function() local g = G() return g and g.spellMode == "only" end)

    R:Hint("|cff888888Available on |r|cffffd479Only these|r|cff888888 spell lists.|r",
        function() local g = G() return g and g.spellMode ~= "only" end)

    R:Add(Check(content, "Only in combat",
        function() return G() and G().onlyInCombat end,
        function(v) G().onlyInCombat = v end), ROW_H)

    R:Gap(10)
    local posFS = Label(content, "", "GameFontDisableSmall", C.faint)
    posFS.Refresh = function()
        local g = G()
        posFS:SetText(g and string.format("Anchored %s at %d, %d", g.point, g.x, g.y) or "")
    end
    sink[#sink + 1] = posFS
    R:Add(posFS, 18)

    local centreBtn = Button(content, "Move to centre", 140, 24, function()
        local g = G()
        g.point, g.relPoint, g.x, g.y = "CENTER", "CENTER", 0, 0
        Apply()
        NAU.RefreshOptions()
    end)
    sink[#sink + 1] = centreBtn
    R:Add(centreBtn, 28)
end

function BUILDERS.look(p)
    sink = p.widgets
    local content = p.content
    local L = NewColumn(content, 0, COL_W)
    local R = NewColumn(content, COL_W + COL_GAP, COL_W)
    p.cols = { L, R }

    local function borderOn() local g = G() return g and g.showBorder end
    local function textOn()   local g = G() return g and (g.showTimer or g.showStacks) end

    L:Header("Icon")

    L:Add(Check(content, "Crop the icon border",
        function() return G() and G().zoomIcon end,
        function(v) G().zoomIcon = v end,
        "Trims the dull edge off the stock icon art."), ROW_H)

    L:Add(Check(content, "Cooldown swipe",
        function() return G() and G().showSwipe end,
        function(v) G().showSwipe = v end,
        "The dark sweep counting the aura down. Driven by the client, so it stays accurate even when the addon cannot read the time."), ROW_H)

    L:Add(Check(content, "Swipe the other way",
        function() return G() and G().reverseSwipe end,
        function(v) G().reverseSwipe = v end,
        "Off: the dark wedge covers what is left and shrinks away, so the icon gets brighter as the aura runs out. On: the icon starts clear and darkens as time is spent, the way most cooldown displays read."),
        ROW_H, function() local g = G() return g and g.showSwipe end)

    -- Only meaningful in "Only what is missing", and hidden otherwise rather than
    -- sitting there doing nothing on every other group.
    local isMissing = function() local g = G() return g and g.spellMode == "missing" end

    L:Add(Check(content, "Grey out the placeholder",
        function() return G() and G().missingDesat end,
        function(v) G().missingDesat = v end,
        "The placeholder should not be mistakable for the live aura that replaces it - the whole point is telling at a glance which of your dots are still owed."),
        ROW_H, isMissing)

    L:Add(Swatch(content, "Placeholder tint",
        function() return G() and G().missingTint end, true), ROW_H, isMissing)

    L:Add(Check(content, "Border on the placeholder",
        function() return G() and G().missingBorder end,
        function(v) G().missingBorder = v end,
        "In the same colour as the tint."), ROW_H, isMissing)


    L:Add(Check(content, "Dim auras that are not mine",
        function() return G() and G().desatOthers end,
        function(v) G().desatOthers = v end), ROW_H)

    L:Header("Border")

    L:Add(Check(content, "Show a border",
        function() return G() and G().showBorder end,
        function(v) G().showBorder = v end), ROW_H)

    L:Add(Slider(content, "Border thickness", 1, 6, 1,
        function() return G() and G().borderSize or 1 end,
        function(v) G().borderSize = v end, "%d px"), 42, borderOn)

    L:Add(Swatch(content, "Border colour",
        function() return G() and G().borderColor end, true), ROW_H, borderOn)

    -- "Colour it by dispel type" was removed in the 12.1 rewrite rather than left
    -- as a toggle that does nothing. The old version got the colour by handing a
    -- secret dispel type through a colour curve, which needed the aura in Lua. The
    -- engine draws the icon now and exposes bindings for icon, cooldown, duration
    -- text, stacks and name - there is no dispel binding among them.
    R:Header("Text")

    R:Add(Check(content, "Time remaining",
        function() return G() and G().showTimer end,
        function(v) G().showTimer = v end), ROW_H)

    R:Add(Check(content, "Stack count",
        function() return G() and G().showStacks end,
        function(v) G().showStacks = v end), ROW_H)

    R:Add(Slider(content, "Hide stacks below", 1, 10, 1,
        function() return G() and G().stackMin or 2 end,
        function(v) G().stackMin = v end, "%d"), 42,
        function() local g = G() return g and g.showStacks end)

    -- A list, not a cycling button. Stepping through a hundred LibSharedMedia fonts
    -- one press at a time is not a control, and it never showed what was available.
    R:Add(MediaButton(content, "Font",
        function() return G() and G().font end,
        function(btn)
            ToggleFontPicker(btn, function(name)
                G().font = name
                Apply()
                NAU.RefreshOptions()
            end)
        end), ROW_H, textOn)

    R:Add(Slider(content, "Font size", 6, 24, 1,
        function() return G() and G().fontSize or 12 end,
        function(v) G().fontSize = v end, "%d"), 42, textOn)

    R:Add(Choice(content, "Outline", NAU.OUTLINES,
        function() return G() and G().fontOutline end,
        function(v) G().fontOutline = v end), 26, textOn)

    R:Add(Swatch(content, "Timer colour",
        function() return G() and G().timerColor end, false), ROW_H,
        function() local g = G() return g and g.showTimer end)

    R:Add(Swatch(content, "Stack colour",
        function() return G() and G().stackColor end, false), ROW_H,
        function() local g = G() return g and g.showStacks end)

    R:Gap(8)
    local copyBtn = Button(content, "Use this look for every group", 220, 24, function()
        local n = NAU.ApplyLookEverywhere(selectedID)
        Apply()
        NAU.Print("copied this group's look onto " .. n .. " other group(s).")
        NAU.RefreshOptions()
    end)
    sink[#sink + 1] = copyBtn
    R:Add(copyBtn, 28)
    R:Hint("Copies size, spacing, fonts and colours. Leaves each group's\nunit, filter, spells and position alone.")
end

--------------------------------------------------------------------------------
-- Spells tab
--
-- The readability mark beside each spell is the point of this whole panel. A spell
-- list looks like it works right up until the pull, and the client will not tell
-- us at read time whether a nil meant "absent" or "not allowed" - so the only
-- honest moment to say so is here, while the list is being built.
--------------------------------------------------------------------------------

local spellRows = {}

-- What a listed spell will actually do, which changed completely with the 12.1
-- rewrite and had been reporting the old answer.
--
-- These marks used to describe whether LUA could read the aura - "never readable",
-- "out of combat only", "via Cooldown Manager". None of that governs the display any
-- more. Blizzard's engine draws the icons from aura data the addon never touches, so
-- a spell this window called "never readable" shows up perfectly. Leaving the old
-- labels in place told people their working spells would not work.
--
-- One thing still depends on a readable aura, and only one: "hide the group when it
-- is empty" asks the game about each listed spell by id. A spell whose aura is always
-- secret cannot answer, so that group stays visible. Everything else is unaffected,
-- which is why that is the only caveat shown.
local function SpellMark(spellID)
    local secrecy = NAU.SpellSecrecy(spellID)
    if secrecy == "never" then
        return "|cffffd479", "shown by the game (cannot auto-hide)"
    end
    return "|cff80ff80", "shown by the game"
end

function BUILDERS.spells(p)
    sink = p.widgets
    local content = p.content
    local L = NewColumn(content, 0, CONTENT_W)
    p.cols = { L }

    L:Header("Spell list")

    L:Add(Choice(content, "Mode", NAU.SPELL_MODES,
        function() return G() and G().spellMode end,
        function(v) G().spellMode = v end), 26)

    L:Hint("|cffffd479Only these|r shows nothing but the spells you list, and |cffffd479ignores the\n" ..
           "Categories on the Look tab|r - the list is the whole filter.\n" ..
           "|cffffd479All but these|r hides the listed spells from whatever the categories let through.\n" ..
           "|cffffd479Off|r ignores the list entirely and the categories decide.\n" ..
           "|cffffd479Always show these|r keeps every listed spell on screen - read on.")

    L:Hint("Every listed spell keeps its own position, always. While it is |cffffd479not|r on the\n" ..
           "unit it shows as a tinted placeholder; the moment it lands the game draws it\n" ..
           "properly, with its swipe, timer and stacks like any other group.\n\n" ..
           "Point it at |cffffd479target|r or |cffffd479focus|r and list your dots: what is dull is what you\n" ..
           "still owe, what is lit is ticking, and the row never moves.\n\n" ..
           "|cff888888Categories are ignored here, as they are in 'Only these' - the list is\n" ..
           "the whole filter.|r",
        function() local g = G() return g and g.spellMode == "missing" end)

    L:Hint("Each listed spell holds its own slot, so an inactive one leaves a gap\n" ..
           "rather than shuffling the rest along. That fixed order is the point.",
        function() local g = G() return g and g.spellMode == "only" end)

    -- Declared up here rather than beside the scanner below, because the add box
    -- writes into them when a name matches more than one spell.
    local scanResults, scanNote = {}, ""

    local function AddSpell(spellID)
        local g = G()
        if not g or not spellID then return end
        if not g.spells[spellID] then
            g.spells[spellID] = true
            g.spellOrder[#g.spellOrder + 1] = spellID
            Apply()
        end
        NAU.RefreshOptions()
    end

    -- ONE box, not two. There used to be an "add" box here and a "search" box
    -- further down, and the difference between them was never visible: both took a
    -- name or an id, and the add box quietly turned into the search box whenever a
    -- name was ambiguous.
    --
    -- Merging them also fixes the more important problem, which is that the add box
    -- COMMITTED an id without ever showing what it resolved to. Most spells carry
    -- more than one id - the ability you cast and the aura it applies are different
    -- numbers, and a tooltip usually shows the wrong one for this purpose - so
    -- adding by number was a coin flip you could not see the result of.
    --
    -- Everything typed here now produces a list you look at before committing.
    -- Typing a number looks that number up and shows you the spell it belongs to,
    -- which is the check that was missing.
    local addBox
    local function RunSearch(text)
        text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
            scanResults, scanNote = {}, ""
            NAU.RefreshOptions()
            return
        end

        local spellID = tonumber(text)
        if spellID then
            local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
            if name then
                scanResults = { { spellID = spellID, name = name } }
                scanNote = "|cff80ff80" .. name .. "|r is spell " .. spellID
                          .. ". Click |cff80ff80+|r to add it."
            else
                scanResults = {}
                scanNote = "|cffff8080no spell with id " .. spellID .. "|r on this client."
            end
            NAU.RefreshOptions()
            return
        end

        local found, more = NAU.SearchSpells(text, 40)
        scanResults = found
        if #found == 0 then
            scanNote = "nothing known called |cffffffff" .. text .. "|r. Cast it once, or scan a unit below."
        else
            scanNote = string.format("%d match(es)%s. Click |cff80ff80+|r to add one.",
                #found, more > 0 and (", " .. more .. " more not shown") or "")
        end
        NAU.RefreshOptions()
    end

    addBox = EditBox(content, 24, function(text)
        -- Enter adds outright only when there is exactly one candidate, because then
        -- there is nothing to choose between. Anything else lists and waits.
        RunSearch(text)
        if #scanResults == 1 then AddSpell(scanResults[1].spellID) end
    end, "spell name or id", RunSearch)
    sink[#sink + 1] = addBox
    L:Add(addBox, 28)

    ---------------------------------------------------------------------- scanner
    -- The answer to "where do I get a spell id". Typing one in from a website or a
    -- tooltip addon is how people get it wrong: the id shown for an ability is
    -- often the *cast*, and the aura it applies carries a different one. Reading
    -- the aura off a live unit cannot make that mistake.
    L:Gap(4)

    -- Scanning answers a question searching cannot - "what is actually on this
    -- thing" - but it is much weaker than it looks, and the window used to oversell
    -- it. Two limits stack: auras can only be read OUT of combat, and this window
    -- closes itself when a fight starts. So scanning a boss mid-pull, which is the
    -- obvious use, is impossible in both directions at once.
    --
    -- What it is genuinely good for is a target dummy, or a debuff still ticking
    -- after a fight. Searching by name is the primary route and works anywhere,
    -- because it reads spell data rather than auras.
    L:Header("Or read what is on a unit")
    L:Hint("|cffffd479Only works out of combat|r, and this window closes when a fight\n" ..
           "starts - so a boss mid-pull cannot be scanned. Use a target dummy, or\n" ..
           "search by name above, which works anywhere and needs nothing to be up.")

    local scanRow = CreateFrame("Frame", nil, content)
    scanRow:SetHeight(26)

    local function DoScan(unit)
        local found, skipped, err = NAU.ScanAuras(unit)
        scanResults = found or {}
        if err then
            scanNote = "|cffff8080" .. err .. "|r"
        elseif skipped > 0 and #scanResults == 0 then
            scanNote = string.format(
                "|cffff8080%d aura(s) on %s, none readable right now.|r Scanning only works out of combat - search above instead.",
                skipped, unit)
        elseif skipped > 0 then
            scanNote = string.format("%d readable, |cffff8080%d withheld|r on %s.",
                #scanResults, skipped, unit)
        elseif #scanResults == 0 then
            scanNote = "no auras on " .. unit .. " right now."
        else
            scanNote = string.format("%d aura(s) on %s. Click |cff80ff80+|r to add one.",
                #scanResults, unit)
        end
        NAU.RefreshOptions()
    end

    local x = 0
    for _, entry in ipairs({ { "Scan target", "target" }, { "Scan focus", "focus" },
                            { "Scan me", "player" } }) do
        local b = Button(scanRow, entry[1], 92, 24, function()
            addBox:SetText("")
            DoScan(entry[2])
        end)
        b:SetPoint("LEFT", x, 0)
        x = x + 96
    end

    -- Everything this character has had on it while the client was naming auras.
    -- Recorded on its own; this button just shows the pile.
    local seenBtn = Button(scanRow, "Seen before", 100, 24, function()
        addBox:SetText("")
        scanResults = NAU.SeenSpells()
        table.sort(scanResults, function(a, b) return a.name < b.name end)
        scanNote = (#scanResults == 0)
            and "nothing recorded yet - it fills in by itself whenever auras are readable."
            or string.format("%d aura(s) this character has seen.", #scanResults)
        NAU.RefreshOptions()
    end)
    seenBtn:SetPoint("LEFT", x, 0)
    x = x + 104

    local clearBtn = Button(scanRow, "Clear", 56, 24, function()
        addBox:SetText("")
        scanResults, scanNote = {}, ""
        NAU.RefreshOptions()
    end)
    clearBtn:SetPoint("LEFT", x, 0)

    sink[#sink + 1] = scanRow
    L:Add(scanRow, 30)

    local scanNoteFS = Label(content, "", "GameFontDisableSmall", C.faint)
    scanNoteFS.Refresh = function() scanNoteFS:SetText(scanNote) end
    sink[#sink + 1] = scanNoteFS
    L:Add(scanNoteFS, 18)

    -- Results are their own pooled block, rebuilt on scan rather than through the
    -- column, so a scan does not re-lay out everything above it.
    local scanRows = {}
    local scanHolder = CreateFrame("Frame", nil, content)
    scanHolder:SetHeight(1)

    scanHolder.Refresh = function()
        local g = G()
        local y = 0
        for i, found in ipairs(scanResults) do
            local row = scanRows[i]
            if not row then
                row = CreateFrame("Frame", nil, scanHolder)
                row:SetHeight(24)
                Backdrop(row, C.rowA, nil)

                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(18, 18)
                row.icon:SetPoint("LEFT", 4, 0)
                row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

                row.text = Label(row, "", "GameFontHighlightSmall")
                row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)

                row.state = Label(row, "", "GameFontDisableSmall", C.faint)
                row.state:SetPoint("RIGHT", -32, 0)
                row.state:SetJustifyH("RIGHT")

                row.add = Button(row, "+", 22, 18, function()
                    AddSpell(row.spellID)
                end)
                row.add:SetPoint("RIGHT", -6, 0)

                scanRows[i] = row
            end

            row.spellID = found.spellID
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("TOPRIGHT", 0, -y)
            row.bgTex:SetColorTexture(unpack(i % 2 == 0 and C.rowB or C.rowA))
            row.icon:SetTexture(found.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            -- `mine` only exists on scan results; `source` only on search results.
            -- One row type renders both, so neither is assumed present.
            local WHERE = {
                tracked   = " |cff8cd2ff[cooldown manager]|r",
                seen      = " |cff888888[seen before]|r",
                spellbook = " |cff888888[spellbook]|r",
            }
            -- Several ids sharing this name are one row, and the count says so
            -- rather than leaving it looking like results are missing. Which of them
            -- gets added does not matter: the filter is built from every id with
            -- this name either way.
            local dupes = (found.idCount and found.idCount > 1)
                and string.format(" |cff888888(+%d more id)|r", found.idCount - 1) or ""
            row.text:SetText(string.format("%s%s|r |cff666666%d|r%s%s",
                found.mine and "|cffffffff" or "|cffaaaaaa",
                found.name, found.spellID,
                dupes,
                (found.source and WHERE[found.source]) or ""))

            local color, verdict = SpellMark(found.spellID)
            local already = g and g.spells[found.spellID]
            row.state:SetText(already and "|cff8cd2ffin the list|r" or (color .. verdict .. "|r"))
            row.add:SetGrey(already and true or false)
            row:Show()
            y = y + 25
        end

        for i = #scanResults + 1, #scanRows do scanRows[i]:Hide() end
        scanHolder:SetHeight(math.max(1, y))
    end

    sink[#sink + 1] = scanHolder
    L:Add(scanHolder, 1)
    p.scanHolder = scanHolder

    L:Gap(10)
    L:Header("In this group")
    L:Gap(2)

    -- The rows are rebuilt into a fixed holder rather than added to the column, so
    -- adding a spell does not have to re-lay out everything above it.
    local holder = CreateFrame("Frame", nil, content)
    holder:SetHeight(1)

    holder.Refresh = function()
        local g = G()
        local y = 0
        local order = (g and g.spellOrder) or {}

        -- What is genuinely on the group's unit, so each row can say whether its id
        -- matches reality. This is the check that catches a cast id standing in for
        -- an aura id, which is the most common reason a list shows nothing.
        NAU.Display:RefreshAuraMaps()
        local liveMap = g and NAU.AuraMapBySpellID(g, g.unit) or nil

        for i, spellID in ipairs(order) do
            if g.spells[spellID] then
                local row = spellRows[i]
                if not row then
                    row = CreateFrame("Frame", nil, holder)
                    row:SetHeight(26)
                    Backdrop(row, C.rowA, nil)

                    row.icon = row:CreateTexture(nil, "ARTWORK")
                    row.icon:SetSize(20, 20)
                    row.icon:SetPoint("LEFT", 4, 0)
                    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

                    row.text = Label(row, "", "GameFontHighlightSmall")
                    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)

                    row.state = Label(row, "", "GameFontDisableSmall", C.faint)
                    row.state:SetPoint("RIGHT", -84, 0)
                    row.state:SetJustifyH("RIGHT")

                    row.up = Button(row, "^", 22, 18, function()
                        local grp, idx = G(), row.index
                        if idx > 1 then
                            grp.spellOrder[idx], grp.spellOrder[idx - 1] =
                                grp.spellOrder[idx - 1], grp.spellOrder[idx]
                            Apply(); NAU.RefreshOptions()
                        end
                    end)
                    row.up:SetPoint("RIGHT", -56, 0)

                    row.down = Button(row, "v", 22, 18, function()
                        local grp, idx = G(), row.index
                        if idx < #grp.spellOrder then
                            grp.spellOrder[idx], grp.spellOrder[idx + 1] =
                                grp.spellOrder[idx + 1], grp.spellOrder[idx]
                            Apply(); NAU.RefreshOptions()
                        end
                    end)
                    row.down:SetPoint("RIGHT", -32, 0)

                    row.remove = Button(row, "x", 22, 18, function()
                        local grp = G()
                        grp.spells[row.spellID] = nil
                        for j, sid in ipairs(grp.spellOrder) do
                            if sid == row.spellID then
                                table.remove(grp.spellOrder, j)
                                break
                            end
                        end
                        Apply(); NAU.RefreshOptions()
                    end)
                    row.remove:SetPoint("RIGHT", -6, 0)

                    spellRows[i] = row
                end

                row.index   = i
                row.spellID = spellID
                row:SetPoint("TOPLEFT", 0, -y)
                row:SetPoint("TOPRIGHT", 0, -y)
                row.bgTex:SetColorTexture(unpack(i % 2 == 0 and C.rowB or C.rowA))

                local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
                row.icon:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")

                -- When the id entered is the ability and the aura is something
                -- else, say so rather than quietly tracking a different number.
                local resolvedID = NAU.ResolvedNote(spellID)
                row.text:SetText(string.format("%s |cff666666%d|r%s",
                    name or "unknown spell", spellID,
                    resolvedID and (" |cff8cd2ff-> aura " .. resolvedID .. "|r") or ""))

                local color, verdict = SpellMark(spellID)
                -- "Is it on the unit right now" beats "could it be read in theory"
                -- when something is not showing, so it wins the label when known.
                if liveMap and NAU.MatchListedSpell(liveMap, spellID) then
                    row.state:SetText("|cff80ff80on " .. g.unit .. " now|r")
                elseif liveMap then
                    row.state:SetText("|cff888888not on " .. g.unit .. "|r  " .. color .. verdict .. "|r")
                else
                    row.state:SetText(color .. verdict .. "|r")
                end

                row.up:SetGrey(i == 1)
                row.down:SetGrey(i == #order)
                row:Show()
                y = y + 27
            end
        end

        for i = #order + 1, #spellRows do spellRows[i]:Hide() end
        holder:SetHeight(math.max(1, y))
        return y
    end

    sink[#sink + 1] = holder
    L:Add(holder, 1)   -- real height comes from Refresh; Layout reads it back below
    p.spellHolder = holder

    L:Gap(10)
    L:Hint("|cff80ff80shown by the game|r - the icon is drawn by Blizzard's aura engine, so it\n" ..
           "keeps working in raids and keys no matter how secret the aura is.\n\n" ..
           "|cffffd479cannot auto-hide|r - it still displays exactly the same. Only\n" ..
           "|cffffd479Hide the group when it is empty|r needs to ask the game about a spell,\n" ..
           "and this one will not answer - so a group holding it stays visible.")
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local tabs = {}

local function SelectTab(key)
    currentKey = key
    if NAU.char then NAU.char.lastTab = key end
    for _, tab in ipairs(tabs) do
        local on = (tab.key == key)
        tab.underline:SetShown(on)
        tab.text:SetTextColor(unpack(on and C.gold or C.faint))
    end
    for k, p in pairs(panels) do
        p.panel:SetShown(k == key)
    end
    NAU.RefreshOptions()
end

local function BuildTabs(parent)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(26)

    local x = 0
    for _, entry in ipairs(TABS) do
        local tab = CreateFrame("Button", nil, strip)
        tab.key = entry.key
        tab:SetHeight(24)

        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tab.text:SetPoint("CENTER", 0, 1)
        tab.text:SetText(entry.label)

        local w = math.max(60, tab.text:GetStringWidth() + 26)
        tab:SetWidth(w)
        tab:SetPoint("LEFT", x, 0)

        tab.underline = tab:CreateTexture(nil, "OVERLAY")
        tab.underline:SetPoint("BOTTOMLEFT", 4, 0)
        tab.underline:SetPoint("BOTTOMRIGHT", -4, 0)
        tab.underline:SetHeight(2)
        tab.underline:SetColorTexture(unpack(C.accent))
        tab.underline:Hide()

        tab:SetScript("OnClick", function() SelectTab(entry.key) end)
        tab:SetScript("OnEnter", function(self)
            if self.key ~= currentKey then self.text:SetTextColor(1, 1, 1) end
        end)
        tab:SetScript("OnLeave", function(self)
            self.text:SetTextColor(unpack(self.key == currentKey and C.gold or C.faint))
        end)

        x = x + w + 2
        tabs[#tabs + 1] = tab
    end

    strip:SetWidth(x)
    return strip
end

local function BuildWindow()
    local f = CreateFrame("Frame", "nugsAurasOptions", UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    Backdrop(f, C.bg, 1)
    tinsert(UISpecialFrames, "nugsAurasOptions")
    window = f

    HeaderBar(f, "nugsAuras", "v" .. NAU.version)

    ---------------------------------------------------------------- group list
    local left = Panel(f, { 0.05, 0.05, 0.05, 0.9 })
    left:SetPoint("TOPLEFT", 10, -38)
    left:SetPoint("BOTTOMLEFT", 10, 78)
    left:SetWidth(LEFT_W)

    local listTitle = Label(left, "Groups", "GameFontNormal", C.accent)
    listTitle:SetPoint("TOPLEFT", 10, -8)

    groupList = ScrollArea(left)
    groupList:SetPoint("TOPLEFT", 6, -30)
    groupList:SetPoint("BOTTOMRIGHT", -6, 6)
    groupList.content:SetWidth(LEFT_W - 15)

    local newBtn = Button(f, "New", 66, 22, function()
        local id = NAU.NewGroup()
        NAU.Display:Rebuild()
        SelectGroup(id)
    end)
    newBtn:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 0, -6)

    local dupBtn = Button(f, "Duplicate", 84, 22, function()
        local g = G()
        if not g then return end
        local seed = NAU.DeepCopy(g)
        seed.name = g.name .. " copy"
        seed.y = (g.y or 0) - 60
        local id = NAU.NewGroup(seed)
        NAU.Display:Rebuild()
        SelectGroup(id)
    end)
    dupBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

    local delBtn = Button(f, "Delete", 72, 22, function()
        if not selectedID then return end
        NAU.DeleteGroup(selectedID)
        selectedID = NAU.db.groupOrder[1]
        NAU.Display:Rebuild()
        SelectGroup(selectedID)
    end)
    delBtn:SetPoint("LEFT", dupBtn, "RIGHT", 4, 0)

    -------------------------------------------------------------- right panels
    tabStrip = BuildTabs(f)
    tabStrip:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, -2)

    -- One panel per tab, each owning its own scroll frame, so switching tabs does
    -- not carry another tab's scroll position with it.
    for _, entry in ipairs(TABS) do
        local panel = Panel(f, { 0.05, 0.05, 0.05, 0.9 })
        panel:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, -30)
        panel:SetPoint("BOTTOMRIGHT", -10, 44)

        local scroll = ScrollArea(panel)
        scroll:SetPoint("TOPLEFT", 10, -10)
        scroll:SetPoint("BOTTOMRIGHT", -10, 10)
        scroll.content:SetWidth(CONTENT_W)

        local p = { panel = panel, scroll = scroll, content = scroll.content, widgets = {} }
        panels[entry.key] = p
        BUILDERS[entry.key](p)
    end

    ---------------------------------------------------------------- bottom bar
    unlockBtn = Button(f, "", 128, 22, function()
        NAU.Display:ToggleLock(not NAU.db.locked)
    end)
    unlockBtn:SetPoint("BOTTOMLEFT", 10, 12)

    local testBtn = Button(f, "Sample icons", 110, 22, function()
        NAU.Display:Test()
        NAU.RefreshOptions()
    end)
    testBtn:SetPoint("LEFT", unlockBtn, "RIGHT", 6, 0)

    local diagBtn = Button(f, "Diagnostics", 100, 22, function()
        NAU.Diagnose()
    end)
    diagBtn:SetPoint("LEFT", testBtn, "RIGHT", 6, 0)

    local hint = Label(f, "|cff8cd2ff/na|r for commands", "GameFontDisableSmall", C.faint)
    hint:SetPoint("BOTTOMRIGHT", -12, 18)
    hint:SetJustifyH("RIGHT")

    -- Every setting on the right acts on the selected group, so with no groups at
    -- all there is nothing for them to act on. The panels are hidden rather than
    -- greyed, because a hidden control cannot be clicked into a nil.
    emptyLabel = Label(f, "No groups yet.\n\nPress |cffffd479New|r to make one.",
                       "GameFontDisableSmall", C.faint)
    emptyLabel:SetPoint("TOPLEFT", left, "TOPRIGHT", 24, -40)
    emptyLabel:SetJustifyH("LEFT")
    emptyLabel:Hide()

    f:SetScript("OnShow", function()
        NAU.Display:SetPreview(true)
        RebuildGroupList()
        NAU.RefreshOptions()
    end)
    f:SetScript("OnHide", function()
        NAU.Display:SetPreview(false)
    end)

    selectedID = (NAU.char and NAU.char.lastGroup and NAU.db.groups[NAU.char.lastGroup])
                 and NAU.char.lastGroup or NAU.db.groupOrder[1]

    SelectTab((NAU.char and NAU.char.lastTab and panels[NAU.char.lastTab])
              and NAU.char.lastTab or "filter")

    -- CreateFrame hands back a *shown* frame, so without this the first /na would
    -- toggle the brand new window straight back off.
    f:Hide()
end

RelayoutAll = function()
    local p = panels[currentKey]
    if not p then return end

    -- The self-sizing blocks are measured after their own refresh rather than being
    -- given a height up front, so the column flows around whatever they turned out
    -- to be.
    -- Not ipairs over a list of the two: either may be nil and ipairs would stop at
    -- the first hole, silently leaving the other block measured at 1px.
    local selfSizing = { p.spellHolder, p.scanHolder }
    for i = 1, 2 do
        local holder = selfSizing[i]
        if holder then
            for _, item in ipairs(p.cols[1].items) do
                if item.region == holder then
                    item.h = holder:GetHeight()
                end
            end
        end
    end

    local h = 0
    for _, col in ipairs(p.cols or {}) do
        h = math.max(h, col:Layout())
    end
    p.content:SetHeight(h + 12)
    p.scroll:UpdateBar()
end

function NAU.RefreshOptions()
    if not window or not NAU.db then return end

    -- The selection can go stale when a group is deleted from the slash command.
    if selectedID and not NAU.db.groups[selectedID] then
        selectedID = NAU.db.groupOrder[1]
    end
    if not selectedID then
        selectedID = NAU.db.groupOrder[1]
    end

    local hasGroup = G() ~= nil
    if emptyLabel then emptyLabel:SetShown(not hasGroup) end
    if tabStrip then tabStrip:SetShown(hasGroup) end
    for key, panel in pairs(panels) do
        panel.panel:SetShown(hasGroup and key == currentKey)
    end
    if not hasGroup then
        if unlockBtn then
            unlockBtn:SetLabel(NAU.db.locked and "Unlock to drag" or "Lock in place")
        end
        return
    end

    local p = panels[currentKey]
    if p then
        for _, w in ipairs(p.widgets) do
            if w.Refresh then w.Refresh() end
        end
    end
    if unlockBtn then
        unlockBtn:SetLabel(NAU.db.locked and "Unlock to drag" or "Lock in place")
    end
    RelayoutAll()
end

--------------------------------------------------------------------------------
-- Move bar
--
-- Placing things means dragging boxes that the settings window is usually sitting on
-- top of, so the window had to be shoved aside first and dragged back after. The
-- window gets out of the way on its own now: unlocking hides it and puts up a small
-- bar instead, and locking brings it back exactly where it was.
--
-- It is deliberately not a saved position. It moves if it is in the way, and starts
-- near the top of the screen next time; persisting it would mean a new saved
-- variable, and a setting nobody would ever go looking for.
--------------------------------------------------------------------------------
local moveBar

local function BuildMoveBar()
    local f = CreateFrame("Frame", "nugsAurasMoveBar", UIParent)
    f:SetSize(246, 78)
    f:SetPoint("TOP", UIParent, "TOP", 0, -60)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    Backdrop(f, C.bg, 1)

    -- Storm-blue edge, so a floating bar reads as sitting on top of the world rather
    -- than being part of it. nugsCooldownPulse gets the same from its PopupChrome
    -- helper; this file has no such helper, so it is drawn here.
    for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                         { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
        local edge = f:CreateTexture(nil, "OVERLAY")
        edge:SetPoint(p[1]); edge:SetPoint(p[2])
        if p[3] == "h" then edge:SetHeight(1) else edge:SetWidth(1) end
        edge:SetColorTexture(0.35, 0.72, 1.00, 0.55)
    end

    local title = Label(f, "Placing your groups", "GameFontNormal", C.accent)
    title:SetPoint("TOPLEFT", 10, -9)

    local hint = Label(f, "Drag each blue box to where you want it.", "GameFontDisableSmall", C.faint)
    hint:SetPoint("TOPLEFT", 10, -28)

    -- Lock is the way out of this state, so it is first and it is the wide one.
    local lockBtn = Button(f, "Lock groups", 110, 22, function()
        NAU.Display:ToggleLock(true)
    end)
    lockBtn:SetPoint("BOTTOMLEFT", 10, 10)

    local extra0 = Button(f, "Sample icons", 100, 22, function()
        NAU.Display:Test()
    end)
    extra0:SetPoint("LEFT", lockBtn, "RIGHT", 6, 0)

    -- Escape locks rather than just dismissing the bar. Hiding it while things were
    -- still unlocked would leave the state with nothing on screen to end it.
    f:EnableKeyboard(true)
    SafePropagate(f, true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and not InCombatLockdown() then
            SafePropagate(self, false)
            NAU.Display:ToggleLock(true)
        else
            SafePropagate(self, true)
        end
    end)

    return f
end

-- Whether the settings window was open when things were unlocked, so locking can put
-- it back only if it was there to begin with. Unlocking from the slash command with
-- nothing open should not conjure a window on lock.
local windowWasOpen = false

function NAU.OnLockChanged(locked)
    if not locked then
        if window and window:IsShown() then
            windowWasOpen = true
            window:Hide()
        end
        moveBar = moveBar or BuildMoveBar()
        SafePropagate(moveBar, true)
        moveBar:Show()
    else
        if moveBar then moveBar:Hide() end
        if windowWasOpen then
            windowWasOpen = false
            if window then window:Show() end
        end
    end
end

-- Builds the window once and hooks it once. Hooked here rather than inside
-- BuildWindow because moveBar is declared in this block: a closure written above its
-- declaration would bind to a nil global instead, silently, until somebody clicked.
--
-- The two hooks keep the pair consistent whichever one the player acts on. Opening
-- settings while unlocked should not leave two lock buttons on screen, and closing
-- settings while unlocked should put the bar back rather than leaving the state with
-- no way out of it.
local function EnsureWindow()
    if window then return end
    BuildWindow()
    window:HookScript("OnShow", function()
        if moveBar then moveBar:Hide() end
    end)
    window:HookScript("OnHide", function()
        if not NAU.db.locked then NAU.OnLockChanged(false) end
    end)
end

--------------------------------------------------------------------------------
-- Combat
--
-- The settings window closes and the anchor locks the moment a fight starts.
--
-- Not because anything here would be blocked: none of these windows touch a secure
-- frame, so nothing throws "action blocked" the way an addon driving action bars
-- does. The reason is that both states put FAKE data on screen - every group fills with sample icons while the window is open, which its own diagnostic calls out - and
-- sample data during a real pull is worse than none, because it cannot be told apart
-- from the real thing.
--
-- Nothing reopens when combat drops. A window appearing by itself while you are
-- looting is worse than pressing a button.
--------------------------------------------------------------------------------
local combatWatch = CreateFrame("Frame")
combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatch:SetScript("OnEvent", function()
    if NAU.db and not NAU.db.locked then
        -- SetLocked and OnLockChanged directly rather than ToggleLock: ToggleLock
        -- prints, and a line of chat on every pull is noise.
        --
        -- Clearing windowWasOpen FIRST is the part that matters. OnLockChanged puts
        -- the settings window back when it was open before the unlock, and doing that
        -- as a fight starts is precisely the wrong moment - it would read as a window
        -- popping open on every pull.
        windowWasOpen = false
        NAU.Display:SetLocked(true)
        NAU.OnLockChanged(true)
        if NAU.RefreshOptions then NAU.RefreshOptions() end
    end
    if window and window:IsShown() then window:Hide() end
end)

function NAU.ToggleOptions()
    EnsureWindow()
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

--------------------------------------------------------------------------------
-- A stub in the Blizzard settings list so the addon is findable there; the real
-- controls live in our own window, which stays movable.
--------------------------------------------------------------------------------

function NAU.InitOptions()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local panel = CreateFrame("Frame")
    panel.name = "nugsAuras"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("nugsAuras")

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    note:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Free-floating buff and debuff groups you place wherever you want them." ..
        "\n\nAll settings live in the nugsAuras window - open it with the button below or with |cffffd479/na|r.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(220, 24)
    open:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -16)
    open:SetText("Open nugsAuras options")
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        EnsureWindow()
        window:Show()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "nugsAuras")
    category.ID = "nugsAuras"
    Settings.RegisterAddOnCategory(category)
end
