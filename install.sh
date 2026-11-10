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

# defaults(1) with an absolute plist path can address a different preferences
# namespace from the entitled app group. Use the same explicit container as
# MenuBarAgent for both backup and restoration, leaving Apple's other keys alone.
cat > "$SCRATCH/preferences.js" <<'MACISLAND_PREFERENCES_JS'
ObjC.import('Foundation');
ObjC.import('CoreFoundation');
function run(args) {
    if (args.length !== 2 && args.length !== 3) throw Error('Invalid arguments');
    var domain = args[0], key = args[1];
    var container = $.NSURL.fileURLWithPathIsDirectory($.NSHomeDirectory().stringByAppendingPathComponent('Library/Group Containers/com.apple.MenuBar'), true);
    var menuBarDomain = ObjC.unwrap(container.path.stringByAppendingPathComponent('Library/Preferences/com.apple.MenuBar'));
    var defaults, storedFile;
    if (domain === menuBarDomain && ['ShowSoftwareNotch', 'EmulateCenterHUD'].indexOf(key) !== -1) {
        storedFile = $(menuBarDomain + '.plist');
        defaults = $.NSUserDefaults.alloc._initWithSuiteNameContainer('com.apple.MenuBar', container);
    } else if (domain === 'com.apple.campo' && key === 'SupportsIslandMitosis') {
        storedFile = $.NSHomeDirectory().stringByAppendingPathComponent('Library/Preferences/com.apple.campo.plist');
        defaults = $.NSUserDefaults.alloc.initWithSuiteName(domain);
    } else {
        throw Error('Unsupported preference');
    }
    if (ObjC.unwrap(defaults) === undefined) throw Error('Preference store unavailable');
    // Inspect this persisted domain only. NSUserDefaults.objectForKey also
    // searches global and registered defaults, which have no value to restore.
    function storedValue() {
        // Read the exact preference plist through Foundation. A missing
        // file is normal, but permission or parse errors must stop the backup.
        var files = $.NSFileManager.defaultManager;
        if (!files.isReadableFileAtPath(storedFile.stringByDeletingLastPathComponent)) {
            throw Error('Cannot access the preference directory');
        }
        if (!files.fileExistsAtPath(storedFile)) return undefined;
        var data = $.NSData.dataWithContentsOfFile(storedFile);
        if (ObjC.unwrap(data) === undefined) throw Error('Cannot read persisted preferences');
        var values = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, null, null);
        if (ObjC.unwrap(values) === undefined || !values.isKindOfClass($.NSDictionary)) {
            throw Error('Invalid persisted preferences dictionary');
        }
        return values.objectForKey(key);
    }
    if (args.length === 3) {
        var saved = $.NSJSONSerialization.JSONObjectWithDataOptionsError($(args[2]).dataUsingEncoding($.NSUTF8StringEncoding), 0, null);
        var present = ObjC.unwrap(saved.objectForKey('present'));
        if (typeof present !== 'boolean') throw Error('Invalid saved preference');
        var target = saved.objectForKey('value');
        if (present) {
            if (!target.isKindOfClass($.NSNumber) && !target.isKindOfClass($.NSString)) throw Error('Unsupported preference type');
            var previous = storedValue();
            // CFPreferences may retain false when assigned an equal integer 0.
            if (ObjC.unwrap(previous) !== undefined && previous.isEqual(target) &&
                $.CFGetTypeID(previous) !== $.CFGetTypeID(target)) {
                defaults.removeObjectForKey(key);
                if (!defaults.synchronize) throw Error('Preference synchronization failed');
            }
            defaults.setObjectForKey(target, key);
        } else {
            defaults.removeObjectForKey(key);
        }
        if (!defaults.synchronize) throw Error('Preference synchronization failed');
        var actual = storedValue();
        var matches = present
            ? ObjC.unwrap(actual) !== undefined && actual.isEqual(target) &&
              $.CFGetTypeID(actual) === $.CFGetTypeID(target)
            : ObjC.unwrap(actual) === undefined;
        if (!matches) throw Error('Preference verification failed');
    }
    var value = storedValue();
    var result = ObjC.unwrap(value) === undefined ? $({present:false}) : $({present:true, value:value});
    var json = $.NSJSONSerialization.dataWithJSONObjectOptionsError(result, 0, null);
    return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(json, $.NSUTF8StringEncoding));
}
MACISLAND_PREFERENCES_JS

if [[ "$MODE" != --uninstall ]]; then
  [[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon only" >&2; exit 1; }
  [[ "$(sw_vers -buildVersion)" == 26C5035r ]] || {
    echo "Supported build: macOS 27.3 beta 26C5035r only." >&2; exit 1;
  }
  xcode-select -p >/dev/null 2>&1 || {
    echo "Install Apple developer tools first (Xcode or: xcode-select --install)." >&2; exit 1;
  }
  for tool in clang swiftc; do
    /usr/bin/xcrun --find "$tool" >/dev/null 2>&1 || {
      echo "The selected developer tools have no $tool; select Xcode with: sudo xcode-select -s /Applications/Xcode.app" >&2; exit 1;
    }
  done
  SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  /usr/bin/awk -v v="$SDK_VERSION" 'BEGIN { n = split(v, a, "."); exit !(n >= 1 && (a[1] > 27 || (a[1] == 27 && a[2] + 0 >= 2))) }' || {
    echo "The macOS 27.2 SDK or later is required (selected SDK: ${SDK_VERSION:-none})." >&2; exit 1;
  }
  if [[ "$MODE" == install ]]; then
    csrutil status | grep -q 'status: disabled' || {
      echo "SIP must already be disabled; no protection settings were changed." >&2; exit 1;
    }
    /usr/bin/xcrun --find lldb >/dev/null 2>&1 || {
      echo "The AMFI-compatible loader requires LLDB in the selected developer tools." >&2; exit 1;
    }
  fi

  cat > "$SCRATCH/island.c" <<'MACISLAND_ISLAND_C'
#include <libproc.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
extern int IsAppleInternalBuild(void);

static pthread_once_t identityOnce = PTHREAD_ONCE_INIT;
static bool isMenuBarAgent;
static void checkExecutable(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    isMenuBarAgent = proc_pidpath(getpid(), path, sizeof(path)) > 0 &&
        strcmp(path, "/System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent") == 0;
}
__attribute__((visibility("hidden"))) bool MacIslandIsMenuBarAgent(void) {
    pthread_once(&identityOnce, checkExecutable);
    return isMenuBarAgent;
}

static int fake_IsAppleInternalBuild(void) {
    if (MacIslandIsMenuBarAgent()) return 1;
    return IsAppleInternalBuild();
}
__attribute__((used)) static struct { const void *r; const void *o; } interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)fake_IsAppleInternalBuild, (const void *)IsAppleInternalBuild },
};

MACISLAND_ISLAND_C

  cat > "$SCRATCH/notch-layout.h" <<'MACISLAND_NOTCH_LAYOUT_H'
#import <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

__attribute__((visibility("hidden"))) bool MacIslandIsMenuBarAgent(void);

// The upper shoulder joins the bezel outside the native content area.
static const CGFloat MacIslandNotchFlare = 6;
// Room for the full-height digits drawn above the short activity's controls.
static const CGFloat MacIslandShortContentClearance = 14;
// Keep room for native controls even before the Clock UI provider is patched.
static const CGFloat MacIslandShortPanelClearance = 6;

MACISLAND_NOTCH_LAYOUT_H

  cat > "$SCRATCH/notch.m" <<'MACISLAND_NOTCH_M'
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "notch-layout.h"
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
    if (!MacIslandIsMenuBarAgent()) return;
    Class screen = NSScreen.class;
    Method defaultMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDDefaultFrame"));
    Method hardwareMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDHardwareFrame"));
    Method minimalMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDMinimalObstructionFrame"));
    // Comparing the private methods to one another would miss a shared ABI change.
    Method frameMethod = class_getInstanceMethod(screen, @selector(frame));
    if (!frameMethod || !defaultMethod || !hardwareMethod || !minimalMethod) return;
    const char *expected = method_getTypeEncoding(frameMethod);
    if (strcmp(expected, method_getTypeEncoding(defaultMethod)) != 0 ||
        strcmp(expected, method_getTypeEncoding(hardwareMethod)) != 0 ||
        strcmp(expected, method_getTypeEncoding(minimalMethod)) != 0) return;
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
#import <objc/message.h>
#import "notch-layout.h"
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// One physical exclusion policy at the shared FBS scene-settings boundary.
// Both ElementRegistry and MenuBarClient receive it, regardless of provider.
static char sceneInsetsKey, originalLayoutPayloadKey;
extern BOOL MacIslandShortHostAvailable(void);
static void (*originalMargins)(id, SEL, id), (*originalMinimum)(id, SEL, id), (*originalMaximum)(id, SEL, id);
static void (*originalHostedMargins)(id, SEL, id), (*originalHostedMinimum)(id, SEL, id), (*originalHostedMaximum)(id, SEL, id);
static void (*originalObstruction)(id, SEL, id), (*originalSpace)(id, SEL, id), (*originalCorners)(id, SEL, id);
static void (*originalHostedObstruction)(id, SEL, id), (*originalHostedSpace)(id, SEL, id), (*originalHostedCorners)(id, SEL, id);
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
@property(nonatomic) CGRect frame;
@property(nonatomic) BOOL updating;
@end
@implementation MacIslandSceneInsets
- (instancetype)init {
    self = [super init];
    if (self) {
        _layouts = @[[MacIslandNativeLayout new], [MacIslandNativeLayout new]];
        _obstructions = @[[MacIslandNativeObstruction new], [MacIslandNativeObstruction new]];
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
static NSString *obstructionSetting(NSUInteger family, NSString *suffix) {
    return [(family ? @"hostedIntegratedObstruction" : @"integratedObstruction") stringByAppendingString:suffix];
}
static NSString *obstructionSetter(NSUInteger family, NSString *suffix) {
    return [[(family ? @"setHostedIntegratedObstruction" : @"setIntegratedObstruction") stringByAppendingString:suffix] stringByAppendingString:@":"];
}
static MacIslandSceneInsets *sceneState(id settings) {
    MacIslandSceneInsets *state = objc_getAssociatedObject(settings, &sceneInsetsKey);
    if (!state) {
        state = [MacIslandSceneInsets new];
        objc_setAssociatedObject(settings, &sceneInsetsKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSUInteger family = 0; family < state.obstructions.count; family++) {
            MacIslandNativeObstruction *native = state.obstructions[family];
            id rect = existingObjectSetting(settings, obstructionSetting(family, @"Rect"));
            id space = existingObjectSetting(settings, obstructionSetting(family, @"RectCoordinateSpace"));
            native.rect = isRectValue(rect) ? rect : nil;
            native.space = isSizeValue(space) ? space : nil;
            native.nativeCorners = existingObjectSetting(settings, obstructionSetting(family, @"CornerRadii"));
        }
        state.frame = existingFrame(settings);
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
        policy.notchHeight = height;
        CGFloat center = (NSMaxX(left) + NSMinX(right)) / 2;
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
    BOOL displayKnown = NO;
    NSScreen *screen = sceneDisplayScreen(settings, &displayKnown);
    BOOL physicalDisplay = !displayKnown || screenHasNotch(screen);
    NSRect rects[2] = {NSZeroRect, NSZeroRect};
    for (NSUInteger family = 0; family < state.obstructions.count; family++) {
        MacIslandNativeObstruction *native = state.obstructions[family];
        NSRect original = native.rect ? native.rect.rectValue : NSZeroRect;
        NSRect rect = canonicalObstruction(original, screen);
        rects[family] = rect;
    }
    CGFloat hostOffsets[2] = {0, 0};
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
        NSRect rect = rects[obstructionFamily];
        NSSize layoutViewport = obstruction.space ? obstruction.space.sizeValue : state.frame.size;
        if (layoutViewport.width <= 0 || layoutViewport.height <= 0) {
            if (native.maximum) layoutViewport = native.maximum.sizeValue;
            else if (native.minimum) layoutViewport = native.minimum.sizeValue;
        }
        MacIslandNotchAvoidance policy = obstruction.rect && physicalDisplay ?
            notchAvoidance(rect, layoutViewport) : (MacIslandNotchAvoidance){0};
        NSDictionary *before = decodedMargins(native.margins);
        // A short panel which settles at the host's minimum has no
        // independent content-height proposal. Give it an intact row below
        // the cutout. ClockAngel, for example, keeps a 260 x 60 local body
        // inside that negotiated frame and only reports its buttons for
        // obstruction clearance. A taller self-sizing panel keeps its layout.
        CGFloat shortHeight = 0;
        if (policy.extendsBelow && MacIslandShortHostAvailable() && before && native.minimum && native.maximum && obstruction.space &&
            NSMinX(rect) >= -1 && NSMaxX(rect) <= layoutViewport.width + 1 &&
            native.minimum.sizeValue.height <= policy.notchHeight + 1) {
            CGFloat top = [before[@"top"] doubleValue], bottom = [before[@"bottom"] doubleValue];
            CGFloat oldFloor = native.minimum.sizeValue.height + MAX(0, policy.top - top);
            CGFloat proposed = policy.notchHeight + MAX(native.minimum.sizeValue.height, policy.notchHeight + top + bottom);
            if (fabs(layoutViewport.height - oldFloor) <= 1 || fabs(layoutViewport.height - proposed) <= 1 ||
                fabs(layoutViewport.height - proposed - MacIslandShortContentClearance) <= 1 ||
                fabs(layoutViewport.height - proposed - MacIslandShortPanelClearance) <= 1) {
                shortHeight = proposed + MacIslandShortPanelClearance;
                hostOffsets[obstructionFamily] = policy.notchHeight + MacIslandShortContentClearance;
                policy.top = 0;
            }
        }
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
                // Element activities place content below the cutout through
                // the top margin. Keep a modest floor so a narrow activity
                // still clears the shoulders, and let providers that ask
                // for more (music, ClockAngel) negotiate their own width.
                CGFloat width = policy.notchWidth + (shortHeight > 0 ? 92 : 140);
                CGFloat floor = MAX(minimum.width, MIN(width, policy.centeredDisplayWidth));
                CGFloat growth = floor - minimum.width;
                maximum.width += MIN(growth, MAX(0, policy.centeredDisplayWidth - maximum.width - extraX));
                minimum.width = floor;
            }
            maximum.width = MAX(maximum.width + extraX, minimum.width);
            maximum.height = MAX(maximum.height, minimum.height);
            minimumValue = layoutPayload([NSValue valueWithSize:minimum], native.minimum);
            maximumValue = layoutPayload([NSValue valueWithSize:maximum], native.maximum);
            applies |= !NSEqualSizes(minimum, native.minimum.sizeValue) || !NSEqualSizes(maximum, native.maximum.sizeValue);
        }
        if (applies || native.applied) writeFamily(settings, family, native, margins, minimumValue, maximumValue);
        native.applied = applies;
    }
    for (NSUInteger family = 0; family < state.obstructions.count; family++) {
        MacIslandNativeObstruction *native = state.obstructions[family];
        NSRect rect = rects[family];
        NSRect published = rect;
        if (hostOffsets[family] > 0) {
            // The short host is already moved below the camera. Some
            // providers reserve horizontal space from the obstruction's
            // width even when it is above their viewport.
            published = NSMakeRect(NSMidX(rect) - 0.5, -hostOffsets[family] - 1, 1, 1);
        }
        NSRect original = native.rect ? native.rect.rectValue : NSZeroRect;
        void (*setRect)(id, SEL, id) = family ? originalHostedObstruction : originalObstruction;
        BOOL corrected = !NSEqualRects(published, original);
        if (setRect && (corrected || native.obstructionApplied)) {
            id value = corrected ? layoutPayload([NSValue valueWithRect:published], native.rect) : native.rect;
            setRect(settings, NSSelectorFromString(obstructionSetter(family, @"Rect")), value);
        }
        native.obstructionApplied = corrected;
        void (*setter)(id, SEL, id) = family ? originalHostedCorners : originalCorners;
        NSSize extent = NSMakeSize(MAX(NSMaxX(rect), rect.size.width) + 1,
                                  MAX(NSMaxY(rect), rect.size.height) + 2);
        BOOL rectangular = native.rect && physicalDisplay && notchAvoidance(rect, extent).physical && setter;
        if (rectangular && !native.rectangularCorners) {
            Class factory = NSClassFromString(@"BSCornerRadiusConfiguration");
            if ([factory instancesRespondToSelector:@selector(initWithCornerRadius:)])
                native.rectangularCorners = layoutPayload([(id<MacIslandCornerFactory>)[factory alloc] initWithCornerRadius:0], native.nativeCorners);
        }
        if (native.rectangularCorners && rectangular)
            setter(settings, NSSelectorFromString(obstructionSetter(family, @"CornerRadii")), native.rectangularCorners);
        else if (native.cornersApplied && setter)
            setter(settings, NSSelectorFromString(obstructionSetter(family, @"CornerRadii")), native.nativeCorners);
        native.cornersApplied = rectangular && native.rectangularCorners != nil;
    }
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
static void setFamilyObstruction(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    (family ? originalHostedObstruction : originalObstruction)(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstructions[family].rect = isRectValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilySpace(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    (family ? originalHostedSpace : originalSpace)(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstructions[family].space = isSizeValue(value) ? value : nil;
    refreshSceneInsets(settings, state);
}
static void setFamilyCorners(id settings, SEL selector, id value, NSUInteger family) {
    value = nativePayload(value);
    (family ? originalHostedCorners : originalCorners)(settings, selector, value);
    MacIslandSceneInsets *state = sceneState(settings);
    state.obstructions[family].nativeCorners = value;
    state.obstructions[family].rectangularCorners = nil;
    refreshSceneInsets(settings, state);
}
static void setObstruction(id o, SEL s, id v) { setFamilyObstruction(o, s, v, 0); }
static void setSpace(id o, SEL s, id v) { setFamilySpace(o, s, v, 0); }
static void setCorners(id o, SEL s, id v) { setFamilyCorners(o, s, v, 0); }
static void setHostedObstruction(id o, SEL s, id v) { setFamilyObstruction(o, s, v, 1); }
static void setHostedSpace(id o, SEL s, id v) { setFamilySpace(o, s, v, 1); }
static void setHostedCorners(id o, SEL s, id v) { setFamilyCorners(o, s, v, 1); }
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
// The scene-extension accessors (margins, minimum size, obstruction…) do not
// exist on FBSSceneSettings until FrontBoardServices registers the matching
// settings extensions, which normally happens lazily on the first expanded or
// hosted scene. Hooks are therefore (re)verified whenever an extension is
// registered, and the known extensions are registered up front.
static pthread_mutex_t contentInsetsHookLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL contentInsetsHooksReported;
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
static void observeSettingsExtensionRegistration(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"FBSSceneSettings");
        Method method = cls ? class_getClassMethod(cls, NSSelectorFromString(@"_settingsExtensionsForSceneExtension:")) : NULL;
        if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8#16")) {
            os_log(OS_LOG_DEFAULT, "MacIsland: settings-extension registration hook unavailable");
            return;
        }
        originalSettingsExtensions = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)settingsExtensionsForSceneExtension);
    });
}
static void registerKnownSettingsExtensions(void) {
    Class cls = NSClassFromString(@"FBSSceneSettings");
    SEL selector = NSSelectorFromString(@"_settingsExtensionsForSceneExtension:");
    if (!cls || ![cls respondsToSelector:selector]) return;
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
    ready &= replaceObjectSetter(cls, @"setHostedIntegratedObstructionRect:", (IMP)setHostedObstruction, &originalHostedObstruction);
    ready &= replaceObjectSetter(cls, @"setHostedIntegratedObstructionRectCoordinateSpace:", (IMP)setHostedSpace, &originalHostedSpace);
    ready &= replaceObjectSetter(cls, @"setHostedIntegratedObstructionCornerRadii:", (IMP)setHostedCorners, &originalHostedCorners);
    // Display configuration and frame are base FBSSceneSettings accessors:
    // hook them when present, but they must not decide readiness.
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
    if (installContentInsetsHooks()) return;
    // The registration hook normally finishes installation; polling is only
    // a fallback, and keeps going slowly instead of giving up.
    int64_t delay = attempt < 20 ? 50 * NSEC_PER_MSEC : attempt < 300 ? 500 * NSEC_PER_MSEC : 5 * NSEC_PER_SEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{ waitForSceneSettings(attempt + 1); });
}
__attribute__((constructor)) static void installNotchContentInsets(void) {
    if (!MacIslandIsMenuBarAgent()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        observeSettingsExtensionRegistration();
        registerKnownSettingsExtensions();
        waitForSceneSettings(0);
    });
}
MACISLAND_SAFEAREA_M

  cat > "$SCRATCH/short-host.m" <<'MACISLAND_SHORT_HOST_M'
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "notch-layout.h"
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

