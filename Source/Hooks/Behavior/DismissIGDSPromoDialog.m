@interface ThetaPromoOnceTarget : NSObject
+ (void)promoGotIt:(id)sender;
@end

@implementation ThetaPromoOnceTarget
+ (void)promoGotIt:(id)sender {
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"Theta_DSPromoDialogSeen"];
}
@end

static BOOL thetaPromoSeen() {
	return [[NSUserDefaults standardUserDefaults] boolForKey:@"Theta_DSPromoDialogSeen"];
}

static void thetaRemovePromoOverlay(UIView *view) {
	if (!view) return;
	// Walk up to find the topmost non-window container that likely owns the overlay
	UIView *container = view;
	while (container.superview && container.superview != container.window) {
		container = container.superview;
	}
	if (container && container != view) {
		container.hidden = YES;
		[container removeFromSuperview];
		// Also try dismissing any presenting controller in the responder chain
		UIResponder *responder = container;
		while (responder) {
			if ([responder isKindOfClass:[UIViewController class]]) {
				UIViewController *vc = (UIViewController *)responder;
				[vc dismissViewControllerAnimated:NO completion:nil];
				break;
			}
			responder = [responder nextResponder];
		}
		return;
	}
	// Fallback: hide and disable interactions on ancestor chain
	UIView *sv = view.superview;
	while (sv && sv != sv.window) {
		sv.userInteractionEnabled = NO;
		sv.hidden = YES;
		sv = sv.superview;
	}
}

static void thetaRemoveGlobalDimmingOverlays(UIWindow *window) {
	if (!window) return;
	for (UIView *sub in [window.subviews copy]) {
		BOOL isEffect = [sub isKindOfClass:NSClassFromString(@"UIVisualEffectView")];
		CGFloat bgAlpha = 0.0;
		if (sub.backgroundColor) {
			[sub.backgroundColor getRed:nil green:nil blue:nil alpha:&bgAlpha];
		}
		BOOL big = (CGRectGetWidth(sub.bounds) >= CGRectGetWidth(window.bounds) * 0.8) &&
				   (CGRectGetHeight(sub.bounds) >= CGRectGetHeight(window.bounds) * 0.8);
		BOOL dimmy = (bgAlpha > 0.01) || (sub.alpha > 0.01);
		if ((isEffect || dimmy) && big) {
			sub.hidden = YES;
			[sub removeFromSuperview];
		}
	}
}

static void thetaMarkSeenDeferred() {
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"Theta_DSPromoDialogSeen"];
}

static void thetaCheckViewDismissed(__weak UIView *weakView, int remainingChecks) {
	if (remainingChecks <= 0) return;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		UIView *v = weakView;
		if (!v || v.window == nil) {
			thetaMarkSeenDeferred();
			return;
		}
		thetaCheckViewDismissed(weakView, remainingChecks - 1);
	});
}

static void thetaScheduleSeenMonitor(UIView *view) {
	if (!view) return;
	thetaCheckViewDismissed(view, 20);
}

static BOOL thetaTriggerAnyTapGestureFromView(UIView *view) {
	if (!view) return NO;
	NSArray<UIGestureRecognizer *> *grs = view.gestureRecognizers;
	for (UIGestureRecognizer *gr in grs) {
		if (![gr isKindOfClass:[UITapGestureRecognizer class]]) continue;
		if (!gr.enabled) continue;
		id targetsArray = [gr valueForKey:@"_targets"];
		if (![targetsArray isKindOfClass:[NSArray class]] || [targetsArray count] == 0) continue;
		id first = [targetsArray firstObject];
		id target = [first valueForKey:@"_target"];
		id actionObj = [first valueForKey:@"_action"];
		SEL action = NULL;
		if ([actionObj isKindOfClass:[NSString class]]) {
            action = NSSelectorFromString((NSString *)actionObj);
        } else if (actionObj) {
            action = NSSelectorFromString([actionObj description]);
        }
		if (target && action && [target respondsToSelector:action]) {
			IMP imp = [target methodForSelector:action];
			((void (*)(id, SEL, id))imp)(target, action, gr);
			return YES;
		}
	}
	for (UIView *sub in view.subviews) {
		if (thetaTriggerAnyTapGestureFromView(sub)) return YES;
	}
	return NO;
}

static void thetaFireOneSyntheticTap(UIWindow *window) {
	if (!window) return;
	(void)thetaTriggerAnyTapGestureFromView(window);
}

static UIViewController *thetaFindOwningViewController(UIView *view) {
	if (!view) return nil;
	UIResponder *responder = view;
	while (responder) {
		if ([responder isKindOfClass:[UIViewController class]]) {
			return (UIViewController *)responder;
		}
		responder = [responder nextResponder];
	}
	return nil;
}

static BOOL thetaLooksLikePromoController(NSString *className) {
	if (className.length == 0) return NO;
	return [className containsString:@"IGDSPromo"] ||
		   [className containsString:@"PromoDialog"] ||
		   [className containsString:@"Promo"];
}

