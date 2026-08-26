# Changelog

All notable changes to WinTaskbar for macOS are documented here.

## [0.0.12] - 2026-08-26

### Fixed

- Restore the Quit action for running apps in Windows-style jump lists while keeping window Close actions separate.
- Keep newly pinned running apps in their current taskbar positions instead of immediately regrouping them.
- Retain pinned app icons after exit and let only unpinned exiting apps collapse the remaining taskbar items to the left.

## [0.0.11] - 2026-08-26

### Added

- Add Windows-style app jump lists positioned above their taskbar icons, with app, pin, shortcut, Finder, and close actions.
- Restore Recent project tracking from the original Demo behavior and show captured items at the top of app jump lists.

### Fixed

- Restore the original standalone shortcut management window instead of the incomplete replacement dialog.

## [0.0.10] - 2026-08-26

### Fixed

- Release app icon press feedback before performing window activation or minimization work.
- Keep multi-window app clicks visual-only while restoring, minimizing, or focusing an app with exactly one window according to its current state.
- Lengthen cross-app preview panel movement and resizing to make the acceleration and deceleration easier to perceive.

## [0.0.9] - 2026-08-26

### Fixed

- Smooth cross-app preview panel movement and resizing with a Fluent-style acceleration and deceleration curve.

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

[0.0.12]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.11...v0.0.12
[0.0.11]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.10...v0.0.11
[0.0.10]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.9...v0.0.10
[0.0.9]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.2...v0.0.3
