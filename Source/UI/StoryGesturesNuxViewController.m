#import "Include/StoryGesturesNuxViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "Include/ThetaHelper.h"

@interface StoryGesturesNuxViewController ()
@property (nonatomic, strong) CAEmitterLayer *confettiLayer;
@property (nonatomic, strong) NSMutableArray<UIView *> *rowAnimatedViews;
@property (nonatomic, assign) BOOL didAnimateRows;
@end

@implementation StoryGesturesNuxViewController

- (instancetype)init {
	self = [super init];
	if (self) {
		self.modalPresentationStyle = UIModalPresentationOverFullScreen;
		self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
	}
	return self;
}

- (UIBlurEffectStyle)preferredBlurStyle {
    return UIBlurEffectStyleSystemUltraThinMaterialDark;
}

- (void)loadView {
	[super loadView];
	self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.clearColor;
	self.rowAnimatedViews = [NSMutableArray array];

	UIBlurEffect *effect = [UIBlurEffect effectWithStyle:[self preferredBlurStyle]];
	UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
	blurView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:blurView];
	[NSLayoutConstraint activateConstraints:@[
		[blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
	]];

	// Confetti container between blur and content
	UIView *confettiContainer = [[UIView alloc] init];
	confettiContainer.translatesAutoresizingMaskIntoConstraints = NO;
	confettiContainer.backgroundColor = UIColor.clearColor;
	[blurView.contentView addSubview:confettiContainer];
	[NSLayoutConstraint activateConstraints:@[
		[confettiContainer.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
		[confettiContainer.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor],
		[confettiContainer.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
		[confettiContainer.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor]
	]];

	UIView *contentView = [[UIView alloc] init];
	contentView.translatesAutoresizingMaskIntoConstraints = NO;
	contentView.backgroundColor = UIColor.clearColor;
	[blurView.contentView addSubview:contentView];
	UILayoutGuide *readable = blurView.contentView.readableContentGuide;
	[NSLayoutConstraint activateConstraints:@[
		[contentView.centerXAnchor constraintEqualToAnchor:blurView.contentView.centerXAnchor],
		[contentView.centerYAnchor constraintEqualToAnchor:blurView.contentView.centerYAnchor],
		[contentView.leadingAnchor constraintEqualToAnchor:readable.leadingAnchor],
		[contentView.trailingAnchor constraintEqualToAnchor:readable.trailingAnchor]
	]];

	UILabel *titleLabel = [self makeTitleLabel:@"Hello and welcome!"];
	UILabel *subtitleLabel = [self makeSubtitleLabel:@"Thank you for using Theta!"];
	UIStackView *headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
	headerStack.axis = UILayoutConstraintAxisVertical;
	headerStack.alignment = UIStackViewAlignmentCenter;
	headerStack.spacing = 8;
	headerStack.translatesAutoresizingMaskIntoConstraints = NO;
	[contentView addSubview:headerStack];

	// Large wave emoji above header
	UIImageView *waveView = [[UIImageView alloc] init];
	waveView.translatesAutoresizingMaskIntoConstraints = NO;
	waveView.contentMode = UIViewContentModeScaleAspectFit;
	waveView.image = [ThetaHelper imageFromEmojiString:@"👋" width:80];
	[contentView addSubview:waveView];

	// Rows: icon + labels
	NSArray<NSArray<NSString *> *> *rows = @[
		@[@"hand.point.up.left.fill", @"Opening Theta's settings.", @"Long press the home tab."],
        @[@"exclamationmark.triangle", @"Reporting bugs/issues.", @"Submit bugs in the Discord."],
        @[@"face.smiling", @"Be sure to have fun!", @"Make the most of Theta!"]
	];

	UIStackView *rowsStack = [[UIStackView alloc] init];
	rowsStack.axis = UILayoutConstraintAxisVertical;
	rowsStack.alignment = UIStackViewAlignmentCenter;
	rowsStack.spacing = 24;
	rowsStack.translatesAutoresizingMaskIntoConstraints = NO;
	[contentView addSubview:rowsStack];

	for (NSArray *row in rows) {
		UIImageView *icon = [[UIImageView alloc] initWithImage:[self systemImage:row[0]]];
		icon.contentMode = UIViewContentModeScaleAspectFit;
		icon.tintColor = [self primaryTextColor];
		icon.translatesAutoresizingMaskIntoConstraints = NO;
		[icon.heightAnchor constraintEqualToConstant:28].active = YES;
		[icon.widthAnchor constraintEqualToConstant:28].active = YES;

		UILabel *primary = [self makeRowPrimaryLabel:row[1]];
		UILabel *secondary = [self makeRowSecondaryLabel:row[2]];
		UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[primary, secondary]];
		textStack.axis = UILayoutConstraintAxisVertical;
		textStack.spacing = 4;
		textStack.alignment = UIStackViewAlignmentCenter;

		UIStackView *rowStack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, textStack]];
		rowStack.axis = UILayoutConstraintAxisHorizontal;
		rowStack.alignment = UIStackViewAlignmentCenter;
		rowStack.spacing = 16;
		// Prepare for cascade animation (slide-in from right)
		rowStack.alpha = 0.0;
		rowStack.transform = CGAffineTransformMakeTranslation(60.0, 0.0);
		[rowsStack addArrangedSubview:rowStack];

		// Constrain a fixed icon column width so all icons align in a straight vertical line
		[icon.widthAnchor constraintEqualToConstant:32].active = YES;

		// Track for later animation
		[self.rowAnimatedViews addObject:rowStack];
	}

	UIButton *cta = [self makeCTAButton:@"Got it, thanks!"];
	cta.translatesAutoresizingMaskIntoConstraints = NO;
	[contentView addSubview:cta];

	[NSLayoutConstraint activateConstraints:@[
		[waveView.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:-80],
		[waveView.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
		[waveView.heightAnchor constraintEqualToConstant:96],
		[waveView.widthAnchor constraintEqualToConstant:96],
		[headerStack.topAnchor constraintEqualToAnchor:waveView.bottomAnchor constant:40],
		[headerStack.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
		[rowsStack.topAnchor constraintEqualToAnchor:headerStack.bottomAnchor constant:60],
		[rowsStack.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
		[rowsStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:contentView.leadingAnchor],
		[rowsStack.trailingAnchor constraintLessThanOrEqualToAnchor:contentView.trailingAnchor],
		[cta.topAnchor constraintEqualToAnchor:rowsStack.bottomAnchor constant:60],
		[cta.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
		[cta.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor]
	]];
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	if (!self.confettiLayer) {
		UIVisualEffectView *blurView = (UIVisualEffectView *)self.view.subviews.firstObject;
		UIView *confettiContainer = blurView.contentView.subviews.firstObject;
		[self setupConfettiInView:confettiContainer];
	}
	[self startConfetti];

	// Cascade slide-in for rows once
	if (!self.didAnimateRows && self.rowAnimatedViews.count > 0) {
		self.didAnimateRows = YES;
		NSTimeInterval baseDelay = 0.05;
		NSTimeInterval perItem = 0.06; // cascading effect
		for (NSUInteger i = 0; i < self.rowAnimatedViews.count; i++) {
			UIView *v = self.rowAnimatedViews[i];
			NSTimeInterval delay = baseDelay + perItem * i;
			[UIView animateWithDuration:0.42
							  delay:delay
							options:UIViewAnimationOptionCurveEaseOut
						 animations:^{
							v.alpha = 1.0;
							v.transform = CGAffineTransformIdentity;
						 }
					 completion:nil];
		}
	}
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopConfetti];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	UIVisualEffectView *blurView = (UIVisualEffectView *)self.view.subviews.firstObject;
	if (![blurView isKindOfClass:[UIVisualEffectView class]]) return;
	UIView *confettiContainer = blurView.contentView.subviews.firstObject;
	if (!self.confettiLayer || !confettiContainer) return;
	self.confettiLayer.frame = confettiContainer.bounds;
	self.confettiLayer.emitterPosition = CGPointMake(CGRectGetMidX(confettiContainer.bounds), -40);
	self.confettiLayer.emitterSize = CGSizeMake(confettiContainer.bounds.size.width, 1);
}

- (UIColor *)primaryTextColor {
	return [UIColor whiteColor];
}

- (UIColor *)secondaryTextColor {
	return [[UIColor whiteColor] colorWithAlphaComponent:0.7];
}


- (UIImage *)systemImage:(NSString *)name {
	UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
	UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
	return img;
}

- (UILabel *)makeTitleLabel:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
	label.textColor = [self primaryTextColor];
	label.textAlignment = NSTextAlignmentLeft;
	label.numberOfLines = 1;
	return label;
}

- (UILabel *)makeSubtitleLabel:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
	label.textColor = [self secondaryTextColor];
	label.textAlignment = NSTextAlignmentLeft;
	label.numberOfLines = 2;
	return label;
}

