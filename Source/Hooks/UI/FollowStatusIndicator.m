#import "Include.h"

static void saveMedia(id hostView);

@interface ThetaSaveMediaButtonTarget : NSObject
@property (nonatomic, weak) UIView *hostView;
- (void)onTap:(id)sender;
@end

@implementation ThetaSaveMediaButtonTarget
- (void)onTap:(id)sender {
    UIView *host = self.hostView;
    if (!host && [sender isKindOfClass:[UIView class]]) {
        host = [(UIView *)sender superview];
    }
    if (!host) {
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"Lost profile context." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
        return;
    }
    [ThetaHelper performHapticFeedbackIfEnabled];
    saveMedia(host);
}
@end

static const NSInteger kThetaFollowSaveButtonTag = 424242;

static UIViewController *theta_profileViewControllerFromView(UIView *view) {
    Class profileCls = NSClassFromString(@"IGProfileViewController");
    if (!profileCls || !view) return nil;

    // Walk responders / superviews for any VC, then climb parents to the profile VC.
    UIViewController *nearest = [ThetaHelper nearestViewController:view];
    for (UIViewController *vc = nearest; vc; vc = vc.parentViewController) {
        if ([vc isKindOfClass:profileCls]) return vc;
    }
    for (UIViewController *vc = nearest; vc; vc = vc.presentingViewController) {
        if ([vc isKindOfClass:profileCls]) return vc;
    }

    // Fallback: top presented stack
    UIViewController *top = [ThetaHelper topViewController];
    for (UIViewController *vc = top; vc; vc = vc.parentViewController) {
        if ([vc isKindOfClass:profileCls]) return vc;
    }
    for (UIViewController *vc = top; vc; vc = vc.presentingViewController) {
        if ([vc isKindOfClass:profileCls]) return vc;
    }
    return nil;
}

static NSArray *theta_copyArrayLocked(id owner, NSString *arrayKey, NSString *lockKey) {
    if (!owner) return nil;
    NSLock *lock = ThetaValueForKey(owner, lockKey);
    if (![lock isKindOfClass:[NSLock class]]) lock = nil;
    @try { [lock lock]; } @catch (__unused NSException *e) { lock = nil; }
    id items = ThetaValueForKey(owner, arrayKey);
    NSArray *copy = [items isKindOfClass:[NSArray class]] ? [items copy] : nil;
    @try { [lock unlock]; } @catch (__unused NSException *e) {}
    return copy;
}

static NSArray *theta_gridItemsFromNetworkSource(id networkSource) {
    if (!networkSource) return nil;
    // IGUserFeedNetworkSource stores loaded profile posts in _gridItems (guarded by _gridItemsLock).
    NSArray *items = theta_copyArrayLocked(networkSource, @"_gridItems", @"_gridItemsLock");
    if (items.count) return items;
    items = ThetaValueForKey(networkSource, @"gridItems");
    return [items isKindOfClass:[NSArray class]] && items.count ? [items copy] : nil;
}

static NSArray *theta_postsFromNetworkSource(id networkSource) {
    if (!networkSource) return nil;
    // Superclass IGFeedNetworkSource keeps fuller IGMedia objects in _posts.
    NSArray *posts = theta_copyArrayLocked(networkSource, @"_posts", @"_lock");
    if (posts.count) return posts;
    posts = ThetaValueForKey(networkSource, @"posts");
    return [posts isKindOfClass:[NSArray class]] && posts.count ? [posts copy] : nil;
}

/// IGProfileFeedSource wraps an IGUserFeedNetworkSource in `_feedSource`.
static id theta_networkSourceFromProfileFeedSource(id profileFeedSource) {
    if (!profileFeedSource) return nil;
    id nested = ThetaValueForKey(profileFeedSource, @"_feedSource");
    if (!nested) nested = ThetaValueForKey(profileFeedSource, @"feedSource");
    if (nested) return nested;
    // Already unwrapped
    if (theta_gridItemsFromNetworkSource(profileFeedSource)) return profileFeedSource;
    return nil;
}

static NSArray *theta_gridItemsFromProfileFeedSource(id profileFeedSource) {
    return theta_gridItemsFromNetworkSource(theta_networkSourceFromProfileFeedSource(profileFeedSource));
}

