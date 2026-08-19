#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "Include/MediaSelectionViewController.h"
#import "Include/CustomToastView.h"
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import "Include/rootless.h"
#import "Include/ThetaHelper.h"
#import "Include/AV1Transcoder.h"
#import "Include/ThetaDashManifest.h"

// Global guard to prevent concurrent downloads
static volatile BOOL sThetaDownloadInProgress = NO;

// Helper functions for cleaner code
static void cleanupTemporaryFiles(NSString *videoPath, NSString *audioPath, NSString *outputPath) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSMutableArray *paths = [NSMutableArray array];
    if (videoPath) [paths addObject:videoPath];
    if (audioPath) [paths addObject:audioPath];
    if (outputPath) [paths addObject:outputPath];
    
    for (NSString *path in paths) {
        NSError *error;
        if ([fileManager fileExistsAtPath:path]) {
            [fileManager removeItemAtPath:path error:&error];
        }
    }
}

static void showCompletionToast(CustomToastView *progressToast, BOOL success, NSString *title, NSString *subtitle, UIImage *icon, NSURL *url) {
    if (progressToast) {
        [progressToast completeProgressWithTitle:title subtitle:subtitle icon:icon url:url];
        if (success) {
            // Haptic feedback for success
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [generator impactOccurred];
        }
    } else {
        // Fallback to regular toast if no progress toast
        // You might need to implement this based on your existing toast system
    }
}


#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]



@implementation MediaSelectionViewController {
    BOOL hasShownToast;
    CAGradientLayer *gradientLayer;
    CAEmitterLayer *emitterLayer;
}

+ (BOOL)isDownloadInProgress {
    @synchronized(self) {
        return sThetaDownloadInProgress;
    }
}

+ (void)setDownloadInProgress:(BOOL)inProgress {
    @synchronized(self) {
        sThetaDownloadInProgress = inProgress;
    }
}

- (instancetype)initWithMediaItems:(NSArray<NSDictionary *> *)mediaItems withCount:(NSInteger)count {
    return [self initWithMediaItems:mediaItems hdVideos:nil withCount:count];
}

- (instancetype)initWithMediaItems:(NSArray<NSDictionary *> *)mediaItems hdVideos:(NSArray<IGVideo *> *)hdVideos withCount:(NSInteger)count {
    self = [super init];
    if (self) {
        _mediaItems = mediaItems ?: @[];
        _hdVideos = hdVideos ?: @[];
        _count = count;
        _selectedIndexes = [NSMutableSet set];
        _selectedVideoIndexes = [NSMutableSet set];
        hasShownToast = NO;
        _previewCache = [self.class sharedPreviewCache]; // Use shared cache
        _videoPlayersCache = [[NSMutableDictionary alloc] init];
        _fetchQueue = [[NSOperationQueue alloc] init];
        _fetchQueue.maxConcurrentOperationCount = 12;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    if (![self isInternetAvailable]) {
        [self showToastWithTitle:@"No internet connection" subtitle:@"Please connect to the internet." icon:[UIImage systemImageNamed:@"wifi.slash"] seconds:4 openURL:nil];
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    } else {
        if (ENABLED(@"Show Banners")) {
            UIImage *fetchedImage = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            [self showToastWithTitle:@"Fetched!" subtitle:@"Thanks for waiting." icon:fetchedImage seconds:2 openURL:nil];
        }
    }
    
    // Force update instruction label after view loads
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateInstructionLabel];
    });

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurEffectView.frame = self.view.bounds;
    blurEffectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blurEffectView];

    gradientLayer = [CAGradientLayer layer];
    gradientLayer.frame = self.view.bounds;
    [self.view.layer insertSublayer:gradientLayer atIndex:0];

    [self calculateAverageColorFromMediaItemsAsync:^(UIColor *averageColor) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupGradientWithColor:averageColor];
            [self setupEmitterWithColor:averageColor];
        });
    }];

    self.selectAllButton = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 100, 30)];
    [self.selectAllButton setTitle:@"Select All" forState:UIControlStateNormal];
    self.selectAllButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    	self.selectAllButton.tintColor = [ThetaHelper iotaPinkColor];
    [self updateSelectAllButtonColor];
    [self.selectAllButton addTarget:self action:@selector(selectAllButtonTapped) forControlEvents:UIControlEventTouchUpInside];

    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"] style:UIBarButtonItemStylePlain target:self action:@selector(dismissView)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(selectAllButtonTapped)]
    ];
    	self.navigationController.navigationBar.tintColor = [ThetaHelper iotaPinkColor];
    // Use iOS 16+ SF Symbol with fallback for older versions
    UIImage *downloadImage;
    if (@available(iOS 16.0, *)) {
        downloadImage = [UIImage systemImageNamed:@"arrow.down.to.line"];
    } else {
        // Fallback for iOS 15 - use a different symbol
        downloadImage = [UIImage systemImageNamed:@"arrow.down"];
    }
    self.downloadButton = [[UIBarButtonItem alloc] initWithImage:downloadImage style:UIBarButtonItemStyleDone target:self action:@selector(downloadSelectedItems)];
    self.downloadButton.enabled = NO;
    self.navigationItem.rightBarButtonItem = self.downloadButton;

    self.instructionLabel = [[UILabel alloc] init];
    self.instructionLabel.textColor = [UIColor lightGrayColor];
    self.instructionLabel.textAlignment = NSTextAlignmentCenter;
    self.instructionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.instructionLabel];
    
    [self updateInstructionLabel];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize = CGSizeMake(200, 350);
    layout.minimumLineSpacing = 20;
    layout.sectionInset = UIEdgeInsetsMake(80, 20, 80, 20);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.delegate = self;
    self.collectionView.dataSource = self;
    self.collectionView.prefetchDataSource = self;
    self.collectionView.prefetchingEnabled = YES;
    self.collectionView.showsHorizontalScrollIndicator = NO;
    [self.collectionView registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"MediaCell"];
    [self.view addSubview:self.collectionView];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [self.instructionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.instructionLabel.bottomAnchor constraintEqualToAnchor:self.collectionView.topAnchor constant:-50],
        [self.collectionView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.collectionView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [self.collectionView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor],
        [self.collectionView.heightAnchor constraintEqualToConstant:370]
    ]];

    self.collectionView.alpha = 0.0;
    [UIView animateWithDuration:0.5 animations:^{
        self.collectionView.alpha = 1.0;
    }];

    for (NSDictionary *mediaItem in self.mediaItems) {
        NSString *urlString = mediaItem[@"url"];
        if ([urlString.pathExtension.lowercaseString isEqualToString:@"mp4"]) {
            AVPlayer *player = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:urlString]];
            self.videoPlayersCache[urlString] = player;
        }
    }
}

- (BOOL)isInternetAvailable {
    SCNetworkReachabilityFlags flags;
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "www.google.com");
    if (!reachability) return NO;
    Boolean success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    if (!success || (flags & kSCNetworkFlagsReachable) == 0 || (flags & kSCNetworkFlagsConnectionRequired) != 0) {
        return NO;
    }
    return YES;
}

- (void)showToastWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon seconds:(int)seconds openURL:(NSURL *)openURL {
    CustomToastView *toast = [[CustomToastView alloc] initWithTitle:title subtitle:subtitle icon:icon autoHide:seconds openURL:openURL];
    [toast presentToast];
    [self hapticIfNeeded];
}

- (void)hapticIfNeeded {
    if (ENABLED(@"Haptic Feedback")) {
        AudioServicesPlaySystemSound(1519);
    }
}

- (void)setupGradientWithColor:(UIColor *)averageColor {
    gradientLayer.colors = @[(id)averageColor.CGColor, (id)[UIColor clearColor].CGColor];
    gradientLayer.startPoint = CGPointMake(0.0, 0.5);
    gradientLayer.endPoint = CGPointMake(1.0, 0.5);
}

- (void)setupEmitterWithColor:(UIColor *)color {
    emitterLayer = [CAEmitterLayer layer];
    emitterLayer.frame = self.view.bounds;
    emitterLayer.renderMode = kCAEmitterLayerAdditive;
    emitterLayer.emitterPosition = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0);
    emitterLayer.emitterSize = CGSizeMake(self.view.bounds.size.width, self.view.bounds.size.height);
    emitterLayer.emitterShape = kCAEmitterLayerRectangle;
    emitterLayer.emitterMode = kCAEmitterLayerSurface;
    emitterLayer.emitterCells = [self createEmitterCellsWithColor:color];
    [self.view.layer insertSublayer:emitterLayer atIndex:1];
}

- (NSArray<CAEmitterCell *> *)createEmitterCellsWithColor:(UIColor *)color {
    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.birthRate = 5.0;
    cell.lifetime = 2.0;
    cell.lifetimeRange = 1.0;
    cell.velocity = 50.0;
    cell.velocityRange = 50.0;
    cell.emissionLongitude = M_PI;
    cell.emissionRange = M_PI_4;
    cell.spin = M_PI_4;
    cell.spinRange = M_PI_4;
    cell.scale = 0.1;
    cell.scaleRange = 0.1;
    cell.scaleSpeed = -0.05;
    cell.alphaSpeed = -0.1;
    cell.color = color.CGColor;
    cell.contents = (id)[UIImage imageNamed:@"spark"].CGImage;

    CAEmitterCell *foldCell = [CAEmitterCell emitterCell];
    foldCell.birthRate = 2.0;
    foldCell.lifetime = 3.0;
    foldCell.lifetimeRange = 2.0;
    foldCell.velocity = 20.0;
    foldCell.velocityRange = 10.0;
    foldCell.emissionLongitude = M_PI;
    foldCell.emissionRange = M_PI_2;
    foldCell.spin = M_PI_2;
    foldCell.spinRange = M_PI_2;
    foldCell.scale = 0.2;
    foldCell.scaleRange = 0.1;
    foldCell.scaleSpeed = -0.05;
    foldCell.alphaSpeed = -0.1;
    foldCell.color = color.CGColor;
    foldCell.contents = (id)[UIImage imageNamed:@"fold"].CGImage;

    return @[cell, foldCell];
}

- (void)calculateAverageColorFromMediaItemsAsync:(void (^)(UIColor *averageColor))completion {
    NSArray *imageItems = [self.mediaItems filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *mediaItem, NSDictionary *bindings) {
        NSString *urlString = mediaItem[@"url"];
        return ![urlString.pathExtension.lowercaseString isEqualToString:@"mp4"];
    }]];
    NSUInteger count = MIN(8, imageItems.count);
    if (count == 0) {
        completion([UIColor whiteColor]);
        return;
    }

    __block uint64_t totalRed = 0, totalGreen = 0, totalBlue = 0, pixelCount = 0;
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *mediaItem = imageItems[i];
        NSString *urlString = mediaItem[@"url"];
        NSURL *url = [NSURL URLWithString:urlString];
        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                if (image) {
                    UIColor *avg = [self averageColorFromImage:image];
                    CGFloat r, g, b, a;
                    [avg getRed:&r green:&g blue:&b alpha:&a];
                    totalRed += r * 255;
                    totalGreen += g * 255;
                    totalBlue += b * 255;
                    pixelCount++;
                }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (pixelCount == 0) {
            completion([UIColor whiteColor]);
        } else {
            CGFloat averageRed = totalRed / pixelCount / 255.0;
            CGFloat averageGreen = totalGreen / pixelCount / 255.0;
            CGFloat averageBlue = totalBlue / pixelCount / 255.0;
            completion([UIColor colorWithRed:averageRed green:averageGreen blue:averageBlue alpha:1.0]);
        }
    });
}

