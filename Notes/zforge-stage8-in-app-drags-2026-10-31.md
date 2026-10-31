# Zforge stage 8 — in-app drags (2026-10-31)

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64, single display. Zforge `7ea66ec`
(clean), same build as the earlier stages (`Zforge.debug.dylib` `da557f4a8d41b160`). Zforge repository
only read. Real runs announced before and after.

## Tests

| Test | Mechanism found | Classification |
|---|---|---|
| `SettingsUITests.testListColumnsReorderByDragging` | SwiftUI `DragGesture` (in-process mouse dragging) after scrolling the Settings window | simulable |
| `SettingsUITests.testArchiveSizeLimitSliderHoldsRoundValuesWhileDragging` | `NSSlider` knob drags of 2 and 8 pt | simulable; **fails in the real mode** |
| `ZforgeUITests.testListHeaderDividerResizesAndHeaderBodyReorders` | divider drags are in-process; the header-body reorder is a SwiftUI `draggable` → `NSCoreDragManager` → **Core Drag (window-server drag and drop)** | **real-only** (reclassified; the stage plan assumed an in-process drag) |

## Results

| Test | Real | Simulated | Assertion | Tree |
|---|---|---|---|---|
| testListColumnsReorderByDragging | pass 20.50 s | pass 27.65 s | — | identical (198) |
| testArchiveSizeLimitSliderHoldsRoundValuesWhileDragging | **fail** 15.05 s | **fail** 17.05 s | both `SettingsUITests.swift:100` "1.03 GB" ≠ "1.06 GB" and `:101` | 164 = 164; one check reordered in the failure capture |
| testListHeaderDividerResizesAndHeaderBodyReorders | not run (real-only) | fails `ZforgeUITests.swift:847` (reorder never happens), with an explicit "UNSUPPORTED: drag-and-drop session" agent log | — | — |

The slider test fails in the real mode on the unmodified build: a pre-existing failure at `7ea66ec`,
reported for separate handling (not investigated in Zforge).

| Regression | Real | Simulated |
|---|---|---|
| colreorder: dragging a column row does nothing, `583ac3acd1ca2ceb` | fail `SettingsUITests.swift:43` and `:60` (same values) | same; trees identical (222) |

## Tool change: window-server drag and drop is refused

In the first simulated run, the header-body drag started a Core Drag session: Core Drag created its
drag window (level 500, full screen, alpha 1) and it was **visible on the user's screen**, and the drag
could not complete (it tracks the hardware pointer). The agent now replaces
`-[NSCoreDragManager _dragUntilMouseUp:location:modifiers:]` with a refusal that logs
"UNSUPPORTED: a drag-and-drop session started …": no drag window is created and the test fails. Two
later simulated runs still showed the window because `prepare-xctestrun.py` had refused to update a
copy whose app was left running by an lldb session, and the run used the previous agent; the spike
helper now refuses to run a copy whose agent CDHash differs from the one just built.

## Revalidation (simulated, no screen)

Sample suite and regressions, the stage 4 and 7 sample tests and regressions, all 14 validated Zforge
tests (13 together plus the compact toolbar test alone): same outcomes; trees identical apart from
`Terminate` steps from run composition, one asynchronous runtime note and post-failure polling.

## Verdict

- `testListColumnsReorderByDragging`: **equivalent** (outcome, tree, regression). Simulated 35 % slower.
- `testArchiveSizeLimitSliderHoldsRoundValuesWhileDragging`: **fails identically** in both modes.
- `testListHeaderDividerResizesAndHeaderBodyReorders`: **real-only** (window-server drag and drop).
