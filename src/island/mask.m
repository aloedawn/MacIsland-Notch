#import "mask-internal.h"
#import <objc/runtime.h>

os_unfair_lock MacIslandMaskStateLock = OS_UNFAIR_LOCK_INIT;
_Thread_local const void *MacIslandActiveModelWriteObserver;

char MacIslandMaskObserverKey;
char MacIslandSceneOriginObserverKey;
char MacIslandMergeVisibilityKey;
char MacIslandParentGeometryKey;
char MacIslandSceneLayersKey;

void (*MacIslandOriginalSetHidden)(id, SEL, BOOL);
void (*MacIslandOriginalSetCornerRadius)(id, SEL, CGFloat);
void (*MacIslandBaseSetBounds)(id, SEL, CGRect);
void (*MacIslandBaseSetPosition)(id, SEL, CGPoint);

static void (*baseSetSublayerTransform)(id, SEL, CATransform3D);

typedef NS_ENUM(NSUInteger, MacIslandSingleLayerKVOKind) {
    MacIslandSingleLayerKVOParentBounds = 0,
    MacIslandSingleLayerKVOMergeSceneSublayers = 1,
};

// An opaque material can draw the shoulder without smoothing it a second
// time through the native merge filter. Never hold MacIslandMaskStateLock across
// any CALayer, CAFilter, or KVO call: Core Animation invokes KVO while holding
// its layer/transaction locks on main, while DisplayLink flushes run on the
// background animation thread.
static BOOL hasOpaqueContourPeer(MacIslandNativeMaskObserver *input) {
    CALayer *source = input.source;
    CALayer *unionLayer = source ? source.superlayer : nil;
    MacIslandPaintExtensions ext = MacIslandObserverPaintExtensions(input);
    CALayer *scene = (unionLayer && ext.topExtension > 0) ? unionLayer.superlayer : nil;
    [input reconcileMergeScene:scene];

    os_unfair_lock_lock(&MacIslandMaskStateLock);
    MacIslandNativeMaskObserver *previous = input->_contourPeer;
    BOOL prevHeldHere = (previous != nil && previous->_desiredHeldBlur != nil &&
                         previous->_desiredHeldUnion == unionLayer && previous->_mergeInput == input);
    os_unfair_lock_unlock(&MacIslandMaskStateLock);

    id blur = unionLayer ? MacIslandActiveMergeBlur(unionLayer) : nil;
    // The two model layers finish their bounds and position writes separately.
    // Once the peer is held for this merge filter, the identified material stays
    // responsible until this same filter hands off. Revalidate ownership, not
    // model endpoints.
    if (scene && previous && prevHeldHere && previous.applied && blur != nil) {
        CALayer *heldMaterial = previous.source;
        CAShapeLayer *prevMask = [previous shapeMask];
        if (heldMaterial && heldMaterial.superlayer == scene &&
            prevMask && heldMaterial.mask == prevMask && !heldMaterial.hidden &&
            heldMaterial.opacity >= 1 && !heldMaterial.contents && !MacIslandLayerHasSublayers(heldMaterial) &&
            MacIslandIsOpaqueBlack(heldMaterial.backgroundColor)) {
            return YES;
        }
    }

    MacIslandNativeMaskObserver *selected = nil;
    if (scene && unionLayer) {
        CGRect body = [unionLayer convertRect:MacIslandNativeBodyFrame(input) toLayer:scene];
        NSArray<CALayer *> *sublayers = MacIslandCopyLayerSublayers(scene);
        for (CALayer *layer in sublayers) {
            if (layer.superlayer != scene || !MacIslandIsOpaqueBlack(layer.backgroundColor)) continue;
            id association = objc_getAssociatedObject(layer, &MacIslandMaskObserverKey);
            if (![association isKindOfClass:MacIslandNativeMaskObserver.class]) continue;
            MacIslandNativeMaskObserver *peer = association;
            CAShapeLayer *peerMask = [peer shapeMask];
            if (!peer.applied || !peerMask || layer.mask != peerMask) continue;
            CGRect r = MacIslandNativeBodyFrame(peer);
            // Native material and opaque merge input differ by a backing-pixel inset.
            if (fabs(CGRectGetMinX(r) - CGRectGetMinX(body)) > 1 ||
                fabs(CGRectGetMaxX(r) - CGRectGetMaxX(body)) > 1 ||
                fabs(CGRectGetMinY(r) - CGRectGetMinY(body)) > 1 ||
                fabs(CGRectGetMaxY(r) - CGRectGetMaxY(body)) > 1) continue;
            os_unfair_lock_lock(&MacIslandMaskStateLock);
            peer->_mergeInput = input;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            if (layer.opacity >= 1 && !layer.contents && !MacIslandLayerHasSublayers(layer) &&
                (!layer.hidden || (blur && !source.hidden && source.opacity >= 1 &&
                                    !unionLayer.hidden && unionLayer.opacity >= 1))) {
                selected = peer;
                break;
            }
        }
    }

    CALayer *selectedSource = selected ? selected.source : nil;
    BOOL needHoldSelected = (selected != nil && blur != nil && selectedSource != nil);

    os_unfair_lock_lock(&MacIslandMaskStateLock);
    MacIslandNativeMaskObserver *oldPeer = input->_contourPeer;
    input->_contourPeer = selected;
    MacIslandNativeMaskObserver *releasePeer =
        (oldPeer != nil && oldPeer != selected && oldPeer->_desiredHeldBlur != nil) ? oldPeer : nil;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);

    if (needHoldSelected) {
        // Hold the opaque shoulder owner whenever a merge blur is active so
        // intermediate model updates keep the crisp outer notch contour.
        if ([selected holdVisibilityInUnion:unionLayer blur:blur] && selectedSource.hidden) {
            MacIslandOriginalSetHidden(selectedSource, @selector(setHidden:), NO);
        }
    } else if (selected && blur == nil) {
        [selected endVisibilityHold:YES];
    }
    if (releasePeer) [releasePeer endVisibilityHold:YES];
    return selected != nil;
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
                  @"superlayer", @"name", @"hidden", @"opacity", @"backgroundColor",
                  @"shadowColor", @"shadowOpacity", @"masksToBounds", @"mask"];
        for (NSString *key in _keys)
            [layer addObserver:self forKeyPath:key options:0 context:&MacIslandMaskObserverKey];
        MacIslandObserveNativeAnimations(layer);
        [self refresh];
    }
    return self;
}

