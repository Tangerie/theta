#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

@interface MediaViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) NSURL *mediaURL;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) AVPlayerViewController *playerViewController;
-(instancetype)initWithMediaURL:(NSURL *)url;
@end
