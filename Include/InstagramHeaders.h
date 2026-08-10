#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface IGDirectMessageBubbleView : UIView
@end

@interface IGDirectMessageViewModel : NSObject
@end

@interface IGDSSwitch : UISwitch
@end

@interface IGStoryGestureNuxView : UIView
@end

@interface IGDirectVisualMessageViewerController : UIViewController
- (UIView *)view;
- (void)storyPlayerMediaView:(id)arg1 didUpdateProgress:(CGFloat)arg2 captionController:(id)arg3;
- (void)storyPlayerMediaViewDidLoad:(id)arg1 loadSource:(id)arg2 networkRequestSummary:(id)arg3;
@end

@interface UIBarButtonItem (PrimaryAction)
- (void)setShowsMenuAsPrimaryAction:(BOOL)showsMenuAsPrimaryAction;
@end

@interface IGFeedItemPageIndicator : UIView
@property (assign, nonatomic) NSUInteger _currentPage;
@end

@interface IGAudioTrackClip : NSObject
@end

@interface IGProfileNavigationBarContext : NSObject
@end

@interface _UIButtonBar : UIView
@end

@interface IGNavigationBar : UINavigationBar
@end

@interface IGDirectThreadLastSeenMessageTracker : NSObject
- (BOOL)hasUnseenMessages;
@end

@interface IGListCollectionView : UICollectionView
@end

@interface IGExploreGridViewController : NSObject
@end

@interface IGDirectInboxThreadCellViewModel : NSObject
@end

@interface IGDirectThreadViewController : UIViewController
@end

@interface IGDirectThreadViewListAdapterDataSource : NSObject
- (BOOL)hasPreviousMessages;
@end

@interface IGDirectMessageKey: NSObject
@property (nonatomic, copy, readonly) NSString *serverId;
@end

@interface IGDirectUIMessageMetadata: NSObject
@property (nonatomic, assign, readonly) IGDirectMessageKey *key;
@end

@protocol IGDirectMessageViewModelProtocol <NSObject>
@property (nonatomic, readonly) IGDirectUIMessageMetadata *messageMetadata;
@end

@interface IGDirectMessageCell: UICollectionViewCell
@property (nonatomic, assign, readonly) UIView *contentViewForVisualMessageViewerPresentation;
@property (nonatomic, assign, readonly) id<IGDirectMessageViewModelProtocol> viewModel;
@end

@interface IGDirectMessageUpdateMessageKey: NSObject
@end

@interface IGDirectMessageUpdate: NSObject
@end

@interface IGDirectThreadUpdate: NSObject
@end

@interface IGSundialViewerVerticalUFI: UIView
@property (nonatomic, weak, readwrite) id delegate;
@property (nonatomic, assign, readonly) UIButton *ufiLikeButton;
@end

@interface IGProfilePictureImageView : UIImageView
@property (nonatomic, strong) UIView *view;
- (void)addHandleLongPress;
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender;
@end

@interface IGViewController: UIViewController
- (void)_superPresentViewController:(UIViewController *)viewController animated:(BOOL)animated completion:(id)completion;
@end

@interface IGDSHeadlineViewModel : NSObject
-(id)initWithTitleText:(id)arg1 isRoundImage:(BOOL)arg2 bodyText:(id)arg3 detailText:(id)arg4 buttonText:(id)arg5 header:(id)arg6 bulletItemViewModels:(id)arg7;
@end

@interface IGProfileBioView : UIView
-(id)initWithFrame:(struct CGRect )arg1;
@end

@interface IGBadgedNavigationButton : UIView
@end

@interface IGTabBarController : UIViewController <UIContextMenuInteractionDelegate>
-(void)_handleUserSwitchLongPress:(id)arg1;
@end

@interface IGTabBar : UIView
@end

@interface IGProfileNavigationHeaderView : UIView 
@property (retain, nonatomic) UIView *titleView;
-(id)initWithFrame:(struct CGRect )arg0 titleView:(id)arg1 sideTrayButton:(id)arg2 addButton:(id)arg3 additionalButton:(id)arg4 wonderwallButton:(id)arg5 discoverAccountsButton:(id)arg6 backButton:(id)arg7 ;
-(void)layoutSubviews;
@end

