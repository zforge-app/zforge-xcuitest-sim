#import <AppKit/AppKit.h>
#include <dlfcn.h>
extern AXUIElementRef NSAccessibilityCreateAXUIElementRef(id element);
@interface NSObject (P)
- (id)initForLocalAccess; - (id)initWithAccessibilityFramework:(id)f;
- (id)snapshotForElement:(id)e attributes:(id)a parameters:(id)p timeoutControls:(id)t error:(NSError **)err;
+ (id)elementWithProcessIdentifier:(pid_t)pid; + (id)elementWithAXUIElement:(AXUIElementRef)r;
- (NSArray *)children; - (NSString *)identifier; - (id)accessibilityElement; - (NSUInteger)elementType;
@end
FILE *gOut;
static id find(id s, NSString *ident) { if ([[s identifier] isEqual:ident]) return s; for (id c in [s children]) { id f = find(c, ident); if (f) return f; } return nil; }
int main(void) { @autoreleasepool {
    gOut = fopen("/tmp/xa-probe/hit-out.txt", "w"); setvbuf(gOut, NULL, _IONBF, 0);
    dlopen("/System/Library/PrivateFrameworks/XCTAutomationSupport.framework/Versions/A/XCTAutomationSupport", RTLD_NOW);
    NSApplication *app = NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(-20000, -20000, 300, 200) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    NSButton *b = [NSButton buttonWithTitle:@"Press me" target:nil action:nil]; b.frame = NSMakeRect(20, 20, 120, 30); b.identifier = @"probe-button";
    NSTextField *t = [NSTextField labelWithString:@"Label text"]; t.frame = NSMakeRect(20, 80, 200, 24); t.identifier = @"probe-label";
    [w.contentView addSubview:b]; [w.contentView addSubview:t]; [w orderFrontRegardless];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id fw = [[NSClassFromString(@"XCTAccessibilityFramework") alloc] initForLocalAccess];
        id session = [[NSClassFromString(@"XCTAutomationSession") alloc] initWithAccessibilityFramework:fw];
        NSError *err;
        id snap = [session snapshotForElement:[NSClassFromString(@"XCAccessibilityElement") elementWithProcessIdentifier:getpid()] attributes:@[@"AXIdentifier", @"XC_kAXXCAttributeElementType", @"XC_kAXXCAttributeChildren"] parameters:@{} timeoutControls:nil error:&err];
        for (NSString *ident in @[@"probe-button", @"probe-label"]) {
            id node = find(snap, ident);
            id tree = [node accessibilityElement];
            NSView *view = [ident isEqual:@"probe-button"] ? b : t;
            for (id obj in @[view, [view accessibilityHitTest:NSMakePoint(NSMidX(view.frame) + w.frame.origin.x, NSMidY(view.frame) + w.frame.origin.y)] ?: [NSNull null]]) {
                if (obj == [NSNull null]) continue;
                AXUIElementRef ref = NSAccessibilityCreateAXUIElementRef(obj);
                id mine = [NSClassFromString(@"XCAccessibilityElement") elementWithAXUIElement:ref];
                fprintf(gOut, "%s obj=%s\n  tree=%s\n  mine=%s\n  equal=%d\n", ident.UTF8String, [[obj className] UTF8String], [[tree description] UTF8String], [[mine description] UTF8String], [tree isEqual:mine]);
            }
        }
        exit(0);
    });
    [app run];
}}
