#import "mask-internal.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

// Full-screen notched island windows sit behind MenuBarAgent's menu bar.
// On macOS 27.3 beta 2 two things drop clicks near or on the top edge:
//  1. Transparent/inverted island hit layers lose their WindowServer click shape,
//     sending top-edge clicks to the menu bar window below them. Adding a
//     clipped opaque black underlay (`MacIslandTopHitUnderlay`) and stripping
//     `colorInvertDisplayAware` keeps `y >= 1.0` hit-testing intact without any
//     visual protrusion.
//  2. The flat top pixel row (`y == 0`) still lands on MenuBarAgent's menu bar
//     window or sits at `y == window.frame.size.height`, which the island view
//     tree ignores unless nudged inside (`y <= height - 1.5`). Hooking
//     `MBApplication.sendEvent:` / `NSWindow.sendEvent:` redirects top-1px menu bar
//     clicks to the island window and clamps `y <= height - 1.5`.

static NSString *const MacIslandTopUnderlayName = @"MacIslandTopHitUnderlay";

static char savedFiltersKey;

typedef int (*MacIslandSLSMainConnectionFn)(void);
typedef int (*MacIslandSLSFindWindowFn)(int, int, int, int, const CGPoint *, CGPoint *, uint32_t *, int *);

static MacIslandSLSMainConnectionFn slsMainConnectionID;
static MacIslandSLSFindWindowFn slsFindWindowAndOwner;

static IMP origSetHitTestsAsOpaque;
static IMP origSetFilters;
static IMP origSendEvent;
static IMP origAppSendEvent;

static BOOL topHitInitialized;
static _Atomic(bool) topHitScanQueued;
static BOOL writingTopHitFilters;
static BOOL forwardingTopHitEvent;
static NSMutableArray<NSArray *> *coveredIslands;   // @[window, container, hitLayer]
__weak static NSWindow *redirectTargetWindow;
static NSEvent *activeAppHandledEvent;
static NSTimer *topHitVerifyTimer;

#ifdef MACISLAND_TESTING
static NSArray<NSWindow *> *testOverrideWindows;
static BOOL useTestInvertOverride;
static BOOL testInvertOverrideValue;
static NSUInteger topHitMissCount;
static NSUInteger topHitRefreshCount;
static CALayer *lastTestClampedLayer;
static NSUInteger testRedirectCount;
static CGPoint lastTestDeliveredPoint;
#endif

static BOOL invertColorsEnabled(void) {
#ifdef MACISLAND_TESTING
    if (useTestInvertOverride) return testInvertOverrideValue;
#endif
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldInvertColors;
}

static CALayer *islandRootLayer(NSWindow *window) {
    NSView *superview = window.contentView.superview;
    if (superview.layer) return superview.layer;
    return window.contentView.layer;
}

static BOOL isWindowActiveForTopHit(NSWindow *window) {
#ifdef MACISLAND_TESTING
    if (testOverrideWindows && [testOverrideWindows containsObject:window]) return YES;
#endif
    return window.visible;
}

static NSArray<NSWindow *> *topHitCandidateWindows(void) {
#ifdef MACISLAND_TESTING
    return testOverrideWindows ?: NSApp.windows;
#else
    return NSApp.windows;
#endif
}

static BOOL isIslandWindow(NSWindow *window) {
    if (![window isKindOfClass:NSWindow.class] || !isWindowActiveForTopHit(window)) return NO;
#ifdef MACISLAND_TESTING
    if (testOverrideWindows) return [testOverrideWindows containsObject:window];
#endif
    NSScreen *screen = window.screen;
    CALayer *root = islandRootLayer(window);
    if (!screen || !root || !MacIslandScreenHasNotch(screen)) return NO;
    return fabs(window.frame.size.width - screen.frame.size.width) < 1 &&
           fabs(window.frame.size.height - screen.frame.size.height) < 1 &&
           fabs(root.bounds.size.width - screen.frame.size.width) < 1 &&
           fabs(root.bounds.size.height - screen.frame.size.height) < 1;
}

