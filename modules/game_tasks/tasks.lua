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

tasksWindow = nil
tasksButton = nil
local tasksTabBar = nil
local tabPanels = {}
-- File-scope so refreshCurrentTab() (called from toggle()) can tell which tab
-- is showing without re-deriving it from the tab bar's children.
local catalogTab = nil
local progressTab = nil

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

-- Which active task id has already played its full "just accepted" sequence
-- (blink-then-move) in the Offers tab - guards against replaying it on the
-- per-kill state pushes that follow while that same task is running.
local lastFlashedActiveId = nil
-- Which active task id has a blink-then-move IN PROGRESS. A kill can land
-- (and push a fresh opcode 72 state) mid-blink, before the deferred move has
-- fired - without this guard that re-entrant fillOffers call would see the
-- row not yet at top and try to move it AGAIN mid-animation. While pending,
-- fillOffers skips both re-flashing and re-moving; the row's text/colour
-- still update normally every push, only the position is held.
local pendingMoveActiveId = nil

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
local GLOW_BORDER = '#FAC775'
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
  [1] = '#639922', [2] = '#378ADD', [3] = '#7F77DD', [4] = '#EF9F27', [5] = '#E24B4A',
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
local CATALOG_GHOST_ROWS = {
  '[--] Nnnrrmm Vhaalk (Tier - - kill -- - lvl --+)',
  '[--] Skrenn (Tier - - kill -- - lvl --+)',
  '[--] Ghorrum Slaath (Tier - - kill -- - lvl --+)',
  '[--] Vaelmirr Dhun (Tier - - kill -- - lvl --+)',
  '[--] Prakk (Tier - - kill -- - lvl --+)',
  '[--] Ithreneth Corr (Tier - - kill -- - lvl --+)',
  '[--] Mmurgash (Tier - - kill -- - lvl --+)',
  '[--] Xhalvinn Traak (Tier - - kill -- - lvl --+)',
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
    outfit = {
      type = tonumber(lookType), head = tonumber(head), body = tonumber(body),
      legs = tonumber(legs), feet = tonumber(feet), addons = tonumber(addons),
    },
  }
end

-- "<offer entry>;...(x5, '-1' if empty)|<wish entry, or -1>|<active>". active
-- is "none" or "<id>,<name>,<progress>,<target>,<lookType>,<head>,<body>,
-- <legs>,<feet>,<addons>".
function onTaskStateOpcode(protocol, opcode, buffer)
  local offersStr, wishStr, activeStr = buffer:match('^(.-)|(.-)|(.*)$')
  if not offersStr then return end

  local offers = {}
  local slot = 0
  for entry in (offersStr .. ';'):gmatch('(.-);') do
    slot = slot + 1
    offers[slot] = parseTaskEntry(entry)
  end

  local wish = parseTaskEntry(wishStr)

  local active = nil
  if activeStr and activeStr ~= 'none' then
    local id, name, progress, target, lookType, head, body, legs, feet, addons =
      activeStr:match('^(%d+),(.-),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)$')
    if id then
      active = {
        id = tonumber(id), name = name, progress = tonumber(progress), target = tonumber(target),
        outfit = {
          type = tonumber(lookType), head = tonumber(head), body = tonumber(body),
          legs = tonumber(legs), feet = tonumber(feet), addons = tonumber(addons),
        },
      }
    end
  end

  -- active is passed to fillOffers too: the accepted task STAYS in the offer
  -- slots (Tasks.acceptTask never clears them), so Offers needs to know which
  -- row is the one being worked.
  fillOffers(offers, wish, active)
  fillActive(active)
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

