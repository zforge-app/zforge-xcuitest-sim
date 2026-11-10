# SwiftUI `.switch` toggles were not hittable without Automation Mode, 2026-11-10

Environment: `xcodebuild -version` = Xcode 27.2, Build version 27B52; macOS 27.2 (26B123), arm64.

## Symptom

Zforge `IconPreviewUITests.testSettingsToggleUpdatesTheOpenGridAndKeepsSelection` failed offscreen (no
Automation Mode) with `Not hittable: CheckBox … identifier: 'settings-show-icon-previews'` on all three
attempts; it passes in a real run. The control is a small SwiftUI `Toggle` with `.toggleStyle(.switch)` and
`.labelsHidden()`. The sample app reproduces it with the same kind of toggle (`CompactSwitchRow`,
`testCompactSwitchToggles`): `isHittable` was false.

The accessibility tree has the toggle as SwiftUI's `CheckBox` node (`AccessibilityNode`, 44×20, carries the
identifier, no children). The agent's hit test answered an element of type Switch, 46×22, whose token is not
in the tree: the AppKit `NSSwitch` that SwiftUI hosts (`SwiftUI.PlatformSwitch`, superview
`AppKitPlatformViewHost`, accessibility parent the hosting view).

## How the accessibility server answers

The agent's `hit:` command (`-[NSWindow accessibilityHitTest:]` at the point) returned the right element
through the attribute channel and the wrong one through the direct port, on the same app and point
(probe: an external process reading `XCUISim:hit:x:y` with `AXUIElementCopyAttributeValue`, and the same
command sent to the port). lldb on the probe app:

- AppKit serves attribute values through `CopyAttributeValue` → `ConvertOutgoingValueForAttribute` →
  `ConvertOutgoingValueForElement` → `NSAccessibilityCreateAXUIElementRef(value)`: the object is passed
  unchanged, the conversion is the same as the agent's.
- The difference is the object. `-[NSWindow(NSWindowAccessibility) accessibilityHitTest:]` finds a view with
  `-[NSWindow hitTestForContext:]` (`+[NSHitTestContext contextWithPoint:radius:]`), lets its superview adjust
  it (`_accessibilityParentAdjustedHitTestElement:atLocation:`) and sends it `accessibilityHitTest:`. Inside
  the attribute request, `hitTestForContext:` returned the **hosting view**, whose `accessibilityHitTest:`
  answered the `CheckBox` node. From the port, it returned the **`PlatformSwitch`**, whose
  `-[NSControl accessibilityHitTest:]` answered itself.
- `SwiftUI.NSHostingView.hitTest(_:)` branches on SwiftUI's `AXIsClientMakingRequest()`: during an
  accessibility client's request it returns the hosting view itself; otherwise it hit tests for events
  (`NSPlatformHitTestingStack`, `managedHitTest`, `NSViewResponder.platformViewHitTest`,
  `AppKitPlatformViewHost.hitTest`) and returns the platform view.
- `AXIsClientMakingRequest()` is `_AXGetClientForCurrentRequestUntrusted() != 0` (HIServices). That returns an
  override when one is set, else the pid of the client whose request HIServices is serving (set around
  `mshMIGPerform`). `_AXSetClientIdentificationOverride(pid)` (HIServices, exported) sets the override;
  SwiftUI's own `AXOverrideIsClientMakingRequest` is a direct jump to it.

So the accessibility server answers `AXUIElementCopyElementAtPosition` while it serves the client's request,
SwiftUI sees a client, and the hit test lands on the SwiftUI node. The agent's port hit test ran on the main
queue outside any request, so SwiftUI hit tested for events. The default mode (testmanagerd) was not affected:
its `hit:` command arrives as an attribute request.

During a full tree read through the accessibility API and during an engine snapshot, `AXIsClientMakingRequest`
was not called at all (lldb breakpoint, sample app); only `NSHostingView.hitTest(_:)` called it. XCTest's
in-app engine (XCTAutomationSupport) does not import `_AXSetClientIdentificationOverride`.

## Fix

- Agent: `XAHitTestAsServer` runs the window's `accessibilityHitTest:` with the requesting client identified
  (`_AXSetClientIdentificationOverride(client)`, reset to 0 afterwards) when no request is in progress
  (`_AXGetClientForCurrentRequestUntrusted() == 0`). Inside a real request (attribute channel) it leaves the
  identification alone. Both functions are looked up with `dlsym`; if missing, the hit test runs as before
  and the agent logs it.
- Shim: port `commands` requests carry `client` (the runner's pid). An agent receiving a request without it
  identifies the app itself as the client; any non-zero client marks a request.
- In a real run the client is testmanagerd; here it is the runner, which made the request. Only "a client is
  making a request" was observed to matter (`_AXIsAppleClientForCurrentRequestUntrusted` was not called in
  this path).

## Evidence

| Run | Tool | Result |
|---|---|---|
| sample `sw-before-noam` (`testCompactSwitchToggles`, no Automation Mode) | `main` agent | failed, `isHittable` false (line 123) |
| sample `sw-after-noam` | fixed | passed; guard: 0 front changes, 0 windows, 0 synthetic, 0 hardware events |
| sample `sw-sample-all` (11 tests, no Automation Mode) | fixed | 11/11; guard clean |
| sample `sw-reg-switch` (`REGRESSION_SWITCH` build) | fixed | `testCompactSwitchToggles` failed at line 125 (click delivered, state unchanged), `testButtonClick` passed |
| Zforge `3693d00`, the D-85 test | `main` agent | failed, `Not hittable` ×3 (`IconPreviewUITests.swift:32`) |
| Zforge `3693d00`, the D-85 test | fixed | passed; guard clean |
| Zforge `3693d00`, offscreen UI-Full set (18 tests, 3 lanes) | fixed | 17/18; the failure is `testListColumnsReorderByDragging` (order `[modificationDate, kind, size]`), which fails the same way with the `main` agent |

The Zforge full-set guard recorded 2 front changes and pointer/hardware events: Safari and Mail, the user's
own activity during the run; 0 visible windows of the app, 0 synthetic events.

Not run: the sample suite in the default mode (Automation Mode) and a real-mode comparison; the real behavior
was established from the accessibility server's own code path (above), not from a real XCUITest run.

## The engine-tree descent (`XADeepestAtPoint`) stays

The port hit test still descends the engine's tree from the AppKit answer to the smallest child containing the
point; the accessibility server does not. It was added because `HostingScrollView` answered with itself
(`Notes/no-automation-mode-spike-2026-11-02.md`), probably the same missing request context. Experiment
with the descent disabled and the fix in place: sample 11/11, but Zforge 16/18:
`testCompactToolbarMenusOpenFromTheirToolbarButtons` also failed (`ZforgeUITests.swift:952`, state
`Collapsed` instead of `Expanded`, not a hittability failure). Removing the descent therefore changes
behavior and needs its own investigation; it is kept.