static CGRect rectInWindowCoordinates(NSWindow *window, CALayer *root, CALayer *layer) {
    if (!window || !root || !layer) return CGRectZero;
    CGRect lr = [layer convertRect:layer.bounds toLayer:root];
    if (root.isGeometryFlipped) {
        CGFloat winH = window.frame.size.height;
        return CGRectMake(lr.origin.x, winH - lr.origin.y - lr.size.height, lr.size.width, lr.size.height);
    }
    return lr;
}

static BOOL layerTreeMinimallyVisibleToRoot(CALayer *layer, CALayer *root) {
    for (CALayer *cur = layer; cur; cur = cur.superlayer) {
        if (cur.hidden || cur.opacity <= 0.05) return NO;
        if (cur == root) break;
    }
    return YES;
}

static BOOL isHitTestOpaqueLayer(CALayer *layer) {
    SEL sel = NSSelectorFromString(@"hitTestsAsOpaque");
    return [layer respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(layer, sel);
}

static BOOL isColorInvertFilter(id filter) {
    for (NSString *key in @[@"type", @"name"]) {
        SEL sel = NSSelectorFromString(key);
        if (![filter respondsToSelector:sel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(filter, sel);
        if ([value isKindOfClass:NSString.class] && [value isEqualToString:@"colorInvertDisplayAware"]) {
            return YES;
        }
    }
    return NO;
}

static void setFiltersRaw(CALayer *layer, NSArray *filters) {
    writingTopHitFilters = YES;
    ((void (*)(id, SEL, NSArray *))origSetFilters)(layer, @selector(setFilters:), filters);
    writingTopHitFilters = NO;
}

static void stripInvertFilterFromContainer(CALayer *container) {
    NSArray *filters = container.filters;
    if (!filters.count) return;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:filters.count];
    BOOL removed = NO;
    for (id filter in filters) {
        if (isColorInvertFilter(filter)) {
            removed = YES;
        } else {
            [kept addObject:filter];
        }
    }
    if (removed) {
        objc_setAssociatedObject(container, &savedFiltersKey, filters, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setFiltersRaw(container, kept.count ? kept : nil);
    }
}

static void restoreInvertFilterOnContainer(CALayer *container) {
    NSArray *saved = objc_getAssociatedObject(container, &savedFiltersKey);
    if (!saved) return;
    objc_setAssociatedObject(container, &savedFiltersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    setFiltersRaw(container, saved);
}

static CALayer *existingTopUnderlay(CALayer *hitLayer) {
    for (CALayer *child in MacIslandCopyLayerSublayers(hitLayer)) {
        if ([child.name isEqualToString:MacIslandTopUnderlayName]) return child;
    }
    return nil;
}

static NSDictionary<NSString *, id> *disabledLayerActions(void) {
    static NSDictionary<NSString *, id> *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        actions = @{
            @"bounds": NSNull.null,
            @"position": NSNull.null,
            @"frame": NSNull.null,
            @"onOrderIn": NSNull.null,
            @"onOrderOut": NSNull.null,
        };
    });
    return actions;
}

static BOOL isSolidContourFillLayer(CALayer *layer) {
    return [layer.name hasPrefix:@"SimpleViewDisplayItem-"] &&
           MacIslandIsOpaqueBlack(layer.backgroundColor) &&
           !layer.contents &&
           !MacIslandLayerHasSublayers(layer);
}

static void walkIslandHierarchy(NSWindow *window, CALayer *container, BOOL apply) {
    NSArray<CALayer *> *children = MacIslandCopyLayerSublayers(container);
    for (CALayer *child in children) {
        if ([child.name isEqualToString:MacIslandTopUnderlayName]) {
            continue;
        }
        if (isSolidContourFillLayer(container)) continue;
        MacIslandNativeMaskObserver *observer = MacIslandModelMaskObserver(container);
        BOOL maskedByNotch = (observer != nil && observer.applied);
        if (isHitTestOpaqueLayer(child) && container.masksToBounds &&
            (container.cornerRadius > 0 || maskedByNotch)) {
            CALayer *underlay = existingTopUnderlay(child);
            if (apply) {
                stripInvertFilterFromContainer(container);
                if (!underlay) {
                    underlay = [CALayer layer];
                    underlay.name = MacIslandTopUnderlayName;
                    underlay.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
                    underlay.frame = child.bounds;
                    underlay.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
                    underlay.actions = disabledLayerActions();
                    [child insertSublayer:underlay atIndex:0];
                } else if (!CGRectEqualToRect(underlay.frame, child.bounds)) {
                    underlay.frame = child.bounds;
                }
                [coveredIslands addObject:@[window, container, child]];
            } else {
                [underlay removeFromSuperlayer];
                restoreInvertFilterOnContainer(container);
            }
        }
        walkIslandHierarchy(window, child, apply);
    }
}

static void scanTopHitWindows(void) {
    BOOL apply = !invertColorsEnabled();
    NSMutableArray<NSArray *> *nextCovered = [NSMutableArray array];
    coveredIslands = nextCovered;

    NSArray<NSWindow *> *windows = topHitCandidateWindows();

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSWindow *window in windows) {
        if (!isIslandWindow(window)) continue;
        CALayer *root = islandRootLayer(window);
        if (root) walkIslandHierarchy(window, root, apply);
    }
    [CATransaction commit];
}

static void scheduleTopHitScan(void) {
    if (atomic_exchange(&topHitScanQueued, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&topHitScanQueued, false);
        scanTopHitWindows();
    });
}

