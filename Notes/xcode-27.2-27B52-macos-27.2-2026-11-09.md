# Xcode 27.2 (27B52) and macOS 27.2 (26B123) — what broke and the fixes, 2026-11-09

Environment: `xcodebuild -version` = Xcode 27.2, Build version 27B52 (installed 2026-11-06);
macOS 27.2 (26B123), arm64. Previous validated environment: Xcode 27.1 (27A9275), macOS 27.0.1
(26A434) — `Notes/xcode-27.1-27A9275-interfaces.md`.

Symptom (consumer Zforge, every offscreen test): `Failed to activate application … (current state:
Running Background)` right after `app.launch(); app.activate()`; a clean consumer checkout failed the
same way. Four independent changes were found, one behind the other: each fix exposed the next.

## 1. `XCUILaunchServicesMonitor` is gone: the launch hooks were never installed

`XSInstallGuardsIfPossible` installed the runner-side activation guards **and** the
`XCUIApplicationImpl` launch hooks, but only once `XCUILaunchServicesMonitor`,
`XCUILaunchServicesFramework` and `XCUIApplicationImpl` all existed. Xcode 27.2's XCUIAutomation no
longer has `XCUILaunchServicesMonitor` (`nm` shows `XCUIPlatformApplicationManager` instead), so
nothing was installed and the log line `installed LaunchServices activation guards` was missing.
Consequences: the app launched **without the agent** (the screen guard saw a real Zforge window,
`visibleWindows=1`), the bundle was never marked simulated, its state stayed 3 (background) instead
of being reported as 4, and `setFrontProcess` was refused (`not simulated: refused`) → "Running
Background".

`-[XCUIPlatformApplicationManager setFrontProcess:completion:]` only forwards to its
`platformApplicationServicesProvider` (disassembly), i.e. the daemon session, whose `_XCT_setFrontProcess`
the proxy already simulates; it is on the normal activation path and must **not** be refused.

Fix (shim): the launch hooks are installed on their own as soon as `XCUIApplicationImpl` exists
(`installed launch hooks on XCUIApplicationImpl: yes`; an `ERROR` line otherwise, and a refused
`setFrontProcess` then says the app was launched without the agent). The guards are installed per
class that exists: `XCUILaunchServicesFramework -setFrontProcess:error:` (27.1 and 27.2) and
`XCUILaunchServicesMonitor -setFrontProcess:completion:` (27.1 only).

## 2. `-[XCElementSnapshot displayID]` aborts the runner (SkyLight `CGS_REQUIRE_INIT`)

With activation fixed, the runner aborted at the first synthesized event:
`Assertion failed: (did_initialize), function CGS_REQUIRE_INIT, file CGInitialization.c, line 44`
(crash report stack: `SLSGetDisplaysWithRect` ← `XCTDisplayInterface.firstDisplayID(containing:)` ←
`-[XCElementSnapshot displayID]` ← `+[XCUIElementBaseEventTarget _dispatchEventWithEventBuilder:…]`).
`-displayID` of a snapshot whose display is not loaded and whose application's device is local
computes it from the frame through CoreGraphics in the runner. The agent's snapshots come from the
app's local engine without a display, and the runner (`LSBackgroundOnly`) never opens a window-server
session; SkyLight now asserts for any rect in such a process (probe: a command-line tool calling
`CGGetDisplaysWithRect` aborts the same way, and does not after `CGMainDisplayID()`). Under 27.1 the
same path only logged `[DisplayManager] Could not find any displays containing rect (inf, inf, 0.0, 0.0)`.

Fix (shim): `CGMainDisplayID()` at load opens the runner's CoreGraphics session (a connection only:
no window, activation or event). The runner again logs the 27.1 `DisplayManager` lines.

## 3. Alert sheets are shown through an ordering proxy window

`testCompressionProfileOpensSavesAndDeletes` (Zforge) clicked the sheet's Cancel button and the sheet
stayed. Trace (agent, temporary): the click went to `AppKit._NSGlassEffectWindow` (#34120, 410×288,
level 0, first in the window server order), a child of `_NSAlertPanel` (#34119, 260×138), which is
**not in the window server's window list** at all. The glass window's content is an
`NSGlassEffectView` → `_NSGlassEffectWindowLayerHostView` (it hosts the panel's layers); the panel
keeps `_NSAlertContentView`, the `_NSAlertButton`s and key status. `_NSGlassEffectWindow` implements
`-_orderingProxiedWindow` (and `_preventsActivation`, `canBecomeKeyWindow` NO). The glass window does
not set `ignoresMouseEvents`, so that is not how clicks pass through.

Fix (agent): `XAWindowAtPoint` gives a point inside an ordering proxy to the proxied window when the
point is inside that window's frame, and otherwise continues below (the glass margin).

## 4. Pending tracking areas of menu item views

`testTagEditorIsSharedByToolbarAndContextMenu` hovers a tag circle in a context-menu item's custom
view (an `NSTrackingArea` added in `-updateTrackingAreas`). At hover time the view had **0 tracking
areas** (chain `FinderTagQuickRowView < NSMenuItemViewer < NSCustomMenuItemView < NSTableRowView <
NSTableViewBackedMenuRepresentation < NSClipView < NSMenuScrollView < NSView < NSGlassContentFrameView`,
window `NSPopupMenuWindow`): AppKit had not called `-updateTrackingAreas` yet. Calling the window's
`_NSTrackingAreaAKManager` (`NSWindow` ivar `_trackingAreaManager`) `-_updateTrackingAreasIfNeeded`
before evaluating the simulated cursor installed the area and the hover worked. The selectors the
agent already hooks (`_updateMenuActiveTrackingAreasForWindowLocation:modifierFlags:`,
`_updateActiveTrackingAreasForWindowLocation:modifierFlags:`, `setCursorForMouseLocation:`) still exist.

Fix (agent): `XAUpdateTrackingAreas` first brings each window's pending tracking areas up to date
(`XAUpdatePendingTrackingAreas`), as AppKit does when it routes a pointer event from the window server.

## Evidence

Zforge offscreen set (18 tests: UI-Full minus `offscreen.realOnly`), 3 lanes, no Automation Mode:

| Run | Build | Result | Screen guard |
|---|---|---|---|
| `affected-20261109-*` (before) | Zforge `main` | 0 of every set ("Running Background") | 1 visible Zforge window (no agent) |
| `zf66-repro1` | `main`, fix 1 only | runner abort (fix 2 needed) | clean |
| `zf66-full-1` | `main`, fixes 1–2 | 13/18 | clean (user's own Safari/Siri activity only) |
| `zf66-base-519a085` | Zforge `519a085` (16/16 on 2026-11-02 under 27.1), fixes 1–2 | 16/18 (sheet, menu hover) | clean |
| `zf66-base-519a085-fixed` | same, fixes 1–4 | **18/18** | 0 front changes, 0 windows, 0 synthetic, 0 hardware events |
| `zf66-main-fixed` | Zforge `main` (`70e4382`), fixes 1–4 | 16/18 | same, clean |

The two failures on `main` are in Zforge's Settings window, which changed after the last 27.1 run
(ZF-62: panes became a SwiftUI `ScrollView` instead of a grouped `Form`); they pass on `519a085`
with the same tool. See the consumer's records for their analysis.

Not re-validated in this round: the tool's own sample app and its negative controls
(`Scripts/run-sample-regressions.sh`), and a real-mode comparison (real runs take the screen).