@interface IGProfileMenuSheetViewController: IGViewController
@end

@interface IGTableViewCell: UITableViewCell
- (id)initWithReuseIdentifier:(NSString *)identifier;
@end

@interface IGProfileSheetTableViewCell: IGTableViewCell
@end

@interface IGTallNavigationBarView: UIView
@end

@interface UIView (RCTViewUnmounting)
@property(retain, nonatomic) UIViewController *viewController;
- (UIView *)_rootView;
@end

@interface IGImageSpecifier : NSObject
@property(readonly, nonatomic) NSURL *url;
@end

@interface IGUFIButtonBarView : UIView
@end

@interface IGUFIInteractionCountsView : UIView
@end

@interface IGFeedItemUFICellConfigurableDelegateImpl : NSObject
@end

@interface IGImageURL: NSObject
@property (nonatomic, assign, readonly) NSURL *url;
@property (nonatomic, assign, readonly) CGFloat width;
@property (nonatomic, assign, readonly) CGFloat height;
@end

@interface IGFeedItemUFICell : NSObject
@property(nonatomic, assign) IGFeedItemUFICellConfigurableDelegateImpl *delegate;
- (NSInteger)pageControlCurrentPage;
@end

@interface IGVideo : NSObject {
  NSSet *_allVideoURLs;
  NSArray *_videoVersionDictionaries;
}
@property(readonly, nonatomic) NSSet *allVideoURLs;
@end

@interface IGPhoto: NSObject
{
  NSArray *_originalImageVersions;
}
@end

@interface IGMedia : NSObject
@property(atomic, assign, readonly) IGVideo *video;
@property (atomic, assign, readonly) IGPhoto *photo;
@property (atomic, strong, readwrite) NSArray *items;
@property long long likeCount;
- (BOOL)isPhotoMedia;
@end

@interface IGPostItem: NSObject
@property(atomic, assign, readonly) IGVideo *video;
@property (atomic, assign, readonly) IGPhoto *photo;
@property (nonatomic, assign, readonly) NSInteger mediaType;
- (NSInteger)itemMediaType;
@end

@interface IGVideoView : UIView
@property(retain, nonatomic) IGVideo *video;
@end

@interface IGSundialViewerControlsOverlayView: UIView
@property (nonatomic, weak, readwrite) id delegate;
@property (nonatomic, assign, readonly) IGMedia *media;
@end

@interface IGPageMediaView: UIView
@property(readonly) NSMutableArray <IGPostItem *> *items;
-(id)currentMediaItemWithUserSession:(id)arg0 sponsoredInfoProvider:(id)arg1 ;
@end

@interface IGFeedItem : NSObject
@property long long likeCount;
@property(readonly) IGVideo *video;
- (BOOL)isSponsored;
- (BOOL)isSponsoredApp;
@end

@interface IGStoryViewerViewModel: NSObject
@end

@interface IGStoryFullscreenSectionController: NSObject
@property (nonatomic, strong, readwrite) IGStoryViewerViewModel *viewModel;
@property (nonatomic, strong, readwrite) id currentStoryItem;
@property (nonatomic, readwrite) id delegate;
- (void)fullscreenOverlayDidTapNextStoryButton:(id)arg1;
- (void)fullscreenOverlay:(id)arg1 didLongPressWithGesture:(id)arg2;
- (void)fullscreenOverlayDidEndPressing:(id)arg1;
@end

@interface IGStoryFullscreenCell: UICollectionViewCell
@property (nonatomic, readwrite) id delegate;
- (void)setupButtons;
@end


@interface IGImageView : UIImageView
@property(retain, nonatomic) IGImageSpecifier *imageSpecifier;
@end

@interface IGFeedItemPagePhotoCell: UICollectionViewCell
@property (nonatomic, strong) id post;
@end

@interface IGProfilePicturePreviewViewController: UIViewController
{
  IGImageView *_profilePictureView;
}
- (void)addHandleLongPress;
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender;
@end
@interface IGProfilePicturePreviewViewController ()
@end

@interface IGFeedItemMediaCell : UICollectionViewCell
@property(retain, nonatomic) IGMedia *post;
- (UIImage *)mediaCellCurrentlyDisplayedImage;
@end

