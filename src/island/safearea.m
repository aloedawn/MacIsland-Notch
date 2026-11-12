#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "notch-layout.h"
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// One physical exclusion policy at the shared FBS scene-settings boundary.
// Both ElementRegistry and MenuBarClient receive it, regardless of provider.
static char sceneInsetsKey, originalLayoutPayloadKey;
static void (*originalMargins[2])(id, SEL, id);
static void (*originalMinimum[2])(id, SEL, id);
static void (*originalMaximum[2])(id, SEL, id);
static void (*originalObstruction[2])(id, SEL, id);
static void (*originalSpace[2])(id, SEL, id);
static void (*originalCorners[2])(id, SEL, id);
static void (*originalLocation[2])(id, SEL, id);
static void (*originalActivityMetricsData)(id, SEL, id);
static void (*originalActivityMetricsRequest)(id, SEL, id);
static void (*originalFrame)(id, SEL, CGRect);
static void (*originalDisplayConfiguration)(id, SEL, id);

typedef struct {
    BOOL present;
    BOOL patched;
    CGSize nativeObstruction;
    CGFloat nativeExpandedMinW;
    CGFloat nativeExpandedMaxW;
    CGFloat nativeExpandedScale;
    CGFloat nativeExpandedCornerRadius;
    CGSize patchedObstruction;
    CGFloat patchedExpandedMinW;
    CGFloat patchedExpandedMaxW;
    CGFloat patchedExpandedMinH;
    CGFloat patchedExpandedMaxH;
    CGFloat patchedExpandedScale;
    CGFloat patchedExpandedCornerRadius;
} MacIslandActivityMetricsSummary;

@protocol MacIslandSizeDimensionRequest <NSObject, NSCopying>
- (instancetype)initWithMinimum:(double)minimum maximum:(double)maximum type:(NSInteger)type;
- (double)minimum;
- (double)maximum;
- (NSInteger)type;
@end

@protocol MacIslandActivityEdgeInsets <NSObject, NSCopying>
- (double)leading;
- (double)trailing;
- (void)setLeading:(double)value;
- (void)setTrailing:(double)value;
@end

@protocol MacIslandActivityItemMetricsRequest <NSObject, NSCopying>
- (id<MacIslandSizeDimensionRequest>)widthRequest;
- (void)setWidthRequest:(id<MacIslandSizeDimensionRequest>)value;
- (id<MacIslandSizeDimensionRequest>)heightRequest;
- (void)setHeightRequest:(id<MacIslandSizeDimensionRequest>)value;
- (id<MacIslandActivityEdgeInsets>)edgeInsets;
- (void)setEdgeInsets:(id<MacIslandActivityEdgeInsets>)value;
- (double)cornerRadius;
- (void)setCornerRadius:(double)value;
- (double)scaleFactor;
- (void)setScaleFactor:(double)value;
@end

@protocol MacIslandSystemApertureMetricsRequest <NSObject, NSCopying>
- (CGSize)obstructionSize;
- (void)setObstructionSize:(CGSize)value;
- (double)obstructionTopMargin;
- (void)setObstructionTopMargin:(double)value;
- (id<MacIslandActivityItemMetricsRequest>)expandedMetricsRequest;
- (void)setExpandedMetricsRequest:(id<MacIslandActivityItemMetricsRequest>)value;
@end

@protocol MacIslandActivityMetricsRequest <NSObject, NSCopying>
- (id<MacIslandSystemApertureMetricsRequest>)systemApertureMetrics;
- (void)setSystemApertureMetrics:(id<MacIslandSystemApertureMetricsRequest>)value;
- (id<MacIslandSystemApertureMetricsRequest>)limitedWidthSystemApertureMetrics;
- (void)setLimitedWidthSystemApertureMetrics:(id<MacIslandSystemApertureMetricsRequest>)value;
@end

@interface MacIslandNativeLayout : NSObject
@property(nonatomic, strong) NSData *margins;
@property(nonatomic, strong) NSValue *minimum;
@property(nonatomic, strong) NSValue *maximum;
@property(nonatomic) BOOL applied;
@end
@implementation MacIslandNativeLayout
@end

@interface MacIslandNativeObstruction : NSObject
@property(nonatomic, strong) NSValue *rect;
@property(nonatomic, strong) NSValue *space;
@property(nonatomic, strong) id nativeCorners;
@property(nonatomic, strong) id rectangularCorners;
@property(nonatomic) BOOL cornersApplied;
@property(nonatomic) BOOL obstructionApplied;
@end
@implementation MacIslandNativeObstruction
@end

@interface MacIslandSceneInsets : NSObject
@property(nonatomic, strong) NSArray<MacIslandNativeLayout *> *layouts;
@property(nonatomic, strong) NSArray<MacIslandNativeObstruction *> *obstructions;
@property(nonatomic, strong) NSMutableArray<NSString *> *auditSignatures;
@property(nonatomic, strong) NSData *nativeActivityMetricsData;
@property(nonatomic, strong) NSData *cachedActivityMetricsSource;
@property(nonatomic, strong) NSData *cachedPatchedActivityMetricsData;
@property(nonatomic) NSRect cachedActivityMetricsCutout;
@property(nonatomic) CGFloat cachedActivityMetricsDisplayWidth;
@property(nonatomic) MacIslandActivityMetricsSummary cachedActivitySummary;
@property(nonatomic) BOOL activityMetricsDataApplied;
@property(nonatomic, strong) id nativeActivityMetricsRequest;
@property(nonatomic) BOOL activityMetricsRequestApplied;
@property(nonatomic) CGRect frame;
@property(nonatomic) BOOL updating;
@end
@implementation MacIslandSceneInsets
- (instancetype)init {
    self = [super init];
    if (self) {
        _layouts = @[[MacIslandNativeLayout new], [MacIslandNativeLayout new]];
        _obstructions = @[[MacIslandNativeObstruction new], [MacIslandNativeObstruction new]];
        _auditSignatures = [@[@"", @""] mutableCopy];
    }
    return self;
}
@end

@protocol MacIslandCornerFactory
- (instancetype)initWithCornerRadius:(CGFloat)radius;
@end

typedef struct {
    BOOL physical;
    BOOL intersects;
    BOOL extendsBelow;
    CGFloat top;
    CGFloat leading;
    CGFloat trailing;
    CGFloat notchWidth;
    CGFloat notchHeight;
    CGFloat centeredDisplayWidth;
} MacIslandNotchAvoidance;

static BOOL isPatchedPayload(id value) {
    return value != nil && objc_getAssociatedObject(value, &originalLayoutPayloadKey) != nil;
}
static id nativePayload(id value) {
    if (!value) return nil;
    id saved = objc_getAssociatedObject(value, &originalLayoutPayloadKey);
    if (!saved) return value;
    return saved == NSNull.null ? nil : saved;
}
static id layoutPayload(id value, id original) {
    id unpatched = nativePayload(original);
    if (value && value != unpatched) {
        objc_setAssociatedObject(value, &originalLayoutPayloadKey, unpatched ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return value;
}
static BOOL isSizeValue(id value) {
    return [value isKindOfClass:NSValue.class] && !strcmp([value objCType], @encode(NSSize));
}
static BOOL isRectValue(id value) {
    return [value isKindOfClass:NSValue.class] && !strcmp([value objCType], @encode(NSRect));
}
static id rawObjectSetting(id settings, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![settings respondsToSelector:selector]) return nil;
    Method method = class_getInstanceMethod([settings class], selector);
    if (!method || method_getTypeEncoding(method)[0] != '@') return nil;
    id (*getter)(id, SEL) = (void *)method_getImplementation(method);
    return getter(settings, selector);
}
static id existingObjectSetting(id settings, NSString *name) {
    return nativePayload(rawObjectSetting(settings, name));
}
static CGRect existingFrame(id settings) {
    SEL selector = NSSelectorFromString(@"frame");
    if (![settings respondsToSelector:selector]) return CGRectZero;
    Method method = class_getInstanceMethod([settings class], selector);
    if (!method) return CGRectZero;
    const char *type = method_getTypeEncoding(method);
    if (type[0] == '{' && strstr(type, "CGRect")) {
        CGRect (*getter)(id, SEL) = (void *)method_getImplementation(method);
        return getter(settings, selector);
    }
    id value = existingObjectSetting(settings, @"frame");
    return isRectValue(value) ? [value rectValue] : CGRectZero;
}
static NSString *familySetting(NSUInteger family, NSString *suffix) {
    return [(family ? @"hosted" : @"elementView") stringByAppendingString:suffix];
}
static NSString *familySetter(NSUInteger family, NSString *suffix) {
    return [[(family ? @"setHosted" : @"setElementView") stringByAppendingString:suffix] stringByAppendingString:@":"];
}
static NSString *obstructionSetting(NSUInteger family, NSString *suffix) {
    return [(family ? @"hostedIntegratedObstruction" : @"integratedObstruction") stringByAppendingString:suffix];
}
static NSString *obstructionSetter(NSUInteger family, NSString *suffix) {
    return [[(family ? @"setHostedIntegratedObstruction" : @"setIntegratedObstruction") stringByAppendingString:suffix] stringByAppendingString:@":"];
}
static BOOL isDetachedObstructionLocation(id raw) {
    if (!raw) return NO;
    id value = raw;
    if ([raw isKindOfClass:NSData.class]) {
        value = [NSJSONSerialization JSONObjectWithData:(NSData *)raw
                                                options:NSJSONReadingFragmentsAllowed
                                                  error:NULL];
        if (!value) {
            NSString *text = [[NSString alloc] initWithData:(NSData *)raw encoding:NSUTF8StringEncoding];
            return text != nil && [text containsString:@"noObstruction"];
        }
    }
    if ([value isKindOfClass:NSDictionary.class]) return ((NSDictionary *)value)[@"noObstruction"] != nil;
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value isEqualToString:@"noObstruction"];
    return NO;
}

