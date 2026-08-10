#import "Include/THProfileAnalyzerService.h"
#import "Include/THProfileAnalyzerAPIClient.h"
#import "Include/THProfileAnalyzerTypes.h"

const NSInteger THProfileAnalyzerMaxAnalyzableFollowers = 13000;

/* Pace pagination: sub-second gaps often trip Instagram throttle (HTTP 400 + “limit how often…” message). */
#define TH_PA_PAGE_DELAY_S 1.05
/** Short pause before the first followers page after `/users/info/` so we don’t burst two calls. */
#define TH_PA_AFTER_PROFILE_INFO_DELAY_S 0.55
/** Retries after 400/429/503 with exponential backoff (same pagination cursor). */
#define TH_PA_MAX_PAGE_FAILURE_RETRIES 6

@interface THProfileAnalyzerService () {
    NSInteger _expectedFollowers;
    NSInteger _expectedFollowing;
}
@property (nonatomic, strong, nullable) THProfileAnalyzerAPIClient *client;
@property (nonatomic, copy) NSString *selfPK;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL running;
@end

static BOOL THPAErrorIndicatesIGThrottle(NSError *error) {
    if (!error) return NO;
    NSInteger code = error.code;
    if (code == 429 || code == 503) return YES;
    /* Instagram often signals action/rate spam with HTTP 400. */
    if (code == 400) return YES;

    NSString *d = [(error.localizedDescription ?: @"") lowercaseString];
    if ([d containsString:@"rate"] || [d containsString:@"limit"] ||
        [d containsString:@"too many"] || [d containsString:@"slow"] ||
        [d containsString:@"try again"]) return YES;
    return NO;
}

static BOOL THPAShouldAvoidRetryHTTPCode(NSInteger code) {
    /* Don’t backoff-spam obviously permanent client errors. */
    return code == 401 || code == 402 || code == 404 || code == 405;
}

static double THPABackoffSecondsForAttempt(NSInteger retryAttemptZeroBased) {
    static const double kSteps[] = { 5.0, 10.0, 20.0, 40.0, 80.0, 90.0 };
    const size_t n = sizeof(kSteps) / sizeof(kSteps[0]);
    if (retryAttemptZeroBased < 0) return kSteps[0];
    if ((size_t)retryAttemptZeroBased >= n) return kSteps[n - 1];
    return kSteps[(size_t)retryAttemptZeroBased];
}

/** Small jitter so pagination isn’t perfectly periodic. */
static double THPAPageDelayWithJitter(void) {
    double j = ((double)((int)(arc4random_uniform(31))) / 100.0) - 0.15;
    return MAX(0.72, TH_PA_PAGE_DELAY_S + j);
}

@implementation THProfileAnalyzerService

- (instancetype)initWithAPIClient:(THProfileAnalyzerAPIClient *)client userPK:(NSString *)userPK {
    self = [super init];
    if (!self) return nil;
    _client = client;
    _selfPK = [userPK copy];
    return self;
}

- (BOOL)isRunning { return self.running; }

- (void)cancel { self.cancelled = YES; }

- (NSError *)errorWithCode:(THProfileAnalyzerServiceError)code message:(NSString *)msg {
    return [NSError errorWithDomain:@"THProfileAnalyzerService" code:code
                           userInfo:@{ NSLocalizedDescriptionKey: msg ?: @"" }];
}

- (void)finishSnapshot:(nullable THProfileAnalyzerSnapshot *)s error:(nullable NSError *)e completion:(void (^)(THProfileAnalyzerSnapshot * _Nullable, NSError * _Nullable))completion {
    self.running = NO;
    self.cancelled = NO;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(s, e); });
}

- (void)reportProgress:(nullable THProfileAnalyzerFractionProgressBlock)p status:(NSString *)s fraction:(double)f {
    if (!p) return;
    dispatch_async(dispatch_get_main_queue(), ^{ p(s, f); });
}

