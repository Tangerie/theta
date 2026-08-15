#import <objc/message.h>
#import <objc/runtime.h>

static NSArray<NSString *> *theta_otherParticipantUsernames(id threadVC);
static Class s_threadVCClass(void);
static id theta_threadVCFromWindow(void);
static id theta_firstVCWithParticipantsFromWindow(void);

static NSString *theta_recipientUsernameFromThreadVCFallback(UIView *rootView) {
	id threadVC = nil;
	Class threadVCClass = s_threadVCClass();
	if (threadVCClass) {
		UIResponder *r = rootView;
		while (r) {
			if ([r isKindOfClass:threadVCClass]) { threadVC = (id)r; break; }
			r = [r nextResponder];
		}
	}
	if (!threadVC) threadVC = theta_threadVCFromWindow();
	if (!threadVC) threadVC = theta_firstVCWithParticipantsFromWindow();
	if (threadVC) {
		NSArray<NSString *> *usernames = theta_otherParticipantUsernames(threadVC);
		if (usernames.count > 0)
			return [[usernames.firstObject lowercaseString] copy];
	}
	return nil;
}

/// Resolves recipient username from nav bar hierarchy. Structure only: Self (rootView) -> IGNavigationBar -> _UINavigationBarContentView -> _UINavigationBarTitleControl -> titleView -> text from _subtitleLabel / _titleLabel / _titleButton.titleLabel. Uses class identity (NSClassFromString + isKindOfClass). When this path fails (e.g. sideload), falls back to thread VC participants. Returns lowercase username or nil.
static NSString *theta_recipientUsernameFromNavBarRootView(UIView *rootView) {
	if (!rootView || ![rootView isKindOfClass:[UIView class]]) return nil;

	// 1. Self -> IGNavigationBar: in rootView.subviews find IGNavigationBar
	Class igNavBarClass = NSClassFromString(@"IGNavigationBar");
	if (!igNavBarClass) return theta_recipientUsernameFromThreadVCFallback(rootView);
	UIView *igNavBar = nil;
	for (UIView *sub in rootView.subviews) {
		if ([sub isKindOfClass:igNavBarClass]) {
			igNavBar = sub;
			break;
		}
	}
	if (!igNavBar) return theta_recipientUsernameFromThreadVCFallback(rootView);

	// 2. IGNavigationBar -> _UINavigationBarContentView: in igNavBar.subviews find content view (try both class names)
	Class contentViewClass = NSClassFromString(@"UINavigationBarContentView");
	if (!contentViewClass) contentViewClass = NSClassFromString(@"_UINavigationBarContentView");
	if (!contentViewClass) return theta_recipientUsernameFromThreadVCFallback(rootView);
	UIView *contentView = nil;
	for (UIView *inner in igNavBar.subviews) {
		if ([inner isKindOfClass:contentViewClass]) {
			contentView = inner;
			break;
		}
	}
	if (!contentView) return theta_recipientUsernameFromThreadVCFallback(rootView);

	// 3. _UINavigationBarContentView -> _UINavigationBarTitleControl: in contentView.subviews find title control
	Class titleControlClass = NSClassFromString(@"UINavigationBarTitleControl");
	if (!titleControlClass) titleControlClass = NSClassFromString(@"_UINavigationBarTitleControl");
	if (!titleControlClass) return theta_recipientUsernameFromThreadVCFallback(rootView);
	UIView *titleControl = nil;
	for (UIView *sub in contentView.subviews) {
		if ([sub isKindOfClass:titleControlClass]) {
			titleControl = sub;
			break;
		}
	}
	if (!titleControl) return theta_recipientUsernameFromThreadVCFallback(rootView);

	// 4. titleControl -> titleView
	id titleView = nil;
	@try { titleView = [titleControl valueForKey:@"titleView"]; } @catch (__unused NSException *e) { titleView = nil; }
	if (!titleView) @try { titleView = [titleControl valueForKey:@"_titleView"]; } @catch (__unused NSException *e) {}
	if (!titleView) return theta_recipientUsernameFromThreadVCFallback(rootView);

	// 5. titleView -> text from _subtitleLabel, then _titleLabel, then _titleButton.titleLabel
	static NSString *(^getLabelText)(id view, Ivar ivar) = ^NSString *(id view, Ivar ivar) {
		if (!view || !ivar) return nil;
		id label = object_getIvar(view, ivar);
		if (!label) return nil;
		NSString *s = nil;
		@try {
			if ([label respondsToSelector:@selector(text)]) s = [label performSelector:@selector(text)];
			if (!s.length) s = [label valueForKey:@"text"];
		} @catch (__unused NSException *e) { s = nil; }
		return [s isKindOfClass:[NSString class]] ? s : nil;
	};
	Class titleViewClass = [titleView class];
	NSString *text = nil;
	Ivar subtitleIvar = class_getInstanceVariable(titleViewClass, "_subtitleLabel");
	if (subtitleIvar) text = getLabelText(titleView, subtitleIvar);
	if (!text.length) {
		Ivar titleLabelIvar = class_getInstanceVariable(titleViewClass, "_titleLabel");
		if (titleLabelIvar) text = getLabelText(titleView, titleLabelIvar);
	}
	if (!text.length) {
		Ivar titleButtonIvar = class_getInstanceVariable(titleViewClass, "_titleButton");
		if (titleButtonIvar) {
			id titleButton = object_getIvar(titleView, titleButtonIvar);
			NSString *titleText = nil;
			// Try titleLabel.text first (works on jailbreak)
			id titleLabel = nil;
			@try { titleLabel = [titleButton valueForKey:@"titleLabel"]; } @catch (__unused NSException *e) { titleLabel = nil; }
			if (titleLabel) {
				@try {
					if ([titleLabel respondsToSelector:@selector(text)]) titleText = [titleLabel performSelector:@selector(text)];
					if (!titleText.length) titleText = [titleLabel valueForKey:@"text"];
				} @catch (__unused NSException *e) {}
			}
			// Sideload: when _subtitleLabel/_titleLabel have no text, titleLabel may be inaccessible; use UIButton's public API
			if (![titleText isKindOfClass:[NSString class]] || !titleText.length) {
				@try {
					if ([titleButton respondsToSelector:@selector(currentTitle)])
						titleText = [titleButton performSelector:@selector(currentTitle)];
					if ((!titleText.length) && [titleButton isKindOfClass:[UIButton class]])
						titleText = [(UIButton *)titleButton titleForState:UIControlStateNormal];
				} @catch (__unused NSException *e) {}
			}
			if ([titleText isKindOfClass:[NSString class]] && titleText.length) text = titleText;
		}
	}
	if (!text.length) return theta_recipientUsernameFromThreadVCFallback(rootView);

	// Business Chat: subtitle shows "Business Chat", username is on _titleButton.titleLabel
	if ([text rangeOfString:@"Business Chat" options:NSCaseInsensitiveSearch].length > 0) {
		Ivar titleButtonIvar = class_getInstanceVariable(titleViewClass, "_titleButton");
		if (titleButtonIvar) {
			id titleButton = object_getIvar(titleView, titleButtonIvar);
			id titleLabel = nil;
			@try { titleLabel = [titleButton valueForKey:@"titleLabel"]; } @catch (__unused NSException *e) { titleLabel = nil; }
			NSString *titleText = nil;
			@try {
				if ([titleLabel respondsToSelector:@selector(text)]) titleText = [titleLabel performSelector:@selector(text)];
				if (!titleText.length) titleText = [titleLabel valueForKey:@"text"];
			} @catch (__unused NSException *e) { titleText = nil; }
			if ([titleText isKindOfClass:[NSString class]] && titleText.length) text = titleText;
		}
	}

	NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (trimmed.length == 0) return theta_recipientUsernameFromThreadVCFallback(rootView);
	if ([trimmed hasPrefix:@"@"] && trimmed.length > 1) trimmed = [trimmed substringFromIndex:1];
	return [[trimmed lowercaseString] copy];
}

