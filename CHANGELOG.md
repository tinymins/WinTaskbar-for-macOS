# Changelog

All notable changes to WinTaskbar for macOS are documented here.

## [0.0.8] - 2026-08-26

### Fixed

- Keep the first window preview immediate while requiring a short stable hover before switching an already visible preview to another app.
- Cancel stale preview switch tasks during fast taskbar pointer movement so only the final hovered app animates into place.

## [0.0.7] - 2026-08-26

### Fixed

- Keep the active window preview open when its taskbar app icon is clicked.
- Match the Start button's pressed scale, background, and release animation on taskbar app icons.

## [0.0.6] - 2026-08-26

### Fixed

- Delay the first Aero Peek activation by 300ms to prevent flashes when the pointer only passes over a window preview.
- Switch Aero Peek immediately between window previews after it has activated for the current hover session.

## [0.0.5] - 2026-08-26

### Fixed

- Reapply the saved system Dock hiding preference whenever WinTaskbar launches.
- Restore the system Dock on exit without clearing the preference used by the next launch.

## [0.0.4] - 2026-08-26

### Added

- Add an Exit action beside the system Dock control with a centered confirmation dialog.

### Fixed

- Reuse one animated window preview panel when moving between taskbar apps, preventing overlapping previews while smoothly adapting its position and size.
- Restore the system Dock when WinTaskbar exits after hiding it.

## [0.0.3] - 2026-08-25

### Fixed

- Show window previews immediately when hovering over a taskbar app while retaining a short dismissal delay.
- Match Windows preview thumbnail proportions and refine preview panel styling.

[0.0.8]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.2...v0.0.3
