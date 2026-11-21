#import "mask-internal.h"
#import <objc/message.h>
#import <objc/runtime.h>

@implementation MacIslandScreenGeometry
+ (instancetype)shared {
    static MacIslandScreenGeometry *geometry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ geometry = [MacIslandScreenGeometry new]; });
    return geometry;
}
@end

CGPathRef MacIslandNotchMaskPathAtTop(CGSize size, CGFloat top, BOOL outwardShoulders, CGFloat scaleY) {
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

BOOL MacIslandIsOpaqueBlack(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.95) return NO;
    size_t count = CGColorGetNumberOfComponents(color);
    if (count != 2 && count != 4) return NO;
    const CGFloat *components = CGColorGetComponents(color);
    for (size_t i = 0; i + 1 < count; i++)
        if (components[i] > 0.05) return NO;
    return YES;
}

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

void MacIslandUpdateScreenGeometry(void) {
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

NSDictionary *MacIslandScreenLayoutForLayer(CALayer *layer) {
    CGSize parent = layer.superlayer.bounds.size;
    for (NSDictionary *layout in [MacIslandScreenGeometry shared].layouts) {
        CGSize size = [layout[@"size"] sizeValue];
        if (fabs(parent.width - size.width) <= 1 && fabs(parent.height - size.height) <= 1) return layout;
    }
    return nil;
}

CGRect MacIslandNativeBodyFrame(MacIslandNativeMaskObserver *observer) {
    CALayer *layer = observer.source;
    CGSize size = observer.nativeBounds.size;
    CGRect box = CGRectMake(-layer.anchorPoint.x * size.width, -layer.anchorPoint.y * size.height,
                            size.width, size.height);
    CGRect frame = CGRectApplyAffineTransform(box, CATransform3DGetAffineTransform(layer.transform));
    return CGRectOffset(frame, observer.nativePosition.x, observer.nativePosition.y);
}

BOOL MacIslandIsNotchBackground(CALayer *layer, MacIslandNativeMaskObserver *observer) {
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
    if (observer) frame = MacIslandNativeBodyFrame(observer);
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

CGFloat MacIslandNativeSceneEdgeCompensation(CALayer *layer) {
    for (CALayer *parent = layer.superlayer; parent; parent = parent.superlayer) {
        id observer = objc_getAssociatedObject(parent, &MacIslandSceneOriginObserverKey);
        SEL pixel = NSSelectorFromString(@"pixel");
        if ([observer respondsToSelector:pixel]) return MAX(0, ((CGFloat (*)(id, SEL))objc_msgSend)(observer, pixel));
    }
    return 0;
}

// Core Animation releases its transaction lock as soon as CALayer.sublayers /
// filters / presentationModifiers returns its internal array wrapper, so an
// unlocked [layer.sublayers copy] on the background DisplayLink thread can race
// with main-thread addSublayer:/removeFromSuperlayer inside __NSArrayI_new.
// Snapshot under +[CATransaction lock] (recursive on main, never nested inside
// MacIslandMaskStateLock).
NSArray<CALayer *> *MacIslandCopyLayerSublayers(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray<CALayer *> *snapshot = [layer.sublayers copy];
    [CATransaction unlock];
    return snapshot;
}

BOOL MacIslandLayerHasSublayers(CALayer *layer) {
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

NSArray *MacIslandCopyLayerModifiers(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray *snapshot = [MacIslandNativeModifierObject(layer, @"presentationModifiers") copy];
    [CATransaction unlock];
    return snapshot;
}

NSArray<NSString *> *MacIslandCopyLayerAnimationKeys(CALayer *layer) {
    if (!layer) return nil;
    [CATransaction lock];
    NSArray<NSString *> *snapshot = [layer.animationKeys copy];
    [CATransaction unlock];
    return snapshot;
}

BOOL MacIslandHasMergeFilters(CALayer *layer) {
    if (!layer) return NO;
    BOOL blur = NO, threshold = NO;
    NSArray *filters = copyLayerFilters(layer);
    for (id filter in filters) {
        id type = MacIslandNativeModifierObject(filter, @"type");
        blur |= [type isEqual:@"gaussianBlur"];
        threshold |= [type isEqual:@"alphaThreshold"];
    }
    return blur && threshold;
}

BOOL MacIslandIsNativeUnionFill(CALayer *layer) {
    return MacIslandIsOpaqueBlack(layer.backgroundColor) && MacIslandHasMergeFilters(layer.superlayer);
}

// Only a secondary opaque input of the same native notch compositor joins
// the primary's transaction. Its path, size, velocity and paint stay native.
BOOL MacIslandIsSecondaryMergeInput(CALayer *layer) {
    return MacIslandIsOpaqueBlack(layer.backgroundColor) && MacIslandHasMergeFilters(layer.superlayer.superlayer) &&
           MacIslandNativeSceneEdgeCompensation(layer) > 0;
}

id MacIslandActiveMergeBlur(CALayer *group) {
    if (!group) return nil;
    id blur = nil;
    BOOL threshold = NO;
    NSArray *filters = copyLayerFilters(group);
    for (id filter in filters) {
        if (!MacIslandNativeModifierEnabled(filter)) continue;
        id type = MacIslandNativeModifierObject(filter, @"type");
        if ([type isEqual:@"alphaThreshold"]) threshold = YES;
        if ([type isEqual:@"gaussianBlur"] && [[filter valueForKey:@"inputRadius"] doubleValue] > 0)
            blur = filter;
    }
    return threshold ? blur : nil;
}

void MacIslandPresentationLayerGeometry(CALayer *layer, CGPoint *originOut, CGSize *sizeOut,
                                        CGPoint *positionOut, CGPoint *anchorOut, CATransform3D *transformOut) {
    CGRect bounds = layer.bounds;
    CGPoint origin = bounds.origin;
    CGSize size = bounds.size;
    CGPoint position = layer.position;
    CGPoint anchor = layer.anchorPoint;
    CATransform3D transform = layer.transform;
    NSArray *modifiers = MacIslandCopyLayerModifiers(layer);
    for (id modifier in modifiers) {
        if (!MacIslandNativeModifierEnabled(modifier)) continue;
        NSString *key = MacIslandNativeModifierObject(modifier, @"keyPath");
        id value = MacIslandNativeModifierObject(modifier, @"value");
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

CGSize MacIslandPaintSize(MacIslandNativeMaskObserver *observer, CGSize size) {
    MacIslandPaintExtensions ext = MacIslandObserverPaintExtensions(observer);
    size.width += 2 * ext.horizontalFlare;
    size.height += ext.topExtension + 2 * ext.pixelInset + ext.bottomExtension;
    return size;
}

CGPoint MacIslandPaintPosition(MacIslandNativeMaskObserver *observer, CGPoint point) {
    MacIslandPaintExtensions ext = MacIslandObserverPaintExtensions(observer);
    CGPoint anchor = observer.source.anchorPoint;
    point.x += (2 * anchor.x - 1) * ext.horizontalFlare;
    point.y += (anchor.y - 1) * ext.topExtension + (2 * anchor.y - 1) * ext.pixelInset +
               anchor.y * ext.bottomExtension;
    return point;
}

CAAnimation *MacIslandAnimationWithoutPillCorners(CAAnimation *animation) {
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        NSMutableArray *children = [NSMutableArray array];
        BOOL changed = NO;
        for (CAAnimation *child in group.animations) {
            CAAnimation *adjusted = MacIslandAnimationWithoutPillCorners(child);
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

void MacIslandObserveNativeAnimations(CALayer *layer) {
    @synchronized (CALayer.class) {
        static NSMutableSet<NSValue *> *methods;
        if (!methods) methods = [NSMutableSet set];
        Method method = class_getInstanceMethod(layer.class, @selector(addAnimation:forKey:));
        if (!method || [methods containsObject:[NSValue valueWithPointer:method]]) return;
        [methods addObject:[NSValue valueWithPointer:method]];
        void (*previous)(id, SEL, CAAnimation *, NSString *) = (void *)method_getImplementation(method);
        IMP implementation = imp_implementationWithBlock(^(CALayer *target, CAAnimation *animation, NSString *key) {
            id association = objc_getAssociatedObject(target, &MacIslandMaskObserverKey);
            MacIslandNativeMaskObserver *observer =
                [association isKindOfClass:MacIslandNativeMaskObserver.class] ? association : nil;
            previous(target, @selector(addAnimation:forKey:),
                     observer.applied ? MacIslandAnimationWithoutPillCorners(animation) : animation, key);
        });
        method_setImplementation(method, implementation);
    }
}