- (CAShapeLayer *)shapeMask {
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    CAShapeLayer *mask = _shapeMask;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
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
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    if (!_shapeMask) _shapeMask = created;
    existing = _shapeMask;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    return existing;
}

- (void)reconcileSingleLayerKVO:(MacIslandSingleLayerKVOKind)kind target:(CALayer *)target {
    NSString *keyPath = kind == MacIslandSingleLayerKVOParentBounds ? @"bounds" : @"sublayers";
    void *context = kind == MacIslandSingleLayerKVOParentBounds ? &MacIslandParentGeometryKey : &MacIslandSceneLayersKey;

    os_unfair_lock_lock(&MacIslandMaskStateLock);
    BOOL *reconciling = kind == MacIslandSingleLayerKVOParentBounds ? &_reconcilingParentKVO : &_reconcilingMergeSceneKVO;
    if (kind == MacIslandSingleLayerKVOParentBounds) _desiredObservedParent = target;
    else _desiredMergeScene = target;
    if (*reconciling) {
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        return;
    }
    *reconciling = YES;
    for (;;) {
        CALayer *current = kind == MacIslandSingleLayerKVOParentBounds ? _registeredObservedParent : _registeredMergeScene;
        CALayer *desired = kind == MacIslandSingleLayerKVOParentBounds ? _desiredObservedParent : _desiredMergeScene;
        if (current == desired) {
            *reconciling = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            return;
        }
        if (kind == MacIslandSingleLayerKVOParentBounds) _registeredObservedParent = desired;
        else _registeredMergeScene = desired;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        if (current) [current removeObserver:self forKeyPath:keyPath context:context];
        if (desired) [desired addObserver:self forKeyPath:keyPath options:0 context:context];
        os_unfair_lock_lock(&MacIslandMaskStateLock);
    }
}

