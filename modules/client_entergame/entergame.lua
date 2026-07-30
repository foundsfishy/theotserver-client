EnterGame = { }

-- Consecutive wrong-password/account streak this client session. The server bans an
-- IP after 5 in 10 minutes (see ARCHITECTURE.md sec 11, theotserver-login fail2ban
-- jail) with NO way for it to tell the client why once banned - a ban drops packets
-- at the firewall, before the game process ever sees the connection, so there is no
-- "you are banned" message possible at that point. This warns proactively, while the
-- attempts are still reaching the server and getting a real answer back.
local failedLoginStreak = 0

-- Brand ONLY login / front-door message boxes (Login Error, Connecting, etc).
-- In-game message boxes never call this, so they stay stock grey.
-- Re-applies the gold MessageBoxWindow frame + gold pill buttons. MessageBoxWindow
-- inherits MainWindow's padding, so re-styling an already-laid-out box doesn't move
-- its contents. Global (not local) so characterlist.lua can reuse it.
function brandLoginBox(box)
  if box then
    pcall(function()
      -- setStyle re-applies the Window default size (200x200), so capture the
      -- already-computed box size and restore it after restyling.
      local w, h = box:getWidth(), box:getHeight()
      box:setStyle('MessageBoxWindow')
      box:setWidth(w)
      box:setHeight(h)
      local holder = box:getChildById('buttonHolder')
      if holder then
        local children = holder:getChildren()
        local total = 0
        for i = 1, #children do
          local btn = children[i]
          local txt = btn:getText()
          btn:setStyle('LoginDialogButton')
          btn:setText(txt)
          btn:addAnchor(AnchorBottom, 'parent', AnchorBottom)
          if i == 1 then
            btn:addAnchor(AnchorLeft, 'parent', AnchorLeft)
          else
            btn:addAnchor(AnchorLeft, 'prev', AnchorRight)
          end
          total = total + btn:getWidth() + btn:getMarginLeft()
        end
        if children[1] then
          holder:setWidth(total)
          holder:setHeight(children[1]:getHeight())
          holder:addAnchor(AnchorHorizontalCenter, 'parent', AnchorHorizontalCenter)
        end
      end
    end)
  end
  return box
end

-- private variables
local loadBox
local enterGame
local enterGameButton
local clientBox
local protocolLogin
local server = nil
local versionsFound = false

local customServerSelectorPanel
local serverSelectorPanel
local serverSelector
local clientVersionSelector
local serverHostTextEdit
local rememberPasswordBox
local protos = {"740", "760", "772", "792", "800", "810", "854", "860", "870", "910", "961", "1000", "1077", "1090", "1096", "1098", "1099", "1100", "1200", "1220"}

local checkedByUpdater = {}
local waitingForHttpResults = 0

-- private functions
local function onProtocolError(protocol, message, errorCode)
  if errorCode then
    return EnterGame.onError(message)
  end
  return EnterGame.onLoginError(message)
end

local function onSessionKey(protocol, sessionKey)
  G.sessionKey = sessionKey
end

local function onCharacterList(protocol, characters, account, otui)
  failedLoginStreak = 0
  if rememberPasswordBox:isChecked() then
    local account = g_crypt.encrypt(G.account)
    local password = g_crypt.encrypt(G.password)

    g_settings.set('account', account)
    g_settings.set('password', password)
  else
    EnterGame.clearAccountFields()
  end

  for _, characterInfo in pairs(characters) do
    if characterInfo.previewState and characterInfo.previewState ~= PreviewState.Default then
      characterInfo.worldName = characterInfo.worldName .. ', Preview'
    end
  end

  if loadBox then
    loadBox:destroy()
    loadBox = nil
  end
    
  CharacterList.create(characters, account, otui)
  CharacterList.show()

  g_settings.save()
end

local function onUpdateNeeded(protocol, signature)
  return EnterGame.onError(tr('Your client needs updating, try redownloading it.'))
end

local function onProxyList(protocol, proxies)
  for _, proxy in ipairs(proxies) do
    g_proxy.addProxy(proxy["host"], proxy["port"], proxy["priority"])
  end
end

local function parseFeatures(features)
  for feature_id, value in pairs(features) do
      if value == "1" or value == "true" or value == true then
        g_game.enableFeature(feature_id)
      else
        g_game.disableFeature(feature_id)
      end
  end  
end

