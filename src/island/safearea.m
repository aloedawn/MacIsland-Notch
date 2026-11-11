#import <AppKit/AppKit.h>
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
static void (*originalFrame)(id, SEL, CGRect);
static void (*originalDisplayConfiguration)(id, SEL, id);

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
        CGFloat center = NSMidX(cutout);
        policy.centeredDisplayWidth = 2 * MIN(center - NSMinX(screen.frame), NSMaxX(screen.frame) - center);
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
                           const MacIslandFamilyAuditSnapshot snapshots[2]) {
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
            minimum.width += extraX;
            minimum.height = MAX(minimum.height + extraY, shortHeight);
            // Hosted system banners (volume, brightness, AirPods) size their
            // own content below the cutout; their native width stays.
            if (policy.extendsBelow && family == 0) {
                // Element activities place wing or body content around the cutout.
                // Reserve at least 57pt per wing outside the 12pt shoulder margin
                // and 12pt camera clearance (384pt on a 220pt notch for 52pt artwork
                // or icons), while raising the ceiling (>= 504pt) so wider providers
                // such as ClockAngel (494pt) and NowPlaying (~390pt) negotiate freely.
                CGFloat width = policy.notchWidth + 164;
                CGFloat floor = MAX(minimum.width, MIN(width, policy.centeredDisplayWidth));
                CGFloat growth = floor - minimum.width;
                maximum.width += MIN(growth, MAX(0, policy.centeredDisplayWidth - maximum.width - extraX));
                CGFloat ceiling = MIN(policy.notchWidth + 284, policy.centeredDisplayWidth);
                minimum.width = floor;
                maximum.width = MAX(maximum.width + extraX, MAX(minimum.width, ceiling));
            } else {
                maximum.width = MAX(maximum.width + extraX, minimum.width);
            }
            maximum.height = MAX(maximum.height, minimum.height);
            minimumValue = layoutPayload([NSValue valueWithSize:minimum], native.minimum);
            maximumValue = layoutPayload([NSValue valueWithSize:maximum], native.maximum);
            applies |= !NSEqualSizes(minimum, native.minimum.sizeValue) || !NSEqualSizes(maximum, native.maximum.sizeValue);
        }
        if (applies || native.applied) writeFamily(settings, family, native, margins, minimumValue, maximumValue);
        native.applied = applies;
        snapshots[family] = (MacIslandFamilyAuditSnapshot){
            .hasData = (native.margins != nil || native.minimum != nil || native.maximum != nil ||
                        state.obstructions[family].rect != nil),
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
                       rects, publishedRects, snapshots);
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
                             @"MenuBarClient.HostedIntegratedObstructionExtension"]) {
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
    // Obstruction location, display configuration, and frame are optional or
    // base FBSSceneSettings accessors: hook them when present without blocking readiness.
    replaceObjectSetter(cls, @"setIntegratedObstructionLocation:", (IMP)setLocationElement, &originalLocation[0]);
    replaceObjectSetter(cls, @"setHostedIntegratedObstructionLocation:", (IMP)setLocationHosted, &originalLocation[1]);
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
static void waitForSceneSettings(NSUInteger attempt) {
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
#endif
__attribute__((constructor)) static void installNotchContentInsets(void) {
    if (!MacIslandIsMenuBarAgent()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        waitForSceneSettings(0);
    });
}
