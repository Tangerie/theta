//
// THProfileAnalyzerTypes.h
// Profile Analyzer types for Theta (track who follows/unfollows you).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface THProfileAnalyzerUser : NSObject
@property (nonatomic, copy) NSString *pk;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy, nullable) NSString *fullName;
@property (nonatomic, copy, nullable) NSString *profilePicURL;
@property (nonatomic, copy, nullable) NSString *profilePicID;
@property (nonatomic, assign) BOOL isPrivate;
@property (nonatomic, assign) BOOL isVerified;
- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;
/** API user row (pk_id, profile_pic_id, …). */
+ (nullable instancetype)userFromAPIDictionary:(NSDictionary *)dict;
@end

@interface THProfileAnalyzerSnapshot : NSObject
@property (nonatomic, copy) NSString *userPK;
@property (nonatomic, copy) NSDate *scannedAt;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *followers;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *following;
/** API-reported counts from users/<pk>/info/; -1 if not stored. Use for display when >= 0. */
@property (nonatomic, assign) NSInteger apiFollowersCount;
@property (nonatomic, assign) NSInteger apiFollowingCount;
/** Optional; from user info snapshot. */
@property (nonatomic, assign) NSInteger mediaCount;
- (instancetype)initWithUserPK:(NSString *)userPK scannedAt:(NSDate *)scannedAt followers:(NSArray<THProfileAnalyzerUser *> *)followers following:(NSArray<THProfileAnalyzerUser *> *)following;
@end

@interface THProfileAnalyzerDiffResult : NSObject
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *followersGained;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *followersLost;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *followingAdded;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *followingRemoved;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *mutualFollowers;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *notFollowingMeBack;
@property (nonatomic, copy) NSArray<THProfileAnalyzerUser *> *youDontFollowBack;
@end

@interface THProfileAnalyzerResult : NSObject
@property (nonatomic, strong) THProfileAnalyzerSnapshot *currentSnapshot;
@property (nonatomic, strong, nullable) THProfileAnalyzerSnapshot *previousSnapshot;
@property (nonatomic, strong, nullable) THProfileAnalyzerDiffResult *diff;
@property (nonatomic, assign) NSInteger followersCount;
@property (nonatomic, assign) NSInteger followingCount;
@end

typedef void (^THProfileAnalyzerProgressBlock)(NSString * _Nullable message, NSInteger count);
typedef void (^THProfileAnalyzerCompletion)(THProfileAnalyzerResult * _Nullable result, NSError * _Nullable error);

NS_ASSUME_NONNULL_END
