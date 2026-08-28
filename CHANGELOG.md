# Changelog

All notable changes to WinTaskbar for macOS are documented here.

## [0.0.17] - 2026-08-28

### Added

- Recreate the Windows 11 clock and calendar flyout with animated navigation, Chinese lunar dates, holidays, system events, and a Fluent-style event editor.
- Add Windows 11-style quick settings and input source panels with paged detail views for audio, battery, accessibility, and related controls.
- Add configurable Windows shortcut bindings, the Win+X quick-link suite, a standalone paged settings window, and Windows-style clock and date formatting options.
- Mirror third-party macOS status items into the taskbar tray with persistent overflow organization, draggable system items, and Windows-style hover titles.
- Add Windows-style taskbar auto-hide, Show Desktop strip behavior, and an expanded empty-area context menu.

### Fixed

- Stabilize window preview animation, sizing, click pinning, and Aero Peek switching while reducing unnecessary thumbnail and panel work.
- Refresh external status items incrementally off the main thread, forward composite item clicks reliably, and support wide labels without app-specific handling.
- Preserve attention indicators while auto-hidden, unmute audio when adjusting volume, retain terminal menu entries, and align Windows input-source switching behavior.

## [0.0.16] - 2026-08-26

### Fixed

- Match the app jump list's taskbar margin to the Windows-aligned 8pt spacing shared by the Start menu on every taskbar edge.

## [0.0.15] - 2026-08-26

### Fixed

- Isolate live drag position updates to the dragged icon overlay instead of recomputing the entire taskbar on every pointer event.
- Load window preview snapshots only when the target app's hover preview activates, removing synchronous Accessibility queries from app icon rendering.
- Preserve existing app icon views and cache their images during reorder layout changes, eliminating the full-row flash while dragging.
- Animate the dragged icon into its final taskbar slot before restoring its background and running indicator on release.

## [0.0.14] - 2026-08-26

### Added

- Animate the Start menu along the taskbar edge with Windows-style directional entrance, exit, easing, and subtle opacity transitions.
- Replace the native macOS Start button context menu with a Windows-style flyout and retained Power submenu.

### Fixed

- Anchor the Start menu and Start button context menu to the same taskbar corner with Windows-style screen and taskbar spacing.
- Wait for the Windows-default 400ms stable hover before showing the first app thumbnail preview, while preserving the shorter cross-app switch delay.
- Cancel pending thumbnail previews when the pointer leaves early and close all preview surfaces before opening the Start menu.

## [0.0.13] - 2026-08-26

### Fixed

- Reorder taskbar app icons live while dragging, with Fluent-style animated avoidance instead of a full taskbar refresh.
- Fade the dragged icon background and shrink its running indicator while keeping the icon attached to the pointer.
- Trigger avoidance when the dragged icon center crosses the target icon center, independent of where the icon was grabbed.
- Lock taskbar icon dragging to the taskbar axis so icons cannot be pulled away from the bar.

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

[0.0.14]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.13...v0.0.14
[0.0.13]: https://github.com/tinymins/WinTaskbar-for-macOS/compare/v0.0.12...v0.0.13
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
