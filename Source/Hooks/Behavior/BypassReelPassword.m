static char kThetaBypassTimerKey;
static char kThetaBypassConstraintsKey;
static char kThetaBypassObserversKey;
static char kThetaBypassShareStateKey;
static char kThetaBypassOriginalFrameKey;
static char kThetaHotColdPrevCorrectKey;
static char kThetaHotColdStaleCountKey;
static char kThetaHotColdPrevTypedLenKey;
static char kThetaBypassDisplayLinkKey;
static char kThetaBypassDisplayLinkTargetKey;
static char kThetaBypassButtonTargetKey;

static void ThetaTeardownBypassButton(UIButton *button);
static void ThetaGlobalDestroyBypassArtifacts(void);
static void ThetaAdjustBypassElevation(UIButton *button, UIView *container, UIView *root, id owner);
static BOOL ThetaViewIsOnscreen(UIView *view, UIView *root);

static BOOL ThetaIsShareClass(UIViewController *vc) {
    static Class DirectShareClass = Nil;
    static Class PartialModalNavClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DirectShareClass = NSClassFromString(@"IGDirectShareSheetContainerViewController");
        PartialModalNavClass = NSClassFromString(@"IGDSPartialModalSheetNavigationController");
    });
    return (DirectShareClass && [vc isKindOfClass:DirectShareClass]) || (PartialModalNavClass && [vc isKindOfClass:PartialModalNavClass]);
}

static NSArray<UIWindow *> *ThetaPrimaryWindows(void) {
    if (![UIApplication respondsToSelector:@selector(sharedApplication)]) { return @[]; }
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.windows.count > 0) { return ws.windows; }
            }
        }
    }
    return UIApplication.sharedApplication.windows ?: @[];
}

static BOOL ThetaIsShareSheetPresented(void) {
    NSArray<UIWindow *> *windows = ThetaPrimaryWindows();
    for (UIWindow *w in windows) {
        if (w.hidden) { continue; }
        UIViewController *vc = w.rootViewController;
        if (!vc) { continue; }
        UIViewController *top = vc;
        while (top.presentedViewController) { top = top.presentedViewController; }
        UIViewController *cursor = top;
        while (cursor) {
            if (ThetaIsShareClass(cursor)) { return YES; }
            cursor = cursor.presentingViewController;
        }
    }
    return NO;
}

static CGFloat ThetaMatchScore(NSString *typedRaw, NSString *answerRaw) {
    if (typedRaw.length == 0 || answerRaw.length == 0) { return 0.0; }
    NSString *typed = [typedRaw lowercaseString];
    NSString *answer = [answerRaw lowercaseString];
    NSUInteger minLen = MIN(typed.length, answer.length);
    NSUInteger correct = 0;
    for (NSUInteger i = 0; i < minLen; i++) {
        unichar ct = [typed characterAtIndex:i];
        unichar ca = [answer characterAtIndex:i];
        if (ct == ca) { correct++; } else { break; }
    }
    CGFloat ratio = (CGFloat)correct / (CGFloat)answer.length;
    if (ratio < 0) ratio = 0; if (ratio > 1) ratio = 1;
    return ratio;
}

static NSString *ThetaTemperatureLabel(CGFloat score) {
    if (score >= 0.95) return @"Scorching! 🔥🔥";
    if (score >= 0.75) return @"Hot 🔥";
    if (score >= 0.55) return @"Warm 🙂";
    if (score >= 0.35) return @"Cool 🆒";
    if (score >= 0.15) return @"Cold 🧊";
    return @"Ice Cold ❄️";
}

@interface ThetaBypassDisplayLinkTarget : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIView *root;
@property (nonatomic, weak) id owner;
- (void)tick:(CADisplayLink *)link;
@end
static BOOL ThetaViewIsOnscreen(UIView *view, UIView *root) {
	if (!view || !view.window) { return NO; }
	if (!root) { root = view.window; }
	// Check visibility in hierarchy
	for (UIView *v = view; v != nil; v = v.superview) {
		if (v.hidden || v.alpha < 0.01) { return NO; }
	}
	// Check intersection with root bounds
	CGRect rectInRoot = [view convertRect:view.bounds toView:root];
	CGRect intersection = CGRectIntersection(rectInRoot, root.bounds);
	if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) { return NO; }
	// Require a minimal visible area to avoid false positives
	CGFloat minArea = 20.0 * 20.0;
	CGFloat area = intersection.size.width * intersection.size.height;
	return area >= minArea;
}

