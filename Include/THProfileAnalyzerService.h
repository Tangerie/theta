//
// Profile analyzer service — pagination + guards — using TH networking.
//

#import <Foundation/Foundation.h>
@class THProfileAnalyzerAPIClient;
@class THProfileAnalyzerSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, THProfileAnalyzerServiceError) {
    THProfileAnalyzerServiceErrorNoSession = 1,
    THProfileAnalyzerServiceErrorTooManyFollowers,
    THProfileAnalyzerServiceErrorNetwork,
    THProfileAnalyzerServiceErrorCancelled,
    /** Repeated requests after backoff still rejected (likely Instagram throttle / spam block). */
    THProfileAnalyzerServiceErrorRateLimited,
};

/** Refuse analysis above this follower count (rate-limit / practicality). */
extern const NSInteger THProfileAnalyzerMaxAnalyzableFollowers;

typedef void (^THProfileAnalyzerHeaderInfoBlock)(NSDictionary *userInfo);
typedef void (^THProfileAnalyzerFractionProgressBlock)(NSString *status, double fraction);

@interface THProfileAnalyzerService : NSObject

@property (nonatomic, readonly) BOOL isRunning;

- (instancetype)initWithAPIClient:(THProfileAnalyzerAPIClient *)client userPK:(NSString *)userPK;

- (void)runForSelfWithHeaderInfo:(nullable THProfileAnalyzerHeaderInfoBlock)headerInfo
                        progress:(nullable THProfileAnalyzerFractionProgressBlock)progress
                      completion:(void (^)(THProfileAnalyzerSnapshot * _Nullable snapshot, NSError * _Nullable error))completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
