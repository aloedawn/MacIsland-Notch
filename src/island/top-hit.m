#import "mask-internal.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

// Full-screen notched island windows sit behind MenuBarAgent's menu bar.
// On macOS 27.3 beta 2 two things drop clicks on the flat top pixel row:
//  1. Transparent/inverted island hit layers lose their WindowServer click shape,
//     sending top-row clicks to the menu bar window below them.
//  2. Mouse events whose locationInWindow.y == window.frame.size.height (top edge
//     when the cursor is pushed to the top of the screen) are ignored by the
//     island's view tree unless nudged 0.5 pt inside the window.

static NSString *const MacIslandTopUnderlayName = @"MacIslandTopHitUnderlay";
static NSString *const MacIslandTopStripName = @"MacIslandTopHitStrip";

static char savedFiltersKey;

typedef int (*MacIslandSLSMainConnectionFn)(void);
typedef int (*MacIslandSLSFindWindowFn)(int, int, int, int, const CGPoint *, CGPoint *, uint32_t *, int *);

static MacIslandSLSMainConnectionFn slsMainConnectionID;
static MacIslandSLSFindWindowFn slsFindWindowByGeometry;

static IMP origSetHitTestsAsOpaque;
static IMP origSetFilters;
static IMP origSendEvent;

static BOOL topHitInitialized;
static _Atomic(bool) topHitScanQueued;
static BOOL writingTopHitFilters;
static BOOL forwardingTopHitEvent;
static NSMutableArray<NSArray *> *coveredIslands;   // @[window, container, hitLayer]
static NSMutableArray<NSArray *> *activeTopStrips;  // @[container, stripLayer]
static NSMutableArray<NSArray *> *nextTopStrips;
__weak static NSWindow *redirectTargetWindow;
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

static BOOL layerTreeVisibleToRoot(CALayer *layer, CALayer *root) {
    for (CALayer *cur = layer; cur; cur = cur.superlayer) {
        if (cur.hidden || cur.opacity < 0.95) return NO;
        CALayer *pres = cur.presentationLayer;
        if (pres && pres != cur && (pres.hidden || pres.opacity < 0.95)) return NO;
        if (cur == root) break;
    }
    return YES;
}

static CGRect opaqueFlatTopBodyRect(CALayer *container, CGRect sourceBounds,
                                    BOOL maskedByNotch, MacIslandPaintExtensions ext) {
    CGFloat insetX = maskedByNotch ? (ext.horizontalFlare + 1.0) : (container.cornerRadius + 1.0);
    CGFloat topOffset = maskedByNotch ? ext.topExtension : 0.0;
    CGFloat x = CGRectGetMinX(sourceBounds) + insetX;
    CGFloat y = CGRectGetMinY(sourceBounds) + topOffset;
    CGFloat w = sourceBounds.size.width - 2.0 * insetX;
    CGFloat h = sourceBounds.size.height - topOffset;
    if (w < 2.0 || h <= 0.0) return CGRectZero;
    return CGRectMake(x, y, w, h);
}

