# Zforge stage 4 — sheet with typing, hover inside a context menu (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Zforge `7ea66ec`
(clean), same build as the earlier stages (`Zforge.debug.dylib` `da557f4a8d41b160`). Zforge repository
only read. Real runs announced before and after.

## Test and new capabilities

`testTagEditorIsSharedByToolbarAndContextMenu`: sheet presented from a toolbar button, focus and typing
in the sheet's text field, Escape dismissing the sheet, context menu whose item is a custom view (tag
circles) that retitles another item on hover (tracking area with entered/moved inside the menu window),
full-screen screenshots.

## Tool changes

1. **Tracking areas in menus and mouseMoved.** The emulation now walks every known window (menu windows
   are not in `NSApp.windows`), delivers `mouseMoved:` to owners of areas created with
   `NSTrackingMouseMoved`, and updates areas directly while a menu is tracking (a menu's loop consumes
   the queued marker events without dispatching them).
2. **Pointer sampling rate.** Real runs show testmanagerd emits ~24 points per 0.1 s move (~240 Hz,
   13–55 px apart, from the screen guard's synthetic-event log); the agent used 6. Where an area is
   entered depends on this: with 6 points the "no mouseMoved" regression passed in the simulated mode
   but failed in the real mode. Now 240 Hz.
3. **Isolation from the user's real cursor.** The invisible windows sit at their real screen geometry,
   so the user's cursor reached the simulated app: (a) the window server sent tracking-area entered
   events (source pid 0) to the open menu window, and (b) AppKit's tracking-area manager turned real
   cursor locations into entered/exited events of its own (`-[_NSTrackingAreaAKManager
   setCursorForMouseLocation:]` from the display cycle when the cursor enters a window's structural
   region, and `_updateMenuActiveTrackingAreasForWindowLocation:` from a dequeuing observer). Found
   because the new sample test passed or failed depending on where the user's cursor rested (passed
   at 821,146; failed at 840,902, inside the area where the menu row opens). Fixes in the agent:
   pointer events whose CGEvent source pid is not the app's own are dropped in
   `-nextEventMatchingMask:…`; AppKit's tracking-area updates are accepted only at the simulated cursor
   location; `-setCursorForMouseLocation:` is a no-op. Controlled check, with the user's cursor parked
   inside the area where the menu row opens: correct result 2/2 with the fixes; a control build without
   the `setCursorForMouseLocation:` no-op also gave the correct result once, so that probe did not
   isolate which layer was decisive (the lldb trace of a failing case showed that call creating the
   event). The full XCTest run of the sample test then passed with the user's cursor inside the row
   area (876,909), the condition that previously failed.

## Sample app

New test `testHoverInsideContextMenu` (AppKit context menu with a custom-view item using an
entered/moved tracking area that retitles another item) and compile-time regression `MENUHOVER`.

| | Real | Simulated | Tree |
|---|---|---|---|
| base | pass 6.62 s | pass 7.88 s | identical (61) |
| MENUHOVER | fail line 97 "Not hovered" ≠ "Hovered left" | same | identical (32) |

## Zforge results

| | Real | Simulated | Assertion | Tree |
|---|---|---|---|---|
| unmodified | pass 19.40 s | pass 20.08 s | — | identical (154) |
| tagmoved: quick-tag row area without `.mouseMoved`, `576156eb7a6fbe22` | fail `:711` "Edit Tags" ≠ "Red" | same (after the 240 Hz fix; passed before) | same | identical (116) |
| tagname: "Tag name" field bound to a constant, `ee79ffb4c425e2c5` | fail `:685` | same | same | identical (71) |

Screen guard: real 2 frontmost changes and 160–432 synthetic events per run; simulated 0.

## Revalidation (simulated, no screen)

Sample suite 8/8 and its HOVER/MENU/FOCUS regressions as before; new sample test and its regression
identical to real; all validated Zforge tests pass with identical trees (only `Terminate` steps caused
by run composition and one asynchronous runtime note differ).

## Verdict

`testTagEditorIsSharedByToolbarAndContextMenu`: **equivalent** (outcome, trees, both regressions) after
the tracking-area, sampling-rate and isolation fixes.
