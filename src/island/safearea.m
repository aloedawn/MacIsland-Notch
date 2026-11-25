#import "safearea-internal.h"
#import <objc/runtime.h>
#import <objc/message.h>
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
static void (*originalClientIdentifier)(id, SEL, id);
static void (*originalElementKindIdentifier)(id, SEL, id);
static void (*originalActivityMetricsData)(id, SEL, id);
static void (*originalActivityMetricsRequest)(id, SEL, id);
static void (*originalFrame)(id, SEL, CGRect);
static void (*originalDisplayConfiguration)(id, SEL, id);

@implementation MacIslandNativeLayout
@end

@implementation MacIslandNativeObstruction
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

static BOOL isPatchedPayload(id value) {
    return value != nil && objc_getAssociatedObject(value, &originalLayoutPayloadKey) != nil;
}
static id nativePayload(id value) {
    if (!value) return nil;
    id saved = objc_getAssociatedObject(value, &originalLayoutPayloadKey);
    if (!saved) return value;
    return saved == NSNull.null ? nil : saved;
}
id MacIslandLayoutPayload(id value, id original) {
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
id MacIslandRawObjectSetting(id settings, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![settings respondsToSelector:selector]) return nil;
    Method method = class_getInstanceMethod([settings class], selector);
    if (!method || method_getTypeEncoding(method)[0] != '@') return nil;
    id (*getter)(id, SEL) = (void *)method_getImplementation(method);
    return getter(settings, selector);
}
id MacIslandExistingObjectSetting(id settings, NSString *name) {
    return nativePayload(MacIslandRawObjectSetting(settings, name));
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
    id value = MacIslandExistingObjectSetting(settings, @"frame");
    return isRectValue(value) ? [value rectValue] : CGRectZero;
}
static NSString *familySetting(NSUInteger family, NSString *suffix) {
    return [(family ? @"hosted" : @"elementView") stringByAppendingString:suffix];
}
static NSString *familySetter(NSUInteger family, NSString *suffix) {
    return [[(family ? @"setHosted" : @"setElementView") stringByAppendingString:suffix] stringByAppendingString:@":"];
}
NSString *MacIslandObstructionSetting(NSUInteger family, NSString *suffix) {
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
static BOOL containsToken(id value, NSString *token) {
    if (!value) return NO;
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    if ([value isKindOfClass:NSData.class]) {
        NSString *text = [[NSString alloc] initWithData:(NSData *)value encoding:NSUTF8StringEncoding];
        if (text) {
            return [text rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound;
        }
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in (NSDictionary *)value) {
            if (containsToken(key, token) || containsToken(((NSDictionary *)value)[key], token)) return YES;
        }
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            if (containsToken(item, token)) return YES;
        }
    }
    return NO;
}
static BOOL isAirDropScene(id settings) {
    return containsToken(MacIslandExistingObjectSetting(settings, @"clientIdentifier"), @"airdrop") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"elementKindIdentifier"), @"airdrop") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"persistenceIdentifier"), @"airdrop");
}
static BOOL isScreenRecordingScene(id settings) {
    return containsToken(MacIslandExistingObjectSetting(settings, @"clientIdentifier"), @"screencaptureui") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"clientIdentifier"), @"screenrecording") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"elementKindIdentifier"), @"screenrecording") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"elementKindIdentifier"), @"screencaptureui") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"persistenceIdentifier"), @"screenrecording") ||
           containsToken(MacIslandExistingObjectSetting(settings, @"persistenceIdentifier"), @"screencaptureui");
}
static BOOL isControlCenterScene(id settings) {
    return containsToken(MacIslandExistingObjectSetting(settings, @"clientIdentifier"), @"controlcenter");
}
static CGFloat controlCenterBatteryBannerTargetWidth(NSSize nativeSize, MacIslandNotchAvoidance policy) {
    if (!isfinite(nativeSize.width) || !isfinite(nativeSize.height)) return 0;
    // Charging (220x50) keeps ~81pt side span; Low Battery (300x60) keeps ~121pt side span.
    // Explicitly exclude 309pt Volume/Brightness HUDs and unrelated banners.
    CGFloat sideSpan = 0;
    if (nativeSize.width >= 180.0 && nativeSize.width <= 240.0 &&
        nativeSize.height >= 44.0 && nativeSize.height <= 56.0) {
        sideSpan = 162.0;
    } else if (nativeSize.width >= 260.0 && nativeSize.width <= 305.0 &&
               nativeSize.height >= 54.0 && nativeSize.height <= 66.0) {
        sideSpan = 242.0;
    }
    if (sideSpan <= 0) return 0;
    return MIN(policy.notchWidth + sideSpan, policy.centeredDisplayWidth);
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
            id rawMargins = MacIslandRawObjectSetting(settings, familySetting(family, @"LayoutMargins"));
            id rawMinimum = MacIslandRawObjectSetting(settings, familySetting(family, @"MinimumSize"));
            id rawMaximum = MacIslandRawObjectSetting(settings, familySetting(family, @"MaximumSize"));
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
            id rawRect = MacIslandRawObjectSetting(settings, MacIslandObstructionSetting(family, @"Rect"));
            id rawSpace = MacIslandRawObjectSetting(settings, MacIslandObstructionSetting(family, @"RectCoordinateSpace"));
            id rawCorners = MacIslandRawObjectSetting(settings, MacIslandObstructionSetting(family, @"CornerRadii"));
            native.obstructionApplied = isPatchedPayload(rawRect);
            native.cornersApplied = isPatchedPayload(rawCorners);
            if (native.cornersApplied) native.rectangularCorners = rawCorners;
            id rect = nativePayload(rawRect);
            id space = nativePayload(rawSpace);
            native.rect = isRectValue(rect) ? rect : nil;
            native.space = isSizeValue(space) ? space : nil;
            native.nativeCorners = nativePayload(rawCorners);
        }
        id rawMetricsData = MacIslandRawObjectSetting(settings, @"metrics");
        state.activityMetricsDataApplied = isPatchedPayload(rawMetricsData);
        id metricsData = nativePayload(rawMetricsData);
        state.nativeActivityMetricsData = [metricsData isKindOfClass:NSData.class] ? metricsData : nil;

        id rawMetricsReq = MacIslandRawObjectSetting(settings, @"metricsRequest");
        state.activityMetricsRequestApplied = isPatchedPayload(rawMetricsReq);
        state.nativeActivityMetricsRequest = nativePayload(rawMetricsReq);
        state.frame = existingFrame(settings);
    }
    return state;
}
static BOOL settingsHaveTrackedValues(id settings) {
    if (objc_getAssociatedObject(settings, &sceneInsetsKey)) return YES;
    for (NSUInteger family = 0; family < 2; family++) {
        if (MacIslandRawObjectSetting(settings, familySetting(family, @"LayoutMargins")) ||
            MacIslandRawObjectSetting(settings, MacIslandObstructionSetting(family, @"Rect")) ||
            MacIslandRawObjectSetting(settings, MacIslandObstructionSetting(family, @"CornerRadii")))
            return YES;
    }
    if (MacIslandRawObjectSetting(settings, @"metrics") || MacIslandRawObjectSetting(settings, @"metricsRequest"))
        return YES;
    return NO;
}

