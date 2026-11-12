#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "notch-layout.h"
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

static char mergeVisibilityKey, secondaryMergeKey, suppressedOpacityKey;
static void (*originalSetHidden)(id, SEL, BOOL);
static void (*originalSetOpacity)(id, SEL, float);
static char maskObserverKey, parentGeometryKey, sceneLayersKey, sceneOriginObserverKey;
static void (*originalSetCornerRadius)(id, SEL, CGFloat);
static void (*baseSetBounds)(id, SEL, CGRect);
static void (*baseSetPosition)(id, SEL, CGPoint);

// Strict leaf lock guarding in-memory observer state only. Never hold across
// Core Animation, AppKit, KVO registration, or @synchronized calls.
static os_unfair_lock maskStateLock = OS_UNFAIR_LOCK_INIT;
static _Thread_local const void *activeModelWriteObserver;

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
        NSRect cutout = NSZeroRect;
        if (!MacIslandScreenNotchCutout(screen, &cutout)) continue;
        [layouts addObject:@{@"size": [NSValue valueWithSize:screen.frame.size],
                            @"height": @(cutout.size.height),
                            @"left": @(NSMinX(cutout) - NSMinX(screen.frame)),
                            @"right": @(NSMaxX(cutout) - NSMinX(screen.frame)),
                            @"pixel": @(1 / MAX(screen.backingScaleFactor, 1)),
                            @"bottomSnap": @(panelBottomSnap(screen, cutout.size.height))}];
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

typedef struct {
    CGFloat pixelInset;
    CGFloat horizontalFlare;
    CGFloat bottomExtension;
    CGFloat topExtension;
} MacIslandPaintExtensions;

@interface MacIslandNativeMaskObserver : NSObject {
  @package
    __weak MacIslandNativeMaskObserver *_mergeInput;
    __weak MacIslandNativeMaskObserver *_contourPeer;
    __weak MacIslandNativeMaskObserver *_detachedOwner;
    __weak MacIslandNativeMaskObserver *_detachedPaint;

    __weak CALayer *_desiredObservedParent;
    __weak CALayer *_registeredObservedParent;
    BOOL _reconcilingParentKVO;

    __weak CALayer *_desiredMergeScene;
    __weak CALayer *_registeredMergeScene;
    BOOL _reconcilingMergeSceneKVO;

    __weak CALayer *_desiredHeldUnion;
    __weak CALayer *_registeredHeldUnion;
    id _desiredHeldBlur;
    id _registeredHeldBlur;
    BOOL _reconcilingHeldKVO;

    __weak CALayer *_desiredObservedUnion;
    __weak CALayer *_registeredObservedUnion;
    id _desiredObservedBlur;
    id _registeredObservedBlur;
    BOOL _reconcilingObservedKVO;

    NSHashTable<CALayer *> *_suppressedPaint;
    CAShapeLayer *_shapeMask;
    MacIslandPaintExtensions _extensions;
    NSArray *_modifierBindings;
    NSArray *_nativeMaskGroups;
    id _nativeMaskSize;

    BOOL _refreshing;
    BOOL _refreshDirty;
    BOOL _maskRefreshing;
    BOOL _maskDirty;
    BOOL _syncingGeometry;
    BOOL _geometryDirty;
}
@property(nonatomic, weak) CALayer *source;
@property(nonatomic, strong) NSArray<NSString *> *keys;
@property(atomic) CGFloat nativeRadius;
@property(atomic) BOOL nativeHidden;
@property(atomic) BOOL applied;
@property(atomic) CGRect nativeBounds;
@property(atomic) CGPoint nativePosition;
- (instancetype)initWithLayer:(CALayer *)layer;
- (CAShapeLayer *)shapeMask;
- (CAShapeLayer *)ensureShapeMask;
- (void)refresh;
- (void)refreshMask;
- (void)reconcileObservedParent:(CALayer *)parent;
- (void)reconcileMergeScene:(CALayer *)scene;
- (void)reconcileHeldVisibilityKVO;
- (void)reconcileObservedMergeKVO;
- (void)endVisibilityHold:(BOOL)applyHide;
- (void)updateVisibilityHold;
- (BOOL)holdVisibilityInUnion:(CALayer *)group blur:(id)blur;
- (void)setMergeSuppression:(BOOL)suppress unionLayer:(CALayer *)unionLayer blur:(id)blur
                      paints:(NSArray<CALayer *> *)paints;
- (void)useDetachedPaint:(MacIslandNativeMaskObserver *)peer inUnion:(CALayer *)group blur:(id)blur;
@end

static inline MacIslandPaintExtensions observerPaintExtensions(MacIslandNativeMaskObserver *observer) {
    MacIslandPaintExtensions ext = {0, 0, 0, 0};
    if (!observer) return ext;
    os_unfair_lock_lock(&maskStateLock);
    ext = observer->_extensions;
    os_unfair_lock_unlock(&maskStateLock);
    return ext;
}

static inline void setObserverPaintExtensions(MacIslandNativeMaskObserver *observer, MacIslandPaintExtensions ext) {
    if (!observer) return;
    os_unfair_lock_lock(&maskStateLock);
    observer->_extensions = ext;
    os_unfair_lock_unlock(&maskStateLock);
}

static inline MacIslandNativeMaskObserver *observerMergeInput(MacIslandNativeMaskObserver *observer) {
    if (!observer) return nil;
    os_unfair_lock_lock(&maskStateLock);
    MacIslandNativeMaskObserver *input = observer->_mergeInput;
    os_unfair_lock_unlock(&maskStateLock);
    return input;
}

static inline CALayer *observerDesiredObservedUnion(MacIslandNativeMaskObserver *observer) {
    if (!observer) return nil;
    os_unfair_lock_lock(&maskStateLock);
    CALayer *unionLayer = observer->_desiredObservedUnion;
    os_unfair_lock_unlock(&maskStateLock);
    return unionLayer;
}

