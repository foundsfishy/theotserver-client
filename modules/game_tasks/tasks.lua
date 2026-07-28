-- Faqir's Tasks window - a third front door onto the same data/lib/tasks.lua
-- module !task and the Faqir NPC already use. Nothing here invents new
-- server logic; every button is meant to call the exact same Tasks.*
-- functions those two already call.
--
-- PHASE A: window + tabs. Offers and Active task now render REAL data, pushed
-- by Player.sendTaskState (data/lib/core/player.lua) over opcode 72 - on
-- login, and after any accept/drop/reroll/shuffle/choose. It does NOT yet
-- update on every kill, so progress is as of the last push, not tick-by-tick.
-- Catalog/Hunt/Progress tabs are still static placeholders.
-- PHASE B (next): every button below sends a small write-opcode that
-- resolves to Tasks.acceptTask/rerollOffer/etc. - see the TODO markers.

tasksWindow = nil
tasksButton = nil
local tasksTabBar = nil
local tabPanels = {}

-- Real numbers from data/lib/tasks.lua (2026-07-27 reroll retier). These are
-- server-wide constants (not per-player), so showing them directly here -
-- rather than waiting on a push - is accurate from the moment the window opens.
local REROLL_COST_BY_TIER = { [1] = 20000, [2] = 40000, [3] = 60000, [4] = 80000, [5] = 100000 }
local SIGIL_CHANCE_BY_TIER = { [1] = 40, [2] = 18, [3] = 40, [4] = 15, [5] = 5 }
local TIER_COLOR = {
  [1] = '#639922', [2] = '#378ADD', [3] = '#7F77DD', [4] = '#EF9F27', [5] = '#E24B4A',
}

-- Matches Player.sendTaskState's TASKSTATE_OPCODE in data/lib/core/player.lua -
-- keep both in sync if this number ever changes.
TASKSTATE_OPCODE = 72

-- "<id>,<name>,<tier>,<target>,<minLevel>;...(x5, '-1' if empty)|<active>"
-- active is "none" or "<id>,<name>,<progress>,<target>".
function onTaskStateOpcode(protocol, opcode, buffer)
  local offersStr, activeStr = buffer:match('^(.-)|(.*)$')
  if not offersStr then return end

  local offers = {}
  local slot = 0
  for entry in (offersStr .. ';'):gmatch('(.-);') do
    slot = slot + 1
    if entry ~= '-1' and entry ~= '' then
      local id, name, tier, target, minLevel = entry:match('^(%d+),(.-),(%d+),(%d+),(%d+)$')
      if id then
        offers[slot] = {
          id = tonumber(id), name = name, tier = tonumber(tier),
          target = tonumber(target), minLevel = tonumber(minLevel),
        }
      end
    end
  end

  local active = nil
  if activeStr and activeStr ~= 'none' then
    local id, name, progress, target = activeStr:match('^(%d+),(.-),(%d+),(%d+)$')
    if id then
      active = { id = tonumber(id), name = name, progress = tonumber(progress), target = tonumber(target) }
    end
  end

  fillOffers(offers)
  fillActive(active)
end

function init()
  connect(g_game, { onGameEnd = offline })

  tasksButton = modules.client_topmenu.addRightGameToggleButton(
    'tasksButton', tr("Faqir's Tasks"), '/images/topbuttons/questlog', toggle)
  tasksButton:setOn(false)

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
  tasksTabBar:addTab(tr('Active task'), tabPanels.active)
  tasksTabBar:addTab(tr('Catalog'), tabPanels.catalog)
  tasksTabBar:addTab(tr('Hunt'), tabPanels.hunt)
  tasksTabBar:addTab(tr('Progress'), tabPanels.progress)
  tasksTabBar:addTab(tr('Reward odds'), tabPanels.odds)

  -- Empty state until the first push arrives (login, or manually forcing
  -- this module to load while already in-game won't have one yet - a relog
  -- triggers the push since it only fires from data/creaturescripts/scripts/
  -- login.lua today).
  fillOffers(nil)
  fillActive(nil)
  fillOdds()

  pcall(ProtocolGame.registerExtendedOpcode, TASKSTATE_OPCODE, onTaskStateOpcode)
