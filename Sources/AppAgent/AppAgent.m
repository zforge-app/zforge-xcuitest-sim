// XCUISim app agent.
//
// Loaded into the application under test (DYLD_INSERT_LIBRARIES in the spike; linked into a
// dedicated test build configuration later). Active only when XCUISIM_ENABLED=1. It:
//   - answers the runner shim through a custom accessibility attribute of the application,
//   - turns XCTest event records into NSEvents posted to the app's own event queue,
//   - keeps every window invisible and click-through (alpha 0, ignores mouse events) while the
//     app keeps its real geometry, so accessibility frames and screen coordinates stay valid,
//   - makes the app behave as active in-process without asking the window server,
//   - simulates the global mouse location, pressed buttons, modifier flags and tracking areas.
//
// Environment (app):
//   XCUISIM_ENABLED     1 to enable the agent
//   XCUISIM_VISIBLE     1 to keep windows visible (debugging only; real cursor is still untouched)
//   XCUISIM_DROP_EVENTS 1 to acknowledge events without posting them (negative control)

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t XALog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.xcuitestsim", "agent"); });
    return log;
}
#define XAInfo(fmt, ...) os_log(XALog(), "%{public}@", [NSString stringWithFormat:fmt, ##__VA_ARGS__])

static BOOL gEnabled;
static BOOL gVisible;
static BOOL gDropEvents;
static NSPoint gMouse;                  // simulated cursor, Cocoa screen coordinates
static NSUInteger gButtons;             // simulated pressedMouseButtons
static NSEventModifierFlags gFlags;     // simulated modifier flags
static NSInteger gEventNumber = 100000;
static NSMutableDictionary<NSString *, NSString *> *gStatus;
static NSMutableSet<NSString *> *gInsideAreas; // view+owner keys of tracking areas the cursor is inside
static id gActivity;
static const short XAMarkerSubtype = 0x5853; // "XS"

static void XARunOnMain(double delay, dispatch_block_t block);

#pragma mark - Swizzling helpers

static IMP XASwizzle(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) { XAInfo(@"missing %@ %@", cls, NSStringFromSelector(selector)); return NULL; }
    // Add on the class itself first so inherited implementations are not replaced globally.
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) return method_getImplementation(method);
    return method_setImplementation(method, replacement);
}

static IMP XASwizzleClass(Class cls, SEL selector, IMP replacement) {
    return XASwizzle(object_getClass(cls), selector, replacement);
}

#pragma mark - Geometry

static CGFloat XAPrimaryHeight(void) {
    return NSScreen.screens.firstObject.frame.size.height;
}

// XCTest coordinates are global display coordinates with a top-left origin.
static NSPoint XACocoaPoint(double x, double y) { return NSMakePoint(x, XAPrimaryHeight() - y); }

static NSHashTable<NSWindow *> *gKnownWindows; // every NSWindow seen, including menus and panels

// The app's visible windows as if it were frontmost: by window level, then by the window
// server's front-to-back order among this app's windows.
static NSArray<NSWindow *> *XAWindowsFrontToBack(void) {
    NSArray<NSNumber *> *order = [NSWindow windowNumbersWithOptions:NSWindowNumberListAllApplications | NSWindowNumberListAllSpaces];
    NSMutableSet *candidates = [NSMutableSet setWithArray:NSApp.windows];
    for (NSWindow *window in gKnownWindows) [candidates addObject:window];
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *window in candidates) {
        // Touch Bar panels and similar windows live on virtual screens; they never take pointer events.
        if (!window.isVisible || window.windowNumber <= 0 || [window.className hasPrefix:@"_NSFunctionRow"]) continue;
        BOOL onScreen = NO;
        for (NSScreen *screen in NSScreen.screens) if (NSIntersectsRect(screen.frame, window.frame)) { onScreen = YES; break; }
        if (onScreen) [windows addObject:window];
    }
    [windows sortUsingComparator:^NSComparisonResult(NSWindow *a, NSWindow *b) {
        if (a.level != b.level) return a.level > b.level ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger ia = [order indexOfObject:@(a.windowNumber)], ib = [order indexOfObject:@(b.windowNumber)];
        return ia == ib ? NSOrderedSame : (ia < ib ? NSOrderedAscending : NSOrderedDescending);
    }];
    return windows;
}

static NSWindow *XAWindowAtPoint(NSPoint point) {
    for (NSWindow *window in XAWindowsFrontToBack()) {
        if (window.isVisible && NSPointInRect(point, window.frame)) return window;
    }
    return nil;
}

#pragma mark - Invisible, click-through windows

static const void *XAGhostKey = &XAGhostKey;
static const void *XAAlphaKey = &XAAlphaKey;
static const void *XAIgnoresKey = &XAIgnoresKey;
static IMP gSetAlpha, gAlpha, gSetIgnores, gIgnores, gOrderWindow;

static void XAGhost(NSWindow *window) {
    [gKnownWindows addObject:window];
    if (gVisible || objc_getAssociatedObject(window, XAGhostKey)) return;
    objc_setAssociatedObject(window, XAGhostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, CGFloat))gSetAlpha)(window, @selector(setAlphaValue:), 0);
    ((void (*)(id, SEL, BOOL))gSetIgnores)(window, @selector(setIgnoresMouseEvents:), YES);
    XAInfo(@"ghosted %@", window.className);
}

static void XASetAlpha(NSWindow *self, SEL _cmd, CGFloat value) {
    objc_setAssociatedObject(self, XAAlphaKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gVisible || !objc_getAssociatedObject(self, XAGhostKey)) ((void (*)(id, SEL, CGFloat))gSetAlpha)(self, _cmd, value);
}
static CGFloat XAAlpha(NSWindow *self, SEL _cmd) {
    NSNumber *value = objc_getAssociatedObject(self, XAAlphaKey);
    return value ? value.doubleValue : ((CGFloat (*)(id, SEL))gAlpha)(self, _cmd);
}
static void XASetIgnores(NSWindow *self, SEL _cmd, BOOL value) {
    objc_setAssociatedObject(self, XAIgnoresKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gVisible || !objc_getAssociatedObject(self, XAGhostKey)) ((void (*)(id, SEL, BOOL))gSetIgnores)(self, _cmd, value);
}
static BOOL XAIgnores(NSWindow *self, SEL _cmd) {
    NSNumber *value = objc_getAssociatedObject(self, XAIgnoresKey);
    return value ? value.boolValue : ((BOOL (*)(id, SEL))gIgnores)(self, _cmd);
}
static void XAOrderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode place, NSInteger other) {
    if (place != NSWindowOut) XAGhost(self);
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))gOrderWindow)(self, _cmd, place, other);
}

// Every NSWindow is made invisible as soon as it exists. Menus (NSPopupMenuWindow), tooltips and
// other system-owned windows are not in NSApp.windows and are ordered in through private paths.
static IMP gWindowInitGhost;
static id XAWindowInitGhost(NSWindow *self, SEL _cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer) {
    NSWindow *window = ((id (*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL))gWindowInitGhost)(self, _cmd, rect, style, backing, defer);
    if (window) XAGhost(window);
    return window;
}

// Safety net for windows ordered in through paths that bypass -orderWindow:relativeTo:.
static void XASweepWindows(void) {
    for (NSWindow *window in NSApp.windows) {
        if (window.isVisible && !objc_getAssociatedObject(window, XAGhostKey)) {
            XAInfo(@"sweep found an unghosted visible window %@", window.className);
            XAGhost(window);
        }
    }
}

#pragma mark - In-process activation

static IMP gActivateIgnoring, gActivate, gRunningActivate, gSendEvent;