static UIViewController *theta_profileFeedPageFromProfileVC(UIViewController *profileVC) {
    if (!profileVC) return nil;

    NSArray *feedPageNames = @[
        @"_TtC9IGProfile27IGProfileFeedViewController",
        @"IGProfile.IGProfileFeedViewController",
        @"_TtC9IGProfile35IGProfileUserGridFeedViewController",
        @"IGProfile.IGProfileUserGridFeedViewController"
    ];
    NSMutableArray *feedClasses = [NSMutableArray array];
    for (NSString *name in feedPageNames) {
        Class cls = NSClassFromString(name);
        if (cls) [feedClasses addObject:cls];
    }

    id page = nil;
    if ([profileVC respondsToSelector:@selector(currentPageViewController)]) {
        @try { page = [profileVC performSelector:@selector(currentPageViewController)]; } @catch (__unused NSException *e) {}
    }
    if (!page) page = ThetaValueForKey(profileVC, @"currentPageViewController");
    for (Class cls in feedClasses) {
        if ([page isKindOfClass:cls]) return page;
    }

    // Breadth-first through children — currentPage can be a container.
    NSMutableArray *queue = [NSMutableArray array];
    if (page) [queue addObject:page];
    [queue addObjectsFromArray:profileVC.childViewControllers ?: @[]];
    NSUInteger i = 0;
    while (i < queue.count) {
        UIViewController *vc = queue[i++];
        for (Class cls in feedClasses) {
            if ([vc isKindOfClass:cls]) return vc;
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
        if (queue.count > 64) break;
    }
    return nil;
}

static id theta_profileFeedSourcesManager(UIViewController *profileVC) {
    if (!profileVC) return nil;
    for (NSString *key in @[ @"_feedSourcesManager", @"feedSourcesManager", @"profileFeedSourcesManager" ]) {
        id mgr = ThetaValueForKey(profileVC, key);
        if (mgr) return mgr;
    }
    UIViewController *feedPage = theta_profileFeedPageFromProfileVC(profileVC);
    for (NSString *key in @[ @"feedSourcesManager", @"_feedSourcesManager" ]) {
        id mgr = ThetaValueForKey(feedPage, key);
        if (mgr) return mgr;
    }
    return nil;
}

static id theta_profileFeedSourceFromManager(id feedSourceMan) {
    if (!feedSourceMan) return nil;

    Class feedSrcCls = NSClassFromString(@"IGProfileFeedSource");
    id sources = ThetaValueForKey(feedSourceMan, @"_sources");
    if (![sources isKindOfClass:[NSDictionary class]]) {
        sources = ThetaValueForKey(feedSourceMan, @"sources");
    }
    if (![sources isKindOfClass:[NSDictionary class]]) return nil;

    // Prefer a source that already has loaded grid items; else first IGProfileFeedSource.
    id fallback = nil;
    for (id raw in [(NSDictionary *)sources allValues]) {
        id candidate = raw;
        if (feedSrcCls && ![candidate isKindOfClass:feedSrcCls]) {
            id nestedProfile = ThetaValueForKey(candidate, @"profileFeedSource");
            if (nestedProfile) candidate = nestedProfile;
        }
        if (theta_gridItemsFromProfileFeedSource(candidate).count > 0) {
            return candidate;
        }
        if (!fallback && feedSrcCls && [candidate isKindOfClass:feedSrcCls]) {
            fallback = candidate;
        }
    }
    return fallback;
}

static id theta_activeProfileFeedSource(UIViewController *profileVC) {
    UIViewController *feedPage = theta_profileFeedPageFromProfileVC(profileVC);
    if (feedPage) {
        id pfs = nil;
        if ([feedPage respondsToSelector:@selector(profileFeedSource)]) {
            @try { pfs = [feedPage performSelector:@selector(profileFeedSource)]; } @catch (__unused NSException *e) {}
        }
        if (!pfs) pfs = ThetaValueForKey(feedPage, @"profileFeedSource");
        if (pfs) return pfs;
    }
    id feedSourceMan = theta_profileFeedSourcesManager(profileVC);
    return theta_profileFeedSourceFromManager(feedSourceMan);
}

static NSArray *theta_collectProfileGridItems(UIViewController *profileVC) {
    id pfs = theta_activeProfileFeedSource(profileVC);
    NSArray *items = theta_gridItemsFromProfileFeedSource(pfs);
    if (items.count) return items;
    // Fallback: full feed posts if grid models aren't populated yet.
    return theta_postsFromNetworkSource(theta_networkSourceFromProfileFeedSource(pfs));
}

static id theta_mediaFromGridItem(id item) {
    if (!item) return nil;

    // IG 441 profile grid cells are IGMediaThumbnailModel — real IGMedia is on media_DO_NOT_USE.
    static SEL mediaDoNotUseSel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaDoNotUseSel = NSSelectorFromString(@"media_DO_NOT_USE");
    });
    if (mediaDoNotUseSel && [item respondsToSelector:mediaDoNotUseSel]) {
        id media = nil;
        @try { media = ((id (*)(id, SEL))objc_msgSend)(item, mediaDoNotUseSel); } @catch (__unused NSException *e) {}
        if (media) return media;
    }

    for (NSString *key in @[ @"media_DO_NOT_USE", @"media", @"_media", @"feedItem", @"post" ]) {
        id media = ThetaValueForKey(item, key);
        if (media && media != item) return media;
    }

    if ([item respondsToSelector:@selector(media)]) {
        id media = nil;
        @try { media = [item performSelector:@selector(media)]; } @catch (__unused NSException *e) {}
        if (media) return media;
    }

    // Already an IGMedia / IGPostItem-like object
    Class mediaCls = NSClassFromString(@"IGMedia");
    if (mediaCls && [item isKindOfClass:mediaCls]) return item;
    return item;
}