// FrontBoardServices creates a fresh FBSMutableSceneSettings copy per update,
// clearing settings-level associated state while preserving payload objects.
// Recover both the original unpatched values and whether patched values are
// currently active inside this settings copy.
static MacIslandSceneInsets *sceneState(id settings) {
    MacIslandSceneInsets *state = objc_getAssociatedObject(settings, &sceneInsetsKey);
    if (!state) {
        state = [MacIslandSceneInsets new];
        objc_setAssociatedObject(settings, &sceneInsetsKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSUInteger family = 0; family < state.layouts.count; family++) {
            MacIslandNativeLayout *native = state.layouts[family];
            id rawMargins = rawObjectSetting(settings, familySetting(family, @"LayoutMargins"));
            id rawMinimum = rawObjectSetting(settings, familySetting(family, @"MinimumSize"));
            id rawMaximum = rawObjectSetting(settings, familySetting(family, @"MaximumSize"));
            native.applied = isPatchedPayload(rawMargins) || isPatchedPayload(rawMinimum) || isPatchedPayload(rawMaximum);
            id margins = nativePayload(rawMargins);
            id minimum = nativePayload(rawMinimum);
            id maximum = nativePayload(rawMaximum);
            native.margins = [margins isKindOfClass:NSData.class] ? margins : nil;
            native.minimum = isSizeValue(minimum) ? minimum : nil;
            native.maximum = isSizeValue(maximum) ? maximum : nil;
        }
        for (NSUInteger family = 0; family < state.obstructions.count; family++) {
            MacIslandNativeObstruction *native = state.obstructions[family];
            id rawRect = rawObjectSetting(settings, obstructionSetting(family, @"Rect"));
            id rawSpace = rawObjectSetting(settings, obstructionSetting(family, @"RectCoordinateSpace"));
            id rawCorners = rawObjectSetting(settings, obstructionSetting(family, @"CornerRadii"));
            native.obstructionApplied = isPatchedPayload(rawRect);
            native.cornersApplied = isPatchedPayload(rawCorners);
            if (native.cornersApplied) native.rectangularCorners = rawCorners;
            id rect = nativePayload(rawRect);
            id space = nativePayload(rawSpace);
            native.rect = isRectValue(rect) ? rect : nil;
            native.space = isSizeValue(space) ? space : nil;
            native.nativeCorners = nativePayload(rawCorners);
        }
        id rawMetricsData = rawObjectSetting(settings, @"metrics");
        state.activityMetricsDataApplied = isPatchedPayload(rawMetricsData);
        id metricsData = nativePayload(rawMetricsData);
        state.nativeActivityMetricsData = [metricsData isKindOfClass:NSData.class] ? metricsData : nil;

        id rawMetricsReq = rawObjectSetting(settings, @"metricsRequest");
        state.activityMetricsRequestApplied = isPatchedPayload(rawMetricsReq);
        state.nativeActivityMetricsRequest = nativePayload(rawMetricsReq);
        state.frame = existingFrame(settings);
    }
    return state;
}
static BOOL settingsHaveTrackedValues(id settings) {
    if (objc_getAssociatedObject(settings, &sceneInsetsKey)) return YES;
    for (NSUInteger family = 0; family < 2; family++) {
        if (rawObjectSetting(settings, familySetting(family, @"LayoutMargins")) ||
            rawObjectSetting(settings, obstructionSetting(family, @"Rect")) ||
            rawObjectSetting(settings, obstructionSetting(family, @"CornerRadii")))
            return YES;
    }
    if (rawObjectSetting(settings, @"metrics") || rawObjectSetting(settings, @"metricsRequest"))
        return YES;
    return NO;
}

static NSScreen *sceneDisplayScreen(id settings, BOOL *known) {
    id identity = existingObjectSetting(settings, @"displayIdentity");
    if (!identity) identity = existingObjectSetting(existingObjectSetting(settings, @"displayConfiguration"), @"identity");
    uint32_t displayID = 0;
    SEL displaySelector = NSSelectorFromString(@"displayID");
    if ([identity respondsToSelector:displaySelector]) {
        Method method = class_getInstanceMethod([identity class], displaySelector);
        if (method && method_getTypeEncoding(method)[0] == 'I') {
            uint32_t (*getter)(id, SEL) = (void *)method_getImplementation(method);
            displayID = getter(identity, displaySelector);
        }
    }
    if (!displayID) {
        SEL selector = NSSelectorFromString(@"controlCenterItemDisplayID");
        if ([settings respondsToSelector:selector]) {
            Method method = class_getInstanceMethod([settings class], selector);
            if (method && method_getTypeEncoding(method)[0] == 'I') {
                uint32_t (*getter)(id, SEL) = (void *)method_getImplementation(method);
                displayID = getter(settings, selector);
            }
        }
    }
    *known = displayID != 0;
    for (NSScreen *screen in NSScreen.screens)
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) return screen;
    return nil;
}
static NSScreen *fallbackNotchedScreen(void) {
    for (NSScreen *screen in NSScreen.screens)
        if (MacIslandScreenHasNotch(screen)) return screen;
    return nil;
}
static NSRect canonicalObstruction(NSRect native, NSScreen *screen) {
    NSRect cutout = NSZeroRect;
    if (!MacIslandScreenNotchCutout(screen, &cutout) || NSIsEmptyRect(native) || !isfinite(native.origin.x) ||
        !isfinite(native.origin.y) || !isfinite(native.size.width) || !isfinite(native.size.height)) return native;
    CGFloat width = cutout.size.width;
    // Correct the common obstruction itself, including legacy pill metrics.
    // Preserve its scene-local horizontal anchor and existing vertical origin.
    return NSMakeRect(NSMidX(native) - (width + 2) / 2, native.origin.y,
                      width + 2, cutout.size.height + 2);
}

static MacIslandNotchAvoidance notchAvoidance(NSRect obstruction, NSSize viewport, NSArray<NSScreen *> *candidates) {
    MacIslandNotchAvoidance policy = {0};
    if (!isfinite(obstruction.origin.x) || !isfinite(obstruction.origin.y) ||
        !isfinite(obstruction.size.width) || !isfinite(obstruction.size.height) ||
        obstruction.size.width <= 0 || obstruction.size.height <= 0) return policy;
    if (!isfinite(viewport.width) || !isfinite(viewport.height) || viewport.width <= 0 || viewport.height <= 0) return policy;
    for (NSScreen *screen in candidates) {
        NSRect cutout = NSZeroRect;
        if (!MacIslandScreenNotchCutout(screen, &cutout)) continue;
        CGFloat width = cutout.size.width;
        CGFloat height = cutout.size.height;
        // Match the physical obstruction itself, not a provider's width,
        // centering, scene height, identity, or display name.
        if (fabs(obstruction.size.width - width) > 4 || fabs(obstruction.size.height - height) > 4 ||
            fabs(obstruction.origin.y) > 3) continue;
        policy.physical = YES;
        policy.notchWidth = width;
        policy.notchHeight = height;
        policy.centeredDisplayWidth = MacIslandCenteredDisplayWidth(screen, cutout);
        NSRect physical = NSInsetRect(obstruction, (obstruction.size.width - width) / 2,
                                                  (obstruction.size.height - height) / 2);
        NSRect area = NSMakeRect(0, 0, viewport.width, viewport.height);
        policy.intersects = NSIntersectsRect(physical, area);
        policy.extendsBelow = policy.intersects && viewport.height > NSMaxY(obstruction) + 1;
        CGFloat outside = MacIslandNotchFlare + 6;
        policy.leading = outside;
        policy.trailing = outside;
        // Compact side regions reserve a gap against the exclusion as well
        // as the outside curve. A full-width scene gets the same policy.
        if (NSMinX(physical) >= NSMaxX(area)) policy.trailing = 6;
        if (NSMaxX(physical) <= NSMinX(area)) policy.leading = 6;
        if (policy.extendsBelow) policy.top = ceil(MAX(height, NSMaxY(obstruction))) + 6;
        return policy;
    }
    return policy;
}
static NSDictionary *decodedMargins(NSData *data) {
    if (![data isKindOfClass:NSData.class]) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![decoded isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"top", @"leading", @"bottom", @"trailing"])
        if (![decoded[key] isKindOfClass:NSNumber.class] || !isfinite([decoded[key] doubleValue])) return nil;
    return decoded;
}
static NSData *safeMargins(NSData *native, NSDictionary *decoded, MacIslandNotchAvoidance policy) {
    if (!policy.physical || !decoded) return native;
    NSMutableDictionary *margins = [decoded mutableCopy];
    margins[@"top"] = @(MAX([decoded[@"top"] doubleValue], policy.top));
    margins[@"leading"] = @(MAX([decoded[@"leading"] doubleValue], policy.leading));
    margins[@"trailing"] = @(MAX([decoded[@"trailing"] doubleValue], policy.trailing));
    if ([margins isEqualToDictionary:decoded]) return native;
    NSData *raw = [NSJSONSerialization dataWithJSONObject:margins options:NSJSONWritingSortedKeys error:NULL];
    NSData *data = raw ? [NSData dataWithData:raw] : nil;
    return layoutPayload(data ?: native, native);
}
typedef struct {
    uint64_t w0;
    uint64_t w1;
} MacIslandSwiftData;

