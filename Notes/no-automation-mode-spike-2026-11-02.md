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
