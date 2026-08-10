#import "Include/CustomToastView.h"

// Toast stacking management
static __weak CustomToastView *sProgressToast = nil; // persistent progress toast (no auto-hide)
static __weak CustomToastView *sNormalToast = nil;   // transient normal toast (auto-hide)
static const CGFloat kToastTopMargin = 50.0;
static const CGFloat kToastMinHeight = 70.0;
static const CGFloat kToastMaxHeight = 300.0;
static const CGFloat kToastVerticalSpacing = -2.0; // tighter gap between stacked toasts
// Coalescing window to treat simultaneous toasts as one (prefer progress)
static const NSTimeInterval kToastCoalesceWindow = 0.25; // seconds
static NSTimeInterval sLastProgressToastAt = 0;
static NSTimeInterval sLastNormalToastAt = 0;

static void closeApp(void) {
	// just a bunch of stuff, so patching one doesn't stop the app from closing
	asm volatile (
		"mov x0, 0x0\n"
		"mov x16, 0x1\n"
		"svc #0"
	);
	exit(0);
	[[NSThread mainThread] performSelector:@selector(exit)];
	[[NSObject alloc] performSelector:@selector(length)];
	exit(1);
	strcpy(0, "");
	int* p = (int*)1; *p = 0;
	*((char*)NULL) = 0;
	*(long*)0 = 0xDEADBEEF;
	@throw NSInternalInconsistencyException;
	assert(NO);
	@throw [NSException exceptionWithName:NSGenericException reason:@"" userInfo:nil];
	kill(getpid(), SIGABRT);
	__builtin_trap();
}

static void closeAppWithAnimation(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[UIApplication sharedApplication] performSelector:@selector(suspend)];
		[NSTimer scheduledTimerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *timer) {
			closeApp();
		}];
	});
}

@implementation CustomToastView
-(UIWindow *)getKeyWindow {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *window in [windows reverseObjectEnumerator]) {
        if (window.hidden == NO && window.alpha > 0) return window;
    }
    return nil;
}