/// Returns YES if the recipient shown in this nav bar (resolved via theta_recipientUsernameFromNavBarRootView) is in the Mark As Seen auto-mark list. Use this for the list button state so it matches add/remove (same username source).
static BOOL theta_isNavBarRecipientInAutoMarkList(UIView *navBarView) {
	if (!navBarView) return NO;
	NSString *username = theta_recipientUsernameFromNavBarRootView(navBarView);
	if (!username.length) return NO;
	NSArray *list = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_MarkAsSeen_AutoMarkUserIds"];
	if (![list isKindOfClass:[NSArray class]]) return NO;
	for (id obj in list) {
		if ([obj isKindOfClass:[NSString class]] && [[(NSString *)obj lowercaseString] isEqualToString:username])
			return YES;
	}
	return NO;
}

/// Returns YES if any participant in the given thread VC is in the Mark As Seen auto-mark list. Uses theta_otherParticipantUsernames first; if that returns empty (e.g. business account), uses nav-bar title resolution so the button state matches add/remove.
static BOOL isThreadVCInAutoMarkList(id threadVC) {
	if (!threadVC) return NO;
	@try {
		NSArray<NSString *> *usernames = theta_otherParticipantUsernames(threadVC);
		if (usernames.count == 0) {
			UIView *root = nil;
			@try {
				id nav = ThetaValueForKey(threadVC, @"navigationController");
				if (nav) root = ThetaValueForKey(nav, @"view");
				if (!root) root = ThetaValueForKey(threadVC, @"view");
			} @catch (__unused NSException *e) { root = nil; }
			if (root) {
				NSString *one = theta_recipientUsernameFromNavBarRootView(root);
				if (one.length) usernames = @[ one ];
			}
		}
		if (!usernames.count) return NO;
		NSArray *list = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_MarkAsSeen_AutoMarkUserIds"];
		if (![list isKindOfClass:[NSArray class]]) return NO;
		NSMutableSet *listSet = [NSMutableSet set];
		for (id obj in list) {
			if ([obj isKindOfClass:[NSString class]])
				[listSet addObject:[(NSString *)obj lowercaseString]];
		}
		if (listSet.count == 0) return NO;
		for (NSString *u in usernames) {
			if ([listSet containsObject:u]) return YES;
		}
		return NO;
	} @catch (__unused NSException *e) {
		return NO;
	}
}

/// Returns YES if any participant in the current thread (from data source self) is in the Mark As Seen auto-mark list. Resolves thread VC from data source and reuses isThreadVCInAutoMarkList.
static BOOL isThreadParticipantInAutoMarkList(id dataSource) {
	if (!dataSource) return NO;
	@try {
		id delegate = ThetaValueForKey(dataSource, @"delegate");
		if (!delegate) delegate = ThetaValueForKey(dataSource, @"_delegate");
		if (!delegate) return NO;
		id threadVC = ThetaValueForKey(delegate, @"delegate");
		if (!threadVC) threadVC = ThetaValueForKey(delegate, @"_delegate");
		if (!threadVC) threadVC = ThetaValueForKey(delegate, @"threadViewController");
		if (!threadVC) return NO;
		return isThreadVCInAutoMarkList(threadVC);
	} @catch (__unused NSException *e) {
		return NO;
	}
}

static BOOL theta_autoMarkListIsEmpty(void) {
	NSArray *list = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_MarkAsSeen_AutoMarkUserIds"];
	return ![list isKindOfClass:[NSArray class]] || list.count == 0;
}

static BOOL (*orig_markMessagesAsSeen)(id self, SEL _cmd);
static BOOL hook_markMessagesAsSeen(id self, SEL _cmd) {
	BOOL markAsSeen = ENABLED(@"Mark As Seen");
	BOOL seenOnTyping = ENABLED(@"Seen On Typing");
	BOOL seenOnReact = ENABLED(@"Seen On React");
	BOOL seenOnSend = ENABLED(@"Seen On Send");
	BOOL anyFeature = markAsSeen || seenOnTyping || seenOnReact || seenOnSend;

	// Fast path: nothing to intercept — avoid KVC that can throw on IG 441 data sources.
	if (!anyFeature && theta_autoMarkListIsEmpty()) {
		return orig_markMessagesAsSeen(self, _cmd);
	}

	// If any thread participant is in the auto-mark list, use normal (auto) mark-as-seen behavior.
	BOOL inAutoList = NO;
	@try {
		inAutoList = isThreadParticipantInAutoMarkList(self);
	} @catch (__unused NSException *e) {
		inAutoList = NO;
	}
	if (inAutoList) {
		return orig_markMessagesAsSeen(self, _cmd);
	}

	// If all settings are off, return original implementation
	if (!anyFeature) {
		return orig_markMessagesAsSeen(self, _cmd);
	}

	// If all settings are on, return NO
	if (markAsSeen && seenOnTyping && seenOnReact && seenOnSend) {
		return NO;
	}

	// If exactly one setting is on and the other two are off, return NO
	if ((markAsSeen && !seenOnTyping && !seenOnReact) ||
		(!markAsSeen && seenOnTyping && !seenOnReact && !seenOnSend) ||
		(!markAsSeen && !seenOnTyping && seenOnReact && !seenOnSend) ||
		(!markAsSeen && !seenOnTyping && !seenOnReact && seenOnSend)) {
		return NO;
	}

	// For any other combination (2 on, 1 off), return NO
	return NO;
}

static Class s_threadVCClass(void) {
	static Class c = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ c = NSClassFromString(@"IGDirectThreadViewController"); });
	return c;
}

// Debug logging macro for Mark As Seen; currently disabled to avoid log spam in normal use.
#define THETA_MARKASSEEN_LOG(fmt, ...) do {} while (0)