- (void)reconcileObservedParent:(CALayer *)parent {
    [self reconcileSingleLayerKVO:MacIslandSingleLayerKVOParentBounds target:parent];
}

- (void)reconcileMergeScene:(CALayer *)scene {
    [self reconcileSingleLayerKVO:MacIslandSingleLayerKVOMergeSceneSublayers target:scene];
}

- (void)reconcileHeldVisibilityKVO {
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    if (_reconcilingHeldKVO) {
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
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
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            return;
        }
        _registeredHeldUnion = desiredUnion;
        _registeredHeldBlur = desiredBlur;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        if (currentBlur != desiredBlur) {
            if (currentBlur) {
                [currentBlur removeObserver:self forKeyPath:@"inputRadius" context:&MacIslandMergeVisibilityKey];
                [currentBlur removeObserver:self forKeyPath:@"enabled" context:&MacIslandMergeVisibilityKey];
            }
            if (desiredBlur) {
                [desiredBlur addObserver:self forKeyPath:@"inputRadius" options:0 context:&MacIslandMergeVisibilityKey];
                [desiredBlur addObserver:self forKeyPath:@"enabled" options:0 context:&MacIslandMergeVisibilityKey];
            }
        }
        if (currentUnion != desiredUnion) {
            if (currentUnion) [currentUnion removeObserver:self forKeyPath:@"filters" context:&MacIslandMergeVisibilityKey];
            if (desiredUnion) [desiredUnion addObserver:self forKeyPath:@"filters" options:0 context:&MacIslandMergeVisibilityKey];
        }
        os_unfair_lock_lock(&MacIslandMaskStateLock);
    }
}