typedef struct {
    void *metadata;
    uint64_t state;
} MacIslandSwiftMetadataResponse;

typedef __attribute__((swiftcall)) MacIslandSwiftMetadataResponse (*MacIslandTypeMetadataAccessorFn)(uint64_t request);
typedef __attribute__((swiftcall)) MacIslandSwiftData (*MacIslandReplicatorEncodeFn)(
    void *object,
    __attribute__((swift_context)) void *coderMetadata,
    __attribute__((swift_error_result)) void **errorOut
);
typedef __attribute__((swiftcall)) void *(*MacIslandReplicatorDecodeFn)(
    void *targetMetadata,
    uint64_t dataW0,
    uint64_t dataW1,
    void *genericMetadata,
    __attribute__((swift_context)) void *coderMetadata,
    __attribute__((swift_error_result)) void **errorOut
);
typedef __attribute__((swiftcall)) void *(*MacIslandDataToNSDataFn)(uint64_t w0, uint64_t w1);
typedef __attribute__((swiftcall)) MacIslandSwiftData (*MacIslandNSDataToDataFn)(void *nsData);
typedef void (*MacIslandSwiftArrayDestroyFn)(void *begin, size_t count, const void *typeMetadata);
typedef void (*MacIslandSwiftErrorReleaseFn)(void *error);

static pthread_mutex_t activityBridgeLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL activityBridgeReady;
static void *activityCoderMetadata;
static void *activityMetricsRequestMetadata;
static void *foundationDataMetadata;
static MacIslandReplicatorEncodeFn replicatorEncodeFn;
static MacIslandReplicatorDecodeFn replicatorDecodeFn;
static MacIslandDataToNSDataFn foundationDataToNSDataFn;
static MacIslandNSDataToDataFn nsDataToFoundationDataFn;
static MacIslandSwiftArrayDestroyFn swiftArrayDestroyFn;
static MacIslandSwiftErrorReleaseFn swiftErrorReleaseFn;

static BOOL ensureActivityMetricsBridge(void) {
    pthread_mutex_lock(&activityBridgeLock);
    if (activityBridgeReady) {
        pthread_mutex_unlock(&activityBridgeLock);
        return YES;
    }
    if (!NSClassFromString(@"ActivityUIServices.ActivityMetricsRequest")) {
        pthread_mutex_unlock(&activityBridgeLock);
        return NO;
    }
    const char *repPath = "/System/Library/PrivateFrameworks/ReplicatorServices.framework/ReplicatorServices";
    void *repHandle = dlopen(repPath, RTLD_LAZY | RTLD_NOLOAD);
    if (!repHandle) repHandle = dlopen(repPath, RTLD_LAZY);
    void *swiftCore = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (!swiftCore) swiftCore = RTLD_DEFAULT;
    if (repHandle) {
        MacIslandTypeMetadataAccessorFn coderMetaFn =
            (MacIslandTypeMetadataAccessorFn)dlsym(repHandle, "$s18ReplicatorServices0A5CoderCMa");
        MacIslandTypeMetadataAccessorFn reqMetaFn =
            (MacIslandTypeMetadataAccessorFn)dlsym(RTLD_DEFAULT, "$s18ActivityUIServices0A14MetricsRequestCMa");
        MacIslandTypeMetadataAccessorFn dataMetaFn =
            (MacIslandTypeMetadataAccessorFn)dlsym(RTLD_DEFAULT, "$s10Foundation4DataVMa");
        replicatorEncodeFn = (MacIslandReplicatorEncodeFn)dlsym(
            repHandle, "$s18ReplicatorServices0A5CoderC20encodeNSSecureCodingy10Foundation4DataVSo0eF0_So8NSObjectpKFZ");
        replicatorDecodeFn = (MacIslandReplicatorDecodeFn)dlsym(
            repHandle, "$s18ReplicatorServices0A5CoderC20decodeNSSecureCoding_4fromxxm_10Foundation4DataVtKSo0eF0RzlFZ");
        foundationDataToNSDataFn = (MacIslandDataToNSDataFn)dlsym(
            RTLD_DEFAULT, "$s10Foundation4DataV19_bridgeToObjectiveCSo6NSDataCyF");
        nsDataToFoundationDataFn = (MacIslandNSDataToDataFn)dlsym(
            RTLD_DEFAULT, "$s10Foundation4DataV36_unconditionallyBridgeFromObjectiveCyACSo6NSDataCSgFZ");
        swiftArrayDestroyFn = (MacIslandSwiftArrayDestroyFn)dlsym(swiftCore, "swift_arrayDestroy");
        swiftErrorReleaseFn = (MacIslandSwiftErrorReleaseFn)dlsym(swiftCore, "swift_errorRelease");
        if (coderMetaFn && reqMetaFn && dataMetaFn && replicatorEncodeFn && replicatorDecodeFn &&
            foundationDataToNSDataFn && nsDataToFoundationDataFn && swiftArrayDestroyFn && swiftErrorReleaseFn) {
            activityCoderMetadata = coderMetaFn(0).metadata;
            activityMetricsRequestMetadata = reqMetaFn(0).metadata;
            foundationDataMetadata = dataMetaFn(0).metadata;
            activityBridgeReady = (activityCoderMetadata && activityMetricsRequestMetadata && foundationDataMetadata);
        }
    }
    BOOL ready = activityBridgeReady;
    pthread_mutex_unlock(&activityBridgeLock);
    return ready;
}

static id<MacIslandActivityMetricsRequest> decodeActivityMetricsData(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length == 0 || !ensureActivityMetricsBridge()) return nil;
    MacIslandSwiftData sdata = nsDataToFoundationDataFn((__bridge void *)data);
    void *err = NULL;
    void *raw = replicatorDecodeFn(activityMetricsRequestMetadata, sdata.w0, sdata.w1,
                                   activityMetricsRequestMetadata, activityCoderMetadata, &err);
    swiftArrayDestroyFn(&sdata, 1, foundationDataMetadata);
    if (err) {
        swiftErrorReleaseFn(err);
        return nil;
    }
    return (__bridge_transfer id<MacIslandActivityMetricsRequest>)raw;
}

static NSData *encodeActivityMetricsData(id<MacIslandActivityMetricsRequest> request) {
    if (!request || !ensureActivityMetricsBridge()) return nil;
    void *err = NULL;
    MacIslandSwiftData sdata = replicatorEncodeFn((__bridge void *)request, activityCoderMetadata, &err);
    if (err) {
        swiftErrorReleaseFn(err);
        return nil;
    }
    NSData *bridged = (__bridge_transfer NSData *)foundationDataToNSDataFn(sdata.w0, sdata.w1);
    swiftArrayDestroyFn(&sdata, 1, foundationDataMetadata);
    return bridged ? [NSData dataWithData:bridged] : nil;
}

static BOOL readSystemApertureSummary(id<MacIslandActivityMetricsRequest> req,
                                      CGSize *obsOut, CGFloat *minWOut, CGFloat *maxWOut,
                                      CGFloat *minHOut, CGFloat *maxHOut,
                                      CGFloat *scaleOut, CGFloat *cornerOut) {
    if (!req || ![req respondsToSelector:@selector(systemApertureMetrics)]) return NO;
    id<MacIslandSystemApertureMetricsRequest> sa = [req systemApertureMetrics];
    if (!sa || ![sa respondsToSelector:@selector(obstructionSize)] ||
        ![sa respondsToSelector:@selector(expandedMetricsRequest)]) return NO;
    id<MacIslandActivityItemMetricsRequest> expanded = [sa expandedMetricsRequest];
    if (!expanded || ![expanded respondsToSelector:@selector(widthRequest)] ||
        ![expanded respondsToSelector:@selector(heightRequest)] ||
        ![expanded respondsToSelector:@selector(scaleFactor)] ||
        ![expanded respondsToSelector:@selector(cornerRadius)]) return NO;
    id<MacIslandSizeDimensionRequest> w = [expanded widthRequest];
    id<MacIslandSizeDimensionRequest> h = [expanded heightRequest];
    if (!w || !h) return NO;
    if (obsOut) *obsOut = [sa obstructionSize];
    if (minWOut) *minWOut = [w minimum];
    if (maxWOut) *maxWOut = [w maximum];
    if (minHOut) *minHOut = [h minimum];
    if (maxHOut) *maxHOut = [h maximum];
    if (scaleOut) *scaleOut = [expanded scaleFactor];
    if (cornerOut) *cornerOut = [expanded cornerRadius];
    return YES;
}