- (void)runForSelfWithHeaderInfo:(THProfileAnalyzerHeaderInfoBlock)headerInfo
                        progress:(THProfileAnalyzerFractionProgressBlock)progress
                      completion:(void (^)(THProfileAnalyzerSnapshot * _Nullable, NSError * _Nullable))completion {
    if (self.running) {
        if (completion)
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [self errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Another analysis is already running."]);
            });
        return;
    }
    self.running = YES;
    self.cancelled = NO;

    NSString *pk = self.selfPK;
    if (!pk.length || !self.client) {
        [self finishSnapshot:nil error:[self errorWithCode:THProfileAnalyzerServiceErrorNoSession message:@"No active Instagram session or client."] completion:completion];
        return;
    }

    [self reportProgress:progress status:@"Fetching profile info…" fraction:0.02];
    [self performProfileInfoGETForPK:pk httpRetryCount:0 headerInfo:headerInfo progress:progress completion:completion];
}

- (void)performProfileInfoGETForPK:(NSString *)pk
                     httpRetryCount:(NSInteger)httpRetryCount
                         headerInfo:(THProfileAnalyzerHeaderInfoBlock)headerInfo
                           progress:(THProfileAnalyzerFractionProgressBlock)progress
                         completion:(void (^)(THProfileAnalyzerSnapshot * _Nullable, NSError * _Nullable))completion {
    THProfileAnalyzerAPIClient *client = self.client;
    __weak typeof(self) weakSelf = self;
    [client GETWithEndpointPath:[NSString stringWithFormat:@"users/%@/info/", pk] queryParams:nil success:^(NSDictionary * _Nullable resp) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.cancelled) {
            [strongSelf finishSnapshot:nil error:[strongSelf errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"] completion:completion];
            return;
        }
        NSDictionary *user = ([resp[@"user"] isKindOfClass:[NSDictionary class]]) ? resp[@"user"] : nil;
        if (!user) user = ([resp[@"User"] isKindOfClass:[NSDictionary class]]) ? resp[@"User"] : nil;
        if (!user) {
            [strongSelf finishSnapshot:nil error:[strongSelf errorWithCode:THProfileAnalyzerServiceErrorNetwork message:@"Couldn't fetch profile information"] completion:completion];
            return;
        }

        NSInteger followerCount = 0;
        id fc = user[@"follower_count"] ?: user[@"followerCount"];
        id fgc = user[@"following_count"] ?: user[@"followingCount"];
        if ([fc respondsToSelector:@selector(integerValue)]) followerCount = (NSInteger)[fc integerValue];

        if (followerCount > THProfileAnalyzerMaxAnalyzableFollowers) {
            [strongSelf finishSnapshot:nil error:[strongSelf errorWithCode:THProfileAnalyzerServiceErrorTooManyFollowers message:@"Too many followers to analyze"] completion:completion];
            return;
        }

        THProfileAnalyzerSnapshot *snap = [[THProfileAnalyzerSnapshot alloc] initWithUserPK:pk scannedAt:[NSDate date] followers:@[] following:@[]];
        snap.apiFollowersCount = followerCount;
        if ([fgc respondsToSelector:@selector(integerValue)]) snap.apiFollowingCount = (NSInteger)[fgc integerValue];
        else snap.apiFollowingCount = -1;

        id mc = user[@"media_count"];
        if ([mc respondsToSelector:@selector(integerValue)]) snap.mediaCount = (NSInteger)[mc integerValue];

        strongSelf->_expectedFollowers = followerCount;
        strongSelf->_expectedFollowing = snap.apiFollowingCount >= 0 ? snap.apiFollowingCount : 0;

        if (headerInfo) dispatch_async(dispatch_get_main_queue(), ^{ headerInfo(user); });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TH_PA_AFTER_PROFILE_INFO_DELAY_S * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) s2 = weakSelf;
            if (!s2) return;
            if (s2.cancelled) {
                [s2 finishSnapshot:nil error:[s2 errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"] completion:completion];
                return;
            }
            [s2 fetchFollowersForPK:pk snapshot:snap progress:progress completion:completion];
        });
    } failure:^(NSError * _Nonnull error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.cancelled) {
            [strongSelf finishSnapshot:nil error:[strongSelf errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"] completion:completion];
            return;
        }
        NSInteger code = error.code;
        if (httpRetryCount < TH_PA_MAX_PAGE_FAILURE_RETRIES && THPAErrorIndicatesIGThrottle(error) && !THPAShouldAvoidRetryHTTPCode(code)) {
            double wait = THPABackoffSecondsForAttempt(httpRetryCount);
            [strongSelf reportProgress:progress status:[NSString stringWithFormat:@"Instagram limited that request — waiting %.0fs before retry…", wait] fraction:0.02];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                typeof(self) s3 = weakSelf;
                if (!s3 || s3.cancelled) {
                    if (s3) [s3 finishSnapshot:nil error:[s3 errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"] completion:completion];
                    return;
                }
                [s3 performProfileInfoGETForPK:pk httpRetryCount:httpRetryCount + 1 headerInfo:headerInfo progress:progress completion:completion];
            });
            return;
        }
        NSError *wrapped = [strongSelf errorWithCode:THProfileAnalyzerServiceErrorNetwork message:error.localizedDescription ?: @"Network error"];
        if (THPAErrorIndicatesIGThrottle(error))
            wrapped = [strongSelf errorWithCode:THProfileAnalyzerServiceErrorRateLimited message:@"Instagram is limiting these requests. Wait a while, then try again."];
        [strongSelf finishSnapshot:nil error:wrapped completion:completion];
    }];
}

