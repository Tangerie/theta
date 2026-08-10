#import "Include/THProfileAnalyzerTypes.h"

@implementation THProfileAnalyzerUser

+ (instancetype)userFromAPIDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    id pkRaw = d[@"pk"] ?: d[@"pk_id"] ?: d[@"id"];
    NSString *pk = [pkRaw isKindOfClass:[NSString class]] ? pkRaw
        : [pkRaw respondsToSelector:@selector(stringValue)] ? [(id)pkRaw stringValue] : nil;
    if (!pk.length) return nil;

    THProfileAnalyzerUser *u = [self new];
    u.pk = pk;
    u.username = [d[@"username"] isKindOfClass:[NSString class]] ? d[@"username"] : @"";
    u.fullName = [d[@"full_name"] isKindOfClass:[NSString class]] ? d[@"full_name"] : nil;
    if (!u.fullName.length) u.fullName = [d[@"fullName"] isKindOfClass:[NSString class]] ? d[@"fullName"] : u.fullName;
    u.profilePicURL = [d[@"profile_pic_url"] isKindOfClass:[NSString class]] ? d[@"profile_pic_url"] : nil;
    if (!u.profilePicURL.length)
        u.profilePicURL = [d[@"profilePicUrl"] isKindOfClass:[NSString class]] ? d[@"profilePicUrl"] : u.profilePicURL;
    id pid = d[@"profile_pic_id"] ?: d[@"profilePicId"];
    if ([pid isKindOfClass:[NSString class]]) u.profilePicID = pid;
    else if ([pid respondsToSelector:@selector(stringValue)]) u.profilePicID = [(id)pid stringValue];
    u.isPrivate = [d[@"is_private"] boolValue];
    u.isVerified = [d[@"is_verified"] boolValue];
    return u;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (!self) return nil;
    THProfileAnalyzerUser *parsed = [THProfileAnalyzerUser userFromAPIDictionary:dict];
    if (parsed) {
        _pk = parsed.pk;
        _username = parsed.username;
        _fullName = parsed.fullName;
        _profilePicURL = parsed.profilePicURL;
        _profilePicID = parsed.profilePicID;
        _isPrivate = parsed.isPrivate;
        _isVerified = parsed.isVerified;
    } else {
        _pk = [dict[@"pk"] description] ?: @"";
        _username = dict[@"username"] ?: @"";
        _fullName = dict[@"full_name"];
        _profilePicURL = dict[@"profile_pic_url"] ?: dict[@"profilePicUrl"] ?: dict[@"profilePicURL"];
        _profilePicID = dict[@"profile_pic_id"];
        _isPrivate = [dict[@"is_private"] boolValue];
        _isVerified = [dict[@"is_verified"] boolValue];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:8];
    d[@"pk"] = _pk;
    d[@"username"] = _username;
    if (_fullName) d[@"full_name"] = _fullName;
    if (_profilePicURL) d[@"profile_pic_url"] = _profilePicURL;
    if (_profilePicID) d[@"profile_pic_id"] = _profilePicID;
    d[@"is_private"] = @(_isPrivate);
    d[@"is_verified"] = @(_isVerified);
    return [d copy];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[THProfileAnalyzerUser class]]) return NO;
    return [((THProfileAnalyzerUser *)object).pk isEqualToString:_pk];
}

- (NSUInteger)hash { return _pk.hash; }

@end

@implementation THProfileAnalyzerSnapshot

- (instancetype)initWithUserPK:(NSString *)userPK scannedAt:(NSDate *)scannedAt followers:(NSArray<THProfileAnalyzerUser *> *)followers following:(NSArray<THProfileAnalyzerUser *> *)following {
    self = [super init];
    if (!self) return nil;
    _userPK = [userPK copy];
    _scannedAt = [scannedAt copy];
    _followers = [followers copy];
    _following = [following copy];
    _apiFollowersCount = -1;
    _apiFollowingCount = -1;
    _mediaCount = -1;
    return self;
}

@end

@implementation THProfileAnalyzerDiffResult
@end

@implementation THProfileAnalyzerResult
@end