static id<MacIslandSystemApertureMetricsRequest> patchedSystemApertureMetrics(
    id<MacIslandSystemApertureMetricsRequest> sa,
    CGSize notchObstruction,
    CGFloat centeredDisplayWidth) {
    if (!sa ||
        ![sa respondsToSelector:@selector(obstructionSize)] ||
        ![sa respondsToSelector:@selector(obstructionTopMargin)] ||
        ![sa respondsToSelector:@selector(expandedMetricsRequest)] ||
        ![sa respondsToSelector:@selector(copyWithZone:)]) {
        return sa;
    }
    CGSize oldObs = [sa obstructionSize];
    id<MacIslandActivityItemMetricsRequest> expanded = [sa expandedMetricsRequest];
    if (!expanded || !(oldObs.width > 0.0) || !(oldObs.height > 0.0)) return sa;
    if (![expanded respondsToSelector:@selector(widthRequest)] ||
        ![expanded respondsToSelector:@selector(heightRequest)] ||
        ![expanded respondsToSelector:@selector(scaleFactor)] ||
        ![expanded respondsToSelector:@selector(cornerRadius)] ||
        ![expanded respondsToSelector:@selector(copyWithZone:)]) {
        return sa;
    }
    id<MacIslandSizeDimensionRequest> oldW = [expanded widthRequest];
    id<MacIslandSizeDimensionRequest> oldH = [expanded heightRequest];
    Class sizeDimCls = NSClassFromString(@"ActivityUIServices.SizeDimensionRequest");
    if (!oldW || !oldH || !sizeDimCls ||
        ![sizeDimCls instancesRespondToSelector:@selector(initWithMinimum:maximum:type:)]) {
        return sa;
    }
    double oldScale = [expanded scaleFactor];
    if (!(oldScale > 0.0) || !isfinite(oldScale)) oldScale = 1.0;
    double unscale = (oldScale < 1.0) ? oldScale : 1.0;

    // Preserve native iPhone Pro System Aperture wing capacity (374 - 126 = 248pt total
    // wing span -> 124pt per side around canonical notch obstruction, 104pt usable inside
    // Jindo's 20pt horizontal edge insets) at crisp 1.0x Retina scale.
    double effectiveOldMaxW = [oldW maximum] * unscale;
    double targetWidth = MIN(MAX(notchObstruction.width + 248.0, effectiveOldMaxW), centeredDisplayWidth);
    NSInteger widthType = [oldW type];
    double newMinW = (widthType == 0) ? MIN([oldW minimum] * unscale, targetWidth) : targetWidth;
    id<MacIslandSizeDimensionRequest> newW =
        [(id<MacIslandSizeDimensionRequest>)[sizeDimCls alloc] initWithMinimum:newMinW
                                                                       maximum:targetWidth
                                                                          type:widthType];

    double rawOldMinH = [oldH minimum];
    NSInteger heightType = [oldH type];
    double newMinH = (rawOldMinH > 0.0) ? MAX(rawOldMinH * unscale, notchObstruction.height + 8.0) : 0.0;
    double rawOldMaxH = [oldH maximum];
    double newMaxH = (heightType == 1) ? MAX(rawOldMaxH * unscale, newMinH) : MAX(rawOldMaxH, newMinH);
    id<MacIslandSizeDimensionRequest> newH =
        [(id<MacIslandSizeDimensionRequest>)[sizeDimCls alloc] initWithMinimum:newMinH
                                                                       maximum:newMaxH
                                                                          type:heightType];

    double oldCR = [expanded cornerRadius];
    double newCR = (oldScale < 1.0) ? (oldCR * oldScale) : oldCR;

    id<MacIslandActivityItemMetricsRequest> newExpanded = [(NSObject *)expanded copy];
    [newExpanded setWidthRequest:newW];
    [newExpanded setHeightRequest:newH];
    [newExpanded setCornerRadius:newCR];
    [newExpanded setScaleFactor:1.0];
    if ([expanded respondsToSelector:@selector(edgeInsets)] &&
        [newExpanded respondsToSelector:@selector(setEdgeInsets:)]) {
        id<MacIslandActivityEdgeInsets> insets = [expanded edgeInsets];
        double minOutside = MacIslandNotchFlare + 6.0;
        if (insets &&
            [insets respondsToSelector:@selector(leading)] &&
            [insets respondsToSelector:@selector(trailing)] &&
            [insets respondsToSelector:@selector(copyWithZone:)] &&
            ([insets leading] < minOutside || [insets trailing] < minOutside)) {
            id<MacIslandActivityEdgeInsets> newInsets = [(NSObject *)insets copy];
            [newInsets setLeading:MAX([insets leading], minOutside)];
            [newInsets setTrailing:MAX([insets trailing], minOutside)];
            [newExpanded setEdgeInsets:newInsets];
        }
    }

    double oldTopMargin = [sa obstructionTopMargin];
    double newTopMargin = (oldScale < 1.0) ? (oldTopMargin * oldScale) : oldTopMargin;
    id<MacIslandSystemApertureMetricsRequest> newSA = [(NSObject *)sa copy];
    [newSA setObstructionSize:notchObstruction];
    [newSA setObstructionTopMargin:newTopMargin];
    [newSA setExpandedMetricsRequest:newExpanded];
    return [newSA isEqual:sa] ? sa : newSA;
}

static id<MacIslandActivityMetricsRequest> patchedActivityMetricsRequest(
    id<MacIslandActivityMetricsRequest> nativeReq,
    NSScreen *targetScreen,
    BOOL physicalDisplay) {
    if (!nativeReq || !physicalDisplay ||
        ![nativeReq respondsToSelector:@selector(systemApertureMetrics)] ||
        ![nativeReq respondsToSelector:@selector(setSystemApertureMetrics:)] ||
        ![nativeReq respondsToSelector:@selector(copyWithZone:)]) {
        return nativeReq;
    }
    NSRect cutout = NSZeroRect;
    if (!MacIslandScreenNotchCutout(targetScreen, &cutout)) return nativeReq;
    CGSize notchObstruction = CGSizeMake(cutout.size.width + 2.0, cutout.size.height + 2.0);
    CGFloat center = NSMidX(cutout);
    CGFloat centeredDisplayWidth = 2.0 * MIN(center - NSMinX(targetScreen.frame),
                                             NSMaxX(targetScreen.frame) - center);
    if (!(centeredDisplayWidth > notchObstruction.width)) return nativeReq;

    id<MacIslandSystemApertureMetricsRequest> oldSA = [nativeReq systemApertureMetrics];
    id<MacIslandSystemApertureMetricsRequest> newSA =
        patchedSystemApertureMetrics(oldSA, notchObstruction, centeredDisplayWidth);
    id<MacIslandSystemApertureMetricsRequest> oldLimSA = nil, newLimSA = nil;
    if ([nativeReq respondsToSelector:@selector(limitedWidthSystemApertureMetrics)] &&
        [nativeReq respondsToSelector:@selector(setLimitedWidthSystemApertureMetrics:)]) {
        oldLimSA = [nativeReq limitedWidthSystemApertureMetrics];
        if (oldLimSA) {
            newLimSA = patchedSystemApertureMetrics(oldLimSA, notchObstruction, centeredDisplayWidth);
        }
    }
    if (newSA == oldSA && newLimSA == oldLimSA) return nativeReq;

    id<MacIslandActivityMetricsRequest> copy = [(NSObject *)nativeReq copy];
    if (newSA != oldSA) [copy setSystemApertureMetrics:newSA];
    if (newLimSA != oldLimSA) [copy setLimitedWidthSystemApertureMetrics:newLimSA];
    return [copy isEqual:nativeReq] ? nativeReq : copy;
}

