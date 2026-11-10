// XCUISim runner shim.
//
// Loaded into an XCUITest runner (XCTRunner host) with DYLD_INSERT_LIBRARIES. It wraps the
// runner's proxy to testmanagerd (-[XCTRunnerDaemonSession daemonProxy]) and replaces the
// calls that would touch the real window server:
//   - application launch (launched without activation, with the app agent inserted),
//   - setFrontProcess (activation),
//   - event synthesis (forwarded to the app agent, delivered in-process),
//   - the keyboard modifier query and the interruption query.
// Everything else (element queries, snapshots, termination, state monitoring) goes to
// testmanagerd unchanged. Private interfaces are documented in Notes/.
//
// Environment (runner):
//   XCUISIM_AGENT_PATH  absolute path of libXCUISimAgent.dylib (required to enable the shim)
//   XCUISIM_LOG_EVENTS  1 to log every event record
//   XCUISIM_DROP_EVENTS 1 to acknowledge events without delivering them (negative control)

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <os/log.h>

static os_log_t XSLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.xcuitestsim", "runner"); });
    return log;
}
#define XSInfo(fmt, ...) do { \
    NSString *_m = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    os_log(XSLog(), "%{public}@", _m); \
    fprintf(stderr, "[xcuisim-runner] %s\n", _m.UTF8String); \
} while (0)

#pragma mark - Private interfaces used through the runtime

@interface NSObject (XCUISimPrivate)
// XCAccessibilityElement
+ (id)elementWithProcessIdentifier:(pid_t)pid;
// XCSynthesizedEventRecord / XCPointerEventPath / XCPointerEvent
- (NSArray *)eventPaths;
- (NSArray *)pointerEvents;
- (NSUInteger)pathType;
- (NSInteger)targetProcessID;
// XCTApplicationStateSnapshot
- (id)initWithBundleID:(NSString *)bundleID path:(NSString *)path runState:(NSUInteger)state
             processID:(pid_t)pid activationPolicy:(NSUInteger)policy eventID:(NSUInteger)eventID
           processName:(NSString *)processName;
- (NSString *)bundleID;
- (NSString *)path;
- (NSString *)processName;
- (NSUInteger)runState;
- (pid_t)processID;
- (NSUInteger)activationPolicy;
// testmanagerd proxy
- (void)_XCT_fetchAttributes:(NSArray *)attributes forElement:(id)element
                       reply:(void (^)(NSDictionary *, NSError *))reply;
- (void)_XCT_requestElementAtPoint:(CGPoint)point reply:(void (^)(id, NSError *))reply;
- (void)_XCT_enableAutomationModeWithReply:(void (^)(NSError *))reply;
- (void)_XCT_loadAccessibilityWithTimeout:(double)timeout reply:(void (^)(BOOL, NSError *))reply;
- (void)_XCT_registerForAXNotificationsForApplicationWithPID:(int)pid timeout:(double)timeout completion:(void (^)(BOOL, NSError *))completion;
- (void)_XCT_unregisterForAXNotificationsForApplicationWithPID:(int)pid;
- (void)_XCT_syncCrashReporterWithReply:(void (^)(BOOL, NSError *))reply;
- (void)_XCT_fetchSnapshotForElement:(id)element attributes:(NSArray *)attributes parameters:(NSDictionary *)parameters reply:(void (^)(id, NSError *))reply;
- (void)_XCT_performWhenMenuOpens:(id)element block:(void (^)(void))block;
- (void)_XCT_notifyWhenEventLoopIsIdleForApplicationWithPID:(int)pid reply:(void (^)(NSError *))reply;
- (void)_XCT_requestScreenshotAttachment:(id)request withReply:(void (^)(id, NSError *))reply;
- (id)initWithRootElementSnapshot:(id)snapshot runtimeIssues:(id)issues;
- (id)initWithUniformTypeIdentifier:(NSString *)uti compressionQuality:(double)quality;
- (id)initWithScale:(double)scale;
- (id)initWithData:(NSData *)data encodedIn:(id)encoding metadata:(id)metadata;
@end

#pragma mark - State shared by the shim

static NSString *gAgentPath;
static BOOL gLogEvents;
static BOOL gDropEvents;
static NSMutableDictionary<NSString *, NSNumber *> *gSimulatedApps; // bundle ID -> pid
static BOOL gNoAutomationMode; // spike: XCUISIM_NO_AUTOMATION_MODE=1
static pid_t gLastPid;
static BOOL gLaunchHooksInstalled; // XCUIApplicationImpl launch hooks (what makes a launch simulated)
static NSUInteger gModifierFlags; // modifier state as the agent tracks it
static NSUInteger gNextRequest;