// Returns an SF Symbol image filled with a specific solid color for use in toasts.
static UIImage *thetaColoredSystemSymbol(NSString *name, UIColor *color) {
	if (name.length == 0 || !color) return nil;
	UIImage *img = [UIImage systemImageNamed:name];
	if (!img || !img.CGImage) return nil;
	CGSize size = img.size;
	CGFloat scale = img.scale > 0 ? img.scale : [UIScreen mainScreen].scale;
	UIGraphicsBeginImageContextWithOptions(size, NO, scale);
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	if (ctx) {
		CGRect rect = CGRectMake(0, 0, size.width, size.height);
		CGContextTranslateCTM(ctx, 0, size.height);
		CGContextScaleCTM(ctx, 1.0, -1.0);
		CGContextClipToMask(ctx, rect, img.CGImage);
		[color setFill];
		CGContextFillRect(ctx, rect);
	}
	UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// Returns the IGDirectThreadViewController from a view. Uses responder chain first (same as FLEX "closest view controller").
static id theta_threadVCFromView(UIView *view) {
	if (!view) {
		THETA_MARKASSEEN_LOG(@"threadVCFromView: view is nil");
		return nil;
	}
	Class threadVCClass = s_threadVCClass();
	if (!threadVCClass) return nil;
	UIResponder *r = view;
	while (r) {
		if ([r isKindOfClass:[UIViewController class]] && [r isKindOfClass:threadVCClass]) {
			THETA_MARKASSEEN_LOG(@"threadVCFromView: found VC from %@", NSStringFromClass([view class]));
			return (id)r;
		}
		r = [r nextResponder];
	}
	THETA_MARKASSEEN_LOG(@"threadVCFromView: no VC in chain from %@", NSStringFromClass([view class]));
	return nil;
}

// Fallback: find IGDirectThreadViewController from key window hierarchy (when responder chain from nav bar doesn't reach it).
static id theta_threadVCFromWindow(void) {
	Class threadVCClass = s_threadVCClass();
	if (!threadVCClass) return nil;
	@try {
		NSArray *windows = [UIApplication sharedApplication].windows;
		if (![windows isKindOfClass:[NSArray class]]) return nil;
		// Search key window first, then all windows (DM might be in a presented or secondary window).
		UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
		NSMutableArray *toTry = [NSMutableArray array];
		if (keyWin) [toTry addObject:keyWin];
		for (UIWindow *w in windows) {
			if (w && w != keyWin) [toTry addObject:w];
		}
		for (UIWindow *window in toTry) {
			UIViewController *root = window.rootViewController;
			if (!root) continue;
			NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
			while (stack.count) {
				UIViewController *vc = [stack lastObject];
				[stack removeLastObject];
				if ([vc isKindOfClass:threadVCClass]) {
					THETA_MARKASSEEN_LOG(@"threadVCFromWindow: found");
					return vc;
				}
				if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
				for (UIViewController *child in vc.childViewControllers) {
					[stack addObject:child];
				}
				if ([vc isKindOfClass:[UINavigationController class]]) {
					UIViewController *top = [(UINavigationController *)vc topViewController];
					if (top) [stack addObject:top];
				}
			}
		}
	} @catch (__unused NSException *e) {}
	THETA_MARKASSEEN_LOG(@"threadVCFromWindow: not found");
	return nil;
}

// Sideload when class name is stripped: find first VC in window hierarchy that has participant usernames (no class check).
static id theta_firstVCWithParticipantsFromWindow(void) {
	@try {
		NSArray *windows = [UIApplication sharedApplication].windows;
		if (![windows isKindOfClass:[NSArray class]]) return nil;
		UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
		NSMutableArray *toTry = [NSMutableArray array];
		if (keyWin) [toTry addObject:keyWin];
		for (UIWindow *w in windows) {
			if (w && w != keyWin) [toTry addObject:w];
		}
		for (UIWindow *window in toTry) {
			UIViewController *root = window.rootViewController;
			if (!root) continue;
			NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
			while (stack.count) {
				UIViewController *vc = [stack lastObject];
				[stack removeLastObject];
				NSArray<NSString *> *usernames = theta_otherParticipantUsernames((id)vc);
				if (usernames.count > 0) return (id)vc;
				if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
				for (UIViewController *child in vc.childViewControllers) [stack addObject:child];
				if ([vc isKindOfClass:[UINavigationController class]]) {
					UIViewController *top = [(UINavigationController *)vc topViewController];
					if (top) [stack addObject:top];
				}
			}
		}
	} @catch (__unused NSException *e) {}
	return nil;
}

// Try to get thread object from an object by key path and by direct ivar (runtime).
static id theta_getThreadFromObject(id obj) {
	if (!obj) return nil;
	id thread = nil;
	@try {
		thread = [obj valueForKey:@"thread"];
		if (!thread) thread = [obj valueForKey:@"_thread"];
		if (!thread) thread = [obj valueForKey:@"directThread"];
		if (!thread) thread = [obj valueForKey:@"_directThread"];
		if (!thread) {
			id vm = [obj valueForKey:@"threadViewModel"];
			if (vm) thread = theta_getThreadFromObject(vm);
			if (!thread) {
				vm = [obj valueForKey:@"viewModel"];
				if (vm) thread = theta_getThreadFromObject(vm);
			}
		}
	}
	@catch (__unused NSException *e) {}
	if (thread) return thread;
	// Direct ivar read in case property/getter changed in app version
	Class cls = [obj class];
	const char *ivarNames[] = { "_thread", "thread", "_directThread", "directThread", NULL };
	for (const char **p = ivarNames; *p; p++) {
		Ivar ivar = class_getInstanceVariable(cls, *p);
		if (ivar) {
			id val = object_getIvar(obj, ivar);
			if (val && [val isKindOfClass:[NSObject class]]) return val;
		}
	}
	return nil;
}

/// Resolves a lowercase username (or pk string) from a user-like object. Handles business/linked accounts where the real user may be in linkedUser, user, or profile.
static NSString *theta_usernameFromUserLikeObject(id user) {
	if (!user) return nil;
	NSString *username = nil;
	@try {
		if ([user respondsToSelector:@selector(username)]) username = [user performSelector:@selector(username)];
		if (!username.length) username = [user valueForKey:@"username"];
		if (![username isKindOfClass:[NSString class]] || !username.length) username = nil;
		if (!username.length && [user respondsToSelector:@selector(name)]) username = [user performSelector:@selector(name)];
		if (!username.length) username = [user valueForKey:@"name"];
		if (![username isKindOfClass:[NSString class]] || !username.length) username = nil;
		// Business / linked accounts: real user is often in linkedUser, user, or profile.
		if (!username.length) {
			id inner = [user valueForKey:@"linkedUser"];
			if (!inner) inner = [user valueForKey:@"user"];
			if (!inner) inner = [user valueForKey:@"profile"];
			if (!inner) inner = [user valueForKey:@"_linkedUser"];
			if (!inner) inner = [user valueForKey:@"_user"];
			if (inner) {
				if ([inner respondsToSelector:@selector(username)]) username = [inner performSelector:@selector(username)];
				if (!username.length) username = [inner valueForKey:@"username"];
				if (![username isKindOfClass:[NSString class]] || !username.length) username = [inner valueForKey:@"name"];
			}
		}
		if (![username isKindOfClass:[NSString class]] || !username.length) username = nil;
		// Fallback: use pk as string so we still have a stable id (e.g. business account with no username on wrapper).
		if (!username.length) {
			id pk = [user valueForKey:@"pk"];
			if ([pk isKindOfClass:[NSNumber class]]) username = [(NSNumber *)pk stringValue];
			else if ([pk isKindOfClass:[NSString class]]) username = (NSString *)pk;
		}
	} @catch (__unused NSException *e) { username = nil; }
	if ([username isKindOfClass:[NSString class]] && username.length > 0)
		return [username lowercaseString];
	return nil;
}

// Try to get participants array from a thread-like object via common keys and ivars.
static NSArray *theta_getParticipantsFromThreadObject(id thread) {
	if (!thread) return nil;
	NSArray *participants = nil;
	@try {
		participants = [thread valueForKey:@"users"];
		if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) participants = [thread valueForKey:@"participants"];
		if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) participants = [thread valueForKey:@"otherParticipants"];
		if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) participants = [thread valueForKey:@"recipients"];
		if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) participants = [thread valueForKey:@"threadUsers"];
		if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) participants = [thread valueForKey:@"allParticipants"];
	} @catch (__unused NSException *e) {}
	if ([participants isKindOfClass:[NSArray class]] && participants.count > 0) return participants;

	// Try common ivar names for participants
	Class cls = [thread class];
	const char *ivarNames[] = { "_users", "users", "_participants", "participants", "_otherParticipants", "otherParticipants", "_recipients", "recipients", NULL };
	for (const char **p = ivarNames; *p; p++) {
		Ivar ivar = class_getInstanceVariable(cls, *p);
		if (!ivar) continue;
		id val = object_getIvar(thread, ivar);
		if ([val isKindOfClass:[NSArray class]] && [(NSArray *)val count] > 0) {
			return (NSArray *)val;
		}
	}
	return nil;
}