@interface IGFeedItemPhotoCell: IGFeedItemMediaCell
@end

@interface IGFeedPhotoView: UIView
@property (nonatomic, strong) id delegate;
@end
@interface IGFeedPhotoView ()
@end

@interface IGSundialViewerUFIViewModel: NSObject
@property (nonatomic, copy, readonly) IGMedia *media;
@end

@interface IGVideoPlayer : NSObject {
  IGVideo *_video;
}
@end

@protocol IGStoryPlayerMediaViewType
@end

@interface IGImageProgressView : UIView
@property(retain, nonatomic) IGImageSpecifier *imageSpecifier;
@end

@interface IGStoryPhotoView : UIView<IGStoryPlayerMediaViewType>
@property(retain, nonatomic) IGImageSpecifier *mediaViewLastLoadedImageSpecifier;
@property(readonly, nonatomic) IGImageProgressView *photoView;
@end

@interface IGStoryVideoView : UIView<IGStoryPlayerMediaViewType>
@property(retain, nonatomic) IGVideoPlayer *videoPlayer;
@end

@interface IGStoryFullscreenDefaultFooterView: UIView
@end

@interface IGStoryFullscreenFooterContainerView: UIView
@property(nonatomic) IGStoryFullscreenDefaultFooterView *defaultFooterView;
@end

@interface IGStoryFullscreenOverlayView: UIView
@property(retain, nonatomic) IGStoryFullscreenFooterContainerView *footerContainerView;
@end

@interface IGStoryViewerViewController : UIViewController
{
  id _focusStoryItemOnEntry;
}
- (id)_getMostVisibleSectionController;
- (void)fullscreenSectionController:(id)arg1 didMarkItemAsSeen:(id)arg2;
@property (nonatomic) UIView *contentViewForSnapshot;
@end


@interface IGStoryViewerContainerView: UIView
@property(retain, nonatomic) UIView<IGStoryPlayerMediaViewType> *mediaView;
@property(nonatomic) IGStoryFullscreenOverlayView *overlayView;
@property (nonatomic, weak) id delegate;
@end
@interface IGStoryViewerContainerView ()
@end

@interface IGUser : NSObject
@property NSInteger followStatus;
@property(copy) NSString *username;
@property BOOL followsCurrentUser;
@property BOOL isCurrentUser;
@property NSString *biography;
- (NSURL *)HDProfilePicURL;
- (BOOL)isUser;

@end

@interface IGFollowController : NSObject 
@property IGUser *user;
@end

@interface IGProfileBioModel
@property(readonly, copy, nonatomic) IGUser *user;
@end

@interface IGProfileSimpleAvatarStatsCell : UICollectionViewCell
@property(nonatomic, retain) UIView *isFollowingYouBadge;
@property(nonatomic, retain) UILabel *isFollowingYouLabel;
- (void)addIsFollowingYouBadgeView;
@end

@interface IGUserSession : NSObject
@property(readonly, nonatomic) IGUser *user;
@end

@interface IGWindow : UIWindow
@property(nonatomic) __weak IGUserSession *userSession;
@end

@interface IGShakeWindow : UIWindow
@property(nonatomic) __weak IGUserSession *userSession;
@end

@interface IGStyledString : NSObject
@property(retain, nonatomic) NSMutableAttributedString *attributedString;
- (void)appendString:(id)arg1;
@end

@interface IGInstagramAppDelegate : NSObject <UIApplicationDelegate>
@end

@interface IGPassthroughView : UIView
@end

@interface IGDirectComposer : UIView <UIContextMenuInteractionDelegate>
@property (nonatomic, strong) UIView *view;
- (void)sendPhoto;
- (void)sendVideo;
- (void)sendVoiceMessage;
- (void)showSpamCountPromptWithMessage:(NSString *)message;
- (void)spamMessage:(NSString *)message withCount:(NSInteger)count;
@end

@interface IGFeedItemHeader : UIView
@end

@interface IGDirectKeyboardTextView : UIView
@end

@interface IGDirectComposerButton : UIButton
@end

@interface IGDSSegmentedPillBarView : UIView
@property (nonatomic, strong) id delegate;
@end

