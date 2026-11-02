# Open menus closed by the user's app switches — 2026-11-02

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64.

## Symptom

Zforge's `testBlankAreaUsesMoreMenuInEveryView` failed offscreen while the user was working: the toolbar
More menu or a context menu closed about 0.3 s after it opened (`Failed to get matching snapshot: No
matches found … Descendants matching type Menu`, or a menu item that never appeared). Alone, without
Automation Mode, it failed 3 of 4 runs (`affected-20261102-1032*`–`1035*`) and 3 of 6 in a later series.
ScreenGuard showed a real frontmost-application change (the user's) just before each failure.

## Cause

When another application becomes frontmost, LaunchServices notifies every application
(`kLSNotifyBecameFrontmost`, registered when a menu starts tracking). AppKit's `_applicationDidSwitch`
(a C function, through HIToolbox `HIToolboxLSNotificationCallbackAllASNsFunc`) calls
`-[NSMenuTrackingSession dismissAnimated:]` and the menu fades out. A real app gets this only when it
loses activation; a simulated app is never the active app, so every app switch of the user's closed
its open menus. Trace (`XCUISIM_APP_TRACE_MENU=1`, run `dis-1`):

```
menu-trace workspace activated com.t3tools.t3code (menus open: 1)
menu-trace dismissAnimated:1
  1 AppKit _applicationDidSwitch + 176
  2 HIToolbox DispatchEventToHandlers …
  5 HIToolbox HIToolboxLSNotificationCallbackAllASNsFunc + 228
  6 LaunchServices ___LSScheduleNotificationFunction_block_invoke_2 + 52
```

`-[NSMenuTrackingSession _handleAppDeactivateIfNeeded]` is not on this path (a swizzle of it never ran).

## Fix

The agent replaces `-[NSMenuTrackingSession dismissAnimated:]` and skips the call when its caller
(`dladdr` of the return address) is `_applicationDidSwitch`. Every other dismissal (Escape, a click
outside, choosing an item, `cancelTracking`) goes through unchanged.

## Evidence

Same Zforge build (Zforge `main` merged with `fix/offscreen-test-automation`), the test alone, without
Automation Mode, 6 runs with the trace while the user worked (`fix2-*`): **6/6 passed**; 43 real app
switches, 20 of them with a menu open; all 20 were `app switch=1` and kept the menu open; the 108 other
dismissals (the test's Escapes and item choices) went through. Before the fix, in the same conditions,
the test failed 3 of 6 (`fix-*`) and each failure followed a switch with a menu open.

## Limits

- No automated regression test: reproducing needs a real frontmost-application change, which the tool
  must not cause on the user's screen. The check is the trace above (`kept a menu open across a real
  application switch` in the agent log).
- Relies on the private symbol name `_applicationDidSwitch`; if AppKit renames it, menus close on app
  switches again (the trace shows the caller).