@implementation ThetaBypassDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    UIButton *button = self.button;
    if (!button) { [link invalidate]; return; }
    UIView *root = self.root ?: button.window;
    id owner = self.owner;
    if (!owner || !root) {
        ThetaTeardownBypassButton(button);
        [link invalidate];
        return;
    }
    if (button.superview != root) { return; }
    UITextField *textField = nil; @try { textField = [owner valueForKey:@"_passwordTextField"]; } @catch (__unused NSException *e) {}
	if (!textField || !textField.window || !ThetaViewIsOnscreen(textField, root)) {
        ThetaTeardownBypassButton(button);
        [link invalidate];
        return;
    }
    CGRect tfFrameInRoot = [textField convertRect:textField.bounds toView:root];
    CGFloat btnWidth = 100.0;
    CGFloat btnHeight = 40.0;
    CGFloat targetX = CGRectGetMidX(tfFrameInRoot) - (btnWidth * 0.5);
    CGFloat targetY = CGRectGetMaxY(tfFrameInRoot) + 20.0;

    button.frame = CGRectMake(targetX, targetY, btnWidth, btnHeight);
}
@end

@interface ThetaBypassButtonTarget : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIView *root;
@property (nonatomic, weak) id owner;
- (void)handleTap:(id)sender;
@end

@implementation ThetaBypassButtonTarget
- (void)handleTap:(id)sender {
	id owner = self.owner;
	if (!owner) {
		UIResponder *responder = [sender isKindOfClass:[UIResponder class]] ? (UIResponder *)sender : self.button;
		while (responder && ![responder isKindOfClass:[UIViewController class]]) {
			responder = responder.nextResponder;
		}
		owner = (UIViewController *)responder;
	}
	if (!owner) { return; }

	UITextField *tf = nil;
	NSString *ans = nil;
	@try {
		tf = [owner valueForKey:@"_passwordTextField"];
		ans = [owner valueForKey:@"_answer"];
	} @catch (__unused NSException *e) {
		tf = nil;
		ans = nil;
	}
	if ([tf isKindOfClass:[UITextField class]]) {
		[tf setText:ans ?: @""];
	}
	if ([owner respondsToSelector:@selector(_didTapSubmitButton)]) {
		[owner performSelector:@selector(_didTapSubmitButton)];
	}

	UIButton *btn = self.button;
	if (!btn) {
		UIView *searchRoot = self.container ?: self.root ?: (self.button ? self.button.window : nil);
		if (!searchRoot && [UIApplication respondsToSelector:@selector(sharedApplication)]) {
			searchRoot = UIApplication.sharedApplication.keyWindow;
		}
		btn = (UIButton *)[searchRoot viewWithTag:869321];
	}
	if (!btn) {
		ThetaGlobalDestroyBypassArtifacts();
		return;
	}
	btn.userInteractionEnabled = NO;
	[UIView animateWithDuration:0.2
		animations:^{
			btn.alpha = 0.0;
		} completion:^(BOOL finished) {
			ThetaTeardownBypassButton(btn);
			ThetaGlobalDestroyBypassArtifacts();
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
				[ThetaHelper showLoadToast:@"Bypassed Password" subtitle:[NSString stringWithFormat:@"Password was \"%@\".", ans ?: @""] icon:[ThetaHelper imageFromEmojiString:@"🤦‍♂️" width:300] autoHide:4 openURL:nil];
			});
		}];
}
@end