// The tagged FBS obstruction is already expressed in the new, below-notch
// content viewport. Move the AppKit event owner and its presentation together.
static char shortHostFrameKey, shortTranslationKey, shortClipKey;
static void (*nativeHostSetFrame)(NSView *, SEL, NSRect);
static void (*nativeHostLayout)(NSView *, SEL);
static _Thread_local BOOL writingShortFrame;
static atomic_bool shortHostAvailable;
BOOL MacIslandShortHostAvailable(void) {
    return atomic_load(&shortHostAvailable);
}

static id hostSetting(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static BOOL matchesShortViewport(id settings, CGFloat cutoutWidth, CGFloat cutoutHeight, NSSize nativeSize) {
    for (NSString *prefix in @[@"", @"hosted"]) {
        NSString *rectName = prefix.length ? @"hostedIntegratedObstructionRect" : @"integratedObstructionRect";
        NSString *sizeName = prefix.length ? @"hostedMinimumSize" : @"elementViewMinimumSize";
        id exclusion = hostSetting(settings, rectName);
        id minimum = hostSetting(settings, sizeName);
        if (![exclusion isKindOfClass:NSValue.class] || strcmp([exclusion objCType], @encode(NSRect)) ||
            ![minimum isKindOfClass:NSValue.class] || strcmp([minimum objCType], @encode(NSSize))) continue;
        NSRect rect = [exclusion rectValue];
        NSSize size = [minimum sizeValue];
        CGFloat inset = cutoutHeight + MacIslandShortContentClearance;
        if (NSEqualSizes(rect.size, NSMakeSize(1, 1)) && fabs(NSMaxY(rect) + inset) <= 0.01 &&
            fabs(size.height - nativeSize.height) <= 1 && size.height > inset &&
            nativeSize.width >= cutoutWidth) return YES;
    }
    return NO;
}
static NSRect positionedHostFrame(NSView *host, NSRect nativeFrame) {
    NSView *parent = host.superview;
    NSWindow *window = host.window;
    NSScreen *screen = window.screen;
    CGFloat height = screen.safeAreaInsets.top;
    if (height <= 0 || !parent.isFlipped || fabs(window.frame.size.height - screen.frame.size.height) > 1 ||
        fabs(nativeFrame.size.height - parent.bounds.size.height) > 1 ||
        fabs(nativeFrame.size.width - parent.bounds.size.width) > 1) return nativeFrame;
    NSRect left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea;
    if (NSIsEmptyRect(left) || NSIsEmptyRect(right)) return nativeFrame;
    CGFloat width = NSMinX(right) - NSMaxX(left);
    if (nativeFrame.size.width <= width || nativeFrame.size.height <= height) return nativeFrame;
    Class hostingClass = NSClassFromString(@"NSSceneHostingView");
    for (NSView *child in host.subviews) {
        if (![child isKindOfClass:hostingClass]) continue;
        id settings = hostSetting(hostSetting(child, @"scene"), @"settings");
        if (!matchesShortViewport(settings, width, height, nativeFrame.size)) continue;
        CGFloat inset = height + MacIslandShortContentClearance;
        nativeFrame.origin.y += inset;
        nativeFrame.size.height -= inset;
        break;
    }
    return nativeFrame;
}
// MenuBarCore gates updates to the backing layer, even when AppKit has moved
// its event owner. Translate the existing remote scene by the remaining delta.
static void allowShortHostOverdraw(CALayer *layer, NSHashTable<CALayer *> *unclipped, NSUInteger depth) {
    if ([NSStringFromClass(layer.class) isEqualToString:@"SceneHosting._SceneLayerHost"]) {
        if (layer.masksToBounds) {
            [unclipped addObject:layer];
            layer.masksToBounds = NO;
        }
    } else if (depth) {
        for (CALayer *child in layer.sublayers) allowShortHostOverdraw(child, unclipped, depth - 1);
    }
}
static void alignHostedPresentation(NSView *view) {
    CALayer *layer = view.layer;
    if (!layer || !layer.superlayer) return;
    NSValue *nativeFrame = objc_getAssociatedObject(view, &shortHostFrameKey);
    NSNumber *previous = objc_getAssociatedObject(layer, &shortTranslationKey);
    NSHashTable<CALayer *> *unclipped = objc_getAssociatedObject(view, &shortClipKey);
    if (!nativeFrame && !previous && !unclipped) return;
    // The native baseline layout can draw the top of its digits above the
    // remote surface. The moved short host reserves room for that overdraw.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (nativeFrame) {
        if (!unclipped) {
            unclipped = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(view, &shortClipKey, unclipped, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        allowShortHostOverdraw(layer, unclipped, 3);
    } else {
        for (CALayer *child in unclipped.allObjects) child.masksToBounds = YES;
        objc_setAssociatedObject(view, &shortClipKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction commit];
    CATransform3D transform = layer.sublayerTransform;
    CATransform3D prior = CATransform3DMakeTranslation(0, previous.doubleValue, 0);
    if (!CATransform3DEqualToTransform(transform, prior)) {
        // Another native owner replaced this transform. Leave it in control.
        objc_setAssociatedObject(layer, &shortTranslationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGFloat delta = nativeFrame ? NSMinY(view.frame) - CGRectGetMinY(layer.frame) : 0;
    if (fabs(delta - previous.doubleValue) < 0.001) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = CATransform3DMakeTranslation(0, delta, 0);
    [CATransaction commit];
    objc_setAssociatedObject(layer, &shortTranslationKey, delta ? @(delta) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void setHostFrame(NSView *view, SEL selector, NSRect requested) {
    if (writingShortFrame) { nativeHostSetFrame(view, selector, requested); return; }
    NSValue *saved = objc_getAssociatedObject(view, &shortHostFrameKey);
    if (saved && NSEqualRects(requested, view.frame)) requested = saved.rectValue;
    NSRect frame = positionedHostFrame(view, requested);
    BOOL adjusted = !NSEqualRects(frame, requested);
    objc_setAssociatedObject(view, &shortHostFrameKey, adjusted ? [NSValue valueWithRect:requested] : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    writingShortFrame = YES;
    nativeHostSetFrame(view, selector, frame);
    writingShortFrame = NO;
    alignHostedPresentation(view);
}
static void layoutHost(NSView *view, SEL selector) {
    if (!writingShortFrame) {
        NSValue *saved = objc_getAssociatedObject(view, &shortHostFrameKey);
        NSRect nativeFrame = saved ? saved.rectValue : view.frame;
        if (!NSEqualRects(view.frame, positionedHostFrame(view, nativeFrame)))
            setHostFrame(view, @selector(setFrame:), nativeFrame);
    }
    nativeHostLayout(view, selector);
    alignHostedPresentation(view);
}
static void installShortHostLayout(unsigned attempt) {
    Class cls = NSClassFromString(@"MenuBarCore.SceneHostDisplayItemContainerView");
    if (!cls && attempt < 100) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            installShortHostLayout(attempt + 1);
        });
        return;
    }
    if (!cls || ![cls isSubclassOfClass:NSView.class] || nativeHostSetFrame) return;
    Method frame = class_getInstanceMethod(cls, @selector(setFrame:));
    Method layout = class_getInstanceMethod(cls, @selector(layout));
    if (!frame || !layout) return;
    nativeHostSetFrame = (void *)method_getImplementation(frame);
    nativeHostLayout = (void *)method_getImplementation(layout);
    class_replaceMethod(cls, @selector(setFrame:), (IMP)setHostFrame, method_getTypeEncoding(frame));
    class_replaceMethod(cls, @selector(layout), (IMP)layoutHost, method_getTypeEncoding(layout));
    atomic_store(&shortHostAvailable, true);
}
__attribute__((constructor)) static void installShortHost(void) {
    if (MacIslandIsMenuBarAgent())
        dispatch_async(dispatch_get_main_queue(), ^{ installShortHostLayout(0); });
}
MACISLAND_SHORT_HOST_M

  cat > "$SCRATCH/mask.m" <<'MACISLAND_MASK_M'
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "notch-layout.h"
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

static char mergeVisibilityKey, secondaryMergeKey;
static void (*originalSetHidden)(id, SEL, BOOL);
static char maskObserverKey, parentGeometryKey, sceneLayersKey, sceneOriginObserverKey;
static void (*originalSetCornerRadius)(id, SEL, CGFloat);
static void (*baseSetBounds)(id, SEL, CGRect);
static void (*baseSetPosition)(id, SEL, CGPoint);

static CGPathRef notchMaskPathAtTop(CGSize size, CGFloat top, BOOL outwardShoulders, CGFloat scaleY) {
    CGFloat flare = MIN(MacIslandNotchFlare, MIN(size.width / 4, size.height / 3));
    CGFloat bottom = MIN(14, size.height / 2);
    CGFloat width = size.width;
    CGFloat height = size.height;
    CGFloat k = 0.5522847498307936;
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat shoulder = outwardShoulders ? flare : 0;
    CGFloat shoulderY = MIN(shoulder / MAX(scaleY, 0.001), height / 3);
    top = MIN(MAX(top, 0), MAX(height - shoulderY - bottom, 0));
    CGFloat left = flare - shoulder, right = width - left;
    CGPathMoveToPoint(path, NULL, left, 0);
    CGPathAddLineToPoint(path, NULL, right, 0);
    CGPathAddLineToPoint(path, NULL, right, top);
    CGPathAddCurveToPoint(path, NULL, right - k * shoulder, top,
                         width - flare, top + (1 - k) * shoulderY, width - flare, top + shoulderY);
    CGPathAddLineToPoint(path, NULL, width - flare, height - bottom);
    CGPathAddCurveToPoint(path, NULL, width - flare, height - bottom + k * bottom,
                         width - flare - bottom + k * bottom, height,
                         width - flare - bottom, height);
    CGPathAddLineToPoint(path, NULL, flare + bottom, height);
    CGPathAddCurveToPoint(path, NULL, flare + bottom - k * bottom, height,
                         flare, height - bottom + k * bottom, flare, height - bottom);
    CGPathAddLineToPoint(path, NULL, flare, top + shoulderY);
    CGPathAddCurveToPoint(path, NULL, flare, top + (1 - k) * shoulderY, left + k * shoulder, top, left, top);
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
// Scaled display modes do not map points onto whole panel pixels. On a
// 3024-pixel panel shown as 1800 points, the 38-point safe area covers 63.84
// physical rows while the camera housing covers 64, leaving a faint partial
// row under the island. Return the extra points needed to reach that row.
static CGFloat panelBottomSnap(NSScreen *screen, CGFloat height) {
    CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGFloat width = screen.frame.size.width;
    if (!display || width <= 0 || height <= 0) return 0;
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)
        @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    size_t native = 0, widest = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pixels = CGDisplayModeGetPixelWidth(mode);
        widest = MAX(widest, pixels);
        if (CGDisplayModeGetIOFlags(mode) & 0x02000000) native = MAX(native, pixels);
    }
    if (modes) CFRelease(modes);
    CGFloat scale = (CGFloat)(native ?: widest) / width;
    if (!isfinite(scale) || scale <= 0) return 0;
    CGFloat rows = height * scale;
    CGFloat snap = ceil(rows - 0.01) / scale - height;
    return snap > 0.001 && snap < 1 / scale ? snap : 0;
}
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
                            @"pixel": @(1 / MAX(screen.backingScaleFactor, 1)),
                            @"bottomSnap": @(panelBottomSnap(screen, screen.safeAreaInsets.top))}];
    }
    [MacIslandScreenGeometry shared].layouts = layouts;
}
static NSDictionary *screenLayoutForLayer(CALayer *layer) {
    CGSize parent = layer.superlayer.bounds.size;
    for (NSDictionary *layout in [MacIslandScreenGeometry shared].layouts) {
        CGSize size = [layout[@"size"] sizeValue];
        if (fabs(parent.width - size.width) <= 1 && fabs(parent.height - size.height) <= 1) return layout;
    }
    return nil;
}

@class MacIslandNativeMaskObserver;
static void synchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer);
static void removeNativeMaskGeometry(MacIslandNativeMaskObserver *observer);
static id nativeModifierObject(id object, NSString *name);
static BOOL nativeModifierEnabled(id modifier);

@interface MacIslandNativeMaskObserver : NSObject
@property(nonatomic, weak) CALayer *source;
@property(nonatomic, weak) CALayer *observedParent;
@property(nonatomic, weak) MacIslandNativeMaskObserver *mergeInput;
@property(nonatomic, weak) MacIslandNativeMaskObserver *contourPeer;
@property(nonatomic, weak) CALayer *heldUnion;
@property(nonatomic, strong) id heldBlur;
@property(nonatomic, weak) CALayer *observedUnion;
@property(nonatomic, weak) MacIslandNativeMaskObserver *detachedPaint;
@property(nonatomic, strong) id observedBlur;
@property(nonatomic, strong) NSMapTable<CALayer *, NSNumber *> *suppressedPaint;
@property(nonatomic, weak) CALayer *mergeScene;
@property(nonatomic, strong) CAShapeLayer *shapeMask;
@property(nonatomic) CGFloat pixelInset;
@property(nonatomic) CGFloat horizontalFlare;
@property(nonatomic) CGFloat bottomExtension;
@property(nonatomic) CGFloat topExtension;
// Native layer updates can arrive on MenuBarAgent's animation thread as well
// as main. These collections are replaced copy-on-write under this lock, which
// is held only for the swap and never across a call into AppKit or Core Animation.
@property(atomic, copy) NSArray *modifierBindings;
@property(atomic, copy) NSArray *nativeMaskGroups;
@property(nonatomic, strong) NSArray<NSString *> *keys;
@property(nonatomic) CGFloat nativeRadius;
@property(nonatomic) BOOL updating;
@property(nonatomic) BOOL applied;
@property(atomic) CGRect nativeBounds;
@property(atomic) CGPoint nativePosition;
@property(atomic, strong) id nativeMaskSize;
- (instancetype)initWithLayer:(CALayer *)layer;
- (void)refresh;
- (void)refreshMask;
- (void)endVisibilityHold:(BOOL)applyHide;
- (void)updateVisibilityHold;
- (void)holdVisibilityInUnion:(CALayer *)group blur:(id)blur;
- (void)setMergeSuppression:(BOOL)suppress unionLayer:(CALayer *)unionLayer blur:(id)blur
                       paints:(NSArray<CALayer *> *)paints;
- (void)useDetachedPaint:(MacIslandNativeMaskObserver *)peer inUnion:(CALayer *)group blur:(id)blur;
@end

static CGRect nativeBodyFrame(MacIslandNativeMaskObserver *observer) {
    CALayer *layer = observer.source;
    CGSize size = observer.nativeBounds.size;
    CGRect box = CGRectMake(-layer.anchorPoint.x * size.width, -layer.anchorPoint.y * size.height,
                            size.width, size.height);
    CGRect frame = CGRectApplyAffineTransform(box, CATransform3DGetAffineTransform(layer.transform));
    return CGRectOffset(frame, observer.nativePosition.x, observer.nativePosition.y);
}