static NSString *theta_mediaIdentity(id media) {
    if (!media) return nil;
    for (NSString *key in @[ @"pk", @"_pk", @"mediaID", @"mediaId", @"id", @"graphQLID" ]) {
        id v = ThetaValueForKey(media, key);
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        if ([v respondsToSelector:@selector(stringValue)]) {
            NSString *s = [v stringValue];
            if (s.length) return s;
        }
    }
    return [NSString stringWithFormat:@"%p", media];
}

static NSURL *theta_urlFromCandidate(id cand) {
    if (!cand) return nil;
    if ([cand isKindOfClass:[NSURL class]]) return ((NSURL *)cand).scheme.length ? cand : nil;
    if ([cand isKindOfClass:[NSString class]]) {
        NSURL *u = [NSURL URLWithString:(NSString *)cand];
        return u.scheme.length ? u : nil;
    }
    for (NSString *key in @[ @"url", @"URL", @"imageURL", @"imageUrl", @"uri", @"src" ]) {
        id url = ThetaValueForKey(cand, key);
        if ([url isKindOfClass:[NSURL class]] && [(NSURL *)url scheme].length) return url;
        if ([url isKindOfClass:[NSString class]]) {
            NSURL *u = [NSURL URLWithString:(NSString *)url];
            if (u.scheme.length) return u;
        }
    }
    return nil;
}

static NSArray *theta_imageVersionArraysFromPhoto(id photo) {
    if (!photo) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in @[ @"_originalImageVersions", @"imageVersions", @"_imageVersions", @"imageVersions2", @"_imageVersions2" ]) {
        id versions = ThetaValueForKey(photo, key);
        if ([versions isKindOfClass:[NSDictionary class]]) {
            id cands = [(NSDictionary *)versions objectForKey:@"candidates"];
            if (!cands) cands = [(NSDictionary *)versions objectForKey:@"_candidates"];
            versions = cands;
        }
        if ([versions isKindOfClass:[NSArray class]] && [(NSArray *)versions count] > 0) {
            [out addObject:versions];
        }
    }
    return out.count ? out : nil;
}

static NSURL *theta_bestImageURLFromPhoto(id photo) {
    if (!photo) return nil;
    for (NSArray *versions in theta_imageVersionArraysFromPhoto(photo)) {
        // Prefer last candidate (usually highest res in IG arrays).
        NSURL *u = theta_urlFromCandidate([versions lastObject]);
        if (u) return u;
        for (id cand in [versions reverseObjectEnumerator]) {
            u = theta_urlFromCandidate(cand);
            if (u) return u;
        }
    }
    return theta_urlFromCandidate(photo);
}

static NSURL *theta_bestImageURLFromObject(id obj) {
    if (!obj) return nil;

    // Collect hintable URLs from the object itself.
    if ([obj respondsToSelector:@selector(hintableImageURLs)]) {
        id urls = nil;
        @try { urls = [obj performSelector:@selector(hintableImageURLs)]; } @catch (__unused NSException *e) {}
        if ([urls isKindOfClass:[NSArray class]]) {
            for (id cand in [(NSArray *)urls reverseObjectEnumerator]) {
                NSURL *u = theta_urlFromCandidate(cand);
                if (u) return u;
            }
        } else if ([urls isKindOfClass:[NSSet class]]) {
            for (id cand in (NSSet *)urls) {
                NSURL *u = theta_urlFromCandidate(cand);
                if (u) return u;
            }
        }
    }

    for (NSString *key in @[ @"photo", @"rawPhoto", @"profileThumbnailPhoto", @"thumbnailPhoto" ]) {
        id photo = nil;
        if ([obj respondsToSelector:NSSelectorFromString(key)]) {
            @try { photo = [obj performSelector:NSSelectorFromString(key)]; } @catch (__unused NSException *e) {}
        }
        if (!photo) photo = ThetaValueForKey(obj, key);
        NSURL *u = theta_bestImageURLFromPhoto(photo);
        if (u) return u;
    }
    return theta_bestImageURLFromPhoto(obj);
}

