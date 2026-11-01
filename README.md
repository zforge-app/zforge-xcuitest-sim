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

`prepare-xctestrun.py` modifies the built app in place (adds a weak load command for the agent and re-signs it); use it on a test build copy only. It refuses copies outside `$XCUISIM_WORK`.

### Copies and the system

Every build and copy the tool makes lives in `$XCUISIM_WORK` and is kept from leaking into the rest of the system (`Scripts/copy_hygiene.py`, `Notes/copy-hygiene-2026-11-01.md`):

- **No app extensions.** Copies keep the original bundle identifiers of their extensions, and the system can load a copy's extension instead of the developer's (a Finder Sync extension did). `prepare-xctestrun.py` and `Scripts/build-for-testing.sh` (use it for every `-derivedDataPath` build in the work directory) remove `Contents/PlugIns` and `Contents/Extensions` from the apps (test bundles stay) and loose extension products, re-sign, and prune the xctestruns. Tests that need an extension run in the real group, from the developer's own build.
- **Registration.** `run-offscreen.sh` and `run-lanes.py` remove leftover Launch Services and pluginkit registrations of the copy before a run and unregister it after the run, also after an abort. macOS services (Spotlight, Finder, HIServices) re-register app bundles they already know within seconds to minutes; such a record has no extension, so it cannot take the place of the real one.
- **Processes.** A run does not start while a process of the copy is alive; at the end (also on abort) leftover processes of the copy, such as the app XCUITest leaves running after the last test, are terminated and reported.
- `copy_hygiene.py check|cleanup|strip [--thorough] <dir>` inspects or cleans any directory of the work directory; tests: `python3 -m unittest discover -s Tests -v` (the last test checks the whole work directory).

Parallel lanes (prototype, see `Notes/zforge-parallel-lanes-2026-10-31.md`):

```sh
# one isolated copy per lane: distinct app and runner bundle IDs, optional app group rename
Scripts/make-lane.py <products dir> <lane dir> --suffix lane2 --identity "Apple Development" \
    [--app-group-suffix] [--plist-suffix-key <Info.plist key naming the app group>]
# run lanes together under one ScreenGuard, sampling CPU and memory
Scripts/run-lanes.py --name <run> --results <dir> --watch <app> --watch <runner> \
    --lane <lane1 offscreen.xctestrun> <test id>,<test id> --lane <lane2 offscreen.xctestrun> <test id>
```

## Planned parts

- **Runner shim:** loaded into the UI test runner; replaces `_XCT_synthesizeEvent:` (and, where needed, launch/terminate) with delivery over a private channel.
- **App agent:** a library linked only into a test build configuration of the app; turns the requests into `NSEvent`s, keeps windows offscreen and makes the app behave as active.
- **CLI:** builds per-lane app copies with distinct bundle IDs, runs `xcodebuild test-without-building` lanes in parallel, keeps real-only tests in a real lane and merges `.xcresult` bundles.
- **Sample app:** a small AppKit/SwiftUI app with its own UI tests that proves delivery of clicks, keyboard, menus and focus on each Xcode version.

## Known limits

Anything that leaves the app process cannot be simulated and stays in the real lane: Finder and other system apps, drag and drop through the window server, out-of-process open/save panels, permission dialogs. The interception relies on private Xcode protocols and can break with any Xcode release.

It is generic for macOS apps built on AppKit (including SwiftUI). Zforge is the first consumer.