// Returns an array of other participants' usernames (lowercase) for the given thread VC. Excludes current user.
static NSArray<NSString *> *theta_otherParticipantUsernames(id threadVC) {
	id thread = nil;
	id dataSource = nil;
	@try {
		thread = theta_getThreadFromObject(threadVC);
		if (!thread) {
			dataSource = [threadVC valueForKey:@"_messageListDataSource"];
			if (!dataSource) dataSource = [threadVC valueForKey:@"messageListDataSource"];
			if (!dataSource) dataSource = [threadVC valueForKey:@"_messageListAdapterDataSource"];
			if (!dataSource) dataSource = [threadVC valueForKey:@"messageListAdapterDataSource"];
			THETA_MARKASSEEN_LOG(@"dataSource %@", dataSource ? NSStringFromClass([dataSource class]) : @"nil");
			if (dataSource) {
				thread = theta_getThreadFromObject(dataSource);
			}
			if (!thread && dataSource) {
				id delegate = [dataSource valueForKey:@"delegate"];
				if (delegate) {
					id vc = [delegate valueForKey:@"delegate"];
					if (vc) thread = theta_getThreadFromObject(vc);
				}
			}
		}
	} @catch (__unused NSException *e) {}
	if (!thread) {
		THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: no thread on VC (tried VC, dataSource, delegate.delegate)");
		// Fallback even without thread: derive lastSender from data source.
		if (!dataSource) {
			@try {
				dataSource = [threadVC valueForKey:@"_messageListDataSource"];
				if (!dataSource) dataSource = [threadVC valueForKey:@"messageListDataSource"];
			} @catch (__unused NSException *e) { dataSource = nil; }
		}
		id lastSender = nil;
		@try {
			if (dataSource && [dataSource respondsToSelector:@selector(mostRecentMessageSenderProfileImage)]) {
				id lastSenderImg = [dataSource performSelector:@selector(mostRecentMessageSenderProfileImage)];
				if (lastSenderImg) {
					Ivar profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImage_user");
					if (profileImageUserIvar) {
						lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
					} else {
						profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImageModel_user");
						if (profileImageUserIvar) {
							lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
						}
					}
				}
			}
		} @catch (__unused NSException *e) { lastSender = nil; }
		if (!lastSender) {
			THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: fallback lastSender not found (no thread case)");
			return @[];
		}
		NSString *lsUsername = theta_usernameFromUserLikeObject(lastSender);
		if (!lsUsername.length) {
			THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: fallback lastSender has no username (no thread case)");
			return @[];
		}
		THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: using fallback lastSender %@ (no thread case)", lsUsername);
		return @[ lsUsername ];
	}
	NSArray *participants = theta_getParticipantsFromThreadObject(thread);
	if (![participants isKindOfClass:[NSArray class]] || participants.count == 0) {
		THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: no participants after thread inspect (class=%@)", NSStringFromClass([thread class]));
		// Fallback: use last sender from data source (works for 1:1 and is good-enough for groups).
		if (!dataSource) {
			@try {
				dataSource = [threadVC valueForKey:@"_messageListDataSource"];
				if (!dataSource) dataSource = [threadVC valueForKey:@"messageListDataSource"];
			} @catch (__unused NSException *e) { dataSource = nil; }
		}
		id lastSender = nil;
		@try {
			if (dataSource && [dataSource respondsToSelector:@selector(mostRecentMessageSenderProfileImage)]) {
				id lastSenderImg = [dataSource performSelector:@selector(mostRecentMessageSenderProfileImage)];
				if (lastSenderImg) {
					Ivar profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImage_user");
					if (profileImageUserIvar) {
						lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
					} else {
						profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImageModel_user");
						if (profileImageUserIvar) {
							lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
						}
					}
				}
			}
		} @catch (__unused NSException *e) { lastSender = nil; }
		if (!lastSender) {
			THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: fallback lastSender not found");
			return @[];
		}
		NSString *lsUsername = theta_usernameFromUserLikeObject(lastSender);
		if (!lsUsername.length) {
			THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: fallback lastSender has no username");
			return @[];
		}
		THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: using fallback lastSender %@", lsUsername);
		participants = @[ lastSender ];
	}
	NSString *currentUsername = nil;
	@try {
		id session = [threadVC valueForKey:@"userSession"];
		if (!session) session = [threadVC valueForKey:@"_userSession"];
		if (session) {
			id cur = [session valueForKey:@"currentUser"];
			if (!cur) cur = [session valueForKey:@"currentIgUser"];
			if (!cur) cur = [session valueForKey:@"user"];
			currentUsername = theta_usernameFromUserLikeObject(cur);
		}
	} @catch (__unused NSException *e) {}
	NSMutableArray<NSString *> *usernames = [NSMutableArray array];
	for (id user in participants) {
		if (!user) continue;
		NSString *username = theta_usernameFromUserLikeObject(user);
		if (username.length && (!currentUsername || ![username isEqualToString:currentUsername]))
			[usernames addObject:username];
	}
	// If we have a thread object and participants but ended up with no non-self usernames (e.g. some account types),
	// fall back to lastSender just like the no-participants path so the auto-mark list button still works.
	if (usernames.count == 0) {
		THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: participants but no non-self usernames; falling back to lastSender / title");
		// First try lastSender again (business accounts, different wrappers, etc.)
		if (!dataSource) {
			@try {
				dataSource = [threadVC valueForKey:@"_messageListDataSource"];
				if (!dataSource) dataSource = [threadVC valueForKey:@"messageListDataSource"];
			} @catch (__unused NSException *e) { dataSource = nil; }
		}
		id lastSender = nil;
		@try {
			if (dataSource && [dataSource respondsToSelector:@selector(mostRecentMessageSenderProfileImage)]) {
				id lastSenderImg = [dataSource performSelector:@selector(mostRecentMessageSenderProfileImage)];
				if (lastSenderImg) {
					Ivar profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImage_user");
					if (profileImageUserIvar) {
						lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
					} else {
						profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImageModel_user");
						if (profileImageUserIvar) {
							lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
						}
					}
				}
			}
		} @catch (__unused NSException *e) { lastSender = nil; }
		if (lastSender) {
			NSString *lsUsername = theta_usernameFromUserLikeObject(lastSender);
			if (lsUsername.length) {
				[usernames addObject:[lsUsername copy]];
			}
		}
		// If still empty, fall back to IGDirectThreadViewController.title, which is the recipient username for many business accounts.
		if (usernames.count == 0) {
			@try {
				id titleObj = [threadVC valueForKey:@"title"];
				if ([titleObj isKindOfClass:[NSString class]]) {
					NSString *title = [(NSString *)titleObj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
					if (title.length > 0) {
						if ([title hasPrefix:@"@"] && title.length > 1) {
							title = [title substringFromIndex:1];
						}
						NSString *lower = [[title lowercaseString] copy];
						if (lower.length > 0) {
							THETA_MARKASSEEN_LOG(@"otherParticipantUsernames: using threadVC.title fallback %@", lower);
							[usernames addObject:lower];
						}
					}
				}
			} @catch (__unused NSException *e) {}
		}
	}
	return usernames;
}

/// Returns YES if we should call markLastMessageAsSeen: there is at least one unread message from the recipient (last message is from them and tracker reports unseen). Returns NO if last message is from self or already seen. Visible for Seen On Typing (BypassCharacterLimit.m).
BOOL theta_hasUnreadFromRecipient(id threadVC) {
	if (!threadVC) return NO;
	id dataSource = nil;
	@try {
		dataSource = [threadVC valueForKey:@"_messageListDataSource"];
		if (!dataSource) dataSource = [threadVC valueForKey:@"messageListDataSource"];
	} @catch (__unused NSException *e) { dataSource = nil; }
	if (!dataSource) return NO;

	id tracker = nil;
	@try {
		id delegate = [dataSource valueForKey:@"delegate"];
		if (delegate) tracker = [delegate valueForKey:@"_lastSeenMessageTracker"];
	} @catch (__unused NSException *e) { tracker = nil; }
	if (!tracker || ![tracker respondsToSelector:@selector(hasUnseenMessages)]) return NO;
	if (![tracker performSelector:@selector(hasUnseenMessages)]) return NO;

	id lastSender = nil;
	@try {
		if ([dataSource respondsToSelector:@selector(mostRecentMessageSenderProfileImage)]) {
			id lastSenderImg = [dataSource performSelector:@selector(mostRecentMessageSenderProfileImage)];
			if (lastSenderImg) {
				Ivar ivar = class_getInstanceVariable([lastSenderImg class], "_profileImage_user");
				if (ivar) lastSender = object_getIvar(lastSenderImg, ivar);
				if (!lastSender) {
					ivar = class_getInstanceVariable([lastSenderImg class], "_profileImageModel_user");
					if (ivar) lastSender = object_getIvar(lastSenderImg, ivar);
				}
			}
		}
	} @catch (__unused NSException *e) { lastSender = nil; }
	if (!lastSender) return NO;

	NSString *lastSenderId = theta_usernameFromUserLikeObject(lastSender);
	if (!lastSenderId.length) return NO;

	id session = nil;
	@try { session = [threadVC valueForKey:@"userSession"]; if (!session) session = [threadVC valueForKey:@"_userSession"]; } @catch (__unused NSException *e) {}
	if (!session) return YES;
	id cur = nil;
	@try {
		cur = [session valueForKey:@"currentUser"];
		if (!cur) cur = [session valueForKey:@"currentIgUser"];
		if (!cur) cur = [session valueForKey:@"user"];
	} @catch (__unused NSException *e) { cur = nil; }
	if (!cur) return YES;
	NSString *currentId = theta_usernameFromUserLikeObject(cur);
	if (currentId.length && [lastSenderId isEqualToString:currentId]) return NO;
	return YES;
}

/// Shows "Marked as seen!" toast after a short delay so the key window is stable (reaction sheet/composer dismissed). Use for auto-mark, Seen On Send, Seen On Typing, Seen On React. Manual button uses immediate toast.
static void theta_showMarkedAsSeenToastDeferred(void) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (ENABLED(@"Show Banners")) {
			[ThetaHelper showToastWithTitle:@"Marked as seen!" subtitle:@"They know we are here." icon:[ThetaHelper imageFromEmojiString:@"👀" width:60] autoHide:4 openURL:nil];
		}
	});
}