static BOOL gSimulatedActivationSent;
static void XASimulateActivation(void) {
    if (gSimulatedActivationSent && NSApp.keyWindow) return;
    gSimulatedActivationSent = YES;
    NSEvent *activated = [NSEvent otherEventWithType:NSEventTypeAppKitDefined location:NSZeroPoint modifierFlags:0
                                           timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
                                             subtype:NSEventSubtypeApplicationActivated data1:0 data2:0];
    ((void (*)(id, SEL, NSEvent *))gSendEvent)(NSApp, @selector(sendEvent:), activated);
    if (!NSApp.keyWindow) {
        for (NSWindow *window in XAWindowsFrontToBack()) {
            if (window.isVisible && window.canBecomeKeyWindow) { [window makeKeyWindow]; break; }
        }
    }
    XAInfo(@"simulated activation: active=%d key=%@", NSApp.isActive, NSApp.keyWindow.title);
}

// AppKit re-derives the active state from the system's frontmost application, so the simulated
// state is made sticky; deactivation events from the window server are dropped.
static IMP gIsActive;
static BOOL XAIsActive(NSApplication *self, SEL _cmd) { return YES; }

static void XAActivateIgnoring(id self, SEL _cmd, BOOL flag) { XASimulateActivation(); }
static void XAActivate(id self, SEL _cmd) { XASimulateActivation(); }
static BOOL XARunningActivate(NSRunningApplication *self, SEL _cmd, NSApplicationActivationOptions options) {
    if (self.processIdentifier == getpid()) { XASimulateActivation(); return YES; }
    return ((BOOL (*)(id, SEL, NSApplicationActivationOptions))gRunningActivate)(self, _cmd, options);
}

#pragma mark - Simulated global input state

static IMP gMouseLocation, gPressedButtons, gModifierFlags, gOutsideLocation;
static NSPoint XAMouseLocation(id self, SEL _cmd) { return gMouse; }
static NSUInteger XAPressedButtons(id self, SEL _cmd) { return gButtons; }
static NSEventModifierFlags XAModifierFlags(id self, SEL _cmd) { return gFlags; }
static NSPoint XAOutsideLocation(NSWindow *self, SEL _cmd) { return [self convertPointFromScreen:gMouse]; }

#pragma mark - Tracking areas

static void XACollectTrackingAreas(NSView *view, NSMutableArray *areas) {
    for (NSTrackingArea *area in view.trackingAreas) [areas addObject:@[area, view]];
    for (NSView *subview in view.subviews) XACollectTrackingAreas(subview, areas);
}

static NSInteger gMenuTrackingDepth; // > 0 while any NSMenu is tracking (context, pop-up, menu bar)

// Emulates the window server's tracking-area events: entered/exited when the simulated cursor crosses
// an area, and mouseMoved inside areas created with NSTrackingMouseMoved. Menus are included: their
// windows are not in NSApp.windows, and views in menu items rely on these events for hover.
static void XAUpdateTrackingAreas(void) {
    NSWindow *target = XAWindowAtPoint(gMouse);
    for (NSWindow *window in XAWindowsFrontToBack()) {
        NSView *root = window.contentView.superview ?: window.contentView;
        NSMutableArray *areas = [NSMutableArray array];
        if (root) XACollectTrackingAreas(root, areas);
        for (NSArray *pair in areas) {
            NSTrackingArea *area = pair[0];
            NSView *view = pair[1];
            if (!(area.options & (NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved))) continue;
            // visibleRect can extend past the bounds when superviews do not clip (macOS 14+).
            NSRect rect = (area.options & NSTrackingInVisibleRect) ? NSIntersectionRect(view.visibleRect, view.bounds) : area.rect;
            NSRect screenRect = [window convertRectToScreen:[view convertRect:rect toView:nil]];
            BOOL inside = window == target && NSPointInRect(gMouse, screenRect);
            // Views commonly recreate their tracking areas in -updateTrackingAreas; the inside
            // state belongs to the view and owner, not to one NSTrackingArea instance.
            NSString *key = [NSString stringWithFormat:@"%p-%p", view, area.owner];
            BOOL wasInside = [gInsideAreas containsObject:key];
            if (getenv("XCUISIM_TRACE_TRACKING")) XAInfo(@"tracking %@ owner %@ rect %@ inside=%d was=%d", key, [area.owner class], NSStringFromRect(screenRect), inside, wasInside);
            NSPoint location = [window convertPointFromScreen:gMouse];
            if (inside && wasInside) {
                if (area.options & NSTrackingMouseMoved) {
                    [area.owner mouseMoved:[NSEvent mouseEventWithType:NSEventTypeMouseMoved location:location modifierFlags:gFlags
                                                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                                                               context:nil eventNumber:++gEventNumber clickCount:0 pressure:0]];
                }
                continue;
            }
            if (inside == wasInside) continue;
            if (inside) [gInsideAreas addObject:key]; else [gInsideAreas removeObject:key];
            if (!(area.options & NSTrackingMouseEnteredAndExited)) continue;
            NSEvent *event = [NSEvent enterExitEventWithType:inside ? NSEventTypeMouseEntered : NSEventTypeMouseExited location:location
                                               modifierFlags:gFlags timestamp:NSProcessInfo.processInfo.systemUptime
                                                windowNumber:window.windowNumber context:nil eventNumber:++gEventNumber
                                              trackingNumber:(NSInteger)area userData:(__bridge void *)area.userInfo];
            if (inside) [area.owner mouseEntered:event]; else [area.owner mouseExited:event];
        }
    }
}

// Tracking-area updates travel through the event queue as a marker so they happen in order
// with the mouse events around them.
static void XASendEvent(NSApplication *self, SEL _cmd, NSEvent *event) {
    if (event.type == NSEventTypeAppKitDefined && event.subtype == NSEventSubtypeApplicationDeactivated) {
        XAInfo(@"dropped a window-server deactivation event");
        return;
    }
    if (event.type == NSEventTypeApplicationDefined && event.subtype == XAMarkerSubtype) {
        XAUpdateTrackingAreas();
        return;
    }
    ((void (*)(id, SEL, NSEvent *))gSendEvent)(self, _cmd, event);
}

#pragma mark - Simulated menu bar

// An inactive app does not own the system menu bar, so AppKit reports its menu bar items with an
// invalid frame. The agent lays them out like a menu bar on the primary screen and, when a click
// lands on one, opens its submenu in-process as a pop-up menu (an invisible window like any other).
static NSArray *XAMenuBarLayout(void) {
    NSMutableArray *layout = [NSMutableArray array];
    NSRect screen = NSScreen.screens.firstObject.frame;
    CGFloat height = 24, x = 42; // the Apple menu occupies the first 42 points
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSArray *items = NSApp.mainMenu.itemArray;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSMenuItem *item = items[i];
        if (item.isHidden) continue;
        CGFloat width = [item.title sizeWithAttributes:@{NSFontAttributeName: i == 0 ? [NSFont boldSystemFontOfSize:font.pointSize] : font}].width + 20;
        [layout addObject:@[item, [NSValue valueWithRect:NSMakeRect(x, NSMaxY(screen) - height, width, height)]]];
        x += width;
    }
    return layout;
}

static NSMenuItem *XAMenuBarItemAtPoint(NSPoint point, NSRect *rectOut) {
    for (NSArray *entry in XAMenuBarLayout()) {
        NSRect rect = [entry[1] rectValue];
        if (NSPointInRect(point, rect)) { if (rectOut) *rectOut = rect; return entry[0]; }
    }
    return nil;
}

static NSRect XAMenuBarRectForItem(NSMenuItem *item, BOOL *found) {
    for (NSArray *entry in XAMenuBarLayout()) if (entry[0] == item) { *found = YES; return [entry[1] rectValue]; }
    *found = NO;
    return NSZeroRect;
}

static NSMenu *gOpenMenuBarMenu; // menu bar menu currently open as a pop-up

