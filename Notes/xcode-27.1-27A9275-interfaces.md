# Private interfaces — Xcode 27.1 (27A9275), macOS 27.0.1 (26A434)

Recorded 2026-10-28/29 with `xcodebuild -version` = Xcode 27.1, Build version 27A9275, on arm64.
Sources: runtime dumps (`objc_copyClassNamesForImage`, `_protocol_getMethodTypeEncoding`),
`objdump --macho -d` of `XCUIAutomation.framework` (local symbols are present), and runtime probes.
Everything here can change with any Xcode release; re-verify per version.

## Frameworks

`$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/`
- `Frameworks/XCUIAutomation.framework` — XCUIApplication, XCUIElement, event records, and the
  `XCTRunnerDaemonSession` categories that talk to testmanagerd.
- `PrivateFrameworks/XCTestCore.framework` — `XCTRunnerDaemonSession` (the runner's XPC session
  with `com.apple.testmanagerd`).
- `PrivateFrameworks/XCTAutomationSupport.framework` — `XCAccessibilityElement`,
  `XCTApplicationStateSnapshot`, `XCTAutomationSession`.

## Which session is used on a local Mac

`XCUIDeviceRemoteAutomationSession` exists but is the remote-device path. A local macOS run uses
`XCTRunnerDaemonSession` (XCTestCore) through categories defined in XCUIAutomation:
`XCTRunnerDaemonSessionUIAutomationDelegate`, `XCUIPlatformApplicationServicesProviding`,
`XCUIRemoteAccessibilityInterface_macOS`, ... Each category method calls `-[self daemonProxy]`
(an `NSXPCConnection` remote proxy) and sends one `_XCT_*` message. **`-daemonProxy` is called for
every message**, so wrapping its return value is a single interception point.

## Runner → testmanagerd messages (extended type encodings)

| Selector | Reply | Shim |
|---|---|---|
| `_XCT_synthesizeEvent:(XCSynthesizedEventRecord*) implicitConfirmationInterval:(double) completion:` | `^(NSError*)` | delivered to the app agent |
| `_XCT_launchApplicationWithBundleID:path:arguments:environment:completion:` | `^(NSError*)` | NSWorkspace launch, `activates = NO` (only used without an IDE) |
| `_XCT_launchApplicationWithBundleID:arguments:environment:completion:` | `^(NSError*)` | same |
| `_XCT_setFrontProcess:(NSNumber*) completion:` | `^(NSError*)` | activation stays in-process |
| `_XCT_requestCurrentKeyboardModifierFlagsWithReply:` | `^(NSUInteger, NSError*)` | simulated flags (XCUIKeyModifierFlags) |
| `_XCT_requestElementsPotentiallyInterruptingElement:targetFrame:applicationIsForeground:reply:` | `^(NSArray*, NSError*)` | empty: other processes cannot cover the simulated app |
| `_XCT_requestElementAtPoint:(CGPoint) reply:` | `^(XCAccessibilityElement*, NSError*)` | hit test inside the app |
| `_XCT_fetchAttributes:(NSArray*) forElement:(XCAccessibilityElement*) reply:` | `^(NSDictionary*, NSError*)` | used as the channel (below) |
| `_XCT_requestScreenshot:withReply:` / `_XCT_startScreenRecordingWithRequest:` | | **not intercepted yet** — capture the real screen |

The launch reply carries no pid. The pid and state arrive later from testmanagerd's LaunchServices
monitoring through `-[XCTRunnerDaemonSession _XCT_applicationWithBundleID:didUpdatePID:andState:]`
and `-[XCTRunnerDaemonSession _XCT_applicationDidUpdateState:(XCTApplicationStateSnapshot*)]`.
Run states: 1 not running, 2 background suspended, 3 background, 4 foreground.
`XCTApplicationStateSnapshot` is immutable; create a copy with
`-initWithBundleID:path:runState:processID:activationPolicy:eventID:processName:`.

## Launch paths in the runner

`XCUIApplicationImpl` launches either through the IDE (`_launchUsingXcodeWithArguments:environment:launchURL:`,
which sends `_XCT_launchProcessWithPath:bundleID:arguments:environmentVariables:` to xcodebuild) or
through the platform (`_launchUsingPlatformWithArguments:environment:launchURL:` → testmanagerd).
**Under xcodebuild the IDE path is used**; it launches the app without activating it. Activation
is a separate `setFrontProcess` call, made on launch and before interactions. Runner-side
LaunchServices activation also exists (`-[XCUILaunchServicesMonitor setFrontProcess:completion:]`,
`-[XCUILaunchServicesFramework setFrontProcess:error:]`); the shim refuses it (never seen called).

## Event record format

`XCSynthesizedEventRecord` (`name`, `eventPaths`, `targetProcessID` — 0 in practice) →
`XCPointerEventPath` (`pathType`: 0 mouse, 3 text input) → `XCPointerEvent`.
Coordinates are global display points, top-left origin. `offset` is seconds from the record start.

`eventType` values (probed with the class constructors):

| value | meaning | fields |
|---|---|---|
| 0 | settle at point (follows a timed move) | coordinate |
| 1 | button down | coordinate, buttonType, clickCount |
| 2 | move (with `duration`: from coordinate to destination) | coordinate, destination, duration |
| 3 | button up | coordinate, buttonType, clickCount |
| 4 | drag | coordinate, destination, duration |
| 5 | scroll by delta | deltaVector, duration |
| 6 | gesture swipe | deltaVector, duration, gesturePhase |
| 7 | scroll by lines | coordinate, verticalLineScroll |
| 8 | set modifiers | keyModifierFlags, mergeModifierFlagsWithCurrentFlags |
| 9 | type key | key (XCUIKeyboardKey string), keyModifierFlags |
| 10 | type text | string, typingSpeed |
| 11 | key code | keyCode, keyPhase, keyModifierFlags |

