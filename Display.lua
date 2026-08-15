--------------------------------------------------------------------------------
-- nugsAuras
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsAuras  -  Display.lua
-- Turns a group's filter into icons on the screen.
--
-- 12.1 changed the premise this file was built on. The old shape relied on an
-- aura's *existence* being readable even though its *identity* was secret: count
-- the instance ids, lay out that many icons, pour secret values straight into
-- widgets. That is over. On 12.1 every aura read is refused in combat - the by-id
-- lookups return nil and the enumerating ones throw - because an addon is tainted
-- by definition. Measured on the PTR, in the open world, not inferred.
--
-- So the addon stopped reading auras. It now builds an AuraContainer, hands the
-- engine a filter and a set of allowed spell ids, and supplies the widgets that
-- Blizzard pushes data into. The aura never enters Lua at all, which is why
-- secrecy stops applying: the same principle as letting a StatusBar do arithmetic
-- the addon is not permitted to do, applied to an entire display.
--
-- What that buys, concretely: the icons keep updating through a pull. What it
-- costs: the addon can no longer know which spell is in a given button, so
-- anything keyed on identity has to be said up front as a filter instead of
-- decided afterwards from a read.
--
-- The spell-search code further down survives untouched, because a settings window
-- is open out of combat by definition and every one of those calls still answers.
--------------------------------------------------------------------------------

local ADDON_NAME, NAU = ...

local Display = {}
NAU.Display = Display

local Plain = NAU.Plain

-- Live frames, keyed by group id. Never rebuilt wholesale while the group still
-- exists: the buttons are pooled and reused so a running cooldown swipe is not
-- restarted every time a setting changes.
local frames = {}

local anchorsShown = false     -- unlocked, so every group shows its grab handle
local testing      = false     -- /na test
local previewing   = false     -- the options window is open

--------------------------------------------------------------------------------
-- Capability probe
--
-- These are still reported by /na diag and still used by the options window, which
-- runs out of combat where they all answer. They no longer drive the display.
--------------------------------------------------------------------------------

local UA = C_UnitAuras or {}

local HAS = {
    unitAuras   = UA.GetUnitAuras                  ~= nil,
    byInstance  = UA.GetAuraDataByAuraInstanceID   ~= nil,
    bySpellID   = UA.GetUnitAuraBySpellID          ~= nil,
}
NAU.HAS = HAS

-- The engine is now a requirement rather than an upgrade, so a client without it
-- has to be detected once and said out loud. Failing quietly here would produce an
-- addon that loads, opens its settings, saves groups and draws nothing - which
-- reads as "my auras are not up yet" rather than as "this needs 12.1", and that is
-- the single most expensive kind of bug this project keeps rediscovering.
Display.hasEngine = false
do
    local ok, f = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if ok and f and f.AddAuraGroup and f.AddAuraSlot then
        Display.hasEngine = true
        f:Hide()
    end
end
Display.engine = Display.hasEngine and "AuraContainer" or "unavailable"

--------------------------------------------------------------------------------
-- Layout
--
-- Plain arithmetic on plain numbers. The index of an icon within the group comes
-- from the position in the instance-id array, which is not secret, so none of this
-- touches anything it is not allowed to.
--------------------------------------------------------------------------------

local GROWTH = {
    RIGHT = { anchor = "TOPLEFT",    dx =  1, dy = -1, horizontal = true  },
    LEFT  = { anchor = "TOPRIGHT",   dx = -1, dy = -1, horizontal = true  },
    DOWN  = { anchor = "TOPLEFT",    dx =  1, dy = -1, horizontal = false },
    UP    = { anchor = "BOTTOMLEFT", dx =  1, dy =  1, horizontal = false },
}

-- `anchorTo` is passed in rather than discovered. Calling button:GetParent() on an
-- engine-owned button raises "Attempt to access forbidden object from code tainted by
-- an AddOn" - the parent is a restricted object and asking for it is the violation,
-- regardless of what we would do with it. Anchoring an engine button IS permitted;
-- interrogating it is not.
--
-- Passing the frame we already own avoids the question entirely, and it is a frame
-- this file created, so nothing about it is restricted.
local function PlaceButton(g, button, index, anchorTo)
    local dir  = GROWTH[g.growth] or GROWTH.RIGHT
    local step = g.size + g.spacing
    local per  = math.max(1, g.perRow)

    local major = (index - 1) % per          -- along the growth direction
    local minor = math.floor((index - 1) / per)  -- the wrapped line

    local offX, offY
    if dir.horizontal then
        offX = major * step * dir.dx
        offY = minor * step * dir.dy
    else
        offX = minor * step * dir.dx
        offY = major * step * dir.dy
    end

    -- Guarded, because moving an engine button is not always permitted.
    --
    -- Positioning one works when it is created and is refused later - "Attempt to
    -- access forbidden object" on ClearAllPoints - so calling this on every update
    -- threw once per slot per pass. 863 errors in one sitting.
    --
    -- Slots are therefore placed ONCE, at creation, and everything that would change
    -- a position - icon size, spacing, growth, per-row - is part of the look
    -- signature, which rebuilds the container and its slots anyway. A pcall on top,
    -- because "sometimes permitted" is not a thing to leave unguarded.
    local ok = pcall(button.ClearAllPoints, button)
    if not ok then return end
    pcall(button.SetPoint, button, dir.anchor, anchorTo, dir.anchor, offX, offY)
    pcall(button.SetSize, button, g.size, g.size)
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------

local function CreateButton(parent, index)
    local b = CreateFrame("Frame", nil, parent)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()

    -- The swipe is a real Cooldown frame rather than anything hand-drawn, because
    -- SetCooldownFromDurationObject is the only way a secret duration can drive an
    -- animation. The widget does the arithmetic the addon is not allowed to do.
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    b.cd:SetDrawEdge(false)
    b.cd:SetDrawBling(false)
    b.cd:SetHideCountdownNumbers(true)

    b.border = b:CreateTexture(nil, "BACKGROUND")

    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.count:SetPoint("BOTTOMRIGHT", 2, -1)

    b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.timer:SetPoint("TOP", b, "BOTTOM", 0, -1)

    return b
end

-- SAMPLE buttons only - the plain frames this addon creates for /na test. Engine
-- buttons are styled once inside BuildRegions, before their regions are handed over,
-- and must never be touched again.
local function StyleButton(g, b)
    if g.zoomIcon then
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    else
        b.icon:SetTexCoord(0, 1, 0, 1)
    end

    b.cd:SetShown(g.showSwipe)

    if g.showBorder then
        local s = g.borderSize
        b.border:ClearAllPoints()
        b.border:SetPoint("TOPLEFT", -s, s)
        b.border:SetPoint("BOTTOMRIGHT", s, -s)
        local c = g.borderColor
        b.border:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        b.border:Show()
    else
        b.border:Hide()
    end

    NAU.ApplyFont(b.count, g)
    NAU.ApplyFont(b.timer, g)
    b.count:SetTextColor(unpack(g.stackColor))
    b.timer:SetTextColor(unpack(g.timerColor))
    b.count:SetShown(g.showStacks)
    b.timer:SetShown(g.showTimer)
end

--------------------------------------------------------------------------------
-- Timer text
--
-- Binding a duration object into a FontString by hand is gone: the engine button's
-- SetDurationText does it, and does it for auras this addon is not allowed to read.
-- Only the teardown survives, for the sample icons - those are drawn on plain
-- frames of our own and still need their text cleared between passes.
--------------------------------------------------------------------------------

local function UnbindTimer(b)
    if b.binding then pcall(b.binding.Disable, b.binding) end
    b.timer:SetText("")
end

--------------------------------------------------------------------------------
-- The spell database, for the options window only
--
-- Everything from here to the end of this section exists to let somebody BUILD a
-- group: search for a spell, see what it is called, and be told whether the client
-- will admit it exists. None of it draws anything, and none of it runs in combat.
--
-- That distinction is new in 12.1 and it is the reason this code survived the
-- rewrite. Reading auras to display them is dead - the engine does that now. But
-- reading them to populate a settings window is fine, because a settings window is
-- open out of combat by definition, and out of combat every one of these calls
-- still answers normally.
--
-- The inverted lookup below is still the trick that makes the picker work: asking
-- "which spell is this aura" is forbidden, but asking "does this unit have spell
-- 774 on it" takes a plain id from the addon and answers directly. It is used here
-- to show the player what is currently on them so they can add it to a list.
--
-- The catch worth keeping in mind: the lookup only answers for spells Blizzard has
-- declassified, and for anything else it returns nil - indistinguishable from "the
-- aura is not there". So the options window reports readability per spell rather
-- than pretending a nil means absent.
--------------------------------------------------------------------------------

-- Answers whether a specific spell can be read as an aura right now. Plain, and
-- safe to branch on. Used to decide whether the spell path is worth running and,
-- in the options window, to mark each listed spell as readable or not.
function NAU.SpellIsReadable(spellID)
    if not (C_Secrets and C_Secrets.ShouldSpellAuraBeSecret) then
        -- No secret system at all (Classic, or a build before 12.0): everything reads.
        return true
    end
    local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, spellID)
    if not ok then return nil end
    return not secret
end

-- Static, context-free secrecy for a spell, so the options window can say "this
-- one never works" rather than "this one is not working at the moment".
function NAU.SpellSecrecy(spellID)
    if not (C_Secrets and C_Secrets.GetSpellAuraSecrecy and Enum and Enum.SecrecyLevel) then
        return nil
    end
    local ok, level = pcall(C_Secrets.GetSpellAuraSecrecy, spellID)
    if not ok then return nil end
    if level == Enum.SecrecyLevel.NeverSecret then return "always" end
    if level == Enum.SecrecyLevel.AlwaysSecret then return "never" end
    return "sometimes"
end

--------------------------------------------------------------------------------
-- Finding a spell id
--
-- Out of combat nothing is secret, so the auras actually on a unit can be read in
-- full - name, id and all. That is the only reliable way to learn the id of a
-- debuff you care about: the id in a tooltip addon or on a website is often the
-- *cast* spell rather than the aura it applies, and those differ more often than
-- people expect.
--
-- So the workflow is: put the aura on something out of combat, scan, and add it
-- from the list. No typing, and no chance of adding an id that was never going to
-- match anything.
--------------------------------------------------------------------------------

-- Returns an array of { spellID, name, icon, harmful, mine }, plus a count of the
-- auras that were present but unreadable. A non-zero skip count is the whole
-- explanation for a short list, so it is reported rather than swallowed.
function NAU.ScanAuras(unit)
    if not UnitName(unit) then
        return nil, 0, "there is no " .. unit
    end

    local out, seen, skipped = {}, {}, 0

    -- api121-ok: this is the options window's "what is on me right now" scanner. It
    -- is driven by a button in a settings panel, which cannot be open in combat, so
    -- the read below always answers. Nothing here draws a live display.
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        local auras
        if HAS.unitAuras then
            local ok, result = pcall(UA.GetUnitAuras, unit, filter, 60)
            if ok then auras = result end
        end

        if NAU.Walkable(auras) then
            for _, aura in ipairs(auras) do
                -- Plain() rather than a direct read: in combat every one of these
                -- is secret, and the count of what we could not read is the honest
                -- thing to show.
                local spellID = Plain(aura.spellId)
                if spellID == nil then
                    skipped = skipped + 1
                elseif not seen[spellID] then
                    seen[spellID] = true
                    -- The name is resolved from the plain id rather than taken off
                    -- the aura, so it is a plain string we may compare and sort.
                    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
                    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
                    out[#out + 1] = {
                        spellID = spellID,
                        name    = name or ("spell " .. spellID),
                        icon    = info and info.iconID or nil,
                        harmful = (filter == "HARMFUL"),
                        mine    = aura.isFromPlayerOrPlayerPet,
                        -- Plain right now, because nothing is secret while this
                        -- runs. Recorded so a cast-driven estimate later has a real
                        -- length to count down instead of a guess.
                        duration = Plain(aura.duration),
                    }
                end
            end
        end
    end

    -- Yours first, then by name: the debuff you are hunting is nearly always one
    -- you applied, and everything here is plain, so sorting is allowed.
    table.sort(out, function(a, b)
        if (a.mine and true) ~= (b.mine and true) then return a.mine and true or false end
        return a.name < b.name
    end)

    return out, skipped
