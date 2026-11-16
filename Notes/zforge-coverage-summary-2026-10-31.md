# Zforge simulated-mode coverage — consolidated (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Zforge
`c127bcaa357e39fabdd7f0cdf2085b43f6aff200` (clean working tree), one build used for every comparison
(`Zforge.debug.dylib` SHA-256 `da557f4a8d41b160…`; simulated copies have the same `__text`). Tool at
`13c5516`. Details per stage: `Notes/zforge-real-vs-simulated-2026-10-31.md`,
`Notes/zforge-stage1-keyboard-2026-10-31.md` … `Notes/zforge-stage8-in-app-drags-2026-10-31.md`.

Method for every test: real run and simulated run on the same build; outcome, failing assertion
(line and message), XCTest activity tree (normalized), duration, screen guard; one injected
regression per new capability, built from a copy of the sources, run in both modes; after every tool
change, the sample suite (with its regressions) and every validated Zforge test re-run in the
simulated mode and diffed against their real references.

## The 17 tests classified as simulable before stage 1

| # | Test | Verdict | Real | Simulated | Regression detected in both modes |
|---|---|---|---|---|---|
| 1 | testKeyboardShortcutHelpOpensAndFilters | equivalent | 14.50 s | 15.10 s | yes (⌘/ removed) |
| 2 | IconPreview…testSettingsToggleUpdatesTheOpenGridAndKeepsSelection | equivalent | 37.78 s | 40.44 s | yes (grid ignores the preference) |
| 3 | testBlankAreaUsesMoreMenuInEveryView | equivalent | 72.37 s | 80.95 s | yes (blank area without menu) |
| 4 | BrowserSearch…testCommandFFocusesToolbarSearchAndEscapeCollapsesIt | **fails in real** (pre-existing), fails identically | 11.39 s (fail) | 12.16 s (fail) | n/a |
| 5 | testListKeyboardZoomAndArrowNavigationAfterChangingView | equivalent (after key-code fix) | 16.30 s | 17.02 s | yes (⌘- removed; arrows ignored) |
| 6 | testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode | equivalent (after menu bar navigation fix) | 33.99 s | 37.00 s | yes (File ▸ Open no-op) |
| 7 | testCompactToolbarMenusOpenFromTheirToolbarButtons | equivalent | 17.28 s | 18.53 s | yes (overflow not tracked) |
| 8 | testFileOpenPrecedesOpenWithAndTracksSelectionInListMode | equivalent | 30.13 s | 36.94 s | yes (⌘-click clears selection) |
| 9 | testViewModeIsPerWindowAndLastClosedWindowRestoresIt | equivalent (after ⌘Q fix) | 31.65 s | 33.51 s | yes (close does not save the mode) |
| 10 | testTagEditorIsSharedByToolbarAndContextMenu | equivalent (after hover, sampling and isolation fixes) | 19.40 s | 20.08 s | yes (no mouseMoved; tag name not bound) |
| 11 | testFolderSelectionMenuAlternatesWithOptionInListMode | equivalent | 11.80 s | 12.68 s | regression not detected by this test in either mode (detected by #12) |
| 12 | testNewFolderWithSelectionMenuAndShortcutInListMode | equivalent | 52.65 s | 56.60 s | yes (wrong alternate modifier; rename not committed; double click as single) |
| 13 | Localization…testLanguageSelectionUpdatesOpenMenuAndPersists | equivalent | 32.14 s | 41.33 s | yes (picker constant; language not saved) |
| 14 | testColumnPreviewRefitsAfterUserScrollsLeft | equivalent (after scroll fixes) | 19.35 s | 19.45 s | yes (columns do not scroll) |
| 15 | Settings…testListColumnsReorderByDragging | equivalent | 20.50 s | 27.65 s | yes (row drag does nothing) |
| 16 | Settings…testArchiveSizeLimitSliderHoldsRoundValuesWhileDragging | **fails in real** (pre-existing), fails identically | 15.05 s (fail) | 17.05 s (fail) | n/a |
| 17 | testListHeaderDividerResizesAndHeaderBodyReorders | **real-only** (header reorder is window-server drag and drop) | not run | refused with an explicit unsupported log | n/a |

Totals: 14 equivalent passing tests (all with a regression caught identically in both modes);
2 tests that fail in the real mode at `c127bca` and fail identically offscreen; 1 test moved to the
real-only group. The 14 passing tests take 409.8 s real and 457.3 s simulated (+12 %; per action
+0.1–0.2 s from the agent round trips; range +4 % to +35 % per test).

Other findings to report to Zforge (not investigated there):
- order dependency: #7 fails (`ZforgeUITests.swift:914`, "Missing Compress Selected") when it runs right
  after #3, in both modes;
- #4 and #16 fail in the real mode on the clean build.

Real-only group (not simulable): Finder ×2, window-server drag and drop ×5 (the four archive drag
tests and #17), out-of-process open panels ×3 (folder chooser, two automation tests) — 10 tests.

## Screen safety over the whole stage work

Every simulated run recorded 0 synthetic events in the session and no cursor movement caused by the
tool. Exceptions, all fixed and recorded in the stage notes: the Core Drag drag window became visible
in three stage-8 runs (window-server drag and drop is now refused in the agent; two of the three were
runs on a stale agent copy, now prevented by the helper); testmanagerd's Automation Mode
authentication prompt appeared when UI tests had not run for ~20 min (inherent to XCUITest on this Mac;
removable once with `automationmodetool enable-automationmode-without-authentication`, user decision);
the user's real cursor influenced hover inside menus until the stage-4 isolation fix.

## Capabilities still emulated (with caveats)

| Capability | How | Caveat |
|---|---|---|
| Activation and key window | `-[NSApplication isActive]` sticky, simulated activated event, key window chosen in-process | AppKit still re-derives some state from the window server (`onFirstEvent` ends key/main); private-state differences possible |
| Menu bar | approximated layout (Apple menu 42 pt + title widths), menus opened as pop-ups, `AXSelected`, ←/→ and hover switching | geometry differs by a few points from the real bar; no Apple menu; ← from the app menu wraps to the last menu |
| Tracking areas | emulated enter/exit/moved on the simulated cursor, plus AppKit's own manager restricted to simulated locations | cursor rects and `cursorUpdate:` not emulated; `NSTrackingInVisibleRect` clipped to bounds |
| Pointer motion | interpolated at ~240 Hz to match testmanagerd | timing only approximates the hardware path |
| Scroll | continuous pixel events of ~21 pt over the record duration, window number and window location set | no scroll/momentum phases, no trackpad gestures (swipe, magnify, rotate) |
| Keyboard | CGEvent-derived key events, main-block key codes from the current layout, keyboard type set | `eventType` 11 (raw key codes with phases) not handled; dead keys and input methods not handled |
| Screenshots | rendered from the app's layer trees | vibrancy/glass and some `draw(_:)` content missing; fine for attachments, not for pixel comparison |
| Isolation from the user | invisible click-through windows, real pointer events dropped by source pid, AppKit real-cursor tracking paths neutralized | relies on private AppKit methods; the controlled cursor probe did not isolate which layer was decisive |
| Not supported | window-server drag and drop (refused explicitly), out-of-process panels, other apps, multiple displays | these tests stay in the real lane |

## Recommendation: parallel lanes next

Go, as a measured prototype, because the simulated mode is now equivalent for every simulable Zforge test
and serial offscreen runs are ~12 % slower than real ones; parallelism is where the time is recovered.

1. **Lane isolation first.** XCUITest terminates a running app with the same bundle ID on launch, and
   Zforge shares one app group container; each lane needs its own app copy with a distinct bundle ID
   (and preferences suite, already randomized by several tests) and its own runner copy. Re-signing
   with a new identifier is already part of `prepare-xctestrun.py`'s job.
2. **Start with 2–3 lanes** of `xcodebuild test-without-building` on prepared xctestruns, measured
   against the 457 s serial simulated baseline and the 410 s real baseline; watch CPU, memory, and
   testmanagerd/Automation Mode behavior with several sessions.
3. **Deterministic lane assignment**: the BlankArea → CompactToolbar order dependency shows that test
   order matters in Zforge; keep a fixed order per lane and report order-dependent failures as such.
4. Keep a **real lane** for the 10 real-only tests, run when the user allows the screen to be used.
5. Each lane result must keep the equivalence checks: trees diffed against real references on a
   sample, regressions caught, screen guard clean.