/// Performs markLastMessageAsSeen using thread VC, then list VC, then delegate/tracker so marking actually takes effect (same pattern as manual button / Seen on Typing).
static void theta_performMarkLastMessageAsSeen(id threadViewController, id listViewController) {
	if ([threadViewController respondsToSelector:@selector(markLastMessageAsSeen)]) {
		[threadViewController performSelector:@selector(markLastMessageAsSeen)];
		return;
	}
	if (listViewController && [listViewController respondsToSelector:@selector(markLastMessageAsSeen)]) {
		[listViewController performSelector:@selector(markLastMessageAsSeen)];
		return;
	}
	id dataSource = [threadViewController valueForKey:@"_messageListDataSource"];
	if (!dataSource) dataSource = [threadViewController valueForKey:@"messageListDataSource"];
	id delegate = dataSource ? [dataSource valueForKey:@"delegate"] : nil;
	if (delegate && [delegate respondsToSelector:@selector(markLastMessageAsSeen)]) {
		[delegate performSelector:@selector(markLastMessageAsSeen)];
		return;
	}
	id tracker = delegate ? [delegate valueForKey:@"_lastSeenMessageTracker"] : nil;
	if (tracker && [tracker respondsToSelector:@selector(markLastMessageAsSeen)]) {
		[tracker performSelector:@selector(markLastMessageAsSeen)];
	}
	if (ENABLED(@"Show Banners")) {
		[ThetaHelper showToastWithTitle:@"Marked as seen!" subtitle:@"They know we are here." icon:[ThetaHelper imageFromEmojiString:@"👀" width:60] autoHide:4 openURL:nil];
	}
}

static void seenButtonHandler(id self);

static void theta_updateListToggleButtonImage(UIButton *listButton, BOOL inList) {
	UIImage *img = [UIImage systemImageNamed:inList ? @"checkmark.circle.fill" : @"plus.circle"];
	[listButton setImage:img forState:UIControlStateNormal];
}