local function validateThings(things)
  local incorrectThings = ""
  local missingFiles = false
  local versionForMissingFiles = 0
  if things ~= nil then
    local thingsNode = {}
    for thingtype, thingdata in pairs(things) do
      thingsNode[thingtype] = thingdata[1]
      if not g_resources.fileExists("/things/" .. thingdata[1]) then
        incorrectThings = incorrectThings .. "Missing file: " .. thingdata[1] .. "\n"
        missingFiles = true
        versionForMissingFiles = thingdata[1]:split("/")[1]
      else
        local localChecksum = g_resources.fileChecksum("/things/" .. thingdata[1]):lower()
        if localChecksum ~= thingdata[2]:lower() and #thingdata[2] > 1 then
          if g_resources.isLoadedFromArchive() then -- ignore checksum if it's test/debug version
            incorrectThings = incorrectThings .. "Invalid checksum of file: " .. thingdata[1] .. " (is " .. localChecksum .. ", should be " .. thingdata[2]:lower() .. ")\n"
          end
        end
      end
    end
    g_settings.setNode("things", thingsNode)
  else
    g_settings.setNode("things", {})
  end
  if missingFiles then
    incorrectThings = incorrectThings .. "\nYou should open data/things and create directory " .. versionForMissingFiles .. 
    ".\nIn this directory (data/things/" .. versionForMissingFiles .. ") you should put missing\nfiles (Tibia.dat and Tibia.spr/Tibia.cwm) " ..
    "from correct Tibia version."
  end
  return incorrectThings
end

local function onTibia12HTTPResult(session, playdata)
  local characters = {}
  local worlds = {}
  local account = {
    status = 0,
    subStatus = 0,
    premDays = 0
  }
  if session["status"] ~= "active" then
    account.status = 1
  end
  if session["ispremium"] then
    account.subStatus = 1 -- premium
  end
  if session["premiumuntil"] > g_clock.seconds() then
    account.subStatus = math.floor((session["premiumuntil"] - g_clock.seconds()) / 86400)
  end
    
  local things = {
    data = {G.clientVersion .. "/Tibia.dat", ""},
    sprites = {G.clientVersion .. "/Tibia.cwm", ""},
  }

  local incorrectThings = validateThings(things)
  if #incorrectThings > 0 then
    things = {
      data = {G.clientVersion .. "/Tibia.dat", ""},
      sprites = {G.clientVersion .. "/Tibia.spr", ""},
    }  
    incorrectThings = validateThings(things)
  end
  
  if #incorrectThings > 0 then
    g_logger.error(incorrectThings)
    if Updater and not checkedByUpdater[G.clientVersion] then
      checkedByUpdater[G.clientVersion] = true
      return Updater.check({
        version = G.clientVersion,
        host = G.host
      })
    else
      return EnterGame.onError(incorrectThings)
    end
  end
  
  onSessionKey(nil, session["sessionkey"])
  
  for _, world in pairs(playdata["worlds"]) do
    worlds[world.id] = {
      name = world.name,
      port = world.externalportunprotected or world.externalportprotected or world.externaladdress,
      address = world.externaladdressunprotected or world.externaladdressprotected or world.externalport
    }
  end
  
  for _, character in pairs(playdata["characters"]) do
    local world = worlds[character.worldid]
    if world then
      table.insert(characters, {
        name = character.name,
        worldName = world.name,
        worldIp = world.address,
        worldPort = world.port
      })
    end
  end
  
  -- proxies
  if g_proxy then
    g_proxy.clear()
    if playdata["proxies"] then
      for i, proxy in ipairs(playdata["proxies"]) do
        g_proxy.addProxy(proxy["host"], tonumber(proxy["port"]), tonumber(proxy["priority"]))
      end
    end
  end
  
  g_game.setCustomProtocolVersion(0)
  g_game.chooseRsa(G.host)
  g_game.setClientVersion(G.clientVersion)
  g_game.setProtocolVersion(g_game.getClientProtocolVersion(G.clientVersion))
  g_game.setCustomOs(-1) -- disable
  if not g_game.getFeature(GameExtendedOpcode) then
    g_game.setCustomOs(5) -- set os to windows if opcodes are disabled
  end
  
  onCharacterList(nil, characters, account, nil)  
end

