#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

__attribute__((visibility("hidden"))) bool MacIslandIsMenuBarAgent(void);
__attribute__((visibility("hidden"))) BOOL MacIslandShortHostAvailable(void);

// The upper shoulder joins the bezel outside the native content area.
static const CGFloat MacIslandNotchFlare = 6;
// Room for the full-height digits drawn above the short activity's controls.
static const CGFloat MacIslandShortContentClearance = 14;
// Keep room for native controls even before the Clock UI provider is patched.
static const CGFloat MacIslandShortPanelClearance = 6;
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

static inline NSString *MacIslandAuditLogPath(void) {
#ifdef MACISLAND_TESTING
    const char *override = getenv("MACISLAND_AUDIT_LOG");
    if (override && override[0] != '\0') return @(override);
#endif
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/MacIsland"];
    NSString *flag = [dir stringByAppendingPathComponent:@"scene-audit.enabled"];
    if (access(flag.fileSystemRepresentation, F_OK) != 0) return nil;
    return [dir stringByAppendingPathComponent:@"scene-audit.jsonl"];
}

static inline id MacIslandAuditNumber(CGFloat value) {
    if (isnan(value)) return @"nan";
    if (!isfinite(value)) return value > 0 ? @"inf" : @"-inf";
    return @(round(value * 1000.0) / 1000.0);
}

static inline id MacIslandAuditSizeDict(NSSize size) {
    return @{@"w": MacIslandAuditNumber(size.width), @"h": MacIslandAuditNumber(size.height)};
}

static inline id MacIslandAuditRectDict(NSRect rect) {
    return @{
        @"x": MacIslandAuditNumber(rect.origin.x),
        @"y": MacIslandAuditNumber(rect.origin.y),
        @"w": MacIslandAuditNumber(rect.size.width),
        @"h": MacIslandAuditNumber(rect.size.height),
    };
}

static inline id MacIslandAuditDataValue(id raw) {
    if (!raw) return NSNull.null;
    if ([raw isKindOfClass:NSString.class]) return raw;
    if ([raw isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) return raw;
        return MacIslandAuditNumber([raw doubleValue]);
    }
    if ([raw isKindOfClass:NSData.class]) {
        NSData *data = (NSData *)raw;
        id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];
        if (json && ([json isKindOfClass:NSString.class] || [json isKindOfClass:NSNumber.class] ||
                     [NSJSONSerialization isValidJSONObject:json])) {
            return json;
        }
        NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return utf8 ?: [data base64EncodedStringWithOptions:0];
    }
    return [raw description] ?: NSNull.null;
}

static inline NSString *MacIslandAuditSerialize(NSDictionary *record) {
    if (!record || ![NSJSONSerialization isValidJSONObject:record]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static inline void MacIslandAuditAppendRecord(NSString *logPath, NSDictionary *record) {
    if (!logPath || !record) return;
    NSMutableDictionary *stamped = [record mutableCopy];
    stamped[@"ts"] = MacIslandAuditNumber([NSDate.date timeIntervalSince1970]);
    if (![NSJSONSerialization isValidJSONObject:stamped]) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:stamped options:NSJSONWritingSortedKeys error:NULL];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size < 8 * 1024 * 1024) {
        const uint8_t *bytes = line.bytes;
        size_t remaining = line.length;
        while (remaining > 0) {
            ssize_t written = write(fd, bytes, remaining);
            if (written > 0) {
                bytes += written;
                remaining -= (size_t)written;
            } else if (written < 0 && errno == EINTR) {
                continue;
            } else {
                break;
            }
        }
    }
    close(fd);
}
