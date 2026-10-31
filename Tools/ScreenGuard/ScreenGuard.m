// Records evidence that a run did not touch the user's screen: frontmost application changes,
// cursor movement, and on-screen windows of the watched processes that are not fully transparent.
// Usage: ScreenGuard <output.log> <process name>...   (stops on SIGTERM/SIGINT)
#import <AppKit/AppKit.h>
#import <signal.h>

static volatile sig_atomic_t gStop;
static FILE *gOut;
static unsigned long gSyntheticEvents, gHardwareEvents;

// Any event in the login session that was posted by a process (source pid != 0) is evidence of
// real event synthesis; hardware events (the user) have no source pid.
static CGEventRef XGTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) return event;
    int64_t pid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    if (pid != 0) {
        gSyntheticEvents++;
        CGPoint p = CGEventGetLocation(event);
        fprintf(gOut, "%.3f SYNTHETIC event type %d from pid %lld at %.0f,%.0f\n", [NSDate date].timeIntervalSince1970, type, pid, p.x, p.y);
    } else {
        gHardwareEvents++;
    }
    return event;
}
static void XGStop(int sig) { gStop = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: ScreenGuard <log> <process>...\n"); return 2; }
        FILE *out = fopen(argv[1], "w");
        gOut = out;
        CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
            | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventLeftMouseDragged)
            | CGEventMaskBit(kCGEventScrollWheel) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
        CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap, kCGEventTapOptionListenOnly, mask, XGTap, NULL);
        if (tap) {
            CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
            fprintf(out, "event tap active\n");
        } else {
            fprintf(out, "event tap unavailable (no Input Monitoring permission); synthetic events are not attributed\n");
        }
        NSMutableSet *names = [NSMutableSet set];
        for (int i = 2; i < argc; i++) [names addObject:@(argv[i])];
        signal(SIGTERM, XGStop); signal(SIGINT, XGStop);
        NSString *lastFront = nil; CGPoint lastMouse = CGPointMake(NAN, NAN);
        NSMutableSet *reported = [NSMutableSet set];
        unsigned long samples = 0, frontChanges = 0, mouseMoves = 0, visibleWindows = 0;
        while (!gStop) {
            @autoreleasepool {
                NSDate *now = [NSDate date];
                NSString *front = NSWorkspace.sharedWorkspace.frontmostApplication.localizedName ?: @"?";
                CGEventRef e = CGEventCreate(NULL); CGPoint mouse = CGEventGetLocation(e); CFRelease(e);
                if (![front isEqualToString:lastFront]) {
                    if (lastFront) frontChanges++;
                    fprintf(out, "%.3f front %s\n", now.timeIntervalSince1970, front.UTF8String); lastFront = front;
                }
                if (!CGPointEqualToPoint(mouse, lastMouse)) {
                    if (!isnan(lastMouse.x)) mouseMoves++;
                    fprintf(out, "%.3f mouse %.0f,%.0f\n", now.timeIntervalSince1970, mouse.x, mouse.y); lastMouse = mouse;
                }
                NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
                for (NSDictionary *w in list) {
                    if (![names containsObject:w[(id)kCGWindowOwnerName]]) continue;
                    double alpha = [w[(id)kCGWindowAlpha] doubleValue];
                    if (alpha <= 0.001) continue;
                    NSString *key = [NSString stringWithFormat:@"%@-%@", w[(id)kCGWindowOwnerPID], w[(id)kCGWindowNumber]];
                    if ([reported containsObject:key]) continue;
                    [reported addObject:key]; visibleWindows++;
                    fprintf(out, "%.3f VISIBLE window %s #%s alpha %.2f layer %s bounds %s\n", now.timeIntervalSince1970,
                            [w[(id)kCGWindowOwnerName] UTF8String], [[w[(id)kCGWindowNumber] description] UTF8String], alpha,
                            [[w[(id)kCGWindowLayer] description] UTF8String], [[w[(id)kCGWindowBounds] description] UTF8String]);
                }
                samples++;
                fflush(out);
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        }
        fprintf(out, "summary samples=%lu frontChanges=%lu mouseMoves=%lu visibleWindows=%lu syntheticEvents=%lu hardwareEvents=%lu\n", samples, frontChanges, mouseMoves, visibleWindows, gSyntheticEvents, gHardwareEvents);
        fclose(out);
    }
    return 0;
}
