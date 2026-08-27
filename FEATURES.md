# WinTaskbar feature matrix

| Area | Implemented behavior | Verification |
|---|---|---|
| Taskbar windows | Borderless accessory panels on bottom, top, left, or right; all or primary display | Live UI + build |
| Pinned apps | Pin/unpin, Finder drop, drag reorder | Live UI/context menu |
| Running apps | Launch/activate/minimize, active indicator, quit, new window, Finder reveal | Live UI/context menu |
| Overflow | Adaptive visible count and overflow menu | Code path + build |
| Dock badges | Reads Dock accessibility status labels per bundle ID | Live: ChatGPT and Feishu badges |
| Window previews | Window enumeration, hover preview, thumbnails, raise selected window | Live preview + build |
| Jump lists | Opens per-app recent projects | Live context menu |
| Per-app shortcuts | Add/remove editor and context-menu launch | Live context menu + build |
| Start menu | Searchable app list, keyboard submit, category grouping | Live UI |
| App folders | Create, rename, delete, expand, drag/move apps | Code path + build |
| Menu shortcuts | Drop files/apps, open, remove | Code path + build |
| Power rail | Lock, sleep, log out, restart, shut down with confirmation where destructive | Code path + build |
| Show desktop | Minimize and restore all visible application windows | Code path + build |
| Window fitting | Manual fit plus continuous focused-window clamping around the bar | Code path + build |
| Clock | Live time/date and graphical calendar popover | Live taskbar + build |
| Battery | Level, charging state, details popover | Live: 80% |
| Volume | Live volume/mute, slider and mute toggle | Live taskbar + build |
| Input source | Current source plus selectable installed input sources | Live current source + build |
| Wi-Fi | Power, scan, list, join/password, disconnect, rescan | Live popover; SSIDs require Location permission |
| Global hotkeys | Windows-key mapping, per-shortcut enable/action/app target, Start, Explorer, settings, search, Run, lock, panels, and pinned apps | Live settings + migration self-test + build |
| Dock control | Hide/restore Dock and orientation sync | Code path + build |
| Login item | ServiceManagement registration and status | Code path + build |
| Permissions | Accessibility, Screen Recording, Automation status/actions | Onboarding + settings UI |
| Preferences | General, Appearance, Start Menu, Features, Permissions, Hotkeys, About | Live embedded settings |
| Onboarding | Welcome, Accessibility, Dock choice | Live three-step flow |
| Localization | Twelve localization bundles including Simplified Chinese | Packaged resources |