static MacIslandActivityMetricsSummary refreshActivityMetrics(id settings, MacIslandSceneInsets *state,
                                                              NSScreen *targetScreen, BOOL physicalDisplay) {
    if (!state.nativeActivityMetricsData) {
        id existing = existingObjectSetting(settings, @"metrics");
        if ([existing isKindOfClass:NSData.class]) state.nativeActivityMetricsData = existing;
    }
    if (!state.nativeActivityMetricsRequest) {
        state.nativeActivityMetricsRequest = existingObjectSetting(settings, @"metricsRequest");
    }

    MacIslandActivityMetricsSummary summary = {0};
    NSRect cutout = NSZeroRect;
    BOOL hasCutout = physicalDisplay && MacIslandScreenNotchCutout(targetScreen, &cutout);
    CGFloat center = hasCutout ? NSMidX(cutout) : 0.0;
    CGFloat centeredWidth = hasCutout
        ? 2.0 * MIN(center - NSMinX(targetScreen.frame), NSMaxX(targetScreen.frame) - center)
        : 0.0;
    if (!hasCutout) cutout = NSZeroRect;

    if (state.nativeActivityMetricsData) {
        NSData *patchedData = nil;
        if (state.cachedActivityMetricsSource == state.nativeActivityMetricsData &&
            NSEqualRects(state.cachedActivityMetricsCutout, cutout) &&
            fabs(state.cachedActivityMetricsDisplayWidth - centeredWidth) < 0.001) {
            patchedData = state.cachedPatchedActivityMetricsData;
            summary = state.cachedActivitySummary;
        } else {
            id<MacIslandActivityMetricsRequest> decoded = decodeActivityMetricsData(state.nativeActivityMetricsData);
            if (decoded) {
                id<MacIslandActivityMetricsRequest> rewritten =
                    patchedActivityMetricsRequest(decoded, targetScreen, physicalDisplay);
                BOOL changed = (rewritten != decoded && ![rewritten isEqual:decoded]);
                if (changed) patchedData = encodeActivityMetricsData(rewritten);
                id<MacIslandActivityMetricsRequest> active = (changed && patchedData) ? rewritten : decoded;
                CGFloat unusedMinH = 0.0, unusedMaxH = 0.0;
                if (readSystemApertureSummary(decoded, &summary.nativeObstruction,
                                              &summary.nativeExpandedMinW, &summary.nativeExpandedMaxW,
                                              &unusedMinH, &unusedMaxH,
                                              &summary.nativeExpandedScale, &summary.nativeExpandedCornerRadius) &&
                    readSystemApertureSummary(active, &summary.patchedObstruction,
                                              &summary.patchedExpandedMinW, &summary.patchedExpandedMaxW,
                                              &summary.patchedExpandedMinH, &summary.patchedExpandedMaxH,
                                              &summary.patchedExpandedScale, &summary.patchedExpandedCornerRadius)) {
                    summary.present = YES;
                    summary.patched = (changed && patchedData != nil);
                }
            }
            state.cachedActivityMetricsSource = state.nativeActivityMetricsData;
            state.cachedActivityMetricsCutout = cutout;
            state.cachedActivityMetricsDisplayWidth = centeredWidth;
            state.cachedPatchedActivityMetricsData = patchedData;
            state.cachedActivitySummary = summary;
        }
        BOOL shouldApply = (patchedData != nil);
        if (originalActivityMetricsData && (shouldApply || state.activityMetricsDataApplied)) {
            NSData *toWrite = shouldApply
                ? layoutPayload(patchedData, state.nativeActivityMetricsData)
                : state.nativeActivityMetricsData;
            originalActivityMetricsData(settings, @selector(setMetrics:), toWrite);
            if (shouldApply) {
                id stored = rawObjectSetting(settings, @"metrics");
                if (stored && stored != state.nativeActivityMetricsData) {
                    layoutPayload(stored, state.nativeActivityMetricsData);
                }
            }
        }
        state.activityMetricsDataApplied = shouldApply;
    }

    if (state.nativeActivityMetricsRequest) {
        id<MacIslandActivityMetricsRequest> nativeReq = state.nativeActivityMetricsRequest;
        id<MacIslandActivityMetricsRequest> rewritten =
            patchedActivityMetricsRequest(nativeReq, targetScreen, physicalDisplay);
        BOOL shouldApply = (rewritten != nativeReq && ![rewritten isEqual:nativeReq]);
        if (!summary.present) {
            CGFloat unusedMinH = 0.0, unusedMaxH = 0.0;
            id<MacIslandActivityMetricsRequest> active = shouldApply ? rewritten : nativeReq;
            if (readSystemApertureSummary(nativeReq, &summary.nativeObstruction,
                                          &summary.nativeExpandedMinW, &summary.nativeExpandedMaxW,
                                          &unusedMinH, &unusedMaxH,
                                          &summary.nativeExpandedScale, &summary.nativeExpandedCornerRadius) &&
                readSystemApertureSummary(active, &summary.patchedObstruction,
                                          &summary.patchedExpandedMinW, &summary.patchedExpandedMaxW,
                                          &summary.patchedExpandedMinH, &summary.patchedExpandedMaxH,
                                          &summary.patchedExpandedScale, &summary.patchedExpandedCornerRadius)) {
                summary.present = YES;
                summary.patched = shouldApply;
            }
        }
        if (originalActivityMetricsRequest && (shouldApply || state.activityMetricsRequestApplied)) {
            id toWrite = shouldApply ? layoutPayload(rewritten, nativeReq) : nativeReq;
            originalActivityMetricsRequest(settings, @selector(setMetricsRequest:), toWrite);
            if (shouldApply) {
                id stored = rawObjectSetting(settings, @"metricsRequest");
                if (stored && stored != nativeReq) layoutPayload(stored, nativeReq);
            }
        }
        state.activityMetricsRequestApplied = shouldApply;
    }
    return summary;
}

static void writeFamily(id settings, NSUInteger family, MacIslandNativeLayout *native, NSData *margins,
                        NSValue *minimum, NSValue *maximum) {
    void (*marginSetter)(id, SEL, id) = originalMargins[family];
    void (*minimumSetter)(id, SEL, id) = originalMinimum[family];
    void (*maximumSetter)(id, SEL, id) = originalMaximum[family];
    if (!marginSetter || !minimumSetter || !maximumSetter) return;
    if (margins || native.applied)
        marginSetter(settings, NSSelectorFromString(familySetter(family, @"LayoutMargins")), margins);
    if (native.minimum)
        minimumSetter(settings, NSSelectorFromString(familySetter(family, @"MinimumSize")), minimum);
    if (native.maximum)
        maximumSetter(settings, NSSelectorFromString(familySetter(family, @"MaximumSize")), maximum);
}
typedef struct {
    BOOL hasData;
    NSUInteger obstructionFamily;
    NSSize viewport;
    MacIslandNotchAvoidance policy;
    CGFloat shortHeight;
    BOOL applies;
    NSData *patchedMargins;
    NSValue *patchedMin;
    NSValue *patchedMax;
} MacIslandFamilyAuditSnapshot;

static NSString *auditLayoutModeName(id rawMode) {
    if (![rawMode isKindOfClass:NSNumber.class]) return nil;
    switch ([rawMode integerValue]) {
        case 0: return @"none";
        case 1: return @"minimal";
        case 2: return @"compact";
        case 3: return @"expanded";
        default: return [NSString stringWithFormat:@"mode_%ld", (long)[rawMode integerValue]];
    }
}

static id auditMarginsDict(NSDictionary *decoded) {
    if (!decoded) return NSNull.null;
    return @{
        @"top": MacIslandAuditDataValue(decoded[@"top"]),
        @"leading": MacIslandAuditDataValue(decoded[@"leading"]),
        @"bottom": MacIslandAuditDataValue(decoded[@"bottom"]),
        @"trailing": MacIslandAuditDataValue(decoded[@"trailing"]),
    };
}

static void emitSceneAudit(NSString *auditPath, id settings, MacIslandSceneInsets *state,
                           NSScreen *targetScreen, BOOL displayKnown, BOOL physicalDisplay,
                           const NSRect rects[2], const NSRect publishedRects[2],
                           const MacIslandFamilyAuditSnapshot snapshots[2],
                           MacIslandActivityMetricsSummary activitySummary) {
    NSRect cutout = NSZeroRect;
    BOOL hasCutout = MacIslandScreenNotchCutout(targetScreen, &cutout);
    id client = MacIslandAuditDataValue(existingObjectSetting(settings, @"clientIdentifier"));
    id persistence = MacIslandAuditDataValue(existingObjectSetting(settings, @"persistenceIdentifier"));
    id elementKind = MacIslandAuditDataValue(existingObjectSetting(settings, @"elementKindIdentifier"));
    id rawMode = existingObjectSetting(settings, @"integratedLayoutMode");
    id modeName = auditLayoutModeName(rawMode) ?: NSNull.null;

    for (NSUInteger family = 0; family < 2; family++) {
        MacIslandFamilyAuditSnapshot snap = snapshots[family];
        if (!snap.hasData) continue;
        MacIslandNativeLayout *nativeLayout = state.layouts[family];
        NSUInteger obsFamily = snap.obstructionFamily;
        MacIslandNativeObstruction *nativeObs = state.obstructions[obsFamily];
        id rawLocation = existingObjectSetting(settings, obstructionSetting(obsFamily, @"Location"))
            ?: existingObjectSetting(settings, @"integratedObstructionLocation");
        id obsLocation = MacIslandAuditDataValue(rawLocation);
        id anchorStyle = MacIslandAuditDataValue(existingObjectSetting(
            settings, family ? @"hostedIntegratedObstructionAnchorStyle" : @"integratedObstructionAnchorStyle"));
        id firstBaseline = MacIslandAuditDataValue(existingObjectSetting(
            settings, family ? @"hostedFirstTextBaselineFromTop" : @"elementViewFirstTextBaselineFromTop"));

        NSDictionary *nativeMargins = decodedMargins(nativeLayout.margins);
        NSDictionary *afterMargins = snap.patchedMargins == nativeLayout.margins
            ? nativeMargins : decodedMargins(snap.patchedMargins);
        BOOL includeActivity = (family == 0 && activitySummary.present);

        NSDictionary *record = @{
            @"event": @"scene_settings",
            @"family": family ? @"hosted" : @"elementView",
            @"obstructionFamily": obsFamily ? @"hosted" : @"elementView",
            @"client": client,
            @"persistenceId": persistence,
            @"elementKind": elementKind,
            @"layoutMode": modeName,
            @"layoutModeRaw": MacIslandAuditDataValue(rawMode),
            @"obstructionLocation": obsLocation,
            @"anchorStyle": anchorStyle,
            @"firstBaselineFromTop": firstBaseline,
            @"displayKnown": @(displayKnown),
            @"physicalDisplay": @(physicalDisplay),
            @"notch": hasCutout ? @{
                @"x": MacIslandAuditNumber(cutout.origin.x),
                @"y": MacIslandAuditNumber(cutout.origin.y),
                @"w": MacIslandAuditNumber(cutout.size.width),
                @"h": MacIslandAuditNumber(cutout.size.height),
                @"centeredDisplayWidth": MacIslandAuditNumber(snap.policy.centeredDisplayWidth),
            } : NSNull.null,
            @"sceneFrame": MacIslandAuditRectDict(state.frame),
            @"viewport": MacIslandAuditSizeDict(snap.viewport),
            @"native": @{
                @"margins": auditMarginsDict(nativeMargins),
                @"min": nativeLayout.minimum ? MacIslandAuditSizeDict(nativeLayout.minimum.sizeValue) : NSNull.null,
                @"max": nativeLayout.maximum ? MacIslandAuditSizeDict(nativeLayout.maximum.sizeValue) : NSNull.null,
                @"obstructionRect": nativeObs.rect ? MacIslandAuditRectDict(nativeObs.rect.rectValue) : NSNull.null,
                @"obstructionSpace": nativeObs.space ? MacIslandAuditSizeDict(nativeObs.space.sizeValue) : NSNull.null,
                @"activityMetrics": includeActivity ? @{
                    @"obstructionSize": MacIslandAuditSizeDict(activitySummary.nativeObstruction),
                    @"expandedMinWidth": MacIslandAuditNumber(activitySummary.nativeExpandedMinW),
                    @"expandedMaxWidth": MacIslandAuditNumber(activitySummary.nativeExpandedMaxW),
                    @"expandedScale": MacIslandAuditNumber(activitySummary.nativeExpandedScale),
                    @"expandedCornerRadius": MacIslandAuditNumber(activitySummary.nativeExpandedCornerRadius),
                } : NSNull.null,
            },
            @"policy": @{
                @"physical": @(snap.policy.physical),
                @"intersects": @(snap.policy.intersects),
                @"extendsBelow": @(snap.policy.extendsBelow),
                @"top": MacIslandAuditNumber(snap.policy.top),
                @"leading": MacIslandAuditNumber(snap.policy.leading),
                @"trailing": MacIslandAuditNumber(snap.policy.trailing),
                @"shortHeight": MacIslandAuditNumber(snap.shortHeight),
            },
            @"patched": @{
                @"applied": @(snap.applies),
                @"margins": auditMarginsDict(afterMargins),
                @"min": snap.patchedMin ? MacIslandAuditSizeDict(snap.patchedMin.sizeValue) : NSNull.null,
                @"max": snap.patchedMax ? MacIslandAuditSizeDict(snap.patchedMax.sizeValue) : NSNull.null,
                @"canonicalObstructionRect": nativeObs.rect ? MacIslandAuditRectDict(rects[obsFamily]) : NSNull.null,
                @"publishedObstructionRect": nativeObs.rect ? MacIslandAuditRectDict(publishedRects[obsFamily]) : NSNull.null,
                @"cornersZeroed": @(nativeObs.cornersApplied),
                @"activityMetrics": includeActivity ? @{
                    @"applied": @(activitySummary.patched),
                    @"obstructionSize": MacIslandAuditSizeDict(activitySummary.patchedObstruction),
                    @"expandedMinWidth": MacIslandAuditNumber(activitySummary.patchedExpandedMinW),
                    @"expandedMaxWidth": MacIslandAuditNumber(activitySummary.patchedExpandedMaxW),
                    @"expandedScale": MacIslandAuditNumber(activitySummary.patchedExpandedScale),
                    @"expandedCornerRadius": MacIslandAuditNumber(activitySummary.patchedExpandedCornerRadius),
                } : NSNull.null,
            },
        };
        NSString *signature = MacIslandAuditSerialize(record);
        if (!signature || [state.auditSignatures[family] isEqualToString:signature]) continue;
        state.auditSignatures[family] = signature;
        MacIslandAuditAppendRecord(auditPath, record);
    }
}