static dispatch_queue_t XSQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("dev.xcuitestsim.runner", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSError *XSError(NSString *description) {
    return [NSError errorWithDomain:@"dev.xcuitestsim" code:1
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - Event record serialization

static NSDictionary *XSPointerEventDictionary(id event) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"eventType", @"buttonType", @"offset", @"duration", @"clickCount",
                            @"keyModifierFlags", @"mergeModifierFlagsWithCurrentFlags", @"typingSpeed",
                            @"keyCode", @"keyPhase", @"verticalLineScroll", @"pressure", @"gesturePhase"]) {
        id value = [event valueForKey:key];
        if (value) d[key] = value;
    }
    for (NSString *key in @[@"key", @"string"]) {
        id value = [event valueForKey:key];
        if (value) d[key] = value;
    }
    CGPoint c = [[event valueForKey:@"coordinate"] pointValue];
    CGPoint dst = [[event valueForKey:@"destination"] pointValue];
    CGVector v = {0, 0};
    [[event valueForKey:@"deltaVector"] getValue:&v size:sizeof(v)];
    d[@"x"] = @(c.x); d[@"y"] = @(c.y);
    d[@"dx"] = @(dst.x); d[@"dy"] = @(dst.y);
    d[@"vx"] = @(v.dx); d[@"vy"] = @(v.dy);
    return d;
}

static NSData *XSSerializeRecord(id record) {
    NSMutableArray *paths = [NSMutableArray array];
    for (id path in [record eventPaths]) {
        NSMutableArray *events = [NSMutableArray array];
        for (id event in [path pointerEvents]) [events addObject:XSPointerEventDictionary(event)];
        [paths addObject:@{@"pathType": @([path pathType]), @"events": events}];
    }
    NSDictionary *payload = @{@"name": [record valueForKey:@"name"] ?: @"", @"paths": paths};
    return [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
}

#pragma mark - Channel to the app agent

// Default channel: a custom accessibility attribute of the application element, read through
// testmanagerd's own attribute fetch. It needs no extra entitlement in either sandbox and is
// serviced by the app's main thread in every run loop mode, including menu tracking.
// Without Automation Mode (XCUISIM_NO_AUTOMATION_MODE=1) testmanagerd refuses that fetch, so the
// shim talks to the agent's CFMessagePort (XCUISIM_PORT, an app-group name the lane's runner may look
// up) with keyed archives of dictionaries.

static NSString *gPortName;

static NSData *XSArchive(id object) {
    return [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:nil];
}

static id XSUnarchive(NSData *data) {
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil];
    unarchiver.requiresSecureCoding = NO;
    return [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
}

// Synchronous request to the agent's port. A relaunched app registers a new port under the same name,
// so an invalid port is looked up again.
static NSDictionary *XSPortSend(NSDictionary *request, CFTimeInterval timeout) {
    static CFMessagePortRef port;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("dev.xcuitestsim.runner.port", DISPATCH_QUEUE_SERIAL); });
    __block NSDictionary *reply;
    dispatch_sync(queue, ^{
        NSData *data = XSArchive(request);
        for (int attempt = 0; attempt < 2 && !reply; attempt++) {
            if (port && !CFMessagePortIsValid(port)) { CFRelease(port); port = NULL; }
            if (!port) port = CFMessagePortCreateRemote(NULL, (__bridge CFStringRef)gPortName);
            if (!port) { reply = @{@"error": [NSString stringWithFormat:@"The app agent's port %@ is not available", gPortName]}; break; }
            CFDataRef out = NULL;
            SInt32 status = CFMessagePortSendRequest(port, 0, (__bridge CFDataRef)data, timeout, timeout, kCFRunLoopDefaultMode, &out);
            if (status == kCFMessagePortSuccess && out) {
                id value = XSUnarchive((__bridge_transfer NSData *)out);
                reply = [value isKindOfClass:[NSDictionary class]] ? value : @{@"error": @"malformed reply from the app agent"};
            } else if (status == kCFMessagePortIsInvalid || status == kCFMessagePortTransportError) {
                CFRelease(port); port = NULL;
            } else {
                reply = @{@"error": [NSString stringWithFormat:@"The app agent did not answer %@ (status %d)", request[@"op"], (int)status]};
            }
        }
        if (!reply) reply = @{@"error": @"The app agent's port is not valid"};
    });
    return reply;
}

static NSError *XSReplyError(NSDictionary *reply) {
    if (!reply[@"error"]) return nil;
    id original = reply[@"nserror"];
    return [original isKindOfClass:[NSError class]] ? original : XSError(reply[@"error"]);
}

