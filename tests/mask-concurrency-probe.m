#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdbool.h>

bool MacIslandIsMenuBarAgent(void) { return false; }

extern void MacIslandInstallMaskHooksForTesting(NSArray<NSDictionary *> *layouts);
extern void MacIslandSetSceneEdgeCompensationForTesting(CALayer *root, CGFloat pixel);

@interface MBGated_TestLayer : CALayer
@end
@implementation MBGated_TestLayer
@end

static id makeCAFilter(NSString *type) {
    Class cls = NSClassFromString(@"CAFilter");
    SEL sel = NSSelectorFromString(@"filterWithType:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(cls, sel, type);
}

static id makeModifierGroup(NSUInteger capacity) {
    Class cls = NSClassFromString(@"CAPresentationModifierGroup");
    SEL sel = NSSelectorFromString(@"groupWithCapacity:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(cls, sel, capacity);
}

static id makePresentationModifier(NSString *keyPath, id value, id group) {
    Class cls = NSClassFromString(@"CAPresentationModifier");
    SEL initSel = NSSelectorFromString(@"initWithKeyPath:initialValue:additive:group:");
    if (!cls || ![cls instancesRespondToSelector:initSel]) return nil;
    id alloced = [cls alloc];
    return ((id (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(alloced, initSel, keyPath, value, NO, group);
}

int main(void) {
    @autoreleasepool {
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

        CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 1);

        [NSApplication sharedApplication];
        NSWindow *hostWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1800, 1169)
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
        hostWindow.contentView.wantsLayer = YES;

        MBGated_TestLayer *root = [MBGated_TestLayer layer];
        root.bounds = CGRectMake(0, 0, 1800, 1169);
        root.anchorPoint = CGPointZero;
        root.position = CGPointZero;
        hostWindow.contentView.layer = root;
        MacIslandSetSceneEdgeCompensationForTesting(root, 0.25);

        MBGated_TestLayer *scene = [MBGated_TestLayer layer];
        scene.bounds = CGRectMake(0, 0, 1800, 1169);
        scene.anchorPoint = CGPointZero;
        scene.position = CGPointZero;
        [root addSublayer:scene];

        // Primary unblurred material peer directly in scene
        MBGated_TestLayer *peer = [MBGated_TestLayer layer];
        peer.name = @"SimpleViewDisplayItem-Material";
        peer.backgroundColor = black;
        peer.anchorPoint = CGPointMake(0.5, 0.5);
        peer.bounds = CGRectMake(0, 0, 220, 38);
        peer.position = CGPointMake(900, 19);
        [scene addSublayer:peer];
        peer.cornerRadius = 19;

        // Union group with gaussianBlur + alphaThreshold
        MBGated_TestLayer *unionLayer = [MBGated_TestLayer layer];
        unionLayer.bounds = CGRectMake(0, 0, 1800, 1169);
        unionLayer.anchorPoint = CGPointZero;
        unionLayer.position = CGPointZero;
        id blur = makeCAFilter(@"gaussianBlur");
        id threshold = makeCAFilter(@"alphaThreshold");
        if (blur) {
            [blur setValue:@(6.6667) forKey:@"inputRadius"];
            [blur setValue:@YES forKey:@"enabled"];
        }
        if (threshold) {
            [threshold setValue:@YES forKey:@"enabled"];
        }
        if (blur && threshold) {
            unionLayer.filters = @[blur, threshold];
        }
        [scene addSublayer:unionLayer];

        // Primary union fill inside unionLayer
        MBGated_TestLayer *primary = [MBGated_TestLayer layer];
        primary.name = @"SimpleViewDisplayItem-Union";
        primary.backgroundColor = black;
        primary.anchorPoint = CGPointMake(0.5, 0.5);
        primary.bounds = CGRectMake(0, 0, 220, 38);
        primary.position = CGPointMake(900, 19);
        [unionLayer addSublayer:primary];
        primary.cornerRadius = 19;

        // Secondary merge input inside unionLayer + matching fallback in scene
        MBGated_TestLayer *secBranch = [MBGated_TestLayer layer];
        secBranch.bounds = CGRectMake(0, 0, 1800, 1169);
        secBranch.anchorPoint = CGPointZero;
        secBranch.position = CGPointZero;
        [unionLayer addSublayer:secBranch];

        MBGated_TestLayer *secLeaf = [MBGated_TestLayer layer];
        secLeaf.name = @"SimpleViewDisplayItem-Secondary";
        secLeaf.backgroundColor = black;
        secLeaf.anchorPoint = CGPointMake(0.5, 0.5);
        secLeaf.bounds = CGRectMake(0, 0, 38, 38);
        secLeaf.position = CGPointMake(1032, 19);
        [secBranch addSublayer:secLeaf];
        secLeaf.cornerRadius = 19;

        MBGated_TestLayer *fallbackBranch = [MBGated_TestLayer layer];
        fallbackBranch.bounds = CGRectMake(0, 0, 1800, 1169);
        fallbackBranch.anchorPoint = CGPointZero;
        fallbackBranch.position = CGPointZero;
        [scene addSublayer:fallbackBranch];

        MBGated_TestLayer *fallbackLeaf = [MBGated_TestLayer layer];
        fallbackLeaf.name = @"SimpleViewDisplayItem-Fallback";
        fallbackLeaf.backgroundColor = black;
        fallbackLeaf.anchorPoint = CGPointMake(0.5, 0.5);
        fallbackLeaf.bounds = CGRectMake(0, 0, 38, 38);
        fallbackLeaf.position = CGPointMake(1032, 19);
        [fallbackBranch addSublayer:fallbackLeaf];
        fallbackLeaf.cornerRadius = 19;

        id group = makeModifierGroup(16);
        id primarySizeMod = makePresentationModifier(@"bounds.size", [NSValue valueWithSize:NSMakeSize(220, 38)], group);
        id primaryPosMod = makePresentationModifier(@"position", [NSValue valueWithPoint:NSMakePoint(900, 19)], group);
        id primaryCornerMod = makePresentationModifier(@"cornerRadius", @(19.0), group);
        id secPosMod = makePresentationModifier(@"position", [NSValue valueWithPoint:NSMakePoint(1032, 19)], group);

        SEL addModSel = NSSelectorFromString(@"addPresentationModifier:");
        if (group && [primary respondsToSelector:addModSel]) {
            if (primarySizeMod) ((void (*)(id, SEL, id))objc_msgSend)(primary, addModSel, primarySizeMod);
            if (primaryPosMod) ((void (*)(id, SEL, id))objc_msgSend)(primary, addModSel, primaryPosMod);
            if (primaryCornerMod) ((void (*)(id, SEL, id))objc_msgSend)(primary, addModSel, primaryCornerMod);
            if (secPosMod) ((void (*)(id, SEL, id))objc_msgSend)(secLeaf, addModSel, secPosMod);
        }

        [CATransaction flush];

        if (![primary.mask isKindOfClass:CAShapeLayer.class] || !((CAShapeLayer *)primary.mask).path) {
            fprintf(stderr, "primary mask missing before stress loop\n");
            CGColorRelease(black);
            return 2;
        }
        if (![peer.mask isKindOfClass:CAShapeLayer.class] || !((CAShapeLayer *)peer.mask).path) {
            fprintf(stderr, "peer mask missing before stress loop\n");
            CGColorRelease(black);
            return 3;
        }

        static atomic_bool running = true;
        atomic_store(&running, true);
        dispatch_semaphore_t bgDone = dispatch_semaphore_create(0);
        SEL flushSel = NSSelectorFromString(@"flushWithTargetTime:");
        SEL setValVelSel = NSSelectorFromString(@"setValue:velocity:");

        // Background animation thread simulating com.apple.MenuBar.BackgroundAnimation DisplayLink
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            double t = CACurrentMediaTime();
            NSUInteger tick = 0;
            while (atomic_load(&running)) {
                @autoreleasepool {
                    CGFloat extraW = (tick % 40) * 2.0;
                    CGFloat secX = 1008.0 + (tick % 24) * 1.5;
                    if (primarySizeMod && [primarySizeMod respondsToSelector:setValVelSel]) {
                        ((void (*)(id, SEL, id, id))objc_msgSend)(
                            primarySizeMod, setValVelSel,
                            [NSValue valueWithSize:NSMakeSize(220 + extraW, 38)], nil);
                    }
                    if (secPosMod && [secPosMod respondsToSelector:setValVelSel]) {
                        ((void (*)(id, SEL, id, id))objc_msgSend)(
                            secPosMod, setValVelSel,
                            [NSValue valueWithPoint:NSMakePoint(secX, 19)], nil);
                    }
                    if (group && [group respondsToSelector:flushSel]) {
                        t += 1.0 / 120.0;
                        ((void (*)(id, SEL, double))objc_msgSend)(group, flushSel, t);
                    }
                    tick++;
                }
            }
            dispatch_semaphore_signal(bgDone);
        });

        // Main thread hammering CA::Transaction::commit/flush + KVO + visibility/opacity/filter churn
        for (NSUInteger i = 0; i < 800; i++) {
            @autoreleasepool {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                CGFloat width = 220.0 + (i % 30) * 3.0;
                primary.bounds = CGRectMake(0, 0, width, 38);
                primary.position = CGPointMake(900, 19);
                peer.bounds = CGRectMake(0, 0, width, 38);
                peer.position = CGPointMake(900, 19);
                peer.hidden = (i % 5 == 0);
                secLeaf.position = CGPointMake(1005 + (i % 25) * 1.5, 19);
                fallbackLeaf.position = secLeaf.position;
                secLeaf.opacity = (i % 7 == 0) ? 0.85f : 1.0f;
                if (blur && (i % 11 == 0)) {
                    [blur setValue:((i % 22 == 0) ? @(0.0) : @(6.6667)) forKey:@"inputRadius"];
                }
                if (i % 17 == 0) {
                    MBGated_TestLayer *ephemeral = [MBGated_TestLayer layer];
                    ephemeral.name = @"SimpleViewDisplayItem-Ephemeral";
                    ephemeral.backgroundColor = black;
                    ephemeral.bounds = CGRectMake(0, 0, 220, 38);
                    ephemeral.position = CGPointMake(900, 19);
                    [scene addSublayer:ephemeral];
                    ephemeral.cornerRadius = 19;
                    [ephemeral removeFromSuperlayer];
                }
                [CATransaction commit];
                [CATransaction flush];
            }
        }

        atomic_store(&running, false);
        if (dispatch_semaphore_wait(bgDone, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "background animation thread deadlocked\n");
            CGColorRelease(black);
            return 4;
        }

        peer.hidden = NO;
        if (blur) [blur setValue:@(6.6667) forKey:@"inputRadius"];
        primary.bounds = CGRectMake(0, 0, 220, 38);
        primary.position = CGPointMake(900, 19);
        [CATransaction flush];

        if (![primary.mask isKindOfClass:CAShapeLayer.class] || !((CAShapeLayer *)primary.mask).path) {
            fprintf(stderr, "primary mask corrupted after stress loop\n");
            CGColorRelease(black);
            return 5;
        }

        CGColorRelease(black);
        printf("mask_concurrency=ok\n");
        return 0;
    }
}
