#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface THProfileAnalyzerViewController : UIViewController

/** Prefetch current user's profile image to disk so the analyzer shows it immediately when opened. Safe to call from any thread; runs work on a background queue. */
+ (void)prefetchProfileImageIfNeeded;

@end

NS_ASSUME_NONNULL_END
