# Changelog

## 0.7.8

- **The font setting is a list you scroll, not a button you click through.** It was
  cycling one font per press, which is fine for four options and unusable for the
  hundred a LibSharedMedia user has - there was no way to see what was available.
  Every name is drawn in its own face, and one that will not load says so rather
  than being offered and then not drawing.

## 0.7.7

**New spell-list mode: "Always show these".**

Every listed spell keeps its own position, permanently. While it is not on the unit
it shows as a tinted placeholder; the moment it lands the game draws it properly,
with swipe, timer and stacks like any other group. Point one at your target, list
your dots, and what is dull is what you still owe - the row never moves, so you read
it by brightness rather than by counting icons.

- Placeholder greying, tint and border are all per group. It wants to be obviously
  different from the live icon that replaces it, since that contrast is the feature.
- Categories are ignored in this mode, as they are in "Only these" - the list is the
  whole filter.

This started out trying to make an icon *disappear* once its aura landed, which is
not something an addon can do during a fight. Knowing whether the game has drawn
something means asking it, and every route to that answer is refused in combat: the
engine's own button, and a widget of ours the engine has marked, both raise
"attempt to access forbidden object". Covering one icon with another is the only
inversion that survives - so the mode was rebuilt around it rather than against it,
and is better for it.

## 0.6.34

- `/na diag` reports whether a named spell can be READ off the group's unit right
  now, and whether you are in combat. Groundwork for a "missing auras" display:
  absence cannot come from the aura engine, only from a read coming back empty, and
  whether that read is served on a target mid-fight has never been measured.

## 0.6.33

- **New: "Swipe the other way".** The cooldown swipe ran only one way round - the
  dark wedge covering what was left and shrinking away, so the icon got brighter as
  the aura expired. It can now be inverted, so the icon starts clear and darkens as
  time is spent, which is how most cooldown displays read. Per group, off by default
  so nothing already set up changes.

## 0.6.32

- Grouped under a **nugsAddons** category in the game's AddOns list, so the whole
  set folds up together instead of scattering through the alphabet.

## 0.6.31

**Rebuilt on patch 12.1's aura engine. This version requires 12.1.**

12.1 refuses to **enumerate** auras while an addon is tainted — which every addon is,
always — in ordinary open-world combat, not just in raids and Mythic+. Every way of
asking "what is on this unit" throws. An addon that wrapped those reads in `pcall`
would not error; it would quietly draw nothing, which looks exactly like having no
auras up.

That is precisely how this addon worked. Category and token groups have no list of
spells to ask about, so they can only be built by enumerating, and enumerating is
gone.

So nugsAuras stopped reading auras. It now hands Blizzard's `AuraContainer` a filter
and a list of allowed spells and supplies the widgets the engine pushes data into. The
aura never enters Lua, so secrecy no longer applies — **and the icons keep updating
through a pull**, which is the entire point.

(Asking about **one spell you name** does still work in combat, and this release uses
that in exactly one place: deciding whether a spell-list group is empty. It is not
used to draw anything.)

- **Ordered spell lists keep their fixed positions.** Each listed spell gets its own
  slot, so an inactive one leaves a gap instead of shuffling the rest along.
- **Unordered groups are laid out by the engine** and compact themselves as auras come
  and go.
- **Removed: estimate-from-casts, and the `~` marker that went with it.** Dead
  reckoning from your own casts existed only because auras could not be read in a
  fight. That problem is properly solved, and a guess running alongside real data is
  worse than no guess at all.
- **Removed: "if nothing can read them, show the categories instead".** There is no
  blind state left to fall back from.
- **Removed: "colour it by dispel type".** The engine draws the icon now and offers
  bindings for icon, cooldown, timer, stacks and name - dispel type is not among them.
  Removed outright rather than left as a switch that does nothing.
- **Growth direction and per-row do not currently apply to unordered groups**, which
  the engine lays out itself. They still work exactly as before on ordered spell
  lists, where every icon is placed by the addon. The engine's layout does expose
  wrapping and element dimensions, so this is a gap to close rather than a permanent
  loss — it just is not wired up yet.
- **Hide-when-empty now works on spell lists**, and is shown as unavailable elsewhere
  rather than quietly doing nothing. The icons belong to the game and cannot be
  counted — asking an engine-owned button whether it is shown is an error rather than
  an answer — so emptiness is established the other way round, by asking the game
  about the spells you listed. A category group has no listed spells to ask about,
  which is exactly why the option is offered for `Only these` and not for the rest.
  If the question cannot be answered the group stays visible: an empty anchor is a
  cosmetic annoyance, a hidden group that actually has auras in it looks broken.