static IMP gMenuItemAttributeValue;
static id XAMenuItemAttributeValue(NSMenuItem *self, SEL _cmd, NSString *attribute) {
    // A real menu bar item is selected while its menu is open; XCUITest's menu traversal reads it
    // to decide whether the title must be clicked before reaching an item.
    if (self.menu == NSApp.mainMenu && self.submenu && [attribute isEqualToString:NSAccessibilitySelectedAttribute]) {
        return @(self.submenu == gOpenMenuBarMenu);
    }
    if (self.menu == NSApp.mainMenu && ([attribute isEqualToString:NSAccessibilityPositionAttribute] ||
                                        [attribute isEqualToString:NSAccessibilitySizeAttribute] ||
                                        [attribute isEqualToString:@"AXFrame"])) {
        BOOL found;
        NSRect rect = XAMenuBarRectForItem(self, &found);
        if (found) {
            if ([attribute isEqualToString:NSAccessibilityPositionAttribute]) return [NSValue valueWithPoint:rect.origin];
            if ([attribute isEqualToString:NSAccessibilitySizeAttribute]) return [NSValue valueWithSize:rect.size];
            return [NSValue valueWithRect:rect];
        }
    }
    return ((id (*)(id, SEL, NSString *))gMenuItemAttributeValue)(self, _cmd, attribute);
}

static NSMenuItem *gPressedMenuBarItem;

// Returns YES when the button event was consumed by the simulated menu bar.
// Menu bar menus open one at a time in a session: switching to another menu (arrow keys, moving the
// pointer over another title) cancels the open pop-up and the session opens the next one after
// the cancelled pop-up has returned, so pop-ups never nest.
static NSMenuItem *gPendingMenuBarItem;

static void XAStartMenuBarSession(NSMenuItem *item) {
    gPendingMenuBarItem = item;
    if (gOpenMenuBarMenu) { [gOpenMenuBarMenu cancelTrackingWithoutAnimation]; return; }
    XARunOnMain(0, ^{
        while (gPendingMenuBarItem) {
            NSMenuItem *next = gPendingMenuBarItem;
            gPendingMenuBarItem = nil;
            BOOL found;
            NSRect rect = XAMenuBarRectForItem(next, &found);
            if (!found || !next.submenu) continue;
            XAInfo(@"opening menu bar menu %@", next.title);
            gOpenMenuBarMenu = next.submenu;
            [next.submenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(rect.origin.x, rect.origin.y) inView:nil];
            gOpenMenuBarMenu = nil;
            XAInfo(@"menu bar menu %@ closed", next.title);
        }
    });
}

static NSMenuItem *XAOpenMenuBarItem(void) {
    for (NSArray *entry in XAMenuBarLayout()) if ([entry[0] submenu] == gOpenMenuBarMenu) return entry[0];
    return nil;
}

// Returns YES when the button event was consumed by the simulated menu bar.
static BOOL XAMenuBarButton(NSUInteger button, BOOL down) {
    NSRect rect;
    NSMenuItem *item = XAMenuBarItemAtPoint(gMouse, &rect);
    if (!item) { gPressedMenuBarItem = nil; return NO; }
    if (down) { gPressedMenuBarItem = item; return YES; }
    if (gPressedMenuBarItem != item || !item.submenu) { gPressedMenuBarItem = nil; return YES; }
    gPressedMenuBarItem = nil;
    // Clicking the title of the open menu closes it, as in the real menu bar.
    if (gOpenMenuBarMenu == item.submenu) { gPendingMenuBarItem = nil; [item.submenu cancelTracking]; return YES; }
    XAStartMenuBarSession(item);
    return YES;
}

// While a menu bar menu is open, moving the pointer over another title switches to its menu.
static void XAMenuBarHover(NSPoint point) {
    if (!gOpenMenuBarMenu || XAWindowAtPoint(point)) return;
    NSMenuItem *item = XAMenuBarItemAtPoint(point, NULL);
    if (item.submenu && item.submenu != gOpenMenuBarMenu) XAStartMenuBarSession(item);
}

// Left/Right arrows move along the menu bar when the keyboard is in the top-level menu (no item of
// an open submenu is highlighted); otherwise the pop-up handles them (closing or entering submenus).
static BOOL XAMenuBarArrow(NSString *key, NSEventModifierFlags modifiers) {
    if (!gOpenMenuBarMenu || (modifiers & NSEventModifierFlagDeviceIndependentFlagsMask & ~(NSEventModifierFlagFunction | NSEventModifierFlagNumericPad))) return NO;
    unichar c = key.length == 1 ? [key characterAtIndex:0] : 0;
    if (c != NSLeftArrowFunctionKey && c != NSRightArrowFunctionKey) return NO;
    for (NSMenuItem *entry in gOpenMenuBarMenu.itemArray) if (entry.submenu.highlightedItem) return NO;
    NSMutableArray *items = [NSMutableArray array];
    for (NSArray *entry in XAMenuBarLayout()) if ([entry[0] submenu]) [items addObject:entry[0]];
    NSUInteger index = [items indexOfObject:XAOpenMenuBarItem()];
    if (index == NSNotFound || !items.count) return NO;
    NSUInteger next = c == NSLeftArrowFunctionKey ? (index + items.count - 1) % items.count : (index + 1) % items.count;
    XAStartMenuBarSession(items[next]);
    return YES;
}

#pragma mark - Isolation from the user's real pointer

static NSUInteger gDroppedRealEvents;

// Pointer events created in this process (by the agent or internally by AppKit, e.g. when a menu
// starts tracking) carry this process's pid; events from the window server (the user's real cursor,
// including tracking-area entered/exited events for the invisible windows) carry pid 0.
static BOOL XAIsRealPointerEvent(NSEvent *event) {
    switch (event.type) {
        case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp: case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp:
        case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged: case NSEventTypeScrollWheel:
        case NSEventTypeMouseEntered: case NSEventTypeMouseExited: case NSEventTypeCursorUpdate:
        case NSEventTypeMagnify: case NSEventTypeSwipe: case NSEventTypeRotate: case NSEventTypeBeginGesture:
        case NSEventTypeEndGesture: case NSEventTypeSmartMagnify: case NSEventTypePressure: case NSEventTypeDirectTouch: {
            CGEventRef cg = event.CGEvent;
            return cg && CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID) != getpid();
        }
        default:
            return NO;
    }
}

// AppKit's tracking-area manager also updates areas from the location of each dequeued event (a
// dequeuing observer that runs before -nextEventMatchingMask: returns), and synthesizes
// entered/exited events itself, e.g. for view-based menu items. Updates whose location is not the
// simulated cursor come from the user's real pointer and are ignored.
static IMP gUpdateMenuAreas, gUpdateAreas;
static BOOL XAIsSimulatedLocation(id manager, CGPoint location) {
    NSWindow *window = [manager valueForKey:@"window"];
    if (!window) return YES;
    NSPoint simulated = [window convertPointFromScreen:gMouse];
    return fabs(simulated.x - location.x) <= 1 && fabs(simulated.y - location.y) <= 1;
}
static void XAUpdateMenuAreas(id self, SEL _cmd, CGPoint location, NSUInteger flags) {
    if (!XAIsSimulatedLocation(self, location)) { XAInfo(@"ignored a menu tracking-area update from the real pointer"); return; }
    ((void (*)(id, SEL, CGPoint, NSUInteger))gUpdateMenuAreas)(self, _cmd, location, flags);
}
static void XAUpdateAreas(id self, SEL _cmd, CGPoint location, NSUInteger flags) {
    if (!XAIsSimulatedLocation(self, location)) return;
    ((void (*)(id, SEL, CGPoint, NSUInteger))gUpdateAreas)(self, _cmd, location, flags);
}

// When the user's real cursor enters an (invisible) window's structural region, AppKit's display
// cycle calls -setCursorForMouseLocation: with the real location, which sets the cursor and
// synthesizes entered/exited events for the areas under it. In the simulation the hardware cursor
// must not matter: the call is dropped (hover comes from the simulated cursor only).
static IMP gSetCursorForMouseLocation;
static void XASetCursorForMouseLocation(id self, SEL _cmd, CGPoint location) {
    static BOOL logged;
    if (!logged) { logged = YES; XAInfo(@"ignored real-cursor tracking update at %@", NSStringFromPoint(location)); }
}

