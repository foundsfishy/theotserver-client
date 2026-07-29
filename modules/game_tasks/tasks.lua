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
local CATALOG_GHOST_ROWS = {
  '[--] Nnnrrmm Vhaalk (Tier -)',
  '[--] Skrenn (Tier -)',
  '[--] Ghorrum Slaath (Tier -)',
  '[--] Vaelmirr Dhun (Tier -)',
  '[--] Prakk (Tier -)',
  '[--] Ithreneth Corr (Tier -)',
  '[--] Mmurgash (Tier -)',
  '[--] Xhalvinn Traak (Tier -)',
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

  fillOffers(offers, wish)
  fillActive(active)
end

-- "<chooseCost>|<id>,<name>,<tier>;..." (empty after the '|' if no matches).
function onTaskCatalogOpcode(protocol, opcode, buffer)
  local costStr, matchesStr = buffer:match('^(%d+)|(.*)$')
  if not costStr then return end

  local matches = {}
  if matchesStr ~= '' then
    for entry in (matchesStr .. ';'):gmatch('(.-);') do
      local id, name, tier = entry:match('^(%d+),(.-),(%d+)$')
      if id then
        matches[#matches + 1] = { id = tonumber(id), name = name, tier = tonumber(tier) }
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
  tabPanels.hunt     = g_ui.createWidget('TasksHuntPanel')
  tabPanels.progress = g_ui.createWidget('TasksProgressPanel')
  tabPanels.odds     = g_ui.createWidget('TasksOddsPanel')

  tasksTabBar:addTab(tr('Offers'), tabPanels.offers)
  tasksTabBar:addTab(tr('Active Task'), tabPanels.active)
  catalogTab = tasksTabBar:addTab(tr('Catalog'), tabPanels.catalog)
  tasksTabBar:addTab(tr('Hunt'), tabPanels.hunt)
  progressTab = tasksTabBar:addTab(tr('Progress'), tabPanels.progress)
  tasksTabBar:addTab(tr('Reward Odds'), tabPanels.odds)

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
function fillOffers(offers, wishTask)
  local panel = tabPanels.offers

  -- Wish of the Day only (Grand Wish/weekly is a separate slot the payload
  -- doesn't carry yet - TODO if this tab ever needs it live).
  local wish = panel:recursiveGetChildById('wishBanner')
  wish:getChildById('label'):setText(tr('Wish of the day - Free'))
  if wishTask then
    wish:getChildById('name'):setText(('%s (Tier %d, kill %d, lvl %d+)'):format(
      wishTask.name, wishTask.tier, wishTask.target, wishTask.minLevel))
    local wishAccept = wish:getChildById('accept')
    wishAccept:setEnabled(true)
    wishAccept.onClick = function()
      sendTaskAction('accept,' .. wishTask.id)
    end
  else
    wish:getChildById('name'):setText(tr('No wish available'))
    wish:getChildById('accept'):setEnabled(false)
  end

  for i = 1, 5 do
    local slot = panel:recursiveGetChildById('slot' .. i)
    if slot then
      local offer = offers and offers[i]
      local acceptBtn = slot:getChildById('accept')
      local rerollBtn = slot:getChildById('reroll')
      local creature = slot:getChildById('creature')
      if offer then
        slot:getChildById('name'):setText(offer.name)
        slot:getChildById('name'):setColor(TIER_COLOR[offer.tier] or '#ffffff')
        slot:getChildById('info'):setText(('Tier %d - kill %d - lvl %d+'):format(offer.tier, offer.target, offer.minLevel))
        rerollBtn:setText(tr('Reroll') .. ' ' .. goldText(REROLL_COST_BY_TIER[offer.tier] or 0))
        acceptBtn:setEnabled(true)
        rerollBtn:setEnabled(true)
        if offer.outfit and offer.outfit.type and offer.outfit.type > 0 then
          creature:setOutfit(offer.outfit)
        end
      else
        slot:getChildById('name'):setText(tr('No offer'))
        slot:getChildById('name'):setColor('#888888')
        slot:getChildById('info'):setText('-')
        rerollBtn:setText(tr('Reroll'))
        acceptBtn:setEnabled(false)
        rerollBtn:setEnabled(false)
        creature:setOutfit({type = 0})
      end

      rerollBtn.onClick = function()
        sendTaskAction('reroll,' .. i)
      end
      acceptBtn.onClick = function()
        if offer then
          sendTaskAction('accept,' .. offer.id)
        end
      end
    end
  end

  panel:recursiveGetChildById('shuffle').onClick = function()
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
    faqirBubble:getChildById('faqirBubbleText'):setText(tr('Choose a hunt from offers.'))
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
    entry:setText(('[%d] %s (Tier %d)'):format(task.id, task.name, task.tier))
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