- (UIColor *)averageColorFromImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return [UIColor whiteColor];
    size_t dataSize = width * height * 4;
    uint8_t *rawData = malloc(dataSize);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSUInteger bytesPerPixel = 4;
    NSUInteger bytesPerRow = bytesPerPixel * width;
    NSUInteger bitsPerComponent = 8;
    CGContextRef context = CGBitmapContextCreate(rawData, width, height, bitsPerComponent, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    uint64_t totalRed = 0, totalGreen = 0, totalBlue = 0;
    uint64_t pixelCount = width * height;

    for (NSUInteger i = 0; i < pixelCount; i++) {
        uint8_t *pixel = rawData + i * 4;
        totalRed += pixel[0];
        totalGreen += pixel[1];
        totalBlue += pixel[2];
    }

    free(rawData);

    CGFloat averageRed = totalRed / pixelCount / 255.0;
    CGFloat averageGreen = totalGreen / pixelCount / 255.0;
    CGFloat averageBlue = totalBlue / pixelCount / 255.0;

    return [UIColor colorWithRed:averageRed green:averageGreen blue:averageBlue alpha:1.0];
}

static BOOL ThetaPreviewImageIsPlaceholder(UIImage *image) {
    if (!image) return YES;
    if (@available(iOS 13.0, *)) {
        if (image.isSymbolImage) return YES;
    }
    // Tiny SF-symbol-sized bitmaps sometimes get rasterized; treat very small images as placeholders.
    if (image.size.width <= 44.0 && image.size.height <= 44.0) return YES;
    return NO;
}

// Async preview generation using NSURLSession
- (void)generatePreviewForMediaItem:(NSDictionary *)mediaItem completion:(void (^)(UIImage *preview))completion {
    if (!completion) return;
    NSString *urlString = mediaItem[@"url"];
    if (!urlString.length) {
        completion(nil);
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(nil);
        return;
    }

    NSString *ext = url.pathExtension.lowercaseString;
    // Strip query-less path ext; CDN URLs often embed ".mp4" before query.
    NSString *path = url.path.lowercaseString ?: @"";
    BOOL looksVideo = [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [path containsString:@".mp4"] || [mediaItem[@"isVideo"] boolValue];
    if (looksVideo) {
        completion(nil);
        return;
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 12.0;
    config.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        @"Accept": @"image/*,*/*;q=0.8",
        @"Referer": @"https://www.instagram.com/"
    };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) {
            completion(nil);
            return;
        }
        UIImage *image = [UIImage imageWithData:data];
        completion(ThetaPreviewImageIsPlaceholder(image) ? nil : image);
    }];
    [task resume];
}

// Prefetching previews using NSOperationQueue and NSURLSession
- (void)startLoadingMediaItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.item < 0 || indexPath.item >= (NSInteger)self.mediaItems.count) return;
    NSDictionary *mediaItem = self.mediaItems[indexPath.item];
    NSString *urlString = mediaItem[@"url"];
    if (!urlString.length) return;

    UIImage *existing = [self.previewCache objectForKey:urlString];
    if ([existing isKindOfClass:[UIImage class]] && !ThetaPreviewImageIsPlaceholder(existing)) {
        return;
    }

    [self.fetchQueue addOperationWithBlock:^{
        [self generatePreviewForMediaItem:mediaItem completion:^(UIImage *preview) {
            if (!preview) return;
            [self.previewCache setObject:preview forKey:urlString];
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                if (indexPath.item < (NSInteger)self.mediaItems.count) {
                    [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
                }
            }];
        }];
    }];
}

- (void)cancelLoadingMediaItemAtIndexPath:(NSIndexPath *)indexPath {
    for (NSOperation *operation in self.fetchQueue.operations) {
        if (!operation.isFinished && !operation.isCancelled) {
            [operation cancel];
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateSelectAllButtonColor];
}

- (void)updateSelectAllButtonColor {
    if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        [self.selectAllButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        [self.selectAllButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateInstructionLabel];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.previewCache removeAllObjects];
    [self.videoPlayersCache removeAllObjects];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.mediaItems.count + self.hdVideos.count;
}

static void * const playerKey = &playerKey;

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    AVPlayer *player = objc_getAssociatedObject(cell, playerKey);
    if (player) {
        [player play];
    }
    // Prefetch alone is unreliable for the first visible page — always kick preview loads here.
    if (indexPath.item < (NSInteger)self.mediaItems.count) {
        [self startLoadingMediaItemAtIndexPath:indexPath];
    }
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"MediaCell" forIndexPath:indexPath];
    
    // Always configure the cell for the correct item
    // Remove any existing content first
    for (UIView *subview in cell.contentView.subviews) {
        [subview removeFromSuperview];
    }

    UIView *cardView = [[UIView alloc] initWithFrame:cell.contentView.bounds];
    cardView.frame = CGRectInset(cardView.frame, 5, 5);
    cardView.backgroundColor = [UIColor whiteColor];
    cardView.layer.cornerRadius = 20;

    if (self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark) {
        cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        cardView.layer.shadowOpacity = 0.5;
        cardView.layer.shadowOffset = CGSizeMake(0, 0);
        cardView.layer.shadowRadius = 5;
    }

    [cell.contentView addSubview:cardView];

    // Determine if this is a regular media item or HD video
    BOOL isHDVideo = indexPath.item >= self.mediaItems.count;
    NSInteger videoIndex = indexPath.item - self.mediaItems.count;
    
    if (isHDVideo) {
        // For HD videos, create the complete cell layout once
        [self setupHDVideoCell:cardView atIndex:videoIndex];
    } else {
        // For regular media items
        [self setupRegularMediaCell:cardView atIndex:indexPath.item];
    }

    CAShapeLayer *borderLayer = [CAShapeLayer layer];
    borderLayer.path = [UIBezierPath bezierPathWithRoundedRect:cardView.bounds cornerRadius:20].CGPath;
    borderLayer.lineWidth = 3.0;
    borderLayer.strokeColor = [ThetaHelper iotaPinkColor].CGColor;
    borderLayer.fillColor = [UIColor clearColor].CGColor;
    borderLayer.frame = cardView.bounds;

    BOOL isSelected = NO;
    if (isHDVideo) {
        isSelected = [self.selectedVideoIndexes containsObject:@(videoIndex)];
    } else {
        isSelected = [self.selectedIndexes containsObject:@(indexPath.item)];
    }
    
    if (isSelected) {
        [cardView.layer addSublayer:borderLayer];
        NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
        self.instructionLabel.text = [NSString stringWithFormat:@"Select which items to download. (%ld/%ld)", totalSelected, self.count];
    } else {
        [borderLayer removeFromSuperlayer];
        NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
        self.instructionLabel.text = [NSString stringWithFormat:@"Select which items to download. (%ld/%ld)", totalSelected, self.count];
    }

    return cell;
}

- (void)showCompletionToast:(CustomToastView *)progressToast completed:(NSInteger)completed total:(NSInteger)total failed:(NSInteger)failed {
    if (progressToast) {
        NSString *title = @"Download Complete!";
        NSString *subtitle = @"";
        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
        if (saveMethod == 0) {
            subtitle = [NSString stringWithFormat:@"%ld items saved to camera roll", (long)completed];
        } else {
            subtitle = [NSString stringWithFormat:@"%ld items saved to local folder", (long)completed];
        }
        UIImage *icon = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        
        if (failed > 0) {
            title = @"Download Finished";
            subtitle = [NSString stringWithFormat:@"%ld saved, %ld failed", (long)completed, (long)failed];
            icon = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        }
        
        [progressToast completeProgressWithTitle:title subtitle:subtitle icon:icon url:[NSURL URLWithString:@"photos-redirect://"]];
    }

    // Allow new downloads after completion
    [MediaSelectionViewController setDownloadInProgress:NO];
}



- (void)setupVideoPlayerLayer:(UIView *)cardView withPlayer:(AVPlayer *)player {
    // Remove any existing video player layers
    for (CALayer *layer in cardView.layer.sublayers) {
        if ([layer isKindOfClass:[AVPlayerLayer class]]) {
            [layer removeFromSuperlayer];
        }
    }
    
    // Create player layer
    AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    playerLayer.frame = cardView.bounds;
    playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    playerLayer.cornerRadius = 8.0;
    playerLayer.masksToBounds = YES;
    
    // Add player layer to card view
    [cardView.layer addSublayer:playerLayer];
    
    // Ensure player is muted and set up for looping
    player.muted = YES;
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    // Remove any existing observers for this player
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem];
    
    // Set up looping with a unique observer
    __weak typeof(self) weakSelf = self;
    __weak typeof(player) weakPlayer = player;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                    object:player.currentItem
                                                                     queue:[NSOperationQueue mainQueue]
                                                                usingBlock:^(NSNotification *notification) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakPlayer && weakPlayer.currentItem) {
                [weakPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
                    if (finished) {
                        [weakPlayer play];
                    }
                }];
            }
        });
    }];
    
    // Store the observer reference to avoid memory leaks
    objc_setAssociatedObject(player, "loopObserver", observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Start playing
    [player play];
}

- (void)cleanupVideoPlayer:(AVPlayer *)player {
    if (player) {
        // Remove the loop observer
        id observer = objc_getAssociatedObject(player, "loopObserver");
        if (observer) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            objc_setAssociatedObject(player, "loopObserver", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        
        // Stop the player
        [player pause];
    }
}

- (void)setupHDVideoCell:(UIView *)cardView atIndex:(NSInteger)videoIndex {
    // Check if we have a cached video player for this index
    NSString *playerKey = [NSString stringWithFormat:@"video_player_%ld", (long)videoIndex];
    AVPlayer *cachedPlayer = [self.previewCache objectForKey:playerKey];
    
    // Create image view for HD video
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:cardView.bounds];
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.layer.cornerRadius = 20;
    [cardView addSubview:imageView];
    
    // Show placeholder with gradient background
    imageView.image = [UIImage systemImageNamed:@"play.circle.fill"];
    imageView.tintColor = [UIColor whiteColor];
    
    // Create gradient background
    CAGradientLayer *videoGradientLayer = [CAGradientLayer layer];
    videoGradientLayer.frame = imageView.bounds;
    videoGradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.15 green:0.15 blue:0.25 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.15 alpha:1.0].CGColor
    ];
    videoGradientLayer.startPoint = CGPointMake(0, 0);
    videoGradientLayer.endPoint = CGPointMake(1, 1);
    [imageView.layer insertSublayer:videoGradientLayer atIndex:0];
    
    // Add "HD VIDEO" text
    UILabel *hdLabel = [[UILabel alloc] init];
    hdLabel.text = @"HD VIDEO";
    hdLabel.font = [UIFont boldSystemFontOfSize:12];
    hdLabel.textColor = [UIColor whiteColor];
    hdLabel.textAlignment = NSTextAlignmentCenter;
    hdLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cardView addSubview:hdLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [hdLabel.centerXAnchor constraintEqualToAnchor:cardView.centerXAnchor],
        [hdLabel.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor constant:-8]
    ]];
    
    // Set up video player for playback (use cached player if available)
    if (cachedPlayer) {
        [self setupVideoPlayerLayer:cardView withPlayer:cachedPlayer];
    } else {
        [self setupVideoPlayerForCell:cardView atIndex:videoIndex];
    }
}

