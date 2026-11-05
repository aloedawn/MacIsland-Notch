#!/bin/bash
# MacIsland Notch: self-contained source build, install, and restore.
# Based on MakrSas/MacIsland a54047f69eceb4eaabd4f80034166fe23c8a0e7e.
set -euo pipefail
MODE="${1:-install}"
case "$MODE" in
  install|--check|--uninstall) ;;
  *) echo "Usage: bash install.sh [--check|--uninstall]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Too many arguments" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "macOS only" >&2; exit 1; }
[[ "$EUID" -ne 0 ]] || { echo "Run as your logged-in user, without sudo." >&2; exit 1; }
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/macisland-notch-install.XXXXXX")"
cleanup() { rm -rf -- "$SCRATCH"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$MODE" != --uninstall ]]; then
  [[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon only" >&2; exit 1; }
  [[ "$(sw_vers -buildVersion)" == 26C5035r ]] || {
    echo "Supported build: macOS 27.3 beta 26C5035r only." >&2; exit 1;
  }
  xcode-select -p >/dev/null 2>&1 || {
    echo "Install Xcode Command Line Tools first: xcode-select --install" >&2; exit 1;
  }
  if [[ "$MODE" == install ]]; then
    csrutil status | grep -q 'status: disabled' || {
      echo "SIP must already be disabled; no protection settings were changed." >&2; exit 1;
    }
    sysctl -n kern.bootargs | grep -Eq '(^|[[:space:]])amfi_get_out_of_my_way=0x1([[:space:]]|$)' || {
      echo "The running boot requires amfi_get_out_of_my_way=0x1; no boot settings were changed." >&2; exit 1;
    }
  fi

  cat > "$SCRATCH/island.c" <<'MACISLAND_ISLAND_C'
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
extern int IsAppleInternalBuild(void);
static int fake_IsAppleInternalBuild(void) {
    const char *n = getprogname();
    if (n && strcmp(n, "MenuBarAgent") == 0) return 1;
    return IsAppleInternalBuild();
}
__attribute__((used)) static struct { const void *r; const void *o; } interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)fake_IsAppleInternalBuild, (const void *)IsAppleInternalBuild },
};

MACISLAND_ISLAND_C

  cat > "$SCRATCH/notch-layout.h" <<'MACISLAND_NOTCH_LAYOUT_H'
#import <CoreGraphics/CoreGraphics.h>

// A shallow shoulder preserves the native content area's horizontal room.
static const CGFloat MacIslandNotchFlare = 4;

MACISLAND_NOTCH_LAYOUT_H

  cat > "$SCRATCH/notch.m" <<'MACISLAND_NOTCH_M'
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>

typedef NSRect (*FrameGetter)(id, SEL);

static FrameGetter originalDefaultFrame;
static FrameGetter originalHardwareFrame;
static FrameGetter originalMinimalFrame;

static NSRect physicalNotch(NSScreen *screen) {
    NSRect left = screen.auxiliaryTopLeftArea;
    NSRect right = screen.auxiliaryTopRightArea;
    CGFloat height = screen.safeAreaInsets.top;
    CGFloat width = NSMinX(right) - NSMaxX(left);
    if (height <= 0 || NSIsEmptyRect(left) || NSIsEmptyRect(right) || width <= 0)
        return NSZeroRect;
    return NSMakeRect(NSMaxX(left), NSMaxY(screen.frame) - height, width, height);
}

static NSRect defaultFrame(id screen, SEL selector) {
    NSRect notch = physicalNotch(screen);
    return NSIsEmptyRect(notch) ? originalDefaultFrame(screen, selector) : notch;
}

static NSRect hardwareFrame(id screen, SEL selector) {
    NSRect notch = physicalNotch(screen);
    return NSIsEmptyRect(notch) ? originalHardwareFrame(screen, selector) : notch;
}

static NSRect minimalFrame(id screen, SEL selector) {
    NSRect notch = physicalNotch(screen);
    return NSIsEmptyRect(notch) ? originalMinimalFrame(screen, selector) : notch;
}

__attribute__((constructor))
static void installNotchGeometry(void) {
    const char *name = getprogname();
    if (!name || strcmp(name, "MenuBarAgent") != 0) return;
    Class screen = NSScreen.class;
    Method defaultMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDDefaultFrame"));
    Method hardwareMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDHardwareFrame"));
    Method minimalMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDMinimalObstructionFrame"));
    if (!defaultMethod || !hardwareMethod || !minimalMethod) return;
    if (strcmp(method_getTypeEncoding(defaultMethod), method_getTypeEncoding(hardwareMethod)) != 0 ||
        strcmp(method_getTypeEncoding(defaultMethod), method_getTypeEncoding(minimalMethod)) != 0) return;
    originalDefaultFrame = (FrameGetter)method_getImplementation(defaultMethod);
    originalHardwareFrame = (FrameGetter)method_getImplementation(hardwareMethod);
    originalMinimalFrame = (FrameGetter)method_getImplementation(minimalMethod);
    method_setImplementation(defaultMethod, (IMP)defaultFrame);
    method_setImplementation(hardwareMethod, (IMP)hardwareFrame);
    method_setImplementation(minimalMethod, (IMP)minimalFrame);
}

MACISLAND_NOTCH_M

  cat > "$SCRATCH/safearea.m" <<'MACISLAND_SAFEAREA_M'
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "notch-layout.h"
#include <stdlib.h>
#include <string.h>

// One physical exclusion policy at the shared FBS scene-settings boundary.
// Both ElementRegistry and MenuBarClient receive it, regardless of provider.
static char sceneInsetsKey, originalLayoutPayloadKey;
static void (*originalMargins)(id, SEL, id), (*originalMinimum)(id, SEL, id), (*originalMaximum)(id, SEL, id);
static void (*originalHostedMargins)(id, SEL, id), (*originalHostedMinimum)(id, SEL, id), (*originalHostedMaximum)(id, SEL, id);
static void (*originalObstruction)(id, SEL, id), (*originalSpace)(id, SEL, id), (*originalCorners)(id, SEL, id);
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
@interface MacIslandSceneInsets : NSObject
@property(nonatomic, strong) NSArray<MacIslandNativeLayout *> *layouts;
@property(nonatomic, strong) NSValue *obstruction;
@property(nonatomic, strong) NSValue *space;
@property(nonatomic) CGRect frame;
@property(nonatomic, strong) id nativeCorners;
@property(nonatomic, strong) id rectangularCorners;
@property(nonatomic) BOOL cornersApplied;
@property(nonatomic) BOOL obstructionApplied;
@property(nonatomic) BOOL updating;
@end
@implementation MacIslandSceneInsets
- (instancetype)init {
    self = [super init];
    if (self) _layouts = @[[MacIslandNativeLayout new], [MacIslandNativeLayout new]];
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
} MacIslandNotchAvoidance;