local function onHTTPResult(data, err)
  if waitingForHttpResults == 0 then
    return
  end
  
  waitingForHttpResults = waitingForHttpResults - 1
  if err and waitingForHttpResults > 0 then
    return -- ignore, wait for other requests
  end

  if err then
    return EnterGame.onError(err)
  end
  waitingForHttpResults = 0 
  if data['error'] and data['error']:len() > 0 then
    return EnterGame.onLoginError(data['error'])
  elseif data['errorMessage'] and data['errorMessage']:len() > 0 then
    return EnterGame.onLoginError(data['errorMessage'])
  end
  
  if type(data["session"]) == "table" and type(data["playdata"]) == "table" then
    return onTibia12HTTPResult(data["session"], data["playdata"])
  end  
  
  local characters = data["characters"]
  local account = data["account"]
  local session = data["session"]
 
  local version = data["version"]
  local things = data["things"]
  local customProtocol = data["customProtocol"]

  local features = data["features"]
  local settings = data["settings"]
  local rsa = data["rsa"]
  local proxies = data["proxies"]

  local incorrectThings = validateThings(things)
  if #incorrectThings > 0 then
    g_logger.info(incorrectThings)
    return EnterGame.onError(incorrectThings)
  end
  
  -- custom protocol
  g_game.setCustomProtocolVersion(0)
  if customProtocol ~= nil then
    customProtocol = tonumber(customProtocol)
    if customProtocol ~= nil and customProtocol > 0 then
      g_game.setCustomProtocolVersion(customProtocol)
    end
  end
  
  -- force player settings
  if settings ~= nil then
    for option, value in pairs(settings) do
      modules.client_options.setOption(option, value, true)
    end
  end
    
  -- version
  G.clientVersion = version
  g_game.setClientVersion(version)
  g_game.setProtocolVersion(g_game.getClientProtocolVersion(version))  
  g_game.setCustomOs(-1) -- disable
  
  if rsa ~= nil then
    g_game.setRsa(rsa)
  end

  if features ~= nil then
    parseFeatures(features)
  end

  if session ~= nil and session:len() > 0 then
    onSessionKey(nil, session)
  end
  
  -- proxies
  if g_proxy then
    g_proxy.clear()
    if proxies then
      for i, proxy in ipairs(proxies) do
        g_proxy.addProxy(proxy["host"], tonumber(proxy["port"]), tonumber(proxy["priority"]))
      end
    end
  end
  
  onCharacterList(nil, characters, account, nil)  
end


-- public functions
function EnterGame.init()
  if USE_NEW_ENERGAME then return end
  enterGame = g_ui.displayUI('entergame')
  
  serverSelectorPanel = enterGame:getChildById('serverSelectorPanel')
  customServerSelectorPanel = enterGame:getChildById('customServerSelectorPanel')
  
  serverSelector = serverSelectorPanel:getChildById('serverSelector')
  rememberPasswordBox = enterGame:getChildById('rememberPasswordBox')
  serverHostTextEdit = customServerSelectorPanel:getChildById('serverHostTextEdit')
  clientVersionSelector = customServerSelectorPanel:getChildById('clientVersionSelector')
  
  if Servers ~= nil then 
    for name,server in pairs(Servers) do
      serverSelector:addOption(name)
    end
  end
  if serverSelector:getOptionsCount() == 0 or ALLOW_CUSTOM_SERVERS then
    serverSelector:addOption(tr("Another"))    
  end  
  for i,proto in pairs(protos) do
    clientVersionSelector:addOption(proto)
  end

  if serverSelector:getOptionsCount() == 1 then
    enterGame:setHeight(enterGame:getHeight() - serverSelectorPanel:getHeight())
    serverSelectorPanel:setOn(false)
  end
  
  local account = g_crypt.decrypt(g_settings.get('account'))
  local password = g_crypt.decrypt(g_settings.get('password'))
  local server = g_settings.get('server')
  local host = g_settings.get('host')
  local clientVersion = g_settings.get('client-version')

  if serverSelector:isOption(server) then
    serverSelector:setCurrentOption(server, false)
    if Servers == nil or Servers[server] == nil then
      serverHostTextEdit:setText(host)
    end
    clientVersionSelector:setOption(clientVersion)
  else
    server = ""
    host = ""
  end
  
  -- Single-server build: the hidden server selector never fires onServerChange,
  -- so populate the host field directly from the configured server (otherwise
  -- login fails with "Invalid server").
  local _srv = serverSelector:getText()
  if not (Servers and Servers[_srv] ~= nil) then
    if Servers then for _n in pairs(Servers) do _srv = _n; break end end
  end
  if Servers and Servers[_srv] ~= nil then
    local _h = Servers[_srv]
    serverHostTextEdit:setText(type(_h) == "table" and _h[1] or _h)
  end
  EnterGame.setupDevHostToggle()
  enterGame:getChildById('accountPasswordTextEdit'):setText(password)
  enterGame:getChildById('accountNameTextEdit'):setText(account)
  -- Default the "remember" box to CHECKED so a first-time player's account and
  -- password are saved on their first successful login (onCharacterList only
  -- persists them while this box is ticked). Returning players keep their saved
  -- credentials pre-filled above; anyone who prefers not to be remembered can
  -- untick it before logging in.
  rememberPasswordBox:setChecked(true)
    
  g_keyboard.bindKeyDown('Ctrl+G', EnterGame.openWindow)

  if g_game.isOnline() then
    return EnterGame.hide()
  end

  scheduleEvent(function()
    EnterGame.show()
  end, 100)
