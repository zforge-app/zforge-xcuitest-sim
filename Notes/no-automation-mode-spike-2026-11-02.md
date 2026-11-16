# Running without Automation Mode — spike, 2026-11-02

Environment: Xcode 27.1 (27A9275), macOS 27.0.1 (26A434), arm64.

Goal: offscreen runs that never turn on macOS Automation Mode (its "Automation Running" indicator and
its authentication prompt, which takes focus for ~3 s after a while without UI tests).

## How Automation Mode is turned on

testmanagerd keeps a client count: `Test session with pid … requesting automation mode` → `Enabling
Automation Mode...`; when the last client leaves, `Disabling Automation Mode...`. A session becomes a
client in two ways (unified log, `process == "testmanagerd"`):

1. the runner sends `_XCT_enableAutomationModeWithReply:` right after the capability exchange;
2. testmanagerd requests it itself (`Automation Mode not yet enabled, requesting...`) when the session
   needs accessibility for the app under test: after `loadAccessibility`, when the runner asks for
   the in-app automation session (`Replying with unsupported bundle identifiers`, `requested endpoint
   for process … preferredBackendPath …/XCTAutomationSupport.framework`).

Without Automation Mode, UI-automation messages fail with `Error 41: Not authorized for performing UI
testing actions`. This includes `_XCT_fetchAttributes:forElement:reply:`, which the tool's own
runner→agent channel uses today.

## Inventory: what still reaches testmanagerd (offscreen run, 2 Zforge tests)

The shim's daemon proxy now logs each forwarded message (`daemon message <selector> #n`):