static id nativePayload(id value) {
    return value ? (objc_getAssociatedObject(value, &originalLayoutPayloadKey) ?: value) : nil;
}
static id layoutPayload(id value, id original) {
    if (value && value != original && original)
        objc_setAssociatedObject(value, &originalLayoutPayloadKey, nativePayload(original), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return value;
}
static BOOL isSizeValue(id value) {
    return [value isKindOfClass:NSValue.class] && !strcmp([value objCType], @encode(NSSize));
}
static BOOL isRectValue(id value) {
    return [value isKindOfClass:NSValue.class] && !strcmp([value objCType], @encode(NSRect));
}
static id existingObjectSetting(id settings, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![settings respondsToSelector:selector]) return nil;
    Method method = class_getInstanceMethod([settings class], selector);
    if (!method || method_getTypeEncoding(method)[0] != '@') return nil;
    id (*getter)(id, SEL) = (void *)method_getImplementation(method);
    return nativePayload(getter(settings, selector));
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
static MacIslandSceneInsets *sceneState(id settings) {
    MacIslandSceneInsets *state = objc_getAssociatedObject(settings, &sceneInsetsKey);
    if (!state) {
        state = [MacIslandSceneInsets new];
        objc_setAssociatedObject(settings, &sceneInsetsKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id rect = existingObjectSetting(settings, @"integratedObstructionRect");
        id space = existingObjectSetting(settings, @"integratedObstructionRectCoordinateSpace");
        state.obstruction = isRectValue(rect) ? rect : nil;
        state.space = isSizeValue(space) ? space : nil;
        state.frame = existingFrame(settings);
        state.nativeCorners = existingObjectSetting(settings, @"integratedObstructionCornerRadii");
    }
    return state;
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
        Method method = class_getInstanceMethod([settings class], selector);
        if (method && method_getTypeEncoding(method)[0] == 'I') {
            uint32_t (*getter)(id, SEL) = (void *)method_getImplementation(method);
            displayID = getter(settings, selector);
        }
    }
    *known = displayID != 0;
    for (NSScreen *screen in NSScreen.screens)
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) return screen;
    return nil;
}
static BOOL screenHasNotch(NSScreen *screen) {
    return screen.safeAreaInsets.top > 0 && !NSIsEmptyRect(screen.auxiliaryTopLeftArea) &&
           !NSIsEmptyRect(screen.auxiliaryTopRightArea);
}
static NSRect canonicalObstruction(NSRect native, NSScreen *screen) {
    if (!screenHasNotch(screen) || NSIsEmptyRect(native) || !isfinite(native.origin.x) ||
        !isfinite(native.origin.y) || !isfinite(native.size.width) || !isfinite(native.size.height)) return native;
    CGFloat width = NSMinX(screen.auxiliaryTopRightArea) - NSMaxX(screen.auxiliaryTopLeftArea);
    // Correct the common obstruction itself, including legacy pill metrics.
    // Preserve its scene-local horizontal anchor and existing vertical origin.
    return NSMakeRect(NSMidX(native) - (width + 2) / 2, native.origin.y,
                      width + 2, screen.safeAreaInsets.top + 2);
}

static MacIslandNotchAvoidance notchAvoidance(NSRect obstruction, NSSize viewport) {
    MacIslandNotchAvoidance policy = {0};
    if (!isfinite(obstruction.origin.x) || !isfinite(obstruction.origin.y) ||
        !isfinite(obstruction.size.width) || !isfinite(obstruction.size.height) ||
        obstruction.size.width <= 0 || obstruction.size.height <= 0) return policy;
    if (!isfinite(viewport.width) || !isfinite(viewport.height) || viewport.width <= 0 || viewport.height <= 0) return policy;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea;
        CGFloat height = screen.safeAreaInsets.top;
        CGFloat width = NSMinX(right) - NSMaxX(left);
        if (height <= 0 || NSIsEmptyRect(left) || NSIsEmptyRect(right) || width <= 0) continue;
        // Match the physical obstruction itself, not a provider's width,
        // centering, scene height, identity, or display name.
        if (fabs(obstruction.size.width - width) > 4 || fabs(obstruction.size.height - height) > 4 ||
            fabs(obstruction.origin.y) > 3) continue;
        policy.physical = YES;
        policy.notchWidth = width;
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
static NSData *safeMargins(NSData *native, MacIslandNotchAvoidance policy) {
    NSDictionary *decoded = decodedMargins(native);
    if (!policy.physical || !decoded) return native;
    NSMutableDictionary *margins = [decoded mutableCopy];
    margins[@"top"] = @(MAX([decoded[@"top"] doubleValue], policy.top));
    margins[@"leading"] = @(MAX([decoded[@"leading"] doubleValue], policy.leading));
    margins[@"trailing"] = @(MAX([decoded[@"trailing"] doubleValue], policy.trailing));
    if ([margins isEqualToDictionary:decoded]) return native;
    NSData *data = [NSJSONSerialization dataWithJSONObject:margins options:NSJSONWritingSortedKeys error:NULL];
    return layoutPayload(data ?: native, native);
}
static void writeFamily(id settings, NSUInteger family, MacIslandNativeLayout *native, NSData *margins,
                        NSValue *minimum, NSValue *maximum) {
    void (*marginSetter)(id, SEL, id) = family ? originalHostedMargins : originalMargins;
    void (*minimumSetter)(id, SEL, id) = family ? originalHostedMinimum : originalMinimum;
    void (*maximumSetter)(id, SEL, id) = family ? originalHostedMaximum : originalMaximum;
    if (!marginSetter || !minimumSetter || !maximumSetter) return;
    marginSetter(settings, NSSelectorFromString(family ? @"setHostedLayoutMargins:" : @"setElementViewLayoutMargins:"), margins);
    if (native.minimum) minimumSetter(settings, NSSelectorFromString(family ? @"setHostedMinimumSize:" : @"setElementViewMinimumSize:"), minimum);
    if (native.maximum) maximumSetter(settings, NSSelectorFromString(family ? @"setHostedMaximumSize:" : @"setElementViewMaximumSize:"), maximum);
}
static void refreshSceneInsets(id settings, MacIslandSceneInsets *state) {
    if (state.updating) return;
    state.updating = YES;
    NSSize viewport = state.space ? state.space.sizeValue : state.frame.size;
    BOOL displayKnown = NO;
    NSScreen *screen = sceneDisplayScreen(settings, &displayKnown);
    NSRect nativeRect = state.obstruction ? state.obstruction.rectValue : NSZeroRect;
    NSRect rect = canonicalObstruction(nativeRect, screen);
    BOOL correctedObstruction = !NSEqualRects(rect, nativeRect);
    if (correctedObstruction && originalObstruction)
        originalObstruction(settings, NSSelectorFromString(@"setIntegratedObstructionRect:"),
            layoutPayload([NSValue valueWithRect:rect], state.obstruction));
    else if (state.obstructionApplied && originalObstruction)
        originalObstruction(settings, NSSelectorFromString(@"setIntegratedObstructionRect:"), state.obstruction);
    state.obstructionApplied = correctedObstruction;
    BOOL physicalDisplay = !displayKnown || screenHasNotch(screen);
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
        NSSize layoutViewport = viewport;
        if (layoutViewport.width <= 0 || layoutViewport.height <= 0) {
            if (native.maximum) layoutViewport = native.maximum.sizeValue;
            else if (native.minimum) layoutViewport = native.minimum.sizeValue;
        }
        MacIslandNotchAvoidance policy = state.obstruction && physicalDisplay ?
            notchAvoidance(rect, layoutViewport) : (MacIslandNotchAvoidance){0};
        NSData *margins = safeMargins(native.margins, policy);
        BOOL applies = margins != native.margins;
        NSValue *minimumValue = native.minimum, *maximumValue = native.maximum;
        if (policy.physical && decodedMargins(native.margins) && native.minimum && native.maximum) {
            NSDictionary *before = decodedMargins(native.margins), *after = decodedMargins(margins);
            CGFloat extraX = [after[@"leading"] doubleValue] - [before[@"leading"] doubleValue] +
                             [after[@"trailing"] doubleValue] - [before[@"trailing"] doubleValue];
            CGFloat extraY = [after[@"top"] doubleValue] - [before[@"top"] doubleValue];
            NSSize minimum = native.minimum.sizeValue, maximum = native.maximum.sizeValue;
            minimum.width += extraX;
            minimum.height += extraY;
            // Preserve the previously requested common expanded-panel width.
            // This floor applies to every intersecting provider, not named cases.
            if (policy.extendsBelow) minimum.width = MAX(minimum.width, policy.notchWidth + 140);
            maximum.width = MAX(maximum.width + extraX, minimum.width);
            maximum.height = MAX(maximum.height, minimum.height);
            minimumValue = layoutPayload([NSValue valueWithSize:minimum], native.minimum);
            maximumValue = layoutPayload([NSValue valueWithSize:maximum], native.maximum);
            applies |= !NSEqualSizes(minimum, native.minimum.sizeValue) || !NSEqualSizes(maximum, native.maximum.sizeValue);
        }
        if (applies || native.applied) writeFamily(settings, family, native, margins, minimumValue, maximumValue);
        native.applied = applies;
    }
    NSSize obstructionExtent = NSMakeSize(MAX(NSMaxX(rect), rect.size.width) + 1,
                                         MAX(NSMaxY(rect), rect.size.height) + 2);
    BOOL rectangular = state.obstruction && physicalDisplay &&
        notchAvoidance(rect, obstructionExtent).physical && originalCorners;
    if (rectangular && !state.rectangularCorners) {
        Class factory = NSClassFromString(@"BSCornerRadiusConfiguration");
        if ([factory instancesRespondToSelector:@selector(initWithCornerRadius:)])
            state.rectangularCorners = layoutPayload([(id<MacIslandCornerFactory>)[factory alloc] initWithCornerRadius:0], state.nativeCorners);
    }
    if (state.rectangularCorners && rectangular)
        originalCorners(settings, NSSelectorFromString(@"setIntegratedObstructionCornerRadii:"), state.rectangularCorners);
    else if (state.cornersApplied && originalCorners)
        originalCorners(settings, NSSelectorFromString(@"setIntegratedObstructionCornerRadii:"), state.nativeCorners);
    state.cornersApplied = rectangular && state.rectangularCorners != nil;
    state.updating = NO;
}

