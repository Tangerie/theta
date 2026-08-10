#import <UIKit/UIKit.h>

@interface CustomToastView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, assign) int autoHideTime;
@property (nonatomic, assign) BOOL isUserHolding;
@property (nonatomic, assign) BOOL isProgressType; // marks a persistent progress toast
-(instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon autoHide:(int)autoHide openURL:(NSURL *)url;
-(void)presentToast;
-(UIWindow *)getKeyWindow;
-(void)hideWithAnimation;
-(void)hideAfter:(NSTimeInterval)time;

// Progress toast methods
+(CustomToastView *)showProgressToastWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
-(void)updateProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
-(void)updateProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon;
-(void)updateProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle progress:(float)progress;
-(void)completeProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon url:(NSURL *)url;
-(void)recalculateWidth;
// Bulk per-item progress
-(void)setupPerItemProgressWithCount:(NSInteger)count;
-(void)updatePerItemProgressAtIndex:(NSInteger)index title:(NSString *)title progress:(float)progress;
@end

@interface CustomToastView ()
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIStackView *hStack; 
@property (nonatomic, strong) UIStackView *vStack;
@property (nonatomic, strong) NSURL *openURL;
@property (nonatomic, strong) UIImageView *progressIconView;
@property (nonatomic, strong) NSLayoutConstraint *topConstraint;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
// Single overall progress bar (used for single-item saves)
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIStackView *singleProgressRow;
// Per-item progress (used for bulk saves)
@property (nonatomic, strong) UIStackView *multiProgressStack;
@property (nonatomic, strong) NSMutableArray<UIProgressView *> *multiProgressBars;
@property (nonatomic, strong) NSMutableArray<UILabel *> *multiProgressTitles;
@end
