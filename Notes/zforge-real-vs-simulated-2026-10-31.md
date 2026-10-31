# Zforge real vs simulated, same build — 2026-10-31

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display.
Tool: zforge-xcuitest-sim at commit `0833d9a` (agent and shim built from it; an experimental agent
change made during this session was reverted, see "Duration").
Real (screen-taking) runs were authorized by the user and announced immediately before each start.

## Build

- Zforge base commit `7ea66ec470133c21025b53d7f64f6873c226a863` (2026-10-30, "feat: Finder-parity
  sidebar, toolbar search and Network level"); the working tree was clean (`git status` empty), so the
  build is exactly that commit. The Zforge repository was only read.
- Copied with rsync to `~/Library/Caches/dev.xcuitestsim/cmp-zf/src` and built once with
  `xcodebuild build-for-testing -scheme Zforge -testPlan UI-Full -configuration Debug` into `cmp-zf/dd`.
  Nothing the runner or the app loads is under `~/Documents`.
- The products were copied twice: `real/` unchanged, `sim/` prepared with `prepare-xctestrun.py`.
- SHA-256 (first 16 hex): `Zforge` stub `adfe336008b7b00e`, `Zforge.debug.dylib` `da557f4a8d41b160`
  (real copy identical to the build), test bundle `ZforgeUITests` `829e635ce29a16e4`. The simulated
  copy's `Zforge.debug.dylib` is `470a4f434e9b30ad`: same `__text` section (disassembly compared), plus the
  weak load command for the agent and a new signature.
- The real xctestrun contains only Xcode's own insertions (`libRPAC`, `libMainThreadChecker`).

## Results — unmodified build

| Test | Real | Simulated | Failing assertion | XCTest activity tree |
|---|---|---|---|---|
| testKeyboardShortcutHelpOpensAndFilters | pass 14.50 s | pass 15.10 s | — | identical (85 steps) |
| testSettingsToggleUpdatesTheOpenGridAndKeepsSelection | pass 37.78 s | pass 40.44 s | — | 215 steps; one asynchronous runtime-issue note ("This method should not be called on the main thread", raised by the test code) recorded one step earlier/later |
| testBlankAreaUsesMoreMenuInEveryView | pass 72.37 s | pass 80.95 s | — | identical (656 steps), including the File ▸ New Zforge Window menu bar path taken in every mode iteration |
| total | 124.7 s | 136.5 s (+9.5 %) | | |

Screen guard over the whole run — real: 12 frontmost-app changes, 195 cursor moves, 32 visible
windows, 1542 synthetic events from another process; simulated: 0 / 0 / 0 / 0. No hardware (user)
events in either.

Activity trees were compared from the result bundles (attachments ignored; pids, addresses, UUIDs,
timestamps and durations normalized).

## Regression in both modes (optional step)

Injected in a copy of the same sources (`BrowserNativeItemMenu.presentsMenu` returns false for the
blank area: no More menu), built once, copied real/sim (`__text` identical between the two copies).
Only `testBlankAreaUsesMoreMenuInEveryView` was run, to keep screen time short (~20 s real).

| | Real | Simulated |
|---|---|---|
| Outcome | fail 12.26 s | fail 13.36 s |
| Assertion | `ZforgeUITests.swift:392` `popup.menuItems["Open"].waitForExistence` — "icons, selected: false" | same line and message |
| Activity tree | 92 steps | 92 steps; identical up to the failure, then only the order of the polling iterations inside the 2 s wait |

## Duration

The simulated run is ~0.1–0.2 s slower per action. Per-phase medians in the blank-area test:

| Phase | Real | Simulated |
|---|---|---|
| Wait for app to idle (before an action) | 3–4 ms | 46–82 ms |
| Synthesize Escape key | 17 ms | 62 ms |
| Synthesize right click (0.4 s of events) | 479 ms | 494 ms |
| Activate after launch | 6 ms | 139 ms |

Cause: each record goes runner → testmanagerd → AX → app and back, and the runner polls the agent until
the last event is posted; the app then still processes the posted events, which XCTest's next idle
wait absorbs. Hypothesis tested and **refuted**: the agent's 50 ms window-sweep timer delaying idle
detection — replacing it with a per-record sweep left durations unchanged (40.20 / 80.58 / 15.14 s);
the change was reverted to keep the validated agent. Not a behavioral difference; reducing round
trips is an optimization for later.

## Verdict

For these three Zforge tests on the same build, the simulated mode is **equivalent to the real mode**:
same outcomes, same XCTest action sequences, the injected regression fails on the same assertion
with the same message, and the screen is untouched only in the simulated mode. Caveats: one real and
one simulated run per case (plus earlier simulated repeats, all passing); one regression compared;
simulated runs are ~10 % slower; the menu bar and tracking areas remain emulations validated only
for the interactions exercised here and in `Notes/real-vs-simulated-2026-10-31.md`.

## Coverage of the other Zforge UI tests (commit 7ea66ec, 26 tests)

Real-only (out of the app or through the window server), 9 tests:
- Finder: `testFinderSubmenuOffersArchiveActionsAndExtractsInZforge`, `testArchivePromisesPublishIntoFinderBeforeRemovingOriginal`.
- Drag and drop sessions (NSDraggingSession through the window server): `testArchiveDragCopiesIntoSidebarFolder`,
  `testArchiveCopyIntoAnotherZforgeWindow`, `testLocalDragsOptionCopyAndConfirmAdditionToArchive`,
  `testArchiveInternalCopyConfirmationKeepsHistoryAndAncestorColumns`.
- Out-of-process open panels (sandbox): `testCustomCompressionPanelOpensFolderChooser`,
  `testSettingsProvidesLocalizedAgentSetupAndNativeCancellation`, `testMCPContextualPermissionCancellationAndDisconnect`.

Simulable, 17 tests: the 3 validated here plus 14 with interaction kinds that have no equivalence
evidence yet (the brief counted 13; the difference is likely the language test or one of the in-app
drag tests being counted as real-only):

| Interaction kind without evidence | Tests |
|---|---|
| Arrow-key navigation, ⌘± zoom, toolbar search focus | `testListKeyboardZoomAndArrowNavigationAfterChangingView`, `testCommandFFocusesToolbarSearchAndEscapeCollapsesIt`, `testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode` |
| Menus opened from toolbar buttons / overflow | `testCompactToolbarMenusOpenFromTheirToolbarButtons` |
| Modifier-clicks for multi-selection, menu contents tracking selection | `testFileOpenPrecedesOpenWithAndTracksSelectionInListMode` |
| Several windows, closing the last one, restoration | `testViewModeIsPerWindowAndLastClosedWindowRestoresIt` |
| Sheets and popovers with text entry | `testTagEditorIsSharedByToolbarAndContextMenu` |
| Menu alternates while Option changes during menu tracking; inline rename editor; double click | `testFolderSelectionMenuAlternatesWithOptionInListMode`, `testNewFolderWithSelectionMenuAndShortcutInListMode` |
| Pop-up button menus; relaunch persistence | `testLanguageSelectionUpdatesOpenMenuAndPersists` |
| Scroll (horizontal and vertical) | `testColumnPreviewRefitsAfterUserScrollsLeft` (also used inside the Settings drag tests) |
| In-app mouse drags (no drag session): SwiftUI `DragGesture`, `NSSlider`, `NSTableHeaderView` resize/reorder | `testListColumnsReorderByDragging`, `testArchiveSizeLimitSliderHoldsRoundValuesWhileDragging`, `testListHeaderDividerResizesAndHeaderBodyReorders` |

Suggested order (lowest risk and most reuse first; each step = simulated run, then real vs simulated on
the same build plus one regression):
1. Keyboard navigation, zoom and toolbar search (3 tests) — uses already-proven key delivery.
2. Toolbar menus and modifier-click multi-selection (2 tests) — pop-up menus from buttons, flags on clicks.
3. Window lifecycle (1 test) — key/main window choice under the agent's sticky activation.
4. Sheets/popovers with typing (1 test).
5. Option alternates during menu tracking, inline editor (2 tests) — flags-changed events inside a
   menu tracking loop; highest risk among the menu cases.
6. Pop-up button menus and relaunch (1 test).
7. Scroll (1 test) — the scroll implementation is basic and unvalidated; needed before step 8.
8. In-app drags (3 tests) — dragged-event timing and cursor rects (not emulated).