static void loadSkyLightSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!skyLight) return;
        slsMainConnectionID = (MacIslandSLSMainConnectionFn)dlsym(skyLight, "SLSMainConnectionID");
        slsFindWindowAndOwner = (MacIslandSLSFindWindowFn)dlsym(skyLight, "SLSFindWindowAndOwner");
    });
}

static int topRowReachable(NSWindow *window, CALayer *container, CALayer *hitLayer) {
    loadSkyLightSymbols();
    if (!slsMainConnectionID || !slsFindWindowAndOwner) return -1;
    CALayer *root = islandRootLayer(window);
    if (!root || !hitLayer.superlayer) return 2;
    if (!layerTreeMinimallyVisibleToRoot(container, root)) return 2;

    CGRect winRect = rectInWindowCoordinates(window, root, container);
    NSRect screenRect = [window convertRectToScreen:NSRectFromCGRect(winRect)];
    CGFloat winTop = NSMaxY(window.frame);
    if (NSMaxY(screenRect) < winTop - 2.0 || NSMinY(screenRect) > winTop - 2.0 ||
        screenRect.size.height < 4.0) {
        return 2;
    }

    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary) return -1;
    CGFloat primaryMaxY = NSMaxY(primary.frame);
    CGFloat topY = MIN(NSMaxY(screenRect), winTop);
    CGPoint query = CGPointMake(NSMidX(screenRect), MAX(2.0, primaryMaxY - topY + 2.0));
    CGPoint outPoint = CGPointZero;
    uint32_t ownerWindowID = 0;
    int ownerConnection = 0;
    if (slsFindWindowAndOwner(slsMainConnectionID(), 0, 1, 0, &query, &outPoint,
                              &ownerWindowID, &ownerConnection) != 0) {
        return -1;
    }
    return ownerWindowID == (uint32_t)window.windowNumber ? 1 : 0;
}

static void verifyTopRowHitShapes(void) {
    if (!coveredIslands.count || invertColorsEnabled()) return;
    NSArray<NSArray *> *snapshot = [coveredIslands copy];
    for (NSArray *entry in snapshot) {
        NSWindow *window = entry[0];
        CALayer *container = entry[1];
        CALayer *hitLayer = entry[2];
        if (!isWindowActiveForTopHit(window) || !hitLayer.superlayer) continue;
        if (topRowReachable(window, container, hitLayer) != 0) continue;
#ifdef MACISLAND_TESTING
        topHitMissCount++;
        topHitRefreshCount++;
#endif
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        NSArray *currentFilters = container.filters;
        setFiltersRaw(container, @[]);
        setFiltersRaw(container, currentFilters);
        ((void (*)(id, SEL, BOOL))origSetHitTestsAsOpaque)(
            hitLayer, NSSelectorFromString(@"setHitTestsAsOpaque:"), NO);
        ((void (*)(id, SEL, BOOL))origSetHitTestsAsOpaque)(
            hitLayer, NSSelectorFromString(@"setHitTestsAsOpaque:"), YES);
        [CATransaction commit];
    }
}

