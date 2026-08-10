static BOOL videoPlayed = NO;

@class IGVideo;
static void downloadHDVideo(IGVideo *inputVideo);

static void (*orig_visualmsgghostbuttons)(IGDirectVisualMessageViewerController *self, SEL _cmd);
static void hook_visualmsgghostbuttons(IGDirectVisualMessageViewerController *self, SEL _cmd) {
    orig_visualmsgghostbuttons(self, _cmd);

    UIView *containerView = [self valueForKey:@"view"];
    if (!containerView || ![containerView isKindOfClass:[UIView class]]) {
        NSLog(@"Failed to get valid container view");
        return;
    }
    
    UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Save Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [downloadButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting download button color: %@", exception);
        [downloadButton setTintColor:[UIColor labelColor]];
    }
    [downloadButton setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
    downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
    downloadButton.layer.shadowOpacity = 0.4;
    downloadButton.layer.shadowOffset = CGSizeMake(-2, 0);
    downloadButton.layer.shadowRadius = 3;
    downloadButton.layer.masksToBounds = NO;
    [downloadButton setTranslatesAutoresizingMaskIntoConstraints:false];

    UIButton *seenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Seen Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [seenButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting seen button color: %@", exception);
        [seenButton setTintColor:[UIColor labelColor]];
    }
    [seenButton setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    seenButton.layer.shadowColor = [UIColor blackColor].CGColor;
    seenButton.layer.shadowOpacity = 0.4;
    seenButton.layer.shadowOffset = CGSizeMake(-2, 0);
    seenButton.layer.shadowRadius = 3;
    seenButton.layer.masksToBounds = NO;
    [seenButton setTranslatesAutoresizingMaskIntoConstraints:false];

    BOOL downloadVideos = ENABLED(@"Save Media");
    BOOL hideSeenState = ENABLED(@"Private Media Ghost");

    ThetaSetCaptureHiding(downloadButton);
    ThetaSetCaptureHiding(seenButton);

    @try {
        if (downloadVideos && !hideSeenState) {
            [containerView addSubview:downloadButton];
            [NSLayoutConstraint activateConstraints:@[
                [downloadButton.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-150],
                [downloadButton.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
                [downloadButton.widthAnchor constraintEqualToConstant:30],
                [downloadButton.heightAnchor constraintEqualToConstant:30]
            ]];
        }

        if (!downloadVideos && hideSeenState) {
            [containerView addSubview:seenButton];
            [NSLayoutConstraint activateConstraints:@[
                [seenButton.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-150],
                [seenButton.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
                [seenButton.widthAnchor constraintEqualToConstant:30],
                [seenButton.heightAnchor constraintEqualToConstant:30]
            ]];
        }

        if (downloadVideos && hideSeenState) {
            [containerView addSubview:downloadButton];
            [containerView addSubview:seenButton];
            [NSLayoutConstraint activateConstraints:@[
                [downloadButton.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-150],
                [downloadButton.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
                [downloadButton.widthAnchor constraintEqualToConstant:30],
                [downloadButton.heightAnchor constraintEqualToConstant:30]
            ]];
            [NSLayoutConstraint activateConstraints:@[
                [seenButton.bottomAnchor constraintEqualToAnchor:downloadButton.topAnchor constant:-20],
                [seenButton.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
                [seenButton.widthAnchor constraintEqualToConstant:30],
                [seenButton.heightAnchor constraintEqualToConstant:30]
            ]];
        }

        if (hideSeenState) {
            __weak typeof(self) weakSelf = self;
            [seenButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
                UIView *containView = [self valueForKey:@"_viewerContainerView"];
                UIView *medView = [containView valueForKey:@"mediaView"];
                if ([medView isKindOfClass:NSClassFromString(@"IGStoryModernVideoView")]) {
                    [self performSelector:@selector(storyPlayerMediaViewDidPlay:) withObject:medView];
                    videoPlayed = YES;
                }

                if ([medView isKindOfClass:NSClassFromString(@"IGStoryPhotoView")]) {
                    [self storyPlayerMediaViewDidLoad:medView loadSource:0 networkRequestSummary:0];
                    videoPlayed = YES;
                }

                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Marked as seen!" subtitle:@"They know we are here." icon:[ThetaHelper imageFromEmojiString:@"👀" width:60] autoHide:4 openURL:nil];
                }
            }] forControlEvents:UIControlEventTouchUpInside];
        }

        if (downloadVideos) {
            __weak typeof(self) weakSelf = self;
            [downloadButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
                id initialVisualMessage = [self valueForKey:@"_initialVisualMessage"];
                id visualMediaInfo = [initialVisualMessage valueForKey:@"_visualMediaInfo"];
                id media = [visualMediaInfo valueForKey:@"media"];
                if ([media valueForKey:@"_video_video"]) {
                    IGVideo *video = [media valueForKey:@"_video_video"];
                    downloadHDVideo(video);
                }

                if ([media valueForKey:@"_photo_photo"]) {
                    IGPhoto *photo = [media valueForKey:@"_photo_photo"];
                    NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                    if (originalImageVersions.count > 1) {
                        id photoURL = [originalImageVersions lastObject];
                        NSURL *url = [photoURL valueForKey:@"url"];
                        MediaSelectionViewController *mediaSelectionViewController = [[MediaSelectionViewController alloc] init];
                        [mediaSelectionViewController downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension){
                            if (ENABLED(@"Show Banners")) {
                                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                if (saveMethod == 0) {
                                    [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                                } else {
                                    [ThetaHelper showToastWithTitle:@"Saved!" subtitle:@"Saved to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:nil];
                                }
                            }
                        }];
                    }
                }
            }] forControlEvents:UIControlEventTouchUpInside];
        }
    } @catch (NSException *exception) {
        NSLog(@"Error adding buttons: %@", exception);
    }
}

static void (*orig_visualmsgghostvideo)(id self, SEL _cmd, id arg1);
static void hook_visualmsgghostvideo(id self, SEL _cmd, id arg1) {
    if (!ENABLED(@"Private Media Ghost")) {
        return orig_visualmsgghostvideo(self, _cmd, arg1);
    }

    if (videoPlayed) {
        orig_visualmsgghostvideo(self, _cmd, arg1);
        videoPlayed = NO;
    }
}

static void (*orig_visualmsgghostphoto)(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4);
static void hook_visualmsgghostphoto(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (!ENABLED(@"Private Media Ghost")) {
        return orig_visualmsgghostphoto(self, _cmd, arg1, arg2, arg3, arg4);
    }

    if (videoPlayed) {
        orig_visualmsgghostphoto(self, _cmd, arg1, arg2, arg3, arg4);
        videoPlayed = NO;
    }
}

void THRegisterPrivateVideoGhostHooks(void) {
    NullHookMessageEx(objc_getClass("IGDirectVisualMessageViewerController"), @selector(viewDidLoad), (void *)hook_visualmsgghostbuttons, &orig_visualmsgghostbuttons);
    NullHookMessageEx(objc_getClass("IGDirectVisualMessageViewerController"), @selector(storyPlayerMediaViewDidPlay:), (void *)hook_visualmsgghostvideo, &orig_visualmsgghostvideo);
    NullHookMessageEx(objc_getClass("IGStoryPhotoView"), @selector(progressImageView:didLoadImage:loadSource:networkRequestSummary:), (void *)hook_visualmsgghostphoto, &orig_visualmsgghostphoto);
}