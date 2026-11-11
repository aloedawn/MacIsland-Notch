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
static char shortHostFrameKey, shortTranslationKey, shortClipKey, shortAuditKey;
static void (*nativeHostSetFrame)(NSView *, SEL, NSRect);
static void (*nativeHostLayout)(NSView *, SEL);
static _Thread_local BOOL writingShortFrame;
static atomic_bool shortHostAvailable;
__attribute__((visibility("hidden"))) BOOL MacIslandShortHostAvailable(void) {
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
        CGFloat inset = MacIslandShortViewportInset(cutoutHeight);
        if (MacIslandIsShortObstructionSentinel(rect, cutoutHeight) &&
            fabs(size.height - nativeSize.height) <= 1 && size.height > inset &&
            nativeSize.width >= cutoutWidth) return YES;
    }
    return NO;
}
static NSRect positionedHostFrame(NSView *host, NSRect nativeFrame) {
    NSView *parent = host.superview;
    NSWindow *window = host.window;
    NSScreen *screen = window.screen;
    NSRect cutout = NSZeroRect;
    if (!MacIslandScreenNotchCutout(screen, &cutout) || !parent.isFlipped ||
        fabs(window.frame.size.height - screen.frame.size.height) > 1 ||
        fabs(nativeFrame.size.height - parent.bounds.size.height) > 1 ||
        fabs(nativeFrame.size.width - parent.bounds.size.width) > 1) return nativeFrame;
    CGFloat width = cutout.size.width;
    CGFloat height = cutout.size.height;
    if (nativeFrame.size.width <= width || nativeFrame.size.height <= height) return nativeFrame;
    Class hostingClass = NSClassFromString(@"NSSceneHostingView");
    for (NSView *child in host.subviews) {
        if (![child isKindOfClass:hostingClass]) continue;
        id settings = hostSetting(hostSetting(child, @"scene"), @"settings");
        if (!matchesShortViewport(settings, width, height, nativeFrame.size)) continue;
        CGFloat inset = MacIslandShortViewportInset(height);
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
static NSRect resolvedRequestedHostFrame(NSView *view, NSRect requested) {
    NSValue *saved = objc_getAssociatedObject(view, &shortHostFrameKey);
    if (!saved) return requested;
    NSRect unshifted = saved.rectValue;
    NSRect current = view.frame;
    if (NSEqualRects(requested, current)) return unshifted;
    // Preserve the unshifted vertical span when AppKit reads the already-moved
    // view.frame and updates only horizontal position or width.
    if (fabs(NSMinY(requested) - NSMinY(current)) < 0.5 &&
        fabs(NSHeight(requested) - NSHeight(current)) < 0.5 &&
        NSMinY(current) > NSMinY(unshifted) + 0.5) {
        requested.origin.y = unshifted.origin.y;
        requested.size.height = unshifted.size.height;
    }
    return requested;
}
static void emitShortHostAudit(NSString *auditPath, NSView *view, NSRect requested, NSRect positioned, BOOL adjusted) {
    id client = NSNull.null;
    id elementKind = NSNull.null;
    Class hostingClass = NSClassFromString(@"NSSceneHostingView");
    for (NSView *child in view.subviews) {
        if (![child isKindOfClass:hostingClass]) continue;
        id settings = hostSetting(hostSetting(child, @"scene"), @"settings");
        if (!settings) continue;
        client = MacIslandAuditDataValue(hostSetting(settings, @"clientIdentifier"));
        elementKind = MacIslandAuditDataValue(hostSetting(settings, @"elementKindIdentifier"));
        break;
    }
    NSDictionary *record = @{
        @"event": @"short_host",
        @"client": client,
        @"elementKind": elementKind,
        @"adjusted": @(adjusted),
        @"requestedFrame": MacIslandAuditRectDict(requested),
        @"positionedFrame": MacIslandAuditRectDict(positioned),
    };
    NSString *signature = MacIslandAuditSerialize(record);
    NSString *previous = objc_getAssociatedObject(view, &shortAuditKey);
    if (!signature || [previous isEqualToString:signature]) return;
    objc_setAssociatedObject(view, &shortAuditKey, signature, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MacIslandAuditAppendRecord(auditPath, record);
}
static void setHostFrame(NSView *view, SEL selector, NSRect requested) {
    if (writingShortFrame) { nativeHostSetFrame(view, selector, requested); return; }
    BOOL hadPriorAdjustment = objc_getAssociatedObject(view, &shortHostFrameKey) != nil;
    requested = resolvedRequestedHostFrame(view, requested);
    NSRect frame = positionedHostFrame(view, requested);
    BOOL adjusted = !NSEqualRects(frame, requested);
    objc_setAssociatedObject(view, &shortHostFrameKey, adjusted ? [NSValue valueWithRect:requested] : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    writingShortFrame = YES;
    nativeHostSetFrame(view, selector, frame);
    writingShortFrame = NO;
    alignHostedPresentation(view);
    if (adjusted || hadPriorAdjustment) {
        NSString *auditPath = MacIslandAuditLogPath();
        if (auditPath) emitShortHostAudit(auditPath, view, requested, frame, adjusted);
    }
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
static void installShortHostLayout(NSUInteger attempt) {
    Class cls = NSClassFromString(@"MenuBarCore.SceneHostDisplayItemContainerView");
    if (!cls) {
        int64_t delay = attempt < 100 ? 50 * NSEC_PER_MSEC : attempt < 300 ? 500 * NSEC_PER_MSEC : 5 * NSEC_PER_SEC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            installShortHostLayout(attempt + 1);
        });
        return;
    }
    if (![cls isSubclassOfClass:NSView.class] || nativeHostSetFrame) return;
    Method frame = class_getInstanceMethod(cls, @selector(setFrame:));
    Method layout = class_getInstanceMethod(cls, @selector(layout));
    Method expectedFrame = class_getInstanceMethod(NSView.class, @selector(setFrame:));
    Method expectedLayout = class_getInstanceMethod(NSView.class, @selector(layout));
    if (!frame || !layout || !expectedFrame || !expectedLayout) return;
    if (strcmp(method_getTypeEncoding(frame), method_getTypeEncoding(expectedFrame)) != 0 ||
        strcmp(method_getTypeEncoding(layout), method_getTypeEncoding(expectedLayout)) != 0) return;
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
