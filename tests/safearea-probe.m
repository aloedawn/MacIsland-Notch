#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdio.h>
#import "notch-layout.h"

bool MacIslandIsMenuBarAgent(void) { return false; }
BOOL MacIslandShortHostAvailable(void) { return YES; }
extern BOOL MacIslandInstallSceneSettingsHooksForTesting(void);

@interface TestDisplayIdentity : NSObject
@property(nonatomic) uint32_t displayID;
@end
@implementation TestDisplayIdentity
@end

@interface TestFakeScreen : NSObject
@property(nonatomic) NSRect frame;
@property(nonatomic) NSEdgeInsets safeAreaInsets;
@property(nonatomic, strong) NSValue *auxLeft;
@property(nonatomic, strong) NSValue *auxRight;
@property(nonatomic, strong) NSDictionary *deviceDescription;
@end
@implementation TestFakeScreen
- (NSRect)auxiliaryTopLeftArea { return _auxLeft ? _auxLeft.rectValue : NSZeroRect; }
- (NSRect)auxiliaryTopRightArea { return _auxRight ? _auxRight.rectValue : NSZeroRect; }
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(auxiliaryTopLeftArea)) return _auxLeft != nil;
    if (aSelector == @selector(auxiliaryTopRightArea)) return _auxRight != nil;
    return [super respondsToSelector:aSelector];
}
@end

static NSArray *fakeScreens;
@interface NSScreen (MacIslandTestScreens)
@end
@implementation NSScreen (MacIslandTestScreens)
+ (NSArray<NSScreen *> *)mi_testScreens {
    return (NSArray<NSScreen *> *)fakeScreens;
}
@end

@protocol MacIslandTestSettings <NSObject>
- (id)elementViewLayoutMargins;
- (id)elementViewMinimumSize;
- (id)elementViewMaximumSize;
- (id)integratedObstructionRect;
- (id)integratedObstructionRectCoordinateSpace;
- (id)integratedObstructionCornerRadii;
- (id)hostedLayoutMargins;
- (id)hostedMinimumSize;
- (id)hostedMaximumSize;
- (void)setClientIdentifier:(id)v;
- (void)setElementKindIdentifier:(id)v;
- (void)setIntegratedLayoutMode:(id)v;
- (void)setIntegratedObstructionLocation:(id)v;
- (void)setElementViewLayoutMargins:(id)v;
- (void)setElementViewMinimumSize:(id)v;
- (void)setElementViewMaximumSize:(id)v;
- (void)setIntegratedObstructionRect:(id)v;
- (void)setIntegratedObstructionRectCoordinateSpace:(id)v;
- (void)setIntegratedObstructionCornerRadii:(id)v;
- (void)setHostedLayoutMargins:(id)v;
- (void)setHostedMinimumSize:(id)v;
- (void)setHostedMaximumSize:(id)v;
- (void)setHostedIntegratedObstructionRect:(id)v;
- (void)setHostedIntegratedObstructionRectCoordinateSpace:(id)v;
- (void)setDisplayConfiguration:(id)v;
@end

@protocol MacIslandTestCornerRadii <NSObject>
- (CGFloat)topLeft;
- (CGFloat)topRight;
@end