#pragma mark - Paginated fetchers

- (void)fetchFollowersForPK:(NSString *)pk
                   snapshot:(THProfileAnalyzerSnapshot *)snap
                   progress:(THProfileAnalyzerFractionProgressBlock)progress
                 completion:(void (^)(THProfileAnalyzerSnapshot * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<THProfileAnalyzerUser *> *acc = [NSMutableArray array];
    NSString *basePath = [NSString stringWithFormat:@"friendships/%@/followers/", pk];
    NSInteger followerProgressTotal = (snap.apiFollowersCount >= 0) ? MAX(1, snap.apiFollowersCount) : 1;
    [self pagePath:basePath
               acc:acc
             maxID:nil
             total:followerProgressTotal
             stage:@"followers"
 pageHTTPRetryCount:0
          progress:progress
        completion:^(NSArray<THProfileAnalyzerUser *> *users, NSError * _Nullable error) {
        if (error) {
            [self finishSnapshot:nil error:error completion:completion];
            return;
        }
        snap.followers = users;

        NSInteger followingTotal = self->_expectedFollowing;
        if (followingTotal <= 0 && snap.apiFollowingCount >= 0) followingTotal = snap.apiFollowingCount;

        [self fetchFollowingForPK:pk snapshot:snap progress:progress totalFollowing:followingTotal completion:completion];
    }];
}

- (void)fetchFollowingForPK:(NSString *)pk
                   snapshot:(THProfileAnalyzerSnapshot *)snap
                   progress:(THProfileAnalyzerFractionProgressBlock)progress
             totalFollowing:(NSInteger)totalFollowing
                 completion:(void (^)(THProfileAnalyzerSnapshot * _Nullable, NSError * _Nullable))completion {
    NSMutableArray<THProfileAnalyzerUser *> *acc = [NSMutableArray array];
    NSString *basePath = [NSString stringWithFormat:@"friendships/%@/following/", pk];
    NSInteger totalRaw = totalFollowing > 0 ? totalFollowing : (snap.apiFollowingCount >= 0 ? snap.apiFollowingCount : 1);
    NSInteger total = MAX(1, totalRaw);

    [self pagePath:basePath
               acc:acc
             maxID:nil
             total:total
             stage:@"following"
 pageHTTPRetryCount:0
          progress:progress
                 completion:^(NSArray<THProfileAnalyzerUser *> *users, NSError * _Nullable error) {
        if (error) {
            [self finishSnapshot:nil error:error completion:completion];
            return;
        }
        snap.following = users;
        [self finishSnapshot:snap error:nil completion:completion];
    }];
}

static NSString *_Nullable THPANextCursor(id next) {
    if (!next) return nil;
    if ([next isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)next;
        return s.length ? s : nil;
    }
    if ([next respondsToSelector:@selector(stringValue)]) {
        NSString *s = [(id)next stringValue];
        return s.length ? s : nil;
    }
    return nil;
}

- (void)pagePath:(NSString *)basePath
             acc:(NSMutableArray<THProfileAnalyzerUser *> *)acc
           maxID:(NSString *)maxID
           total:(NSInteger)total
           stage:(NSString *)stage
 pageHTTPRetryCount:(NSInteger)pageHTTPRetryCount
        progress:(THProfileAnalyzerFractionProgressBlock)progress
      completion:(void (^)(NSArray<THProfileAnalyzerUser *> *users, NSError * _Nullable error))completion {
    if (self.cancelled) {
        completion(nil, [self errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"]);
        return;
    }

    NSDictionary<NSString *, NSString *> *query = nil;
    if (maxID.length) query = @{ @"max_id": maxID };

    THProfileAnalyzerAPIClient *client = self.client;
    __weak typeof(self) weakSelf = self;

    [client GETWithEndpointPath:basePath queryParams:query success:^(NSDictionary * _Nullable resp) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            completion(nil, [NSError errorWithDomain:@"THProfileAnalyzerService" code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"Service released." }]);
            return;
        }
        if (!resp) {
            completion(nil, strongSelf.cancelled ? [strongSelf errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"] : [strongSelf errorWithCode:THProfileAnalyzerServiceErrorNetwork message:@"Empty response"]);
            return;
        }

        NSArray *users = resp[@"users"];
        if ([users isKindOfClass:[NSArray class]]) {
            for (NSDictionary *d in users) {
                if ([d isKindOfClass:[NSDictionary class]]) {
                    THProfileAnalyzerUser *u = [THProfileAnalyzerUser userFromAPIDictionary:d];
                    if (u) [acc addObject:u];
                }
            }
        }

        NSInteger followerTarget = strongSelf->_expectedFollowers;
        NSInteger followingTarget = strongSelf->_expectedFollowing;
        double totalWeight = MAX(1.0, (double)(followerTarget + followingTarget));
        double stageWeight = [stage isEqualToString:@"followers"] ? followerTarget / totalWeight : followingTarget / totalWeight;
        double stageOffset = [stage isEqualToString:@"followers"] ? 0.0 : (double)followerTarget / totalWeight;
        double denom = total > 0 ? (double)total : 1.0;
        double stageLocal = MIN(1.0, (double)acc.count / denom);
        double frac = 0.03 + (stageOffset + stageLocal * stageWeight) * 0.97;

        NSInteger totalForLabel = total;
        NSString *label = [stage isEqualToString:@"followers"]
            ? [NSString stringWithFormat:@"Fetching followers (%lu/%ld)…", (unsigned long)acc.count, (long)totalForLabel]
            : [NSString stringWithFormat:@"Fetching following (%lu/%ld)…", (unsigned long)acc.count, (long)totalForLabel];
        [strongSelf reportProgress:progress status:label fraction:frac];

        NSString *nextMax = THPANextCursor(resp[@"next_max_id"]);
        if (!nextMax.length || strongSelf.cancelled) {
            completion(acc, strongSelf.cancelled ? [strongSelf errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"] : nil);
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(THPAPageDelayWithJitter() * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf pagePath:basePath acc:acc maxID:nextMax total:total stage:stage pageHTTPRetryCount:0 progress:progress completion:completion];
        });
    } failure:^(NSError * _Nonnull error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            completion(nil, error);
            return;
        }
        if (strongSelf.cancelled) {
            completion(nil, [strongSelf errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"]);
            return;
        }
        NSInteger code = error.code;
        if (pageHTTPRetryCount < TH_PA_MAX_PAGE_FAILURE_RETRIES && THPAErrorIndicatesIGThrottle(error) && !THPAShouldAvoidRetryHTTPCode(code)) {
            double wait = THPABackoffSecondsForAttempt(pageHTTPRetryCount);
            [strongSelf reportProgress:progress status:[NSString stringWithFormat:@"Instagram limited that request — waiting %.0fs (%@)…", wait, stage] fraction:0.03];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                typeof(self) s2 = weakSelf;
                if (!s2) {
                    completion(nil, [NSError errorWithDomain:@"THProfileAnalyzerService" code:-1 userInfo:@{ NSLocalizedDescriptionKey: @"Service released." }]);
                    return;
                }
                if (s2.cancelled) {
                    completion(nil, [s2 errorWithCode:THProfileAnalyzerServiceErrorCancelled message:@"Cancelled"]);
                    return;
                }
                [s2 pagePath:basePath acc:acc maxID:maxID total:total stage:stage pageHTTPRetryCount:pageHTTPRetryCount + 1 progress:progress completion:completion];
            });
            return;
        }
        NSError *outErr = error;
        if (THPAErrorIndicatesIGThrottle(error))
            outErr = [strongSelf errorWithCode:THProfileAnalyzerServiceErrorRateLimited message:@"Instagram is limiting these requests. Wait a while, then try again."];
        completion(nil, outErr);
    }];
}

@end
