#import "mask-internal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

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
static _Thread_local NSUInteger nativeGroupFlushDepth;

id MacIslandNativeModifierObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

BOOL MacIslandNativeModifierEnabled(id modifier) {
    SEL selector = NSSelectorFromString(@"isEnabled");
    return [modifier respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(modifier, selector);
}

MacIslandNativeMaskObserver *MacIslandModelMaskObserver(CALayer *layer) {
    if (!layer || layer.modelLayer != layer) return nil;
    id value = objc_getAssociatedObject(layer, &MacIslandMaskObserverKey);
    return [value isKindOfClass:MacIslandNativeMaskObserver.class] ? value : nil;
}

static id paintValue(MacIslandModifierBinding *binding, id value) {
    if ([binding.key isEqual:@"cornerRadius"]) return @0;
    if (![value isKindOfClass:NSValue.class]) return value;
    if ([binding.key isEqual:@"bounds.size"] && !strcmp([value objCType], @encode(CGSize)))
        return [NSValue valueWithSize:MacIslandPaintSize(binding.observer, [value sizeValue])];
    if ([binding.key isEqual:@"position"] && !strcmp([value objCType], @encode(CGPoint)))
        return [NSValue valueWithPoint:MacIslandPaintPosition(binding.observer, [value pointValue])];
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
        binding.nativeValue = MacIslandNativeModifierObject(modifier, @"value");
        // A spring may already be moving when Apple attaches its modifier.
        // This pinned build exposes the value getter but only an object ivar
        // for its derivative. Read it once at attachment, never on each flush.
        Ivar velocity = class_getInstanceVariable([modifier class], "_velocity");
        if (velocity && ivar_getTypeEncoding(velocity)[0] == '@')
            binding.nativeVelocity = object_getIvar(modifier, velocity);
        objc_setAssociatedObject(modifier, &modifierBindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSArray *oldBindings = nil;
        os_unfair_lock_lock(&MacIslandMaskStateLock);
        oldBindings = observer->_modifierBindings;
        observer->_modifierBindings = [(oldBindings ?: @[]) arrayByAddingObject:binding];
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        (void)oldBindings;
    }
    id adjusted = paintValue(binding, binding.nativeValue);
    if (adjusted && ![adjusted isEqual:MacIslandNativeModifierObject(modifier, @"value")])
        originalModifierValueVelocity(modifier, NSSelectorFromString(@"setValue:velocity:"), adjusted,
                                      [key isEqual:@"cornerRadius"] && binding.nativeVelocity ? @0 : binding.nativeVelocity);
}

static void unbindModifier(MacIslandModifierBinding *binding) {
    id modifier = binding.modifier;
    if (modifier && objc_getAssociatedObject(modifier, &modifierBindingKey) == binding) {
        objc_setAssociatedObject(modifier, &modifierBindingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        originalModifierValueVelocity(modifier, NSSelectorFromString(@"setValue:velocity:"),
                                      binding.nativeValue, binding.nativeVelocity);
    }
    binding.observer = nil;
}

static void modifierListChanged(CALayer *layer) {
    MacIslandNativeMaskObserver *observer = MacIslandModelMaskObserver(layer);
    if (observer.applied) [observer refreshMask];
    else if (observer) MacIslandSynchronizeNativeMaskGeometry(observer);
    else if (MacIslandHasMergeFilters(layer.superlayer)) {
        NSArray<CALayer *> *children = MacIslandCopyLayerSublayers(layer);
        for (CALayer *child in children) {
            MacIslandNativeMaskObserver *childObserver = MacIslandModelMaskObserver(child);
            if (childObserver) MacIslandSynchronizeNativeMaskGeometry(childObserver);
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

static void removePresentationModifier(CALayer *layer, SEL selector, id modifier) {
    originalRemovePresentationModifier(layer, selector, modifier);
    modifierListChanged(layer);
}

void MacIslandRemoveNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    // Detach all state under the lock, then call out to Core Animation.
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    id size = observer->_nativeMaskSize;
    NSArray *groups = observer->_nativeMaskGroups;
    NSArray *bindings = observer->_modifierBindings;
    CAShapeLayer *maskLayer = observer->_shapeMask;
    observer->_nativeMaskSize = nil;
    observer->_nativeMaskGroups = nil;
    observer->_modifierBindings = nil;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);
    if (size && maskLayer && originalRemovePresentationModifier)
        originalRemovePresentationModifier(maskLayer, NSSelectorFromString(@"removePresentationModifier:"), size);
    for (id group in groups) {
        @synchronized(group) { [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) removeObject:observer]; }
    }
    for (MacIslandModifierBinding *binding in bindings) unbindModifier(binding);
}

void MacIslandSynchronizeNativeMaskGeometry(MacIslandNativeMaskObserver *observer) {
    if (!observer || !originalAddPresentationModifier) return;
    os_unfair_lock_lock(&MacIslandMaskStateLock);
    if (observer->_syncingGeometry) {
        observer->_geometryDirty = YES;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
        return;
    }
    observer->_syncingGeometry = YES;
    observer->_geometryDirty = NO;
    os_unfair_lock_unlock(&MacIslandMaskStateLock);

    NSUInteger passes = 0;
    for (;;) {
        CALayer *source = observer.source;
        BOOL applied = observer.applied;
        BOOL secondary = !applied && source && MacIslandIsSecondaryMergeInput(source);
        BOOL member = applied || secondary;
        NSArray *modifiers = (member && source) ? MacIslandCopyLayerModifiers(source) : nil;

        os_unfair_lock_lock(&MacIslandMaskStateLock);
        NSArray *currentBindings = observer->_modifierBindings;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);

        NSMutableArray *stale = [NSMutableArray array];
        for (MacIslandModifierBinding *binding in currentBindings) {
            if (!applied || !binding.modifier || ![modifiers containsObject:binding.modifier])
                [stale addObject:binding];
        }
        if (stale.count) {
            NSArray *oldBindings = nil;
            os_unfair_lock_lock(&MacIslandMaskStateLock);
            oldBindings = observer->_modifierBindings;
            NSMutableArray *kept = [oldBindings mutableCopy] ?: [NSMutableArray array];
            for (id binding in stale) [kept removeObjectIdenticalTo:binding];
            observer->_modifierBindings = [kept copy];
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            (void)oldBindings;
            for (MacIslandModifierBinding *binding in stale) unbindModifier(binding);
        }
        id size = nil;
        NSMutableArray *groups = [NSMutableArray array];
        for (id modifier in modifiers) {
            NSString *key = MacIslandNativeModifierObject(modifier, @"keyPath");
            if (applied) {
                bindNativeModifier(observer, modifier, key);
                if ([key isEqual:@"bounds.size"] && MacIslandNativeModifierEnabled(modifier) &&
                    ((MacIslandModifierBinding *)objc_getAssociatedObject(modifier, &modifierBindingKey)).observer == observer)
                    size = modifier;
            }
            id group = MacIslandNativeModifierObject(modifier, @"group");
            if (group && ![groups containsObject:group]) [groups addObject:group];
        }
        if (secondary) {
            NSArray *parentModifiers = MacIslandCopyLayerModifiers(source.superlayer);
            for (id modifier in parentModifiers) {
                id group = MacIslandNativeModifierObject(modifier, @"group");
                if (group && ![groups containsObject:group]) [groups addObject:group];
            }
        }
        NSArray *immutableGroups = [groups copy];
        os_unfair_lock_lock(&MacIslandMaskStateLock);
        NSArray *previousGroups = observer->_nativeMaskGroups ?: @[];
        observer->_nativeMaskGroups = immutableGroups;
        id previousSize = observer->_nativeMaskSize;
        BOOL sizeChanged = previousSize != size;
        if (sizeChanged) observer->_nativeMaskSize = size;
        os_unfair_lock_unlock(&MacIslandMaskStateLock);

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

        os_unfair_lock_lock(&MacIslandMaskStateLock);
        if (!observer->_geometryDirty) {
            observer->_syncingGeometry = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            return;
        }
        observer->_geometryDirty = NO;
        if (++passes >= 4) {
            observer->_syncingGeometry = NO;
            os_unfair_lock_unlock(&MacIslandMaskStateLock);
            dispatch_async(dispatch_get_main_queue(), ^{ MacIslandSynchronizeNativeMaskGeometry(observer); });
            return;
        }
        os_unfair_lock_unlock(&MacIslandMaskStateLock);
    }
}

static NSArray *nativeGroupMaskObservers(id group) {
    NSArray *snapshot;
    @synchronized(group) { snapshot = [objc_getAssociatedObject(group, &nativeMaskGroupObserversKey) allObjects]; }
    // Reparenting an entire secondary branch need not notify its leaf.
    for (MacIslandNativeMaskObserver *observer in snapshot)
        if (observer.applied || MacIslandIsSecondaryMergeInput(observer.source)) return snapshot;
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

void MacIslandInstallNativeCornerModifierHooks(void) {
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