## 0.5.6

- **Groups can no longer be placed during combat**, which matches the rule that a pull
  locks them in the first place. Unlocking puts every drag box and its sample icons on
  screen at once, and sample icons during a real pull cannot be told apart from the
  real thing. It is now refused with a line of chat rather than half-entered.

## 0.5.5

- **Fixed: "action blocked" errors during combat.** `SetPropagateKeyboardInput` - used
  so that Escape closes a dropdown or the placement bar rather than the window behind
  it - is protected during a fight. Calling it then raises ADDON_ACTION_BLOCKED naming
  this addon, and unlike a Lua error it cannot be caught: it taints the addon for the
  rest of the session. 4 call sites now skip themselves in combat.
- The worst of them was the key handler: it guarded the Escape branch but not the
  branch every *other* key took, so with a list open in combat any keypress would have
  thrown it - movement keys included.

## 0.5.4

- Internal hardening, no visible change. The scroll helper's fallback width guard could
  copy a zero width onto a list's content frame during the first layout pass, and once
  copied nothing would correct it - rows would draw but not be clickable. Every list here
  sets its own content width afterwards, so this was never reachable; the guard now waits
  for the scroll frame to have a real width, so it stays a safe backstop.

## 0.5.3

- **The settings window gets out of the way while you place your aura groups.** Unlocking
  hides it and puts up a small bar instead - Lock groups and Sample icons - and locking brings the
  window back exactly where it was. Placing things meant dragging boxes the window was
  usually sitting on top of, so it had to be shoved aside and dragged back every time.
- The bar can be dragged if it is in the way, and Escape locks rather than just
  dismissing it - hiding it while things were still unlocked would have left nothing on
  screen to end that state.
- `/na unlock` puts the bar up too. If the settings window was not open when you
  unlocked, locking does not conjure one.
- **The settings window closes when a fight starts, and the anchors lock.** Not because
  anything here would be blocked - none of these windows touch a secure frame, so
  nothing throws "action blocked" the way an addon driving action bars does. The
  reason is that both states put fake data on screen: with the window open, every group fills with sample icons, and sample
  data during a real pull cannot be told apart from the real thing. Nothing reopens
  when combat drops.

## 0.5.2

- **The scroll bar can be grabbed and dragged.** It was drawn as a texture, and a
  texture cannot take mouse input at all - so it showed you where you were in a list
  and gave you no way to act on it, leaving the wheel as the only way down a long one.
  It is a real bar now: drag the thumb, or click the track to page toward the click.

## 0.5.1

**"Only these" reverted to showing everything a few seconds after it started
working.** One counter, wrong.

The spell list tracked how many lookups *found something* and treated zero as
"this group could not be resolved, fall back to the categories". So the moment the
last tracked aura expired — five to ten seconds in, which is how long the dots
last — the group stopped meaning "only these" and started meaning "everything".

An empty result is a real answer. It means none of your spells are up, and the
right thing to draw is nothing. The counter now measures whether any route was
*able to answer*, not whether it happened to find one.

Falling back to the categories is now **off by default**, and a per-group toggle.

That reverses the choice made when this was designed, where the reasoning was that
showing something beats showing nothing. Watching it in practice says otherwise: a
group set to "only these" that silently fills with every debuff reads as the addon
ignoring its own settings, and there is no way to tell it apart from being broken.
An empty group is at least honest. The old behaviour is one checkbox away, and it
now only applies when a group is genuinely blind — auras secret, no Cooldown
Manager, and estimates off.

## 0.5.0

Add spells by name, and stop caring which of the two ids you happened to have.

**The bug that kept "only these" broken.** Estimates were keyed on the id in your
list, but casting an ability reports the *ability's* id. If the id you listed was
the debuff's — which is what a tooltip shows you — the cast never matched it and no
estimate ever started. Casts are now matched **by name** as well as by id, so a list
holding either number works.

- **Type a name into the add box.** `Execution Sentence` is a thing people know;
  `1260251` is not. An id still works, and a name matching several spells shows them
  rather than guessing.
- **Every match is by name as well as id**, in one shared function so the two
  cannot drift apart: whether a listed spell is on the unit, which aura instance to
  draw, and which cast starts an estimate.