- (UILabel *)makeRowPrimaryLabel:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
	label.textColor = [self primaryTextColor];
	label.numberOfLines = 0;
	label.lineBreakMode = NSLineBreakByWordWrapping;
	label.textAlignment = NSTextAlignmentCenter;
	return label;
}

- (UILabel *)makeRowSecondaryLabel:(NSString *)text {
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
	label.textColor = [self secondaryTextColor];
	label.numberOfLines = 0;
	label.lineBreakMode = NSLineBreakByWordWrapping;
	label.textAlignment = NSTextAlignmentCenter;
	return label;
}

- (UIButton *)makeCTAButton:(NSString *)text {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setTitle:text forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
	[button setTitleColor:[self primaryTextColor] forState:UIControlStateNormal];
	[button addTarget:self action:@selector(dismissTapped:) forControlEvents:UIControlEventTouchUpInside];
	return button;
}

- (void)dismissTapped:(id)sender {
	// ThetaFirst is marked when the NUX is first scheduled (see THTweak.m).
	[self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Confetti

- (void)setupConfettiInView:(UIView *)container {
	CAEmitterLayer *emitter = [CAEmitterLayer layer];
	emitter.frame = container.bounds;
	emitter.emitterPosition = CGPointMake(CGRectGetMidX(container.bounds), -40);
	emitter.emitterSize = CGSizeMake(container.bounds.size.width, 1);
	emitter.emitterShape = kCAEmitterLayerLine;
	emitter.emitterMode = kCAEmitterLayerOutline;
	emitter.renderMode = kCAEmitterLayerUnordered;
	emitter.seed = arc4random();
	emitter.birthRate = 0.0;

	NSArray<UIColor *> *colors = @[
		[UIColor systemPinkColor], [UIColor systemBlueColor], [UIColor systemGreenColor],
		[UIColor systemOrangeColor], [UIColor systemYellowColor], [UIColor systemPurpleColor]
	];

	NSMutableArray<CAEmitterCell *> *cells = [NSMutableArray array];
	for (UIColor *color in colors) {
		// Thin confetti strip
		CAEmitterCell *strip = [CAEmitterCell emitterCell];
		strip.contents = (__bridge id)[self confettiStripImageWithColor:color].CGImage;
		strip.birthRate = 2.4;
		strip.lifetime = 10.0;
		strip.velocity = 110;
		strip.velocityRange = 60;
		strip.yAcceleration = 140;
		strip.scale = 0.9;
		strip.scaleRange = 0.35;
		strip.spin = 4.0;
		strip.spinRange = 5.0;
		strip.alphaRange = 0.2;
		strip.alphaSpeed = -0.02;
		strip.emissionLongitude = M_PI;
		strip.emissionRange = (M_PI / 3.0);
		[cells addObject:strip];

		// Small confetti chip
		CAEmitterCell *chip = [CAEmitterCell emitterCell];
		chip.contents = (__bridge id)[self confettiChipImageWithColor:color].CGImage;
		chip.birthRate = 1.0;
		chip.lifetime = 10.0;
		chip.velocity = 90;
		chip.velocityRange = 70;
		chip.yAcceleration = 140;
		chip.scale = 0.8;
		chip.scaleRange = 0.25;
		chip.spin = 2.6;
		chip.spinRange = 4.0;
		chip.alphaRange = 0.2;
		chip.alphaSpeed = -0.02;
		chip.emissionLongitude = M_PI;
		chip.emissionRange = M_PI_4;
		[cells addObject:chip];
	}

	emitter.emitterCells = cells;
	[container.layer addSublayer:emitter];
	self.confettiLayer = emitter;
	container.layer.masksToBounds = YES;
}

- (UIImage *)confettiStripImageWithColor:(UIColor *)color {
	CGSize size = CGSizeMake(5, 12);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:2];
	[color setFill];
	[path fill];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

- (UIImage *)confettiChipImageWithColor:(UIColor *)color {
	CGSize size = CGSizeMake(6, 6);
	UIGraphicsBeginImageContextWithOptions(size, NO, 0);
	UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:1.5];
	[color setFill];
	[path fill];
	UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return img;
}

- (void)startConfetti {
	if (!self.confettiLayer) return;
	// Pre-roll the emitter timeline so particles are already in-flight above the top edge
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.confettiLayer.beginTime = CACurrentMediaTime() - 0.6; // simulate 0.6s elapsed
	self.confettiLayer.birthRate = 1.0; // steady-state immediately; beginTime offset prevents visible spurt
	[CATransaction commit];
}

- (void)stopConfetti {
	if (!self.confettiLayer) return;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	CABasicAnimation *fadeOut = [CABasicAnimation animationWithKeyPath:@"birthRate"];
	fadeOut.fromValue = @1.0;
	fadeOut.toValue = @0.0;
	fadeOut.duration = 0.4;
	fadeOut.fillMode = kCAFillModeForwards;
	fadeOut.removedOnCompletion = NO;
	fadeOut.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
	[CATransaction setCompletionBlock:^{
		self.confettiLayer.birthRate = 0.0;
		[self.confettiLayer removeAnimationForKey:@"confettiStop"];
	}];
	[self.confettiLayer addAnimation:fadeOut forKey:@"confettiStop"];
	[CATransaction commit];
}

@end