end

--------------------------------------------------------------------------------
-- Browsing for a spell id without needing the aura to be up
--
-- Scanning a live unit has a hole in it that cannot be closed: a debuff you want
-- to track exists in combat, and auras can only be read out of combat. Wait for
-- the aura and you cannot read it; wait until you can read it and it has fallen
-- off. Anything built on reading auras inherits that hole.
--
-- So these three sources do not read auras at all. They read *spell* data, which
-- is configuration rather than combat state and is never secret - so they work in
-- combat, out of combat, and whether or not the aura is anywhere near you.
--------------------------------------------------------------------------------

-- Forward-declared: the tracked-spell cache is defined further down with the rest
-- of the Cooldown Manager code, but the browser needs it here. Without these two
-- lines the functions below would close over globals of the same name and silently
-- read nil.
local trackedSpells, BuildTrackedSet

-- Every spell you know. The overriding id is preferred where there is one, because
-- a talent-overridden spell applies its override's aura, and the base id would
-- match nothing.
function NAU.SpellbookSpells()
    local out = {}
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return out end

    local banks = { Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0 }

    for _, bank in ipairs(banks) do
        local okLines, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        if okLines and numLines then
            for line = 1, numLines do
                local okInfo, lineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
                if okInfo and lineInfo then
                    local first = (lineInfo.itemIndexOffset or 0) + 1
                    local last  = (lineInfo.itemIndexOffset or 0) + (lineInfo.numSpellBookItems or 0)
                    for slot = first, last do
                        local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
                        if ok and info and info.spellID and not info.isPassive
                           and not info.isOffSpec then
                            out[#out + 1] = {
                                spellID = info.spellID,
                                name    = info.name,
                                icon    = info.iconID,
                                source  = "spellbook",
                            }
                        end
                    end
                end
            end
        end
    end
    return out
end

-- What the Cooldown Manager tracks for this spec, resolved to names. These are the
-- best candidates by a distance: they are exactly the spells with auras worth
-- following, and they are the ones the bridge can track in combat.
function NAU.TrackedSpells()
    local out = {}
    if trackedSpells == nil then trackedSpells = BuildTrackedSet() or false end
    if not trackedSpells then return out end

    for spellID in pairs(trackedSpells) do
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
        if name then
            out[#out + 1] = {
                spellID = spellID,
                name    = name,
                icon    = info and info.iconID or nil,
                source  = "tracked",
            }
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- The seen catalog
--
-- Recorded automatically whenever auras happen to be readable, rather than only
-- when you remember to press Scan. That matters for exactly the case scanning
-- cannot reach: your dots are still ticking for a few seconds after combat drops,
-- and the recorder catches them in that window without you having to time it.
--
-- Per character, because the spells worth tracking follow the class.
--------------------------------------------------------------------------------

local lastRecord = 0
local RECORD_INTERVAL = 2

local function RecordSeenAuras()
    if not (NAU.char and NAU.char.catalog) then return end
    if NAU.AurasAreSecret() then return end

    local now = GetTime()
    if now - lastRecord < RECORD_INTERVAL then return end
    lastRecord = now

    local catalog = NAU.char.catalog
    for _, unit in ipairs({ "target", "player", "focus" }) do
        if UnitName(unit) then
            local found = NAU.ScanAuras(unit)
            if found then
                for _, a in ipairs(found) do
                    local entry = catalog[a.spellID]
                    local known = entry ~= nil
                    if not entry then
                        entry = {}
                        catalog[a.spellID] = entry
                    end
                    -- Refreshed rather than left alone: a spell can be renamed or
                    -- re-iconed between patches, and a stale catalog entry is worse
                    -- than none because it looks authoritative.
                    entry.name    = a.name
                    entry.icon    = a.icon
                    entry.harmful = a.harmful
                    -- Only overwrite with a real length. A zero duration means the
                    -- aura is permanent *or* that we caught it mid-refresh, and
                    -- either way it would ruin a learned countdown.
                    if a.duration and a.duration > 0 then
                        entry.duration = a.duration
                    end
                    if not known then
                        -- Something new was learned, so a cast id that could not be
                        -- resolved before may resolve now.
                        NAU.ClearResolveCache()
                    end
                end
            end
        end
    end
end
NAU.RecordSeenAuras = RecordSeenAuras

--------------------------------------------------------------------------------
-- Cast id to aura id
--
-- The single most common way a spell list ends up empty: the id people have is the
-- one for the *ability*, because that is what the spellbook, the Cooldown Manager
-- and every website hand you - and the aura it applies carries a different one.
-- 343527 casts Execution Sentence; the debuff sitting on the target is not 343527.
--
-- Rather than making that the player's problem, the catalog is searched for an
-- aura with the same name. Names are readable whenever auras are, so any aura this
-- character has ever had recorded can be matched back to the ability that applies
-- it, and the id the player pasted in starts working on its own.
--------------------------------------------------------------------------------

local resolveCache = {}

function NAU.ResolveAuraID(spellID)
    local cached = resolveCache[spellID]
    if cached ~= nil then return cached end

    local resolved = spellID
    local catalog = NAU.char and NAU.char.catalog

    -- A learned pairing beats every guess below: it was observed, not inferred.
    local links = NAU.char and NAU.char.castToAura
    if links and links[spellID] then
        resolveCache[spellID] = links[spellID]
        return links[spellID]
    end

    if catalog then
        -- Already an aura we have seen: nothing to resolve.
        if catalog[spellID] then
            resolved = spellID
        else
            local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
            if name then
                for auraID, entry in pairs(catalog) do
                    if entry.name == name then
                        resolved = auraID
                        break
                    end
                end
            end
        end
    end

    resolveCache[spellID] = resolved
    return resolved
end

-- The catalog grows as auras are seen, so a resolution that failed a minute ago
-- may succeed now. Cleared whenever something new is recorded.
function NAU.ClearResolveCache()
    wipe(resolveCache)
end

-- What a listed id will actually be looked up as, for the options window to show.
-- Returns nil when it resolves to itself, so the UI only speaks up when there is
-- something surprising to say.
function NAU.ResolvedNote(spellID)
    local resolved = NAU.ResolveAuraID(spellID)
    if resolved == spellID then return nil end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(resolved)
    return resolved, name
end

function NAU.SeenSpells()
    local out = {}
    if not (NAU.char and NAU.char.catalog) then return out end
    for spellID, entry in pairs(NAU.char.catalog) do
        out[#out + 1] = {
            spellID = spellID,
            name    = entry.name or ("spell " .. spellID),
            icon    = entry.icon,
            harmful = entry.harmful,
            source  = "seen",
        }
    end
    return out
end

-- One search across all three, deduplicated, best source first. `query` may be a
-- name fragment or a bare spell id.
-- Every id that shares a name with this one, including it.
--
-- This exists because the engine matches candidate filters on the aura's OWN spell
-- id, and most abilities carry at least two: the one you cast and the one the aura
-- it applies is registered under. A tooltip generally shows the first. Adding a
-- spell by the number on its tooltip therefore had a real chance of matching nothing
-- at all, with no way to tell that apart from "the aura is not up".
--
-- The old read-based version dodged this by matching on NAME when it looked an aura
-- up. That option is gone: the engine is handed numbers and does the matching
-- itself. So the resolution moves to where the filter is built - hand it every id
-- that spell could plausibly be, and whichever one the aura actually carries will
-- match.
--
-- The cost is a name shared by two unrelated spells matching both. That is rare, and
-- far better than the failure it replaces, which was silent.
local relatedCache = {}

function NAU.ClearRelatedCache()
    wipe(relatedCache)
end

function NAU.RelatedSpellIDs(spellID)
    spellID = tonumber(spellID)
    if not spellID then return nil end
    if relatedCache[spellID] then return relatedCache[spellID] end

    local set = { [spellID] = true }
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if name then
        local wanted = name:lower()
        for _, list in ipairs({ NAU.TrackedSpells(), NAU.SeenSpells(), NAU.SpellbookSpells() }) do
            for _, entry in ipairs(list) do
                if entry.name and entry.name:lower() == wanted then
                    set[entry.spellID] = true
                end
            end
        end
    end

    relatedCache[spellID] = set
    return set
end

-- Merges the expansions of a whole list into one set, which is the shape both
-- includeSpellIDs and excludeSpellIDs want.
function NAU.ExpandSpellIDs(ids)
    local set = {}
    for i = 1, #ids do
        for id in pairs(NAU.RelatedSpellIDs(ids[i]) or { [ids[i]] = true }) do
            set[id] = true
        end
    end
    return set
end

