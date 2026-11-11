#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "notch-layout.h"
#include <string.h>
#include <stdlib.h>

typedef NSRect (*FrameGetter)(id, SEL);

static FrameGetter originalDefaultFrame;
static FrameGetter originalHardwareFrame;
static FrameGetter originalMinimalFrame;

static NSRect physicalNotch(NSScreen *screen) {
    NSRect cutout = NSZeroRect;
    return MacIslandScreenNotchCutout(screen, &cutout) ? cutout : NSZeroRect;
}

static NSRect defaultFrame(id screen, SEL selector) {
    NSRect notch = physicalNotch(screen);
    return NSIsEmptyRect(notch) ? originalDefaultFrame(screen, selector) : notch;
}

static NSRect hardwareFrame(id screen, SEL selector) {
    NSRect notch = physicalNotch(screen);
    return NSIsEmptyRect(notch) ? originalHardwareFrame(screen, selector) : notch;
}

static NSRect minimalFrame(id screen, SEL selector) {
    NSRect notch = physicalNotch(screen);
    return NSIsEmptyRect(notch) ? originalMinimalFrame(screen, selector) : notch;
}

__attribute__((constructor))
static void installNotchGeometry(void) {
    if (!MacIslandIsMenuBarAgent()) return;
    Class screen = NSScreen.class;
    Method defaultMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDDefaultFrame"));
    Method hardwareMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDHardwareFrame"));
    Method minimalMethod = class_getInstanceMethod(screen, NSSelectorFromString(@"_centerHUDMinimalObstructionFrame"));
    // Comparing the private methods to one another would miss a shared ABI change.
    Method frameMethod = class_getInstanceMethod(screen, @selector(frame));
    if (!frameMethod || !defaultMethod || !hardwareMethod || !minimalMethod) return;
    const char *expected = method_getTypeEncoding(frameMethod);
    if (strcmp(expected, method_getTypeEncoding(defaultMethod)) != 0 ||
        strcmp(expected, method_getTypeEncoding(hardwareMethod)) != 0 ||
        strcmp(expected, method_getTypeEncoding(minimalMethod)) != 0) return;
    originalDefaultFrame = (FrameGetter)method_getImplementation(defaultMethod);
    originalHardwareFrame = (FrameGetter)method_getImplementation(hardwareMethod);
    originalMinimalFrame = (FrameGetter)method_getImplementation(minimalMethod);
    method_setImplementation(defaultMethod, (IMP)defaultFrame);
    method_setImplementation(hardwareMethod, (IMP)hardwareFrame);
    method_setImplementation(minimalMethod, (IMP)minimalFrame);
}