// Every event loop (the main loop, nested tracking loops, menu tracking) dequeues through here.
static IMP gNextEvent;
static NSEvent *XANextEvent(NSApplication *self, SEL _cmd, NSEventMask mask, NSDate *until, NSRunLoopMode mode, BOOL dequeue) {
    static int traceOnly = -1;
    if (traceOnly < 0) traceOnly = getenv("XCUISIM_TRACE_POINTER") != NULL;
    for (;;) {
        NSEvent *event = ((NSEvent *(*)(id, SEL, NSEventMask, NSDate *, NSRunLoopMode, BOOL))gNextEvent)(self, _cmd, mask, until, mode, dequeue);
        if (traceOnly) {
            if (event && event.type != NSEventTypeAppKitDefined && event.type != NSEventTypeSystemDefined && event.type != NSEventTypeApplicationDefined && event.type != NSEventTypePeriodic) {
                CGEventRef cg = event.CGEvent;
                if (event.type == NSEventTypeScrollWheel) XAInfo(@"pointer-trace scroll dx=%.1f dy=%.1f precise=%d inverted=%d phase=%lu momentum=%lu loc=%@ win=%ld",
                    event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas, event.isDirectionInvertedFromDevice,
                    (unsigned long)event.phase, (unsigned long)event.momentumPhase, NSStringFromPoint(event.locationInWindow), (long)event.windowNumber);
                XAInfo(@"pointer-trace type=%lu evNum=%ld win=%ld pid=%lld state=%lld userData=%lld deq=%d mode=%@", (unsigned long)event.type,
                       (long)((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged) ? -1 : event.eventNumber), (long)event.windowNumber,
                       cg ? CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID) : -1,
                       cg ? CGEventGetIntegerValueField(cg, kCGEventSourceStateID) : -1,
                       cg ? CGEventGetIntegerValueField(cg, kCGEventSourceUserData) : -1, dequeue, mode);
            }
            return event;
        }
        if (!event || !XAIsRealPointerEvent(event)) return event;
        if (!dequeue) {
            ((NSEvent *(*)(id, SEL, NSEventMask, NSDate *, NSRunLoopMode, BOOL))gNextEvent)(self, _cmd, NSEventMaskFromType(event.type), [NSDate distantPast], mode, YES);
        }
        if (++gDroppedRealEvents % 50 == 1) XAInfo(@"dropped real pointer event %@ (%lu so far)", event, (unsigned long)gDroppedRealEvents);
    }
}

#pragma mark - Event construction

static void XAPost(NSEvent *event) {
    if (event) [NSApp postEvent:event atStart:NO];
}

static void XAPostTrackingMarker(void) {
    XAPost([NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil
                               subtype:XAMarkerSubtype data1:0 data2:0]);
}

static void XAPostMouse(NSEventType type, NSPoint point, NSInteger clickCount, float pressure) {
    NSWindow *window = XAWindowAtPoint(point);
    NSPoint location = window ? [window convertPointFromScreen:point] : point;
    NSEvent *event = [NSEvent mouseEventWithType:type location:location modifierFlags:gFlags
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:window.windowNumber context:nil eventNumber:++gEventNumber
                                      clickCount:clickCount pressure:pressure];
    XAPost(event);
}

static NSEventType XAMoveType(void) {
    if (gButtons & 1) return NSEventTypeLeftMouseDragged;
    if (gButtons & 2) return NSEventTypeRightMouseDragged;
    if (gButtons) return NSEventTypeOtherMouseDragged;
    return NSEventTypeMouseMoved;
}

static void XAMenuBarHover(NSPoint point);

static void XAMoveTo(NSPoint point) {
    gMouse = point;
    XAMenuBarHover(point);
    XAPostMouse(XAMoveType(), point, 0, gButtons ? 1 : 0);
    // A menu's tracking loop consumes queued events without dispatching application-defined
    // markers, so tracking areas are updated right away while a menu is open.
    if (gMenuTrackingDepth > 0) XAUpdateTrackingAreas(); else XAPostTrackingMarker();
}

static void XAButton(NSUInteger button, BOOL down, NSInteger clickCount) {
    NSEventType type;
    NSUInteger mask = 1u << button;
    if (button == 0) type = down ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp;
    else if (button == 1) type = down ? NSEventTypeRightMouseDown : NSEventTypeRightMouseUp;
    else type = down ? NSEventTypeOtherMouseDown : NSEventTypeOtherMouseUp;
    if (down) gButtons |= mask; else gButtons &= ~mask;
    if (button == 0 && !XAWindowAtPoint(gMouse) && XAMenuBarButton(button, down)) return;
    XAPostMouse(type, gMouse, MAX(clickCount, 1), down ? 1 : 0);
}

// Private CoreGraphics call: the window-relative location (top-left origin) that NSEvent uses as
// -locationInWindow for events targeted at a window.
extern void CGEventSetWindowLocation(CGEventRef event, CGPoint location);

// Scroll events are built as CGEvents (pixel or line units) and marked with this process's pid: the
// isolation filter drops pointer events from other sources.
static void XAPostScroll(CGScrollEventUnit unit, int32_t vertical, int32_t horizontal) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, unit, 2, vertical, horizontal);
    if (unit == kCGScrollEventUnitPixel) CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, 1);
    NSWindow *window = XAWindowAtPoint(gMouse);
    CGEventSetLocation(cg, CGPointMake(gMouse.x, XAPrimaryHeight() - gMouse.y));
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, window.windowNumber);
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, window.windowNumber);
    // Field 51 is what +[NSEvent eventWithCGEvent:] reads as the window number (found empirically on
    // macOS 27.0.1); without it the event has no window and AppKit does not route it to the view.
    CGEventSetIntegerValueField(cg, (CGEventField)51, window.windowNumber);
    if (window) {
        NSPoint inWindow = [window convertPointFromScreen:gMouse];
        CGEventSetWindowLocation(cg, CGPointMake(inWindow.x, window.frame.size.height - inWindow.y));
    }
    CGEventSetIntegerValueField(cg, kCGEventSourceUnixProcessID, getpid());
    CGEventSetFlags(cg, (CGEventFlags)gFlags);
    NSEvent *event = [NSEvent eventWithCGEvent:cg];
    if (getenv("XCUISIM_TRACE_POINTER")) XAInfo(@"scroll post: gMouse=%@ window=%@ #%ld frame=%@ expected=%@ got=%@", NSStringFromPoint(gMouse), window.className, (long)window.windowNumber,
        NSStringFromRect(window.frame), NSStringFromPoint([window convertPointFromScreen:gMouse]), NSStringFromPoint(event.locationInWindow));
    XAPost(event);
    CFRelease(cg);
}

#pragma mark - Keyboard

typedef struct { CGKeyCode code; NSEventModifierFlags flags; BOOL found; } XAKeyStroke;

static NSDictionary<NSString *, NSArray *> *XAKeyTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
        CFDataRef data = source ? TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) : NULL;
        if (data) {
            const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
            UInt32 modifierSets[] = {0, shiftKey >> 8, optionKey >> 8, (shiftKey | optionKey) >> 8};
            NSEventModifierFlags flagSets[] = {0, NSEventModifierFlagShift, NSEventModifierFlagOption,
                                               NSEventModifierFlagShift | NSEventModifierFlagOption};
            // First match wins: the fewest modifiers, then the lowest key code, so main-block keys are
            // preferred over keypad keys that type the same character (keypad codes are 65–92).
            for (int m = 0; m < 4; m++) {
                for (UInt16 code = 0; code < 128; code++) {
                    UInt32 deadKeys = 0; UniChar chars[4]; UniCharCount length = 0;
                    if (UCKeyTranslate(layout, code, kUCKeyActionDown, modifierSets[m], LMGetKbdType(),
                                       kUCKeyTranslateNoDeadKeysMask, &deadKeys, 4, &length, chars) == noErr && length == 1) {
                        NSString *character = [NSString stringWithCharacters:chars length:1];
                        if (!map[character]) map[character] = @[@(code), @(flagSets[m])];
                    }
                }
            }
        }
        if (source) CFRelease(source);
        NSDictionary *special = @{@"\x7f": @51, @"\r": @36, @"\x03": @76, @"\t": @48, @" ": @49, @"\x1b": @53,
                                  @"": @126, @"": @125, @"": @123, @"": @124,
                                  @"": @117, @"": @115, @"": @119, @"": @116, @"": @121,
                                  @"": @114, @"": @71,
                                  @"": @122, @"": @120, @"": @99, @"": @118, @"": @96,
                                  @"": @97, @"": @98, @"": @100, @"": @101, @"": @109,
                                  @"": @103, @"": @111};
        for (NSString *key in special) map[key] = @[special[key], @0];
        table = map;
    });
    return table;
}

