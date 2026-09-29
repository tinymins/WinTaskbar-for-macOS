# Notification action PoC

Independent macOS app for checking whether Accessibility can invoke the original
system notification action. It posts only synthetic notifications with a random
UUID, and verifies the system callback against that UUID. Opening the app alone
is not evidence of success.

## Build and run

```sh
bash Prototypes/NotificationActionPoC/build.sh
open 'dist/Notification Action PoC.app'
```

The app has its own bundle identifier and ad-hoc signature. Allow its notifications
and Accessibility access using the permission button. Rebuilding may invalidate
Accessibility permission; check it again before scanning.

## Manual scenarios

Temporarily pause other notification replacers during each scenario so they do not
automatically close the synthetic banner. Restore them immediately afterward.

1. **Visible banner:** send a notification, locate its original object, then press
   `AXPress`. Success requires a callback with the same request and target UUID.
   The `正式实现点击` button runs WinTaskbar's shared `NotificationOriginalAction`
   implementation against the already authorized synthetic subtree. Use it to
   verify the production parser, identity validation and original action together.
2. **Natural expiration:** send and locate another notification; let the banner
   expire, query this app's delivered notifications, then try the cached object.
   A stored notification and a currently actionable AX object are distinct states.
3. **Explicit closure:** send and locate another notification, use `AXCancel` if
   the object exposes it, query the remaining delivered notifications, then try
   `AXPress` on the old object. Unsupported actions are reported, never guessed.
4. **Notification Center:** optionally open Notification Center manually and retry
   locating the same selected test UUID. Do not assume its rebuilt AX object has
   the same identity as the expired banner.

## Boundaries

- Locating reads AX identifiers, descriptions and tree structure. Only a unique
  object whose identifier includes this session's test UUID, or whose description
  equals the complete generated test notification, can become an action target.
- Unmatched descriptions are discarded immediately and never displayed or logged.
- Every action revalidates the target and checks its advertised action names.
- The app does not read the notification database, inspect another app's payload,
  use an app-specific deep link, or alter WinTaskbar settings.
- Results and references remain in memory. Normal exit removes only notifications
  created during this session. Force termination cannot perform that cleanup.
- This is a manual experiment, not a production implementation or a guarantee for
  old notifications. OS return-code success alone does not prove message routing.

## Observations on macOS 26.6.2

- With WinTaskbar's automatic dismissal active, the synthetic notification was no
  longer in this app's delivered list by the time it was queried.
- During a bounded pause of WinTaskbar, the visible synthetic banner increased
  the AX tree from 8 to 16 nodes, but no AXIdentifier contained its request UUID.
- After natural banner expiration, the request remained in this app's delivered
  list while the AX tree returned to 8 nodes. Identifier-only lookup found no
  target in either state.
- On 2026-09-29, removing the stale Accessibility entry and adding the current
  app bundle restored permission; toggling the old entry and restarting alone
  had still left the app reporting `AXIsProcessTrusted() == false`.
- With WinTaskbar temporarily paused, exact-description lookup uniquely matched
  the visible banner in a complete 16-node scan. Its advertised actions included
  `AXPress`, Show Details and Close; `AXCancel` was not advertised.
- Invoking `AXPress` while that banner remained visible returned success and
  produced `com.apple.UNNotificationDefaultActionIdentifier` in this app's
  notification delegate. The callback request UUID equaled its payload target
  UUID. This verifies original-message routing for a live synthetic banner.
- For a separately captured banner, the cached target failed identity validation
  after natural expiration, while the request remained in the app's delivered
  list. No action was attempted against the invalid target.
- Repeating the live and expired scenarios with `正式实现点击` verified the shared
  production implementation: live action returned `handedOff` and received the
  matching default-action callback; the expired action returned `unavailable`
  while its request remained in the delivered list.
- WinTaskbar's important-message click now tries the retained original action,
  then a unique current card with the same UUID-bearing AX identifier and unchanged
  source/title/body, then its existing source-app opener. Text equality alone is
  never sufficient for re-finding an expired object. References remain in memory
  and are pruned as important messages and countdowns leave the runtime.
- WinTaskbar was resumed afterward without changing its configuration. Historical
  re-finding was not verified on this host, which did not expose a usable stable
  identifier. An explicitly closed notification can therefore fall back to opening
  its source app. The installed WinTaskbar was not replaced for these PoC checks.
