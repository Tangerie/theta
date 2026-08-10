static void (*orig_messageCache)(id self, SEL _cmd, id update);
static void hook_messageCache(id self, SEL _cmd, id update) {
	if (!ENABLED(@"Keep Deleted Messages")) {
		orig_messageCache(self, _cmd, update);
		return;
	}

	if (update) {
		id retained = update;
		static char kThetaRetainedUpdateKey;
		objc_setAssociatedObject(self, &kThetaRetainedUpdateKey, retained, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		NSString *debugDescription = [retained respondsToSelector:@selector(debugDescription)] ? [retained debugDescription] : [retained description];

		id cacheThreadUpdate = nil;
		if ([retained isKindOfClass:[NSArray class]] && [(NSArray *)retained count] > 0) {
			cacheThreadUpdate = [(NSArray *)retained firstObject];
		} else {
			cacheThreadUpdate = retained;
		}

		id threadUpdates = nil;
		if (cacheThreadUpdate && [cacheThreadUpdate respondsToSelector:@selector(valueForKey:)]) {
			threadUpdates = [cacheThreadUpdate valueForKey:@"threadUpdates"];
		}

		id threadUpdateObj = nil;
		if ([threadUpdates isKindOfClass:[NSArray class]] && [(NSArray *)threadUpdates count] > 0) {
			threadUpdateObj = [(NSArray *)threadUpdates firstObject];
		}

		if (threadUpdateObj) {
			static char kThetaRetainedThreadUpdateKey;
			objc_setAssociatedObject(self, &kThetaRetainedThreadUpdateKey, threadUpdateObj, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			@try {
				id messageUpdate = [threadUpdateObj valueForKey:@"_messageUpdate"];
				if (messageUpdate) {
					NSArray *removeKeys = [messageUpdate valueForKey:@"_removeMessages_messageKeys"];
					if (removeKeys.count == 0) {
						orig_messageCache(self, _cmd, retained);
						return;
					}

					for (id messageKey in removeKeys) {
						if (![messageKey isKindOfClass:NSClassFromString(@"IGDirectMessageUpdateMessageKey")]) {
							orig_messageCache(self, _cmd, retained);
							return;
						}
						IGDirectMessageUpdateMessageKey *updateKey = messageKey;

						if (![updateKey valueForKey:@"_messageServerId"]) {
							orig_messageCache(self, _cmd, retained);
							return;
						}

						NSString *MsgKey = [updateKey valueForKey:@"_messageServerId"];
						[[MessagesManager sharedManager] saveDeletedMessageWithID:MsgKey];
						return;
					}
				}
			} @catch (NSException *e) {
				NSLog(@"Error accessing IGDirectThreadUpdate: %@", e);
			}
		}
	}

	orig_messageCache(self, _cmd, update);
}

/* static void (*orig_directMessageCell)(id self, SEL _cmd, id viewModel, id specFactory, id launcher);
 static void hook_directMessageCell(id self, SEL _cmd, id viewModel, id specFactory, id launcher) {
 	orig_directMessageCell(self, _cmd, viewModel, specFactory, launcher);

 	if (![viewModel conformsToProtocol:@protocol(IGDirectMessageViewModelProtocol)]) return;
 	IGDirectUIMessageMetadata *metadata = [(id<IGDirectMessageViewModelProtocol>)viewModel messageMetadata];
 	NSString *serverId = metadata.key.serverId;

 	if (![[MessagesManager sharedManager] messageExistsWithID:serverId]) return;

 	UIButton *deletedButton = [UIButton buttonWithType:UIButtonTypeSystem];
 	[deletedButton setImage:[UIImage systemImageNamed:@"trash.circle"] forState:UIControlStateNormal];
 	[deletedButton setTintColor:UIColor.systemRedColor];
	deletedButton.translatesAutoresizingMaskIntoConstraints = NO;
	static char kThetaDeletedServerIdKey;
	objc_setAssociatedObject(deletedButton, &kThetaDeletedServerIdKey, serverId, OBJC_ASSOCIATION_COPY_NONATOMIC);

 	UIView *container = nil;
 	if ([self respondsToSelector:@selector(contentViewForVisualMessageViewerPresentation)]) {
 		#pragma clang diagnostic push
 		#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
 		container = [self performSelector:@selector(contentViewForVisualMessageViewerPresentation)];
 		#pragma clang diagnostic pop
 	}
 	if (!container && [self respondsToSelector:@selector(contentView)]) {
 		container = [self valueForKey:@"contentView"];
 	}
 	if (!container && [self isKindOfClass:[UIView class]]) {
 		container = (UIView *)self;
 	}
 	if (!container) return;

 	for (UIView *sub in container.subviews) {
 		if ([sub isKindOfClass:[UIButton class]] && sub.tag == 9911) { return; }
 	}
 	deletedButton.tag = 9911;
 	ThetaSetCaptureHiding(deletedButton);
 	[container addSubview:deletedButton];

 	[NSLayoutConstraint activateConstraints:@[
 		[deletedButton.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
 		[deletedButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:30],
 		[deletedButton.widthAnchor constraintEqualToConstant:20],
 		[deletedButton.heightAnchor constraintEqualToConstant:20],
 	]];

	if (@available(iOS 14.0, *)) {
		[deletedButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
			NSString *sid = objc_getAssociatedObject(deletedButton, &kThetaDeletedServerIdKey);
			NSString *deletedMessageDate = [[MessagesManager sharedManager] dateForDeletedMessageWithID:sid];
			UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BHInsta, Hi" message:[NSString stringWithFormat:@"Message deleted at: %@", deletedMessageDate ?: @"Unknown"] preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
			[topMostController() presentViewController:alert animated:YES completion:nil];
		}] forControlEvents:UIControlEventTouchUpInside];
	}
	[deletedButton addTarget:self action:@selector(_thetaShowDeletedInfo:) forControlEvents:UIControlEventTouchUpInside];
}*/

static void _thetaShowDeletedInfo(id self, SEL _cmd, id sender) {
	if (![sender isKindOfClass:[UIButton class]]) return;
	UIButton *button = (UIButton *)sender;
	static char kThetaDeletedServerIdKey;
	NSString *sid = objc_getAssociatedObject(button, &kThetaDeletedServerIdKey);
	if (sid.length == 0) return;
	NSString *deletedMessageDate = [[MessagesManager sharedManager] dateForDeletedMessageWithID:sid];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BHInsta, Hi" message:[NSString stringWithFormat:@"Message deleted at: %@", deletedMessageDate ?: @"Unknown"] preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
	[topMostController() presentViewController:alert animated:YES completion:nil];
}

static char kThetaOriginalBackgroundColorKey;
static char kThetaProcessedMessageIdKey;
static char kThetaOverlayViewKey;

static UIView *thetaFindMessageBubble(UIView *root) {
	if (!root) return nil;
	Class bubbleClass = NSClassFromString(@"IGDirectMessageBubbleView");
	if (bubbleClass && [root isKindOfClass:bubbleClass]) return root;
	// Heuristic: look for any subview class name that contains "BubbleView"
	for (UIView *sub in root.subviews) {
		NSString *className = NSStringFromClass([sub class]);
		if ([className containsString:@"BubbleView"]) return sub;
	}
	for (UIView *sub in root.subviews) {
		UIView *found = thetaFindMessageBubble(sub);
		if (found) return found;
	}
	return nil;
}

static UIView *thetaFindFirstSubviewOfClass(UIView *root, Class cls) {
	if (!root || !cls) return nil;
	for (UIView *sub in root.subviews) {
		if ([sub isKindOfClass:cls]) return sub;
	}
	for (UIView *sub in root.subviews) {
		UIView *found = thetaFindFirstSubviewOfClass(sub, cls);
		if (found) return found;
	}
	return nil;
}

// Find: IGDirectMessageBubbleView (outer) -> IGDirectTextMessageBubbleView -> IGDirectMessageBubbleView (inner target)
static UIView *thetaFindInnerTextMessageBubble(UIView *root) {
	if (!root) return nil;
	Class outerBubble = NSClassFromString(@"IGDirectMessageBubbleView");
	Class textBubble = NSClassFromString(@"IGDirectTextMessageBubbleView");
	Class innerBubble = NSClassFromString(@"IGDirectMessageBubbleView");

	UIView *outer = thetaFindFirstSubviewOfClass(root, outerBubble) ?: root;
	UIView *text = thetaFindFirstSubviewOfClass(outer, textBubble);
	if (!text) {
		// Sometimes the text bubble may be deeper under root
		text = thetaFindFirstSubviewOfClass(root, textBubble);
	}
	if (!text) return nil;
	UIView *inner = thetaFindFirstSubviewOfClass(text, innerBubble);
	return inner ?: nil;
}

static void (*orig_directMessageCell_configure)(id self, SEL _cmd, id viewModel, id specFactory, id launcher);
static void hook_directMessageCell_configure(id self, SEL _cmd, id viewModel, id specFactory, id launcher) {
	orig_directMessageCell_configure(self, _cmd, viewModel, specFactory, launcher);
	if (!ENABLED(@"Keep Deleted Messages")) return;
	if (![viewModel conformsToProtocol:@protocol(IGDirectMessageViewModelProtocol)]) return;

	IGDirectUIMessageMetadata *metadata = [(id<IGDirectMessageViewModelProtocol>)viewModel messageMetadata];
	NSString *serverId = metadata.key.serverId;
	if (serverId.length == 0) return;

	UIView *container = nil;
	if ([self respondsToSelector:@selector(contentViewForVisualMessageViewerPresentation)]) {
		#pragma clang diagnostic push
		#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
		container = [self performSelector:@selector(contentViewForVisualMessageViewerPresentation)];
		#pragma clang diagnostic pop
	}
	if (!container && [self respondsToSelector:@selector(contentView)]) {
		container = [self valueForKey:@"contentView"];
	}
	if (!container && [self isKindOfClass:[UIView class]]) {
		container = (UIView *)self;
	}
	if (!container) return;

	UIView *bubble = thetaFindInnerTextMessageBubble(container);
	if (!bubble) bubble = thetaFindMessageBubble(container);
	if (!bubble) bubble = container;

	UIColor *originalBackgroundColor = objc_getAssociatedObject(bubble, &kThetaOriginalBackgroundColorKey);
	if (!originalBackgroundColor) {
		@try {
			originalBackgroundColor = [bubble valueForKey:@"backgroundColor"];
			if (originalBackgroundColor) {
				objc_setAssociatedObject(bubble, &kThetaOriginalBackgroundColorKey, originalBackgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			}
		} @catch (__unused NSException *e) {}
	}

	NSString *processedServerId = objc_getAssociatedObject(bubble, &kThetaProcessedMessageIdKey);
	if ([processedServerId isKindOfClass:[NSString class]] && [processedServerId isEqualToString:serverId]) {
		return;
	}

	BOOL exists = [[MessagesManager sharedManager] messageExistsWithID:serverId];
	UIColor *targetColor = nil;
	if (exists) {
		@try {
			NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Deleted Message Color_Color"];
			if (!data) {
				targetColor = [UIColor systemRedColor];
			}
			targetColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
		} @catch (__unused NSException *e) {}
		if (!targetColor) targetColor = [UIColor systemRedColor];
	} else if (originalBackgroundColor) {
		targetColor = originalBackgroundColor;
	}

	if (targetColor) {
		@try {
			// 1) Attempt direct background set
			[bubble setValue:targetColor forKey:@"backgroundColor"];
			if ([bubble layer]) {
				bubble.layer.backgroundColor = targetColor.CGColor;
			}
			// 2) Try tinting common shape layers that render the bubble
			CALayer *layer = bubble.layer;
			for (CALayer *sublayer in layer.sublayers ?: @[]) {
				if ([sublayer isKindOfClass:[CAShapeLayer class]]) {
					((CAShapeLayer *)sublayer).fillColor = targetColor.CGColor;
					((CAShapeLayer *)sublayer).backgroundColor = targetColor.CGColor;
				}
			}
			// 3) Ensure a persistent visual using an overlay if needed
			UIView *overlay = objc_getAssociatedObject(bubble, &kThetaOverlayViewKey);
			if (!overlay) {
				overlay = [[UIView alloc] initWithFrame:bubble.bounds];
				overlay.userInteractionEnabled = NO;
				overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
				overlay.layer.cornerRadius = bubble.layer.cornerRadius;
				overlay.layer.masksToBounds = YES;
				objc_setAssociatedObject(bubble, &kThetaOverlayViewKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				// Put behind content but inside bubble
				[bubble insertSubview:overlay atIndex:0];
			}
			overlay.backgroundColor = targetColor;
		} @catch (__unused NSException *e) {}
	}

	objc_setAssociatedObject(bubble, &kThetaProcessedMessageIdKey, serverId, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void (*orig_messageCache2)(id self, SEL _cmd, id updates, id completion);
static void hook_messageCache2(id self, SEL _cmd, id updates, id completion) {
	if (!ENABLED(@"Keep Deleted Messages")) {
		orig_messageCache2(self, _cmd, updates, completion);
		return;
	}

	BOOL shouldBlockUpdate = NO;

	if (updates) {
		id retained = updates;
		static char kThetaRetainedUpdateKey;
		objc_setAssociatedObject(self, &kThetaRetainedUpdateKey, retained, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		NSString *debugDescription = [retained respondsToSelector:@selector(debugDescription)] ? [retained debugDescription] : [retained description];

		id cacheThreadUpdate = nil;
		if ([retained isKindOfClass:[NSArray class]] && [(NSArray *)retained count] > 0) {
			cacheThreadUpdate = [(NSArray *)retained firstObject];
		} else {
			cacheThreadUpdate = retained;
		}

		id threadUpdates = nil;
		if (cacheThreadUpdate && [cacheThreadUpdate respondsToSelector:@selector(valueForKey:)]) {
			threadUpdates = [cacheThreadUpdate valueForKey:@"threadUpdates"];
		}

		id threadUpdateObj = nil;
		if ([threadUpdates isKindOfClass:[NSArray class]] && [(NSArray *)threadUpdates count] > 0) {
			threadUpdateObj = [(NSArray *)threadUpdates firstObject];
		}

		if (threadUpdateObj) {
			static char kThetaRetainedThreadUpdateKey;
			objc_setAssociatedObject(self, &kThetaRetainedThreadUpdateKey, threadUpdateObj, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			@try {
				id messageUpdate = [threadUpdateObj valueForKey:@"_messageUpdate"];
				if (messageUpdate) {
					NSArray *removeKeys = [messageUpdate valueForKey:@"_removeMessages_messageKeys"];
					if (removeKeys.count == 0) {
						// No messages to remove, proceed normally
						orig_messageCache2(self, _cmd, updates, completion);
						return;
					}

					// Process all removeKeys to save deleted messages
					BOOL allValid = YES;
					for (id messageKey in removeKeys) {
						if (![messageKey isKindOfClass:NSClassFromString(@"IGDirectMessageUpdateMessageKey")]) {
							// Invalid message key format, proceed normally
							allValid = NO;
							break;
						}
						IGDirectMessageUpdateMessageKey *updateKey = messageKey;

						id serverIdValue = [updateKey valueForKey:@"_messageServerId"];
						if (!serverIdValue) {
							// No server ID, proceed normally
							allValid = NO;
							break;
						}

						NSString *MsgKey = serverIdValue;
						[[MessagesManager sharedManager] saveDeletedMessageWithID:MsgKey];
						shouldBlockUpdate = YES; // Mark that we should block this update
					}

					// If we found any invalid cases, proceed normally
					if (!allValid) {
						orig_messageCache2(self, _cmd, updates, completion);
						return;
					}
				}
			} @catch (NSException *e) {
				NSLog(@"Error accessing IGDirectThreadUpdate: %@", e);
				// On error, proceed normally
				orig_messageCache2(self, _cmd, updates, completion);
				return;
			}
		}
	}

	// If we successfully saved deleted messages, block the update
	if (shouldBlockUpdate) {
		return;
	}

	// Otherwise, proceed with the original update
	orig_messageCache2(self, _cmd, updates, completion);
}

static void (*orig_messageCache3)(id self, SEL _cmd, id updates, id completion, id userAccess);
static void hook_messageCache3(id self, SEL _cmd, id updates, id completion, id userAccess) {
	if (!ENABLED(@"Keep Deleted Messages")) {
		orig_messageCache3(self, _cmd, updates, completion, userAccess);
		return;
	}

	BOOL shouldBlockUpdate = NO;

	if (updates) {
		id retained = updates;
		static char kThetaRetainedUpdateKey;
		objc_setAssociatedObject(self, &kThetaRetainedUpdateKey, retained, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		NSString *debugDescription = [retained respondsToSelector:@selector(debugDescription)] ? [retained debugDescription] : [retained description];

		id cacheThreadUpdate = nil;
		if ([retained isKindOfClass:[NSArray class]] && [(NSArray *)retained count] > 0) {
			cacheThreadUpdate = [(NSArray *)retained firstObject];
		} else {
			cacheThreadUpdate = retained;
		}

		id threadUpdates = nil;
		if (cacheThreadUpdate && [cacheThreadUpdate respondsToSelector:@selector(valueForKey:)]) {
			threadUpdates = [cacheThreadUpdate valueForKey:@"threadUpdates"];
		}

		id threadUpdateObj = nil;
		if ([threadUpdates isKindOfClass:[NSArray class]] && [(NSArray *)threadUpdates count] > 0) {
			threadUpdateObj = [(NSArray *)threadUpdates firstObject];
		}

		if (threadUpdateObj) {
			static char kThetaRetainedThreadUpdateKey;
			objc_setAssociatedObject(self, &kThetaRetainedThreadUpdateKey, threadUpdateObj, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			@try {
				id messageUpdate = [threadUpdateObj valueForKey:@"_messageUpdate"];
				if (messageUpdate) {
					NSArray *removeKeys = [messageUpdate valueForKey:@"_removeMessages_messageKeys"];
					if (removeKeys.count == 0) {
						// No messages to remove, proceed normally
						orig_messageCache3(self, _cmd, updates, completion, userAccess);
						return;
					}

					// Process all removeKeys to save deleted messages
					BOOL allValid = YES;
					for (id messageKey in removeKeys) {
						if (![messageKey isKindOfClass:NSClassFromString(@"IGDirectMessageUpdateMessageKey")]) {
							// Invalid message key format, proceed normally
							allValid = NO;
							break;
						}
						IGDirectMessageUpdateMessageKey *updateKey = messageKey;

						id serverIdValue = [updateKey valueForKey:@"_messageServerId"];
						if (!serverIdValue) {
							// No server ID, proceed normally
							allValid = NO;
							break;
						}

						NSString *MsgKey = serverIdValue;
						[[MessagesManager sharedManager] saveDeletedMessageWithID:MsgKey];
						shouldBlockUpdate = YES; // Mark that we should block this update
					}

					// If we found any invalid cases, proceed normally
					if (!allValid) {
						orig_messageCache3(self, _cmd, updates, completion, userAccess);
						return;
					}
				}
			} @catch (NSException *e) {
				NSLog(@"Error accessing IGDirectThreadUpdate: %@", e);
				// On error, proceed normally
				orig_messageCache3(self, _cmd, updates, completion, userAccess);
				return;
			}
		}
	}

	// If we successfully saved deleted messages, block the update
	if (shouldBlockUpdate) {
		return;
	}

	// Otherwise, proceed with the original update
	orig_messageCache3(self, _cmd, updates, completion, userAccess);
}

void THRegisterKeepDeletedMessagesHooks(void) {
	Class applicator = objc_getClass("IGDirectCacheUpdatesApplicator");
	NullHookMessageIfPresent(applicator, @selector(_applyThreadUpdates:completion:userAccess:), (void *)hook_messageCache3, &orig_messageCache3);
	NullHookMessageIfPresent(applicator, @selector(_applyThreadUpdates:completion:), (void *)hook_messageCache2, &orig_messageCache2);

	Class messageCell = ThetaFirstClass(@[
		@"_TtC19IGDirectMessageCell19IGDirectMessageCell",
		@"IGDirectMessageCell"
	]);
	NullHookMessageIfPresent(messageCell,
		@selector(configureWithViewModel:ringViewSpecFactory:launcherSet:),
		(void *)hook_directMessageCell_configure,
		&orig_directMessageCell_configure);
}