end

function terminate()
  disconnect(g_game, { onGameEnd = offline })
  pcall(ProtocolGame.unregisterExtendedOpcode, TASKSTATE_OPCODE)
  if tasksButton then tasksButton:destroy() end
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
  end
end

-- ============================================================================
-- Offers tab - offers is nil (nothing pushed yet) or a table keyed 1-5,
-- any of which may itself be nil (that slot came back empty from the server).
-- ============================================================================
function fillOffers(offers)
  local panel = tabPanels.offers

  -- Wish of the Day/Grand Wish aren't in the opcode 72 payload yet (only the
  -- 5 core offers + active task) - shown as a neutral not-yet-wired state
  -- rather than a fake specific monster, so nothing here claims to be real
  -- before it is. TODO: add these to the push once this tab needs them live.
  local wish = panel:recursiveGetChildById('wishBanner')
  wish:getChildById('label'):setText(tr('Wish of the day'))
  wish:getChildById('name'):setText(tr('(not wired up yet)'))
  wish:getChildById('accept'):setEnabled(false)

  for i = 1, 5 do
    local slot = panel:recursiveGetChildById('slot' .. i)
    if slot then
      local offer = offers and offers[i]
      local acceptBtn = slot:getChildById('accept')
      local rerollBtn = slot:getChildById('reroll')
      if offer then
        slot:getChildById('name'):setText(offer.name)
        slot:getChildById('name'):setColor(TIER_COLOR[offer.tier] or '#ffffff')
        slot:getChildById('info'):setText(('Tier %d - kill %d - lvl %d+'):format(offer.tier, offer.target, offer.minLevel))
        rerollBtn:setText(tr('Reroll') .. ' ' .. (REROLL_COST_BY_TIER[offer.tier] or 0) .. 'g')
        acceptBtn:setEnabled(true)
        rerollBtn:setEnabled(true)
      else
        slot:getChildById('name'):setText(tr('No offer'))
        slot:getChildById('name'):setColor('#888888')
        slot:getChildById('info'):setText('-')
        rerollBtn:setText(tr('Reroll'))
        acceptBtn:setEnabled(false)
        rerollBtn:setEnabled(false)
      end

      rerollBtn.onClick = function()
        -- TODO Phase B: send opcode(reroll, i) -> Tasks.rerollOffer
      end
      acceptBtn.onClick = function()
        -- TODO Phase B: send opcode(accept, offers[i].id) -> Tasks.acceptTask
      end
    end
  end

  panel:recursiveGetChildById('shuffle').onClick = function()
    -- TODO Phase B: send opcode(shuffle) -> Tasks.shuffleOffers
  end
end

-- ============================================================================
-- Active task tab - active is nil (no task, or nothing pushed yet) or
-- {id, name, progress, target}.
-- ============================================================================
function fillActive(active)
  local panel = tabPanels.active
  local dropBtn = panel:getChildById('drop')

  if active then
    panel:getChildById('name'):setText(active.name)
    panel:getChildById('progressText'):setText(('%d / %d killed'):format(active.progress, active.target))
    local percent = 0
    if active.target > 0 then
      percent = math.min(100, math.floor(active.progress * 100 / active.target))
    end
    panel:getChildById('progress'):setPercent(percent)
    dropBtn:setEnabled(true)
  else
    panel:getChildById('name'):setText(tr('No active task'))
    panel:getChildById('progressText'):setText('-')
    panel:getChildById('progress'):setPercent(0)
    dropBtn:setEnabled(false)
  end

  -- TODO: not in the opcode 72 payload yet (warrior ladder milestone state) -
  -- left blank rather than showing a fake number.
  panel:getChildById('ladderTeaser'):setText('')

  dropBtn.onClick = function()
    -- TODO Phase B: send opcode(drop) -> Tasks.dropTask
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