static CGRect nativeBodyFrame(MacIslandNativeMaskObserver *observer) {
    CALayer *layer = observer.source;
    CGSize size = observer.nativeBounds.size;
    CGRect box = CGRectMake(-layer.anchorPoint.x * size.width, -layer.anchorPoint.y * size.height,
                            size.width, size.height);
    CGRect frame = CGRectApplyAffineTransform(box, CATransform3DGetAffineTransform(layer.transform));
    return CGRectOffset(frame, observer.nativePosition.x, observer.nativePosition.y);
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
static id nativeModifierObject(id object, NSString *name);
static BOOL nativeModifierEnabled(id modifier);

// Core Animation releases its transaction lock as soon as CALayer.sublayers /
// filters / presentationModifiers returns its internal array wrapper, so an
// unlocked [layer.sublayers copy] on the background DisplayLink thread can race
// with main-thread addSublayer:/removeFromSuperlayer inside __NSArrayI_new.
// Snapshot under +[CATransaction lock] (recursive on main, never nested inside
// maskStateLock).
static NSArray<CALayer *> *copyLayerSublayers(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray<CALayer *> *snapshot = [layer.sublayers copy];
    [CATransaction unlock];
    return snapshot;
}
static BOOL layerHasSublayers(CALayer *layer) {
    if (!layer) return NO;
    [CATransaction lock];
    BOOL has = layer.sublayers.count != 0;
    [CATransaction unlock];
    return has;
}
static NSArray *copyLayerFilters(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray *snapshot = [layer.filters copy];
    [CATransaction unlock];
    return snapshot;
}
static NSArray *copyLayerModifiers(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray *snapshot = [nativeModifierObject(layer, @"presentationModifiers") copy];
    [CATransaction unlock];
    return snapshot;
}
static NSArray<NSString *> *copyLayerAnimationKeys(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray<NSString *> *snapshot = [layer.animationKeys copy];
    [CATransaction unlock];
    return snapshot;
}

static BOOL hasMergeFilters(CALayer *layer) {
    if (!layer) return NO;
    BOOL blur = NO, threshold = NO;
    NSArray *filters = copyLayerFilters(layer);
    for (id filter in filters) {
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
    if (!group) return nil;
    id blur = nil;
    BOOL threshold = NO;
    NSArray *filters = copyLayerFilters(group);
    for (id filter in filters) {
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
    NSArray *modifiers = copyLayerModifiers(layer);
    for (id modifier in modifiers) {
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
    if (!scene) return @[leaf];
    CGRect circle = presentationLayerFrameInAncestor(leaf, scene);
    CALayer *match = nil;
    NSArray<CALayer *> *sceneBranches = copyLayerSublayers(scene);
    for (CALayer *branch in sceneBranches) {
        if (branch == group || branch.contents) continue;
        NSArray<CALayer *> *candidates = copyLayerSublayers(branch);
        for (CALayer *candidate in candidates) {
            if (![candidate.name hasPrefix:@"SimpleViewDisplayItem-"] ||
                !isOpaqueBlack(candidate.backgroundColor) || candidate.contents || layerHasSublayers(candidate))
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
    for (CALayer *branch in sceneBranches) {
        if (branch == group || branch.contents) continue;
        NSArray<CALayer *> *candidates = copyLayerSublayers(branch);
        for (CALayer *candidate in candidates) {
            if (candidate.contents || layerHasSublayers(candidate)) continue;
            CGRect expected = fallback;
            if ([candidate.name hasPrefix:@"BackdropViewDisplayItem-"]) {
                NSArray *filters = copyLayerFilters(candidate);
                NSArray *types = [filters valueForKey:@"type"];
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

static void clearSecondaryMergeInputs(CALayer *unionLayer) {
    NSArray<CALayer *> *branches = copyLayerSublayers(unionLayer);
    for (CALayer *branch in branches) {
        NSArray<CALayer *> *children = copyLayerSublayers(branch);
        if (children.count != 1) continue;
        MacIslandNativeMaskObserver *secondary = modelMaskObserver(children.firstObject);
        if (observerDesiredObservedUnion(secondary))
            [secondary setMergeSuppression:NO unionLayer:nil blur:nil paints:nil];
    }
}

static void refreshSecondaryMergeInputs(MacIslandNativeMaskObserver *input, CGRect primaryBody) {
    CALayer *unionLayer = input.source.superlayer;
    if (!unionLayer) return;
    id blur = activeMergeBlur(unionLayer);
    NSArray<CALayer *> *branches = copyLayerSublayers(unionLayer);
    for (CALayer *branch in branches) {
        if (branch == input.source || branch.contents ||
            (branch.backgroundColor && CGColorGetAlpha(branch.backgroundColor) > 0))
            continue;
        NSArray<CALayer *> *children = copyLayerSublayers(branch);
        if (children.count != 1) continue;
        CALayer *leaf = children.firstObject;
        if (!isSecondaryMergeInput(leaf) || leaf.contents || layerHasSublayers(leaf)) continue;
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
    NSArray<CALayer *> *siblings = copyLayerSublayers(secondary.superlayer.superlayer);
    for (CALayer *sibling in siblings) {
        if (!isNativeUnionFill(sibling)) continue;
        MacIslandNativeMaskObserver *primary = modelMaskObserver(sibling);
        if (primary.applied) [primary refreshMask];
    }
}

// An opaque material can draw the shoulder without smoothing it a second
// time through the native merge filter. Never hold maskStateLock across any
// CALayer, CAFilter, or KVO call: Core Animation invokes KVO while holding its
// layer/transaction locks on main, while DisplayLink flushes run on the
// background animation thread.
static BOOL hasOpaqueContourPeer(MacIslandNativeMaskObserver *input) {
    CALayer *source = input.source;
    CALayer *unionLayer = source ? source.superlayer : nil;
    MacIslandPaintExtensions ext = observerPaintExtensions(input);
    CALayer *scene = (unionLayer && ext.topExtension > 0) ? unionLayer.superlayer : nil;
    [input reconcileMergeScene:scene];

    os_unfair_lock_lock(&maskStateLock);
    MacIslandNativeMaskObserver *previous = input->_contourPeer;
    BOOL prevHeldHere = (previous != nil && previous->_desiredHeldBlur != nil &&
                         previous->_desiredHeldUnion == unionLayer && previous->_mergeInput == input);
    os_unfair_lock_unlock(&maskStateLock);

    id blur = unionLayer ? activeMergeBlur(unionLayer) : nil;
    // The two model layers finish their bounds and position writes separately.
    // Once Apple requests the hide, the identified material stays responsible
    // until this same filter hands off. Revalidate ownership, not model endpoints.
    if (scene && previous && prevHeldHere && previous.applied) {
        CALayer *heldMaterial = previous.source;
        CAShapeLayer *prevMask = [previous shapeMask];
        if (heldMaterial && heldMaterial.superlayer == scene &&
            prevMask && heldMaterial.mask == prevMask && !heldMaterial.hidden &&
            heldMaterial.opacity >= 1 && !heldMaterial.contents && !layerHasSublayers(heldMaterial) &&
            isOpaqueBlack(heldMaterial.backgroundColor)) {
            return YES;
        }
    }

    MacIslandNativeMaskObserver *selected = nil;
    if (scene && unionLayer) {
        CGRect body = [unionLayer convertRect:nativeBodyFrame(input) toLayer:scene];
        NSArray<CALayer *> *sublayers = copyLayerSublayers(scene);
        for (CALayer *layer in sublayers) {
            if (layer.superlayer != scene || !isOpaqueBlack(layer.backgroundColor)) continue;
            id association = objc_getAssociatedObject(layer, &maskObserverKey);
            if (![association isKindOfClass:MacIslandNativeMaskObserver.class]) continue;
            MacIslandNativeMaskObserver *peer = association;
            CAShapeLayer *peerMask = [peer shapeMask];
            if (!peer.applied || !peerMask || layer.mask != peerMask) continue;
            CGRect r = nativeBodyFrame(peer);
            // Native material and opaque merge input differ by a backing-pixel inset.
            if (fabs(CGRectGetMinX(r) - CGRectGetMinX(body)) > 1 ||
                fabs(CGRectGetMaxX(r) - CGRectGetMaxX(body)) > 1 ||
                fabs(CGRectGetMinY(r) - CGRectGetMinY(body)) > 1 ||
                fabs(CGRectGetMaxY(r) - CGRectGetMaxY(body)) > 1) continue;
            os_unfair_lock_lock(&maskStateLock);
            peer->_mergeInput = input;
            os_unfair_lock_unlock(&maskStateLock);
            if (layer.opacity >= 1 && !layer.contents && !layerHasSublayers(layer) &&
                (!layer.hidden || (blur && !source.hidden && source.opacity >= 1 &&
                                    !unionLayer.hidden && unionLayer.opacity >= 1))) {
                selected = peer;
                break;
            }
        }
    }

    CALayer *selectedSource = selected ? selected.source : nil;
    BOOL needHoldSelected = (selected != nil && blur != nil && selectedSource != nil && selectedSource.hidden);

    os_unfair_lock_lock(&maskStateLock);
    MacIslandNativeMaskObserver *oldPeer = input->_contourPeer;
    input->_contourPeer = selected;
    MacIslandNativeMaskObserver *releasePeer =
        (oldPeer != nil && oldPeer != selected && oldPeer->_desiredHeldBlur != nil) ? oldPeer : nil;
    os_unfair_lock_unlock(&maskStateLock);

    if (needHoldSelected) {
        // Sharing can hide the material before the merge starts. Reuse the
        // matched native paint until the same blur releases it.
        if ([selected holdVisibilityInUnion:unionLayer blur:blur]) {
            originalSetHidden(selectedSource, @selector(setHidden:), NO);
        }
    }
    if (releasePeer) [releasePeer endVisibilityHold:YES];
    return selected != nil;
}

static CGSize paintSize(MacIslandNativeMaskObserver *observer, CGSize size) {
    MacIslandPaintExtensions ext = observerPaintExtensions(observer);
    size.width += 2 * ext.horizontalFlare;
    size.height += ext.topExtension + 2 * ext.pixelInset + ext.bottomExtension;
    return size;
}

static CGPoint paintPosition(MacIslandNativeMaskObserver *observer, CGPoint point) {
    MacIslandPaintExtensions ext = observerPaintExtensions(observer);
    CGPoint anchor = observer.source.anchorPoint;
    point.x += (2 * anchor.x - 1) * ext.horizontalFlare;
    point.y += (anchor.y - 1) * ext.topExtension + (2 * anchor.y - 1) * ext.pixelInset +
               anchor.y * ext.bottomExtension;
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
        _nativeHidden = layer.hidden;
        _nativeBounds = layer.bounds;
        _nativePosition = layer.position;
        _keys = @[@"bounds", @"position", @"anchorPoint", @"transform",
                  @"superlayer", @"name", @"hidden", @"opacity", @"backgroundColor", @"shadowColor", @"shadowOpacity", @"masksToBounds", @"mask"];
        for (NSString *key in _keys)
            [layer addObserver:self forKeyPath:key options:0 context:&maskObserverKey];
        observeNativeAnimations(layer);
        [self refresh];
    }
    return self;
}

- (CAShapeLayer *)shapeMask {
    os_unfair_lock_lock(&maskStateLock);
    CAShapeLayer *mask = _shapeMask;
    os_unfair_lock_unlock(&maskStateLock);
    return mask;
}

- (CAShapeLayer *)ensureShapeMask {
    CAShapeLayer *existing = [self shapeMask];
    if (existing) return existing;
    CAShapeLayer *created = [CAShapeLayer layer];
    created.fillColor = NSColor.whiteColor.CGColor;
    created.name = @"MacIslandNativeNotchMask";
    created.anchorPoint = CGPointZero;
    // Match the native background: antialias the Bezier contour, not the
    // mask's rectangular surface edge during fractional native motion.
    created.edgeAntialiasingMask = 0;
    created.actions = @{@"path": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
    os_unfair_lock_lock(&maskStateLock);
    if (!_shapeMask) _shapeMask = created;
    existing = _shapeMask;
    os_unfair_lock_unlock(&maskStateLock);
    return existing;
}

- (void)reconcileObservedParent:(CALayer *)parent {
    os_unfair_lock_lock(&maskStateLock);
    _desiredObservedParent = parent;
    if (_reconcilingParentKVO) {
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    _reconcilingParentKVO = YES;
    for (;;) {
        CALayer *current = _registeredObservedParent;
        CALayer *desired = _desiredObservedParent;
        if (current == desired) {
            _reconcilingParentKVO = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        _registeredObservedParent = desired;
        os_unfair_lock_unlock(&maskStateLock);
        if (current) [current removeObserver:self forKeyPath:@"bounds" context:&parentGeometryKey];
        if (desired) [desired addObserver:self forKeyPath:@"bounds" options:0 context:&parentGeometryKey];
        os_unfair_lock_lock(&maskStateLock);
    }
}

- (void)reconcileMergeScene:(CALayer *)scene {
    os_unfair_lock_lock(&maskStateLock);
    _desiredMergeScene = scene;
    if (_reconcilingMergeSceneKVO) {
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    _reconcilingMergeSceneKVO = YES;
    for (;;) {
        CALayer *current = _registeredMergeScene;
        CALayer *desired = _desiredMergeScene;
        if (current == desired) {
            _reconcilingMergeSceneKVO = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        _registeredMergeScene = desired;
        os_unfair_lock_unlock(&maskStateLock);
        if (current) [current removeObserver:self forKeyPath:@"sublayers" context:&sceneLayersKey];
        if (desired) [desired addObserver:self forKeyPath:@"sublayers" options:0 context:&sceneLayersKey];
        os_unfair_lock_lock(&maskStateLock);
    }
}

- (void)reconcileHeldVisibilityKVO {
    os_unfair_lock_lock(&maskStateLock);
    if (_reconcilingHeldKVO) {
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    _reconcilingHeldKVO = YES;
    for (;;) {
        CALayer *currentUnion = _registeredHeldUnion;
        id currentBlur = _registeredHeldBlur;
        CALayer *desiredUnion = _desiredHeldUnion;
        id desiredBlur = _desiredHeldBlur;
        if (currentUnion == desiredUnion && currentBlur == desiredBlur) {
            _reconcilingHeldKVO = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        _registeredHeldUnion = desiredUnion;
        _registeredHeldBlur = desiredBlur;
        os_unfair_lock_unlock(&maskStateLock);
        if (currentBlur != desiredBlur) {
            if (currentBlur) {
                [currentBlur removeObserver:self forKeyPath:@"inputRadius" context:&mergeVisibilityKey];
                [currentBlur removeObserver:self forKeyPath:@"enabled" context:&mergeVisibilityKey];
            }
            if (desiredBlur) {
                [desiredBlur addObserver:self forKeyPath:@"inputRadius" options:0 context:&mergeVisibilityKey];
                [desiredBlur addObserver:self forKeyPath:@"enabled" options:0 context:&mergeVisibilityKey];
            }
        }
        if (currentUnion != desiredUnion) {
            if (currentUnion) [currentUnion removeObserver:self forKeyPath:@"filters" context:&mergeVisibilityKey];
            if (desiredUnion) [desiredUnion addObserver:self forKeyPath:@"filters" options:0 context:&mergeVisibilityKey];
        }
        os_unfair_lock_lock(&maskStateLock);
    }
}

- (void)reconcileObservedMergeKVO {
    os_unfair_lock_lock(&maskStateLock);
    if (_reconcilingObservedKVO) {
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    _reconcilingObservedKVO = YES;
    for (;;) {
        CALayer *currentUnion = _registeredObservedUnion;
        id currentBlur = _registeredObservedBlur;
        CALayer *desiredUnion = _desiredObservedUnion;
        id desiredBlur = _desiredObservedBlur;
        if (currentUnion == desiredUnion && currentBlur == desiredBlur) {
            _reconcilingObservedKVO = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        _registeredObservedUnion = desiredUnion;
        _registeredObservedBlur = desiredBlur;
        os_unfair_lock_unlock(&maskStateLock);
        if (currentBlur != desiredBlur) {
            if (currentBlur) {
                [currentBlur removeObserver:self forKeyPath:@"inputRadius" context:&secondaryMergeKey];
                [currentBlur removeObserver:self forKeyPath:@"enabled" context:&secondaryMergeKey];
            }
            if (desiredBlur) {
                [desiredBlur addObserver:self forKeyPath:@"inputRadius" options:0 context:&secondaryMergeKey];
                [desiredBlur addObserver:self forKeyPath:@"enabled" options:0 context:&secondaryMergeKey];
            }
        }
        if (currentUnion != desiredUnion) {
            if (currentUnion) [currentUnion removeObserver:self forKeyPath:@"filters" context:&secondaryMergeKey];
            if (desiredUnion) [desiredUnion addObserver:self forKeyPath:@"filters" options:0 context:&secondaryMergeKey];
        }
        os_unfair_lock_lock(&maskStateLock);
    }
}

- (void)refresh {
    os_unfair_lock_lock(&maskStateLock);
    if (_refreshing) {
        _refreshDirty = YES;
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    _refreshing = YES;
    _refreshDirty = NO;
    os_unfair_lock_unlock(&maskStateLock);

    NSUInteger passes = 0;
    for (;;) {
        CALayer *source = self.source;
        // Native children may settle before their display parent gets its size.
        // Eligibility must follow that existing parent's layout too.
        CALayer *parent = source ? source.superlayer : nil;
        [self reconcileObservedParent:parent];

        CAShapeLayer *currentMask = [self shapeMask];
        BOOL ownsMask = currentMask && source && source.mask == currentMask;
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
            setObserverPaintExtensions(self, (MacIslandPaintExtensions){inset, flare, bottom, top});
            bounds.size = paintSize(self, bounds.size);
            position = paintPosition(self, position);
            CAShapeLayer *maskLayer = [self ensureShapeMask];
            const void *previousWriteObserver = activeModelWriteObserver;
            activeModelWriteObserver = (__bridge const void *)self;
            baseSetBounds(source, @selector(setBounds:), bounds);
            baseSetPosition(source, @selector(setPosition:), position);
            originalSetCornerRadius(source, @selector(setCornerRadius:), 0);
            source.mask = maskLayer;
            activeModelWriteObserver = previousWriteObserver;
            BOOL newlyApplied = !self.applied;
            self.applied = YES;
            if (newlyApplied) {
                NSArray<NSString *> *animKeys = copyLayerAnimationKeys(source);
                for (NSString *key in animKeys) {
                    CAAnimation *animation = [source animationForKey:key];
                    CAAnimation *adjusted = animationWithoutPillCorners(animation);
                    if (adjusted != animation) [source addAnimation:adjusted forKey:key];
                }
            }
            [self refreshMask];
        } else if (self.applied) {
            os_unfair_lock_lock(&maskStateLock);
            MacIslandNativeMaskObserver *peer = _contourPeer;
            _contourPeer = nil;
            os_unfair_lock_unlock(&maskStateLock);
            [self reconcileMergeScene:nil];
            [peer endVisibilityHold:YES];
            [self endVisibilityHold:YES];
            if (source && isNativeUnionFill(source)) clearSecondaryMergeInputs(source.superlayer);
            if (source) {
                const void *previousWriteObserver = activeModelWriteObserver;
                activeModelWriteObserver = (__bridge const void *)self;
                baseSetBounds(source, @selector(setBounds:), self.nativeBounds);
                baseSetPosition(source, @selector(setPosition:), self.nativePosition);
                if (ownsMask) source.mask = nil;
                originalSetCornerRadius(source, @selector(setCornerRadius:), self.nativeRadius);
                activeModelWriteObserver = previousWriteObserver;
            }
            self.applied = NO;
        }
        if (!self.applied) {
            CALayer *obsUnion = observerDesiredObservedUnion(self);
            if (obsUnion && (!source || source.superlayer.superlayer != obsUnion || !isSecondaryMergeInput(source)))
                [self setMergeSuppression:NO unionLayer:nil blur:nil paints:nil];
            synchronizeNativeMaskGeometry(self);
            if (source && isSecondaryMergeInput(source)) notifyUnionPrimaryObserver(source);
        }
        // Re-evaluate immediately if the native material is hidden or removed.
        [observerMergeInput(self) refreshMask];
        [CATransaction commit];

        os_unfair_lock_lock(&maskStateLock);
        if (!_refreshDirty) {
            _refreshing = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        _refreshDirty = NO;
        if (++passes >= 4) {
            _refreshing = NO;
            os_unfair_lock_unlock(&maskStateLock);
            dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
            return;
        }
        os_unfair_lock_unlock(&maskStateLock);
    }
}

- (void)refreshMask {
    os_unfair_lock_lock(&maskStateLock);
    if (_maskRefreshing) {
        _maskDirty = YES;
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    _maskRefreshing = YES;
    _maskDirty = NO;
    os_unfair_lock_unlock(&maskStateLock);

    NSUInteger passes = 0;
    for (;;) {
        CALayer *source = self.source;
        if (!self.applied) {
            if (source && isSecondaryMergeInput(source)) {
                synchronizeNativeMaskGeometry(self);
                notifyUnionPrimaryObserver(source);
            }
        } else {
            CAShapeLayer *maskLayer = [self shapeMask];
            if (source && maskLayer && source.mask == maskLayer) {
                synchronizeNativeMaskGeometry(self);
                CGPoint origin, position, anchor;
                CGSize size;
                CATransform3D transform;
                presentationLayerGeometry(source, &origin, &size, &position, &anchor, &transform);
                if (isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0) {
                    CGFloat scaleY = hypot(transform.m21, transform.m22);
                    CGFloat top = MAX(0, -(position.y - anchor.y * size.height)) / MAX(scaleY, 0.001);
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    maskLayer.bounds = (CGRect){CGPointZero, size};
                    maskLayer.position = origin;
                    maskLayer.contentsScale = MAX(source.contentsScale, 2);
                    BOOL peerOwnsShoulder = hasOpaqueContourPeer(self) && activeMergeBlur(source.superlayer);
                    CGPathRef path = notchMaskPathAtTop(size, top, !peerOwnsShoulder, scaleY);
                    maskLayer.path = path;
                    CGPathRelease(path);
                    [CATransaction commit];
                    if (isNativeUnionFill(source)) {
                        MacIslandPaintExtensions ext = observerPaintExtensions(self);
                        CGFloat verticalPad = ext.topExtension + 2 * ext.pixelInset + ext.bottomExtension;
                        CGRect primaryBody = CGRectMake((position.x - anchor.x * size.width) + ext.horizontalFlare,
                                                        (position.y - anchor.y * size.height) + ext.topExtension + ext.pixelInset,
                                                        MAX(0, size.width - 2 * ext.horizontalFlare),
                                                        MAX(0, size.height - verticalPad));
                        refreshSecondaryMergeInputs(self, primaryBody);
                    }
                }
            }
        }

        os_unfair_lock_lock(&maskStateLock);
        if (!_maskDirty) {
            _maskRefreshing = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        _maskDirty = NO;
        if (++passes >= 4) {
            _maskRefreshing = NO;
            os_unfair_lock_unlock(&maskStateLock);
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshMask]; });
            return;
        }
        os_unfair_lock_unlock(&maskStateLock);
    }
}

// Apple hides its existing primary material partway through closing, before
// the merge kernel is disabled. Preserve this previously-visible paint until
// the native filter handoff; a new show request cancels the pending hide.
- (void)endVisibilityHold:(BOOL)applyHide {
    id oldBlur = nil;
    os_unfair_lock_lock(&maskStateLock);
    oldBlur = _desiredHeldBlur;
    BOOL hadHold = (oldBlur != nil || _desiredHeldUnion != nil);
    _desiredHeldBlur = nil;
    _desiredHeldUnion = nil;
    os_unfair_lock_unlock(&maskStateLock);
    (void)oldBlur;
    if (!hadHold) return;

    [self reconcileHeldVisibilityKVO];
    if (!applyHide) return;
    CALayer *source = self.source;
    if (!source) return;
    os_unfair_lock_lock(&maskStateLock);
    BOOL shouldHide = (_desiredHeldBlur == nil) && self.nativeHidden;
    os_unfair_lock_unlock(&maskStateLock);
    if (shouldHide) originalSetHidden(source, @selector(setHidden:), YES);
}

- (BOOL)holdVisibilityInUnion:(CALayer *)group blur:(id)blur {
    if (!group || !blur) return NO;
    os_unfair_lock_lock(&maskStateLock);
    if (!_desiredHeldBlur) {
        _desiredHeldUnion = group;
        _desiredHeldBlur = blur;
    }
    BOOL held = (_desiredHeldBlur != nil);
    os_unfair_lock_unlock(&maskStateLock);
    [self reconcileHeldVisibilityKVO];
    return held;
}

- (void)updateVisibilityHold {
    os_unfair_lock_lock(&maskStateLock);
    id currentBlur = _desiredHeldBlur;
    CALayer *unionLayer = _desiredHeldUnion;
    MacIslandNativeMaskObserver *input = _mergeInput;
    os_unfair_lock_unlock(&maskStateLock);
    if (!currentBlur) return;

    id blur = unionLayer ? activeMergeBlur(unionLayer) : nil;
    if (blur == currentBlur) return;
    if (blur) {
        id oldBlur = nil;
        os_unfair_lock_lock(&maskStateLock);
        if (_desiredHeldBlur == currentBlur && _desiredHeldUnion == unionLayer) {
            oldBlur = _desiredHeldBlur;
            _desiredHeldBlur = blur;
        }
        os_unfair_lock_unlock(&maskStateLock);
        (void)oldBlur;
        [self reconcileHeldVisibilityKVO];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self endVisibilityHold:YES];
    [input refreshMask];
    [CATransaction commit];
}

- (void)useDetachedPaint:(MacIslandNativeMaskObserver *)peer inUnion:(CALayer *)group blur:(id)blur {
    os_unfair_lock_lock(&maskStateLock);
    MacIslandNativeMaskObserver *previous = _detachedPaint;
    if (previous != peer) {
        if (previous && previous->_detachedOwner == self) previous->_detachedOwner = nil;
        _detachedPaint = peer;
        if (peer) peer->_detachedOwner = self;
    } else {
        previous = nil;
    }
    os_unfair_lock_unlock(&maskStateLock);

    // The stock fallback is painted at the same spring frame, outside the
    // union. It keeps the two contours separate while the filter is active.
    CALayer *peerSource = peer ? peer.source : nil;
    if (peer && blur && peerSource && peerSource.hidden) {
        if ([peer holdVisibilityInUnion:group blur:blur]) {
            originalSetHidden(peerSource, @selector(setHidden:), NO);
        }
    }
    if (previous) [previous endVisibilityHold:YES];
}

- (void)setMergeSuppression:(BOOL)suppress unionLayer:(CALayer *)unionLayer blur:(id)blur
                     paints:(NSArray<CALayer *> *)paints {
    if (!suppress) [self useDetachedPaint:nil inUnion:nil blur:nil];
    id nextBlur = suppress ? blur : nil;
    CALayer *nextUnion = nextBlur ? unionLayer : nil;
    NSArray<CALayer *> *targets = suppress && paints ? paints : @[];
    NSMutableArray<NSNumber *> *targetOpacities = [NSMutableArray arrayWithCapacity:targets.count];
    for (CALayer *paint in targets) {
        [targetOpacities addObject:@(paint.opacity)];
    }
    NSMutableArray<CALayer *> *restored = [NSMutableArray array];
    NSMutableArray<NSNumber *> *restoredOpacities = [NSMutableArray array];
    NSHashTable<CALayer *> *freshTable = targets.count
        ? [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality]
        : nil;
    id oldBlur = nil;

    os_unfair_lock_lock(&maskStateLock);
    oldBlur = _desiredObservedBlur;
    _desiredObservedBlur = nextBlur;
    _desiredObservedUnion = nextUnion;
    if (targets.count && !_suppressedPaint) _suppressedPaint = freshTable;
    NSArray<CALayer *> *existingSuppressed = _suppressedPaint ? _suppressedPaint.allObjects : nil;
    for (CALayer *paint in existingSuppressed) {
        if ([targets containsObject:paint]) continue;
        [_suppressedPaint removeObject:paint];
        NSNumber *saved = objc_getAssociatedObject(paint, &suppressedOpacityKey);
        objc_setAssociatedObject(paint, &suppressedOpacityKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (saved) {
            [restored addObject:paint];
            [restoredOpacities addObject:saved];
        }
    }
    for (NSUInteger i = 0; i < targets.count; i++) {
        CALayer *paint = targets[i];
        if (!objc_getAssociatedObject(paint, &suppressedOpacityKey)) {
            objc_setAssociatedObject(paint, &suppressedOpacityKey, targetOpacities[i],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [_suppressedPaint addObject:paint];
    }
    os_unfair_lock_unlock(&maskStateLock);
    (void)oldBlur;
    (void)freshTable;

    [self reconcileObservedMergeKVO];

    if (!restored.count && !targets.count) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < restored.count; i++) {
        CALayer *paint = restored[i];
        os_unfair_lock_lock(&maskStateLock);
        BOOL resuppressed = (objc_getAssociatedObject(paint, &suppressedOpacityKey) != nil);
        os_unfair_lock_unlock(&maskStateLock);
        if (!resuppressed) originalSetOpacity(paint, @selector(setOpacity:), restoredOpacities[i].floatValue);
    }
    for (CALayer *paint in targets) {
        os_unfair_lock_lock(&maskStateLock);
        BOOL stillSuppressed = (objc_getAssociatedObject(paint, &suppressedOpacityKey) != nil);
        os_unfair_lock_unlock(&maskStateLock);
        if (stillSuppressed && paint.opacity > 0.0f) originalSetOpacity(paint, @selector(setOpacity:), 0.0f);
    }
    [CATransaction commit];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == &mergeVisibilityKey) { [self updateVisibilityHold]; return; }
    if (context == &secondaryMergeKey) {
        CALayer *obsUnion = observerDesiredObservedUnion(self);
        id blur = activeMergeBlur(obsUnion);
        if (!blur || !isSecondaryMergeInput(self.source)) {
            [self setMergeSuppression:NO unionLayer:nil blur:nil paints:nil];
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
    if (activeModelWriteObserver == (__bridge const void *)self) return;
    if ([keyPath isEqualToString:@"hidden"] || [keyPath isEqualToString:@"opacity"]) {
        [observerMergeInput(self) refreshMask];
        return;
    }
    CALayer *source = self.source;
    if (!source) return;
    if ([keyPath isEqualToString:@"bounds"]) self.nativeBounds = source.bounds;
    if ([keyPath isEqualToString:@"position"]) self.nativePosition = source.position;
    [self refresh];
}

- (void)dealloc {
    MacIslandNativeMaskObserver *peer = _contourPeer;
    _contourPeer = nil;
    CALayer *scene = _registeredMergeScene;
    _registeredMergeScene = nil;
    _desiredMergeScene = nil;
    if (scene) [scene removeObserver:self forKeyPath:@"sublayers" context:&sceneLayersKey];

    [peer endVisibilityHold:YES];

    id heldBlur = _registeredHeldBlur;
    CALayer *heldUnion = _registeredHeldUnion;
    _registeredHeldBlur = nil;
    _desiredHeldBlur = nil;
    _registeredHeldUnion = nil;
    _desiredHeldUnion = nil;
    if (heldBlur) {
        [heldBlur removeObserver:self forKeyPath:@"inputRadius" context:&mergeVisibilityKey];
        [heldBlur removeObserver:self forKeyPath:@"enabled" context:&mergeVisibilityKey];
    }
    if (heldUnion) [heldUnion removeObserver:self forKeyPath:@"filters" context:&mergeVisibilityKey];

    CALayer *parent = _registeredObservedParent;
    _registeredObservedParent = nil;
    _desiredObservedParent = nil;
    if (parent) [parent removeObserver:self forKeyPath:@"bounds" context:&parentGeometryKey];

    removeNativeMaskGeometry(self);

    MacIslandNativeMaskObserver *detached = _detachedPaint;
    _detachedPaint = nil;
    [detached endVisibilityHold:YES];

    id obsBlur = _registeredObservedBlur;
    CALayer *obsUnion = _registeredObservedUnion;
    _registeredObservedBlur = nil;
    _desiredObservedBlur = nil;
    _registeredObservedUnion = nil;
    _desiredObservedUnion = nil;
    if (obsBlur) {
        [obsBlur removeObserver:self forKeyPath:@"inputRadius" context:&secondaryMergeKey];
        [obsBlur removeObserver:self forKeyPath:@"enabled" context:&secondaryMergeKey];
    }
    if (obsUnion) [obsUnion removeObserver:self forKeyPath:@"filters" context:&secondaryMergeKey];

    NSArray<CALayer *> *suppressed = _suppressedPaint ? _suppressedPaint.allObjects : nil;
    _suppressedPaint = nil;
    if (suppressed.count) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *paint in suppressed) {
            os_unfair_lock_lock(&maskStateLock);
            NSNumber *saved = objc_getAssociatedObject(paint, &suppressedOpacityKey);
            objc_setAssociatedObject(paint, &suppressedOpacityKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            os_unfair_lock_unlock(&maskStateLock);
            if (saved) originalSetOpacity(paint, @selector(setOpacity:), saved.floatValue);
        }
        [CATransaction commit];
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
        NSArray *oldBindings = nil;
        os_unfair_lock_lock(&maskStateLock);
        oldBindings = observer->_modifierBindings;
        observer->_modifierBindings = [(oldBindings ?: @[]) arrayByAddingObject:binding];
        os_unfair_lock_unlock(&maskStateLock);
        (void)oldBindings;
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
    if (!layer || layer.modelLayer != layer) return nil;
    id value = objc_getAssociatedObject(layer, &maskObserverKey);
    return [value isKindOfClass:MacIslandNativeMaskObserver.class] ? value : nil;
}
static void modifierListChanged(CALayer *layer) {
    MacIslandNativeMaskObserver *observer = modelMaskObserver(layer);
    if (observer.applied) [observer refreshMask];
    else if (observer) synchronizeNativeMaskGeometry(observer);
    else if (hasMergeFilters(layer.superlayer)) {
        NSArray<CALayer *> *children = copyLayerSublayers(layer);
        for (CALayer *child in children) {
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
    id size = observer->_nativeMaskSize;
    NSArray *groups = observer->_nativeMaskGroups;
    NSArray *bindings = observer->_modifierBindings;
    CAShapeLayer *maskLayer = observer->_shapeMask;
    observer->_nativeMaskSize = nil;
    observer->_nativeMaskGroups = nil;
    observer->_modifierBindings = nil;
    os_unfair_lock_unlock(&maskStateLock);
    if (size && maskLayer && originalRemovePresentationModifier)
        originalRemovePresentationModifier(maskLayer, NSSelectorFromString(@"removePresentationModifier:"), size);
    for (id group in groups) {
        @synchronized(group) { [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) removeObject:observer]; }
    }
    for (MacIslandModifierBinding *binding in bindings) unbindModifier(binding);
}
static void synchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    if (!observer || !originalAddPresentationModifier) return;
    os_unfair_lock_lock(&maskStateLock);
    if (observer->_syncingGeometry) {
        observer->_geometryDirty = YES;
        os_unfair_lock_unlock(&maskStateLock);
        return;
    }
    observer->_syncingGeometry = YES;
    observer->_geometryDirty = NO;
    os_unfair_lock_unlock(&maskStateLock);

    NSUInteger passes = 0;
    for (;;) {
        CALayer *source = observer.source;
        BOOL applied = observer.applied;
        BOOL secondary = !applied && source && isSecondaryMergeInput(source);
        BOOL member = applied || secondary;
        NSArray *modifiers = (member && source) ? copyLayerModifiers(source) : nil;

        os_unfair_lock_lock(&maskStateLock);
        NSArray *currentBindings = observer->_modifierBindings;
        os_unfair_lock_unlock(&maskStateLock);

        NSMutableArray *stale = [NSMutableArray array];
        for (MacIslandModifierBinding *binding in currentBindings) {
            if (!applied || !binding.modifier || ![modifiers containsObject:binding.modifier])
                [stale addObject:binding];
        }
        if (stale.count) {
            NSArray *oldBindings = nil;
            os_unfair_lock_lock(&maskStateLock);
            oldBindings = observer->_modifierBindings;
            NSMutableArray *kept = [oldBindings mutableCopy] ?: [NSMutableArray array];
            for (id binding in stale) [kept removeObjectIdenticalTo:binding];
            observer->_modifierBindings = [kept copy];
            os_unfair_lock_unlock(&maskStateLock);
            (void)oldBindings;
            for (MacIslandModifierBinding *binding in stale) unbindModifier(binding);
        }
        id size = nil;
        NSMutableArray *groups = [NSMutableArray array];
        for (id modifier in modifiers) {
            NSString *key = nativeModifierObject(modifier, @"keyPath");
            if (applied) {
                bindNativeModifier(observer, modifier, key);
                if ([key isEqual:@"bounds.size"] && nativeModifierEnabled(modifier) &&
                    ((MacIslandModifierBinding *)objc_getAssociatedObject(modifier, &modifierBindingKey)).observer == observer)
                    size = modifier;
            }
            id group = nativeModifierObject(modifier, @"group");
            if (group && ![groups containsObject:group]) [groups addObject:group];
        }
        if (secondary) {
            NSArray *parentModifiers = copyLayerModifiers(source.superlayer);
            for (id modifier in parentModifiers) {
                id group = nativeModifierObject(modifier, @"group");
                if (group && ![groups containsObject:group]) [groups addObject:group];
            }
        }
        NSArray * immutableGroups = [groups copy];
        os_unfair_lock_lock(&maskStateLock);
        NSArray *previousGroups = observer->_nativeMaskGroups ?: @[];
        observer->_nativeMaskGroups = immutableGroups;
        id previousSize = observer->_nativeMaskSize;
        BOOL sizeChanged = previousSize != size;
        if (sizeChanged) observer->_nativeMaskSize = size;
        os_unfair_lock_unlock(&maskStateLock);

        for (id group in previousGroups) {
            if (![immutableGroups containsObject:group]) {
                @synchronized(group) { [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) removeObject:observer]; }
            }
        }
        for (id group in immutableGroups) {
            if (![previousGroups containsObject:group]) {
                @synchronized(group) {
                    NSHashTable *observers = objc_getAssociatedObject(group, &nativeMaskGroupObserversKey);
                    if (!observers) {
                        observers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory |
                                                                      NSPointerFunctionsObjectPointerPersonality];
                        objc_setAssociatedObject(group, &nativeMaskGroupObserversKey, observers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    [observers addObject:observer];
                }
            }
        }
        if (sizeChanged) {
            CAShapeLayer *maskLayer = [observer shapeMask];
            if (previousSize && maskLayer)
                originalRemovePresentationModifier(maskLayer, NSSelectorFromString(@"removePresentationModifier:"), previousSize);
            if (size)
                originalAddPresentationModifier([observer ensureShapeMask], NSSelectorFromString(@"addPresentationModifier:"), size);
        }
        (void)previousSize;
        (void)previousGroups;

        os_unfair_lock_lock(&maskStateLock);
        if (!observer->_geometryDirty) {
            observer->_syncingGeometry = NO;
            os_unfair_lock_unlock(&maskStateLock);
            return;
        }
        observer->_geometryDirty = NO;
        if (++passes >= 4) {
            observer->_syncingGeometry = NO;
            os_unfair_lock_unlock(&maskStateLock);
            dispatch_async(dispatch_get_main_queue(), ^{ synchronizeNativeMaskGeometry(observer); });
            return;
        }
        os_unfair_lock_unlock(&maskStateLock);
    }
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
    if (layer.modelLayer == layer) {
        id association = objc_getAssociatedObject(layer, &maskObserverKey);
        if ([association isKindOfClass:MacIslandNativeMaskObserver.class]) {
            MacIslandNativeMaskObserver *peer = association;
            peer.nativeHidden = hidden;
            if (!hidden) {
                [peer endVisibilityHold:NO];
            } else {
                os_unfair_lock_lock(&maskStateLock);
                BOOL alreadyHeldDetached = (peer->_desiredHeldBlur != nil) && !peer.applied;
                MacIslandNativeMaskObserver *detachedOwner = peer->_detachedOwner;
                CALayer *detachedUnion = detachedOwner ? detachedOwner->_desiredObservedUnion : nil;
                MacIslandNativeMaskObserver *input = peer->_mergeInput;
                BOOL isContourPeer = (input != nil && input->_contourPeer == peer);
                os_unfair_lock_unlock(&maskStateLock);

                if (alreadyHeldDetached) return;
                id detachedBlur = detachedUnion ? activeMergeBlur(detachedUnion) : nil;
                if (detachedOwner && detachedBlur && !layer.hidden) {
                    if ([peer holdVisibilityInUnion:detachedUnion blur:detachedBlur]) return;
                }
                CALayer *inputSource = isContourPeer ? input.source : nil;
                CALayer *group = inputSource ? inputSource.superlayer : nil;
                CAShapeLayer *peerMask = [peer shapeMask];
                if (isContourPeer && input.applied && peer.applied && group &&
                    !layer.hidden && layer.opacity >= 1 && !layer.contents && !layerHasSublayers(layer) &&
                    isOpaqueBlack(layer.backgroundColor) && peerMask && layer.mask == peerMask &&
                    layer.superlayer == group.superlayer) {
                    id blur = activeMergeBlur(group);
                    if (blur && [peer holdVisibilityInUnion:group blur:blur]) return;
                }
            }
        }
    }
    originalSetHidden(layer, selector, hidden);
}

static void setLayerOpacity(CALayer *layer, SEL selector, float opacity) {
    if (layer.modelLayer == layer) {
        id oldSaved = nil;
        os_unfair_lock_lock(&maskStateLock);
        oldSaved = objc_getAssociatedObject(layer, &suppressedOpacityKey);
        if (oldSaved) {
            objc_setAssociatedObject(layer, &suppressedOpacityKey, @(opacity),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            os_unfair_lock_unlock(&maskStateLock);
            (void)oldSaved;
            originalSetOpacity(layer, selector, 0.0f);
            return;
        }
        os_unfair_lock_unlock(&maskStateLock);
    }
    originalSetOpacity(layer, selector, opacity);
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
@property(atomic) CGFloat pixel;
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
@end

static void refreshNativeBackgroundCoverage(CALayer *layer) {
    id observer = objc_getAssociatedObject(layer, &maskObserverKey);
    if ([observer isKindOfClass:MacIslandNativeMaskObserver.class]) [observer refresh];
    NSArray<CALayer *> *children = copyLayerSublayers(layer);
    for (CALayer *child in children) refreshNativeBackgroundCoverage(child);
}

static void refreshNativeSceneOrigin(NSWindow *window) {
    if (![window isKindOfClass:NSWindow.class]) return;
    CALayer *root = window.contentView.layer;
    if (!root) return;
    MacIslandSceneOriginObserver *observer = objc_getAssociatedObject(root, &sceneOriginObserverKey);
    NSScreen *screen = window.screen;
    BOOL eligible = window.visible && MacIslandScreenHasNotch(screen) &&
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

static void installMaskLayerHooks(void) {
    if (originalSetCornerRadius) return;
    Method method = class_getInstanceMethod(CALayer.class, @selector(setCornerRadius:));
    originalSetCornerRadius = (void *)method_getImplementation(method);
    baseSetBounds = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setBounds:)));
    baseSetPosition = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setPosition:)));
    baseSetSublayerTransform = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setSublayerTransform:)));
    Method visibility = class_getInstanceMethod(CALayer.class, @selector(setHidden:));
    originalSetHidden = (void *)method_getImplementation(visibility);
    Method opacityMethod = class_getInstanceMethod(CALayer.class, @selector(setOpacity:));
    originalSetOpacity = (void *)method_getImplementation(opacityMethod);
    method_setImplementation(visibility, (IMP)setNativeMaterialHidden);
    method_setImplementation(opacityMethod, (IMP)setLayerOpacity);
    method_setImplementation(method, (IMP)setCornerRadius);
    installNativeCornerModifierHooks();
}

#ifdef MACISLAND_TESTING
void MacIslandInstallMaskHooksForTesting(NSArray<NSDictionary *> *layouts) {
    [MacIslandScreenGeometry shared].layouts = layouts;
    installMaskLayerHooks();
}
void MacIslandSetSceneEdgeCompensationForTesting(CALayer *root, CGFloat pixel) {
    MacIslandSceneOriginObserver *observer = objc_getAssociatedObject(root, &sceneOriginObserverKey);
    if (!observer) {
        observer = [[MacIslandSceneOriginObserver alloc] initWithLayer:root];
        objc_setAssociatedObject(root, &sceneOriginObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    observer.pixel = pixel;
    [observer refresh];
    refreshNativeBackgroundCoverage(root);
}
#endif

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
    installMaskLayerHooks();
}