end

function EnterGame.terminate()
  if not enterGame then return end
  g_keyboard.unbindKeyDown('Ctrl+G')
  
  enterGame:destroy()
  if loadBox then
    loadBox:destroy()
    loadBox = nil
  end
  if protocolLogin then
    protocolLogin:cancelLogin()
    protocolLogin = nil
  end
  EnterGame = nil
end

function EnterGame.show()
  if not enterGame then return end
  enterGame:show()
  enterGame:raise()
  enterGame:focus()
  enterGame:getChildById('accountNameTextEdit'):focus()
end

function EnterGame.hide()
  if not enterGame then return end
  enterGame:hide()
end

function EnterGame.openWindow()
  if g_game.isOnline() then
    CharacterList.show()
  elseif not g_game.isLogging() and not CharacterList.isVisible() then
    EnterGame.show()
  end
end

function EnterGame.clearAccountFields()
  enterGame:getChildById('accountNameTextEdit'):clearText()
  enterGame:getChildById('accountPasswordTextEdit'):clearText()
  enterGame:getChildById('accountTokenTextEdit'):clearText()
  enterGame:getChildById('accountNameTextEdit'):focus()
  g_settings.remove('account')
  g_settings.remove('password')
end

-- Dev-only LIVE/LOCAL host toggle. Enabled ONLY when host_local.lua (gitignored,
-- never shipped to players) sets DEV_MODE = true. One click swaps the login host
-- and the choice persists across restarts.
-- Animated indeterminate "loading" bar on the connecting box (Please wait...).
-- Self-stops when the box is destroyed (connect succeeds / fails / cancelled).
function EnterGame.addConnectingBar(box)
  if not box then return box end
  pcall(function()
    local bar = g_ui.createWidget('ProgressBar', box)
    bar:setOn(true)
    bar:setBackgroundColor('#c9a24a')
    bar:setHeight(8)
    bar:addAnchor(AnchorTop, 'messageBoxLabel', AnchorBottom)
    bar:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    bar:addAnchor(AnchorRight, 'parent', AnchorRight)
    bar:setMarginTop(12)
    bar:setMarginLeft(16)
    bar:setMarginRight(16)
    box:setHeight(box:getHeight() + 22)
    local pct = 0
    local function tick()
      if not bar or bar:isDestroyed() then return end
      pct = pct + 4
      if pct > 104 then pct = 0 end
      bar:setPercent(math.min(pct, 100))
      scheduleEvent(tick, 45)
    end
    tick()
  end)
  return box
end

local function getDevToggle()
  return modules.client_topmenu and modules.client_topmenu.getDevHostButton and modules.client_topmenu.getDevHostButton()
end

function EnterGame.setupDevHostToggle()
  if not (DEV_MODE and getDevToggle()) then return end
  -- capture the LIVE host once, from the public init.lua default (before any override)
  if not EnterGame.liveHost then
    EnterGame.liveHost = (Servers and Servers.Theotserver) or "play.theotserver.com:7171:860"
  end
  EnterGame.localHost = (type(DEV_LOCAL_HOST) == 'string' and DEV_LOCAL_HOST) or "127.0.0.1:7171:860"
  EnterGame.applyDevHost(g_settings.getString('devHostMode') == 'local')
end