static XAKeyStroke XAStrokeFor(NSString *key) {
    NSArray *entry = XAKeyTable()[key];
    if (!entry && key.length == 1) entry = XAKeyTable()[key.lowercaseString];
    if (!entry) return (XAKeyStroke){0, 0, NO};
    return (XAKeyStroke){(CGKeyCode)[entry[0] unsignedShortValue], [entry[1] unsignedIntegerValue], YES};
}

static NSWindow *XAKeyTargetWindow(void) {
    if (NSApp.keyWindow) return NSApp.keyWindow;
    for (NSWindow *window in XAWindowsFrontToBack()) if (window.isVisible) return window;
    return nil;
}

// Key events are built as CGEvents and converted, like hardware events: AppKit's menu key
// equivalent matching uses the CGEvent's layout information, which a plain
// +keyEventWithType:... event lacks.
static void XAPostKey(XAKeyStroke stroke, NSString *characters, NSEventModifierFlags flags, BOOL down) {
    CGEventRef cg = CGEventCreateKeyboardEvent(NULL, stroke.found ? stroke.code : 0, down);
    CGEventSetFlags(cg, (CGEventFlags)flags);
    // Hardware events carry the keyboard type; AppKit needs it to translate the key with other
    // modifiers (e.g. matching ⌘= against a ⌘+ key equivalent on layouts where + is Shift-=).
    CGEventSetIntegerValueField(cg, kCGKeyboardEventKeyboardType, LMGetKbdType());
    if (!stroke.found) {
        UniChar buffer[8]; NSUInteger length = MIN(characters.length, 8u);
        [characters getCharacters:buffer range:NSMakeRange(0, length)];
        CGEventKeyboardSetUnicodeString(cg, length, buffer);
    }
    CGEventSetTimestamp(cg, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    NSEvent *event = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    XAPost(event);
}

static void XASetFlags(NSEventModifierFlags flags) {
    static const struct { NSEventModifierFlags flag; unsigned short code; } keys[] = {
        {NSEventModifierFlagShift, 56}, {NSEventModifierFlagControl, 59},
        {NSEventModifierFlagOption, 58}, {NSEventModifierFlagCommand, 55}, {NSEventModifierFlagFunction, 63}};
    flags &= NSEventModifierFlagDeviceIndependentFlagsMask;
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        BOOL was = (gFlags & keys[i].flag) != 0, now = (flags & keys[i].flag) != 0;
        if (was == now) continue;
        gFlags = now ? (gFlags | keys[i].flag) : (gFlags & ~keys[i].flag);
        NSWindow *window = XAKeyTargetWindow();
        XAPost([NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:gFlags
                               timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                                 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO
                                 keyCode:keys[i].code]);
    }
}

static BOOL XAMenuBarArrow(NSString *key, NSEventModifierFlags modifiers);

static void XATypeKey(NSString *key, NSEventModifierFlags modifiers) {
    if (XAMenuBarArrow(key, gFlags | modifiers)) return;
    XAKeyStroke stroke = XAStrokeFor(key);
    NSEventModifierFlags flags = gFlags | modifiers | stroke.flags;
    unichar first = [key characterAtIndex:0];
    if (first >= 0xF700 && first <= 0xF8FF) flags |= NSEventModifierFlagFunction;
    if (first >= 0xF700 && first <= 0xF703) flags |= NSEventModifierFlagNumericPad;
    if (!stroke.found) XAInfo(@"no key code for key U+%04X; posting characters only", [key characterAtIndex:0]);
    XAPostKey(stroke, key, flags, YES);
    XAPostKey(stroke, key, flags, NO);
}

#pragma mark - XCTest flag conversion

// XCUIKeyModifierFlags: alphaShift 1<<0, shift 1<<1, control 1<<2, option 1<<3, command 1<<4, function 1<<5.
static NSEventModifierFlags XAFlagsFromXCUI(NSUInteger xcui) {
    NSEventModifierFlags flags = 0;
    if (xcui & (1 << 0)) flags |= NSEventModifierFlagCapsLock;
    if (xcui & (1 << 1)) flags |= NSEventModifierFlagShift;
    if (xcui & (1 << 2)) flags |= NSEventModifierFlagControl;
    if (xcui & (1 << 3)) flags |= NSEventModifierFlagOption;
    if (xcui & (1 << 4)) flags |= NSEventModifierFlagCommand;
    if (xcui & (1 << 5)) flags |= NSEventModifierFlagFunction;
    return flags;
}

static NSUInteger XAFlagsToXCUI(NSEventModifierFlags flags) {
    NSUInteger xcui = 0;
    if (flags & NSEventModifierFlagCapsLock) xcui |= 1 << 0;
    if (flags & NSEventModifierFlagShift) xcui |= 1 << 1;
    if (flags & NSEventModifierFlagControl) xcui |= 1 << 2;
    if (flags & NSEventModifierFlagOption) xcui |= 1 << 3;
    if (flags & NSEventModifierFlagCommand) xcui |= 1 << 4;
    return xcui;
}

#pragma mark - Record playback

typedef void (^XAStep)(void);

static void XAAddStep(NSMutableArray *steps, double offset, XAStep step) {
    [steps addObject:@[@(offset), [step copy]]];
}

