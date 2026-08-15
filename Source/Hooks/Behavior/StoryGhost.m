#import <objc/runtime.h>

extern void THStorySeenReceiptNetworkGuardEnter(void);
extern void THStorySeenReceiptNetworkGuardEnterWithContext(id fullscreenSectionController, id storyViewer);
extern void THStorySeenReceiptNetworkGuardResealAfterMark(id fullscreenSectionController, id storyViewer);
extern void THStorySeenReceiptNetworkGuardLeave(void);

@class IGVideo;
static void downloadHDVideo(IGVideo *inputVideo);
static UIImage *thetaColoredSystemSymbol(NSString *name, UIColor *color);

static const NSInteger kThetaStoryButtonTag = 77001;

static char kThetaBtnTouchUpInsideBlockKey;
static char kThetaBtnTouchDownBlockKey;
static void *UIGestureBlockKey = &UIGestureBlockKey;

@interface UIButton (BlockTarget)
- (void)handleControlEvent:(UIControlEvents)event withBlock:(void (^)(id sender))block;
@end

@implementation UIButton (BlockTarget)
- (void)handleControlEvent:(UIControlEvents)event withBlock:(void (^)(id sender))block {
    // Separate keys so TouchDown + TouchUpInside don't clobber each other.
    if (event == UIControlEventTouchDown) {
        objc_setAssociatedObject(self, &kThetaBtnTouchDownBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [self addTarget:self action:@selector(theta_fireTouchDownBlock:) forControlEvents:UIControlEventTouchDown];
        return;
    }
    objc_setAssociatedObject(self, &kThetaBtnTouchUpInsideBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self addTarget:self action:@selector(theta_fireTouchUpInsideBlock:) forControlEvents:event];
}

- (void)theta_fireTouchUpInsideBlock:(id)sender {
    void (^block)(id) = objc_getAssociatedObject(self, &kThetaBtnTouchUpInsideBlockKey);
    if (block) {
        @try { block(sender ?: self); } @catch (__unused NSException *e) {}
    }
}

- (void)theta_fireTouchDownBlock:(id)sender {
    void (^block)(id) = objc_getAssociatedObject(self, &kThetaBtnTouchDownBlockKey);
    if (block) {
        @try { block(sender ?: self); } @catch (__unused NSException *e) {}
    }
}
@end

@interface UIGestureRecognizer (BlockTarget)
- (void)addActionBlock:(void (^)(UIGestureRecognizer *sender))block;
@end

@implementation UIGestureRecognizer (BlockTarget)
- (void)addActionBlock:(void (^)(UIGestureRecognizer *sender))block {
    objc_setAssociatedObject(self, UIGestureBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self addTarget:self action:@selector(theta_gestureCallActionBlock:)];
}

- (void)theta_gestureCallActionBlock:(UIGestureRecognizer *)sender {
    void (^block)(UIGestureRecognizer *) = objc_getAssociatedObject(self, UIGestureBlockKey);
    if (block) {
        @try { block(sender); } @catch (__unused NSException *e) {}
    }
}
@end

static void thetaStoryAddTap(UIButton *button, void (^handler)(void)) {
    if (!button || !handler) return;
    void (^copied)(void) = [handler copy];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        @try { copied(); } @catch (__unused NSException *e) {}
    }] forControlEvents:UIControlEventTouchUpInside];
}

static void thetaStorySkipIfEnabled(id firstDelegate) {
    if (!ENABLED(@"Skip On Seen") || !firstDelegate) return;
    if (![firstDelegate respondsToSelector:@selector(fullscreenOverlayDidTapNextStoryButton:)]) return;
    @try {
        [firstDelegate fullscreenOverlayDidTapNextStoryButton:nil];
    } @catch (__unused NSException *e) {}
}

static id thetaStorySectionControllerFromCell(IGStoryFullscreenCell *cell) {
    if (!cell) return nil;
    id section = nil;
    @try {
        if ([cell respondsToSelector:@selector(delegate)]) {
            section = [cell performSelector:@selector(delegate)];
        }
    } @catch (__unused NSException *e) {}
    if (!section) {
        id container = ThetaValueForKey(cell, @"containerView");
        section = ThetaValueForKey(container, @"delegate");
    }
    return section;
}

static id thetaStoryViewerFromCell(IGStoryFullscreenCell *cell) {
    Class viewerCls = NSClassFromString(@"IGStoryViewerViewController");
    if (!viewerCls) return nil;

    id section = thetaStorySectionControllerFromCell(cell);
    id candidate = ThetaValueForKey(section, @"delegate");
    if ([candidate isKindOfClass:viewerCls]) return candidate;

    // Responder / superview walk — section.delegate is not always the viewer on newer IG.
    UIView *view = (UIView *)cell;
    while (view) {
        UIResponder *r = view.nextResponder;
        while (r) {
            if ([r isKindOfClass:viewerCls]) return r;
            r = r.nextResponder;
        }
        view = view.superview;
    }

    for (NSString *key in @[ @"storyViewer", @"viewController", @"parentViewController", @"delegate" ]) {
        id fromKey = ThetaValueForKey(section, key);
        if ([fromKey isKindOfClass:viewerCls]) return fromKey;
    }

    // Presented / top VC fallback
    @try {
        UIViewController *top = [ThetaHelper topViewController];
        UIViewController *p = top;
        while (p) {
            if ([p isKindOfClass:viewerCls]) return p;
            p = p.parentViewController;
        }
        p = top;
        while (p) {
            if ([p isKindOfClass:viewerCls]) return p;
            p = p.presentingViewController;
        }
    } @catch (__unused NSException *e) {}

    return nil; // never return a non-viewer object
}

static BOOL thetaStoryMarkItemAsSeen(IGStoryFullscreenCell *cell, id item) {
    if (!cell || !item) return NO;
    id section = thetaStorySectionControllerFromCell(cell);
    id viewer = thetaStoryViewerFromCell(cell);
    Class viewerCls = NSClassFromString(@"IGStoryViewerViewController");
    SEL sel = @selector(fullscreenSectionController:didMarkItemAsSeen:);
    if (!viewer || (viewerCls && ![viewer isKindOfClass:viewerCls]) || ![viewer respondsToSelector:sel]) {
        NSLog(@"[Theta] StoryGhost: no viewer for didMarkItemAsSeen (viewer=%@)", NSStringFromClass([viewer class]));
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(viewer, sel, section, item);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[Theta] StoryGhost: didMarkItemAsSeen threw %@", e);
        return NO;
    }
}

static NSURL *thetaStoryURLFromCandidate(id cand) {
    if (!cand) return nil;
    if ([cand isKindOfClass:[NSURL class]]) return cand;
    if ([cand isKindOfClass:[NSString class]]) {
        NSURL *u = [NSURL URLWithString:(NSString *)cand];
        return u.scheme.length ? u : nil;
    }
    id url = ThetaValueForKey(cand, @"url");
    if ([url isKindOfClass:[NSURL class]]) return url;
    if ([url isKindOfClass:[NSString class]]) {
        NSURL *u = [NSURL URLWithString:(NSString *)url];
        return u.scheme.length ? u : nil;
    }
    return nil;
}

