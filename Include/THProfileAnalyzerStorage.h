#import <Foundation/Foundation.h>
@class THProfileAnalyzerSnapshot;

NS_ASSUME_NONNULL_BEGIN

@interface THProfileAnalyzerStorage : NSObject
+ (NSString *)profileAnalyzerDirectory;
+ (NSString *)profileAnalyzerSQLPathForUserPK:(NSString *)userPK;
- (BOOL)saveSnapshot:(THProfileAnalyzerSnapshot *)snapshot error:(NSError **)outError;
- (nullable THProfileAnalyzerSnapshot *)loadMostRecentSnapshotForUserPK:(NSString *)userPK error:(NSError **)outError;
- (nullable THProfileAnalyzerSnapshot *)loadSnapshotAtIndex:(NSInteger)index forUserPK:(NSString *)userPK error:(NSError **)outError;
/** Number of stored scans for this user (0 if none or DB missing). */
- (NSInteger)snapshotCountForUserPK:(NSString *)userPK error:(NSError **)outError;
/** Deletes one scan row. `newestFirstIndex` matches `loadSnapshotAtIndex:` (0 = most recent scan). */
- (BOOL)deleteSnapshotAtNewestFirstIndex:(NSInteger)newestFirstIndex forUserPK:(NSString *)userPK error:(NSError **)outError;
- (BOOL)deleteAllSnapshotsForUserPK:(NSString *)userPK error:(NSError **)outError;
/** Update the most recently saved scan row with authoritative API follower/following counts (if you fetched them separately). */
- (BOOL)updateAPICountsForMostRecentScanWithUserPK:(NSString *)userPK followers:(NSInteger)followers following:(NSInteger)following error:(NSError **)outError;
@end

NS_ASSUME_NONNULL_END