static id theta_videoFromObject(id obj) {
    if (!obj) return nil;
    id video = nil;
    if ([obj respondsToSelector:@selector(video)]) {
        @try { video = [obj performSelector:@selector(video)]; } @catch (__unused NSException *e) {}
    }
    if (!video) video = ThetaValueForKey(obj, @"video");
    if (!video) video = ThetaValueForKey(obj, @"rawVideo");
    return video;
}

static NSURL *theta_bestVideoURLFromVideo(id video) {
    if (!video) return nil;
    if ([video respondsToSelector:@selector(allVideoURLs)]) {
        id set = nil;
        @try { set = [video performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
        if ([set isKindOfClass:[NSSet class]]) {
            for (id cand in (NSSet *)set) {
                NSURL *u = theta_urlFromCandidate(cand);
                if (u) return u;
            }
        } else if ([set isKindOfClass:[NSArray class]]) {
            for (id cand in [(NSArray *)set reverseObjectEnumerator]) {
                NSURL *u = theta_urlFromCandidate(cand);
                if (u) return u;
            }
        }
    }
    for (NSString *key in @[ @"videoUrl", @"videoURL", @"url", @"_url" ]) {
        NSURL *u = theta_urlFromCandidate(ThetaValueForKey(video, key));
        if (u) return u;
    }
    return nil;
}

static NSInteger theta_mediaTypeOfObject(id obj) {
    if (!obj) return -1;
    // Prefer explicit item/media enums. Avoid bare `mediaType` first — on some objects it is not an NSInteger.
    NSArray<NSString *> *sels = @[ @"itemMediaType", @"mediaTypeEnum", @"computedMediaType", @"mediaType" ];
    for (NSString *name in sels) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        @try {
            NSInteger v = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
            // Sane IG media-type range (1 photo, 2 video, 8 carousel, etc.)
            if (v >= 0 && v < 64) return v;
        } @catch (__unused NSException *e) {}
    }
    return -1;
}

static NSArray *theta_carouselOrSelfItems(id media) {
    if (!media) return nil;
    for (NSString *key in @[ @"items", @"_items", @"carouselMedia", @"_carouselMedia", @"carousel_media" ]) {
        id items = ThetaValueForKey(media, key);
        if ([items isKindOfClass:[NSArray class]] && [(NSArray *)items count] > 0) {
            return items;
        }
    }
    return @[ media ];
}

static void theta_addPhotoURL(NSURL *imageURL, NSMutableArray *urlItems) {
    if (!imageURL.absoluteString.length || !urlItems) return;
    [urlItems addObject:@{
        @"url": imageURL.absoluteString,
        @"preview": [UIImage systemImageNamed:@"photo"] ?: [UIImage new],
        @"isVideo": @NO
    }];
}

static BOOL theta_videoHasDownloadablePayload(id video) {
    if (!video) return NO;
    if (theta_bestVideoURLFromVideo(video)) return YES;
    if (![video respondsToSelector:@selector(allVideoURLs)]) return NO;
    id set = nil;
    @try { set = [video performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
    if ([set isKindOfClass:[NSSet class]]) return [(NSSet *)set count] > 0;
    if ([set isKindOfClass:[NSArray class]]) return [(NSArray *)set count] > 0;
    return NO;
}

static BOOL theta_addVideoFromObject(id postItem, NSMutableArray *urlItems, NSMutableArray *hdVideos) {
    id video = theta_videoFromObject(postItem);
    if (!theta_videoHasDownloadablePayload(video) && !theta_videoHasDownloadablePayload(postItem)) {
        return NO;
    }
    NSURL *vurl = theta_bestVideoURLFromVideo(video);
    if (!vurl) vurl = theta_bestVideoURLFromVideo(postItem);

    if (video && hdVideos) {
        [hdVideos addObject:video];
        return YES;
    }
    if (vurl.absoluteString.length && urlItems) {
        [urlItems addObject:@{
            @"url": vurl.absoluteString,
            @"preview": [UIImage systemImageNamed:@"video"] ?: [UIImage new],
            @"isVideo": @YES
        }];
        return YES;
    }
    return NO;
}

/// Append URL dicts and/or IGVideo objects from one IGMedia (including carousel children).
/// `thumbnailFallback` is the grid cell model (has display photo even when media is sparse).
static void theta_appendMediaFromMedia(id media, id thumbnailFallback, NSMutableArray *urlItems, NSMutableArray *hdVideos) {
    if ((!media && !thumbnailFallback) || (!urlItems && !hdVideos)) return;

    id root = media ?: thumbnailFallback;
    NSArray *items = theta_carouselOrSelfItems(root);
    NSInteger addedBefore = (NSInteger)urlItems.count + (NSInteger)hdVideos.count;

    for (id postItem in items) {
        NSInteger mediaType = theta_mediaTypeOfObject(postItem);
        // IG: 1=photo, 2=video, 8=carousel (parent). Never treat 8 as video.
        BOOL explicitPhoto = (mediaType == 1);
        BOOL explicitVideo = (mediaType == 2);

        if (explicitVideo) {
            if (!theta_addVideoFromObject(postItem, urlItems, hdVideos)) {
                // Cover frame fallback
                NSURL *imageURL = theta_bestImageURLFromObject(postItem) ?: theta_bestImageURLFromObject(thumbnailFallback);
                theta_addPhotoURL(imageURL, urlItems);
            }
            continue;
        }

        if (explicitPhoto) {
            NSURL *imageURL = theta_bestImageURLFromObject(postItem);
            if (!imageURL) imageURL = theta_bestImageURLFromObject(root);
            if (!imageURL) imageURL = theta_bestImageURLFromObject(thumbnailFallback);
            theta_addPhotoURL(imageURL, urlItems);
            continue;
        }

        // Unknown / carousel child without type: real video payload wins, else photo/thumbnail.
        if (theta_addVideoFromObject(postItem, urlItems, hdVideos)) continue;
        NSURL *imageURL = theta_bestImageURLFromObject(postItem);
        if (!imageURL && postItem != root) imageURL = theta_bestImageURLFromObject(root);
        if (!imageURL) imageURL = theta_bestImageURLFromObject(thumbnailFallback);
        theta_addPhotoURL(imageURL, urlItems);
    }

    // Guarantee at least the grid thumbnail photo for this cell if nothing else extracted.
    NSInteger addedAfter = (NSInteger)urlItems.count + (NSInteger)hdVideos.count;
    if (addedAfter == addedBefore) {
        NSURL *imageURL = theta_bestImageURLFromObject(thumbnailFallback);
        if (!imageURL) imageURL = theta_bestImageURLFromObject(root);
        theta_addPhotoURL(imageURL, urlItems);
    }
}

static void saveMedia(id hostView) {
    @try {
        UIViewController *profileVC = theta_profileViewControllerFromView([hostView isKindOfClass:[UIView class]] ? hostView : nil);
        if (!profileVC) {
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"Open a user profile and try again." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }

        id profileFeedSource = theta_activeProfileFeedSource(profileVC);
        id networkSource = theta_networkSourceFromProfileFeedSource(profileFeedSource);
        NSArray *gridItems = theta_gridItemsFromNetworkSource(networkSource);
        NSArray *posts = theta_postsFromNetworkSource(networkSource);
        if (gridItems.count == 0 && posts.count == 0) {
            // Only treat as private when the user model says so AND we're not following.
            BOOL isPrivateBlocked = NO;
            @try {
                id user = nil;
                if ([profileVC respondsToSelector:@selector(user)]) {
                    user = [profileVC performSelector:@selector(user)];
                }
                BOOL isPrivate = NO;
                if ([user respondsToSelector:@selector(isPrivate)]) {
                    isPrivate = ((BOOL (*)(id, SEL))objc_msgSend)(user, @selector(isPrivate));
                } else if ([user respondsToSelector:@selector(isPrivateProfile)]) {
                    isPrivate = ((BOOL (*)(id, SEL))objc_msgSend)(user, @selector(isPrivateProfile));
                } else {
                    id priv = ThetaValueForKey(user, @"isPrivate");
                    if (!priv) priv = ThetaValueForKey(user, @"is_private");
                    if ([priv respondsToSelector:@selector(boolValue)]) isPrivate = [priv boolValue];
                }

                BOOL following = NO;
                id friendship = ThetaValueForKey(user, @"friendshipStatus");
                if (!friendship) friendship = ThetaValueForKey(user, @"_friendshipStatus");
                id followingVal = ThetaValueForKey(friendship, @"following");
                if (!followingVal) followingVal = ThetaValueForKey(friendship, @"is_following");
                if ([followingVal respondsToSelector:@selector(boolValue)]) {
                    following = [followingVal boolValue];
                } else if ([user respondsToSelector:@selector(following)]) {
                    following = ((BOOL (*)(id, SEL))objc_msgSend)(user, @selector(following));
                }

                isPrivateBlocked = isPrivate && !following;
            } @catch (__unused NSException *e) {}

            if (isPrivateBlocked) {
                [ThetaHelper showToastWithTitle:@"Can't save posts!" subtitle:@"This account is private." icon:[UIImage systemImageNamed:@"lock.fill"] autoHide:4 openURL:nil];
            } else {
                [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!"
                                             description:@"As of now, we can't find any posts.\n\nMake sure you are on the user's posts tab, scroll to load posts, then try again."
                                                 actions:@[ @{ @"title": @"Okay, thanks.", @"handler": ^(id sender) {} } ]];
            }
            return;
        }

        NSUInteger loadedPostCount = MAX(gridItems.count, posts.count);
        NSString *toastTitle = loadedPostCount > 1 ? @"Fetching media..." : @"Saving media...";
        NSString *toastDescription = loadedPostCount > 1 ? @"This may take a couple minutes." : @"This may take a few seconds.";
        [ThetaHelper showToastWithTitle:toastTitle subtitle:toastDescription icon:[UIImage systemImageNamed:@"arrow.clockwise"] autoHide:4 openURL:nil];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSMutableArray *urlItems = [NSMutableArray array];
            NSMutableArray *hdVideos = [NSMutableArray array];
            NSMutableSet *seenMedia = [NSMutableSet set];

            // Grid items first — matches the loaded profile grid the user sees, and thumbnails
            // always have a display photo even when full media payloads are sparse.
            NSMutableArray *candidates = [NSMutableArray array];
            if (gridItems.count) [candidates addObjectsFromArray:gridItems];
            if (posts.count) [candidates addObjectsFromArray:posts];

            for (id item in candidates) {
                id media = theta_mediaFromGridItem(item);
                id thumbnail = item;
                // If `item` is already IGMedia (from _posts), don't use it as thumbnail fallback.
                Class thumbCls = NSClassFromString(@"_TtC21IGMediaThumbnailModel21IGMediaThumbnailModel");
                if (thumbCls && ![item isKindOfClass:thumbCls]) {
                    // Still allow photo/video accessors on non-thumbnail items.
                    thumbnail = item;
                }
                if (!media && !thumbnail) continue;
                id identityObj = media ?: thumbnail;
                NSString *ident = theta_mediaIdentity(identityObj);
                if (ident && [seenMedia containsObject:ident]) continue;
                if (ident) [seenMedia addObject:ident];
                @try {
                    theta_appendMediaFromMedia(media, thumbnail, urlItems, hdVideos);
                } @catch (NSException *exception) {
                    NSLog(@"[Theta] Save Profile Posts item error: %@", exception);
                }
            }

            // Download real photo previews so MediaSelectionViewController doesn't show SF Symbol placeholders.
            NSMutableArray *readyItems = [NSMutableArray arrayWithCapacity:urlItems.count];
            for (NSUInteger i = 0; i < urlItems.count; i++) {
                [readyItems addObject:[NSNull null]];
            }
            dispatch_group_t previewGroup = dispatch_group_create();
            [urlItems enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger idx, BOOL *stop) {
                NSMutableDictionary *copy = [item mutableCopy];
                NSString *urlString = copy[@"url"];
                BOOL isVideo = [copy[@"isVideo"] boolValue];
                NSURL *previewURL = (!isVideo && urlString.length) ? [NSURL URLWithString:urlString] : nil;
                if (!previewURL) {
                    readyItems[idx] = [copy copy];
                    return;
                }
                dispatch_group_enter(previewGroup);
                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:previewURL];
                req.timeoutInterval = 10.0;
                [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
                [req setValue:@"https://www.instagram.com/" forHTTPHeaderField:@"Referer"];
                [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    UIImage *preview = (data.length && !error) ? [UIImage imageWithData:data] : nil;
                    if (preview && preview.size.width > 44.0 && preview.size.height > 44.0) {
                        copy[@"preview"] = preview;
                    }
                    readyItems[idx] = [copy copy];
                    dispatch_group_leave(previewGroup);
                }] resume];
            }];
            dispatch_group_wait(previewGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
            // Replace any timed-out slots with the original dicts.
            for (NSUInteger i = 0; i < urlItems.count; i++) {
                if (readyItems[i] == [NSNull null] || ![readyItems[i] isKindOfClass:[NSDictionary class]]) {
                    readyItems[i] = urlItems[i];
                }
            }

            NSInteger total = (NSInteger)readyItems.count + (NSInteger)hdVideos.count;
            void (^presentPicker)(void) = ^{
                if (total == 0) {
                    [ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"Found posts, but no downloadable media URLs." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:nil];
                    return;
                }

                if (total == 1 && readyItems.count == 1) {
                    @try {
                        MediaSelectionViewController *mediaSelectionVC = [MediaSelectionViewController new];
                        [mediaSelectionVC downloadMediaToTemp:[NSURL URLWithString:readyItems[0][@"url"]] completion:^(NSString *filePath, NSString *fileExtension) {
                            if (!filePath || !fileExtension) return;
                            [mediaSelectionVC saveFilesToCameraRoll:[NSMutableArray arrayWithObject:filePath]
                                                         extensions:[NSMutableArray arrayWithObject:fileExtension]];
                        }];
                    } @catch (NSException *exception) {
                        NSLog(@"[Theta] Save Profile Posts single: %@", exception);
                    }
                    return;
                }

                @try {
                    MediaSelectionViewController *mediaSelectionVC =
                        [[MediaSelectionViewController alloc] initWithMediaItems:readyItems
                                                                        hdVideos:hdVideos
                                                                       withCount:total];
                    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
                    [[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
                } @catch (NSException *exception) {
                    NSLog(@"[Theta] Save Profile Posts multi: %@", exception);
                    [ThetaHelper showToastWithTitle:@"Save failed" subtitle:exception.reason ?: @"Couldn't open media picker." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:nil];
                }
            };

            dispatch_async(dispatch_get_main_queue(), ^{
                if (hdVideos.count > 0) {
                    [MediaSelectionViewController preloadHDVideoThumbnails:hdVideos completion:^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            presentPicker();
                        });
                    }];
                } else {
                    presentPicker();
                }
            });
        });
    } @catch (NSException *exception) {
        NSLog(@"[Theta] Save Profile Posts: %@", exception);
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Save failed" subtitle:exception.reason ?: @"Unexpected error." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
    }
}

