#import <Foundation/Foundation.h>
@class THProfileAnalyzerSnapshot;
@class THProfileAnalyzerDiffResult;
@class THProfileAnalyzerUser;

NS_ASSUME_NONNULL_BEGIN

@interface THProfileAnalyzerDiffEngine : NSObject
+ (nullable THProfileAnalyzerDiffResult *)diffBetweenPreviousSnapshot:(nullable THProfileAnalyzerSnapshot *)previous currentSnapshot:(THProfileAnalyzerSnapshot *)current usersByPK:(NSDictionary<NSString *, THProfileAnalyzerUser *> *)usersByPK;
+ (NSDictionary<NSString *, THProfileAnalyzerUser *> *)usersByPKFromSnapshot:(THProfileAnalyzerSnapshot *)snapshot;
@end

NS_ASSUME_NONNULL_END