static void ThetaTeardownBypassButton(UIButton *button) {
    if (!button) { return; }
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    NSTimer *timer = objc_getAssociatedObject(button, &kThetaBypassTimerKey);
    if (timer) { [timer invalidate]; objc_setAssociatedObject(button, &kThetaBypassTimerKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    NSArray *observers = objc_getAssociatedObject(button, &kThetaBypassObserversKey);
    if ([observers isKindOfClass:[NSArray class]]) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (id obs in observers) {
            if (obs && obs != [NSNull null]) { [nc removeObserver:obs]; }
        }
        objc_setAssociatedObject(button, &kThetaBypassObserversKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    NSArray *saved = objc_getAssociatedObject(button, &kThetaBypassConstraintsKey);
    if (saved) { [NSLayoutConstraint deactivateConstraints:saved]; objc_setAssociatedObject(button, &kThetaBypassConstraintsKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    CADisplayLink *link = objc_getAssociatedObject(button, &kThetaBypassDisplayLinkKey);
    if (link) { [link invalidate]; objc_setAssociatedObject(button, &kThetaBypassDisplayLinkKey, nil, OBJC_ASSOCIATION_ASSIGN); }
    objc_setAssociatedObject(button, &kThetaBypassDisplayLinkTargetKey, nil, OBJC_ASSOCIATION_ASSIGN);
    id owner = nil;
    UIResponder *responder = button.nextResponder;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) { responder = responder.nextResponder; }
    owner = responder;
    UILabel *tTitle = nil;
    @try { if (owner) { tTitle = [owner valueForKey:@"_titleLabel"]; } } @catch (__unused NSException *e) {}
    if ([tTitle isKindOfClass:[UILabel class]]) {
        UIView *hc = [tTitle.superview viewWithTag:869322];
        [hc removeFromSuperview];
    }
    @try {
        UITextField *tf = owner ? [owner valueForKey:@"_passwordTextField"] : nil;
        if ([tf isKindOfClass:[UITextField class]]) {
            [tf removeTarget:nil action:NULL forControlEvents:UIControlEventEditingChanged];
            objc_setAssociatedObject(tf, &kThetaHotColdPrevCorrectKey, nil, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(tf, &kThetaHotColdPrevTypedLenKey, nil, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(tf, &kThetaHotColdStaleCountKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    } @catch (__unused NSException *e) {}
    [button removeFromSuperview];
    NSArray<UIWindow *> *windows = ThetaPrimaryWindows();
    for (UIWindow *w in windows) {
        UIView *v = [w viewWithTag:869321];
        if (v) { [v removeFromSuperview]; }
        UIView *assist = [w viewWithTag:869322];
        if (assist) { [assist removeFromSuperview]; }
    }
    objc_setAssociatedObject(button, &kThetaBypassOriginalFrameKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(button, &kThetaBypassShareStateKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void ThetaGlobalDestroyBypassArtifacts(void) {
    NSArray<UIWindow *> *windows = ThetaPrimaryWindows();
    for (UIWindow *w in windows) {
        UIView *maybeButton = [w viewWithTag:869321];
        if ([maybeButton isKindOfClass:[UIButton class]]) {
            ThetaTeardownBypassButton((UIButton *)maybeButton);
        } else if (maybeButton) {
            [maybeButton removeFromSuperview];
        }
        UIView *assist = [w viewWithTag:869322];
        if (assist) { [assist removeFromSuperview]; }
    }
}

static void ThetaUpdateBypassButtonPlacement(UIButton *button, UIView *container, UIView *root, id owner) {
    if (!button) { return; }
    if (!owner || !container) { ThetaTeardownBypassButton(button); return; }
    if (button.superview != container) {
        NSArray *saved = objc_getAssociatedObject(button, &kThetaBypassConstraintsKey);
        if (saved) { [NSLayoutConstraint deactivateConstraints:saved]; objc_setAssociatedObject(button, &kThetaBypassConstraintsKey, nil, OBJC_ASSOCIATION_ASSIGN); }
        [button removeFromSuperview];
        [container addSubview:button];
        [button setTranslatesAutoresizingMaskIntoConstraints:NO];
    }
    UITextField *textField = nil;
    @try { textField = [owner valueForKey:@"_passwordTextField"]; } @catch (__unused NSException *e) { textField = nil; }
    if (!textField) { ThetaTeardownBypassButton(button); return; }
    NSArray *existing = objc_getAssociatedObject(button, &kThetaBypassConstraintsKey);
    if (!existing || existing.count == 0) {
        NSArray *constraints = @[
            [button.topAnchor constraintEqualToAnchor:textField.bottomAnchor constant:20],
            [button.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
            [button.widthAnchor constraintEqualToConstant:100],
            [button.heightAnchor constraintEqualToConstant:40]
        ];
        [NSLayoutConstraint activateConstraints:constraints];
        objc_setAssociatedObject(button, &kThetaBypassConstraintsKey, constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    button.layer.zPosition = 10000;
    [container bringSubviewToFront:button];
}

static void ThetaAdjustBypassElevation(UIButton *button, UIView *container, UIView *root, id owner) {
	if (!button || !container || !owner) { return; }
	if (!root) {
		root = container.window ?: container;
		while (root.superview) { root = root.superview; }
	}
	UITextField *visibleTF = nil;
	@try { visibleTF = [owner valueForKey:@"_passwordTextField"]; } @catch (__unused NSException *e) { visibleTF = nil; }
	if (![visibleTF isKindOfClass:[UITextField class]] || visibleTF.window == nil || !ThetaViewIsOnscreen(visibleTF, root)) {
		// No on-screen field: keep button within container (not elevated), disable interaction
		CADisplayLink *link = objc_getAssociatedObject(button, &kThetaBypassDisplayLinkKey);
		if (link) { [link invalidate]; objc_setAssociatedObject(button, &kThetaBypassDisplayLinkKey, nil, OBJC_ASSOCIATION_ASSIGN); }
		objc_setAssociatedObject(button, &kThetaBypassDisplayLinkTargetKey, nil, OBJC_ASSOCIATION_ASSIGN);
		if (button.superview != container) {
			[button removeFromSuperview];
			[container addSubview:button];
			[button setTranslatesAutoresizingMaskIntoConstraints:NO];
		}
		if ([visibleTF isKindOfClass:[UITextField class]]) {
			ThetaUpdateBypassButtonPlacement(button, container, root, owner);
		}
		button.userInteractionEnabled = NO;
		button.layer.zPosition = 0;
		button.hidden = YES;
		return;
	}
	BOOL sharePresented = ThetaIsShareSheetPresented();

	if (!sharePresented) {
		// Elevate to window/root with display link placement for reliable taps
		// Remove any container constraints
		NSArray *saved = objc_getAssociatedObject(button, &kThetaBypassConstraintsKey);
		if (saved) { [NSLayoutConstraint deactivateConstraints:saved]; objc_setAssociatedObject(button, &kThetaBypassConstraintsKey, nil, OBJC_ASSOCIATION_ASSIGN); }
		if (button.superview != root) {
			[button removeFromSuperview];
			[root addSubview:button];
			[button setTranslatesAutoresizingMaskIntoConstraints:YES];
		}
		// Start (or keep) the display link to track the text field position
		ThetaBypassDisplayLinkTarget *target = objc_getAssociatedObject(button, &kThetaBypassDisplayLinkTargetKey);
		CADisplayLink *link = objc_getAssociatedObject(button, &kThetaBypassDisplayLinkKey);
		if (!target || !link) {
			target = [ThetaBypassDisplayLinkTarget new];
			target.button = button;
			target.container = container;
			target.root = root;
			target.owner = owner;
			link = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
			[link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
			objc_setAssociatedObject(button, &kThetaBypassDisplayLinkTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			objc_setAssociatedObject(button, &kThetaBypassDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		}
		button.userInteractionEnabled = YES;
		button.layer.zPosition = 100000;
		[root bringSubviewToFront:button];
		button.hidden = NO;
	} else {
		// Push back into container with constraints and disable interaction to avoid intercepting
		CADisplayLink *link = objc_getAssociatedObject(button, &kThetaBypassDisplayLinkKey);
		if (link) { [link invalidate]; objc_setAssociatedObject(button, &kThetaBypassDisplayLinkKey, nil, OBJC_ASSOCIATION_ASSIGN); }
		objc_setAssociatedObject(button, &kThetaBypassDisplayLinkTargetKey, nil, OBJC_ASSOCIATION_ASSIGN);
		if (button.superview != container) {
			[button removeFromSuperview];
			[container addSubview:button];
			[button setTranslatesAutoresizingMaskIntoConstraints:NO];
		}
		ThetaUpdateBypassButtonPlacement(button, container, root, owner);
		button.userInteractionEnabled = NO;
		button.layer.zPosition = 0;
		[container sendSubviewToBack:button];
		button.hidden = YES;
	}
}
static void (*orig_bypassReelPassword)(id self, SEL _cmd);
static void hook_bypassReelPassword(id self, SEL _cmd) {
    orig_bypassReelPassword(self, _cmd);

    if (ENABLED(@"Bypass Reel Password")) {
        @try {
            UIView *container = [self valueForKey:@"_containerView"];
            if (container) {
                ThetaGlobalDestroyBypassArtifacts();
                UITextField *textField = [self valueForKey:@"_passwordTextField"];
                NSString *answer = [self valueForKey:@"_answer"];

                UIButton *bypassButton = [UIButton buttonWithType:UIButtonTypeSystem];
                [bypassButton setTitle:@"Bypass" forState:UIControlStateNormal];
                [bypassButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
                [bypassButton setBackgroundColor:UIColor.clearColor];
                bypassButton.layer.cornerRadius = 20.0;
                bypassButton.layer.masksToBounds = YES;

                UILabel *titleLabel = [self valueForKey:@"_titleLabel"];
                if (titleLabel && titleLabel.superview) {
                    UIView *hotColdContainer = [titleLabel.superview viewWithTag:869322];
                    if (!hotColdContainer) {
                        hotColdContainer = [[UIView alloc] initWithFrame:CGRectZero];
                        hotColdContainer.tag = 869322;
                        hotColdContainer.translatesAutoresizingMaskIntoConstraints = NO;

                        UILabel *tempLabel = [[UILabel alloc] initWithFrame:CGRectZero];
                        tempLabel.tag = 869323;
                        tempLabel.text = @"Ice Cold ❄️";
                        tempLabel.textAlignment = NSTextAlignmentCenter;
                        tempLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
                        tempLabel.textColor = UIColor.secondaryLabelColor ?: [UIColor colorWithWhite:1 alpha:0.8];
                        tempLabel.translatesAutoresizingMaskIntoConstraints = NO;

                        UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                        progress.tag = 869324;
                        progress.progressTintColor = [UIColor systemPinkColor] ?: [UIColor colorWithRed:1.0 green:0.2 blue:0.6 alpha:1.0];
                        progress.trackTintColor = [UIColor colorWithWhite:1 alpha:0.15];
                        progress.layer.cornerRadius = 2.0;
                        progress.clipsToBounds = YES;
                        progress.translatesAutoresizingMaskIntoConstraints = NO;

                        [hotColdContainer addSubview:tempLabel];
                        [hotColdContainer addSubview:progress];
                        [titleLabel.superview addSubview:hotColdContainer];

                        [NSLayoutConstraint activateConstraints:@[
                            [hotColdContainer.bottomAnchor constraintEqualToAnchor:titleLabel.topAnchor constant:-8], [hotColdContainer.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
                            [hotColdContainer.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],

                            [tempLabel.topAnchor constraintEqualToAnchor:hotColdContainer.topAnchor], [tempLabel.leadingAnchor constraintEqualToAnchor:hotColdContainer.leadingAnchor], [tempLabel.trailingAnchor constraintEqualToAnchor:hotColdContainer.trailingAnchor],

                            [progress.topAnchor constraintEqualToAnchor:tempLabel.bottomAnchor constant:4], [progress.leadingAnchor constraintEqualToAnchor:hotColdContainer.leadingAnchor], [progress.trailingAnchor constraintEqualToAnchor:hotColdContainer.trailingAnchor],
                            [progress.heightAnchor constraintEqualToConstant:4], [progress.bottomAnchor constraintEqualToAnchor:hotColdContainer.bottomAnchor]
                        ]];
                    }
                }

                BOOL sharePresented = ThetaIsShareSheetPresented();
                UIView *root = container.window;
                if (!root) {
                    root = container;
                    while (root.superview) {
                        root = root.superview;
                    }
                }
                if ([root viewWithTag:869321] || [container viewWithTag:869321]) {
                    return;
                }
                bypassButton.tag = 869321;
                ThetaSetCaptureHiding(bypassButton);
                UIView *initialParent = container;
                [initialParent addSubview:bypassButton];

                UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
                UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
                blurView.userInteractionEnabled = NO;
                blurView.layer.cornerRadius = 20.0;
                blurView.layer.masksToBounds = YES;
                blurView.layer.borderWidth = 1.0;
                blurView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
                blurView.frame = bypassButton.bounds;
                blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [bypassButton insertSubview:blurView atIndex:0];

                [bypassButton setTranslatesAutoresizingMaskIntoConstraints:NO];
                NSArray *constraints = @[
                    [bypassButton.topAnchor constraintEqualToAnchor:textField.bottomAnchor constant:20], [bypassButton.centerXAnchor constraintEqualToAnchor:container.centerXAnchor], [bypassButton.widthAnchor constraintEqualToConstant:100],
                    [bypassButton.heightAnchor constraintEqualToConstant:40]
                ];
                [NSLayoutConstraint activateConstraints:constraints];
                objc_setAssociatedObject(bypassButton, &kThetaBypassConstraintsKey, constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                container.userInteractionEnabled = YES;
                bypassButton.userInteractionEnabled = YES;
                bypassButton.exclusiveTouch = YES;
                bypassButton.layer.zPosition = 10000;
                [initialParent bringSubviewToFront:bypassButton];
				ThetaAdjustBypassElevation(bypassButton, container, root, self);

                __weak typeof(self) weakSelf = self;
                __weak UIView *weakContainer = container;
                __weak UIView *weakRoot = root;
                __weak UIButton *weakButton = bypassButton;
                __weak UIProgressView *weakProgress = (UIProgressView *)[[titleLabel.superview viewWithTag:869322] viewWithTag:869324];
                __weak UILabel *weakTempLabel = (UILabel *)[[titleLabel.superview viewWithTag:869322] viewWithTag:869323];

                [((UITextField *)textField) addAction:[UIAction actionWithHandler:^(UIAction *action) {
                    UITextField *tfEdit = (UITextField *)textField;
                    NSString *typed = tfEdit.text ?: @"";
                    NSString *ansFull = [weakSelf valueForKey:@"_answer"] ?: @"";

                    NSUInteger minLen = MIN(typed.length, ansFull.length);
                    NSUInteger correct = 0;
                    for (NSUInteger i = 0; i < minLen; i++) {
                        if ([[typed lowercaseString] characterAtIndex:i] == [[ansFull lowercaseString] characterAtIndex:i]) {
                            correct++;
                        } else {
                            break;
                        }
                    }

                    NSNumber *prevCorrectNum = objc_getAssociatedObject(tfEdit, &kThetaHotColdPrevCorrectKey);
                    NSNumber *prevTypedLenNum = objc_getAssociatedObject(tfEdit, &kThetaHotColdPrevTypedLenKey);
                    NSNumber *staleCountNum = objc_getAssociatedObject(tfEdit, &kThetaHotColdStaleCountKey);
                    NSUInteger prevCorrect = prevCorrectNum ? [prevCorrectNum unsignedIntegerValue] : 0;
                    NSUInteger prevTypedLen = prevTypedLenNum ? [prevTypedLenNum unsignedIntegerValue] : 0;
                    NSUInteger staleCount = staleCountNum ? [staleCountNum unsignedIntegerValue] : 0;

                    BOOL typedMore = typed.length > prevTypedLen;
                    if (correct > prevCorrect) {
                        staleCount = 0;  // improvement resets stagnation
                    } else if (typedMore && correct == prevCorrect) {
                        staleCount += 1;
                    } else if (typed.length < prevTypedLen) {
                        staleCount = (staleCount > 0) ? staleCount - 1 : 0;
                    } else {
                    }

                    objc_setAssociatedObject(tfEdit, &kThetaHotColdPrevCorrectKey, @(correct), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(tfEdit, &kThetaHotColdPrevTypedLenKey, @(typed.length), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(tfEdit, &kThetaHotColdStaleCountKey, @(staleCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                    CGFloat baseScore = ThetaMatchScore(typed, ansFull);
                    CGFloat adjusted = baseScore;
                    if (staleCount > 2) {
                        CGFloat decay = 0.05f * (CGFloat)(staleCount - 2);
                        adjusted = MAX(0.0f, baseScore - decay);
                    }

                    if (weakProgress) {
                        [weakProgress setProgress:adjusted animated:YES];
                    }
                    if (weakTempLabel) {
                        weakTempLabel.text = ThetaTemperatureLabel(adjusted);
                    }
                }] forControlEvents:UIControlEventEditingChanged];

				ThetaBypassButtonTarget *tapTarget = [ThetaBypassButtonTarget new];
				tapTarget.button = bypassButton;
				tapTarget.container = weakContainer;
				tapTarget.root = weakRoot;
				tapTarget.owner = weakSelf;
				[bypassButton addTarget:tapTarget action:@selector(handleTap:) forControlEvents:UIControlEventTouchUpInside];
				if (@available(iOS 14.0, *)) {
					[bypassButton addAction:[UIAction actionWithHandler:^(__unused UIAction *a) {
						[tapTarget handleTap:bypassButton];
					}] forControlEvents:UIControlEventPrimaryActionTriggered];
				}
				objc_setAssociatedObject(bypassButton, &kThetaBypassButtonTargetKey, tapTarget, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                [initialParent bringSubviewToFront:bypassButton];

                id willPresentObs = [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                                                    object:nil
                                                                                    queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *_Nonnull note) {
                                                                                    if (!weakSelf) { ThetaTeardownBypassButton(weakButton); return; }
                                                                                    ThetaUpdateBypassButtonPlacement(weakButton, weakContainer, weakRoot, weakSelf);
																					ThetaAdjustBypassElevation(weakButton, weakContainer, weakRoot, weakSelf);
                                                                                }];
                id didPresentObs = [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidResignKeyNotification
                                                                                    object:nil
                                                                                    queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *_Nonnull note) {
                                                                                if (!weakSelf) { ThetaTeardownBypassButton(weakButton); return; }
                                                                                ThetaUpdateBypassButtonPlacement(weakButton, weakContainer, weakRoot, weakSelf);
																				ThetaAdjustBypassElevation(weakButton, weakContainer, weakRoot, weakSelf);
                                                                                }];
                id appActiveObs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                    object:nil
                                                                                    queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *_Nonnull note) {
                                                                                if (!weakSelf) { ThetaTeardownBypassButton(weakButton); return; }
                                                                                ThetaUpdateBypassButtonPlacement(weakButton, weakContainer, weakRoot, weakSelf);
																				ThetaAdjustBypassElevation(weakButton, weakContainer, weakRoot, weakSelf);
                                                                                }];
                id appForegroundObs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                                                        object:nil
                                                                                        queue:NSOperationQueue.mainQueue
                                                                                    usingBlock:^(NSNotification *_Nonnull note) {
                                                                                    if (!weakSelf) { ThetaTeardownBypassButton(weakButton); return; }
                                                                                    ThetaUpdateBypassButtonPlacement(weakButton, weakContainer, weakRoot, weakSelf);
																					ThetaAdjustBypassElevation(weakButton, weakContainer, weakRoot, weakSelf);
                                                                                    }];
                NSTimer *guardTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer * _Nonnull t) {
                    if (!weakSelf || !weakButton || !weakContainer) { [t invalidate]; return; }
                    UITextField *guardTF = nil; @try { guardTF = [weakSelf valueForKey:@"_passwordTextField"]; } @catch (__unused NSException *e) { guardTF = nil; }
					UIView *ownerView = nil; @try { ownerView = [weakSelf valueForKey:@"view"]; } @catch (__unused NSException *e) { ownerView = nil; }
					if (!guardTF || ![guardTF isKindOfClass:[UITextField class]] || guardTF.window == nil || ![ownerView isKindOfClass:[UIView class]] || ownerView.window == nil) {
						// Keep the button, just adjust elevation back to container mode
						ThetaAdjustBypassElevation(weakButton, weakContainer, weakRoot, weakSelf);
						return;
					}
					ThetaAdjustBypassElevation(weakButton, weakContainer, weakRoot, weakSelf);
                }];
                [[NSRunLoop mainRunLoop] addTimer:guardTimer forMode:NSRunLoopCommonModes];
                objc_setAssociatedObject(weakButton, &kThetaBypassTimerKey, guardTimer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                NSArray *observers = @[ willPresentObs ?: [NSNull null], didPresentObs ?: [NSNull null], appActiveObs ?: [NSNull null], appForegroundObs ?: [NSNull null] ];
                objc_setAssociatedObject(bypassButton, &kThetaBypassObserversKey, observers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } @catch (NSException *e) {
            NSLog(@"Error in bypassReelPassword: %@", e);
        }
    }
}

void THRegisterBypassReelPasswordHooks(void) {
    NullHookMessageEx(objc_getClass("IGMediaOverlayProfileWithPasswordView"), @selector(layoutSubviews), (void *)hook_bypassReelPassword, &orig_bypassReelPassword);
}