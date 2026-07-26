-- Training bot: repeatedly casts an attack spell to train magic level, and
-- auto-eats food so you don't need to babysit hunger during a long session.
-- Off by default - pick "Training" from the bot config list and flip it on
-- whenever you actually want it running.
--
-- WHAT TO ATTACK: point this at a Training Monk (found in dedicated training
-- rooms around the world) - it has 60,000 HP, heals whoever is fighting it so
-- a long unattended session never ends in death, and gives zero experience
-- and zero loot on purpose (a pure skill-training dummy, not a farm). Attacking
-- it also refills your stamina far faster than normal. This script auto-targets
-- the closest monster to you and attacks it - it does NOT know "monk" from any
-- other monster, so only run it somewhere the monk is the only thing nearby
-- (its own training room), or it will happily attack whatever else is close.
--
-- NO ANTI-LOGOUT NEEDED: the server does not have an idle-kick timer at all
-- right now, specifically so long training sessions like this one are never
-- disconnected for inactivity. Nothing in this script tries to work around
-- an idle-kick, because there is nothing to work around.
--
-- SETUP: change ATTACK_SPELL below to YOUR OWN attack spell's words (whatever
-- you'd normally type to cast it) before turning this on. Vocations here have
-- their own custom spells, so there's no single default that works for every
-- character - re-check this after a vocation change or spell unlock too.
-- UTILITY_SPELL defaults to Great Light ("utevo gran lux") since every
-- vocation on this server can cast it - fires on its own timer regardless of
-- whether you're attacking anything. Leave it as "" if you don't want one.

local ATTACK_SPELL = "exori" -- CHANGE to your own attack spell's words
local ATTACK_INTERVAL_MS = 2000 -- matches typical spell exhaust; raise this if
                                 -- your spell has a longer cooldown

local UTILITY_SPELL = "utevo gran lux" -- open to every vocation on this server;
                                        -- leave as "" to disable
local UTILITY_INTERVAL_MS = 1100 -- Great Light's real cooldown is 1000ms

-- Every edible item in the game (69 of them), as CLIENT item ids: meats, fish,
-- all the fruits, every mushroom, breads, cheeses, cakes, sweets and veggies.
--
-- IMPORTANT if you ever edit this list: a server and a client can number the
-- same item DIFFERENTLY (items.otb is what maps between the two) - a brown
-- mushroom is 2789 server-side but 3725 to the client. A script running here
-- only ever sees client ids, so pasting ids out of a server-side item list
-- silently matches nothing at all. These are already the client ids.
local FOOD_ITEMS = {
  130, 169, 229, 904, 3250, 3577, 3578, 3579, 3580, 3581, 3582, 3583, 3584,
  3585, 3586, 3587, 3588, 3589, 3590, 3591, 3592, 3593, 3594, 3595, 3596, 3597,
  3599, 3600, 3601, 3602, 3606, 3723, 3724, 3725, 3726, 3727, 3728, 3729, 3730,
  3731, 3732, 5096, 6125, 6277, 6278, 6500, 6541, 6542, 6543, 6544, 6545, 6569,
  6574, 7158, 7159, 7373, 7374, 7375, 7376, 7377, 8010, 8011, 8012, 8013, 8014,
  8015, 8016, 8017, 8019,
}

-- Same distance metric the Battle List sorts by (game_battle/battle.lua) - tile
-- (chessboard) distance, not straight-line, since that matches how far a monster
-- actually is to walk/reach in this game.
local function tileDistance(a, b)
  return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

local function findClosestMonster()
  local playerPos = player:getPosition()
  local closest, closestDist = nil, math.huge
  for _, creature in pairs(getSpectators()) do
    if creature:isMonster() then
      local dist = tileDistance(playerPos, creature:getPosition())
      if dist < closestDist then
        closest, closestDist = creature, dist
      end
    end
  end
  return closest
end

macro(ATTACK_INTERVAL_MS, "Train - Attack", function()
  local target = findClosestMonster()
  if not target then return end
  if g_game.getAttackingCreature() ~= target then
    g_game.attack(target)
  end
  say(ATTACK_SPELL)
end)

macro(UTILITY_INTERVAL_MS, "Train - Utility Spell", function()
  if UTILITY_SPELL ~= "" then
    say(UTILITY_SPELL)
  end
end)

-- The client only knows what's inside a bag once the server has actually
-- sent that bag's contents - which only happens while the bag is open on
-- screen. A closed bag (even one you're carrying) is invisible to the eat
-- search below, so this opens your equipped backpack - and any bag nested
-- inside it - automatically instead of requiring you to keep them open by hand.
local function openAllContainers()
  local backpack = getBack()
  if backpack and backpack:isContainer() then
    local open = false
    for _, c in pairs(g_game.getContainers()) do
      if c:getContainerItem() and c:getContainerItem():getId() == backpack:getId() then
        open = true
      end
    end
    if not open then
      g_game.open(backpack)
    end
  end

  for _, container in pairs(g_game.getContainers()) do
    for _, item in ipairs(container:getItems()) do
      if item:isContainer() then
        local open = false
        for _, c in pairs(g_game.getContainers()) do
          if c:getContainerItem() and c:getContainerItem():getId() == item:getId() then
            open = true
          end
        end
        if not open then
          g_game.open(item, container)
        end
      end
    end
  end
end

local function eatFromOpenContainers()
  for _, container in pairs(g_game.getContainers()) do
    for _, item in ipairs(container:getItems()) do
      for _, foodId in ipairs(FOOD_ITEMS) do
        if item:getId() == foodId then
          return g_game.use(item)
        end
      end
    end
  end
end

-- getRealRegenerationTime() is the real hunger signal, pushed by the server
-- over a custom opcode since the native 8.60 stats packet never carries it
-- (see game_bot/functions/player.lua). Only bothers opening bags/searching
-- once actually needed instead of blindly on a timer.
--
-- g_game.open() is a request to the server, not instant - a bag's contents
-- only arrive after a round trip, so the food search has to happen a moment
-- later rather than in the same tick that opens the bag.
macro(2000, "Train - Eat", function()
  if getRealRegenerationTime() > 400 then return end
  openAllContainers()
  schedule(300, eatFromOpenContainers)
end)
