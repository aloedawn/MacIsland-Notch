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
extern void MacIslandSyncHostedSceneMaximumContentWidthForTesting(NSUserDefaults *defaults);

@interface TestDefaultsObserver : NSObject
@property(nonatomic) NSUInteger changeCount;
@property(nonatomic) double lastObservedWidth;
@end
@implementation TestDefaultsObserver
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)__unused change
                       context:(void *)__unused context {
    _changeCount++;
    if ([object isKindOfClass:NSUserDefaults.class] && keyPath) {
        _lastObservedWidth = [(NSUserDefaults *)object doubleForKey:keyPath];
    }
}
@end

@protocol MacIslandSuiteDefaultsInit <NSObject>
- (instancetype)_initWithSuiteName:(NSString *)suite container:(NSURL *)container;
@end

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
- (NSData *)metrics;
- (id)metricsRequest;
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
- (void)setMetrics:(NSData *)v;
- (void)setMetricsRequest:(id)v;
- (void)setDisplayConfiguration:(id)v;
@end

@protocol MacIslandTestSizeDim <NSObject>
- (instancetype)initWithMinimum:(double)min maximum:(double)max type:(NSInteger)type;
- (double)minimum;
- (double)maximum;
- (NSInteger)type;
@end

@protocol MacIslandTestEdgeInsets <NSObject>
- (instancetype)initWithTop:(double)t leading:(double)l bottom:(double)b trailing:(double)tr;
- (double)leading;
- (double)trailing;
@end

@protocol MacIslandTestItemMetrics <NSObject>
- (instancetype)initWithWidth:(id)w height:(id)h cornerRadius:(double)cr edgeInsets:(id)ei clipMargin:(double)cm scaleFactor:(double)sf;
- (id<MacIslandTestSizeDim>)widthRequest;
- (id<MacIslandTestSizeDim>)heightRequest;
- (double)cornerRadius;
- (double)scaleFactor;
@end

@protocol MacIslandTestSAMetrics <NSObject>
- (instancetype)initWithObstructionSize:(CGSize)obs obstructionTopMargin:(double)tm expandedMetricsRequest:(id)exp compactLeadingMetricsRequest:(id)cl compactTrailingMetricsRequest:(id)ct minimalMetricsRequest:(id)min;
- (CGSize)obstructionSize;
- (double)obstructionTopMargin;
- (id<MacIslandTestItemMetrics>)expandedMetricsRequest;
- (id<MacIslandTestItemMetrics>)minimalMetricsRequest;
@end

@protocol MacIslandTestActivityMetrics <NSObject>
- (instancetype)initWithLockScreenMetrics:(id)ls systemApertureMetrics:(id)sa ambientMetrics:(id)amb;
- (id<MacIslandTestSAMetrics>)systemApertureMetrics;
@end