static NSURL *thetaStoryBestImageURLFromMedia(id media) {
    if (!media) return nil;
    // IG 441+: IGMedia exposes hintableImageURLs instead of isPhotoMedia/photo.
    if ([media respondsToSelector:@selector(hintableImageURLs)]) {
        id urls = nil;
        @try { urls = [media performSelector:@selector(hintableImageURLs)]; } @catch (__unused NSException *e) {}
        if ([urls isKindOfClass:[NSArray class]] && [urls count] > 0) {
            NSURL *u = thetaStoryURLFromCandidate([urls lastObject]);
            if (u) return u;
            for (id o in urls) {
                u = thetaStoryURLFromCandidate(o);
                if (u) return u;
            }
        } else if ([urls isKindOfClass:[NSSet class]]) {
            for (id o in (NSSet *)urls) {
                NSURL *u = thetaStoryURLFromCandidate(o);
                if (u) return u;
            }
        }
    }

    id photo = nil;
    if ([media respondsToSelector:@selector(photo)]) {
        @try { photo = [media performSelector:@selector(photo)]; } @catch (__unused NSException *e) {}
    }
    if (!photo) photo = ThetaValueForKey(media, @"photo");
    if (!photo) photo = ThetaValueForKey(media, @"rawPhoto");

    NSArray *versions = ThetaValueForKey(photo, @"_originalImageVersions");
    if (![versions isKindOfClass:[NSArray class]]) versions = ThetaValueForKey(photo, @"imageVersions");
    if (![versions isKindOfClass:[NSArray class]]) versions = ThetaValueForKey(media, @"imageVersions");
    if ([versions isKindOfClass:[NSArray class]] && versions.count > 0) {
        NSURL *u = thetaStoryURLFromCandidate([versions lastObject]);
        if (u) return u;
    }
    return nil;
}

static id thetaStoryVideoObjectFromMedia(id media) {
    if (!media) return nil;
    id video = nil;
    if ([media respondsToSelector:@selector(video)]) {
        @try { video = [media performSelector:@selector(video)]; } @catch (__unused NSException *e) {}
    }
    if (!video) video = ThetaValueForKey(media, @"video");
    if (!video) video = ThetaValueForKey(media, @"rawVideo");
    return video;
}

static void thetaStorySaveURL(NSURL *url, BOOL isVideoHint) {
    if (![url isKindOfClass:[NSURL class]]) return;
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error || !location) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Save failed" subtitle:error.localizedDescription ?: @"Download error" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
                }
            });
            return;
        }
        NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *ext = url.pathExtension.length ? url.pathExtension : (isVideoHint ? @"mp4" : @"jpg");
        NSString *newFilename = [NSString stringWithFormat:@"story-%@.%@", [[NSUUID UUID] UUIDString], ext];
        NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
        NSError *fileError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&fileError];
        if (fileError) return;

        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
        if (saveMethod == 0) {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                if (isVideoHint || [ext.lowercaseString isEqualToString:@"mp4"] || [ext.lowercaseString isEqualToString:@"mov"]) {
                    [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                } else {
                    [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                }
            } completionHandler:^(BOOL success, NSError * _Nullable err) {
                [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        if (success) {
                            [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        } else {
                            [ThetaHelper showToastWithTitle:@"Save failed" subtitle:err.localizedDescription ?: @"Photos error" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
                        }
                    }
                });
            }];
        } else {
            NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            NSString *destPath = [audioNotesDir stringByAppendingPathComponent:newFilename];
            [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Saved!" subtitle:@"Saved to Documents." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:nil];
                }
            });
        }
    }];
    [downloadTask resume];
    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Saving…" subtitle:@"Downloading story media" icon:[UIImage systemImageNamed:@"arrow.down.circle"] autoHide:2 openURL:nil];
    }
}