| Message | Count (2 tests) | Use |
|---|---|---|
| `_XCT_requestSerializedTransportWrapperForIDESessionWithIdentifier:reply:` | 1 | IDE transport; no Automation Mode needed |
| `_XCT_enableAutomationModeWithReply:` | 1 | turns Automation Mode on |
| `_XCT_loadAccessibilityWithTimeout:reply:` | 1 | accessibility setup |
| `_XCT_registerForAXNotificationsForApplicationWithPID:timeout:completion:` / `_XCT_unregister…` | ≥3 | AX notifications (menu-open waits depend on them) |
| `_XCT_startMonitoringApplicationWithBundleID:path:` | ≥3 | pid/state callbacks (`_XCT_applicationWithBundleID:didUpdatePID:andState:`) |
| `_XCT_bundleIdentifierForApplicationAtURL:completion:` | ≥3 | Launch Services lookup |
| `_XCT_requestProcessSpecifierForPID:reply:` | ≥3 | process description |
| `_XCT_fetchSnapshotForElement:attributes:parameters:reply:` | 12 hierarchy captures | element tree (queries) |
| `_XCT_fetchAttributes:forElement:reply:` | 573 (incl. the tool's channel) | attributes; the tool's channel |
| `_XCT_performWhenMenuOpens:block:` | ≥2 | waits for a menu-open AX notification |
| `_XCT_requestScreenshotAttachment:withReply:` | 52 | automatic screenshots — **of the real screen** (`Asking Skylight to take screenshot`) |
| `_XCT_syncCrashReporterWithReply:` | 2 | crash reports |
| `requestUnsupportedBundleIdentifiersForAutomationSessions:` / `requestAutomationSessionForTestTargetWithPID:…` | 2 | in-app automation session; not through `daemonProxy` (own methods of `XCTRunnerDaemonSession`) |

Signatures (extended type encodings) were dumped with `_protocol_getMethodTypeEncoding`; e.g.
`_XCT_fetchSnapshotForElement:attributes:parameters:reply:` replies `(XCUIElementSnapshotRequestResult *, NSError *)`.

## Experiment v0 (`--env XCUISIM_NO_AUTOMATION_MODE=1`)

The shim answered `enableAutomationMode`, `loadAccessibility`, AX-notification (un)registration and
`syncCrashReporter` locally. Result (`noam-1`, `testKeyboardShortcutHelpOpensAndFilters`): Automation
Mode was still enabled (testmanagerd requested it when the in-app automation session was set up), and
the test failed with "timed out while waiting for menu open notification" (AX notifications were no
longer registered). Expected: v0 only maps the dependencies. With the switch off (default), the same
tests pass unchanged (`default-check`, 2/2).

## Feasibility of the replacement: the in-app engine works without trust or testmanagerd

XCTAutomationSupport (also at `/System/Library/PrivateFrameworks/XCTAutomationSupport.framework`)
contains the engine testmanagerd and the in-app session use: `XCTAccessibilityFramework`
(`-initForLocalAccess`) and `XCTAutomationSession` (`-initWithAccessibilityFramework:`,
`-snapshotForElement:attributes:parameters:timeoutControls:error:`, `-attributesForElement:attributes:error:`,
`-_XCT_fetchMatchesForQuery:`, `-notifyWhenMainRunLoopIsIdle:`, `-notifyWhenAnimationsAreIdle:`).

Probe (`Notes/probes/localsnap.m`, built into an ad-hoc signed `.app` with `LSUIElement`): an `.app` opened through Launch Services (`AXIsProcessTrusted() == 0`,
no testmanagerd, Automation Mode off) built a local session and captured its own tree:
`XCElementSnapshot` application → window "Probe window" → button `probe-button` "Press me", text field
`probe-field`, static text, with frames. So the element tree, attributes and idle notifications can
come from inside the app, from Apple's own code.

## Plan

1. **Direct channel** runner ↔ agent, not through testmanagerd: the agent opens a `CFMessagePort`
   named `<app group>.xcuisim` (sandboxed apps may use names prefixed with their app group); the lane
   preparation adds that name to the runner copy's `temporary-exception.mach-lookup.global-name`
   (the runner already has such exceptions). Payloads are `NSKeyedArchiver` data of the XCTest types
   (they are secure-coded, since they cross XPC today). The current commands (deliver, status, hit,
   shot, activate) move to it.
2. **Agent engine:** a local `XCTAutomationSession`; answers snapshots, attributes, accessibility
   actions, idle waits, menu-open waits (`NSMenuDidBeginTrackingNotification`) and AX notifications.
3. **Shim:** with the switch on, answer every UI-automation message from the inventory through the
   channel or locally (Launch Services and pid/state monitoring through `NSWorkspace`, termination
   through `NSRunningApplication`); report the app as unsupported for in-app automation sessions so
   XCTest uses the snapshot path; render automatic screenshots from the app (no real-screen capture).
4. **Validation:** a dual mode that fetches each snapshot both ways (testmanagerd and agent) and diffs
   them on the 16 simulable Zforge tests; then activity trees against the real references, injected
   regressions, and Automation Mode checked off (`automationmodetool`, testmanagerd log) during a run.

Risks: more private interfaces (XCTAutomationSupport classes and `XCTRunnerDaemonSession` methods); snapshot
fidelity of local versus remote accessibility (the dual mode measures it); timing of idle waits.

## Phase 2 — implemented (2026-11-02)

Opt-in per run: `run-lanes.py --env XCUISIM_NO_AUTOMATION_MODE=1` (Zforge's `affected-tests.py` passes it
by default). Without the switch nothing changes.

- **Direct port.** `make-lane.py` names a port `<app group>.xcuisim.<lane>` (bundle identifier when the app
  has no group), adds it to the runner copy's `temporary-exception.mach-lookup.global-name`, **adds the
  runner copy to the app's group** (launchd answered `CFMessagePortCreateRemote` with nothing until the
  runner was a member; no sandbox denial was logged), and passes `XCUISIM_PORT` / `XCUISIM_APP_PORT`. The
  agent opens a `CFMessagePort` on a background queue; requests and replies are keyed archives.
