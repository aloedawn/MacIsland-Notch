#import "safearea-internal.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *MacIslandAuditLogPath(void) {
#ifdef MACISLAND_TESTING
    const char *override = getenv("MACISLAND_AUDIT_LOG");
    if (override && override[0] != '\0') return @(override);
#endif
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/MacIsland"];
    NSString *flag = [dir stringByAppendingPathComponent:@"scene-audit.enabled"];
    if (access(flag.fileSystemRepresentation, F_OK) != 0) return nil;
    return [dir stringByAppendingPathComponent:@"scene-audit.jsonl"];
}

id MacIslandAuditNumber(CGFloat value) {
    if (isnan(value)) return @"nan";
    if (!isfinite(value)) return value > 0 ? @"inf" : @"-inf";
    return @(round(value * 1000.0) / 1000.0);
}

id MacIslandAuditSizeDict(NSSize size) {
    return @{@"w": MacIslandAuditNumber(size.width), @"h": MacIslandAuditNumber(size.height)};
}

id MacIslandAuditRectDict(NSRect rect) {
    return @{
        @"x": MacIslandAuditNumber(rect.origin.x),
        @"y": MacIslandAuditNumber(rect.origin.y),
        @"w": MacIslandAuditNumber(rect.size.width),
        @"h": MacIslandAuditNumber(rect.size.height),
    };
}