static UIView *theta_makeSeenButtonView(id navBarSelf) {
	CGFloat w = 44.0 * 2.0 + 8.0;
	UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
	container.backgroundColor = [UIColor clearColor];

	// Use nav-bar-based check so button state matches add/remove (same username source as tap handler).
	NSString *usernameAtCreate = theta_recipientUsernameFromNavBarRootView((UIView *)navBarSelf);
	BOOL inList = usernameAtCreate.length && theta_isNavBarRecipientInAutoMarkList((UIView *)navBarSelf);

	UIButton *listButton = [UIButton buttonWithType:UIButtonTypeSystem];
	listButton.frame = CGRectMake(0, 0, 44, 44);
	theta_updateListToggleButtonImage(listButton, inList);
	listButton.accessibilityLabel = inList ? @"Remove from auto-mark list" : @"Add to auto-mark list";
	[container addSubview:listButton];

	// Re-evaluate list state shortly after creation, once data source/thread are fully wired up.
	__weak typeof(navBarSelf) weakNavForDelayed = navBarSelf;
	__weak UIButton *weakListButton = listButton;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		UIButton *strongBtn = weakListButton;
		if (!strongBtn) return;
		// Same nav-bar-based check so state matches add/remove when re-entering conversation.
		BOOL inListLater = theta_isNavBarRecipientInAutoMarkList((UIView *)weakNavForDelayed);
		theta_updateListToggleButtonImage(strongBtn, inListLater);
		strongBtn.accessibilityLabel = inListLater ? @"Remove from auto-mark list" : @"Add to auto-mark list";
	});

	UIButton *seenButton = [UIButton buttonWithType:UIButtonTypeSystem];
	seenButton.frame = CGRectMake(44 + 8, 0, 44, 44);
	[seenButton setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
	seenButton.accessibilityLabel = @"Mark as seen";
	__weak typeof(navBarSelf) weakSelf = navBarSelf;
	[seenButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
		seenButtonHandler(weakSelf);
	}] forControlEvents:UIControlEventTouchUpInside];
	[container addSubview:seenButton];
	ThetaSetCaptureHiding(container);

	__weak typeof(navBarSelf) weakNavBar = navBarSelf;
	[listButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
		NSString *resolvedUsername = theta_recipientUsernameFromNavBarRootView((UIView *)weakNavBar);
		NSArray<NSString *> *usernames = resolvedUsername.length ? @[ resolvedUsername ] : @[];
		if (usernames.count == 0) {
			THETA_MARKASSEEN_LOG(@"early return: no usernames");
			return;
		}
		NSMutableArray *list = [NSMutableArray array];
		NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_MarkAsSeen_AutoMarkUserIds"];
		if ([stored isKindOfClass:[NSArray class]]) [list addObjectsFromArray:stored];
		BOOL anyInList = NO;
		for (NSString *u in usernames) {
			if ([list containsObject:u]) { anyInList = YES; break; }
		}
		if (anyInList) {
			[list removeObjectsInArray:usernames];
			theta_updateListToggleButtonImage(listButton, NO);
			listButton.accessibilityLabel = @"Add to auto-mark list";
			THETA_MARKASSEEN_LOG(@"removed from list, saving %lu entries", (unsigned long)list.count);
			if (ENABLED(@"Show Banners")) {
				UIImage *icon = thetaColoredSystemSymbol(@"minus.circle", [UIColor systemRedColor]);
				[ThetaHelper showToastWithTitle:[NSString stringWithFormat:@"Removed @%@ from list", usernames.firstObject] subtitle:@"No longer know we're here." icon:icon autoHide:3 openURL:nil];
			}
		} else {
			for (NSString *u in usernames) {
				if (![list containsObject:u]) [list addObject:u];
			}
			theta_updateListToggleButtonImage(listButton, YES);
			listButton.accessibilityLabel = @"Remove from auto-mark list";
			THETA_MARKASSEEN_LOG(@"added to list: %@, saving %lu entries", usernames, (unsigned long)list.count);
			if (ENABLED(@"Show Banners")) {
				NSString *msg = usernames.count == 1
					? [NSString stringWithFormat:@"Added @%@ to list", usernames.firstObject]
					: [NSString stringWithFormat:@"%lu user(s) added.", (unsigned long)usernames.count];
				UIImage *icon = thetaColoredSystemSymbol(@"checkmark.circle.fill", [UIColor systemGreenColor]);
				[ThetaHelper showToastWithTitle:msg subtitle:@"They will know we're here." icon:icon autoHide:3 openURL:nil];
			}
		}
		[[NSUserDefaults standardUserDefaults] setObject:list forKey:@"Theta_MarkAsSeen_AutoMarkUserIds"];
		[[NSUserDefaults standardUserDefaults] synchronize];
		THETA_MARKASSEEN_LOG(@"saved to UserDefaults");
	}] forControlEvents:UIControlEventTouchUpInside];

	return container;
}

static void seenButtonHandler(id self) {
    @try {
		UIResponder *responder = self;
		while ((responder = [responder nextResponder])) {
			if ([responder isKindOfClass:[UIViewController class]]) {
				break;
			}
		}

		if ([responder isKindOfClass:objc_getClass("IGDirectThreadViewController")]) {
			id threadVC = responder;
			// Manual button: always mark when tapped (no unread check); use full chain so it works across accounts.
			if (!theta_hasUnreadFromRecipient(threadVC)) return;
			theta_performMarkLastMessageAsSeen(threadVC, nil);
			if (ENABLED(@"Show Banners")) {
				[ThetaHelper showToastWithTitle:@"Marked as seen!" subtitle:@"They know we are here." icon:[ThetaHelper imageFromEmojiString:@"👀" width:60] autoHide:4 openURL:nil];
			}
		}
	} @catch (NSException *exception) {
		NSLog(@"Error: %@", exception);
	}
}

// Returns YES if the view is or contains IGDirectCallButton / IGDirectJointCallButton (DM header call buttons).
static BOOL viewIsCallButtonOrContainer(id view) {
	if (!view || ![view isKindOfClass:[UIView class]]) return NO;
	Class callCls = NSClassFromString(@"IGDirectCallButton");
	Class jointCls = NSClassFromString(@"IGDirectJointCallButton");
	if (!callCls && !jointCls) return NO;
	if ([view isKindOfClass:callCls] || [view isKindOfClass:jointCls]) return YES;
	for (UIView *subview in [view subviews]) {
		if ([subview isKindOfClass:callCls] || [subview isKindOfClass:jointCls]) return YES;
	}
	return NO;
}

// Returns YES if we're on the DM thread screen (so we only hide blend/call buttons in that context).
static BOOL isDirectThreadNavigationBar(id navBarView) {
	if (!navBarView) return NO;
	UIResponder *responder = (UIResponder *)navBarView;
	while (responder) {
		if ([responder isKindOfClass:[UIViewController class]]) {
			UIViewController *vc = (UIViewController *)responder;
			if ([vc isKindOfClass:NSClassFromString(@"IGDirectThreadViewController")]) return YES;
			// Nav bar might be owned by a container whose child is the thread VC
			for (UIViewController *child in vc.childViewControllers) {
				if ([child isKindOfClass:NSClassFromString(@"IGDirectThreadViewController")]) return YES;
			}
			break;
		}
		responder = [responder nextResponder];
	}
	return NO;
}

static void (*orig_rightBarButtonItems)(id self, SEL _cmd, id arg1);
static void hook_rightBarButtonItems(id self, SEL _cmd, id arg1) {
	NSMutableArray *new_items = [arg1 mutableCopy];
	BOOL hideBlend = ENABLED(@"Hide Blend Button");
	BOOL hideCalls = ENABLED(@"Hide Call Buttons");

	if (ENABLED(@"Mark As Seen")) {
		@try {
			UIView *seenView = theta_makeSeenButtonView(self);
			if (seenView) [new_items addObject:[[UIBarButtonItem alloc] initWithCustomView:seenView]];
		} @catch (__unused NSException *e) {}
	}

	// Only filter by view identity when we're on the DM thread screen; never use index.
	if ((hideBlend || hideCalls) && isDirectThreadNavigationBar(self)) {
		Class badgeCls = NSClassFromString(@"IGBadgeButton");
		for (NSInteger i = (NSInteger)[new_items count] - 1; i >= 0; i--) {
			id item = [new_items objectAtIndex:(NSUInteger)i];
			id view = ThetaValueForKey(item, @"_view");
			if (!view) view = ThetaValueForKey(item, @"customView");
			if (!view) continue;
			if (hideBlend && badgeCls && [view isKindOfClass:badgeCls]) {
				[new_items removeObjectAtIndex:(NSUInteger)i];
				continue;
			}
			if (hideCalls && viewIsCallButtonOrContainer(view)) {
				[new_items removeObjectAtIndex:(NSUInteger)i];
			}
		}
	}

	orig_rightBarButtonItems(self, _cmd, new_items);
}