@interface IGALButton : UIButton
@property (nonatomic) BOOL enableAutomatedLogging;
@property (copy, nonatomic) NSString *finalDestinationModuleForAutomatedLogging;
- (void)_didTapOnALButton:(id)albutton;
@end

@interface IGTapButton : IGALButton {
  NSMutableDictionary *_stateToBackgroundColorMap;
  UIVisualEffectView *_visualEffectView;
  unsigned long long _visualEffectViewState;
  CALayer *_hitTestVisualizer;
  BOOL _edr;
  BOOL _enableOpacityAnimation;
  BOOL _sizeAndPositionTitleLabelToMatchButton;
}
- (void)layoutSubviews;
- (void)setBackgroundColor:(id)color;
- (void)setHighlighted:(BOOL)highlighted;
- (void)setEnabled:(BOOL)enabled;
- (void)setSelected:(BOOL)selected;
- (void)didUpdateFocusInContext:(id)context withAnimationCoordinator:(id)coordinator;
- (void)touchesBegan:(id)began withEvent:(id)event;
- (void)touchesMoved:(id)moved withEvent:(id)event;
- (void)touchesEnded:(id)ended withEvent:(id)event;
- (void)touchesCancelled:(id)cancelled withEvent:(id)event;
- (void)setEDR:(BOOL)edr;
@end

@interface IGDSAlertDialogActionButton : IGTapButton
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSString *currentTitle;
@end

@interface IGAlertDialogActionButton : IGTapButton
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSString *currentTitle;
@end

@interface IGBadgeButton : IGTapButton
@end

@interface IGCustomAlertAction : NSObject
@end

@interface IGDSAlertDialogView : UIView
- (id)initWithStyle:(id)style titleText:(id)title descriptionText:(id)description actions:(NSArray *)actions showHorizontalButtons:(BOOL)showHorizontalButtons;
- (void)_alertActionButtonTapped:(id)tapped;
- (void)show;
@end

@interface IGAlertDialogView : UIView
-(id)initWithStyle:(id)arg1 titleText:(id)arg2 descriptionText:(id)arg3 actions:(id)arg4 showHorizontalButtons:(BOOL)arg5;
- (void)_alertActionButtonTapped:(id)tapped;
- (void)show;
@end

@interface IGDSAlertDialogStyle : NSObject {
    unsigned long long _subtype;
    UIView *_centeredImage;
    UIView *_circleImage;
    UIView *_freeformImage;
}
+ (id)centeredImage:(id)image;
+ (id)circleImage:(id)image;
+ (id)defaultStyle;
+ (id)freeformImage:(id)image;
@end

@interface IGAlertDialogStyle : NSObject {
    unsigned long long _subtype;
    UIView *_centeredImage;
    UIView *_circleImage;
    UIView *_freeformImage;
}
+ (id)centeredImage:(id)image;
+ (id)circleImage:(id)image;
+ (id)defaultStyle;
+ (id)freeformImage:(id)image;
@end

@interface IGUFIButton : UIView
@end

@interface IGFeedItemPageCell : UICollectionViewCell
@end

@interface IGUnifiedVideoCollectionView : UIScrollView
@end

NS_ASSUME_NONNULL_BEGIN

@class IGActionableConfirmationToastViewModel;
@class IGActionableConfirmationToastViewThumbnail;
@class IGActionableConfirmationToastPresentationContext;
@protocol IGActionableConfirmationToastViewDelegate;

#pragma mark - Block types

typedef void (^IGActionableConfirmationToastTapActionBlock)(void);
typedef void (^IGActionableConfirmationToastPresentedHandler)(UIView * _Nullable toastView);
typedef void (^IGActionableConfirmationToastDismissedHandler)(UIView * _Nullable toastView);
typedef void (^IGActionableConfirmationToastTapToastBlock)(UIView * _Nullable toastView);

#pragma mark - IGActionableConfirmationToastViewThumbnail

/// Wraps the image shown in the toast. Reverse-engineered; exact initializer may vary by Instagram version.
/// If initWithImage: is not found, search the binary for IGActionableConfirmationToastViewThumbnail and
/// look for selectors containing "image", "URL", or "init" and add the correct declaration here.
@interface IGActionableConfirmationToastViewThumbnail : NSObject

