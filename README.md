# setres

Built-in display resolution switcher for MacBooks. Built to replace SwitchResX for
one job: run the built-in panel at 1920x1080 so game UI layouts (EVE Online's
overview, World of Warcraft's) survive launching on the road (no externals) vs.
at the desk (external 1080p display).

macOS only exposes 16:10 modes on built-in panels (max 1920x1200 in System
Settings). setres adds the missing mode via a display override
(`/Library/Displays/.../Overrides`, scaled resolutions — the same mechanism
SwitchResX used, and the one thing Apple Silicon *does* allow, unlike custom
timings), plus a small Swift CLI to switch modes. Public CoreGraphics API only,
nothing third-party.

## Install

Needs Xcode Command Line Tools (`swiftc` + `python3`) and sudo for the override.

```
./install.sh [WxH]      # default 1920x1080
# reboot
setres list 1920x1080   # the new mode(s) should show up
```

`install.sh` does three things:

- builds the CLI to `~/.local/bin/setres`
- writes a default config to `~/.config/setres/config` with the chosen
  resolution (an existing config is left untouched)
- auto-detects the built-in panel's vendor/product IDs and installs the display
  override adding the scaled modes (generated plist kept in `override/` for
  reference; an existing override for the panel is backed up to `*.bak`)

The override only takes effect after a reboot. If the target mode is already in
the mode list, the override step is skipped — re-running the installer is safe.

## Usage

```
setres                              # switch to configured target
setres reset                        # back to what it was
setres WxH                          # one-off target
setres set [WxH] [--hidpi] [--hz N] # full form
setres list [WxH]                   # all modes, hidden ones included
setres status                       # current mode / saved / watched apps / externals / target
setres apps                         # running apps with bundle IDs (* = watched)
setres watch [WxH] [--hidpi]        # daemon mode, see below
```

Low-res (1:1 pixel) modes are the default — for a game that means true target
pixels, exactly like an external 1080p display, and less GPU heat. `--hidpi`
(or `hidpi=true` in config) picks the HiDPI variant instead: crisper desktop,
but macOS composites a doubled framebuffer, and the mode may not even survive
the panel's supersampling cap — check `setres list WxH` after reboot.

The refresh rate is preserved: switching picks the target mode closest to the
display's current refresh (60Hz stays 60Hz, ProMotion 120Hz stays 120Hz).
`--hz N` or `hz=` in config overrides that.

### Config

`~/.config/setres/config` — key=value lines, `#` comments. Used by argless
`setres` and by `watch`; CLI arguments override it.

```
resolution=1920x1080
hidpi=false
# hz=60
# apps=com.ccpgames.eve-online-launcher,com.ccpgames.eveonline,net.battle.app,com.blizzard.worldofwarcraft
```

### Auto-switch on game launch

`setres watch` runs as a daemon, strictly edge-triggered:

- A watched app **launches** while none was running and **no external displays
  are connected** → switch built-in panel to the configured target.
- The **last** watched app quits → reset to the previous mode (2s debounce, so
  a launcher or client restart doesn't bounce the resolution).
- Nothing else: display plug/unplug is deliberately ignored, and a watcher
  starting while a watched app is already running leaves the resolution alone.

Watched apps are bundle IDs from `apps=` in the config (comma-separated). Default:

| Bundle ID | App |
|---|---|
| `com.ccpgames.eve-online-launcher` | EVE launcher |
| `com.ccpgames.eveonline` | EVE client |
| `net.battle.app` | Battle.net |
| `com.blizzard.worldofwarcraft` | World of Warcraft client |

Launchers are the trigger — the panel switches before the game starts. Clients
are listed too so the session survives a launcher that quits while the game
runs (Battle.net's "When I launch a game → exit" setting). Don't add background
helpers such as `com.blizzard.agent`: they outlive the launcher and would block
the reset.

To add another game: launch it, run `setres apps`, copy its bundle ID into
`apps=`. The list replaces the default, so keep the entries you still want.
The daemon reads the config once at start — restart it after editing:

```
launchctl kickstart -k gui/$(id -u)/com.entropiadev.setres
```

Enable at login:

```
cp com.entropiadev.setres.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.entropiadev.setres.plist
```

Disable:

```
launchctl bootout gui/$(id -u)/com.entropiadev.setres
rm ~/Library/LaunchAgents/com.entropiadev.setres.plist
```

Log: `~/Library/Logs/setres.log`. Saved-mode state: `~/.config/setres/saved-mode`.

## Uninstall

```
# remove the override (installer prints the exact path)
sudo rm /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-a04f
# CLI + config
rm ~/.local/bin/setres
rm -rf ~/.config/setres
# watcher, if enabled
launchctl bootout gui/$(id -u)/com.entropiadev.setres
rm ~/Library/LaunchAgents/com.entropiadev.setres.plist
# reboot
```

---

created by [entropiadev.com](https://entropiadev.com/)
