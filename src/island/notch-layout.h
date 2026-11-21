#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>

__attribute__((visibility("hidden"))) bool MacIslandIsMenuBarAgent(void);
__attribute__((visibility("hidden"))) BOOL MacIslandShortHostAvailable(void);

// The upper shoulder joins the bezel outside the native content area.
static const CGFloat MacIslandNotchFlare = 6;
// Room for the full-height digits drawn above the short activity's controls.
static const CGFloat MacIslandShortContentClearance = 14;
// Keep room for native controls even before the Clock UI provider is patched.
static const CGFloat MacIslandShortPanelClearance = 6;
// AirDropUI's ObstructionClearingWidthLayout sizes vertical share/failure cards to 274pt
// (224pt content + 25pt horizontal margins), while LowersBelowObstructionLayout places
// top icons/previews at CGRectGetMaxY(integratedObstructionRect) - 9pt (tucked for iPhone's
// pill optical gap, which clips 7pt into a 38pt solid MacBook camera bezel).
static const CGFloat MacIslandAirDropCardWidth = 274;
static const CGFloat MacIslandAirDropShoulderSpan = 54;
static const CGFloat MacIslandAirDropObstructionClearance = 16;
// MenuBarAgent's CenterHUD clamps expanded hosted/element containers to 408pt
// (Settings.hostedSceneMetrics.maximumContentWidth) unless overridden.
#define MacIslandHostedMaxContentWidthKey @"HostedSceneMetricsMaximumContentWidth"

static inline BOOL MacIslandScreenNotchCutout(NSScreen *screen, NSRect *cutoutOut) {
    if (!screen) return NO;
    NSRect left = screen.auxiliaryTopLeftArea;
    NSRect right = screen.auxiliaryTopRightArea;
    CGFloat height = screen.safeAreaInsets.top;
    CGFloat width = NSMinX(right) - NSMaxX(left);
    if (height <= 0 || NSIsEmptyRect(left) || NSIsEmptyRect(right) || width <= 0) return NO;
    if (cutoutOut) *cutoutOut = NSMakeRect(NSMaxX(left), NSMaxY(screen.frame) - height, width, height);
    return YES;
}

static inline BOOL MacIslandScreenHasNotch(NSScreen *screen) {
    return MacIslandScreenNotchCutout(screen, NULL);
}

static inline CGFloat MacIslandCenteredDisplayWidth(NSScreen *screen, NSRect cutout) {
    if (!screen) return 0;
    CGFloat center = NSMidX(cutout);
    CGFloat span = 2 * MIN(center - NSMinX(screen.frame), NSMaxX(screen.frame) - center);
    return span > 0 ? span : 0;
}

static inline CGFloat MacIslandExpandedMaxWidth(CGFloat notchWidth, CGFloat centeredDisplayWidth) {
    if (notchWidth <= 0 || centeredDisplayWidth <= 0) return 0;
    return MIN(MAX(notchWidth + 320.0, 408.0), centeredDisplayWidth);
}

static inline CGFloat MacIslandScreenExpandedMaxWidth(NSScreen *screen) {
    NSRect cutout = NSZeroRect;
    if (!MacIslandScreenNotchCutout(screen, &cutout)) return 0;
    return MacIslandExpandedMaxWidth(cutout.size.width, MacIslandCenteredDisplayWidth(screen, cutout));
}

static inline CGFloat MacIslandShortViewportInset(CGFloat cutoutHeight) {
    return cutoutHeight + MacIslandShortContentClearance;
}

static inline NSRect MacIslandMakeShortObstructionSentinel(CGFloat midX, CGFloat cutoutHeight) {
    return NSMakeRect(midX - 0.5, -MacIslandShortViewportInset(cutoutHeight) - 1, 1, 1);
}

static inline BOOL MacIslandIsShortObstructionSentinel(NSRect rect, CGFloat cutoutHeight) {
    return NSEqualSizes(rect.size, NSMakeSize(1, 1)) &&
           fabs(NSMaxY(rect) + MacIslandShortViewportInset(cutoutHeight)) <= 0.01;
}

__attribute__((visibility("hidden"))) NSString *MacIslandAuditLogPath(void);
__attribute__((visibility("hidden"))) id MacIslandAuditNumber(CGFloat value);
__attribute__((visibility("hidden"))) id MacIslandAuditSizeDict(NSSize size);
__attribute__((visibility("hidden"))) id MacIslandAuditRectDict(NSRect rect);
__attribute__((visibility("hidden"))) id MacIslandAuditDataValue(id raw);
__attribute__((visibility("hidden"))) NSString *MacIslandAuditSerialize(NSDictionary *record);
__attribute__((visibility("hidden"))) void MacIslandAuditAppendRecord(NSString *logPath, NSDictionary *record);
