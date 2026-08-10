#import "Include.h"
static void saveMedia(id self);

// Helper target to call C function saveMedia from UIButton action
@interface ThetaSaveMediaButtonTarget : NSObject
@property (nonatomic, weak) id hostView;
- (void)onTap:(id)sender;
@end

@implementation ThetaSaveMediaButtonTarget
- (void)onTap:(id)sender {
    saveMedia(self.hostView);
}
@end

static const NSInteger kThetaFollowSaveButtonTag = 424242;

static void saveMedia(id self) {
	@try {
		NSMutableArray *blah = [NSMutableArray array];
		UIViewController *topController = [ThetaHelper nearestViewController:self];
		if ([topController isKindOfClass:NSClassFromString(@"IGProfileViewController")]) {

			UIViewController *childViewController = nil;
			for (UIViewController *child in topController.childViewControllers) {
				if ([child isKindOfClass:NSClassFromString(@"IGDynamicPageViewController")]) {
					childViewController = child;
					break;
				}
			}

			id collectionView = [childViewController valueForKey:@"collectionView"];
			if (collectionView) {
				for (UIView *subview in [(UIView *)collectionView subviews]) {
					if ([subview isKindOfClass:NSClassFromString(@"IGDynamicPageContainerCollectionViewCell")]) {
						UIView *currentView = subview;
						while (currentView && currentView.subviews.count > 0) {
							if ([currentView isKindOfClass:NSClassFromString(@"IGProfileTabCollectionView")]) {
								break;
							}

							currentView = currentView.subviews.firstObject;
						}

						if (currentView && [currentView isKindOfClass:NSClassFromString(@"IGProfileTabCollectionView")]) {
							UIView *feedStatusCollectionCell = nil;
							for (UIView *subview in currentView.subviews) {
								if ([subview isKindOfClass:NSClassFromString(@"IGFeedStatusCollectionCell")]) {
									feedStatusCollectionCell = subview;
									break;
								}
							}

							if (feedStatusCollectionCell) {
								[ThetaHelper showToastWithTitle:@"Can't save posts!" subtitle:@"This account is private." icon:[ThetaHelper imageFromEmojiString:@"🔒" width:60] autoHide:4 openURL:nil];
								return;
							}
						}
						break;
					}
				}
			}

			id feedSourceMan = [topController valueForKey:@"_feedSourcesManager"];
			if (feedSourceMan) {
				NSMutableDictionary *sources = [feedSourceMan valueForKey:@"_sources"];
				id source = [sources allValues][0];
				if ([source isKindOfClass:NSClassFromString(@"IGProfileFeedSource")]) {
					id feedSource = [source valueForKey:@"_feedSource"];
					if (feedSource) {
						NSArray *gridItems = [feedSource valueForKey:@"_gridItems"];
						if (gridItems == nil || gridItems.count == 0) {
							[ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!" description:@"As of now, we can't find any posts.\n\nMake sure you are on the user's posts tab, not reels or tagged posts tab and try again." actions:@[
								@{
									@"title": @"Okay, thanks.",
									@"handler": ^(id sender) {
									}
								}
							]];
							return;
						}
						NSString *toastTitle = gridItems.count > 1 ? @"Fetching media..." : @"Saving media...";
						NSString *toastDescription = gridItems.count > 1 ? @"This may take a couple minutes." : @"This may take a few seconds.";
						[ThetaHelper showToastWithTitle:toastTitle subtitle:toastDescription icon:[UIImage systemImageNamed:@"arrow.clockwise"] autoHide:4 openURL:nil];
						dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
							for (id item in gridItems) {
								IGMedia *media = [item performSelector:@selector(media)];
								NSArray *mediaItems = [media valueForKey:@"items"];
								for (IGPostItem *postItem in mediaItems) {
									NSURL *url = nil;
									UIImage *preview = nil;

									BOOL handled = NO;

									if (!handled && [postItem respondsToSelector:@selector(itemMediaType)]) {
										if (postItem.itemMediaType == 1) {
											IGPhoto *photo = postItem.photo;
											NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
											if (originalImageVersions.count > 1) {
												id photoURL = [originalImageVersions lastObject];
												url = [photoURL valueForKey:@"url"];
												preview = [UIImage imageWithData:[NSData dataWithContentsOfURL:url]];
											}
										} else if (postItem.itemMediaType == 2) {
											IGVideo *video = postItem.video;
											NSSet *videoURLs = [video allVideoURLs];
											url = [videoURLs anyObject];
											preview = [UIImage systemImageNamed:@"video"];
										}
										handled = YES;
									}

									if (!handled && [postItem respondsToSelector:@selector(mediaType)]) {
										if (postItem.mediaType == 1) {
											IGPhoto *photo = postItem.photo;
											NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
											if (originalImageVersions.count > 1) {
												id photoURL = [originalImageVersions lastObject];
												url = [photoURL valueForKey:@"url"];
												preview = [UIImage imageWithData:[NSData dataWithContentsOfURL:url]];
											}
										} else if (postItem.mediaType == 2) {
											IGVideo *video = postItem.video;
											NSSet *videoURLs = [video allVideoURLs];
											url = [videoURLs anyObject];
											preview = [UIImage systemImageNamed:@"video"];
										}
										handled = YES;
									}

									if (url) {
										NSDictionary *mediaDict = @{ @"url": url.absoluteString, @"preview": preview ?: [UIImage systemImageNamed:@"photo"] };
										[blah addObject:mediaDict];
									}
								}
							}

							dispatch_async(dispatch_get_main_queue(), ^{
								if (blah.count == 1) {
									NSMutableArray<NSString *> *singleDownloadedFilePath = [NSMutableArray array];
    								NSMutableArray<NSString *> *singleFileExtension = [NSMutableArray array];
									@try {
										MediaSelectionViewController *mediaSelectionVC = [MediaSelectionViewController new];
										[mediaSelectionVC downloadMediaToTemp:[NSURL URLWithString:blah[0][@"url"]] completion:^(NSString *filePath, NSString *fileExtension) {
											[singleDownloadedFilePath addObject:filePath];
											[singleFileExtension addObject:fileExtension];
										}];
										[mediaSelectionVC saveFilesToCameraRoll:singleDownloadedFilePath extensions:singleFileExtension];
									} @catch (NSException *exception) {
										NSLog(@"Error: %@", exception);
									}
									return;
								}

								if (blah.count > 1) {
									@try {
										MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:blah withCount:blah.count];
										UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
										[[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
									} @catch (NSException *exception) {
										NSLog(@"Error: %@", exception);
									}
								}
							});
						});
					}
				}
			}
		}
	} @catch (NSException *exception) {
		NSLog(@"Error: %@", exception);
	}
}