- (void)setupRegularMediaCell:(UIView *)cardView atIndex:(NSInteger)mediaIndex {
    NSDictionary *mediaItem = self.mediaItems[mediaIndex];
    NSString *urlString = mediaItem[@"url"];
    NSURL *url = [NSURL URLWithString:urlString];
    
    // Create image view
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:cardView.bounds];
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.layer.cornerRadius = 20;
    imageView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    [cardView addSubview:imageView];
    
    // Prefer a real cached bitmap. Never permanently cache SF Symbol placeholders —
    // that blocked async preview downloads and left the carousel looking empty.
    UIImage *cachedImage = urlString.length ? [self.previewCache objectForKey:urlString] : nil;
    UIImage *dictPreview = mediaItem[@"preview"];
    if ([cachedImage isKindOfClass:[UIImage class]] && !ThetaPreviewImageIsPlaceholder(cachedImage)) {
        imageView.image = cachedImage;
    } else if ([dictPreview isKindOfClass:[UIImage class]] && !ThetaPreviewImageIsPlaceholder(dictPreview)) {
        imageView.image = dictPreview;
        if (urlString.length) [self.previewCache setObject:dictPreview forKey:urlString];
    } else {
        imageView.image = ThetaPreviewImageIsPlaceholder(dictPreview) ? dictPreview : [UIImage systemImageNamed:@"photo"];
        imageView.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
        imageView.contentMode = UIViewContentModeCenter;
        if (urlString.length) {
            [self startLoadingMediaItemAtIndexPath:[NSIndexPath indexPathForItem:mediaIndex inSection:0]];
        }
    }
    
    // Set up video player if it's a video
    NSString *path = url.path.lowercaseString ?: @"";
    BOOL looksVideo = [url.pathExtension.lowercaseString isEqualToString:@"mp4"]
        || [url.pathExtension.lowercaseString isEqualToString:@"mov"]
        || [path containsString:@".mp4"]
        || [mediaItem[@"isVideo"] boolValue];
    if (looksVideo && url) {
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        AVPlayer *player = self.videoPlayersCache[urlString];
        if (!player) {
            player = [[AVPlayer alloc] initWithURL:url];
            self.videoPlayersCache[urlString] = player;
        }

        AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
        playerLayer.frame = cardView.bounds;
        playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        playerLayer.cornerRadius = 20;
        playerLayer.masksToBounds = YES;
        player.volume = 0;
        [cardView.layer addSublayer:playerLayer];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidReachEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem];

        [player play];
    }
}

- (void)collectionView:(UICollectionView *)collectionView prefetchItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    for (NSIndexPath *indexPath in indexPaths) {
        [self startLoadingMediaItemAtIndexPath:indexPath];
    }
}

- (void)collectionView:(UICollectionView *)collectionView cancelPrefetchingForItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    for (NSIndexPath *indexPath in indexPaths) {
        [self cancelLoadingMediaItemAtIndexPath:indexPath];
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *playerItem = [notification object];
    NSArray *visibleCells = [self.collectionView visibleCells];
    for (UICollectionViewCell *cell in visibleCells) {
        AVPlayer *player = objc_getAssociatedObject(cell, playerKey);
        if (player && player.currentItem == playerItem) {
            [player seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
                if (finished) {
                    [player play];
                }
            }];
            break;
        }
    }
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isHDVideo = indexPath.item >= self.mediaItems.count;
    NSInteger videoIndex = indexPath.item - self.mediaItems.count;
    
    NSLog(@"Selection changed - item: %ld, isHDVideo: %@, videoIndex: %ld", (long)indexPath.item, isHDVideo ? @"YES" : @"NO", (long)videoIndex);
    
    if (isHDVideo) {
        NSNumber *index = @(videoIndex);
        if ([self.selectedVideoIndexes containsObject:index]) {
            [self.selectedVideoIndexes removeObject:index];
            NSLog(@"Deselected HD video %ld", (long)videoIndex);
        } else {
            [self.selectedVideoIndexes addObject:index];
            NSLog(@"Selected HD video %ld", (long)videoIndex);
        }
    } else {
        NSNumber *index = @(indexPath.item);
        if ([self.selectedIndexes containsObject:index]) {
            [self.selectedIndexes removeObject:index];
            NSLog(@"Deselected regular media %ld", (long)indexPath.item);
        } else {
            [self.selectedIndexes addObject:index];
            NSLog(@"Selected regular media %ld", (long)indexPath.item);
        }
    }
    
    NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
    NSLog(@"Total selected: %ld (regular: %ld, videos: %ld)", (long)totalSelected, (long)self.selectedIndexes.count, (long)self.selectedVideoIndexes.count);
    
    self.downloadButton.enabled = totalSelected > 0;
    [self updateSelectAllButtonTitle];

    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    [self updateBorderLayerForCell:cell atIndexPath:indexPath];
    
    [self updateInstructionLabel];
}

- (void)updateSelectAllButtonTitle {
    NSInteger totalItems = self.mediaItems.count + self.hdVideos.count;
    NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
    
    UIBarButtonItem *selectAllBarButton = self.navigationItem.leftBarButtonItems[1];
    if (totalSelected == totalItems) {
        selectAllBarButton.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    } else {
        selectAllBarButton.image = [UIImage systemImageNamed:@"checkmark.circle"];
    }
    
    [self updateInstructionLabel];
}

- (void)updateInstructionLabel {
    NSInteger totalItems = self.mediaItems.count + self.hdVideos.count;
    NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
    NSString *labelText = [NSString stringWithFormat:@"Select which items to download. (%ld/%ld)", totalSelected, totalItems];
    self.instructionLabel.text = labelText;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Update instruction label when scrolling to ensure it stays correct
    [self updateInstructionLabel];
}

- (void)selectAllButtonTapped {
    NSInteger totalItems = self.mediaItems.count + self.hdVideos.count;
    NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
    
    if (totalSelected == totalItems) {
        // Deselect all
        [self.selectedIndexes removeAllObjects];
        [self.selectedVideoIndexes removeAllObjects];
    } else {
        // Select all
        [self.selectedIndexes removeAllObjects];
        [self.selectedVideoIndexes removeAllObjects];
        
        for (NSInteger i = 0; i < self.mediaItems.count; i++) {
            [self.selectedIndexes addObject:@(i)];
        }
        for (NSInteger i = 0; i < self.hdVideos.count; i++) {
            [self.selectedVideoIndexes addObject:@(i)];
        }
    }
    
    NSInteger newTotalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
    self.downloadButton.enabled = newTotalSelected > 0;
    [self updateSelectAllButtonTitle];

    for (NSIndexPath *indexPath in [self.collectionView indexPathsForVisibleItems]) {
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        [self updateBorderLayerForCell:cell atIndexPath:indexPath];
    }
    
    [self updateInstructionLabel];
}

- (void)updateBorderLayerForCell:(UICollectionViewCell *)cell atIndexPath:(NSIndexPath *)indexPath {
    UIView *cardView = cell.contentView.subviews.firstObject;
    CAShapeLayer *borderLayer = nil;

    for (CALayer *layer in cardView.layer.sublayers) {
        if ([layer isKindOfClass:[CAShapeLayer class]]) {
            borderLayer = (CAShapeLayer *)layer;
            break;
        }
    }

    if (!borderLayer) {
        borderLayer = [CAShapeLayer layer];
        borderLayer.path = [UIBezierPath bezierPathWithRoundedRect:cardView.bounds cornerRadius:20].CGPath;
        borderLayer.lineWidth = 3.0;
        borderLayer.strokeColor = [ThetaHelper iotaPinkColor].CGColor;
        borderLayer.fillColor = [UIColor clearColor].CGColor;
        borderLayer.frame = cardView.bounds;
    }

    BOOL isHDVideo = indexPath.item >= self.mediaItems.count;
    NSInteger videoIndex = indexPath.item - self.mediaItems.count;
    
    BOOL isSelected = NO;
    if (isHDVideo) {
        isSelected = [self.selectedVideoIndexes containsObject:@(videoIndex)];
    } else {
        isSelected = [self.selectedIndexes containsObject:@(indexPath.item)];
    }

    if (isSelected) {
        [cardView.layer addSublayer:borderLayer];
    } else {
        [borderLayer removeFromSuperlayer];
    }
    
    // Don't update the instruction label here - it should only be updated when selections actually change
}