// Reads agent commands (attribute names without the XCUISim: prefix) through the active channel.
static void XSFetchFromAgent(id daemon, pid_t pid, NSArray<NSString *> *commands, void (^reply)(NSDictionary *, NSError *)) {
    if (gNoAutomationMode && gPortName.length) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *answer = XSPortSend(@{@"op": @"commands", @"commands": commands}, 30);
            reply(answer[@"values"], XSReplyError(answer));
        });
        return;
    }
    NSMutableArray *attributes = [NSMutableArray array];
    for (NSString *command in commands) [attributes addObject:[@"XCUISim:" stringByAppendingString:command]];
    id element = [NSClassFromString(@"XCAccessibilityElement") elementWithProcessIdentifier:pid];
    [daemon _XCT_fetchAttributes:attributes forElement:element reply:^(NSDictionary *values, NSError *error) {
        NSMutableDictionary *byCommand = [NSMutableDictionary dictionary];
        for (NSString *command in commands) {
            id value = values[[@"XCUISim:" stringByAppendingString:command]];
            if (value) byCommand[command] = value;
        }
        reply(byCommand, error);
    }];
}

static void XSAgentRequest(id daemon, pid_t pid, NSString *command, void (^reply)(NSString *, NSError *)) {
    NSString *attribute = command;
    XSFetchFromAgent(daemon, pid, @[command], ^(NSDictionary *values, NSError *error) {
        id value = values[attribute];
        if (error || ![value isKindOfClass:[NSString class]]) {
            reply(nil, error ?: XSError([NSString stringWithFormat:@"The app agent did not answer %@ (got %@)",
                                         [command substringToIndex:MIN(command.length, 24u)], value]));
            return;
        }
        reply(value, nil);
    });
}

static pid_t XSTargetPid(id record) {
    NSInteger pid = [record targetProcessID];
    if (pid > 0) {
        for (NSNumber *known in gSimulatedApps.allValues) if (known.intValue == pid) return (pid_t)pid;
    }
    return gLastPid;
}

// A record can make the app quit (⌘Q): the status request then fails because the process is going
// away. Hardware synthesis completes regardless of what the app does with the events, so a target
// that terminates within 2 s counts as a completed delivery.
static void XSCompleteIfTerminated(pid_t pid, NSError *error, CFAbsoluteTime deadline, void (^completion)(NSError *)) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.isTerminated) {
        XSInfo(@"target pid %d terminated while its events were delivered; delivery complete", pid);
        completion(nil);
        return;
    }
    if (CFAbsoluteTimeGetCurrent() > deadline) { completion(error); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), XSQueue(), ^{
        XSCompleteIfTerminated(pid, error, deadline, completion);
    });
}

static void XSPollDelivery(id daemon, pid_t pid, NSString *requestID, CFAbsoluteTime start, void (^completion)(NSError *)) {
    XSAgentRequest(daemon, pid, [@"status:" stringByAppendingString:requestID], ^(NSString *status, NSError *error) {
        if (error) { XSCompleteIfTerminated(pid, error, CFAbsoluteTimeGetCurrent() + 2, completion); return; }
        if ([status hasPrefix:@"done"]) {
            NSArray *parts = [status componentsSeparatedByString:@":"];
            if (parts.count > 1) gModifierFlags = (NSUInteger)[parts[1] longLongValue];
            if (gLogEvents) XSInfo(@"delivered %@ in %.3fs", requestID, CFAbsoluteTimeGetCurrent() - start);
            completion(nil);
            return;
        }
        if (CFAbsoluteTimeGetCurrent() - start > 60) { completion(XSError(@"Event delivery timed out")); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), XSQueue(), ^{
            XSPollDelivery(daemon, pid, requestID, start, completion);
        });
    });
}

static void XSDeliverRecord(id daemon, id record, void (^completion)(NSError *)) {
    pid_t pid = XSTargetPid(record);
    NSData *json = XSSerializeRecord(record);
    if (gLogEvents) XSInfo(@"event %@ -> pid %d: %@", [record valueForKey:@"name"], pid,
                           [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    if (pid <= 0) { completion(XSError(@"No simulated application is running")); return; }
    if (gDropEvents) { XSInfo(@"negative control: dropping %@", [record valueForKey:@"name"]); completion(nil); return; }
    NSString *requestID = [NSString stringWithFormat:@"%lu", (unsigned long)++gNextRequest];
    NSString *command = [NSString stringWithFormat:@"deliver:%@:%@", requestID,
                         [json base64EncodedStringWithOptions:0]];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    XSAgentRequest(daemon, pid, command, ^(NSString *answer, NSError *error) {
        if (error) { XSInfo(@"delivery failed: %@", error); completion(error); return; }
        // Wait until the agent has posted the last event of the record.
        XSPollDelivery(daemon, pid, requestID, start, completion);
    });
}

#pragma mark - Launch without activation

static void XSLaunch(NSString *bundleID, NSString *path, NSArray *arguments, NSDictionary *environment,
                     void (^completion)(NSError *)) {
    NSURL *url = path.length ? [NSURL fileURLWithPath:path]
                             : [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleID];
    if (!url) { completion(XSError([NSString stringWithFormat:@"Cannot resolve %@", bundleID])); return; }
    // The agent is linked into the app's test build (a weak load command in the spike); it stays
    // inert unless XCUISIM_ENABLED is set.
    NSMutableDictionary *env = [environment mutableCopy] ?: [NSMutableDictionary dictionary];
    env[@"XCUISIM_ENABLED"] = @"1";
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = NO;
    configuration.addsToRecentItems = NO;
    configuration.createsNewApplicationInstance = YES;
    configuration.promptsUserIfNeeded = NO;
    configuration.arguments = arguments ?: @[];
    configuration.environment = env;
    XSInfo(@"launching %@ (%@) without activation, args %@", bundleID, url.path, arguments);
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:configuration
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error || !app) { XSInfo(@"launch failed: %@", error); completion(error ?: XSError(@"Launch failed")); return; }
        dispatch_async(XSQueue(), ^{
            gSimulatedApps[bundleID] = @(app.processIdentifier);
            gLastPid = app.processIdentifier;
            gModifierFlags = 0;
            XSInfo(@"launched %@ pid %d active=%d", bundleID, app.processIdentifier, app.active);
            completion(nil);
        });
    }];
}