static os_unfair_lock maskStateLock = OS_UNFAIR_LOCK_INIT;
// Atomic check-and-set: a second thread must not run the same refresh at once.
static BOOL beginObserverUpdate(MacIslandNativeMaskObserver *observer) {
    os_unfair_lock_lock(&maskStateLock);
    BOOL began = !observer.updating;
    if (began) observer.updating = YES;
    os_unfair_lock_unlock(&maskStateLock);
    return began;
}
static void endObserverUpdate(MacIslandNativeMaskObserver *observer) {
    os_unfair_lock_lock(&maskStateLock);
    observer.updating = NO;
    os_unfair_lock_unlock(&maskStateLock);
}

static BOOL isNotchBackground(CALayer *layer, MacIslandNativeMaskObserver *observer) {
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
    // Eligibility follows Apple's original geometry, not the larger paint
    // bounds used for shoulders and offscreen filter sampling.
    if (observer) frame = nativeBodyFrame(observer);
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

static CGFloat nativeSceneEdgeCompensation(CALayer *layer) {
    for (CALayer *parent = layer.superlayer; parent; parent = parent.superlayer) {
        id observer = objc_getAssociatedObject(parent, &sceneOriginObserverKey);
        SEL pixel = NSSelectorFromString(@"pixel");
        if ([observer respondsToSelector:pixel]) return MAX(0, ((CGFloat (*)(id, SEL))objc_msgSend)(observer, pixel));
    }
    return 0;
}
static BOOL hasMergeFilters(CALayer *layer) {
    BOOL blur = NO, threshold = NO;
    for (id filter in layer.filters) {
        id type = nativeModifierObject(filter, @"type");
        blur |= [type isEqual:@"gaussianBlur"];
        threshold |= [type isEqual:@"alphaThreshold"];
    }
    return blur && threshold;
}

static BOOL isNativeUnionFill(CALayer *layer) {
    return isOpaqueBlack(layer.backgroundColor) && hasMergeFilters(layer.superlayer);
}

// Only a secondary opaque input of the same native notch compositor joins
// the primary's transaction. Its path, size, velocity and paint stay native.
static BOOL isSecondaryMergeInput(CALayer *layer) {
    return isOpaqueBlack(layer.backgroundColor) && hasMergeFilters(layer.superlayer.superlayer) &&
           nativeSceneEdgeCompensation(layer) > 0;
}

// Only paint-only, childless black backgrounds qualify for delayed hiding.
static id activeMergeBlur(CALayer *group) {
    id blur = nil;
    BOOL threshold = NO;
    for (id filter in group.filters) {
        if (!nativeModifierEnabled(filter)) continue;
        id type = nativeModifierObject(filter, @"type");
        if ([type isEqual:@"alphaThreshold"]) threshold = YES;
        if ([type isEqual:@"gaussianBlur"] && [[filter valueForKey:@"inputRadius"] doubleValue] > 0)
            blur = filter;
    }
    return threshold ? blur : nil;
}

static MacIslandNativeMaskObserver *modelMaskObserver(CALayer *layer);

static void presentationLayerGeometry(CALayer *layer, CGPoint *originOut, CGSize *sizeOut,
                                      CGPoint *positionOut, CGPoint *anchorOut, CATransform3D *transformOut) {
    CGRect bounds = layer.bounds;
    CGPoint origin = bounds.origin;
    CGSize size = bounds.size;
    CGPoint position = layer.position;
    CGPoint anchor = layer.anchorPoint;
    CATransform3D transform = layer.transform;
    for (id modifier in nativeModifierObject(layer, @"presentationModifiers")) {
        if (!nativeModifierEnabled(modifier)) continue;
        NSString *key = nativeModifierObject(modifier, @"keyPath");
        id value = nativeModifierObject(modifier, @"value");
        if (![value isKindOfClass:NSValue.class]) continue;
        const char *type = [value objCType];
        if ([key isEqual:@"bounds"] && !strcmp(type, @encode(CGRect))) {
            CGRect r = [value rectValue];
            origin = r.origin;
            size = r.size;
        } else if ([key isEqual:@"bounds.origin"] && !strcmp(type, @encode(CGPoint))) {
            origin = [value pointValue];
        } else if ([key isEqual:@"bounds.size"] && !strcmp(type, @encode(CGSize))) {
            size = [value sizeValue];
        } else if ([key isEqual:@"position"] && !strcmp(type, @encode(CGPoint))) {
            position = [value pointValue];
        } else if ([key isEqual:@"anchorPoint"] && !strcmp(type, @encode(CGPoint))) {
            anchor = [value pointValue];
        } else if ([key isEqual:@"transform"] && !strcmp(type, @encode(CATransform3D))) {
            transform = [value CATransform3DValue];
        }
    }
    *originOut = origin;
    *sizeOut = size;
    *positionOut = position;
    *anchorOut = anchor;
    *transformOut = transform;
}

static CGRect layerFrameInAncestor(CALayer *layer, CALayer *ancestor, BOOL presentation) {
    CGPoint origin, position, anchor;
    CGSize size;
    CATransform3D transform;
    CGRect rect = CGRectZero;
    for (CALayer *cur = layer; cur && cur != ancestor; cur = cur.superlayer) {
        if (presentation) {
            presentationLayerGeometry(cur, &origin, &size, &position, &anchor, &transform);
        } else {
            origin = cur.bounds.origin;
            size = cur.bounds.size;
            position = cur.position;
            anchor = cur.anchorPoint;
            transform = cur.transform;
        }
        if (cur == layer) rect = (CGRect){origin, size};
        CGRect centered = CGRectOffset(rect, -origin.x - anchor.x * size.width, -origin.y - anchor.y * size.height);
        CGRect transformed = CGRectApplyAffineTransform(centered, CATransform3DGetAffineTransform(transform));
        rect = CGRectOffset(transformed, position.x, position.y);
    }
    return rect;
}

static CGRect presentationLayerFrameInAncestor(CALayer *layer, CALayer *ancestor) {
    return layerFrameInAncestor(layer, ancestor, YES);
}

// Apple supplies two black fills for the circle: the filtered input and a
// matching opaque fallback outside the group. Match the fallback by its
// presentation bounds in the same scene, including the native pixel inset.
static BOOL sameCircleFrame(CGRect a, CGRect b) {
    return fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) <= 1.5 &&
           fabs(CGRectGetMaxX(a) - CGRectGetMaxX(b)) <= 1.5 &&
           fabs(CGRectGetMinY(a) - CGRectGetMinY(b)) <= 1.5 &&
           fabs(CGRectGetMaxY(a) - CGRectGetMaxY(b)) <= 1.5;
}

static NSArray<CALayer *> *secondaryPaints(CALayer *leaf, CALayer *group) {
    CALayer *scene = group.superlayer;
    CGRect circle = presentationLayerFrameInAncestor(leaf, scene);
    CALayer *match = nil;
    for (CALayer *branch in scene.sublayers) {
        if (branch == group || branch.contents) continue;
        for (CALayer *candidate in branch.sublayers) {
            if (![candidate.name hasPrefix:@"SimpleViewDisplayItem-"] ||
                !isOpaqueBlack(candidate.backgroundColor) || candidate.contents || candidate.sublayers.count)
                continue;
            CGRect rect = presentationLayerFrameInAncestor(candidate, scene);
            if (!sameCircleFrame(circle, rect)) continue;
            if (match) return @[leaf];
            match = candidate;
        }
    }
    if (!match) return @[leaf];

    // The circular backdrops and gain map still draw after the two black
    // fills are suppressed. The transition backdrop has a two-point bleed
    // on the same native spring frame.
    CGRect fallback = presentationLayerFrameInAncestor(match, scene);
    NSMutableArray<CALayer *> *paints = [NSMutableArray arrayWithArray:@[leaf, match]];
    for (CALayer *branch in scene.sublayers) {
        if (branch == group || branch.contents) continue;
        for (CALayer *candidate in branch.sublayers) {
            if (candidate.contents || candidate.sublayers.count) continue;
            CGRect expected = fallback;
            if ([candidate.name hasPrefix:@"BackdropViewDisplayItem-"]) {
                NSArray *types = [candidate.filters valueForKey:@"type"];
                if (types.count) {
                    if (types.count != 2 || ![types containsObject:@"colorMatrix"] ||
                        ![types containsObject:@"colorInvertDisplayAware"]) continue;
                    expected = CGRectInset(fallback, -2, -2);
                }
            } else if (branch != match.superlayer || ![candidate.name hasPrefix:@"GainMapViewDisplayItem-"]) {
                continue;
            }
            if (sameCircleFrame(expected, presentationLayerFrameInAncestor(candidate, scene)))
                [paints addObject:candidate];
        }
    }
    return paints;
}
static void refreshSecondaryMergeInputs(MacIslandNativeMaskObserver *input, CGRect primaryBody) {
    CALayer *unionLayer = input.source.superlayer;
    if (!unionLayer) return;
    id blur = activeMergeBlur(unionLayer);
    for (CALayer *branch in unionLayer.sublayers) {
        if (branch == input.source || branch.contents || branch.sublayers.count != 1 ||
            (branch.backgroundColor && CGColorGetAlpha(branch.backgroundColor) > 0))
            continue;
        CALayer *leaf = branch.sublayers.firstObject;
        if (!isSecondaryMergeInput(leaf) || leaf.contents || leaf.sublayers.count) continue;
        MacIslandNativeMaskObserver *secondaryObserver = modelMaskObserver(leaf);
        CGRect circle = presentationLayerFrameInAncestor(leaf, unionLayer);
        BOOL trailing = CGRectGetMidX(circle) >= CGRectGetMidX(primaryBody);
        CGFloat gap = trailing ? CGRectGetMinX(circle) - CGRectGetMaxX(primaryBody)
                               : CGRectGetMinX(primaryBody) - CGRectGetMaxX(circle);
        CGFloat radius = [[blur valueForKey:@"inputRadius"] doubleValue];
        // Both contours spread into the gap before the threshold joins them.
        // Start retiring the paint when the circle's spring targets the
        // inside of the primary, even before its diameter starts shrinking.
        // A full-size circle at its detached endpoint stays visible.
        NSDictionary *screen = screenLayoutForLayer(input.source);
        CGFloat compactHeight = [screen[@"height"] doubleValue];
        CGFloat pixel = [screen[@"pixel"] doubleValue];
        CGRect target = layerFrameInAncestor(leaf, unionLayer, NO);
        CGFloat targetGap = trailing ? CGRectGetMinX(target) - CGRectGetMaxX(primaryBody)
                                     : CGRectGetMinX(primaryBody) - CGRectGetMaxX(target);
        BOOL entering = compactHeight > 0 && targetGap < -pixel &&
                        target.size.height < compactHeight - 3 * pixel;
        BOOL moving = !sameCircleFrame(circle, target);
        BOOL absorbing = moving && (gap < radius || (entering && gap <= 2 * radius));
        NSArray<CALayer *> *paints = blur && gap <= 2 * radius ? secondaryPaints(leaf, unionLayer) : nil;
        MacIslandNativeMaskObserver *detached = !absorbing && paints.count > 1
            ? modelMaskObserver(paints[1]) : nil;
        BOOL suppress = paints.count && (absorbing || detached);
        [secondaryObserver setMergeSuppression:suppress unionLayer:unionLayer blur:blur
                                         paints:absorbing ? paints : (detached ? @[leaf] : nil)];
        [secondaryObserver useDetachedPaint:detached inUnion:unionLayer blur:blur];
    }
}

static void notifyUnionPrimaryObserver(CALayer *secondary) {
    for (CALayer *sibling in secondary.superlayer.superlayer.sublayers) {
        if (!isNativeUnionFill(sibling)) continue;
        MacIslandNativeMaskObserver *primary = modelMaskObserver(sibling);
        if (primary.applied) [primary refreshMask];
    }
}

// An opaque material can draw the shoulder without smoothing it a second
// time through the native merge filter.
static BOOL hasOpaqueContourPeer(MacIslandNativeMaskObserver *input) {
    CALayer *unionLayer = input.source.superlayer;
    CALayer *scene = unionLayer.superlayer;
    if (input.topExtension <= 0) scene = nil;
    if (input.mergeScene != scene) {
        [input.mergeScene removeObserver:input forKeyPath:@"sublayers" context:&sceneLayersKey];
        input.mergeScene = scene;
        [scene addObserver:input forKeyPath:@"sublayers" options:0 context:&sceneLayersKey];
    }
    MacIslandNativeMaskObserver *previous = input.contourPeer;
    CALayer *heldMaterial = previous.source;
    id blur = activeMergeBlur(unionLayer);
    // The two model layers finish their bounds and position writes separately.
    // Once Apple requests the hide, the identified material stays responsible
    // until this same filter hands off. Revalidate ownership, not model endpoints.
    if (scene && previous.heldBlur && previous.heldUnion == unionLayer && previous.applied &&
        previous.mergeInput == input && heldMaterial.superlayer == scene &&
        heldMaterial.mask == previous.shapeMask && !heldMaterial.hidden && heldMaterial.opacity >= 1 &&
        !heldMaterial.contents && !heldMaterial.sublayers.count && isOpaqueBlack(heldMaterial.backgroundColor))
        return YES;
    MacIslandNativeMaskObserver *selected = nil;
    CGRect body = [unionLayer convertRect:nativeBodyFrame(input) toLayer:scene];
    for (CALayer *layer in scene.sublayers) {
        if (layer.superlayer != scene || !isOpaqueBlack(layer.backgroundColor)) continue;
        id association = objc_getAssociatedObject(layer, &maskObserverKey);
        if (![association isKindOfClass:MacIslandNativeMaskObserver.class]) continue;
        MacIslandNativeMaskObserver *peer = association;
        if (!peer.applied || layer.mask != peer.shapeMask) continue;
        CGRect r = nativeBodyFrame(peer);
        // Native material and opaque merge input differ by a backing-pixel inset.
        if (fabs(CGRectGetMinX(r) - CGRectGetMinX(body)) > 1 ||
            fabs(CGRectGetMaxX(r) - CGRectGetMaxX(body)) > 1 ||
            fabs(CGRectGetMinY(r) - CGRectGetMinY(body)) > 1 ||
            fabs(CGRectGetMaxY(r) - CGRectGetMaxY(body)) > 1) continue;
        peer.mergeInput = input;
        if (layer.opacity >= 1 && !layer.contents && !layer.sublayers.count &&
            (!layer.hidden || (blur && !input.source.hidden && input.source.opacity >= 1 &&
                                !unionLayer.hidden && unionLayer.opacity >= 1))) {
            selected = peer;
            break;
        }
    }
    input.contourPeer = selected;
    if (previous != selected && previous.heldBlur) [previous endVisibilityHold:YES];
    // Sharing can hide the material before the merge starts. Reuse the
    // matched native paint until the same blur releases it.
    if (selected.source.hidden) {
        [selected holdVisibilityInUnion:unionLayer blur:blur];
        originalSetHidden(selected.source, @selector(setHidden:), NO);
    }
    return selected != nil;
}

static CGSize paintSize(MacIslandNativeMaskObserver *observer, CGSize size) {
    size.width += 2 * observer.horizontalFlare;
    size.height += observer.topExtension + 2 * observer.pixelInset + observer.bottomExtension;
    return size;
}

static CGPoint paintPosition(MacIslandNativeMaskObserver *observer, CGPoint point) {
    CGPoint anchor = observer.source.anchorPoint;
    point.x += (2 * anchor.x - 1) * observer.horizontalFlare;
    point.y += (anchor.y - 1) * observer.topExtension + (2 * anchor.y - 1) * observer.pixelInset +
               anchor.y * observer.bottomExtension;
    return point;
}

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
        // Match the native background: antialias the Bezier contour, not the
        // mask's rectangular surface edge during fractional native motion.
        _shapeMask.edgeAntialiasingMask = 0;
        _shapeMask.actions = @{@"path": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
        _keys = @[@"bounds", @"position", @"anchorPoint", @"transform",
                  @"superlayer", @"name", @"hidden", @"opacity", @"backgroundColor", @"shadowColor", @"shadowOpacity", @"masksToBounds", @"mask"];
        for (NSString *key in _keys)
            [layer addObserver:self forKeyPath:key options:0 context:&maskObserverKey];
        observeNativeAnimations(layer);
        [self refresh];
    }
    return self;
}