- (void)dismissView {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)downloadSelectedItems {
    NSInteger totalSelected = self.selectedIndexes.count + self.selectedVideoIndexes.count;
    if (totalSelected == 0) {
        [self showToastWithTitle:@"No items selected" subtitle:@"Please select items to download" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] seconds:3 openURL:nil];
        return;
    }

    // Enforce single active download
    if ([MediaSelectionViewController isDownloadInProgress]) {
        UIImage *hourglass = [UIImage systemImageNamed:@"hourglass"];
        hourglass = [hourglass imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        hourglass = [hourglass imageWithTintColor:[ThetaHelper iotaPinkColor]];
        [self showToastWithTitle:@"Download in progress!" subtitle:@"Please wait for download to finish." icon:hourglass seconds:3 openURL:nil];
        return;
    }
    [MediaSelectionViewController setDownloadInProgress:YES];

    // dismiss view controller
    [self dismissViewControllerAnimated:YES completion:nil];
    
    // Show initial progress toast
    CustomToastView *progressToast = [CustomToastView showProgressToastWithTitle:@"Starting download..." subtitle:@"Preparing to download selected items"];
    
    // Separate regular media and video items
    NSArray *selectedRegularItems = [self.selectedIndexes allObjects];
    NSMutableArray<IGVideo *> *selectedHDVideos = [NSMutableArray array];
    for (NSNumber *index in self.selectedVideoIndexes) {
        if (index.intValue < self.hdVideos.count) {
            [selectedHDVideos addObject:self.hdVideos[index.intValue]];
        }
    }
    
    NSInteger totalItems = selectedRegularItems.count + selectedHDVideos.count;
    __block NSInteger completedItems = 0;
    __block NSInteger failedItems = 0;
    
    // Update toast to show we're starting with photos
    if (selectedRegularItems.count > 0) {
        [progressToast updateProgressWithTitle:@"Downloading photos..." subtitle:[NSString stringWithFormat:@"Processing %ld photos first", (long)selectedRegularItems.count]];
    }
    
    // Download regular media items first (photos)
    if (selectedRegularItems.count > 0) {
        NSMutableArray<NSString *> *downloadedFilePaths = [NSMutableArray array];
        NSMutableArray<NSString *> *fileExtensions = [NSMutableArray array];
        
        dispatch_group_t group = dispatch_group_create();
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 15;

        for (NSInteger i = 0; i < selectedRegularItems.count; i++) {
            NSNumber *index = selectedRegularItems[i];
            NSDictionary *media = self.mediaItems[index.intValue];
            NSURL *url = [NSURL URLWithString:media[@"url"]];
            
            dispatch_group_enter(group);
            [queue addOperationWithBlock:^{
                [self downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension) {
                    if (filePath) {
                        @synchronized (downloadedFilePaths) {
                            [downloadedFilePaths addObject:filePath];
                            [fileExtensions addObject:fileExtension];
                        }
                    }
                    
                    completedItems++;
                    float progress = (float)completedItems / (float)totalItems;
                    
                    // Update toast with photo progress
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [progressToast updateProgressWithTitle:@"Downloading photos..." subtitle:[NSString stringWithFormat:@"%ld of %ld photos completed", (long)completedItems, (long)selectedRegularItems.count]];
                    });
                    
                    dispatch_group_leave(group);
                }];
            }];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [self saveFilesToCameraRoll:downloadedFilePaths extensions:fileExtensions suppressToast:YES];
            
            // If all photos are done, start videos
            if (selectedHDVideos.count > 0) {
                [progressToast updateProgressWithTitle:@"Downloading videos..." subtitle:[NSString stringWithFormat:@"Processing %ld videos", (long)selectedHDVideos.count]];
                
                // Start downloading videos
                [self downloadHDVideosBulk:selectedHDVideos progressToast:progressToast completed:completedItems total:totalItems failed:failedItems];
            } else {
                [self showCompletionToast:progressToast completed:completedItems total:totalItems failed:failedItems];
                [self dismissViewControllerAnimated:YES completion:nil];
            }
        });
    } else if (selectedHDVideos.count > 0) {
        // If no photos, start videos immediately
        [progressToast updateProgressWithTitle:@"Downloading videos..." subtitle:[NSString stringWithFormat:@"Processing %ld videos", (long)selectedHDVideos.count]];
        [self downloadHDVideosBulk:selectedHDVideos progressToast:progressToast completed:completedItems total:totalItems failed:failedItems];
    }
}

- (void)downloadMediaToTemp:(NSURL *)url completion:(void(^)(NSString *filePath, NSString *fileExtension))completion {
    // Respect save method: 0 = camera roll, 1 = local folder
    NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
    if (saveMethod == 0) {
        // Check photo library permission first
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
        if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authorizationStatus) {
                if (authorizationStatus == PHAuthorizationStatusAuthorized) {
                    [self performDownloadWithURL:url completion:completion];
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (ENABLED(@"Show Banners")) {
                            [self showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] seconds:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                        }
                    });
                    if (completion) {
                        completion(nil, nil);
                    }
                }
            }];
        } else if (status == PHAuthorizationStatusAuthorized) {
            [self performDownloadWithURL:url completion:completion];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ENABLED(@"Show Banners")) {
                    [self showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] seconds:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                }
            });
            if (completion) {
                completion(nil, nil);
            }
        }
    } else {
        // Local folder mode doesn't require Photos permission
        [self performDownloadWithURL:url completion:completion];
    }
}

- (void)saveMediaToPhotoLibrary:(NSString *)filePath fileExtension:(NSString *)fileExtension completion:(void(^)(NSString *filePath, NSString *fileExtension))completion {
    if ([fileExtension.lowercaseString isEqualToString:@"mp4"] || [fileExtension.lowercaseString isEqualToString:@"mov"]) {
        // Save video
        UISaveVideoAtPathToSavedPhotosAlbum(filePath, self, @selector(video:didFinishSavingWithError:contextInfo:), (__bridge_retained void *)(^{
            // Clean up temporary file
            NSError *deleteError;
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:&deleteError];
            if (deleteError) {
                NSLog(@"Error deleting temporary file: %@", deleteError);
            }
            
            if (completion) {
                completion(filePath, fileExtension);
            }
        }));
    } else {
        // Save image
        UIImage *image = [UIImage imageWithContentsOfFile:filePath];
        if (image) {
            UIImageWriteToSavedPhotosAlbum(image, self, @selector(image:didFinishSavingWithError:contextInfo:), (__bridge_retained void *)(^{
                // Clean up temporary file
                NSError *deleteError;
                [[NSFileManager defaultManager] removeItemAtPath:filePath error:&deleteError];
                if (deleteError) {
                    NSLog(@"Error deleting temporary file: %@", deleteError);
                }
                
                if (completion) {
                    completion(filePath, fileExtension);
                }
            }));
        } else {
            NSLog(@"Failed to create image from file: %@", filePath);
            if (completion) {
                completion(nil, fileExtension);
            }
        }
    }
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        NSLog(@"Error saving image: %@", error);
    }
    
    if (contextInfo) {
        void (^completion)(void) = (__bridge_transfer void (^)(void))contextInfo;
        completion();
    }
}

- (void)video:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        NSLog(@"Error saving video: %@", error);
    }
    
    if (contextInfo) {
        void (^completion)(void) = (__bridge_transfer void (^)(void))contextInfo;
        completion();
    }
}

- (void)performDownloadWithURL:(NSURL *)url completion:(void(^)(NSString *filePath, NSString *fileExtension))completion {
    @try {
        NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"Download error: %@", error);
                if (completion) {
                    completion(nil, nil);
                }
                return;
            }

            NSError *moveError;
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *fileExtension = [[url pathExtension] lowercaseString];
            if (fileExtension.length == 0) {
                NSString *mime = [[response MIMEType] lowercaseString];
                if ([mime hasPrefix:@"image/"]) {
                    if ([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/jpg"]) fileExtension = @"jpg";
                    else if ([mime isEqualToString:@"image/png"]) fileExtension = @"png";
                    else if ([mime isEqualToString:@"image/heic"] || [mime isEqualToString:@"image/heif"]) fileExtension = @"heic";
                    else if ([mime isEqualToString:@"image/webp"]) fileExtension = @"webp";
                    else fileExtension = @"jpg";
                } else if ([mime hasPrefix:@"video/"]) {
                    if ([mime isEqualToString:@"video/quicktime"]) fileExtension = @"mov";
                    else if ([mime isEqualToString:@"video/mp4"]) fileExtension = @"mp4";
                    else fileExtension = @"mp4";
                } else if ([mime hasPrefix:@"audio/"]) {
                    if ([mime isEqualToString:@"audio/aac"]) fileExtension = @"aac";
                    else if ([mime isEqualToString:@"audio/m4a"] || [mime isEqualToString:@"audio/mp4"]) fileExtension = @"m4a";
                    else if ([mime isEqualToString:@"audio/mpeg"]) fileExtension = @"mp3";
                    else fileExtension = @"m4a";
                } else {
                    fileExtension = @"mp4";
                }
            }
            NSString *uuidPart = [[NSUUID UUID] UUIDString];
            NSString *newFilename = fileExtension.length > 0 ? [NSString stringWithFormat:@"media-%@.%@", uuidPart, fileExtension] : [NSString stringWithFormat:@"media-%@", uuidPart];
            NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
            
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&moveError];
            if (moveError) {
                NSLog(@"Error moving file: %@", moveError);
                if (completion) {
                    completion(nil, nil);
                }
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                if (saveMethod == 0) {
                    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
                    if (status == PHAuthorizationStatusNotDetermined) {
                        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
                            if (newStatus == PHAuthorizationStatusAuthorized) {
                                [self saveMediaToPhotoLibrary:permanentFilePath fileExtension:fileExtension completion:completion];
                            } else {
                                NSLog(@"Photo library permission denied");
                                if (completion) {
                                    completion(nil, fileExtension);
                                }
                                // Clean up temporary file
                                NSError *deleteError;
                                [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:&deleteError];
                                if (deleteError) {
                                    NSLog(@"Error deleting temporary file: %@", deleteError);
                                }
                            }
                        }];
                    } else if (status == PHAuthorizationStatusAuthorized) {
                        [self saveMediaToPhotoLibrary:permanentFilePath fileExtension:fileExtension completion:completion];
                    } else {
                        NSLog(@"Photo library permission denied");
                        if (completion) {
                            completion(nil, fileExtension);
                        }
                        // Clean up temporary file
                        NSError *deleteError;
                        [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:&deleteError];
                        if (deleteError) {
                            NSLog(@"Error deleting temporary file: %@", deleteError);
                        }
                    }
                } else {
                    // Local folder mode: move file into Documents/AudioNotes
                    NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                    BOOL isDir = NO;
                    if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                        [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[permanentFilePath lastPathComponent]];
                    NSError *moveErr = nil;
                    if (![[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:&moveErr]) {
                        // Fallback to unique name
                        NSString *base = [[permanentFilePath lastPathComponent] stringByDeletingPathExtension];
                        NSString *ext = [permanentFilePath pathExtension];
                        NSString *unique = [NSString stringWithFormat:@"%@-%@.%@", base, [[NSUUID UUID] UUIDString], ext];
                        destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                        [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
                    }
                    if (completion) {
                        completion(destPath, fileExtension);
                    }
                }
            });
        }];
        [downloadTask resume];
    } @catch (NSException *exception) {
        NSLog(@"Error downloading media: %@", exception);
        if (completion) {
            completion(nil, nil);
        }
    }
}