static void (*orig_hideIGDSPromoDialog)(id self, SEL _cmd);
static void hook_hideIGDSPromoDialog(id self, SEL _cmd) {
	orig_hideIGDSPromoDialog(self, _cmd);

	@try {
		UIView *view = (UIView *)self;
		if (!view) return;

		// Only handle the specific IGDS promo with the matching title ivar
		NSString *dialogTitle = nil;
		@try {
			id titleObj = [self valueForKey:@"title"];
			if ([titleObj isKindOfClass:[NSString class]]) {
				dialogTitle = (NSString *)titleObj;
			} else if ([titleObj isKindOfClass:[UILabel class]]) {
				dialogTitle = ((UILabel *)titleObj).text;
			}
		} @catch (__unused NSException *e) {
			// ignore KVC failures
		}
		if (dialogTitle) {
			dialogTitle = [dialogTitle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		}
		NSString *expectedTitle = @"Swipe to easily access Reels and messages";
		if (dialogTitle.length == 0 || ![dialogTitle isEqualToString:expectedTitle]) {
			// Not the targeted promo; do not hide or auto-press
			return;
		}

		// Helpers to press the "Got it" button if present
		static BOOL (^thetaStringLooksLikeGotIt)(NSString *) = ^BOOL(NSString *s) {
			if (![s isKindOfClass:[NSString class]]) return NO;
			NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (t.length == 0) return NO;
			return [t rangeOfString:@"got it" options:NSCaseInsensitiveSearch].location != NSNotFound;
		};
		static UIControl* (^thetaFindNearestControl)(UIView *) = ^UIControl* (UIView *v) {
			UIView *p = v;
			while (p && ![p isKindOfClass:[UIControl class]] && p != p.window) {
				p = p.superview;
			}
			return [p isKindOfClass:[UIControl class]] ? (UIControl *)p : nil;
		};
		static UIControl* (^thetaFindGotItControlInView)(UIView *) = ^UIControl* (UIView *root) {
			if (!root) return nil;
			// Direct UIButton title match
			if ([root isKindOfClass:[UIButton class]]) {
				UIButton *btn = (UIButton *)root;
				NSString *title = [btn titleForState:UIControlStateNormal] ?: btn.currentTitle ?: btn.titleLabel.text;
				if (thetaStringLooksLikeGotIt(title)) return btn;
			}
			// Label inside custom view
			if ([root isKindOfClass:[UILabel class]]) {
				UILabel *lbl = (UILabel *)root;
				if (thetaStringLooksLikeGotIt(lbl.text)) {
					UIControl *ctl = thetaFindNearestControl(lbl);
					if (ctl) return ctl;
				}
			}
			// Accessibility label/title
			NSString *ax = root.accessibilityLabel;
			if (thetaStringLooksLikeGotIt(ax)) {
				UIControl *ctl = thetaFindNearestControl(root);
				if (ctl) return ctl;
			}
			for (UIView *sub in root.subviews) {
				UIControl *found = thetaFindGotItControlInView(sub);
				if (found) return found;
			}
			return nil;
		};
		static BOOL (^thetaPressGotItIfPresent)(UIView *) = ^BOOL(UIView *root) {
			UIControl *ctl = thetaFindGotItControlInView(root);
			if (!ctl || !ctl.enabled || ctl.hidden || ctl.alpha <= 0.01) return NO;
			@try {
				[ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
				return YES;
			} @catch (__unused NSException *e) {
				return NO;
			}
		};

		// If we've already seen it once, remove and suppress
		if (thetaPromoSeen()) {
			// Give layout a moment, then try pressing the internal "Got it" button.
			BOOL pressed = thetaPressGotItIfPresent(view);
            if (pressed) return;
            // Fallback: remove/dismiss safely if we couldn't press
            view.hidden = YES;
            [view removeFromSuperview];
            UIWindow *w = view.window ?: UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.windows.firstObject;
            if (!w) return;
            UIViewController *vc = thetaFindOwningViewController(view);
            if (!vc) vc = w.rootViewController.presentedViewController;
            if (vc && thetaLooksLikePromoController(NSStringFromClass([vc class]))) {
                [vc dismissViewControllerAnimated:NO completion:nil];
                return;
            }
            UIViewController *presented = w.rootViewController.presentedViewController;
            if (presented && thetaLooksLikePromoController(NSStringFromClass([presented class]))) {
                [presented dismissViewControllerAnimated:NO completion:nil];
            }
			return;
		}

		// First time: let it show; monitor for dismissal and mark seen when it disappears
		thetaScheduleSeenMonitor(view);
	} @catch (__unused NSException *e) {
		// no-op
	}
}

void THRegisterDismissIGDSPromoDialogHooks(void) {
#ifdef SIDELOAD
    NullHookMessageEx(objc_getClass("IGDSPromoDialog.IGDSPromoDialogView"), @selector(didMoveToWindow), (void *)hook_hideIGDSPromoDialog, &orig_hideIGDSPromoDialog);
#endif
}