--------------------------------------------------------------------------------
-- nugsAuras
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsAuras  -  Core.lua
-- The namespace, the group model, saved variables and the slash command.
--
-- Every other debuff tracker hangs its icons off a unit frame or a nameplate, so
-- where they appear is decided by something that is not the tracker. Here a group
-- owns its own anchor and nothing else does, which is the entire point: a group of
-- one is a single icon you can put anywhere on the screen.
--
-- The group is therefore the unit of everything - position, growth, size, look and
-- filter all live on it, and there is no global "look" to inherit from. Two groups
-- that should match are made to match by copying one onto the other, which is a
-- button in the options window rather than a layer of settings.
--
-- Shared namespace: the second vararg is the same table across every Lua file in
-- this addon, so all state and functions hang off of it.
--------------------------------------------------------------------------------

local ADDON_NAME, NAU = ...

NAU.name    = ADDON_NAME
NAU.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
              or "0.1.0"

local PREFIX = "|cff6fc2ffnugsAuras|r: "
function NAU.Print(msg)
    print(PREFIX .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Secret values (Midnight / 12.0)
--
-- Combat data is handed to addons as opaque "secret" values. Reading one is fine;
-- doing arithmetic or comparisons on it raises a Lua error. Every value we pull
-- out of an aura therefore goes through Plain(), which hands back nil rather than
-- something we are not allowed to compute with. nil means "cannot know right now"
-- and the numeric code paths stand down.
--
-- A secret *boolean* is the sharp edge: truth-testing one throws, because a
-- boolean's truthiness is its value. PlainBool() returns a true/false/nil
-- tri-state so a boolean from an aura can be branched on safely, where nil means
-- "not allowed to know".
--------------------------------------------------------------------------------

local issecretvalue = _G.issecretvalue
local issecrettable = _G.issecrettable

NAU.secretsExist = (issecretvalue ~= nil)

local function Plain(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
NAU.Plain = Plain

-- Separated from Plain because the caller has to know the difference between
-- "false" and "not allowed to know", and a bare Plain() would flatten both to nil
-- and read as false at the call site.
local function PlainBool(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v and true or false
end
NAU.PlainBool = PlainBool

-- A secret table throws on #, ipairs and pairs, not just on its contents. The
-- UNIT_AURA payload's addedAuras container is itself secret in combat on 12.x, so
-- anything we are about to iterate is checked before we walk it.
local function Walkable(t)
    if type(t) ~= "table" then return false end
    if issecrettable and issecrettable(t) then return false end
    if issecretvalue and issecretvalue(t) then return false end
    return true
end
NAU.Walkable = Walkable

-- Whether the client is currently withholding aura data. This is a mode, not a
-- constant: it turns on for combat, encounters, keystones and rated pvp, and off
-- again afterwards, so nothing may cache the answer.
function NAU.AurasAreSecret()
    if not C_Secrets then return false end
    local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
    if not ok then return false end
    return secret and true or false
end

--------------------------------------------------------------------------------
-- Units and filters
--
-- Groups are described by Blizzard's filter tokens rather than by spell lists.
-- That is not a preference: under secrecy an aura's spellId and name are secret
-- and cannot be compared, so a list of spell IDs has nothing to match against in
-- a raid. The tokens are evaluated by the client, which is allowed to know.
--------------------------------------------------------------------------------

NAU.UNITS = {
    { key = "player", label = "Me"     },
    { key = "target", label = "Target" },
    { key = "focus",  label = "Focus"  },
    { key = "pet",    label = "Pet"    },
    { key = "boss1",  label = "Boss 1" },
    { key = "boss2",  label = "Boss 2" },
    { key = "boss3",  label = "Boss 3" },
    { key = "boss4",  label = "Boss 4" },
    { key = "boss5",  label = "Boss 5" },
}

-- The client's own filter vocabulary, taken from AuraUtil.AuraFilters in the
-- shipped 12.0.7 interface source. There are exactly thirteen and this is a
-- closed set: a token the client does not know is not ignored, it makes the whole
-- filter string useless, so nothing here may be invented.
--
-- Deliberately absent: MAW and INCLUDE_NAME_PLATE_ONLY are too situational to be
-- worth a row. IMPORTANT and STEALABLE are *not on this build* - IMPORTANT existed
-- in 12.0.1, was removed in 12.0.7, and returns in 12.1; STEALABLE was never a
-- filter at all. Both are easy to find in older documentation and neither works
-- here, which is exactly why they are called out rather than quietly omitted.
--
-- `negatable` marks the one token with a NOT_ partner. The `!TOKEN` negation
-- prefix that would make every token negatable is a 12.1 addition and does not
-- work on 12.0.7, so exclusion is offered only where Blizzard shipped the pair.
NAU.TOKENS = {
    { key = "CROWD_CONTROL",           label = "Crowd control",
      hint = "Stuns, roots, fears and the like." },
    { key = "BIG_DEFENSIVE",           label = "Major defensive",
      hint = "Personal cooldowns such as Shield Wall." },
    { key = "EXTERNAL_DEFENSIVE",      label = "External defensive",
      hint = "Defensives someone else put on the unit." },
    { key = "RAID_IN_COMBAT",          label = "Shows on raid frames",
      hint = "Combine with 'only auras I applied' to get your own HoTs." },
    { key = "RAID_PLAYER_DISPELLABLE", label = "Dispellable by me",
      hint = "Only auras your class can remove." },
    { key = "RAID",                    label = "Raid-relevant",
      hint = "What Blizzard's raid frames would consider worth showing." },
    { key = "CANCELABLE",              label = "Cancellable",
      hint = "Buffs you are allowed to click off.", negatable = true },
}

-- The negation partners the client ships. Only used for tokens marked negatable.
local NOT_TOKEN = {
    CANCELABLE = "NOT_CANCELABLE",
}
NAU.NOT_TOKEN = NOT_TOKEN

function NAU.TokenModes(entry)
    if entry.negatable then
        return { { key = "off",     label = "ignore"   },
                 { key = "require", label = "required" },
                 { key = "exclude", label = "excluded" } }
    end
    -- No NOT_ partner on this build, so "excluded" would be a control that cannot
    -- do anything, and a toggle that cannot do anything is worse than no toggle.
    return { { key = "off",     label = "ignore"   },
             { key = "require", label = "required" } }
end

NAU.GROWTH = {
    { key = "RIGHT", label = "Right" },
    { key = "LEFT",  label = "Left"  },
    { key = "UP",    label = "Up"    },
    { key = "DOWN",  label = "Down"  },
}

NAU.OUTLINES = { "NONE", "OUTLINE", "THICKOUTLINE" }

NAU.SPELL_MODES = {
    { key = "off",     label = "Off"         },
    { key = "only",    label = "Only these"  },
    { key = "exclude", label = "All but these" },
    -- The inverse of the other three: an icon for every listed spell that is NOT on
    -- the unit, disappearing as each one lands. A dot reminder rather than a tracker.
    { key = "missing", label = "Always show these" },
}

-- Builds the pipe-joined filter string the client expects, e.g.
-- "HARMFUL|PLAYER|CROWD_CONTROL". Order is stable so the string can be compared
-- against the one a group was last built with.
function NAU.BuildFilter(g)
    local parts = { g.kind or "HARMFUL" }
    if g.mineOnly then
        parts[#parts + 1] = "PLAYER"
    end
    for _, entry in ipairs(NAU.TOKENS) do
        local mode = g.tokens and g.tokens[entry.key]
        if mode == "require" then
            parts[#parts + 1] = entry.key
        elseif mode == "exclude" and NOT_TOKEN[entry.key] then
            parts[#parts + 1] = NOT_TOKEN[entry.key]
        end
    end
    return table.concat(parts, "|")
end

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

-- Every setting a group owns. A group carries a full copy rather than inheriting
-- from a global look, so two groups can be completely different without either of
-- them being "the odd one out" that has to override everything.
NAU.groupDefaults = {
    name     = "New group",
    enabled  = true,

    unit     = "target",
    kind     = "HARMFUL",     -- HELPFUL or HARMFUL
    mineOnly = true,
    tokens   = {},            -- [token] = "require" | "exclude"

    -- Spell list. In "only" mode this drives the group directly, one lookup per
    -- spell, which is the only way to get icons in an order the player chose - and
    -- the only aura path that keeps working in combat, for spells Blizzard has
    -- declassified. When none of the listed spells are readable the group falls
    -- back to its tokens above, which is why every group has them.
    --
    -- spellOrder is kept beside spells because the order is the feature; a set
    -- alone has none, and pairs() would shuffle the icons on every reload.
    spellMode  = "off",       -- off | only | exclude
    spells     = {},          -- [spellID] = true
    spellOrder = {},          -- array of spellID, the order icons appear in

    -- Position. relPoint is saved beside point because StopMovingOrSizing is free
    -- to re-anchor to a different corner, and rebuilding from point alone walks
    -- the group across the screen on every reload.
    point    = "CENTER",
    relPoint = "CENTER",
    x        = 0,
    y        = -120,

    -- Layout
    growth   = "RIGHT",
    size     = 36,
    spacing  = 4,
    perRow   = 8,             -- wraps to a new line after this many
    maxCount = 8,
    scale    = 1.00,

    -- Look
    showIcon      = true,
    zoomIcon      = true,     -- crop the icon border rather than show it
    showSwipe     = true,
    -- Which way round the swipe runs. Off is Blizzard's default: the dark wedge
    -- covers what is left and shrinks away, so the icon brightens as the aura
    -- expires. On inverts it - the icon starts clear and darkens as time runs out,
    -- which is what most cooldown displays do and reads as "draining" rather than
    -- "filling". Left off by default so nobody's existing groups change look.
    reverseSwipe  = false,

    -- "Only what is missing" look. A missing icon has to be distinguishable at a
    -- glance from a real aura, because both kinds of group can be on screen at once
    -- and they mean opposite things.
    missingDesat  = true,                       -- grey the icon out
    missingTint   = { 1, 0.35, 0.35, 1 },       -- and wash it with a colour
    missingBorder = true,                       -- border in the same colour

    showTimer     = true,
    showStacks    = true,
    stackMin      = 2,        -- stacks below this are not worth the clutter
    stackMax      = 999,
    showBorder    = true,
    borderSize    = 1,
    borderColor   = { 0, 0, 0, 0.9 },
    desatOthers   = false,    -- dim auras that are not yours

    font        = "Friz Quadrata TT",
    fontSize    = 12,
    fontOutline = "OUTLINE",
    timerColor  = { 1.00, 1.00, 1.00 },
    stackColor  = { 1.00, 0.82, 0.00 },

    -- Behaviour
    hideWhenEmpty = true,
    onlyInCombat  = false,
}

NAU.defaults = {
    enabled       = true,
    locked        = true,
    minimapHidden = false,
    minimapAngle  = 200,

    -- Groups are stored by id and ordered by a separate array, so renaming or
    -- reordering never has to touch the settings themselves.
    groups     = {},
    groupOrder = {},
    nextGroupID = 1,

    -- Shown once, then never again. A tracker that silently shows nothing in a
    -- raid because the client withheld the data is indistinguishable from a broken
    -- addon, and the one place to explain that is the first time it happens.
    warnedAboutSecrets = false,
}

NAU.charDefaults = {
    lastTab   = nil,
    lastGroup = nil,

    -- Every aura this character has seen while the client was willing to name it,
    -- as [spellID] = { name, icon, harmful }. Recorded passively rather than on
    -- demand, because the auras worth tracking exist in combat and can only be
    -- read out of it - and the few seconds after a fight, while your dots are
    -- still ticking, is the window that closes before anybody thinks to press a
    -- button. Per character, because the spells follow the class.
    catalog = {},

    -- [castSpellID] = auraSpellID, learned by watching which aura appeared when
    -- you cast something. Names cover most abilities, but Wake of Ashes applies
    -- Truth's Wake and nothing connects those two but observation.
    castToAura = {},
}

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

-- Recursive merge of missing keys only, so a new release can add a default without
-- touching anything the player has already changed. Duplicated from the other nugs
-- addons rather than shared, because a shared copy would be a load-order dependency.
local function CopyDefaults(dst, src)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end
NAU.CopyDefaults = CopyDefaults

-- A fresh deep copy, for handing a group its own tables rather than references
-- into the defaults that every other group would then share.
local function DeepCopy(src)
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            out[k] = DeepCopy(v)
        else
            out[k] = v
        end
    end
    return out
end
NAU.DeepCopy = DeepCopy

-- The two groups a new install starts with. Not zero: an addon whose first screen
-- is an empty list gives no clue what a group is supposed to look like, and these
-- two are the pair almost everybody wants anyway.
local STARTER_GROUPS = {
    {
        name = "My debuffs", unit = "target", kind = "HARMFUL", mineOnly = true,
        point = "CENTER", relPoint = "CENTER", x = 0, y = -140,
        growth = "RIGHT", size = 38,
    },
    {
        -- No tokens: on this build there is no "important" filter to lean on, so
        -- the honest default is every debuff on you, sorted soonest-first, and a
        -- small enough cap that it cannot swamp the screen.
        name = "On me", unit = "player", kind = "HARMFUL", mineOnly = false,
        sort = "expiryonly", maxCount = 6,
        point = "CENTER", relPoint = "CENTER", x = 0, y = 180,
        growth = "RIGHT", size = 42,
    },
}

function NAU.NewGroup(seed)
    local db = NAU.db
    local id = "g" .. tostring(db.nextGroupID or 1)
    db.nextGroupID = (db.nextGroupID or 1) + 1

    local g = DeepCopy(NAU.groupDefaults)
    if seed then
        for k, v in pairs(seed) do
            g[k] = type(v) == "table" and DeepCopy(v) or v
        end
    end

    db.groups[id] = g
    db.groupOrder[#db.groupOrder + 1] = id
    return id, g
end

function NAU.DeleteGroup(id)
    local db = NAU.db
    if not db.groups[id] then return end
    db.groups[id] = nil
    for i, other in ipairs(db.groupOrder) do
        if other == id then
            table.remove(db.groupOrder, i)
            break
        end
    end
end

-- Copies one group's look onto every other, for the case where they should match.
-- Deliberately does not copy unit, filter, spells or position: those are what make
-- a group a different group, and overwriting them would merge rather than restyle.
local LOOK_KEYS = {
    "growth", "size", "spacing", "perRow", "maxCount", "scale",
    "showIcon", "zoomIcon", "showSwipe", "reverseSwipe", "showTimer", "showStacks",
    "missingDesat", "missingTint", "missingBorder",
    "stackMin", "stackMax", "showBorder", "borderSize",
    "desatOthers", "font", "fontSize", "fontOutline",
    "hideWhenEmpty", "onlyInCombat",
}
local LOOK_COLORS = { "borderColor", "timerColor", "stackColor" }

function NAU.ApplyLookEverywhere(fromID)
    local src = NAU.db.groups[fromID]
    if not src then return 0 end
    local count = 0
    for id, g in pairs(NAU.db.groups) do
        if id ~= fromID then
            for _, key in ipairs(LOOK_KEYS) do
                g[key] = src[key]
            end
            for _, key in ipairs(LOOK_COLORS) do
                local c, s = g[key], src[key]
                for i = 1, #s do c[i] = s[i] end
            end
            count = count + 1
        end
    end
    return count
end

local function InitDB()
    nugsAurasDB     = CopyDefaults(nugsAurasDB     or {}, NAU.defaults)
    nugsAurasCharDB = CopyDefaults(nugsAurasCharDB or {}, NAU.charDefaults)

    NAU.db   = nugsAurasDB
    NAU.char = nugsAurasCharDB

    -- Seed the starter groups only on a genuinely fresh install. Checking the
    -- order array rather than the group table, because a player who deleted every
    -- group meant it and should not have them handed back on the next login.
    if not NAU.db.seeded then
        NAU.db.seeded = true
        if #NAU.db.groupOrder == 0 then
            for _, seed in ipairs(STARTER_GROUPS) do
                NAU.NewGroup(seed)
            end
        end
    end

    -- Every group is topped up with any setting added since it was created, so a
    -- new release lands on groups the player made months ago as well as new ones.
    for _, g in pairs(NAU.db.groups) do
        CopyDefaults(g, NAU.groupDefaults)
    end

    -- Drop ids in the order array that no longer have a group, and append any
    -- group the order array has lost track of. Neither should happen, but a group
    -- that exists and cannot be reached is invisible and unfixable from the UI.
    local seen = {}
    for i = #NAU.db.groupOrder, 1, -1 do
        local id = NAU.db.groupOrder[i]
        if not NAU.db.groups[id] or seen[id] then
            table.remove(NAU.db.groupOrder, i)
        else
            seen[id] = true
        end
    end
    for id in pairs(NAU.db.groups) do
        if not seen[id] then
            NAU.db.groupOrder[#NAU.db.groupOrder + 1] = id
        end
    end
end

--------------------------------------------------------------------------------
-- Media
--------------------------------------------------------------------------------

local STOCK_FONTS = {
    { name = "Friz Quadrata TT", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",     path = "Fonts\\ARIALN.TTF"   },
    { name = "Skurri",           path = "Fonts\\SKURRI.TTF"   },
    { name = "Morpheus",         path = "Fonts\\MORPHEUS.TTF" },
}

-- Stock list first, LibSharedMedia appended if some other addon happens to have
-- loaded it, never depended on.
local function MediaList(stock, lsmKind)
    local list, seen = {}, {}
    for _, entry in ipairs(stock) do
        list[#list + 1] = entry
        seen[entry.name] = true
    end
    local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local ok, names = pcall(LSM.List, LSM, lsmKind)
        if ok and type(names) == "table" then
            for _, name in ipairs(names) do
                if not seen[name] then
                    local okPath, path = pcall(LSM.Fetch, LSM, lsmKind, name)
                    if okPath and path then
                        list[#list + 1] = { name = name, path = path }
                        seen[name] = true
                    end
                end
            end
        end
    end
    return list
end

function NAU.FontList() return MediaList(STOCK_FONTS, "font") end

function NAU.FontPath(name)
    for _, entry in ipairs(NAU.FontList()) do
        if entry.name == name then return entry.path end
    end
    return STOCK_FONTS[1].path
end

-- SetFont answers false rather than erroring on a file it cannot use, so the
-- return has to be checked as well as the call.
function NAU.ApplyFont(fs, g)
    local flags = (g.fontOutline ~= "NONE") and g.fontOutline or ""
    local ok, applied = pcall(fs.SetFont, fs, NAU.FontPath(g.font), g.fontSize, flags)
    if not ok or applied == false then
        fs:SetFontObject("GameFontHighlightSmall")
    end
end

--------------------------------------------------------------------------------
-- nugsSuite
--
-- One entry in a plain global table, which the nugsSuite launcher reads to list
-- this addon, open its options and carry its settings between characters.
--
-- Written unconditionally and without checking whether nugsSuite exists: the table
-- is inert on its own, so this costs nothing when the suite is not installed, and
-- being a global rather than a call into it means neither addon has to load first.
--------------------------------------------------------------------------------

-- The groups block starts empty and is filled in per group, so handing over
-- NAU.defaults directly would make every setting of every group read as changed
-- from default and ride along in every export. Rebuilt here instead, with each
-- existing group's defaults spelled out so only real edits are diffed.
local function EffectiveDefaults()
    local eff = CopyDefaults({}, NAU.defaults)
    eff.groups = {}
    if NAU.db then
        for id in pairs(NAU.db.groups) do
            eff.groups[id] = DeepCopy(NAU.groupDefaults)
        end
    end
    return eff
end

local function RegisterWithSuite()
    _G.nugsSuiteRegistry = _G.nugsSuiteRegistry or {}
    _G.nugsSuiteRegistry[ADDON_NAME] = {
        title      = "nugsAuras",
        version    = NAU.version,
        icon       = "Interface\\AddOns\\nugsAuras\\icon",
        slash      = "/na",
        Open       = function() NAU.ToggleOptions() end,
        SetMinimap = function(shown)
            NAU.db.minimapHidden = not shown
            NAU.SetMinimapShown(shown)
        end,
        GetDB      = function() return nugsAurasDB, EffectiveDefaults() end,
        GetCharDB  = function() return nugsAurasCharDB, NAU.charDefaults end,
        -- Where this button sits is nobody else's business.
        exclude    = { minimapAngle = true, seeded = true, warnedAboutSecrets = true },
        -- The catalog is machine-written, per character and class-specific. The
        -- groups are the part of this addon worth sharing; a Paladin's seen-aura
        -- list is noise on a Druid and would bloat every profile string.
        excludeChar = { catalog = true, castToAura = true },
    }
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        NAU.Display:Init()
        if NAU.InitOptions then NAU.InitOptions() end
        RegisterWithSuite()

    elseif event == "PLAYER_LOGIN" then
        if NAU.InitMinimap then NAU.InitMinimap() end
        NAU.Display:Rebuild()
    end
end)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

local function Usage()
    NAU.Print("v" .. NAU.version .. " commands:")
    print("  |cffffd479/na|r - open the options window")
    print("  |cffffd479/na unlock|r / |cffffd479/na lock|r - drag your groups into place")
    print("  |cffffd479/na search <name>|r - find a spell id without needing the aura to be up")
    print("  |cffffd479/na scan [unit]|r - list the auras on a unit with their spell ids")
    print("  |cffffd479/na test|r - fill every group with sample icons")
    print("  |cffffd479/na on|r / |cffffd479/na off|r - master switch")
    print("  |cffffd479/na new|r - add a group")
    print("  |cffffd479/na list|r - list your groups")
    print("  |cffffd479/na reset|r - back to the shipped groups and positions")
    print("  |cffffd479/na minimap|r - show or hide the minimap button")
    print("  |cffffd479/na diag|r - report what the client lets the addon see")
end

SLASH_NUGSAURAS1 = "/na"
SLASH_NUGSAURAS2 = "/nugsauras"
SlashCmdList["NUGSAURAS"] = function(msg)
    local db = NAU.db
    if not db then return end

    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "config" or cmd == "options" then
        NAU.ToggleOptions()

    elseif cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        NAU.Display:Rebuild()
        NAU.Print("tracker " .. (db.enabled and "enabled" or "disabled") .. ".")

    elseif cmd == "lock" then
        NAU.Display:ToggleLock(true)

    elseif cmd == "unlock" then
        NAU.Display:ToggleLock(false)

    elseif cmd == "test" then
        NAU.Display:Test()

    elseif cmd == "new" then
        local id, g = NAU.NewGroup()
        if rest ~= "" then g.name = rest end
        NAU.Display:Rebuild()
        NAU.Print("added group '" .. g.name .. "'. |cffffd479/na unlock|r to place it.")

    elseif cmd == "list" then
        NAU.Print("groups:")
        for i, id in ipairs(db.groupOrder) do
            local g = db.groups[id]
            print(string.format("  %d. %s |cff888888(%s, %s%s)|r%s",
                i, g.name, g.unit,
                g.mineOnly and "mine " or "",
                g.kind == "HARMFUL" and "debuffs" or "buffs",
                g.enabled and "" or " |cffff8080disabled|r"))
        end

    elseif cmd == "reset" then
        for id in pairs(db.groups) do db.groups[id] = nil end
        wipe(db.groupOrder)
        db.nextGroupID = 1
        for _, seed in ipairs(STARTER_GROUPS) do NAU.NewGroup(seed) end
        NAU.Display:Rebuild()
        NAU.Print("groups reset to the shipped pair.")

    elseif cmd == "search" or cmd == "find" then
        if rest == "" then
            NAU.Print("usage: |cffffd479/na search <name or id>|r")
        else
            local found, more = NAU.SearchSpells(rest, 20)
            NAU.Print(string.format("spells matching '%s':", rest))
            for _, a in ipairs(found) do
                -- Secrecy no longer decides whether a spell can be shown - the engine
                -- draws it either way. It only decides whether hide-when-empty can
                -- ask about it, which is all this note claims now.
                local secrecy = NAU.SpellSecrecy(a.spellID)
                local note = (secrecy == "never")
                    and "|cffffd479shown; cannot auto-hide|r"
                    or  "|cff80ff80shown by the game|r"
                print(string.format("  |cffffd479%d|r  %s  %s", a.spellID, a.name, note))
            end
            if #found == 0 then print("  |cff888888(nothing matched)|r") end
            if more > 0 then print("  |cff888888(" .. more .. " more not shown)|r") end
        end

    elseif cmd == "scan" then
        local unit = (rest ~= "" and rest:lower()) or "target"
        local found, skipped, err = NAU.ScanAuras(unit)
        if err then
            NAU.Print(err .. ".")
        else
            NAU.Print(string.format("auras on %s:", unit))
            for _, a in ipairs(found) do
                -- Secrecy no longer decides whether a spell can be shown - the engine
                -- draws it either way. It only decides whether hide-when-empty can
                -- ask about it, which is all this note claims now.
                local secrecy = NAU.SpellSecrecy(a.spellID)
                local note = (secrecy == "never")
                    and "|cffffd479shown; cannot auto-hide|r"
                    or  "|cff80ff80shown by the game|r"
                print(string.format("  |cffffd479%d|r  %s%s|r  %s  %s",
                    a.spellID,
                    a.mine and "|cffffffff" or "|cffaaaaaa", a.name,
                    a.harmful and "|cff888888debuff|r" or "|cff888888buff|r",
                    note))
            end
            if skipped > 0 then
                print(string.format(
                    "  |cffff8080%d more the client would not let me read.|r Scan again out of combat.",
                    skipped))
            end
            if #found == 0 and skipped == 0 then
                print("  |cff888888(nothing up)|r")
            end
        end

    elseif cmd == "minimap" then
        db.minimapHidden = not db.minimapHidden
        NAU.SetMinimapShown(not db.minimapHidden)
        NAU.Print("minimap button " .. (db.minimapHidden and "hidden" or "shown") .. ".")

    elseif cmd == "diag" then
        NAU.Diagnose()

    else
        Usage()
    end

    if NAU.RefreshOptions then NAU.RefreshOptions() end
end

--------------------------------------------------------------------------------
-- Diagnostics
--
-- The one command that answers "why is my group empty". Everything it prints is
-- about what the client is willing to tell the addon, because that is the only
-- thing that ever explains an empty group on this expansion.
--------------------------------------------------------------------------------

local function YesNo(v)
    if v == nil then return "|cff888888unknown|r" end
    return v and "|cff80ff80yes|r" or "|cffff8080no|r"
end

function NAU.Diagnose()
    NAU.Print("v" .. NAU.version .. " diagnostics")
    NAU.Display:RefreshAuraMaps()

    print("  secret values exist: " .. YesNo(NAU.secretsExist))
    print("  auras secret right now: " .. YesNo(NAU.AurasAreSecret()))
    print("  display engine: " .. (NAU.Display.engine or "none"))

    -- Loud and first, because sample icons and real auras look identical on screen
    -- and every other number below is meaningless while these are on.
    if NAU.Display:IsPreviewing() or NAU.Display:IsTesting() then
        print("  |cffff8080SHOWING SAMPLE ICONS, NOT REAL AURAS.|r "
            .. (NAU.Display:IsPreviewing()
                and "Close the options window to see what is really being tracked."
                or "Run |cffffd479/na test|r again to turn the demo off."))
    end

    local u = C_UnitAuras or {}
    print("  AuraContainer frame type: " .. YesNo(NAU.Display.hasEngine))

    -- The bridge is only as good as the Cooldown Manager being switched on, and a
    -- hidden one silently stops updating, so its state is reported rather than
    -- assumed.
    local anyViewer = false
    for _, name in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer",
                            "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
        local viewer = _G[name]
        if viewer and viewer:IsShown() then anyViewer = true end
    end
    -- Which category tokens this client will actually accept in a filter string.
    -- Asked rather than assumed: the engine's grammar is narrower than the one these
    -- were written against, and an unrecognised token does NOT error - the group just
    -- never matches anything, which is indistinguishable from a broken addon.
    if AuraUtil and AuraUtil.IsValidFilterString then
        local good, bad = {}, {}
        for _, entry in ipairs(NAU.TOKENS or {}) do
            local kind = "HELPFUL"
            local ok, valid = pcall(AuraUtil.IsValidFilterString, kind .. "|" .. entry.key)
            if ok and valid then good[#good + 1] = entry.key
            else bad[#bad + 1] = entry.key end
        end
        if #bad > 0 then
            print("  |cffff8080categories this client REJECTS: " .. table.concat(bad, ", ") .. "|r")
        end
        if #good > 0 then
            print("  |cff80ff80categories accepted: " .. table.concat(good, ", ") .. "|r")
        end
    end

    print("  Cooldown Manager visible: " .. YesNo(anyViewer)
        .. (anyViewer and "" or "  |cff888888(bridge is asleep - spells that rely on it will not show)|r"))
    print("  GetUnitAuras: " .. YesNo(u.GetUnitAuras ~= nil)
        .. "   GetAuraDuration: " .. YesNo(u.GetAuraDuration ~= nil)
        .. "   stack display: " .. YesNo(u.GetAuraApplicationDisplayCount ~= nil))
    print("  by spell id: " .. YesNo(u.GetUnitAuraBySpellID ~= nil)
        .. "   by instance: " .. YesNo(u.GetAuraDataByAuraInstanceID ~= nil)
        .. "   instance ids: " .. YesNo(u.GetUnitAuraInstanceIDs ~= nil))

    print("  groups: " .. #NAU.db.groupOrder)
    for i, id in ipairs(NAU.db.groupOrder) do
        local g = NAU.db.groups[id]
        local shown = NAU.Display:ShownCount(id)
        local wanted = NAU.BuildFilter(g)
        -- Both filters, and loudly when they differ. The engine's grammar is narrower
        -- than the one these tokens were written for, and a token it does not know is
        -- not an error - it simply never matches, leaving a group that looks broken
        -- for no visible reason. Reporting only the intended filter hides exactly the
        -- case worth reporting.
        local effective = g._filter
        local filterText = wanted
        if effective and effective ~= wanted then
            filterText = string.format("%s |cffff8080(engine got: %s)|r", wanted, effective)
        end
        -- "frames built", not "icons". The engine pre-creates frames in batches, so
        -- this is pool capacity rather than matched auras - it read as the latter for
        -- several builds and sent the diagnosis in the wrong direction every time.
        print(string.format("   %d. %s |cff888888[%s]|r %s -> %s frame(s) built%s",
            i, g.name, g.unit, filterText, tostring(shown),
            g.enabled and "" or " |cffff8080disabled|r"))
        -- Which of the three routes actually produced those icons. Without this,
        -- "the spell list is set but I am seeing everything" has no explanation.
        print(string.format("      those icons came from: %s%s|r",
            NAU.Display:ShowingSamples(id) and "|cffff8080" or "|cff8cd2ff",
            g._path or "nothing yet"))

        -- The two ways an engine group shows nothing look identical on screen and
        -- have nothing in common underneath, so they are separated here.
        --
        --   0 frames built  -> nothing matched the filter. A filter or unit problem.
        --   frames built    -> the engine wanted icons and we drew them invisibly.
        --                      A binding or styling problem, on our side.
        if next(NAU.bindReport or {}) then
            local bad = {}
            for name, result in pairs(NAU.bindReport) do
                if result ~= "ok" then bad[#bad + 1] = name .. " " .. result end
            end
            if #bad > 0 then
                print("      |cffff8080aura bindings failed: " .. table.concat(bad, ", ") .. "|r")
            else
                print("      |cff8cd2ffaura bindings: all ok|r")
            end
        end

        -- The group's own configuration calls. These were bare pcalls whose results
        -- went nowhere, so a group could be built and filled and never laid out with
        -- nothing reporting it.
        if next(NAU.groupReport or {}) then
            local gbad = {}
            for name, result in pairs(NAU.groupReport) do
                -- Anything beginning "ok" counts as success. An exact match against
                -- "ok" reported "SetUnit ok (target)" as a failure, which is a
                -- diagnostic telling you the opposite of what it measured.
                if tostring(result):sub(1, 2) ~= "ok" then
                    gbad[#gbad + 1] = name .. " " .. tostring(result)
                end
            end
            print(#gbad > 0
                and ("      |cffff8080group setup failed: " .. table.concat(gbad, ", ") .. "|r")
                or  "      |cff8cd2ffgroup setup: all ok|r")

            -- When the sort call is the one complaining, the enum it wants is printed
            -- rather than guessed at again. Its field names are not documented, and
            -- one round of guessing them has already cost a build.
            if NAU.groupReport.SetAuraGroupSortMethod ~= "ok"
               and type(AuraContainerSortDirection) == "table" then
                local names = {}
                for k, v in pairs(AuraContainerSortDirection) do
                    names[#names + 1] = tostring(k) .. "=" .. tostring(v)
                end
                table.sort(names)
                print("      |cff888888AuraContainerSortDirection: "
                      .. (next(names) and table.concat(names, " ") or "empty") .. "|r")
            end
        end

        -- Where everything actually is. Reached only when the engine says it built
        -- frames, since that is the case where the screen and the addon disagree.
        -- The missing-icons path, when this group uses it. Each counter separates a
        -- different reason the icons might be stuck: never refreshed, the read
        -- refused, or the alpha sink refusing the value.
        if g.spellMode == "missing" and NAU.missReport then
            local R = NAU.missReport
            print(string.format(
                "      missing icons: %d refresh(es), IsShown %d ok / %d threw, alpha %d ok / %d threw",
                R.runs, R.isShownOK, R.isShownThrew, R.sinkOK, R.sinkThrew))
            print(string.format("      last refresh was in combat: %s%s",
                tostring(R.lastInCombat),
                R.lastErr and ("  |cffff8080" .. R.lastErr .. "|r") or ""))
        end

        -- What hide-when-empty last decided, and on what. "unknown" means the client
        -- was not answering, which must never hide the group.
        if g.hideWhenEmpty and NAU.Display.LastAnyUp then
            print("      hide-when-empty last saw: " .. tostring(NAU.Display:LastAnyUp(id)))
        end

        if NAU.SlotReport then
            for _, line in ipairs(NAU.SlotReport(id) or {}) do print("      " .. line) end
        end

        if NAU.GeometryReport then
            local lines = NAU.GeometryReport(id)
            if type(lines) == "table" then
                for _, line in ipairs(lines) do print("      " .. line) end
            else
                print("      " .. tostring(lines))
            end
        end
        if g.spellMode ~= "off" then
            -- Per spell, because the answer differs per spell: Blizzard declassified
            -- a specific list, and a group can easily be half readable. Reporting
            -- one verdict for the whole group would be a lie in the common case.
            local readable, total = 0, 0
            for _, spellID in ipairs(g.spellOrder or {}) do
                if g.spells[spellID] then
                    total = total + 1
                    if NAU.SpellIsReadable(spellID) ~= false then readable = readable + 1 end
                end
            end
            -- "Readable" no longer has anything to do with whether these display -
            -- the engine draws them regardless. It governs one thing, so it is
            -- labelled as that one thing. The old line said a group with nothing
            -- readable "is showing its token filter instead", which stopped being
            -- true at the rewrite and reads as an error about a working group.
            print(string.format("      spell list: %s, %d spell(s) (%d can answer auto-hide)",
                g.spellMode, total, readable))
            -- What is genuinely on the unit right now, so each listed id can be
            -- checked against reality rather than against our assumptions. This is
            -- what catches a *cast* id entered where the aura carries another one,
            -- which is the most common way a spell list ends up showing nothing.
            -- Can this unit be asked about a NAMED spell right now?
            --
            -- This is the question a "missing auras" display rests on. Absence cannot
            -- be shown by the engine - it draws auras that exist and has no binding
            -- for one that does not - so it has to come from a by-id read coming back
            -- empty. That read survives combat on the player, measured. On a target
            -- it is unmeasured, and if it is refused mid-fight then every dot would
            -- read as missing the moment a pull starts.
            --
            -- The catch is that "refused" and "genuinely absent" are the same nil, so
            -- no single reading settles it. Run this with a dot definitely ticking,
            -- once out of combat and once in, and compare the two lines.
            local UA = C_UnitAuras or {}
            if UA.GetUnitAuraBySpellID then
                local present, absent, threw = 0, 0, 0
                for _, spellID in ipairs(g.spellOrder or {}) do
                    if g.spells[spellID] then
                        local ok, aura = pcall(UA.GetUnitAuraBySpellID, g.unit, spellID)
                        if not ok then threw = threw + 1
                        elseif aura then present = present + 1
                        else absent = absent + 1 end
                    end
                end
                print(string.format(
                    "      by-id read on %s: %d present, %d absent, %d threw  |cff888888(in combat: %s)|r",
                    g.unit, present, absent, threw, tostring(InCombatLockdown() and true or false)))
            end

            local liveMap = NAU.AuraMapBySpellID(g, g.unit)
            local matched, unmatched = 0, {}

            for _, spellID in ipairs(g.spellOrder or {}) do
                if g.spells[spellID] then
                    local secrecy = NAU.SpellSecrecy(spellID)
                    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
                    -- Every listed spell displays, whatever its secrecy: the engine
                    -- draws it and the addon never reads the aura. The only thing
                    -- readability still governs is whether hide-when-empty can ask
                    -- about this spell, so that is all this column reports now.
                    --
                    -- It used to print "never readable" and "via Cooldown Manager",
                    -- which described a route this addon no longer takes and read as
                    -- "this spell will not work" about spells that work fine.
                    local how = (secrecy == "never")
                        and "|cffffd479shown; cannot auto-hide|r"
                        or  "|cff80ff80shown by the game|r"

                    -- How many ids this spell is actually being matched on. The
                    -- engine matches the AURA's id, which is frequently not the one
                    -- typed in, so the list is expanded by name before being handed
                    -- over. Showing the count makes that verifiable instead of
                    -- something to take on trust - and a spell expanding to exactly
                    -- one id is the case most likely to silently match nothing.
                    if NAU.RelatedSpellIDs then
                        local related = NAU.RelatedSpellIDs(spellID)
                        local ids, n = {}, 0
                        for rid in pairs(related or {}) do
                            n = n + 1
                            if n <= 4 then ids[#ids + 1] = tostring(rid) end
                        end
                        if n > 1 then
                            how = how .. string.format(" |cff888888[%d ids: %s%s]|r",
                                n, table.concat(ids, ","), n > 4 and ",..." or "")
                        else
                            how = how .. " |cff888888[1 id only]|r"
                        end
                    end

                    -- The lookup uses the aura this id resolves to, but the line
                    -- still reports the id that was entered - that is the one the
                    -- player recognises and would go looking for in the list.
                    local auraID, auraName = NAU.ResolvedNote(spellID)
                    local lookupID = auraID or spellID
                    if auraID then
                        name = (name or "?") .. " |cff8cd2ff-> "
                            .. (auraName or ("aura " .. auraID)) .. "|r"
                    end

                    local live = ""
                    if liveMap then
                        if NAU.MatchListedSpell(liveMap, spellID) then
                            live = "  |cff80ff80on " .. g.unit .. " now|r"
                            matched = matched + 1
                        else
                            live = "  |cff888888not on " .. g.unit .. "|r"
                            unmatched[#unmatched + 1] = spellID
                        end
                    end

                    print(string.format("        |cffffd479%d|r %s - %s%s",
                        spellID, name or "?", how, live))
                end
            end

            if g._viaScan or g._viaDirect or g._viaBridge or g._viaEstimate then
                print(string.format("      matched now: %d by reading the unit, %d direct, %d via Cooldown Manager, %d estimated from your casts",
                    g._viaScan or 0, g._viaDirect or 0, g._viaBridge or 0, g._viaEstimate or 0))
            end

            -- The specific, actionable warning. If the unit visibly has auras and
            -- none of the listed ids are among them, the ids are for something
            -- other than the auras that are up - almost always the cast spell.
            if liveMap and matched == 0 and #unmatched > 0 then
                local anyLive = false
                for _ in pairs(liveMap.byID) do anyLive = true break end
                if anyLive then
                    print("      |cffff8080None of these ids match anything on " .. g.unit
                        .. " right now.|r If the aura IS up, these are probably")
                    print("      |cffff8080cast spell ids and the aura carries a different one.|r Use "
                        .. "|cffffd479/na scan " .. g.unit .. "|r to read the real ones.")
                end
            end
        end
    end
end