- (void)refresh {
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    if (_refreshing) {
        _refreshDirty = YES;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        return;
    }
    _refreshing = YES;
    _refreshDirty = NO;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);

    NSUInteger passes = 0;
    for (;;) {
        CALayer *source = self.source;
        // Native children may settle before their display parent gets its size.
        // Eligibility must follow that existing parent's layout too.
        CALayer *parent = source ? source.superlayer : nil;
        [self reconcileObservedParent:parent];

        CAShapeLayer *currentMask = [self shapeMask];
        BOOL ownsMask = currentMask && source && source.mask == currentMask;
        BOOL eligible = source && (self.nativeRadius > 0 || self.applied) && MacIslandIsNotchBackground(source, self) &&
                        (ownsMask || !source.mask);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (eligible) {
            // Apple's opaque fill is inset by one physical pixel inside its
            // material. Remove only that vertical inset on the existing fill.
            CGFloat inset = 0;
            if ([source.name hasPrefix:@"SimpleViewDisplayItem-"] &&
                MacIslandIsOpaqueBlack(source.backgroundColor) && CATransform3DIsIdentity(source.transform)) {
                CGFloat nativeTop = self.nativePosition.y - source.anchorPoint.y * self.nativeBounds.size.height;
                for (NSDictionary *layout in [MacIslandScreenGeometry shared].layouts) {
                    CGSize size = [layout[@"size"] sizeValue];
                    if (fabs(source.superlayer.bounds.size.width - size.width) > 1 ||
                        fabs(source.superlayer.bounds.size.height - size.height) > 1) continue;
                    CGFloat pixel = [layout[@"pixel"] doubleValue];
                    if (MacIslandIsNativeUnionFill(source) || (nativeTop > 0 && fabs(nativeTop - pixel) < 0.05)) inset = pixel;
                }
            }
            CGFloat flare = MacIslandNotchFlare;
            // Reach the camera housing's last physical row in scaled modes.
            CGFloat bottom = MacIslandNativeSceneEdgeCompensation(source) +
                             [MacIslandScreenLayoutForLayer(source)[@"bottomSnap"] doubleValue];
            // Build 26C5035r uses a 6 2/3-point native merge blur. Its
            // three-radius sampling support must continue above the bezel.
            // Reserve it even while idle so native spring geometry never jumps
            // when the filter switches on or off. This is outside the display.
            CGFloat top = MacIslandIsNativeUnionFill(source) ? 20 : 0;
            CGRect bounds = self.nativeBounds;
            CGPoint position = self.nativePosition;
            // The shoulder sits outside the native body, rather than consuming
            // its absorption area. Offset the bounds origin so existing children
            // keep their native coordinates when the paint surface grows.
            bounds.origin.x -= flare;
            bounds.origin.y -= top;
            MacIslandSetObserverPaintExtensions(self, (MacIslandPaintExtensions){inset, flare, bottom, top});
            bounds.size = MacIslandPaintSize(self, bounds.size);
            position = MacIslandPaintPosition(self, position);
            CAShapeLayer *maskLayer = [self ensureShapeMask];
            const void *previousWriteObserver = MacIslandActiveModelWriteObserver;
            MacIslandActiveModelWriteObserver = (__bridge const void *)self;
            MacIslandBaseSetBounds(source, @selector(setBounds:), bounds);
            MacIslandBaseSetPosition(source, @selector(setPosition:), position);
            MacIslandOriginalSetCornerRadius(source, @selector(setCornerRadius:), 0);
            source.mask = maskLayer;
            MacIslandActiveModelWriteObserver = previousWriteObserver;
            BOOL newlyApplied = !self.applied;
            self.applied = YES;
            if (newlyApplied) {
                NSArray<NSString *> *animKeys = MacIslandCopyLayerAnimationKeys(source);
                for (NSString *key in animKeys) {
                    CAAnimation *animation = [source animationForKey:key];
                    CAAnimation *adjusted = MacIslandAnimationWithoutPillCorners(animation);
                    if (adjusted != animation) [source addAnimation:adjusted forKey:key];
                }
            }
            [self refreshMask];
        } else if (self.applied) {
            os_unfair_lock_lock(&MacIslandMaskStateLock);
            MacIslandNativeMaskObserver *peer = _contourPeer;
            _contourPeer = nil;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            [self reconcileMergeScene:nil];
            [peer endVisibilityHold:YES];
            [self endVisibilityHold:YES];
            if (source) {
                const void *previousWriteObserver = MacIslandActiveModelWriteObserver;
                MacIslandActiveModelWriteObserver = (__bridge const void *)self;
                MacIslandBaseSetBounds(source, @selector(setBounds:), self.nativeBounds);
                MacIslandBaseSetPosition(source, @selector(setPosition:), self.nativePosition);
                if (ownsMask) source.mask = nil;
                MacIslandOriginalSetCornerRadius(source, @selector(setCornerRadius:), self.nativeRadius);
                MacIslandActiveModelWriteObserver = previousWriteObserver;
            }
            self.applied = NO;
        }
        if (!self.applied) MacIslandSynchronizeNativeMaskGeometry(self);
        // Re-evaluate immediately if the native material is hidden or removed.
        [MacIslandObserverMergeInput(self) refreshMask];
        [CATransaction commit];

        os_unfair_lock_lock(&MacIslandMaskStateLock);
        if (!_refreshDirty) {
            _refreshing = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            return;
        }
        _refreshDirty = NO;
        if (++passes >= 4) {
            _refreshing = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
            return;
        }
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
    }
}

