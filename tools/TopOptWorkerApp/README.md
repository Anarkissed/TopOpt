# TopOpt Worker (macOS menu-bar app)

A set-and-forget menu-bar app that runs the TopOpt optimizer on your Mac so the
iPad can offload runs to it over the LAN (handoff 097). Download once, open once,
done — a menu-bar item shows it's alive, and it survives reboots.

## What it does

- **Supervises the existing Python worker** (`tools/topopt-worker/topopt_worker.py`,
  bundled into the app) as a subprocess, restarting it if it dies. There is one
  HTTP server implementation — the Python one; this app does not reimplement it.
- **Advertises `_topopt._tcp` on the LAN** (Bonjour/NetService) with the core
  fingerprint in the TXT record, so the iPad discovers this Mac **by name** and can
  warn about version skew before a run — no IP address is ever typed.
- **Holds a keep-awake assertion only while a job is running** (so the Mac never
  sleeps mid-solve, and is free to sleep when idle).
- **Menu**: running/port status · active job (rung/iter) · core fingerprint ·
  Start/Stop/Restart · Launch at Login (SMAppService) · Update core… · Settings ·
  Quit.
- **Locates `topopt-cli`**: a binary bundled in the app if present, else the path
  set in Settings. If it's missing or `--version` fails, the menu says so in plain
  words with the build command, instead of running a dead server.

## Build & install

```sh
./tools/TopOptWorkerApp/build_and_install.sh          # build + copy to /Applications
./tools/TopOptWorkerApp/build_and_install.sh --build  # build only
```

Or open `TopOptWorkerApp.xcodeproj` in Xcode and Run.

## First launch (signing is out of scope)

The app is **ad-hoc signed, not notarized** (notarization/signing is out of scope
for handoff 097). So the first time, macOS blocks it as an "unidentified
developer": **right-click `TopOpt Worker` in /Applications → Open → Open**. After
that it launches normally. Toggle **Launch at Login** in the menu so it comes back
after a reboot.

## Providing topopt-cli

The app runs the optimizer via `topopt-cli`. If you don't bundle one into the app,
open the menu → **Settings…** and point it at your built binary (e.g.
`core/build/topopt-cli`), or build it once:

```sh
cmake --build core/build --target topopt_cli
```

The iPad refuses a worker whose core fingerprint differs from the app's build. To
update this Mac's core, the menu's **Update core…** shows the rebuild command
(git pull + rebuild topopt_cli). Actual auto-update is out of scope for 097.

## Local Network permission

On recent macOS, advertising/serving on the local network needs the system
**Local Network** privacy permission. The first time the app publishes its Bonjour
service, macOS prompts once — allow it so the iPad can discover this Mac. (This
prompt is interactive and can't be granted headlessly, so the live Bonjour
advertise/browse handshake is device QA; the offload run path itself works over a
direct/localhost address without it.)
