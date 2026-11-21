#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdbool.h>
#include <stdio.h>

bool MacIslandIsMenuBarAgent(void) { return false; }

extern void MacIslandInstallMaskHooksForTesting(NSArray<NSDictionary *> *layouts);
extern void MacIslandInstallTopHitHooksForTesting(void);
extern void MacIslandSetTopHitTestWindows(NSArray<NSWindow *> *windows);
extern void MacIslandSetTopHitInvertColorsForTesting(BOOL enabled);
extern void MacIslandScanTopHitForTesting(void);
extern void MacIslandTopHitStatsForTesting(NSUInteger *coveredOut, NSUInteger *stripsOut,
                                           NSUInteger *redirectsOut, CGPoint *lastPointOut);

@interface MBGated_TopHitLayer : CALayer
@end
@implementation MBGated_TopHitLayer
@end

@interface TopHitTestWindow : NSWindow
@end
@implementation TopHitTestWindow
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen {
    (void)screen;
    return frameRect;
}
@end

@interface TopHitTestView : NSView
@property(nonatomic) NSUInteger receivedClicks;
@property(nonatomic) NSUInteger gestureTriggers;
@property(nonatomic) CGPoint lastClickPoint;
@end
@implementation TopHitTestView
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}
- (void)handleTap:(NSGestureRecognizer *)sender {
    _gestureTriggers++;
    _lastClickPoint = [sender locationInView:nil];
}
- (void)mouseDown:(NSEvent *)event {
    _receivedClicks++;
    _lastClickPoint = event.locationInWindow;
}
- (void)mouseDragged:(NSEvent *)event {
    _receivedClicks++;
    _lastClickPoint = event.locationInWindow;
}
- (void)mouseUp:(NSEvent *)event {
    _receivedClicks++;
    _lastClickPoint = event.locationInWindow;
}
@end

