static void (*orig_IGNotificationPresenter_dismissAnimated)(id, SEL, BOOL) = nil;
static void hook_IGNotificationPresenter_dismissAnimated(id self, SEL _cmd, BOOL animated) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (s_lastToastShowTime > 0 && (now - s_lastToastShowTime) < 1.5) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (orig_IGNotificationPresenter_dismissAnimated) orig_IGNotificationPresenter_dismissAnimated(self, _cmd, animated);
        });
        return;
    }
    if (orig_IGNotificationPresenter_dismissAnimated) orig_IGNotificationPresenter_dismissAnimated(self, _cmd, animated);
}

// Match CustomToastView kToastTopMargin (50pt from key window top) so native toasts align with load toast
static CGFloat const kToastTopMarginFromWindow = 50.0;
static void (*orig_toastView_layoutSubviews)(id, SEL) = nil;
static void hook_toastView_layoutSubviews(id self, SEL _cmd) {
    if (orig_toastView_layoutSubviews) orig_toastView_layoutSubviews(self, _cmd);
    UIView *v = (UIView *)self;
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden == NO && w.alpha > 0) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = v.window;
    if (!keyWindow) return;
    CGFloat currentTop = [v convertPoint:CGPointZero toView:keyWindow].y;
    CGFloat translationY = kToastTopMarginFromWindow - currentTop;
    v.transform = CGAffineTransformMakeTranslation(0, translationY);
}

void THRegisterToastDismissHooks(void) {
    NullHookMessageIfPresent(objc_getClass("IGNotificationPresenter"),
                             NSSelectorFromString(@"dismissAnimated:"),
                             (void *)hook_IGNotificationPresenter_dismissAnimated,
                             (void **)&orig_IGNotificationPresenter_dismissAnimated);
    // Align IG toast chrome with custom toast top margin when present.
    Class toastCls = objc_getClass("IGActionableConfirmationToastView");
    if (!toastCls) toastCls = objc_getClass("IGToastView");
    NullHookMessageIfPresent(toastCls, @selector(layoutSubviews),
                             (void *)hook_toastView_layoutSubviews,
                             (void **)&orig_toastView_layoutSubviews);
}