static CGPoint windowPointToScreen(NSWindow *window, CGPoint point) {
    return [window convertRectToScreen:(NSRect){point, {0, 0}}].origin;
}

static BOOL islandWindowHasInteractiveTopViewAtPoint(NSWindow *window, CGPoint screenPoint) {
    if (!isIslandWindow(window)) return NO;
    NSRect frame = window.frame;
    if (screenPoint.x < NSMinX(frame) || screenPoint.x > NSMaxX(frame) ||
        screenPoint.y < NSMaxY(frame) - 2.0 || screenPoint.y > NSMaxY(frame) + 1.0) {
        return NO;
    }
    NSView *rootView = window.contentView.superview ?: window.contentView;
    if (!rootView) return NO;
    NSPoint probePoint = NSMakePoint(screenPoint.x - frame.origin.x, MAX(0.0, frame.size.height - 2.0));
    NSView *hitView = [rootView hitTest:probePoint];
    for (NSView *view = hitView; view && view != rootView; view = view.superview) {
        if (view.gestureRecognizers.count > 0) return YES;
        NSString *className = NSStringFromClass(view.class);
        if ([className containsString:@"SceneHost"] || [className containsString:@"EventRegion"]) {
            return YES;
        }
    }
    return NO;
}

static NSWindow *islandWindowAtTopEdge(CGPoint screenPoint) {
    for (NSWindow *window in topHitCandidateWindows()) {
        if (islandWindowHasInteractiveTopViewAtPoint(window, screenPoint)) {
            return window;
        }
    }
    for (NSArray *entry in coveredIslands) {
        NSWindow *window = entry[0];
        CALayer *container = entry[1];
        CALayer *root = islandRootLayer(window);
        if (!isWindowActiveForTopHit(window) || !root || !container.superlayer) continue;
        if (!layerTreeMinimallyVisibleToRoot(container, root)) continue;

        CGRect winRect = rectInWindowCoordinates(window, root, container);
        NSRect screenRect = [window convertRectToScreen:NSRectFromCGRect(winRect)];
        CGFloat winTop = NSMaxY(window.frame);
        if (NSMaxY(screenRect) < winTop - 2.0 || NSMinY(screenRect) > winTop - 1.0) continue;

        CGFloat topY = MIN(NSMaxY(screenRect), winTop);
        if (screenPoint.y < topY - 2.0 || screenPoint.y > winTop + 1.0) continue;

        MacIslandNativeMaskObserver *observer = MacIslandModelMaskObserver(container);
        BOOL maskedByNotch = (observer != nil && observer.applied);
        CGFloat leftEdge = NSMinX(screenRect);
        CGFloat rightEdge = NSMaxX(screenRect);
        if (maskedByNotch) {
            CGFloat flare = MacIslandObserverPaintExtensions(observer).horizontalFlare;
            if (screenRect.size.width > 2.0 * flare) {
                leftEdge += flare;
                rightEdge -= flare;
            }
        } else {
            CGFloat radius = container.cornerRadius;
            if (winRect.size.width - 2.0 * radius >= 2.0) {
                leftEdge += radius;
                rightEdge -= radius;
            }
        }
        if (screenPoint.x >= leftEdge && screenPoint.x <= rightEdge) {
            return window;
        }
    }
    return nil;
}

static NSEvent *clampedMouseEvent(NSEvent *event, NSWindow *target, CGPoint point) {
    NSEvent *moved = [NSEvent mouseEventWithType:event.type
                                        location:point
                                   modifierFlags:event.modifierFlags
                                       timestamp:event.timestamp
                                    windowNumber:target.windowNumber
                                         context:nil
                                     eventNumber:event.eventNumber
                                      clickCount:event.clickCount
                                        pressure:event.pressure];
    return moved ?: event;
}

static BOOL isTrackedMouseEvent(NSEventType type) {
    return (type >= NSEventTypeLeftMouseDown && type <= NSEventTypeMouseMoved) ||
           type == NSEventTypeLeftMouseDragged ||
           type == NSEventTypeRightMouseDragged;
}