// Always download and place the file into Documents/AudioNotes, regardless of Save Method.
- (void)performDownloadToAudioNotesWithURL:(NSURL *)url completion:(void(^)(NSString *filePath, NSString *fileExtension))completion {
    @try {
        NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"Download error: %@", error);
                if (completion) {
                    completion(nil, nil);
                }
                return;
            }

            NSError *moveError;
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *fileExtension = [[url pathExtension] lowercaseString];
            if (fileExtension.length == 0) {
                NSString *mime = [[response MIMEType] lowercaseString];
                if ([mime hasPrefix:@"image/"]) {
                    if ([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/jpg"]) fileExtension = @"jpg";
                    else if ([mime isEqualToString:@"image/png"]) fileExtension = @"png";
                    else if ([mime isEqualToString:@"image/heic"] || [mime isEqualToString:@"image/heif"]) fileExtension = @"heic";
                    else if ([mime isEqualToString:@"image/webp"]) fileExtension = @"webp";
                    else fileExtension = @"jpg";
                } else if ([mime hasPrefix:@"video/"]) {
                    if ([mime isEqualToString:@"video/quicktime"]) fileExtension = @"mov";
                    else if ([mime isEqualToString:@"video/mp4"]) fileExtension = @"mp4";
                    else fileExtension = @"mp4";
                } else if ([mime hasPrefix:@"audio/"]) {
                    if ([mime isEqualToString:@"audio/aac"]) fileExtension = @"aac";
                    else if ([mime isEqualToString:@"audio/m4a"] || [mime isEqualToString:@"audio/mp4"]) fileExtension = @"m4a";
                    else if ([mime isEqualToString:@"audio/mpeg"]) fileExtension = @"mp3";
                    else fileExtension = @"m4a";
                } else {
                    fileExtension = @"mp4";
                }
            }
            NSString *uuidPart = [[NSUUID UUID] UUIDString];
            NSString *newFilename = fileExtension.length > 0 ? [NSString stringWithFormat:@"media-%@.%@", uuidPart, fileExtension] : [NSString stringWithFormat:@"media-%@", uuidPart];
            NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];

            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&moveError];
            if (moveError) {
                NSLog(@"Error moving file: %@", moveError);
                if (completion) {
                    completion(nil, nil);
                }
                return;
            }

            // Move into Documents/AudioNotes (ensuring directory exists)
            NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[permanentFilePath lastPathComponent]];
            NSError *moveErr = nil;
            if (![[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:&moveErr]) {
                // Fallback to unique name
                NSString *base = [[permanentFilePath lastPathComponent] stringByDeletingPathExtension];
                NSString *ext = [permanentFilePath pathExtension];
                NSString *unique = [NSString stringWithFormat:@"%@-%@.%@", base, [[NSUUID UUID] UUIDString], ext];
                destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(destPath, fileExtension);
                }
            });
        }];
        [downloadTask resume];
    } @catch (NSException *exception) {
        NSLog(@"Error downloading media: %@", exception);
        if (completion) {
            completion(nil, nil);
        }
    }
}

// Batch save all files to camera roll in one transaction
- (void)saveFilesToCameraRoll:(NSArray<NSString *> *)filePaths extensions:(NSArray<NSString *> *)fileExtensions {
    [self saveFilesToCameraRoll:filePaths extensions:fileExtensions suppressToast:NO];
}

- (void)saveFilesToCameraRoll:(NSArray<NSString *> *)filePaths extensions:(NSArray<NSString *> *)fileExtensions suppressToast:(BOOL)suppressToast {
    static dispatch_source_t toastTimer = nil;
    static NSTimeInterval lastCallTime = 0;
    static NSTimeInterval debounceInterval = 1.0; // seconds

    if (filePaths.count == 0) return;
    NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
    if (saveMethod == 0) {
        PHPhotoLibrary *photoLibrary = [PHPhotoLibrary sharedPhotoLibrary];
        [photoLibrary performChanges:^{
            for (NSInteger i = 0; i < filePaths.count; i++) {
                NSString *filePath = filePaths[i];
                NSString *fileExtension = fileExtensions[i];
                if ([[fileExtension lowercaseString] isEqualToString:@"mp4"]) {
                    [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:filePath]];
                } else {
                    UIImage *image = [UIImage imageWithContentsOfFile:filePath];
                    if (image) {
                        [PHAssetChangeRequest creationRequestForAssetFromImage:image];
                    }
                }
            }
        } completionHandler:^(BOOL success, NSError *error) {
            for (NSString *filePath in filePaths) {
                [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    if (!suppressToast) {
                        lastCallTime = [[NSDate date] timeIntervalSince1970];
                        if (toastTimer) {
                            dispatch_source_cancel(toastTimer);
                            toastTimer = nil;
                        }
                        toastTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
                        dispatch_source_set_timer(toastTimer,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(debounceInterval * NSEC_PER_SEC)),
                            DISPATCH_TIME_FOREVER, 0);
                        dispatch_source_set_event_handler(toastTimer, ^{
                            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                            if (now - lastCallTime >= debounceInterval) {
                                [self showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] seconds:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                                dispatch_source_cancel(toastTimer);
                                toastTimer = nil;
                            }
                        });
                        dispatch_resume(toastTimer);
                    }
                } else {
                    NSLog(@"Error saving batch: %@", error);
                }
            });
        }];
    } else {
        // Local folder mode: move files into Documents/AudioNotes
        NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
            [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        for (NSString *filePath in filePaths) {
            NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[filePath lastPathComponent]];
            NSError *moveErr = nil;
            if (![[NSFileManager defaultManager] moveItemAtPath:filePath toPath:destPath error:&moveErr]) {
                // Fallback to unique name
                NSString *base = [[filePath lastPathComponent] stringByDeletingPathExtension];
                NSString *ext = [filePath pathExtension];
                NSString *unique = [NSString stringWithFormat:@"%@-%@.%@", base, [[NSUUID UUID] UUIDString], ext];
                destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                [[NSFileManager defaultManager] moveItemAtPath:filePath toPath:destPath error:nil];
            }
        }
        if (!suppressToast && ENABLED(@"Show Banners")) {
            [self showToastWithTitle:@"Saved!" subtitle:@"Saved to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] seconds:3 openURL:nil];
        }
    }
}