// Expands the XCTest pointer events of one record into timed steps.
static NSArray *XAStepsForRecord(NSDictionary *record) {
    NSMutableArray *steps = [NSMutableArray array];
    for (NSDictionary *path in record[@"paths"]) {
        for (NSDictionary *e in path[@"events"]) {
            NSUInteger type = [e[@"eventType"] unsignedIntegerValue];
            double offset = [e[@"offset"] doubleValue], duration = [e[@"duration"] doubleValue];
            NSPoint point = XACocoaPoint([e[@"x"] doubleValue], [e[@"y"] doubleValue]);
            NSPoint destination = XACocoaPoint([e[@"dx"] doubleValue], [e[@"dy"] doubleValue]);
            // XCTest button types: 1 left, 2 right, 3 other.
            NSUInteger buttonType = [e[@"buttonType"] unsignedIntegerValue];
            NSUInteger button = buttonType > 0 ? buttonType - 1 : 0;
            NSInteger clicks = [e[@"clickCount"] integerValue];
            NSEventModifierFlags flags = XAFlagsFromXCUI([e[@"keyModifierFlags"] unsignedIntegerValue]);
            switch (type) {
                case 1: XAAddStep(steps, offset, ^{ if (!NSEqualPoints(gMouse, point)) XAMoveTo(point); XAButton(button, YES, clicks); }); break;
                case 3: XAAddStep(steps, offset, ^{ if (!NSEqualPoints(gMouse, point)) XAMoveTo(point); XAButton(button, NO, clicks); }); break;
                case 0: XAAddStep(steps, offset, ^{ if (!NSEqualPoints(gMouse, point)) XAMoveTo(point); }); break;
                case 2:
                case 4: {
                    BOOL hasDestination = duration > 0 && !isnan(destination.x);
                    if (!hasDestination) { XAAddStep(steps, offset, ^{ XAMoveTo(point); }); break; }
                    // testmanagerd emits about 24 points per 0.1 s move (~240 Hz, measured from real runs
                    // 2026-10-31); where an area is entered depends on this sampling.
                    NSInteger count = MAX(2, (NSInteger)lround(duration * 240));
                    for (NSInteger i = 0; i <= count; i++) {
                        double t = (double)i / count;
                        NSPoint p = NSMakePoint(point.x + (destination.x - point.x) * t, point.y + (destination.y - point.y) * t);
                        XAAddStep(steps, offset + duration * t, ^{ XAMoveTo(p); });
                    }
                    break;
                }
                case 5: case 7: {
                    double vx = [e[@"vx"] doubleValue], vy = [e[@"vy"] doubleValue];
                    NSInteger lines = [e[@"verticalLineScroll"] integerValue];
                    if (type == 7) {
                        XAAddStep(steps, offset, ^{
                            if (!NSEqualPoints(gMouse, point)) XAMoveTo(point);
                            XAPostScroll(kCGScrollEventUnitLine, (int32_t)lines, 0);
                        });
                        break;
                    }
                    // testmanagerd sends a delta scroll as continuous (trackpad-like) pixel events of
                    // about 21 pt each, within ~15 ms and without phases (measured 2026-10-31).
                    double length = MAX(fabs(vx), fabs(vy));
                    NSInteger count = MAX(1, (NSInteger)lround(length / 21.0));
                    int32_t sentX = 0, sentY = 0;
                    for (NSInteger i = 1; i <= count; i++) {
                        int32_t x = (int32_t)lround(vx * i / count) - sentX, y = (int32_t)lround(vy * i / count) - sentY;
                        sentX += x; sentY += y;
                        XAAddStep(steps, offset + duration * (i - 1) / MAX(count - 1, 1), ^{ XAPostScroll(kCGScrollEventUnitPixel, y, x); });
                    }
                    break;
                }
                case 8: {
                    BOOL merge = [e[@"mergeModifierFlagsWithCurrentFlags"] boolValue];
                    XAAddStep(steps, offset, ^{ XASetFlags(merge ? (gFlags | flags) : flags); });
                    break;
                }
                case 9: {
                    NSString *key = e[@"key"];
                    if (key.length) XAAddStep(steps, offset, ^{ XATypeKey(key, flags); });
                    break;
                }
                case 10: {
                    NSString *string = e[@"string"];
                    double speed = MAX([e[@"typingSpeed"] doubleValue], 1);
                    double interval = MIN(1.0 / speed, 0.02);
                    __block double at = offset;
                    [string enumerateSubstringsInRange:NSMakeRange(0, string.length) options:NSStringEnumerationByComposedCharacterSequences
                                            usingBlock:^(NSString *character, NSRange r, NSRange er, BOOL *stop) {
                        XAAddStep(steps, at, ^{ XATypeKey(character, 0); });
                        at += interval;
                    }];
                    break;
                }
                default:
                    XAInfo(@"unsupported XCTest event type %lu: %@", (unsigned long)type, e);
                    break;
            }
        }
    }
    [steps sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] compare:b[0]];
    }];
    return steps;
}

static void XARunOnMain(double delay, dispatch_block_t block) {
    CFRunLoopRef loop = CFRunLoopGetMain();
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0,
                                                               ^(CFRunLoopTimerRef t) { block(); });
    CFRunLoopAddTimer(loop, timer, kCFRunLoopCommonModes);
    CFRunLoopAddTimer(loop, timer, (__bridge CFStringRef)NSEventTrackingRunLoopMode);
    CFRunLoopMode current = CFRunLoopCopyCurrentMode(loop);
    if (current) { CFRunLoopAddTimer(loop, timer, current); CFRelease(current); }
    CFRelease(timer);
}

static void XADeliver(NSString *requestID, NSDictionary *record) {
    gStatus[requestID] = @"pending";
    XASimulateActivation();
    if (gDropEvents) { gStatus[requestID] = [NSString stringWithFormat:@"done:%lu", (unsigned long)XAFlagsToXCUI(gFlags)]; return; }
    NSArray *steps = XAStepsForRecord(record);
    if (!steps.count) { gStatus[requestID] = [NSString stringWithFormat:@"done:%lu", (unsigned long)XAFlagsToXCUI(gFlags)]; return; }
    double last = [steps.lastObject[0] doubleValue];
    for (NSArray *step in steps) {
        double offset = [step[0] doubleValue];
        XAStep body = step[1];
        BOOL isLast = step == steps.lastObject;
        XARunOnMain(offset, ^{
            body();
            if (isLast) gStatus[requestID] = [NSString stringWithFormat:@"done:%lu", (unsigned long)XAFlagsToXCUI(gFlags)];
        });
    }
    XAInfo(@"queued %@ (%@): %lu steps over %.3fs", requestID, record[@"name"], (unsigned long)steps.count, last);
}

#pragma mark - Screenshots

// Windows are invisible to the window server, so screenshots are rendered from the app's own
// layer trees. Returns base64 PNG data as a string: the app's container is not readable by the
// runner, and testmanagerd only forwards plain attribute values such as strings.
static id XAScreenshot(NSRect topLeftRect) {
    NSArray<NSWindow *> *windows = XAWindowsFrontToBack();
    NSRect target;
    if (topLeftRect.size.width <= 0 || topLeftRect.size.height <= 0) {
        target = NSZeroRect;
        for (NSWindow *window in windows) target = NSIsEmptyRect(target) ? window.frame : NSUnionRect(target, window.frame);
    } else {
        target = NSMakeRect(topLeftRect.origin.x, XAPrimaryHeight() - NSMaxY(topLeftRect), topLeftRect.size.width, topLeftRect.size.height);
    }
    if (NSIsEmptyRect(target)) return @"error:empty";
    CGFloat scale = NSScreen.screens.firstObject.backingScaleFactor ?: 2;
    NSInteger width = (NSInteger)ceil(target.size.width * scale), height = (NSInteger)ceil(target.size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(context, scale, scale);
    for (NSWindow *window in windows.reverseObjectEnumerator) {
        if (!NSIntersectsRect(window.frame, target)) continue;
        NSView *frameView = window.contentView.superview ?: window.contentView;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, window.frame.origin.x - target.origin.x, window.frame.origin.y - target.origin.y);
        if (frameView.layer) {
            [frameView.layer renderInContext:context];
        } else {
            NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
            [frameView displayRectIgnoringOpacity:frameView.bounds inContext:graphics];
        }
        CGContextRestoreGState(context);
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    CGImageRelease(image);
    return png ? [png base64EncodedStringWithOptions:0] : @"error:encode";
}

#pragma mark - Channel

static IMP gAttributeValue;

static NSString *XADiagnoseKey(NSString *key, NSUInteger xcuiFlags) {
    XAKeyStroke stroke = XAStrokeFor(key);
    NSEventModifierFlags flags = XAFlagsFromXCUI(xcuiFlags) | stroke.flags;
    CGEventRef cg = CGEventCreateKeyboardEvent(NULL, stroke.code, true);
    CGEventSetFlags(cg, (CGEventFlags)flags);
    NSEvent *derived = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:XAKeyTargetWindow().windowNumber
                                       context:nil characters:derived.characters charactersIgnoringModifiers:derived.charactersIgnoringModifiers
                                     isARepeat:NO keyCode:stroke.code];
    NSMutableString *items = [NSMutableString string];
    for (NSMenuItem *top in NSApp.mainMenu.itemArray) for (NSMenuItem *item in top.submenu.itemArray)
        if (item.keyEquivalent.length) [items appendFormat:@"[%@ '%@' %lx] ", item.title, item.keyEquivalent, (unsigned long)item.keyEquivalentModifierMask];
    BOOL windowHandled = [XAKeyTargetWindow() performKeyEquivalent:event];
    BOOL menuHandled = windowHandled ? NO : [NSApp.mainMenu performKeyEquivalent:event];
    return [NSString stringWithFormat:@"event=%@ window=%d menu=%d items=%@", event, windowHandled, menuHandled, items];
}