-(instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon autoHide:(int)seconds openURL:(NSURL *)url {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.isProgressType = NO;
        self.containerView = [[UIView alloc] init];
        self.containerView.layer.cornerRadius = 25;
        self.containerView.layer.masksToBounds = YES;
        self.containerView.layer.shadowColor = [UIColor blackColor].CGColor;
        self.containerView.layer.shadowOpacity = 0.18;
        self.containerView.layer.shadowOffset = CGSizeMake(0, 8);
        self.containerView.layer.shadowRadius = 10;
        self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.containerView];

        self.hStack = [[UIStackView alloc] init];
        self.hStack.axis = UILayoutConstraintAxisHorizontal;
        self.hStack.alignment = UIStackViewAlignmentCenter;
        self.hStack.spacing = 10.0;
        self.hStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.containerView addSubview:self.hStack];

        if (icon) {
            UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
            iconView.contentMode = UIViewContentModeScaleAspectFit;
            iconView.translatesAutoresizingMaskIntoConstraints = NO;
            [self.hStack addArrangedSubview:iconView];
            
            // Store reference to icon view for progress updates
            self.progressIconView = iconView;

            CGFloat iconWidth = 30;
            CGFloat iconHeight = 30;
            UIEdgeInsets margins = UIEdgeInsetsMake(0, 0, 0, 20);


            if ([iconView.image isEqual:[UIImage systemImageNamed:@"checkmark.circle.fill"]]) {
                iconWidth = 24;
                iconHeight = 24;
                margins = UIEdgeInsetsMake(0, 0, 0, 20);
                iconView.tintColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0];
            }

            if ([iconView.image isEqual:[UIImage systemImageNamed:@"arrow.clockwise"]]) {
                iconWidth = 24;
                iconHeight = 24;
                margins = UIEdgeInsetsMake(0, 0, 0, 20);
                iconView.tintColor = [UIColor labelColor];
            }

            if ([iconView.image isEqual:[UIImage systemImageNamed:@"play.circle"]]) {
                iconView.tintColor = [UIColor labelColor];
            }

            if ([iconView.image isEqual:[UIImage systemImageNamed:@"trash"]]) {
                iconView.tintColor = [UIColor labelColor];
            }

            if ([iconView.image isEqual:[UIImage systemImageNamed:@"doc.on.doc.fill"]]) {
                iconWidth = 24;
                iconHeight = 24;
                margins = UIEdgeInsetsMake(0, 0, 0, 20);
                iconView.tintColor = [UIColor labelColor];
            }

            [NSLayoutConstraint activateConstraints:@[
                [iconView.widthAnchor constraintEqualToConstant:iconWidth],
                [iconView.heightAnchor constraintEqualToConstant:iconHeight]
            ]];

            [self.hStack setLayoutMargins:margins];
            self.hStack.layoutMarginsRelativeArrangement = YES;
        }

        self.vStack = [[UIStackView alloc] init];
        self.vStack.axis = UILayoutConstraintAxisVertical;
        self.vStack.alignment = UIStackViewAlignmentCenter;
        self.vStack.spacing = 2.0;
        self.vStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.hStack addArrangedSubview:self.vStack];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.text = title;
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.vStack addArrangedSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        // Slightly bolder subtitle for better readability in progress lists
        self.subtitleLabel.font = [UIFont boldSystemFontOfSize:11];
        self.subtitleLabel.textAlignment = NSTextAlignmentLeft;
        self.subtitleLabel.text = subtitle;
        self.subtitleLabel.numberOfLines = 0; // Allow multiple lines
        self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.vStack addArrangedSubview:self.subtitleLabel];

        [self.vStack setLayoutMargins:UIEdgeInsetsMake(4, 0, 4, 0)];
        self.vStack.layoutMarginsRelativeArrangement = YES;

        [NSLayoutConstraint activateConstraints:@[
            [self.containerView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [self.containerView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [self.containerView.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
            [self.containerView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10]
        ]];

        [NSLayoutConstraint activateConstraints:@[
            [self.hStack.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],
            [self.hStack.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor]
        ]];

        UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:panGesture];

        if (url) {
            self.openURL = url;
            UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
            [self addGestureRecognizer:tapGesture];
        }

        [self updateAppearance];

        self.autoHideTime = seconds;
        self.isUserHolding = NO;
        if (seconds > 0) {
            [self hideAfter:seconds];
        }

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

// Ensure the single overall progress view exists (for single-item saves)
-(void)ensureProgressView {
    if (self.progressView) {
        return;
    }
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progress = 0.0f;
    // Light grey progress to match subtle system style
    self.progressView.progressTintColor = [UIColor lightGrayColor];
    self.progressView.trackTintColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.3];
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)appDidEnterBackground {
    [self hideWithAnimation];
}

-(void)appWillEnterForeground {
    if (self.superview) {
        [self hideWithAnimation];
    }
}

-(void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 12.0, *)) {
        if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle) {
            [self updateAppearance];
        }
    }
}

-(void)updateAppearance {
    if (@available(iOS 12.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            self.containerView.backgroundColor = [UIColor colorWithRed:0.125 green:0.125 blue:0.125 alpha:1.0];
            self.titleLabel.textColor = [UIColor whiteColor];
            self.subtitleLabel.textColor = [UIColor lightGrayColor];
        } else {
            self.containerView.backgroundColor = [UIColor whiteColor];
            self.titleLabel.textColor = [UIColor blackColor];
            self.subtitleLabel.textColor = [UIColor darkGrayColor];
        }
    } else {
        self.containerView.backgroundColor = [UIColor whiteColor];
        self.titleLabel.textColor = [UIColor blackColor];
        self.subtitleLabel.textColor = [UIColor darkGrayColor];
    }
}

