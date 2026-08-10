/*
 * Sideload-only: dismiss Instagram Beta / TestFlight force-update nag.
 * Do NOT hook UIViewController's presentViewController: — that breaks UIKit
 * presentations (including Theta's NUX) and can crash with PC=0.
 */

#ifdef SIDELOAD

static void theta_dismissTestFlightNag(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return;

    @try {
        vc.view.hidden = YES;
        vc.view.alpha = 0;
        vc.view.userInteractionEnabled = NO;

        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:NO completion:nil];
        } else if (vc.parentViewController) {
            [vc.view removeFromSuperview];
            [vc removeFromParentViewController];
        } else {
            [vc.view removeFromSuperview];
        }
    } @catch (__unused NSException *e) {
    }
}

static void (*orig_tfNag_viewDidLoad)(id, SEL);
static void hook_tfNag_viewDidLoad(id self, SEL _cmd) {
    if (orig_tfNag_viewDidLoad) orig_tfNag_viewDidLoad(self, _cmd);
    theta_dismissTestFlightNag((UIViewController *)self);
}

static void (*orig_tfNag_viewWillAppear)(id, SEL, BOOL);
static void hook_tfNag_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_tfNag_viewWillAppear) orig_tfNag_viewWillAppear(self, _cmd, animated);
    theta_dismissTestFlightNag((UIViewController *)self);
}

static void (*orig_tfNag_viewDidAppear)(id, SEL, BOOL);
static void hook_tfNag_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_tfNag_viewDidAppear) orig_tfNag_viewDidAppear(self, _cmd, animated);
    theta_dismissTestFlightNag((UIViewController *)self);
}

void THRegisterHideTestFlightNagHooks(void) {
    Class nag = ThetaFirstClass(@[
        @"_TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController"
    ]);
    if (!nag) return;

    NullHookMessageIfPresent(nag, @selector(viewDidLoad), (void *)hook_tfNag_viewDidLoad, (void **)&orig_tfNag_viewDidLoad);
    NullHookMessageIfPresent(nag, @selector(viewWillAppear:), (void *)hook_tfNag_viewWillAppear, (void **)&orig_tfNag_viewWillAppear);
    NullHookMessageIfPresent(nag, @selector(viewDidAppear:), (void *)hook_tfNag_viewDidAppear, (void **)&orig_tfNag_viewDidAppear);
}

#else

void THRegisterHideTestFlightNagHooks(void) {
}

#endif
