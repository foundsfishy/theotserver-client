skillsWindow = nil
skillsButton = nil
limitBreakActive = false
limitBreakSecsLeft = 0
limitBreakTickEvent = nil

-- Countdown bar color: solid yellow above LIMITBREAK_FADE_START_PCT remaining,
-- then linearly interpolates yellow -> red as it drains through the last
-- stretch, so the color itself telegraphs urgency instead of a blink.
local LIMITBREAK_COLOR_YELLOW = {r = 255, g = 204, b = 0}
local LIMITBREAK_COLOR_RED = {r = 255, g = 51, b = 51}
local LIMITBREAK_FADE_START_PCT = 80

local function limitBreakBarColor(percentLeft)
  if percentLeft >= LIMITBREAK_FADE_START_PCT then
    return string.format('#%02X%02X%02X', LIMITBREAK_COLOR_YELLOW.r, LIMITBREAK_COLOR_YELLOW.g, LIMITBREAK_COLOR_YELLOW.b)
  end
  local t = 1 - (percentLeft / LIMITBREAK_FADE_START_PCT) -- 0 at the fade start, 1 at empty
  local r = math.floor(LIMITBREAK_COLOR_YELLOW.r + (LIMITBREAK_COLOR_RED.r - LIMITBREAK_COLOR_YELLOW.r) * t)
  local g = math.floor(LIMITBREAK_COLOR_YELLOW.g + (LIMITBREAK_COLOR_RED.g - LIMITBREAK_COLOR_YELLOW.g) * t)
  local b = math.floor(LIMITBREAK_COLOR_YELLOW.b + (LIMITBREAK_COLOR_RED.b - LIMITBREAK_COLOR_YELLOW.b) * t)
  return string.format('#%02X%02X%02X', r, g, b)
end

-- Server pushes the player's live effective EXP multiplier over this opcode
-- (see data/lib/core/player.lua -> Player:sendExpRate on the server).
local EXPRATE_OPCODE = 60

function onExpRateOpcode(protocol, opcode, buffer)
  if not skillsWindow then return end
  local rate = tonumber(buffer)
  if rate then
    setSkillValue('expRate', string.format('%.1fx', rate))
  end
end

-- Server pushes the player's real (uncapped) experience over this opcode (see
-- data/lib/core/player.lua -> Player:sendRealExp on the server). The native
-- experience field on the wire is clamped to EXP_CLAMP_THRESHOLD server-side
-- (protocolgame.cpp), so a high-rate/high-level character's displayed exp --
-- and anything sampled from it client-side, like Exp/Hour and Next Level --
-- freezes solid once real exp crosses that ceiling. This opcode is the
-- workaround: once the native value is seen pinned at the ceiling, everything
-- below switches to this instead, refreshed every 30s by the exprate globalevent.
local REALEXP_OPCODE = 65
local EXP_CLAMP_THRESHOLD = 2147483647 -- 0x7FFFFFFF, matches protocolgame.cpp's std::min clamp
local realExperience = nil

function onRealExpOpcode(protocol, opcode, buffer)
  if not skillsWindow then return end
  local value = tonumber(buffer)
  if not value then return end
  realExperience = value

  local player = g_game.getLocalPlayer()
  if player and player:getExperience() >= EXP_CLAMP_THRESHOLD then
    onExperienceChange(player, currentExperience(player))
    onLevelChange(player, player:getLevel(), player:getLevelPercent())
  end
end

-- The native LocalPlayer field once it's pinned at the ceiling never changes
-- again (the server keeps sending the same clamped value), so anything that
-- needs the TRUE current experience past that point must read realExperience
-- instead -- it's the only side still moving.
function currentExperience(player)
  if realExperience and player:getExperience() >= EXP_CLAMP_THRESHOLD then
    return realExperience
  end
  return player:getExperience()
end

-- Server pushes "kills,goldPerHour" since login (see Player:sendSessionStats).
local SESSIONSTATS_OPCODE = 62