static void hookedSetHitTestsAsOpaque(CALayer *layer, SEL selector, BOOL value) {
    ((void (*)(id, SEL, BOOL))origSetHitTestsAsOpaque)(layer, selector, value);
    if (value) scheduleTopHitScan();
}

static void hookedSetFilters(CALayer *layer, SEL selector, NSArray *filters) {
    ((void (*)(id, SEL, NSArray *))origSetFilters)(layer, selector, filters);
    if (!writingTopHitFilters && objc_getAssociatedObject(layer, &savedFiltersKey)) {
        objc_setAssociatedObject(layer, &savedFiltersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        scheduleTopHitScan();
    }
}

static NSEvent *rewriteTopHitEvent(NSWindow *window, NSEvent *event, NSWindow **targetOut) {
    NSWindow *target = window;
    BOOL clamped = NO;
    NSEventType type = event.type;
    if (!invertColorsEnabled() && isTrackedMouseEvent(type)) {
        CGPoint inPoint = event.locationInWindow;
        BOOL targetingIsland = isIslandWindow(window);
        BOOL isDown = (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown);
        BOOL isUp = (type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp);
        BOOL isDrag = (type == NSEventTypeLeftMouseDragged || type == NSEventTypeRightMouseDragged);
        if (!targetingIsland && isDown) {
            NSWindow *matched = islandWindowAtTopEdge(windowPointToScreen(window, inPoint));
            redirectTargetWindow = matched;
            if (matched) target = matched;
        } else if (!targetingIsland && redirectTargetWindow && (isDrag || isUp)) {
            target = redirectTargetWindow;
            if (isUp) redirectTargetWindow = nil;
        } else if (isDown || isUp) {
            redirectTargetWindow = nil;
        }

        if (target != window || targetingIsland) {
            CGPoint point = inPoint;
            if (target != window) {
                CGPoint screenPoint = windowPointToScreen(window, point);
                point = CGPointMake(screenPoint.x - target.frame.origin.x,
                                    screenPoint.y - target.frame.origin.y);
#ifdef MACISLAND_TESTING
                testRedirectCount++;
#endif
            }
            CGFloat topLimit = target.frame.size.height - 1.5;
            CGFloat clampedX = MIN(MAX(point.x, 0.0), target.frame.size.width);
            if (clampedX != point.x) {
                point.x = clampedX;
                clamped = YES;
            }
            if (point.y > topLimit) {
                point.y = topLimit;
                clamped = YES;
            }
            if (target != window || clamped) {
                event = clampedMouseEvent(event, target, point);
            }
        }
    }
    if (targetOut) *targetOut = target;
    return event;
}

static void hookedSendEvent(NSWindow *window, SEL selector, NSEvent *event) {
    if (forwardingTopHitEvent || event == activeAppHandledEvent) {
        ((void (*)(id, SEL, NSEvent *))origSendEvent)(window, selector, event);
        return;
    }
    NSWindow *target = window;
    event = rewriteTopHitEvent(window, event, &target);
#ifdef MACISLAND_TESTING
    if (isTrackedMouseEvent(event.type)) {
        lastTestClampedLayer = islandRootLayer(target);
        lastTestDeliveredPoint = event.locationInWindow;
    }
#endif
    if (target != window) {
        @try {
            forwardingTopHitEvent = YES;
            [target sendEvent:event];
        } @finally {
            forwardingTopHitEvent = NO;
        }
        return;
    }
    ((void (*)(id, SEL, NSEvent *))origSendEvent)(window, selector, event);
}

static void hookedAppSendEvent(NSApplication *app, SEL selector, NSEvent *event) {
    if (!invertColorsEnabled() && isTrackedMouseEvent(event.type)) {
        NSWindow *window = [app windowWithWindowNumber:event.windowNumber];
        if (!window) window = event.window;
        if (window) {
            NSWindow *target = window;
            event = rewriteTopHitEvent(window, event, &target);
#ifdef MACISLAND_TESTING
            lastTestClampedLayer = islandRootLayer(target);
            lastTestDeliveredPoint = event.locationInWindow;
#endif
            NSEvent *prevHandled = activeAppHandledEvent;
            activeAppHandledEvent = event;
            @try {
                ((void (*)(id, SEL, NSEvent *))origAppSendEvent)(app, selector, event);
            } @finally {
                activeAppHandledEvent = prevHandled;
            }
            return;
        }
    }
    ((void (*)(id, SEL, NSEvent *))origAppSendEvent)(app, selector, event);
}

static BOOL verifyVoidOneArgMethod(Method method, char expectedArgType) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char ret[16] = {0}, arg[16] = {0};
    method_getReturnType(method, ret, sizeof(ret));
    method_getArgumentType(method, 2, arg, sizeof(arg));
    return ret[0] == 'v' && arg[0] == expectedArgType;
}

