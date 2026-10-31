# zforge-xcuitest-sim

Runs existing macOS XCUITest suites without taking over the user's screen, and in parallel.

XCUITest normally asks `testmanagerd` to synthesize real HID events through the window server, which moves the cursor, activates the app and steals focus. This tool intercepts that private event-synthesis path in the test runner and delivers the events inside the app under test (offscreen windows, simulated activation). Element queries keep using the real accessibility tree, so existing tests run unchanged.

Status: feasibility spike. See `Notes/feasibility-2026-10-29.md` for what was proven and what was not.

## Layout

- `Sources/RunnerShim/` — runner shim (`libXCUISimRunnerShim.dylib`).
- `Sources/AppAgent/` — app agent (`libXCUISimAgent.dylib`).
- `Tools/ScreenGuard/` — records frontmost-app changes, cursor movement, visible windows and synthetic events during a run (evidence that the screen was not touched).
- `Sample/` — sample AppKit/SwiftUI app with unchanged XCUITests and compile-time regressions for negative controls.
- `Scripts/` — build, prepare and run scripts.
- `Notes/` — reverse-engineered interface notes per Xcode version and spike findings.

Work products go to `$XCUISIM_WORK` (default `~/Library/Caches/dev.xcuitestsim`). Never build or load test products from `~/Documents`, `~/Desktop` or `~/Downloads`: the runner reading them makes macOS show a permission prompt.

## Spike usage

```sh
XCUISIM_SIGN_IDENTITY="Apple Development" Scripts/build-tools.sh
XCUISIM_TEAM=<team> Scripts/build-sample.sh                         # prints the xctestrun path
Scripts/prepare-xctestrun.py <xctestrun> --identity "Apple Development"   # writes <name>-offscreen.xctestrun
Scripts/run-offscreen.sh <name> <offscreen.xctestrun> <app>,<runner> [-only-testing:...]
```

`prepare-xctestrun.py` modifies the built app in place (adds a weak load command for the agent and re-signs it); use it on a test build copy only.

## Planned parts

- **Runner shim:** loaded into the UI test runner; replaces `_XCT_synthesizeEvent:` (and, where needed, launch/terminate) with delivery over a private channel.
- **App agent:** a library linked only into a test build configuration of the app; turns the requests into `NSEvent`s, keeps windows offscreen and makes the app behave as active.
- **CLI:** builds per-lane app copies with distinct bundle IDs, runs `xcodebuild test-without-building` lanes in parallel, keeps real-only tests in a real lane and merges `.xcresult` bundles.
- **Sample app:** a small AppKit/SwiftUI app with its own UI tests that proves delivery of clicks, keyboard, menus and focus on each Xcode version.

## Known limits

Anything that leaves the app process cannot be simulated and stays in the real lane: Finder and other system apps, drag and drop through the window server, out-of-process open/save panels, permission dialogs. The interception relies on private Xcode protocols and can break with any Xcode release.

It is generic for macOS apps built on AppKit (including SwiftUI). Zforge is the first consumer.