#pragma mark - Daemon proxy wrapper

@interface XCUISimDaemonProxy : NSProxy
@property (nonatomic, strong) id target;
@end

@implementation XCUISimDaemonProxy

// Every message that still reaches testmanagerd is logged with its running count: the inventory of
// what a run without testmanagerd would have to answer (first 3 of each, then every 100th).
- (id)forwardingTargetForSelector:(SEL)selector {
    static NSCountedSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSCountedSet set]; });
    NSString *name = NSStringFromSelector(selector);
    NSUInteger count;
    @synchronized (seen) { [seen addObject:name]; count = [seen countForObject:name]; }
    if (count <= 3 || count % 100 == 0) XSInfo(@"daemon message %@ #%lu", name, (unsigned long)count);
    return self.target;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.target methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.target]; }
- (BOOL)respondsToSelector:(SEL)selector { return [self.target respondsToSelector:selector]; }
- (BOOL)conformsToProtocol:(Protocol *)protocol { return [self.target conformsToProtocol:protocol]; }

- (void)_XCT_launchApplicationWithBundleID:(NSString *)bundleID path:(NSString *)path arguments:(NSArray *)arguments
                               environment:(NSDictionary *)environment completion:(void (^)(NSError *))completion {
    XSLaunch(bundleID, path, arguments, environment, completion);
}

- (void)_XCT_launchApplicationWithBundleID:(NSString *)bundleID arguments:(NSArray *)arguments
                               environment:(NSDictionary *)environment completion:(void (^)(NSError *))completion {
    XSLaunch(bundleID, nil, arguments, environment, completion);
}

- (void)_XCT_setFrontProcess:(NSNumber *)pid completion:(void (^)(NSError *))completion {
    __block BOOL simulated;
    dispatch_sync(XSQueue(), ^{ simulated = [gSimulatedApps.allValues containsObject:pid]; });
    XSInfo(@"setFrontProcess %@ %@", pid, simulated ? @"(simulated: activation stays in-process)" : @"(not simulated: refused)");
    if (!simulated) {
        completion(XSError(gLaunchHooksInstalled ? @"Activating a process outside the simulation is not allowed"
                                                 : @"XCUISim launch hooks are not installed (unsupported Xcode): the app was launched without the agent"));
        return;
    }
    XSAgentRequest(self.target, pid.intValue, @"activate", ^(NSString *answer, NSError *error) { completion(error); });
}

- (void)_XCT_synthesizeEvent:(id)record implicitConfirmationInterval:(double)interval completion:(void (^)(NSError *))completion {
    XSDeliverRecord(self.target, record, completion);
}

// Hit testing goes to the app: its windows are invisible and click-through, so the window server
// would report whatever is behind them.
- (void)_XCT_requestElementAtPoint:(CGPoint)point reply:(void (^)(id, NSError *))reply {
    pid_t pid = gLastPid;
    if (pid <= 0) { [self.target _XCT_requestElementAtPoint:point reply:reply]; return; }
    Class elementClass = NSClassFromString(@"XCAccessibilityElement");
    NSString *attribute = [NSString stringWithFormat:@"hit:%.3f:%.3f", point.x, point.y];
    XSFetchFromAgent(self.target, pid, @[attribute], ^(NSDictionary *values, NSError *error) {
        id element = values[attribute];
        if ([element isKindOfClass:elementClass]) { reply(element, nil); return; }
        XSInfo(@"hit test at %@ found nothing in the app (%@ %@)", NSStringFromPoint(point), element, error);
        reply(nil, error ?: XSError(@"No element at point"));
    });
}