- (void)refreshMask {
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    if (_maskRefreshing) {
        _maskDirty = YES;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        return;
    }
    _maskRefreshing = YES;
    _maskDirty = NO;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);

    NSUInteger passes = 0;
    for (;;) {
        CALayer *source = self.source;
        if (!self.applied) {
            if (source && MacIslandIsSecondaryMergeInput(source)) {
                MacIslandSynchronizeNativeMaskGeometry(self);
            }
        } else {
            CAShapeLayer *maskLayer = [self shapeMask];
            if (source && maskLayer && source.mask == maskLayer) {
                MacIslandSynchronizeNativeMaskGeometry(self);
                CGPoint origin, position, anchor;
                CGSize size;
                CATransform3D transform;
                MacIslandPresentationLayerGeometry(source, &origin, &size, &position, &anchor, &transform);
                if (isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0) {
                    CGFloat scaleY = hypot(transform.m21, transform.m22);
                    CGFloat top = MAX(0, -(position.y - anchor.y * size.height)) / MAX(scaleY, 0.001);
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    maskLayer.bounds = (CGRect){CGPointZero, size};
                    maskLayer.position = origin;
                    maskLayer.contentsScale = MAX(source.contentsScale, 2);
                    BOOL peerOwnsShoulder = hasOpaqueContourPeer(self);
                    CGPathRef path = MacIslandNotchMaskPathAtTop(size, top, !peerOwnsShoulder, scaleY);
                    maskLayer.path = path;
                    CGPathRelease(path);
                    [CATransaction commit];
                }
            }
        }

        os_unfair_lock_lock(&MacIslandMaskStateLock);
        if (!_maskDirty) {
            _maskRefreshing = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            return;
        }
        _maskDirty = NO;
        if (++passes >= 4) {
            _maskRefreshing = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshMask]; });
            return;
        }
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
    }
}

// Apple hides its existing primary material partway through closing, before
// the merge kernel is disabled. Preserve this previously-visible paint until
// the native filter handoff; a new show request cancels the pending hide.
- (void)endVisibilityHold:(BOOL)applyHide {
    id oldBlur = nil;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    oldBlur = _desiredHeldBlur;
    BOOL hadHold = (oldBlur != nil || _desiredHeldUnion != nil);
    _desiredHeldBlur = nil;
    _desiredHeldUnion = nil;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    (void)oldBlur;
    if (!hadHold) return;

    [self reconcileHeldVisibilityKVO];
    if (!applyHide) return;
    CALayer *source = self.source;
    if (!source) return;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    BOOL shouldHide = (_desiredHeldBlur == nil) && self.nativeHidden;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    if (shouldHide) MacIslandOriginalSetHidden(source, @selector(setHidden:), YES);
}

- (BOOL)holdVisibilityInUnion:(CALayer *)group blur:(id)blur {
    if (!group || !blur) return NO;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    if (!_desiredHeldBlur) {
        _desiredHeldUnion = group;
        _desiredHeldBlur = blur;
    }
    BOOL held = (_desiredHeldBlur != nil);
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    [self reconcileHeldVisibilityKVO];
    return held;
}