- (void)refresh {
    if (!beginObserverUpdate(self)) return;
    CALayer *source = self.source;
    // Native children may settle before their display parent gets its size.
    // Eligibility must follow that existing parent's layout too.
    CALayer *parent = source.superlayer;
    if (parent != self.observedParent) {
        [self.observedParent removeObserver:self forKeyPath:@"bounds" context:&parentGeometryKey];
        self.observedParent = parent;
        [parent addObserver:self forKeyPath:@"bounds" options:0 context:&parentGeometryKey];
    }
    BOOL ownsMask = source.mask == self.shapeMask;
    BOOL eligible = source && (self.nativeRadius > 0 || self.applied) && isNotchBackground(source, self) &&
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
                if (isNativeUnionFill(source) || (nativeTop > 0 && fabs(nativeTop - pixel) < 0.05)) inset = pixel;
            }
        }
        CGFloat flare = MacIslandNotchFlare;
        // Reach the camera housing's last physical row in scaled modes.
        CGFloat bottom = nativeSceneEdgeCompensation(source) + [screenLayoutForLayer(source)[@"bottomSnap"] doubleValue];
        // Build 26C5035r uses a 6 2/3-point native merge blur. Its
        // three-radius sampling support must continue above the bezel.
        // Reserve it even while idle so native spring geometry never jumps
        // when the filter switches on or off. This is outside the display.
        CGFloat top = isNativeUnionFill(source) ? 20 : 0;
        CGRect bounds = self.nativeBounds;
        CGPoint position = self.nativePosition;
        // The shoulder sits outside the native body, rather than consuming
        // its absorption area. Offset the bounds origin so existing children
        // keep their native coordinates when the paint surface grows.
        bounds.origin.x -= flare;
        bounds.origin.y -= top;
        self.pixelInset = inset;
        self.horizontalFlare = flare;
        self.bottomExtension = bottom;
        self.topExtension = top;
        bounds.size = paintSize(self, bounds.size);
        position = paintPosition(self, position);
        baseSetBounds(source, @selector(setBounds:), bounds);
        baseSetPosition(source, @selector(setPosition:), position);
        originalSetCornerRadius(source, @selector(setCornerRadius:), 0);
        source.mask = self.shapeMask;
        BOOL newlyApplied = !self.applied;
        self.applied = YES;
        if (newlyApplied) {
            for (NSString *key in source.animationKeys) {
                CAAnimation *animation = [source animationForKey:key];
                CAAnimation *adjusted = animationWithoutPillCorners(animation);
                if (adjusted != animation) [source addAnimation:adjusted forKey:key];
            }
        }
        [self refreshMask];
    } else if (self.applied) {
        [self.contourPeer endVisibilityHold:YES];
        [self endVisibilityHold:YES];
        self.contourPeer = nil;
        baseSetBounds(source, @selector(setBounds:), self.nativeBounds);
        baseSetPosition(source, @selector(setPosition:), self.nativePosition);
        if (ownsMask) source.mask = nil;
        originalSetCornerRadius(source, @selector(setCornerRadius:), self.nativeRadius);
        self.applied = NO;
        removeNativeMaskGeometry(self);
    }
    if (!self.applied) {
        if (self.observedUnion &&
            (source.superlayer.superlayer != self.observedUnion || !isSecondaryMergeInput(source)))
            [self setMergeSuppression:NO unionLayer:nil blur:nil paints:nil];
        synchronizeNativeMaskGeometry(self);
        if (isSecondaryMergeInput(source)) notifyUnionPrimaryObserver(source);
    }
    // Re-evaluate immediately if the native material is hidden or removed.
    [self.mergeInput refreshMask];
    [CATransaction commit];
    endObserverUpdate(self);
}

- (void)refreshMask {
    CALayer *source = self.source;
    if (!self.applied) {
        if (isSecondaryMergeInput(source)) {
            synchronizeNativeMaskGeometry(self);
            notifyUnionPrimaryObserver(source);
        }
        return;
    }
    if (!source || source.mask != self.shapeMask) return;
    synchronizeNativeMaskGeometry(self);
    CGRect bounds = source.bounds;
    CGSize size = bounds.size;
    CGPoint position = source.position;
    CGPoint anchor = source.anchorPoint;
    CATransform3D transform = source.transform;
    for (id modifier in nativeModifierObject(source, @"presentationModifiers")) {
        if (!nativeModifierEnabled(modifier)) continue;
        NSString *key = nativeModifierObject(modifier, @"keyPath");
        id value = nativeModifierObject(modifier, @"value");
        if (![value isKindOfClass:NSValue.class]) continue;
        const char *type = [value objCType];
        if ([key isEqual:@"bounds.size"] && !strcmp(type, @encode(CGSize))) size = [value sizeValue];
        if ([key isEqual:@"position"] && !strcmp(type, @encode(CGPoint))) position = [value pointValue];
        if ([key isEqual:@"anchorPoint"] && !strcmp(type, @encode(CGPoint))) anchor = [value pointValue];
        if ([key isEqual:@"transform"] && !strcmp(type, @encode(CATransform3D))) transform = [value CATransform3DValue];
    }
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return;
    CGFloat scaleY = hypot(transform.m21, transform.m22);
    CGFloat top = MAX(0, -(position.y - anchor.y * size.height)) / MAX(scaleY, 0.001);
    self.shapeMask.bounds = (CGRect){CGPointZero, size};
    self.shapeMask.position = bounds.origin;
    self.shapeMask.contentsScale = MAX(source.contentsScale, 2);
    BOOL peerOwnsShoulder = hasOpaqueContourPeer(self) && activeMergeBlur(source.superlayer);
    CGPathRef path = notchMaskPathAtTop(size, top, !peerOwnsShoulder, scaleY);
    self.shapeMask.path = path;
    CGPathRelease(path);
    if (isNativeUnionFill(source)) {
        CGRect primaryBody = CGRectMake((position.x - anchor.x * size.width) + self.horizontalFlare,
                                        (position.y - anchor.y * size.height) + self.topExtension,
                                        MAX(0, size.width - 2 * self.horizontalFlare),
                                        MAX(0, size.height - self.topExtension));
        refreshSecondaryMergeInputs(self, primaryBody);
    }
}

// Apple hides its existing primary material partway through closing, before
// the merge kernel is disabled. Preserve this previously-visible paint until
// the native filter handoff; a new show request cancels the pending hide.
- (void)endVisibilityHold:(BOOL)applyHide {
    if (!self.heldBlur) return;
    [self.heldBlur removeObserver:self forKeyPath:@"inputRadius" context:&mergeVisibilityKey];
    [self.heldBlur removeObserver:self forKeyPath:@"enabled" context:&mergeVisibilityKey];
    [self.heldUnion removeObserver:self forKeyPath:@"filters" context:&mergeVisibilityKey];
    self.heldBlur = nil;
    self.heldUnion = nil;
    if (applyHide && self.source) originalSetHidden(self.source, @selector(setHidden:), YES);
}

- (void)holdVisibilityInUnion:(CALayer *)group blur:(id)blur {
    if (self.heldBlur || !blur) return;
    self.heldUnion = group;
    self.heldBlur = blur;
    [group addObserver:self forKeyPath:@"filters" options:0 context:&mergeVisibilityKey];
    [blur addObserver:self forKeyPath:@"inputRadius" options:0 context:&mergeVisibilityKey];
    [blur addObserver:self forKeyPath:@"enabled" options:0 context:&mergeVisibilityKey];
}

- (void)updateVisibilityHold {
    if (!self.heldBlur) return;
    id blur = activeMergeBlur(self.heldUnion);
    if (blur == self.heldBlur) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (blur) {
        [self.heldBlur removeObserver:self forKeyPath:@"inputRadius" context:&mergeVisibilityKey];
        [self.heldBlur removeObserver:self forKeyPath:@"enabled" context:&mergeVisibilityKey];
        self.heldBlur = blur;
        [blur addObserver:self forKeyPath:@"inputRadius" options:0 context:&mergeVisibilityKey];
        [blur addObserver:self forKeyPath:@"enabled" options:0 context:&mergeVisibilityKey];
    } else {
        [self endVisibilityHold:YES];
        [self.mergeInput refreshMask];
    }
    [CATransaction commit];
}

- (void)useDetachedPaint:(MacIslandNativeMaskObserver *)peer inUnion:(CALayer *)group blur:(id)blur {
    if (self.detachedPaint != peer) {
        [self.detachedPaint endVisibilityHold:YES];
        self.detachedPaint = peer;
    }
    // The stock fallback is painted at the same spring frame, outside the
    // union. It keeps the two contours separate while the filter is active.
    if (peer.source.hidden) {
        [peer holdVisibilityInUnion:group blur:blur];
        originalSetHidden(peer.source, @selector(setHidden:), NO);
    }
}

- (void)setMergeSuppression:(BOOL)suppress unionLayer:(CALayer *)unionLayer blur:(id)blur
                       paints:(NSArray<CALayer *> *)paints {
    if (!suppress) [self useDetachedPaint:nil inUnion:nil blur:nil];
    id nextBlur = suppress ? blur : nil;
    CALayer *nextUnion = nextBlur ? unionLayer : nil;
    if (self.observedBlur != nextBlur || self.observedUnion != nextUnion) {
        [self.observedBlur removeObserver:self forKeyPath:@"inputRadius" context:&secondaryMergeKey];
        [self.observedBlur removeObserver:self forKeyPath:@"enabled" context:&secondaryMergeKey];
        [self.observedUnion removeObserver:self forKeyPath:@"filters" context:&secondaryMergeKey];
        self.observedBlur = nextBlur;
        self.observedUnion = nextUnion;
        [nextUnion addObserver:self forKeyPath:@"filters" options:0 context:&secondaryMergeKey];
        [nextBlur addObserver:self forKeyPath:@"inputRadius" options:0 context:&secondaryMergeKey];
        [nextBlur addObserver:self forKeyPath:@"enabled" options:0 context:&secondaryMergeKey];
    }
    NSArray<CALayer *> *targets = suppress ? paints : @[];
    NSMutableArray<NSNumber *> *opacities = [NSMutableArray arrayWithCapacity:targets.count];
    for (CALayer *paint in targets) [opacities addObject:@(paint.opacity)];
    NSMutableArray<CALayer *> *restored = [NSMutableArray array];
    NSMutableArray<NSNumber *> *original = [NSMutableArray array];
    os_unfair_lock_lock(&maskStateLock);
    if (targets.count && !self.suppressedPaint) self.suppressedPaint = [NSMapTable weakToStrongObjectsMapTable];
    for (CALayer *paint in self.suppressedPaint.keyEnumerator.allObjects) {
        if ([targets containsObject:paint]) continue;
        NSNumber *opacity = [self.suppressedPaint objectForKey:paint];
        [self.suppressedPaint removeObjectForKey:paint];
        if (opacity) {
            [restored addObject:paint];
            [original addObject:opacity];
        }
    }
    for (NSUInteger i = 0; i < targets.count; i++) {
        if (opacities[i].floatValue > 0.0f || ![self.suppressedPaint objectForKey:targets[i]])
            [self.suppressedPaint setObject:opacities[i] forKey:targets[i]];
    }
    os_unfair_lock_unlock(&maskStateLock);
    // Core Animation can invoke observers synchronously; leave the lock first.
    for (NSUInteger i = 0; i < restored.count; i++)
        if (restored[i].opacity == 0.0f) restored[i].opacity = original[i].floatValue;
    for (CALayer *paint in targets)
        if (paint.opacity > 0.0f) paint.opacity = 0.0f;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context == &mergeVisibilityKey) { [self updateVisibilityHold]; return; }
    if (context == &secondaryMergeKey) {
        id blur = activeMergeBlur(self.observedUnion);
        if (!blur || !isSecondaryMergeInput(self.source)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self setMergeSuppression:NO unionLayer:nil blur:nil paints:nil];
            [CATransaction commit];
        } else {
            notifyUnionPrimaryObserver(self.source);
        }
        return;
    }
    if (context == &sceneLayersKey) { [self refreshMask]; return; }
    if (context == &parentGeometryKey) { [self refresh]; return; }
    if (context != &maskObserverKey) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (self.updating) return;
    if ([keyPath isEqualToString:@"hidden"] || [keyPath isEqualToString:@"opacity"]) {
        [self.mergeInput refreshMask];
        return;
    }
    CALayer *source = self.source;
    CGRect bounds = source.bounds;
    CGPoint position = source.position;
    if ([keyPath isEqualToString:@"bounds"]) self.nativeBounds = bounds;
    if ([keyPath isEqualToString:@"position"]) self.nativePosition = position;
    [self refresh];
}

- (void)dealloc {
    [_contourPeer endVisibilityHold:YES];
    [self endVisibilityHold:YES];
    [self.mergeScene removeObserver:self forKeyPath:@"sublayers" context:&sceneLayersKey];
    [self.observedParent removeObserver:self forKeyPath:@"bounds" context:&parentGeometryKey];
    removeNativeMaskGeometry(self);
    CALayer *source = _source;
    for (NSString *key in _keys)
        [source removeObserver:self forKeyPath:key context:&maskObserverKey];
    [self setMergeSuppression:NO unionLayer:nil blur:nil paints:nil];
    if (source.mask == _shapeMask) {
        if (_applied) {
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
@interface MacIslandModifierBinding : NSObject
@property(nonatomic, weak) MacIslandNativeMaskObserver *observer;
@property(nonatomic, weak) id modifier;
@property(nonatomic, copy) NSString *key;
@property(atomic, strong) id nativeValue;
@property(atomic, strong) id nativeVelocity;
@end
@implementation MacIslandModifierBinding
@end

static char modifierBindingKey, nativeMaskGroupObserversKey;
static void (*originalModifierValueVelocity)(id, SEL, id, id);
static void (*originalModifierEnabled)(id, SEL, BOOL);
static void (*originalAddPresentationModifier)(id, SEL, id);
static void (*originalSetPresentationModifiers)(id, SEL, id);
static void (*originalRemovePresentationModifier)(id, SEL, id);
static id nativeModifierObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static id paintValue(MacIslandModifierBinding *binding, id value) {
    if ([binding.key isEqual:@"cornerRadius"]) return @0;
    if (![value isKindOfClass:NSValue.class]) return value;
    if ([binding.key isEqual:@"bounds.size"] && !strcmp([value objCType], @encode(CGSize)))
        return [NSValue valueWithSize:paintSize(binding.observer, [value sizeValue])];
    if ([binding.key isEqual:@"position"] && !strcmp([value objCType], @encode(CGPoint)))
        return [NSValue valueWithPoint:paintPosition(binding.observer, [value pointValue])];
    return value;
}

// On this build setValue: forwards to setValue:velocity: with nil.
// Intercept the terminal setter once, retaining Apple's derivative for motion.
static void setModifierValueVelocity(id modifier, SEL selector, id value, id velocity) {
    MacIslandModifierBinding *binding = objc_getAssociatedObject(modifier, &modifierBindingKey);
    if (binding.observer.applied) {
        binding.nativeValue = value;
        binding.nativeVelocity = velocity;
        value = paintValue(binding, value);
        if (velocity && [binding.key isEqual:@"cornerRadius"]) velocity = @0;
    }
    originalModifierValueVelocity(modifier, selector, value, velocity);
}
static void setModifierEnabled(id modifier, SEL selector, BOOL enabled) {
    originalModifierEnabled(modifier, selector, enabled);
    MacIslandModifierBinding *binding = objc_getAssociatedObject(modifier, &modifierBindingKey);
    if (binding.observer.applied) [binding.observer refreshMask];
}
static void bindNativeModifier(MacIslandNativeMaskObserver *observer, id modifier, NSString *key) {
    if (!([key isEqual:@"cornerRadius"] || [key isEqual:@"bounds.size"] || [key isEqual:@"position"])) return;
    if (((BOOL (*)(id, SEL))objc_msgSend)(modifier, NSSelectorFromString(@"additive"))) return;
    MacIslandModifierBinding *binding = objc_getAssociatedObject(modifier, &modifierBindingKey);
    if (binding && binding.observer != observer && binding.observer) return;
    if (!binding || !binding.observer) {
        binding = [MacIslandModifierBinding new];
        binding.observer = observer;
        binding.modifier = modifier;
        binding.key = key;
        binding.nativeValue = nativeModifierObject(modifier, @"value");
        // A spring may already be moving when Apple attaches its modifier.
        // This pinned build exposes the value getter but only an object ivar
        // for its derivative. Read it once at attachment, never on each flush.
        Ivar velocity = class_getInstanceVariable([modifier class], "_velocity");
        if (velocity && ivar_getTypeEncoding(velocity)[0] == '@')
            binding.nativeVelocity = object_getIvar(modifier, velocity);
        objc_setAssociatedObject(modifier, &modifierBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_unfair_lock_lock(&maskStateLock);
        observer.modifierBindings = [observer.modifierBindings ?: @[] arrayByAddingObject:binding];
        os_unfair_lock_unlock(&maskStateLock);
    }
    id adjusted = paintValue(binding, binding.nativeValue);
    if (adjusted && ![adjusted isEqual:nativeModifierObject(modifier, @"value")])
        originalModifierValueVelocity(modifier, NSSelectorFromString(@"setValue:velocity:"), adjusted,
                                      [key isEqual:@"cornerRadius"] && binding.nativeVelocity ? @0 : binding.nativeVelocity);
}
static void unbindModifier(MacIslandModifierBinding *binding) {
    id modifier = binding.modifier;
    if (modifier && objc_getAssociatedObject(modifier, &modifierBindingKey) == binding) {
        objc_setAssociatedObject(modifier, &modifierBindingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        originalModifierValueVelocity(modifier, NSSelectorFromString(@"setValue:velocity:"), binding.nativeValue, binding.nativeVelocity);
    }
    binding.observer = nil;
}
static MacIslandNativeMaskObserver *modelMaskObserver(CALayer *layer) {
    if (layer.modelLayer != layer) return nil;
    id value = objc_getAssociatedObject(layer, &maskObserverKey);
    return [value isKindOfClass:MacIslandNativeMaskObserver.class] ? value : nil;
}
static void modifierListChanged(CALayer *layer) {
    MacIslandNativeMaskObserver *observer = modelMaskObserver(layer);
    if (observer.applied) [observer refreshMask];
    else if (observer) synchronizeNativeMaskGeometry(observer);
    else if (hasMergeFilters(layer.superlayer)) {
        for (CALayer *child in layer.sublayers) {
            MacIslandNativeMaskObserver *childObserver = modelMaskObserver(child);
            if (childObserver) synchronizeNativeMaskGeometry(childObserver);
        }
    }
}
static void addPresentationModifier(CALayer *layer, SEL selector, id modifier) {
    originalAddPresentationModifier(layer, selector, modifier);
    modifierListChanged(layer);
}
static void setPresentationModifiers(CALayer *layer, SEL selector, id modifiers) {
    originalSetPresentationModifiers(layer, selector, modifiers);
    modifierListChanged(layer);
}
static BOOL nativeModifierEnabled(id modifier) {
    SEL selector = NSSelectorFromString(@"isEnabled");
    return [modifier respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(modifier, selector);
}
static void removeNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    // Detach all state under the lock, then call out to Core Animation.
    os_unfair_lock_lock(&maskStateLock);
    id size = observer.nativeMaskSize;
    NSArray *groups = observer.nativeMaskGroups;
    NSArray *bindings = observer.modifierBindings;
    observer.nativeMaskSize = nil;
    observer.nativeMaskGroups = nil;
    observer.modifierBindings = nil;
    os_unfair_lock_unlock(&maskStateLock);
    if (size && originalRemovePresentationModifier)
        originalRemovePresentationModifier(observer.shapeMask, NSSelectorFromString(@"removePresentationModifier:"), size);
    for (id group in groups) {
        @synchronized(group) { [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) removeObject:observer]; }
    }
    for (MacIslandModifierBinding *binding in bindings) unbindModifier(binding);
}
static void synchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    if (!originalAddPresentationModifier) return;
    BOOL member = observer.applied || isSecondaryMergeInput(observer.source);
    NSArray *modifiers = member ? nativeModifierObject(observer.source, @"presentationModifiers") : nil;
    NSMutableArray *stale = [NSMutableArray array];
    for (MacIslandModifierBinding *binding in observer.modifierBindings) {
        if (!observer.applied || !binding.modifier || ![modifiers containsObject:binding.modifier])
            [stale addObject:binding];
    }
    if (stale.count) {
        os_unfair_lock_lock(&maskStateLock);
        NSMutableArray *kept = [observer.modifierBindings mutableCopy];
        for (id binding in stale) [kept removeObjectIdenticalTo:binding];
        observer.modifierBindings = kept;
        os_unfair_lock_unlock(&maskStateLock);
        for (MacIslandModifierBinding *binding in stale) unbindModifier(binding);
    }
    id size = nil;
    NSMutableArray *groups = [NSMutableArray array];
    for (id modifier in modifiers) {
        NSString *key = nativeModifierObject(modifier, @"keyPath");
        if (observer.applied) {
            bindNativeModifier(observer, modifier, key);
            if ([key isEqual:@"bounds.size"] && nativeModifierEnabled(modifier) &&
                ((MacIslandModifierBinding *)objc_getAssociatedObject(modifier, &modifierBindingKey)).observer == observer)
                size = modifier;
        }
        id group = nativeModifierObject(modifier, @"group");
        if (group && ![groups containsObject:group]) [groups addObject:group];
    }
    if (!observer.applied && isSecondaryMergeInput(observer.source)) {
        for (id modifier in nativeModifierObject(observer.source.superlayer, @"presentationModifiers")) {
            id group = nativeModifierObject(modifier, @"group");
            if (group && ![groups containsObject:group]) [groups addObject:group];
        }
    }
    os_unfair_lock_lock(&maskStateLock);
    NSArray *previousGroups = observer.nativeMaskGroups ?: @[];
    observer.nativeMaskGroups = groups;
    id previousSize = observer.nativeMaskSize;
    BOOL sizeChanged = previousSize != size;
    if (sizeChanged) observer.nativeMaskSize = size;
    os_unfair_lock_unlock(&maskStateLock);
    for (id group in previousGroups) {
        if (![groups containsObject:group]) {
            @synchronized(group) { [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) removeObject:observer]; }
        }
    }
    for (id group in groups) {
        if (![previousGroups containsObject:group]) {
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
    if (!sizeChanged) return;
    if (previousSize)
        originalRemovePresentationModifier(observer.shapeMask, NSSelectorFromString(@"removePresentationModifier:"), previousSize);
    if (size) originalAddPresentationModifier(observer.shapeMask, NSSelectorFromString(@"addPresentationModifier:"), size);
}
static _Thread_local NSUInteger nativeGroupFlushDepth;
static NSArray *nativeGroupMaskObservers(id group) {
    NSArray *snapshot;
    @synchronized(group) { snapshot = [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) allObjects]; }
    // Reparenting an entire secondary branch need not notify its leaf.
    for (MacIslandNativeMaskObserver *observer in snapshot)
        if (observer.applied || isSecondaryMergeInput(observer.source)) return snapshot;
    return nil;
}
static void refreshNativeGroupMasks(NSArray *observers) {
    for (MacIslandNativeMaskObserver *observer in observers) [observer refreshMask];
}
static void installNativeGroupFlushHooks(void) {
    Class groupClass = NSClassFromString(@"CAPresentationModifierGroup");
    // All three untimed entry points forward to their timed counterparts.
    // A local flush prepares the group's back buffer without publishing it.
    SEL transaction = NSSelectorFromString(@"flushWithTransactionAndTargetTime:");
    Method method = class_getInstanceMethod(groupClass, transaction);
    if (!method) return;
    void (*submit)(id, SEL, double) = (void *)method_getImplementation(method);
    for (NSString *name in @[@"flushWithTargetTime:", @"flushLocallyWithTargetTime:", @"flushWithTransactionAndTargetTime:"]) {
        SEL selector = NSSelectorFromString(name);
        Method entry = class_getInstanceMethod(groupClass, selector);
        if (!entry) continue;
        void (*previous)(id, SEL, double) = (void *)method_getImplementation(entry);
        method_setImplementation(entry, imp_implementationWithBlock(^(id group, double time) {
            NSArray *observers = nativeGroupFlushDepth ? nil : nativeGroupMaskObservers(group);
            if (!observers.count) { previous(group, selector, time); return; }
            nativeGroupFlushDepth++;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            refreshNativeGroupMasks(observers);
            if (selector == NSSelectorFromString(@"flushWithTargetTime:")) submit(group, transaction, time);
            else previous(group, selector, time);
            [CATransaction commit];
            nativeGroupFlushDepth--;
        }));
    }
}
static void removePresentationModifier(CALayer *layer, SEL selector, id modifier) {
    originalRemovePresentationModifier(layer, selector, modifier);
    modifierListChanged(layer);
}

static void installNativeCornerModifierHooks(void) {
    Class modifier = NSClassFromString(@"CAPresentationModifier");
    Method value = class_getInstanceMethod(modifier, NSSelectorFromString(@"setValue:"));
    Method velocity = class_getInstanceMethod(modifier, NSSelectorFromString(@"setValue:velocity:"));
    Method enabled = class_getInstanceMethod(modifier, NSSelectorFromString(@"setEnabled:"));
    Method add = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"addPresentationModifier:"));
    Method set = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"setPresentationModifiers:"));
    Method remove = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"removePresentationModifier:"));
    if (!value || !velocity || !enabled || !add || !set || !remove || originalModifierValueVelocity) return;
    originalModifierValueVelocity = (void *)method_getImplementation(velocity);
    originalModifierEnabled = (void *)method_getImplementation(enabled);
    originalAddPresentationModifier = (void *)method_getImplementation(add);
    originalSetPresentationModifiers = (void *)method_getImplementation(set);
    originalRemovePresentationModifier = (void *)method_getImplementation(remove);
    method_setImplementation(velocity, (IMP)setModifierValueVelocity);
    method_setImplementation(enabled, (IMP)setModifierEnabled);
    method_setImplementation(add, (IMP)addPresentationModifier);
    method_setImplementation(set, (IMP)setPresentationModifiers);
    method_setImplementation(remove, (IMP)removePresentationModifier);
    installNativeGroupFlushHooks();
}