-- 6 pipe-joined fields: streakText|weeklyText|weeklyCount|weeklyTarget|
-- passText|rankingText (rankingText may itself contain real newlines - it's
-- last, so that's safe).
function onTaskProgressOpcode(protocol, opcode, buffer)
  -- Numeric fields accept an optional decimal tail ("3" or "3.0"). The server
  -- pins them to integers, but a Lua storage value can surface as a float and
  -- a strict %d+ here silently blanked the ENTIRE tab over one stray ".0" -
  -- too brittle for a display-only path.
  local streakText, weeklyText, weeklyCount, weeklyTarget, passText, rankingText =
    buffer:match('^(.-)|(.-)|([%d%.]+)|([%d%.]+)|(.-)|(.*)$')
  if not streakText then return end

  fillProgress({
    streakText = streakText,
    weeklyText = weeklyText,
    weeklyCount = math.floor(tonumber(weeklyCount) or 0),
    weeklyTarget = math.floor(tonumber(weeklyTarget) or 0),
    passText = passText,
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

  tasksTabBar:addTab(tr('Offers'), tabPanels.offers)
  tasksTabBar:addTab(tr('Active Task'), tabPanels.active)
  catalogTab = tasksTabBar:addTab(tr('Catalog'), tabPanels.catalog)
  progressTab = tasksTabBar:addTab(tr('Progress'), tabPanels.progress)
  tasksTabBar:addTab(tr('Reward Odds'), tabPanels.odds)

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
  fillOffers(nil, nil)
  fillActive(nil)
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
  if tasksWindow then tasksWindow:destroy() end
  tasksButton = nil
  tasksWindow = nil
end

function offline()
  if tasksWindow then tasksWindow:hide() end
  if tasksButton then tasksButton:setOn(false) end
  -- lastFlashedActiveId is deliberately NOT reset here. Module-local Lua state
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
    -- Progress data is fetched on demand (opcode 75), so reopening the window
    -- with Progress ALREADY the selected tab would otherwise show whatever was
    -- true last time it was opened - onTabChange never fires when the tab
    -- doesn't actually change.
    refreshCurrentTab()
  end
end

-- Re-fetch whatever the visible tab needs. Offers/Active are server-pushed
-- (opcode 72) and always current, so only Progress needs an explicit pull.
function refreshCurrentTab()
  if not tasksTabBar then return end
  if tasksTabBar:getCurrentTab() == progressTab then
    sendTaskAction('progress')
  end
end

-- ============================================================================
-- Offers tab - offers is nil (nothing pushed yet) or a table keyed 1-5,
-- any of which may itself be nil (that slot came back empty from the server).
-- ============================================================================
function fillOffers(offers, wishTask, active)
  local panel = tabPanels.offers
  local hasActive = active ~= nil
  -- Computed BEFORE the slot loop (not inside the post-loop reorder block,
  -- which runs after this text is already set) so the accept button shows
  -- "MOVED UP" from the very first render of a fresh accept, not one push
  -- late. True for every push while the blink-then-move sequence is either
  -- about to start or already running for this task id.
  local isFreshAccept = hasActive and lastFlashedActiveId ~= active.id

  -- Wish of the Day only (Grand Wish/weekly is a separate slot the payload
  -- doesn't carry yet - TODO if this tab ever needs it live).
  local wish = panel:recursiveGetChildById('wishBanner')
  wish:getChildById('label'):setText(tr('Wish of the day - Free'))
  if wishTask then
    wish:getChildById('name'):setText(('%s (Tier %d, kill %d, lvl %d+)'):format(
      wishTask.name, wishTask.tier, wishTask.target, wishTask.minLevel))
    local wishAccept = wish:getChildById('accept')
    -- The engine refuses any accept while a task is running, so the Wish's
    -- Accept is disabled too rather than left to fail with an error message.
    wishAccept:setEnabled(not hasActive)
    wishAccept.onClick = function()
      sendTaskAction('accept,' .. wishTask.id)
    end
  else
    wish:getChildById('name'):setText(tr('No wish available'))
    wish:getChildById('accept'):setEnabled(false)
  end

  local activeSlotWidget = nil

  for i = 1, 5 do
    local slot = panel:recursiveGetChildById('slot' .. i)
    if slot then
      local offer = offers and offers[i]
      local acceptBtn = slot:getChildById('accept')
      local rerollBtn = slot:getChildById('reroll')
      local creature = slot:getChildById('creature')
      local isActiveOffer = offer and active and offer.id == active.id
      if isActiveOffer then activeSlotWidget = slot end
      if offer then
        slot:getChildById('name'):setText(
          offer.name .. (isActiveOffer and '  [ACTIVE]' or ''))
        slot:getChildById('info'):setText(('Tier %d - kill %d - lvl %d+'):format(offer.tier, offer.target, offer.minLevel))
        rerollBtn:setText(tr('Reroll') .. ' ' .. goldText(REROLL_COST_BY_TIER[offer.tier] or 0))
        -- Disabled while a task runs (Mizo 2026-07-29, reversing the earlier
        -- confirm-dialog approach): rerolling the active task's own slot
        -- orphans it out of the offer list entirely, and nothing else in the
        -- tab marks it as still running once that happens - five dead grey
        -- rows with no explanation. Disabling this (and Shuffle, below) makes
        -- Offers fully read-only while hunting, so that state can never occur.
        rerollBtn:setEnabled(not hasActive)

        -- State is carried by CONTRAST, not by a new colour: with a task
        -- running the other rows dim and this one stays at full brightness.
        -- Deliberately not "tint the accepted row green" - Tier 1 already IS
        -- green (#639922), so a green state marker would be indistinguishable
        -- from tier language on exactly the rows most likely to be accepted.
        if isActiveOffer then
          slot:setOpacity(1.0)
          slot:getChildById('name'):setColor(TIER_COLOR[offer.tier] or '#ffffff')
          slot:getChildById('info'):setColor('#aaaaaa')
          -- The Accept button here can never work (the engine refuses a second
          -- accept), and it is the biggest element in the row - so it becomes
          -- the live kill count instead of dead disabled chrome. Updates on
          -- every kill for free, since opcode 72 already pushes per-kill.
          -- During the blink-then-move sequence it shows "^ MOVED UP" instead -
          -- see flashActiveOffer's onDone, which switches it to the counter
          -- the instant the blink ends rather than waiting on the next kill.
          if isFreshAccept then
            acceptBtn:setText(tr('^ MOVED UP'))
          else
            acceptBtn:setText(('%d / %d'):format(active.progress, active.target))
          end
          acceptBtn:setEnabled(false)
        else
          -- Dim BOTH ways on purpose: setOpacity is not verified to cascade to
          -- child widgets in this client (no C++ source here to check), so the
          -- de-emphasis is also applied as explicit colours. If opacity does
          -- cascade the row just dims a little further; if it does not, the
          -- contrast still lands. Never rely on the opacity alone.
          slot:setOpacity(hasActive and 0.45 or 1.0)
          if hasActive then
            slot:getChildById('name'):setColor('#5a5a5a')
            slot:getChildById('info'):setColor('#4a4a4a')
          else
            slot:getChildById('name'):setColor(TIER_COLOR[offer.tier] or '#ffffff')
            slot:getChildById('info'):setColor('#aaaaaa')
          end
          acceptBtn:setText(tr('Accept'))
          -- Disabled while a task runs because the ENGINE refuses it - leaving
          -- it clickable meant five live buttons that all failed with
          -- "You already have an active task."
          acceptBtn:setEnabled(not hasActive)
        end

        if offer.outfit and offer.outfit.type and offer.outfit.type > 0 then
          creature:setOutfit(offer.outfit)
        end
      else
        slot:setOpacity(1.0)
        acceptBtn:setText(tr('Accept'))
        slot:getChildById('name'):setText(tr('No offer'))
        slot:getChildById('name'):setColor('#888888')
        slot:getChildById('info'):setText('-')
        rerollBtn:setText(tr('Reroll'))
        acceptBtn:setEnabled(false)
        rerollBtn:setEnabled(false) -- already disabled: an empty slot has nothing to reroll
        creature:setOutfit({type = 0})
      end

      rerollBtn.onClick = function()
        -- Reroll is disabled above whenever hasActive, so this can only fire
        -- with no task running - no confirm needed, nothing here can orphan
        -- the active task out of the offer list.
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
  -- itself is DEFERRED until after the glow+star plays at the row's original
  -- spot (see flashActiveOffer above) - moving it in the same instant as the
  -- click meant the indicator only ever appeared after the row had already
  -- jumped, which read as no indicator at all.
  local offersScroll = panel:getChildById('offersScroll')
  if activeSlotWidget and offersScroll then
    local id = active.id
    if lastFlashedActiveId == id then
      -- Sequence already finished on an earlier push - keep it pinned at top
      -- on every subsequent state push (a later fillOffers call could
      -- otherwise leave it wherever the server slot array put it).
      offersScroll:moveChildToIndex(activeSlotWidget, offersScroll:getChildIndex(wish) + 1)
    elseif pendingMoveActiveId ~= id then
      -- Brand new accept: glow in place first, THEN move.
      pendingMoveActiveId = id
      flashActiveOffer(activeSlotWidget, function()
        offersScroll:moveChildToIndex(activeSlotWidget, offersScroll:getChildIndex(wish) + 1)
        pendingMoveActiveId = nil
        lastFlashedActiveId = id
        -- Switch the counter on immediately rather than waiting for the next
        -- opcode 72 push (the next kill could be a while away) - the button
        -- would otherwise keep reading "^ MOVED UP" long after it stopped
        -- being true.
        local acceptBtn = activeSlotWidget:getChildById('accept')
        if acceptBtn then
          acceptBtn:setText(('%d / %d'):format(active.progress, active.target))
        end
      end)
    end
    -- else: glow already in progress for this id - a kill landed mid-sequence
    -- and re-pushed state. Do nothing here; the scheduled callback above will
    -- still fire and move it once, at the original time.
  else
    lastFlashedActiveId = nil
    pendingMoveActiveId = nil
  end

  local shuffleBtn = panel:recursiveGetChildById('shuffle')
  -- Disabled while a task runs, same reasoning as Reroll above: shuffle
  -- replaces ALL five offers, always including the active task's, so leaving
  -- it live would orphan the active task out of the list every time.
  shuffleBtn:setEnabled(not hasActive)
  shuffleBtn.onClick = function()
    sendTaskAction('shuffle')
  end

end

-- ============================================================================
-- Active task tab - active is nil (no task, or nothing pushed yet) or
-- {id, name, progress, target}.
-- ============================================================================
-- Faqir the Wise's real outfit (data/npc/Faqir the Wise.xml on the server) -
-- outfits aren't remapped server/client like item ids are, so this look type
-- is safe to pass straight to setOutfit().
local FAQIR_OUTFIT = { type = 103, head = 20, body = 30, legs = 40, feet = 50, addons = 0 }
local FAQIR_MATERIALIZE_MS = 500
local FAQIR_SIZE = 128
local FAQIR_START_SIZE = 48

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

-- Only replay the materialize animation on the ACTUAL transition into the
-- empty state, not every opcode 72 push while it's already showing (the
-- server can re-send state for unrelated reasons - the window shouldn't
-- restart the animation every time that happens while the player is just
-- sitting on the tab).
local wasShowingEmptyState = nil

function fillActive(active)
  local panel = tabPanels.active
  -- Sprite/name/progressText/drop live inside the activeCard wrapper (matching
  -- OfferSlot's card look), so these need a recursive lookup; the progress bar
  -- sits outside it, but recursive finds a direct child too.
  local activeCard = panel:getChildById('activeCard')
  local dropBtn = panel:recursiveGetChildById('drop')
  local creature = panel:recursiveGetChildById('creature')
  local nameLabel = panel:recursiveGetChildById('name')
  local progressTextLabel = panel:recursiveGetChildById('progressText')
  local progressBar = panel:recursiveGetChildById('progress')
  local faqirBubble = panel:getChildById('faqirBubble')
  local faqirCreature = panel:getChildById('faqirCreature')

  if active then
    wasShowingEmptyState = false
    activeCard:setVisible(true)
    faqirBubble:setVisible(false)
    faqirCreature:setVisible(false)

    nameLabel:setText(active.name)
    nameLabel:setColor('#dfdfdf')
    progressTextLabel:setText(('%d / %d killed'):format(active.progress, active.target))
    local percent = 0
    if active.target > 0 then
      percent = math.min(100, math.floor(active.progress * 100 / active.target))
    end
    progressBar:setPercent(percent)
    progressBar:setVisible(true)
    dropBtn:setVisible(true)
    if active.outfit and active.outfit.type and active.outfit.type > 0 then
      creature:setOutfit(active.outfit)
    end
  else
    -- Empty state: the card (and its Drop button/bar) disappears entirely
    -- rather than showing a disabled button next to an empty bar - both
    -- described a task that doesn't exist. Faqir himself, big, with a
    -- speech bubble carrying the message, fills that space instead.
    activeCard:setVisible(false)
    progressBar:setVisible(false)

    faqirBubble:setVisible(true)
    faqirCreature:setVisible(true)
    faqirBubble:getChildById('faqirBubbleTitle'):setText(tr('Faqir waits.'))
    faqirBubble:getChildById('faqirBubbleText'):setText(tr('Choose a task from the offers Tab.'))
    faqirCreature:setOutfit(FAQIR_OUTFIT)

    if wasShowingEmptyState ~= true then
      materializeFaqir(faqirCreature)
    end
    wasShowingEmptyState = true
  end

  dropBtn.onClick = function()
    -- Mizo 2026-07-28: confirm before dropping - an accidental click loses an
    -- in-progress task with no undo. UIMessageBox's own addButton() does NOT
    -- auto-close on click (only :ok()/:cancel() do that) - every path here
    -- (Yes/No/Escape/Enter) explicitly destroys the box itself.
    -- Enter/Escape/No all cancel, never confirm, so an accidental keypress
    -- can't do the destructive thing this dialog exists to prevent.
    local box
    local function cancel() box:destroy() end
    local function confirm() sendTaskAction('drop'); box:destroy() end

    box = displayGeneralBox(tr('Drop Task'), tr('Are you sure you want to drop this task?'), {
      { text = tr('Yes'), callback = confirm },
      { text = tr('No'), callback = cancel },
      anchor = AnchorHorizontalCenter,
    }, cancel, cancel)
  end
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
  -- in a near-background grey, so the eye reads "content lives here" without
  -- being able to read any of it. Non-focusable and carrying no taskId, so
  -- they can never be selected or hand-picked by accident.
  if #matches == 0 then
    for _, ghost in ipairs(CATALOG_GHOST_ROWS) do
      local row = g_ui.createWidget('TaskCatalogEntry', list)
      row:setFocusable(false)
      row:setColor('#33312c')
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
    entry:setColor(CATALOG_TIER_COLOR[task.tier] or '#dfdfdf')
    entry.taskId = task.id
    entry.taskName = task.name
  end

  panel:getChildById('chooseBtn'):setEnabled(false)
end

-- ============================================================================
-- Progress tab - streak/weekly/season pass status + season rankings, pushed
-- on-demand when the tab is opened (see init()'s onTabChange). data is nil
-- before the first push (window just opened, tab not yet visited).
-- ============================================================================
function fillProgress(data)
  local panel = tabPanels.progress

  if not data then
    panel:getChildById('streakLabel'):setText(tr('Streak'))
    panel:getChildById('weeklyLabel'):setText(tr('Weekly challenge'))
    panel:getChildById('weeklyProgress'):setPercent(0)
    panel:getChildById('passLabel'):setText(tr('Season pass'))
    panel:getChildById('rankingsList'):destroyChildren()
    return
  end

  panel:getChildById('streakLabel'):setText(data.streakText)
  panel:getChildById('weeklyLabel'):setText(data.weeklyText)
  local percent = 0
  if data.weeklyTarget > 0 then
    percent = math.min(100, math.floor(data.weeklyCount * 100 / data.weeklyTarget))
  end
  panel:getChildById('weeklyProgress'):setPercent(percent)
  panel:getChildById('passLabel'):setText(data.passText)

  local RANK_COLOR = { [1] = '#FFD700', [2] = '#C0C0C0', [3] = '#CD7F32' } -- gold/silver/bronze
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
-- Reward odds tab - real numbers, informational only, no buttons
-- ============================================================================
function fillOdds()
  local panel = tabPanels.odds
  for tier = 1, 5 do
    local row = panel:getChildById('oddsRow' .. tier)
    if row then
      row:getChildById('tierLabel'):setText('Tier ' .. tier)
      row:getChildById('tierLabel'):setColor(TIER_COLOR[tier])
      row:getChildById('rewardText'):setText(SIGIL_CHANCE_BY_TIER[tier] .. '% sigil chance on completion')
      row:getChildById('sigilBar'):setPercent(SIGIL_CHANCE_BY_TIER[tier])
    end
  end
end
