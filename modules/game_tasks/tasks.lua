-- Faqir's Tasks window - a third front door onto the same data/lib/tasks.lua
-- module !task and the Faqir NPC already use. Nothing here invents new
-- server logic; every button is meant to call the exact same Tasks.*
-- functions those two already call.
--
-- PHASE A: window + tabs. Offers and Active task render REAL data, pushed by
-- Player.sendTaskState (data/lib/core/player.lua) over opcode 72 - on login,
-- after any accept/drop/reroll/shuffle/choose, and per-kill for the active
-- task's progress.
-- PHASE B: Accept/Reroll/Shuffle (Offers) and Drop (Active task) send opcode
-- 73, resolved server-side through the exact same Tasks.acceptTask/
-- rerollOffer/shuffleOffers/dropTask that !task calls.
-- PHASE C: Catalog (search + hand-pick, opcode 74) and Progress (streak/
-- weekly/season pass/rankings, opcode 75) are pushed ON-DEMAND when their
-- tab is opened/typed in, not always-on like Offers/Active. Hunt tab is
-- still a static placeholder.
-- PHASE D (payload v2): on first window open per connection the client sends
-- a "hello:v2" handshake over opcode 73; a v2 server answers every later
-- opcode 72 push for that session in the v2 shape (leading "v2|"). This file
-- parses BOTH shapes forever, and every v2-only widget (multi-slot actives,
-- Marks tab, wallet readout, unlock-slots button) hides itself whenever only
-- v1 data is available - deploy order between client and server never
-- matters, in either direction.