- (UIButton *)selectAllButton {
    if (!_selectAllButton) {
        _selectAllButton = [[UIButton alloc] initWithFrame:CGRectMake(0, 0, 150, 30)];
        [_selectAllButton setTitle:@"Select All" forState:UIControlStateNormal];
        [_selectAllButton addTarget:self action:@selector(selectAllButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return _selectAllButton;
}

#pragma mark - HD Video Download Methods

- (void)downloadHDVideosBulk:(NSArray<IGVideo *> *)videos progressToast:(CustomToastView *)progressToast completed:(NSInteger)completedItems total:(NSInteger)totalItems failed:(NSInteger)failedItems {
    if (!videos || videos.count == 0) {
        return;
    }
    
    if (!progressToast) {
        progressToast = [CustomToastView showProgressToastWithTitle:@"Bulk saving videos!" subtitle:[NSString stringWithFormat:@"Preparing %lu videos...", (unsigned long)videos.count]];
    }
    
    static const NSInteger maxConcurrentDownloads = 3;
    static const NSInteger maxConcurrentTranscoding = 2;
    
    dispatch_semaphore_t downloadSemaphore = dispatch_semaphore_create(maxConcurrentDownloads);
    dispatch_semaphore_t transcodeSemaphore = dispatch_semaphore_create(maxConcurrentTranscoding);
    
    __block NSInteger completedVideos = completedItems;
    __block NSInteger totalVideos = totalItems;
    __block NSInteger failedVideos = failedItems;
    
    __block NSTimeInterval bulkProcessStartTime = [[NSDate date] timeIntervalSince1970];
    
    dispatch_queue_t statsQueue = dispatch_queue_create("com.theta.bulkstats", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t processingQueue = dispatch_queue_create("com.theta.bulkdownload", DISPATCH_QUEUE_CONCURRENT);
    
    // Track progress for each video
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *videoProgress = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < videos.count; i++) {
        videoProgress[@(i)] = [NSMutableDictionary dictionaryWithDictionary:@{
            @"state": @"pending",  // pending, downloading, transcoding, saving, done
            @"progress": @(0.0),
            @"status": @"Waiting..."
        }];
    }
    
    // Helper to format multi-line progress display
    NSString* (^formatProgressDisplay)(void) = ^NSString*() {
        
        dispatch_sync(statsQueue, ^{
            // Show active videos (not pending or done)
            for (NSInteger i = 0; i < videos.count; i++) {
                NSDictionary *info = videoProgress[@(i)];
                NSString *state = info[@"state"];
                
                if (![state isEqualToString:@"pending"] && ![state isEqualToString:@"done"]) {
                    float vidProgress = [info[@"progress"] floatValue];
                    // Update per-item UIProgressView via CustomToastView helper
                    // Title is ignored (we render a bullet only), so pass nil
                    [progressToast updatePerItemProgressAtIndex:i title:nil progress:vidProgress];
                }
            }
            
            // If nothing active, we can optionally show a simple summary in subtitle
            if (completedVideos >= totalVideos && totalVideos > 0) {
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - bulkProcessStartTime;
                NSString *timeStr = @"";
                
                if (completedVideos > 0 && totalVideos > 0 && elapsed > 3.0) {
                    double percentage = (double)completedVideos / (double)totalVideos * 100.0;
                    if (percentage > 0.5) {
                        NSTimeInterval estimatedTotal = elapsed / (percentage / 100.0);
                        NSTimeInterval remaining = estimatedTotal - elapsed;
                        
                        if (remaining > 0) {
                            if (remaining < 60) {
                                timeStr = [NSString stringWithFormat:@" • %ds left", (int)remaining];
                            } else if (remaining < 3600) {
                                int minutes = (int)(remaining / 60);
                                int seconds = (int)fmod(remaining, 60);
                                timeStr = [NSString stringWithFormat:@" • %dm %ds left", minutes, seconds];
                            }
                        }
                    }
                }
                
                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                //NSString *summary = [NSString stringWithFormat:@"Completed: %ld/%ld%@", (long)completedVideos, (long)totalVideos, timeStr];
                NSString *summary;
                if (saveMethod == 0) {
                    summary = [NSString stringWithFormat:@"Saved %ld/%ld to camera roll%@", (long)completedVideos, (long)totalVideos, timeStr];
                } else {
                    summary = [NSString stringWithFormat:@"Saved %ld/%ld to local folder%@", (long)completedVideos, (long)totalVideos, timeStr];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [progressToast updateProgressWithTitle:@"Saved!"
                                                  subtitle:summary];
                });
            }
        });
        
        return @""; // not used as text anymore
    };
    
    // Helper block to calculate time string for individual video progress
    NSString* (^formatTimeString)(NSTimeInterval) = ^NSString*(NSTimeInterval seconds) {
        if (seconds < 60) {
            return [NSString stringWithFormat:@"%ds left", (int)seconds];
        } else if (seconds < 3600) {
            int minutes = (int)(seconds / 60);
            int secs = (int)fmod(seconds, 60);
            return [NSString stringWithFormat:@"%dm %ds left", minutes, secs];
        } else {
            int hours = (int)(seconds / 3600);
            int minutes = (int)(fmod(seconds, 3600) / 60);
            return [NSString stringWithFormat:@"%dh %dm left", hours, minutes];
        }
    };
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    
    // Configure per-item UIProgressView rows in the toast (one bar per video)
    dispatch_async(dispatch_get_main_queue(), ^{
        [progressToast setupPerItemProgressWithCount:videos.count];
    });
    
    // Process each video
    for (NSInteger i = 0; i < videos.count; i++) {
        IGVideo *video = videos[i];
        NSInteger videoIndex = i;
        
        dispatch_async(processingQueue, ^{
            // Wait for available download slot
            dispatch_semaphore_wait(downloadSemaphore, DISPATCH_TIME_FOREVER);
            
            @autoreleasepool {
                // Update state to downloading
                dispatch_sync(statsQueue, ^{
                    videoProgress[@(videoIndex)][@"state"] = @"downloading";
                    videoProgress[@(videoIndex)][@"status"] = @"Starting download...";
                });
                formatProgressDisplay(); // Updates toast internally with progress
                
                NSData *videoData = [video valueForKey:@"dashManifestData"];
                if (!videoData) {
                    dispatch_semaphore_signal(downloadSemaphore);
                    dispatch_async(statsQueue, ^{
                        videoProgress[@(videoIndex)][@"state"] = @"done";
                        videoProgress[@(videoIndex)][@"status"] = @"Failed";
                        failedVideos++;
                        completedVideos++;
                    });
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                    });
                    return;
                }
                
                NSString *videoManifest = [[NSString alloc] initWithData:videoData encoding:NSUTF8StringEncoding];
                NSString *videoURLString = IGDashManifestBestCompatibleURL(videoManifest);
                NSString *audioURLString = IGDashManifestBestAudioURL(videoManifest);
                
                if (!videoURLString.length || ![NSURL URLWithString:videoURLString]) {
                    dispatch_semaphore_signal(downloadSemaphore);
                    dispatch_async(statsQueue, ^{
                        videoProgress[@(videoIndex)][@"state"] = @"done";
                        videoProgress[@(videoIndex)][@"status"] = @"Failed";
                        failedVideos++;
                        completedVideos++;
                    });
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                    });
                    return;
                }
                
                NSURL *audioTestURL = audioURLString.length > 0 ? [NSURL URLWithString:audioURLString] : nil;
                __block BOOL hasAudio = (audioURLString.length > 0 && audioTestURL != nil);
                
                NSString *videoPath = [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"bulk_video_%ld.mp4", (long)videoIndex]];
                __block NSString *audioPath = hasAudio ? [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"bulk_audio_%ld.m4a", (long)videoIndex]] : nil;
                
                // Remove any existing files
                if ([fm fileExistsAtPath:videoPath]) [fm removeItemAtPath:videoPath error:nil];
                if (audioPath && [fm fileExistsAtPath:audioPath]) [fm removeItemAtPath:audioPath error:nil];
                
                NSURLSession *session = [NSURLSession sharedSession];
                dispatch_group_t downloadGroup = dispatch_group_create();
                
                __block NSTimeInterval downloadStartTime = [[NSDate date] timeIntervalSince1970];
                
                // Download video
                dispatch_group_enter(downloadGroup);
                dispatch_sync(statsQueue, ^{
                    videoProgress[@(videoIndex)][@"status"] = @"Downloading video...";
                });
                formatProgressDisplay(); // Updates toast internally with progress
                
                NSURLSessionDownloadTask *videoTask = [session downloadTaskWithURL:[NSURL URLWithString:videoURLString] completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                    if (error || !location) {
                        NSLog(@"Error downloading video %ld: %@", (long)videoIndex, error);
                    } else {
                        [fm moveItemAtPath:location.path toPath:videoPath error:nil];
                    }
                    dispatch_group_leave(downloadGroup);
                }];
                [videoTask resume];
                
                // Download audio if available
                if (hasAudio) {
                    dispatch_group_enter(downloadGroup);
                    dispatch_sync(statsQueue, ^{
                        videoProgress[@(videoIndex)][@"status"] = @"Downloading audio...";
                    });
                    
                    NSURLSessionDownloadTask *audioTask = [session downloadTaskWithURL:[NSURL URLWithString:audioURLString] completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                        if (error || !location) {
                            NSLog(@"Error downloading audio %ld: %@", (long)videoIndex, error);
                        } else {
                            [fm moveItemAtPath:location.path toPath:audioPath error:nil];
                        }
                        dispatch_group_leave(downloadGroup);
                    }];
                    [audioTask resume];
                }
                
                // Wait for downloads to complete
                dispatch_group_wait(downloadGroup, DISPATCH_TIME_FOREVER);
                
                // Release download slot
                dispatch_semaphore_signal(downloadSemaphore);
                
                // Verify downloads (non-empty video)
                NSDictionary *downloadedVideoAttrs = [fm attributesOfItemAtPath:videoPath error:nil];
                if (![fm fileExistsAtPath:videoPath] || !downloadedVideoAttrs || [downloadedVideoAttrs fileSize] == 0) {
                    dispatch_async(statsQueue, ^{
                        videoProgress[@(videoIndex)][@"state"] = @"done";
                        videoProgress[@(videoIndex)][@"status"] = @"Download failed";
                        failedVideos++;
                        completedVideos++;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                            
                            if (completedVideos >= totalVideos) {
                                [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                [MediaSelectionViewController setDownloadInProgress:NO];
                            }
                        });
                    });
                    return;
                }
                if (hasAudio) {
                    NSString *preparedAudio = ThetaPrepareDashAudioForMerge(audioPath);
                    if (preparedAudio.length) {
                        audioPath = preparedAudio;
                    } else {
                        NSLog(@"Bulk %ld: audio file missing, empty, or undecodable; video only", (long)videoIndex);
                        hasAudio = NO;
                    }
                }
                
                // Detect video encoding
                AVAsset *videoAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
                NSArray<AVAssetTrack *> *videoTracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
                BOOL isAV1Video = NO;
                
                if (videoTracks.count > 0) {
                    AVAssetTrack *videoTrack = videoTracks[0];
                    NSArray *formatDescriptions = [videoTrack formatDescriptions];
                    if (formatDescriptions.count > 0) {
                        CMFormatDescriptionRef formatDesc = (__bridge CMFormatDescriptionRef)formatDescriptions[0];
                        FourCharCode codec = CMFormatDescriptionGetMediaSubType(formatDesc);
                        if (codec == 0x61763031) { // 'av01'
                            isAV1Video = YES;
                        }
                    }
                }
                
                // Wait for transcoding slot
                dispatch_semaphore_wait(transcodeSemaphore, DISPATCH_TIME_FOREVER);
                
                dispatch_sync(statsQueue, ^{
                    videoProgress[@(videoIndex)][@"state"] = @"transcoding";
                    videoProgress[@(videoIndex)][@"status"] = @"Processing...";
                });
                formatProgressDisplay(); // Updates toast internally with progress
                
                NSString *outputPath = [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"bulk_output_%ld.mp4", (long)videoIndex]];
                if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];
                
                __block NSTimeInterval transcodeStartTime = [[NSDate date] timeIntervalSince1970];
                
                if (isAV1Video) {
                    // Use AV1Transcoder for AV1 videos
                    NSError *transcodeError = nil;
                    BOOL transcodeSuccess = [AV1Transcoder transcodeAV1ToH264:videoPath
                                                                    outputPath:outputPath
                                                                     audioPath:audioPath
                                                                         error:&transcodeError
                                                                 progressBlock:^(NSString *status, float progress) {
                        // Update progress for this specific video
                        dispatch_sync(statsQueue, ^{
                            videoProgress[@(videoIndex)][@"progress"] = @(progress);
                            videoProgress[@(videoIndex)][@"status"] = @"Transcoding...";
                        });
                        
                        // Update UI periodically
                        static NSTimeInterval lastUIUpdate = 0;
                        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                        if (now - lastUIUpdate > 0.5) {
                            lastUIUpdate = now;
                            formatProgressDisplay(); // updates inline bars per item
                        }
                    }];
                    
                    dispatch_semaphore_signal(transcodeSemaphore);
                    
                    if (!transcodeSuccess) {
                        NSLog(@"AV1 transcoding failed for video %ld (%@); trying native export", (long)videoIndex, transcodeError);
                        if ([fm fileExistsAtPath:outputPath]) [fm removeItemAtPath:outputPath error:nil];
                        if (!ThetaExportPhotosCompatibleMP4(videoPath, audioPath, hasAudio, outputPath)) {
                            NSError *copyErr = nil;
                            if (![fm copyItemAtPath:videoPath toPath:outputPath error:&copyErr]) {
                                NSLog(@"Bulk %ld: could not copy original after transcode failure: %@", (long)videoIndex, copyErr);
                                [fm removeItemAtPath:videoPath error:nil];
                                if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                                dispatch_async(statsQueue, ^{
                                    videoProgress[@(videoIndex)][@"state"] = @"done";
                                    videoProgress[@(videoIndex)][@"status"] = @"Transcoding failed";
                                    failedVideos++;
                                    completedVideos++;
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                        if (completedVideos >= totalVideos) {
                                            [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                            [MediaSelectionViewController setDownloadInProgress:NO];
                                        }
                                    });
                                });
                                return;
                            }
                        }
                    }
                    
                } else {
                    dispatch_sync(statsQueue, ^{
                        videoProgress[@(videoIndex)][@"status"] = @"Merging...";
                    });
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                    });
                    
                    AVMutableComposition *composition = [AVMutableComposition composition];
                    AVMutableCompositionTrack *compositionVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
                    
                    AVAssetTrack *videoTrackForMerge = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
                    AVAsset *audioAssetForMerge = nil;
                    AVAssetTrack *audioTrackForMerge = nil;
                    if (hasAudio && audioPath && [fm fileExistsAtPath:audioPath]) {
                        audioAssetForMerge = [AVAsset assetWithURL:[NSURL fileURLWithPath:audioPath]];
                        audioTrackForMerge = [[audioAssetForMerge tracksWithMediaType:AVMediaTypeAudio] firstObject];
                    }
                    
                    CMTime videoDur = videoAsset.duration;
                    /* mergeDur is derived from videoDur, so falling back to videoDur cannot rescue a
                       bad value — and insertTimeRange: raises on an invalid range instead of
                       reporting through its error out-param. */
                    BOOL durationUsable = CMTIME_IS_NUMERIC(videoDur) && CMTIME_COMPARE_INLINE(videoDur, >, kCMTimeZero);
                    CMTime mergeDur = videoDur;
                    if (durationUsable && audioTrackForMerge && audioAssetForMerge && CMTIME_IS_NUMERIC(audioAssetForMerge.duration)
                        && CMTIME_COMPARE_INLINE(audioAssetForMerge.duration, >, kCMTimeZero)) {
                        mergeDur = CMTimeMinimum(videoDur, audioAssetForMerge.duration);
                    }
                    if (!CMTIME_IS_NUMERIC(mergeDur) || CMTIME_COMPARE_INLINE(mergeDur, <=, kCMTimeZero)) {
                        mergeDur = videoDur;
                    }
                    CMTimeRange mergeRange = CMTimeRangeMake(kCMTimeZero, mergeDur);
                    
                    NSError *videoInsertError = nil;
                    if (videoTrackForMerge) {
                        if (!durationUsable) {
                            videoInsertError = [NSError errorWithDomain:@"Theta" code:-10
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Unusable video duration"}];
                        } else {
                            [compositionVideoTrack insertTimeRange:mergeRange ofTrack:videoTrackForMerge atTime:kCMTimeZero error:&videoInsertError];
                        }
                        if (videoInsertError) {
                            NSLog(@"Error adding video track for video %ld: %@", (long)videoIndex, videoInsertError);
                            dispatch_semaphore_signal(transcodeSemaphore);
                            [fm removeItemAtPath:videoPath error:nil];
                            if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                            
                            dispatch_async(statsQueue, ^{
                                videoProgress[@(videoIndex)][@"state"] = @"done";
                                videoProgress[@(videoIndex)][@"status"] = @"Merge failed";
                                failedVideos++;
                                completedVideos++;
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                    
                                    if (completedVideos >= totalVideos) {
                                        [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                        [MediaSelectionViewController setDownloadInProgress:NO];
                                    }
                                });
                            });
                            return;
                        }
                    }
                    
                    if (audioTrackForMerge) {
                        AVMutableCompositionTrack *compositionAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                        NSError *audioInsertError = nil;
                        [compositionAudioTrack insertTimeRange:mergeRange ofTrack:audioTrackForMerge atTime:kCMTimeZero error:&audioInsertError];
                        if (audioInsertError) {
                            NSLog(@"Error adding audio track for video %ld: %@", (long)videoIndex, audioInsertError);
                        }
                    }
                    
                    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
                    exportSession.outputURL = [NSURL fileURLWithPath:outputPath];
                    BOOL canWriteMP4 = ThetaExportSessionSetFileType(exportSession, AVFileTypeMPEG4);
                    if ([exportSession respondsToSelector:@selector(setShouldOptimizeForNetworkUse:)]) {
                        exportSession.shouldOptimizeForNetworkUse = YES;
                    }
                    
                    dispatch_semaphore_t exportSemaphore = dispatch_semaphore_create(0);
                    if (canWriteMP4) {
                        [exportSession exportAsynchronouslyWithCompletionHandler:^{
                            dispatch_semaphore_signal(exportSemaphore);
                        }];
                        dispatch_semaphore_wait(exportSemaphore, DISPATCH_TIME_FOREVER);
                    } else {
                        NSLog(@"Bulk %ld: export session cannot write MPEG-4", (long)videoIndex);
                    }
                    
                    dispatch_semaphore_signal(transcodeSemaphore);
                    
                    if (!canWriteMP4 || exportSession.status != AVAssetExportSessionStatusCompleted) {
                        NSLog(@"Export failed for video %ld: %@", (long)videoIndex, exportSession.error);
                        
                        // Cleanup
                        [fm removeItemAtPath:videoPath error:nil];
                        if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                        
                        dispatch_async(statsQueue, ^{
                            failedVideos++;
                            completedVideos++;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                
                                if (completedVideos >= totalVideos) {
                                    [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                    [MediaSelectionViewController setDownloadInProgress:NO];
                                }
                            });
                        });
                        return;
                    }
                    
                }
                
                // Save to camera roll or local folder
                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                
                if (saveMethod == 0) {
                    // Save to camera roll
                    #ifdef SIDELOAD
                    // For sideload builds, copy to Caches and use ALAssetsLibrary
                    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
                    NSString *cachesDir = [paths firstObject];
                    NSString *cacheVideoPath = [cachesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"theta_bulk_%ld_%@.mp4", (long)videoIndex, [[NSUUID UUID] UUIDString]]];
                    
                    NSError *copyError = nil;
                    if ([fm copyItemAtPath:outputPath toPath:cacheVideoPath error:&copyError]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                        [library writeVideoAtPathToSavedPhotosAlbum:[NSURL fileURLWithPath:cacheVideoPath] completionBlock:^(NSURL *assetURL, NSError *error) {
                            // Cleanup
                            [fm removeItemAtPath:videoPath error:nil];
                            if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                            [fm removeItemAtPath:outputPath error:nil];
                            [fm removeItemAtPath:cacheVideoPath error:nil];
                            
                            dispatch_async(statsQueue, ^{
                                if (!error && assetURL) {
                                } else {
                                    NSLog(@"Failed to save video %ld: %@", (long)videoIndex, error);
                                    failedVideos++;
                                }
                                completedVideos++;
                                
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                    
                                    if (completedVideos >= totalVideos) {
                                        [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                        [MediaSelectionViewController setDownloadInProgress:NO];
                                    }
                                });
                            });
                        }];