id MacIslandAuditDataValue(id raw) {
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

NSString *MacIslandAuditSerialize(NSDictionary *record) {
    if (!record || ![NSJSONSerialization isValidJSONObject:record]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

void MacIslandAuditAppendRecord(NSString *logPath, NSDictionary *record) {
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

static NSString *auditLayoutModeName(id rawMode) {
    if (![rawMode isKindOfClass:NSNumber.class]) return nil;
    switch ([rawMode integerValue]) {
        case 0: return @"none";
        case 1: return @"minimal";
        case 2: return @"compact";
        case 3: return @"expanded";
        default: return [NSString stringWithFormat:@"mode_%ld", (long)[rawMode integerValue]];
    }
}

static id auditMarginsDict(NSDictionary *decoded) {
    if (!decoded) return NSNull.null;
    return @{
        @"top": MacIslandAuditDataValue(decoded[@"top"]),
        @"leading": MacIslandAuditDataValue(decoded[@"leading"]),
        @"bottom": MacIslandAuditDataValue(decoded[@"bottom"]),
        @"trailing": MacIslandAuditDataValue(decoded[@"trailing"]),
    };
}

void MacIslandEmitSceneAudit(NSString *auditPath, id settings, MacIslandSceneInsets *state,
                             NSScreen *targetScreen, BOOL displayKnown, BOOL physicalDisplay,
                             const NSRect rects[2], const NSRect publishedRects[2],
                             const MacIslandFamilyAuditSnapshot snapshots[2],
                             MacIslandActivityMetricsSummary activitySummary) {
    NSRect cutout = NSZeroRect;
    BOOL hasCutout = MacIslandScreenNotchCutout(targetScreen, &cutout);
    id client = MacIslandAuditDataValue(MacIslandExistingObjectSetting(settings, @"clientIdentifier"));
    id persistence = MacIslandAuditDataValue(MacIslandExistingObjectSetting(settings, @"persistenceIdentifier"));
    id elementKind = MacIslandAuditDataValue(MacIslandExistingObjectSetting(settings, @"elementKindIdentifier"));
    id rawMode = MacIslandExistingObjectSetting(settings, @"integratedLayoutMode");
    id modeName = auditLayoutModeName(rawMode) ?: NSNull.null;

    for (NSUInteger family = 0; family < 2; family++) {
        MacIslandFamilyAuditSnapshot snap = snapshots[family];
        if (!snap.hasData) continue;
        MacIslandNativeLayout *nativeLayout = state.layouts[family];
        NSUInteger obsFamily = snap.obstructionFamily;
        MacIslandNativeObstruction *nativeObs = state.obstructions[obsFamily];
        id rawLocation = MacIslandExistingObjectSetting(settings, MacIslandObstructionSetting(obsFamily, @"Location"))
            ?: MacIslandExistingObjectSetting(settings, @"integratedObstructionLocation");
        id obsLocation = MacIslandAuditDataValue(rawLocation);
        id anchorStyle = MacIslandAuditDataValue(MacIslandExistingObjectSetting(
            settings, family ? @"hostedIntegratedObstructionAnchorStyle" : @"integratedObstructionAnchorStyle"));
        id firstBaseline = MacIslandAuditDataValue(MacIslandExistingObjectSetting(
            settings, family ? @"hostedFirstTextBaselineFromTop" : @"elementViewFirstTextBaselineFromTop"));

        NSDictionary *nativeMargins = MacIslandDecodedMargins(nativeLayout.margins);
        NSDictionary *afterMargins = snap.patchedMargins == nativeLayout.margins
            ? nativeMargins : MacIslandDecodedMargins(snap.patchedMargins);
        BOOL includeActivity = (family == 0 && activitySummary.present);

        NSDictionary *record = @{
            @"event": @"scene_settings",
            @"family": family ? @"hosted" : @"elementView",
            @"obstructionFamily": obsFamily ? @"hosted" : @"elementView",
            @"client": client,
            @"persistenceId": persistence,
            @"elementKind": elementKind,
            @"layoutMode": modeName,
            @"layoutModeRaw": MacIslandAuditDataValue(rawMode),
            @"obstructionLocation": obsLocation,
            @"anchorStyle": anchorStyle,
            @"firstBaselineFromTop": firstBaseline,
            @"displayKnown": @(displayKnown),
            @"physicalDisplay": @(physicalDisplay),
            @"notch": hasCutout ? @{
                @"x": MacIslandAuditNumber(cutout.origin.x),
                @"y": MacIslandAuditNumber(cutout.origin.y),
                @"w": MacIslandAuditNumber(cutout.size.width),
                @"h": MacIslandAuditNumber(cutout.size.height),
                @"centeredDisplayWidth": MacIslandAuditNumber(snap.policy.centeredDisplayWidth),
            } : NSNull.null,
            @"sceneFrame": MacIslandAuditRectDict(state.frame),
            @"viewport": MacIslandAuditSizeDict(snap.viewport),
            @"native": @{
                @"margins": auditMarginsDict(nativeMargins),
                @"min": nativeLayout.minimum ? MacIslandAuditSizeDict(nativeLayout.minimum.sizeValue) : NSNull.null,
                @"max": nativeLayout.maximum ? MacIslandAuditSizeDict(nativeLayout.maximum.sizeValue) : NSNull.null,
                @"obstructionRect": nativeObs.rect ? MacIslandAuditRectDict(nativeObs.rect.rectValue) : NSNull.null,
                @"obstructionSpace": nativeObs.space ? MacIslandAuditSizeDict(nativeObs.space.sizeValue) : NSNull.null,
                @"activityMetrics": includeActivity ? @{
                    @"obstructionSize": MacIslandAuditSizeDict(activitySummary.nativeObstruction),
                    @"expandedMinWidth": MacIslandAuditNumber(activitySummary.nativeExpandedMinW),
                    @"expandedMaxWidth": MacIslandAuditNumber(activitySummary.nativeExpandedMaxW),
                    @"expandedScale": MacIslandAuditNumber(activitySummary.nativeExpandedScale),
                    @"expandedCornerRadius": MacIslandAuditNumber(activitySummary.nativeExpandedCornerRadius),
                } : NSNull.null,
            },
            @"policy": @{
                @"physical": @(snap.policy.physical),
                @"intersects": @(snap.policy.intersects),
                @"extendsBelow": @(snap.policy.extendsBelow),
                @"top": MacIslandAuditNumber(snap.policy.top),
                @"leading": MacIslandAuditNumber(snap.policy.leading),
                @"trailing": MacIslandAuditNumber(snap.policy.trailing),
                @"shortHeight": MacIslandAuditNumber(snap.shortHeight),
            },
            @"patched": @{
                @"applied": @(snap.applies),
                @"margins": auditMarginsDict(afterMargins),
                @"min": snap.patchedMin ? MacIslandAuditSizeDict(snap.patchedMin.sizeValue) : NSNull.null,
                @"max": snap.patchedMax ? MacIslandAuditSizeDict(snap.patchedMax.sizeValue) : NSNull.null,
                @"canonicalObstructionRect": nativeObs.rect ? MacIslandAuditRectDict(rects[obsFamily]) : NSNull.null,
                @"publishedObstructionRect": nativeObs.rect ? MacIslandAuditRectDict(publishedRects[obsFamily]) : NSNull.null,
                @"cornersZeroed": @(nativeObs.cornersApplied),
                @"activityMetrics": includeActivity ? @{
                    @"applied": @(activitySummary.patched),
                    @"obstructionSize": MacIslandAuditSizeDict(activitySummary.patchedObstruction),
                    @"expandedMinWidth": MacIslandAuditNumber(activitySummary.patchedExpandedMinW),
                    @"expandedMaxWidth": MacIslandAuditNumber(activitySummary.patchedExpandedMaxW),
                    @"expandedScale": MacIslandAuditNumber(activitySummary.patchedExpandedScale),
                    @"expandedCornerRadius": MacIslandAuditNumber(activitySummary.patchedExpandedCornerRadius),
                } : NSNull.null,
            },
        };
        NSString *signature = MacIslandAuditSerialize(record);
        if (!signature || [state.auditSignatures[family] isEqualToString:signature]) continue;
        state.auditSignatures[family] = signature;
        MacIslandAuditAppendRecord(auditPath, record);
    }
}