- **The addon learns which aura an ability applies.** Names bridge most of them,
  but not all — Wake of Ashes applies Truth's Wake and nothing but observation
  connects those. When you cast a tracked spell while auras are readable, the
  unit's auras are compared before and after and anything new is recorded as the
  pairing. It happens by itself while you are on a dummy, and holds after that.

### On ElvUI

For the record, since it came up: ElvUI's aura whitelist and blacklist **also stop
filtering in combat** — `Auras.lua:763` skips the list entirely when the spell id is
secret. Its by-name UI is backed by hand-curated spell-id lists its authors
maintain (ClassDebuffs, ImportantCC, CCDebuffs, TurtleBuffs), with names resolved
out of combat. It is a maintained dataset, not a capability this addon was missing.

## 0.4.0

Spell lists that just work, without the Cooldown Manager and without hunting for
the right id.

Two things were making this hard, and both are gone.

- **The id you have is almost never the id of the aura.** 343527 casts Execution
  Sentence; the debuff on the target is something else. Every list built from the
  spellbook, the Cooldown Manager or a website hits this, and the failure looks
  exactly like "the aura is not up".
  Listed ids are now **resolved to the aura automatically**: the addon looks for a
  recorded aura with the same name and tracks that instead. Paste the ability's id
  and it starts working on its own. The Spells tab shows what an id resolved to
  when the two differ.
- **Nothing could see a secret aura in combat unless Blizzard's Cooldown Manager
  was switched on and visible** — which is a poor thing to demand.
  Your own casts are never secret: the rule is that cast data goes secret only "if
  the unit being queried is not the player or their pet". So when nothing can read
  the aura, the icon is now **estimated from the fact that we watched you cast it**,
  counted down against a length learned out of combat. No Cooldown Manager, no aura
  read, works in combat, in raids and in keys.
  - Marked with a `~` on the timer, the way the cast bars mark a remembered length.
    It is dead reckoning: it cannot know about a dispel, an early death, or the
    target dying. It is dropped when you swap targets rather than following you,
    because an icon that follows would read as "still up".
  - A length is learned the first time the aura is seen while readable — which the
    catalog does by itself in the seconds after combat drops. Until then the icon
    shows with no countdown rather than a made-up one.
  - Per group, on by default, under the spell list.

Also:

- Durations are recorded into the seen-aura catalog, which is what the estimates
  count down against.
- `/na diag` breaks down how each group's icons were obtained, estimates included.

## 0.3.1

Three fixes for "the spell list is set and it is still showing everything".

- **The spell list now matches against what is actually on the unit.** Previously
  it only asked the client about each id in turn, which answers about the id you
  passed in — so an id that is *nearly* right, a cast spell where the aura carries
  a different one, came back nil and looked identical to "the aura is not up".
  When auras are readable the list is now resolved by reading the unit's auras and
  comparing, which cannot make that mistake and is what makes the mismatch
  visible.
- **`/na diag` says when it is showing sample icons.** The display fills every
  group with placeholders while the options window is open or `/na test` is on, and
  five placeholders look exactly like five real debuffs. The diagnostic reported
  the count without ever mentioning it was demo data. It now says so first and in
  red, and reports which of the three routes produced each group's icons.
- **Listed spells are marked against reality.** Both the Spells tab and `/na diag`
  now show *on target now* or *not on target* per id. If none of a group's ids
  match anything while the unit visibly has auras, the diagnostic says outright
  that they are probably cast ids and points at `/na scan`.

Also: `/na diag` lists whether each aura API is present, including the by-spell-id
lookup that the spell path depends on.

## 0.3.0

Getting a spell id without needing the aura to be up.

Scanning a live unit had a hole that could not be closed: the debuff you want
exists in combat, and auras can only be read out of combat. Wait for the aura and
you cannot read it; wait until you can read it and it has fallen off. So finding a
spell id no longer goes through auras at all.

- **Search by name** in the Spells tab, and `/na search <name or id>`. Reads
  *spell* data rather than aura data — never secret — so it works in combat and
  whether or not the aura is anywhere near you. Draws on three sources, best first:
  - **the Cooldown Manager's tracked set** for your spec, which is both the most
    useful shortlist and exactly the spells the bridge can follow in combat;
  - **everything this character has seen before** (below);
  - **your spellbook**, minus passives and off-spec.
  Results are tagged with where they came from, and carry the same combat-readable
  mark as the list itself.