/// Primary candidate from reverse engineering. Adjust selector if the binary uses a different one (e.g. thumbnailWithImage:).
- (instancetype)initWithImage:(UIImage *)image;

@end

#pragma mark - IGActionableConfirmationToastViewModel

/// View model for the toast. The binary may not expose initWithTitle:subtitle:thumbnail: on this class
/// (e.g. it may be on a Swift type or a different class). Use IGActionableConfirmationToastViewModelCreate()
/// to create an instance at runtime.
@interface IGActionableConfirmationToastViewModel : NSObject
@end

/// Creates a toast view model at runtime by finding the class that responds to initWithTitle:subtitle:thumbnail:.
/// Returns an object you can pass to showAlertWithViewModel: (use as IGActionableConfirmationToastViewModel *).
/// Returns nil if no such class is found in the loaded ObjC runtime.
FOUNDATION_EXPORT id _Nullable IGActionableConfirmationToastViewModelCreate(NSString *title, NSString * _Nullable subtitle, id _Nullable thumbnail);

#pragma mark - IGActionableConfirmationToastPresentationContext

@interface IGActionableConfirmationToastPresentationContext : NSObject

- (instancetype)initWithPresentingViewController:(UIViewController *)presentingViewController
              onlyShowOnSpecifiedViewController:(BOOL)onlyShowOnSpecifiedViewController;

@end

#pragma mark - IGActionableConfirmationToastPresenter

@interface IGActionableConfirmationToastPresenter : NSObject

/// Show ephemeral toast with presentation context (recommended).
- (void)showAlertWithViewModel:(IGActionableConfirmationToastViewModel *)viewModel
            presentationContext:(IGActionableConfirmationToastPresentationContext *)context
                    isAnimated:(BOOL)animated
             animationDuration:(NSTimeInterval)duration
         presentationPriority:(NSInteger)priority
                tapActionBlock:(nullable IGActionableConfirmationToastTapActionBlock)tapActionBlock
              presentedHandler:(nullable IGActionableConfirmationToastPresentedHandler)presentedHandler
              dismissedHandler:(nullable IGActionableConfirmationToastDismissedHandler)dismissedHandler;

/// Show ephemeral toast without context (uses default presentation).
- (void)showAlertWithViewModel:(IGActionableConfirmationToastViewModel *)viewModel
                    isAnimated:(BOOL)animated
             animationDuration:(NSTimeInterval)duration
         presentationPriority:(NSInteger)priority
                tapActionBlock:(nullable IGActionableConfirmationToastTapActionBlock)tapActionBlock
              presentedHandler:(nullable IGActionableConfirmationToastPresentedHandler)presentedHandler
              dismissedHandler:(nullable IGActionableConfirmationToastDismissedHandler)dismissedHandler;

@end

#pragma mark - IGActionableConfirmationToastView (reference only)

/// The actual toast UIView. You do not instantiate this directly; the presenter creates it from the ViewModel.
@interface IGActionableConfirmationToastView : UIView
@property (nonatomic, weak, nullable) id<IGActionableConfirmationToastViewDelegate> delegate;
@end

@protocol IGActionableConfirmationToastViewDelegate <NSObject>
@optional
- (void)actionableConfirmationToastViewDidTap:(IGActionableConfirmationToastView *)toastView;
- (void)actionableConfirmationToastViewDidDismiss:(IGActionableConfirmationToastView *)toastView;
@end

NS_ASSUME_NONNULL_END

static BOOL is_iPad() {
    if ([(NSString *)[UIDevice currentDevice].model hasPrefix:@"iPad"]) {
        return YES;
    }
    return NO;
}

static UIViewController * _Nullable _topMostController(UIViewController * _Nonnull cont) {
    UIViewController *topController = cont;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    if ([topController isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)topController).visibleViewController;
        if (visible) {
            topController = visible;
        }
    }
    return (topController != cont ? topController : nil);
}
static UIViewController * _Nonnull topMostController() {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    UIViewController *next = nil;
    while ((next = _topMostController(topController)) != nil) {
        topController = next;
    }
    return topController;
}