static NSString *thetaStoryOwnerKey(id owner) {
    if (!owner) return nil;
    @try {
        if ([owner respondsToSelector:@selector(name)]) {
            id n = [owner performSelector:@selector(name)];
            if ([n isKindOfClass:[NSString class]] && [(NSString *)n length]) return [(NSString *)n lowercaseString];
        }
    } @catch (__unused NSException *e) {}
    id n = ThetaValueForKey(owner, @"username");
    if (![n isKindOfClass:[NSString class]] || ![n length]) n = ThetaValueForKey(owner, @"pk");
    if ([n isKindOfClass:[NSString class]] || [n isKindOfClass:[NSNumber class]]) {
        return [[[n description] lowercaseString] copy];
    }
    return [NSString stringWithFormat:@"%p", owner];
}
static void downloadButtonTapped(IGStoryFullscreenCell *self) {
	[ThetaHelper performHapticFeedbackIfEnabled];

	id firstDelegate = thetaStorySectionControllerFromCell(self);
	id currentMedia = nil;
	@try {
		if ([firstDelegate respondsToSelector:@selector(currentStoryItem)]) {
			currentMedia = [firstDelegate performSelector:@selector(currentStoryItem)];
		}
	} @catch (__unused NSException *e) {}
	if (!currentMedia) {
		id viewer = thetaStoryViewerFromCell(self);
		@try {
			if ([viewer respondsToSelector:@selector(currentStoryItem)]) {
				currentMedia = [viewer performSelector:@selector(currentStoryItem)];
			}
		} @catch (__unused NSException *e) {}
	}
	if (!currentMedia) {
		if (ENABLED(@"Show Banners")) {
			[ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"Couldn't find the current story item." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
		}
		return;
	}

	// Prefer image URLs (works for photo stories on IG 441+ without isPhotoMedia).
	NSURL *imageURL = thetaStoryBestImageURLFromMedia(currentMedia);
	id video = thetaStoryVideoObjectFromMedia(currentMedia);

	// Progressive / dash URLs directly on the story item.
	NSURL *directVideoURL = nil;
	if ([currentMedia respondsToSelector:@selector(allVideoURLs)]) {
		id set = nil;
		@try { set = [currentMedia performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
		if ([set isKindOfClass:[NSSet class]]) directVideoURL = thetaStoryURLFromCandidate([(NSSet *)set anyObject]);
		else if ([set isKindOfClass:[NSArray class]] && [set count]) directVideoURL = thetaStoryURLFromCandidate([set lastObject]);
	}
	if (!directVideoURL && video && [video respondsToSelector:@selector(allVideoURLs)]) {
		id set = nil;
		@try { set = [video performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
		if ([set isKindOfClass:[NSSet class]]) directVideoURL = thetaStoryURLFromCandidate([(NSSet *)set anyObject]);
	}

	NSInteger mediaType = -1;
	@try {
		if ([currentMedia respondsToSelector:@selector(mediaTypeEnum)]) {
			mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(currentMedia, @selector(mediaTypeEnum));
		} else if ([currentMedia respondsToSelector:@selector(mediaType)]) {
			mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(currentMedia, @selector(mediaType));
		}
	} @catch (__unused NSException *e) {}

	BOOL looksVideo = (mediaType == 2) || (video != nil) || (directVideoURL != nil);
	BOOL looksPhoto = (mediaType == 1) || (imageURL != nil && !looksVideo);

	if (looksPhoto && imageURL) {
		thetaStorySaveURL(imageURL, NO);
		return;
	}

	if (video) {
		@try {
			downloadHDVideo(video);
			return;
		} @catch (NSException *exception) {
			NSLog(@"Error downloading video: %@", exception);
		}
	}

	if (directVideoURL) {
		thetaStorySaveURL(directVideoURL, YES);
		return;
	}

	// Last resort: image URL even if type detection was ambiguous.
	if (imageURL) {
		thetaStorySaveURL(imageURL, NO);
		return;
	}

	if (ENABLED(@"Show Banners")) {
		[ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"No downloadable photo/video URL on this story." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
	}
}

static void downloadAllMedia(IGStoryFullscreenCell *self) {
	id firstDelegate = nil;
	@try {
		if ([self respondsToSelector:@selector(delegate)]) {
			firstDelegate = [self performSelector:@selector(delegate)];
		} else if ([self respondsToSelector:@selector(valueForKey:)]) {
			id container = [self valueForKey:@"containerView"];
			if (container && [container respondsToSelector:@selector(valueForKey:)]) {
				firstDelegate = [container valueForKey:@"delegate"];
			}
		}
	} @catch (__unused NSException *e) {}
	if (!firstDelegate) return;

	id secondDelegate = nil;
	@try {
		secondDelegate = [firstDelegate valueForKey:@"delegate"];
	} @catch (__unused NSException *e) {}
	if (!secondDelegate) return;

	id viewModel = nil;
	@try {
		viewModel = [secondDelegate valueForKey:@"currentViewModel"];
	} @catch (__unused NSException *e) {}
	if (!viewModel) return;

	NSArray *items = nil;
	@try {
		items = [viewModel valueForKey:@"items"];
	} @catch (__unused NSException *e) {}
	if (![items isKindOfClass:[NSArray class]] || items.count == 0) return;

	NSMutableArray *mediaItems = [NSMutableArray array];
	NSMutableArray *igvideos = [NSMutableArray array];
	//NSString *toastTitle = currentMedia.items.count > 1 ? @"Fetching media..." : @"Saving media...";
	NSString *toastTitle = items.count > 1 ? @"Fetching media..." : @"Saving media...";
	if (ENABLED(@"Show Banners")) {
		UIImage *fetchingImage = [UIImage systemImageNamed:@"arrow.clockwise"];
		[ThetaHelper showToastWithTitle:toastTitle subtitle:@"This will only take a second." icon:fetchingImage autoHide:4 openURL:nil];
	}
	NSURL *url = nil;
	UIImage *preview = nil;
	if (viewModel) {
		for (id item in items) {
			if (item && [item isKindOfClass:NSClassFromString(@"IGMedia")]) {
				id media = item;
				BOOL isPhoto = NO;
				@try {
					if ([media respondsToSelector:@selector(isPhotoMedia)]) {
						isPhoto = ((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(isPhotoMedia));
					} else {
						id flag = [media valueForKey:@"isPhotoMedia"];
						if ([flag isKindOfClass:[NSNumber class]]) {
							isPhoto = [flag boolValue];
						}
					}
				} @catch (__unused NSException *e) {}
				if (isPhoto) {
					@try {
						id photo = nil;
						if ([media respondsToSelector:@selector(photo)]) {
							photo = [media performSelector:@selector(photo)];
						}
						if (!photo) continue;
						NSArray *originalImageVersions = nil;
						@try {
							originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
						} @catch (__unused NSException *e) {}
						id photoURL;
						if ([originalImageVersions isKindOfClass:[NSArray class]] && [originalImageVersions count] > 1) {
							photoURL = [originalImageVersions lastObject];
							@try { url = [photoURL valueForKey:@"url"]; } @catch (__unused NSException *e) {}
							if ([url isKindOfClass:[NSURL class]]) {
								NSData *data = [NSData dataWithContentsOfURL:url];
								if (data) preview = [UIImage imageWithData:data];
							} else {
								url = nil;
							}
						}
					} @catch (NSException *exception) {
						NSLog(@"Error downloading image: %@", exception);
					}
				} else {
					@try {
						id video = nil;
						if ([media respondsToSelector:@selector(video)]) {
							video = [media performSelector:@selector(video)];
						}
						if (video) {
							[igvideos addObject:video];
						}
					} @catch (NSException *exception) {
						NSLog(@"Error downloading video: %@", exception);
					}
				}
			}
			
			if (url && url.absoluteString) {  // Make sure we have a valid URL
				NSDictionary *mediaDict = @{ @"url": url.absoluteString, @"preview": preview ?: [UIImage systemImageNamed:@"photo"] };
				[mediaItems addObject:mediaDict];
				url = nil;  // Reset URL to avoid duplicates
				preview = nil;
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			// If we have HD videos always use the HD path
			if (igvideos.count > 0) {
				// Preload HD video thumbnails before showing the view controller
				[MediaSelectionViewController preloadHDVideoThumbnails:igvideos completion:^{
					dispatch_async(dispatch_get_main_queue(), ^{
						MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:mediaItems hdVideos:igvideos withCount:mediaItems.count + igvideos.count];
						UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
						[[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
					});
				}];
				return;
			}

			// Handle regular media items
			if (mediaItems.count == 1) {
				NSDictionary *mediaDict = mediaItems.firstObject;
				NSURL *url = [NSURL URLWithString:mediaDict[@"url"]];
				if (url) {
					MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] init];
					[mediaSelectionVC downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension){
						if (ENABLED(@"Show Banners")) {
                            [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        }
					}];
				}
				return;
			}

			if (mediaItems.count > 1) {
				MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:mediaItems withCount:mediaItems.count];
				UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
											[[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
			}
		});
	}
}

/// Mark as seen on this device only (`Seen Receipts Stay Local`). Tap = current item; long-press = every item in this reel.
static void thetaLocalSeenResolveDelegates(IGStoryFullscreenCell *self, id *outFirst, id *outSecond) {
    id firstDelegate = thetaStorySectionControllerFromCell(self);
    id secondDelegate = thetaStoryViewerFromCell(self);
    if (outFirst) *outFirst = firstDelegate;
    if (outSecond) *outSecond = secondDelegate;
}

/// Resolves NSArray of objects acceptable for `-fullscreenSectionController:didMarkItemAsSeen:` (often `IGStoryItem`, not bare `IGMedia`).
static NSArray *theta_storyResolvedItemsForMarkAll(id firstDelegate, id secondDelegate) {
    id vm = nil;
    @try { vm = [firstDelegate valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) @try { vm = [secondDelegate valueForKey:@"currentViewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) @try { vm = [secondDelegate valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) return nil;

    NSArray * (^bundleFromKeys)(id) = ^NSArray *(id model) {
        for (NSString *key in @[ @"storyItems", @"items", @"sortedStoryItems", @"reelItems", @"mediaItems" ]) {
            NSArray *a = nil;
            @try {
                id o = [model valueForKey:key];
                if ([o isKindOfClass:[NSArray class]])
                    a = (NSArray *)o;
            } @catch (__unused NSException *e) {}
            if (a.count > 0u)
                return a;
        }
        return nil;
    };

    NSArray *bucket = bundleFromKeys(vm);
    if (bucket.count == 0u)
        return nil;

    id cur = nil;
    @try {
        if (firstDelegate && [firstDelegate respondsToSelector:@selector(currentStoryItem)])
            cur = [firstDelegate performSelector:@selector(currentStoryItem)];
    } @catch (__unused NSException *e) {}

    Class curCls = cur ? object_getClass(cur) : Nil;
    Class mediaCls = NSClassFromString(@"IGMedia");
    Class storyItemCls = NSClassFromString(@"IGStoryItem");

    if (curCls && bucket.count && [bucket.firstObject isKindOfClass:curCls])
        return bucket;

    if (storyItemCls && mediaCls && bucket.count && [bucket.firstObject isKindOfClass:mediaCls]) {
        NSArray *alternate = nil;
        for (NSString *key in @[ @"storyItems", @"sortedStoryItems", @"storyItemList", @"items" ]) {
            @try {
                id o = [vm valueForKey:key];
                if ([o isKindOfClass:[NSArray class]] && [(NSArray *)o count] > 0u &&
                    [((NSArray *)o).firstObject isKindOfClass:storyItemCls])
                    alternate = (NSArray *)o;
            } @catch (__unused NSException *e) {}
            if (alternate.count)
                break;
        }
        if (alternate.count)
            return alternate;

        /* Last resort: map each IGMedia from `bucket` onto story items gathered from parallel arrays / pk. */
        NSMutableArray *truthItems = [NSMutableArray array];
        for (NSString *key in @[ @"storyItems", @"sortedStoryItems", @"storyItemList", @"items" ]) {
            @try {
                id o = [vm valueForKey:key];
                if (![o isKindOfClass:[NSArray class]])
                    continue;
                for (id cand in (NSArray *)o) {
                    if ([cand isKindOfClass:storyItemCls])
                        [truthItems addObject:cand];
                }
            } @catch (__unused NSException *e) {}
        }
        NSArray *truth = truthItems.count ? truthItems : @[];

        NSMutableArray *out = [NSMutableArray arrayWithCapacity:bucket.count];
        for (id media in bucket) {
            id matched = nil;
            for (id cand in truth) {
                id m = nil;
                @try { m = [cand valueForKey:@"media"]; } @catch (__unused NSException *e) {}
                if (m == media || (m && media && [(id)m isEqual:(id)media])) {
                    matched = cand;
                    break;
                }
            }
            if (!matched && storyItemCls) {
                for (id cand in truth) {
                    NSString *pk1 = nil, *pk2 = nil;
                    @try {
                        id pkMed = nil;
                        @try { pkMed = [media valueForKey:@"pk"]; } @catch (__unused NSException *e) {}
                        if (pkMed) pk1 = [pkMed description];
                        id cm = nil;
                        @try { cm = [cand valueForKey:@"media"]; } @catch (__unused NSException *e) {}
                        if (cm) pk2 = [[[cm valueForKey:@"pk"] description] ?: @"" copy];
                    } @catch (__unused NSException *e) {}
                    if (pk1.length && pk2.length && [pk1 isEqualToString:pk2]) {
                        matched = cand;
                        break;
                    }
                }
            }
            [out addObject:matched ?: media];
        }
        return out;
    }

    return bucket;
}

static void thetaLocalSeenMarkCurrent(IGStoryFullscreenCell *self) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    [ThetaHelper performHapticFeedbackIfEnabled];
    id firstDelegate = nil;
    id secondDelegate = nil;
    thetaLocalSeenResolveDelegates(self, &firstDelegate, &secondDelegate);
    if (!firstDelegate || !secondDelegate) {
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Story viewer not found." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
        return;
    }
    id currentItem = nil;
    @try {
        if ([firstDelegate respondsToSelector:@selector(currentStoryItem)])
            currentItem = [firstDelegate performSelector:@selector(currentStoryItem)];
    } @catch (__unused NSException *e) {}
    if (!currentItem) return;

    THStorySeenReceiptNetworkGuardEnterWithContext(firstDelegate, secondDelegate);
    BOOL ghostOn = ENABLED(@"Story Ghost");
    if (ghostOn) shouldBeSeen = YES;
    BOOL ok = thetaStoryMarkItemAsSeen(self, currentItem);
    if (ghostOn) shouldBeSeen = NO;
    THStorySeenReceiptNetworkGuardLeave();

    if (ENABLED(@"Show Banners")) {
        if (ok) {
            [ThetaHelper showToastWithTitle:@"Marked on this device"
                                    subtitle:@"Stories clear here; receipts are not sent."
                                        icon:[UIImage systemImageNamed:@"iphone"]
                                    autoHide:3
                                     openURL:nil];
        } else {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Couldn't update seen state." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
    }
    if (ok) thetaStorySkipIfEnabled(firstDelegate);
}

static void thetaLocalSeenMarkAll(IGStoryFullscreenCell *self) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    [ThetaHelper performHapticFeedbackIfEnabled];
    id firstDelegate = nil;
    id secondDelegate = nil;
    thetaLocalSeenResolveDelegates(self, &firstDelegate, &secondDelegate);
    if (!firstDelegate || !secondDelegate) return;

    NSArray *items = theta_storyResolvedItemsForMarkAll(firstDelegate, secondDelegate);
    if (![items isKindOfClass:[NSArray class]] || items.count == 0u) return;

    /* Only the item aligned with `-currentStoryItem` is honored; iterate by retargeting the playhead between marks (restore after). */
    id priorFocused = nil;
    @try {
        if ([firstDelegate respondsToSelector:@selector(currentStoryItem)])
            priorFocused = [firstDelegate performSelector:@selector(currentStoryItem)];
    } @catch (__unused NSException *e) {}

    THStorySeenReceiptNetworkGuardEnterWithContext(firstDelegate, secondDelegate);
    BOOL ghostOn = ENABLED(@"Story Ghost");
    if (ghostOn) shouldBeSeen = YES;
    @try {
        for (id item in items) {
            if (!item) continue;
            @try {
                if ([firstDelegate respondsToSelector:@selector(setCurrentStoryItem:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(firstDelegate, @selector(setCurrentStoryItem:), item);
                else
                    ThetaSetValueForKey(firstDelegate, item, @"currentStoryItem");
            } @catch (__unused NSException *e) {}
            (void)thetaStoryMarkItemAsSeen(self, item);
        }
    } @catch (__unused NSException *e) {}
    if (ghostOn) shouldBeSeen = NO;
    THStorySeenReceiptNetworkGuardLeave();

    if (priorFocused) {
        @try {
            if ([firstDelegate respondsToSelector:@selector(setCurrentStoryItem:)])
                ((void (*)(id, SEL, id))objc_msgSend)(firstDelegate, @selector(setCurrentStoryItem:), priorFocused);
            else
                ThetaSetValueForKey(firstDelegate, priorFocused, @"currentStoryItem");
        } @catch (__unused NSException *e) {}
    }

    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"All marked on this device"
                                subtitle:@"Receipts are not sent."
                                    icon:[UIImage systemImageNamed:@"iphone"]
                                autoHide:3
                                 openURL:nil];
    }
    thetaStorySkipIfEnabled(firstDelegate);
}

static void handleLocalSeenTap(IGStoryFullscreenCell *self, UIButton *sender) {
    thetaLocalSeenMarkCurrent(self);
}

static void handleLocalSeenLongPress(IGStoryFullscreenCell *self, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan)
        thetaLocalSeenMarkAll(self);
}

static void seenButtonPressedAll(IGStoryFullscreenCell *self) {
    id firstDelegate = thetaStorySectionControllerFromCell(self);
    id secondDelegate = thetaStoryViewerFromCell(self);
    if (!firstDelegate || !secondDelegate) return;

    NSArray *items = theta_storyResolvedItemsForMarkAll(firstDelegate, secondDelegate);
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        id viewModel = ThetaValueForKey(secondDelegate, @"currentViewModel");
        items = ThetaValueForKey(viewModel, @"items");
    }
    if (![items isKindOfClass:[NSArray class]]) return;

    for (id item in items) {
        shouldBeSeen = true;
        (void)thetaStoryMarkItemAsSeen(self, item);
    }

    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Marked all as seen!" subtitle:@"They know we are here." icon:[UIImage systemImageNamed:@"eye"] autoHide:4 openURL:nil];
    }

    thetaStorySkipIfEnabled(firstDelegate);
}

static void seenButtonPressedCurrent(IGStoryFullscreenCell *self) {
    id firstDelegate = thetaStorySectionControllerFromCell(self);
    if (!firstDelegate) {
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Story section not found." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
        return;
    }

	id currentItem = nil;
	@try {
		if ([firstDelegate respondsToSelector:@selector(currentStoryItem)]) {
			currentItem = [firstDelegate performSelector:@selector(currentStoryItem)];
		}
	} @catch (__unused NSException *e) {}
    if (!currentItem) {
        id viewer = thetaStoryViewerFromCell(self);
        @try {
            if ([viewer respondsToSelector:@selector(currentStoryItem)]) {
                currentItem = [viewer performSelector:@selector(currentStoryItem)];
            }
        } @catch (__unused NSException *e) {}
    }

    BOOL ok = NO;
	if (currentItem) {
		shouldBeSeen = true;
        ok = thetaStoryMarkItemAsSeen(self, currentItem);
	}

	if (ENABLED(@"Show Banners")) {
        if (ok) {
            [ThetaHelper showToastWithTitle:@"Marked as seen!" subtitle:@"They know we are here." icon:[UIImage systemImageNamed:@"eye"] autoHide:4 openURL:nil];
        } else {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Couldn't update seen state." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
	}

	if (ok) thetaStorySkipIfEnabled(firstDelegate);
}

static NSMutableDictionary *lastSetupOwnerForCell;

/// Returns YES if the given IGUser's username is in the Story Ghost auto-mark list.
static BOOL isStoryOwnerInAutoMarkList(IGUser *owner) {
    if (!owner) return NO;
    NSString *username = nil;
    @try {
        if ([owner respondsToSelector:@selector(name)]) {
            username = [[owner performSelector:@selector(name)] copy];
        } else {
            id n = [owner valueForKey:@"username"];
            if (!n) n = [owner valueForKey:@"name"];
            if ([n isKindOfClass:[NSString class]]) username = [n copy];
        }
    } @catch (__unused NSException *e) {}
    if (!username.length) return NO;
    username = [username lowercaseString];
    NSArray *list = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_StoryGhost_AutoMarkUserIds"];
    if (![list isKindOfClass:[NSArray class]]) return NO;
    for (id obj in list) {
        if ([obj isKindOfClass:[NSString class]] && [[(NSString *)obj lowercaseString] isEqualToString:username])
            return YES;
    }
    return NO;
}

__attribute__((constructor))
static void StoryGhostInit() {
    lastSetupOwnerForCell = [NSMutableDictionary dictionary];
}

static void handleDownloadButtonTap(IGStoryFullscreenCell *self, UIButton *sender) {
    downloadButtonTapped(self);
}

static void handleDownloadButtonLongPress(IGStoryFullscreenCell *self, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        downloadAllMedia(self);
    }
}

static void handleSeenButtonTap(IGStoryFullscreenCell *self, UIButton *sender) {
    seenButtonPressedCurrent(self);
}

static void handleSeenButtonLongPress(IGStoryFullscreenCell *self, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        seenButtonPressedAll(self);
    }
}

static NSArray<IGUser *> *storyMentionUsersForCell(IGStoryFullscreenCell *self) {
    id firstDelegate = nil;
    @try {
        if ([self respondsToSelector:@selector(delegate)]) {
            firstDelegate = [self performSelector:@selector(delegate)];
        } else if ([self respondsToSelector:@selector(valueForKey:)]) {
            id container = [self valueForKey:@"containerView"];
            if (container && [container respondsToSelector:@selector(valueForKey:)]) {
                firstDelegate = [container valueForKey:@"delegate"];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!firstDelegate) return @[];

    id currentItem = nil;
    @try {
        if ([firstDelegate respondsToSelector:@selector(currentStoryItem)]) {
            currentItem = [firstDelegate performSelector:@selector(currentStoryItem)];
        } else {
            currentItem = [firstDelegate valueForKey:@"currentStoryItem"];
        }
    } @catch (__unused NSException *e) {}
    if (!currentItem) return @[];

    NSArray *reelMentions = nil;
    @try {
        if ([currentItem respondsToSelector:@selector(reelMentions)]) {
            reelMentions = [currentItem performSelector:@selector(reelMentions)];
        } else {
            reelMentions = [currentItem valueForKey:@"reelMentions"];
        }
    } @catch (__unused NSException *e) {}
    if (![reelMentions isKindOfClass:[NSArray class]] || reelMentions.count == 0) {
        return @[];
    }

    NSMutableArray<IGUser *> *users = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *seenUsernames = [NSMutableOrderedSet orderedSet];
    for (id mention in reelMentions) {
        id user = nil;
        @try { user = [mention valueForKey:@"user"]; } @catch (__unused NSException *e) {}
        if (!user) continue;

        NSString *username = nil;
        @try {
            if ([user respondsToSelector:@selector(name)]) {
                username = [user performSelector:@selector(name)];
            }
        } @catch (__unused NSException *e) {}

        if (username.length > 0) {
            if ([seenUsernames containsObject:username]) continue;
            [seenUsernames addObject:username];
        }
        [users addObject:user];
    }

    return users;
}

static NSString *mentionDisplayTitle(IGUser *user) {
    NSString *displayName = nil;
    NSString *username = nil;
    @try { displayName = [user valueForKey:@"secondaryName"]; } @catch (__unused NSException *e) {}
    @try {
        if ([user respondsToSelector:@selector(name)]) {
            username = [user performSelector:@selector(name)];
        }
    } @catch (__unused NSException *e) {}

    if (displayName.length > 0 && username.length > 0) {
        return [NSString stringWithFormat:@"%@ (@%@)", displayName, username];
    }
    if (username.length > 0) {
        return [NSString stringWithFormat:@"@%@", username];
    }
    if (displayName.length > 0) {
        return displayName;
    }
    return @"Unknown user";
}

static UIImage *thetaImageFromBundle(NSString *fileName) {
    if (fileName.length == 0) return nil;
    NSString *mainBundlePath = [NSBundle mainBundle].bundlePath;
    NSString *resourceBundlePath = [[NSBundle mainBundle] pathForResource:@"ThetaResources" ofType:@"bundle"];
    NSString *rootBundlePath = mainBundlePath.length > 0 ? [mainBundlePath stringByAppendingPathComponent:@"ThetaResources.bundle"] : nil;
    NSString *resourcesBundlePath = [NSBundle mainBundle].resourcePath.length > 0 ? [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"ThetaResources.bundle"] : nil;
    NSArray<NSString *> *bundlePaths = @[
        rootBundlePath ?: @"",
        resourceBundlePath ?: @"",
        resourcesBundlePath ?: @"",
        @"/Library/Application Support/ThetaResources.bundle",
        @"/var/jb/Library/Application Support/ThetaResources.bundle"
    ];
    for (NSString *bundlePath in bundlePaths) {
        if (bundlePath.length == 0) continue;
        NSString *imagePath = [bundlePath stringByAppendingPathComponent:fileName];
        UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
        if (image) return image;
    }
    return nil;
}

// Returns a solid white SF Symbol image for use in toasts, so it renders white regardless of view tint.
static UIImage *thetaWhiteSystemSymbol(NSString *name) {
    if (name.length == 0) return nil;
    UIImage *img = [UIImage systemImageNamed:name];
    if (!img) return nil;
    CGSize size = img.size;
    CGFloat scale = img.scale > 0 ? img.scale : [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx && img.CGImage) {
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGContextTranslateCTM(ctx, 0, size.height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextClipToMask(ctx, rect, img.CGImage);
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, rect);
    }
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static void openProfileForUser(IGUser *user) {
    if (!user) return;
    NSString *username = nil;
    @try {
        if ([user respondsToSelector:@selector(name)]) {
            username = [user performSelector:@selector(name)];
        }
    } @catch (__unused NSException *e) {}
    if (username.length == 0) return;

    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (encoded.length == 0) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"instagram://user?username=%@", encoded]];
    if (!url) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[UIApplication sharedApplication] respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    });
}

static UIMenu *buildMentionsMenu(IGStoryFullscreenCell *self) {
    if (!NSClassFromString(@"UIMenu") || !NSClassFromString(@"UIAction")) {
        return nil;
    }
    NSArray<IGUser *> *users = storyMentionUsersForCell(self);
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    if (users.count == 0) {
        UIAction *emptyAction = [UIAction actionWithTitle:@"No mentions found"
                                                   image:[UIImage systemImageNamed:@"person.crop.circle.badge.xmark"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
            // No-op
        }];
        emptyAction.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:emptyAction];
    } else {
        for (IGUser *user in users) {
            NSString *title = mentionDisplayTitle(user);
            UIAction *action = [UIAction actionWithTitle:title
                                                   image:[UIImage systemImageNamed:@"person.crop.circle"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
                openProfileForUser(user);
            }];
            [actions addObject:action];
        }
    }

    return [UIMenu menuWithTitle:@"Story Mentions" children:actions];
}

static void presentMentionsAlert(IGStoryFullscreenCell *self) {
    NSArray<IGUser *> *users = storyMentionUsersForCell(self);
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    if (users.count == 0) {
        [actions addObject:@{ @"title": @"No mentions found", @"handler": ^{ /* no-op */ } }];
    } else {
        for (IGUser *user in users) {
            NSString *title = mentionDisplayTitle(user);
            [actions addObject:@{
                @"title": title ?: @"@user",
                @"handler": ^{
                    openProfileForUser(user);
                }
            }];
        }
    }
    [actions addObject:@{ @"title": @"Cancel", @"handler": ^{ /* no-op */ } }];
    [ThetaHelper showCustomAlertWithActions:@"Story Mentions" description:@"Select a user to open their profile." actions:actions];
}

static void setupButtons(IGStoryFullscreenCell *self) {
    id firstDelegate = nil;
    @try {
        if ([self respondsToSelector:@selector(delegate)]) {
            firstDelegate = [self performSelector:@selector(delegate)];
        } else if ([self respondsToSelector:@selector(valueForKey:)]) {
            id container = [self valueForKey:@"containerView"];
            if (container && [container respondsToSelector:@selector(valueForKey:)]) {
                firstDelegate = [container valueForKey:@"delegate"];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!firstDelegate) return;
    id viewModel = nil;
    @try { viewModel = [firstDelegate valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!viewModel) return;
    IGUser *owner = nil;
    @try { owner = [viewModel valueForKey:@"owner"]; } @catch (__unused NSException *e) {}
    if (!owner) return;

    NSNumber *cellKey = @((uintptr_t)self);
    NSString *ownerKey = thetaStoryOwnerKey(owner) ?: @"";
    NSString *lastOwnerKey = lastSetupOwnerForCell[cellKey];
    if ([lastOwnerKey isKindOfClass:[NSString class]] && [lastOwnerKey isEqualToString:ownerKey] && ownerKey.length > 0) {
        return;
    }
    lastSetupOwnerForCell[cellKey] = ownerKey;

    // Only remove Theta-owned controls — never strip Instagram's UIButtons.
    for (UIView *subview in [self.subviews copy]) {
        if ([subview isKindOfClass:[UIButton class]] && subview.tag == kThetaStoryButtonTag) {
            [subview removeFromSuperview];
        }
    }

    UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    downloadButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Save Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [downloadButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting download button color: %@", exception);
        [downloadButton setTintColor:[UIColor labelColor]];
    }
    [downloadButton setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
    downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
    downloadButton.layer.shadowOpacity = 0.4;
    downloadButton.layer.shadowOffset = CGSizeMake(-2, 0);
    downloadButton.layer.shadowRadius = 3;
    downloadButton.layer.masksToBounds = NO;
    [downloadButton setTranslatesAutoresizingMaskIntoConstraints:false];

    UIButton *seenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    seenButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Seen Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [seenButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting seen button color: %@", exception);
        [seenButton setTintColor:[UIColor labelColor]];
    }
    [seenButton setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    seenButton.layer.shadowColor = [UIColor blackColor].CGColor;
    seenButton.layer.shadowOpacity = 0.4;
    seenButton.layer.shadowOffset = CGSizeMake(-2, 0);
    seenButton.layer.shadowRadius = 3;
    seenButton.layer.masksToBounds = NO;
    [seenButton setTranslatesAutoresizingMaskIntoConstraints:false];

    UIButton *localSeenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    localSeenButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Seen Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [localSeenButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        [localSeenButton setTintColor:[UIColor labelColor]];
    }
    UIImage *localIcon = [UIImage systemImageNamed:@"iphone"];
    if (!localIcon) localIcon = [UIImage systemImageNamed:@"iphone.circle"];
    if (!localIcon) localIcon = [UIImage systemImageNamed:@"internaldrive"];
    [localSeenButton setImage:localIcon forState:UIControlStateNormal];
    localSeenButton.layer.shadowColor = [UIColor blackColor].CGColor;
    localSeenButton.layer.shadowOpacity = 0.4;
    localSeenButton.layer.shadowOffset = CGSizeMake(-2, 0);
    localSeenButton.layer.shadowRadius = 3;
    localSeenButton.layer.masksToBounds = NO;
    [localSeenButton setTranslatesAutoresizingMaskIntoConstraints:false];

    BOOL downloadVideos = ENABLED(@"Save Media");
    BOOL hideSeenState = ENABLED(@"Story Ghost");
    BOOL showLocalSeenOnly = ENABLED(@"Seen Receipts Stay Local");
    BOOL showMentions = ENABLED(@"See Story Mentions");

    NSArray *items = nil;
    @try {
        items = [viewModel valueForKey:@"items"];
    } @catch (__unused NSException *e) {}
    NSInteger itemCount = [items isKindOfClass:[NSArray class]] ? items.count : 0;

    UIButton *mentionsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    mentionsButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Mentions Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [mentionsButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting mentions button color: %@", exception);
        [mentionsButton setTintColor:[UIColor labelColor]];
    }
    UIImage *mentionsImage = nil;
    @try {
        mentionsImage = thetaImageFromBundle(@"ig_icon_story_mention_pano_outline_24_Normal2x.png");
    } @catch (__unused NSException *exception) {}
    [mentionsButton setImage:mentionsImage ?: [UIImage systemImageNamed:@"at"] forState:UIControlStateNormal];
    mentionsButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    mentionsButton.imageEdgeInsets = UIEdgeInsetsMake(2, 2, 2, 2);
    mentionsButton.layer.shadowColor = [UIColor blackColor].CGColor;
    mentionsButton.layer.shadowOpacity = 0.4;
    mentionsButton.layer.shadowOffset = CGSizeMake(-2, 0);
    mentionsButton.layer.shadowRadius = 3;
    mentionsButton.layer.masksToBounds = NO;
    [mentionsButton setTranslatesAutoresizingMaskIntoConstraints:false];

    NSArray<IGUser *> *mentionUsers = nil;
    @try {
        mentionUsers = storyMentionUsersForCell(self);
    } @catch (__unused NSException *exception) {}
    NSInteger mentionCount = [mentionUsers isKindOfClass:[NSArray class]] ? mentionUsers.count : 0;
    BOOL hasMentions = (mentionCount > 0);

    mentionsButton.enabled = hasMentions;
    mentionsButton.alpha = hasMentions ? 1.0 : 0.5;

    UILabel *mentionsBadge = [[UILabel alloc] init];
    mentionsBadge.textAlignment = NSTextAlignmentCenter;
    mentionsBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    mentionsBadge.textColor = [UIColor whiteColor];
    mentionsBadge.backgroundColor = [UIColor systemRedColor];
    mentionsBadge.layer.cornerRadius = 8;
    mentionsBadge.layer.masksToBounds = YES;
    mentionsBadge.text = [NSString stringWithFormat:@"%ld", (long)mentionCount];
    mentionsBadge.hidden = !hasMentions;
    mentionsBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [mentionsButton addSubview:mentionsBadge];
    [NSLayoutConstraint activateConstraints:@[
        [mentionsBadge.widthAnchor constraintGreaterThanOrEqualToConstant:16],
        [mentionsBadge.heightAnchor constraintEqualToConstant:16],
        [mentionsBadge.trailingAnchor constraintEqualToAnchor:mentionsButton.trailingAnchor constant:2],
        [mentionsBadge.bottomAnchor constraintEqualToAnchor:mentionsButton.bottomAnchor constant:2]
    ]];

    UIMenu *mentionsMenu = nil;
    @try {
        mentionsMenu = buildMentionsMenu(self);
    } @catch (__unused NSException *exception) {}
    if (hasMentions && mentionsMenu && [mentionsButton respondsToSelector:@selector(setShowsMenuAsPrimaryAction:)]) {
        mentionsButton.showsMenuAsPrimaryAction = YES;
        mentionsButton.menu = mentionsMenu;
    }

    NSMutableArray<UIButton *> *buttonStack = [NSMutableArray array];
    if (downloadVideos) {
        [buttonStack addObject:downloadButton];
    }
    if (hideSeenState) {
        [buttonStack addObject:seenButton];
    }
    if (showLocalSeenOnly) {
        [buttonStack addObject:localSeenButton];
    }
    if (showMentions) {
        [buttonStack addObject:mentionsButton];
    }

    UIButton *previousButton = nil;
    for (UIButton *button in buttonStack) {
        ThetaSetCaptureHiding(button);
        [self addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [button.widthAnchor constraintEqualToConstant:30],
            [button.heightAnchor constraintEqualToConstant:30]
        ]];

        if (!previousButton) {
            [NSLayoutConstraint activateConstraints:@[
                [button.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-150]
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [button.bottomAnchor constraintEqualToAnchor:previousButton.topAnchor constant:-20]
            ]];
        }
        previousButton = button;
    }

    __weak IGStoryFullscreenCell *weakSelf = self;
    if (downloadVideos) {
        thetaStoryAddTap(downloadButton, ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) downloadButtonTapped(cell);
        });
        
        // Add long press gesture for downloading all
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] init];
        [longPress addActionBlock:^(UIGestureRecognizer *recognizer) {
            if (((UILongPressGestureRecognizer *)recognizer).state == UIGestureRecognizerStateBegan) {
                IGStoryFullscreenCell *cell = weakSelf;
                if (cell) downloadAllMedia(cell);
            }
        }];
        longPress.minimumPressDuration = 0.5;
        [downloadButton addGestureRecognizer:longPress];
    }

    if (hideSeenState) {
        thetaStoryAddTap(seenButton, ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) seenButtonPressedCurrent(cell);
        });

        // Long press: show menu — Mark all as seen / Add owner to auto-mark list
        NSString *ownerUsername = nil;
        @try {
            if ([owner respondsToSelector:@selector(name)]) {
                ownerUsername = [owner performSelector:@selector(name)];
            } else {
                id n = ThetaValueForKey(owner, @"username");
                if (!n) n = ThetaValueForKey(owner, @"name");
                if ([n isKindOfClass:[NSString class]]) ownerUsername = n;
            }
        } @catch (__unused NSException *e) {}
        NSString *displayName = ownerUsername.length ? [NSString stringWithFormat:@"@%@", ownerUsername] : @"this user";
        __weak IGStoryFullscreenCell *weakCell = self;
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] init];
        [longPress addActionBlock:^(UIGestureRecognizer *recognizer) {
            if (((UILongPressGestureRecognizer *)recognizer).state != UIGestureRecognizerStateBegan) return;

            // Determine current membership so we can show Add/Remove appropriately.
            BOOL inAutoList = NO;
            NSString *lower = nil;
            if (ownerUsername.length) {
                lower = [[ownerUsername lowercaseString] copy];
                NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                if ([stored isKindOfClass:[NSArray class]] && [stored containsObject:lower]) {
                    inAutoList = YES;
                }
            }

            NSString *toggleTitle = inAutoList
                ? [NSString stringWithFormat:@"Remove %@ from auto-mark list", displayName]
                : [NSString stringWithFormat:@"Add %@ to auto-mark list", displayName];

            NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];

            // Mark all as seen — run after alert dismisses so delegate chain is still valid
            [actions addObject:@{
                @"title": @"Mark all as seen",
                @"handler": ^(id sender){
                    IGStoryFullscreenCell *cell = weakCell;
                    if (!cell) return;
                    __strong IGStoryFullscreenCell *strongCell = cell;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!strongCell) return;
                        seenButtonPressedAll(strongCell);
                    });
                }
            }];

            // Add / Remove from auto-mark list
            [actions addObject:@{
                @"title": toggleTitle,
                @"handler": ^(id sender){
                    if (!ownerUsername.length) return;
                    NSString *lowerLocal = [ownerUsername lowercaseString];
                    NSMutableArray *list = [NSMutableArray array];
                    NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                    if ([stored isKindOfClass:[NSArray class]]) [list addObjectsFromArray:stored];

                    BOOL currentlyInList = [list containsObject:lowerLocal];
                    if (currentlyInList) {
                        // Remove from list
                        [list removeObject:lowerLocal];
                        [[NSUserDefaults standardUserDefaults] setObject:list forKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        if (ENABLED(@"Show Banners")) {
                            UIImage *icon = thetaColoredSystemSymbol(@"minus.circle", [UIColor systemRedColor]);
                            [ThetaHelper showToastWithTitle:[NSString stringWithFormat:@"Removed %@ from list", displayName]
                                                    subtitle:@"They won't know we're here."
                                                        icon:icon
                                                    autoHide:3
                                                     openURL:nil];
                        }
                    } else {
                        // Add to list
                        [list addObject:lowerLocal];
                        [[NSUserDefaults standardUserDefaults] setObject:list forKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        if (ENABLED(@"Show Banners")) {
                            UIImage *icon = thetaColoredSystemSymbol(@"checkmark.circle.fill", [UIColor systemGreenColor]);
                            [ThetaHelper showToastWithTitle:[NSString stringWithFormat:@"Added %@ to list", displayName]
                                                    subtitle:@"They will know we're here."
                                                        icon:icon
                                                    autoHide:3
                                                     openURL:nil];
                        }
                    }
                }
            }];

            // Cancel
            [actions addObject:@{
                @"title": @"Cancel",
                @"handler": ^(id sender){}
            }];

            [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!"
                                         description:@"What would you like to do?"
                                             actions:actions];
        }];
        longPress.minimumPressDuration = 0.5;
        [seenButton addGestureRecognizer:longPress];
    }

    if (showLocalSeenOnly) {
        thetaStoryAddTap(localSeenButton, ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) handleLocalSeenTap(cell, localSeenButton);
        });
        UILongPressGestureRecognizer *localLP = [[UILongPressGestureRecognizer alloc] init];
        [localLP addActionBlock:^(UIGestureRecognizer *recognizer) {
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) handleLocalSeenLongPress(cell, (UILongPressGestureRecognizer *)recognizer);
        }];
        localLP.minimumPressDuration = 0.5;
        [localSeenButton addGestureRecognizer:localLP];
    }

    if (showMentions) {
        [mentionsButton handleControlEvent:UIControlEventTouchDown withBlock:^(id sender) {
            if (!hasMentions) return;
            IGStoryFullscreenCell *cell = weakSelf;
            if (!cell) return;
            @try {
                UIMenu *menu = buildMentionsMenu(cell);
                if (menu) {
                    mentionsButton.menu = menu;
                }
            } @catch (__unused NSException *exception) {}
        }];
        thetaStoryAddTap(mentionsButton, ^{
            if (!hasMentions) return;
            IGStoryFullscreenCell *cell = weakSelf;
            if (!cell) return;
            if (!mentionsButton.menu) {
                presentMentionsAlert(cell);
            }
        });
    }

    if (hideSeenState && isStoryOwnerInAutoMarkList(owner)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (!cell) return;
            seenButtonPressedCurrent(cell);
            id firstDel = nil;
            @try {
                if ([cell respondsToSelector:@selector(delegate)]) {
                    firstDel = [cell performSelector:@selector(delegate)];
                } else {
                    id container = ThetaValueForKey(cell, @"containerView");
                    if (container) firstDel = ThetaValueForKey(container, @"delegate");
                }
            } @catch (__unused NSException *e) {}
            thetaStorySkipIfEnabled(firstDel);
        });
    }
}

