-- Faqir's Tasks window - a third front door onto the same data/lib/tasks.lua
-- module !task and the Faqir NPC already use. Nothing here invents new
-- server logic; every button is meant to call the exact same Tasks.*
-- functions those two already call.
--
-- PHASE A (this file, as first built): window + tabs render with STATIC
-- placeholder data. No opcode exists yet, no button is wired to the server.
-- Safe to test purely as a UI shell before any server-side risk.
-- PHASE B (next): a state-push opcode feeds real data in, and each button
-- sends a small write-opcode that resolves to Tasks.acceptTask/rerollOffer/
-- etc. - see the TODO markers below for exactly where that plugs in.

tasksWindow = nil
tasksButton = nil
local tasksTabBar = nil
local tabPanels = {}

-- Real numbers from data/lib/tasks.lua (2026-07-27 reroll retier) - kept
-- here ONLY as Phase A placeholder data. Once the state-push opcode exists,
-- these get replaced by whatever the server actually sends, per player.
local REROLL_COST_BY_TIER = { [1] = 20000, [2] = 40000, [3] = 60000, [4] = 80000, [5] = 100000 }
local SIGIL_CHANCE_BY_TIER = { [1] = 40, [2] = 18, [3] = 40, [4] = 15, [5] = 5 }
local TIER_COLOR = {
  [1] = '#639922', [2] = '#378ADD', [3] = '#7F77DD', [4] = '#EF9F27', [5] = '#E24B4A',
}

local PLACEHOLDER_OFFERS = {
  { slot = 1, name = 'Cyclops',     tier = 2, target = 220, minLevel = 25 },
  { slot = 2, name = 'Minotaur',    tier = 1, target = 450, minLevel = 8  },
  { slot = 3, name = 'Dragon Lord', tier = 4, target = 80,  minLevel = 60 },
  { slot = 4, name = 'Demon',       tier = 5, target = 40,  minLevel = 80 },
  { slot = 5, name = 'Troll',       tier = 1, target = 450, minLevel = 8  },
}

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

  fillOffers()
  fillActive()
  fillOdds()

  -- TODO Phase B: register the state-push opcode here, e.g.
  -- ProtocolGame.registerExtendedOpcode(TASK_STATE_OPCODE, onTaskStateOpcode)
  -- and call fill*() from that handler instead of once at init with
  -- placeholder data.
end

function terminate()
  disconnect(g_game, { onGameEnd = offline })
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
-- Offers tab
-- ============================================================================
function fillOffers()
  local panel = tabPanels.offers
  local wish = panel:getChildById('wishBanner')
  wish:getChildById('label'):setText(tr('Wish of the day - free'))
  wish:getChildById('name'):setText('Dragon')
  wish:getChildById('accept').onClick = function()
    -- TODO Phase B: send an accept-wish opcode -> Tasks.acceptTask server-side
  end

  for _, offer in ipairs(PLACEHOLDER_OFFERS) do
    local slot = panel:getChildById('slot' .. offer.slot)
    if slot then
      slot:getChildById('name'):setText(offer.name)
      slot:getChildById('name'):setColor(TIER_COLOR[offer.tier])
      slot:getChildById('info'):setText(('Tier %d - kill %d - lvl %d+'):format(offer.tier, offer.target, offer.minLevel))

      local rerollBtn = slot:getChildById('reroll')
      rerollBtn:setText(tr('Reroll') .. ' ' .. REROLL_COST_BY_TIER[offer.tier] .. 'g')
      rerollBtn.onClick = function()
        -- TODO Phase B: send opcode(reroll, offer.slot) -> Tasks.rerollOffer
      end

      slot:getChildById('accept').onClick = function()
        -- TODO Phase B: send opcode(accept, offer.slot) -> Tasks.acceptTask
      end
    end
  end

  panel:getChildById('shuffle').onClick = function()
    -- TODO Phase B: send opcode(shuffle) -> Tasks.shuffleOffers
  end
end

-- ============================================================================
-- Active task tab
-- ============================================================================
function fillActive()
  local panel = tabPanels.active
  panel:getChildById('name'):setText('Dragon Lord')
  panel:getChildById('progressText'):setText('52 / 80 killed')
  panel:getChildById('progress'):setPercent(65)
  panel:getChildById('ladderTeaser'):setText('Next weapon unlock: level 40 (you: 32)')
  panel:getChildById('drop').onClick = function()
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