static NSScreen *sceneDisplayScreen(id settings, BOOL *known) {
    id identity = MacIslandExistingObjectSetting(settings, @"displayIdentity");
    if (!identity) identity = MacIslandExistingObjectSetting(MacIslandExistingObjectSetting(settings, @"displayConfiguration"), @"identity");
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
NSDictionary *MacIslandDecodedMargins(NSData *data) {
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
    return MacIslandLayoutPayload(data ?: native, native);
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

static void collectObstructionSnapshots(id settings, MacIslandSceneInsets *state, NSScreen *targetScreen,
                                        NSRect rects[2], BOOL detached[2]) {
    for (NSUInteger family = 0; family < state.obstructions.count; family++) {
        MacIslandNativeObstruction *native = state.obstructions[family];
        NSRect original = native.rect ? native.rect.rectValue : NSZeroRect;
        rects[family] = canonicalObstruction(original, targetScreen);
        detached[family] = isDetachedObstructionLocation(
            MacIslandExistingObjectSetting(settings, MacIslandObstructionSetting(family, @"Location")));
    }
}

static MacIslandFamilyAuditSnapshot applyFamilyLayout(
    id settings,
    MacIslandSceneInsets *state,
    NSUInteger family,
    BOOL physicalDisplay,
    BOOL airDropScene,
    BOOL screenRecordingScene,
    NSArray<NSScreen *> *candidates,
    const NSRect rects[2],
    const BOOL detached[2],
    MacIslandActivityMetricsSummary activitySummary) {
    MacIslandNativeLayout *native = state.layouts[family];
    if (!native.margins) {
        id value = MacIslandExistingObjectSetting(settings, familySetting(family, @"LayoutMargins"));
        if ([value isKindOfClass:NSData.class]) native.margins = value;
    }
    if (!native.minimum) {
        id value = MacIslandExistingObjectSetting(settings, familySetting(family, @"MinimumSize"));
        if (isSizeValue(value)) native.minimum = value;
    }
    if (!native.maximum) {
        id value = MacIslandExistingObjectSetting(settings, familySetting(family, @"MaximumSize"));
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
    NSDictionary *before = MacIslandDecodedMargins(native.margins);
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
        NSDictionary *after = margins == native.margins ? before : MacIslandDecodedMargins(margins);
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
        } else if (policy.extendsBelow && family == 0 && airDropScene) {
            // AirDropUI's ObstructionClearingWidthLayout sizes vertical incoming share
            // and failure cards to 274pt (224pt content + 25pt horizontal margins), so
            // forcing the generic 384pt wing-activity floor leaves 55pt of empty black
            // platter per side. Keep a snug 274pt floor (with >=27pt shoulders outside
            // the notch) while preserving the 569pt ceiling for horizontal progress views.
            CGFloat width = MAX(MacIslandAirDropCardWidth,
                                policy.notchWidth + MacIslandAirDropShoulderSpan);
            CGFloat floor = MAX(minimum.width + extraX, MIN(width, policy.centeredDisplayWidth));
            CGFloat ceiling = MacIslandExpandedMaxWidth(policy.notchWidth, policy.centeredDisplayWidth);
            minimum.width = floor;
            if (isfinite(maximum.width)) {
                maximum.width = MAX(maximum.width + extraX, MAX(minimum.width, ceiling));
            }
            CGFloat minExpandedH = rect.size.height + MacIslandAirDropObstructionClearance + 8.0;
            minimum.height = MAX(minimum.height, MAX(minExpandedH, shortHeight));
            if (isfinite(maximum.height)) {
                maximum.height = MAX(maximum.height, minimum.height);
            }
        } else if (policy.extendsBelow && family == 0 && screenRecordingScene) {
            // screencaptureui frames IntegratedContentView from minimumSize directly
            // (max(min.width, 260) x max(min.height, 60)) and sizes its StopButton as a
            // square expandedHeight() x expandedHeight(). Reserve 100pt per wing beside
            // the notch and keep native expanded height (no extraY) so controls fit cleanly.
            CGFloat width = policy.notchWidth + MacIslandScreenRecordingWingSpan;
            CGFloat floor = MAX(minimum.width, MIN(width, policy.centeredDisplayWidth));
            CGFloat ceiling = MacIslandExpandedMaxWidth(policy.notchWidth, policy.centeredDisplayWidth);
            minimum.width = floor;
            if (isfinite(maximum.width)) {
                maximum.width = MAX(maximum.width, MAX(minimum.width, ceiling));
            }
            CGFloat minExpandedH = rect.size.height + 8.0;
            minimum.height = MAX(minimum.height, MAX(minExpandedH, shortHeight));
            if (isfinite(maximum.height)) {
                maximum.height = MAX(maximum.height, minimum.height);
            }
        } else {
            minimum.width += extraX;
            minimum.height = MAX(minimum.height + extraY, shortHeight);
            // Hosted system banners (volume, brightness, AirPods) keep their own
            // native minimum width while receiving the lifted CenterHUD ceiling.
            if (policy.extendsBelow && family == 0) {
                // Element activities place wing or body content around the cutout.
                // Reserve at least 57pt per wing outside the 12pt shoulder margin
                // and 12pt camera clearance (384pt on a 220pt notch for 52pt artwork
                // or icons), while aligning the ceiling with MenuBarAgent's overridden
                // HostedSceneMetricsMaximumContentWidth (569pt on a 220pt notch) so
                // wider providers such as ClockAngel (522pt) and NowPlaying (~390pt)
                // negotiate freely without CenterHUD outer-platter clipping.
                CGFloat width = policy.notchWidth + 164;
                CGFloat floor = MAX(minimum.width, MIN(width, policy.centeredDisplayWidth));
                CGFloat ceiling = MacIslandExpandedMaxWidth(policy.notchWidth, policy.centeredDisplayWidth);
                minimum.width = floor;
                if (isfinite(maximum.width)) {
                    maximum.width = MAX(maximum.width, MAX(minimum.width, ceiling));
                }
            } else if (policy.extendsBelow && family == 1 && isControlCenterScene(settings)) {
                CGFloat targetWidth = controlCenterBatteryBannerTargetWidth(native.minimum.sizeValue, policy);
                if (targetWidth > 0) {
                    minimum.width = MAX(minimum.width, targetWidth);
                    CGFloat ceiling = MacIslandExpandedMaxWidth(policy.notchWidth, policy.centeredDisplayWidth);
                    if (isfinite(maximum.width)) {
                        maximum.width = MAX(maximum.width, MAX(minimum.width, ceiling));
                    }
                } else if (isfinite(maximum.width)) {
                    maximum.width = MAX(maximum.width + extraX, minimum.width);
                }
            } else if (isfinite(maximum.width)) {
                maximum.width = MAX(maximum.width + extraX, minimum.width);
            }
            if (isfinite(maximum.height)) {
                maximum.height = MAX(maximum.height, minimum.height);
            }
        }
        minimumValue = MacIslandLayoutPayload([NSValue valueWithSize:minimum], native.minimum);
        maximumValue = MacIslandLayoutPayload([NSValue valueWithSize:maximum], native.maximum);
        applies |= !NSEqualSizes(minimum, native.minimum.sizeValue) || !NSEqualSizes(maximum, native.maximum.sizeValue);
    }
    if (applies || native.applied) writeFamily(settings, family, native, margins, minimumValue, maximumValue);
    native.applied = applies;
    return (MacIslandFamilyAuditSnapshot){
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

static void publishObstructionUpdates(id settings, MacIslandSceneInsets *state,
                                      BOOL physicalDisplay, BOOL airDropScene,
                                      NSArray<NSScreen *> *candidates,
                                      const NSRect rects[2], const BOOL detached[2],
                                      const MacIslandFamilyAuditSnapshot snapshots[2],
                                      NSRect publishedRects[2]) {
    for (NSUInteger family = 0; family < state.obstructions.count; family++) {
        MacIslandNativeObstruction *native = state.obstructions[family];
        NSRect original = native.rect ? native.rect.rectValue : NSZeroRect;
        NSRect rect = rects[family];
        NSRect published = detached[family] ? original : rect;
        if (!detached[family] && family == 0 && airDropScene && snapshots[0].policy.extendsBelow) {
            // AirDropUI's LowersBelowObstructionLayout places top icons and incoming
            // previews at CGRectGetMaxY(integratedObstructionRect) - 9pt (tuned for
            // iPhone's pill optical gap), which clips 7pt behind a solid 38pt MacBook
            // camera housing. Extending the published expanded obstruction height by
            // 16pt shifts AirDrop content cleanly below the physical notch while
            // preserving native SwiftUI hit-testing on Decline/Accept controls.
            published.size.height += MacIslandAirDropObstructionClearance;
        }
        publishedRects[family] = published;
        void (*setRect)(id, SEL, id) = originalObstruction[family];
        BOOL corrected = !detached[family] && native.rect != nil && !NSEqualRects(published, original);
        if (setRect && (corrected || native.obstructionApplied)) {
            id value = corrected ? MacIslandLayoutPayload([NSValue valueWithRect:published], native.rect) : native.rect;
            setRect(settings, NSSelectorFromString(obstructionSetter(family, @"Rect")), value);
            if (corrected) {
                id stored = MacIslandRawObjectSetting(settings, MacIslandObstructionSetting(family, @"Rect"));
                if (stored && stored != native.rect) MacIslandLayoutPayload(stored, native.rect);
            }
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
                native.rectangularCorners = MacIslandLayoutPayload(native.rectangularCorners, native.nativeCorners);
        }
        if (native.rectangularCorners && rectangular)
            setter(settings, NSSelectorFromString(obstructionSetter(family, @"CornerRadii")), native.rectangularCorners);
        else if (native.cornersApplied && setter)
            setter(settings, NSSelectorFromString(obstructionSetter(family, @"CornerRadii")), native.nativeCorners);
        native.cornersApplied = rectangular && native.rectangularCorners != nil;
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
    BOOL airDropScene = isAirDropScene(settings);
    BOOL screenRecordingScene = isScreenRecordingScene(settings);
    NSRect rects[2] = {NSZeroRect, NSZeroRect};
    NSRect publishedRects[2] = {NSZeroRect, NSZeroRect};
    BOOL detached[2] = {NO, NO};
    MacIslandFamilyAuditSnapshot snapshots[2] = {{0}, {0}};
    MacIslandActivityMetricsSummary activitySummary = MacIslandRefreshActivityMetrics(
        settings, state, targetScreen, physicalDisplay,
        originalActivityMetricsData, originalActivityMetricsRequest);

    collectObstructionSnapshots(settings, state, targetScreen, rects, detached);
    for (NSUInteger family = 0; family < state.layouts.count; family++) {
        snapshots[family] = applyFamilyLayout(
            settings, state, family, physicalDisplay, airDropScene, screenRecordingScene,
            candidates, rects, detached, activitySummary);
    }
    publishObstructionUpdates(
        settings, state, physicalDisplay, airDropScene, candidates,
        rects, detached, snapshots, publishedRects);

    NSString *auditPath = MacIslandAuditLogPath();
    if (auditPath) {
        MacIslandEmitSceneAudit(auditPath, settings, state, targetScreen, displayKnown, physicalDisplay,
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
static void setClientIdentifier(id settings, SEL selector, id value) {
    originalClientIdentifier(settings, selector, value);
    if (!settingsHaveTrackedValues(settings)) return;
    MacIslandSceneInsets *state = sceneState(settings);
    refreshSceneInsets(settings, state);
}
static void setElementKindIdentifier(id settings, SEL selector, id value) {
    originalElementKindIdentifier(settings, selector, value);
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
    replaceObjectSetter(cls, @"setClientIdentifier:", (IMP)setClientIdentifier, &originalClientIdentifier);
    replaceObjectSetter(cls, @"setElementKindIdentifier:", (IMP)setElementKindIdentifier, &originalElementKindIdentifier);
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
