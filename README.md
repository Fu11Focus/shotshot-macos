# ShotShot

A minimal, native (arm64, **no Rosetta**) LightShot alternative for macOS: capture a screen region, annotate it, copy or save.

Screenshots are taken via **ScreenCaptureKit** — the modern, non-deprecated API.

## Features

- Global hotkey **⌘⇧7** → freezes the screen and lets you select a region
- Resize (8 handles) and move the selected region
- Annotations: arrow, rectangle, line, text, marker; color picker; undo
- **Copy** to clipboard or **save** a PNG to the Desktop
- Background menubar agent (✂︎), no Dock icon, ~11 MB RAM

## Build

```bash
./build.sh        # compiles + bundles ShotShot.app
open ShotShot.app
```

Requires macOS 14+ and the **Screen Recording** permission (prompted on first capture).

### Stable signing (optional, for development)

So the Screen Recording permission doesn't reset after every rebuild, set up a
self-signed certificate once:

```bash
./setup-signing.sh   # creates a self-signed identity; asks for your macOS password
```

After that, `build.sh` signs with a stable identity, so the TCC grant survives rebuilds.

## How it works

- **Capture**: on the hotkey, the full screen under the cursor is grabbed with
  `SCScreenshotManager` and shown frozen in a borderless overlay window.
- **Select/annotate**: drag to select; handles resize, the border moves the region,
  the interior draws with the current tool. Export renders only the selected region
  plus annotations (the dim overlay, handles, and toolbar are excluded).
- **Signing**: an ad-hoc signature changes its cdhash on every rebuild, so macOS
  treats each build as a new app and re-prompts for Screen Recording. A stable
  self-signed certificate keeps the designated requirement constant.

## License

MIT