function onSessionStatsOpcode(protocol, opcode, buffer)
  if not skillsWindow then return end
  local kills, goldPerHour = buffer:match('^(%-?%d+),(%-?%d+)$')
  if kills then
    setSkillValue('kills', comma_value(tonumber(kills)))
    setSkillValue('goldPerHour', comma_value(tonumber(goldPerHour)))
  end
end

-- Server pushes the Limit Break state (see Player:sendLimitBreak) -- Conqueror/
-- Mighty Conqueror only, sent in real time (every combat tick it can change,
-- not just periodically). The server never sends this opcode at all for any
-- other vocation, so the row starts hidden (see refresh()) and reveals itself
-- the first time a packet actually arrives -- no vocation check needed client-
-- side, and no vocation-change signal exists in this client to react to a
-- mid-session promotion anyway; the row simply appears the moment the newly
-- promoted Mighty Conqueror's gauge next updates.
--
-- Payload is "mode,value": mode 0 = building gauge (value = percent full),
-- mode 1 = an active Break (value = seconds left). Must match the LBS_MOVE_
-- DURATION_MS constant in data/lib/limitbreaksystem.lua on the server.
local LIMITBREAK_OPCODE = 63
local LIMITBREAK_DURATION_SECS = 90

function onLimitBreakOpcode(protocol, opcode, buffer)
  if not skillsWindow then return end
  local mode, value = buffer:match('^(%d+),(%-?%d+)$')
  if not mode then return end
  mode = tonumber(mode)
  value = tonumber(value)

  toggleSkill('limitBreak', true)
  toggleSkill('lbsSeparatorBottom', true)

  if mode == 1 then
    -- Active Break: limitBreakActive/limitBreakSecsLeft are read by the
    -- persistent 1s ticker (limitBreakTick, started once in refresh() -- same
    -- pattern as expSpeedEvent/checkExpSpeed above) so the bar keeps draining
    -- on its own between hits instead of only updating when a fresh packet
    -- happens to land. A per-opcode cycleEvent used to be created/cancelled
    -- here instead, which looked fine on paper but in practice only ever
    -- visibly ticked when a new hit re-triggered it -- this single always-
    -- running ticker is the same proven shape the exp/hour speed check uses.
    limitBreakActive = true
    limitBreakSecsLeft = math.max(0, value)
    updateLimitBreakBar()
  else
    limitBreakActive = false
    local percent = math.max(0, value)
    setSkillValue('limitBreak', percent .. '%')
    setSkillPercent('limitBreak', percent, tr('Anger gauge: %s percent', percent), '#FFCC00')
  end
end

-- Separate from LIMITBREAK_OPCODE: that one is pure numbers sent every combat
-- tick, this one is text (current move name + compact next-unlock progress,
-- see Player.sendLimitBreakMoves on the server) that only changes on a fire/
-- unlock/!level switch, so it's kept off the high-frequency gauge packet.
local LIMITBREAK_MOVES_OPCODE = 64

-- The 'Next' row's value (LBSgetProgressCompact on the server) can run to
-- ~25-30 chars, e.g. "247 more -> Ascended Warrior" - long enough to overlap
-- the 'Next' name label on a narrower Skills window (smaller monitor, or the
-- MiniWindow just resized down) since name/value share the same row width
-- with no gap enforcement. Truncate what's shown, keep the full string as a
-- hover tooltip via the existing setSkillTooltip helper (see setSkillColor
-- above for the same pattern).
local LIMITBREAK_VALUE_MAX_CHARS = 18

local function truncateForDisplay(text)
  if #text <= LIMITBREAK_VALUE_MAX_CHARS then
    return text
  end
  return text:sub(1, LIMITBREAK_VALUE_MAX_CHARS - 3) .. '...'
end

function onLimitBreakMovesOpcode(protocol, opcode, buffer)
  if not skillsWindow then return end
  local moveName, progress = buffer:match('^([^|]*)|(.*)$')
  if not moveName then return end
  toggleSkill('lbsMove', true)
  toggleSkill('lbsNext', true)
  setSkillValue('lbsMove', truncateForDisplay(moveName))
  setSkillValue('lbsNext', truncateForDisplay(progress))
  setSkillTooltip('lbsMove', moveName)
  setSkillTooltip('lbsNext', progress)