static void setFamilyMargins(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    (family ? originalHostedMargins : originalMargins)(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.layouts[family].margins = [value isKindOfClass:NSData.class] ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyMinimum(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    (family ? originalHostedMinimum : originalMinimum)(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.layouts[family].minimum = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyMaximum(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    (family ? originalHostedMaximum : originalMaximum)(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.layouts[family].maximum = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setMargins(id o, SEL s, id v) { setFamilyMargins(o, s, v, 0); }
static void setMinimum(id o, SEL s, id v) { setFamilyMinimum(o, s, v, 0); }
static void setMaximum(id o, SEL s, id v) { setFamilyMaximum(o, s, v, 0); }
static void setHostedMargins(id o, SEL s, id v) { setFamilyMargins(o, s, v, 1); }
static void setHostedMinimum(id o, SEL s, id v) { setFamilyMinimum(o, s, v, 1); }
static void setHostedMaximum(id o, SEL s, id v) { setFamilyMaximum(o, s, v, 1); }
static void setObstruction(id settings, SEL selector, id value) {
    value = nativePayload(value);
    originalObstruction(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstruction = isRectValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setSpace(id settings, SEL selector, id value) {
    originalSpace(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.space = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setCorners(id settings, SEL selector, id value) {
    value = nativePayload(value);
    originalCorners(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.nativeCorners = value;
    state.rectangularCorners = nil;
    refreshSceneInsets(settings, state);
}
static void setFrame(id settings, SEL selector, CGRect value) {
    originalFrame(settings, selector, value);
    MacIslandSceneInsets *state = objc_getAssociatedObject(settings, &sceneInsetsKey);
    if (state) { state.frame = value; refreshSceneInsets(settings, state); }
}
static void setDisplayConfiguration(id settings, SEL selector, id value) {
    originalDisplayConfiguration(settings, selector, value);
    MacIslandSceneInsets *state = objc_getAssociatedObject(settings, &sceneInsetsKey);
    if (state) refreshSceneInsets(settings, state);
}
static BOOL replaceObjectSetter(Class cls, NSString *name, IMP replacement, void (**original)(id, SEL, id)) {
    if (*original) return YES;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method || strncmp(method_getTypeEncoding(method), "v24@0:8@", strlen("v24@0:8@"))) return NO;
    *original = (void *)method_getImplementation(method);
    method_setImplementation(method, replacement);
    return YES;
}
static BOOL installContentInsetsHooks(void) {
    Class cls = NSClassFromString(@"FBSSceneSettings");
    if (!cls) return NO;
    BOOL ready = YES;
    ready &= replaceObjectSetter(cls, @"setElementViewLayoutMargins:", (IMP)setMargins, &originalMargins);
    ready &= replaceObjectSetter(cls, @"setElementViewMinimumSize:", (IMP)setMinimum, &originalMinimum);
    ready &= replaceObjectSetter(cls, @"setElementViewMaximumSize:", (IMP)setMaximum, &originalMaximum);
    ready &= replaceObjectSetter(cls, @"setHostedLayoutMargins:", (IMP)setHostedMargins, &originalHostedMargins);
    ready &= replaceObjectSetter(cls, @"setHostedMinimumSize:", (IMP)setHostedMinimum, &originalHostedMinimum);
    ready &= replaceObjectSetter(cls, @"setHostedMaximumSize:", (IMP)setHostedMaximum, &originalHostedMaximum);
    ready &= replaceObjectSetter(cls, @"setIntegratedObstructionRect:", (IMP)setObstruction, &originalObstruction);
    ready &= replaceObjectSetter(cls, @"setIntegratedObstructionRectCoordinateSpace:", (IMP)setSpace, &originalSpace);
    ready &= replaceObjectSetter(cls, @"setIntegratedObstructionCornerRadii:", (IMP)setCorners, &originalCorners);
    ready &= replaceObjectSetter(cls, @"setDisplayConfiguration:", (IMP)setDisplayConfiguration, &originalDisplayConfiguration);
    if (!originalFrame) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"setFrame:"));
        if (method && strstr(method_getTypeEncoding(method), "CGRect")) {
            originalFrame = (void *)method_getImplementation(method);
            method_setImplementation(method, (IMP)setFrame);
        }
    }
    return ready;
}
static void waitForSceneSettings(NSUInteger attempt) {
    if (installContentInsetsHooks() || attempt >= 300) return;
    int64_t delay = attempt < 20 ? 50 * NSEC_PER_MSEC : 500 * NSEC_PER_MSEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{ waitForSceneSettings(attempt + 1); });
}
__attribute__((constructor)) static void installNotchContentInsets(void) {
    if (strcmp(getprogname(), "MenuBarAgent") != 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{ waitForSceneSettings(0); });
}

MACISLAND_SAFEAREA_M

  cat > "$SCRATCH/mask.m" <<'MACISLAND_MASK_M'
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "notch-layout.h"
#include <stdlib.h>
#include <string.h>

static char maskObserverKey;
static void (*originalSetCornerRadius)(id, SEL, CGFloat);
static void (*baseSetBounds)(id, SEL, CGRect);
static void (*baseSetPosition)(id, SEL, CGPoint);

static CGPathRef notchMaskPathAtTop(CGSize size, CGFloat top) {
    CGFloat flare = MIN(MacIslandNotchFlare, MIN(size.width / 4, size.height / 3));
    CGFloat bottom = MIN(14, size.height / 2);
    CGFloat width = size.width;
    CGFloat height = size.height;
    CGFloat k = 0.5522847498307936;
    CGMutablePathRef path = CGPathCreateMutable();
    top = MIN(MAX(top, 0), MAX(height - flare - bottom, 0));
    CGPathMoveToPoint(path, NULL, 0, top);
    CGPathAddLineToPoint(path, NULL, width, top);
    CGPathAddCurveToPoint(path, NULL, width - k * flare, top,
                         width - flare, top + flare - k * flare, width - flare, top + flare);
    CGPathAddLineToPoint(path, NULL, width - flare, height - bottom);
    CGPathAddCurveToPoint(path, NULL, width - flare, height - bottom + k * bottom,
                         width - flare - bottom + k * bottom, height,
                         width - flare - bottom, height);
    CGPathAddLineToPoint(path, NULL, flare + bottom, height);
    CGPathAddCurveToPoint(path, NULL, flare + bottom - k * bottom, height,
                         flare, height - bottom + k * bottom, flare, height - bottom);
    CGPathAddLineToPoint(path, NULL, flare, top + flare);
    CGPathAddCurveToPoint(path, NULL, flare, top + flare - k * flare, k * flare, top, 0, top);
    CGPathCloseSubpath(path);
    return path;
}

static BOOL isOpaqueBlack(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.95) return NO;
    size_t count = CGColorGetNumberOfComponents(color);
    if (count != 2 && count != 4) return NO;
    const CGFloat *components = CGColorGetComponents(color);
    for (size_t i = 0; i + 1 < count; i++)
        if (components[i] > 0.05) return NO;
    return YES;
}

// AppKit screen information is captured on the main thread. Native layer
// updates may arrive on MenuBarAgent's background animation thread.
@interface MacIslandScreenGeometry : NSObject
@property(atomic, copy) NSArray<NSDictionary *> *layouts;
+ (instancetype)shared;
@end
@implementation MacIslandScreenGeometry
+ (instancetype)shared {
    static MacIslandScreenGeometry *geometry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ geometry = [MacIslandScreenGeometry new]; });
    return geometry;
}
@end
static void updateScreenGeometry(void) {
    NSMutableArray *layouts = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSRect left = screen.auxiliaryTopLeftArea;
        NSRect right = screen.auxiliaryTopRightArea;
        if (screen.safeAreaInsets.top <= 0 || NSIsEmptyRect(left) || NSIsEmptyRect(right)) continue;
        [layouts addObject:@{@"size": [NSValue valueWithSize:screen.frame.size],
                            @"height": @(screen.safeAreaInsets.top),
                            @"left": @(NSMaxX(left) - NSMinX(screen.frame)),
                            @"right": @(NSMinX(right) - NSMinX(screen.frame)),
                            @"pixel": @(1 / MAX(screen.backingScaleFactor, 1))}];
    }
    [MacIslandScreenGeometry shared].layouts = layouts;
}

static BOOL isNotchBackground(CALayer *layer) {
    // Include the native rim, shadow, and transparent clipping containers.
    // The latter clip the animated hover highlight: retaining their native
    // pill radius cuts a different outline into an otherwise notched island.
    BOOL fill = [layer.name hasPrefix:@"SimpleViewDisplayItem-"] &&
                ((layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0) ||
                 (layer.shadowColor && layer.shadowOpacity > 0) || layer.masksToBounds);
    BOOL material = [layer.name hasPrefix:@"BackdropViewDisplayItem-"] ||
                    [layer.name hasPrefix:@"GainMapViewDisplayItem-"];
    if (!fill && !material) return NO;
    CALayer *parent = layer.superlayer;
    CGRect frame = layer.frame;
    if (!parent || CGRectGetMinY(frame) > 2) return NO;
    for (NSDictionary *layout in [MacIslandScreenGeometry shared].layouts) {
        CGFloat height = [layout[@"height"] doubleValue];
        CGSize size = [layout[@"size"] sizeValue];
        if (fabs(parent.bounds.size.width - size.width) > 1 ||
            fabs(parent.bounds.size.height - size.height) > 1) continue;
        CGFloat notchLeft = [layout[@"left"] doubleValue];
        CGFloat notchRight = [layout[@"right"] doubleValue];
        if (CGRectGetMinY(frame) >= -height &&
            frame.size.height >= height - 3 && frame.size.height <= size.height * 0.75 &&
            // Native bounds and position are written separately. Intermediate
            // frames can overlap only part of the physical notch; requiring
            // both edges removes the mask between those writes.
            CGRectGetMidX(frame) >= notchLeft && CGRectGetMidX(frame) <= notchRight &&
            MIN(CGRectGetMaxX(frame), notchRight) - MAX(CGRectGetMinX(frame), notchLeft) >=
                (notchRight - notchLeft) / 2) return YES;
    }
    return NO;
}

@class MacIslandNativeMaskObserver;
static void synchronizeNativeCornerModifiers(MacIslandNativeMaskObserver *observer);
static void restoreNativeCornerModifiers(MacIslandNativeMaskObserver *observer);
static void synchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer);
static void removeNativeMaskGeometry(MacIslandNativeMaskObserver *observer);
static id nativeModifierObject(id object, NSString *name);
static BOOL nativeModifierEnabled(id modifier);

@interface MacIslandNativeMaskObserver : NSObject
@property(nonatomic, weak) CALayer *source;
@property(nonatomic, strong) CAShapeLayer *shapeMask;
@property(nonatomic) CGFloat pixelInset;
@property(nonatomic, strong) NSMutableArray *geometryModifiers;
@property(nonatomic, strong) NSMutableArray *nativeMaskGroups;
@property(nonatomic, strong) NSArray<NSString *> *keys;
@property(nonatomic) CGFloat nativeRadius;
@property(nonatomic) BOOL updating;
@property(nonatomic) BOOL applied;
@property(nonatomic) CGRect nativeBounds;
@property(nonatomic) CGPoint nativePosition;
@property(nonatomic) BOOL expandedFill;
@property(nonatomic, strong) NSMutableArray *radiusModifiers;
@property(nonatomic, strong) id nativeMaskGroup;
@property(nonatomic, strong) id nativeMaskSize;
- (instancetype)initWithLayer:(CALayer *)layer;
- (void)refresh;
- (void)refreshMask;
@end

static CAAnimation *animationWithoutPillCorners(CAAnimation *animation) {
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        NSMutableArray *children = [NSMutableArray array];
        BOOL changed = NO;
        for (CAAnimation *child in group.animations) {
            CAAnimation *adjusted = animationWithoutPillCorners(child);
            changed |= adjusted != child;
            [children addObject:adjusted];
        }
        if (!changed) return animation;
        CAAnimationGroup *copy = [group copy];
        copy.animations = children;
        return copy;
    }
    if (![animation isKindOfClass:CAPropertyAnimation.class] ||
        ![((CAPropertyAnimation *)animation).keyPath isEqualToString:@"cornerRadius"]) return animation;
    // Keep the native timing and delegate, while the notch mask owns the shape.
    if ([animation isKindOfClass:CABasicAnimation.class]) {
        CABasicAnimation *copy = [animation copy];
        copy.fromValue = @0;
        copy.toValue = @0;
        copy.byValue = nil;
        if ([copy isKindOfClass:CASpringAnimation.class]) ((CASpringAnimation *)copy).initialVelocity = 0;
        return copy;
    }
    if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
        CAKeyframeAnimation *copy = [animation copy];
        NSMutableArray *values = [NSMutableArray array];
        for (__unused id value in copy.values) [values addObject:@0];
        copy.values = values;
        return copy;
    }
    return animation;
}