static void setNativeMaterialHidden(CALayer *layer, SEL selector, BOOL hidden) {
    id association = objc_getAssociatedObject(layer, &maskObserverKey);
    if ([association isKindOfClass:MacIslandNativeMaskObserver.class]) {
        MacIslandNativeMaskObserver *peer = association;
        MacIslandNativeMaskObserver *input = peer.mergeInput;
        if (!hidden) [peer endVisibilityHold:NO];
        else if (peer.heldBlur && !peer.applied) return;
        else if (input && input.contourPeer == peer && input.applied && peer.applied &&
                 !layer.hidden && layer.opacity >= 1 && !layer.contents && layer.sublayers.count == 0 &&
                 isOpaqueBlack(layer.backgroundColor) && layer.mask == peer.shapeMask &&
                 layer.superlayer == input.source.superlayer.superlayer) {
            CALayer *group = input.source.superlayer;
            id blur = activeMergeBlur(group);
            if (blur) {
                [peer holdVisibilityInUnion:group blur:blur];
                return;
            }
        }
    }
    originalSetHidden(layer, selector, hidden);
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
        originalSetCornerRadius(layer, selector, observer.applied && isNotchBackground(model, observer) ? 0 : radius);
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

static void (*baseSetSublayerTransform)(id, SEL, CATransform3D);

// Apply the half-backing-pixel sampling correction after the native scene has
// drawn its masks and merge effects. Do not reshape individual islands.
@interface MacIslandSceneOriginObserver : NSObject
@property(nonatomic, weak) CALayer *source;
@property(nonatomic) CATransform3D nativeTransform;
@property(nonatomic) CGFloat pixel;
@property(nonatomic) BOOL updating;
- (instancetype)initWithLayer:(CALayer *)layer;
- (void)refresh;
@end
@implementation MacIslandSceneOriginObserver
- (instancetype)initWithLayer:(CALayer *)layer {
    if ((self = [super init])) {
        _source = layer;
        _nativeTransform = layer.sublayerTransform;
        [layer addObserver:self forKeyPath:@"sublayerTransform" options:0 context:&sceneOriginObserverKey];
    }
    return self;
}
- (void)refresh {
    if (self.updating || !self.source) return;
    self.updating = YES;
    CATransform3D transform = self.nativeTransform;
    transform.m42 -= self.pixel;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    baseSetSublayerTransform(self.source, @selector(setSublayerTransform:), transform);
    [CATransaction commit];
    self.updating = NO;
}
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &sceneOriginObserverKey) {
        [super observeValueForKeyPath:key ofObject:object change:change context:context];
        return;
    }
    if (self.updating) return;
    CATransform3D expected = self.nativeTransform;
    expected.m42 -= self.pixel;
    CATransform3D value = self.source.sublayerTransform;
    if (CATransform3DEqualToTransform(value, expected)) return;
    self.nativeTransform = value;
    [self refresh];
}
- (void)dealloc {
    CALayer *source = self.source;
    [source removeObserver:self forKeyPath:@"sublayerTransform" context:&sceneOriginObserverKey];
    if (source && self.pixel > 0) baseSetSublayerTransform(source, @selector(setSublayerTransform:), self.nativeTransform);
}
@end

static void refreshNativeBackgroundCoverage(CALayer *layer) {
    id observer = objc_getAssociatedObject(layer, &maskObserverKey);
    if ([observer isKindOfClass:MacIslandNativeMaskObserver.class]) [observer refresh];
    for (CALayer *child in layer.sublayers) refreshNativeBackgroundCoverage(child);
}

static void refreshNativeSceneOrigin(NSWindow *window) {
    if (![window isKindOfClass:NSWindow.class]) return;
    CALayer *root = window.contentView.layer;
    if (!root) return;
    MacIslandSceneOriginObserver *observer = objc_getAssociatedObject(root, &sceneOriginObserverKey);
    NSScreen *screen = window.screen;
    NSRect left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea;
    BOOL eligible = window.visible && screen.safeAreaInsets.top > 0 && !NSIsEmptyRect(left) && !NSIsEmptyRect(right) &&
        [NSStringFromClass(root.class) hasPrefix:@"MBGated_"] &&
        fabs(window.frame.size.width - screen.frame.size.width) < 1 &&
        fabs(window.frame.size.height - screen.frame.size.height) < 1 &&
        fabs(root.bounds.size.width - screen.frame.size.width) < 1 &&
        fabs(root.bounds.size.height - screen.frame.size.height) < 1;
    if (!eligible && !observer) return;
    if (!observer) {
        observer = [[MacIslandSceneOriginObserver alloc] initWithLayer:root];
        objc_setAssociatedObject(root, &sceneOriginObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat pixel = eligible ? 0.5 / MAX(screen.backingScaleFactor, 1) : 0;
    if (observer.pixel != pixel) { observer.pixel = pixel; [observer refresh]; refreshNativeBackgroundCoverage(root); }
}
static void refreshAllNativeSceneOrigins(void) {
    for (NSWindow *window in NSApp.windows) refreshNativeSceneOrigin(window);
}

__attribute__((constructor))
static void installNativeNotchMask(void) {
    if (!MacIslandIsMenuBarAgent()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        updateScreenGeometry();
        refreshAllNativeSceneOrigins();
        for (NSNotificationName name in @[NSWindowDidUpdateNotification, NSWindowDidResizeNotification, NSWindowDidChangeScreenNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) { refreshNativeSceneOrigin(notification.object); }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(__unused NSNotification *notification) {
            updateScreenGeometry();
            refreshAllNativeSceneOrigins();
            // A resolution change can keep the backing scale (so no pixel change
            // above) while moving the notch in points. Re-evaluate every mask.
            for (NSWindow *window in NSApp.windows) {
                CALayer *root = window.contentView.layer;
                if (root) refreshNativeBackgroundCoverage(root);
            }
        }];
    });
    Method method = class_getInstanceMethod(CALayer.class, @selector(setCornerRadius:));
    originalSetCornerRadius = (void *)method_getImplementation(method);
    baseSetBounds = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setBounds:)));
    baseSetPosition = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setPosition:)));
    baseSetSublayerTransform = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setSublayerTransform:)));
    Method visibility = class_getInstanceMethod(CALayer.class, @selector(setHidden:));
    originalSetHidden = (void *)method_getImplementation(visibility);
    method_setImplementation(visibility, (IMP)setNativeMaterialHidden);
    method_setImplementation(method, (IMP)setCornerRadius);
    installNativeCornerModifierHooks();
}
MACISLAND_MASK_M

  cat > "$SCRATCH/loader.py" <<'MACISLAND_LOADER_PY'
"""Inject the Dynamic Island interposer into MenuBarAgent and keep it applied."""

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


LAUNCHCTL = "/bin/launchctl"
SERVICE = f"gui/{os.getuid()}/com.apple.MenuBarAgent"
ENVIRONMENT_KEY = "DYLD_INSERT_LIBRARIES"
LIBRARY = str(Path.home() / "Library/MacIsland/island.dylib")
SUPPORTED_BUILD = "26C5035r"
MUSIC_EXE = "/System/Library/CoreServices/MediaRemoteUIService.app/Contents/MacOS/MediaRemoteUIService"
CLOCK_EXE = "/System/Library/CoreServices/ClockAngel.app/Contents/MacOS/ClockAngel"
# Readiness is read through a fresh debugger attachment. Wait progressively,
# rather than attaching repeatedly while the provider's main queue is busy.
MUSIC_READY_DELAYS = (0.15, 0.35, 0.75, 1.5, 2.5)
# Automatic reapplication budget per component. A patch that makes a service
# crash repeatedly must not turn into an endless restart loop.
REAPPLY_LIMIT = 3
REAPPLY_WINDOW = 15 * 60


def log(message, *, error=False):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", file=sys.stderr if error else sys.stdout, flush=True)


def state_path():
    return Path(LIBRARY).with_name("loader-state.json")


def load_state():
    try:
        value = json.loads(state_path().read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save_state(state):
    path = state_path()
    temporary = path.with_name(path.name + ".next")
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(path)


def current_build():
    return subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip()


def require_supported_build():
    build = current_build()
    if build != SUPPORTED_BUILD:
        raise RuntimeError(
            f"Unsupported OS build {build} (supported: {SUPPORTED_BUILD}); services left unchanged")
    return build


def require_trusted_library(library):
    """Refuse to inject code from a shared-writable or redirected install path."""
    for path, expected in ((library.parent, stat.S_ISDIR), (library, stat.S_ISREG)):
        info = path.lstat()
        if not expected(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError(
                f"{path} must be owned by the current user, not be a symbolic link, "
                "and not be group- or world-writable")


def find_lldb(*, required=True):
    try:
        return subprocess.check_output(["/usr/bin/xcrun", "--find", "lldb"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        if required:
            raise RuntimeError("LLDB was not found in the selected developer tools")
        return None


def process_identity(pid):
    """PID plus start time, so a reused PID is never mistaken for a patched one."""
    if not pid:
        return None
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                            capture_output=True, text=True)
    start = result.stdout.strip()
    return f"{pid}@{start}" if result.returncode == 0 and start else None


def is_traced(pid):
    flags = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "flags="], text=True).strip()
    return bool(int(flags, 16) & 0x800)  # Darwin P_TRACED


def menu_bar_agent_pid():
    """Return the current MenuBarAgent PID, or None while it is restarting."""
    try:
        output = subprocess.check_output([LAUNCHCTL, "print", SERVICE], text=True)
    except subprocess.CalledProcessError:
        return None
    match = re.search(r"^\s*pid = (\d+)", output, re.MULTILINE)
    return int(match.group(1)) if match else None


def legacy_main(library_path):
    """Restart through the launch environment. The caller holds loader.lock."""
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
                return current_pid
            time.sleep(0.1)
        raise RuntimeError("MenuBarAgent did not report a new PID")
    finally:
        restore = (
            ["unsetenv", ENVIRONMENT_KEY]
            if old_value is None
            else ["setenv", ENVIRONMENT_KEY, old_value]
        )
        subprocess.run([LAUNCHCTL, *restore], check=True)
        print("Prior launch environment restored", flush=True)


def current_boot_arguments():
    # NVRAM describes the next boot; kern.bootargs describes this process's OS.
    return subprocess.check_output(
        ["/usr/sbin/sysctl", "-n", "kern.bootargs"], text=True
    ).strip()


def amfi_globally_disabled():
    return any(
        token.startswith("amfi_get_out_of_my_way=")
        and token.split("=", 1)[1] in ("1", "0x1")
        for token in current_boot_arguments().split()
    )


@contextmanager
def temporary_launch_environment(library_path):
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
        environment.group(1), re.MULTILINE,
    )
    old_value = prior.group(1) if prior else None
    value = f"{old_value}:{library_path}" if old_value else str(library_path)
    try:
        subprocess.run([LAUNCHCTL, "setenv", ENVIRONMENT_KEY, value], check=True)
        yield
    finally:
        restore = (["unsetenv", ENVIRONMENT_KEY] if old_value is None else
                   ["setenv", ENVIRONMENT_KEY, old_value])
        subprocess.run([LAUNCHCTL, *restore], check=True)


