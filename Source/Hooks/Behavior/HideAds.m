#import "Include/ThetaTweakCommon.h"

static NSArray *removeAdsItemsInList(NSArray *list) {
    if (!list) {
        return @[];
    }
    
    BOOL disableAds = ENABLED(@"Disable Ads");

    NSMutableArray *filteredList = [list mutableCopy];
    [filteredList enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if (!obj) return;

        BOOL isSponsored = (([obj isKindOfClass:%c(IGFeedItem)] && [obj performSelector:@selector(isSponsored)]) ||
                            ([obj isKindOfClass:%c(IGFeedItem)] && [obj performSelector:@selector(isSponsoredApp)]) ||
                            [obj isKindOfClass:%c(IGAdItem)]);

        BOOL isSuggested = NO;
        if ([obj respondsToSelector:@selector(isOrganicMedia)]) {
            isSuggested = [obj isKindOfClass:NSClassFromString(@"IGMedia")] && [[obj performSelector:@selector(explorePostInFeed)] integerValue] == 1 && ![[obj performSelector:@selector(isOrganicMedia)] boolValue];
        } else if ([obj respondsToSelector:@selector(isShoppableOrganicMedia:)]) {
            isSuggested = [obj isKindOfClass:NSClassFromString(@"IGMedia")] && [[obj performSelector:@selector(explorePostInFeed)] integerValue] == 1 && ![[obj performSelector:@selector(isShoppableOrganicMedia:)] boolValue];
        }

        NSMutableArray *adsToRemove = [NSMutableArray array];
        NSMutableArray *suggestedToRemove = [NSMutableArray array];

        if (disableAds) {
            if (isSponsored) {
                [adsToRemove addObject:obj];
            }
        }

        if (disableAds) {
            if (isSponsored) {
                [adsToRemove addObject:obj];
            }
            if (isSuggested) {
                [suggestedToRemove addObject:obj];
            }
        }

        [filteredList removeObjectsInArray:adsToRemove];
        [filteredList removeObjectsInArray:suggestedToRemove];
    }];
    
    return [filteredList copy];
}

static NSArray *(*orig_hideAds)(id self, SEL _cmd, id arg1);
static NSArray *hook_hideAds(id self, SEL _cmd, id arg1) {
    @try {
        NSArray *result = orig_hideAds(self, _cmd, arg1);
        BOOL disableAds = ENABLED(@"Disable Ads");
        if (disableAds) {
            result = removeAdsItemsInList(result);
        }
        return ThetaApplyHideFeedFiltering(result ?: @[], YES);
    } @catch (NSException *exception) {
        NSLog(@"Error in hideAds hook: %@", exception);
        return orig_hideAds(self, _cmd, arg1);
    }
}

static id (*orig_hideAds2)(id self, SEL _cmd, id arg1);
static id hook_hideAds2(id self, SEL _cmd, id arg1) {
    BOOL disableAds = ENABLED(@"Disable Ads");

    if (!(disableAds)) {
        return orig_hideAds2(self, _cmd, arg1);
    }

    @try {
        if (disableAds) {
            return nil;
        }
        if (!disableAds) {
            return orig_hideAds2(self, _cmd, arg1);
        }
        return nil;
    } @catch (NSException *exception) {
        NSLog(@"Error in hideAds2 hook: %@", exception);
        return orig_hideAds2(self, _cmd, arg1);
    }
}

static id (*orig_hideAds3)(id self, SEL _cmd);
static id hook_hideAds3(id self, SEL _cmd) {
    @try {
        BOOL disableAds = ENABLED(@"Disable Ads");

        if (!(disableAds)) {
            return orig_hideAds3(self, _cmd);
        }

        NSMutableArray *originalList = [orig_hideAds3(self, _cmd) mutableCopy];
        if (!originalList) {
            return @[];
        }

        if (disableAds) {
            [originalList enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                if (!obj) return;
                if ([obj isKindOfClass:NSClassFromString(@"IGAdItem")]) {
                    @try {
                        [originalList removeObjectAtIndex:idx];
                    } @catch (NSException *exception) {
                        NSLog(@"Error removing ad item at index %lu: %@", (unsigned long)idx, exception);
                    }
                }
            }];
        } else if (!disableAds) {
            // Do nothing
        } else {
            [originalList enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                if (!obj) return;
                if ([obj isKindOfClass:NSClassFromString(@"IGAdItem")]) {
                    @try {
                        [originalList removeObjectAtIndex:idx];
                    } @catch (NSException *exception) {
                        NSLog(@"Error removing ad item at index %lu: %@", (unsigned long)idx, exception);
                    }
                }
            }];
        }

        return originalList;
    } @catch (NSException *exception) {
        NSLog(@"Error in hideAds3 hook: %@", exception);
        return orig_hideAds3(self, _cmd);
    }
}