end

function updateLimitBreakBar()
  setSkillValue('limitBreak', limitBreakSecsLeft .. 's')
  local percentLeft = math.floor(limitBreakSecsLeft * 100 / LIMITBREAK_DURATION_SECS)
  setSkillPercent('limitBreak', percentLeft,
    tr('Limit Break active: %s seconds left', limitBreakSecsLeft), limitBreakBarColor(percentLeft))
end

-- Self-rescheduling one-shot timer (scheduleEvent, NOT cycleEvent) -- same
-- proven pattern client_stats/stats.lua's monitor() already uses for its 1s
-- FPS/ping sampler. cycleEvent was tried here first and, in practice, never
-- actually kept ticking on its own (only the display value from a fresh
-- server packet ever showed up) -- switched to this instead of continuing to
-- guess at why.
function limitBreakTick()
  if limitBreakActive then
    if limitBreakSecsLeft <= 0 then
      limitBreakActive = false
    else
      limitBreakSecsLeft = limitBreakSecsLeft - 1
      updateLimitBreakBar()
    end
  end
  limitBreakTickEvent = scheduleEvent(limitBreakTick, 1000)
end

function init()
  -- pcall: registerExtendedOpcode throws if the opcode is already registered
  -- (e.g. a dev module-reload) -- don't let that abort the whole Skills init.
  pcall(ProtocolGame.registerExtendedOpcode, EXPRATE_OPCODE, onExpRateOpcode)
  pcall(ProtocolGame.registerExtendedOpcode, SESSIONSTATS_OPCODE, onSessionStatsOpcode)
  pcall(ProtocolGame.registerExtendedOpcode, LIMITBREAK_OPCODE, onLimitBreakOpcode)
  pcall(ProtocolGame.registerExtendedOpcode, LIMITBREAK_MOVES_OPCODE, onLimitBreakMovesOpcode)
  pcall(ProtocolGame.registerExtendedOpcode, REALEXP_OPCODE, onRealExpOpcode)

  connect(LocalPlayer, {
    onExperienceChange = onExperienceChange,
    onLevelChange = onLevelChange,
    onHealthChange = onHealthChange,
    onManaChange = onManaChange,
    onSoulChange = onSoulChange,
    onFreeCapacityChange = onFreeCapacityChange,
    onTotalCapacityChange = onTotalCapacityChange,
    onStaminaChange = onStaminaChange,
    onOfflineTrainingChange = onOfflineTrainingChange,
    onRegenerationChange = onRegenerationChange,
    onSpeedChange = onSpeedChange,
    onBaseSpeedChange = onBaseSpeedChange,
    onMagicLevelChange = onMagicLevelChange,
    onBaseMagicLevelChange = onBaseMagicLevelChange,
    onSkillChange = onSkillChange,
    onBaseSkillChange = onBaseSkillChange
  })
  connect(g_game, {
    onGameStart = refresh,
    onGameEnd = offline
  })

  skillsButton = modules.client_topmenu.addRightGameToggleButton('skillsButton', tr('Skills'), '/images/topbuttons/skills', toggle, false, 1)
  skillsButton:setOn(true)
  skillsWindow = g_ui.loadUI('skills', modules.game_interface.getRightPanel())
  
  refresh()
  skillsWindow:setup()
end