def debugger_load(service, library_path, lldb, *, timeout=30):
    """Request a suspended launch, attach briefly, and verify the loaded library."""
    if any(c in str(library_path) for c in "\n\r\0"):
        raise ValueError("Invalid library path")
    launched = False
    try:
        # Like the installed loader, stage the variable only until launchd has
        # spawned the target. Restore it before waiting for debugger attachment.
        # kickstart -s works as the service owner; launchctl debug needs root.
        with temporary_launch_environment(library_path):
            result = subprocess.run(
                [LAUNCHCTL, "kickstart", "-k", "-p", "-s", service], check=True,
                capture_output=True, text=True, timeout=timeout,
            )
            launched = True
        pid = int(result.stdout.strip())
        with tempfile.TemporaryDirectory(prefix="macisland-debugger-") as scratch:
            # Attach to the requested suspended launch and detach to resume it.
            # Startup timing can vary; verify the mapping rather than assume
            # attachment occurred before dyld. No debugger remains running.
            result = subprocess.run(
                [lldb, "--no-lldbinit", "--batch", "--attach-pid", str(pid),
                 "--one-line-before-file",
                 f"settings set symbols.clang-modules-cache-path {scratch}/modules",
                 "--one-line", "process detach"],
                check=True, capture_output=True, text=True, timeout=timeout,
            )
            print(result.stdout, end="", flush=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            mapped = subprocess.run(
                ["/usr/bin/vmmap", "-w", str(pid)], capture_output=True,
                text=True, timeout=timeout,
            )
            if mapped.returncode == 0 and str(library_path) in mapped.stdout:
                print(f"Verified injected library in PID {pid}", flush=True)
                return pid
            time.sleep(0.2)
        raise RuntimeError("Process started but injected library was not verified")
    except BaseException:
        if launched:
            # No persistent launch overrides exist. Restart normally if attach
            # or loading failed, rather than leave a suspended system service.
            subprocess.run(
                [LAUNCHCTL, "kill", "SIGKILL", service],
                capture_output=True, timeout=timeout,
            )
            subprocess.run(
                [LAUNCHCTL, "kickstart", service],
                capture_output=True, timeout=timeout,
            )
        raise


def provider_pid(executable):
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", Path(executable).name],
        capture_output=True, text=True,
    )
    if result.returncode == 1:
        return None
    result.check_returncode()
    pid = result.stdout.strip()
    if not pid.isdecimal() or subprocess.check_output(
        ["/bin/ps", "-p", pid, "-o", "comm="], text=True,
    ).strip() != executable:
        raise RuntimeError(f"Could not identify the current user's {Path(executable).name} provider")
    return pid


def music_pid():
    return provider_pid(MUSIC_EXE)


def clock_pid():
    return provider_pid(CLOCK_EXE)


def spotlight_pid():
    return provider_pid("/System/Applications/Siri AI.app/Contents/MacOS/Siri AI")


def available_provider_pid(pid, get_pid):
    if get_pid() != pid:
        raise RuntimeError("The UI provider restarted")
    flags = subprocess.check_output(["/bin/ps", "-p", pid, "-o", "flags="], text=True)
    if int(flags.strip(), 16) & 0x800:
        raise RuntimeError("The UI provider is already being debugged")


def available_music_pid(pid):
    available_provider_pid(pid, music_pid)


def stop_managed_provider(library, get_pid):
    """Unmap our old provider code before replacing it or restoring a backup."""
    pid = get_pid()
    if pid is None:
        return False
    mapped = subprocess.check_output(["/usr/bin/vmmap", "-w", pid], text=True, timeout=20)
    if not any(line.rstrip().endswith(" " + str(library)) for line in mapped.splitlines()):
        return False
    available_provider_pid(pid, get_pid)
    os.kill(int(pid), 15)
    for _ in range(50):
        if get_pid() != pid:
            return True
        time.sleep(0.1)
    raise RuntimeError("The old UI provider is still running")


def stop_managed_music(library):
    stop_managed_provider(library, music_pid)


def prepare_provider(library, lldb, get_pid, check_pid, bundle, name, *, launch):
    """Install an optional native layout and verify its witness hook."""
    if not library.is_file():
        return None
    require_supported_build()
    require_trusted_library(library)
    pid = get_pid()
    if pid is None and launch:
        subprocess.run(["/usr/bin/open", "-gj", "-b", bundle],
                       check=True, timeout=15)
        for _ in range(50):
            pid = get_pid()
            if pid:
                break
            time.sleep(0.1)
        if pid is None:
            raise RuntimeError(f"The native {name} UI provider did not start")
    if pid is None:
        return None
    if not lldb:
        raise RuntimeError(f"LLDB is required for the native {name} layout")

    # Encode the filesystem bytes, including spaces and quotes, as a C literal.
    path = '"' + ''.join(f'\\x{byte:02x}' for byte in os.fsencode(library)) + '"'
    with tempfile.TemporaryDirectory(prefix=f"macisland-{name}-") as scratch:
        def invoke(symbol, load):
            check_pid(pid)
            expr = f'void *h = dlopen({path}, RTLD_NOLOAD | RTLD_NOW); bool resident = h != 0; '
            if load:
                expr += f'if (!h) h = dlopen({path}, RTLD_NOW | RTLD_LOCAL); '
            expr += (f'int (*fn)(void) = h ? (int(*)(void))dlsym(h, "{symbol}") : 0; '
                     'int rc = fn ? fn() : -100; if (resident) dlclose(h); (int)rc')
            result = subprocess.run(
                [lldb, "--no-lldbinit", "--batch", "--attach-pid", pid,
                 "-O", f"settings set symbols.clang-modules-cache-path {scratch}/modules",
                 "-o", "expr -l objc++ -- @import Darwin",
                 "-o", "expr -a true -t 3000000 -l objc++ -- " + expr,
                 "-o", "process detach"], capture_output=True, text=True, timeout=40,
            )
            match = re.search(r"^\(int\) \$\d+ = (-?\d+)$", result.stdout, re.MULTILINE)
            if result.returncode or not match:
                raise RuntimeError(f"Could not verify {symbol} in the {name} UI provider: {result.stderr.strip()}")
            return int(match.group(1))

        if invoke(f"mi_{name}_enable", True) != 0:
            raise RuntimeError(f"The {name} UI provider rejected the build or bundle")
        # Installation runs on the target's main queue after LLDB detaches.
        # At login that queue can be busy; 0 means it has not run yet.
        state = 0
        for delay in MUSIC_READY_DELAYS:
            time.sleep(delay)
            state = invoke(f"mi_{name}_status", False)
            if state == 1:
                print(f"Verified native {name} layout in PID {pid}", flush=True)
                return pid
            if state < 0:
                break
        raise RuntimeError(f"The {name} provider did not accept its native layout (state {state})")


def prepare_music(library, lldb, *, launch=True):
    return prepare_provider(library, lldb, music_pid, available_music_pid,
                            "com.apple.MediaRemoteUIService", "music", launch=launch)


def background_providers():
    return (("clock", clock_pid, "com.apple.ClockAngel"),
            ("spotlight", spotlight_pid, "com.apple.campo"))


def prepare_background_safely(library, lldb, name, get_pid, bundle):
    try:
        return prepare_provider(library, lldb, get_pid,
                                lambda pid: available_provider_pid(pid, get_pid),
                                bundle, name, launch=False)
    except Exception as error:
        log(f"Native {name} setup skipped: {error}", error=True)
        return None


def prepare_music_safely(library, lldb, *, launch=True):
    """The optional music layout must never prevent the island from loading."""
    try:
        return prepare_music(library, lldb, launch=launch)
    except Exception as error:
        log(f"Native music layout skipped: {error}", error=True)
        return None


def inject(state, *, force_debugger=False):
    """Apply the music layout (optional) and the island (required).

    The caller holds loader.lock. Records what was patched in ``state``.
    """
    require_supported_build()
    library_path = Path(LIBRARY)
    if not library_path.is_file():
        raise RuntimeError("Missing island.dylib; service unchanged")
    require_trusted_library(library_path)
    legacy = amfi_globally_disabled() and not force_debugger
    lldb = find_lldb(required=not legacy)
    if not legacy:
        sip = subprocess.check_output(["/usr/bin/csrutil", "status"], text=True)
        if "status: disabled" not in sip:
            raise RuntimeError("This loader requires existing disabled SIP")
    pid = menu_bar_agent_pid()
    if pid and is_traced(pid):
        raise RuntimeError("MenuBarAgent is being debugged; leave it unchanged")
    music = prepare_music_safely(library_path.with_name("notch-music.dylib"), lldb)
    state["music"] = process_identity(music)
    for name, get_pid, bundle in background_providers():
        patched = prepare_background_safely(library_path.with_name("notch-music.dylib"),
                                            lldb, name, get_pid, bundle)
        state[name] = process_identity(patched)
    if legacy:
        new_pid = legacy_main(library_path)
    else:
        new_pid = debugger_load(SERVICE, library_path.resolve(), lldb)
    state["menubar"] = process_identity(new_pid)
    return new_pid


def take_attempt(state, name, now=None):
    """Allow at most REAPPLY_LIMIT automatic attempts per REAPPLY_WINDOW."""
    now = time.time() if now is None else now
    key = f"{name}_attempts"
    recent = [t for t in state.get(key, []) if isinstance(t, (int, float)) and 0 <= now - t < REAPPLY_WINDOW]
    state[key] = recent
    if len(recent) >= REAPPLY_LIMIT:
        if not state.get(f"{name}_paused"):
            log(f"{name}: {REAPPLY_LIMIT} automatic attempts within {REAPPLY_WINDOW // 60} minutes; "
                "pausing to avoid a restart loop", error=True)
            state[f"{name}_paused"] = True
        return False
    state.pop(f"{name}_paused", None)
    recent.append(now)
    return True


def ensure():
    """Periodic check: reapply only to service instances not yet patched."""
    library_path = Path(LIBRARY)
    if not library_path.is_file():
        return
    with (library_path.parent / "loader.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # An install, removal or another loader is running.
        state = load_state()
        before = json.dumps(state, sort_keys=True)
        try:
            ensure_locked(library_path, state)
        finally:
            if json.dumps(state, sort_keys=True) != before:
                save_state(state)


def ensure_locked(library_path, state):
    build = current_build()
    if build != SUPPORTED_BUILD:
        if state.get("unsupported_build") != build:
            log(f"Unsupported OS build {build}; automatic patching paused", error=True)
            state["unsupported_build"] = build
        return
    state.pop("unsupported_build", None)
    menubar = process_identity(menu_bar_agent_pid())
    if menubar and menubar != state.get("menubar"):
        if take_attempt(state, "menubar"):
            log(f"MenuBarAgent {menubar} is not patched; applying")
            try:
                inject(state)
            except Exception as error:
                log(f"MenuBarAgent patch failed: {error}", error=True)
        return
    library = library_path.with_name("notch-music.dylib")
    if not library.is_file():
        return
    for name, get_pid, bundle in (("music", music_pid, None), *background_providers()):
        try:
            identity = process_identity(get_pid())
        except Exception:
            continue
        # Optional providers start on demand; do not launch them here.
        if not identity or identity == state.get(name) or not take_attempt(state, name):
            continue
        log(f"{name.capitalize()} UI provider {identity} is not patched; applying")
        lldb = find_lldb(required=False)
        pid = (prepare_music_safely(library, lldb, launch=False) if name == "music"
               else prepare_background_safely(library, lldb, name, get_pid, bundle))
        state[name] = process_identity(pid)


def print_status(force_debugger):
    state = load_state()
    build = current_build()
    globally_disabled = amfi_globally_disabled()
    print(f"OS build: {build} ({'supported' if build == SUPPORTED_BUILD else 'unsupported'})")
    print(f"AMFI-disable boot flag active: {globally_disabled}")
    print(f"Selected loader: {'legacy' if globally_disabled and not force_debugger else 'debugger'}")
    print(f"Debugger: {find_lldb(required=False) or 'not found'}")
    menubar = process_identity(menu_bar_agent_pid())
    print(f"MenuBarAgent: {menubar or 'not running'}; matches last recorded instance: "
          f"{bool(menubar) and menubar == state.get('menubar')}")
    for name, get_pid, _ in (("music", music_pid, None), *background_providers()):
        try:
            identity = process_identity(get_pid())
        except Exception:
            identity = None
        print(f"{name.capitalize()} UI provider: {identity or 'not running'}; matches last recorded instance: "
              f"{bool(identity) and identity == state.get(name)}")
    for name in ("menubar", "music", "clock", "spotlight"):
        if state.get(f"{name}_paused"):
            print(f"Automatic {name} reapplication paused after repeated attempts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--status", action="store_true")
    group.add_argument("--ensure", action="store_true",
                       help="Reapply only when MenuBarAgent or a patched UI provider has restarted")
    group.add_argument("--music-only", action="store_true",
                       help="Reapply the native music layout without restarting MenuBarAgent")
    group.add_argument("--stop-music", action="store_true", help="Detach the installed native provider layouts")
    parser.add_argument("--debugger", action="store_true",
                        help="Force the process-scoped debugger loader")
    args = parser.parse_args()
    if args.status:
        print_status(args.debugger)
        return
    if args.ensure:
        ensure()
        return
    library_path = Path(LIBRARY)
    with (library_path.parent / "loader.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        try:
            if args.stop_music:
                library = library_path.with_name("notch-music.dylib")
                stop_managed_music(library)
                if stop_managed_provider(library, clock_pid):
                    subprocess.run(["/usr/bin/open", "-gj", "-b", "com.apple.ClockAngel"],
                                   check=True, timeout=15)
                if stop_managed_provider(library, spotlight_pid):
                    print("Stopped patched Spotlight", flush=True)
                for name in ("music", "clock", "spotlight"):
                    state.pop(name, None)
            elif args.music_only:
                pid = prepare_music(library_path.with_name("notch-music.dylib"), find_lldb())
                state["music"] = process_identity(pid)
            else:
                inject(state, force_debugger=args.debugger)
                for name in ("menubar", "music", "clock", "spotlight"):
                    state.pop(f"{name}_attempts", None)
                    state.pop(f"{name}_paused", None)
        finally:
            save_state(state)


if __name__ == "__main__":
    main()
MACISLAND_LOADER_PY

  /usr/bin/python3 - "$SCRATCH/loader.py" <<'MACISLAND_LOADER_CHECK'
from pathlib import Path
import sys
path = Path(sys.argv[1])
compile(path.read_text(), str(path), 'exec')
MACISLAND_LOADER_CHECK

  cat > "$SCRATCH/music.swift" <<'MACISLAND_MUSIC_SWIFT'
import AppKit
import Darwin
import SwiftUI
import os

private let sessionMangle = "12NowPlayingUI0aB19ActivitySessionViewV"
private func child(_ value: Any, _ name: String) -> Any? {
  Mirror(reflecting: value).children.first(where: { $0.label == name })?.value
}
private func valueName(_ value: Any) -> String { String(reflecting: type(of: value)) }
private func view(_ value: Any) -> AnyView? {
  guard let v = value as? any View else { return nil }
  return AnyView(v)
}
private func stackChildren(_ value: Any) -> [Any]? {
  guard let tree = child(value, "_tree"), let tupleView = child(tree, "content"),
    let tuple = child(tupleView, "content")
  else { return nil }
  let fields = Mirror(reflecting: tuple)
  guard fields.displayStyle == .tuple else { return nil }
  return fields.children.map(\.value)
}
// Apple's artwork carries its own fixed frame. The surface width is chosen
// before the session lays out, so remember the last native artwork width.
private let artworkWidth = OSAllocatedUnfairLock<CGFloat?>(initialState: nil)
private func fixedWidth(_ value: Any) -> CGFloat? {
  var current = value
  while valueName(current).hasPrefix("SwiftUI.ModifiedContent<") {
    if let modifier = child(current, "modifier"), valueName(modifier) == "SwiftUI._FrameLayout",
      let field = child(modifier, "width") as? CGFloat?, let width = field, width.isFinite, width > 0
    {
      return width
    }
    guard let next = child(current, "content") else { return nil }
    current = next
  }
  return nil
}
// Space between the artwork (or waveform) and the camera housing.
private let notchClearance: CGFloat = 12
private struct HeaderParts {
  let children: [AnyView]
  let modifiers: [any ViewModifier]
  init?(_ header: Any) {
    var stack = header
    var mods: [any ViewModifier] = []
    while valueName(stack).hasPrefix("SwiftUI.ModifiedContent<") {
      guard let next = child(stack, "content"),
        let mod = child(stack, "modifier") as? any ViewModifier
      else { return nil }
      mods.append(mod)
      stack = next
    }
    guard valueName(stack).hasPrefix("SwiftUI.HStack<"), let parts = stackChildren(stack),
      parts.count == 4,
      valueName(parts[0]).contains("NowPlayingUI.FlippingArtworkView"),
      valueName(parts[1]).contains("NowPlayingUI.MetadataView"),
      valueName(parts[2]) == "SwiftUI.Spacer",
      valueName(parts[3]).contains("NowPlayingUI.Waveform")
    else { return nil }
    // Keep the active native accessory and its playback modifiers.
    guard let storage = child(parts[3], "storage"),
      let selected = Mirror(reflecting: storage).children.first?.value,
      let accessory = view(selected)
    else { return nil }
    let vs = parts.prefix(3).compactMap(view) + [accessory]
    guard vs.count == 4 else { return nil }
    children = vs
    modifiers = mods.reversed()
    if let width = fixedWidth(parts[0]) { artworkWidth.withLock { $0 = width } }
  }
  @MainActor func build(size: CGSize) -> AnyView {
    let layout = NotchMusicHeader(cutoutWidth: size.width, cutoutHeight: size.height)
    var row = AnyView(
      layout {
        children[0]
        children[1]
        children[2]
        HStack(spacing: 0) { children[3].fixedSize() }
      })
    func apply<M: ViewModifier>(_ modifier: M, _ value: AnyView) -> AnyView {
      AnyView(value.modifier(modifier))
    }
    for modifier in modifiers { row = apply(modifier, row) }
    return row
  }
}
// The loader reads readiness after it detaches, on a separate debugger thread.
private let readiness = OSAllocatedUnfairLock<Int32>(initialState: 0)

private func cutoutScreen(_ size: CGSize) -> NSScreen? {
  NSScreen.screens.first { screen in
    guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
      screen.safeAreaInsets.top > 0
    else { return false }
    return abs(right.minX - left.maxX - size.width) <= 4
      && abs(screen.safeAreaInsets.top - size.height) <= 4
  }
}

// The full music session receives compact mode before the host finishes
// dismissing it. Its artwork and transport still belong to the outgoing panel.
// Apple's separate leading/trailing compact scenes use their own view types.
private func panelCutout(_ context: Any) -> (size: CGSize, screen: NSScreen)? {
  guard let mode = child(context, "layoutMode"),
    ["expanded", "compact"].contains(String(describing: mode)),
    let metrics = child(context, "obstructionMetrics"),
    let size = child(metrics, "size") as? CGSize, let screen = cutoutScreen(size)
  else { return nil }
  return (size, screen)
}

private struct SessionLayout<Native: View>: View {
  let native: Native
  var body: AnyView {
    let stock = native.body
    let fallback = AnyView(stock)
    guard let context = child(native, "context"), let cutout = panelCutout(context) else {
      return fallback
    }
    guard let rows = stackChildren(stock), rows.count == 3, let lead = view(rows[0]),
      let parts = HeaderParts(rows[1]), let tail = view(rows[2]),
      valueName(rows[2]).contains("NowPlayingUI.TimelineControl"),
      valueName(rows[2]).contains("NowPlayingUI.TransportControls")
    else { return fallback }
    let gap =
      child(stock, "_tree").flatMap { child($0, "root") }.flatMap { child($0, "spacing") }
      as? CGFloat

    return AnyView(
      VStack(spacing: gap) {
        lead
        parts.build(size: cutout.size)
        tail
      })
  }
}
extension View {
  fileprivate nonisolated var miProjectedSession: SessionLayout<Self> {
    SessionLayout(native: self)
  }
}
// SwiftUI invokes these signed witness entries with the native graph. Project
// the typed graph through a key path so its state and observation stay attached.
private struct Relay: View {
  nonisolated(unsafe) static var make: ((_GraphValue<Relay>, _ViewInputs) -> _ViewOutputs)!
  nonisolated(unsafe) static var list: ((_GraphValue<Relay>, _ViewListInputs) -> _ViewListOutputs)!
  var body: Never { fatalError("uninstantiated graph relay") }
  nonisolated static func _makeView(view: _GraphValue<Relay>, inputs: _ViewInputs) -> _ViewOutputs {
    return make(view, inputs)
  }
  nonisolated static func _makeViewList(view: _GraphValue<Relay>, inputs: _ViewListInputs)
    -> _ViewListOutputs
  { return list(view, inputs) }
}
@_silgen_name("move_signed") private func signedEntry(
  _ source: UnsafeMutablePointer<UInt>, _ destination: UnsafeMutablePointer<UInt>,
  _ discriminator: UInt32
) -> UInt
private func table(_ t: any View.Type) -> UnsafeMutablePointer<UInt> {
  var t = t
  return withUnsafeBytes(of: &t) {
    $0.load(
      fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UnsafeMutablePointer<UInt>.self)
  }
}
private nonisolated(unsafe) var installed: (UnsafeMutablePointer<UInt>, UInt, UInt, UInt, UInt)?
private func writable(_ p: UnsafeMutablePointer<UInt>) -> Bool {
  var a = mach_vm_address_t(UInt(bitPattern: p))
  var size: mach_vm_size_t = 0
  var info = vm_region_basic_info_data_64_t()
  let start = a
  var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / 4)
  var obj = mach_port_t()
  let result = withUnsafeMutablePointer(to: &info) { q in
    q.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      mach_vm_region(mach_task_self_, &a, &size, VM_REGION_BASIC_INFO_64, $0, &count, &obj)
    }
  }
  if obj != 0 { mach_port_deallocate(mach_task_self_, obj) }
  return result == KERN_SUCCESS && info.protection & VM_PROT_WRITE != 0 && a <= start
    && start + 40 <= a + size
}
private func install<T: View>(_ type: T.Type) -> Int {
  guard installed == nil else { return 1 }
  let name = String(reflecting: T.Body.self)
  guard name.hasPrefix("SwiftUI.VStack<SwiftUI.TupleContent<"),
    ["FlippingArtworkView", "MetadataView", "Waveform", "TimelineControl", "TransportControls"]
      .allSatisfy(name.contains)
  else { return -3 }
  let dest = table(type)
  let source = table(Relay.self)
  guard writable(dest) else { return -4 }
  let requirements = [
    "$s7SwiftUI4ViewP05_makeC04view6inputsAA01_C7OutputsVAA11_GraphValueVyxG_AA01_C6InputsVtFZTq",
    "$s7SwiftUI4ViewP05_makeC4List4view6inputsAA01_cE7OutputsVAA11_GraphValueVyxG_AA01_cE6InputsVtFZTq",
  ]
  let disc = requirements.compactMap {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0)?.load(as: UInt32.self)
  }.map { $0 >> 16 }
  guard disc == [0xaeaf, 0x6ddd] else { return -5 }
  Relay.make = { graph, inputs in
    let typed = unsafeBitCast(graph, to: _GraphValue<T>.self)
    return SessionLayout<T>._makeView(view: typed[\.miProjectedSession], inputs: inputs)
  }
  Relay.list = { graph, inputs in
    let typed = unsafeBitCast(graph, to: _GraphValue<T>.self)
    return SessionLayout<T>._makeViewList(view: typed[\.miProjectedSession], inputs: inputs)
  }
  let make = signedEntry(source + 3, dest + 3, disc[0])
  let list = signedEntry(source + 4, dest + 4, disc[1])
  installed = (dest, dest[3], dest[4], make, list)
  dest[3] = make
  dest[4] = list
  return 1
}
private func rightBuild() -> Bool {
  var value = [CChar](repeating: 0, count: 64)
  var size = value.count
  return sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0
    && String(cString: value) == "26C5035r"
}
@_cdecl("mi_music_enable") public func enable() -> Int32 {
  guard rightBuild(), Bundle.main.bundleIdentifier == "com.apple.MediaRemoteUIService" else {
    return -1
  }
  DispatchQueue.main.async {
    guard let target = _typeByName(sessionMangle) as? any View.Type else {
      readiness.withLock { $0 = -2 }
      return
    }
    if installed != nil { return }
    guard let surface = _typeByName("12NowPlayingUI0aB15ActivitySurfaceV") as? any View.Type,
      installSurface(surface)
    else {
      readiness.withLock { $0 = -6 }
      return
    }
    let result = install(target)
    if result < 0, let (slot, old, ours) = surfaceSlot, slot.pointee == ours {
      slot.pointee = old
      surfaceSlot = nil
    }
    readiness.withLock { $0 = Int32(result) }
  }
  return 0
}
@_cdecl("mi_music_disable") public func disable() -> Int32 {
  DispatchQueue.main.async {
    if let (p, make, list, ours, oursList) = installed {
      if p[3] == ours { p[3] = make }
      if p[4] == oursList { p[4] = list }
      installed = nil
    }
    if let (slot, old, ours) = surfaceSlot, slot.pointee == ours {
      slot.pointee = old
      surfaceSlot = nil
    }
    readiness.withLock { $0 = 0 }
  }
  return 0
}
@_cdecl("mi_music_status") public func musicStatus() -> Int32 { readiness.withLock { $0 } }

