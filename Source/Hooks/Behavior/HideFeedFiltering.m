#import "Include.h"
#import "Include/InstagramHeaders.h"
#import "Include/ThetaTweakCommon.h"
#import <objc/runtime.h>

/* Older builds used "Strip …" titles as NSUserDefaults keys; copy to new keys once. */
__attribute__((constructor))
static void THMigrateFeedSettingTitles(void) {
    static NSArray *pairs = @[
        @[@"Strip Inline Suggested Posts", @"Hide Suggested Posts"],
        @[@"Strip Suggested Reels Strip", @"Hide Suggested Reels"],
        @[@"Strip People You Might Like", @"Hide People You May Know"],
        @[@"Strip Threads Carousel In Feed", @"Hide Threads Carousel"],
        @[@"Strip Home Stories Row", @"Hide Home Stories"],
        @[@"Strip End of Feed Suggestion Footer", @"Hide End-of-Feed Footer"],
    ];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSArray *p in pairs) {
        NSString *oldKey = [NSString stringWithFormat:@"%@_Enabled", p[0]];
        NSString *newKey = [NSString stringWithFormat:@"%@_Enabled", p[1]];
        if ([d objectForKey:newKey] == nil && [d objectForKey:oldKey] != nil)
            [d setBool:[d boolForKey:oldKey] forKey:newKey];
    }
}

@interface IGDiscoveryGridItem : NSObject
@property (nonatomic, readonly) id model;
@end

/* Feed list filtering; toggles use Theta wording. */

static NSArray *theta_removeAdsFromList(NSArray *list);

static BOOL theta_shouldRemoveSuggestedPosts(void) {
    return ENABLED(@"Hide Suggested Posts");
}
static BOOL theta_shouldRemoveSuggestedReelsCarousel(void) {
    return ENABLED(@"Hide Suggested Reels");
}
static BOOL theta_shouldRemoveSuggestedAccounts(void) {
    return ENABLED(@"Hide People You May Know");
}
static BOOL theta_shouldRemoveThreadsCarousel(void) {
    return ENABLED(@"Hide Threads Carousel");
}
static BOOL theta_shouldHideStoriesTrayRow(void) {
    return ENABLED(@"Hide Home Stories");
}
static BOOL theta_shouldBlankHomeFeed(void) {
    return ENABLED(@"Mute Entire Home Feed");
}

NSArray *ThetaApplyHideFeedFiltering(NSArray *list, BOOL isMainFeed) {
    if (![list isKindOfClass:[NSArray class]] || list.count == 0)
        return list;

    NSArray *filtered = list;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:filtered.count];
    for (id obj in filtered) {
        @autoreleasepool {
            if (!obj) continue;

            if (isMainFeed && theta_shouldRemoveSuggestedPosts()) {
                NSString *grpTitle = nil;
                if ([obj isKindOfClass:%c(IGFeedGroupHeaderViewModel)] && [obj respondsToSelector:@selector(title)])
                    grpTitle = ((NSString *(*)(id, SEL))objc_msgSend)(obj, @selector(title));
                BOOL isExploreInFeed = NO;
                if ([obj isKindOfClass:%c(IGMedia)] && [obj respondsToSelector:@selector(explorePostInFeed)])
                    isExploreInFeed = [@YES isEqual:((id (*)(id, SEL))objc_msgSend)(obj, @selector(explorePostInFeed))];
                if (isExploreInFeed
                    || (grpTitle.length && [[grpTitle lowercaseString] isEqualToString:@"suggested posts"])) {
                    continue;
                }
                if ([obj isKindOfClass:%c(IGInFeedStoriesTrayModel)])
                    continue;
            }

            if (isMainFeed && theta_shouldRemoveSuggestedReelsCarousel()) {
                if ([obj isKindOfClass:%c(IGFeedScrollableClipsModel)])
                    continue;
            }

            if (theta_shouldRemoveSuggestedAccounts()) {
                if (isMainFeed && [obj isKindOfClass:%c(IGHScrollAYMFModel)])
                    continue;
                if ([obj isKindOfClass:%c(IGSuggestedUserInReelsModel)])
                    continue;
            }

            if (theta_shouldRemoveThreadsCarousel()) {
                if (isMainFeed) {
                    Class threadsCls = objc_getClass("IGThreadsInFeedModels.IGThreadsInFeedModel");
                    if ([obj isKindOfClass:%c(IGBloksFeedUnitModel)] || (threadsCls && [obj isKindOfClass:threadsCls]))
                        continue;
                }
                if ([obj isKindOfClass:%c(IGSundialNetegoItem)])
                    continue;
            }

            if (isMainFeed && theta_shouldHideStoriesTrayRow()) {
                if ([obj isKindOfClass:%c(IGStoryDataController)])
                    continue;
            }

            if (isMainFeed && theta_shouldBlankHomeFeed()) {
                if ([obj isKindOfClass:%c(IGPostCreationManager)]
                    || [obj isKindOfClass:%c(IGMedia)]
                    || [obj isKindOfClass:%c(IGEndOfFeedDemarcatorModel)]
                    || [obj isKindOfClass:%c(IGSpinnerLabelViewModel)]) {
                    continue;
                }
            }

            [out addObject:obj];
        }
    }

    NSUInteger n = out.count;
    if (isMainFeed && n <= 5) {
        NSMutableArray *noSpinner = [NSMutableArray array];
        for (id obj in out) {
            if (![obj isKindOfClass:[%c(IGSpinnerLabelViewModel) class]])
                [noSpinner addObject:obj];
        }
        out = noSpinner;
    }

    return [out copy];
}