-(void)presentToast {
    UIWindow *keyWindow = [self getKeyWindow];

    if (!keyWindow) return;

    // Coalesce only when truly simultaneous (within window); otherwise allow stacking
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!self.isProgressType) {
        // If a progress toast was just created very recently, drop this normal toast
        if ((now - sLastProgressToastAt) <= kToastCoalesceWindow) {
            return;
        }
    }

    // Replace only same-type toasts; keep progress when showing a normal toast
    if (self.isProgressType) {
        if (sProgressToast && sProgressToast != self) {
            [sProgressToast hideWithAnimation];
            sProgressToast = nil;
        }
        // If a normal toast was just shown nearly at the same time, remove it immediately
        if (sNormalToast && sNormalToast.superview) {
            if ((now - sLastNormalToastAt) <= kToastCoalesceWindow) {
                [sNormalToast removeFromSuperview];
                sNormalToast = nil;
            }
        }
    } else {
        if (sNormalToast && sNormalToast != self) {
            [sNormalToast hideWithAnimation];
            sNormalToast = nil;
        }
    }

    [keyWindow addSubview:self];

    self.translatesAutoresizingMaskIntoConstraints = NO;

    CGFloat maxWidth = keyWindow.bounds.size.width - 40;
    CGFloat requiredWidth = [self calculateRequiredWidth];
    CGFloat toastWidth = MIN(maxWidth, requiredWidth);
    
    // Calculate required height based on content
    CGFloat requiredHeight = [self calculateRequiredHeight:toastWidth];
    requiredHeight = MAX(kToastMinHeight, MIN(kToastMaxHeight, requiredHeight));

    // Base constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.centerXAnchor constraintEqualToAnchor:keyWindow.centerXAnchor]
    ]];
    // Adjustable constraints we keep references to
    self.topConstraint = [self.topAnchor constraintEqualToAnchor:keyWindow.topAnchor constant:kToastTopMargin];
    self.widthConstraint = [self.widthAnchor constraintEqualToConstant:toastWidth];
    self.heightConstraint = [self.heightAnchor constraintEqualToConstant:requiredHeight];
    self.topConstraint.active = YES;
    self.widthConstraint.active = YES;
    self.heightConstraint.active = YES;

    // Stacking offsets
    if (!self.isProgressType && sProgressToast && sProgressToast.superview) {
        // Showing a normal toast while a progress toast exists → push progress down
        CGFloat progressHeight = sProgressToast.heightConstraint.constant;
        sProgressToast.topConstraint.constant = kToastTopMargin + requiredHeight + kToastVerticalSpacing;
    }
    if (self.isProgressType && sNormalToast && sNormalToast.superview) {
        // If normal appeared within the coalesce window, prefer only progress
        if ((now - sLastNormalToastAt) <= kToastCoalesceWindow) {
            [sNormalToast removeFromSuperview];
            sNormalToast = nil;
            self.topConstraint.constant = kToastTopMargin;
        } else {
            // Showing progress while a normal toast is showing → place progress under normal
            CGFloat normalHeight = sNormalToast.heightConstraint.constant;
            self.topConstraint.constant = kToastTopMargin + normalHeight + kToastVerticalSpacing;
        }
    } else {
        self.topConstraint.constant = kToastTopMargin;
    }

    [keyWindow layoutIfNeeded];

    self.transform = CGAffineTransformMakeTranslation(0, -self.bounds.size.height);

    [UIView animateWithDuration:0.35
                          delay:0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        if (!self.isProgressType && sProgressToast && sProgressToast.superview) {
            [keyWindow layoutIfNeeded];
        }
    } completion:^(BOOL finished) {
    }];

    if (self.isProgressType) {
        sProgressToast = self;
        sLastProgressToastAt = now;
    } else {
        sNormalToast = self;
        sLastNormalToastAt = now;
    }
}

-(CGFloat)calculateRequiredWidth {
    CGFloat padding = 40;
    CGFloat iconWidth = 24;
    CGFloat spacing = 2;

    // Calculate text width directly from label text using boundingRectWithSize
    // This is more reliable than intrinsicContentSize which may not be updated yet
    CGFloat titleWidth = 0;
    CGFloat subtitleWidth = 0;
    
    if (self.titleLabel.text.length > 0) {
        CGSize titleSize = [self.titleLabel.text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                                               options:NSStringDrawingUsesLineFragmentOrigin
                                                            attributes:@{NSFontAttributeName: self.titleLabel.font}
                                                               context:nil].size;
        titleWidth = ceil(titleSize.width);
    }
    
    if (self.subtitleLabel.text.length > 0 && !self.subtitleLabel.hidden) {
        CGSize subtitleSize = [self.subtitleLabel.text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                                  attributes:@{NSFontAttributeName: self.subtitleLabel.font}
                                                                     context:nil].size;
        subtitleWidth = ceil(subtitleSize.width);
    }
    
    // Also check multi-progress stack for width if it exists
    if (self.multiProgressStack && self.multiProgressTitles.count > 0) {
        for (UILabel *label in self.multiProgressTitles) {
            if (label.text.length > 0) {
                CGSize labelSize = [label.text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                                             options:NSStringDrawingUsesLineFragmentOrigin
                                                          attributes:@{NSFontAttributeName: label.font}
                                                             context:nil].size;
                subtitleWidth = MAX(subtitleWidth, ceil(labelSize.width) + 80.0f); // Add progress bar width
            }
        }
    }

    CGFloat textWidth = MAX(titleWidth, subtitleWidth);

    return padding + iconWidth + spacing + textWidth + padding;
}

