# WinTaskbar for macOS

[![Release](https://github.com/tinymins/WinTaskbar-for-macOS/actions/workflows/release.yml/badge.svg)](https://github.com/tinymins/WinTaskbar-for-macOS/actions/workflows/release.yml)

A Windows-style taskbar for macOS.

WinTaskbar is a native AppKit and SwiftUI application that brings a familiar Windows-style taskbar workflow to macOS, including pinned and running apps, window previews, a searchable Start menu, system tray controls, and multi-display layouts.

## Features

- Borderless multi-display taskbar at the bottom, top, left, or right
- Pinned and running app merging, drag reorder, overflow, Dock badges, context menus, recent projects, and per-app shortcuts
- Window enumeration, hover previews, thumbnails, activation, minimization, Show Desktop, and taskbar-aware window fitting
- Searchable Start menu with custom folders, category grouping, drag-and-drop shortcuts, and power actions
- Interactive clock/calendar, battery, volume, Wi-Fi, and input-source tray controls
- Dock hiding and restoration, launch at login, global hotkeys, onboarding, and permission guidance
- Twelve bundled localizations, including Simplified Chinese

## Requirements

- macOS 13 or later
- Swift 6.2 or later

## Download

Each [GitHub Release](https://github.com/tinymins/WinTaskbar-for-macOS/releases) provides three builds:

| Package | Mac type |
|---|---|
| `macos-arm64` | Apple Silicon Macs (M1 and newer) |
| `macos-x86_64` | Intel Macs |
| `macos-universal` | Both Apple Silicon and Intel Macs |

Release archives are ad-hoc signed but not Apple-notarized. On first launch, macOS may require opening the app from the Finder context menu.

## Run from source

```bash
swift run WinTaskbar
```

## Build the macOS app

```bash
bash Scripts/package_app.sh
open dist/WinTaskbar.app
```

The generated app is ad-hoc signed for local use.

## Verification

```bash
bun run lint
bun run tsc
```

`bun run tsc` performs a full Swift build and runs the built-in defaults and persistence self-test without requiring a full Xcode installation.

See [FEATURES.md](FEATURES.md) for the item-by-item feature matrix.

## Automated releases

Pushing a semantic version tag such as `v0.0.1` builds, validates, and publishes the three architecture packages with SHA-256 checksum files. The same build matrix can be run without publishing from the Actions tab.

## Known limitations

- Wi-Fi SSID visibility can require Location permission on newer macOS versions.
- Accessibility, Screen Recording, and Automation features require the corresponding macOS permissions.

## License

WinTaskbar is released under the [MIT License](LICENSE).