static void observeNativeAnimations(CALayer *layer) {
    @synchronized (CALayer.class) {
        static NSMutableSet<NSValue *> *methods;
        if (!methods) methods = [NSMutableSet set];
        Method method = class_getInstanceMethod(layer.class, @selector(addAnimation:forKey:));
        if (!method || [methods containsObject:[NSValue valueWithPointer:method]]) return;
        [methods addObject:[NSValue valueWithPointer:method]];
        void (*previous)(id, SEL, CAAnimation *, NSString *) = (void *)method_getImplementation(method);
        IMP implementation = imp_implementationWithBlock(^(CALayer *target, CAAnimation *animation, NSString *key) {
            id association = objc_getAssociatedObject(target, &maskObserverKey);
            MacIslandNativeMaskObserver *observer = [association isKindOfClass:MacIslandNativeMaskObserver.class] ? association : nil;
            previous(target, @selector(addAnimation:forKey:), observer.applied ? animationWithoutPillCorners(animation) : animation, key);
        });
        method_setImplementation(method, implementation);
    }
}

@implementation MacIslandNativeMaskObserver
- (instancetype)initWithLayer:(CALayer *)layer {
    self = [super init];
    if (self) {
        _source = layer;
        _nativeRadius = layer.cornerRadius;
        _nativeBounds = layer.bounds;
        _nativePosition = layer.position;
        _shapeMask = [CAShapeLayer layer];
        _shapeMask.fillColor = NSColor.whiteColor.CGColor;
        _shapeMask.name = @"MacIslandNativeNotchMask";
        _shapeMask.anchorPoint = CGPointZero;
        _shapeMask.actions = @{@"path": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
        _keys = @[@"bounds", @"position", @"anchorPoint", @"transform",
                  @"superlayer", @"name", @"backgroundColor", @"shadowColor", @"shadowOpacity", @"masksToBounds", @"mask"];
        for (NSString *key in _keys)
            [layer addObserver:self forKeyPath:key options:0 context:&maskObserverKey];
        observeNativeAnimations(layer);
        [self refresh];
    }
    return self;
}

- (void)refresh {
    if (self.updating) return;
    self.updating = YES;
    CALayer *source = self.source;
    BOOL ownsMask = source.mask == self.shapeMask;
    BOOL eligible = source && (self.nativeRadius > 0 || self.applied) && isNotchBackground(source) &&
                    (ownsMask || !source.mask);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (eligible) {
        // Apple's opaque fill is inset by one physical pixel inside its
        // material. Remove only that vertical inset on the existing fill.
        CGFloat inset = 0;
        if ([source.name hasPrefix:@"SimpleViewDisplayItem-"] &&
            isOpaqueBlack(source.backgroundColor) && CATransform3DIsIdentity(source.transform)) {
            CGFloat nativeTop = self.nativePosition.y - source.anchorPoint.y * self.nativeBounds.size.height;
            for (NSDictionary *layout in [MacIslandScreenGeometry shared].layouts) {
                CGSize size = [layout[@"size"] sizeValue];
                if (fabs(source.superlayer.bounds.size.width - size.width) > 1 ||
                    fabs(source.superlayer.bounds.size.height - size.height) > 1) continue;
                CGFloat pixel = [layout[@"pixel"] doubleValue];
                if (nativeTop > 0 && fabs(nativeTop - pixel) < 0.05) inset = pixel;
            }
        }
        if (inset > 0 || self.expandedFill) {
            CGRect bounds = self.nativeBounds;
            CGPoint position = self.nativePosition;
            bounds.size.height += 2 * inset;
            position.y += (2 * source.anchorPoint.y - 1) * inset;
            // MBGated_* ignores ordinary geometry writes outside its gate.
            // Use CALayer's implementation, as for the corner-radius override.
            baseSetBounds(source, @selector(setBounds:), bounds);
            baseSetPosition(source, @selector(setPosition:), position);
        }
        self.expandedFill = inset > 0;
        self.pixelInset = inset;
        originalSetCornerRadius(source, @selector(setCornerRadius:), 0);
        source.mask = self.shapeMask;
        BOOL newlyApplied = !self.applied;
        self.applied = YES;
        synchronizeNativeCornerModifiers(self);
        if (newlyApplied) {
            for (NSString *key in source.animationKeys) {
                CAAnimation *animation = [source animationForKey:key];
                CAAnimation *adjusted = animationWithoutPillCorners(animation);
                if (adjusted != animation) [source addAnimation:adjusted forKey:key];
            }
        }
        [self refreshMask];
    } else if (self.applied) {
        if (self.expandedFill) {
            baseSetBounds(source, @selector(setBounds:), self.nativeBounds);
            baseSetPosition(source, @selector(setPosition:), self.nativePosition);
            self.expandedFill = NO;
        }
        if (ownsMask) source.mask = nil;
        originalSetCornerRadius(source, @selector(setCornerRadius:), self.nativeRadius);
        self.applied = NO;
        restoreNativeCornerModifiers(self);
        removeNativeMaskGeometry(self);
    }
    [CATransaction commit];
    self.updating = NO;
}

- (void)refreshMask {
    CALayer *source = self.source;
    if (!self.applied || !source || source.mask != self.shapeMask) return;
    synchronizeNativeMaskGeometry(self);
    CGRect bounds = source.bounds;
    CGSize size = bounds.size;
    CGPoint position = source.position;
    CGPoint anchor = source.anchorPoint;
    for (id modifier in nativeModifierObject(source, @"presentationModifiers")) {
        if (!nativeModifierEnabled(modifier)) continue;
        NSString *key = nativeModifierObject(modifier, @"keyPath");
        id value = nativeModifierObject(modifier, @"value");
        if (![value isKindOfClass:NSValue.class]) continue;
        const char *type = [value objCType];
        if ([key isEqual:@"bounds.size"] && !strcmp(type, @encode(CGSize))) size = [value sizeValue];
        if ([key isEqual:@"position"] && !strcmp(type, @encode(CGPoint))) position = [value pointValue];
        if ([key isEqual:@"anchorPoint"] && !strcmp(type, @encode(CGPoint))) anchor = [value pointValue];
    }
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return;
    CGFloat scaleY = hypot(source.transform.m21, source.transform.m22);
    CGFloat top = MAX(0, -(position.y - anchor.y * size.height)) / MAX(scaleY, 0.001);
    self.shapeMask.bounds = (CGRect){CGPointZero, size};
    self.shapeMask.position = bounds.origin;
    self.shapeMask.contentsScale = MAX(source.contentsScale, 2);
    CGPathRef path = notchMaskPathAtTop(size, top);
    self.shapeMask.path = path;
    CGPathRelease(path);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context != &maskObserverKey) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (self.updating) return;
    CALayer *source = self.source;
    CGRect bounds = source.bounds;
    CGPoint position = source.position;
    if ([keyPath isEqualToString:@"bounds"]) self.nativeBounds = bounds;
    if ([keyPath isEqualToString:@"position"]) self.nativePosition = position;
    [self refresh];
}