function EnterGame.applyDevHost(useLocal)
  local toggle = getDevToggle()
  local h = useLocal and EnterGame.localHost or EnterGame.liveHost
  if Servers then Servers.Theotserver = h end
  if serverHostTextEdit then serverHostTextEdit:setText(h) end
  g_settings.set('devHostMode', useLocal and 'local' or 'live')
  if toggle then
    toggle:setText(useLocal and 'LOCAL' or 'LIVE')
    -- gold pill on LIVE, red pill on LOCAL (test-mode warning)
    toggle:setImageSource(useLocal and '/images/ui/dialog-button-sheet-off' or '/images/ui/dialog-button-sheet')
    toggle:setTooltip(useLocal and 'Connecting to LOCALHOST - click for LIVE' or 'Connecting to LIVE - click for localhost')
  end
end

function EnterGame.toggleDevHost()
  EnterGame.applyDevHost(g_settings.getString('devHostMode') ~= 'local')
end

function EnterGame.onServerChange()
  server = serverSelector:getText()
  if server == tr("Another") then
    if not customServerSelectorPanel:isOn() then
      serverHostTextEdit:setText("")
      customServerSelectorPanel:setOn(true)  
      enterGame:setHeight(enterGame:getHeight() + customServerSelectorPanel:getHeight())
    end
  elseif customServerSelectorPanel:isOn() then
    enterGame:setHeight(enterGame:getHeight() - customServerSelectorPanel:getHeight())
    customServerSelectorPanel:setOn(false)
  end
  if Servers and Servers[server] ~= nil then
    if type(Servers[server]) == "table" then
      serverHostTextEdit:setText(Servers[server][1])
    else
      serverHostTextEdit:setText(Servers[server])
    end
  end
end

function EnterGame.doLogin(account, password, token, host)
  if g_game.isOnline() then
    local errorBox = brandLoginBox(displayErrorBox(tr('Login Error'), tr('Cannot login while already in game.')))
    connect(errorBox, { onOk = EnterGame.show })
    return
  end
  
  G.account = account or enterGame:getChildById('accountNameTextEdit'):getText()
  G.password = password or enterGame:getChildById('accountPasswordTextEdit'):getText()
  G.authenticatorToken = token or enterGame:getChildById('accountTokenTextEdit'):getText()
  G.stayLogged = true
  G.server = serverSelector:getText():trim()
  G.host = host or serverHostTextEdit:getText()
  G.clientVersion = tonumber(clientVersionSelector:getText())  
 
  -- Respect the "remember account/password" checkbox. When it is UNCHECKED we
  -- forget any saved credentials right now, regardless of whether this login
  -- succeeds. When it IS checked, credentials are persisted (encrypted) on a
  -- successful login by onCharacterList — never here, and never in plaintext.
  if not rememberPasswordBox:isChecked() then
    g_settings.remove('account')
    g_settings.remove('password')
  end
  g_settings.set('host', G.host)
  g_settings.set('server', G.server)
  g_settings.set('client-version', G.clientVersion)
  g_settings.save()

  local server_params = G.host:split(":")
  if G.host:lower():find("http") ~= nil then
    if #server_params >= 4 then
      G.host = server_params[1] .. ":" .. server_params[2] .. ":" .. server_params[3] 
      G.clientVersion = tonumber(server_params[4])
    elseif #server_params >= 3 then
      if tostring(tonumber(server_params[3])) == server_params[3] then
        G.host = server_params[1] .. ":" .. server_params[2] 
        G.clientVersion = tonumber(server_params[3])
      end
    end
    return EnterGame.doLoginHttp()      
  end
  
  local server_ip = server_params[1]
  local server_port = 7171
  if #server_params >= 2 then
    server_port = tonumber(server_params[2])
  end
  if #server_params >= 3 then
    G.clientVersion = tonumber(server_params[3])
  end
  if type(server_ip) ~= 'string' or server_ip:len() <= 3 or not server_port or not G.clientVersion then
    return EnterGame.onError("Invalid server, it should be in format IP:PORT or it should be http url to login script")  
  end
  
  local things = {
    data = {G.clientVersion .. "/Tibia.dat", ""},
    sprites = {G.clientVersion .. "/Tibia.cwm", ""},
  }
  
  local incorrectThings = validateThings(things)
  if #incorrectThings > 0 then
    things = {
      data = {G.clientVersion .. "/Tibia.dat", ""},
      sprites = {G.clientVersion .. "/Tibia.spr", ""},
    }  
    incorrectThings = validateThings(things)
  end
  if #incorrectThings > 0 then
    g_logger.error(incorrectThings)
    if Updater and not checkedByUpdater[G.clientVersion] then
      checkedByUpdater[G.clientVersion] = true
      return Updater.check({
        version = G.clientVersion,
        host = G.host
      })
    else
      return EnterGame.onError(incorrectThings)
    end
  end

  protocolLogin = ProtocolLogin.create()
  protocolLogin.onLoginError = onProtocolError
  protocolLogin.onSessionKey = onSessionKey
  protocolLogin.onCharacterList = onCharacterList
  protocolLogin.onUpdateNeeded = onUpdateNeeded
  protocolLogin.onProxyList = onProxyList

  EnterGame.hide()
  loadBox = EnterGame.addConnectingBar(brandLoginBox(displayCancelBox(tr('Please wait'), tr('Connecting to login server...'))))
  connect(loadBox, { onCancel = function(msgbox)
                                  loadBox = nil
                                  protocolLogin:cancelLogin()
                                  EnterGame.show()
                                end })

  if G.clientVersion == 1000 then -- some people don't understand that tibia 10 uses 1100 protocol
    G.clientVersion = 1100
  end
  -- if you have custom rsa or protocol edit it here
  g_game.setClientVersion(G.clientVersion)
  g_game.setProtocolVersion(g_game.getClientProtocolVersion(G.clientVersion))
  g_game.setCustomProtocolVersion(0)
  g_game.setCustomOs(-1) -- disable
  g_game.chooseRsa(G.host)
  if #server_params <= 3 and not g_game.getFeature(GameExtendedOpcode) then
    g_game.setCustomOs(2) -- set os to windows if opcodes are disabled
  end

  -- extra features from init.lua
  for i = 4, #server_params do
    g_game.enableFeature(tonumber(server_params[i]))
  end
  
  -- proxies
  if g_proxy then
    g_proxy.clear()
  end
  
  if modules.game_things.isLoaded() then
    g_logger.info("Connecting to: " .. server_ip .. ":" .. server_port)
    protocolLogin:login(server_ip, server_port, G.account, G.password, G.authenticatorToken, G.stayLogged)
  else
    loadBox:destroy()
    loadBox = nil
    EnterGame.show()
  end
