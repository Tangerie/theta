#import "Include/ThetaSwitch.h"
#import "Include/ThetaHelper.h"
#import "Include/InstagramHeaders.h"

@interface ThetaSwitch ()
@property (nonatomic, strong) UIControl *embeddedSwitch; // IGDSSwitch or UISwitch
@end

@implementation ThetaSwitch

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:CGRectMake(frame.origin.x, frame.origin.y, 46, 24)];
	if (self) {
		Class IGDSSwitchClass = NSClassFromString(@"IGDSSwitch");
		if (IGDSSwitchClass) {
			self.embeddedSwitch = [[IGDSSwitchClass alloc] init];
			if ([self.embeddedSwitch respondsToSelector:@selector(setOnTintColor:)]) {
				[(id)self.embeddedSwitch performSelector:@selector(setOnTintColor:) withObject:[ThetaHelper iotaPinkColor]];
			}
		} else {
            NSLog(@"IGDSSwitchClass not found");
			self.embeddedSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
			((UISwitch *)self.embeddedSwitch).onTintColor = [ThetaHelper iotaPinkColor];
		}
		[self addSubview:self.embeddedSwitch];
		self.embeddedSwitch.translatesAutoresizingMaskIntoConstraints = NO;
		[NSLayoutConstraint activateConstraints:@[
			[self.embeddedSwitch.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
			[self.embeddedSwitch.centerXAnchor constraintEqualToAnchor:self.centerXAnchor]
		]];

		[self.embeddedSwitch addTarget:self action:@selector(valueChangedForwarded:) forControlEvents:UIControlEventValueChanged];
	}
	return self;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(46, 24); }

- (BOOL)isOn {
	if ([self.embeddedSwitch isKindOfClass:[UISwitch class]]) return ((UISwitch *)self.embeddedSwitch).isOn;
	if ([self.embeddedSwitch respondsToSelector:@selector(isOn)]) return ((BOOL (*)(id,SEL))[self.embeddedSwitch methodForSelector:@selector(isOn)])(self.embeddedSwitch, @selector(isOn));
	return NO;
}

- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }

- (void)setOn:(BOOL)on animated:(BOOL)animated {
	if ([self.embeddedSwitch isKindOfClass:[UISwitch class]]) {
		[(UISwitch *)self.embeddedSwitch setOn:on animated:animated];
		return;
	}
	if ([self.embeddedSwitch respondsToSelector:@selector(setOn:animated:)]) {
		((void (*)(id,SEL,BOOL,BOOL))[self.embeddedSwitch methodForSelector:@selector(setOn:animated:)])(self.embeddedSwitch, @selector(setOn:animated:), on, animated);
	}
}

- (void)valueChangedForwarded:(id)sender {
	[self sendActionsForControlEvents:UIControlEventValueChanged];
}

@end