static id makeFilter(NSString *name) {
    Class cls = NSClassFromString(@"CAFilter");
    SEL sel = NSSelectorFromString(@"filterWithType:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, name);
}

static BOOL layerHasChildNamed(CALayer *layer, NSString *name) {
    for (CALayer *child in layer.sublayers) {
        if ([child.name isEqualToString:name]) return YES;
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];

        NSArray<NSDictionary *> *layouts = @[
            @{
                @"size": [NSValue valueWithSize:NSMakeSize(1800, 1169)],
                @"height": @(38.0),
                @"left": @(790.0),
                @"right": @(1010.0),
                @"pixel": @(0.5),
                @"bottomSnap": @(0.1),
            }
        ];
        MacIslandInstallMaskHooksForTesting(layouts);
        MacIslandInstallTopHitHooksForTesting();

        TopHitTestWindow *islandWindow =
            [[TopHitTestWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1800, 1169)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        TopHitTestWindow *menuBarWindow =
            [[TopHitTestWindow alloc] initWithContentRect:NSMakeRect(0, 1131, 1800, 38)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        TopHitTestView *islandView = [[TopHitTestView alloc] initWithFrame:NSMakeRect(0, 0, 1800, 1169)];
        TopHitTestView *menuBarView = [[TopHitTestView alloc] initWithFrame:NSMakeRect(0, 0, 1800, 38)];
        islandView.wantsLayer = YES;
        menuBarView.wantsLayer = YES;
        islandWindow.contentView = islandView;
        menuBarWindow.contentView = menuBarView;
        [islandWindow orderFront:nil];
        [menuBarWindow orderFront:nil];
        if (!NSEqualRects(islandWindow.frame, NSMakeRect(0, 0, 1800, 1169)) ||
            !NSEqualRects(menuBarWindow.frame, NSMakeRect(0, 1131, 1800, 38))) {
            fprintf(stderr, "unexpected test window frames\n");
            return 1;
        }

        CALayer *root = islandWindow.contentView.layer;
        root.geometryFlipped = YES;
        root.bounds = CGRectMake(0, 0, 1800, 1169);

        // 1. Rounded island container touching top edge (flipped=YES top = 0)
        CALayer *roundedContainer = [CALayer layer];
        roundedContainer.masksToBounds = YES;
        roundedContainer.cornerRadius = 18.0;
        roundedContainer.bounds = CGRectMake(0, 0, 260, 44);
        roundedContainer.position = CGPointMake(600, 22);
        id invertFilter = makeFilter(@"colorInvertDisplayAware");
        id blurFilter = makeFilter(@"gaussianBlur");
        if (invertFilter && blurFilter) {
            roundedContainer.filters = @[invertFilter, blurFilter];
        } else if (invertFilter) {
            roundedContainer.filters = @[invertFilter];
        }
        [root addSublayer:roundedContainer];

        CALayer *roundedHit = [CALayer layer];
        roundedHit.frame = roundedContainer.bounds;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(roundedHit, NSSelectorFromString(@"setHitTestsAsOpaque:"), YES);
        [roundedContainer addSublayer:roundedHit];

        // 2. Flat-top notch-masked container via mask.m (cornerRadius -> 0 after MBGated_ attach)
        MBGated_TopHitLayer *notchedContainer = [MBGated_TopHitLayer layer];
        notchedContainer.name = @"SimpleViewDisplayItem-NotchContainer";
        notchedContainer.masksToBounds = YES;
        notchedContainer.anchorPoint = CGPointMake(0.5, 0.5);
        notchedContainer.bounds = CGRectMake(0, 0, 300, 38);
        notchedContainer.position = CGPointMake(900, 19);
        if (invertFilter) notchedContainer.filters = @[invertFilter];
        [root addSublayer:notchedContainer];
        notchedContainer.cornerRadius = 19.0; // activates MacIslandNativeMaskObserver

        CALayer *notchedHit = [CALayer layer];
        notchedHit.frame = notchedContainer.bounds;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(notchedHit, NSSelectorFromString(@"setHitTestsAsOpaque:"), YES);
        [notchedContainer addSublayer:notchedHit];

        // 3. Detached circular pill (38x38, cr=19) touching top edge
        CALayer *circleContainer = [CALayer layer];
        circleContainer.masksToBounds = YES;
        circleContainer.cornerRadius = 19.0;
        circleContainer.bounds = CGRectMake(0, 0, 38, 38);
        circleContainer.position = CGPointMake(1037, 19);
        [root addSublayer:circleContainer];

        CALayer *circleHit = [CALayer layer];
        circleHit.frame = circleContainer.bounds;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(circleHit, NSSelectorFromString(@"setHitTestsAsOpaque:"), YES);
        [circleContainer addSublayer:circleHit];

        MacIslandSetTopHitTestWindows(@[islandWindow]);
        MacIslandSetTopHitInvertColorsForTesting(NO);
        [CATransaction flush];

        NSUInteger covered = 0, strips = 0, redirects = 0;
        CGPoint lastPt = CGPointZero;
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);

        if (covered != 3 || strips != 0) {
            fprintf(stderr, "expected covered=3 strips=0, got covered=%lu strips=%lu\n",
                    (unsigned long)covered, (unsigned long)strips);
            return 2;
        }
        if (!layerHasChildNamed(roundedHit, @"MacIslandTopHitUnderlay") ||
            !layerHasChildNamed(notchedHit, @"MacIslandTopHitUnderlay") ||
            !layerHasChildNamed(circleHit, @"MacIslandTopHitUnderlay")) {
            fprintf(stderr, "missing underlay on hit layer\n");
            return 3;
        }
        CALayer *stripHost = islandWindow.contentView.superview.layer ?: root;
        if (layerHasChildNamed(stripHost, @"MacIslandTopHitStrip") ||
            layerHasChildNamed(root, @"MacIslandTopHitStrip")) {
            fprintf(stderr, "unexpected top strip on root or superview layer\n");
            return 4;
        }
        if (invertFilter && (roundedContainer.filters.count != (blurFilter ? 1u : 0u) ||
                             notchedContainer.filters.count != 0)) {
            fprintf(stderr, "colorInvertDisplayAware was not stripped cleanly\n");
            return 6;
        }

        // Test Invert Colors toggle ON -> restores filters & removes underlays/strips
        MacIslandSetTopHitInvertColorsForTesting(YES);
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        CALayer *superviewLayer = islandWindow.contentView.superview.layer;
        if (covered != 0 || strips != 0 ||
            layerHasChildNamed(roundedHit, @"MacIslandTopHitUnderlay") ||
            layerHasChildNamed(root, @"MacIslandTopHitStrip") ||
            (superviewLayer && layerHasChildNamed(superviewLayer, @"MacIslandTopHitStrip"))) {
            fprintf(stderr, "invert colors toggle did not clean up top hit layers\n");
            return 7;
        }
        if (invertFilter && notchedContainer.filters.count != 1) {
            fprintf(stderr, "invert colors toggle did not restore container filters\n");
            return 8;
        }

        // Re-enable top-hit and check visibility gating when notchedContainer hides
        MacIslandSetTopHitInvertColorsForTesting(NO);
        notchedContainer.hidden = YES;
        MacIslandScanTopHitForTesting();
        NSEvent *hiddenTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                location:NSMakePoint(900, 38)
                                           modifierFlags:0
                                               timestamp:0.8
                                            windowNumber:menuBarWindow.windowNumber
                                                 context:nil
                                             eventNumber:0
                                              clickCount:1
                                                pressure:1.0];
        [menuBarWindow sendEvent:hiddenTop];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (strips != 0 || menuBarView.receivedClicks != 1 ||
            islandView.receivedClicks != 0 || redirects != 0) {
            fprintf(stderr, "hidden container top click did not stay on menuBar (strips=%lu menuBar=%lu island=%lu redirects=%lu)\n",
                    (unsigned long)strips,
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)islandView.receivedClicks,
                    (unsigned long)redirects);
            return 13;
        }
        notchedContainer.hidden = NO;
        MacIslandScanTopHitForTesting();

        // Click on menuBarWindow at top row inside notchedContainer (x=900, screen y=1169 => menuBar y=38)
        NSEvent *downTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                              location:NSMakePoint(900, 38)
                                         modifierFlags:0
                                             timestamp:1.0
                                          windowNumber:menuBarWindow.windowNumber
                                               context:nil
                                           eventNumber:1
                                            clickCount:1
                                              pressure:1.0];
        NSEvent *dragTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                              location:NSMakePoint(902, 38)
                                         modifierFlags:0
                                             timestamp:1.1
                                          windowNumber:menuBarWindow.windowNumber
                                               context:nil
                                           eventNumber:2
                                            clickCount:1
                                              pressure:1.0];
        NSEvent *upTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                            location:NSMakePoint(902, 38)
                                       modifierFlags:0
                                           timestamp:1.2
                                        windowNumber:menuBarWindow.windowNumber
                                             context:nil
                                         eventNumber:3
                                          clickCount:1
                                            pressure:0.0];
        [menuBarWindow sendEvent:downTop];
        [menuBarWindow sendEvent:dragTop];
        [menuBarWindow sendEvent:upTop];

        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (islandView.receivedClicks != 3 || menuBarView.receivedClicks != 1 || redirects != 3) {
            fprintf(stderr, "top-edge redirect failed (island=%lu menuBar=%lu redirects=%lu)\n",
                    (unsigned long)islandView.receivedClicks,
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects);
            return 9;
        }
        if (islandView.lastClickPoint.y > 1167.501) {
            fprintf(stderr, "top-edge event y was not clamped to <= height - 1.5 (got %.2f)\n",
                    islandView.lastClickPoint.y);
            return 10;
        }

        // Direct top-edge click on islandWindow at (900, 1169.0) -> clamped to <= height - 1.5
        NSEvent *directTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                location:NSMakePoint(900, 1169.0)
                                           modifierFlags:0
                                               timestamp:1.5
                                            windowNumber:islandWindow.windowNumber
                                                 context:nil
                                             eventNumber:4
                                              clickCount:1
                                                pressure:1.0];
        [islandWindow sendEvent:directTop];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (islandView.receivedClicks != 4 || redirects != 3 || islandView.lastClickPoint.y > 1167.501) {
            fprintf(stderr, "direct top-edge clamp failed (island=%lu redirects=%lu y=%.2f)\n",
                    (unsigned long)islandView.receivedClicks,
                    (unsigned long)redirects,
                    islandView.lastClickPoint.y);
            return 11;
        }

        // Click on menuBarWindow at top row inside detached circular pill (x=1037, screen y=1169 => menuBar y=38)
        NSEvent *circleTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                location:NSMakePoint(1037, 38)
                                           modifierFlags:0
                                               timestamp:1.8
                                            windowNumber:menuBarWindow.windowNumber
                                                 context:nil
                                             eventNumber:5
                                              clickCount:1
                                                pressure:1.0];
        [menuBarWindow sendEvent:circleTop];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (islandView.receivedClicks != 5 || menuBarView.receivedClicks != 1 ||
            redirects != 4 || islandView.lastClickPoint.y > 1167.501) {
            fprintf(stderr, "detached circle top-edge redirect failed (island=%lu menuBar=%lu redirects=%lu y=%.2f)\n",
                    (unsigned long)islandView.receivedClicks,
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects,
                    islandView.lastClickPoint.y);
            return 14;
        }

        // Click outside island horizontal span (x=200, y=37.5) -> stays on menuBarWindow
        NSEvent *outside = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                              location:NSMakePoint(200, 37.5)
                                         modifierFlags:0
                                             timestamp:2.0
                                          windowNumber:menuBarWindow.windowNumber
                                               context:nil
                                           eventNumber:6
                                            clickCount:1
                                              pressure:1.0];
        [menuBarWindow sendEvent:outside];
        if (menuBarView.receivedClicks != 2 || islandView.receivedClicks != 5) {
            fprintf(stderr, "outside top click was erroneously redirected (menuBar=%lu island=%lu)\n",
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)islandView.receivedClicks);
            return 12;
        }

        // Click on outer edge of detached circular pill (x=1020, y=38) -> redirects to islandWindow
        NSEvent *circleEdgeTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                    location:NSMakePoint(1020, 38)
                                               modifierFlags:0
                                                   timestamp:2.2
                                                windowNumber:menuBarWindow.windowNumber
                                                     context:nil
                                                 eventNumber:7
                                                  clickCount:1
                                                    pressure:1.0];
        [menuBarWindow sendEvent:circleEdgeTop];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (islandView.receivedClicks != 6 || menuBarView.receivedClicks != 2 ||
            redirects != 5 || islandView.lastClickPoint.y > 1167.501) {
            fprintf(stderr, "circle outer-edge redirect failed (island=%lu menuBar=%lu redirects=%lu y=%.2f)\n",
                    (unsigned long)islandView.receivedClicks,
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects,
                    islandView.lastClickPoint.y);
            return 15;
        }

        // Hover/spring overshoot (notchedContainer shifted up by 0.8pt so minY=-0.8) -> strips=0 & click redirects
        notchedContainer.position = CGPointMake(900, 18.2);
        [CATransaction flush];
        MacIslandScanTopHitForTesting();
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (strips != 0 || layerHasChildNamed(stripHost, @"MacIslandTopHitStrip") ||
            layerHasChildNamed(root, @"MacIslandTopHitStrip")) {
            fprintf(stderr, "unexpected top strip during top overshoot (strips=%lu)\n",
                    (unsigned long)strips);
            return 16;
        }
        NSEvent *overshootTop = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                   location:NSMakePoint(900, 38)
                                              modifierFlags:0
                                                  timestamp:2.4
                                               windowNumber:menuBarWindow.windowNumber
                                                    context:nil
                                                eventNumber:8
                                                 clickCount:1
                                                   pressure:1.0];
        [menuBarWindow sendEvent:overshootTop];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (islandView.receivedClicks != 7 || menuBarView.receivedClicks != 2 ||
            redirects != 6 || islandView.lastClickPoint.y > 1167.501) {
            fprintf(stderr, "overshoot top-edge redirect failed (island=%lu menuBar=%lu redirects=%lu y=%.2f)\n",
                    (unsigned long)islandView.receivedClicks,
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects,
                    islandView.lastClickPoint.y);
            return 17;
        }
        notchedContainer.position = CGPointMake(900, 19.0);
        [CATransaction flush];
        MacIslandScanTopHitForTesting();

        // [NSApp sendEvent:] routing with interactive NSView carrying NSClickGestureRecognizer
        // at x=1100..1180, y=0..38 (flipped inside islandView, NO coveredIslands layer entry)
        TopHitTestView *interactiveView = [[TopHitTestView alloc] initWithFrame:NSMakeRect(1100, 0, 80, 38)];
        NSClickGestureRecognizer *tap =
            [[NSClickGestureRecognizer alloc] initWithTarget:interactiveView action:@selector(handleTap:)];
        [interactiveView addGestureRecognizer:tap];
        [islandView addSubview:interactiveView];

        NSEvent *appDown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                              location:NSMakePoint(1140, 38)
                                         modifierFlags:0
                                             timestamp:2.6
                                          windowNumber:menuBarWindow.windowNumber
                                               context:nil
                                           eventNumber:9
                                            clickCount:1
                                              pressure:1.0];
        NSEvent *appDrag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                              location:NSMakePoint(1142, 38)
                                         modifierFlags:0
                                             timestamp:2.7
                                          windowNumber:menuBarWindow.windowNumber
                                               context:nil
                                           eventNumber:10
                                            clickCount:1
                                              pressure:1.0];
        NSEvent *appUp = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                            location:NSMakePoint(1142, 38)
                                       modifierFlags:0
                                           timestamp:2.8
                                        windowNumber:menuBarWindow.windowNumber
                                             context:nil
                                         eventNumber:11
                                          clickCount:1
                                            pressure:0.0];
        [NSApp sendEvent:appDown];
        [NSApp sendEvent:appDrag];
        [NSApp sendEvent:appUp];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (interactiveView.gestureTriggers != 1 || menuBarView.receivedClicks != 2 ||
            redirects != 9 || lastPt.y > 1167.501 || interactiveView.lastClickPoint.y > 1167.501) {
            fprintf(stderr, "NSApp sendEvent interactive redirect failed (gest=%lu menuBar=%lu redirects=%lu gestPt=(%.1f,%.1f) lastPt=(%.1f,%.1f))\n",
                    (unsigned long)interactiveView.gestureTriggers,
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects,
                    interactiveView.lastClickPoint.x, interactiveView.lastClickPoint.y,
                    lastPt.x, lastPt.y);
            return 18;
        }

        // Empty gap x=1075 (between circle 1018..1056 and interactiveView 1100..1180) via [NSApp sendEvent:]
        NSEvent *appGap = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                             location:NSMakePoint(1075, 38)
                                        modifierFlags:0
                                            timestamp:3.0
                                         windowNumber:menuBarWindow.windowNumber
                                              context:nil
                                          eventNumber:12
                                           clickCount:1
                                             pressure:1.0];
        [NSApp sendEvent:appGap];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (menuBarView.receivedClicks != 3 || redirects != 9 || interactiveView.gestureTriggers != 1) {
            fprintf(stderr, "gap click via NSApp was erroneously redirected (menuBar=%lu redirects=%lu gest=%lu)\n",
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects,
                    (unsigned long)interactiveView.gestureTriggers);
            return 19;
        }

        // Click in 6pt shoulder flare outside notchedContainer native body (750..1050, flared 744..1056)
        NSEvent *flareMargin = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                  location:NSMakePoint(746, 38)
                                             modifierFlags:0
                                                 timestamp:3.2
                                              windowNumber:menuBarWindow.windowNumber
                                                   context:nil
                                               eventNumber:13
                                                clickCount:1
                                                  pressure:1.0];
        [NSApp sendEvent:flareMargin];
        MacIslandTopHitStatsForTesting(&covered, &strips, &redirects, &lastPt);
        if (menuBarView.receivedClicks != 4 || redirects != 9 || interactiveView.gestureTriggers != 1) {
            fprintf(stderr, "flare-margin click was erroneously redirected (menuBar=%lu redirects=%lu gest=%lu)\n",
                    (unsigned long)menuBarView.receivedClicks,
                    (unsigned long)redirects,
                    (unsigned long)interactiveView.gestureTriggers);
            return 20;
        }

        printf("top_hit=ok covered=%lu strips=%lu redirects=%lu clamped_y=%.1f\n",
               (unsigned long)covered, (unsigned long)strips, (unsigned long)redirects,
               interactiveView.lastClickPoint.y);
        return 0;
    }
}