static void refreshSceneInsets(id settings, MacIslandSceneInsets *state) {
    if (state.updating) return;
    state.updating = YES;
    BOOL displayKnown = NO;
    NSScreen *resolvedScreen = sceneDisplayScreen(settings, &displayKnown);
    NSScreen *targetScreen = displayKnown ? resolvedScreen : fallbackNotchedScreen();
    NSArray<NSScreen *> *candidates = displayKnown ? (resolvedScreen ? @[resolvedScreen] : @[]) : NSScreen.screens;
    BOOL physicalDisplay = MacIslandScreenHasNotch(targetScreen);
    NSRect rects[2] = {NSZeroRect, NSZeroRect};
    NSRect publishedRects[2] = {NSZeroRect, NSZeroRect};
    BOOL detached[2] = {NO, NO};
    MacIslandFamilyAuditSnapshot snapshots[2] = {{0}, {0}};
    MacIslandActivityMetricsSummary activitySummary =
        refreshActivityMetrics(settings, state, targetScreen, physicalDisplay);
    for (NSUInteger family = 0; family < state.obstructions.count; family++) {
        MacIslandNativeObstruction *native = state.obstructions[family];
        NSRect original = native.rect ? native.rect.rectValue : NSZeroRect;
        rects[family] = canonicalObstruction(original, targetScreen);
        detached[family] = isDetachedObstructionLocation(
            existingObjectSetting(settings, obstructionSetting(family, @"Location")));
    }
    for (NSUInteger family = 0; family < state.layouts.count; family++) {
        MacIslandNativeLayout *native = state.layouts[family];
        if (!native.margins) {
            id value = existingObjectSetting(settings, familySetting(family, @"LayoutMargins"));
            if ([value isKindOfClass:NSData.class]) native.margins = value;
        }
        if (!native.minimum) {
            id value = existingObjectSetting(settings, familySetting(family, @"MinimumSize"));
            if (isSizeValue(value)) native.minimum = value;
        }
        if (!native.maximum) {
            id value = existingObjectSetting(settings, familySetting(family, @"MaximumSize"));
            if (isSizeValue(value)) native.maximum = value;
        }
        // Optional geometry may be absent on early or legacy scene settings.
        // Native size constraints still describe whether the root can extend
        // below the cutout. Use that shared capability until its viewport arrives.
        // The two native transports carry separate obstruction coordinates.
        // Fall back to the other transport only when this one is absent;
        // an explicitly empty rectangle must continue to mean no exclusion.
        NSUInteger obstructionFamily = state.obstructions[family].rect ? family : 1 - family;
        MacIslandNativeObstruction *obstruction = state.obstructions[obstructionFamily];
        BOOL isDetached = detached[obstructionFamily];
        NSRect rect = rects[obstructionFamily];
        NSSize layoutViewport = obstruction.space ? obstruction.space.sizeValue : state.frame.size;
        if (layoutViewport.width <= 0 || layoutViewport.height <= 0) {
            if (native.maximum) layoutViewport = native.maximum.sizeValue;
            else if (native.minimum) layoutViewport = native.minimum.sizeValue;
        }
        MacIslandNotchAvoidance policy = (!isDetached && obstruction.rect && physicalDisplay) ?
            notchAvoidance(rect, layoutViewport, candidates) : (MacIslandNotchAvoidance){0};
        NSDictionary *before = decodedMargins(native.margins);
        // Compact leading/trailing wing scenes arrive with asymmetric native
        // margins before obstructionSpace is populated. Stabilize their wing
        // margins up front so opening/closing transitions never jump by 6pt.
        if (policy.physical && !obstruction.space &&
            (state.frame.size.width <= 0 || state.frame.size.height <= 0) &&
            layoutViewport.height <= policy.notchHeight + 4 && before) {
            CGFloat lead = [before[@"leading"] doubleValue];
            CGFloat trail = [before[@"trailing"] doubleValue];
            if (lead > 0 && trail == 0) {
                policy.intersects = NO;
                policy.extendsBelow = NO;
                policy.top = 0;
                policy.leading = MacIslandNotchFlare + 6;
                policy.trailing = 6;
            } else if (lead == 0 && trail > 0) {
                policy.intersects = NO;
                policy.extendsBelow = NO;
                policy.top = 0;
                policy.leading = 6;
                policy.trailing = MacIslandNotchFlare + 6;
            }
        }
        CGFloat shortHeight = 0;
        NSData *margins = safeMargins(native.margins, before, policy);
        BOOL applies = margins != native.margins;
        NSValue *minimumValue = native.minimum, *maximumValue = native.maximum;
        if (policy.physical && before && native.minimum && native.maximum) {
            NSDictionary *after = margins == native.margins ? before : decodedMargins(margins);
            CGFloat extraX = [after[@"leading"] doubleValue] - [before[@"leading"] doubleValue] +
                             [after[@"trailing"] doubleValue] - [before[@"trailing"] doubleValue];
            CGFloat extraY = [after[@"top"] doubleValue] - [before[@"top"] doubleValue];
            NSSize minimum = native.minimum.sizeValue, maximum = native.maximum.sizeValue;
            if (policy.extendsBelow && family == 0 && activitySummary.present) {
                // ActivityKit / WidgetRenderer_Activities scenes render Jindo wings from
                // y=0 around SystemApertureMetricsRequest.obstructionSize rather than
                // below elementViewLayoutMargins.top. Match the rewritten Jindo width
                // and height bounds directly without inflating minimum height by extraY.
                CGFloat width = MAX(policy.notchWidth + 164, activitySummary.patchedExpandedMinW);
                CGFloat floor = MAX(minimum.width, MIN(width, policy.centeredDisplayWidth));
                CGFloat ceiling = MIN(MAX(MacIslandExpandedMaxWidth(policy.notchWidth, policy.centeredDisplayWidth),
                                          activitySummary.patchedExpandedMaxW),
                                      policy.centeredDisplayWidth);
                minimum.width = floor;
                if (isfinite(maximum.width)) {
                    maximum.width = MAX(maximum.width, MAX(minimum.width, ceiling));
                }
                CGFloat minExpandedH = MAX(rect.size.height + 8.0, activitySummary.patchedExpandedMinH);
                minimum.height = MAX(minimum.height, MAX(minExpandedH, shortHeight));
                if (isfinite(maximum.height)) {
                    maximum.height = MAX(maximum.height, MAX(minimum.height, activitySummary.patchedExpandedMaxH));
                }
            } else {
                minimum.width += extraX;
                minimum.height = MAX(minimum.height + extraY, shortHeight);
                // Hosted system banners (volume, brightness, AirPods) size their
                // own content below the cutout; their native width stays.
                if (policy.extendsBelow && family == 0) {
                    // Element activities place wing or body content around the cutout.
                    // Reserve at least 57pt per wing outside the 12pt shoulder margin
                    // and 12pt camera clearance (384pt on a 220pt notch for 52pt artwork
                    // or icons), while aligning the ceiling with MenuBarAgent's overridden
                    // HostedSceneMetricsMaximumContentWidth (540pt on a 220pt notch) so
                    // wider providers such as ClockAngel (522pt) and NowPlaying (~390pt)
                    // negotiate freely without CenterHUD outer-platter clipping.
                    CGFloat width = policy.notchWidth + 164;
                    CGFloat floor = MAX(minimum.width, MIN(width, policy.centeredDisplayWidth));
                    CGFloat ceiling = MacIslandExpandedMaxWidth(policy.notchWidth, policy.centeredDisplayWidth);
                    minimum.width = floor;
                    if (isfinite(maximum.width)) {
                        maximum.width = MAX(maximum.width, MAX(minimum.width, ceiling));
                    }
                } else if (isfinite(maximum.width)) {
                    maximum.width = MAX(maximum.width + extraX, minimum.width);
                }
                if (isfinite(maximum.height)) {
                    maximum.height = MAX(maximum.height, minimum.height);
                }
            }
            minimumValue = layoutPayload([NSValue valueWithSize:minimum], native.minimum);
            maximumValue = layoutPayload([NSValue valueWithSize:maximum], native.maximum);
            applies |= !NSEqualSizes(minimum, native.minimum.sizeValue) || !NSEqualSizes(maximum, native.maximum.sizeValue);
        }
        if (applies || native.applied) writeFamily(settings, family, native, margins, minimumValue, maximumValue);
        native.applied = applies;
        snapshots[family] = (MacIslandFamilyAuditSnapshot){
            .hasData = (native.margins != nil || native.minimum != nil || native.maximum != nil ||
                        state.obstructions[family].rect != nil || (family == 0 && activitySummary.present)),
            .obstructionFamily = obstructionFamily,
            .viewport = layoutViewport,
            .policy = policy,
            .shortHeight = shortHeight,
            .applies = applies,
            .patchedMargins = margins,
            .patchedMin = minimumValue,
            .patchedMax = maximumValue,
        };
    }
    for (NSUInteger family = 0; family < state.obstructions.count; family++) {
        MacIslandNativeObstruction *native = state.obstructions[family];
        NSRect original = native.rect ? native.rect.rectValue : NSZeroRect;
        NSRect rect = rects[family];
        NSRect published = detached[family] ? original : rect;
        publishedRects[family] = published;
        void (*setRect)(id, SEL, id) = originalObstruction[family];
        BOOL corrected = !detached[family] && native.rect != nil && !NSEqualRects(published, original);
        if (setRect && (corrected || native.obstructionApplied)) {
            id value = corrected ? layoutPayload([NSValue valueWithRect:published], native.rect) : native.rect;
            setRect(settings, NSSelectorFromString(obstructionSetter(family, @"Rect")), value);
        }
        native.obstructionApplied = corrected;
        void (*setter)(id, SEL, id) = originalCorners[family];
        NSSize extent = NSMakeSize(MAX(NSMaxX(rect), rect.size.width) + 1,
                                  MAX(NSMaxY(rect), rect.size.height) + 2);
        BOOL rectangular = !detached[family] && native.rect && physicalDisplay &&
                           notchAvoidance(rect, extent, candidates).physical && setter;
        if (rectangular) {
            if (!native.rectangularCorners) {
                Class factory = NSClassFromString(@"BSCornerRadiusConfiguration");
                if ([factory instancesRespondToSelector:@selector(initWithCornerRadius:)])
                    native.rectangularCorners = [(id<MacIslandCornerFactory>)[factory alloc] initWithCornerRadius:0];
            }
            if (native.rectangularCorners)
                native.rectangularCorners = layoutPayload(native.rectangularCorners, native.nativeCorners);
        }
        if (native.rectangularCorners && rectangular)
            setter(settings, NSSelectorFromString(obstructionSetter(family, @"CornerRadii")), native.rectangularCorners);
        else if (native.cornersApplied && setter)
            setter(settings, NSSelectorFromString(obstructionSetter(family, @"CornerRadii")), native.nativeCorners);
        native.cornersApplied = rectangular && native.rectangularCorners != nil;
    }
    NSString *auditPath = MacIslandAuditLogPath();
    if (auditPath) {
        emitSceneAudit(auditPath, settings, state, targetScreen, displayKnown, physicalDisplay,
                       rects, publishedRects, snapshots, activitySummary);
    }
    state.updating = NO;
}