- (void)dealloc {
    removeNativeMaskGeometry(self);
    restoreNativeCornerModifiers(self);
    CALayer *source = _source;
    for (NSString *key in _keys)
        [source removeObserver:self forKeyPath:key context:&maskObserverKey];
    if (source.mask == _shapeMask) {
        if (_expandedFill) {
            baseSetBounds(source, @selector(setBounds:), _nativeBounds);
            baseSetPosition(source, @selector(setPosition:), _nativePosition);
        }
        source.mask = nil;
        originalSetCornerRadius(source, @selector(setCornerRadius:), _nativeRadius);
    }
}
@end

// MenuBarAgent drives hover through CAPresentationModifier, not only
// CABasicAnimation or model setters. A live cornerRadius modifier can restore
// pill clipping over the concave mask. Keep that existing modifier in its
// original native group, but neutralize its rounding while the notch applies.
@interface MacIslandRadiusModifierBinding : NSObject
@property(nonatomic, weak) MacIslandNativeMaskObserver *observer;
@property(nonatomic, weak) id modifier;
@property(atomic, strong) id nativeValue;
@end
@implementation MacIslandRadiusModifierBinding
@end
@interface MacIslandGeometryModifierBinding : MacIslandRadiusModifierBinding
@property(nonatomic, copy) NSString *key;
@end
@implementation MacIslandGeometryModifierBinding
@end
static char radiusModifierBindingKey, geometryModifierBindingKey, nativeMaskGroupObserversKey;
static id adjustedNativeGeometry(MacIslandGeometryModifierBinding *binding, id value);
static void restoreNativeGeometryModifiers(MacIslandNativeMaskObserver *observer);
static void (*originalModifierValue)(id, SEL, id);
static void (*originalModifierValueVelocity)(id, SEL, id, id);
static void (*originalAddPresentationModifier)(id, SEL, id);
static void (*originalSetPresentationModifiers)(id, SEL, id);
static void (*originalRemovePresentationModifier)(id, SEL, id);
static _Thread_local NSUInteger modifierWriteDepth;