static void (*orig_followStatusIndicator)(UIView *self, SEL _cmd);
static void hook_followStatusIndicator(UIView *self, SEL _cmd) {
    if (orig_followStatusIndicator) orig_followStatusIndicator(self, _cmd);

    UIViewController *profileVC = theta_profileViewControllerFromView(self);
    if (!profileVC) {
        return;
    }

    IGUser *user = nil;
    @try {
        if ([profileVC respondsToSelector:@selector(user)]) {
            user = [profileVC performSelector:@selector(user)];
        }
    } @catch (__unused NSException *e) {
        return;
    }
    if (!user) {
        return;
    }

    id context = ThetaValueForKey(profileVC, @"_navBarContext");
    if (!context) context = ThetaValueForKey(profileVC, @"navBarContext");
    BOOL currentUser = context ? [ThetaValueForKey(context, @"isCurrentUser") boolValue] : NO;
    if (currentUser) {
        return;
    }

    BOOL doesFollow = NO;
    @try {
        if ([user respondsToSelector:@selector(followsCurrentUser)]) {
            doesFollow = [user followsCurrentUser];
        }
    } @catch (__unused NSException *e) {}

    BOOL showFollowIndicator = [[NSUserDefaults standardUserDefaults] boolForKey:@"Follow Status Indicator_Enabled"];
    BOOL showSaveButton = [[NSUserDefaults standardUserDefaults] boolForKey:@"Save Profile Posts_Enabled"];

    for (UIView *view in [self subviews]) {
        if (![view isKindOfClass:NSClassFromString(@"IGCoreTextView")]) {
            continue;
        }

        id styledString = ThetaValueForKey(view, @"styledString");
        if (!styledString || ![styledString respondsToSelector:@selector(attributedString)]) {
            continue;
        }

        NSMutableAttributedString *attributedString = [styledString attributedString];
        if (!attributedString) {
            attributedString = [[NSMutableAttributedString alloc] init];
        } else if (![attributedString isKindOfClass:[NSMutableAttributedString class]]) {
            attributedString = [[NSMutableAttributedString alloc] initWithAttributedString:attributedString];
        }

        NSString *currentString = attributedString.string ?: @"";
        NSArray<NSString *> *indicators = @[ @" | ✅", @" | ❌", @" ✅", @" ❌" ];
        for (NSString *indicator in indicators) {
            NSRange range = [currentString rangeOfString:indicator options:NSBackwardsSearch];
            if (range.location != NSNotFound && NSMaxRange(range) == currentString.length) {
                [attributedString deleteCharactersInRange:range];
                break;
            }
        }

        NSString *suffix = (doesFollow ? @" | ✅" : @" | ❌");

        if (showFollowIndicator) {
            if ([styledString respondsToSelector:@selector(appendString:)]) {
                if ([styledString respondsToSelector:@selector(setAttributedString:)]) {
                    [styledString setAttributedString:attributedString];
                }
                [styledString appendString:suffix];
            } else {
                NSDictionary *attrs = nil;
                if (attributedString.length > 0) {
                    attrs = [attributedString attributesAtIndex:attributedString.length - 1 effectiveRange:NULL];
                }
                NSAttributedString *toAppend = attrs ? [[NSAttributedString alloc] initWithString:suffix attributes:attrs] : [[NSAttributedString alloc] initWithString:suffix];
                [attributedString appendAttributedString:toAppend];
                if ([styledString respondsToSelector:@selector(setAttributedString:)]) {
                    [styledString setAttributedString:attributedString];
                }
            }
        } else {
            if ([styledString respondsToSelector:@selector(setAttributedString:)]) {
                [styledString setAttributedString:attributedString];
            }
        }

        @try {
            ThetaSetValueForKey(view, styledString, @"styledString");

            UIButton *saveButton = nil;
            for (UIView *sub in [self subviews]) {
                if ([sub isKindOfClass:[UIButton class]] && sub.tag == kThetaFollowSaveButtonTag) {
                    saveButton = (UIButton *)sub;
                    break;
                }
            }
            if (showSaveButton) {
                self.userInteractionEnabled = YES;
                self.clipsToBounds = NO;
                if (!saveButton) {
                    saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
                    saveButton.tag = kThetaFollowSaveButtonTag;
                    [saveButton setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
                    [saveButton setTintColor:[ThetaHelper iotaPinkColor]];
                    saveButton.userInteractionEnabled = YES;
                    saveButton.exclusiveTouch = YES;
                    saveButton.accessibilityIdentifier = @"theta_save_profile_button";
                    ThetaSaveMediaButtonTarget *target = [ThetaSaveMediaButtonTarget new];
                    target.hostView = self;
                    objc_setAssociatedObject(saveButton, @selector(onTap:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                    [saveButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                        [target onTap:saveButton];
                    }] forControlEvents:UIControlEventTouchUpInside];

                    ThetaSetCaptureHiding(saveButton);
                    [self addSubview:saveButton];
                } else {
                    // Keep hostView fresh across layout passes
                    ThetaSaveMediaButtonTarget *target = objc_getAssociatedObject(saveButton, @selector(onTap:));
                    if ([target isKindOfClass:[ThetaSaveMediaButtonTarget class]]) {
                        target.hostView = self;
                    }
                }

                [saveButton sizeToFit];
                CGRect btnFrame = saveButton.frame;
                btnFrame.size.width = MAX(44.0, btnFrame.size.width);
                btnFrame.size.height = MAX(44.0, btnFrame.size.height);
                CGFloat spacing = 2.0;
                CGRect vframe = view.frame;
                btnFrame.origin.x = CGRectGetMaxX(vframe) + spacing;
                btnFrame.origin.y = CGRectGetMidY(vframe) - btnFrame.size.height / 2.0;
                CGFloat maxX = self.bounds.size.width - 2.0;
                if (CGRectGetMaxX(btnFrame) > maxX) {
                    btnFrame.origin.x = maxX - btnFrame.size.width;
                }
                // Keep inside parent bounds so hit-testing works
                if (btnFrame.origin.x < 0) btnFrame.origin.x = 0;
                if (btnFrame.origin.y < 0) btnFrame.origin.y = 0;
                saveButton.frame = btnFrame;
                saveButton.hidden = NO;
                [self bringSubviewToFront:saveButton];
            } else if (saveButton) {
                [saveButton removeFromSuperview];
            }

            [view setNeedsLayout];
            [view setNeedsDisplay];
        } @catch (NSException *exception) {
            NSLog(@"[Theta] FollowStatusIndicator: %@", exception);
        }
    }
}

void THRegisterFollowStatusIndicatorHooks(void) {
    Class nameView = ThetaFirstClass(@[
        @"_TtC23IGProfileHeaderIdentity31IGProfileHeaderIdentityNameView",
        @"IGProfileHeaderIdentity.IGProfileHeaderIdentityNameView"
    ]);
    NullHookMessageIfPresent(nameView, @selector(layoutSubviews), (void *)hook_followStatusIndicator, &orig_followStatusIndicator);
}