static void setFamilyMargins(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    originalMargins[family](settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.layouts[family].margins = [value isKindOfClass:NSData.class] ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyMinimum(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    originalMinimum[family](settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.layouts[family].minimum = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyMaximum(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    originalMaximum[family](settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.layouts[family].maximum = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyObstruction(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    originalObstruction[family](settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstructions[family].rect = isRectValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilySpace(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    originalSpace[family](settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstructions[family].space = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyCorners(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    originalCorners[family](settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstructions[family].nativeCorners = value;
    state.obstructions[family].rectangularCorners = nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyLocation(id settings, SEL selector, id value, NSUInteger family) {
    originalLocation[family](settings, selector, value);
    if (!settingsHaveTrackedValues(settings)) return;
    MacIslandSceneInsets *state = sceneState(settings);
    refreshSceneInsets(settings, state);
}
static void setActivityMetricsData(id settings, SEL selector, id value) {
    value = nativePayload(value);
    originalActivityMetricsData(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.nativeActivityMetricsData = [value isKindOfClass:NSData.class] ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setActivityMetricsRequest(id settings, SEL selector, id value) {
    value = nativePayload(value);
    originalActivityMetricsRequest(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.nativeActivityMetricsRequest = value;
    refreshSceneInsets(settings, state);
}

#define DEFINE_FAMILY_SETTERS(SUFFIX, INDEX) \
    static void setMargins##SUFFIX(id o, SEL s, id v) { setFamilyMargins(o, s, v, INDEX); } \
    static void setMinimum##SUFFIX(id o, SEL s, id v) { setFamilyMinimum(o, s, v, INDEX); } \
    static void setMaximum##SUFFIX(id o, SEL s, id v) { setFamilyMaximum(o, s, v, INDEX); } \
    static void setObstruction##SUFFIX(id o, SEL s, id v) { setFamilyObstruction(o, s, v, INDEX); } \
    static void setSpace##SUFFIX(id o, SEL s, id v) { setFamilySpace(o, s, v, INDEX); } \
    static void setCorners##SUFFIX(id o, SEL s, id v) { setFamilyCorners(o, s, v, INDEX); } \
    static void setLocation##SUFFIX(id o, SEL s, id v) { setFamilyLocation(o, s, v, INDEX); }

DEFINE_FAMILY_SETTERS(Element, 0)
DEFINE_FAMILY_SETTERS(Hosted, 1)

static void setFrame(id settings, SEL selector, CGRect value) {
    originalFrame(settings, selector, value);
    if (!settingsHaveTrackedValues(settings)) return;
    MacIslandSceneInsets *state = sceneState(settings);
    state.frame = value;
    refreshSceneInsets(settings, state);
}
static void setDisplayConfiguration(id settings, SEL selector, id value) {
    originalDisplayConfiguration(settings, selector, value);
    if (!settingsHaveTrackedValues(settings)) return;
    MacIslandSceneInsets *state = sceneState(settings);
    refreshSceneInsets(settings, state);
}

// The scene-extension accessors (margins, minimum size, obstruction…) do not
// exist on FBSSceneSettings until FrontBoardServices registers the matching
// settings extensions, which normally happens lazily on the first expanded or
// hosted scene. Hooks are therefore (re)verified whenever an extension is
// registered, and the known extensions are registered up front.
static pthread_mutex_t contentInsetsHookLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL contentInsetsHooksReported;
static BOOL extensionRegistrationHooked;
static BOOL extensionRegistrationWarningLogged;

static BOOL replaceObjectSetter(Class cls, NSString *name, IMP replacement, void (**original)(id, SEL, id)) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method || strncmp(method_getTypeEncoding(method), "v24@0:8@", strlen("v24@0:8@"))) return NO;
    IMP current = method_getImplementation(method);
    if (current == replacement) return *original != NULL;
    // Either first installation or the accessor was re-synthesized after an
    // earlier hook; in both cases the current implementation is the original.
    *original = (void *)current;
    method_setImplementation(method, replacement);
    return YES;
}
static BOOL installContentInsetsHooksLocked(void);
static BOOL installContentInsetsHooks(void) {
    pthread_mutex_lock(&contentInsetsHookLock);
    BOOL ready = installContentInsetsHooksLocked();
    pthread_mutex_unlock(&contentInsetsHookLock);
    return ready;
}
static id (*originalSettingsExtensions)(id, SEL, id);
static id settingsExtensionsForSceneExtension(id cls, SEL selector, id extension) {
    id result = originalSettingsExtensions(cls, selector, extension);
    installContentInsetsHooks();
    return result;
}
static void observeSettingsExtensionRegistrationLocked(Class cls) {
    if (extensionRegistrationHooked || !cls) return;
    Method method = class_getClassMethod(cls, NSSelectorFromString(@"_settingsExtensionsForSceneExtension:"));
    if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8#16")) {
        if (!extensionRegistrationWarningLogged) {
            extensionRegistrationWarningLogged = YES;
            os_log(OS_LOG_DEFAULT, "MacIsland: settings-extension registration hook unavailable");
        }
        return;
    }
    originalSettingsExtensions = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)settingsExtensionsForSceneExtension);
    extensionRegistrationHooked = YES;
}
static void registerKnownSettingsExtensions(Class cls) {
    if (!cls) return;
    // Instantiate once so FrontBoardServices synthesizes core accessors
    // (setFrame:, setDisplayConfiguration:) before hooks are installed.
    static dispatch_once_t coreOnce;
    dispatch_once(&coreOnce, ^{ (void)[cls new]; });
    SEL selector = NSSelectorFromString(@"_settingsExtensionsForSceneExtension:");
    if (![cls respondsToSelector:selector]) return;
    for (NSString *name in @[@"ElementRegistryFoundation.ElementRegistrySceneExtension",
                             @"MenuBarClient.HostedMetricsExtension",
                             @"MenuBarClient.HostedIntegratedObstructionExtension",
                             @"ActivityUIServices.ElementActivitySceneExtension",
                             @"ActivityUIServices.ActivitySceneExtension"]) {
        Class extension = NSClassFromString(name);
        if (extension) ((id (*)(id, SEL, Class))objc_msgSend)(cls, selector, extension);
    }
}
static BOOL installContentInsetsHooksLocked(void) {
    Class cls = NSClassFromString(@"FBSSceneSettings");
    if (!cls) return NO;
    observeSettingsExtensionRegistrationLocked(cls);
    BOOL ready = YES;
    ready &= replaceObjectSetter(cls, @"setElementViewLayoutMargins:", (IMP)setMarginsElement, &originalMargins[0]);
    ready &= replaceObjectSetter(cls, @"setElementViewMinimumSize:", (IMP)setMinimumElement, &originalMinimum[0]);
    ready &= replaceObjectSetter(cls, @"setElementViewMaximumSize:", (IMP)setMaximumElement, &originalMaximum[0]);
    ready &= replaceObjectSetter(cls, @"setHostedLayoutMargins:", (IMP)setMarginsHosted, &originalMargins[1]);
    ready &= replaceObjectSetter(cls, @"setHostedMinimumSize:", (IMP)setMinimumHosted, &originalMinimum[1]);
    ready &= replaceObjectSetter(cls, @"setHostedMaximumSize:", (IMP)setMaximumHosted, &originalMaximum[1]);
    ready &= replaceObjectSetter(cls, @"setIntegratedObstructionRect:", (IMP)setObstructionElement, &originalObstruction[0]);
    ready &= replaceObjectSetter(cls, @"setIntegratedObstructionRectCoordinateSpace:", (IMP)setSpaceElement, &originalSpace[0]);
    ready &= replaceObjectSetter(cls, @"setIntegratedObstructionCornerRadii:", (IMP)setCornersElement, &originalCorners[0]);
    ready &= replaceObjectSetter(cls, @"setHostedIntegratedObstructionRect:", (IMP)setObstructionHosted, &originalObstruction[1]);
    ready &= replaceObjectSetter(cls, @"setHostedIntegratedObstructionRectCoordinateSpace:", (IMP)setSpaceHosted, &originalSpace[1]);
    ready &= replaceObjectSetter(cls, @"setHostedIntegratedObstructionCornerRadii:", (IMP)setCornersHosted, &originalCorners[1]);
    // Obstruction location, Live Activity metrics, display configuration, and frame are
    // optional or base FBSSceneSettings accessors: hook them when present without blocking readiness.
    replaceObjectSetter(cls, @"setIntegratedObstructionLocation:", (IMP)setLocationElement, &originalLocation[0]);
    replaceObjectSetter(cls, @"setHostedIntegratedObstructionLocation:", (IMP)setLocationHosted, &originalLocation[1]);
    replaceObjectSetter(cls, @"setMetrics:", (IMP)setActivityMetricsData, &originalActivityMetricsData);
    replaceObjectSetter(cls, @"setMetricsRequest:", (IMP)setActivityMetricsRequest, &originalActivityMetricsRequest);
    replaceObjectSetter(cls, @"setDisplayConfiguration:", (IMP)setDisplayConfiguration, &originalDisplayConfiguration);
    Method frameMethod = class_getInstanceMethod(cls, NSSelectorFromString(@"setFrame:"));
    if (frameMethod && strstr(method_getTypeEncoding(frameMethod), "CGRect")
        && method_getImplementation(frameMethod) != (IMP)setFrame) {
        originalFrame = (void *)method_getImplementation(frameMethod);
        method_setImplementation(frameMethod, (IMP)setFrame);
    }
    if (ready && !contentInsetsHooksReported) {
        contentInsetsHooksReported = YES;
        os_log(OS_LOG_DEFAULT, "MacIsland: scene-settings notch hooks installed");
    }
    return ready;
}
// MenuBarAgent's SystemSettingsController clamps expanded CenterHUD containers
// to Settings.hostedSceneMetrics.maximumContentWidth (408pt iPhone default),
// clipping wider notched layouts (470pt Live Activities, 522pt ClockAngel).
// Registering HostedSceneMetricsMaximumContentWidth in volatile NSRegistrationDomain
// lifts the cap in-memory, fires SystemSettingsController's KVO reload immediately,
// leaves zero disk state on uninstall, and restores 408pt when no notch is active.
static void syncHostedSceneMaximumContentWidthWithDefaults(NSUserDefaults *defaults) {
    if (!defaults) return;
    CGFloat targetWidth = 0;
    for (NSScreen *screen in NSScreen.screens) {
        CGFloat screenMax = MacIslandScreenExpandedMaxWidth(screen);
        if (screenMax > targetWidth) targetWidth = screenMax;
    }
    NSDictionary<NSString *, id> *registered = [defaults volatileDomainForName:NSRegistrationDomain];
    id current = registered[MacIslandHostedMaxContentWidthKey];
    if (targetWidth > 0) {
        if ([current isKindOfClass:NSNumber.class] && fabs([current doubleValue] - targetWidth) <= 0.001) {
            return;
        }
        [defaults registerDefaults:@{MacIslandHostedMaxContentWidthKey: @(targetWidth)}];
    } else if (current != nil) {
        // Trigger cross-suite KVO reload (e.g. MenuBarAgent's group suite) back to
        // Apple's 408pt baseline before stripping the volatile registration key.
        [defaults registerDefaults:@{MacIslandHostedMaxContentWidthKey: @(408.0)}];
        NSMutableDictionary<NSString *, id> *updated = [[defaults volatileDomainForName:NSRegistrationDomain] mutableCopy];
        [updated removeObjectForKey:MacIslandHostedMaxContentWidthKey];
        [defaults removeVolatileDomainForName:NSRegistrationDomain];
        if (updated.count > 0) {
            [defaults setVolatileDomain:updated forName:NSRegistrationDomain];
        }
    }
}
static void syncHostedSceneMaximumContentWidth(void) {
    syncHostedSceneMaximumContentWidthWithDefaults(NSUserDefaults.standardUserDefaults);
}
static void displayReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    (void)display;
    (void)context;
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        syncHostedSceneMaximumContentWidth();
    });
}
static void waitForSceneSettings(NSUInteger attempt) {
    syncHostedSceneMaximumContentWidth();
    Class cls = NSClassFromString(@"FBSSceneSettings");
    if (cls) registerKnownSettingsExtensions(cls);
    if (installContentInsetsHooks()) return;
    // The registration hook normally finishes installation; polling is only
    // a fallback, and keeps going slowly instead of giving up.
    int64_t delay = attempt < 20 ? 50 * NSEC_PER_MSEC : attempt < 300 ? 500 * NSEC_PER_MSEC : 5 * NSEC_PER_SEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{ waitForSceneSettings(attempt + 1); });
}
#ifdef MACISLAND_TESTING
BOOL MacIslandInstallSceneSettingsHooksForTesting(void) {
    Class cls = NSClassFromString(@"FBSSceneSettings");
    if (cls) registerKnownSettingsExtensions(cls);
    return installContentInsetsHooks();
}
void MacIslandSyncHostedSceneMaximumContentWidthForTesting(NSUserDefaults *defaults) {
    syncHostedSceneMaximumContentWidthWithDefaults(defaults);
}
#endif
__attribute__((constructor)) static void installNotchContentInsets(void) {
    if (!MacIslandIsMenuBarAgent()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *__unused note) {
            syncHostedSceneMaximumContentWidth();
        }];
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, NULL);
        waitForSceneSettings(0);
    });
}
