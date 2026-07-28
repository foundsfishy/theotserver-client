-- CONFIG
APP_NAME = "otclientv8"  -- important, change it, it's name for config dir and files in appdata
APP_VERSION = 1342       -- client version for updater and login to identify outdated client
DEFAULT_LAYOUT = "retro" -- on android it's forced to "mobile", check code bellow

-- If you don't use updater or other service, set it to updater = ""
Services = {
  website = "",
  updater = "https://theotserver.com/updater.php",
  stats = "",
  crash = "",
  feedback = "",
  status = ""
}

-- Servers accept http login url, websocket login url or ip:port:version
-- PUBLIC default - this ships in the repo and is what every player connects to.
Servers = {
  Theotserver = "play.theotserver.com:7171:860"
}

-- LOCAL-ONLY override (gitignored, never committed). If a host_local.lua exists
-- next to init.lua it runs here and may repoint the host for local testing, e.g.:
--     Servers.Theotserver = "127.0.0.1:7171:860"
-- See host_local.example.lua. Because host_local.lua is in .gitignore, the public
-- repo always keeps the live address - you can never accidentally ship localhost.
if g_resources.fileExists("/host_local.lua") then
  pcall(dofile, "/host_local.lua")
end

--Server = "ws://otclient.ovh:3000/"
--Server = "ws://127.0.0.1:88/"
--USE_NEW_ENERGAME = true -- uses entergamev2 based on websockets instead of entergame
ALLOW_CUSTOM_SERVERS = false -- if true it shows option ANOTHER on server list

g_app.setName("Theotserver")
-- CONFIG END

-- print first terminal message
g_logger.info(os.date("== application started at %b %d %Y %X"))
g_logger.info(g_app.getName() .. ' ' .. g_app.getVersion() .. ' rev ' .. g_app.getBuildRevision() .. ' (' .. g_app.getBuildCommit() .. ') made by ' .. g_app.getAuthor() .. ' built on ' .. g_app.getBuildDate() .. ' for arch ' .. g_app.getBuildArch())

if not g_resources.directoryExists("/data") then
  g_logger.fatal("Data dir doesn't exist.")
end

if not g_resources.directoryExists("/modules") then
  g_logger.fatal("Modules dir doesn't exist.")
end

-- settings
g_configs.loadSettings("/config.otml")

-- set layout
local settings = g_configs.getSettings()
local layout = DEFAULT_LAYOUT
if g_app.isMobile() then
  layout = "mobile"
elseif settings:exists('layout') then
  layout = settings:getValue('layout')
end
g_resources.setLayout(layout)

-- load mods
g_modules.discoverModules()
g_modules.ensureModuleLoaded("corelib")

-- Cursor fix: OTCv8's g_mouse.loadCursors reads cursor files from the physical
-- work dir, NOT the mounted data.zip -- so a packaged (archive-boot) client shows
-- NO cursors at all (target crosshair, window-resize, text). Copy them out of the
-- archive into the work dir before client_styles loads them. Harmless on a loose
-- dev boot (files already on disk) and cheap (a few tiny files, once at startup).
do
  pcall(g_resources.makeDir, '/data')
  pcall(g_resources.makeDir, '/data/cursors')
  for _, f in ipairs({'cursors.otml', 'targetcursor.png', 'horizontalcursor.png',
                      'verticalcursor.png', 'textcursor.png', 'pointer.png'}) do
    local rel = '/data/cursors/' .. f
    local ok, data = pcall(g_resources.readFileContents, rel)
    if ok and data and #data > 0 then
      pcall(g_resources.writeFileContents, rel, data)
    end
  end
end

local function loadModules()
  -- libraries modules 0-99
  g_modules.autoLoadModules(99)
  g_modules.ensureModuleLoaded("gamelib")

  -- client modules 100-499
  g_modules.autoLoadModules(499)
  g_modules.ensureModuleLoaded("client")

  -- game modules 500-999
  g_modules.autoLoadModules(999)
  g_modules.ensureModuleLoaded("game_interface")

  -- game_tasks (Faqir's Tasks window) is discovered fine but autoLoadModules
  -- never picks it up on its own for a reason not yet understood (a stale
  -- data.zip sitting in this dev folder predates the module and may be
  -- feeding a cached registry - unconfirmed). Force it explicitly, same
  -- pattern as crash_reporter/updater below, rather than block on that.
  if g_modules.getModule("game_tasks") then
    g_modules.ensureModuleLoaded("game_tasks")
  end

  -- mods 1000-9999
  g_modules.autoLoadModules(9999)
end

-- report crash
if type(Services.crash) == 'string' and Services.crash:len() > 4 and g_modules.getModule("crash_reporter") then
  g_modules.ensureModuleLoaded("crash_reporter")
end

-- run updater. The isLoadedFromArchive() gate is REQUIRED: OTClientV8's file-apply
-- step (g_resources.updateData) FATAL-ERRORS with "Client can be updated only when
-- running from zip archive" if the client booted from loose files. So the updater
-- only runs when the client is loaded from the archive (a proper packaged run);
-- loose/dev runs skip it cleanly. Confirmed live 2026-07-05: removing this gate let
-- the download+checksum succeed but then crashed at apply on a loose-booted client.
-- HTTPS-only pin: the updater runs ONLY when its URL is https:// -- a plain-HTTP
-- URL (accidental or a downgrade attempt) disables the updater instead of pulling
-- code over an unencrypted channel.
if type(Services.updater) == 'string' and Services.updater:find('^https://')
  and g_resources.isLoadedFromArchive() and g_modules.getModule("updater") then
  g_modules.ensureModuleLoaded("updater")
  return Updater.init(loadModules)
end
loadModules()
