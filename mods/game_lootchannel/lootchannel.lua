-- TheOtServer Loot Channel
-- The server already sends "Loot of <monster>: <items>" as an info message on every
-- kill (default_onDropLoot.lua). This mod routes those lines into a dedicated,
-- closeable "Loot" console tab so the main log stays clean. Close the tab to hide it;
-- it reappears on the next loot message.
--
-- The Loot tab has no server channelId, so typing in it used to fall through to a
-- private message to a player named "Loot" (see console.lua sendMessage). That used
-- to be worked around with a send-filter that blocked ALL input while the tab was
-- focused -- which also silently swallowed spell words, since casting a spell is just
-- typed text sent through the same path (fixed 2026-07-15). game_console now redirects
-- the Loot tab to the default channel like it already does for Server Log, so typing
-- (chat or spells) works normally regardless of which tab is focused -- no filter needed.

local TAB_NAME   = 'Loot'
local LOOT_COLOR = { color = '#9be29b' }   -- soft green; addTabText only needs .color

local function ensureTab()
  local console = modules.game_console
  if not console then return nil end
  return console.getTab(TAB_NAME) or console.addTab(TAB_NAME, false)  -- create, don't grab focus
end

local function onTextMessage(mode, text)
  if not text or not string.find(text, '^Loot of ') then
    return
  end
  if ensureTab() then
    modules.game_console.addText(text, LOOT_COLOR, TAB_NAME)
  end
end

-- The tab itself is kept alive across relogs (console.clear() never removes it -- see
-- LOOT_TAB_NAMES in game_console), so old session's text was still sitting in it on
-- the next login. Wipe its buffer every game start, same technique console.clearChannel
-- uses for the tab bar's current tab.
local function clearTab(tab)
  local buffer = tab.tabPanel and tab.tabPanel:getChildById('consoleBuffer')
  if buffer then
    buffer:destroyChildren()
  end
end

local function onGameStart()
  local tab = ensureTab()   -- open the Loot tab as soon as you enter the game
  if tab then
    clearTab(tab)
  end
end

function init()
  connect(g_game, { onTextMessage = onTextMessage, onGameStart = onGameStart })
  if g_game.isOnline() then
    onGameStart()
  end
end

function terminate()
  disconnect(g_game, { onTextMessage = onTextMessage, onGameStart = onGameStart })
end