- **A seen-aura catalog that fills in by itself.** Whenever the client is willing
  to name auras, whatever is on you, your target and your focus is recorded to a
  per-character list. This is aimed squarely at the case scanning could not reach:
  your dots keep ticking for a few seconds after combat drops, and the recorder
  catches them in that window without anybody having to time a button press.
  Browse it with **Seen before**. It is excluded from suite profile strings, being
  machine-written and class-specific.
- **Scan** is still there — search needs you to know roughly what the thing is
  called, and a scan tells you what is on that boss right now.

Fixes found while building the above:

- `NAU.TrackedSpells` closed over `trackedSpells` and `BuildTrackedSet` before
  either was declared, so both resolved to nil globals and the tracked source
  would have come back empty. Forward-declared.
- The edit box helper owned `OnTextChanged` for its placeholder, so the search
  box's own handler silently replaced it. Changed handling is now a parameter,
  and the two are chained rather than racing.

## 0.2.0

Finding a spell id, and tracking one in combat.

- **`/na scan [unit]`, and Scan buttons in the Spells tab.** Lists every aura on the
  unit with its real spell id, icon and whether it will work in combat, and adds it
  to the group with one click. Out of combat nothing is secret, so this is the
  reliable way to get an id — the number shown for an ability on a website or in a
  tooltip addon is often the *cast*, and the aura it applies carries a different one.
- **The Cooldown Manager bridge.** Blizzard's Cooldown Manager is not an addon, so
  it may read the aura data we may not, and it leaves a plain `cooldownID` and a
  plain `auraInstanceID` on its item frames. Reading those recovers the
  spell-to-aura mapping the secret system withholds, **without calling a restricted
  API at all** — so a spell the manager tracks can now be followed in combat even
  though its own lookup goes quiet. Such spells are marked *via Cooldown Manager*.
  - Only covers spells the manager tracks for your current spec.
  - `CooldownViewerMixin:OnHide` unregisters `UNIT_AURA`, so a **hidden** Cooldown
    Manager stops updating and the bridge goes stale. `/na diag` reports whether it
    is visible, because a silently-asleep bridge looks exactly like a spell that is
    simply not up.
- Listed spells are now resolved one at a time rather than all-or-nothing, so a
  list that is part declassified and part Cooldown-Manager-tracked works throughout
  instead of falling back wholesale.
- `/na diag` reports how many icons each group is getting from each path.
- The tracked-spell set is cached and invalidated on spec, talent and hotfix
  events. Rebuilding it per row per refresh was the slowest thing in the addon.

## 0.1.1

- A single line in the options window - "Part of the nugs suite" - shown only when
  nugsSuite is not installed. A note, not a warning, and not a dependency: this
  addon works exactly the same on its own, and the suite is only worth having once
  you run more than one of them.
- Listed in nugsSuite's roster, so it can be launched from the suite's minimap
  button and its settings travel in a suite profile string.

## 0.1.0

First build.

- **Groups are the unit of everything.** Each one owns its anchor, growth
  direction, size, filter and look, so two groups can be completely different. A
  group of one is a single icon placed anywhere on screen.
- **Nine units** — you, target, focus, pet and boss 1-5.
- **Category filters** built on the client's own aura filter tokens, so they keep
  working in combat, in raids and in keys: crowd control, major and external
  defensives, raid-frame relevance, dispellable-by-me, and cancellable.
- **Spell lists** drive a group directly, one lookup per spell, in the order you
  set. Each entry is marked with whether the client will actually let it be read,
  and a group whose spells are all unreadable falls back to its categories.
- **Sorting is done by the client** — mine first, time remaining, name — because
  comparing two expiry times is an operation addons are no longer allowed to
  perform.
- Icons carry a cooldown swipe, timer text, stack count and an optional border
  coloured by dispel type.
- `/na diag` reports what the client is currently willing to tell the addon, per
  group and per listed spell.
- Registers with nugsSuite for settings export and minimap consolidation.

Written against retail 12.0.7 (build 68887). Two notes on that, since both cost
time to discover and neither is guessable from older documentation:

- The `AuraContainer` frame type, which draws floating aura icons for you, does
  **not** exist on 12.0.7 — it arrives in 12.1. The display here is hand-rolled and
  probes for the engine, so a later version can hand over rather than be rewritten.
- The `IMPORTANT` and `STEALABLE` filters and the `!` negation prefix are all
  absent on this build. `IMPORTANT` existed in 12.0.1 and returns in 12.1;
  `STEALABLE` was never a filter. Only the thirteen tokens the client actually
  ships are offered, and exclusion appears only for `CANCELABLE`, which is the one
  with a `NOT_` partner.
