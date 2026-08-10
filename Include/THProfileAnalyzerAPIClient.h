#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const THProfileAnalyzerAPIBaseURL;

@protocol THProfileAnalyzerAPIClientNetworkDelegate <NSObject>
- (void)performGETRequestWithURL:(NSURL *)url
                         success:(void (^)(NSDictionary * _Nullable json))success
                         failure:(void (^)(NSError * _Nonnull))failure;
@end

@interface THProfileAnalyzerAPIClient : NSObject
@property (nonatomic, strong, nullable) id<THProfileAnalyzerAPIClientNetworkDelegate> networkDelegate;
+ (NSString *)fullURLWithEndpointPath:(NSString *)path queryParams:(nullable NSDictionary<NSString *, NSString *> *)params;
- (void)GETWithEndpointPath:(NSString *)path
               queryParams:(nullable NSDictionary<NSString *, NSString *> *)params
                   success:(void (^)(NSDictionary * _Nullable json))success
                   failure:(void (^)(NSError * _Nonnull))failure;
@end

NS_ASSUME_NONNULL_END