- **Engine.** The agent hosts XCTest's own engine (`XCTAutomationSession` over `XCTAccessibilityFramework
  initForLocalAccess`). With local access every call **must run on the main thread**
  (`XCTAccessibilityFrameworkAssertThreadRequirement`: when `allowsRemoteAccess` is NO it asserts
  `isMainThread`); a call from the port queue aborted the app twice (crash dialogs at 08:39 and 08:42).
  Calls now go through `dispatch_sync(main)` (the main queue drains in menu tracking too), and every
  request is wrapped in `@try`, so an exception becomes an error reply instead of an abort.
- **Shim, with the switch on:** `enableAutomationMode` / `enableAutomationModeWithError:`,
  `loadAccessibility`, AX-notification (un)registration and `syncCrashReporter` answered locally;
  `fetchSnapshotForElement` and `fetchAttributes` from the engine; `performWhenMenuOpens` from the agent's
  `NSMenuDidBeginTrackingNotification` count or an open menu (XCTest arms the wait and sends the opening
  click right after, so the menu may already be open when the baseline is read);
  `notifyWhenEventLoopIsIdle` from the engine's run-loop and animation idle notifications; the agent
  commands (deliver, status, hit, shot, activate) through the port; in-app automation sessions declined
  (`requestUnsupportedBundleIdentifiersForAutomationSessions:` lists the simulated apps,
  `requestAutomationSessionForTestTargetWithPID:…` replies with an error), so XCTest uses the snapshot
  path. testmanagerd still carries the IDE transport and Launch Services monitoring (pid/state), which work
  without Automation Mode. `SystemAttachmentLifetime` is `keepNever`: XCTest's automatic screenshots were
  taken from the real screen.
- **Hit testing.** XCTest compares the element at the hit point with the tree's element
  (`-[XCAccessibilityElement isEqual:]`: pid, three identity fields, token). SwiftUI's `HostingScrollView`
  answers `accessibilityHitTest:` with itself (also when asked again), so the hit landed on an ancestor:
  8 of 16 tests failed `Not hittable`. The agent now takes the engine's tree below the AppKit result and
  descends to the smallest element whose frame contains the point; elements built from the AppKit object
  that accessibility exposes (e.g. `NSButtonCell`) have the same token as the tree's (probe
  `Notes/probes/hitprobe.m`).
  Update 2026-11-10: port hit tests now run with the requesting client identified, as inside a real
  accessibility request; SwiftUI hit tests differently outside one (`Notes/swiftui-switch-hit-test-2026-11-10.md`).

### Evidence (Zforge)

| Run | Build | Result | Automation Mode (1 s samples) |
|---|---|---|---|
| `noam-16b` | `zforge-888896d` | 15/16; the failure is the Columns File ▸ Open race below | 175 × disabled |
| `fo-noam`, `fo-default` | Zforge worktree with the test synchronized | 3/3 and 3/3 | `fo-noam` disabled |
| `noam-16c` | same worktree | **16/16**, guard clean (0 front changes, 0 windows, 0 synthetic events), 170 s in 3 lanes | **174 × disabled** |
| `noam-drop` (negative control, `XCUISIM_APP_DROP_EVENTS=1`) | same | 2/2 failed as they must | — |

Activity trees of `noam-16b` against the real reference on the same build (`adopt-real-888896d`), ignoring
only the steps of XCTest's query path (`Setting up automation session`; `Requesting snapshot of
accessibility hierarchy…`, `Find: …`): **8 identical**; 5 differ only by `Terminate io.libor.Zforge` at
launch (lane versus serial order, accepted before) or real-only runtime warnings; one has an extra
`Wait for accessibility to load`; `testViewModeIsPerWindow…` logs one `Unable to monitor event loop` (an
idle wait without an answer; to watch); the Columns File ▸ Open test failed.

**The Columns File ▸ Open race.** Without the ~0.2 s that automatic screenshots added to each step (`keepNever`,
also in the default mode), `testFileOpenNavigatesSelectedFolderAndArchiveInColumnsMode` failed 3/3: its
Left Arrow (meant to close the Open with submenu) moves to the app menu, as in the real run (where the Open
item was `Not hittable` and XCTest's retry recovered it), and the next File ▸ Open click raced XCTest's
menu traversal. Zforge's test now closes the menu with Escape and waits until no menu bar item is selected,
as its List-mode sibling does; then 3/3 in each mode. `keepNever` stays limited to runs without Automation Mode.

### Still open

- The real-only tests (Finder, window-server drag and drop, out-of-process panels) still need Automation Mode.
- `Unable to monitor event loop` once in 16 tests: see whether the idle request timed out or the app was quitting.
- A test's failure screenshots now come only from the test's own `screenshot()` calls (automatic ones are off).