static NSArray *theta_removeAdsFromList(NSArray *list) {
    if (!ENABLED(@"Disable Ads") || ![list isKindOfClass:[NSArray class]])
        return list;
    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:list.count];
    for (id obj in list) {
        if (!obj) continue;
        BOOL isAd = NO;
        if ([obj isKindOfClass:%c(IGFeedItem)] && ([obj performSelector:@selector(isSponsored)] || [obj performSelector:@selector(isSponsoredApp)]))
            isAd = YES;
        if ([obj isKindOfClass:%c(IGDiscoveryGridItem)] && [(IGDiscoveryGridItem *)obj respondsToSelector:@selector(model)]) {
            id model = [(IGDiscoveryGridItem *)obj model];
            if ([model isKindOfClass:%c(IGAdItem)]) isAd = YES;
        }
        if ([obj isKindOfClass:%c(IGAdItem)])
            isAd = YES;
        if (!isAd)
            [filteredObjs addObject:obj];
    }
    return [filteredObjs copy];
}

static NSArray *(*orig_sundialObjs)(id, SEL, id);
static NSArray *hook_sundialObjs(id self, SEL _cmd, id arg1) {
    NSArray *r = orig_sundialObjs ? orig_sundialObjs(self, _cmd, arg1) : nil;
    r = ThetaApplyHideFeedFiltering(r ?: @[], NO);
    if (ENABLED(@"Disable Ads"))
        r = theta_removeAdsFromList(r);
    return r;
}

static NSArray *(*orig_ctxObjs)(id, SEL, id);
static NSArray *hook_ctxObjs(id self, SEL _cmd, id arg1) {
    NSArray *r = orig_ctxObjs(self, _cmd, arg1);
    if (!ENABLED(@"Disable Ads")) return r;
    return theta_removeAdsFromList(r);
}

static NSArray *(*orig_videoObjs)(id, SEL, id);
static NSArray *hook_videoObjs(id self, SEL _cmd, id arg1) {
    NSArray *r = orig_videoObjs(self, _cmd, arg1);
    if (!ENABLED(@"Disable Ads")) return r;
    return theta_removeAdsFromList(r);
}

static NSArray *(*orig_chainObjs)(id, SEL, id);
static NSArray *hook_chainObjs(id self, SEL _cmd, id arg1) {
    NSArray *r = orig_chainObjs(self, _cmd, arg1);
    if (!ENABLED(@"Disable Ads")) return r;
    return theta_removeAdsFromList(r);
}

static NSArray *(*orig_exploreObjs)(id, SEL, id);
static NSArray *hook_exploreObjs(id self, SEL _cmd, id arg1) {
    NSArray *r = orig_exploreObjs(self, _cmd, arg1);
    if (!ENABLED(@"Disable Ads")) return r;
    return theta_removeAdsFromList(r);
}

static NSArray *(*orig_exploreSwiftObjs)(id, SEL, id);
static NSArray *hook_exploreSwiftObjs(id self, SEL _cmd, id arg1) {
    NSArray *r = orig_exploreSwiftObjs(self, _cmd, arg1);
    if (!ENABLED(@"Disable Ads")) return r;
    return theta_removeAdsFromList(r);
}

static void (*orig_endFeedCell)(id self, SEL _cmd, id arg1);
static void hook_endFeedCell(id self, SEL _cmd, id arg1) {
    orig_endFeedCell(self, _cmd, arg1);
    if (!ENABLED(@"Hide End-of-Feed Footer")) return;
    @try {
        id titleLabel = [self valueForKey:@"_titleLabel"];
        if (titleLabel && [titleLabel respondsToSelector:@selector(setText:)])
            [(id)titleLabel setText:@""];
    } @catch (__unused NSException *e) {}
}

void THRegisterHideFeedFilteringHooks(void) {
    NullHookMessageIfPresent(objc_getClass("IGSundialFeedDataSource"), @selector(objectsForListAdapter:), (void *)hook_sundialObjs, &orig_sundialObjs);
    NullHookMessageIfPresent(objc_getClass("IGContextualFeedViewController"), @selector(objectsForListAdapter:), (void *)hook_ctxObjs, &orig_ctxObjs);
    NullHookMessageIfPresent(objc_getClass("IGVideoFeedViewController"), @selector(objectsForListAdapter:), (void *)hook_videoObjs, &orig_videoObjs);
    NullHookMessageIfPresent(objc_getClass("IGChainingFeedViewController"), @selector(objectsForListAdapter:), (void *)hook_chainObjs, &orig_chainObjs);
    NullHookMessageIfPresent(objc_getClass("IGExploreListKitDataSource"), @selector(objectsForListAdapter:), (void *)hook_exploreObjs, &orig_exploreObjs);

    Class swiftExplore = objc_getClass("_TtC28IGExploreViewControllerSwift26IGExploreListKitDataSource");
    NullHookMessageIfPresent(swiftExplore, @selector(objectsForListAdapter:), (void *)hook_exploreSwiftObjs, &orig_exploreSwiftObjs);
    NullHookMessageIfPresent(objc_getClass("IGEndOfFeedDemarcatorCellTopOfFeed"), @selector(configureWithViewConfig:), (void *)hook_endFeedCell, &orig_endFeedCell);
}