static id XAHandleCommand(NSString *command) {
    if ([command isEqualToString:@"ping"]) return [NSString stringWithFormat:@"pong:%d", getpid()];
    if ([command isEqualToString:@"scale"]) return [NSString stringWithFormat:@"%g", NSScreen.screens.firstObject.backingScaleFactor ?: 2];
    if ([command hasPrefix:@"shot:"]) {
        NSArray *parts = [command componentsSeparatedByString:@":"];
        return XAScreenshot(NSMakeRect([parts[1] doubleValue], [parts[2] doubleValue], [parts[3] doubleValue], [parts[4] doubleValue]));
    }
    if ([command hasPrefix:@"hit:"]) {
        // hit:<x>:<y> in XCTest (top-left) coordinates; returns the accessibility element at the
        // point as if the app were frontmost. AppKit hands it to the caller as an AXUIElement.
        NSArray *parts = [command componentsSeparatedByString:@":"];
        NSPoint point = XACocoaPoint([parts[1] doubleValue], [parts[2] doubleValue]);
        NSWindow *window = XAWindowAtPoint(point);
        id element = window ? [window accessibilityHitTest:point] : XAMenuBarItemAtPoint(point, NULL);
        XAInfo(@"hit test %@ -> %@ in %@", NSStringFromPoint(point), element, window.className);
        return element ?: @"none";
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([command isEqualToString:@"diagmenubar"]) {
        id bar = [NSApp accessibilityAttributeValue:NSAccessibilityMenuBarAttribute];
        NSMutableString *out = [NSMutableString stringWithFormat:@"bar=%@ ", [bar class]];
        for (id item in [bar accessibilityAttributeValue:NSAccessibilityChildrenAttribute]) {
            [out appendFormat:@"[%@ %@ pos=%@ size=%@] ", [item class], [item accessibilityAttributeValue:NSAccessibilityTitleAttribute],
             [item accessibilityAttributeValue:NSAccessibilityPositionAttribute], [item accessibilityAttributeValue:NSAccessibilitySizeAttribute]];
        }
        return out;
    }
#pragma clang diagnostic pop
    if ([command isEqualToString:@"diagactive"]) {
        NSRunningApplication *me = NSRunningApplication.currentApplication;
        return [NSString stringWithFormat:@"NSApp.isActive=%d running.isActive=%d ownsMenuBar=%d front=%@ keyAppearance=%@",
                NSApp.isActive, me.isActive, me.ownsMenuBar, NSWorkspace.sharedWorkspace.frontmostApplication.localizedName,
                [NSApp.keyWindow respondsToSelector:NSSelectorFromString(@"hasKeyAppearance")] ? [NSApp.keyWindow valueForKey:@"hasKeyAppearance"] : @"?"];
    }
    if ([command isEqualToString:@"diagfocus"]) {
        NSMutableString *out = [NSMutableString stringWithFormat:@"key=%@ main=%@ ", NSApp.keyWindow.className, NSApp.mainWindow.className];
        for (NSWindow *window in XAWindowsFrontToBack()) {
            [out appendFormat:@"[%@ '%@' key=%d main=%d canKey=%d occl=%lu fr=%@] ", window.className, window.title, window.isKeyWindow,
             window.isMainWindow, window.canBecomeKeyWindow, (unsigned long)window.occlusionState, window.firstResponder.className];
        }
        return out;
    }
    if ([command hasPrefix:@"diagraw:"]) {
        // diagraw:<chars>:<unmodified chars>:<NSEvent flags hex>:<keycode>
        NSArray *parts = [command componentsSeparatedByString:@":"];
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                     modifierFlags:strtoul([parts[3] UTF8String], NULL, 16)
                                         timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:XAKeyTargetWindow().windowNumber
                                           context:nil characters:parts[1] charactersIgnoringModifiers:parts[2]
                                         isARepeat:NO keyCode:(unsigned short)[parts[4] intValue]];
        BOOL menu = [NSApp.mainMenu performKeyEquivalent:event];
        return [NSString stringWithFormat:@"menu=%d active=%d", menu, NSApp.isActive];
    }
    if ([command hasPrefix:@"diagcg:"]) {
        // diagcg:<keycode>:<NSEvent flags hex>
        NSArray *parts = [command componentsSeparatedByString:@":"];
        CGEventRef cg = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)[parts[1] intValue], true);
        CGEventSetFlags(cg, (CGEventFlags)strtoul([parts[2] UTF8String], NULL, 16));
        NSEvent *event = [NSEvent eventWithCGEvent:cg];
        CFRelease(cg);
        BOOL menu = [NSApp.mainMenu performKeyEquivalent:event];
        return [NSString stringWithFormat:@"menu=%d chars=%@ unmod=%@", menu, event.characters, event.charactersIgnoringModifiers];
    }
    if ([command hasPrefix:@"diagkey:"]) {
        NSArray *parts = [command componentsSeparatedByString:@":"];
        return XADiagnoseKey(parts[1], [parts[2] integerValue]);
    }
    if ([command isEqualToString:@"activate"]) { XASimulateActivation(); return @"ok"; }
    if ([command hasPrefix:@"status:"]) return gStatus[[command substringFromIndex:7]] ?: @"unknown";
    if ([command hasPrefix:@"deliver:"]) {
        NSArray *parts = [command componentsSeparatedByString:@":"];
        if (parts.count != 3) return @"error:malformed";
        NSData *json = [[NSData alloc] initWithBase64EncodedString:parts[2] options:0];
        NSDictionary *record = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        if (![record isKindOfClass:[NSDictionary class]]) return @"error:payload";
        XADeliver(parts[1], record);
        return @"queued";
    }
    return @"error:unknown";
}

static id XAAttributeValue(NSApplication *self, SEL _cmd, NSString *attribute) {
    if ([attribute isKindOfClass:[NSString class]] && [attribute hasPrefix:@"XCUISim:"]) {
        return XAHandleCommand([attribute substringFromIndex:8]);
    }
    return ((id (*)(id, SEL, NSString *))gAttributeValue)(self, _cmd, attribute);
}

#pragma mark - Diagnostics

static IMP gWindowInit;
static id XAWindowInit(NSWindow *self, SEL _cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer) {
    XAInfo(@"diag: NSWindow init %@", NSStringFromClass([self class]));
    return ((id (*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL))gWindowInit)(self, _cmd, rect, style, backing, defer);
}

static void XALogProcessWindows(NSString *when) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    for (NSDictionary *w in list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != getpid()) continue;
        NSInteger number = [w[(id)kCGWindowNumber] integerValue];
        NSWindow *window = [NSApp windowWithWindowNumber:number];
        XAInfo(@"diag %@: window #%ld onscreen=%@ alpha=%@ layer=%@ bounds=%@ nswindow=%@", when, (long)number,
               w[(id)kCGWindowIsOnscreen], w[(id)kCGWindowAlpha], w[(id)kCGWindowLayer],
               [w[(id)kCGWindowBounds] description], window ? NSStringFromClass([window class]) : @"none");
    }
}

static IMP gMakeFirstResponder;
static BOOL XAMakeFirstResponder(NSWindow *self, SEL _cmd, NSResponder *responder) {
    BOOL ok = ((BOOL (*)(id, SEL, NSResponder *))gMakeFirstResponder)(self, _cmd, responder);
    XAInfo(@"diag: makeFirstResponder %@ -> %d (window key=%d, NSApp.keyWindow=%@)\n%@", responder.className, ok,
           self.isKeyWindow, NSApp.keyWindow.className, [[NSThread callStackSymbols] subarrayWithRange:NSMakeRange(1, MIN(8u, NSThread.callStackSymbols.count - 1))]);
    return ok;
}

