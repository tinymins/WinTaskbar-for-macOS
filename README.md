# WinTaskbar for macOS

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

## Known limitations

- Wi-Fi SSID visibility can require Location permission on newer macOS versions.
- Accessibility, Screen Recording, and Automation features require the corresponding macOS permissions.

## License

WinTaskbar is released under the [MIT License](LICENSE).