-(CGFloat)calculateRequiredHeight:(CGFloat)toastWidth {
    CGFloat padding = 20; // Top and bottom padding
    CGFloat iconWidth = 24;
    CGFloat spacing = 10; // Horizontal spacing
    
    // Calculate available width for text
    CGFloat availableTextWidth = toastWidth - (padding * 2) - iconWidth - spacing;
    
    // Calculate title height
    CGFloat titleHeight = 0;
    if (self.titleLabel.text.length > 0) {
        CGSize titleSize = [self.titleLabel.text boundingRectWithSize:CGSizeMake(availableTextWidth, CGFLOAT_MAX)
                                                               options:NSStringDrawingUsesLineFragmentOrigin
                                                            attributes:@{NSFontAttributeName: self.titleLabel.font}
                                                               context:nil].size;
        titleHeight = ceil(titleSize.height);
    }
    
    // Calculate subtitle height
    CGFloat subtitleHeight = 0;
    if (self.subtitleLabel.text.length > 0) {
        CGSize subtitleSize = [self.subtitleLabel.text boundingRectWithSize:CGSizeMake(availableTextWidth, CGFLOAT_MAX)
                                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                                  attributes:@{NSFontAttributeName: self.subtitleLabel.font}
                                                                     context:nil].size;
        subtitleHeight = ceil(subtitleSize.height);
    }
    
    // Stack spacing between title and subtitle
    CGFloat stackSpacing = (titleHeight > 0 && subtitleHeight > 0) ? 2.0 : 0;
    
    CGFloat baseHeight = padding + titleHeight + stackSpacing + subtitleHeight + padding;
    
    // Extra height for single progress bar
    if (self.progressView) {
        baseHeight += 8.0f;
    }
    
    // Extra height for multi-progress stack (rough estimate per row)
    if (self.multiProgressStack && self.multiProgressBars.count > 0) {
        baseHeight += self.multiProgressBars.count * 16.0f;
    }
    
    return baseHeight;
}

// Setup per-item progress UI (one UIProgressView per item, used for bulk saves)
-(void)setupPerItemProgressWithCount:(NSInteger)count {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Clean up any previous stack
        if (self.multiProgressStack) {
            [self.multiProgressStack removeFromSuperview];
            self.multiProgressStack = nil;
        }
        self.multiProgressBars = [NSMutableArray arrayWithCapacity:count];
        self.multiProgressTitles = [NSMutableArray arrayWithCapacity:count];
        
        // Hide the single subtitle when showing per-item rows
        self.subtitleLabel.hidden = YES;
        
        UIStackView *stack = [[UIStackView alloc] init];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 4.0f;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.vStack addArrangedSubview:stack];
        self.multiProgressStack = stack;
        
        for (NSInteger i = 0; i < count; i++) {
            UIStackView *row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.alignment = UIStackViewAlignmentCenter;
            row.spacing = 6.0f;
            row.translatesAutoresizingMaskIntoConstraints = NO;
            
            UILabel *label = [[UILabel alloc] init];
            label.font = [UIFont boldSystemFontOfSize:11];
            label.textColor = self.subtitleLabel.textColor;
            // Just a bullet per line, no "Video 1" text
            label.text = @"•";
            [row addArrangedSubview:label];

            UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            bar.translatesAutoresizingMaskIntoConstraints = NO;
            bar.progress = 0.0f;
            bar.progressTintColor = [UIColor lightGrayColor];
            bar.trackTintColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.3];
            [row addArrangedSubview:bar];
            // Give the bar a clear, fixed visual width so it looks like a real progress bar
            [bar.widthAnchor constraintEqualToConstant:80.0f].active = YES;
            
            [stack addArrangedSubview:row];
            
            [self.multiProgressTitles addObject:label];
            [self.multiProgressBars addObject:bar];
        }
        
        [self recalculateWidth];
    });
}