static id (*orig_storyGhost)(id self, SEL _cmd);
static id hook_storyGhost(id self, SEL _cmd) {
    id media = nil;
    if (orig_storyGhost) {
        @try {
            media = orig_storyGhost(self, _cmd);
        } @catch (__unused NSException *e) {
            media = nil;
        }
    }

    @try {
        setupButtons(self);
    } @catch (NSException *exception) {
        NSLog(@"[Theta] StoryGhost setupButtons: %@", exception);
    }
    return media;
}

static void (*orig_storyGhost2)(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen);
static void hook_storyGhost2(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen) {
    if (!orig_storyGhost2) return;

    if (!ENABLED(@"Story Ghost")) {
        if (ENABLED(@"Seen Receipts Stay Local")) {
            THStorySeenReceiptNetworkGuardEnterWithContext(fullscreenSectionController, self);
            @try {
                orig_storyGhost2(self, _cmd, fullscreenSectionController, didMarkItemAsSeen);
            } @catch (__unused NSException *e) {
            }
            // Restore any temporary networker swaps; do not leave the viewer stripped.
            THStorySeenReceiptNetworkGuardLeave();
            return;
        }
        @try {
            orig_storyGhost2(self, _cmd, fullscreenSectionController, didMarkItemAsSeen);
        } @catch (__unused NSException *e) {
        }
        return;
    }

    if (shouldBeSeen) {
        shouldBeSeen = false;
        @try {
            orig_storyGhost2(self, _cmd, fullscreenSectionController, didMarkItemAsSeen);
        } @catch (__unused NSException *e) {
        }
    }
}