end

function EnterGame.doLoginHttp()
  if G.host == nil or G.host:len() < 10 then
    return EnterGame.onError("Invalid server url: " .. G.host)    
  end

  loadBox = EnterGame.addConnectingBar(brandLoginBox(displayCancelBox(tr('Please wait'), tr('Connecting to login server...'))))
  connect(loadBox, { onCancel = function(msgbox)
                                  loadBox = nil
                                  EnterGame.show()
                                end })                                
                              
  local data = {
    type = "login",
    account = G.account,
    accountname = G.account,
    email = G.account,
    password = G.password,
    accountpassword = G.password,
    token = G.authenticatorToken,
    version = APP_VERSION,
    uid = G.UUID,
    stayloggedin = true
  }
  
  local server = serverSelector:getText()
  if Servers and Servers[server] ~= nil then
    if type(Servers[server]) == "table" then
      local urls = Servers[server]      
      waitingForHttpResults = #urls
      for _, url in ipairs(urls) do
        HTTP.postJSON(url, data, onHTTPResult)
      end
    else
      waitingForHttpResults = 1
      HTTP.postJSON(G.host, data, onHTTPResult)    
    end
  end
  EnterGame.hide()
end

function EnterGame.onError(err)
  if loadBox then
    loadBox:destroy()
    loadBox = nil
  end
  local errorBox = brandLoginBox(displayErrorBox(tr('Login Error'), err))
  errorBox.onOk = EnterGame.show
end

function EnterGame.onLoginError(err)
  if loadBox then
    loadBox:destroy()
    loadBox = nil
  end
  local isBadCredentials = err:lower():find("invalid") or err:lower():find("not correct") or err:lower():find("or password")
  if isBadCredentials then
    failedLoginStreak = failedLoginStreak + 1
    -- Server bans at 5 wrong tries / 10 min (fail2ban); warn a couple tries before
    -- that point instead of letting the player hit an unexplained "connecting..."
    -- hang once actually banned - there is no way to message them AFTER that (see
    -- the module-level comment above failedLoginStreak).
    if failedLoginStreak >= 3 then
      err = err .. "\n\n" .. tr("Warning: too many wrong attempts in a row may temporarily\nlock out your connection for a few minutes. If you're not\nsure of your password, use the account recovery option\ninstead of guessing.")
    end
  end
  local errorBox = brandLoginBox(displayErrorBox(tr('Login Error'), err))
  errorBox.onOk = EnterGame.show
  if isBadCredentials then
    EnterGame.clearAccountFields()
  end
end