function terminate()
  disconnect(LocalPlayer, {
    onExperienceChange = onExperienceChange,
    onLevelChange = onLevelChange,
    onHealthChange = onHealthChange,
    onManaChange = onManaChange,
    onSoulChange = onSoulChange,
    onFreeCapacityChange = onFreeCapacityChange,
    onTotalCapacityChange = onTotalCapacityChange,
    onStaminaChange = onStaminaChange,
    onOfflineTrainingChange = onOfflineTrainingChange,
    onRegenerationChange = onRegenerationChange,
    onSpeedChange = onSpeedChange,
    onBaseSpeedChange = onBaseSpeedChange,
    onMagicLevelChange = onMagicLevelChange,
    onBaseMagicLevelChange = onBaseMagicLevelChange,
    onSkillChange = onSkillChange,
    onBaseSkillChange = onBaseSkillChange
  })
  disconnect(g_game, {
    onGameStart = refresh,
    onGameEnd = offline
  })
  pcall(ProtocolGame.unregisterExtendedOpcode, EXPRATE_OPCODE)
  pcall(ProtocolGame.unregisterExtendedOpcode, SESSIONSTATS_OPCODE)
  pcall(ProtocolGame.unregisterExtendedOpcode, LIMITBREAK_OPCODE)
  pcall(ProtocolGame.unregisterExtendedOpcode, LIMITBREAK_MOVES_OPCODE)
  pcall(ProtocolGame.unregisterExtendedOpcode, REALEXP_OPCODE)

  skillsWindow:destroy()
  skillsButton:destroy()
end

function expForLevel(level)
  return math.floor((50*level*level*level)/3 - 100*level*level + (850*level)/3 - 200)
end

function expToAdvance(currentLevel, currentExp)
  return expForLevel(currentLevel+1) - currentExp
end

function resetSkillColor(id)
  local skill = skillsWindow:recursiveGetChildById(id)
  local widget = skill:getChildById('value')
  widget:setColor('#bbbbbb')
end

function toggleSkill(id, state)
  local skill = skillsWindow:recursiveGetChildById(id)
  skill:setVisible(state)
end

function setSkillBase(id, value, baseValue)
  if baseValue <= 0 or value < 0 then
    return
  end
  local skill = skillsWindow:recursiveGetChildById(id)
  local widget = skill:getChildById('value')

  if value > baseValue then
    widget:setColor('#008b00') -- green
    skill:setTooltip(baseValue .. ' +' .. (value - baseValue))
  elseif value < baseValue then
    widget:setColor('#b22222') -- red
    skill:setTooltip(baseValue .. ' ' .. (value - baseValue))
  else
    widget:setColor('#bbbbbb') -- default
    skill:removeTooltip()
  end
end

function setSkillValue(id, value)
  local skill = skillsWindow:recursiveGetChildById(id)
  local widget = skill:getChildById('value')
  widget:setText(value)
end

function setSkillColor(id, value)
  local skill = skillsWindow:recursiveGetChildById(id)
  local widget = skill:getChildById('value')
  widget:setColor(value)
end

function setSkillTooltip(id, value)
  local skill = skillsWindow:recursiveGetChildById(id)
  local widget = skill:getChildById('value')
  widget:setTooltip(value)
end

function setSkillPercent(id, percent, tooltip, color)
  local skill = skillsWindow:recursiveGetChildById(id)
  local widget = skill:getChildById('percent')
  if widget then
    widget:setPercent(math.floor(percent))

    if tooltip then
      widget:setTooltip(tooltip)
    end

    if color then
    	widget:setBackgroundColor(color)
    end
  end
end

function checkAlert(id, value, maxValue, threshold, greaterThan)
  if greaterThan == nil then greaterThan = false end
  local alert = false

  -- maxValue can be set to false to check value and threshold
  -- used for regeneration checking
  if type(maxValue) == 'boolean' then
    if maxValue then
      return
    end

    if greaterThan then
      if value > threshold then
        alert = true
      end
    else
      if value < threshold then
        alert = true
      end
    end
  elseif type(maxValue) == 'number' then
    if maxValue < 0 then
      return
    end

    local percent = math.floor((value / maxValue) * 100)
    if greaterThan then
      if percent > threshold then
        alert = true
      end
    else
      if percent < threshold then
        alert = true
      end
    end
  end

  if alert then
    setSkillColor(id, '#b22222') -- red
  else
    resetSkillColor(id)
  end
end