@_silgen_name("swift_reflectionMirror_recursiveCount") private func fieldCount(_ type: Any.Type)
  -> Int
@_silgen_name("swift_reflectionMirror_recursiveChildMetadata") private func fieldType(
  _ t: Any.Type, _ i: Int, _ d: UnsafeMutableRawPointer
) -> Any.Type
@_silgen_name("swift_reflectionMirror_recursiveChildOffset") private func fieldOffset(
  _ t: Any.Type, _ i: Int
) -> Int
// _FieldReflectionMetadata from the Swift runtime's ReflectionMirror interface.
private struct ReflectionFieldMetadata {
  var name: UnsafePointer<CChar>? = nil
  var freeName: (@convention(c) (UnsafePointer<CChar>?) -> Void)? = nil
  var isStrong: Bool = false
  var isVar: Bool = false
}
private func fieldInfo(_ type: Any.Type, _ name: String) -> (Int, Any.Type)? {
  var metadata = ReflectionFieldMetadata()
  for index in 0..<fieldCount(type) {
    metadata = ReflectionFieldMetadata()
    let field = withUnsafeMutablePointer(to: &metadata) { fieldType(type, index, $0) }
    let matches = metadata.name.map { String(cString: $0) == name } ?? false
    if let free = metadata.freeName { free(metadata.name) }
    if matches { return (fieldOffset(type, index), field) }
  }
  return nil
}
// Look up the two native layout fields by reflection on this exact OS build.
// The assembly shim calls Apple's body getter first, retaining its stored state.
private func originalModifiers(_ type: Any.Type) -> (Int, Int)? {
  var current = type
  var base = 0
  var width: Int?
  var insets: Int?
  while String(reflecting: current).hasPrefix("SwiftUI.ModifiedContent<") {
    guard let c = fieldInfo(current, "content"), let m = fieldInfo(current, "modifier") else {
      return nil
    }
    if String(reflecting: m.1) == "SwiftUI._FrameLayout", let w = fieldInfo(m.1, "width"),
      w.1 == CGFloat?.self
    {
      width = base + m.0 + w.0
    }
    if String(reflecting: m.1) == "SwiftUI._PaddingLayout", let i = fieldInfo(m.1, "insets"),
      i.1 == EdgeInsets?.self
    {
      insets = base + m.0 + i.0
    }
    base += c.0
    current = c.1
  }
  guard let w = width, let i = insets else { return nil }
  return (w, i)
}
@_silgen_name("sign_surface") private func signSurface(
  _ slot: UnsafeMutablePointer<UInt>, _ disc: UInt32
) -> UInt
private nonisolated(unsafe) var surfaceResult:
  ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void)?
private nonisolated(unsafe) var surfaceSlot: (UnsafeMutablePointer<UInt>, UInt, UInt)?
private func installSurface<T: View>(_ t: T.Type) -> Bool {
  guard let (w, i) = originalModifiers(T.Body.self), w >= 0, i >= 0,
    w % MemoryLayout<CGFloat?>.alignment == 0, i % MemoryLayout<EdgeInsets?>.alignment == 0,
    w + MemoryLayout<CGFloat?>.size <= MemoryLayout<T.Body>.size,
    i + MemoryLayout<EdgeInsets?>.size <= MemoryLayout<T.Body>.size,
    let req = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI4ViewP4body4BodyQzvgTq")
  else { return false }
  let slot = table(t) + 6
  guard writable(slot) else { return false }
  surfaceResult = { native, out in
    let surface = native.assumingMemoryBound(to: T.self).pointee
    guard let context = child(surface, "context"), let cutout = panelCutout(context) else { return }
    let size = cutout.size
    let width = out.advanced(by: w).assumingMemoryBound(to: CGFloat?.self)
    let margins = out.advanced(by: i).assumingMemoryBound(to: EdgeInsets?.self)
    guard let nativeWidth = width.pointee, nativeWidth >= size.width,
      var pad = margins.pointee, pad.top >= size.height
    else { return }
    // Preserve the native root and its DynamicProperty storage. Give the
    // expanded session its actual scene proposal; it lays out its own safe
    // header, so top padding does not have to clear the notch a second time.
    // Advertising an unbounded frame makes this provider lay out against its
    // maximum offer, even while the host displays its smaller preferred size.
    // Like the iPhone layout, the artwork shares the timeline's leading edge:
    // each wing holds the content inset, the artwork and the notch clearance.
    let art = artworkWidth.withLock { $0 } ?? cutout.screen.safeAreaInsets.top + notchClearance
    let wing = art + notchClearance + max(pad.leading, pad.trailing)
    width.pointee = max(nativeWidth, size.width + 2 * wing)
    pad.top = min(pad.leading, 4)
    margins.pointee = pad
  }
  let discriminator = req.load(as: UInt32.self) >> 16
  let ours = signSurface(slot, discriminator)
  surfaceSlot = (slot, slot.pointee, ours)
  slot.pointee = ours
  return true
}
@_cdecl("mi_music_surface_result") public func adjust(
  _ native: UnsafeRawPointer, _ out: UnsafeMutableRawPointer
) { surfaceResult?(native, out) }

// ClockAngel's stock horizontal stack paints the countdown above its own
// layout baseline. Align the original button row to that visible baseline.
private enum RaisedTimerControls: AlignmentID {
  static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
    // Two native 38-point buttons with an eight-point gap.
    let isControls = abs(dimensions.width - 84) < 1 && abs(dimensions.height - 38) < 1
    return dimensions[VerticalAlignment.center] + (isControls ? 26 : 0)
  }
}
private func clockField<Root, Value>(
  _ root: Root.Type, _ names: [String], _ expected: Value.Type
) -> Int? {
  var type: Any.Type = root
  var offset = 0
  for name in names {
    guard let (fieldOffset, fieldType) = fieldInfo(type, name) else { return nil }
    offset += fieldOffset
    type = fieldType
  }
  guard type == expected, offset >= 0, offset % MemoryLayout<Value>.alignment == 0,
    offset + MemoryLayout<Value>.size <= MemoryLayout<Root>.size
  else { return nil }
  return offset
}
private func isShortNotchViewport(_ rect: CGRect) -> Bool {
  guard rect.size == CGSize(width: 1, height: 1) else { return false }
  return NSScreen.screens.contains {
    let height = $0.safeAreaInsets.top
    return height > 0 && abs(rect.maxY + height + 14) < 0.01
  }
}
@_silgen_name("prepare_clock_body") private func prepareClockBody(
  _ slot: UnsafeMutablePointer<UInt>, _ discriminator: UInt32
) -> UInt
private let clockReadiness = OSAllocatedUnfairLock<Int32>(initialState: 0)
private nonisolated(unsafe) var clockResult: ((UnsafeRawPointer, UnsafeMutableRawPointer) -> Void)?
private nonisolated(unsafe) var clockSlot: (UnsafeMutablePointer<UInt>, UInt, UInt)?
private func installClock<T: View>(_ nativeType: T.Type) -> Int32 {
  guard clockSlot == nil else { return 1 }
  let bodyName = String(reflecting: T.Body.self)
  guard bodyName.contains("ClockAngel.TimerControlsView"), bodyName.contains("ClockAngel.BaselineRow"),
    let obstruction = clockField(nativeType, ["_obstructionRect"], Environment<CGRect?>.self),
    let alignment = clockField(
      T.Body.self, ["content", "content", "_tree", "root", "alignment"], VerticalAlignment.self),
    let req = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s7SwiftUI4ViewP4body4BodyQzvgTq")
  else { return -3 }
  let slot = table(nativeType) + 6
  guard writable(slot) else { return -4 }
  clockResult = { native, out in
    let environment = native.advanced(by: obstruction).assumingMemoryBound(to: Environment<CGRect?>.self)
    guard let rect = environment.pointee.wrappedValue, isShortNotchViewport(rect) else { return }
    let value = out.advanced(by: alignment).assumingMemoryBound(to: VerticalAlignment.self)
    if value.pointee == .center { value.pointee = VerticalAlignment(RaisedTimerControls.self) }
  }
  let replacement = prepareClockBody(slot, req.load(as: UInt32.self) >> 16)
  clockSlot = (slot, slot.pointee, replacement)
  slot.pointee = replacement
  return 1
}
@_cdecl("mi_clock_enable") public func enableClock() -> Int32 {
  guard rightBuild(), Bundle.main.bundleIdentifier == "com.apple.ClockAngel" else { return -1 }
  DispatchQueue.main.async {
    guard let target = _typeByName("10ClockAngel17TimerExpandedViewV") as? any View.Type else {
      clockReadiness.withLock { $0 = -2 }
      return
    }
    let result = installClock(target)
    clockReadiness.withLock { $0 = result }
  }
  return 0
}
@_cdecl("mi_clock_status") public func clockStatus() -> Int32 {
  clockReadiness.withLock { $0 }
}
@_cdecl("mi_clock_layout_result") public func adjustClock(
  _ native: UnsafeRawPointer, _ out: UnsafeMutableRawPointer
) { clockResult?(native, out) }
MACISLAND_MUSIC_SWIFT

  cat > "$SCRATCH/music-layout.swift" <<'MACISLAND_MUSIC_LAYOUT_SWIFT'
import SwiftUI

/// Apple supplies artwork, metadata, a spacer and a trailing accessory in this order.
/// The enclosing view owns the native header tap target, timeline and transport row.
struct NotchMusicHeader: Layout {
  let cutoutWidth: CGFloat
  let cutoutHeight: CGFloat

  private struct Positions {
    let size: CGSize
    let art: CGRect
    let metadata: CGRect
    let accessory: CGRect
  }

