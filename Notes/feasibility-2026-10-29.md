# Feasibility spike — 2026-10-28/29

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Interface notes:
`Notes/xcode-27.1-27A9275-interfaces.md`.

Question: can XCTest's event synthesis be intercepted in the runner and delivered inside the app
under test so that real, unmodified XCUITests pass offscreen, and still fail when the behavior is
broken?

Answer so far: **yes for the capabilities and tests below, with caveats.** Update 2026-10-31: the
sample suite and three regressions were run real vs simulated on identical builds; see
`Notes/real-vs-simulated-2026-10-31.md` (equivalent after one menu bar fix).

## How it works

1. Runner shim (`DYLD_INSERT_LIBRARIES` via the xctestrun) wraps `-[XCTRunnerDaemonSession daemonProxy]`
   and handles: event synthesis, `setFrontProcess`, the modifier-flags query, the interruption
   query, element hit testing and screenshots. It adds `XCUISIM_ENABLED=1` to the app's launch
   environment (IDE and platform launch paths) and reports the app as running in the foreground.
   Everything else (queries, snapshots, launch, terminate, Automation Mode) still goes to testmanagerd.
2. Channel: a command encoded in an accessibility attribute name of the application element, read
   through testmanagerd (`_XCT_fetchAttributes:forElement:reply:`). No new entitlements, works across
   both sandboxes, serviced during menu tracking.
3. App agent (weak load command in the test build copy): invisible, click-through windows at their
   real geometry; sticky in-process activation; XCTest records turned into NSEvents posted to the
   app's queue (keys built from CGEvents); simulated cursor, buttons, modifier flags and tracking
   areas; a simulated menu bar layout whose menus open as in-process pop-ups; hit testing and
   screenshots answered from the app's own windows.

## Capabilities (sample app, `Sample/`)

All 8 sample tests pass offscreen, repeatedly (runs `sample-all`, ~4–7.5 s per test, ~49 s for the
suite). Negative controls: with events dropped by the agent all 8 fail; with each of the 8
compile-time regressions exactly the matching test fails and the other 7 pass.

| Capability | Result | Evidence / caveat |
|---|---|---|
| Click | works | `testButtonClick`; regression CLICK caught |
| Keyboard shortcut (⌘⇧K menu key equivalent) | works | `testKeyboardShortcut`; needs CGEvent-derived key events (Shift matching) |
| Focus + typing | works | `testTextFieldFocusAndTyping` (focus moves from another field, typed value read back); regressions TYPING and FOCUS caught |
| Context menu (open, choose item, Escape) | works | `testContextMenu`, `testContextMenuEscapeCloses`; menu window made invisible at creation |
| Menu bar | works with caveat | `testMenuBar`; the app does not own the real menu bar, so the agent fakes the menu bar item frames and `AXSelected` and opens the menu as a pop-up. Menu bar appearance/position are not those of the real menu bar |
| Modifier keys (`perform(withKeyModifiers:)`, `NSEvent.modifierFlags`) | works | `testModifierClick` checks event and global flags; regression MODIFIER caught |
| Hover (tracking areas) | works with caveat | `testHover` (enter and exit). Tracking areas are emulated by the agent (not the window server); `visibleRect` is clipped to bounds, cursor rects/`cursorUpdate:` are not emulated |
| Screenshots (`XCUIElement.screenshot()`, automatic ones) | works with caveat | rendered from the app's layer trees: vibrancy/glass materials and some `draw(_:)` content are missing; fine for attachments, not for pixel comparison. Screen recordings are switched to screenshots |

## Zforge tests (unchanged sources, build copy under `$XCUISIM_WORK`)

| Test | Offscreen | Regression caught | Duration offscreen (3 runs) | Real baseline 2026-10-27 (loaded machine) | Screen/cursor touched |
|---|---|---|---|---|---|
| `testKeyboardShortcutHelpOpensAndFilters` | pass ×4 | yes — `.keyboardShortcut("/")` removed → fails at `shortcutsWindow.waitForExistence` | 15.8–16.3 s | 22.5 s | no |
| `testSettingsToggleUpdatesTheOpenGridAndKeepsSelection` | pass ×4 | yes — grid ignores the preference → fails at `fallback(...).waitForExistence` | 39.8–40.1 s | 48.8 s | no |
| `testBlankAreaUsesMoreMenuInEveryView` | pass ×4 | yes — blank area presents no menu → fails at `popup.menuItems["Open"]` | 83.3–83.5 s | 117.1 s | no |