- (void)updateVisibilityHold {
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    id currentBlur = _desiredHeldBlur;
    CALayer *unionLayer = _desiredHeldUnion;
    MacIslandNativeMaskObserver *input = _mergeInput;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    if (!currentBlur) return;

    id blur = unionLayer ? MacIslandActiveMergeBlur(unionLayer) : nil;
    if (blur == currentBlur) return;
    if (blur) {
        id oldBlur = nil;
        os_unfair_lock_lock(&MacIslandMaskStateLock);
        if (_desiredHeldBlur == currentBlur && _desiredHeldUnion == unionLayer) {
            oldBlur = _desiredHeldBlur;
            _desiredHeldBlur = blur;
        }
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
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

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == &MacIslandMergeVisibilityKey) { [self updateVisibilityHold]; return; }
    if (context == &MacIslandSceneLayersKey) { [self refreshMask]; return; }
    if (context == &MacIslandParentGeometryKey) { [self refresh]; return; }
    if (context != &MacIslandMaskObserverKey) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (MacIslandActiveModelWriteObserver == (__bridge const void *)self) return;
    if ([keyPath isEqualToString:@"hidden"] || [keyPath isEqualToString:@"opacity"]) {
        [MacIslandObserverMergeInput(self) refreshMask];
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
    if (scene) [scene removeObserver:self forKeyPath:@"sublayers" context:&MacIslandSceneLayersKey];

    [peer endVisibilityHold:YES];

    id heldBlur = _registeredHeldBlur;
    CALayer *heldUnion = _registeredHeldUnion;
    _registeredHeldBlur = nil;
    _desiredHeldBlur = nil;
    _registeredHeldUnion = nil;
    _desiredHeldUnion = nil;
    if (heldBlur) {
        [heldBlur removeObserver:self forKeyPath:@"inputRadius" context:&MacIslandMergeVisibilityKey];
        [heldBlur removeObserver:self forKeyPath:@"enabled" context:&MacIslandMergeVisibilityKey];
    }
    if (heldUnion) [heldUnion removeObserver:self forKeyPath:@"filters" context:&MacIslandMergeVisibilityKey];

    CALayer *parent = _registeredObservedParent;
    _registeredObservedParent = nil;
    _desiredObservedParent = nil;
    if (parent) [parent removeObserver:self forKeyPath:@"bounds" context:&MacIslandParentGeometryKey];

    MacIslandRemoveNativeMaskGeometry(self);
}
@end

static void setNativeMaterialHidden(CALayer *layer, SEL selector, BOOL hidden) {
    if (layer.modelLayer == layer) {
        id association = objc_getAssociatedObject(layer, &MacIslandMaskObserverKey);
        if ([association isKindOfClass:MacIslandNativeMaskObserver.class]) {
            MacIslandNativeMaskObserver *peer = association;
            peer.nativeHidden = hidden;
            if (!hidden) {
                [peer endVisibilityHold:NO];
            } else {
                os_unfair_lock_lock(&MacIslandMaskStateLock);
                MacIslandNativeMaskObserver *input = peer->_mergeInput;
                BOOL isContourPeer = (input != nil && input->_contourPeer == peer);
                os_unfair_lock_unlock(&MacIslandMaskStateLock);

                CALayer *inputSource = isContourPeer ? input.source : nil;
                CALayer *group = inputSource ? inputSource.superlayer : nil;
                CAShapeLayer *peerMask = [peer shapeMask];
                if (isContourPeer && input.applied && peer.applied && group &&
                    !layer.hidden && layer.opacity >= 1 && !layer.contents && !MacIslandLayerHasSublayers(layer) &&
                    MacIslandIsOpaqueBlack(layer.backgroundColor) && peerMask && layer.mask == peerMask &&
                    layer.superlayer == group.superlayer) {
                    id blur = MacIslandActiveMergeBlur(group);
                    if (blur && [peer holdVisibilityInUnion:group blur:blur]) {
                        [input refreshMask];
                        return;
                    }
                }
            }
        }
    }
    MacIslandOriginalSetHidden(layer, selector, hidden);
}

static void setCornerRadius(CALayer *layer, SEL selector, CGFloat radius) {
    // Core Animation calls setters while applying modifiers to presentation
    // copies too. Never register KVO or create a mask on those derived layers.
    // Preserve the model's notch treatment without mutating the model or
    // recursively requesting another presentation copy.
    CALayer *model = layer.modelLayer;
    if (model != layer) {
        id modelAssociation = objc_getAssociatedObject(model, &MacIslandMaskObserverKey);
        MacIslandNativeMaskObserver *observer =
            [modelAssociation isKindOfClass:MacIslandNativeMaskObserver.class] ? modelAssociation : nil;
        MacIslandOriginalSetCornerRadius(
            layer, selector, observer.applied && MacIslandIsNotchBackground(model, observer) ? 0 : radius);
        return;
    }
    id association = objc_getAssociatedObject(layer, &MacIslandMaskObserverKey);
    if ([association isKindOfClass:MacIslandNativeMaskObserver.class]) {
        MacIslandNativeMaskObserver *observer = association;
        MacIslandOriginalSetCornerRadius(layer, selector, radius);
        observer.nativeRadius = radius;
        [observer refresh];
        return;
    }
    MacIslandOriginalSetCornerRadius(layer, selector, radius);
    if (radius <= 0 || association ||
        ![NSStringFromClass(layer.class) hasPrefix:@"MBGated_"]) return;
    objc_setAssociatedObject(layer, &MacIslandMaskObserverKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Install before the native creation transaction commits. Deferring to
    // main leaves a newly created expansion background briefly pill-shaped.
    MacIslandNativeMaskObserver *observer = [[MacIslandNativeMaskObserver alloc] initWithLayer:layer];
    objc_setAssociatedObject(layer, &MacIslandMaskObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

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
        [layer addObserver:self forKeyPath:@"sublayerTransform" options:0 context:&MacIslandSceneOriginObserverKey];
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
    if (context != &MacIslandSceneOriginObserverKey) {
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
    id observer = objc_getAssociatedObject(layer, &MacIslandMaskObserverKey);
    if ([observer isKindOfClass:MacIslandNativeMaskObserver.class]) [observer refresh];
    NSArray<CALayer *> *children = MacIslandCopyLayerSublayers(layer);
    for (CALayer *child in children) refreshNativeBackgroundCoverage(child);
}

static void refreshNativeSceneOrigin(NSWindow *window) {
    if (![window isKindOfClass:NSWindow.class]) return;
    CALayer *root = window.contentView.layer;
    if (!root) return;
    MacIslandSceneOriginObserver *observer = objc_getAssociatedObject(root, &MacIslandSceneOriginObserverKey);
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
        objc_setAssociatedObject(root, &MacIslandSceneOriginObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat pixel = eligible ? 0.5 / MAX(screen.backingScaleFactor, 1) : 0;
    if (observer.pixel != pixel) { observer.pixel = pixel; [observer refresh]; refreshNativeBackgroundCoverage(root); }
}

static void refreshAllNativeSceneOrigins(void) {
    for (NSWindow *window in NSApp.windows) refreshNativeSceneOrigin(window);
}

static void installMaskLayerHooks(void) {
    if (MacIslandOriginalSetCornerRadius) return;
    Method method = class_getInstanceMethod(CALayer.class, @selector(setCornerRadius:));
    MacIslandOriginalSetCornerRadius = (void *)method_getImplementation(method);
    MacIslandBaseSetBounds = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setBounds:)));
    MacIslandBaseSetPosition = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setPosition:)));
    baseSetSublayerTransform = (void *)method_getImplementation(class_getInstanceMethod(CALayer.class, @selector(setSublayerTransform:)));
    Method visibility = class_getInstanceMethod(CALayer.class, @selector(setHidden:));
    MacIslandOriginalSetHidden = (void *)method_getImplementation(visibility);
    method_setImplementation(visibility, (IMP)setNativeMaterialHidden);
    method_setImplementation(method, (IMP)setCornerRadius);
    MacIslandInstallNativeCornerModifierHooks();
}

#ifdef MACISLAND_TESTING
void MacIslandInstallMaskHooksForTesting(NSArray<NSDictionary *> *layouts) {
    [MacIslandScreenGeometry shared].layouts = layouts;
    installMaskLayerHooks();
}
void MacIslandSetSceneEdgeCompensationForTesting(CALayer *root, CGFloat pixel) {
    MacIslandSceneOriginObserver *observer = objc_getAssociatedObject(root, &MacIslandSceneOriginObserverKey);
    if (!observer) {
        observer = [[MacIslandSceneOriginObserver alloc] initWithLayer:root];
        objc_setAssociatedObject(root, &MacIslandSceneOriginObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        MacIslandUpdateScreenGeometry();
        refreshAllNativeSceneOrigins();
        for (NSNotificationName name in @[NSWindowDidUpdateNotification, NSWindowDidResizeNotification, NSWindowDidChangeScreenNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) { refreshNativeSceneOrigin(notification.object); }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                       object:nil queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(__unused NSNotification *notification) {
            MacIslandUpdateScreenGeometry();
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