#pragma clang diagnostic pop
                    } else {
                        NSLog(@"Failed to copy video %ld to Caches: %@", (long)videoIndex, copyError);
                        
                        // Cleanup
                        [fm removeItemAtPath:videoPath error:nil];
                        if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                        [fm removeItemAtPath:outputPath error:nil];
                        
                        dispatch_async(statsQueue, ^{
                            failedVideos++;
                            completedVideos++;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                
                                if (completedVideos >= totalVideos) {
                                    [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                    [MediaSelectionViewController setDownloadInProgress:NO];
                                }
                            });
                        });
                    }
                    #else
                    // Jailbreak: Photos import (creation-request path when available)
                    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
                    ThetaPhotoLibraryImportVideoFromURL(outputURL, ^(BOOL success, NSError *error) {
                        // Cleanup
                        [fm removeItemAtPath:videoPath error:nil];
                        if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                        [fm removeItemAtPath:outputPath error:nil];
                        
                        dispatch_async(statsQueue, ^{
                            if (success) {
                            } else {
                                NSLog(@"Failed to save video %ld: %@", (long)videoIndex, error);
                                failedVideos++;
                            }
                            completedVideos++;
                            
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                
                                if (completedVideos >= totalVideos) {
                                    [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                    [MediaSelectionViewController setDownloadInProgress:NO];
                                }
                            });
                        });
                    });
                    #endif
                } else {
                    // Save to AudioNotes folder
                    NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                    if (![fm fileExistsAtPath:audioNotesDir]) {
                        [fm createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    
                    NSDateFormatter *formatter = [NSDateFormatter new];
                    [formatter setDateFormat:@"yyyyMMdd-HHmmss"];
                    NSString *destName = [NSString stringWithFormat:@"Video-%@_%ld.mp4", [formatter stringFromDate:[NSDate date]], (long)videoIndex];
                    NSString *destPath = [audioNotesDir stringByAppendingPathComponent:destName];
                    
                    NSError *moveError = nil;
                    if ([fm moveItemAtPath:outputPath toPath:destPath error:&moveError]) {
                        
                        // Cleanup
                        [fm removeItemAtPath:videoPath error:nil];
                        if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                        
                        dispatch_async(statsQueue, ^{
                            completedVideos++;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                
                                if (completedVideos >= totalVideos) {
                                    [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                    [MediaSelectionViewController setDownloadInProgress:NO];
                                }
                            });
                        });
                    } else {
                        NSLog(@"Failed to move video %ld to AudioNotes: %@", (long)videoIndex, moveError);
                        
                        // Cleanup
                        [fm removeItemAtPath:videoPath error:nil];
                        if (audioPath) [fm removeItemAtPath:audioPath error:nil];
                        [fm removeItemAtPath:outputPath error:nil];
                        
                        dispatch_async(statsQueue, ^{
                            failedVideos++;
                            completedVideos++;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [progressToast updateProgressWithTitle:@"Bulk saving videos!" subtitle:formatProgressDisplay()];
                                
                                if (completedVideos >= totalVideos) {
                                    [self showCompletionToast:progressToast completed:completedVideos total:totalVideos failed:failedVideos];
                                    [MediaSelectionViewController setDownloadInProgress:NO];
                                }
                            });
                        });
                    }
                }
            }
        });
    }
}

- (void)generateHDVideoThumbnail:(IGVideo *)video forIndex:(NSInteger)index {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            NSLog(@"Starting thumbnail generation for HD video %ld", (long)index);
            
            // First, create a placeholder immediately
            UIImage *placeholder = [self createVideoPlaceholder];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *cacheKey = [NSString stringWithFormat:@"hd_video_%ld", (long)index];
                [self.previewCache setObject:placeholder forKey:cacheKey];
                
                // Reload the specific cell immediately with placeholder
                NSIndexPath *indexPath = [NSIndexPath indexPathForItem:index + self.mediaItems.count inSection:0];
                [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
                NSLog(@"Created initial placeholder for HD video %ld", (long)index);
            });
            
            // Try to get video info and attempt thumbnail generation
            NSSet *videoURLs = [video allVideoURLs];
            if (videoURLs && videoURLs.count > 0) {
                NSURL *firstVideoURL = [videoURLs anyObject];
                NSLog(@"Found video URL for HD video %ld: %@", (long)index, firstVideoURL);
                
                // Try to download a small portion and generate thumbnail
                [self attemptThumbnailFromURL:firstVideoURL forIndex:index];
            } else {
                NSLog(@"No video URLs found for HD video %ld", (long)index);
            }
            
        } @catch (NSException *exception) {
            NSLog(@"Error generating HD video thumbnail: %@", exception);
        }
    });
}

- (UIImage *)createVideoPlaceholder {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(400, 400), NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Create gradient background
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGFloat locations[] = {0.0, 1.0};
    CGFloat components[] = {
        0.15, 0.15, 0.25, 1.0,  // Start color - darker blue
        0.05, 0.05, 0.15, 1.0   // End color - even darker
    };
    CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, locations, 2);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0), CGPointMake(400, 400), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
    
    // Add video icon with better styling
    UIImage *videoIcon = [UIImage systemImageNamed:@"play.circle.fill"];
    if (videoIcon) {
        // Draw a larger, more prominent play button
        [videoIcon drawInRect:CGRectMake(120, 120, 160, 160)];
    }
    
    // Add "HD" text
    UIFont *hdFont = [UIFont boldSystemFontOfSize:24];
    NSDictionary *textAttributes = @{
        NSFontAttributeName: hdFont,
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    NSString *hdText = @"HD VIDEO";
    CGSize textSize = [hdText sizeWithAttributes:textAttributes];
    CGPoint textPoint = CGPointMake((400 - textSize.width) / 2, 320);
    [hdText drawAtPoint:textPoint withAttributes:textAttributes];
    
    UIImage *placeholder = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return placeholder;
}

- (void)attemptThumbnailFromURL:(NSURL *)videoURL forIndex:(NSInteger)index {
    // Create a session with browser-like headers
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 10.0;
    config.timeoutIntervalForResource = 15.0;
    
    // Add headers that mimic a browser request
    config.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        @"Accept": @"*/*",
        @"Accept-Language": @"en-US,en;q=0.9",
        @"Accept-Encoding": @"gzip, deflate, br",
        @"Connection": @"keep-alive",
        @"Referer": @"https://www.instagram.com/"
    };
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    // Request only the first 2MB of the video
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:videoURL];
    [request setValue:@"bytes=0-2097152" forHTTPHeaderField:@"Range"];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"Error downloading video data for thumbnail %ld: %@", (long)index, error);
            return;
        }
        
        NSLog(@"Downloaded %ld bytes for thumbnail generation %ld", (long)data.length, (long)index);
        
        // Check if we got a valid response
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200 && httpResponse.statusCode != 206) {
            NSLog(@"HTTP error %ld for thumbnail generation %ld", (long)httpResponse.statusCode, (long)index);
            return;
        }
        
        // Write to temp file
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"temp_video_%ld.mp4", (long)index]];
        BOOL writeSuccess = [data writeToFile:tempPath atomically:YES];
        
        if (!writeSuccess) {
            NSLog(@"Failed to write video data to temp file for %ld", (long)index);
            return;
        }
        
        // Try to create thumbnail from the downloaded portion
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:tempPath]];
        
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
            AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:nil];
            if (status != AVKeyValueStatusLoaded) {
                NSLog(@"Failed to load asset tracks for thumbnail %ld", (long)index);
                [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                dispatch_semaphore_signal(semaphore);
                return;
            }
            
            AVAssetImageGenerator *imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
            imageGenerator.appliesPreferredTrackTransform = YES;
            imageGenerator.maximumSize = CGSizeMake(400, 400);
            imageGenerator.requestedTimeToleranceBefore = CMTimeMake(2, 1);  // 2 second tolerance
            imageGenerator.requestedTimeToleranceAfter = CMTimeMake(2, 1);   // 2 second tolerance
            
            // Try at the beginning of the video
            CMTime time = CMTimeMake(1, 1);  // 1 second
            NSError *imageError = nil;
            CGImageRef cgImage = [imageGenerator copyCGImageAtTime:time actualTime:nil error:&imageError];
            
            if (cgImage) {
                UIImage *thumbnail = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                
                NSLog(@"Successfully generated thumbnail for HD video %ld", (long)index);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *cacheKey = [NSString stringWithFormat:@"hd_video_%ld", (long)index];
                    [self.previewCache setObject:thumbnail forKey:cacheKey];
                    
                    // Reload the specific cell with actual thumbnail
                    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:index + self.mediaItems.count inSection:0];
                    [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
                    NSLog(@"Updated HD video %ld with actual thumbnail", (long)index);
                });
            } else {
                NSLog(@"Failed to generate thumbnail for HD video %ld: %@", (long)index, imageError);
            }
            
            // Clean up temp file
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            dispatch_semaphore_signal(semaphore);
        }];
        
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    }];
    
    [task resume];
}