With events dropped by the agent, all three fail. In every regression build the two untouched tests
still passed. "Not touched" = ScreenGuard over the whole run: no frontmost-application change, no
cursor movement, no visible window of the app or runner, no event in the session posted by any
process (listen-only event tap; hardware events counted separately).

The duration comparison is indicative only: the baseline was a loaded machine and a slightly
older working tree. Most of each test's time is XCTest's own waits (quiescence, 0.4 s per click
record), which the tool does not shorten.

## Incidents during the spike (screen was touched — not by event delivery)

1. **Documents permission prompt.** Builds and tool dylibs were first under `~/Documents/...`; the
   runner reading them made macOS show "…Runner.app would like to access files in your Documents
   folder" (Zforge runner: user answered Don't Allow; sample runner around 00:13: 2 s focus change,
   outcome unconfirmed). Fix: everything the runner/app loads lives in `~/Library/Caches/dev.xcuitestsim`;
   `prepare-xctestrun.py` refuses protected folders; `run-offscreen.sh` aborts when a system dialog
   comes to the front.
2. **Automation Mode authentication.** After ~7 h without UI tests, testmanagerd asked for
   authentication (coreautha, ~5 s in front) when enabling Automation Mode. Skipping the request
   makes testmanagerd refuse the session ("Not authorized for performing UI testing actions", code 41),
   so the prompt is inherent to XCUITest on this Mac. It can be removed once by an administrator
   (`automationmodetool enable-automationmode-without-authentication`) — the user's decision.
3. The very first run (IDE launch path not yet handled) launched the app without the agent: a
   visible, inactive window appeared for ~60 s; activation was refused, so focus did not move.

## Not validated / open risks

- ~~No real run of the sample suite yet~~ — done 2026-10-31 (`Notes/real-vs-simulated-2026-10-31.md`):
  equivalent outcomes, failing assertions and XCTest action sequences after fixing `AXSelected` on the
  emulated menu bar.
- The Zforge real baseline predates the user's current uncommitted changes.
- User input during a run was not exercised (hardware events were ~0 in the Zforge runs): e.g.
  whether a real click elsewhere dismisses an open invisible menu of the app under test.
- Parallel lanes not attempted (one simulated app per runner; bundle-ID lanes still to build).
- Not handled: drag and drop, scroll/swipe beyond a basic implementation, `cursorUpdate:`, key codes
  (`eventType` 11), multiple displays (coordinates assume the primary display's height),
  out-of-process panels, system UI.
- Dock icon and Automation Mode indicators may still appear (not focus changes).

## What a proper Zforge test configuration would need (not applied)

- A `UITest` build configuration (copy of Debug) that links the agent weakly
  (e.g. embed `libXCUISimAgent.dylib` in `Contents/Frameworks` and `-weak_library`), signed by the
  same team. No entitlement, sandbox or hardened-runtime change; inert unless `XCUISIM_ENABLED=1`.
  Release unchanged.
- Runner shim inserted by the tool's CLI into the `xctestrun` (`TestingEnvironmentVariables`), not by the
  project; DerivedData outside TCC-protected folders (Xcode's default location is fine).
- Optional, user decision: Automation Mode without authentication.

## Main fragility points (private interfaces)

`-[XCTRunnerDaemonSession daemonProxy]` and the `_XCT_*` selectors listed in the interface notes;
`XCTRunnerDaemonSession` state callbacks and `XCTApplicationStateSnapshot` initializer;
`XCUIApplicationImpl _launchUsingXcode…/_launchUsingPlatform…`; `XCSynthesizedEventRecord` /
`XCPointerEvent` KVC keys and event-type numbering; `XCAccessibilityElement elementWithProcessIdentifier:`;
`XCTImage`/`XCTImageEncoding`/`XCTImageMetadata` initializers; testmanagerd passing unknown attribute
names and string values through. On the AppKit side: `NSPopupMenuWindow` creation path, legacy
`accessibilityAttributeValue:` on `NSApplication`/`NSMenuItem`, `-isActive` swizzle, CGEvent-derived
key events.
