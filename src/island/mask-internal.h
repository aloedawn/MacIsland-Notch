#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "notch-layout.h"
#include <os/lock.h>

// Strict leaf lock guarding in-memory observer state only. Never hold across
// Core Animation, AppKit, KVO registration, or @synchronized calls.
__attribute__((visibility("hidden"))) extern os_unfair_lock MacIslandMaskStateLock;
__attribute__((visibility("hidden"))) extern _Thread_local const void *MacIslandActiveModelWriteObserver;

__attribute__((visibility("hidden"))) extern char MacIslandMaskObserverKey;
__attribute__((visibility("hidden"))) extern char MacIslandSceneOriginObserverKey;
__attribute__((visibility("hidden"))) extern char MacIslandMergeVisibilityKey;
__attribute__((visibility("hidden"))) extern char MacIslandParentGeometryKey;
__attribute__((visibility("hidden"))) extern char MacIslandSceneLayersKey;

__attribute__((visibility("hidden"))) extern void (*MacIslandOriginalSetHidden)(id, SEL, BOOL);
__attribute__((visibility("hidden"))) extern void (*MacIslandOriginalSetCornerRadius)(id, SEL, CGFloat);
__attribute__((visibility("hidden"))) extern void (*MacIslandBaseSetBounds)(id, SEL, CGRect);
__attribute__((visibility("hidden"))) extern void (*MacIslandBaseSetPosition)(id, SEL, CGPoint);

// AppKit screen information is captured on the main thread. Native layer
// updates may arrive on MenuBarAgent's background animation thread.
@interface MacIslandScreenGeometry : NSObject
@property(atomic, copy) NSArray<NSDictionary *> *layouts;
+ (instancetype)shared;
@end

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
- (void)endVisibilityHold:(BOOL)applyHide;
- (void)updateVisibilityHold;
- (BOOL)holdVisibilityInUnion:(CALayer *)group blur:(id)blur;
@end

static inline MacIslandPaintExtensions MacIslandObserverPaintExtensions(MacIslandNativeMaskObserver *observer) {
    MacIslandPaintExtensions ext = {0, 0, 0, 0};
    if (!observer) return ext;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    ext = observer->_extensions;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    return ext;
}

static inline void MacIslandSetObserverPaintExtensions(MacIslandNativeMaskObserver *observer, MacIslandPaintExtensions ext) {
    if (!observer) return;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    observer->_extensions = ext;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
}

static inline MacIslandNativeMaskObserver *MacIslandObserverMergeInput(MacIslandNativeMaskObserver *observer) {
    if (!observer) return nil;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    MacIslandNativeMaskObserver *input = observer->_mergeInput;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    return input;
}

// Presentation modifier helpers (mask-modifiers.m)
__attribute__((visibility("hidden"))) MacIslandNativeMaskObserver *MacIslandModelMaskObserver(CALayer *layer);

// Geometry & layer inspection helpers (mask-geometry.m)
__attribute__((visibility("hidden"))) CGPathRef MacIslandNotchMaskPathAtTop(CGSize size, CGFloat top, BOOL outwardShoulders, CGFloat scaleY);
__attribute__((visibility("hidden"))) BOOL MacIslandIsOpaqueBlack(CGColorRef color);
__attribute__((visibility("hidden"))) void MacIslandUpdateScreenGeometry(void);
__attribute__((visibility("hidden"))) NSDictionary *MacIslandScreenLayoutForLayer(CALayer *layer);
__attribute__((visibility("hidden"))) CGRect MacIslandNativeBodyFrame(MacIslandNativeMaskObserver *observer);
__attribute__((visibility("hidden"))) BOOL MacIslandIsNotchBackground(CALayer *layer, MacIslandNativeMaskObserver *observer);
__attribute__((visibility("hidden"))) CGFloat MacIslandNativeSceneEdgeCompensation(CALayer *layer);
__attribute__((visibility("hidden"))) NSArray<CALayer *> *MacIslandCopyLayerSublayers(CALayer *layer);
__attribute__((visibility("hidden"))) BOOL MacIslandLayerHasSublayers(CALayer *layer);
__attribute__((visibility("hidden"))) NSArray *MacIslandCopyLayerModifiers(CALayer *layer);
__attribute__((visibility("hidden"))) NSArray<NSString *> *MacIslandCopyLayerAnimationKeys(CALayer *layer);
__attribute__((visibility("hidden"))) BOOL MacIslandHasMergeFilters(CALayer *layer);
__attribute__((visibility("hidden"))) BOOL MacIslandIsNativeUnionFill(CALayer *layer);
__attribute__((visibility("hidden"))) BOOL MacIslandIsSecondaryMergeInput(CALayer *layer);
__attribute__((visibility("hidden"))) id MacIslandActiveMergeBlur(CALayer *group);
__attribute__((visibility("hidden"))) void MacIslandPresentationLayerGeometry(
    CALayer *layer, CGPoint *originOut, CGSize *sizeOut,
    CGPoint *positionOut, CGPoint *anchorOut, CATransform3D *transformOut);
__attribute__((visibility("hidden"))) CGSize MacIslandPaintSize(MacIslandNativeMaskObserver *observer, CGSize size);
__attribute__((visibility("hidden"))) CGPoint MacIslandPaintPosition(MacIslandNativeMaskObserver *observer, CGPoint point);
__attribute__((visibility("hidden"))) CAAnimation *MacIslandAnimationWithoutPillCorners(CAAnimation *animation);
__attribute__((visibility("hidden"))) void MacIslandObserveNativeAnimations(CALayer *layer);

// Presentation modifier & group flush hooks (mask-modifiers.m)
__attribute__((visibility("hidden"))) id MacIslandNativeModifierObject(id object, NSString *name);
__attribute__((visibility("hidden"))) BOOL MacIslandNativeModifierEnabled(id modifier);
__attribute__((visibility("hidden"))) MacIslandNativeMaskObserver *MacIslandModelMaskObserver(CALayer *layer);
__attribute__((visibility("hidden"))) void MacIslandSynchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer);
__attribute__((visibility("hidden"))) void MacIslandRemoveNativeMaskGeometry(MacIslandNativeMaskObserver *observer);
__attribute__((visibility("hidden"))) void MacIslandInstallNativeCornerModifierHooks(void);