static void installTopHitHooks(void) {
    if (topHitInitialized) return;
    Method hitMethod = class_getInstanceMethod(CALayer.class, NSSelectorFromString(@"setHitTestsAsOpaque:"));
    Method filterMethod = class_getInstanceMethod(CALayer.class, @selector(setFilters:));
    Method sendEventMethod = class_getInstanceMethod(NSWindow.class, @selector(sendEvent:));
    if (!hitMethod || !filterMethod || !sendEventMethod) return;
    if (!(verifyVoidOneArgMethod(hitMethod, 'B') || verifyVoidOneArgMethod(hitMethod, 'c')) ||
        !verifyVoidOneArgMethod(filterMethod, '@') ||
        !verifyVoidOneArgMethod(sendEventMethod, '@')) {
        return;
    }
    origSetHitTestsAsOpaque = method_getImplementation(hitMethod);
    origSetFilters = method_getImplementation(filterMethod);
    origSendEvent = method_getImplementation(sendEventMethod);
    method_setImplementation(hitMethod, (IMP)hookedSetHitTestsAsOpaque);
    method_setImplementation(filterMethod, (IMP)hookedSetFilters);
    method_setImplementation(sendEventMethod, (IMP)hookedSendEvent);
    if (NSApp) {
        Method appSendMethod = class_getInstanceMethod(NSApp.class, @selector(sendEvent:));
        if (appSendMethod && verifyVoidOneArgMethod(appSendMethod, '@')) {
            origAppSendEvent = method_getImplementation(appSendMethod);
            method_setImplementation(appSendMethod, (IMP)hookedAppSendEvent);
        }
    }
    MacIslandSetTopHitNotifyCallback(scheduleTopHitScan);

    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        scanTopHitWindows();
    }];

    topHitVerifyTimer = [NSTimer timerWithTimeInterval:0.5
                                               repeats:YES
                                                 block:^(__unused NSTimer *timer) {
        verifyTopRowHitShapes();
        scanTopHitWindows();
    }];
    topHitVerifyTimer.tolerance = 0.25;
    [NSRunLoop.mainRunLoop addTimer:topHitVerifyTimer forMode:NSRunLoopCommonModes];
    topHitInitialized = YES;
}

#ifdef MACISLAND_TESTING
void MacIslandInstallTopHitHooksForTesting(void) {
    installTopHitHooks();
}

void MacIslandSetTopHitTestWindows(NSArray<NSWindow *> *windows) {
    testOverrideWindows = windows;
}

void MacIslandSetTopHitInvertColorsForTesting(BOOL enabled) {
    useTestInvertOverride = YES;
    testInvertOverrideValue = enabled;
    scanTopHitWindows();
}

void MacIslandScanTopHitForTesting(void) {
    scanTopHitWindows();
}

void MacIslandTopHitStatsForTesting(NSUInteger *coveredOut, NSUInteger *stripsOut,
                                    NSUInteger *redirectsOut, CGPoint *lastPointOut) {
    if (coveredOut) *coveredOut = coveredIslands.count;
    if (stripsOut) *stripsOut = 0;
    if (redirectsOut) *redirectsOut = testRedirectCount;
    if (lastPointOut) *lastPointOut = lastTestDeliveredPoint;
    (void)topHitMissCount;
    (void)topHitRefreshCount;
    (void)lastTestClampedLayer;
}
#endif

__attribute__((constructor))
static void installTopEdgeHitSupport(void) {
    if (!MacIslandIsMenuBarAgent()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        installTopHitHooks();
        scanTopHitWindows();
    });
}