// Screenshots come from the app's own windows; the real screen shows the user's work, not the app.
- (void)_XCT_requestScreenshot:(id)request withReply:(void (^)(id, NSError *))reply {
    pid_t pid = gLastPid;
    if (pid <= 0) { reply(nil, XSError(@"No simulated application for the screenshot")); return; }
    CGRect rect = [[request valueForKey:@"rect"] rectValue];
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect)) rect = CGRectZero;
    NSString *shot = [NSString stringWithFormat:@"shot:%.3f:%.3f:%.3f:%.3f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
    XSFetchFromAgent(self.target, pid, @[@"scale", shot], ^(NSDictionary *values, NSError *error) {
        id value = values[shot];
        NSData *data = [value isKindOfClass:[NSString class]] ? [[NSData alloc] initWithBase64EncodedString:value options:0] : nil;
        if (error || !data) { XSInfo(@"screenshot failed: %@ %@", values[shot], error); reply(nil, error ?: XSError(@"Screenshot failed")); return; }
        double scale = [values[@"scale"] doubleValue] ?: 2;
        id encoding = [[NSClassFromString(@"XCTImageEncoding") alloc] initWithUniformTypeIdentifier:@"public.png" compressionQuality:1.0];
        id metadata = [[NSClassFromString(@"XCTImageMetadata") alloc] initWithScale:scale];
        reply([[NSClassFromString(@"XCTImage") alloc] initWithData:data encodedIn:encoding metadata:metadata], nil);
    });
}

#pragma mark Without Automation Mode (spike, XCUISIM_NO_AUTOMATION_MODE=1)

// testmanagerd turns macOS Automation Mode on for every session that asks for it or for accessibility.
// With the spike switch on, these requests are answered here; everything else is still forwarded and
// logged above, so a run shows what testmanagerd refuses without Automation Mode.
- (void)_XCT_enableAutomationModeWithReply:(void (^)(NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_enableAutomationModeWithReply:reply]; return; }
    XSInfo(@"no-automation-mode: enableAutomationMode answered locally");
    reply(nil);
}

- (void)_XCT_loadAccessibilityWithTimeout:(double)timeout reply:(void (^)(BOOL, NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_loadAccessibilityWithTimeout:timeout reply:reply]; return; }
    XSInfo(@"no-automation-mode: loadAccessibility answered locally");
    reply(YES, nil);
}

- (void)_XCT_registerForAXNotificationsForApplicationWithPID:(int)pid timeout:(double)timeout completion:(void (^)(BOOL, NSError *))completion {
    if (!gNoAutomationMode) { [self.target _XCT_registerForAXNotificationsForApplicationWithPID:pid timeout:timeout completion:completion]; return; }
    XSInfo(@"no-automation-mode: registerForAXNotifications pid %d answered locally", pid);
    completion(YES, nil);
}

- (void)_XCT_unregisterForAXNotificationsForApplicationWithPID:(int)pid {
    if (!gNoAutomationMode) { [self.target _XCT_unregisterForAXNotificationsForApplicationWithPID:pid]; return; }
}

- (void)_XCT_syncCrashReporterWithReply:(void (^)(BOOL, NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_syncCrashReporterWithReply:reply]; return; }
    reply(YES, nil);
}

// The element tree and attributes come from XCTest's in-app engine through the agent's port.
- (void)_XCT_fetchSnapshotForElement:(id)element attributes:(NSArray *)attributes parameters:(NSDictionary *)parameters
                               reply:(void (^)(id, NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_fetchSnapshotForElement:element attributes:attributes parameters:parameters reply:reply]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *request = [@{@"op": @"snapshot", @"element": element, @"attributes": attributes ?: @[]} mutableCopy];
        if (parameters) request[@"parameters"] = parameters;
        NSDictionary *answer = XSPortSend(request, 60);
        NSError *error = XSReplyError(answer);
        if (error) { XSInfo(@"snapshot failed: %@", error); reply(nil, error); return; }
        reply([[NSClassFromString(@"XCUIElementSnapshotRequestResult") alloc] initWithRootElementSnapshot:answer[@"result"] runtimeIssues:nil], nil);
    });
}

- (void)_XCT_fetchAttributes:(NSArray *)attributes forElement:(id)element reply:(void (^)(NSDictionary *, NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_fetchAttributes:attributes forElement:element reply:reply]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *answer = XSPortSend(@{@"op": @"attributes", @"element": element, @"attributes": attributes ?: @[]}, 30);
        NSError *error = XSReplyError(answer);
        if (error) XSInfo(@"attributes %@ failed: %@", attributes, error);
        reply(error ? nil : answer[@"result"], error);
    });
}

