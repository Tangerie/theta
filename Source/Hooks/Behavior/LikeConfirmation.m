#import "Include/ThetaHelper.h"

static void showLikeConfirmationAlert(NSString *mediaType, void (^confirmAction)(void)) {
    NSString *description = [NSString stringWithFormat:@"Are you sure you want to like this %@?", mediaType];
    [ThetaHelper showCustomAlertWithActions:@"Hold up!" description:description actions:@[
        @{ @"title": @"Yes, like it!", @"handler": ^(id sender) { confirmAction(); } },
        @{ @"title": @"No, cancel.", @"handler": ^(id sender) { } },
    ]];
}

/// If the setting is off, invokes `invokeOrig` only. If on, shows the confirmation alert, then invokes `invokeOrig` when the user confirms.
static void theta_runLikeConfirmation(NSString *mediaType, void (^invokeOrig)(void)) {
    if (!ENABLED(@"Like Confirmation")) {
        invokeOrig();
        return;
    }
    showLikeConfirmationAlert(mediaType, invokeOrig);
}

static void (*orig_likeConfirmation)(id self, SEL _cmd, id arg1);
static void hook_likeConfirmation(id self, SEL _cmd, id arg1) {
    theta_runLikeConfirmation(@"post", ^{ orig_likeConfirmation(self, _cmd, arg1); });
}

static void (*orig_likeConfirmation2)(id self, SEL _cmd, id arg1, id arg2);
static void hook_likeConfirmation2(id self, SEL _cmd, id arg1, id arg2) {
    theta_runLikeConfirmation(@"reel", ^{ orig_likeConfirmation2(self, _cmd, arg1, arg2); });
}

static void (*orig_likeConfirmation3)(id self, SEL _cmd, id arg1);
static void hook_likeConfirmation3(id self, SEL _cmd, id arg1) {
    theta_runLikeConfirmation(@"photo", ^{ orig_likeConfirmation3(self, _cmd, arg1); });
}

static void (*orig_likeConfirmation4)(id self, SEL _cmd, id arg1);
static void hook_likeConfirmation4(id self, SEL _cmd, id arg1) {
    theta_runLikeConfirmation(@"post", ^{ orig_likeConfirmation4(self, _cmd, arg1); });
}

static void (*orig_likeConfirmation5)(id self, SEL _cmd, id arg1);
static void hook_likeConfirmation5(id self, SEL _cmd, id arg1) {
    theta_runLikeConfirmation(@"post", ^{ orig_likeConfirmation5(self, _cmd, arg1); });
}

static void (*orig_likeConfirmation6)(id self, SEL _cmd);
static void hook_likeConfirmation6(id self, SEL _cmd) {
    theta_runLikeConfirmation(@"post", ^{ orig_likeConfirmation6(self, _cmd); });
}

void THRegisterLikeConfirmationHooks(void) {
    // Feed video double-tap (Swift rename)
    ThetaHookFirst(
        @[ @"_TtC25IGModernFeedVideoOverlays33IGVideoPlayerOverlayContainerView",
           @"IGVideoPlayerOverlayContainerView" ],
        @[ @"handleDoubleTapGesture:", @"_handleDoubleTapGesture:" ],
        (void *)hook_likeConfirmation, &orig_likeConfirmation);

    NullHookMessageIfPresent(objc_getClass("IGSundialViewerVideoCell"),
                             @selector(gestureController:didObserveDoubleTap:),
                             (void *)hook_likeConfirmation2, &orig_likeConfirmation2);
    NullHookMessageIfPresent(objc_getClass("IGFeedPhotoView"),
                             @selector(_onDoubleTap:),
                             (void *)hook_likeConfirmation3, &orig_likeConfirmation3);
    NullHookMessageIfPresent(objc_getClass("IGFeedItemUFICell"),
                             @selector(UFIButtonBarDidTapOnLike:),
                             (void *)hook_likeConfirmation4, &orig_likeConfirmation4);

    // Reels vertical UFI like button (Swift rename)
    Class ufi = ThetaFirstClass(@[
        @"_TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI",
        @"IGSundialViewerVerticalUFI"
    ]);
    if (ufi) {
        NullHookMessageIfPresent(ufi, @selector(didTapLikeButton), (void *)hook_likeConfirmation6, &orig_likeConfirmation6);
        NullHookMessageIfPresent(ufi, @selector(_didTapLikeButton), (void *)hook_likeConfirmation6, &orig_likeConfirmation6);
        NullHookMessageIfPresent(ufi, @selector(_didTapLikeButton:), (void *)hook_likeConfirmation5, &orig_likeConfirmation5);
    }
}
