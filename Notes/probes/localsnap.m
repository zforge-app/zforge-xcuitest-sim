#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
@interface NSObject (P)
- (id)initForLocalAccess;
- (id)initWithAccessibilityFramework:(id)f;
- (id)snapshotForElement:(id)e attributes:(id)a parameters:(id)p timeoutControls:(id)t error:(NSError **)err;
+ (id)elementWithProcessIdentifier:(pid_t)pid;
- (NSArray *)children; - (NSString *)identifier; - (NSUInteger)elementType; - (NSString *)title; - (CGRect)frame;
@end
extern FILE *gOut; static void dump(id s, int depth, int *count) {
    (*count)++;
    if (depth < 6) fprintf(gOut, "%*stype=%lu id=%s title=%s frame=%s\n", depth*2, "", (unsigned long)[s elementType], [[s identifier] UTF8String] ?: "", [[s title] UTF8String] ?: "", NSStringFromRect([s frame]).UTF8String);
    for (id c in [s children]) dump(c, depth + 1, count);
}
FILE *gOut; int main(void) { gOut = fopen("/tmp/xa-probe/app-out.txt", "w"); setvbuf(gOut, NULL, _IONBF, 0);
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/XCTAutomationSupport.framework/Versions/A/XCTAutomationSupport", RTLD_NOW)) { fprintf(gOut, "dlopen %s\n", dlerror()); return 1; }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 300, 200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        w.title = @"Probe window";
        NSButton *b = [NSButton buttonWithTitle:@"Press me" target:nil action:nil]; b.frame = NSMakeRect(20, 20, 120, 30); b.identifier = @"probe-button";
        NSTextField *t = [NSTextField textFieldWithString:@"hello"]; t.frame = NSMakeRect(20, 80, 200, 24); t.identifier = @"probe-field";
        [w.contentView addSubview:b]; [w.contentView addSubview:t];
        [w orderFrontRegardless]; [w setFrameOrigin:NSMakePoint(-10000, -10000)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(gOut, "AXIsProcessTrusted=%d\n", AXIsProcessTrusted());
            id fw = [[NSClassFromString(@"XCTAccessibilityFramework") alloc] initForLocalAccess];
            id session = [[NSClassFromString(@"XCTAutomationSession") alloc] initWithAccessibilityFramework:fw];
            id element = [NSClassFromString(@"XCAccessibilityElement") elementWithProcessIdentifier:getpid()];
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                NSError *err = nil;
                id snap = [session snapshotForElement:element attributes:@[@"XC_kAXXCAttributeElementType", @"AXIdentifier", @"AXTitle", @"AXFrame", @"AXRole", @"AXValue", @"XC_kAXXCAttributeChildren"] parameters:@{} timeoutControls:nil error:&err];
                dispatch_async(dispatch_get_main_queue(), ^{
                    fprintf(gOut, "snapshot=%s error=%s\n", [[snap className] UTF8String] ?: "nil", err.description.UTF8String ?: "none");
                    if (snap) { id root = [snap respondsToSelector:@selector(children)] ? snap : [snap valueForKey:@"elementSnapshot"]; int count = 0; dump(root, 0, &count); fprintf(gOut, "nodes=%d\n", count); }
                    exit(0);
                });
            });
        });
        [app run];
    }
}
