#import "Include.h"
#import "Include/InstagramHeaders.h"
#import "Include/ThetaTweakCommon.h"
#import "Include/ThetaHelper.h"
#import <objc/runtime.h>

/* Live viewer count polling + comment strip toggle. */

static void theta_disableLiveViewerCountPuller(id feedbackController) {
    Ivar pullerIvar = class_getInstanceVariable([feedbackController class], "_viewCountPuller");
    if (!pullerIvar) return;
    id puller = object_getIvar(feedbackController, pullerIvar);
    if (!puller) return;

    Ivar activeIvar = NULL;
    Ivar timerIvar = NULL;
    for (Class c = [puller class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        if (!activeIvar) activeIvar = class_getInstanceVariable(c, "_isActive");
        if (!timerIvar) timerIvar = class_getInstanceVariable(c, "_nextFetchTimer");
        if (activeIvar && timerIvar) break;
    }
    if (activeIvar) {
        ptrdiff_t off = ivar_getOffset(activeIvar);
        *(BOOL *)((char *)(__bridge void *)puller + off) = NO;
    }
    if (timerIvar) {
        id timer = object_getIvar(puller, timerIvar);
        if (timer && [timer respondsToSelector:@selector(invalidate)])
            ((void (*)(id, SEL))objc_msgSend)(timer, @selector(invalidate));
    }
}

static void (*orig_liveFeedbackStart)(id, SEL);
static void hook_liveFeedbackStart(id self, SEL _cmd) {
    orig_liveFeedbackStart(self, _cmd);
    if (ENABLED(@"Live Without Viewer List"))
        theta_disableLiveViewerCountPuller(self);
}

static __weak UIViewController *theta_activeLiveCommentsVC = nil;
static BOOL theta_liveCommentsHidden = NO;
static const void *kThetaLiveHeartLPKey = &kThetaLiveHeartLPKey;

static void theta_hideCommentCollections(UIView *root, BOOL hide, int depth) {
    if (!root || depth > 8) return;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UICollectionView class]]) {
            sub.alpha = hide ? 0.0 : 1.0;
            sub.userInteractionEnabled = !hide;
            continue;
        }
        theta_hideCommentCollections(sub, hide, depth + 1);
    }
}

static void theta_applyLiveCommentsVisibility(void) {
    if (!theta_activeLiveCommentsVC || !theta_activeLiveCommentsVC.isViewLoaded) return;
    theta_hideCommentCollections(theta_activeLiveCommentsVC.view, theta_liveCommentsHidden, 0);
}

@interface ThetaLiveCommentToggle : NSObject
+ (instancetype)shared;
- (void)heartLongPress:(UILongPressGestureRecognizer *)g;
@end

@implementation ThetaLiveCommentToggle
+ (instancetype)shared {
    static ThetaLiveCommentToggle *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ThetaLiveCommentToggle new]; });
    return s;
}
- (void)heartLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!ENABLED(@"Live Comments Sheet Toggle")) return;
    theta_liveCommentsHidden = !theta_liveCommentsHidden;
    theta_applyLiveCommentsVisibility();
    if (ENABLED(@"Show Banners")) {
        NSString *t = theta_liveCommentsHidden ? @"Comment list hidden" : @"Comment list visible";
        [ThetaHelper showToastWithTitle:@"Live" subtitle:t icon:[UIImage systemImageNamed:@"bubble.left.and.bubble.right"] autoHide:2 openURL:nil];
    }
}
@end

static void theta_attachHeartLongPress(UIView *v) {
    if (!v || objc_getAssociatedObject(v, kThetaLiveHeartLPKey)) return;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:[ThetaLiveCommentToggle shared] action:@selector(heartLongPress:)];
    g.minimumPressDuration = 0.5;
    g.cancelsTouchesInView = YES;
    [v addGestureRecognizer:g];
    objc_setAssociatedObject(v, kThetaLiveHeartLPKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void (*orig_liveFooterLayout)(id, SEL);
static void hook_liveFooterLayout(id self, SEL _cmd) {
    orig_liveFooterLayout(self, _cmd);
    if (!ENABLED(@"Live Comments Sheet Toggle")) return;
    Ivar iv = class_getInstanceVariable([self class], "_likeButton");
    if (!iv) return;
    UIView *btn = object_getIvar(self, iv);
    if (btn) theta_attachHeartLongPress(btn);
}

static void (*orig_liveCommentsAppear)(id, SEL, BOOL);
static void hook_liveCommentsAppear(id self, SEL _cmd, BOOL anim) {
    orig_liveCommentsAppear(self, _cmd, anim);
    theta_activeLiveCommentsVC = (UIViewController *)self;
    theta_liveCommentsHidden = NO;
    theta_applyLiveCommentsVisibility();
}

static void (*orig_liveCommentsDisappear)(id, SEL, BOOL);
static void hook_liveCommentsDisappear(id self, SEL _cmd, BOOL anim) {
    if (theta_activeLiveCommentsVC == (UIViewController *)self) theta_activeLiveCommentsVC = nil;
    orig_liveCommentsDisappear(self, _cmd, anim);
}

void THRegisterLiveBrowseTweaksHooks(void) {
    Class feedback = objc_getClass("IGLiveFeedbackController");
    if (feedback) NullHookMessageEx(feedback, @selector(start), (void *)hook_liveFeedbackStart, &orig_liveFeedbackStart);
    Class footer = objc_getClass("IGLiveFooterButtonsView");
    if (footer) NullHookMessageEx(footer, @selector(layoutSubviews), (void *)hook_liveFooterLayout, &orig_liveFooterLayout);
    Class comments = objc_getClass("IGLiveCommentsContainerViewController");
    if (comments) {
        NullHookMessageEx(comments, @selector(viewDidAppear:), (void *)hook_liveCommentsAppear, &orig_liveCommentsAppear);
        NullHookMessageEx(comments, @selector(viewWillDisappear:), (void *)hook_liveCommentsDisappear, &orig_liveCommentsDisappear);
    }
}