static id (*orig_hideAds4)(id self, SEL _cmd, id arg1);
static id hook_hideAds4(id self, SEL _cmd, id arg1) {
    BOOL disableAds = ENABLED(@"Disable Ads");

    if (!(disableAds)) {
        return orig_hideAds4(self, _cmd, arg1);
    }

    @try {
        if (disableAds) {
            return nil;
        }
        if (!disableAds) {
            return orig_hideAds4(self, _cmd, arg1);
        }
        return nil;
    } @catch (NSException *exception) {
        NSLog(@"Error in hideAds4 hook: %@", exception);
        return orig_hideAds4(self, _cmd, arg1);
    }
}

static void (*orig_hideSuggestedReels)(id self, SEL _cmd);
static void hook_hideSuggestedReels(id self, SEL _cmd) {
    if (!ENABLED(@"Disable Suggested Posts")) {
        orig_hideSuggestedReels(self, _cmd);
        return;
    }

    @try {
        NSString *accessibilityLabel = [self valueForKey:@"accessibilityLabel"];
        if ([accessibilityLabel isEqualToString:@"Suggested reels"]) {
            [self removeFromSuperview];
            return;
        }
    } @catch (NSException *exception) {
        NSLog(@"Error in hideSuggestedReels hook: %@", exception);
        orig_hideSuggestedReels(self, _cmd);
    }
}

static void (*orig_hideSuggestedReels2)(id self, SEL _cmd);
static void hook_hideSuggestedReels2(id self, SEL _cmd) {
    if (!ENABLED(@"Disable Suggested Posts")) {
        orig_hideSuggestedReels2(self, _cmd);
        return;
    }

    @try {
        NSString *accessibilityLabel = [self valueForKey:@"accessibilityLabel"];
        if ([accessibilityLabel isEqualToString:@"Suggested reels"]) {
            [self removeFromSuperview];
            return;
        }
    } @catch (NSException *exception) {
        NSLog(@"Error in hideSuggestedReels2 hook: %@", exception);
        orig_hideSuggestedReels2(self, _cmd);
    }
}

static void (*orig_hideSuggestedReels3)(id self, SEL _cmd);
static void hook_hideSuggestedReels3(id self, SEL _cmd) {
    if (!ENABLED(@"Disable Suggested Posts")) {
        orig_hideSuggestedReels3(self, _cmd);
        return;
    }

    @try {
        UILabel *label = [self valueForKey:@"_titleLabel"];
        if ([label.text isEqualToString:@"Suggested Posts"]) {
            [self removeFromSuperview];
            return;
        }
    } @catch (NSException *exception) {
        NSLog(@"Error in hideSuggestedReels3 hook: %@", exception);
        orig_hideSuggestedReels3(self, _cmd);
    }
}

static void (*orig_hideAds5)(id self, SEL _cmd, id adItem, NSInteger overlayStyle, BOOL ctaEnabled, id delegate, NSUInteger surfaceType, id analyticsModule, NSUInteger labelAlignment);
static void hook_hideAds5(id self, SEL _cmd, id adItem, NSInteger overlayStyle, BOOL ctaEnabled, id delegate, NSUInteger surfaceType, id analyticsModule, NSUInteger labelAlignment) {
    if (!ENABLED(@"Disable Ads")) {
        orig_hideAds5(self, _cmd, adItem, overlayStyle, ctaEnabled, delegate, surfaceType, analyticsModule, labelAlignment);
        return;
    }

    [self removeFromSuperview];
}

void THRegisterHideAdsCoreHooks(void) {
    NullHookMessageIfPresent(objc_getClass("IGMainFeedListAdapterDataSource"), @selector(objectsForListAdapter:), (void *)hook_hideAds, &orig_hideAds);
    NullHookMessageIfPresent(objc_getClass("IGStoryAdsResponseParser"), @selector(parsedObjectFromResponse:), (void *)hook_hideAds2, &orig_hideAds2);
    NullHookMessageIfPresent(objc_getClass("IGSundialAdsResponseParser"), @selector(parsedObjectFromResponse:), (void *)hook_hideAds4, &orig_hideAds4);
    NullHookMessageIfPresent(objc_getClass("IGFeedItemChain"), @selector(allChainItems), (void *)hook_hideAds3, &orig_hideAds3);
    NullHookMessageIfPresent(objc_getClass("IGDiscoveryGridAdNoCTAOverlayView"), @selector(configureWithAdItem:overlayViewStyle:ctaEnabled:delegate:surfaceType:analyticsModule:labelAlignment:), (void *)hook_hideAds5, &orig_hideAds5);
}

void THRegisterHideSuggestedReelsHooks(void) {
    NullHookMessageIfPresent(objc_getClass("IGStoryTrayCollectionViewCell"), @selector(layoutSubviews), (void *)hook_hideSuggestedReels, &orig_hideSuggestedReels);
    NullHookMessageIfPresent(objc_getClass("IGStoryTraySectionHeaderCell"), @selector(layoutSubviews), (void *)hook_hideSuggestedReels2, &orig_hideSuggestedReels2);
    NullHookMessageIfPresent(objc_getClass("IGFeedGroupHeaderCell"), @selector(layoutSubviews), (void *)hook_hideSuggestedReels3, &orig_hideSuggestedReels3);
}