tasksWindow = nil
tasksButton = nil
local tasksTabBar = nil
local tabPanels = {}
-- File-scope so refreshCurrentTab() (called from toggle()) can tell which tab
-- is showing without re-deriving it from the tab bar's children.
local catalogTab = nil
local progressTab = nil
local oddsTab = nil
-- Marks tab (Faqir's Dagger) is CREATED LAZILY on the first v2 state push -
-- a v1 session never has dagger/contract data, so it never sees the tab at
-- all rather than seeing a permanently-empty one.
local marksTab = nil
local marksTabDefaultColor = nil
-- Slow red pulse on the Marks tab label while daggers exist (Mizo's
-- "could pulse/highlight"). One event at a time; stopped whenever the
-- dagger count hits zero and in terminate() before the tab widget dies.
local marksTabPulseEvent = nil

-- Last parsed opcode 72 state (v1 or v2, normalised into one table) - kept so
-- tab switches can re-render gates/greys without waiting for the next push.
local lastState = nil
-- Set of task ids currently being hunted - drives the Offers [ACTIVE] rows,
-- the catalog greying and accept gating, refreshed on every state push.
local currentActiveIds = {}
-- One v2 handshake per connection: sent on first window open, reset in
-- offline(). Sent from toggle() rather than onGameStart so a server that
-- logs opcodes at login isn't spammed by players who never open the window.
local v2HelloSent = false

-- Real numbers from data/lib/tasks.lua (2026-07-27 reroll retier). These are
-- server-wide constants (not per-player), so showing them directly here -
-- rather than waiting on a push - is accurate from the moment the window opens.
-- Last hand-pick cost the server told us (opcode 74) - level-scaled, so it's
-- pushed rather than derived here. Used by the hand-pick confirm dialog so it
-- can state the real price instead of pointing at the tab header.
local lastChooseCost = 0

-- Comfortably above handleTaskAction's 300ms server throttle, so a burst of
-- keystrokes collapses into ONE search that is never the one thrown away.
local CATALOG_SEARCH_DEBOUNCE_MS = 350
local catalogSearchEvent = nil

local REROLL_COST_BY_TIER = { [1] = 20000, [2] = 40000, [3] = 60000, [4] = 80000, [5] = 100000 }

-- Which active task ids have already played their full "just accepted"
-- sequence (blink-then-move) in the Offers tab - guards against replaying it
-- on the per-kill state pushes that follow while those tasks are running.
-- Sets keyed by task id rather than single ids: payload v2 allows up to
-- three actives at once, each with its own animation lifecycle.
local flashedActiveIds = {}
-- Active task ids whose blink-then-move is IN PROGRESS. A kill can land (and
-- push a fresh opcode 72 state) mid-blink, before the deferred move has fired
-- - without this guard that re-entrant fillOffers call would see the row not
-- yet at top and try to move it AGAIN mid-animation. While pending, fillOffers
-- skips both re-flashing and re-moving; the row's text/colour still update
-- normally every push, only the position is held.
local pendingMoveIds = {}

-- Last known progress per active task id (Mizo 2026-08-04 - "make it feel
-- alive") - fillActive rebuilds every ActiveTaskCard from scratch on each
-- push, so there's no persistent widget to diff against; this table is what
-- lets a fresh card know whether ITS number just went up since last time.
local lastKillCounts = {}

-- Brief flash on a kill-count update - same step-blink SHAPE as
-- flashActiveOffer below (color, not border: this is a number ticking up,
-- not a row that moved), 2 blinks rather than 3 since this fires far more
-- often (every kill vs. once per accept) and needs to stay unobtrusive.
-- Color pass (Mizo 2026-08-04): the window's chrome (#171209/#5c4a24) stayed
-- consistent across all 6 tabs, but everything built on top of it drifted -
-- 4 golds, 3 whites, 4 muted greys, 2 reds, 3 greens all doing the same job
-- with slightly different hex, accumulated one isolated edit at a time. This
-- collapses each family to one value (still spread across each constant's
-- own point of use rather than one central table, to match how this file
-- already organizes color constants - only the VALUES changed, not the
-- pattern). KILL_FLASH_COLOR stays separate - a transient flash genuinely
-- warrants a brighter, more attention-grabbing tone than the resting green.
local KILL_FLASH_COLOR = '#a6e08c'
local KILL_FLASH_NORMAL = '#F0E6D2'
local function flashKillCount(label)
  removeEvent(label.killFlashEvent)
  local total = 2 * 2
  local function step(n)
    if n > total then
      label:setColor(KILL_FLASH_NORMAL)
      return
    end
    label:setColor(n % 2 == 1 and KILL_FLASH_COLOR or KILL_FLASH_NORMAL)
    label.killFlashEvent = scheduleEvent(function() step(n + 1) end, 150)
  end
  step(1)
end

-- Sixth attempt at this indicator (Mizo 2026-07-30 x6):
--   1. a 1px border flash alone - too subtle, easy to miss.
--   2. a blinking "^ MOVED UP" text badge alone - ugly ASCII chrome.
--   3. prey_star.png alone, fading in/hold/out - too brief, too small.
--   4. star + border glow together - landed, then a slide-to-top travel
--      effect was requested, built, and then explicitly removed again.
--   5. "^ MOVED UP" badge back, blinking in sync with the border.
-- This version drops the separate corner badge entirely: the Accept button
-- itself (already repurposed into the live kill counter for the active row -
-- see fillOffers) shows "^ MOVED UP" for the WHOLE blink duration instead,
-- then switches to the real counter the instant the blink ends (not waiting
-- for the next kill to land, which could otherwise leave stale text sitting
-- there for a while). Border still reverts to normal explicitly at the end.
local FLASH_BLINKS = 3
local FLASH_STEP_MS = 220
local GLOW_BORDER = '#FFC968'
local NORMAL_BORDER = '#4a453e'

local function flashActiveOffer(slot, onDone)
  removeEvent(slot.flashEvent)
  local total = FLASH_BLINKS * 2
  local function step(n)
    if n > total then
      slot:setBorderColor(NORMAL_BORDER)
      if onDone then onDone() end
      return
    end
    slot:setBorderColor(n % 2 == 1 and GLOW_BORDER or NORMAL_BORDER)
    slot.flashEvent = scheduleEvent(function() step(n + 1) end, FLASH_STEP_MS)
  end
  step(1)
end

local SIGIL_CHANCE_BY_TIER = { [1] = 40, [2] = 18, [3] = 40, [4] = 15, [5] = 5 }
local TIER_COLOR = {
  [1] = '#6FBF6F', [2] = '#378ADD', [3] = '#7F77DD', [4] = '#EFA83A', [5] = '#E85A5A',
}

-- Same tier identity, brightened for the Catalog list specifically. TIER_COLOR
-- is tuned against the Offers tab's near-black slot panels (#1a1a1a); on the
-- Catalog TextList's much lighter grey the mid-tone blues/purples especially
-- drop to unreadable. No text-outline exists in this client, so contrast has
-- to come from the color itself.
-- Deliberately unreadable stand-ins, shaped like real catalog rows (id, name of
-- plausible length, tier suffix) so the empty list reads as ghosted content
-- rather than a blank grey box. Fixed list, not randomised: a skeleton that
-- reshuffles every keystroke draws the eye instead of receding.
-- Shaped like a REAL catalog row (id, plausible name, tier/kill/level suffix)
-- so the empty list reads as ghosted content. Kept in step with the live row
-- format - when rows gained "- kill N - lvl N+" these did too, otherwise the
-- skeleton is visibly shorter than what replaces it and the list jumps.
-- Trimmed to 4 (was 8, then 5 - Mizo 2026-08-04 x2) plus a tapering dot fade
-- - the gibberish names carry the "content lives here" read on their own; a
-- full list of them all the way down read as noisy repetition, so the tail
-- now trails off into shorter and shorter dot runs instead, like the
-- skeleton itself is fading out rather than just stopping.
local CATALOG_GHOST_ROWS = {
  '[--] Nnnrrmm Vhaalk (Tier - - kill -- - lvl --+)',
  '[--] Ghorrum Slaath (Tier - - kill -- - lvl --+)',
  '[--] Vaelmirr Dhun (Tier - - kill -- - lvl --+)',
  '[--] Prakk (Tier - - kill -- - lvl --+)',
  ('.'):rep(46),
  ('.'):rep(34),
  ('.'):rep(22),
  ('.'):rep(10),
}

local CATALOG_TIER_COLOR = {
  [1] = '#8FD03A', [2] = '#6FB6FF', [3] = '#B3ACFF', [4] = '#FFC257', [5] = '#FF8080',
}

-- Matches Player.sendTaskState's TASKSTATE_OPCODE in data/lib/core/player.lua -
-- keep both in sync if this number ever changes.
TASKSTATE_OPCODE = 72

-- Matches TASKACTION_OPCODE in data/lib/core/player.lua. Sends
-- "<action>[,<arg>]" - the server resolves it through the exact same
-- Tasks.acceptTask/rerollOffer/shuffleOffers/dropTask/chooseTask that !task
-- calls, and pushes a fresh opcode 72 state back on success (accept/reroll/
-- shuffle/drop/choose), so no local echo is needed for those. search/progress
-- are pure reads answered on TASKCATALOG_OPCODE/TASKPROGRESS_OPCODE instead.
TASKACTION_OPCODE = 73

-- Matches TASKCATALOG_OPCODE/TASKPROGRESS_OPCODE in data/lib/core/player.lua.
TASKCATALOG_OPCODE = 74
TASKPROGRESS_OPCODE = 75

-- 20000 -> "20K", 150000 -> "150K", 284265 -> "284K". Anything under 1000 stays
-- a plain number. Player-facing shorthand only - every actual charge is still
-- the exact server-side amount, this never rounds what is paid.
local function goldText(amount)
  amount = tonumber(amount) or 0
  if amount >= 1000 then
    return math.floor(amount / 1000) .. 'K'
  end
  return tostring(amount)
end

local function sendTaskAction(payload)
  local protocol = g_game.getProtocolGame()
  if not protocol then return end
  protocol:sendExtendedOpcode(TASKACTION_OPCODE, payload)
end

local function parseOutfit(lookType, head, body, legs, feet, addons)
  return {
    type = tonumber(lookType), head = tonumber(head), body = tonumber(body),
    legs = tonumber(legs), feet = tonumber(feet), addons = tonumber(addons),
  }
end

-- Shared shape used by an offer AND the Wish of the Day - both are just "a
-- task", so both parse the same 11-field entry:
-- "<id>,<name>,<tier>,<target>,<minLevel>,<lookType>,<head>,<body>,<legs>,
-- <feet>,<addons>". Returns nil if entry is "-1" (empty) or malformed.
local function parseTaskEntry(entry)
  if not entry or entry == '-1' or entry == '' then return nil end
  local id, name, tier, target, minLevel, lookType, head, body, legs, feet, addons =
    entry:match('^(%d+),(.-),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$')
  if not id then return nil end
  return {
    id = tonumber(id), name = name, tier = tonumber(tier),
    target = tonumber(target), minLevel = tonumber(minLevel),
    outfit = parseOutfit(lookType, head, body, legs, feet, addons),
  }
end

-- The v1 active-task shape; also each entry of the v2 active list.
-- "<id>,<name>,<progress>,<target>,<lookType>,<head>,<body>,<legs>,<feet>,
-- <addons>". Returns nil for 'none'/empty/malformed.
local function parseActiveEntry(entry)
  if not entry or entry == '' or entry == 'none' then return nil end
  local id, name, progress, target, lookType, head, body, legs, feet, addons =
    entry:match('^(%d+),(.-),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$')
  if not id then return nil end
  return {
    id = tonumber(id), name = name, progress = tonumber(progress), target = tonumber(target),
    outfit = parseOutfit(lookType, head, body, legs, feet, addons),
  }
end

local function parseOffersSegment(offersStr)
  local offers = {}
  local slot = 0
  for entry in (offersStr .. ';'):gmatch('(.-);') do
    slot = slot + 1
    offers[slot] = parseTaskEntry(entry)
  end
  return offers
end

-- v2 payload, sent by the server only after this client's hello:v2 handshake:
--
--   v2|slots:<1-3>|<active;active;... or none>|<offers as v1>|<wish or -1>
--     |gear:<0/1>|wallet:<minutes>,<cap>
--     |daggers:<n>[,<name>,<level>,<lookType>,<head>,<body>,<legs>,<feet>,<addons>,<vocation>]*
--     |contract:<name>,<level>,<lookType>,<head>,<body>,<legs>,<feet>,<addons>,<vocation> or -
--     |shopoffer:<taskslots offer id>
--
-- Parsed segment-by-segment on '|': labelled segments are recognised by their
-- "word:" prefix and UNKNOWN labels are ignored outright, so the server may
-- append fields freely - the exact extension trap the v1 payload's greedy
-- tail match had. The three unlabelled segments are taken positionally as
-- active list, offers, wish (task names never start with "letters:", so the
-- two kinds can't collide). Dagger/contract entries tolerate ';' between
-- entries too - normalised to ',' before the positional field walk.
local function parseV2State(buffer)
  local s = { v2 = true, slots = 1, activeList = {}, offers = {}, daggers = {} }

  local segments = {}
  for seg in (buffer .. '|'):gmatch('(.-)|') do
    segments[#segments + 1] = seg
  end

  local unlabeled = {}
  for i = 2, #segments do -- segments[1] is the 'v2' marker itself
    local seg = segments[i]
    local label, rest = seg:match('^(%a+):(.*)$')
    if label == 'slots' then
      s.slots = math.max(1, math.min(3, tonumber(rest) or 1))
    elseif label == 'gear' then
      s.gear = rest == '1'
    elseif label == 'wallet' then
      local minutes, cap = rest:match('^(%d+),(%d+)')
      if minutes then
        s.walletMinutes, s.walletCap = tonumber(minutes), tonumber(cap)
      end
    elseif label == 'daggers' then
      local flat = rest:gsub(';', ',')
      local count = tonumber(flat:match('^(%d+)')) or 0
      local entriesStr = flat:match('^%d+,(.*)$') or ''
      for name, level, lookType, head, body, legs, feet, addons, vocation in
          entriesStr:gmatch('([^,]+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),([^,]+)') do
        if #s.daggers < count then
          s.daggers[#s.daggers + 1] = {
            name = name, level = tonumber(level), vocation = vocation,
            outfit = parseOutfit(lookType, head, body, legs, feet, addons),
          }
        end
      end
    elseif label == 'contract' then
      if rest ~= '' and rest ~= '-' then
        local flat = rest:gsub(';', ',')
        local name, level, lookType, head, body, legs, feet, addons, vocation =
          flat:match('^([^,]+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),([^,]+)$')
        if name then
          s.contract = {
            name = name, level = tonumber(level), vocation = vocation,
            outfit = parseOutfit(lookType, head, body, legs, feet, addons),
          }
        end
      end
    elseif label == 'shopoffer' then
      if rest ~= '' and rest ~= '-' then s.shopoffer = rest end
    elseif not label then
      unlabeled[#unlabeled + 1] = seg
    end
  end

  local activeStr = unlabeled[1]
  if activeStr and activeStr ~= 'none' and activeStr ~= '' then
    for entry in (activeStr .. ';'):gmatch('(.-);') do
      local task = parseActiveEntry(entry)
      if task and #s.activeList < 3 then
        s.activeList[#s.activeList + 1] = task
      end
    end
  end
  s.offers = parseOffersSegment(unlabeled[2] or '')
  s.wish = parseTaskEntry(unlabeled[3])
  return s
end

-- Two shapes on this opcode, decided by prefix. v1:
-- "<offer entry>;...(x5, '-1' if empty)|<wish entry, or -1>|<active>", active
-- being 'none' or the parseActiveEntry shape. v2: see parseV2State above.
-- Both normalise into ONE state table so every fill function below is
-- version-blind and just hides whatever its data slice doesn't carry.
function onTaskStateOpcode(protocol, opcode, buffer)
  local state
  if buffer:sub(1, 3) == 'v2|' then
    state = parseV2State(buffer)
  else
    local offersStr, wishStr, activeStr = buffer:match('^(.-)|(.-)|(.*)$')
    if not offersStr then return end
    state = {
      v2 = false, slots = 1, daggers = {}, activeList = {},
      offers = parseOffersSegment(offersStr),
      wish = parseTaskEntry(wishStr),
    }
    local active = parseActiveEntry(activeStr)
    if active then state.activeList[1] = active end
  end

  lastState = state
  currentActiveIds = {}
  for _, task in ipairs(state.activeList) do
    currentActiveIds[task.id] = true
  end

  -- Bar-button alert BEFORE the tab-specific fills below: it must fire even
  -- on a v1 push (daggers/contract just stay empty forever there, so the
  -- diff never triggers) and even if the window has never been opened this
  -- session - see checkTasksBarAlert's own comment.
  checkTasksBarAlert(state)

  -- activeList is passed to fillOffers too: accepted tasks STAY in the offer
  -- slots (Tasks.acceptTask never clears them), so Offers needs to know which
  -- rows are the ones being worked.
  fillOffers(state.offers, state.wish, state.activeList, state.slots)
  fillActive(state.activeList, state)
  if state.v2 then ensureMarksTab() end
  fillMarks(state)
  -- Accepting/dropping with the Catalog open re-greys the visible rows.
  applyCatalogActiveGrey()
end

-- "<chooseCost>|<id>,<name>,<tier>,<target>,<minLevel>;..." (empty after the
-- '|' if no matches).
--
-- Parsed tolerantly: the 5-field shape (with kill count + level) is what the
-- server sends since 2026-07-29, but the old 3-field shape is still accepted so
-- this client keeps working against a server that has not been deployed yet.
-- Without that fallback the whole tab would silently blank against an older
-- server, which is the exact failure mode the "3.0" float bug had.
function onTaskCatalogOpcode(protocol, opcode, buffer)
  local costStr, matchesStr = buffer:match('^(%d+)|(.*)$')
  if not costStr then return end

  local matches = {}
  if matchesStr ~= '' then
    for entry in (matchesStr .. ';'):gmatch('(.-);') do
      local id, name, tier, target, minLevel =
        entry:match('^(%d+),(.-),(%d+),(%d+),(%d+)$')
      if not id then
        id, name, tier = entry:match('^(%d+),(.-),(%d+)$')
      end
      if id then
        matches[#matches + 1] = {
          id = tonumber(id), name = name, tier = tonumber(tier),
          target = tonumber(target), minLevel = tonumber(minLevel),
        }
      end
    end
  end

  fillCatalog(tonumber(costStr), matches)
end

-- 14 pipe-joined fields (Mizo 2026-08-04 Progress tab overhaul - was 6):
-- streakText|weeklyText|weeklyCount|weeklyTarget|passText|streakDays|
-- freezeTokens|freezeCap|passTier|passMaxTier|passSeasonTasks|
-- passPrevThreshold|passNextThreshold|rankingText. The *Text fields are the
-- old pre-formatted sentences (kept in case anything still wants them
-- verbatim); everything from streakDays on is new raw numbers so the client
-- can build real bars/pips instead of only ever having a sentence to print
-- as-is. rankingText may itself contain real newlines - it's last, so
-- that's safe (Lua's "." matches newlines too).
function onTaskProgressOpcode(protocol, opcode, buffer)
  -- Numeric fields accept an optional decimal tail ("3" or "3.0"). The server
  -- pins them to integers, but a Lua storage value can surface as a float and
  -- a strict %d+ here silently blanked the ENTIRE tab over one stray ".0" -
  -- too brittle for a display-only path.
  local streakText, weeklyText, weeklyCount, weeklyTarget, passText,
        streakDays, freezeTokens, freezeCap,
        passTier, passMaxTier, passSeasonTasks, passPrevThreshold, passNextThreshold,
        rankingText =
    buffer:match('^(.-)|(.-)|([%d%.]+)|([%d%.]+)|(.-)|'
      .. '([%d%.]+)|([%d%.]+)|([%d%.]+)|'
      .. '([%d%.]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)|(.*)$')
  if not streakText then return end

  local function n(v) return math.floor(tonumber(v) or 0) end

  fillProgress({
    streakText = streakText,
    weeklyText = weeklyText,
    weeklyCount = n(weeklyCount),
    weeklyTarget = n(weeklyTarget),
    passText = passText,
    streakDays = n(streakDays),
    freezeTokens = n(freezeTokens),
    freezeCap = n(freezeCap),
    passTier = n(passTier),
    passMaxTier = n(passMaxTier),
    passSeasonTasks = n(passSeasonTasks),
    passPrevThreshold = n(passPrevThreshold),
    passNextThreshold = n(passNextThreshold),
    rankingText = rankingText,
  })
end

-- Tab buttons are sized at RUNTIME from however many tabs actually exist, so
-- adding or hiding one (the Hunt tab, 2026-07-29) re-fits the row evenly
-- instead of leaving a dead gap or overflowing the window. The .otui width is
-- only a fallback for the instant before this runs.
-- 372 = the window's 388px content area (420 wide, minus MainWindow's 16px
-- padding each side) minus the 16px the Offers/Catalog lists reserve for their
-- scrollbar - so the last tab's right edge lines up with the cards below it.
local TAB_ROW_WIDTH = 372
local TAB_GAP = 4

-- NOTE: UITabBar:addTab() already sets each tab's width to fit its OWN text
-- (getTextSize().width + padding), which silently overrides any width set in
-- the .otui style - so the row naturally ends wherever the labels happen to
-- add up, never at the window edge.
--
-- This does NOT flatten them to one equal width: forcing that shrinks the long
-- labels ("Reward Odds") below what their text needs and clips them. Instead it
-- KEEPS each tab's natural text width and shares the leftover space out evenly,
-- so every tab grows by the same amount, nothing clips, and dropping a tab
-- widens the survivors to absorb what it freed.
function layoutTabs()
  if not tasksTabBar then return end
  local tabs = tasksTabBar:getTabs()
  local count = #tabs
  if count == 0 then return end

  local natural, total = {}, 0
  for i, tab in ipairs(tabs) do
    local w = tab:getTextSize().width + tab:getPaddingLeft() + tab:getPaddingRight()
    natural[i] = w
    total = total + w
  end

  -- Only ever expand. If the labels already overflow the row (slack < 0),
  -- leave them at their natural width rather than clipping every one of them.
  local slack = TAB_ROW_WIDTH - TAB_GAP * (count - 1) - total
  local share = slack > 0 and math.floor(slack / count) or 0

  for i, tab in ipairs(tabs) do
    tab:setWidth(natural[i] + share)
  end
end

-- The lamp icon is set here rather than once in init(). init() runs at the
-- login screen, before any game connection - item sprites are tied to the
-- connected game version and aren't loaded yet, so setItemId() at boot
-- silently resolves to nothing (confirmed 2026-07-29: only a Ctrl+Shift+R
-- reloadModules() while already online made it appear, since that reruns
-- init() with sprite data present). Same class of bug game_inventory.lua's
-- own onGameStart=refresh hook exists to avoid; game_tasks just never had it.
function setTaskIcon()
  if not tasksButton then return end
  -- Gemmed lamp is server item 2344 - the client renders by CLIENT id
  -- (items.otb clientid for 2344 is 3231). Passing the server id here
  -- silently shows nothing; see reference_client_vs_server_item_ids memory.
  tasksButton:getChildById('icon'):setItemId(3231)
end

-- ============================================================================
-- Bar-button "unread mark" alert (Mizo 2026-08-04): a dagger landing on you,
-- or a fresh PvP Hunt contract, are things a player needs to know about EVEN
-- IF they've never opened this window - so this is driven straight from
-- onTaskStateOpcode, not fillMarks (which no-ops until the Marks tab exists,
-- i.e. after the window's first open - exactly the case this alert exists
-- for). Two phases, both reusing shapes already proven in this file: a fast
-- attention-grabbing blink (same step-blink structure as flashActiveOffer
-- above - 5 design iterations landed there, no need to reinvent it) for 3s,
-- then a hand-off into a slow steady breathe matching the Marks tab label's
-- own existing 700ms danger-pulse cadence, so "still unread" reads as one
-- consistent visual language across the window rather than two different
-- pulse speeds meaning the same thing.
-- ============================================================================
local TASKBAR_ALERT_COLOR = '#E85A5A' -- matches MARKS_RED below
local TASKBAR_NORMAL_BORDER = '#EFA83A' -- TaskBarButton's own resting border
local TASKBAR_ALERT_BLINKS = 6 -- 12 half-steps
local TASKBAR_ALERT_STEP_MS = 250 -- 12 * 250 = 3000ms fast phase
local TASKBAR_ALERT_PULSE_MS = 700 -- matches marksTabPulseEvent's cadence

local tasksBarUnread = false
local tasksBarAlertEvent = nil
-- Last known counts, diffed on every push to fire only on a genuinely NEW
-- mark/contract - the server resends both every opcode 72, not just on
-- change. Deliberately NOT reset on offline() (same reasoning as
-- flashedActiveIds above: module-local Lua state survives a plain
-- logout/login, so a standing dagger doesn't re-trigger the fast blink on
-- every relog - see checkTasksBarAlert's "resume, don't replay" branch).
local knownDaggerCount = 0
local knownContractName = nil

-- playFastPhase=true for a brand-new event (full 3s attention grab, then
-- settle); false to resume straight into the steady breathe (an
-- already-unread mark surviving a relog - see checkTasksBarAlert).
local function startTasksBarAlert(playFastPhase)
  if not tasksButton then return end
  if tasksBarUnread and tasksBarAlertEvent then return end -- already pulsing
  tasksBarUnread = true
  removeEvent(tasksBarAlertEvent)

  local function settlePulse()
    local lit = true
    local function pulse()
      lit = not lit
      tasksButton:setBorderColor(lit and TASKBAR_ALERT_COLOR or TASKBAR_NORMAL_BORDER)
      tasksBarAlertEvent = scheduleEvent(pulse, TASKBAR_ALERT_PULSE_MS)
    end
    pulse()
  end

  if not playFastPhase then
    settlePulse()
    return
  end

  local total = TASKBAR_ALERT_BLINKS * 2
  local function fastStep(n)
    if n > total then
      settlePulse()
      return
    end
    tasksButton:setBorderColor(n % 2 == 1 and TASKBAR_ALERT_COLOR or TASKBAR_NORMAL_BORDER)
    tasksBarAlertEvent = scheduleEvent(function() fastStep(n + 1) end, TASKBAR_ALERT_STEP_MS)
  end
  fastStep(1)
end

-- Real acknowledgment: the button was actually clicked (see toggle()). Clears
-- the unread flag itself, unlike offline()'s cleanup which only silences the
-- visual for the disconnected session.
local function stopTasksBarAlert()
  removeEvent(tasksBarAlertEvent)
  tasksBarAlertEvent = nil
  tasksBarUnread = false
  if tasksButton then tasksButton:setBorderColor(TASKBAR_NORMAL_BORDER) end
end

-- GLOBAL, not local: onTaskStateOpcode (declared earlier in this file, same
-- reason fillOffers/fillActive/fillMarks below are also global) calls this
-- directly - a local here would be textually invisible to it and resolve to
-- nil at call time despite parsing fine.
function checkTasksBarAlert(state)
  local daggerCount = #(state.daggers or {})
  local contractName = state.contract and state.contract.name or nil
  local isNew = (daggerCount > knownDaggerCount)
    or (contractName ~= nil and contractName ~= knownContractName)
  knownDaggerCount = daggerCount
  knownContractName = contractName

  if isNew then
    startTasksBarAlert(true)
  elseif tasksBarUnread and not tasksBarAlertEvent then
    -- Unread mark surviving a relog (offline() stopped the pulse loop but
    -- left tasksBarUnread true) - resume the steady breathe directly, no
    -- need to replay the fast blink for something already known about.
    startTasksBarAlert(false)
  end
end

function init()
  connect(g_game, { onGameStart = setTaskIcon, onGameEnd = offline })

  -- Lives inside the equipment (inventory) window's layout, not the topmenu -
  -- Mizo 2026-07-29 wanted it wide, under the equipment slots, filling that
  -- panel's width. The widget itself is declared in the retro layout's
  -- 40-inventory.otui (TaskBarButton/tasksBarButton) alongside that window's
  -- other buttons (Stop/Options/Hotkeys/Logout); this module only wires it up.
  -- Only the retro layout's 40-inventory.otui defines tasksBarButton; other
  -- layouts (mobile) don't have it, so this is a soft no-op there rather than
  -- a nil-index crash on init.
  tasksButton = modules.game_inventory.inventoryWindow:recursiveGetChildById('tasksBarButton')
  if tasksButton then
    tasksButton.onClick = toggle
    tasksButton:setOn(false)
    if g_game.isOnline() then
      setTaskIcon()
    end
  end

  g_ui.importStyle('tasks')
  tasksWindow = g_ui.createWidget('TasksWindow', rootWidget)
  tasksWindow:hide()

  tasksTabBar = tasksWindow:getChildById('tasksTabBar')
  tasksTabBar:setContentWidget(tasksWindow:getChildById('tasksTabContent'))

  tabPanels.offers   = g_ui.createWidget('TasksOffersPanel')
  tabPanels.active   = g_ui.createWidget('TasksActivePanel')
  tabPanels.catalog  = g_ui.createWidget('TasksCatalogPanel')
  tabPanels.progress = g_ui.createWidget('TasksProgressPanel')
  tabPanels.odds     = g_ui.createWidget('TasksOddsPanel')

  -- Static resting lines (Mizo 2026-08-04) - Faqir now greets every tab, not
  -- just Active Task. Active Task itself wires its own mascot inside
  -- fillActive (its line reacts to real state); these four never change, so
  -- one-time setup here is enough.
  setupFaqirMascot(tabPanels.offers, 'Pick your prey from these offers, hunter.')
  setupFaqirMascot(tabPanels.catalog, 'Search my ledger for any task you desire.')
  setupFaqirMascot(tabPanels.progress, 'Your deeds are being counted, hunter.')
  setupFaqirMascot(tabPanels.odds, 'Fortune favors the bold - see what awaits.')

  tasksTabBar:addTab(tr('Offers'), tabPanels.offers)
  tasksTabBar:addTab(tr('Active Task'), tabPanels.active)
  catalogTab = tasksTabBar:addTab(tr('Catalog'), tabPanels.catalog)
  progressTab = tasksTabBar:addTab(tr('Progress'), tabPanels.progress)
  oddsTab = tasksTabBar:addTab(tr('Odds'), tabPanels.odds)

  -- HUNT TAB HIDDEN (2026-07-29, Mizo): the feature is unbuilt, so shipping a
  -- tab of static placeholder text to live players advertises something that
  -- does nothing. TasksHuntPanel's style is left intact in tasks.otui - to
  -- bring it back, restore the createWidget above and one addTab line here;
  -- layoutTabs() re-fits the row automatically, no width numbers to touch.

  -- Sized AFTER every addTab, from however many tabs actually exist.
  layoutTabs()

  -- Catalog/Progress are pushed on-demand (not always-on like Offers/Active)
  -- since a search result list and the season/streak/rankings text are only
  -- worth the wire cost when the player actually opens that tab.
  tasksTabBar.onTabChange = function(widget, tab)
    if tab == progressTab then
      sendTaskAction('progress')
    elseif tab == marksTab then
      -- Re-render from the last push so the level gate re-reads the player's
      -- CURRENT level on every visit, not the level at the last push.
      fillMarks(lastState)
    elseif tab == catalogTab then
      -- Always reopen Catalog in its clean state. Leaving a stale result list
      -- from a previous visit sitting under an empty search box reads as "these
      -- are your options" rather than "this is what you last searched for".
      removeEvent(catalogSearchEvent)
      tabPanels.catalog:getChildById('search'):setText('')
      fillCatalog(lastChooseCost, {})
    end
  end

  local searchEdit = tabPanels.catalog:getChildById('search')
  searchEdit.onTextChange = function(widget, text)
    -- Debounced, and an empty box clears LOCALLY rather than over the wire.
    -- Both exist for the same root cause: handleTaskAction (server) throttles
    -- every task action to one per 300ms, so fast typing/backspacing had its
    -- LAST keystroke silently dropped. That's why deleting a short numeric
    -- query ("12") left the old list on screen while a longer word ("dragon")
    -- looked fine - the word's backspaces were just spread wider than 300ms.
    removeEvent(catalogSearchEvent)
    if text == '' then
      fillCatalog(lastChooseCost, {})
      return
    end
    catalogSearchEvent = scheduleEvent(function()
      sendTaskAction('search,' .. text)
    end, CATALOG_SEARCH_DEBOUNCE_MS)
  end

  local catalogList = tabPanels.catalog:getChildById('catalogList')
  connect(catalogList, {
    onChildFocusChange = function(self, focusedChild)
      local chooseBtn = tabPanels.catalog:getChildById('chooseBtn')
      if focusedChild and focusedChild.taskId then
        chooseBtn:setEnabled(true)
      else
        chooseBtn:setEnabled(false)
      end
    end
  })

  tabPanels.catalog:getChildById('chooseBtn'):setEnabled(false)
  tabPanels.catalog:getChildById('chooseBtn').onClick = function()
    local focusedChild = catalogList:getFocusedChild()
    if not focusedChild or not focusedChild.taskId then return end
    local taskId, taskName = focusedChild.taskId, focusedChild.taskName

    local box
    local function cancel() box:destroy() end
    local function confirm() sendTaskAction('choose,' .. taskId); box:destroy() end

    box = displayGeneralBox(tr('Hand-pick task'),
      tr('Hand-pick %s for %s gold?', taskName, goldText(lastChooseCost)), {
      { text = tr('Yes'), callback = confirm },
      { text = tr('No'), callback = cancel },
      anchor = AnchorHorizontalCenter,
    }, cancel, cancel)
  end

  -- Empty state until the first push arrives (login, or manually forcing
  -- this module to load while already in-game won't have one yet - a relog
  -- triggers the push since it only fires from data/creaturescripts/scripts/
  -- login.lua today).
  fillOffers(nil, nil, {}, 1)
  fillActive({}, nil)
  fillOdds()
  fillCatalog(0, {})
  fillProgress(nil)

  pcall(ProtocolGame.registerExtendedOpcode, TASKSTATE_OPCODE, onTaskStateOpcode)
  pcall(ProtocolGame.registerExtendedOpcode, TASKCATALOG_OPCODE, onTaskCatalogOpcode)
  pcall(ProtocolGame.registerExtendedOpcode, TASKPROGRESS_OPCODE, onTaskProgressOpcode)
end

function terminate()
  disconnect(g_game, { onGameStart = setTaskIcon, onGameEnd = offline })
  pcall(ProtocolGame.unregisterExtendedOpcode, TASKSTATE_OPCODE)
  pcall(ProtocolGame.unregisterExtendedOpcode, TASKCATALOG_OPCODE)
  pcall(ProtocolGame.unregisterExtendedOpcode, TASKPROGRESS_OPCODE)
  -- tasksButton lives in game_inventory's static layout, not created here -
  -- unwire it rather than destroying someone else's widget.
  if tasksButton then
    tasksButton.onClick = nil
    tasksButton:setOn(false)
  end
  -- Pulse event first, THEN the window: the tab widget dies with the window
  -- and a still-scheduled pulse tick would poke a destroyed widget.
  removeEvent(marksTabPulseEvent)
  marksTabPulseEvent = nil
  removeEvent(tasksBarAlertEvent)
  tasksBarAlertEvent = nil
  if tasksWindow then tasksWindow:destroy() end
  tasksButton = nil
  tasksWindow = nil
  -- The Marks tab dies with the window; forget it so a re-init starts from
  -- the lazy-creation state again instead of filling a destroyed widget.
  marksTab = nil
  lastState = nil
  currentActiveIds = {}
  v2HelloSent = false
end

function offline()
  if tasksWindow then tasksWindow:hide() end
  if tasksButton then tasksButton:setOn(false) end
  -- The v2 handshake is per-SESSION on the server, so a fresh connection
  -- starts back at v1 until the window is opened again - the hello must be
  -- re-sent then.
  v2HelloSent = false
  -- No connection, no daggers - stop the tab pulse rather than letting it
  -- blink at the character-select screen until the next login's push.
  removeEvent(marksTabPulseEvent)
  marksTabPulseEvent = nil
  if marksTab and marksTabDefaultColor then marksTab:setColor(marksTabDefaultColor) end
  -- Bar-button alert: stop the VISUAL only (tasksBarUnread deliberately
  -- survives - an un-acknowledged mark should resume its steady breathe on
  -- the next login's first push via checkTasksBarAlert, not silently
  -- disappear just because the client disconnected).
  removeEvent(tasksBarAlertEvent)
  tasksBarAlertEvent = nil
  if tasksButton then tasksButton:setBorderColor(TASKBAR_NORMAL_BORDER) end
  lastState = nil
  currentActiveIds = {}
  -- flashedActiveIds is deliberately NOT reset here. Module-local Lua state
  -- survives a plain logout/login within the same client process, so leaving
  -- it means a task that was already active before logout does not flash
  -- again after login. Only a genuinely fresh client launch clears it (Lua
  -- state resets), which at worst flashes once for an already-active task on
  -- first window open - harmless, and not worth extra state to prevent.
end

function toggle()
  if tasksButton:isOn() then
    tasksWindow:hide()
    tasksButton:setOn(false)
  else
    tasksWindow:show()
    tasksWindow:raise()
    tasksWindow:focus()
    tasksButton:setOn(true)
    -- Real acknowledgment: they actually clicked to open the window, so the
    -- mark/contract that triggered the alert has been seen. Stop the pulse
    -- and clear tasksBarUnread for good (unlike offline()'s cleanup, which
    -- only silences the visual without acknowledging anything).
    stopTasksBarAlert()
    -- Payload v2 handshake, once per connection: after this the server
    -- answers every opcode 72 push for the session in the v2 shape. A v1
    -- server just ignores the unknown action (it politely refuses unknown
    -- verbs), so this is safe to send blind in either deploy order.
    if g_game.isOnline() and not v2HelloSent then
      v2HelloSent = true
      sendTaskAction('hello:v2')
      -- handleTaskAction throttles to one action per 300ms server-side; the
      -- tab refresh right below would otherwise be the request that gets
      -- silently dropped when the window opens straight onto Progress.
      scheduleEvent(refreshCurrentTab, 350)
    else
      -- Progress data is fetched on demand (opcode 75), so reopening the
      -- window with Progress ALREADY the selected tab would otherwise show
      -- whatever was true last time it was opened - onTabChange never fires
      -- when the tab doesn't actually change.
      refreshCurrentTab()
    end
  end
end

-- Re-fetch/re-render whatever the visible tab needs. Offers/Active are
-- server-pushed (opcode 72) and always current, so only Progress needs an
-- explicit pull; Marks re-renders locally for its level gate.
function refreshCurrentTab()
  if not tasksTabBar then return end
  local current = tasksTabBar:getCurrentTab()
  if current == progressTab then
    sendTaskAction('progress')
  elseif marksTab and current == marksTab then
    fillMarks(lastState)
  end
end

-- ============================================================================
-- Offers tab - offers is nil (nothing pushed yet) or a table keyed 1-5,
-- any of which may itself be nil (that slot came back empty from the server).
-- activeList: every running task (v1: at most one; v2: up to slots). The v1
-- "a task is running" gates generalise to "no free slot left" - a 3-slot
-- player with one hunt running can still accept, so nothing dims or disables
-- until the slots are actually full.
-- ============================================================================
function fillOffers(offers, wishTask, activeList, slots)
  activeList = activeList or {}
  slots = slots or 1
  local panel = tabPanels.offers

  local activeById = {}
  for _, task in ipairs(activeList) do activeById[task.id] = task end
  local slotsFull = #activeList >= slots

  -- Wish of the Day only (Grand Wish/weekly is a separate slot the payload
  -- doesn't carry yet - TODO if this tab ever needs it live).
  local wish = panel:recursiveGetChildById('wishBanner')
  wish:getChildById('label'):setText(tr('Wish of the day - Free'))
  if wishTask then
    wish:getChildById('name'):setText(('%s (Tier %d, kill %d, lvl %d+)'):format(
      wishTask.name, wishTask.tier, wishTask.target, wishTask.minLevel))
    local wishAccept = wish:getChildById('accept')
    -- The engine refuses any accept with no free slot, so the Wish's Accept
    -- is disabled too rather than left to fail with an error message.
    wishAccept:setEnabled(not slotsFull and not activeById[wishTask.id])
    wishAccept.onClick = function()
      sendTaskAction('accept,' .. wishTask.id)
    end
  else
    wish:getChildById('name'):setText(tr('No wish available'))
    wish:getChildById('accept'):setEnabled(false)
  end

  -- Active rows in payload order, for the pin/flash pass after the loop.
  local activeRows = {}

  for i = 1, 5 do
    local slot = panel:recursiveGetChildById('slot' .. i)
    if slot then
      local offer = offers and offers[i]
      local acceptBtn = slot:getChildById('accept')
      local rerollBtn = slot:getChildById('reroll')
      local creature = slot:getChildById('creature')
      local activeEntry = offer and activeById[offer.id] or nil
      local isActiveOffer = activeEntry ~= nil
      if isActiveOffer then
        activeRows[#activeRows + 1] = { slot = slot, entry = activeEntry }
      end
      if offer then
        slot:getChildById('name'):setText(
          offer.name .. (isActiveOffer and '  [ACTIVE]' or ''))
        slot:getChildById('info'):setText(('Tier %d - kill %d - lvl %d+'):format(offer.tier, offer.target, offer.minLevel))
        rerollBtn:setText(tr('Reroll') .. ' ' .. goldText(REROLL_COST_BY_TIER[offer.tier] or 0))
        -- Rerolling an ACTIVE row orphans the running task out of the offer
        -- list entirely, and nothing else in the tab marks it as running
        -- once that happens - so active rows never reroll. With a single
        -- slot the whole tab additionally goes read-only while hunting
        -- (Mizo 2026-07-29, reversing the earlier confirm-dialog approach);
        -- with v2 multi-slot that blanket rule would dead-lock the FREE
        -- slots, so there the non-active rows stay live.
        rerollBtn:setEnabled(not isActiveOffer and (slots > 1 or #activeList == 0))

        -- State is carried by CONTRAST, not by a new colour: with the slots
        -- full the other rows dim and the active ones stay at full
        -- brightness. Deliberately not "tint the accepted row green" - Tier 1
        -- already IS green (#6FBF6F), so a green state marker would be
        -- indistinguishable from tier language on exactly the rows most
        -- likely to be accepted.
        if isActiveOffer then
          slot:setOpacity(1.0)
          slot:getChildById('name'):setColor(TIER_COLOR[offer.tier] or '#F0E6D2')
          slot:getChildById('info'):setColor('#B0A48C')
          -- The Accept button here can never work (the engine refuses a
          -- re-accept), and it is the biggest element in the row - so it
          -- becomes the live kill count instead of dead disabled chrome.
          -- Updates on every kill for free, since opcode 72 already pushes
          -- per-kill. During the blink-then-move sequence it shows
          -- "^ MOVED UP" instead - see flashActiveOffer's onDone, which
          -- switches it to the counter the instant the blink ends rather
          -- than waiting on the next kill.
          if not flashedActiveIds[offer.id] then
            acceptBtn:setText(tr('^ MOVED UP'))
          else
            acceptBtn:setText(('%d / %d'):format(activeEntry.progress, activeEntry.target))
          end
          acceptBtn:setEnabled(false)
        else
          -- Dim BOTH ways on purpose: setOpacity is not verified to cascade to
          -- child widgets in this client (no C++ source here to check), so the
          -- de-emphasis is also applied as explicit colours. If opacity does
          -- cascade the row just dims a little further; if it does not, the
          -- contrast still lands. Never rely on the opacity alone.
          slot:setOpacity(slotsFull and 0.45 or 1.0)
          if slotsFull then
            slot:getChildById('name'):setColor('#5a5a5a')
            slot:getChildById('info'):setColor('#4a4a4a')
          else
            slot:getChildById('name'):setColor(TIER_COLOR[offer.tier] or '#F0E6D2')
            slot:getChildById('info'):setColor('#B0A48C')
          end
          acceptBtn:setText(tr('Accept'))
          -- Disabled with no free slot because the ENGINE refuses it -
          -- leaving it clickable meant five live buttons that all failed
          -- with "You already have an active task."
          acceptBtn:setEnabled(not slotsFull)
        end

        if offer.outfit and offer.outfit.type and offer.outfit.type > 0 then
          creature:setOutfit(offer.outfit)
        end
      else
        slot:setOpacity(1.0)
        acceptBtn:setText(tr('Accept'))
        slot:getChildById('name'):setText(tr('No offer'))
        slot:getChildById('name'):setColor('#55534c')
        slot:getChildById('info'):setText('-')
        rerollBtn:setText(tr('Reroll'))
        acceptBtn:setEnabled(false)
        rerollBtn:setEnabled(false) -- already disabled: an empty slot has nothing to reroll
        creature:setOutfit({type = 0})
      end

      rerollBtn.onClick = function()
        -- Reroll is disabled above for every active row, so this can only
        -- fire on a non-active slot - no confirm needed, nothing here can
        -- orphan a running task out of the offer list.
        sendTaskAction('reroll,' .. i)
      end
      acceptBtn.onClick = function()
        if offer then
          sendTaskAction('accept,' .. offer.id)
        end
      end
    end
  end

  -- Accepting a task should not leave it buried wherever it happened to be
  -- offered - it moves to the top of the list (right under the Wish banner)
  -- via moveChildToIndex (the same reordering API game_actionbar and the
  -- console log already use inside a box layout - children under
  -- layout:verticalBox cannot carry their own anchors in this engine, so a
  -- true position TWEEN would fight the list's own reflow every frame; a
  -- ghost-panel slide effect was tried and built, then removed at Mizo's
  -- request 2026-07-30 - keep the move a plain instant reorder). The move
  -- itself is DEFERRED until after the glow plays at the row's original
  -- spot (see flashActiveOffer above) - moving it in the same instant as the
  -- click meant the indicator only ever appeared after the row had already
  -- jumped, which read as no indicator at all. With v2 multi-slot each
  -- active row runs this lifecycle independently; already-flashed rows stay
  -- pinned under the Wish banner in payload order.
  local offersScroll = panel:getChildById('offersScroll')
  if offersScroll then
    local pinPos = 0
    for _, row in ipairs(activeRows) do
      local id = row.entry.id
      if flashedActiveIds[id] then
        -- Sequence already finished on an earlier push - keep it pinned on
        -- every subsequent state push (a later fillOffers call could
        -- otherwise leave it wherever the server slot array put it).
        pinPos = pinPos + 1
        offersScroll:moveChildToIndex(row.slot, offersScroll:getChildIndex(wish) + pinPos)
      elseif not pendingMoveIds[id] then
        -- Brand new accept: glow in place first, THEN move.
        pendingMoveIds[id] = true
        local slotWidget, entry = row.slot, row.entry
        flashActiveOffer(slotWidget, function()
          pendingMoveIds[id] = nil
          -- Dropped/finished mid-blink: a later push already re-rendered
          -- this row as a plain offer - moving it now would reorder a row
          -- that no longer has anything to pin.
          if not currentActiveIds[id] then return end
          offersScroll:moveChildToIndex(slotWidget, offersScroll:getChildIndex(wish) + 1)
          flashedActiveIds[id] = true
          -- Switch the counter on immediately rather than waiting for the
          -- next opcode 72 push (the next kill could be a while away) - the
          -- button would otherwise keep reading "^ MOVED UP" long after it
          -- stopped being true.
          local acceptBtn = slotWidget:getChildById('accept')
          if acceptBtn then
            acceptBtn:setText(('%d / %d'):format(entry.progress, entry.target))
          end
        end)
      end
      -- else: glow already in progress for this id - a kill landed
      -- mid-sequence and re-pushed state. Do nothing here; the scheduled
      -- callback above will still fire and move it once, at the original
      -- time.
    end
  end
  -- Forget ids that stopped running so a later re-accept flashes again.
  for id in pairs(flashedActiveIds) do
    if not activeById[id] then flashedActiveIds[id] = nil end
  end

  local shuffleBtn = panel:recursiveGetChildById('shuffle')
  -- Disabled while ANY task runs, even with free slots: shuffle replaces ALL
  -- five offers, always including every active row, so leaving it live would
  -- orphan the running tasks out of the list every time.
  shuffleBtn:setEnabled(#activeList == 0)
  shuffleBtn.onClick = function()
    sendTaskAction('shuffle')
  end

end

-- ============================================================================
-- Faqir the Wise's mascot (Mizo 2026-08-04) - shared by EVERY tab in this
-- window now, not just Active Task where he started. Outfit lives here
-- (data/npc/Faqir the Wise.xml on the server - outfits aren't remapped
-- server/client like item ids are, so this look type is safe to pass
-- straight to setOutfit()) since this was the first tab to use him.
-- ============================================================================
local FAQIR_OUTFIT = { type = 103, head = 20, body = 30, legs = 40, feet = 50, addons = 0 }
local FAQIR_MATERIALIZE_MS = 500
-- 40/16 (was 128/48 pre-redesign, briefly 32/12 - too small to notice the
-- grow-in at all, per Mizo feedback 2026-08-04): matches faqirCreature's
-- OTUI size (40x40, standing at the top of the counter frame - see
-- TasksActivePanel), big enough for the materialize effect to actually read.
local FAQIR_SIZE = 40
local FAQIR_START_SIZE = 16

-- Click Faqir for a random line (Mizo 2026-08-04) - cheap personality: no
-- state to track beyond "which line", and it can never desync from the real
-- state text since the NEXT genuine push (state change, tab refresh) just
-- overwrites it the normal way through fillOffers/fillActive/fillMarks/etc.
local FAQIR_CLICK_LINES = {
  "Careful out there, hunter.",
  "Gold and glory favor the bold.",
  "I have seen many hunters. Few return rich.",
  "The Blades Board never forgets a name.",
  "Ask, and I may answer - if I feel like it.",
  "Every task tells me something about you.",
}

-- Wires outfit + the click-quip handler for one tab's mascot instance.
-- staticLine (optional) sets its resting text immediately for tabs whose
-- line never changes with state (Catalog, Odds); tabs that DO react to
-- their own data (Active Task, Bounties) set text themselves in their own
-- fill function instead and pass nothing here. GLOBAL, not local: called
-- from init()/ensureMarksTab(), both declared EARLIER in this file - a
-- local here would be textually invisible to them (same reasoning as
-- checkTasksBarAlert above).
function setupFaqirMascot(panel, staticLine)
  local mascot = panel:getChildById('faqirMascot')
  if not mascot then return nil end
  local creature = mascot:getChildById('faqirCreature')
  creature:setOutfit(FAQIR_OUTFIT)
  if staticLine then
    mascot:getChildById('faqirBubbleText'):setText(tr(staticLine))
  end
  mascot.onClick = function()
    mascot:getChildById('faqirBubbleText'):setText(tr(FAQIR_CLICK_LINES[math.random(#FAQIR_CLICK_LINES)]))
  end
  return mascot
end

-- ============================================================================
-- Active task tab - activeList is {} (no tasks, or nothing pushed yet) or up
-- to three {id, name, progress, target, outfit} entries (v1: exactly one).
-- ============================================================================

-- No real warp/dissolve shader is available here (this client's outfit
-- shaders only expose a scroll-offset uniform the engine drives itself, not
-- a generic per-frame uniform Lua can animate, and this is a compiled client
-- with no C++ source to add one) - this fakes "materializing" out of the
-- lamp with a fade + grow tween instead, reusing corelib's g_effects.fadeIn
-- for opacity and hand-rolling the same step pattern for size.
local function materializeFaqir(creature)
  removeEvent(creature.materializeEvent)
  creature:setOpacity(0)
  creature:setSize({width = FAQIR_START_SIZE, height = FAQIR_START_SIZE})
  g_effects.fadeIn(creature, FAQIR_MATERIALIZE_MS)

  local function step(elapsed)
    local t = math.min(elapsed / FAQIR_MATERIALIZE_MS, 1)
    local size = FAQIR_START_SIZE + math.floor((FAQIR_SIZE - FAQIR_START_SIZE) * t)
    creature:setSize({width = size, height = size})
    if t < 1 then
      creature.materializeEvent = scheduleEvent(function() step(elapsed + 30) end, 30)
    else
      creature.materializeEvent = nil
    end
  end
  step(0)
end

-- Faqir's materialize entrance now plays ONCE, the first time the tab is
-- ever filled this session, rather than on every empty<->busy transition -
-- he's persistent chrome now (see fillActive), not a reveal tied to the
-- empty state, so replaying it per-transition would fire constantly as tasks
-- get accepted/dropped/completed.
local faqirMaterialized = nil

-- Always renders exactly 3 slot rows in this fixed order: busy tasks first
-- (ActiveTaskCard), then owned-but-idle slots (TaskSlotEmpty) up to s.slots,
-- then locked slots (TaskSlotLocked) for the rest - so the row always reads
-- as "3 total, this many are yours, this many are still for sale" at a
-- glance instead of just shrinking when a task finishes.
function fillActive(activeList, s)
  activeList = activeList or {}
  s = s or {}
  local panel = tabPanels.active
  local listPanel = panel:getChildById('activeList')
  local mascot = panel:getChildById('faqirMascot')
  local faqirCreature = mascot:getChildById('faqirCreature')
  -- faqirBubbleText is a DIRECT child of faqirMascot again (no separate
  -- bordered bubble panel - it floats plain above his head now, inside the
  -- counter frame's own border, see TasksActivePanel in the otui).
  local faqirText = mascot:getChildById('faqirBubbleText')
  local unlockBtn = panel:getChildById('unlockSlots')

  setupFaqirMascot(panel) -- outfit + click-quip handler (idempotent, cheap)
  if not faqirMaterialized then
    materializeFaqir(faqirCreature)
    faqirMaterialized = true
  end

  -- Plain, classic-Tibia-NPC phrasing (Mizo feedback 2026-08-04: the first
  -- pass read stiffer/more like a UI label than an NPC line) - short,
  -- second-person, no jargon. Kept to ONE short line on purpose now: the
  -- bubble floats directly above his head with no box of its own to wrap
  -- into (see TasksActivePanel), so a long line would just clip.
  local slots = s.slots or 1
  local busy = #activeList
  if busy == 0 then
    faqirText:setText(tr('Choose a task from my offers, hunter.'))
  elseif busy < slots then
    faqirText:setText(tr("Another task awaits, if you're ready."))
  else
    faqirText:setText(tr('Hands full! Return once a task concludes.'))
  end

  -- Cards are rebuilt from scratch on every push - cheap at <=3 cards, and it
  -- sidesteps every hidden-widget/stale-handler pitfall of pooling them.
  listPanel:destroyChildren()

  -- pcall per slot (Mizo bug report 2026-08-04: the row was rendering
  -- completely empty, mascot only) - g_ui.createWidget/getChildById calls
  -- were unguarded, so ANY single bad slot (e.g. one bogus task entry) threw
  -- and killed the rest of the loop with no visible error, taking every
  -- OTHER slot down with it. Now a broken slot logs and gets skipped; the
  -- other two still render.
  local function buildSlot(i)
    local task = activeList[i]
    if task then
      local card = g_ui.createWidget('ActiveTaskCard', listPanel)
      card:getChildById('name'):setText(task.name)
      local progressLabel = card:getChildById('progressText')
      progressLabel:setText(('%d / %d killed'):format(task.progress, task.target))
      -- Brief green flash when the kill count actually went up since the
      -- last push - a small "yes, that counted" confirmation instead of the
      -- number just silently being a different number now.
      if task.progress > (lastKillCounts[task.id] or 0) then
        flashKillCount(progressLabel)
      end
      lastKillCounts[task.id] = task.progress
      local percent = 0
      if task.target > 0 then
        percent = math.min(100, math.floor(task.progress * 100 / task.target))
      end
      card:getChildById('progress'):setPercent(percent)
      if task.outfit and task.outfit.type and task.outfit.type > 0 then
        card:getChildById('creature'):setOutfit(task.outfit)
      end

      -- v1 servers know only the argument-less drop (they have exactly one
      -- task to drop); v2 must say WHICH of the up-to-three goes.
      local dropPayload = s.v2 and ('drop,' .. task.id) or 'drop'
      local taskName = task.name
      card:getChildById('drop').onClick = function()
        -- Mizo 2026-07-28: confirm before dropping - an accidental click
        -- loses an in-progress task with no undo. UIMessageBox's own
        -- addButton() does NOT auto-close on click (only :ok()/:cancel() do
        -- that) - every path here (Yes/No/Escape/Enter) explicitly destroys
        -- the box itself. Enter/Escape/No all cancel, never confirm, so an
        -- accidental keypress can't do the destructive thing this dialog
        -- exists to prevent.
        local box
        local function cancel() box:destroy() end
        local function confirm() sendTaskAction(dropPayload); box:destroy() end

        box = displayGeneralBox(tr('Drop Task'), tr('Are you sure you want to drop %s?', taskName), {
          { text = tr('Yes'), callback = confirm },
          { text = tr('No'), callback = cancel },
          anchor = AnchorHorizontalCenter,
        }, cancel, cancel)
      end
    elseif i <= slots then
      local card = g_ui.createWidget('TaskSlotEmpty', listPanel)
      card:getChildById('text'):setText(tr('Empty slot - pick a task from the Offers tab.'))
    else
      local card = g_ui.createWidget('TaskSlotLocked', listPanel)
      card:getChildById('teaser'):setText(tr('+1 concurrent task - unlock in the webshop.'))
    end
  end

  for i = 1, 3 do
    local ok, err = pcall(buildSlot, i)
    if not ok then
      g_logger.error('game_tasks fillActive: slot ' .. i .. ' failed to build - ' .. tostring(err))
    end
  end

  -- Dynamic CTA (Mizo): count-aware text ("Unlock 1/2 more task slot(s)")
  -- instead of the old static "Unlock extra slots?" - shown ONLY while
  -- something is actually left to unlock AND the server told us which shop
  -- offer sells it; hidden entirely once expanded to 3, and on v1 servers
  -- that don't carry the field at all.
  local locked = math.max(0, 3 - slots)
  if s.v2 and locked > 0 and s.shopoffer then
    local shopoffer = s.shopoffer
    unlockBtn:setVisible(true)
    unlockBtn:setText(locked == 1 and tr('Unlock 1 more task slot') or tr('Unlock %d more task slots', locked))
    -- 10028 is the CLIENT id for server item 10945 ("Soul Contract" - Task
    -- Slot Expansion's icon on the website shop card, see web/pages/shop.php
    -- itemMeta) - same icon on both surfaces so this button reads as "the
    -- same thing you'd click Buy on over there" (Mizo 2026-08-04).
    unlockBtn:getChildById('unlockIcon'):setItemId(10028)
    unlockBtn.onClick = function()
      -- The site scrolls to and gold-highlights this exact card.
      g_platform.openUrl('https://theotserver.com/?page=shop#offer-' .. shopoffer)
    end
  else
    unlockBtn:setVisible(false)
  end
end

-- ============================================================================
-- Bounties tab (Faqir's Dagger, v2 only - player-facing label is "Bounties",
-- Mizo 2026-08-04; internal ids/functions stay "marks" throughout, see
-- ensureMarksTab). Side-by-side columns, full rework 2026-08-04: "HUNTING
-- YOU" (red, left, one row per assassin) and "YOUR TARGET" (green, right, at
-- most one row - Faqir only ever gives you a single live contract at a
-- time). Replaces the earlier stacked-sections redesign - the two lists are
-- mechanically the same instruction ("kill this person") from opposite
-- directions, so mirrored columns read faster than two long full-width
-- sections repeating the same visual language. Display-only: story lines
-- arrive in chat from the server; this tab only reflects current state and
-- never animates history.
-- ============================================================================
local MARKS_RED = '#E85A5A'
local MARKS_GREEN = '#6FBF6F'

-- Longest a name/subline is allowed to render before getting cut with "..."
-- (plain ASCII, not a unicode ellipsis - the 8.60 client's font doesn't
-- reliably carry non-ASCII glyphs). Used to be a fixed character count, but
-- that's only an average-glyph-width guess - a genuinely long character name
-- (or a wide-lettered one well under the count) could still overflow the
-- 137px column and get hard-clipped by the row's own bounds instead of
-- eliding cleanly (Mizo bug report 2026-08-05: "long names having their
-- name/level cutout"). Measures the ACTUAL rendered pixel width via the
-- widget's own font (getTextSize, same API uitabbar/uipopupmenu use to size
-- themselves) and binary-searches for the longest prefix that still fits, so
-- it's exact regardless of which characters the name/vocation contain.
-- 137 = MarksRow's own width (175) minus the 32px portrait and 6px
-- margin-left - both nameplate and subline resolve to that same width.
local MARKS_ROW_TEXT_WIDTH = 137

local function fitRowText(widget, text)
  text = text or ''
  widget:setText(text)
  if widget:getTextSize().width <= MARKS_ROW_TEXT_WIDTH then return end
  local lo, hi = 0, #text
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    widget:setText(text:sub(1, mid) .. '...')
    if widget:getTextSize().width <= MARKS_ROW_TEXT_WIDTH then
      lo = mid
    else
      hi = mid - 1
    end
  end
  widget:setText(text:sub(1, lo) .. '...')
end

-- Shared by both columns: portrait + pixel-fit name + pixel-fit
-- "Lvl N - Vocation" subline. Level leads (Mizo bug report 2026-08-05: a
-- long promoted-vocation name like "Mighty Conqueror" pushed the level off
-- the end, so a pixel-fit "..." was landing mid-number and hiding the one
-- number a player actually needs to decide whether to fight) - the fit still
-- trims from the right when a row runs long, but now it eats into the
-- (decorative) vocation name instead of the level.
local function fillBountyRow(row, entry)
  if entry.outfit and entry.outfit.type and entry.outfit.type > 0 then
    row:getChildById('creature'):setOutfit(entry.outfit)
  end
  fitRowText(row:getChildById('nameplate'), entry.name)
  fitRowText(row:getChildById('subline'),
    ('Lvl %d - %s'):format(entry.level or 0, entry.vocation or '?'))
end

-- Rebuilds one column's row list in place (header/note labels are static
-- otui children, only rowsBox gets destroyed/repopulated). emptyText shows
-- a single muted placeholder row rather than leaving a bare gap under the
-- header - same "always show something" rule the Active Task tab's 3-slot
-- design follows.
local function fillBountyColumn(column, entries, emptyText)
  local rowsBox = column:getChildById('rowsBox')
  rowsBox:destroyChildren()
  if #entries == 0 then
    local empty = g_ui.createWidget('MarksColumnEmpty', rowsBox)
    empty:setText(emptyText)
    return
  end
  for _, entry in ipairs(entries) do
    fillBountyRow(g_ui.createWidget('MarksRow', rowsBox), entry)
  end
end

-- Created on the FIRST v2 push and never before - a v1 session never sees
-- the tab. Never removed either (UITabBar has no removeTab); once the server
-- has spoken v2 it keeps speaking it for the session, so that's moot.
function ensureMarksTab()
  if marksTab or not tasksTabBar then return end
  tabPanels.marks = g_ui.createWidget('TasksMarksPanel')
  -- "Bounties" (was "Marks" - Mizo 2026-08-04, confirmed via AskUserQuestion):
  -- clearer to any MMO player at a glance. Internal ids/comments stay "marks"
  -- throughout this file and the otui - only the player-facing label changed.
  marksTab = tasksTabBar:addTab(tr('Bounties'), tabPanels.marks)
  marksTabDefaultColor = marksTab:getColor()
  -- No static line: fillMarks sets the mascot's text every push, reacting to
  -- whether the player is currently hunted, hunting, or neither.
  setupFaqirMascot(tabPanels.marks)
  -- addTab always APPENDS - Marks would otherwise land right of Reward Odds
  -- (Mizo's call: Reward Odds stays the last tab, always). Move it back to
  -- the end of the button row every time; harmless no-op on v1 sessions,
  -- where this function never runs at all.
  if oddsTab then
    tasksTabBar.buttonsPanel:moveChildToIndex(oddsTab, tasksTabBar.buttonsPanel:getChildCount())
  end
  -- Re-fit the row to make room, exactly like the hidden Hunt tab note says.
  layoutTabs()

  tabPanels.marks:getChildById('bladesBoard').onClick = function()
    g_platform.openUrl('https://theotserver.com/?page=bountyboard')
  end
end

function fillMarks(s)
  if not marksTab then return end
  s = s or {}
  local panel = tabPanels.marks
  local list = panel:getChildById('marksScroll')
  local threatColumn = list:getChildById('threatColumn')
  local targetColumn = list:getChildById('targetColumn')
  local gateMessage = list:getChildById('gateMessage')

  local daggers = s.daggers or {}
  local contract = s.contract

  -- Tab label carries the dagger count and pulses red while any exist -
  -- enough to pull the eye from anywhere in the window without opening the
  -- tab. layoutTabs() re-fits the row since the label just changed width.
  -- The pulse is a slow 700ms breathe, not the accept-flash's fast blink -
  -- this is a standing condition, not a one-shot event. $checked overrides
  -- color while the tab is selected, which is fine: whoever is ON the tab
  -- is already looking at the daggers.
  removeEvent(marksTabPulseEvent)
  marksTabPulseEvent = nil
  if #daggers > 0 then
    marksTab:setText(('%s (%d)'):format(tr('Bounties'), #daggers))
    marksTab:setColor(MARKS_RED)
    local lit = true
    local function pulse()
      lit = not lit
      marksTab:setColor(lit and MARKS_RED or marksTabDefaultColor)
      marksTabPulseEvent = scheduleEvent(pulse, 700)
    end
    marksTabPulseEvent = scheduleEvent(pulse, 700)
  else
    marksTab:setText(tr('Bounties'))
    marksTab:setColor(marksTabDefaultColor)
  end
  layoutTabs()

  -- Faqir reacts to your own threat state (Mizo 2026-08-04) - plain Tibia
  -- English, matching the section headers below.
  local mascotText = panel:getChildById('faqirMascot'):getChildById('faqirBubbleText')
  if #daggers > 0 then
    mascotText:setText(tr('Blades are drawn against you. Strike first.'))
  elseif contract then
    mascotText:setText(tr('Your target awaits, hunter.'))
  else
    mascotText:setText(tr('No blood owed, on you or by you.'))
  end

  -- PvP/Hunt level gate (Mizo final call: level 100 itself is still
  -- protected). The client reads its OWN level and only greys the controls -
  -- the server enforces regardless, this is UX not security. Re-evaluated on
  -- every state push and every visit to this tab, so crossing the line while
  -- the window is open corrects itself.
  local player = g_game.getLocalPlayer()
  local level = player and player:getLevel() or 0
  local gated = level < 101
  panel:getChildById('bladesBoard'):setEnabled(not gated)
  if gated then
    gateMessage:setText(tr('Unlocks at level 101 - the realm protects the young.'))
    gateMessage:setColor('#55534c')
    gateMessage:setVisible(true)
    threatColumn:setVisible(false)
    targetColumn:setVisible(false)
    return
  end
  gateMessage:setVisible(false)
  threatColumn:setVisible(true)
  targetColumn:setVisible(true)

  -- The showdown case: your contract's prey is ALSO one of your assassins.
  -- Both reward lines pay out there - surfaced on the target column's own
  -- note line now (used to be a per-entry "Two daggers, one grave" teaser;
  -- there's no room for a third text line per row in the compact layout).
  local mutual = false
  if contract then
    for _, dagger in ipairs(daggers) do
      if dagger.name == contract.name then
        mutual = true
        break
      end
    end
  end

  -- "HUNTING YOU" (left, red) - answers "what do I need to defend myself
  -- from". One row per assassin; the steal-the-reward rule lives once on
  -- the column note rather than repeating per row (Mizo bug report
  -- 2026-08-04: it read as redundant with more than one hunter).
  local threatHeader = threatColumn:getChildById('columnHeader')
  threatHeader:setText(#daggers > 0 and ('%s (%d)'):format(tr('HUNTING YOU'), #daggers) or tr('HUNTING YOU'))
  threatHeader:setColor(MARKS_RED)
  local threatNote = threatColumn:getChildById('columnNote')
  threatNote:setText(tr('Kill them first - steal the reward.'))
  threatNote:setColor('#EFA83A')
  fillBountyColumn(threatColumn, daggers, tr('Nobody hunting you.'))

  -- "YOUR TARGET" (right, green) - who you're hunting. At most one row:
  -- Faqir only ever hands out a single live contract at a time.
  local targetHeader = targetColumn:getChildById('columnHeader')
  targetHeader:setText(tr('YOUR TARGET'))
  targetHeader:setColor(MARKS_GREEN)
  local targetNote = targetColumn:getChildById('columnNote')
  if mutual then
    -- Rephrased in plain English (Mizo 2026-08-04: "I myself am confused
    -- what does this mean" about the old "[x_x] Drawn blades walk beneath
    -- the green skull" line) - say exactly what's happening: this is a
    -- mutual showdown, both reward lines pay out.
    targetNote:setText(tr("They're hunting you too - kill them and collect both rewards."))
  else
    targetNote:setText(tr('Kill them to claim the contract reward.'))
  end
  targetNote:setColor(MARKS_GREEN)
  fillBountyColumn(targetColumn, contract and { contract } or {}, tr('No target yet.'))
end

-- ============================================================================
-- Catalog tab - search any of the ~250 tasks by name/id and hand-pick one for
-- gold (Tasks.chooseTask, same function/cost/gates as "!task choose <query>").
-- matches is a table of {id, name, tier} - server caps it at 30.
-- ============================================================================
function fillCatalog(chooseCost, matches)
  local panel = tabPanels.catalog
  lastChooseCost = chooseCost
  panel:getChildById('searchLabel'):setText(
    tr('Search by name or id (hand-pick cost: %s gold)', goldText(chooseCost)))

  local list = panel:getChildById('catalogList')
  list:destroyChildren()

  -- Empty state = ghosted skeleton rows. This client has no blur filter, so
  -- "blurred" is faked the only way it can be: unreadable pseudo-names drawn
  -- in a muted grey, so the eye reads "content lives here" without being
  -- able to read any of it. #33312c -> #55534c (Mizo 2026-08-04: the old
  -- shade was tuned as "near-background" against catalogList's PREVIOUS
  -- #636363 grey - once that background went dark (#120c04, same bug report
  -- as the fix above), the same color became near-invisible instead of
  -- tastefully faded. #55534c is the same muted tone TaskSlotLocked's own
  -- teaser text already uses for "greyed out but still legible on dark".
  -- Non-focusable and carrying no taskId, so these can never be selected or
  -- hand-picked by accident.
  if #matches == 0 then
    for _, ghost in ipairs(CATALOG_GHOST_ROWS) do
      local row = g_ui.createWidget('TaskCatalogEntry', list)
      row:setFocusable(false)
      row:setColor('#55534c')
      row:setText(ghost)
    end
  end

  for _, task in ipairs(matches) do
    local entry = g_ui.createWidget('TaskCatalogEntry', list)
    -- Show the kill count and level gate, phrased the same way the Offers tab
    -- phrases them ("Tier N - kill X - lvl Y+"), so a hand-picked task reads
    -- identically to an offered one. task.target is the LEVEL-SCALED count the
    -- server computed for this player, not a generic base number. Falls back to
    -- the old name-only row if talking to a server that doesn't send them yet.
    if task.target and task.minLevel then
      entry:setText(('[%d] %s (Tier %d - kill %d - lvl %d+)'):format(
        task.id, task.name, task.tier, task.target, task.minLevel))
    else
      entry:setText(('[%d] %s (Tier %d)'):format(task.id, task.name, task.tier))
    end
    entry.tierColor = CATALOG_TIER_COLOR[task.tier] or '#F0E6D2'
    entry:setColor(entry.tierColor)
    entry.taskId = task.id
    entry.taskName = task.name
  end

  panel:getChildById('chooseBtn'):setEnabled(false)
  applyCatalogActiveGrey()
end

-- Grey any catalog row whose task is already being hunted (reachable now that
-- v2 multi-slot lets the Catalog stay useful mid-hunt). The server refuses
-- the choose anyway - the grey is UX, not security, so the row stays
-- focusable. Runs after every fillCatalog AND after every state push, so
-- accepting or dropping with the Catalog open re-colours the visible rows
-- without needing a fresh search.
function applyCatalogActiveGrey()
  if not tabPanels.catalog then return end
  local list = tabPanels.catalog:getChildById('catalogList')
  for _, row in ipairs(list:getChildren()) do
    if row.taskId then
      if currentActiveIds[row.taskId] then
        if not row.activeGrey then
          row.activeGrey = true
          row:setColor('#5a5a5a')
          row:setTooltip(tr('You are already hunting these.'))
        end
      elseif row.activeGrey then
        row.activeGrey = nil
        row:setColor(row.tierColor or '#F0E6D2')
        row:removeTooltip()
      end
    end
  end
end

-- ============================================================================
-- Progress tab - streak/weekly/season pass status + season rankings, pushed
-- on-demand when the tab is opened (see init()'s onTabChange). data is nil
-- before the first push (window just opened, tab not yet visited).
-- Redesigned 2026-08-04 (Mizo: "the x/x numbers are just reading as text") -
-- three ProgressStatCard instances (big number + caption + bar/pips) instead
-- of plain sentence Labels the server's pre-formatted text got dumped into
-- verbatim. Needed raw numbers from the server to do this at all - see
-- onTaskProgressOpcode's payload comment for the new fields.
-- ============================================================================
local PASS_BAR_COLOR = '#7F77DD'   -- matches TIER_COLOR[3] above, for reuse
local WEEKLY_BAR_COLOR = '#378ADD' -- the bar's own long-standing color
local PIP_FILLED_COLOR = '#EFA83A'
local PIP_EMPTY_COLOR = '#4a453e'

-- Card hover tooltips (and the propagateCardTooltip helper that made them
-- actually work around child widgets swallowing the hover) were removed
-- 2026-08-04 - each card's visible statHint line now carries the same
-- explanation on screen, so the tooltip duplicated it.
local function setStatBar(card, color, numberText, captionText, percent)
  card:getChildById('pipRow'):setVisible(false)
  local bar = card:getChildById('statBar')
  bar:setVisible(true)
  bar:setBackgroundColor(color)
  bar:setPercent(percent)
  local numberLabel = card:getChildById('statNumber')
  numberLabel:setColor(color)
  numberLabel:setText(numberText)
  card:getChildById('statCaption'):setText(captionText)
end

local function setStatPips(card, numberText, captionText, filled, cap)
  card:getChildById('statBar'):setVisible(false)
  local pipRow = card:getChildById('pipRow')
  pipRow:setVisible(true)
  for i = 1, 5 do
    local pip = pipRow:getChildById('pip' .. i)
    pip:setVisible(i <= cap)
    if i <= cap then
      pip:setBackgroundColor(i <= filled and PIP_FILLED_COLOR or PIP_EMPTY_COLOR)
    end
  end
  card:getChildById('statNumber'):setColor(PIP_FILLED_COLOR)
  card:getChildById('statNumber'):setText(numberText)
  card:getChildById('statCaption'):setText(captionText)
end

function fillProgress(data)
  local panel = tabPanels.progress
  local streakCard = panel:getChildById('streakCard')
  local weeklyCard = panel:getChildById('weeklyCard')
  local passCard = panel:getChildById('passCard')

  if not data then
    setStatPips(streakCard, '0', tr('day streak'), 0, 3)
    setStatBar(weeklyCard, WEEKLY_BAR_COLOR, '0/0', tr('Weekly Challenge'), 0)
    setStatBar(passCard, PASS_BAR_COLOR, tr('Tier -/-'), tr('Season Pass'), 0)
    panel:getChildById('rankingsList'):destroyChildren()
    return
  end

  -- "day streak" reads fine at any count ("1 day streak", "7 day streak" -
  -- same compound-modifier shape as "5-day trip"), no singular/plural split
  -- needed.
  setStatPips(streakCard, tostring(data.streakDays), tr('day streak'),
    data.freezeTokens, math.max(1, data.freezeCap))
  streakCard:getChildById('statHint'):setText(
    tr('Every 5th day: free reroll. Every 7th: a freeze token. Every 15th: 50,000 gold + 15%% exp boost.'))

  local weeklyPercent = 0
  if data.weeklyTarget > 0 then
    weeklyPercent = math.min(100, math.floor(data.weeklyCount * 100 / data.weeklyTarget))
  end
  setStatBar(weeklyCard, WEEKLY_BAR_COLOR,
    ('%d/%d'):format(data.weeklyCount, data.weeklyTarget), tr('Weekly Challenge'), weeklyPercent)
  weeklyCard:getChildById('statHint'):setText(
    tr('5 tasks of any kind before Monday pays 50,000 gold + 10 min haste, automatically.'))

  -- Bar fills and resets PER TIER (prevThreshold -> nextThreshold) rather
  -- than crawling toward the season's final 70-task tier all season - see
  -- Tasks.getPassProgress's own comment for why. nextThreshold == 0 means
  -- every tier is already claimed.
  --
  -- Caption uses the SAME into/span numbers that drive the bar (Mizo bug
  -- report 2026-08-04, character Bubble: "Tier 2/10" next to "8/10 tasks
  -- this season" read as two competing fractions with the same denominator
  -- meaning different things - tier count vs. season-cumulative threshold -
  -- and the raw cumulative count didn't even match the bar's own fill %,
  -- since the bar is relative to the current tier's band, not the season
  -- total. Showing the tier-band numbers in both places keeps the caption
  -- honest about what the bar is visibly doing.
  local passPercent, passCaption = 100, tr('All tiers claimed!')
  if data.passNextThreshold > 0 then
    local span = data.passNextThreshold - data.passPrevThreshold
    local into = math.min(span, math.max(0, data.passSeasonTasks - data.passPrevThreshold))
    passPercent = span > 0 and math.floor(into * 100 / span) or 0
    passCaption = ('%d/%d tasks to Tier %d'):format(into, span, data.passTier + 1)
  end
  setStatBar(passCard, PASS_BAR_COLOR,
    ('Tier %d/%d'):format(data.passTier, data.passMaxTier), passCaption, passPercent)
  passCard:getChildById('statHint'):setText(data.passNextThreshold > 0
    and tr('Every task this season climbs the ladder - a reward waits at each of the 10 tiers.')
    or tr('All 10 tiers claimed this season - the ladder resets next month.'))

  local RANK_COLOR = { [1] = '#EFA83A', [2] = '#C0C0C0', [3] = '#CD7F32' } -- gold/silver/bronze
  local rankingsList = panel:getChildById('rankingsList')
  rankingsList:destroyChildren()
  local rank = 0
  for line in (data.rankingText .. '\n'):gmatch('(.-)\n') do
    if line ~= '' then
      rank = rank + 1
      local entry = g_ui.createWidget('TaskCatalogEntry', rankingsList)
      entry:setFocusable(false)
      entry:setText(line)
      if RANK_COLOR[rank] then
        entry:setColor(RANK_COLOR[rank])
      end
    end
  end
end

-- ============================================================================
-- Reward odds tab - real numbers, informational only, no buttons. Overhaul
-- 2026-08-04 (Mizo: "mention all the possible odds... all kinds of rewards
-- you get through the task system") - every tier's actual grind/rich payout
-- plus its Exp Boost Wallet ceiling, and a SEPARATE sigil/sliver section -
-- unlike gold/premium/wallet-ceiling, sigil odds do NOT scale with the
-- task's own reward tier (data/lib/tasks.lua's rollSigilDrop rolls ALL 5
-- sigil tiers independently on every completion, gating tiers III-V to rich
-- only) - the OLD one-row-per-tier layout conflated the two systems, since
-- "tier" happens to mean something different in each. Content here is
-- static (REWARD_POOL/SIGIL_DROP_CHANCE/WALLET_TIER_MAX are game-design
-- facts, not runtime state) - mirrors the server by hand rather than adding
-- a new payload just to describe numbers that rarely change.
-- ============================================================================
local ODDS_TIER_INFO = {
  [1] = { grind = 'Always: 50,000 gold', rich = 'Rich (3x/day): 75,000 gold + Haste',
          wallet = 'Rich also banks up to 15 min of exp bonus' },
  [2] = { grind = 'Always: 60,000 gold', rich = 'Rich (3x/day): 90,000 gold',
          wallet = 'Rich also banks up to 22 min of exp bonus' },
  [3] = { grind = 'Always: 75,000 gold', rich = 'Rich (3x/day): 115,000 gold + skill progress',
          wallet = 'Rich also banks up to 30 min of exp bonus' },
  [4] = { grind = 'Always: 90,000 gold', rich = 'Rich (3x/day): 140,000 gold + 1 premium day',
          wallet = 'Rich also banks up to 38 min of exp bonus' },
  [5] = { grind = 'Always: 110,000 gold', rich = 'Rich (3x/day): 175,000 gold + 2 premium days, a Tier III sigil, a golden trophy',
          wallet = 'Rich also banks up to 45 min of exp bonus' },
}

function fillOdds()
  local panel = tabPanels.odds
  -- recursiveGetChildById, NOT plain (Mizo bug report 2026-08-04: tab showed
  -- nothing at all) - oddsRow1-5/sigilText sit inside oddsScroll now (the
  -- new ScrollablePanel wrapper added for the overhaul), two levels below
  -- this panel, and plain getChildById only searches DIRECT children -
  -- silent nil, no error, so this whole function was a no-op the entire
  -- time. Same gotcha logged in [[reference-otui-gotchas]] #3.
  for tier = 1, 5 do
    local row = panel:recursiveGetChildById('oddsRow' .. tier)
    if row then
      local info = ODDS_TIER_INFO[tier]
      local tierLabel = row:getChildById('tierLabel')
      tierLabel:setText('TIER ' .. tier)
      tierLabel:setColor(TIER_COLOR[tier])
      row:getChildById('grindText'):setText(tr(info.grind))
      row:getChildById('richText'):setText(tr(info.rich))
      row:getChildById('walletText'):setText(tr(info.wallet))
    end
  end

  local sigilText = panel:recursiveGetChildById('sigilText')
  if sigilText then
    -- FATAL ERROR fix (Mizo 2026-08-04: "Unable to load module 'game_tasks'"
    -- - bad argument #2 to 'tr', crashing the ENTIRE module on load, not
    -- just this tab): tr() does its OWN string.format-style substitution
    -- internally (see 'Unlock %d more task slots' above) - it needs the RAW
    -- template plus the values as separate args. Pre-formatting with :format()
    -- first and handing tr() the ALREADY-substituted string (with real "%"
    -- characters left over from %% escapes) made tr() try to format THOSE
    -- as new placeholders with no args to match, and it throws rather than
    -- failing soft.
    sigilText:setText(tr(
      'Sigil I %d%% / Sigil II %d%% - every completion.\n'
      .. 'Sigil III/IV/V: %d%% / %d%% / %d%% - rich only.\n'
      .. 'Mana sliver 8%% / Mirror sliver 5%% - rich only.',
      SIGIL_CHANCE_BY_TIER[1], SIGIL_CHANCE_BY_TIER[2],
      SIGIL_CHANCE_BY_TIER[3], SIGIL_CHANCE_BY_TIER[4], SIGIL_CHANCE_BY_TIER[5]))
  end

  -- Reward economy pass (Mizo 2026-08-04) - static text, no dynamic values,
  -- so this is safe from the exact FATAL bug fixed just above: no pre-
  -- formatting, no stray "%" characters at all in this string to begin with.
  local bonusText = panel:recursiveGetChildById('bonusText')
  if bonusText then
    bonusText:setText(tr(
      'Every task: free Haste burst, no claim needed.\n'
      .. 'Weekly (5 tasks): gold, haste, wallet minutes.\n'
      .. 'Plus a Sigil I/II chance and sometimes a skill boost.\n'
      .. 'Day 15 streak: gold, exp boost, Sigil I chance.\n'
      .. 'Day 30 streak: Sigil III guaranteed, wallet minutes.\n'
      .. 'Plus a Sigil IV/V chance.\n'
      .. 'Season Pass: 11 tiers, gold and premium days.\n'
      .. 'Past tier 11: a bonus roll every 10 tasks.'))
  end
end