// testmanagerd calls the block when its accessibility observer sees the menu open; the agent counts
// NSMenuDidBeginTrackingNotification instead.
- (void)_XCT_performWhenMenuOpens:(id)element block:(void (^)(void))block {
    if (!gNoAutomationMode) { [self.target _XCT_performWhenMenuOpens:element block:block]; return; }
    // XCTest arms the wait and synthesizes the click that opens the menu right after it, so the menu
    // may already be open when the baseline is read: an open menu satisfies the wait as well.
    NSNumber *baseline = XSPortSend(@{@"op": @"menuOpenings"}, 5)[@"result"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 30;
        while (CFAbsoluteTimeGetCurrent() < deadline) {
            NSDictionary *now = XSPortSend(@{@"op": @"menuOpenings"}, 5);
            BOOL opened = baseline && [now[@"result"] unsignedLongLongValue] > baseline.unsignedLongLongValue;
            if (opened || [now[@"open"] boolValue]) { block(); return; }
            usleep(20000);
        }
        XSInfo(@"no menu opened within 30 s");
    });
}

- (void)_XCT_notifyWhenEventLoopIsIdleForApplicationWithPID:(int)pid reply:(void (^)(NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_notifyWhenEventLoopIsIdleForApplicationWithPID:pid reply:reply]; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ reply(XSReplyError(XSPortSend(@{@"op": @"idle"}, 70))); });
}

// Automatic screenshots would be taken from the real screen; offscreen runs set
// SystemAttachmentLifetime to keepNever, so this is only a guard.
- (void)_XCT_requestScreenshotAttachment:(id)request withReply:(void (^)(id, NSError *))reply {
    if (!gNoAutomationMode) { [self.target _XCT_requestScreenshotAttachment:request withReply:reply]; return; }
    reply(nil, XSError(@"Screenshots of the real screen are disabled offscreen"));
}

- (void)_XCT_requestCurrentKeyboardModifierFlagsWithReply:(void (^)(NSUInteger, NSError *))reply {
    reply(gModifierFlags, nil);
}

- (void)_XCT_requestElementsPotentiallyInterruptingElement:(id)element targetFrame:(CGRect)frame
                                  applicationIsForeground:(BOOL)foreground reply:(void (^)(NSArray *, NSError *))reply {
    // The simulated app is never covered by other processes' windows from its own point of view.
    reply(@[], nil);
}

@end

#pragma mark - Swizzles

