#!/usr/bin/env python3
"""
build-release.py - build the player-facing Windows release (ARCHIVE MODE).

Run from the repo root:   python build-release.py
Output: ../TheOtServer-Client-Windows.zip  (the EXACT asset name download.php serves)

WHY archive mode: OTCv8 only enables its in-client auto-updater when it boots from a
data archive (g_resources.isLoadedFromArchive()). If loose module/data folders are
present, it boots in dev mode and the updater is skipped (and updateData fatal-errors).
So the release ships ONLY the binaries + a single data.zip (all runtime files at the
ZIP ROOT). This was proven live on 2026-07-06: binaries + data.zip -> archive mode ->
auto-update works end to end.

Layout of the release (inside TheOtServer/):
    otclient_dx.exe, otclient_gl.exe        (the two Windows render backends)
    *.dll                                    (libGLESv2, libEGL, d3dcompiler_47)
    theotserver.ico
    data.zip                                 (init.lua + modules/ + data/ + layouts/ + mods/)
NO loose modules/data/layouts/mods/init.lua, NO otcv8.zip, NO other-platform binaries,
NO host_local.lua (dev localhost toggle - a leak of it aborts the build).
"""
import os, sys, zipfile, fnmatch

HERE = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.join(os.path.dirname(HERE), "TheOtServer-Client-Windows.zip")
TOP  = "TheOtServer"

# Runtime tree that goes INSIDE data.zip (paths kept at the archive root).
RUNTIME_DIRS   = ["modules", "data", "layouts", "mods"]
RUNTIME_FILES  = ["init.lua"]
# Files that ship loosely alongside data.zip in the release (the binaries).
BINARY_GLOBS   = ["*.exe", "*.dll", "*.ico"]
# Legal notices that MUST ship in the zip root. LICENSE is the upstream
# OTClientV8 MIT text, and MIT requires that notice to be included in "all
# copies or substantial portions of the Software" - the player download is a
# copy, so omitting it was a real (if small) compliance gap. NOTICE.txt is
# TheOtServer's own copyright over the custom modules/artwork the MIT license
# does NOT cover. Neither has a file extension the binary globs would catch,
# which is exactly why they were being dropped silently.
LEGAL_FILES    = ["LICENSE", "NOTICE.txt"]
# Never package these (dev-only, other-platform, player runtime state, obsolete).
EXCLUDE_FILES  = [
    "host_local.lua", "host_local.example.lua",   # DEV localhost toggle - NEVER ship
    "*.theotbak", "otcv8.zip*",                    # obsolete archive + its backups
    "*.log", "*.otmm", "config.otml",              # logs + player runtime state
    # NOTE: do NOT glob "*.otml" -- that also strips data/cursors/cursors.otml
    # (the cursor DEFINITIONS), which left packaged clients with no cursors at all.
    # config.otml (player settings) is excluded by exact name above.
    "otclient_mac", "otclient_linux", "otclientv8.apk",  # other platforms
    "DONT_USE_PANELS.txt", "README.md",            # dev-only notes with zero player value
    # (vBot's own version.txt is left unexcluded - its UI may read that file)
]
skip = lambda n: any(fnmatch.fnmatch(n, p) for p in EXCLUDE_FILES)

# ---- 1) build data.zip (files at the archive ROOT, no wrapper folder) ----
DATA_ZIP = os.path.join(HERE, "data.zip")
if os.path.exists(DATA_ZIP):
    os.remove(DATA_ZIP)
dcount = 0
with zipfile.ZipFile(DATA_ZIP, "w", zipfile.ZIP_DEFLATED) as dz:
    for f in RUNTIME_FILES:
        p = os.path.join(HERE, f)
        if os.path.isfile(p) and not skip(f):
            dz.write(p, f); dcount += 1
    for d in RUNTIME_DIRS:
        for root, _dirs, files in os.walk(os.path.join(HERE, d)):
            for f in files:
                if skip(f):
                    continue
                full = os.path.join(root, f)
                arc  = os.path.relpath(full, HERE).replace("\\", "/")
                dz.write(full, arc); dcount += 1

# Safety gate: host_local.lua must never end up inside data.zip.
leaked = [n for n in zipfile.ZipFile(DATA_ZIP).namelist() if "host_local.lua" in n]
if leaked:
    os.remove(DATA_ZIP)
    sys.exit("ABORTED: host_local.lua leaked into data.zip -> " + str(leaked))
if "init.lua" not in zipfile.ZipFile(DATA_ZIP).namelist():
    os.remove(DATA_ZIP)
    sys.exit("ABORTED: init.lua missing from data.zip root (client won't boot from archive)")

# ---- 2) package the release: binaries + data.zip only ----
if os.path.exists(OUT):
    os.remove(OUT)
count = 0
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(DATA_ZIP, os.path.join(TOP, "data.zip")); count += 1
    for f in sorted(os.listdir(HERE)):
        full = os.path.join(HERE, f)
        if not os.path.isfile(full) or skip(f):
            continue
        if any(fnmatch.fnmatch(f, g) for g in BINARY_GLOBS) or f in LEGAL_FILES:
            z.write(full, os.path.join(TOP, f)); count += 1

# Safety gate: the MIT notice is a licence obligation, not a nice-to-have -
# fail the build rather than silently ship a non-compliant zip.
_names = zipfile.ZipFile(OUT).namelist()
for _legal in LEGAL_FILES:
    if not any(n.endswith("/" + _legal) or n == _legal for n in _names):
        os.remove(OUT)
        sys.exit("ABORTED: " + _legal + " missing from the release zip (required notice)")

# Safety gate: no loose modules/init.lua/host_local in the release (would break archive mode).
names = zipfile.ZipFile(OUT).namelist()
bad = [n for n in names if "host_local.lua" in n
       or n.endswith("/init.lua") or "/modules/" in n]
if bad:
    os.remove(OUT)
    sys.exit("ABORTED: loose runtime files leaked into the release -> " + str(bad[:5]))

# ---- 3) SHA-256 of the release (for the download page's integrity check) ----
import hashlib
_h = hashlib.sha256()
with open(OUT, "rb") as _f:
    for _chunk in iter(lambda: _f.read(1 << 20), b""):
        _h.update(_chunk)
sha = _h.hexdigest()

mb = os.path.getsize(OUT) / 1048576
print(f"Built {OUT}")
print(f"  data.zip: {dcount} files | release: {count} entries, {mb:.1f} MB (archive mode)")
print(f"  host_local.lua shipped: NO | loose runtime files: NO | archive-mode: YES")
print(f"  SHA-256: {sha}")
print("")
print("Next steps:")
print("  1) Publish a GitHub Release; attach the zip as exactly TheOtServer-Client-Windows.zip")
print("  2) Paste this SHA-256 into the download page (lang/*/download.php) - it replaces the old one:")
print(f"     {sha}")