static id nativeModifierObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static BOOL modifierNeedsNotch(MacIslandRadiusModifierBinding *binding) {
    MacIslandNativeMaskObserver *observer = binding.observer;
    return observer.applied && isNotchBackground(observer.source);
}
static void setModifierValue(id modifier, SEL selector, id value) {
    MacIslandRadiusModifierBinding *binding = objc_getAssociatedObject(modifier, &radiusModifierBindingKey) ?: objc_getAssociatedObject(modifier, &geometryModifierBindingKey);
    if (modifierWriteDepth || !binding) { originalModifierValue(modifier, selector, value); return; }
    binding.nativeValue = value;
    modifierWriteDepth++;
    originalModifierValue(modifier, selector, [binding isKindOfClass:MacIslandGeometryModifierBinding.class] ? adjustedNativeGeometry((id)binding, value) : (modifierNeedsNotch(binding) ? @0 : value));
    modifierWriteDepth--;
}
static void setModifierValueVelocity(id modifier, SEL selector, id value, id velocity) {
    MacIslandRadiusModifierBinding *binding = objc_getAssociatedObject(modifier, &radiusModifierBindingKey) ?: objc_getAssociatedObject(modifier, &geometryModifierBindingKey);
    if (modifierWriteDepth || !binding) { originalModifierValueVelocity(modifier, selector, value, velocity); return; }
    binding.nativeValue = value;
    BOOL notch = ![binding isKindOfClass:MacIslandGeometryModifierBinding.class] && modifierNeedsNotch(binding);
    modifierWriteDepth++;
    originalModifierValueVelocity(modifier, selector, [binding isKindOfClass:MacIslandGeometryModifierBinding.class] ? adjustedNativeGeometry((id)binding, value) : (notch ? @0 : value), notch ? @0 : velocity);
    modifierWriteDepth--;
}
static void bindNativeCornerModifier(MacIslandNativeMaskObserver *observer, id modifier) {
    if (!originalModifierValue || ![nativeModifierObject(modifier, @"keyPath") isEqual:@"cornerRadius"]) return;
    MacIslandRadiusModifierBinding *binding = objc_getAssociatedObject(modifier, &radiusModifierBindingKey);
    if (!binding) {
        binding = [MacIslandRadiusModifierBinding new];
        binding.modifier = modifier;
        binding.nativeValue = nativeModifierObject(modifier, @"value");
        objc_setAssociatedObject(modifier, &radiusModifierBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (binding.observer != observer) {
        binding.observer = observer;
        if (!observer.radiusModifiers) observer.radiusModifiers = [NSMutableArray array];
        [observer.radiusModifiers addObject:binding];
    }
    if (modifierNeedsNotch(binding)) {
        modifierWriteDepth++;
        originalModifierValue(modifier, NSSelectorFromString(@"setValue:"), @0);
        modifierWriteDepth--;
    }
}
static MacIslandNativeMaskObserver *modelMaskObserver(CALayer *layer) {
    if (layer.modelLayer != layer) return nil;
    id value = objc_getAssociatedObject(layer, &maskObserverKey);
    return [value isKindOfClass:MacIslandNativeMaskObserver.class] ? value : nil;
}
static void addPresentationModifier(CALayer *layer, SEL selector, id modifier) {
    MacIslandNativeMaskObserver *observer = modelMaskObserver(layer);
    if (observer) bindNativeCornerModifier(observer, modifier);
    originalAddPresentationModifier(layer, selector, modifier);
    if (observer.applied) synchronizeNativeMaskGeometry(observer);
}
static void setPresentationModifiers(CALayer *layer, SEL selector, id modifiers) {
    MacIslandNativeMaskObserver *observer = modelMaskObserver(layer);
    if (observer && [modifiers isKindOfClass:NSArray.class])
        for (id modifier in modifiers) bindNativeCornerModifier(observer, modifier);
    originalSetPresentationModifiers(layer, selector, modifiers);
    if (observer.applied) synchronizeNativeMaskGeometry(observer);
}
static void synchronizeNativeCornerModifiers(MacIslandNativeMaskObserver *observer) {
    id modifiers = nativeModifierObject(observer.source, @"presentationModifiers");
    NSIndexSet *expired = [observer.radiusModifiers indexesOfObjectsPassingTest:^BOOL(MacIslandRadiusModifierBinding *binding, __unused NSUInteger index, __unused BOOL *stop) { return !binding.modifier; }];
    if (expired.count) [observer.radiusModifiers removeObjectsAtIndexes:expired];
    if ([modifiers isKindOfClass:NSArray.class])
        for (id modifier in modifiers) bindNativeCornerModifier(observer, modifier);
}
static void restoreNativeCornerModifiers(MacIslandNativeMaskObserver *observer) {
    if (!originalModifierValue) return;
    for (MacIslandRadiusModifierBinding *binding in observer.radiusModifiers) {
        id modifier = binding.modifier;
        if (modifier && binding.observer == observer) {
            modifierWriteDepth++;
            originalModifierValue(modifier, NSSelectorFromString(@"setValue:"), binding.nativeValue);
            modifierWriteDepth--;
        }
    }
}
// Keep vector geometry in the native modifier transaction. The existing
// bounds modifier is shared with the mask; no extra modifier slots, spring,
// raster stretching, or separate display timer are introduced.
static BOOL nativeModifierEnabled(id modifier) {
    SEL selector = NSSelectorFromString(@"isEnabled");
    return [modifier respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(modifier, selector);
}
static id adjustedNativeGeometry(MacIslandGeometryModifierBinding *binding, id value) {
    MacIslandNativeMaskObserver *observer = binding.observer;
    if (!observer.applied || observer.pixelInset <= 0 || ![value isKindOfClass:NSValue.class]) return value;
    if ([binding.key isEqual:@"bounds.size"] && !strcmp([value objCType], @encode(CGSize))) {
        CGSize size = [value sizeValue];
        size.height += 2 * observer.pixelInset;
        return [NSValue valueWithSize:size];
    }
    if ([binding.key isEqual:@"position"] && !strcmp([value objCType], @encode(CGPoint))) {
        CGPoint point = [value pointValue];
        point.y += (2 * observer.source.anchorPoint.y - 1) * observer.pixelInset;
        return [NSValue valueWithPoint:point];
    }
    return value;
}
static void bindNativeGeometryModifier(MacIslandNativeMaskObserver *observer, id modifier) {
    NSString *key = nativeModifierObject(modifier, @"keyPath");
    if (![key isEqual:@"bounds.size"] && ![key isEqual:@"position"]) return;
    MacIslandGeometryModifierBinding *binding = objc_getAssociatedObject(modifier, &geometryModifierBindingKey);
    if (binding.observer && binding.observer != observer) return;
    if (!binding) {
        binding = [MacIslandGeometryModifierBinding new];
        binding.modifier = modifier;
        binding.key = key;
        binding.nativeValue = nativeModifierObject(modifier, @"value");
        objc_setAssociatedObject(modifier, &geometryModifierBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (binding.observer != observer) {
        binding.observer = observer;
        if (!observer.geometryModifiers) observer.geometryModifiers = [NSMutableArray array];
        [observer.geometryModifiers addObject:binding];
    }
    modifierWriteDepth++;
    originalModifierValue(modifier, NSSelectorFromString(@"setValue:"), adjustedNativeGeometry(binding, binding.nativeValue));
    modifierWriteDepth--;
}
static void restoreNativeGeometryModifiers(MacIslandNativeMaskObserver *observer) {
    for (MacIslandGeometryModifierBinding *binding in observer.geometryModifiers) {
        id modifier = binding.modifier;
        if (!modifier || binding.observer != observer) continue;
        modifierWriteDepth++;
        originalModifierValue(modifier, NSSelectorFromString(@"setValue:"), binding.nativeValue);
        modifierWriteDepth--;
        binding.observer = nil;
    }
    [observer.geometryModifiers removeAllObjects];
}
static void removeNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    if (observer.nativeMaskSize && originalRemovePresentationModifier)
        originalRemovePresentationModifier(observer.shapeMask, NSSelectorFromString(@"removePresentationModifier:"), observer.nativeMaskSize);
    observer.nativeMaskSize = nil;
    observer.nativeMaskGroup = nil;
    for (id group in observer.nativeMaskGroups) {
        @synchronized(group) { [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) removeObject:observer]; }
    }
    [observer.nativeMaskGroups removeAllObjects];
    restoreNativeGeometryModifiers(observer);
}
static void synchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    if (!observer.applied || !originalAddPresentationModifier) return;
    id size = nil;
    for (id modifier in nativeModifierObject(observer.source, @"presentationModifiers")) {
        if (!nativeModifierEnabled(modifier)) continue;
        NSString *key = nativeModifierObject(modifier, @"keyPath");
        if ([key isEqual:@"bounds.size"]) size = modifier;
        bindNativeGeometryModifier(observer, modifier);
        id group = nativeModifierObject(modifier, @"group");
        if (!group || !([key isEqual:@"bounds.size"] || [key isEqual:@"position"] || [key isEqual:@"anchorPoint"])) continue;
        if (!observer.nativeMaskGroups) observer.nativeMaskGroups = [NSMutableArray array];
        if (![observer.nativeMaskGroups containsObject:group]) {
            [observer.nativeMaskGroups addObject:group];
            @synchronized(group) {
                NSHashTable *observers = objc_getAssociatedObject(group, &nativeMaskGroupObserversKey);
                if (!observers) {
                    observers = [NSHashTable weakObjectsHashTable];
                    objc_setAssociatedObject(group, &nativeMaskGroupObserversKey, observers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                [observers addObject:observer];
            }
        }
    }
    if (size == observer.nativeMaskSize) return;
    if (observer.nativeMaskSize)
        originalRemovePresentationModifier(observer.shapeMask, NSSelectorFromString(@"removePresentationModifier:"), observer.nativeMaskSize);
    observer.nativeMaskSize = size;
    observer.nativeMaskGroup = nativeModifierObject(size, @"group");
    if (size) originalAddPresentationModifier(observer.shapeMask, NSSelectorFromString(@"addPresentationModifier:"), size);
}
static _Thread_local NSUInteger nativeGroupFlushDepth;
static void refreshNativeGroupMasks(id group) {
    NSArray *observers;
    @synchronized(group) { observers = [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) allObjects]; }
    for (MacIslandNativeMaskObserver *observer in observers) [observer refreshMask];
}
static void installNativeGroupFlushHooks(void) {
    Class groupClass = NSClassFromString(@"CAPresentationModifierGroup");
    for (NSString *name in @[@"flush", @"flushLocally", @"flushWithTransaction"]) {
        Method method = class_getInstanceMethod(groupClass, NSSelectorFromString(name));
        if (!method) continue;
        void (*previous)(id, SEL) = (void *)method_getImplementation(method);
        SEL selector = NSSelectorFromString(name);
        method_setImplementation(method, imp_implementationWithBlock(^(id group) {
            if (nativeGroupFlushDepth++) { previous(group, selector); nativeGroupFlushDepth--; return; }
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            refreshNativeGroupMasks(group);
            previous(group, selector);
            [CATransaction commit]; nativeGroupFlushDepth--;
        }));
    }
    for (NSString *name in @[@"flushWithTargetTime:", @"flushLocallyWithTargetTime:", @"flushWithTransactionAndTargetTime:"]) {
        Method method = class_getInstanceMethod(groupClass, NSSelectorFromString(name));
        if (!method) continue;
        void (*previous)(id, SEL, double) = (void *)method_getImplementation(method);
        SEL selector = NSSelectorFromString(name);
        method_setImplementation(method, imp_implementationWithBlock(^(id group, double time) {
            if (nativeGroupFlushDepth++) { previous(group, selector, time); nativeGroupFlushDepth--; return; }
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            refreshNativeGroupMasks(group);
            previous(group, selector, time);
            [CATransaction commit]; nativeGroupFlushDepth--;
        }));
    }
}
static void removePresentationModifier(CALayer *layer, SEL selector, id modifier) {
    originalRemovePresentationModifier(layer, selector, modifier);
    MacIslandNativeMaskObserver *observer = modelMaskObserver(layer);
    if (observer.applied) synchronizeNativeMaskGeometry(observer);
}

static void installNativeCornerModifierHooks(void) {
    Class modifier = NSClassFromString(@"CAPresentationModifier");
    Method value = class_getInstanceMethod(modifier, NSSelectorFromString(@"setValue:"));
    Method velocity = class_getInstanceMethod(modifier, NSSelectorFromString(@"setValue:velocity:"));
    Method add = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"addPresentationModifier:"));
    Method set = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"setPresentationModifiers:"));
    Method remove = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"removePresentationModifier:"));
    if (!value || !velocity || !add || !set || !remove || originalModifierValue) return;
    originalModifierValue = (void *)method_getImplementation(value);
    originalModifierValueVelocity = (void *)method_getImplementation(velocity);
    originalAddPresentationModifier = (void *)method_getImplementation(add);
    originalSetPresentationModifiers = (void *)method_getImplementation(set);
    originalRemovePresentationModifier = (void *)method_getImplementation(remove);
    method_setImplementation(value, (IMP)setModifierValue);
    method_setImplementation(velocity, (IMP)setModifierValueVelocity);
    method_setImplementation(add, (IMP)addPresentationModifier);
    method_setImplementation(set, (IMP)setPresentationModifiers);
    method_setImplementation(remove, (IMP)removePresentationModifier);
    installNativeGroupFlushHooks();
}