static IMP gOriginalDaemonProxy;
static id XSDaemonProxy(id self, SEL _cmd) {
    id real = ((id (*)(id, SEL))gOriginalDaemonProxy)(self, _cmd);
    if (!real) return nil;
    static const void *key = &key;
    XCUISimDaemonProxy *wrapper = objc_getAssociatedObject(real, key);
    if (!wrapper) {
        wrapper = [XCUISimDaemonProxy alloc];
        wrapper.target = real;
        objc_setAssociatedObject(real, key, wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return wrapper;
}

// testmanagerd reports a launched-but-inactive app as running in the background. The app agent
// makes it behave as active in-process, so report it as foreground to XCUITest.
static void XSRecordPid(NSString *bundleID, pid_t pid) {
    if (!bundleID || !gSimulatedApps[bundleID] || pid <= 0) return;
    if (gSimulatedApps[bundleID].intValue != pid) XSInfo(@"tracking %@ pid %d", bundleID, pid);
    gSimulatedApps[bundleID] = @(pid);
    gLastPid = pid;
}

static IMP gOriginalStateUpdate;
static void XSApplicationDidUpdateState(id self, SEL _cmd, id snapshot) {
    NSString *bundleID = [snapshot bundleID];
    if ([snapshot runState] >= 2) XSRecordPid(bundleID, [snapshot processID]);
    if (bundleID && gSimulatedApps[bundleID] && [snapshot runState] == 3) {
        snapshot = [[[snapshot class] alloc] initWithBundleID:bundleID path:[snapshot path] runState:4
                                                    processID:[snapshot processID]
                                             activationPolicy:[snapshot activationPolicy]
                                                      eventID:((NSUInteger (*)(id, SEL))objc_msgSend)(snapshot, NSSelectorFromString(@"eventID"))
                                                  processName:[snapshot processName]];
    }
    ((void (*)(id, SEL, id))gOriginalStateUpdate)(self, _cmd, snapshot);
}

static IMP gOriginalPidUpdate;
static void XSApplicationDidUpdatePID(id self, SEL _cmd, NSString *bundleID, pid_t pid, NSUInteger state) {
    if (state >= 2) XSRecordPid(bundleID, pid);
    if (bundleID && gSimulatedApps[bundleID] && state == 3) state = 4;
    ((void (*)(id, SEL, NSString *, pid_t, NSUInteger))gOriginalPidUpdate)(self, _cmd, bundleID, pid, state);
}

// XCUIApplication launches through the IDE (xcodebuild) when one is attached, otherwise through
// testmanagerd. Both paths get the agent switch and mark the bundle as simulated; the IDE launch
// does not activate the app (activation is a separate setFrontProcess call, handled above).
static IMP gOriginalLaunchUsingXcode, gOriginalLaunchUsingPlatform;
static NSDictionary *XSSimulatedEnvironment(id impl, NSDictionary *environment) {
    NSString *bundleID = [impl valueForKey:@"bundleID"];
    if (bundleID) {
        dispatch_sync(XSQueue(), ^{ if (!gSimulatedApps[bundleID]) gSimulatedApps[bundleID] = @0; });
    }
    NSMutableDictionary *env = [environment mutableCopy] ?: [NSMutableDictionary dictionary];
    env[@"XCUISIM_ENABLED"] = @"1";
    for (NSString *key in NSProcessInfo.processInfo.environment) {
        if ([key hasPrefix:@"XCUISIM_APP_"]) env[[key stringByReplacingOccurrencesOfString:@"XCUISIM_APP_" withString:@"XCUISIM_"]] = NSProcessInfo.processInfo.environment[key];
    }
    return env;
}
static void XSLaunchUsingXcode(id self, SEL _cmd, NSArray *arguments, NSDictionary *environment, NSURL *url) {
    XSInfo(@"IDE launch of %@ with the agent enabled", [self valueForKey:@"bundleID"]);
    ((void (*)(id, SEL, NSArray *, NSDictionary *, NSURL *))gOriginalLaunchUsingXcode)(self, _cmd, arguments, XSSimulatedEnvironment(self, environment), url);
}
static void XSLaunchUsingPlatform(id self, SEL _cmd, NSArray *arguments, NSDictionary *environment, NSURL *url) {
    XSInfo(@"platform launch of %@ with the agent enabled", [self valueForKey:@"bundleID"]);
    ((void (*)(id, SEL, NSArray *, NSDictionary *, NSURL *))gOriginalLaunchUsingPlatform)(self, _cmd, arguments, XSSimulatedEnvironment(self, environment), url);
}

// Without Automation Mode the in-app automation session (brokered by testmanagerd, which turns
// Automation Mode on for it) is declined; XCTest then uses the snapshot path the shim answers.
static void XSUnsupportedBundleIdentifiers(id self, SEL _cmd, void (^reply)(NSSet *, NSError *)) {
    __block NSSet *ids;
    dispatch_sync(XSQueue(), ^{ ids = [NSSet setWithArray:gSimulatedApps.allKeys]; });
    XSInfo(@"no-automation-mode: in-app automation sessions declined for %@", ids);
    reply(ids, nil);
}
static void XSRequestAutomationSession(id self, SEL _cmd, int pid, NSString *path, void (^reply)(id, NSError *)) {
    XSInfo(@"no-automation-mode: in-app automation session for pid %d declined", pid);
    reply(nil, XSError(@"In-app automation sessions are not used without Automation Mode"));
}
static BOOL XSEnableAutomationModeWithError(id self, SEL _cmd, NSError **error) {
    XSInfo(@"no-automation-mode: enableAutomationModeWithError answered locally");
    return YES;
}

static BOOL XSSwizzle(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_setImplementation(method, replacement);
    return YES;
}

static void XSInstallIfPossible(void) {
    static BOOL installedSession;
    Class session = NSClassFromString(@"XCTRunnerDaemonSession");
    if (!session || installedSession) return;
    // The state-update methods come from an XCUIAutomation category; wait until it is loaded.
    if (!class_getInstanceMethod(session, @selector(_XCT_applicationDidUpdateState:))) return;
    installedSession = YES;
    BOOL ok = XSSwizzle(session, NSSelectorFromString(@"daemonProxy"), (IMP)XSDaemonProxy, &gOriginalDaemonProxy);
    ok &= XSSwizzle(session, NSSelectorFromString(@"_XCT_applicationDidUpdateState:"), (IMP)XSApplicationDidUpdateState, &gOriginalStateUpdate);
    ok &= XSSwizzle(session, NSSelectorFromString(@"_XCT_applicationWithBundleID:didUpdatePID:andState:"), (IMP)XSApplicationDidUpdatePID, &gOriginalPidUpdate);
    if (gNoAutomationMode) {
        IMP unused;
        ok &= XSSwizzle(session, NSSelectorFromString(@"requestUnsupportedBundleIdentifiersForAutomationSessions:"), (IMP)XSUnsupportedBundleIdentifiers, &unused);
        ok &= XSSwizzle(session, NSSelectorFromString(@"requestAutomationSessionForTestTargetWithPID:preferredBackendPath:reply:"), (IMP)XSRequestAutomationSession, &unused);
        ok &= XSSwizzle(session, NSSelectorFromString(@"enableAutomationModeWithError:"), (IMP)XSEnableAutomationModeWithError, &unused);
    }
    XSInfo(@"installed on XCTRunnerDaemonSession: %@", ok ? @"yes" : @"PARTIAL");
}

// Guards for runner-side paths that would activate a process directly through LaunchServices
// instead of going through testmanagerd. They are not expected to run on a local Mac; if they
// do, the activation is refused and logged.
static void XSRefusedFrontProcessCompletion(id self, SEL _cmd, pid_t pid, void (^completion)(NSError *)) {
    XSInfo(@"refused runner-side activation of pid %d through %@", pid, NSStringFromClass([self class]));
    if (completion) completion(XSError(@"Runner-side activation is disabled by XCUISim"));
}
static BOOL XSRefusedFrontProcessError(id self, SEL _cmd, pid_t pid, NSError **error) {
    XSInfo(@"refused runner-side activation of pid %d through %@", pid, NSStringFromClass([self class]));
    if (error) *error = XSError(@"Runner-side activation is disabled by XCUISim");
    return NO;
}

// The launch hooks are what make a run simulated: without them the app starts without the agent,
// shows real windows and is never reported as foreground. They are installed as soon as
// XCUIApplicationImpl is loaded and do not depend on any guard class, because the guard classes
// change between Xcode releases (Xcode 27.2 removed XCUILaunchServicesMonitor; its successor,
// XCUIPlatformApplicationManager, forwards setFrontProcess to the daemon session, which is the
// path the proxy simulates, so it must not be refused).
static void XSInstallLaunchHooksIfPossible(void) {
    static BOOL attempted;
    Class impl = NSClassFromString(@"XCUIApplicationImpl");
    if (attempted || !impl) return;
    attempted = YES;
    BOOL ok = XSSwizzle(impl, NSSelectorFromString(@"_launchUsingXcodeWithArguments:environment:launchURL:"), (IMP)XSLaunchUsingXcode, &gOriginalLaunchUsingXcode);
    ok &= XSSwizzle(impl, NSSelectorFromString(@"_launchUsingPlatformWithArguments:environment:launchURL:"), (IMP)XSLaunchUsingPlatform, &gOriginalLaunchUsingPlatform);
    gLaunchHooksInstalled = ok;
    if (ok) XSInfo(@"installed launch hooks on XCUIApplicationImpl: yes");
    else XSInfo(@"ERROR: launch hooks on XCUIApplicationImpl NOT installed (unsupported Xcode): apps launch without the agent and cannot be activated");
}

static void XSInstallGuardsIfPossible(void) {
    static BOOL installed;
    Class framework = NSClassFromString(@"XCUILaunchServicesFramework");
    if (installed || !framework) return;
    installed = YES;
    IMP unused;
    NSMutableArray *guarded = [NSMutableArray array];
    if (XSSwizzle(framework, NSSelectorFromString(@"setFrontProcess:error:"), (IMP)XSRefusedFrontProcessError, &unused))
        [guarded addObject:@"XCUILaunchServicesFramework"];
    // Xcode 27.1 and earlier only; a direct LaunchServices path there.
    Class monitor = NSClassFromString(@"XCUILaunchServicesMonitor");
    if (monitor && XSSwizzle(monitor, NSSelectorFromString(@"setFrontProcess:completion:"), (IMP)XSRefusedFrontProcessCompletion, &unused))
        [guarded addObject:@"XCUILaunchServicesMonitor"];
    XSInfo(@"installed LaunchServices activation guards: %@", guarded.count ? [guarded componentsJoinedByString:@", "] : @"NONE");
}

static void XSImageAdded(const struct mach_header *header, intptr_t slide) {
    XSInstallIfPossible();
    XSInstallLaunchHooksIfPossible();
    XSInstallGuardsIfPossible();
}

__attribute__((constructor)) static void XCUISimRunnerShimInit(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    gAgentPath = env[@"XCUISIM_AGENT_PATH"];
    if (!gAgentPath.length) return;
    gLogEvents = [env[@"XCUISIM_LOG_EVENTS"] isEqualToString:@"1"];
    gDropEvents = [env[@"XCUISIM_DROP_EVENTS"] isEqualToString:@"1"];
    gNoAutomationMode = [env[@"XCUISIM_NO_AUTOMATION_MODE"] isEqualToString:@"1"];
    gPortName = env[@"XCUISIM_PORT"];
    gSimulatedApps = [NSMutableDictionary dictionary];
    XSInfo(@"runner shim loaded in %@ (agent %@)", NSProcessInfo.processInfo.processName, gAgentPath);
    // Since Xcode 27.2, -[XCElementSnapshot displayID] of a snapshot without a display (the agent's
    // snapshots come from the app's local engine) asks CoreGraphics in the runner
    // (XCTDisplayInterface -> CGGetDisplaysWithRect), and SkyLight asserts (CGS_REQUIRE_INIT) in a
    // process that never opened its window-server session: the LSBackgroundOnly runner aborts at the
    // first synthesized event. Opening the session here is only a connection: no window, activation
    // or event. (Xcode 27.1 resolved displays through a DisplayManager that did not require it.)
    XSInfo(@"runner CoreGraphics session opened (main display %u)", CGMainDisplayID());
    _dyld_register_func_for_add_image(XSImageAdded);
}