static IMP gDiagMenuItemAttributeValue;
static id XADiagMenuItemAttributeValue(NSMenuItem *self, SEL _cmd, NSString *attribute) {
    id value = ((id (*)(id, SEL, NSString *))gDiagMenuItemAttributeValue)(self, _cmd, attribute);
    if (self.menu == NSApp.mainMenu && ([attribute isEqualToString:NSAccessibilitySelectedAttribute] ||
                                        [attribute isEqualToString:NSAccessibilityPositionAttribute] ||
                                        [attribute isEqualToString:NSAccessibilitySizeAttribute])) {
        XAInfo(@"diag: menubar %@ %@ = %@", self.title, attribute, value);
    }
    return value;
}

static void XAInstallDiagnostics(void) {
    gDiagMenuItemAttributeValue = XASwizzle([NSMenuItem class], @selector(accessibilityAttributeValue:), (IMP)XADiagMenuItemAttributeValue);
    for (NSNotificationName name in @[NSMenuDidBeginTrackingNotification, NSMenuDidEndTrackingNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            XAInfo(@"diag: %@ %@", note.name, [note.object title]);
        }];
    }
    // Samples the menu bar items' AXSelected every 20 ms (all run loop modes) and logs changes, so a
    // real run shows exactly when AppKit flips it.
    static NSString *last;
    NSTimer *sampler = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        NSMutableString *state = [NSMutableString string];
        for (NSMenuItem *item in NSApp.mainMenu.itemArray) {
            id selected = ((id (*)(id, SEL, NSString *))gDiagMenuItemAttributeValue)(item, @selector(accessibilityAttributeValue:), NSAccessibilitySelectedAttribute);
            if ([selected boolValue]) [state appendFormat:@"%@ ", item.title];
        }
        if (![state isEqualToString:last ?: @"?"]) { XAInfo(@"diag: menubar selected now [%@]", state); last = [state copy]; }
    }];
    [[NSRunLoop mainRunLoop] addTimer:sampler forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:sampler forMode:NSEventTrackingRunLoopMode];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        // Menu tracking may run in a private mode; add the sampler to whatever mode is current.
        dispatch_async(dispatch_get_main_queue(), ^{});
        CFRunLoopMode mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
        if (mode) { CFRunLoopAddTimer(CFRunLoopGetMain(), (__bridge CFRunLoopTimerRef)sampler, mode); XAInfo(@"diag: sampler mode %@", mode); CFRelease(mode); }
    }];
    for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification,
                                      NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                      NSWindowDidBecomeMainNotification, NSWindowDidResignMainNotification]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSArray *stack = NSThread.callStackSymbols;
            XAInfo(@"diag: %@ %@\n%@", note.name, [note.object className], [stack subarrayWithRange:NSMakeRange(1, MIN(9u, stack.count - 1))]);
        }];
    }
    gMakeFirstResponder = XASwizzle([NSWindow class], @selector(makeFirstResponder:), (IMP)XAMakeFirstResponder);
    gWindowInit = XASwizzle([NSWindow class], @selector(initWithContentRect:styleMask:backing:defer:), (IMP)XAWindowInit);
    [[NSNotificationCenter defaultCenter] addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        XAInfo(@"diag: menu did begin tracking %@", [note.object title]);
        XALogProcessWindows(@"begin");
        XARunOnMain(0, ^{ XALogProcessWindows(@"begin+0"); });
        XARunOnMain(0.05, ^{ XALogProcessWindows(@"begin+50ms"); });
    }];
}

#pragma mark - Installation

static void XAInstall(void) {
    Class app = [NSApplication class], window = [NSWindow class], event = [NSEvent class];
    gAttributeValue = XASwizzle(app, @selector(accessibilityAttributeValue:), (IMP)XAAttributeValue);
    gSendEvent = XASwizzle(app, @selector(sendEvent:), (IMP)XASendEvent);
    gIsActive = XASwizzle(app, @selector(isActive), (IMP)XAIsActive);
    gNextEvent = XASwizzle(app, @selector(nextEventMatchingMask:untilDate:inMode:dequeue:), (IMP)XANextEvent);
    Class areaManager = NSClassFromString(@"_NSTrackingAreaAKManager");
    gUpdateMenuAreas = XASwizzle(areaManager, NSSelectorFromString(@"_updateMenuActiveTrackingAreasForWindowLocation:modifierFlags:"), (IMP)XAUpdateMenuAreas);
    gSetCursorForMouseLocation = XASwizzle(areaManager, NSSelectorFromString(@"setCursorForMouseLocation:"), (IMP)XASetCursorForMouseLocation);
    gUpdateAreas = XASwizzle(areaManager, NSSelectorFromString(@"_updateActiveTrackingAreasForWindowLocation:modifierFlags:"), (IMP)XAUpdateAreas);
    gMenuItemAttributeValue = XASwizzle([NSMenuItem class], @selector(accessibilityAttributeValue:), (IMP)XAMenuItemAttributeValue);
    gActivateIgnoring = XASwizzle(app, @selector(activateIgnoringOtherApps:), (IMP)XAActivateIgnoring);
    gActivate = XASwizzle(app, @selector(activate), (IMP)XAActivate);
    gRunningActivate = XASwizzle([NSRunningApplication class], @selector(activateWithOptions:), (IMP)XARunningActivate);
    gSetAlpha = XASwizzle(window, @selector(setAlphaValue:), (IMP)XASetAlpha);
    gAlpha = XASwizzle(window, @selector(alphaValue), (IMP)XAAlpha);
    gSetIgnores = XASwizzle(window, @selector(setIgnoresMouseEvents:), (IMP)XASetIgnores);
    gIgnores = XASwizzle(window, @selector(ignoresMouseEvents), (IMP)XAIgnores);
    gOrderWindow = XASwizzle(window, @selector(orderWindow:relativeTo:), (IMP)XAOrderWindow);
    gWindowInitGhost = XASwizzle(window, @selector(initWithContentRect:styleMask:backing:defer:), (IMP)XAWindowInitGhost);
    gOutsideLocation = XASwizzle(window, @selector(mouseLocationOutsideOfEventStream), (IMP)XAOutsideLocation);
    gMouseLocation = XASwizzleClass(event, @selector(mouseLocation), (IMP)XAMouseLocation);
    gPressedButtons = XASwizzleClass(event, @selector(pressedMouseButtons), (IMP)XAPressedButtons);
    gModifierFlags = XASwizzleClass(event, @selector(modifierFlags), (IMP)XAModifierFlags);
}

__attribute__((constructor)) static void XCUISimAgentInit(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    gEnabled = [env[@"XCUISIM_ENABLED"] isEqualToString:@"1"];
    if (!gEnabled) {
        // Observe-only mode for real runs: records responder and activation changes, changes nothing.
        if ([env[@"XCUISIM_OBSERVE"] isEqualToString:@"1"]) {
            XAInstallDiagnostics();
            XAInfo(@"observer loaded in %@ pid %d", NSProcessInfo.processInfo.processName, getpid());
        }
        return;
    }
    gVisible = [env[@"XCUISIM_VISIBLE"] isEqualToString:@"1"];
    gDropEvents = [env[@"XCUISIM_DROP_EVENTS"] isEqualToString:@"1"];
    gStatus = [NSMutableDictionary dictionary];
    gInsideAreas = [NSMutableSet set];
    gKnownWindows = [NSHashTable weakObjectsHashTable];
    gMouse = NSMakePoint(-10000, -10000);
    XAInstall();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) { gMenuTrackingDepth++; }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) { gMenuTrackingDepth = MAX(gMenuTrackingDepth - 1, 0); }];
    if ([env[@"XCUISIM_DIAG"] isEqualToString:@"1"]) XAInstallDiagnostics();
    // Offscreen apps are candidates for App Nap and timer throttling.
    gActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                                                             reason:@"XCUISim offscreen UI test"];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
        XASweepWindows();
        XASimulateActivation();
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) { XASweepWindows(); }];
    }];
    XAInfo(@"agent loaded in %@ pid %d", NSProcessInfo.processInfo.processName, getpid());
}