- (void)setupVideoPlayerForCell:(UIView *)cardView atIndex:(NSInteger)videoIndex {
    // Remove any existing video player
    for (UIView *subview in cardView.subviews) {
        if ([subview isKindOfClass:[AVPlayerLayer class]] || ([subview isKindOfClass:[UIView class]] && subview.tag == 999)) {
            [subview removeFromSuperview];
        }
    }
    
    // Try to get preloaded player first
    NSString *playerKey = [NSString stringWithFormat:@"video_player_%ld", (long)videoIndex];
    AVPlayer *player = [self.previewCache objectForKey:playerKey];
    
    if (!player) {
        // Fallback: create new player if preloaded one not available
        IGVideo *video = self.hdVideos[videoIndex];
        NSSet *videoURLs = [video allVideoURLs];
        if (!videoURLs || videoURLs.count == 0) {
            return;
        }
        
        NSURL *videoURL = [videoURLs anyObject];
        player = [AVPlayer playerWithURL:videoURL];
        
        // Cache the player for future use
        [self.previewCache setObject:player forKey:playerKey];
    }
    
    // Use the helper method to set up the player layer
    [self setupVideoPlayerLayer:cardView withPlayer:player];
    
    // Store player reference for cleanup
    cardView.tag = 999; // Mark as having video player
}

+ (void)preloadHDVideoThumbnails:(NSArray<IGVideo *> *)hdVideos completion:(void(^)(void))completion {
    if (!hdVideos || hdVideos.count == 0) {
        if (completion) completion();
        return;
    }
    
    NSLog(@"Preloading HD video players for %ld videos", (long)hdVideos.count);
    
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *videoPlayers = [[NSMutableDictionary alloc] init];
    
    for (NSInteger i = 0; i < hdVideos.count; i++) {
        dispatch_group_enter(group);
        
        IGVideo *video = hdVideos[i];
        NSSet *videoURLs = [video allVideoURLs];
        
        if (!videoURLs || videoURLs.count == 0) {
            dispatch_group_leave(group);
            continue;
        }
        
        NSURL *videoURL = [videoURLs anyObject];
        
        // Create AVPlayer with muted audio
        AVPlayer *player = [AVPlayer playerWithURL:videoURL];
        player.muted = YES; // Mute the video
        player.actionAtItemEnd = AVPlayerActionAtItemEndNone; // Don't pause at end
        
        // Set up looping with proper observer management
        __weak typeof(player) weakPlayer = player;
        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                        object:player.currentItem
                                                                         queue:[NSOperationQueue mainQueue]
                                                                    usingBlock:^(NSNotification *notification) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakPlayer && weakPlayer.currentItem) {
                    [weakPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
                        if (finished) {
                            [weakPlayer play];
                        }
                    }];
                }
            });
        }];
        
        // Store the observer reference
        objc_setAssociatedObject(player, "loopObserver", observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        // Set up a timer to check if player is ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
                NSString *key = [NSString stringWithFormat:@"video_player_%ld", (long)i];
                videoPlayers[key] = player;
                NSLog(@"Preloaded video player %ld", (long)i);
            } else {
                NSLog(@"Failed to preload video player %ld (timeout)", (long)i);
            }
            dispatch_group_leave(group);
        });
        
        // Start loading the video
        [player play];
        [player pause]; // Pause immediately but keep loaded
    }
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // Store preloaded players in shared cache
        NSCache *sharedCache = [self sharedPreviewCache];
        for (NSString *key in videoPlayers) {
            [sharedCache setObject:videoPlayers[key] forKey:key];
        }
        
        NSLog(@"Preloaded %ld HD video players", (long)videoPlayers.count);
        if (completion) completion();
    });
}

+ (NSCache *)sharedPreviewCache {
    static NSCache *sharedCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCache = [[NSCache alloc] init];
        sharedCache.countLimit = 100;
    });
    return sharedCache;
}

// Convert a media file to MP3 using FFmpegKit. On success returns output .mp3 path and deletes input.
- (void)convertFileToMP3:(NSString *)inputPath completion:(void(^)(NSString *outputPath, NSError *error))completion {
    if (inputPath.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"theta" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Empty input path"}]);
        return;
    }

    NSString *dir = [inputPath stringByDeletingLastPathComponent];
    NSString *base = [[inputPath lastPathComponent] stringByDeletingPathExtension];
    NSString *outputPath = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"mp3"]];

    static dispatch_queue_t mp3ConversionQueue;
    static dispatch_once_t mp3OnceToken;
    dispatch_once(&mp3OnceToken, ^{
        mp3ConversionQueue = dispatch_queue_create("theta.ffmpeg.mp3.queue", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(mp3ConversionQueue, ^{
        @autoreleasepool {
            static void *ffmpegkitHandle = NULL;
            static Class FFmpegKitClass = NULL;
            static dispatch_once_t onceToken;
            __block NSString *frameworkPath;

            dispatch_once(&onceToken, ^{
#ifndef SIDELOAD
                frameworkPath = ROOT_PATH_NS(@"/Library/Application Support/ffmpeg.framework/ffmpegkit");
                ffmpegkitHandle = dlopen([frameworkPath UTF8String], RTLD_NOW);
                if (!ffmpegkitHandle) {
                    NSString *alternativePath = ROOT_PATH_NS(@"/Library/Application Support/ffmpeg.framework/ffmpegkit");
                    ffmpegkitHandle = dlopen([alternativePath UTF8String], RTLD_NOW);
                }
#else
                NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
                NSString *frameworksPath = [[NSBundle mainBundle] privateFrameworksPath];
                NSArray *sideloadPaths = @[
                    [bundlePath stringByAppendingPathComponent:@"ffmpeg.framework/ffmpegkit"],
                    [frameworksPath stringByAppendingPathComponent:@"ffmpeg.framework/ffmpegkit"],
                    [[NSBundle mainBundle] pathForResource:@"ffmpegkit" ofType:nil inDirectory:@"ffmpeg.framework"] ?: @"",
                    @"/ffmpeg.framework/ffmpegkit"
                ];
                for (NSString *path in sideloadPaths) {
                    if (path.length > 0) {
                        frameworkPath = path;
                        ffmpegkitHandle = dlopen([frameworkPath UTF8String], RTLD_NOW);
                        if (ffmpegkitHandle) break;
                    }
                }
#endif
                FFmpegKitClass = objc_getClass("FFmpegKit");
            });

            if (!ffmpegkitHandle || !FFmpegKitClass) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, [NSError errorWithDomain:@"theta" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"FFmpegKit not available"}]);
                });
                return;
            }

            NSString *command = [NSString stringWithFormat:@"-y -hide_banner -loglevel error -i '%@' -vn -map a -c:a libmp3lame -q:a 0 '%@'", inputPath, outputPath];
            NSMethodSignature *signature = [FFmpegKitClass methodSignatureForSelector:@selector(execute:)];
            if (!signature) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, [NSError errorWithDomain:@"theta" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"FFmpegKit execute: not found"}]);
                });
                return;
            }
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:FFmpegKitClass];
            [invocation setSelector:@selector(execute:)];
            [invocation setArgument:&command atIndex:2];

            id __unsafe_unretained session = nil;
            @try {
                [invocation invoke];
                [invocation getReturnValue:&session];
            } @catch (NSException *exception) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, [NSError errorWithDomain:@"theta" code:-4 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"FFmpegKit exception"}]);
                });
                return;
            }

            // Consider conversion successful if output file exists and is non-empty,
            // even if FFmpegKit return code isn't flagged success on this build.
            NSFileManager *fmCheck = [NSFileManager defaultManager];
            NSDictionary *attrs = [fmCheck attributesOfItemAtPath:outputPath error:nil];
            unsigned long long fsize = [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
            BOOL fileOk = (attrs != nil && fsize > 0);
            if (!fileOk) {
                // Fallback to AAC/M4A if MP3 encoder unavailable
                NSString *m4aPath = [[inputPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"m4a"];
                NSString *aacCommand = [NSString stringWithFormat:@"-y -hide_banner -loglevel error -i '%@' -vn -map a -c:a aac -b:a 192k '%@'", inputPath, m4aPath];
                NSMethodSignature *sig2 = [FFmpegKitClass methodSignatureForSelector:@selector(execute:)];
                if (sig2) {
                    NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:sig2];
                    [inv2 setTarget:FFmpegKitClass];
                    [inv2 setSelector:@selector(execute:)];
                    [inv2 setArgument:&aacCommand atIndex:2];
                    id __unsafe_unretained s2 = nil;
                    @try { [inv2 invoke]; [inv2 getReturnValue:&s2]; } @catch (__unused NSException *e) {}
                    BOOL ok2 = NO;
                    if (s2 && [s2 respondsToSelector:@selector(getReturnCode)]) {
                        @try {
                            id rc2 = [s2 performSelector:@selector(getReturnCode)];
                            if (rc2 && [rc2 respondsToSelector:@selector(isSuccess)]) {
                                ok2 = [rc2 performSelector:@selector(isSuccess)];
                            }
                        } @catch (__unused NSException *e) {}
                    }
                    if (ok2 && [[NSFileManager defaultManager] fileExistsAtPath:m4aPath]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSFileManager defaultManager] removeItemAtPath:inputPath error:nil];
                            if (completion) completion(m4aPath, nil);
                        });
                        return;
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, [NSError errorWithDomain:@"theta" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"MP3 conversion failed"}]);
                });
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSFileManager defaultManager] removeItemAtPath:inputPath error:nil];
                if (completion) completion(outputPath, nil);
            });
        }
    });
}

@end