static id displayConfigWithID(uint32_t displayID) {
    static Class subclass;
    if (!subclass) {
        Class base = NSClassFromString(@"FBSDisplayConfiguration");
        subclass = objc_allocateClassPair(base, "MacIslandTestDisplayConfiguration", 0);
        IMP identityIMP = imp_implementationWithBlock(^id(id self) {
            return objc_getAssociatedObject(self, @selector(identity));
        });
        class_addMethod(subclass, @selector(identity), identityIMP, "@16@0:8");
        IMP copyIMP = imp_implementationWithBlock(^id(id self, NSZone *__unused zone) {
            return self;
        });
        class_addMethod(subclass, @selector(copyWithZone:), copyIMP, "@24@0:8^{_NSZone=}16");
        objc_registerClassPair(subclass);
    }
    TestDisplayIdentity *identity = [TestDisplayIdentity new];
    identity.displayID = displayID;
    id config = class_createInstance(subclass, 0);
    objc_setAssociatedObject(config, @selector(identity), identity, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return config;
}

static NSData *encodeJSON(NSDictionary *dict) {
    return [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingSortedKeys error:NULL];
}

static NSDictionary *decodeJSON(NSData *data) {
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

int main(void) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/ElementRegistryFoundation.framework/ElementRegistryFoundation", RTLD_NOW) ||
            !dlopen("/System/Library/PrivateFrameworks/MenuBarClient.framework/MenuBarClient", RTLD_NOW)) {
            fprintf(stderr, "Required scene-extension private frameworks unavailable\n");
            return 1;
        }

        TestFakeScreen *notched = [TestFakeScreen new];
        notched.frame = NSMakeRect(0, 0, 1512, 982);
        notched.safeAreaInsets = NSEdgeInsetsMake(32, 0, 0, 0);
        notched.auxLeft = [NSValue valueWithRect:NSMakeRect(0, 950, 666, 32)];
        notched.auxRight = [NSValue valueWithRect:NSMakeRect(846, 950, 666, 32)];
        notched.deviceDescription = @{@"NSScreenNumber": @101};

        TestFakeScreen *external = [TestFakeScreen new];
        external.frame = NSMakeRect(1512, 0, 2560, 1440);
        external.safeAreaInsets = NSEdgeInsetsMake(0, 0, 0, 0);
        external.deviceDescription = @{@"NSScreenNumber": @202};

        fakeScreens = @[notched, external];
        Method realScreens = class_getClassMethod(NSScreen.class, @selector(screens));
        Method mockScreens = class_getClassMethod(NSScreen.class, @selector(mi_testScreens));
        method_exchangeImplementations(realScreens, mockScreens);

        if (!MacIslandInstallSceneSettingsHooksForTesting()) {
            fprintf(stderr, "failed to install scene settings hooks\n");
            return 1;
        }

        Class mutableClass = NSClassFromString(@"FBSMutableSceneSettings");
        NSData *nativeMargins = encodeJSON(@{
            @"top": @12, @"leading": @8, @"bottom": @12, @"trailing": @8
        });
        NSValue *nativeMin = [NSValue valueWithSize:NSMakeSize(260, 32)];
        NSValue *nativeMax = [NSValue valueWithSize:NSMakeSize(260, 94)];
        NSValue *nativeSpace = [NSValue valueWithSize:NSMakeSize(454, 72)];
        NSValue *nativeObs = [NSValue valueWithRect:NSMakeRect(46, 0, 180, 32)];

        // 1. Apply notched B안 wing policy on built-in display 101 (stays at y=0, no short-host sentinel).
        NSObject<MacIslandTestSettings> *m1 = [mutableClass new];
        [m1 setClientIdentifier:@"com.apple.ClockAngel"];
        [m1 setElementKindIdentifier:[@"\"timer\"" dataUsingEncoding:NSUTF8StringEncoding]];
        [m1 setIntegratedLayoutMode:@3];
        [m1 setDisplayConfiguration:displayConfigWithID(101)];
        [m1 setElementViewLayoutMargins:nativeMargins];
        [m1 setElementViewMinimumSize:nativeMin];
        [m1 setElementViewMaximumSize:nativeMax];
        [m1 setIntegratedObstructionRectCoordinateSpace:nativeSpace];
        [m1 setIntegratedObstructionRect:nativeObs];

        NSRect publishedObs = [[m1 integratedObstructionRect] rectValue];
        if (MacIslandIsShortObstructionSentinel(publishedObs, 32) ||
            fabs(publishedObs.size.width - 182.0) > 0.001 ||
            fabs(publishedObs.size.height - 34.0) > 0.001) {
            fprintf(stderr, "expected canonical 182x34 obstruction in B안, got (%.1f, %.1f, %.1f, %.1f)\n",
                    publishedObs.origin.x, publishedObs.origin.y, publishedObs.size.width, publishedObs.size.height);
            return 1;
        }
        id<MacIslandTestCornerRadii> corners = [m1 integratedObstructionCornerRadii];
        if (!corners || fabs([corners topLeft]) > 0.001 || fabs([corners topRight]) > 0.001) {
            fprintf(stderr, "expected rectangular 0-radius corners on notched display\n");
            return 1;
        }
        NSDictionary *patchedMargins = decodeJSON([m1 elementViewLayoutMargins]);
        if (fabs([patchedMargins[@"leading"] doubleValue] - 12.0) > 0.001 ||
            fabs([patchedMargins[@"trailing"] doubleValue] - 12.0) > 0.001 ||
            fabs([patchedMargins[@"top"] doubleValue] - 40.0) > 0.001) {
            fprintf(stderr, "expected B안 margins (top=40, leading=12, trailing=12), got %s\n",
                    patchedMargins.description.UTF8String);
            return 1;
        }
        NSSize patchedMin = [[m1 elementViewMinimumSize] sizeValue];
        NSSize patchedMax = [[m1 elementViewMaximumSize] sizeValue];
        if (fabs(patchedMin.width - 344.0) > 0.001 || patchedMax.width < 464.0 - 0.001) {
            fprintf(stderr, "expected B안 min.w=344 and max.w>=464, got min=%.1f max=%.1f\n",
                    patchedMin.width, patchedMax.width);
            return 1;
        }

        // 2. Freeze via real FBSSceneSettings copy -> mutableCopy (wiping object-level associated state),
        // then move the scene to external display 202 and verify full restoration.
        NSObject *frozen = [m1 copy];
        NSObject<MacIslandTestSettings> *m2 = [frozen mutableCopy];
        [m2 setDisplayConfiguration:displayConfigWithID(202)];

        if (![[m2 elementViewLayoutMargins] isEqualToData:nativeMargins]) {
            fprintf(stderr, "failed to restore native margins after mutableCopy -> external display\n");
            return 1;
        }
        if (!NSEqualSizes([[m2 elementViewMinimumSize] sizeValue], nativeMin.sizeValue) ||
            !NSEqualSizes([[m2 elementViewMaximumSize] sizeValue], nativeMax.sizeValue)) {
            fprintf(stderr, "failed to restore native min/max sizes after mutableCopy\n");
            return 1;
        }
        if (!NSEqualRects([[m2 integratedObstructionRect] rectValue], nativeObs.rectValue)) {
            fprintf(stderr, "failed to restore native obstruction rect after mutableCopy\n");
            return 1;
        }
        if ([m2 integratedObstructionCornerRadii] != nil) {
            fprintf(stderr, "leaked rectangular corners after mutableCopy onto external display\n");
            return 1;
        }

        // 3. Explicit unknown displayID (e.g. disconnected/external ID 999) must not
        // fall back to the built-in notched display.
        id<MacIslandTestSettings> m3 = [mutableClass new];
        [m3 setDisplayConfiguration:displayConfigWithID(999)];
        [m3 setElementViewLayoutMargins:nativeMargins];
        [m3 setElementViewMinimumSize:nativeMin];
        [m3 setElementViewMaximumSize:nativeMax];
        [m3 setIntegratedObstructionRectCoordinateSpace:nativeSpace];
        [m3 setIntegratedObstructionRect:nativeObs];
        if (![[m3 elementViewLayoutMargins] isEqualToData:nativeMargins] ||
            [m3 integratedObstructionCornerRadii] != nil) {
            fprintf(stderr, "unknown explicit displayID unexpectedly applied notched policy\n");
            return 1;
        }

        // 4. Verify non-finite maximum sizes serialize safely when audit telemetry is enabled.
        id<MacIslandTestSettings> m4 = [mutableClass new];
        [m4 setClientIdentifier:@"com.apple.MediaRemoteUIService"];
        [m4 setIntegratedLayoutMode:@2];
        [m4 setDisplayConfiguration:displayConfigWithID(101)];
        [m4 setElementViewLayoutMargins:nativeMargins];
        [m4 setElementViewMinimumSize:[NSValue valueWithSize:NSMakeSize(28, 28)]];
        [m4 setElementViewMaximumSize:[NSValue valueWithSize:NSMakeSize(INFINITY, 38)]];

        // 5. Detached minimal/mitosis scene (noObstruction) must remain 100% unpatched
        // both when Location is set before layout/obstruction and when set afterward.
        NSData *detachedMargins = encodeJSON(@{
            @"top": @3, @"leading": @3, @"bottom": @3, @"trailing": @3
        });
        NSData *noObstructionLoc = encodeJSON(@{@"noObstruction": @{}});
        NSValue *detachedMin = [NSValue valueWithSize:NSMakeSize(0, 32)];
        NSValue *detachedMax = [NSValue valueWithSize:NSMakeSize(45, 32)];
        NSValue *stalePillObs = [NSValue valueWithRect:NSMakeRect(0, 0, 180, 32)];

        id<MacIslandTestSettings> m5 = [mutableClass new];
        [m5 setClientIdentifier:@"com.apple.MediaRemoteUIService"];
        [m5 setIntegratedLayoutMode:@1];
        [m5 setDisplayConfiguration:displayConfigWithID(101)];
        [m5 setIntegratedObstructionLocation:noObstructionLoc];
        [m5 setElementViewLayoutMargins:detachedMargins];
        [m5 setElementViewMinimumSize:detachedMin];
        [m5 setElementViewMaximumSize:detachedMax];
        [m5 setIntegratedObstructionRect:stalePillObs];
        if (![[m5 elementViewLayoutMargins] isEqualToData:detachedMargins] ||
            !NSEqualSizes([[m5 elementViewMaximumSize] sizeValue], detachedMax.sizeValue) ||
            !NSEqualRects([[m5 integratedObstructionRect] rectValue], stalePillObs.rectValue) ||
            [m5 integratedObstructionCornerRadii] != nil) {
            fprintf(stderr, "detached noObstruction scene was unexpectedly patched\n");
            return 1;
        }

        id<MacIslandTestSettings> m6 = [mutableClass new];
        [m6 setDisplayConfiguration:displayConfigWithID(101)];
        [m6 setElementViewLayoutMargins:detachedMargins];
        [m6 setElementViewMinimumSize:detachedMin];
        [m6 setElementViewMaximumSize:detachedMax];
        [m6 setIntegratedObstructionRect:stalePillObs];
        [m6 setIntegratedObstructionLocation:noObstructionLoc];
        if (![[m6 elementViewLayoutMargins] isEqualToData:detachedMargins] ||
            !NSEqualSizes([[m6 elementViewMaximumSize] sizeValue], detachedMax.sizeValue) ||
            !NSEqualRects([[m6 integratedObstructionRect] rectValue], stalePillObs.rectValue) ||
            [m6 integratedObstructionCornerRadii] != nil) {
            fprintf(stderr, "late noObstruction location failed to restore native settings\n");
            return 1;
        }

        // 6. Compact leading & trailing wing scenes without obstructionSpace must get
        // steady 12/6 and 6/12 margins with zero transition jitter.
        NSData *compactLeadMargins = encodeJSON(@{
            @"top": @3, @"leading": @3, @"bottom": @3, @"trailing": @0
        });
        NSData *compactTrailMargins = encodeJSON(@{
            @"top": @3, @"leading": @0, @"bottom": @3, @"trailing": @3
        });
        NSValue *compactMin = [NSValue valueWithSize:NSMakeSize(0, 32)];
        NSValue *compactMax = [NSValue valueWithSize:NSMakeSize(112, 32)];

        id<MacIslandTestSettings> m7 = [mutableClass new];
        [m7 setClientIdentifier:@"com.apple.MediaRemoteUIService"];
        [m7 setIntegratedLayoutMode:@2];
        [m7 setDisplayConfiguration:displayConfigWithID(101)];
        [m7 setElementViewLayoutMargins:compactLeadMargins];
        [m7 setElementViewMinimumSize:compactMin];
        [m7 setElementViewMaximumSize:compactMax];
        [m7 setIntegratedObstructionRect:stalePillObs];
        NSDictionary *leadAfter = decodeJSON([m7 elementViewLayoutMargins]);
        if (fabs([leadAfter[@"leading"] doubleValue] - 12.0) > 0.001 ||
            fabs([leadAfter[@"trailing"] doubleValue] - 6.0) > 0.001 ||
            fabs([[m7 elementViewMaximumSize] sizeValue].width - 127.0) > 0.001) {
            fprintf(stderr, "compact leading jitter fix failed: margins=%s max=%.1f\n",
                    leadAfter.description.UTF8String, [[m7 elementViewMaximumSize] sizeValue].width);
            return 1;
        }

        id<MacIslandTestSettings> m8 = [mutableClass new];
        [m8 setClientIdentifier:@"com.apple.ClockAngel"];
        [m8 setIntegratedLayoutMode:@2];
        [m8 setDisplayConfiguration:displayConfigWithID(101)];
        [m8 setElementViewLayoutMargins:compactTrailMargins];
        [m8 setElementViewMinimumSize:compactMin];
        [m8 setElementViewMaximumSize:compactMax];
        [m8 setIntegratedObstructionRect:stalePillObs];
        NSDictionary *trailAfter = decodeJSON([m8 elementViewLayoutMargins]);
        if (fabs([trailAfter[@"leading"] doubleValue] - 6.0) > 0.001 ||
            fabs([trailAfter[@"trailing"] doubleValue] - 12.0) > 0.001 ||
            fabs([[m8 elementViewMaximumSize] sizeValue].width - 127.0) > 0.001) {
            fprintf(stderr, "compact trailing jitter fix failed: margins=%s max=%.1f\n",
                    trailAfter.description.UTF8String, [[m8 elementViewMaximumSize] sizeValue].width);
            return 1;
        }

        // 7. Hosted system banners (Volume / Brightness, family 1) must keep their snug native width.
        NSData *hostedMargins = encodeJSON(@{
            @"top": @8, @"leading": @11, @"bottom": @8, @"trailing": @11
        });
        id<MacIslandTestSettings> m9 = [mutableClass new];
        [m9 setClientIdentifier:@"com.apple.controlcenter"];
        [m9 setDisplayConfiguration:displayConfigWithID(101)];
        [m9 setHostedLayoutMargins:hostedMargins];
        [m9 setHostedMinimumSize:[NSValue valueWithSize:NSMakeSize(220, 32)]];
        [m9 setHostedMaximumSize:[NSValue valueWithSize:NSMakeSize(408, 982)]];
        [m9 setHostedIntegratedObstructionRectCoordinateSpace:[NSValue valueWithSize:NSMakeSize(309, 84)]];
        [m9 setHostedIntegratedObstructionRect:[NSValue valueWithRect:NSMakeRect(64.5, 0, 180, 32)]];
        if (fabs([[m9 hostedMinimumSize] sizeValue].width - 222.0) > 0.001) {
            fprintf(stderr, "hosted banner width unexpectedly inflated to %.1f\n",
                    [[m9 hostedMinimumSize] sizeValue].width);
            return 1;
        }

        printf("safearea=ok canonical=(%.1f,%.1f,%.0fx%.0f) restored_corners=nil\n",
               publishedObs.origin.x, publishedObs.origin.y, publishedObs.size.width, publishedObs.size.height);
        return 0;
    }
}