function update()
  local offlineTraining = skillsWindow:recursiveGetChildById('offlineTraining')
  if not g_game.getFeature(GameOfflineTrainingTime) then
    offlineTraining:hide()
  else
    offlineTraining:show()
  end

  local regenerationTime = skillsWindow:recursiveGetChildById('regenerationTime')
  if not g_game.getFeature(GamePlayerRegenerationTime) then
    regenerationTime:hide()
  else
    regenerationTime:show()
  end
end

function refresh()
  local player = g_game.getLocalPlayer()
  if not player then return end

  if expSpeedEvent then expSpeedEvent:cancel() end
  expSpeedEvent = cycleEvent(checkExpSpeed, 30*1000)

  if limitBreakTickEvent then removeEvent(limitBreakTickEvent) end
  limitBreakTickEvent = scheduleEvent(limitBreakTick, 1000)

  onExperienceChange(player, player:getExperience())
  onLevelChange(player, player:getLevel(), player:getLevelPercent())
  onHealthChange(player, player:getHealth(), player:getMaxHealth())
  onManaChange(player, player:getMana(), player:getMaxMana())
  onSoulChange(player, player:getSoul())
  onFreeCapacityChange(player, player:getFreeCapacity())
  onStaminaChange(player, player:getStamina())
  onMagicLevelChange(player, player:getMagicLevel(), player:getMagicLevelPercent())
  onOfflineTrainingChange(player, player:getOfflineTrainingTime())
  onRegenerationChange(player, player:getRegenerationTime())
  onSpeedChange(player, player:getSpeed())

  -- placeholder until the server pushes the real rate over EXPRATE_OPCODE (~1s after login)
  setSkillValue('expRate', '...')
  -- exp/hour + next-level fill in once expSpeed has a sample (~30s of hunting)
  setSkillValue('xpGain', '...')
  setSkillValue('nextLevel', '...')
  -- session counters start at 0; server refreshes them every ~30s
  setSkillValue('kills', '0')
  setSkillValue('goldPerHour', '0')

  -- Hidden until the server actually sends a Limit Break packet (Conqueror/
  -- Mighty Conqueror only) -- reset here so switching to a non-Conqueror
  -- character doesn't leak the previous character's visible row.
  limitBreakActive = false
  toggleSkill('limitBreak', false)
  toggleSkill('lbsMove', false)
  toggleSkill('lbsNext', false)
  toggleSkill('lbsSeparatorBottom', false)

  local hasAdditionalSkills = g_game.getFeature(GameAdditionalSkills)
  for i = Skill.Fist, Skill.ManaLeechAmount do
    onSkillChange(player, i, player:getSkillLevel(i), player:getSkillLevelPercent(i))
    onBaseSkillChange(player, i, player:getSkillBaseLevel(i))

    if i > Skill.Fishing then
      toggleSkill('skillId'..i, hasAdditionalSkills)
    end
  end

  update()

  local contentsPanel = skillsWindow:getChildById('contentsPanel')
  skillsWindow:setContentMinimumHeight(44)
  if hasAdditionalSkills then
    skillsWindow:setContentMaximumHeight(480)
  else
    skillsWindow:setContentMaximumHeight(390)
  end
end

function offline()
  if expSpeedEvent then expSpeedEvent:cancel() expSpeedEvent = nil end
  if limitBreakTickEvent then removeEvent(limitBreakTickEvent) limitBreakTickEvent = nil end
  limitBreakActive = false
  realExperience = nil -- don't leak this character's real exp into the next login
end

function toggle()
  if skillsButton:isOn() then
    skillsWindow:close()
    skillsButton:setOn(false)
  else
    skillsWindow:open()
    skillsButton:setOn(true)
  end
end

function checkExpSpeed()
  local player = g_game.getLocalPlayer()
  if not player then return end

  local currentExp = currentExperience(player)
  local currentTime = g_clock.seconds()
  if player.lastExps ~= nil then
    player.expSpeed = (currentExp - player.lastExps[1][1])/(currentTime - player.lastExps[1][2])
    onLevelChange(player, player:getLevel(), player:getLevelPercent())
  else
    player.lastExps = {}
  end
  table.insert(player.lastExps, {currentExp, currentTime})
  if #player.lastExps > 30 then
    table.remove(player.lastExps, 1)
  end
