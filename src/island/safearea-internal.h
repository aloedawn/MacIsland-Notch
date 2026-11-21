#import "notch-layout.h"

typedef struct {
    BOOL present;
    BOOL patched;
    CGSize nativeObstruction;
    CGFloat nativeExpandedMinW;
    CGFloat nativeExpandedMaxW;
    CGFloat nativeExpandedScale;
    CGFloat nativeExpandedCornerRadius;
    CGSize patchedObstruction;
    CGFloat patchedExpandedMinW;
    CGFloat patchedExpandedMaxW;
    CGFloat patchedExpandedMinH;
    CGFloat patchedExpandedMaxH;
    CGFloat patchedExpandedScale;
    CGFloat patchedExpandedCornerRadius;
} MacIslandActivityMetricsSummary;

@protocol MacIslandSizeDimensionRequest <NSObject, NSCopying>
- (instancetype)initWithMinimum:(double)minimum maximum:(double)maximum type:(NSInteger)type;
- (double)minimum;
- (double)maximum;
- (NSInteger)type;
@end

@protocol MacIslandActivityEdgeInsets <NSObject, NSCopying>
- (double)leading;
- (double)trailing;
- (void)setLeading:(double)value;
- (void)setTrailing:(double)value;
@end

@protocol MacIslandActivityItemMetricsRequest <NSObject, NSCopying>
- (id<MacIslandSizeDimensionRequest>)widthRequest;
- (void)setWidthRequest:(id<MacIslandSizeDimensionRequest>)value;
- (id<MacIslandSizeDimensionRequest>)heightRequest;
- (void)setHeightRequest:(id<MacIslandSizeDimensionRequest>)value;
- (id<MacIslandActivityEdgeInsets>)edgeInsets;
- (void)setEdgeInsets:(id<MacIslandActivityEdgeInsets>)value;
- (double)cornerRadius;
- (void)setCornerRadius:(double)value;
- (double)scaleFactor;
- (void)setScaleFactor:(double)value;
@end

@protocol MacIslandSystemApertureMetricsRequest <NSObject, NSCopying>
- (CGSize)obstructionSize;
- (void)setObstructionSize:(CGSize)value;
- (double)obstructionTopMargin;
- (void)setObstructionTopMargin:(double)value;
- (id<MacIslandActivityItemMetricsRequest>)expandedMetricsRequest;
- (void)setExpandedMetricsRequest:(id<MacIslandActivityItemMetricsRequest>)value;
@end

@protocol MacIslandActivityMetricsRequest <NSObject, NSCopying>
- (id<MacIslandSystemApertureMetricsRequest>)systemApertureMetrics;
- (void)setSystemApertureMetrics:(id<MacIslandSystemApertureMetricsRequest>)value;
- (id<MacIslandSystemApertureMetricsRequest>)limitedWidthSystemApertureMetrics;
- (void)setLimitedWidthSystemApertureMetrics:(id<MacIslandSystemApertureMetricsRequest>)value;
@end

@interface MacIslandNativeLayout : NSObject
@property(nonatomic, strong) NSData *margins;
@property(nonatomic, strong) NSValue *minimum;
@property(nonatomic, strong) NSValue *maximum;
@property(nonatomic) BOOL applied;
@end

@interface MacIslandNativeObstruction : NSObject
@property(nonatomic, strong) NSValue *rect;
@property(nonatomic, strong) NSValue *space;
@property(nonatomic, strong) id nativeCorners;
@property(nonatomic, strong) id rectangularCorners;
@property(nonatomic) BOOL cornersApplied;
@property(nonatomic) BOOL obstructionApplied;
@end

@interface MacIslandSceneInsets : NSObject
@property(nonatomic, strong) NSArray<MacIslandNativeLayout *> *layouts;
@property(nonatomic, strong) NSArray<MacIslandNativeObstruction *> *obstructions;
@property(nonatomic, strong) NSMutableArray<NSString *> *auditSignatures;
@property(nonatomic, strong) NSData *nativeActivityMetricsData;
@property(nonatomic, strong) NSData *cachedActivityMetricsSource;
@property(nonatomic, strong) NSData *cachedPatchedActivityMetricsData;
@property(nonatomic) NSRect cachedActivityMetricsCutout;
@property(nonatomic) CGFloat cachedActivityMetricsDisplayWidth;
@property(nonatomic) MacIslandActivityMetricsSummary cachedActivitySummary;
@property(nonatomic) BOOL activityMetricsDataApplied;
@property(nonatomic, strong) id nativeActivityMetricsRequest;
@property(nonatomic) BOOL activityMetricsRequestApplied;
@property(nonatomic) CGRect frame;
@property(nonatomic) BOOL updating;
@end

typedef struct {
    BOOL physical;
    BOOL intersects;
    BOOL extendsBelow;
    CGFloat top;
    CGFloat leading;
    CGFloat trailing;
    CGFloat notchWidth;
    CGFloat notchHeight;
    CGFloat centeredDisplayWidth;
} MacIslandNotchAvoidance;

typedef struct {
    BOOL hasData;
    NSUInteger obstructionFamily;
    NSSize viewport;
    MacIslandNotchAvoidance policy;
    CGFloat shortHeight;
    BOOL applies;
    NSData *patchedMargins;
    NSValue *patchedMin;
    NSValue *patchedMax;
} MacIslandFamilyAuditSnapshot;

__attribute__((visibility("hidden"))) id MacIslandLayoutPayload(id value, id original);
__attribute__((visibility("hidden"))) id MacIslandRawObjectSetting(id settings, NSString *name);
__attribute__((visibility("hidden"))) id MacIslandExistingObjectSetting(id settings, NSString *name);
__attribute__((visibility("hidden"))) NSString *MacIslandObstructionSetting(NSUInteger family, NSString *suffix);
__attribute__((visibility("hidden"))) NSDictionary *MacIslandDecodedMargins(NSData *data);

__attribute__((visibility("hidden"))) MacIslandActivityMetricsSummary MacIslandRefreshActivityMetrics(
    id settings,
    MacIslandSceneInsets *state,
    NSScreen *targetScreen,
    BOOL physicalDisplay,
    void (*originalActivityMetricsData)(id, SEL, id),
    void (*originalActivityMetricsRequest)(id, SEL, id));

__attribute__((visibility("hidden"))) void MacIslandEmitSceneAudit(
    NSString *auditPath,
    id settings,
    MacIslandSceneInsets *state,
    NSScreen *targetScreen,
    BOOL displayKnown,
    BOOL physicalDisplay,
    const NSRect rects[2],
    const NSRect publishedRects[2],
    const MacIslandFamilyAuditSnapshot snapshots[2],
    MacIslandActivityMetricsSummary activitySummary);