  private func positions(width: CGFloat?, subviews: Subviews) -> Positions {
    let art = subviews[0].sizeThatFits(.unspecified)
    let accessory = subviews[3].sizeThatFits(.unspecified)
    let idealMetadata = subviews[1].sizeThatFits(.unspecified)
    let idealWidth = max(idealMetadata.width, cutoutWidth + 2 * max(art.width, accessory.width))
    let width = width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? idealWidth
    let textWidth = min(width, cutoutWidth)
    let text = subviews[1].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
    let wing = max(0, (width - cutoutWidth) / 2)
    let gap = max(0, subviews[0].spacing.distance(to: subviews[1].spacing, along: .vertical))
    // Contents with large Dynamic Type or a narrow proposal flow under the camera.
    let fits = max(art.width, accessory.width) <= wing
    let top = fits ? 0 : cutoutHeight
    let rowHeight = max(art.height, accessory.height, fits ? cutoutHeight : 0)
    let artX: CGFloat = 0
    let accessoryX = max(0, width - accessory.width)
    let stacksAccessory = !fits && art.width + accessory.width > width
    let metadataTop = cutoutHeight + gap
    let artY =
      fits
      ? max(cutoutHeight, metadataTop + (text.height - art.height) / 2)
      : top + (rowHeight - art.height) / 2
    let artFrame = CGRect(origin: CGPoint(x: artX, y: artY), size: art)
    let textY =
      fits
      ? max(metadataTop, artFrame.midY - text.height / 2)
      : top + (stacksAccessory ? art.height + accessory.height : rowHeight) + gap
    let accessoryY = stacksAccessory ? artFrame.maxY : artFrame.midY - accessory.height / 2
    let accessoryFrame = CGRect(
      origin: CGPoint(x: accessoryX, y: max(fits ? 0 : top, accessoryY)), size: accessory)
    let titleX = fits ? wing : 0
    return Positions(
      size: CGSize(
        width: width, height: max(artFrame.maxY, accessoryFrame.maxY, textY + text.height)),
      art: artFrame, metadata: CGRect(x: titleX, y: textY, width: textWidth, height: text.height),
      accessory: accessoryFrame)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    positions(width: proposal.width, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = positions(width: bounds.width, subviews: subviews)
    for (index, rect) in [(0, result.art), (1, result.metadata), (3, result.accessory)] {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: rect.width, height: index == 1 ? nil : rect.height))
    }
    subviews[2].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
  }
}
MACISLAND_MUSIC_LAYOUT_SWIFT

  cat > "$SCRATCH/music-abi.c" <<'MACISLAND_MUSIC_ABI_C'
#include <ptrauth.h>
#include <stddef.h>
#include <stdint.h>
uintptr_t move_signed(uintptr_t *from, uintptr_t *to, unsigned disc) {
#if __has_feature(ptrauth_calls)
  void *before = (void *)*from;
  void *after = ptrauth_auth_and_resign(
      before, ptrauth_key_asia, ptrauth_blend_discriminator(from, disc),
      ptrauth_key_asia, ptrauth_blend_discriminator(to, disc));
  return (uintptr_t)after;
#else
  return *from;
#endif
}
extern void mi_surface_body(void);
__attribute__((visibility("hidden"))) uintptr_t music_saved_body;
uintptr_t sign_surface(uintptr_t *slot, unsigned discriminator) {
#if __has_feature(ptrauth_calls)
  uintptr_t context = ptrauth_blend_discriminator(slot, discriminator);
  music_saved_body = (uintptr_t)ptrauth_auth_and_resign(
      (void *)*slot, ptrauth_key_asia, context, ptrauth_key_function_pointer, 0);
  return (uintptr_t)ptrauth_auth_and_resign(
      &mi_surface_body, ptrauth_key_function_pointer, 0, ptrauth_key_asia, context);
#else
  music_saved_body = *slot;
  return (uintptr_t)mi_surface_body;
#endif
}
extern void mi_clock_body(void);
__attribute__((visibility("hidden"))) uintptr_t clock_saved_body;
uintptr_t prepare_clock_body(uintptr_t *slot, uint32_t discriminator) {
  uintptr_t context = ptrauth_blend_discriminator(slot, discriminator);
  clock_saved_body = (uintptr_t)ptrauth_auth_and_resign(
      (void *)*slot, ptrauth_key_asia, context, ptrauth_key_function_pointer, 0);
  return (uintptr_t)ptrauth_auth_and_resign(
      &mi_clock_body, ptrauth_key_function_pointer, 0, ptrauth_key_asia, context);
}
MACISLAND_MUSIC_ABI_C

  cat > "$SCRATCH/music-body.S" <<'MACISLAND_MUSIC_BODY_S'
.text
.p2align 2
.globl _mi_surface_body
_mi_surface_body:
 pacibsp
 stp x20, x19, [sp, #-32]!
 stp x29, x30, [sp, #16]
 add x29, sp, #16
 mov x19, x8
 adrp x16, _music_saved_body@PAGE
 ldr x16, [x16, _music_saved_body@PAGEOFF]
 blraaz x16
 mov x0, x20
 mov x1, x19
 bl _mi_music_surface_result
 ldp x29, x30, [sp, #16]
 ldp x20, x19, [sp], #32
 retab

.p2align 2
.globl _mi_clock_body
_mi_clock_body:
 pacibsp
 stp x20, x19, [sp, #-32]!
 stp x29, x30, [sp, #16]
 add x29, sp, #16
 mov x19, x8
 adrp x16, _clock_saved_body@PAGE
 ldr x16, [x16, _clock_saved_body@PAGEOFF]
 blraaz x16
 mov x0, x20
 mov x1, x19
 bl _mi_clock_layout_result
 ldp x29, x30, [sp, #16]
 ldp x20, x19, [sp], #32
 retab
MACISLAND_MUSIC_BODY_S

  cat > "$SCRATCH/spotlight.m" <<'MACISLAND_SPOTLIGHT_M'
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <ptrauth.h>
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>
#import <sys/sysctl.h>

// Spotlight's island is gated per device, not per display. On hardware Apple
// ships with a CenterHUD aperture, CampoDeviceSupportsCenterHUD() is true and
// Siri AI only grows Spotlight out of a display that MenuBarAgent configured
// with a cutout; every other display comes up detached as ordinary Spotlight.
// On a notched Mac the function is false, so Campo falls back to a simulated
// cutout on every display and abandons the search when the menu bar refuses
// the cutout on an external monitor. Setting the function's cached answer
// inside Siri AI selects Apple's hardware path without changing global
// MobileGestalt answers or hooking any method.
//
// On 26C5035r the cached fast path is:
//   adrp x8, sOnce@PAGE;  ldr x8, [x8, sOnce@PAGEOFF]; cmn x8, #1; b.ne slow
//   adrp x8, sSupports@PAGE; ldrb w0, [x8, sSupports@PAGEOFF]; ret
static atomic_int state;

static uintptr_t adrpPage(uint32_t insn, uintptr_t pc) {
    int64_t imm = ((int64_t)((insn >> 5) & 0x7ffff) << 2) | ((insn >> 29) & 3);
    imm = (imm << 43) >> 31;  // sign-extend 21 bits, then scale by 4 KiB
    return (pc & ~(uintptr_t)0xfff) + imm;
}

int mi_spotlight_patch(void) {
    void *symbol = dlsym(RTLD_DEFAULT, "CampoDeviceSupportsCenterHUD");
    if (!symbol) return -2;
    bool (*supports)(void) = (bool (*)(void))symbol;
    bool original = supports();  // completes the dispatch_once initialiser
    const uint32_t *code = ptrauth_strip(symbol, ptrauth_key_function_pointer);
    uintptr_t pc = (uintptr_t)code;
    if ((code[0] & 0x9f00001f) != 0x90000008 ||      // adrp x8
        (code[1] & 0xffc003ff) != 0xf9400108 ||      // ldr x8, [x8, #imm]
        (code[4] & 0x9f00001f) != 0x90000008 ||      // adrp x8
        (code[5] & 0xffc003ff) != 0x39400100 ||      // ldrb w0, [x8, #imm]
        code[6] != 0xd65f03c0)                       // ret
        return -3;
    volatile uint8_t *cached = (volatile uint8_t *)(adrpPage(code[4], pc + 16) + ((code[5] >> 10) & 0xfff));
    if (*cached != (uint8_t)original) return -4;
    *cached = 1;
    return supports() ? 1 : -5;
}

int mi_spotlight_enable(void) {
    char build[64] = {0};
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26C5035r") ||
        ![NSBundle.mainBundle.executablePath isEqualToString:@"/System/Applications/Siri AI.app/Contents/MacOS/Siri AI"])
        return -1;
    atomic_store(&state, mi_spotlight_patch());
    return 0;
}

int mi_spotlight_status(void) { return atomic_load(&state); }
MACISLAND_SPOTLIGHT_M

  echo "Building native notch patch from embedded source..."
  /usr/bin/xcrun clang -arch arm64e -dynamiclib -fobjc-arc -Wall -Wextra -Werror \
    -o "$SCRATCH/island.dylib" "$SCRATCH/island.c" "$SCRATCH/notch.m" \
    "$SCRATCH/safearea.m" "$SCRATCH/short-host.m" "$SCRATCH/mask.m" \
    -framework AppKit -framework QuartzCore -F/System/Library/PrivateFrameworks \
    -framework CoreUtils -undefined dynamic_lookup
  /usr/bin/codesign -f -s - "$SCRATCH/island.dylib"
  /usr/bin/codesign --verify --strict "$SCRATCH/island.dylib"
  /usr/bin/xcrun clang -arch arm64e -fobjc-arc -Wall -Wextra -Werror -c "$SCRATCH/spotlight.m" -o "$SCRATCH/spotlight.o"
  /usr/bin/xcrun clang -arch arm64e -c "$SCRATCH/music-abi.c" -o "$SCRATCH/music-abi.o"
  /usr/bin/xcrun clang -arch arm64e -c "$SCRATCH/music-body.S" -o "$SCRATCH/music-body.o"
  /usr/bin/xcrun swiftc -target arm64e-apple-macos27.2 -module-name MacIslandMusic \
    -module-cache-path "$SCRATCH/swift-modules" -O -emit-library \
    "$SCRATCH/music.swift" "$SCRATCH/music-layout.swift" "$SCRATCH/music-abi.o" "$SCRATCH/music-body.o" "$SCRATCH/spotlight.o" \
    -Xlinker -undefined -Xlinker dynamic_lookup -Xlinker -install_name -Xlinker @rpath/notch-music.dylib \
    -o "$SCRATCH/notch-music.dylib"
  /usr/bin/codesign -f -s - "$SCRATCH/notch-music.dylib"
  /usr/bin/codesign --verify --strict "$SCRATCH/notch-music.dylib"
  if [[ "$MODE" == --check ]]; then
    echo "Loader syntax, native build, and signature checks passed. No installation or preference changes."
    exit 0
  fi
fi

/usr/bin/python3 - "$MODE" "$SCRATCH" <<'MACISLAND_MANAGER'
import fcntl
import os
from pathlib import Path
import plistlib
import json
import re
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
MUSIC = ROOT / 'notch-music.dylib'
FILES[MUSIC.name] = MUSIC
AUXILIARY = [ROOT / name for name in ('loader.lock', 'loader.log', 'loader-error.log',
                                      'loader-state.json', 'loader-state.json.next')]
# Login and periodic check: patch only service instances that are not yet patched.
CHECK_INTERVAL = 30


def run(*args, required=True):
    return subprocess.run(args, check=required, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def preference(domain, key):
    saved = json.loads(run('/usr/bin/osascript', '-l', 'JavaScript', str(SOURCE / 'preferences.js'), domain, key).stdout)
    if saved['present'] and type(saved['value']) not in (bool, int, str):
        raise RuntimeError(f'Unsupported existing preference type: {key}; no settings changed')
    return saved


def write_preference(domain, key, saved):
    run('/usr/bin/osascript', '-l', 'JavaScript', str(SOURCE / 'preferences.js'), domain, key, json.dumps(saved))


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
        state = plistlib.loads(STATE.read_bytes())
        if MUSIC.name not in state['files']:
            if MUSIC.exists():
                raise RuntimeError(f'Unmanaged music library exists: {MUSIC}')
            state['files'][MUSIC.name] = {'existed': False, 'mode': 0o755}
            temporary = BACKUP / 'state.next'
            temporary.write_bytes(plistlib.dumps(state))
            temporary.chmod(0o600)
            temporary.replace(STATE)
        return state
    if MUSIC.exists():
        raise RuntimeError(f'Unmanaged music library exists: {MUSIC}')
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


def stop_installed_music(state):
    if MUSIC.name in state['files'] and MUSIC.is_file():
        result = run('/usr/bin/python3', str(ROOT / 'loader.py'), '--stop-music')
        return b'Stopped patched Spotlight' in result.stdout.splitlines()
    return False


def restore_original(state, stopped_spotlight=False):
    for name, details in state['files'].items():
        if details['existed'] and not (BACKUP / name).is_file():
            raise RuntimeError(f'Missing backup: {BACKUP / name}; restoration stopped')
    # Stop the periodic check first, so it cannot reapply what is being removed.
    run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
    stopped_spotlight = stop_installed_music(state) or stopped_spotlight
    for name, details in state['files'].items():
        path = FILES[name]
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
    if stopped_spotlight:
        reload_running_spotlight(stopped=True, ensure=False)
    for name in FILES:
        (BACKUP / name).unlink(missing_ok=True)
    STATE.unlink()
    BACKUP.rmdir()
    for path in AUXILIARY:
        # States written by earlier versions do not list newer auxiliary files.
        if not state['auxiliary_existed'].get(path.name, False):
            path.unlink(missing_ok=True)


def snapshot_current():
    """Copy the currently installed files, so a failed upgrade can return to them."""
    folder = SOURCE / 'previous'
    folder.mkdir()
    snapshot = {}
    for name, path in FILES.items():
        exists = path.is_file()
        snapshot[name] = {'existed': exists, 'mode': path.stat().st_mode & 0o777 if exists else 0o644}
        if exists:
            shutil.copy2(path, folder / name)
    preferences = [
        (domain, key, preference(domain, key)) for domain, key, _ in PREFERENCES
    ]
    return snapshot, preferences


def restore_previous(previous, stopped_spotlight=False):
    """Return to the installation that was working before this upgrade."""
    snapshot, preferences = previous
    folder = SOURCE / 'previous'
    run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
    if MUSIC.is_file():
        result = run('/usr/bin/python3', str(ROOT / 'loader.py'), '--stop-music', required=False)
        stopped_spotlight |= b'Stopped patched Spotlight' in result.stdout.splitlines()
    for name, details in snapshot.items():
        path = FILES[name]
        if details['existed']:
            replace_file(folder / name, path, details['mode'])
        else:
            path.unlink(missing_ok=True)
    for domain, key, saved in preferences:
        write_preference(domain, key, saved)
    if snapshot['agent.plist']['existed']:
        # Its RunAtLoad loader reapplies the previous patch.
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT), required=False)
    else:
        run('/bin/launchctl', 'kickstart', '-k', MENU_SERVICE, required=False)
    if stopped_spotlight:
        reload_running_spotlight(stopped=True, ensure=False)


def agent_definition():
    return {
        'Label': 'com.macisland.loader',
        'ProgramArguments': ['/usr/bin/python3', str(ROOT / 'loader.py'), '--ensure'],
        'RunAtLoad': True,
        'StartInterval': CHECK_INTERVAL,
        'ProcessType': 'Background',
        'StandardOutPath': str(ROOT / 'loader.log'),
        'StandardErrorPath': str(ROOT / 'loader-error.log'),
    }


def reload_running_spotlight(*, stopped=False, ensure=True):
    """Refresh the native cutout client after MenuBarAgent is ready."""
    service = f'{DOMAIN}/com.apple.campo'
    try:
        if not stopped:
            state = run('/bin/launchctl', 'print', service, required=False)
            if state.returncode or not re.search(rb'^\s*pid = [1-9]\d*\s*$', state.stdout, re.MULTILINE):
                return
        run('/bin/launchctl', 'kickstart', '-k', service)
        if ensure:
            run('/usr/bin/python3', str(ROOT / 'loader.py'), '--ensure')
    except (OSError, subprocess.CalledProcessError) as error:
        # The island is installed even if this optional consumer cannot reload.
        print(f'Could not reload Spotlight: {error}. If it stays detached, run: '
              f'launchctl kickstart -k {service}', file=sys.stderr)


def install():
    upgrading = STATE.is_file()
    state = save_original()
    previous = snapshot_current() if upgrading else None
    stopped_spotlight = False
    try:
        # Stop the previous periodic check before replacing what it loads.
        run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
        stopped_spotlight = stop_installed_music(state)
        replace_file(SOURCE / 'island.dylib', ROOT / 'island.dylib', 0o755)
        replace_file(SOURCE / 'loader.py', ROOT / 'loader.py', 0o644)
        replace_file(SOURCE / MUSIC.name, MUSIC, 0o755)
        for domain, key, value in PREFERENCES:
            write_preference(domain, key, {'present': True, 'value': value})
        # Apply synchronously first; the island must load. The music layout
        # is optional and only reported if it cannot be applied.
        subprocess.run(['/usr/bin/python3', str(ROOT / 'loader.py')], check=True)
        (SOURCE / 'agent.plist').write_bytes(plistlib.dumps(agent_definition()))
        replace_file(SOURCE / 'agent.plist', AGENT, 0o644)
        # Its first run finds the instances just patched and leaves them alone.
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT))
    except BaseException:
        if previous is not None:
            print('Upgrade failed; restoring the previously installed version.', file=sys.stderr)
            restore_previous(previous, stopped_spotlight)
        else:
            print('Installation failed; restoring the saved pre-install state.', file=sys.stderr)
            restore_original(state, stopped_spotlight)
        raise
    reload_running_spotlight(stopped=stopped_spotlight)
    print('Installed MacIsland Notch. Login injection and automatic reapplication are enabled.')
    print(f'Original files and preferences: {BACKUP}')


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    lock_path = ROOT / 'installer.lock'
    # Keep this inode stable, including after removal, for concurrent waiters.
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MODE == '--uninstall':
            if not STATE.is_file():
                raise RuntimeError('No MacIsland Notch backup found; existing MacIsland files were left untouched')
            restore_original(plistlib.loads(STATE.read_bytes()))
            print('Removed MacIsland Notch; restored the saved pre-install files and preferences.')
        else:
            install()


if __name__ == '__main__':
    main()

MACISLAND_MANAGER