-(void)updatePerItemProgressAtIndex:(NSInteger)index title:(NSString *)title progress:(float)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (index < 0 || index >= self.multiProgressBars.count) return;
        UILabel *label = self.multiProgressTitles[index];
        UIProgressView *bar = self.multiProgressBars[index];
        // Show "• XX%" before each per-item bar
        float clamped = progress;
        if (clamped < 0.0f) clamped = 0.0f;
        if (clamped > 1.0f) clamped = 1.0f;
        int percent = (int)roundf(clamped * 100.0f);
        label.text = [NSString stringWithFormat:@"• %d%%", percent];
        [bar setProgress:clamped animated:YES];
    });
}

-(void)removeFromSuperview {
    [super removeFromSuperview];
}

-(void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    CGPoint velocity = [gesture velocityInView:self];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.isUserHolding = YES;
            break;
        case UIGestureRecognizerStateChanged:
            if (translation.y < 0) {
                self.transform = CGAffineTransformMakeTranslation(0, translation.y);
            }
            break;
        case UIGestureRecognizerStateEnded:
            self.isUserHolding = NO;
            if (velocity.y < -500 || translation.y < -self.bounds.size.height / 2) {
                [self hideWithAnimation];
            } else {
                [UIView animateWithDuration:0.3 animations:^{
                    self.transform = CGAffineTransformIdentity;
                }];
                if (self.autoHideTime > 0) {
                    [self hideAfter:self.autoHideTime];
                }
            }
            break;
        default:
            break;
    }
}

-(void)handleTap:(UITapGestureRecognizer *)gesture {
    [UIView animateWithDuration:0.1 animations:^{
        self.containerView.backgroundColor = [self.containerView.backgroundColor colorWithAlphaComponent:0.5];
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            [self updateAppearance];
        } completion:^(BOOL finished) {
            if (self.openURL) {
                if ([self.openURL isKindOfClass:[NSURL class]]) {
                    NSURL *url = (NSURL *)self.openURL;
                    if ([url.absoluteString isEqualToString:@"Close"]) {
                        closeAppWithAnimation();
                        return;
                    } else {
                        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                    }
                } else if ([self.openURL isKindOfClass:[NSString class]]) {
                    NSString *stringAction = (NSString *)self.openURL;
                    if ([stringAction isEqualToString:@"Close"]) {
                        closeAppWithAnimation();
                        return;
                    }
                }
            }
        }];
    }];
}

-(void)hideWithAnimation {
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.95
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.transform = CGAffineTransformMakeTranslation(0, -self.bounds.size.height - 30);
    } completion:^(BOOL finished) {
        if (finished) {
            BOOL wasNormal = (self == sNormalToast);
            BOOL wasProgress = (self == sProgressToast);
            if (wasNormal) sNormalToast = nil;
            if (wasProgress) sProgressToast = nil;

            [self removeFromSuperview];

            // If a normal toast disappeared and we have a progress toast, move it back up
            if (wasNormal && sProgressToast && sProgressToast.superview) {
                UIWindow *keyWindow = [self getKeyWindow];
                sProgressToast.topConstraint.constant = kToastTopMargin;
                [UIView animateWithDuration:0.25
                                      delay:0
                     usingSpringWithDamping:0.95
                      initialSpringVelocity:0.2
                                    options:UIViewAnimationOptionCurveEaseInOut
                                 animations:^{
                    [keyWindow layoutIfNeeded];
                } completion:nil];
            }
        }
    }];
}

-(void)hideAfter:(NSTimeInterval)time {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(time * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        if (!self.isUserHolding) {
            [self hideWithAnimation];
        }
    });
}

// Progress toast methods
+(CustomToastView *)showProgressToastWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    CustomToastView *progressToast = [[CustomToastView alloc] initWithTitle:title subtitle:subtitle icon:[UIImage systemImageNamed:@"arrow.clockwise"] autoHide:0 openURL:nil];
    progressToast.isProgressType = YES;
    [progressToast presentToast];
    return progressToast;
}

-(void)updateProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.titleLabel.text = title;
        self.subtitleLabel.text = subtitle;
        [self recalculateWidth];
    });
}