static void downloadStoryMedia(id self) {
    @try {
        IGStoryFullscreenCell *firstDelegate = nil;
        @try {
            id container = [self valueForKey:@"containerView"];
            if (container && [container respondsToSelector:@selector(valueForKey:)]) {
                firstDelegate = [container valueForKey:@"delegate"];
            }
        } @catch (__unused NSException *e) {}
        if (!firstDelegate) {
            NSLog(@"No delegate found for story download");
            return;
        }
        
        IGPhoto *photo = nil;
        @try { photo = [firstDelegate valueForKey:@"_photo"]; } @catch (__unused NSException *e) {}
        if (!photo) {
            NSLog(@"No photo found for story download");
            return;
        }
        
        NSArray *originalImageVersions = nil;
        @try { originalImageVersions = [photo valueForKey:@"_originalImageVersions"]; } @catch (__unused NSException *e) {}
        if (!originalImageVersions || originalImageVersions.count == 0) {
            NSLog(@"No image versions found for story download");
            return;
        }
        
        id photoURL = [originalImageVersions lastObject];
        NSURL *url = nil;
        @try { url = [photoURL valueForKey:@"url"]; } @catch (__unused NSException *e) {}
        if (!url) {
            NSLog(@"No URL found for story download");
            return;
        }

        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
        if (saveMethod == 0) {
            // Check photo library permission first
            PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
            if (status == PHAuthorizationStatusNotDetermined) {
                [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authorizationStatus) {
                    if (authorizationStatus == PHAuthorizationStatusAuthorized) {
                        performStoryDownloadWithURL(url);
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (ENABLED(@"Show Banners")) {
                                [ThetaHelper showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                            }
                        });
                    }
                }];
            } else if (status == PHAuthorizationStatusAuthorized) {
                performStoryDownloadWithURL(url);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                    }
                });
            }
        } else {
            // Local folder mode does not require Photos permission
            performStoryDownloadWithURL(url);
        }
    } @catch (NSException *exception) {
        NSLog(@"Error downloading image: %@", exception);
    }
}