static void (*orig_followStatusIndicator)(UIView *self, SEL _cmd);
static void hook_followStatusIndicator(UIView *self, SEL _cmd) {
    orig_followStatusIndicator(self, _cmd);

    UIViewController *topController = [ThetaHelper nearestViewController:self];
    if (![topController isKindOfClass:NSClassFromString(@"IGProfileViewController")]) {
        return;
    }

    IGUser *user = nil;
    @try {
        user = [topController performSelector:@selector(user)];
    } @catch (__unused NSException *e) {
        return;
    }
    if (!user) {
        return;
    }

	id context = ThetaValueForKey(topController, @"_navBarContext");
	BOOL currentUser = context ? [ThetaValueForKey(context, @"isCurrentUser") boolValue] : NO;
    
	if (currentUser) {
		return;
	}

    BOOL doesFollow = [user followsCurrentUser];
    BOOL showFollowIndicator = [[NSUserDefaults standardUserDefaults] boolForKey:@"Follow Status Indicator_Enabled"];
    BOOL showSaveButton = [[NSUserDefaults standardUserDefaults] boolForKey:@"Save Profile Posts_Enabled"];

    for (UIView *view in [self subviews]) {
        if (![view isKindOfClass:NSClassFromString(@"IGCoreTextView")]) {
            continue;
        }

        id styledString = nil;
        @try {
            styledString = [view valueForKey:@"styledString"];
        } @catch (__unused NSException *e) {
            continue;
        }

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
            // No suffix when disabled (cleanup already removed any existing one)
            if ([styledString respondsToSelector:@selector(setAttributedString:)]) {
                [styledString setAttributedString:attributedString];
            }
        }
		@try {
            ThetaSetValueForKey(view, styledString, @"styledString");
            
            // Ensure a single inline button exists only if enabled
            UIButton *saveButton = nil;
            for (UIView *sub in [self subviews]) {
                if ([sub isKindOfClass:[UIButton class]] && sub.tag == kThetaFollowSaveButtonTag) {
                    saveButton = (UIButton *)sub;
                    break;
                }
            }
            if (showSaveButton) {
                if (!saveButton) {
                    saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
                    saveButton.tag = kThetaFollowSaveButtonTag;
                    [saveButton setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
                    [saveButton setTintColor:[ThetaHelper iotaPinkColor]];
                    ThetaSaveMediaButtonTarget *target = [ThetaSaveMediaButtonTarget new];
                    target.hostView = self;
                    objc_setAssociatedObject(saveButton, @selector(onTap:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [saveButton addTarget:target action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
                    saveButton.userInteractionEnabled = YES;
                    saveButton.exclusiveTouch = YES;
                    saveButton.accessibilityIdentifier = @"theta_save_profile_button";
                    // Fallback recognizer in case parent intercepts UIControl events
                    if (!objc_getAssociatedObject(saveButton, "theta_gr")) {
                        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(onTap:)];
                        tap.cancelsTouchesInView = YES;
                        [saveButton addGestureRecognizer:tap];
                        objc_setAssociatedObject(saveButton, "theta_gr", @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    ThetaSetCaptureHiding(saveButton);
                    [self addSubview:saveButton];
                }
                // Match text color and font from the end of the styled string
                NSDictionary *endAttrs = nil;
                if (attributedString.length > 0) {
                    endAttrs = [attributedString attributesAtIndex:attributedString.length - 1 effectiveRange:NULL];
                }
                UIColor *textColor = endAttrs[(id)NSForegroundColorAttributeName];
                UIFont *textFont = endAttrs[(id)NSFontAttributeName];
                if (!textColor) textColor = [UIColor labelColor];
                [saveButton setTitleColor:textColor forState:UIControlStateNormal];
                if (textFont) saveButton.titleLabel.font = textFont;
                [saveButton sizeToFit];
                CGFloat spacing = 6.0;
                CGRect vframe = view.frame;
                CGRect btnFrame = saveButton.frame;
                btnFrame.origin.x = CGRectGetMaxX(vframe) + spacing;
                btnFrame.origin.y = CGRectGetMidY(vframe) - btnFrame.size.height / 2.0;
                CGFloat maxX = self.bounds.size.width - 4.0;
                if (CGRectGetMaxX(btnFrame) > maxX) {
                    btnFrame.origin.x = maxX - btnFrame.size.width;
                }
                saveButton.frame = btnFrame;
                saveButton.hidden = NO;
                [self bringSubviewToFront:saveButton];
            } else {
                if (saveButton) {
                    [saveButton removeFromSuperview];
                }
            }
		
            [view setNeedsLayout];
            [view setNeedsDisplay];
        } @catch (NSException *exception) {
            NSLog(@"Error: %@", exception);
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