static void (*orig_seenOnSend)(id self, SEL _cmd, id arg1);
static void hook_seenOnSend(id self, SEL _cmd, id arg1) {
	orig_seenOnSend(self, _cmd, arg1);

	if (ENABLED(@"Seen On Send")) {
		@try {
			UIViewController *viewController = [ThetaHelper nearestViewController:self];
			id threadViewController = [viewController valueForKey:@"delegate"];
			if ([threadViewController isKindOfClass:NSClassFromString(@"IGDirectThreadViewController")]) {
				if (!theta_hasUnreadFromRecipient(threadViewController)) return;
				id msgListDataSource = [threadViewController valueForKey:@"_messageListDataSource"];
				id delegate = [msgListDataSource valueForKey:@"delegate"];
				id tracker = [delegate valueForKey:@"_lastSeenMessageTracker"];

				if ([threadViewController respondsToSelector:@selector(markLastMessageAsSeen)]) {
					[threadViewController performSelector:@selector(markLastMessageAsSeen)];
				} else {
					[tracker performSelector:@selector(markLastMessageAsSeen)];
				}

				theta_showMarkedAsSeenToastDeferred();
			} else if ([threadViewController isKindOfClass:NSClassFromString(@"IGDirectThreadViewComposerViewControllerDelegateController")]) {
				id threadVC = [[threadViewController valueForKey:@"_messageListDataSource"] valueForKey:@"delegate"];
				if (threadVC) threadVC = [threadVC valueForKey:@"delegate"];
				if (threadVC && theta_hasUnreadFromRecipient(threadVC)) {
					id msgListDataSource = [threadViewController valueForKey:@"_messageListDataSource"];
					id delegate = [msgListDataSource valueForKey:@"delegate"];
					id tracker = [delegate valueForKey:@"_lastSeenMessageTracker"];

					if ([delegate respondsToSelector:@selector(markLastMessageAsSeen)]) {
						[delegate performSelector:@selector(markLastMessageAsSeen)];
					} else {
						[tracker performSelector:@selector(markLastMessageAsSeen)];
					}

					theta_showMarkedAsSeenToastDeferred();
				}
			}
		} @catch (NSException *exception) {
			NSLog(@"Error: %@", exception);
		}
	}
}

static void (*orig_seenOnSend2)(id self, SEL _cmd);
static void hook_seenOnSend2(id self, SEL _cmd) {
	orig_seenOnSend2(self, _cmd);

	if (ENABLED(@"Seen On Send")) {
		@try {
			UIViewController *viewController = [ThetaHelper nearestViewController:self];
			id threadViewController = [viewController valueForKey:@"delegate"];
			if ([threadViewController isKindOfClass:NSClassFromString(@"IGDirectThreadViewController")]) {
				if (!theta_hasUnreadFromRecipient(threadViewController)) return;
				id msgListDataSource = [threadViewController valueForKey:@"_messageListDataSource"];
				id delegate = [msgListDataSource valueForKey:@"delegate"];
				id tracker = [delegate valueForKey:@"_lastSeenMessageTracker"];

				if ([threadViewController respondsToSelector:@selector(markLastMessageAsSeen)]) {
					[threadViewController performSelector:@selector(markLastMessageAsSeen)];
				} else {
					[tracker performSelector:@selector(markLastMessageAsSeen)];
				}

				theta_showMarkedAsSeenToastDeferred();
			} else if ([threadViewController isKindOfClass:NSClassFromString(@"IGDirectThreadViewComposerViewControllerDelegateController")]) {
				id threadVC = [[threadViewController valueForKey:@"_messageListDataSource"] valueForKey:@"delegate"];
				if (threadVC) threadVC = [threadVC valueForKey:@"delegate"];
				if (threadVC && theta_hasUnreadFromRecipient(threadVC)) {
					id msgListDataSource = [threadViewController valueForKey:@"_messageListDataSource"];
					id delegate = [msgListDataSource valueForKey:@"delegate"];
					id tracker = [delegate valueForKey:@"_lastSeenMessageTracker"];

					if ([delegate respondsToSelector:@selector(markLastMessageAsSeen)]) {
						[delegate performSelector:@selector(markLastMessageAsSeen)];
					} else {
						[tracker performSelector:@selector(markLastMessageAsSeen)];
					}

					theta_showMarkedAsSeenToastDeferred();
				}
			}
		} @catch (NSException *exception) {
			NSLog(@"Error: %@", exception);
		}
	}
}