static void setCornerRadius(CALayer *layer, SEL selector, CGFloat radius) {
    // Core Animation calls setters while applying modifiers to presentation
    // copies too. Never register KVO or create a mask on those derived layers.
    // Preserve the model's notch treatment without mutating the model or
    // recursively requesting another presentation copy.
    CALayer *model = layer.modelLayer;
    if (model != layer) {
        id modelAssociation = objc_getAssociatedObject(model, &maskObserverKey);
        MacIslandNativeMaskObserver *observer = [modelAssociation isKindOfClass:MacIslandNativeMaskObserver.class] ? modelAssociation : nil;
        originalSetCornerRadius(layer, selector, observer.applied && isNotchBackground(model) ? 0 : radius);
        return;
    }
    id association = objc_getAssociatedObject(layer, &maskObserverKey);
    if ([association isKindOfClass:MacIslandNativeMaskObserver.class]) {
        MacIslandNativeMaskObserver *observer = association;
        originalSetCornerRadius(layer, selector, radius);
        observer.nativeRadius = radius;
        [observer refresh];
        return;
    }
    originalSetCornerRadius(layer, selector, radius);
    if (radius <= 0 || association ||
        ![NSStringFromClass(layer.class) hasPrefix:@"MBGated_"]) return;
    objc_setAssociatedObject(layer, &maskObserverKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Install before the native creation transaction commits. Deferring to
    // main leaves a newly created expansion background briefly pill-shaped.
    MacIslandNativeMaskObserver *observer = [[MacIslandNativeMaskObserver alloc] initWithLayer:layer];
    objc_setAssociatedObject(layer, &maskObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

__attribute__((constructor))
static void installNativeNotchMask(void) {
    if (strcmp(getprogname(), "MenuBarAgent") != 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        updateScreenGeometry();
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(__unused NSNotification *notification) { updateScreenGeometry(); }];
    });
    Method method = class_getInstanceMethod(CALayer.class, @selector(setCornerRadius:));
    originalSetCornerRadius = (void *)method_getImplementation(method);
    baseSetBounds = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setBounds:)));
    baseSetPosition = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setPosition:)));
    method_setImplementation(method, (IMP)setCornerRadius);
    installNativeCornerModifierHooks();
}

MACISLAND_MASK_M

  cat > "$SCRATCH/loader.py" <<'MACISLAND_LOADER_PY'
"""Inject the Dynamic Island interposer into the next MenuBarAgent process."""

import fcntl
import os
from pathlib import Path
import re
import subprocess
import time


LAUNCHCTL = "/bin/launchctl"
SERVICE = f"gui/{os.getuid()}/com.apple.MenuBarAgent"
ENVIRONMENT_KEY = "DYLD_INSERT_LIBRARIES"
LIBRARY = str(Path.home() / "Library/MacIsland/island.dylib")


def menu_bar_agent_pid():
    """Return the current MenuBarAgent PID, or None while it is restarting."""
    try:
        output = subprocess.check_output([LAUNCHCTL, "print", SERVICE], text=True)
    except subprocess.CalledProcessError:
        return None
    match = re.search(r"^\s*pid = (\d+)", output, re.MULTILINE)
    return int(match.group(1)) if match else None


def main():
    library_path = Path(LIBRARY)
    if not library_path.is_file():
        raise RuntimeError("Missing island.dylib; no launch environment changed")

    # Prevent two login/reload events from racing while they temporarily change
    # the per-user launch environment.
    with (library_path.parent / "loader.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        domain = subprocess.check_output(
            [LAUNCHCTL, "print", f"gui/{os.getuid()}"], text=True
        )
        environment = re.search(
            r"^\tenvironment = \{\n(.*?)^\t\}", domain, re.MULTILINE | re.DOTALL
        )
        if environment is None:
            raise RuntimeError("Cannot establish prior launch environment")

        prior = re.search(
            rf"^\t\t{re.escape(ENVIRONMENT_KEY)} => (.*)$",
            environment.group(1),
            re.MULTILINE,
        )
        old_value = prior.group(1) if prior else None
        previous_pid = menu_bar_agent_pid()
        injected_value = library_path.as_posix()
        if old_value:
            injected_value = f"{old_value}:{injected_value}"

        try:
            subprocess.run(
                [LAUNCHCTL, "setenv", ENVIRONMENT_KEY, injected_value], check=True
            )
            subprocess.run([LAUNCHCTL, "kickstart", "-k", SERVICE], check=True)

            for _ in range(100):
                current_pid = menu_bar_agent_pid()
                if current_pid and current_pid != previous_pid:
                    print(f"MenuBarAgent started: {current_pid}", flush=True)
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("MenuBarAgent did not report a new PID")
        finally:
            restore = (
                ["unsetenv", ENVIRONMENT_KEY]
                if old_value is None
                else ["setenv", ENVIRONMENT_KEY, old_value]
            )
            subprocess.run([LAUNCHCTL, *restore], check=True)
            print("Prior launch environment restored", flush=True)