typedef struct { uint64_t w0; uint64_t w1; } ProbeSwiftData;
typedef struct { void *meta; uint64_t state; } ProbeMetaResp;
typedef __attribute__((swiftcall)) ProbeMetaResp (*ProbeMetaFn)(uint64_t req);
typedef __attribute__((swiftcall)) ProbeSwiftData (*ProbeEncodeFn)(
    void *obj,
    __attribute__((swift_context)) void *coderMeta,
    __attribute__((swift_error_result)) void **err
);
typedef __attribute__((swiftcall)) void *(*ProbeDecodeFn)(
    void *targetMeta, uint64_t w0, uint64_t w1, void *genericMeta,
    __attribute__((swift_context)) void *coderMeta,
    __attribute__((swift_error_result)) void **err
);
typedef __attribute__((swiftcall)) void *(*ProbeDataToNSDataFn)(uint64_t w0, uint64_t w1);
typedef __attribute__((swiftcall)) ProbeSwiftData (*ProbeNSDataToDataFn)(void *nsData);
typedef void (*ProbeArrayDestroyFn)(void *begin, size_t count, const void *typeMeta);

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
            !dlopen("/System/Library/PrivateFrameworks/MenuBarClient.framework/MenuBarClient", RTLD_NOW) ||
            !dlopen("/System/Library/PrivateFrameworks/ActivityUIServices.framework/ActivityUIServices", RTLD_NOW) ||
            !dlopen("/System/Library/PrivateFrameworks/ReplicatorServices.framework/ReplicatorServices", RTLD_NOW)) {
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
        if (fabs(patchedMin.width - 344.0) > 0.001 || fabs(patchedMax.width - 500.0) > 0.001) {
            fprintf(stderr, "expected B안 min.w=344 and exact max.w=500, got min=%.1f max=%.1f\n",
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

        // 8. General Live Activities (ActivityUIServices ElementActivitySceneExtension + ActivitySceneExtension):
        // rewrite remote/3rd-party 374pt @ 0.80x metrics to full notched wing width (430pt @ 1.0x around 182x34
        // canonical obstruction), preserve compact/minimal archive hash parity, avoid +extraY height inflation,
        // and restore original OPACK bytes after mutableCopy onto external display 202.
        ProbeMetaFn coderMetaFn = (ProbeMetaFn)dlsym(RTLD_DEFAULT, "$s18ReplicatorServices0A5CoderCMa");
        ProbeMetaFn reqMetaFn = (ProbeMetaFn)dlsym(RTLD_DEFAULT, "$s18ActivityUIServices0A14MetricsRequestCMa");
        ProbeMetaFn dataMetaFn = (ProbeMetaFn)dlsym(RTLD_DEFAULT, "$s10Foundation4DataVMa");
        ProbeEncodeFn encodeFn = (ProbeEncodeFn)dlsym(
            RTLD_DEFAULT, "$s18ReplicatorServices0A5CoderC20encodeNSSecureCodingy10Foundation4DataVSo0eF0_So8NSObjectpKFZ");
        ProbeDecodeFn decodeFn = (ProbeDecodeFn)dlsym(
            RTLD_DEFAULT, "$s18ReplicatorServices0A5CoderC20decodeNSSecureCoding_4fromxxm_10Foundation4DataVtKSo0eF0RzlFZ");
        ProbeDataToNSDataFn toNSData = (ProbeDataToNSDataFn)dlsym(
            RTLD_DEFAULT, "$s10Foundation4DataV19_bridgeToObjectiveCSo6NSDataCyF");
        ProbeNSDataToDataFn fromNSData = (ProbeNSDataToDataFn)dlsym(
            RTLD_DEFAULT, "$s10Foundation4DataV36_unconditionallyBridgeFromObjectiveCyACSo6NSDataCSgFZ");
        void *swiftCore = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY);
        ProbeArrayDestroyFn destroyData = (ProbeArrayDestroyFn)dlsym(swiftCore ?: RTLD_DEFAULT, "swift_arrayDestroy");
        if (!coderMetaFn || !reqMetaFn || !dataMetaFn || !encodeFn || !decodeFn || !toNSData || !fromNSData || !destroyData) {
            fprintf(stderr, "failed to resolve ReplicatorCoder symbols\n");
            return 1;
        }
        void *coderMeta = coderMetaFn(0).meta;
        void *reqMeta = reqMetaFn(0).meta;
        void *dataMeta = dataMetaFn(0).meta;

        Class sizeDimCls = NSClassFromString(@"ActivityUIServices.SizeDimensionRequest");
        Class insetsCls = NSClassFromString(@"ActivityUIServices.ActivityEdgeInsets");
        Class itemCls = NSClassFromString(@"ActivityUIServices.ActivityItemMetricsRequest");
        Class saCls = NSClassFromString(@"ActivityUIServices.SystemApertureMetricsRequest");
        Class reqCls = NSClassFromString(@"ActivityUIServices.ActivityMetricsRequest");

        id<MacIslandTestSizeDim> expW = [(id<MacIslandTestSizeDim>)[sizeDimCls alloc] initWithMinimum:374.0 maximum:374.0 type:1];
        id<MacIslandTestSizeDim> expH = [(id<MacIslandTestSizeDim>)[sizeDimCls alloc] initWithMinimum:52.5 maximum:960.0 type:0];
        id<MacIslandTestEdgeInsets> expInsets = [(id<MacIslandTestEdgeInsets>)[insetsCls alloc] initWithTop:0 leading:20 bottom:0 trailing:20];
        id<MacIslandTestItemMetrics> expItem = [(id<MacIslandTestItemMetrics>)[itemCls alloc]
            initWithWidth:expW height:expH cornerRadius:32.0 edgeInsets:expInsets clipMargin:1.0 scaleFactor:0.80];

        id<MacIslandTestSizeDim> compW = [(id<MacIslandTestSizeDim>)[sizeDimCls alloc] initWithMinimum:0.0 maximum:37.0 type:0];
        id<MacIslandTestSizeDim> compH = [(id<MacIslandTestSizeDim>)[sizeDimCls alloc] initWithMinimum:37.0 maximum:37.0 type:1];
        id<MacIslandTestEdgeInsets> zeroInsets = [(id<MacIslandTestEdgeInsets>)[insetsCls alloc] initWithTop:0 leading:0 bottom:0 trailing:0];
        id<MacIslandTestItemMetrics> compItem = [(id<MacIslandTestItemMetrics>)[itemCls alloc]
            initWithWidth:compW height:compH cornerRadius:19.0 edgeInsets:zeroInsets clipMargin:1.0 scaleFactor:1.0];

        id<MacIslandTestSAMetrics> nativeSA = [(id<MacIslandTestSAMetrics>)[saCls alloc]
            initWithObstructionSize:CGSizeMake(227.5, 42.5)
               obstructionTopMargin:0.0
             expandedMetricsRequest:expItem
       compactLeadingMetricsRequest:compItem
      compactTrailingMetricsRequest:compItem
              minimalMetricsRequest:compItem];
        id<MacIslandTestItemMetrics> lockItem = [(id<MacIslandTestItemMetrics>)[itemCls alloc]
            initWithWidth:expW height:expH cornerRadius:24.0 edgeInsets:expInsets clipMargin:1.0 scaleFactor:0.80];
        id<MacIslandTestActivityMetrics> nativeActivityReq = [(id<MacIslandTestActivityMetrics>)[reqCls alloc]
            initWithLockScreenMetrics:lockItem systemApertureMetrics:nativeSA ambientMetrics:nil];

        void *swiftErr = NULL;
        ProbeSwiftData encNative = encodeFn((__bridge void *)nativeActivityReq, coderMeta, &swiftErr);
        if (swiftErr) { fprintf(stderr, "encode nativeActivityReq failed\n"); return 1; }
        NSData *bridgedNative = (__bridge_transfer NSData *)toNSData(encNative.w0, encNative.w1);
        destroyData(&encNative, 1, dataMeta);
        NSData *nativeMetricsData = [NSData dataWithData:bridgedNative];

        NSData *zeroMargins = encodeJSON(@{@"top": @0, @"leading": @0, @"bottom": @0, @"trailing": @0});
        NSObject<MacIslandTestSettings> *m10 = [mutableClass new];
        [m10 setClientIdentifier:@"com.apple.chrono.WidgetRenderer-Activities"];
        [m10 setIntegratedLayoutMode:@3];
        [m10 setDisplayConfiguration:displayConfigWithID(101)];
        [m10 setMetrics:nativeMetricsData];
        [m10 setElementViewLayoutMargins:zeroMargins];
        [m10 setElementViewMinimumSize:[NSValue valueWithSize:NSMakeSize(299.2, 34.0)]];
        [m10 setElementViewMaximumSize:[NSValue valueWithSize:NSMakeSize(299.2, 768.0)]];
        [m10 setIntegratedObstructionRect:[NSValue valueWithRect:NSMakeRect(59.6, 0, 180, 32)]];

        ProbeSwiftData decPatchedIn = fromNSData((__bridge void *)[m10 metrics]);
        swiftErr = NULL;
        void *rawDecodedPatched = decodeFn(reqMeta, decPatchedIn.w0, decPatchedIn.w1, reqMeta, coderMeta, &swiftErr);
        destroyData(&decPatchedIn, 1, dataMeta);
        if (swiftErr || !rawDecodedPatched) { fprintf(stderr, "decode patched metrics failed\n"); return 1; }
        id<MacIslandTestActivityMetrics> decodedPatched = (__bridge_transfer id<MacIslandTestActivityMetrics>)rawDecodedPatched;
        id<MacIslandTestSAMetrics> patchedSA = [decodedPatched systemApertureMetrics];
        id<MacIslandTestItemMetrics> patchedExp = [patchedSA expandedMetricsRequest];
        if (fabs([patchedSA obstructionSize].width - 182.0) > 0.001 ||
            fabs([patchedSA obstructionSize].height - 34.0) > 0.001 ||
            fabs([[patchedExp widthRequest] minimum] - 430.0) > 0.001 ||
            fabs([[patchedExp widthRequest] maximum] - 430.0) > 0.001 ||
            fabs([patchedExp scaleFactor] - 1.0) > 0.001 ||
            fabs([patchedExp cornerRadius] - 25.6) > 0.001 ||
            fabs([[patchedExp heightRequest] minimum] - 42.0) > 0.001) {
            fprintf(stderr, "unexpected patched Live Activity metrics: obs=(%.1f,%.1f) w=%.1f..%.1f s=%.2f cr=%.1f minH=%.1f\n",
                    [patchedSA obstructionSize].width, [patchedSA obstructionSize].height,
                    [[patchedExp widthRequest] minimum], [[patchedExp widthRequest] maximum],
                    [patchedExp scaleFactor], [patchedExp cornerRadius], [[patchedExp heightRequest] minimum]);
            return 1;
        }
        NSSize laMin = [[m10 elementViewMinimumSize] sizeValue];
        NSSize laMax = [[m10 elementViewMaximumSize] sizeValue];
        if (fabs(laMin.width - 430.0) > 0.001 || fabs(laMin.height - 42.0) > 0.001 ||
            fabs(laMax.width - 500.0) > 0.001 || fabs(laMax.height - 960.0) > 0.001) {
            fprintf(stderr, "unexpected Live Activity scene min/max: min=(%.1f,%.1f) max=(%.1f,%.1f)\n",
                    laMin.width, laMin.height, laMax.width, laMax.height);
            return 1;
        }

        NSObject *frozen10 = [m10 copy];
        id<MacIslandTestSettings> m11 = [frozen10 mutableCopy];
        [m11 setDisplayConfiguration:displayConfigWithID(202)];
        if (![[m11 metrics] isEqualToData:nativeMetricsData] ||
            fabs([[m11 elementViewMinimumSize] sizeValue].width - 299.2) > 0.001) {
            fprintf(stderr, "failed to restore native Live Activity metrics after mutableCopy -> external display\n");
            return 1;
        }

        // Detached minimal Live Activity keeps unpatched elementView margins/sizes while sharing
        // the notched ActivityMetricsRequest hash with compact/expanded scenes.
        id<MacIslandTestSettings> m12 = [mutableClass new];
        [m12 setClientIdentifier:@"com.apple.chrono.WidgetRenderer-Activities"];
        [m12 setIntegratedLayoutMode:@1];
        [m12 setDisplayConfiguration:displayConfigWithID(101)];
        [m12 setIntegratedObstructionLocation:noObstructionLoc];
        [m12 setMetrics:nativeMetricsData];
        [m12 setElementViewLayoutMargins:detachedMargins];
        [m12 setElementViewMinimumSize:detachedMin];
        [m12 setElementViewMaximumSize:detachedMax];
        [m12 setIntegratedObstructionRect:stalePillObs];
        if (![[m12 elementViewLayoutMargins] isEqualToData:detachedMargins] ||
            !NSEqualSizes([[m12 elementViewMaximumSize] sizeValue], detachedMax.sizeValue) ||
            [[m12 metrics] isEqualToData:nativeMetricsData]) {
            fprintf(stderr, "detached minimal Live Activity failed archive-hash parity or margin preservation\n");
            return 1;
        }

        // Direct setMetricsRequest: object hook must neither mutate caller's native object nor leak onto external display.
        NSObject<MacIslandTestSettings> *m13 = [mutableClass new];
        [m13 setDisplayConfiguration:displayConfigWithID(101)];
        [m13 setMetricsRequest:nativeActivityReq];
        id<MacIslandTestActivityMetrics> patchedObjReq = [m13 metricsRequest];
        if (fabs([[[nativeActivityReq systemApertureMetrics] expandedMetricsRequest] scaleFactor] - 0.80) > 0.001 ||
            fabs([[[patchedObjReq systemApertureMetrics] expandedMetricsRequest] scaleFactor] - 1.0) > 0.001) {
            fprintf(stderr, "setMetricsRequest: failed or mutated native request\n");
            return 1;
        }
        NSObject *frozen13 = [m13 copy];
        id<MacIslandTestSettings> m14 = [frozen13 mutableCopy];
        [m14 setDisplayConfiguration:displayConfigWithID(202)];
        if (![[m14 metricsRequest] isEqual:nativeActivityReq]) {
            fprintf(stderr, "setMetricsRequest: failed to restore native request on external display\n");
            return 1;
        }

        // 9. Verify 220pt notch (1800x1169) width alignment + volatile HostedSceneMetricsMaximumContentWidth
        // registration, KVO propagation to MenuBarAgent's suite NSUserDefaults, idempotence, and zero-disk cleanup.
        TestFakeScreen *notched220 = [TestFakeScreen new];
        notched220.frame = NSMakeRect(0, 0, 1800, 1169);
        notched220.safeAreaInsets = NSEdgeInsetsMake(38, 0, 0, 0);
        notched220.auxLeft = [NSValue valueWithRect:NSMakeRect(0, 1131, 790, 38)];
        notched220.auxRight = [NSValue valueWithRect:NSMakeRect(1010, 1131, 790, 38)];
        notched220.deviceDescription = @{@"NSScreenNumber": @303};
        fakeScreens = @[notched, external];

        NSString *tempContainerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:[tempContainerPath stringByAppendingPathComponent:@"Library/Preferences"]
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        NSString *suiteName = [NSString stringWithFormat:@"com.macisland.probe.%@", NSUUID.UUID.UUIDString];
        NSUserDefaults *suiteDefaults = [(id<MacIslandSuiteDefaultsInit>)[NSUserDefaults alloc]
            _initWithSuiteName:suiteName
                     container:[NSURL fileURLWithPath:tempContainerPath isDirectory:YES]];
        TestDefaultsObserver *kvo = [TestDefaultsObserver new];
        [suiteDefaults addObserver:kvo
                        forKeyPath:MacIslandHostedMaxContentWidthKey
                           options:NSKeyValueObservingOptionNew
                           context:NULL];

        NSUserDefaults *stdDefaults = NSUserDefaults.standardUserDefaults;
        [stdDefaults registerDefaults:@{@"MacIslandProbeUnrelatedKey": @42}];

        // 180pt notch -> 500pt
        MacIslandSyncHostedSceneMaximumContentWidthForTesting(stdDefaults);
        if (kvo.changeCount != 1 || fabs([suiteDefaults doubleForKey:MacIslandHostedMaxContentWidthKey] - 500.0) > 0.001) {
            fprintf(stderr, "expected KVO=1 and maxContentWidth=500.0 on 180pt notch, got KVO=%lu val=%.1f\n",
                    (unsigned long)kvo.changeCount, [suiteDefaults doubleForKey:MacIslandHostedMaxContentWidthKey]);
            return 1;
        }
        // Idempotent re-sync must not re-fire KVO
        MacIslandSyncHostedSceneMaximumContentWidthForTesting(stdDefaults);
        if (kvo.changeCount != 1) {
            fprintf(stderr, "redundant KVO fired on unchanged screen parameters (%lu)\n", (unsigned long)kvo.changeCount);
            return 1;
        }

        // 220pt notch -> 540pt, matching both ClockAngel (522pt <= 540pt) and Live Activities (470pt <= 540pt)
        fakeScreens = @[notched, notched220, external];
        MacIslandSyncHostedSceneMaximumContentWidthForTesting(stdDefaults);
        if (kvo.changeCount != 2 || fabs([suiteDefaults doubleForKey:MacIslandHostedMaxContentWidthKey] - 540.0) > 0.001) {
            fprintf(stderr, "expected KVO=2 and maxContentWidth=540.0 on 220pt notch, got KVO=%lu val=%.1f\n",
                    (unsigned long)kvo.changeCount, [suiteDefaults doubleForKey:MacIslandHostedMaxContentWidthKey]);
            return 1;
        }

        NSObject<MacIslandTestSettings> *m15 = [mutableClass new];
        [m15 setClientIdentifier:@"com.apple.chrono.WidgetRenderer-Activities"];
        [m15 setIntegratedLayoutMode:@3];
        [m15 setDisplayConfiguration:displayConfigWithID(303)];
        [m15 setMetrics:nativeMetricsData];
        [m15 setElementViewLayoutMargins:zeroMargins];
        [m15 setElementViewMinimumSize:[NSValue valueWithSize:NSMakeSize(299.2, 34.0)]];
        [m15 setElementViewMaximumSize:[NSValue valueWithSize:NSMakeSize(540.0, 768.0)]];
        [m15 setIntegratedObstructionRect:[NSValue valueWithRect:NSMakeRect(59.6, 0, 220, 38)]];
        NSSize la220Min = [[m15 elementViewMinimumSize] sizeValue];
        NSSize la220Max = [[m15 elementViewMaximumSize] sizeValue];
        if (fabs(la220Min.width - 470.0) > 0.001 || fabs(la220Max.width - 540.0) > 0.001) {
            fprintf(stderr, "expected 220pt Live Activity min=470 max=540, got min=%.1f max=%.1f\n",
                    la220Min.width, la220Max.width);
            return 1;
        }

        // Clamshell / external non-notched only -> passively wake suite KVO (408.0) without requiring a prior read,
        // strip registered key (nil), and keep unrelated registered keys intact.
        fakeScreens = @[external];
        MacIslandSyncHostedSceneMaximumContentWidthForTesting(stdDefaults);
        if (kvo.changeCount < 3 || fabs(kvo.lastObservedWidth - 408.0) > 0.001) {
            fprintf(stderr, "clamshell sync failed to wake passive suite KVO observer (KVO=%lu, last=%.1f)\n",
                    (unsigned long)kvo.changeCount, kvo.lastObservedWidth);
            return 1;
        }
        id afterClamshellObj = [suiteDefaults objectForKey:MacIslandHostedMaxContentWidthKey];
        if (afterClamshellObj != nil || [stdDefaults integerForKey:@"MacIslandProbeUnrelatedKey"] != 42) {
            fprintf(stderr, "failed clamshell HostedSceneMetricsMaximumContentWidth cleanup (obj=%s)\n",
                    [afterClamshellObj description].UTF8String ?: "nil");
            return 1;
        }
        // Idempotent clamshell re-sync must not re-fire KVO
        NSUInteger settledKVO = kvo.changeCount;
        MacIslandSyncHostedSceneMaximumContentWidthForTesting(stdDefaults);
        if (kvo.changeCount != settledKVO || [suiteDefaults objectForKey:MacIslandHostedMaxContentWidthKey] != nil) {
            fprintf(stderr, "redundant KVO fired on unchanged clamshell screens (%lu vs %lu)\n",
                    (unsigned long)kvo.changeCount, (unsigned long)settledKVO);
            return 1;
        }
        NSArray<NSString *> *writtenPlists = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:[tempContainerPath stringByAppendingPathComponent:@"Library/Preferences"]
                                error:NULL];
        if (writtenPlists.count != 0) {
            fprintf(stderr, "unexpected disk plist created during volatile NSRegistrationDomain sync: %s\n",
                    writtenPlists.description.UTF8String);
            return 1;
        }

        [suiteDefaults removeObserver:kvo forKeyPath:MacIslandHostedMaxContentWidthKey];
        [NSFileManager.defaultManager removeItemAtPath:tempContainerPath error:NULL];
        NSMutableDictionary *cleanReg = [[stdDefaults volatileDomainForName:NSRegistrationDomain] mutableCopy];
        [cleanReg removeObjectForKey:@"MacIslandProbeUnrelatedKey"];
        [stdDefaults removeVolatileDomainForName:NSRegistrationDomain];
        if (cleanReg.count > 0) [stdDefaults setVolatileDomain:cleanReg forName:NSRegistrationDomain];

        printf("safearea=ok canonical=(%.1f,%.1f,%.0fx%.0f) activity_expanded=%.0f@%.1fx max_content_220=540 restored_corners=nil\n",
               publishedObs.origin.x, publishedObs.origin.y, publishedObs.size.width, publishedObs.size.height,
               [[patchedExp widthRequest] maximum], [patchedExp scaleFactor]);
        return 0;
    }
}
