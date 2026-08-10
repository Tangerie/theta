#import "Include/MediaViewController.h"



@implementation MediaViewController
- (instancetype)initWithMediaURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _mediaURL = url;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    NSString *fileExtension = [_mediaURL pathExtension].lowercaseString;
    if ([fileExtension isEqualToString:@"jpg"] || [fileExtension isEqualToString:@"png"]) {
        [self displayImage];
    } else if ([fileExtension isEqualToString:@"mp4"] || [fileExtension isEqualToString:@"mov"]) {
        [self displayVideo];
    }
}

- (void)displayImage {
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.delegate = self;
    self.scrollView.maximumZoomScale = 3.0;
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.contentSize = self.view.bounds.size;
    [self.view addSubview:self.scrollView];

    self.imageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.userInteractionEnabled = YES;
    [self.scrollView addSubview:self.imageView];

    NSData *imageData = [NSData dataWithContentsOfURL:_mediaURL];
    UIImage *image = [UIImage imageWithData:imageData];
    self.imageView.image = image;

    UIButton *dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [dismissButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    [dismissButton addTarget:self action:@selector(dismissViewController) forControlEvents:UIControlEventTouchUpInside];
    dismissButton.frame = CGRectMake(20, 40, 40, 40);
    dismissButton.tintColor = [UIColor whiteColor];
    [self.view addSubview:dismissButton];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)displayVideo {
    AVPlayer *player = [AVPlayer playerWithURL:_mediaURL];
    self.playerViewController = [AVPlayerViewController new];
    self.playerViewController.player = player;
    self.playerViewController.showsPlaybackControls = YES;

    [self addChildViewController:self.playerViewController];
    [self.view addSubview:self.playerViewController.view];
    self.playerViewController.view.frame = self.view.bounds;
    [self.playerViewController didMoveToParentViewController:self];

    [player play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (self.imageView) {
        self.imageView.image = nil;
    }

    if (self.playerViewController) {
        [self.playerViewController.player pause];
        [self.playerViewController.view removeFromSuperview];
        [self.playerViewController removeFromParentViewController];
        self.playerViewController = nil;
    }
}

- (void)dismissViewController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end