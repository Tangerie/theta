#import "Include/THProfileAnalyzerDiffEngine.h"
#import "Include/THProfileAnalyzerTypes.h"

/** Profile analyzer report set math (mutual / subtract / intersect on user equality by pk). */

static NSArray<THProfileAnalyzerUser *> *THPANSubtract(NSArray<THProfileAnalyzerUser *> *a, NSSet<THProfileAnalyzerUser *> *bSet) {
    if (!a.count) return @[];
    NSMutableArray<THProfileAnalyzerUser *> *out = [NSMutableArray arrayWithCapacity:a.count];
    for (THProfileAnalyzerUser *u in a) {
        if (![bSet containsObject:u]) [out addObject:u];
    }
    return out;
}

static NSArray<THProfileAnalyzerUser *> *THPANIntersect(NSArray<THProfileAnalyzerUser *> *a, NSSet<THProfileAnalyzerUser *> *bSet) {
    if (!a.count) return @[];
    NSMutableArray<THProfileAnalyzerUser *> *out = [NSMutableArray arrayWithCapacity:a.count];
    for (THProfileAnalyzerUser *u in a) {
        if ([bSet containsObject:u]) [out addObject:u];
    }
    return out;
}

static NSArray<THProfileAnalyzerUser *> *THPANEnrichWithByPK(NSArray<THProfileAnalyzerUser *> *users, NSDictionary<NSString *, THProfileAnalyzerUser *> *byPK) {
    if (!byPK.count) return users;
    NSMutableArray<THProfileAnalyzerUser *> *out = [NSMutableArray arrayWithCapacity:users.count];
    for (THProfileAnalyzerUser *u in users) {
        THProfileAnalyzerUser *e = (u.pk.length && byPK[u.pk]) ? byPK[u.pk] : u;
        [out addObject:e];
    }
    return out;
}

@implementation THProfileAnalyzerDiffEngine

+ (NSDictionary<NSString *, THProfileAnalyzerUser *> *)usersByPKFromSnapshot:(THProfileAnalyzerSnapshot *)snapshot {
    NSMutableDictionary<NSString *, THProfileAnalyzerUser *> *byPK = [NSMutableDictionary dictionary];
    for (THProfileAnalyzerUser *u in snapshot.followers) if (u.pk.length) byPK[u.pk] = u;
    for (THProfileAnalyzerUser *u in snapshot.following) if (u.pk.length) byPK[u.pk] = u;
    return [byPK copy];
}

+ (THProfileAnalyzerDiffResult *)diffBetweenPreviousSnapshot:(THProfileAnalyzerSnapshot *)previous currentSnapshot:(THProfileAnalyzerSnapshot *)current usersByPK:(NSDictionary<NSString *, THProfileAnalyzerUser *> *)usersByPK {
    NSSet<THProfileAnalyzerUser *> *followersSet = [NSSet setWithArray:current.followers];
    NSSet<THProfileAnalyzerUser *> *followingSet = [NSSet setWithArray:current.following];

    NSArray<THProfileAnalyzerUser *> *mutual = THPANIntersect(current.followers, followingSet);
    NSArray<THProfileAnalyzerUser *> *notBack = THPANSubtract(current.following, followersSet);
    NSArray<THProfileAnalyzerUser *> *youDont = THPANSubtract(current.followers, followingSet);

    NSArray<THProfileAnalyzerUser *> *gained = @[], *lost = @[], *addF = @[], *remF = @[];
    if (previous) {
        NSSet<THProfileAnalyzerUser *> *prevFollowers = [NSSet setWithArray:previous.followers];
        NSSet<THProfileAnalyzerUser *> *prevFollowing = [NSSet setWithArray:previous.following];
        gained = THPANSubtract(current.followers, prevFollowers);
        lost = THPANSubtract(previous.followers, followersSet);
        addF = THPANSubtract(current.following, prevFollowing);
        remF = THPANSubtract(previous.following, followingSet);
    }

    THProfileAnalyzerDiffResult *r = [[THProfileAnalyzerDiffResult alloc] init];
    r.mutualFollowers = THPANEnrichWithByPK(mutual, usersByPK);
    r.notFollowingMeBack = THPANEnrichWithByPK(notBack, usersByPK);
    r.youDontFollowBack = THPANEnrichWithByPK(youDont, usersByPK);
    r.followersGained = THPANEnrichWithByPK(gained, usersByPK);
    r.followersLost = THPANEnrichWithByPK(lost, usersByPK);
    r.followingAdded = THPANEnrichWithByPK(addF, usersByPK);
    r.followingRemoved = THPANEnrichWithByPK(remF, usersByPK);
    return r;
}

@end