`buttonType`: 1 left, 2 right (3 presumably other). Flags are `XCUIKeyModifierFlags`
(capsLock 1<<0, shift 1<<1, control 1<<2, option 1<<3, command 1<<4, function 1<<5), not
NSEventModifierFlags. A click is: timed move from the *real* cursor position, settle, down at +0.25 s,
up at +0.4 s. `XCUIElement.perform(withKeyModifiers:)` sends separate "Set key modifiers" records
around the click.

`XCUIKeyboardKey` constants are the AppKit function-key characters: Delete U+007F, Return U+000D,
Enter U+0003, Tab U+0009, Escape U+001B, arrows U+F700–F703, F1–F12 U+F704–F70F, Home U+F729,
End U+F72B, PageUp U+F72C, PageDown U+F72D, ForwardDelete U+F728, Help U+F746, Clear U+F739.

## Channel to the app agent

Both the runner (`SampleAppUITests-Runner.app`, not hardened) and the app are sandboxed. The runner's
Xcode-generated entitlements include read access to `/`, mach-lookup of testmanagerd and
`(allow hid-control)`; it is *not* AX-trusted (testmanagerd is). Channel used: an accessibility
attribute of the application element whose name carries the command
(`XCUISim:deliver:<id>:<base64 json>`, `XCUISim:status:<id>`, `XCUISim:hit:<x>:<y>`, `XCUISim:activate`),
sent with `_XCT_fetchAttributes:forElement:reply:` and `+[XCAccessibilityElement elementWithProcessIdentifier:]`.
testmanagerd passes unknown attribute names through; the app answers in a swizzled
`-[NSApplication accessibilityAttributeValue:]`. Returned NSAccessibility objects are converted by
AppKit/testmanagerd into `XCAccessibilityElement`s (used for hit testing). AX requests are serviced
on the app's main thread in every run loop mode, including menu tracking.

## Injection

- Runner: `DYLD_INSERT_LIBRARIES` in the xctestrun `TestingEnvironmentVariables` works (Xcode already
  inserts `libMainThreadChecker.dylib` there).
- App: **LaunchServices launches ignore `DYLD_INSERT_LIBRARIES`** even with
  `com.apple.security.cs.allow-dyld-environment-variables` and `get-task-allow` (dyld prints the
  environment but loads nothing extra; a direct `exec` honors it). The spike adds an
  `LC_LOAD_WEAK_DYLIB @loader_path/libXCUISimAgent.dylib` to Xcode's `<App>.debug.dylib` (the stub
  main executable has only ~24 bytes of header padding) and re-signs with the same team identity,
  so library validation under the hardened runtime passes without new entitlements.

## AppKit behavior relied on by the agent (macOS 27.0.1)

- `NSApp.isActive` set by a synthetic `NSEventSubtypeApplicationActivated` event does not stick:
  AppKit re-derives it from the system's frontmost application. The agent swizzles `-isActive`.
- Key events built with `+keyEventWithType:...` do not match menu key equivalents with Shift
  (`charactersIgnoringModifiers` "K" vs item "k"); events converted from a `CGEventCreateKeyboardEvent`
  do. Posted events from `-[NSApplication postEvent:atStart:]` reach nested menu tracking loops.
- Context menus are `NSPopupMenuWindow` instances: not in `NSApp.windows`, not ordered through
  `-orderWindow:relativeTo:`; they do pass through `-initWithContentRect:styleMask:backing:defer:`.
- Menu bar items of an app that does not own the system menu bar report position (0, top) and size
  (-1, 0); their AX elements are the `NSMenuItem`s themselves.
- XCUITest's menu traversal (`_performMenuTraversalPath:`) reads the menu bar item's `AXSelected` to
  decide whether to click the title before reaching an item (real menu bar: 1 while open). Verified by
  comparing activity trees of a real and a simulated run (2026-10-31).
- `NSView.visibleRect` extends past the bounds when superviews do not clip (macOS 14+ default).
- Tracking areas are delivered by the window server; posted mouse-moved events do not produce
  `mouseEntered:`/`mouseExited:`. Views often recreate their areas in `-updateTrackingAreas`.
- Cross-process menu dismissal (macOS 27.0.1, 2026-10-31): when a process starts menu tracking,
  `-[NSMenuTrackingSession sendBeginTrackingNotifications]` posts
  `com.apple.HIToolbox.beginMenuTrackingNotification` (`CFNotificationCenterPostNotification`, a C call),
  and other apps receive a window-server event whose description reads `type=ProcessNotification`,
  `subtype=16384` (0x4000); AppKit dismisses an open menu on it. The event type is not a public
  `NSEventType` and `-subtype` must not be read on key events (raises). The agent drops these events;
  outgoing notifications from the simulated app are still posted.
- A locked console session (`IOConsoleUsers` → `CGSSessionScreenIsLocked`) leaves the app under test
  with an empty, disabled accessibility application element, in the simulated mode too.

## Keyboard focus (added 2026-11-02)

AppKit imports `CPSStealKeyFocusReturningID`, `CPSReleaseKeyFocusWithID`, `CPSGetKeyFocusProcess`; HIToolbox
also `CPSStealKeyFocus`, `CPSReleaseKeyFocus` (CoreGraphics, re-exported from SkyLight `SLPS*`).
`SLPSStealKeyFocusReturningID(int connection, uint32_t options, uint32_t *outID)` sends RPC
`StealKeyFocusReturningID` and writes the ID on success; `SLPSReleaseKeyFocusWithID(uint32_t id)`.
The caller becomes the window server's key thief (keyboard routed to it while another app is
frontmost). The agent interposes all four; see `Notes/keyboard-focus-2026-11-02.md`.