if __name__ == "__main__":
    main()

MACISLAND_LOADER_PY

  echo "Building native notch patch from embedded source..."
  /usr/bin/xcrun clang -arch arm64e -dynamiclib -fobjc-arc -Wall -Wextra -Werror \
    -o "$SCRATCH/island.dylib" "$SCRATCH/island.c" "$SCRATCH/notch.m" \
    "$SCRATCH/safearea.m" "$SCRATCH/mask.m" \
    -framework AppKit -framework QuartzCore -F/System/Library/PrivateFrameworks \
    -framework CoreUtils -undefined dynamic_lookup
  /usr/bin/codesign -f -s - "$SCRATCH/island.dylib"
  /usr/bin/codesign --verify --strict "$SCRATCH/island.dylib"
  if [[ "$MODE" == --check ]]; then
    echo "Build and signature check passed. No installation or preference changes."
    exit 0
  fi
fi

/usr/bin/python3 - "$MODE" "$SCRATCH" <<'MACISLAND_MANAGER'
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

MODE, SOURCE = sys.argv[1], Path(sys.argv[2])
ROOT = Path.home() / 'Library/MacIsland'
AGENT = Path.home() / 'Library/LaunchAgents/com.macisland.loader.plist'
BACKUP = ROOT / 'notch-backup'
STATE = BACKUP / 'state.plist'
DOMAIN = f'gui/{os.getuid()}'
MENU_SERVICE = f'{DOMAIN}/com.apple.MenuBarAgent'
PREFERENCES = [
    (str(Path.home() / 'Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar'), 'ShowSoftwareNotch', False),
    (str(Path.home() / 'Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar'), 'EmulateCenterHUD', True),
    ('com.apple.campo', 'SupportsIslandMitosis', True),
]
FILES = {'island.dylib': ROOT / 'island.dylib', 'loader.py': ROOT / 'loader.py', 'agent.plist': AGENT}
AUXILIARY = [ROOT / name for name in ('loader.lock', 'loader.log', 'loader-error.log')]


def run(*args, required=True):
    return subprocess.run(args, check=required, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def preference(domain, key):
    result = run('/usr/bin/defaults', 'export', domain, '-', required=False)
    if result.returncode and b'does not exist' not in result.stderr:
        raise RuntimeError(f'Cannot read preferences: {domain}; no settings changed')
    values = plistlib.loads(result.stdout) if result.returncode == 0 else {}
    if key not in values:
        return {'present': False}
    value = values[key]
    if type(value) not in (bool, int, str):
        raise RuntimeError(f'Unsupported existing preference type: {key}; no settings changed')
    return {'present': True, 'value': value}


def write_preference(domain, key, saved):
    if not saved['present']:
        run('/usr/bin/defaults', 'delete', domain, key, required=False)
        return
    value = saved['value']
    kind = {bool: '-bool', int: '-int', str: '-string'}[type(value)]
    text = ('true' if value else 'false') if type(value) is bool else str(value)
    run('/usr/bin/defaults', 'write', domain, key, kind, text)


def replace_file(source, destination, mode):
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_name(destination.name + '.notch-next')
    try:
        shutil.copyfile(source, staged)
        staged.chmod(mode)
        staged.replace(destination)
    finally:
        staged.unlink(missing_ok=True)


def save_original():
    if STATE.is_file():
        return plistlib.loads(STATE.read_bytes())
    if BACKUP.exists():
        raise RuntimeError(f'Incomplete backup exists: {BACKUP}; refusing to overwrite it')
    state = {'version': 1, 'files': {}, 'preferences': [],
             'auxiliary_existed': {p.name: p.exists() for p in AUXILIARY}}
    # Read every setting before creating or modifying installation state.
    for domain, key, _ in PREFERENCES:
        state['preferences'].append({'domain': domain, 'key': key, **preference(domain, key)})
    BACKUP.mkdir(parents=True, mode=0o700)
    try:
        for name, path in FILES.items():
            exists = path.is_file()
            state['files'][name] = {'existed': exists, 'mode': path.stat().st_mode & 0o777 if exists else 0o644}
            if exists:
                shutil.copy2(path, BACKUP / name)
        temporary = BACKUP / 'state.next'
        temporary.write_bytes(plistlib.dumps(state))
        temporary.chmod(0o600)
        temporary.replace(STATE)
    except BaseException:
        # Only files created by this attempt, before any live state was changed.
        for name in [*FILES, 'state.next', 'state.plist']:
            (BACKUP / name).unlink(missing_ok=True)
        BACKUP.rmdir()
        raise
    return state


def restore_original(state):
    for name, details in state['files'].items():
        if details['existed'] and not (BACKUP / name).is_file():
            raise RuntimeError(f'Missing backup: {BACKUP / name}; restoration stopped')
    run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
    for name, path in FILES.items():
        details = state['files'][name]
        if details['existed']:
            replace_file(BACKUP / name, path, details['mode'])
        else:
            path.unlink(missing_ok=True)
    for saved in state['preferences']:
        write_preference(saved['domain'], saved['key'], saved)
    if state['files']['agent.plist']['existed']:
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT))
    else:
        run('/bin/launchctl', 'kickstart', '-k', MENU_SERVICE)
    for name in FILES:
        (BACKUP / name).unlink(missing_ok=True)
    STATE.unlink()
    BACKUP.rmdir()
    for path in AUXILIARY:
        if not state['auxiliary_existed'][path.name]:
            path.unlink(missing_ok=True)


def install():
    state = save_original()
    try:
        replace_file(SOURCE / 'island.dylib', ROOT / 'island.dylib', 0o755)
        replace_file(SOURCE / 'loader.py', ROOT / 'loader.py', 0o644)
        agent = {
            'Label': 'com.macisland.loader',
            'ProgramArguments': ['/usr/bin/python3', str(ROOT / 'loader.py')],
            'RunAtLoad': True,
            'StandardOutPath': str(ROOT / 'loader.log'),
            'StandardErrorPath': str(ROOT / 'loader-error.log'),
        }
        (SOURCE / 'agent.plist').write_bytes(plistlib.dumps(agent))
        replace_file(SOURCE / 'agent.plist', AGENT, 0o644)
        for domain, key, value in PREFERENCES:
            write_preference(domain, key, {'present': True, 'value': value})
        run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
        # Bootstrap without RunAtLoad so injection can be checked synchronously.
        agent['RunAtLoad'] = False
        (SOURCE / 'agent.plist').write_bytes(plistlib.dumps(agent))
        replace_file(SOURCE / 'agent.plist', AGENT, 0o644)
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT))
        agent['RunAtLoad'] = True
        (SOURCE / 'agent.plist').write_bytes(plistlib.dumps(agent))
        replace_file(SOURCE / 'agent.plist', AGENT, 0o644)
        # Loaded job has no KeepAlive or events; the plist on disk enables login.
        subprocess.run(['/usr/bin/python3', str(ROOT / 'loader.py')], check=True)
    except BaseException:
        print('Installation failed; restoring the saved pre-install state.', file=sys.stderr)
        restore_original(state)
        raise
    print('Installed MacIsland Notch. Login injection is enabled.')
    print(f'Original files and preferences: {BACKUP}')


def main():
    if MODE == '--uninstall' and not STATE.is_file():
        raise RuntimeError('No MacIsland Notch backup found; existing MacIsland files were left untouched')
    ROOT.mkdir(parents=True, exist_ok=True)
    lock_path = ROOT / 'installer.lock'
    with lock_path.open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MODE == '--uninstall':
            restore_original(plistlib.loads(STATE.read_bytes()))
            print('Removed MacIsland Notch; restored the saved pre-install files and preferences.')
        else:
            install()
    lock_path.unlink(missing_ok=True)
    if MODE == '--uninstall':
        try:
            ROOT.rmdir()
        except OSError:
            pass  # Preserve unrelated or pre-existing files.


if __name__ == '__main__':
    main()

MACISLAND_MANAGER
