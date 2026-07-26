-- LOCAL DEV OVERRIDE (template) -- enables the in-client LIVE/LOCAL host toggle.
--
-- To use:
--   1. Copy this file to "host_local.lua" (same folder as init.lua).
--   2. host_local.lua is in .gitignore, so it never gets committed/shipped.
--   3. Restart the client. A small "Server: LIVE / LOCAL" button appears on the
--      login (top-left) -- click it to switch instantly; your choice is remembered.
--   4. Delete host_local.lua to remove the button entirely (players never have it).
--
-- This only sets flags; it does NOT change the public Servers default in init.lua,
-- so play.theotserver.com is always what ships.

DEV_MODE = true
DEV_LOCAL_HOST = "127.0.0.1:7171:860"   -- the "LOCAL" target the toggle points to