end

function onMiniWindowClose()
  skillsButton:setOn(false)
end

function onSkillButtonClick(button)
  local percentBar = button:getChildById('percent')
  if percentBar then
    percentBar:setVisible(not percentBar:isVisible())
    if percentBar:isVisible() then
      button:setHeight(21)
    else
      button:setHeight(21 - 6)
    end
  end
end

function onExperienceChange(localPlayer, value)
  local postFix = ""
  if value > 1e15 then
	postFix = "B"
	value = math.floor(value / 1e9)
  elseif value > 1e12 then
	postFix = "M"
	value = math.floor(value / 1e6)
  elseif value > 1e9 then
	postFix = "K"
	value = math.floor(value / 1e3)
  end
  setSkillValue('experience', comma_value(value) .. postFix)
end

function onLevelChange(localPlayer, value, percent)
  setSkillValue('level', value)
  local text = tr('You have %s percent to go', 100 - percent) .. '\n' ..
               comma_value(expToAdvance(localPlayer:getLevel(), currentExperience(localPlayer))) .. tr(' of experience left')

  if localPlayer.expSpeed ~= nil then
     local expPerHour = math.floor(localPlayer.expSpeed * 3600)
     -- surface the live rate as its own always-visible rows (was tooltip-only)
     setSkillValue('xpGain', comma_value(math.max(0, expPerHour)))
     if expPerHour > 0 then
        local nextLevelExp = expForLevel(localPlayer:getLevel()+1)
        local hoursLeft = (nextLevelExp - currentExperience(localPlayer)) / expPerHour
        local minutesLeft = math.floor((hoursLeft - math.floor(hoursLeft))*60)
        hoursLeft = math.floor(hoursLeft)
        setSkillValue('nextLevel', string.format('%dh %02dm', hoursLeft, minutesLeft))
        text = text .. '\n' .. comma_value(expPerHour) .. ' of experience per hour'
        text = text .. '\n' .. tr('Next level in %d hours and %d minutes', hoursLeft, minutesLeft)
     else
        setSkillValue('nextLevel', '--')
     end
  end

  setSkillPercent('level', percent, text)
end

function onHealthChange(localPlayer, health, maxHealth)
  setSkillValue('health', health)
  checkAlert('health', health, maxHealth, 30)
end

function onManaChange(localPlayer, mana, maxMana)
  setSkillValue('mana', mana)
  checkAlert('mana', mana, maxMana, 30)
end

function onSoulChange(localPlayer, soul)
  setSkillValue('soul', soul)
end

function onFreeCapacityChange(localPlayer, freeCapacity)
  setSkillValue('capacity', freeCapacity)
  checkAlert('capacity', freeCapacity, localPlayer:getTotalCapacity(), 20)
end

function onTotalCapacityChange(localPlayer, totalCapacity)
  checkAlert('capacity', localPlayer:getFreeCapacity(), totalCapacity, 20)
end