-(void)updateProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle progress:(float)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.titleLabel.text = title;
        float clamped = progress;
        if (clamped < 0.0f) clamped = 0.0f;
        if (clamped > 1.0f) clamped = 1.0f;

        // For single-item progress, build a horizontal row: "• XX%" + bar on the same line
        if (!self.singleProgressRow) {
            // Remove subtitle label from vertical stack and place it into a horizontal row
            [self.vStack removeArrangedSubview:self.subtitleLabel];
            [self.subtitleLabel removeFromSuperview];

            UIStackView *row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.alignment = UIStackViewAlignmentCenter;
            row.spacing = 6.0f;
            row.translatesAutoresizingMaskIntoConstraints = NO;

            [row addArrangedSubview:self.subtitleLabel];
            [self ensureProgressView];
            [row addArrangedSubview:self.progressView];
            [self.progressView.widthAnchor constraintEqualToConstant:80.0f].active = YES;

            [self.vStack addArrangedSubview:row];
            self.singleProgressRow = row;
        }

        int percent = (int)roundf(clamped * 100.0f);
        self.subtitleLabel.text = [NSString stringWithFormat:@"• %d%%", percent];
        [self.progressView setProgress:clamped animated:YES];
        
        [self recalculateWidth];
    });
}

-(void)updateProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.titleLabel.text = title;
        self.subtitleLabel.text = subtitle;
        
        if (icon && self.progressIconView) {
            self.progressIconView.image = icon;
        }
        
        [self recalculateWidth];
    });
}

-(void)recalculateWidth {
    UIWindow *keyWindow = [self getKeyWindow];
    if (!keyWindow) return;
    
    // Calculate width directly from text (no layout pass needed since we measure text directly)
    CGFloat maxWidth = keyWindow.bounds.size.width - 40;
    CGFloat requiredWidth = [self calculateRequiredWidth];
    CGFloat toastWidth = MIN(maxWidth, requiredWidth);
    
    // Calculate required height based on new content
    CGFloat requiredHeight = [self calculateRequiredHeight:toastWidth];
    requiredHeight = MAX(kToastMinHeight, MIN(kToastMaxHeight, requiredHeight));
    
    // Update width and height constraints
    if (self.widthConstraint) {
        self.widthConstraint.constant = toastWidth;
    }
    if (self.heightConstraint) {
        self.heightConstraint.constant = requiredHeight;
    }
    
    // Animate the constraint changes smoothly
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.95
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [keyWindow layoutIfNeeded];
    } completion:nil];
}

-(void)completeProgressWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon url:(NSURL *)url {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only complete if this is still the active progress toast
        if (self != sProgressToast || !self.superview) {
            return;
        }
        
        // Tear down any progress UI so the final toast is a clean, static banner
        if (self.progressView) {
            [self.progressView removeFromSuperview];
            self.progressView = nil;
        }
        if (self.singleProgressRow) {
            // Remove the row, but we need to re-add subtitleLabel to vStack
            [self.singleProgressRow removeFromSuperview];
            self.singleProgressRow = nil;
            // Re-add subtitleLabel to vStack (it was moved to singleProgressRow, so it's no longer in vStack)
            [self.vStack addArrangedSubview:self.subtitleLabel];
        }
        if (self.multiProgressStack) {
            [self.multiProgressStack removeFromSuperview];
            self.multiProgressStack = nil;
        }
        self.multiProgressBars = nil;
        self.multiProgressTitles = nil;
        self.subtitleLabel.hidden = NO;
        
        // Set all content first (text, icon, URL) before calculating dimensions
        self.titleLabel.text = title;
        self.subtitleLabel.text = subtitle;
        
        if (icon && self.progressIconView) {
            self.progressIconView.image = icon;
            self.progressIconView.tintColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0];
        }
        
        // Set the URL for tap handling
        if (url) {
            self.openURL = url;
            // Add tap gesture if not already present
            BOOL hasTapGesture = NO;
            for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
                if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                    hasTapGesture = YES;
                    break;
                }
            }
            if (!hasTapGesture) {
                UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
                [self addGestureRecognizer:tapGesture];
            }
        }
        
        // Force immediate layout pass so labels update their intrinsicContentSize
        // This must happen BEFORE recalculateWidth to ensure accurate measurements
        [self setNeedsLayout];
        [self layoutIfNeeded];
        [self.titleLabel setNeedsLayout];
        [self.titleLabel layoutIfNeeded];
        [self.subtitleLabel setNeedsLayout];
        [self.subtitleLabel layoutIfNeeded];
        
        // Now recalculate width for new content (with updated intrinsic sizes)
        [self recalculateWidth];
        
        // Auto-hide after 3 seconds
        [self hideAfter:3.0];
    });
}

@end