function NAU.SearchSpells(query, limit)
    query = (query or ""):lower()
    local asID = tonumber(query)

    local out, seen = {}, {}
    local function consider(list)
        for _, entry in ipairs(list) do
            if not seen[entry.spellID] then
                local match
                if asID then
                    match = (entry.spellID == asID)
                elseif query == "" then
                    match = true
                else
                    match = entry.name and entry.name:lower():find(query, 1, true) ~= nil
                end
                if match then
                    seen[entry.spellID] = true
                    out[#out + 1] = entry
                end
            end
        end
    end

    -- Tracked first: those are the ones that will still work once the pull starts.
    consider(NAU.TrackedSpells())
    consider(NAU.SeenSpells())
    consider(NAU.SpellbookSpells())

    -- Collapsed by NAME, because picking between two ids with the same name is a
    -- choice with no consequence: adding either one expands to all of them when the
    -- filter is built, so both would behave identically. Listing them separately
    -- asked the player to decide something that does not matter, and implied getting
    -- it wrong was possible.
    --
    -- Skipped when searching by id, where the exact number IS the question.
    if not asID then
        local byName, collapsed = {}, {}
        for _, entry in ipairs(out) do
            local key = entry.name and entry.name:lower()
            if not key then
                collapsed[#collapsed + 1] = entry
            elseif byName[key] then
                byName[key].idCount = (byName[key].idCount or 1) + 1
            else
                entry.idCount = 1
                byName[key] = entry
                collapsed[#collapsed + 1] = entry
            end
        end
        out = collapsed
    end

    -- A bare id that matched nothing known is still worth offering - it may be a
    -- boss debuff this character has never had on it.
    if asID and #out == 0 then
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(asID)
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(asID)
        if name then
            out[#out + 1] = { spellID = asID, name = name,
                              icon = info and info.iconID or nil, source = "id" }
        end
    end

    if limit and #out > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = out[i] end
        return trimmed, #out - limit
    end
    return out, 0
end

-- Whether Blizzard's Cooldown Manager is tracking this spell for the current spec.
-- That matters because a CDM-tracked spell can be followed in combat even when its
-- own aura lookup is secret - see the bridge above.
--
-- Built once into a set and cached, because the options window asks this per row
-- per refresh and the honest answer costs four category queries plus a lookup per
-- cooldown. Doing that on every slider tick was measurably the slowest thing in
-- the addon. Invalidated on the events that can change what the manager tracks.
trackedSpells = nil

BuildTrackedSet = function()
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end
    if not (Enum and Enum.CooldownViewerCategory) then return nil end

    local set = {}
    for _, category in pairs(Enum.CooldownViewerCategory) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, false)
        if ok and type(ids) == "table" then
            for _, cooldownID in ipairs(ids) do
                local okInfo, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                if okInfo and info and info.spellID then
                    set[info.spellID] = true
                    -- A talent can override the spell that is actually cast, and
                    -- the aura then carries the override's id rather than the base.
                    if info.overrideSpellID then set[info.overrideSpellID] = true end
                    if type(info.linkedSpellIDs) == "table" then
                        for _, linked in ipairs(info.linkedSpellIDs) do
                            set[linked] = true
                        end
                    end
                end
            end
        end
    end
    return set
end

function NAU.CooldownManagerTracks(spellID)
    if trackedSpells == nil then
        trackedSpells = BuildTrackedSet() or false
    end
    if trackedSpells == false then return nil end
    return trackedSpells[spellID] and true or false
end

function NAU.InvalidateTrackedSet()
    trackedSpells = nil
    -- The name expansion is built from the tracked and spellbook lists, so it goes
    -- stale for exactly the same reasons - a spec change can rename or replace the
    -- spell an id belongs to.
    if NAU.ClearRelatedCache then NAU.ClearRelatedCache() end
end

--------------------------------------------------------------------------------
-- The Cooldown Manager bridge
--
-- Blizzard's own Cooldown Manager tracks auras for the current spec, and it is not
-- an addon - its code is untainted, so it may read the aura data we may not. What
-- it then leaves lying on its item frames is the useful part:
--
--   frame.cooldownID      plain, it is configuration rather than combat state
--   frame.auraInstanceID  plain, auraInstanceID is NeverSecret
--   frame.auraDataUnit    plain, "player" or "target"
--
-- Resolving cooldownID through GetCooldownViewerCooldownInfo gives a plain spellID.
-- So reading those three fields recovers exactly the spellID-to-aura mapping the
-- secret system withholds, **without calling a single restricted API ourselves**.
--
-- Two hard limits, both worth knowing before relying on it:
--   * it only covers spells the Cooldown Manager tracks for your current spec;
--   * CooldownViewerMixin:OnHide unregisters UNIT_AURA, so a hidden Cooldown
--     Manager stops updating and the bridge goes stale. It has to be switched on
--     and visible, which is why this is a fallback and not the primary path.
--------------------------------------------------------------------------------

local VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

-- Rebuilt once per update pass rather than per group: several groups can be dirty
-- at once and walking four frame pools for each of them would be waste.
local cdmMap, cdmGeneration, generation = nil, -1, 0

local function CooldownManagerMap()
    if cdmGeneration == generation then return cdmMap end
    cdmGeneration = generation
    cdmMap = nil

    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end

    local map
    for _, name in ipairs(VIEWERS) do
        local viewer = _G[name]
        -- A viewer that is hidden has unregistered UNIT_AURA and is no longer being
        -- told about aura changes, so whatever it is still holding is stale. Better
        -- to have no answer than a wrong one.
        if viewer and viewer:IsShown() then
            local frames
            if viewer.GetItemFrames then
                local ok, result = pcall(viewer.GetItemFrames, viewer)
                if ok then frames = result end
            end
            if not frames and viewer.itemFramePool then
                frames = {}
                local ok = pcall(function()
                    for f in viewer.itemFramePool:EnumerateActive() do
                        frames[#frames + 1] = f
                    end
                end)
                if not ok then frames = nil end
            end

            if type(frames) == "table" then
                for _, f in ipairs(frames) do
                    local cooldownID     = f and f.cooldownID
                    local auraInstanceID = f and f.auraInstanceID
                    if cooldownID and auraInstanceID ~= nil then
                        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                        if ok and info and info.spellID then
                            map = map or {}
                            map[info.spellID] = {
                                id   = auraInstanceID,
                                unit = f.auraDataUnit or "player",
                            }
                        end
                    end
                end
            end
        end
    end

    cdmMap = map
    return map
end

-- Returns an ordered array of instance ids for the group's listed spells, or nil
-- if no path could answer for any of them.
--
-- Each spell is tried twice: the direct lookup first, which is exact but only
-- answers for declassified spells, then the Cooldown Manager bridge. A list can
-- easily be half and half, so the choice is made per spell rather than per group.
-- When auras are not secret, reading spellId straight off an enumeration is both
-- allowed and the most reliable match there is: it compares what is *actually on
-- the unit* rather than asking the client about an id we hope is right.
--
-- It exists because GetUnitAuraBySpellID answers about the id you pass in, so an
-- id that is nearly-but-not-quite correct - a cast id where the aura carries a
-- different one - comes back nil and looks exactly like "the aura is not up".
-- This path cannot make that mistake, and comparing what it finds against the
-- list is what lets the options window say so out loud.
local auraMaps, auraMapGeneration = {}, -1

local function AuraMapBySpellID(g, unit)
    if NAU.AurasAreSecret() then return nil end
    if not HAS.unitAuras then return nil end

    if auraMapGeneration ~= generation then
        auraMapGeneration = generation
        wipe(auraMaps)
    end

    -- The explicit list is the filter, so only kind and ownership narrow the pool.
    -- Applying the group's category tokens as well would let a token silently veto
    -- a spell the player asked for by name.
    local filter = (g.kind or "HARMFUL") .. (g.mineOnly and "|PLAYER" or "")
    local cached = auraMaps[unit .. filter]
    if cached ~= nil then return cached or nil end

    -- api121-ok: reached only from the options window, where it answers "is this
    -- listed spell actually on the unit" so a spell row can be ticked. The display
    -- itself no longer calls this - the engine matches spells now.

    local map
    local ok, auras = pcall(UA.GetUnitAuras, unit, filter, 60)
    if ok and NAU.Walkable(auras) then
        map = { byID = {}, byName = {} }
        for _, aura in ipairs(auras) do
            local spellID = Plain(aura.spellId)
            if spellID and aura.auraInstanceID ~= nil then
                map.byID[spellID] = aura.auraInstanceID
                -- Also indexed by name, because the id somebody has for a spell is
                -- as likely to be the ability as the aura, and the two share a name
                -- far more reliably than they share a number.
                local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
                if name then map.byName[name] = aura.auraInstanceID end
            end
        end
    end

    auraMaps[unit .. filter] = map or false
    return map
end

-- One place that answers "is this listed spell on the unit, whichever id it was
-- given as". Everything that needs to match a listed id against a live aura goes
-- through here so the id-versus-name fallback cannot drift between callers.
function NAU.MatchListedSpell(map, listedID)
    if not map then return nil end
    if map.byID[listedID] then return map.byID[listedID] end

    local resolved = NAU.ResolveAuraID(listedID)
    if resolved ~= listedID and map.byID[resolved] then return map.byID[resolved] end

    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(listedID)
    if name and map.byName[name] then return map.byName[name] end

    return nil
end
NAU.AuraMapBySpellID = AuraMapBySpellID

--------------------------------------------------------------------------------
-- Estimates from your own casts
--
-- The last resort, and the only one that needs nothing from anybody. Cast data for
-- *the player* is never secret - the predicate reads "produce secret values if the
-- unit being queried is not the player or their pet" - so UNIT_SPELLCAST_SUCCEEDED
-- tells us, in plain numbers, that you cast spell X at time T. In combat, in a
-- raid, in a key, with the Cooldown Manager switched off.
--
-- Combined with a duration learned out of combat, that is enough to draw the icon
-- and count it down without reading the aura at all.
--
-- It is an estimate and is labelled as one, because dead reckoning cannot know
-- about a dispel, an early death, or the target being swapped. For "is my dot
-- still up on the thing I am hitting" it is right nearly all of the time, and a
-- nearly-always-right icon beats the empty space that is the honest alternative.
--------------------------------------------------------------------------------

local estimates = {}        -- [castSpellID] = { start, duration, target }

-- Forward-declared: Touch schedules the coalesced redraw and lives with the event
-- code at the bottom of the file, but a cast and the estimate ticker both need to
-- ask for one from up here. Without this they would close over a nil global.
local Touch

--------------------------------------------------------------------------------
-- The 12.1 engine
--
-- Everything that used to live here - the cast watching, the duration estimates,
-- the aura maps, the instance-id gathering - existed for one reason: an addon could
-- not read auras in combat. 12.1 solves that properly by never letting the data
-- into Lua at all. Blizzard populates the buttons; we supply the widgets and say
-- which auras are allowed in.
--
-- Two rules govern every line below, and both were learned the hard way:
--
--  1. Never ask an engine button about its state. IsShown() on a bound button
--     returns a SECRET boolean, and a secret boolean cannot even be truth-tested -
--     `if b:IsShown()` is a hard error, not a false. We track what we put there.
--  2. An empty include set is MATCH-ALL, not match-nothing. A group switched off by
--     emptying its filter silently catches every aura on the unit instead. Parking
--     it on an impossible spell id is the only way to say "nothing".
--------------------------------------------------------------------------------

-- Rule 2, in one place. Any slot that should currently show nothing points here.
local DORMANT = { includeSpellIDs = { [599999] = true } }

-- Slots are back, and with them the ordering that is the point of "Only these": one
-- slot per list position, each placed by us, so the row reads in the order you typed
-- rather than in whatever order the engine sorts.
--
-- They were switched off after a slot carrying includeSpellIDs never matched anything
-- across four attempts. That conclusion was wrong. "Always show these" was later built
-- on slots and worked immediately, and the difference between the two was one thing:
-- the broken path passed sortMethod and sortDirection. A slot holds a single aura, so
-- sorting is meaningless, and supplying it stops the slot matching - silently, since
-- the options validate.
local SLOTS_WORK = true

-- Forward-declared: FilterString needs it, and it is defined further down beside the
-- other spell-list helpers. Without this the name would resolve to a global, read as
-- nil, and fail at the call rather than at load - which is the exact trap the
-- fwdref check exists to catch, and did.
local ListedSpells

local SORT_METHODS = {
    default    = "Default",
    expiration = "Expiration",
    expiryonly = "ExpirationOnly",
    name       = "Name",
    unsorted   = "Default",
}

local function SortMethod(g)
    local name = SORT_METHODS[g.sort or "default"] or "Default"
    local e = AuraContainerSortMethod
    return (e and (e[name] or e.Default)) or nil
end

-- Read from Blizzard's own source rather than guessed at:
--     AuraContainerSortDirection = { Normal = 0, Reverse = 1 }
-- SetAuraGroupSortMethod takes the direction as a third argument and THROWS without
-- it - "sortDirection must be a valid AuraContainerSortDirection" - which fired on
-- every update and left the group populated but never laid out.
--
-- The literals are the documented fallback because an enum table missing at load is
-- not worth failing over, and these two values are fixed in the shipped source.
local function SortDirection(g)
    local e = AuraContainerSortDirection
    local normal  = (e and e.Normal)  or 0
    local reverse = (e and e.Reverse) or 1
    return g.sortReverse and reverse or normal
end

-- The engine's filter grammar is NARROWER than the one the old instance-id reads
-- accepted, and that is a trap worth spelling out. A group's category tokens were
-- written against the old grammar: CROWD_CONTROL, BIG_DEFENSIVE, EXTERNAL_DEFENSIVE
-- and friends. Handing an unrecognised token to the engine does not raise anything -
-- the slot simply never matches, and the group sits there empty looking like an
-- addon that does not work.
--
-- So every token is graded by the client and the rejects are dropped rather than
-- guessed at. NAU.rejectedTokens is what /na diag reports, so "that category does
-- nothing on 12.1" is answerable instead of mysterious.
NAU.rejectedTokens = {}
NAU.bindReport = {}
NAU.groupReport = {}

-- Geometry of our own frames, for the case where the engine says it drew something
-- and the screen says otherwise. The container and the group frame are ours, so their
-- size and position are plain and safe to print. A button belongs to the engine, so
-- everything about it is asked for inside a pcall and rendered secret-safe - and its
-- shown state is never asked for at all, because that is a secret boolean and testing
-- one is a hard error.

-- What each slot is actually filtering on, which is the thing that decides whether
-- "Only these" shows anything. Reported rather than reasoned about, because a slot
-- that matches nothing and a slot that was never pointed at a spell look identical
-- on screen - both are empty.
function Display:LastAnyUp(id)
    local f = frames[id]
    return f and f.lastAnyUp or "not evaluated"
end

function NAU.SlotReport(id)
    local f = frames[id]
    if not (f and f.slots) then return nil end
    local out = {}
    for i = 1, #f.slots do
        local spellID = f.slotSpell and f.slotSpell[i]
        if spellID then
            local n = 0
            for _ in pairs(NAU.ExpandSpellIDs({ spellID })) do n = n + 1 end
            local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
            out[#out + 1] = string.format("slot %d -> %s (%d) matching %d id(s)",
                i, name or "?", spellID, n)
        else
            out[#out + 1] = string.format("slot %d -> |cff888888parked|r", i)
        end
    end
    return out
end

function NAU.GeometryReport(id)
    local f = frames[id]
    if not f then return { "no frame" } end
    local out = {}

    local fw, fh = f:GetWidth() or 0, f:GetHeight() or 0
    local p, _, _, px, py = f:GetPoint(1)
    out[#out + 1] = string.format("group frame %dx%d at %s %d,%d shown=%s alpha=%.2f",
        fw, fh, tostring(p), px or 0, py or 0, tostring(f:IsShown()), f:GetAlpha())

    local c = f.container
    if not c then
        out[#out + 1] = "container: NONE"
        return out
    end

    -- Every field asked for separately and inside a pcall. The previous version built
    -- this line in one string.format, so a single unreadable value threw and took the
    -- whole line with it - the container line simply never appeared, which read as
    -- "there is no container" when there is one. An AuraContainer can carry secret
    -- aspects (Shown among them), so any of these may legitimately refuse to answer.
    local function ask(label, fn, ...)
        local ok, v = pcall(fn, ...)
        if not ok then return label .. "=unreadable" end
        if issecretvalue and issecretvalue(v) then return label .. "=secret" end
        return label .. "=" .. tostring(v)
    end
    out[#out + 1] = "container  " .. table.concat({
        ask("w", c.GetWidth, c), ask("h", c.GetHeight, c),
        ask("shown", c.IsShown, c), ask("alpha", c.GetAlpha, c),
        ask("strata", c.GetFrameStrata, c),
    }, " ")

    -- The first engine button, if the engine has handed one over. Anchoring is the
    -- suspect when frames exist and nothing appears, so its point matters most.
    local b = f.firstButton
    if not b then
        out[#out + 1] = "engine buttons: none handed over yet"
    else
        -- The engine's buttons are deliberately NOT questioned. GetSize and GetPoint
        -- on one raise "Attempt to access forbidden object from code tainted by an
        -- AddOn" - the button is a restricted object and asking is itself the
        -- violation. The previous version wrapped both in pcall and reported
        -- "unreadable", which was true, useless, and raised a taint error to say so.
        out[#out + 1] = "engine buttons: " .. tostring(f.initCount or 0)
                        .. " pooled - restricted objects, not measurable"
    end
    -- Returned as a LIST, and printed one line per call by the caller. WoW's print
    -- does not reliably render an embedded newline, so a multi-line string arrives as
    -- one truncated line or not at all - which is why this report appeared to be
    -- missing entirely across three separate diagnostics.
    return out
end

local function Valid(s)
    if not (AuraUtil and AuraUtil.IsValidFilterString) then return true end
    local ok, valid = pcall(AuraUtil.IsValidFilterString, s)
    return ok and valid and true or false
end

local function FilterString(g)
    -- "Only these" means only these. When a spell list is driving the group, the
    -- category tokens are dropped and just the kind and ownership remain.
    --
    -- They combine as AND otherwise, and that is a silent trap: naming Expurgation
    -- and also ticking Crowd control asks for auras that are both, which is nothing
    -- at all. A category could veto a spell the player asked for BY NAME and there
    -- would be no way to see why.
    --
    -- This restores a decision the addon had already made before the rewrite, in the
    -- old spell-list path: "the explicit list is the filter, so only kind and
    -- ownership narrow the pool".
    -- "missing" narrows the same way "only" does, and for the same reason: the
    -- sensors behind it are per-spell, so a category could veto a spell the player
    -- named and that dot would then never register as present - the icon would sit
    -- there claiming it was missing while it ticked away on the target.
    if (g.spellMode == "only" or g.spellMode == "missing") and ListedSpells(g) then
        local parts = { (g.kind == "HARMFUL") and "HARMFUL" or "HELPFUL" }
        if g.mineOnly then parts[#parts + 1] = "PLAYER" end
        local s = table.concat(parts, "|")
        g._filter = s
        return s
    end

    -- NAU.BuildFilter is the single definition of what a group means; this only
    -- strains out the parts 12.1's engine will not accept.
    --
    -- Each candidate is tested by appending it to the string ACTUALLY being built,
    -- which matters more than it looks. A first version graded every token against a
    -- fixed "HELPFUL|" prefix, so a HARMFUL group was asked whether "HELPFUL|HARMFUL"
    -- was valid - it is not, being a contradiction - and HARMFUL was dropped as
    -- unsupported. The group was left filtering on PLAYER alone and showed no
    -- debuffs at all. Tokens are not independent of each other, so they cannot be
    -- graded in isolation.
    local full = NAU.BuildFilter(g)
    -- Recorded so /na diag can show what the engine was ACTUALLY given. Printing only
    -- the intended filter is what let a group quietly run on "PLAYER" while the
    -- diagnostic cheerfully reported "HARMFUL|PLAYER".
    g._filter = full
    if Valid(full) then return full end

    -- The kind is not optional and is never strained out: it is the difference
    -- between buffs and debuffs, not a refinement of either.
    local base = (g.kind == "HARMFUL") and "HARMFUL" or "HELPFUL"
    local out  = base

    for token in full:gmatch("[^|]+") do
        if token ~= base then
            local try = out .. "|" .. token
            if Valid(try) then
                out = try
            else
                NAU.rejectedTokens[token] = true
            end
        end
    end
    g._filter = out
    return out
end

-- The ordered spell list, as plain numbers. This is the one place the addon still
-- names spells - and it may, because a spell id the player typed into the options
-- window is not secret. It never asks whether that aura is present; it hands the
-- list to the engine and lets the engine decide.
-- The listed spell ids, in the player's order. The mode keys are "off", "only" and
-- "exclude" - NOT "list", which is what this tested for and which no group has ever
-- been set to. Every group therefore fell through to the category path and the spell
-- list was never consulted at all.
function ListedSpells(g)
    local order, spells = g.spellOrder, g.spells
    if not (order and spells and #order > 0) then return nil end

    local out = {}
    for i = 1, #order do
        local id = tonumber(order[i])
        if id and spells[id] ~= false then out[#out + 1] = id end
    end
    return (#out > 0) and out or nil
end

-- "Only these" is the mode that gets a slot per spell, because position is what
-- carries the order.
local function OrderedSpells(g)
    if g.spellMode ~= "only" then return nil end
    return ListedSpells(g)
end

--------------------------------------------------------------------------------
-- Containers
--
-- One per group, parented to that group's frame. Buzzard shares a single container
-- per unit - the filter is a per-slot argument, so it can - but a container per
-- group buys something worth more than the saving: hiding the group frame hides its
-- buttons. Engine buttons cannot be hidden by us directly, and we are not allowed
-- to ask whether they are hidden, so owning the parent is how a group turns off.
--------------------------------------------------------------------------------

-- Everything about a button that is decided BEFORE binding. Once bound, none of it
-- can be changed, so a change here means the buttons have to be built again.
local function LookSignature(g)
    local function rgba(t) return t and table.concat(t, ",") or "" end
    return table.concat({
        g.size or 0, g.zoomIcon and 1 or 0,
        g.showSwipe and 1 or 0, g.reverseSwipe and 1 or 0,
        g.showTimer and 1 or 0, g.showStacks and 1 or 0,
        g.showBorder and 1 or 0, g.borderSize or 0, rgba(g.borderColor),
        g.font or "", g.fontSize or 0, g.fontOutline or "",
        rgba(g.stackColor), rgba(g.timerColor),
    }, "|")
end

local function EnsureContainer(id)
    local f = frames[id]
    local g = NAU.db and NAU.db.groups[id]
    if not (f and g) then return nil end

    -- A look change means starting over. The engine takes ownership of a region the
    -- moment it is bound, so an existing button cannot be restyled - the icon cannot
    -- even have its texture coordinates changed. The only way to apply new settings
    -- is a fresh container with freshly built buttons.
    --
    -- The old container is hidden and dropped rather than destroyed, because frames
    -- cannot be destroyed in this API. That leaks one container per look change,
    -- which is acceptable for something that happens when a person edits a setting
    -- and never during play.
    local sig = LookSignature(g)
    if f.container and f.lookSig ~= sig then
        f.container:Hide()
        -- slotPlaced goes with them: the new slots are new frames and have never
        -- been positioned, so carrying the old table over would leave every one of
        -- them unanchored and invisible.
        f.container, f.slots, f.slotKeys, f.slotSpell = nil, nil, nil, nil
        f.slotPlaced = nil
        f.groupBuilt, f.initCount, f.firstButton = nil, 0, nil
    end
    f.lookSig = sig

    if f.container then return f.container end

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
    if not (ok and c) then
        f.engineFailed = true
        return nil
    end

    -- ONE anchor point, never SetAllPoints. The engine sizes the container itself
    -- when its flow layout finishes:
    --     function CustomAuraContainerFlowLayoutMixin:OnLayoutComplete(container, w, h)
    --         container:SetSize(secretwrap(w, h))
    -- and SetSize does nothing to a frame whose four corners are already anchored.
    -- Pinning all four sides to the group frame was therefore a fight with the layout
    -- manager over who owns the container's dimensions - which the addon cannot win,
    -- and which leaves the elements laid out against a container that never took the
    -- size the layout computed for it.
    --
    -- The corner is chosen to match the group's growth direction so it still expands
    -- the way the settings say, while the extent stays Blizzard's to decide.
    local corner = (GROWTH[g.growth] or GROWTH.RIGHT).anchor
    c:ClearAllPoints()
    c:SetPoint(corner, f, corner, 0, 0)

    -- Recorded, not discarded. SetUnit is what points the container at a unit, and it
    -- is not defined anywhere in the shipped CustomAuraContainer Lua - so whether it
    -- exists at all, and under this name, was an assumption. A container watching
    -- nothing produces exactly what is being seen: frames created, bindings fine,
    -- nothing ever shown, because the button shows itself only when an aura is
    -- assigned to it (SetShown(auraData ~= nil)).
    if not c.SetUnit then
        NAU.groupReport.SetUnit = "MISSING - container has no SetUnit method"
    else
        local okU, errU = pcall(c.SetUnit, c, g.unit or "player")
        NAU.groupReport.SetUnit = okU and ("ok (" .. tostring(g.unit or "player") .. ")")
                                       or ("FAILED: " .. tostring(errU))
    end
    f.container = c
    f.slots = {}
    f.slotKeys = {}
    return c
end

-- Regions are ours until they are bound, and the engine's afterwards.
--
-- That order is not a style preference, it is the whole contract. Handing a region to
-- a binding runs it through InitializeInboundScriptObject and adds secret aspects:
--
--     cooldown:AddSecretAspect(Enum.SecretAspect.Shown)
--     fontString:AddSecretAspect(Enum.SecretAspect.Text)
--     fontString:AddSecretAspect(Enum.SecretAspect.Alpha)
--     fontString:AddSecretAspect(Enum.SecretAspect.VertexColor)
--
-- After that, touching one of those aspects - or in the icon's case touching the
-- texture at all - raises "Attempt to access forbidden object from code tainted by an
-- AddOn". Styling used to run on every update, after binding, so it threw once per
-- button per pass.
--
-- So: create, style completely, and only then bind. Nothing styles an engine button
-- afterwards. A settings change is handled by rebuilding the container, because these
-- bindings cannot be taken back.
local function BuildRegions(b, g)
    if b._nugsBuilt then return end
    b._nugsBuilt = true

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()

    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    b.cd:SetDrawEdge(false)
    b.cd:SetDrawBling(false)
    b.cd:SetHideCountdownNumbers(true)

    b.border = b:CreateTexture(nil, "BACKGROUND")

    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.count:SetPoint("BOTTOMRIGHT", 2, -1)

    b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.timer:SetPoint("TOP", b, "BOTTOM", 0, -1)

    -- The bindings themselves. Every one of these replaces a read that 12.1 refuses.
    --
    -- Each result is recorded. A failed bind does not error and does not draw: the
    -- button exists, is sized, is positioned, and is completely transparent - which
    -- on screen is indistinguishable from "no auras matched the filter". Those two
    -- have completely different causes and the addon could not tell them apart, so
    -- the outcome is now reported by /na diag instead of guessed at.
    -- STYLE FIRST, while these are still ours. Everything below this point is the
    -- last chance to touch them.
    if g then
        b.icon:SetTexCoord(g.zoomIcon and 0.07 or 0, g.zoomIcon and 0.93 or 1,
                           g.zoomIcon and 0.07 or 0, g.zoomIcon and 0.93 or 1)

        -- Which way the swipe runs, set BEFORE SetDurationCooldown hands this widget
        -- over. The engine takes the Cooldown and Shown aspects on binding, so this
        -- is the last moment it can be changed - which is why toggling the setting
        -- rebuilds the container rather than adjusting the existing buttons.
        b.cd:SetReverse(g.reverseSwipe and true or false)

        if g.showBorder then
            local s = g.borderSize or 1
            b.border:ClearAllPoints()
            b.border:SetPoint("TOPLEFT", -s, s)
            b.border:SetPoint("BOTTOMRIGHT", s, -s)
            local col = g.borderColor
            b.border:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
            b.border:Show()
        else
            b.border:Hide()
        end

        NAU.ApplyFont(b.count, g)
        NAU.ApplyFont(b.timer, g)
        b.count:SetTextColor(unpack(g.stackColor))
        b.timer:SetTextColor(unpack(g.timerColor))
    end

    -- The bindings themselves. Every one of these replaces a read that 12.1 refuses.
    --
    -- Each result is recorded. A failed bind does not error and does not draw: the
    -- button exists, is sized, is positioned, and is completely transparent - which
    -- on screen is indistinguishable from "no auras matched the filter".
    local function bind(name, fn, region)
        if not fn then NAU.bindReport[name] = "missing"; return end
        local ok, err = pcall(fn, b, region)
        NAU.bindReport[name] = ok and "ok" or ("FAILED: " .. tostring(err))
    end

    -- Only what the group actually wants is bound. Visibility cannot be toggled
    -- afterwards - the engine owns Shown on these once bound - so "off" has to mean
    -- "never handed over" rather than "handed over and hidden".
    bind("SetIcon", b.SetIcon, b.icon)
    if not g or g.showSwipe  then bind("SetDurationCooldown", b.SetDurationCooldown, b.cd)   else b.cd:Hide()    end
    if not g or g.showTimer  then bind("SetDurationText",     b.SetDurationText,     b.timer) else b.timer:Hide() end
    if not g or g.showStacks then bind("SetApplicationCount", b.SetApplicationCount, b.count) else b.count:Hide() end
end

-- One slot per position in the ordered list. Position implies identity, which is how
-- "my spells, in my order" survives without the addon knowing what is in any button.
local function EnsureSlot(id, index, spellID)
    local f = frames[id]
    local g = NAU.db.groups[id]
    local c = EnsureContainer(id)
    if not c then return nil end

    local b = f.slots[index]
    if not b then
        local key = "nau" .. id .. "s" .. index
        -- Created pointing at the real spell, not parked and re-pointed afterwards.
        --
        -- The engine test proves a slot draws when its filters are supplied at
        -- creation. The only thing the real path did differently was start every slot
        -- at DORMANT and then call SetAuraSlotCandidateFilters - so that setter is the
        -- suspect, and its result was being thrown away by a bare pcall, which is how
        -- it stayed invisible.
        local filters = spellID and { includeSpellIDs = NAU.ExpandSpellIDs({ spellID }) }
                                 or DORMANT
        -- NO sortMethod or sortDirection. A slot holds exactly one aura, so sorting
        -- it means nothing - and passing them appears to stop it matching at all.
        -- Validation accepts them, so this failed silently and cost several builds
        -- before "Always show these" turned out to use slots successfully while
        -- differing in precisely this.
        local ok, button = pcall(c.AddAuraSlot, c, key, FilterString(g), {
            candidateFilters = filters,
        })
        if not (ok and button) then
            NAU.groupReport["AddAuraSlot" .. index] = "FAILED: " .. tostring(button)
            return nil
        end
        b = button
        f.slots[index]    = b
        f.slotKeys[index] = key
        BuildRegions(b, g)

        -- The remembered spell is deliberately NOT recorded here, so the next pass
        -- sees a change and re-applies the candidate filters.
        --
        -- A slot created during the first update has nothing to match yet - the
        -- engine has not bound anything to this container - and it does not go back
        -- and reconsider on its own. The symptom was auras never appearing on a fresh
        -- pull and then working perfectly once combat dropped and restarted, because
        -- that round trip forced the pass that should have happened immediately.
        -- Flags the group for one more pass shortly after, so the filters get applied
        -- once the engine has something to bind. Placement is NOT keyed off this -
        -- see slotPlaced in UpdateGroup for why that broke.
        f.newSlot = true
        return b
    end

    -- Re-pointed rather than rebuilt, so changing a spell in the list does not
    -- restart a running swipe on the slots either side of it.
    if f.slotSpell ~= nil and f.slotSpell[index] ~= spellID then
        -- Every id sharing this spell's name, not just the one that was typed in.
        -- The aura may be registered under a different number from the ability, and
        -- the engine matches on the aura's.
        local okF, errF = pcall(c.SetAuraSlotCandidateFilters, c, f.slotKeys[index],
              spellID and { includeSpellIDs = NAU.ExpandSpellIDs({ spellID }) } or DORMANT)
        -- Recorded rather than discarded. If re-pointing a slot does not work, that
        -- has to be visible in /na diag instead of presenting as an empty group.
        NAU.groupReport["SetAuraSlotCandidateFilters"] =
            okF and "ok" or ("FAILED: " .. tostring(errF))
        f.slotSpell[index] = spellID
    end
    return b
end

-- Is any spell on this group's list currently up? This is the ONLY read left in the
-- display path, and it is deliberately the smallest one available.
--
-- It asks about existence, never identity. The returned table is not opened - no
-- icon, no stacks, no duration, no instance id - so nothing secret is ever touched
-- and there is nothing here to compare or use as a key. What comes back is a plain
-- boolean about a spell id we already knew, because the player typed it in.
--
-- api121-ok: 12.1 refuses to ENUMERATE auras in combat; a by-id lookup for one named
-- spell is still served, and returns plain values. Verified on live by watching a
-- Frost Mage's Icicles tracked through this exact call mid-fight.
--
-- Only ordered groups can answer. A category group is defined by a filter rather than
-- by named spells, so there is no list to ask about - which is why hideWhenEmpty is
-- offered for spell lists only rather than silently doing nothing everywhere else.
local function AnyListedSpellUp(g, ids)
    if not (UA.GetUnitAuraBySpellID and ids) then return nil end
    local unit = g.unit or "player"

    -- If the client is withholding aura data, this question cannot be answered at
    -- all, and the honest return is "unknown" rather than "nothing is up".
    --
    -- The distinction matters because a refused read and an absent aura both come
    -- back nil. Returning false for both is the mistake that hid a working group: the
    -- slot was pointed at the right spell, matching the right ids, and the frame was
    -- hidden anyway because this reported "empty" when it meant "not allowed to
    -- look". The comment below the loop already said nil meant unknown - the function
    -- simply had no path that produced one.
    --
    -- It also fails much more readily on another unit than on the player: reading a
    -- named spell off yourself is served in combat, off a target it frequently is
    -- not.
    if NAU.AurasAreSecret and NAU.AurasAreSecret() then return nil end
    -- Asked against every id the spell could be, for the same reason the candidate
    -- filters are: the aura is often registered under a different number from the
    -- ability, and asking about the wrong one returns nil - which here would read as
    -- "nothing is up" and hide a group that has icons in it.
    local answered = false
    for id in pairs(NAU.ExpandSpellIDs(ids)) do
        local ok, aura = pcall(UA.GetUnitAuraBySpellID, unit, id)
        -- A secret table is still safe to truth-test; it is the FIELDS that are
        -- barred, and none are read here.
        if ok then
            answered = true
            if aura then return true end
        end
    end
    -- Only a pass where at least one call actually returned may say "nothing is up".
    -- If every one of them threw, nothing was learned.
    if not answered then return nil end
    return false
end

--------------------------------------------------------------------------------
-- "Only what is missing"
--
-- The inverse of everything else here, and it works without reading a single aura.
--
-- The engine can only draw what EXISTS - there is no binding for an aura that is
-- absent - so the obvious implementation is to ask "is this spell on the unit" and
-- draw when the answer is no. That question is a read, and a read can be refused;
-- on a target during a fight, which is the only time a dot reminder matters, it
-- might always come back empty and light up every icon.
--
-- So nothing asks. Instead:
--
--   1. An engine slot is created per listed spell, filtered to that spell. It is
--      given no regions at all, so it draws nothing - it exists purely so the engine
--      will track that spell's presence for us.
--   2. We draw our own icon for that spell.
--   3. The slot's IsShown() is a SECRET boolean. It cannot be tested, but it can be
--      handed to SetAlphaFromBoolean, which is the display sink for exactly this -
--      and handed over INVERTED: alpha 0 when the aura is present, 1 when it is not.
--
-- Nothing is ever compared, so no restriction applies. The engine decides presence
-- and a widget does the arithmetic, which is the same principle as letting a
-- StatusBar count down a secret duration.
--
-- Measured working before this was built: IsShown on a bound button returns rather
-- than raising a forbidden access, it really is secret, and the sink accepts it.
--------------------------------------------------------------------------------

local function MissingSpells(g)
    if g.spellMode ~= "missing" then return nil end
    return ListedSpells(g)
end

-- Everything this mode puts on screen, taken back down.
--
-- Needed because the icons are plain frames of OURS and the sensors are engine slots,
-- and neither goes away on its own when the mode changes. Switching to another mode
-- left both sitting there until a reload, which reads as the addon ignoring the
-- setting - the same class of bug as a group and its slots both staying live.
local function ParkMissing(id, c)
    local f = frames[id]
    if not f then return end
    for _, icon in pairs(f.missIcons or {}) do icon:Hide() end
    if c and f.missSpell then
        for i in pairs(f.missSpell) do
            pcall(c.SetAuraSlotCandidateFilters, c, "naum" .. id .. "s" .. i, DORMANT)
            f.missSpell[i] = nil
        end
    end
end

-- SetAlphaFromBoolean evaluates ONCE, when called - it is a sink, not a binding. So
-- the alpha only follows the aura if something re-applies it, and the first call
-- happens before the engine has bound anything. Re-applied on UNIT_AURA and shortly
-- after a group is built, which covers both.
-- Every outcome is recorded rather than swallowed. "The icons stay up in combat" has
-- several possible causes that look identical on screen - the read being refused, the
-- sink refusing the value, or this simply never running - and a bare pcall hides
-- which. That mistake has been made enough times in this file already.
NAU.unitStamp = {}
NAU.missReport = { runs = 0, isShownOK = 0, isShownThrew = 0,
                   sinkOK = 0, sinkThrew = 0, lastInCombat = false, lastErr = nil }

-- Nothing to refresh any more: the inversion is done by stacking, and the engine
-- shows and hides its own button. Kept as a no-op counter so /na diag can still say
-- the mode is alive, and so the shape is here if a future build needs it.
-- Nothing to refresh. The inversion is done by stacking and the engine shows and
-- hides its own button, so this only keeps a counter for /na diag.
--
-- It used to drive our icon's alpha from a secret boolean, which made a satisfied
-- spell vanish outright rather than be covered. That is gone, and it is worth
-- recording why so it is not attempted a third time:
--
--   * asking the engine's BUTTON whether it is shown is a forbidden object access
--     in combat - measured, 68 throws to 32
--   * lending the engine a Cooldown of our own and asking THAT is refused the same
--     way - measured, 95 throws to 96. Marking a widget with a secret aspect makes
--     it restricted regardless of who created it
--
-- There is no third source. Our icon cannot be a child of the engine's button
-- either, since that hides it when the aura is ABSENT, which is backwards, and no
-- filter can match "this aura is not here". Occlusion is the only inversion that
-- survives combat, and occlusion has to draw something - hence the covered look
-- being a setting rather than an absence.
local function RefreshMissing(id)
    local f = frames[id]
    if not (f and f.missSlots) then return end
    local R = NAU.missReport
    R.runs = R.runs + 1
    R.lastInCombat = InCombatLockdown() and true or false
end
NAU.RefreshMissing = RefreshMissing

local function EnsureMissing(id, index, spellID)
    local f = frames[id]
    local g = NAU.db.groups[id]
    local c = EnsureContainer(id)
    if not c then return nil end

    f.missSlots = f.missSlots or {}
    f.missIcons = f.missIcons or {}
    f.missSpell = f.missSpell or {}

    if not f.missSlots[index] then
        local key = "naum" .. id .. "s" .. index
        local ok, button = pcall(c.AddAuraSlot, c, key, FilterString(g), {
            candidateFilters = spellID and { includeSpellIDs = NAU.ExpandSpellIDs({ spellID }) }
                                       or DORMANT,
        })
        if not (ok and button) then
            NAU.groupReport["AddAuraSlot(missing)" .. index] = "FAILED: " .. tostring(button)
            return nil
        end
        -- The slot is a real, VISIBLE icon that sits directly on top of our missing
        -- icon and covers it.
        --
        -- The first attempt asked the button whether it was shown and drove our
        -- alpha from the answer. That works out of combat and is forbidden in it -
        -- "Attempt to access forbidden object" - so the icons froze at whatever they
        -- last were, in a fight, which is the only time they matter.
        --
        -- Nothing is asked now. The engine shows its button when the aura is present
        -- and hides it when it is not, entirely on its own; ours is underneath, so
        -- presence covers it and absence reveals it. An opaque backing texture is
        -- what makes that a clean swap rather than two icons bleeding through each
        -- other.
        pcall(button.SetSize, button, g.size or 32, g.size or 32)
        if not button._nugsMissBuilt then
            button._nugsMissBuilt = true

            -- An opaque backing FIRST, so whatever the engine draws on top of it
            -- completely hides the placeholder underneath. Without this the two
            -- icons bleed through each other and the swap reads as a rendering bug.
            local bg = button:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0, 0, 0, 1)
            button._nugsCover = { bg = bg }

            -- Then the ordinary treatment - icon, swipe, timer, stacks - so a spell
            -- that IS applied is tracked exactly like it would be in any other
            -- group. That is the whole shape of this mode: the listed spells always
            -- hold their positions, showing a placeholder until they land and a live
            -- aura once they have.
            BuildRegions(button, g)
        end
        f.missSlots[index] = button
        f.missSpell[index] = spellID
    else
        -- Re-applied EVERY pass, not only when the listed spell changes.
        --
        -- Swapping targets left the engine's icons up as though the dots were still
        -- there. The container is told SetUnit("target") on the change, but it was
        -- already "target" - the token has not changed, only what it points at - so
        -- nothing re-evaluates and the button carries on showing what it matched on
        -- the previous mob.
        --
        -- Re-setting the candidate filters forces that re-evaluation. This only runs
        -- when something has actually happened - an aura event or a target change -
        -- so it is not a poll.
        pcall(c.SetAuraSlotCandidateFilters, c, "naum" .. id .. "s" .. index,
              spellID and { includeSpellIDs = NAU.ExpandSpellIDs({ spellID }) } or DORMANT)
        f.missSpell[index] = spellID
    end

    -- Our icon. Entirely ours - a plain frame parented to the group frame - so every
    -- ordinary setter works on it and none of the engine's restrictions apply.
    local icon = f.missIcons[index]
    if not icon then
        icon = CreateFrame("Frame", nil, f)
        icon.border = icon:CreateTexture(nil, "BACKGROUND")
        icon.tex = icon:CreateTexture(nil, "ARTWORK")
        icon.tex:SetAllPoints()
        f.missIcons[index] = icon
    end
    -- Ours goes UNDERNEATH the engine's, which is the whole mechanism. The container
    -- holds every engine button, so lifting it once puts all of them above every
    -- missing icon; without this the two draw in creation order and the cover is a
    -- coin toss.
    icon:SetFrameLevel(f:GetFrameLevel() + 1)
    pcall(c.SetFrameLevel, c, f:GetFrameLevel() + 10)

    -- The sensor is parked directly over its icon, so presence hides absence.
    local slot = f.missSlots[index]
    if slot then
        pcall(slot.ClearAllPoints, slot)
        pcall(slot.SetPoint, slot, "TOPLEFT", icon, "TOPLEFT", 0, 0)
        pcall(slot.SetSize, slot, g.size or 32, g.size or 32)
    end

    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    icon.tex:SetTexture(info and info.iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon.tex:SetTexCoord(g.zoomIcon and 0.07 or 0, g.zoomIcon and 0.93 or 1,
                         g.zoomIcon and 0.07 or 0, g.zoomIcon and 0.93 or 1)
    icon.tex:SetDesaturated(g.missingDesat and true or false)
    local t = g.missingTint or { 1, 0.35, 0.35, 1 }
    icon.tex:SetVertexColor(t[1], t[2], t[3])

    if g.missingBorder then
        local s = g.borderSize or 1
        icon.border:ClearAllPoints()
        icon.border:SetPoint("TOPLEFT", -s, s)
        icon.border:SetPoint("BOTTOMRIGHT", s, -s)
        icon.border:SetColorTexture(t[1], t[2], t[3], t[4] or 1)
        icon.border:Show()
    else
        icon.border:Hide()
    end

    icon:Show()
    return icon
end

-- The unordered pile: one managed group, the engine lays it out and compacts it as
-- auras come and go. Growth and perRow are deliberately not applied here - the
-- engine's group layout exposes elementSpacing and nothing else, and quietly
-- ignoring two settings the options window still offers is worse than not offering
-- them.
local function EnsureGroup(id)
    local f = frames[id]
    local g = NAU.db.groups[id]
    local c = EnsureContainer(id)
    if not c then return nil end

    if not f.groupBuilt then
        -- Everything the group needs is supplied at creation. Blizzard's
        -- CustomAuraContainerGroupDefaultOptions documents exactly these fields -
        -- templateNames, initializeFrame, candidateFilters, sortMethod, sortDirection,
        -- layout, maxFrameCount - so the sort no longer depends on a separate call
        -- that throws when its third argument is missed.
        local ok = pcall(c.AddAuraGroup, c, "main", FilterString(g), {
            maxFrameCount   = math.max(1, g.maxCount or 8),
            sortMethod      = SortMethod(g),
            sortDirection   = SortDirection(g),
            -- elementWidth/elementHeight are how the LAYOUT is told how big an
            -- element is, and they matter more than they look. The frames the
            -- provider hands over carry access restrictions - GetSize and GetPoint on
            -- one throw outright - so a SetSize from this side is not something the
            -- addon can confirm took effect. Telling the layout the dimensions is the
            -- sanctioned route, and a layout that thinks its elements are zero-sized
            -- produces a zero-sized container full of invisible buttons.
            layout          = {
                elementSpacing = g.spacing or 2,
                elementWidth   = g.size or 32,
                elementHeight  = g.size or 32,
            },
            initializeFrame = function(button)
                -- Frames the engine has BUILT - which is not the same as auras
                -- matched. The provider creates them in batches ahead of need
                -- (FrameCreationBatchSize), so this counts pool capacity, not
                -- content. It was reported as "icons" for several builds and is not
                -- evidence that anything matched the filter.
                f.initCount = (f.initCount or 0) + 1
                f.firstButton = f.firstButton or button
                -- Sizing comes first and is not optional: the provider hands over a
                -- frame with no dimensions, and a SetAllPoints texture on a
                -- zero-sized frame draws nothing at all. That failure looks exactly
                -- like "the container never worked", which is where a day went.
                button:SetSize(g.size or 32, g.size or 32)
                BuildRegions(button, g)
            end,
        })
        if not ok then return nil end
        f.groupBuilt = true
    end

    -- Recorded rather than swallowed. Every one of these was a bare pcall whose
    -- result went nowhere, which meant a group could be built, populated by the
    -- engine, and never laid out - with nothing anywhere saying so.
    local function call(name, fn, ...)
        if not fn then NAU.groupReport[name] = "missing"; return end
        local ok2, err = pcall(fn, c, "main", ...)
        NAU.groupReport[name] = ok2 and "ok" or ("FAILED: " .. tostring(err))
    end
    call("SetAuraGroupMaxFrameCount", c.SetAuraGroupMaxFrameCount, math.max(1, g.maxCount or 8))
    call("SetAuraGroupLayout", c.SetAuraGroupLayout, { elementSpacing = g.spacing or 2 })
    call("SetAuraGroupSortMethod", c.SetAuraGroupSortMethod, SortMethod(g), SortDirection(g))

    -- "All but these" hides the listed spells from whatever the filter string lets
    -- through. The engine has excludeSpellIDs for exactly this, so it is one field
    -- rather than the post-filtering the old read-based version had to do.
    local excluded = (g.spellMode == "exclude") and ListedSpells(g) or nil
    if excluded then
        -- Expanded by name, exactly as the include path is. An exclusion that missed
        -- because the listed id was the ability's rather than the aura's would leave
        -- the spell on screen while the settings said it was hidden.
        call("SetAuraGroupCandidateFilters", c.SetAuraGroupCandidateFilters,
             { excludeSpellIDs = NAU.ExpandSpellIDs(excluded) })
        return true
    end

    local ids = OrderedSpells(g)
    if ids then
        call("SetAuraGroupCandidateFilters", c.SetAuraGroupCandidateFilters,
             { includeSpellIDs = NAU.ExpandSpellIDs(ids) })
    else
        -- NO candidate filters at all, which is not the same as empty ones.
        --
        -- This previously passed `{ includeSpellIDs = {} }` on the belief that an
        -- empty include set means match-all. That belief came from a comment in
        -- another addon's source, not from the API, and it is the difference between
        -- a group that draws and one that never matches anything: an empty list of
        -- included spell ids is a list that includes no spell ids.
        --
        -- The engine test in this file passes no candidateFilters and draws, which is
        -- what the real group needs to match.
        call("SetAuraGroupCandidateFilters", c.SetAuraGroupCandidateFilters, nil)
    end
    return true
end

--------------------------------------------------------------------------------

function Display:UpdateGroup(id)
    local g = NAU.db and NAU.db.groups[id]
    local f = frames[id]
    if not (g and f) then return end

    -- While the groups are UNLOCKED, nothing may hide a frame. Everything below can
    -- otherwise hide it - no target, not in combat yet, nothing on the unit - and
    -- these run on every aura event, so an unlocked group would vanish the moment one
    -- fired and leave nothing to drag.
    --
    -- This is what made placing an empty group impossible. The version before the
    -- rewrite carried `or anchorsShown` in its final SetShown and that condition was
    -- lost; a disabled group is still hidden, because switching it off is a
    -- deliberate instruction rather than a passing state.
    local placing = anchorsShown
    local function HideUnlessPlacing()
        if not placing then f:Hide() end
    end

    if not (NAU.db.enabled and g.enabled) then
        f:Hide()
        return
    end

    -- Samples are shown ONLY when explicitly asked for, via /na test.
    --
    -- They used to appear the instant the options window opened. That made sense when
    -- the addon drew every icon itself and could clear them first. It does not now:
    -- samples are painted on plain frames of ours while the engine keeps drawing the
    -- real auras in its container, so both sets appear at once, overlapping.
    --
    -- Opening a settings window should not change what is on screen, and a group that
    -- already has icons in it needs no placeholders to demonstrate anything.
    if testing then
        f:Show()
        f.showingSamples = true
        g._path = "SAMPLE icons (/na test is on)"
        -- The engine is parked while samples are up, so the two cannot be on screen
        -- together. Its filters are restored by the normal path below as soon as
        -- testing stops.
        -- The always-show placeholders too, or samples land on top of them.
        ParkMissing(id, f.container)
        if f.container then
            if f.groupBuilt then
                pcall(f.container.SetAuraGroupCandidateFilters, f.container, "main", DORMANT)
            end
            -- Slots are cleared to nil as well as parked, because EnsureSlot only
            -- re-points a slot whose spell has CHANGED. Leaving the remembered spell
            -- in place would make it skip the restore and the slot would stay empty
            -- after testing ended.
            for i, key in pairs(f.slotKeys or {}) do
                pcall(f.container.SetAuraSlotCandidateFilters, f.container, key, DORMANT)
                if f.slotSpell then f.slotSpell[i] = nil end
            end
        end
        self:FillWithSamples(id, g, f)
        return
    end
    if f.showingSamples then
        -- Sample art is drawn on plain frames of our own. They have to go before the
        -- engine's buttons are shown again or the two sets overlap. The engine's own
        -- filters need no special restore: EnsureGroup re-applies them on every pass.
        for i = 1, #f.buttons do f.buttons[i]:Hide() end
        f.showingSamples = false
    end

    if g.onlyInCombat and not InCombatLockdown() then
        HideUnlessPlacing()
        if not placing then return end
    end

    -- The container and its slots are built BEFORE the "is the unit there" test, and
    -- deliberately so.
    --
    -- Everything below returns early when there is no target, so with nothing
    -- selected at login the slots were never created. The first update that reached
    -- them was the one after you targeted something and opened on it - by which time
    -- you are in combat, where building and configuring a slot does not take. It then
    -- worked perfectly the moment combat dropped and restarted, because that was the
    -- first out-of-combat pass with a target.
    --
    -- Built while idle, they are simply waiting when the pull starts.
    if not InCombatLockdown() and OrderedSpells(g) then
        local pre = EnsureContainer(id)
        if pre then
            local warm = OrderedSpells(g)
            f.slotSpell = f.slotSpell or {}
            for i = 1, math.min(#warm, g.maxCount or #warm) do
                EnsureSlot(id, i, warm[i])
            end
        end
    end

    -- UnitName is nil for a unit that is not there, which replaces UnitExists and
    -- its landmine boolean.
    if not UnitName(g.unit) then
        HideUnlessPlacing()
        if not placing then return end
        -- Nothing to point a container at, but the grab box still has to be here.
        f:Show()
        return
    end

    local c = EnsureContainer(id)
    if not c then
        HideUnlessPlacing()
        if not placing then return end
        f:Show()
        return
    end
    -- A container does not follow a unit token: when target or focus repoints, the
    -- same container is now watching somebody else and has to be told.
    --
    -- And telling it the SAME token is not enough. "target" is still "target" after
    -- you swap mobs, so re-setting it changes nothing and the engine carries on
    -- displaying what it matched on the last one. The unit is cleared first, which
    -- makes the re-set a real change and forces a re-evaluation.
    if c.SetUnit then
        local okU, errU = pcall(c.SetUnit, c, g.unit)
        NAU.groupReport.SetUnit = okU and ("ok (" .. tostring(g.unit) .. ")")
                                       or ("FAILED: " .. tostring(errU))
        local stamp = NAU.unitStamp and NAU.unitStamp[g.unit] or 0
        if f.lastUnitStamp ~= stamp then
            pcall(c.SetUnit, c, "none")
            pcall(c.SetUnit, c, g.unit)
            f.lastUnitStamp = stamp
        end
    else
        NAU.groupReport.SetUnit = "MISSING - container has no SetUnit method"
    end

    -- "Only what is missing" - our icons, alpha-driven inverse off engine slots.
    local missing = MissingSpells(g)
    if missing then
        g._path = "always-show (" .. #missing .. " listed)"
        local n = math.min(#missing, g.maxCount or #missing)
        for i = 1, n do
            local icon = EnsureMissing(id, i, missing[i])
            if icon then PlaceButton(g, icon, i, f) end
        end
        -- Surplus icons from a shortened list, and the sensors behind them.
        for i = n + 1, #(f.missIcons or {}) do
            if f.missIcons[i] then f.missIcons[i]:Hide() end
            if f.missSpell and f.missSpell[i] then
                pcall(c.SetAuraSlotCandidateFilters, c, "naum" .. id .. "s" .. i, DORMANT)
                f.missSpell[i] = nil
            end
        end
        -- Nothing else may be drawing into this container.
        if f.groupBuilt then
            pcall(c.SetAuraGroupCandidateFilters, c, "main", DORMANT)
        end
        f.shown = n
        RefreshMissing(id)
        -- The first pass runs before the engine has bound anything, so the alphas are
        -- all "absent" whatever the truth is. One re-apply a moment later settles it;
        -- UNIT_AURA keeps it right from then on.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.1, function() RefreshMissing(id) end)
        end
        f:Show()
        return
    end

    -- Not in that mode, so anything it left behind comes down before another path
    -- draws over the top of it.
    ParkMissing(id, c)

    -- "Only these" is one slot per list position, each placed by us - so the icons
    -- read in the order you typed them, which is the whole reason for the mode. The
    -- engine sorts a group; it does not sort a row of individual slots.
    --
    -- An inactive spell leaves its position empty rather than closing the gap. That
    -- is deliberate: a fixed row can be read by shape, and one that compacts cannot.
    local ids = SLOTS_WORK and OrderedSpells(g)
    if ids then
        g._path = "ordered slots (" .. #ids .. ")"
        f.slotSpell = f.slotSpell or {}
        local n = math.min(#ids, g.maxCount or #ids)
        for i = 1, n do
            local b = EnsureSlot(id, i, ids[i])
            -- Placed ONCE, tracked by whether THIS slot has been placed - not by
            -- whether this call happened to create it.
            --
            -- Keying off "did I just create it" broke the display completely: the
            -- warm-up pass above creates the slots while idle and discards the
            -- return, so by the time this ran they already existed, nothing was ever
            -- placed, and every icon sat unanchored and invisible. Two changes that
            -- were each correct alone and cancelled each other out.
            --
            -- Placing once is still the rule: moving an engine button is only
            -- permitted while it is being built. Anything that would change a
            -- position is in the look signature, which rebuilds the container and
            -- its slots, and this table goes with them.
            f.slotPlaced = f.slotPlaced or {}
            if b and not f.slotPlaced[i] then
                f.slotPlaced[i] = true
                PlaceButton(g, b, i, f)
            end
        end
        -- The category group is parked while slots are driving this group. Both live
        -- on the same container, and a group that was built during an earlier "Off"
        -- setting keeps matching after the mode changes - so every aura appeared
        -- twice, once from its slot and once from the group, with the group laying
        -- its copy out on top of the positioned one.
        if f.groupBuilt then
            pcall(c.SetAuraGroupCandidateFilters, c, "main", DORMANT)
        end

        -- Surplus slots from a shortened list are parked, never hidden: we are not
        -- permitted to hide an engine button, but an impossible candidate id empties
        -- it just as well.
        for i = n + 1, #f.slots do
            if f.slotSpell[i] ~= nil then
                pcall(c.SetAuraSlotCandidateFilters, c, f.slotKeys[i], DORMANT)
                f.slotSpell[i] = nil
            end
        end
        f.shown = n

        -- A slot built this pass has not been given a real chance to match: the
        -- engine had nothing bound to this container when it was created. One more
        -- pass a moment later applies its filters properly, which is what dropping
        -- and re-entering combat was doing by accident.
        if f.newSlot then
            f.newSlot = nil
            if C_Timer and C_Timer.After then
                C_Timer.After(0.1, function() Display:UpdateGroup(id) end)
            end
        end

        -- hideWhenEmpty, for spell lists only. The engine owns the buttons and we
        -- may not ask one whether it is shown - that returns a secret boolean and
        -- truth-testing it is a hard error - so emptiness is established the other
        -- way round, by asking the game about the spells we named.
        if g.hideWhenEmpty and not anchorsShown then
            local anyUp = AnyListedSpellUp(g, ids)
            -- Never hides during combat, whatever the read said.
            --
            -- The read is the only way to tell "empty" from "not allowed to look",
            -- and in a fight it cannot tell them apart on any unit - a target
            -- especially. It answered "nothing is up" for two dots that were
            -- actually ticking, and hid the whole group; the icons were correct and
            -- the anchor was not there to show them.
            --
            -- So the rule is now the blunt one rather than the clever one: an empty
            -- anchor out of combat is tidy, and an anchor that vanishes mid-pull is
            -- the addon breaking. Only a definite "nothing is up", established while
            -- the client is answering honestly, may hide it.
            local mayHide = (anyUp == false)
                            and not InCombatLockdown()
                            and not (NAU.AurasAreSecret and NAU.AurasAreSecret())
            f.lastAnyUp = (anyUp == nil) and "unknown" or tostring(anyUp)
            f:SetShown(not mayHide)
            return
        end
    else
        -- The label has to say which of the three it actually did, because they are
        -- one code path now and look identical from outside. Reporting "categories"
        -- for a working spell list is how a correct group gets diagnosed as broken.
        local listed = ListedSpells(g)
        if g.spellMode == "exclude" and listed then
            g._path = "engine group, excluding " .. #listed .. " listed spell(s)"
        elseif g.spellMode == "only" and listed then
            g._path = "engine group, only your " .. #listed .. " listed spell(s)"
        elseif g.spellMode == "only" then
            -- "Only these" with an empty list. The filter string is all that is left,
            -- so the group behaves as a category group - said out loud, because
            -- otherwise it looks like the mode is being ignored.
            g._path = "engine group (categories) - spell list is set to 'only' but is empty"
        else
            g._path = "engine group (categories)"
        end
        -- And the mirror image: slots left over from a previous "Only these" keep
        -- matching their spells once the group takes over, so they are parked here.
        -- Their remembered spell is cleared too, or EnsureSlot would decide nothing
        -- had changed and never restore them when the mode is switched back.
        if f.slotKeys then
            for i, key in pairs(f.slotKeys) do
                pcall(c.SetAuraSlotCandidateFilters, c, key, DORMANT)
                if f.slotSpell then f.slotSpell[i] = nil end
            end
        end
        EnsureGroup(id)
        -- Frames the engine actually asked us to build, not the group's capacity.
        f.shown = f.initCount or 0
    end

    f:Show()
end

-- Sample icons for the options window and /na test. Real aura instance ids cannot
-- be invented, so these are drawn with plain values through the ordinary setters -
-- which is allowed, because nothing here came from a restricted API.
local SAMPLE_ICONS = {
    "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
    "Interface\\Icons\\Spell_Shadow_AbominationExplosion",
    "Interface\\Icons\\Spell_Fire_Immolation",
    "Interface\\Icons\\Spell_Nature_CorrosiveBreath",
    "Interface\\Icons\\Spell_Shadow_CurseOfSargeras",
    "Interface\\Icons\\Spell_Frost_FrostShock",
    "Interface\\Icons\\Spell_Holy_Renew",
    "Interface\\Icons\\Spell_Nature_Rejuvenation",
}

function Display:FillWithSamples(id, g, f)
    local count = math.max(1, math.min(g.maxCount, 5))
    for i = 1, count do
        local b = f.buttons[i]
        if not b then
            b = CreateButton(f, i)
            f.buttons[i] = b
        end
        StyleButton(g, b)
        PlaceButton(g, b, i, f)

        b.icon:SetTexture(SAMPLE_ICONS[((i - 1) % #SAMPLE_ICONS) + 1])
        pcall(b.icon.SetDesaturated, b.icon, false)
        b.icon:SetTexCoord(g.zoomIcon and 0.07 or 0, g.zoomIcon and 0.93 or 1,
                           g.zoomIcon and 0.07 or 0, g.zoomIcon and 0.93 or 1)

        if g.showSwipe then
            -- Plain numbers, so the ordinary setter is fine here.
            b.cd:SetCooldown(GetTime() - (i * 2), 30)
            b.cd:Show()
        else
            b.cd:Hide()
        end

        UnbindTimer(b)
        b.timer:SetText(g.showTimer and string.format("%ds", 30 - i * 2) or "")
        b.count:SetText(g.showStacks and (i > 1 and tostring(i) or "") or "")
        b:Show()
    end

    for i = count + 1, #f.buttons do
        UnbindTimer(f.buttons[i])
        f.buttons[i]:Hide()
    end
    f.shown = count
end

function Display:ShownCount(id)
    local f = frames[id]
    return f and f.shown or 0
end

-- Whether what is on screen for this group is sample art rather than real auras.
-- Reported by /na diag, because five placeholder icons and five real debuffs look
-- identical from the outside and that cost an evening of confusion.
function Display:ShowingSamples(id)
    local f = frames[id]
    return f and f.showingSamples or false
end

function Display:IsPreviewing() return previewing end
function Display:IsTesting()    return testing end

-- The aura map is cached per update pass. A diagnostic asking a question about
-- right now must not be handed an answer from several seconds ago, so it forces a
-- rebuild first.
function Display:RefreshAuraMaps()
    auraMapGeneration = -1
end

--------------------------------------------------------------------------------
-- Group frames
--------------------------------------------------------------------------------

local function SavePosition(id)
    local g = NAU.db.groups[id]
    local f = frames[id]
    if not (g and f) then return end
    -- StopMovingOrSizing is free to re-anchor the frame to whichever corner it
    -- likes, so the relative point has to be saved as well. Reconstructing the
    -- position from `point` alone would move the group on every reload.
    local point, _, relPoint, x, y = f:GetPoint(1)
    if point then
        g.point    = point
        g.relPoint = relPoint or point
        g.x = math.floor(x + 0.5)
        g.y = math.floor(y + 0.5)
    end
end

local function RestorePosition(id)
    local g = NAU.db.groups[id]
    local f = frames[id]
    if not (g and f) then return end
    f:ClearAllPoints()
    f:SetPoint(g.point or "CENTER", UIParent, g.relPoint or g.point or "CENTER",
               g.x or 0, g.y or 0)
    f:SetScale(g.scale or 1)
end

local function CreateGroupFrame(id)
    local g = NAU.db.groups[id]

    local f = CreateFrame("Frame", "nugsAurasGroup" .. id, UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(id)
        if NAU.RefreshOptions then NAU.RefreshOptions() end
    end)

    f.buttons = {}
    f.shown = 0
    f.groupID = id

    -- Only drawn while unlocked, so there is something to grab when the group is
    -- empty - which is most of the time, and exactly when you want to move it.
    f.grip = f:CreateTexture(nil, "BACKGROUND")
    f.grip:SetPoint("TOPLEFT", -4, 4)
    f.grip:SetPoint("BOTTOMRIGHT", 4, -4)
    f.grip:SetColorTexture(0.35, 0.72, 1.00, 0.22)
    f.grip:Hide()

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.label:SetPoint("BOTTOM", f, "TOP", 0, 4)
    f.label:Hide()

    frames[id] = f
    return f
end

-- The group frame is sized to the block its icons occupy, so the grab handle
-- covers the whole group rather than a single corner of it.
local function SizeGroupFrame(id)
    local g = NAU.db.groups[id]
    local f = frames[id]
    if not (g and f) then return end

    local step = g.size + g.spacing
    local per  = math.max(1, g.perRow)
    local majorCount = math.min(g.maxCount, per)
    local minorCount = math.ceil(g.maxCount / per)

    local majorLen = majorCount * step - g.spacing
    local minorLen = minorCount * step - g.spacing

    local dir = GROWTH[g.growth] or GROWTH.RIGHT
    if dir.horizontal then
        f:SetSize(math.max(1, majorLen), math.max(1, minorLen))
    else
        f:SetSize(math.max(1, minorLen), math.max(1, majorLen))
    end
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

function Display:Init()
    -- Said once, at login, and deliberately not swallowed. Without the engine this
    -- addon draws nothing at all, and an empty screen is indistinguishable from
    -- "none of my auras are up" - the user would sit there adjusting settings that
    -- were never going to do anything.
    if not self.hasEngine then
        NAU.Print("|cffff5555this build of the game has no AuraContainer|r - nugsAuras needs "
                  .. "patch 12.1 or later and will not draw anything until then.")
    end
    self:Rebuild()
end

function Display:Rebuild()
    if not NAU.db then return end

    -- Retire frames whose group is gone. The frame itself cannot be destroyed, so
    -- it is hidden and forgotten; a new group with the same id would reuse it.
    for id, f in pairs(frames) do
        if not NAU.db.groups[id] then
            f:Hide()
            frames[id] = nil
        end
    end

    for _, id in ipairs(NAU.db.groupOrder) do
        if not frames[id] then CreateGroupFrame(id) end
        SizeGroupFrame(id)
        RestorePosition(id)
        local g = NAU.db.groups[id]
        frames[id].label:SetText(g.name .. " |cff888888(drag)|r")
        for _, b in ipairs(frames[id].buttons) do StyleButton(g, b) end
    end

    self:SetLocked(NAU.db.locked)
    self:UpdateAll()
    self:RegisterUnits()
end

function Display:UpdateAll()
    if not NAU.db then return end
    for _, id in ipairs(NAU.db.groupOrder) do
        self:UpdateGroup(id)
    end
end

function Display:UpdateUnit(unit)
    if not NAU.db then return end
    for _, id in ipairs(NAU.db.groupOrder) do
        local g = NAU.db.groups[id]
        if g and g.unit == unit then
            self:UpdateGroup(id)
        end
    end
end

-- Silent: the options window calls this on every slider tick, so anything chatty
-- or expensive belongs in ToggleLock.
function Display:SetLocked(locked)
    -- The guard lives HERE, not only in ToggleLock, because this is where the state
    -- actually changes. ToggleLock refuses to unlock in combat and every button and
    -- slash command goes through it - but "every caller is polite" is not a
    -- guarantee, it is an assumption, and it only takes one direct call to leave
    -- drag boxes on screen mid-pull.
    if not locked and InCombatLockdown() then return end

    NAU.db.locked = locked and true or false
    anchorsShown = not NAU.db.locked

    for id, f in pairs(frames) do
        f:EnableMouse(anchorsShown)
        f.grip:SetShown(anchorsShown)
        f.label:SetShown(anchorsShown)
        if anchorsShown then
            f:Show()
            -- The grab box is what you drag, and it has to be there whether or not
            -- the group currently holds any icons. Sample icons used to be switched
            -- on alongside it, which made placing a group look like it depended on
            -- them; it never did, but an unlocked empty group had nothing obvious to
            -- aim at. The box is drawn from the group's configured size, so it is the
            -- same size the icons will occupy.
            f.grip:SetAlpha(1)
            f:SetFrameStrata("HIGH")
        else
            f:SetFrameStrata("MEDIUM")
        end
    end

    if not anchorsShown then self:UpdateAll() end
end

function Display:ToggleLock(locked)
    -- Unlocking mid-fight is refused, for the same reason a pull locks the groups:
    -- placing them puts every drag box and its sample contents on screen, and that
    -- cannot be told apart from the real thing during a real pull. The button and the
    -- slash command both come through here, so this is the only place it needs saying.
    if not locked and InCombatLockdown() then
        NAU.Print("groups cannot be placed during combat - try again after the fight.")
        return
    end

    self:SetLocked(locked)
    if locked then
        NAU.Print("groups locked.")
    else
        NAU.Print("groups unlocked - drag each blue box, then |cffffd479/na lock|r.")
    end
    if NAU.RefreshOptions then NAU.RefreshOptions() end
    -- The options window gets out of the way while you are placing things, and a
    -- small bar takes its place. Options.lua owns that; guarded because that file
    -- is only loaded on demand.
    if NAU.OnLockChanged then NAU.OnLockChanged(NAU.db.locked) end
end

function Display:Test()
    testing = not testing
    self:UpdateAll()
    if testing then
        NAU.Print("sample icons on - |cffffd479/na test|r again to stop.")
    else
        NAU.Print("sample icons off.")
    end
end

-- Called by the options window as it opens and closes.
function Display:SetPreview(on)
    on = on and true or false
    if on == previewing then return end
    previewing = on
    self:UpdateAll()
end

function Display:ApplySettings()
    if not NAU.db then return end
    for _, id in ipairs(NAU.db.groupOrder) do
        SizeGroupFrame(id)
        RestorePosition(id)
        local g = NAU.db.groups[id]
        frames[id].label:SetText(g.name .. " |cff888888(drag)|r")
        for _, b in ipairs(frames[id].buttons) do StyleButton(g, b) end
    end
    self:UpdateAll()
end

--------------------------------------------------------------------------------
-- Events
--
-- Registration is rebuilt from the groups rather than fixed, so an addon watching
-- only the player never hears a raid's worth of target aura churn. UNIT_AURA is a
-- synchronous event and fires hard during a fight, so the work is coalesced into
-- one pass on the next frame instead of running per event.
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
local dirty = {}
local dirtyAll = false
local pending = false

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
    self:Hide()
    pending = false
    -- One generation per pass, so the Cooldown Manager map is walked once however
    -- many groups turned out to be dirty.
    generation = generation + 1
    if dirtyAll then
        dirtyAll = false
        wipe(dirty)
        Display:UpdateAll()
        return
    end
    for unit in pairs(dirty) do
        Display:UpdateUnit(unit)
    end
    wipe(dirty)

    -- Piggy-backed on the update pass rather than given a timer of its own: an
    -- aura changed, which is exactly when there is something new worth recording,
    -- and the function throttles itself and bails immediately while auras are
    -- secret.
    RecordSeenAuras()
end)

Touch = function(unit)
    if unit then dirty[unit] = true else dirtyAll = true end
    if not pending then
        pending = true
        driver:Show()
    end
end
Display.Touch = Touch

function Display:RegisterUnits()
    events:UnregisterAllEvents()
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_TARGET_CHANGED")
    events:RegisterEvent("PLAYER_FOCUS_CHANGED")
    events:RegisterEvent("UNIT_PET")
    events:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")

    -- The restriction state is a mode that turns on for combat, encounters,
    -- keystones and rated pvp. Every group is re-evaluated when it flips, because
    -- a spell list that applied a second ago may not apply now.
    events:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

    if C_EventUtils and C_EventUtils.IsEventValid then
        for _, name in ipairs({ "ADDON_RESTRICTION_STATE_CHANGED", "AURA_DATA_PROVIDER_SWITCH",
                                "COOLDOWN_VIEWER_DATA_LOADED", "COOLDOWN_VIEWER_TABLE_HOTFIXED",
                                "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED", "TRAIT_CONFIG_UPDATED" }) do
            if C_EventUtils.IsEventValid(name) then
                pcall(events.RegisterEvent, events, name)
            end
        end
    end

    -- Every unit token is a fixed string, so each group listens on its own unit
    -- rather than to the whole world's aura traffic.
    local units, list = {}, {}
    for _, id in ipairs(NAU.db.groupOrder) do
        local g = NAU.db.groups[id]
        if g and g.enabled and not units[g.unit] then
            units[g.unit] = true
            list[#list + 1] = g.unit
        end
    end
    if #list > 0 then
        pcall(function() events:RegisterUnitEvent("UNIT_AURA", unpack(list)) end)
    end

    -- UNIT_SPELLCAST_SUCCEEDED is deliberately not registered any more. Watching
    -- your own casts existed only to estimate an aura the addon could not read; the
    -- engine reads it for us now, and guessing alongside it would be worse than
    -- useless - two sources disagreeing on the same icon.
end

-- What the Cooldown Manager tracks changes with spec, talents and hotfixes, and
-- the cached set has to go with it.
local RETRACK_EVENTS = {
    PLAYER_SPECIALIZATION_CHANGED          = true,
    TRAIT_CONFIG_UPDATED                   = true,
    COOLDOWN_VIEWER_DATA_LOADED            = true,
    COOLDOWN_VIEWER_TABLE_HOTFIXED         = true,
    COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED = true,
}

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if RETRACK_EVENTS[event] then
        NAU.InvalidateTrackedSet()
    end

    if event == "PLAYER_REGEN_DISABLED" then
        -- Locking on a pull belongs HERE, in the display, not only in the options
        -- window. The window's copy of this can be missed - it is a different file
        -- with its own state - and this event was already being registered here and
        -- then handled by nothing, which is the worst of both.
        --
        -- Placing groups puts a drag box on every one of them; leaving that up during
        -- a fight is unusable and looks like the addon has come apart.
        if NAU.db and not NAU.db.locked then
            Display:SetLocked(true)
            if NAU.OnLockChanged then NAU.OnLockChanged(true) end
            if NAU.RefreshOptions then NAU.RefreshOptions() end
        end
        Touch(nil)

    elseif event == "UNIT_AURA" then
        Touch(arg1)
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Counted rather than compared. Knowing the unit CHANGED is all that is
        -- needed, and the alternatives - a GUID or a name - can both be secret on the
        -- units this matters for.
        NAU.unitStamp.target = (NAU.unitStamp.target or 0) + 1
        Touch("target")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        NAU.unitStamp.focus = (NAU.unitStamp.focus or 0) + 1
        Touch("focus")
    elseif event == "UNIT_PET" then
        Touch("pet")
    else
        Touch(nil)
    end
end)