static void (*orig_messageReactionSelection)(id self, SEL _cmd, id arg1, id arg2, BOOL arg3, BOOL arg4, NSInteger arg5);
static void hook_messageReactionSelection(id self, SEL _cmd, id arg1, id arg2, BOOL arg3, BOOL arg4, NSInteger arg5) {
    orig_messageReactionSelection(self, _cmd, arg1, arg2, arg3, arg4, arg5);

    @try {
        if (!ENABLED(@"Seen On React")) return;
        id threadViewController = [[self valueForKey:@"delegate"] valueForKey:@"delegate"];
        if (!threadViewController) threadViewController = theta_threadVCFromWindow();
        if (!threadViewController) return;
        if (!theta_hasUnreadFromRecipient(threadViewController)) return;
        id listViewController = [self valueForKey:@"delegate"];
        theta_performMarkLastMessageAsSeen(threadViewController, listViewController);
        theta_showMarkedAsSeenToastDeferred();
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

static void (*orig_messageReactionSelection2)(id self, SEL _cmd, id arg1, id arg2, BOOL arg3);
static void hook_messageReactionSelection2(id self, SEL _cmd, id arg1, id arg2, BOOL arg3) {
	orig_messageReactionSelection2(self, _cmd, arg1, arg2, arg3);

	if (!ENABLED(@"Seen On React")) return;
	@try {
		// Double-tap: arg1 is the cell; prefer window so we get the visible thread VC.
		id threadViewController = theta_threadVCFromWindow();
		if (!threadViewController && arg1 && [arg1 isKindOfClass:[UIView class]]) threadViewController = theta_threadVCFromView((UIView *)arg1);
		if (!threadViewController) threadViewController = [[self valueForKey:@"delegate"] valueForKey:@"delegate"];
		if (!threadViewController) return;
		if (!theta_hasUnreadFromRecipient(threadViewController)) return;
		id listViewController = [self valueForKey:@"delegate"];
		theta_performMarkLastMessageAsSeen(threadViewController, listViewController);
		theta_showMarkedAsSeenToastDeferred();
	} @catch (NSException *exception) {
		NSLog(@"Error: %@", exception);
	}
}

static void (*orig_messageReactionSelection3)(id self, SEL _cmd, id arg1, id arg2, BOOL arg3, BOOL arg4, NSInteger arg5);
static void hook_messageReactionSelection3(id self, SEL _cmd, id arg1, id arg2, BOOL arg3, BOOL arg4, NSInteger arg5) {
    orig_messageReactionSelection3(self, _cmd, arg1, arg2, arg3, arg4, arg5);

    @try {
        if (!ENABLED(@"Seen On React")) return;
        id threadViewController = [[self valueForKey:@"messageActionBlockHandler"] valueForKey:@"_threadViewFeatureDelegate"];
        if (!threadViewController) threadViewController = theta_threadVCFromWindow();
        if (!threadViewController) return;
        if (!theta_hasUnreadFromRecipient(threadViewController)) return;
        id listViewController = [[self valueForKey:@"presentationDelegate"] valueForKey:@"delegate"];
        theta_performMarkLastMessageAsSeen(threadViewController, listViewController);
        theta_showMarkedAsSeenToastDeferred();
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

static void (*orig_messageReactionSelection5)(id self, SEL _cmd, id arg1, id arg2, BOOL arg3, BOOL arg4, NSInteger arg5, id arg6);
static void hook_messageReactionSelection5(id self, SEL _cmd, id arg1, id arg2, BOOL arg3, BOOL arg4, NSInteger arg5, id arg6) {
    orig_messageReactionSelection5(self, _cmd, arg1, arg2, arg3, arg4, arg5, arg6);

    @try {
        if (!ENABLED(@"Seen On React")) return;
        id threadViewController = [[self valueForKey:@"messageActionBlockHandler"] valueForKey:@"_threadViewFeatureDelegate"];
        if (!threadViewController) threadViewController = theta_threadVCFromWindow();
        if (!threadViewController) return;
        if (!theta_hasUnreadFromRecipient(threadViewController)) return;
        id listViewController = [[self valueForKey:@"presentationDelegate"] valueForKey:@"delegate"];
        theta_performMarkLastMessageAsSeen(threadViewController, listViewController);
        theta_showMarkedAsSeenToastDeferred();
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

static void (*orig_messageReactionSelection4)(id self, SEL _cmd, id arg1, id arg2, BOOL arg3);
static void hook_messageReactionSelection4(id self, SEL _cmd, id arg1, id arg2, BOOL arg3) {
	orig_messageReactionSelection4(self, _cmd, arg1, arg2, arg3);

	if (!ENABLED(@"Seen On React")) return;
	@try {
		// Double-tap: arg1 is the cell; prefer window so we get the visible thread VC.
		id threadViewController = theta_threadVCFromWindow();
		if (!threadViewController && arg1 && [arg1 isKindOfClass:[UIView class]]) threadViewController = theta_threadVCFromView((UIView *)arg1);
		if (!threadViewController) threadViewController = [[self valueForKey:@"messageActionBlockHandler"] valueForKey:@"_threadViewFeatureDelegate"];
		if (!threadViewController) return;
		if (!theta_hasUnreadFromRecipient(threadViewController)) return;
		id listViewController = [[self valueForKey:@"presentationDelegate"] valueForKey:@"delegate"];
		theta_performMarkLastMessageAsSeen(threadViewController, listViewController);
		theta_showMarkedAsSeenToastDeferred();
	} @catch (NSException *exception) {
		NSLog(@"Error: %@", exception);
	}
}

static void (*orig_threadViewDidAppear)(id self, SEL _cmd, BOOL animated);
static void hook_threadViewDidAppear(id self, SEL _cmd, BOOL animated) {
	if (orig_threadViewDidAppear) orig_threadViewDidAppear(self, _cmd, animated);
	@try {
		// Auto-mark on open only applies when the list has entries.
		if (theta_autoMarkListIsEmpty()) return;
		if (!isThreadVCInAutoMarkList(self)) return;
		if (!theta_hasUnreadFromRecipient(self)) return;
		theta_performMarkLastMessageAsSeen(self, nil);
		theta_showMarkedAsSeenToastDeferred();
	} @catch (NSException *exception) {
		NSLog(@"[Theta] MarkAsSeen viewDidAppear: %@", exception);
	}
}

void THRegisterMarkAsSeenThreadAndReactionHooks(void) {
    NullHookMessageEx(objc_getClass("IGDirectThreadViewListAdapterDataSource"), @selector(shouldUpdateLastSeenMessage), (void *)hook_markMessagesAsSeen, &orig_markMessagesAsSeen);
    NullHookMessageEx(objc_getClass("IGDirectThreadViewController"), @selector(viewDidAppear:), (void *)hook_threadViewDidAppear, &orig_threadViewDidAppear);
    NullHookMessageEx(objc_getClass("IGTallNavigationBarView"), @selector(setRightBarButtonItems:), (void *)hook_rightBarButtonItems, &orig_rightBarButtonItems);
    if ([appVersion compare:@"411.0.0" options:NSNumericSearch] == NSOrderedAscending) {
        NullHookMessageEx(objc_getClass("IGDirectMessageReactionController"), @selector(messageReactionSelectionViewController:didToggleEmoji:isSelected:isSuperReact:actionSource:), (void *)hook_messageReactionSelection, &orig_messageReactionSelection);
        NullHookMessageEx(objc_getClass("IGDirectMessageReactionController"), @selector(performDoubleTapActionForCell:withViewModel:animated:), (void *)hook_messageReactionSelection2, &orig_messageReactionSelection2);
    } else if ([appVersion compare:@"411.0.0" options:NSNumericSearch] != NSOrderedAscending && [appVersion compare:@"413.0.0" options:NSNumericSearch] == NSOrderedAscending) {
        NullHookMessageEx(objc_getClass("IGDirectMessageReactionController.IGDirectMessageReactionController"), @selector(messageReactionSelectionViewController:didToggleEmoji:isSelected:isSuperReact:actionSource:), (void *)hook_messageReactionSelection3, &orig_messageReactionSelection3);
        NullHookMessageEx(objc_getClass("IGDirectMessageReactionController.IGDirectMessageReactionController"), @selector(performDoubleTapActionForCell:withViewModel:animated:), (void *)hook_messageReactionSelection4, &orig_messageReactionSelection4);
    } else {
        NullHookMessageEx(objc_getClass("IGDirectMessageReactionController.IGDirectMessageReactionController"), @selector(messageReactionSelectionViewController:didToggleEmoji:isSelected:isSuperReact:actionSource:bottomSheetSessionId:), (void *)hook_messageReactionSelection5, &orig_messageReactionSelection5);
        NullHookMessageEx(objc_getClass("IGDirectMessageReactionController.IGDirectMessageReactionController"), @selector(performDoubleTapActionForCell:withViewModel:animated:), (void *)hook_messageReactionSelection4, &orig_messageReactionSelection4);
    }
}

void THRegisterMarkAsSeenSeenOnSendHook(void) {
    //NullHookMessageEx(objc_getClass("IGDirectComposer"), @selector(_didTapSend:), (void *)hook_seenOnSend, &orig_seenOnSend);
	Class klass = objc_getClass("IGDirectComposer");
	if ([klass respondsToSelector:@selector(_didTapSend:)]) {
		NullHookMessageEx(klass, @selector(_didTapSend:), (void *)hook_seenOnSend, &orig_seenOnSend);
	} else if ([klass respondsToSelector:@selector(_didTapSend)]) {
		NullHookMessageEx(klass, @selector(_didTapSend), (void *)hook_seenOnSend2, &orig_seenOnSend2);
	}
}