static void resolvedTopSpanInRoot(CALayer *container, CALayer *root, BOOL *atTopOut,
                                  CGFloat *flatWidthOut, CGFloat *centerXOut) {
    *atTopOut = NO;
    *flatWidthOut = 0;
    *centerXOut = 0;
    if (!layerTreeVisibleToRoot(container, root)) return;

    MacIslandNativeMaskObserver *observer = MacIslandModelMaskObserver(container);
    BOOL maskedByNotch = (observer != nil && observer.applied);
    MacIslandPaintExtensions ext = maskedByNotch
        ? MacIslandObserverPaintExtensions(observer)
        : (MacIslandPaintExtensions){0, 0, 0, 0};
    CGRect body = opaqueFlatTopBodyRect(container, container.bounds, maskedByNotch, ext);
    if (CGRectIsEmpty(body)) return;

    CGRect lr = [container convertRect:body toLayer:root];
    BOOL atTop = root.isGeometryFlipped
        ? fabs(CGRectGetMinY(lr)) <= 0.5
        : fabs(CGRectGetMaxY(lr) - root.bounds.size.height) <= 0.5;
    if (!atTop) return;

    CGFloat left = CGRectGetMinX(lr);
    CGFloat right = CGRectGetMaxX(lr);
    CALayer *pres = container.presentationLayer;
    if (pres && pres != container && pres.superlayer) {
        CGRect presBody = opaqueFlatTopBodyRect(container, pres.bounds, maskedByNotch, ext);
        if (!CGRectIsEmpty(presBody)) {
            CGRect pr = [pres convertRect:presBody toLayer:(root.presentationLayer ?: root)];
            left = MAX(left, CGRectGetMinX(pr));
            right = MIN(right, CGRectGetMaxX(pr));
        }
    }
    CGFloat flat = right - left;
    if (flat < 2.0) return;

    *atTopOut = YES;
    *flatWidthOut = flat;
    *centerXOut = (left + right) / 2.0;
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

static CALayer *existingTopStripForContainer(NSArray<NSArray *> *items, CALayer *container) {
    for (NSArray *pair in items) {
        if (pair[0] == container) return pair[1];
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

static void ensureTopStripForContainer(NSWindow *window, CALayer *container) {
    CALayer *root = islandRootLayer(window);
    if (!root || existingTopStripForContainer(nextTopStrips, container)) return;
    BOOL atTop = NO;
    CGFloat flat = 0;
    CGFloat midX = 0;
    resolvedTopSpanInRoot(container, root, &atTop, &flat, &midX);
    if (!atTop) return;

    CALayer *strip = existingTopStripForContainer(activeTopStrips, container);
    if (!strip) {
        strip = [CALayer layer];
        strip.name = MacIslandTopStripName;
        strip.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        strip.actions = disabledLayerActions();
    }
    if (strip.superlayer != root) [root insertSublayer:strip atIndex:0];
    CGFloat stripY = root.isGeometryFlipped ? 0.0 : (root.bounds.size.height - 1.0);
    strip.frame = CGRectMake(midX - flat / 2.0, stripY, flat, 1.0);
    [nextTopStrips addObject:@[container, strip]];
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
        if ([child.name isEqualToString:MacIslandTopUnderlayName] ||
            [child.name isEqualToString:MacIslandTopStripName]) {
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
                if (!child.hidden && child.opacity >= 0.95) {
                    ensureTopStripForContainer(window, container);
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
    NSMutableArray<NSArray *> *stripsNext = [NSMutableArray array];
    coveredIslands = nextCovered;
    nextTopStrips = stripsNext;

#ifdef MACISLAND_TESTING
    NSArray<NSWindow *> *windows = testOverrideWindows ?: NSApp.windows;
#else
    NSArray<NSWindow *> *windows = NSApp.windows;
#endif

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSWindow *window in windows) {
        if (!isIslandWindow(window)) continue;
        CALayer *root = islandRootLayer(window);
        if (root) walkIslandHierarchy(window, root, apply);
    }
    for (NSArray *pair in activeTopStrips) {
        if (!existingTopStripForContainer(stripsNext, pair[0])) {
            [(CALayer *)pair[1] removeFromSuperlayer];
        }
    }
    activeTopStrips = stripsNext;
    nextTopStrips = nil;
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
        slsFindWindowByGeometry = (MacIslandSLSFindWindowFn)dlsym(skyLight, "SLSFindWindowByGeometry");
    });
}

static int topRowReachable(NSWindow *window, CALayer *container, CALayer *hitLayer) {
    loadSkyLightSymbols();
    if (!slsMainConnectionID || !slsFindWindowByGeometry) return -1;
    CALayer *root = islandRootLayer(window);
    if (!root || !hitLayer.superlayer) return 2;
    BOOL atTop = NO;
    CGFloat flat = 0;
    CGFloat midX = 0;
    resolvedTopSpanInRoot(container, root, &atTop, &flat, &midX);
    if (!atTop) return 2;

    CGRect winRect = rectInWindowCoordinates(window, root, container);
    if (winRect.size.width < winRect.size.height + 4) return 2;
    NSRect screenRect = [window convertRectToScreen:NSRectFromCGRect(winRect)];
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary) return -1;
    CGFloat primaryMaxY = NSMaxY(primary.frame);
    CGPoint query = CGPointMake(NSMidX(screenRect), primaryMaxY - NSMaxY(screenRect));
    CGPoint outPoint = CGPointZero;
    uint32_t ownerWindowID = 0;
    int ownerConnection = 0;
    if (slsFindWindowByGeometry(slsMainConnectionID(), 0, 1, 0, &query, &outPoint,
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

static NSWindow *islandWindowAtTopEdge(CGPoint screenPoint) {
    for (NSArray *entry in coveredIslands) {
        NSWindow *window = entry[0];
        CALayer *container = entry[1];
        CALayer *root = islandRootLayer(window);
        if (!isWindowActiveForTopHit(window) || !root || !container.superlayer) continue;
        BOOL atTop = NO;
        CGFloat flat = 0;
        CGFloat midX = 0;
        resolvedTopSpanInRoot(container, root, &atTop, &flat, &midX);
        if (!atTop) continue;

        CGRect winRect = rectInWindowCoordinates(window, root, container);
        NSRect screenRect = [window convertRectToScreen:NSRectFromCGRect(winRect)];
        CGFloat inset = MacIslandModelMaskObserver(container).applied ? 0.0 : container.cornerRadius;
        CGFloat leftEdge = NSMinX(screenRect) + inset;
        CGFloat rightEdge = NSMaxX(screenRect) - inset;
        if (fabs(screenPoint.y - NSMaxY(screenRect)) <= 1.0 &&
            screenPoint.x >= leftEdge && screenPoint.x <= rightEdge) {
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

static void hookedSendEvent(NSWindow *window, SEL selector, NSEvent *event) {
    if (forwardingTopHitEvent) {
        ((void (*)(id, SEL, NSEvent *))origSendEvent)(window, selector, event);
        return;
    }
    NSEventType type = event.type;
    NSWindow *target = window;
    if (!invertColorsEnabled() && isTrackedMouseEvent(type)) {
        BOOL targetingIsland = isIslandWindow(window);
        BOOL isDown = (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown);
        BOOL isUp = (type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp);
        BOOL isDrag = (type == NSEventTypeLeftMouseDragged || type == NSEventTypeRightMouseDragged);
        if (!targetingIsland && isDown) {
            NSWindow *matched = islandWindowAtTopEdge(windowPointToScreen(window, event.locationInWindow));
            redirectTargetWindow = matched;
            if (matched) target = matched;
        } else if (!targetingIsland && redirectTargetWindow && (isDrag || isUp)) {
            target = redirectTargetWindow;
            if (isUp) redirectTargetWindow = nil;
        } else if (isDown || isUp) {
            redirectTargetWindow = nil;
        }

        if (target != window || targetingIsland) {
            CGPoint point = event.locationInWindow;
            if (target != window) {
                CGPoint screenPoint = windowPointToScreen(window, point);
                point = CGPointMake(screenPoint.x - target.frame.origin.x,
                                    screenPoint.y - target.frame.origin.y);
#ifdef MACISLAND_TESTING
                testRedirectCount++;
#endif
            }
            CGFloat topLimit = target.frame.size.height - 0.5;
            if (target != window || point.y > topLimit) {
                if (point.y > topLimit) point.y = topLimit;
                event = clampedMouseEvent(event, target, point);
            }
        }
    }
#ifdef MACISLAND_TESTING
    if (isTrackedMouseEvent(type)) {
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
    if (stripsOut) *stripsOut = activeTopStrips.count;
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