function onStaminaChange(localPlayer, stamina)
  local hours = math.floor(stamina / 60)
  local minutes = stamina % 60
  if minutes < 10 then
    minutes = '0' .. minutes
  end
  local percent = math.floor(100 * stamina / (42 * 60)) -- max is 42 hours --TODO not in all client versions

  setSkillValue('stamina', hours .. ":" .. minutes)

  -- Colour the value to match the server's stamina-based exp rate. The stock
  -- green/low colouring below is version-gated >=1038, so it never fires on 8.60;
  -- this mirrors our rules: >2400 min + premium = +50%, <=840 min = -50%.
  if stamina > 2400 and localPlayer:isPremium() then
    setSkillColor('stamina', '#44db44')
  elseif stamina <= 840 then
    setSkillColor('stamina', '#db4444')
  else
    setSkillColor('stamina', '#bbbbbb')
  end

  --TODO not all client versions have premium time
  if stamina > 2400 and g_game.getClientVersion() >= 1038 and localPlayer:isPremium() then
  	local text = tr("You have %s hours and %s minutes left", hours, minutes) .. '\n' ..
		tr("Now you will gain 50%% more experience")
		setSkillPercent('stamina', percent, text, 'green')
	elseif stamina > 2400 and g_game.getClientVersion() >= 1038 and not localPlayer:isPremium() then
		local text = tr("You have %s hours and %s minutes left", hours, minutes) .. '\n' ..
		tr("You will not gain 50%% more experience because you aren't premium player, now you receive only 1x experience points")
		setSkillPercent('stamina', percent, text, '#89F013')
	elseif stamina > 2400 and g_game.getClientVersion() < 1038 then
		local text = tr("You have %s hours and %s minutes left", hours, minutes) .. '\n' ..
		tr("If you are premium player, you will gain 50%% more experience")
		setSkillPercent('stamina', percent, text, 'green')
	elseif stamina <= 2400 and stamina > 840 then
		setSkillPercent('stamina', percent, tr("You have %s hours and %s minutes left", hours, minutes), 'orange')
	elseif stamina <= 840 and stamina > 0 then
		local text = tr("You have %s hours and %s minutes left", hours, minutes) .. "\n" ..
		tr("You gain only 50%% experience and you don't may gain loot from monsters")
		setSkillPercent('stamina', percent, text, 'red')
	elseif stamina == 0 then
		local text = tr("You have %s hours and %s minutes left", hours, minutes) .. "\n" ..
		tr("You don't may receive experience and loot from monsters")
		setSkillPercent('stamina', percent, text, 'black')
	end
end

function onOfflineTrainingChange(localPlayer, offlineTrainingTime)
  if not g_game.getFeature(GameOfflineTrainingTime) then
    return
  end
  local hours = math.floor(offlineTrainingTime / 60)
  local minutes = offlineTrainingTime % 60
  if minutes < 10 then
    minutes = '0' .. minutes
  end
  local percent = 100 * offlineTrainingTime / (12 * 60) -- max is 12 hours

  setSkillValue('offlineTraining', hours .. ":" .. minutes)
  setSkillPercent('offlineTraining', percent, tr('You have %s percent', percent))
end

function onRegenerationChange(localPlayer, regenerationTime)
  if not g_game.getFeature(GamePlayerRegenerationTime) or regenerationTime < 0 then
    return
  end
  local minutes = math.floor(regenerationTime / 60)
  local seconds = regenerationTime % 60
  if seconds < 10 then
    seconds = '0' .. seconds
  end

  setSkillValue('regenerationTime', minutes .. ":" .. seconds)
  checkAlert('regenerationTime', regenerationTime, false, 300)
end

function onSpeedChange(localPlayer, speed)
  setSkillValue('speed', speed)

  onBaseSpeedChange(localPlayer, localPlayer:getBaseSpeed())
end

function onBaseSpeedChange(localPlayer, baseSpeed)
  setSkillBase('speed', localPlayer:getSpeed(), baseSpeed)
end

function onMagicLevelChange(localPlayer, magiclevel, percent)
  setSkillValue('magiclevel', magiclevel)
  setSkillPercent('magiclevel', percent, tr('You have %s percent to go', 100 - percent))

  onBaseMagicLevelChange(localPlayer, localPlayer:getBaseMagicLevel())
end

function onBaseMagicLevelChange(localPlayer, baseMagicLevel)
  setSkillBase('magiclevel', localPlayer:getMagicLevel(), baseMagicLevel)
end

function onSkillChange(localPlayer, id, level, percent)
  setSkillValue('skillId' .. id, level)
  setSkillPercent('skillId' .. id, percent, tr('You have %s percent to go', 100 - percent))

  onBaseSkillChange(localPlayer, id, localPlayer:getSkillBaseLevel(id))
end

function onBaseSkillChange(localPlayer, id, baseLevel)
  setSkillBase('skillId'..id, localPlayer:getSkillLevel(id), baseLevel)
end