static void performStoryDownloadWithURL(NSURL *url) {
    @autoreleasepool {
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error downloading file: %@", error);
                return;
            }

            NSError *moveError;
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *newFilename = [NSString stringWithFormat:@"story-%@.jpg", [[NSUUID UUID] UUIDString]];
            NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
            
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&moveError];
            if (moveError) {
                NSLog(@"Error moving downloaded file: %@", moveError);
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                if (saveMethod == 0) {
                    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                        [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                    } completionHandler:^(BOOL success, NSError *error) {
                        if (!success) {
                            NSLog(@"Error saving image to camera roll: %@", error);
                        }

                        // Clean up temporary file after saving to Photos
                        NSError *deleteError;
                        [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:&deleteError];
                        if (deleteError) {
                            NSLog(@"Error deleting temporary file: %@", deleteError);
                        }

                        if (success && ENABLED(@"Show Banners")) {
                            [ThetaHelper showToastWithTitle:@"Story saved!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        }
                    }];
                } else {
                    // Local folder mode: move into Documents/AudioNotes
                    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                    NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                    BOOL isDir = NO;
                    if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                        [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[permanentFilePath lastPathComponent]];
                    NSError *moveErr = nil;
                    if (![[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:&moveErr]) {
                        NSString *unique = [NSString stringWithFormat:@"story-%@.jpg", [[NSUUID UUID] UUIDString]];
                        destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                        [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
                    }
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Story saved!" subtitle:@"Saved to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:nil];
                    }
                }
            });
        }];
        [downloadTask resume];
    }
}

void THRegisterStoryGhostHooks(void) {
    Class cellCls = ThetaFirstClass(@[ @"IGStoryFullscreenCell" ]);
    Class viewerCls = ThetaFirstClass(@[ @"IGStoryViewerViewController" ]);
    NullHookMessageIfPresent(cellCls, @selector(mediaView), (void *)hook_storyGhost, &orig_storyGhost);
    NullHookMessageIfPresent(viewerCls, @selector(fullscreenSectionController:didMarkItemAsSeen:), (void *)hook_storyGhost2, &orig_storyGhost2);
    if (!orig_storyGhost) {
        NSLog(@"[Theta] StoryGhost: mediaView hook missing orig — overlay may be unavailable");
    }
    if (!orig_storyGhost2) {
        NSLog(@"[Theta] StoryGhost: didMarkItemAsSeen hook missing orig — mark-seen actions are no-ops");
    }
}