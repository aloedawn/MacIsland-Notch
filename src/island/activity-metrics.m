#import "safearea-internal.h"
#import <dlfcn.h>
#include <pthread.h>

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

static MacIslandActivityMetricsSummary summarizeActivityTransition(
    id<MacIslandActivityMetricsRequest> original,
    id<MacIslandActivityMetricsRequest> active,
    BOOL applied) {
    MacIslandActivityMetricsSummary summary = {0};
    CGFloat unusedMinH = 0.0, unusedMaxH = 0.0;
    if (readSystemApertureSummary(original, &summary.nativeObstruction,
                                  &summary.nativeExpandedMinW, &summary.nativeExpandedMaxW,
                                  &unusedMinH, &unusedMaxH,
                                  &summary.nativeExpandedScale, &summary.nativeExpandedCornerRadius) &&
        readSystemApertureSummary(active, &summary.patchedObstruction,
                                  &summary.patchedExpandedMinW, &summary.patchedExpandedMaxW,
                                  &summary.patchedExpandedMinH, &summary.patchedExpandedMaxH,
                                  &summary.patchedExpandedScale, &summary.patchedExpandedCornerRadius)) {
        summary.present = YES;
        summary.patched = applied;
    }
    return summary;
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
    CGFloat centeredDisplayWidth = MacIslandCenteredDisplayWidth(targetScreen, cutout);
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

MacIslandActivityMetricsSummary MacIslandRefreshActivityMetrics(
    id settings,
    MacIslandSceneInsets *state,
    NSScreen *targetScreen,
    BOOL physicalDisplay,
    void (*originalActivityMetricsData)(id, SEL, id),
    void (*originalActivityMetricsRequest)(id, SEL, id)) {
    if (!state.nativeActivityMetricsData) {
        id existing = MacIslandExistingObjectSetting(settings, @"metrics");
        if ([existing isKindOfClass:NSData.class]) state.nativeActivityMetricsData = existing;
    }
    if (!state.nativeActivityMetricsRequest) {
        state.nativeActivityMetricsRequest = MacIslandExistingObjectSetting(settings, @"metricsRequest");
    }

    MacIslandActivityMetricsSummary summary = {0};
    NSRect cutout = NSZeroRect;
    BOOL hasCutout = physicalDisplay && MacIslandScreenNotchCutout(targetScreen, &cutout);
    CGFloat centeredWidth = hasCutout ? MacIslandCenteredDisplayWidth(targetScreen, cutout) : 0.0;
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
                summary = summarizeActivityTransition(decoded, active, (changed && patchedData != nil));
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
                ? MacIslandLayoutPayload(patchedData, state.nativeActivityMetricsData)
                : state.nativeActivityMetricsData;
            originalActivityMetricsData(settings, @selector(setMetrics:), toWrite);
            if (shouldApply) {
                id stored = MacIslandRawObjectSetting(settings, @"metrics");
                if (stored && stored != state.nativeActivityMetricsData) {
                    MacIslandLayoutPayload(stored, state.nativeActivityMetricsData);
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
            id<MacIslandActivityMetricsRequest> active = shouldApply ? rewritten : nativeReq;
            summary = summarizeActivityTransition(nativeReq, active, shouldApply);
        }
        if (originalActivityMetricsRequest && (shouldApply || state.activityMetricsRequestApplied)) {
            id toWrite = shouldApply ? MacIslandLayoutPayload(rewritten, nativeReq) : nativeReq;
            originalActivityMetricsRequest(settings, @selector(setMetricsRequest:), toWrite);
            if (shouldApply) {
                id stored = MacIslandRawObjectSetting(settings, @"metricsRequest");
                if (stored && stored != nativeReq) MacIslandLayoutPayload(stored, nativeReq);
            }
        }
        state.activityMetricsRequestApplied = shouldApply;
    }
    return summary;
}
