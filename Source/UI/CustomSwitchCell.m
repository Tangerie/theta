#import "Include/CustomSwitchCell.h"
#import "Include/ThetaHelper.h"
#import "Include/ThetaSwitch.h"

@implementation CustomSwitchCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self) {
        self.settingSwitch = [[ThetaSwitch alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:self.settingSwitch];
        self.infoButton = [UIButton buttonWithType:UIButtonTypeInfoLight];
        self.infoButton.tintColor = [ThetaHelper iotaPinkColor];
        [self.contentView addSubview:self.infoButton];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.textLabel.numberOfLines = 0;
        self.detailTextLabel.numberOfLines = 0;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // check if iOS 19+
    NSString *osVersion = [[UIDevice currentDevice] systemVersion];

	CGFloat leftPadding = 20.0;
	CGFloat rightPadding = 12.0;
	CGFloat interControlSpacing = 8.0;
	CGFloat textToControlSpacing = 12.0; // keep labels away from controls on the right
	CGFloat switchWidth = 52.0;
	CGFloat switchHeight = 32.0;
	CGFloat infoSize = 28.0;
	CGFloat ios19Extra = (osVersion.floatValue >= 19.0) ? 4.0 : 0.0;
	BOOL hasInfo = !self.infoButton.hidden;

	// Compute reserved width on the right for controls
	CGFloat reservedRight = rightPadding + switchWidth + ios19Extra;
	if (hasInfo) reservedRight += interControlSpacing + infoSize;
	// Add spacing so text never touches the control area
	reservedRight += textToControlSpacing;

	CGFloat maxLabelWidth = self.contentView.frame.size.width - leftPadding - reservedRight;
	if (maxLabelWidth < 60.0) maxLabelWidth = 60.0;

	// Measure labels based on available width
	CGSize titleSize = [self.textLabel sizeThatFits:CGSizeMake(maxLabelWidth, CGFLOAT_MAX)];
	CGSize detailSize = [self.detailTextLabel sizeThatFits:CGSizeMake(maxLabelWidth, CGFLOAT_MAX)];

	// Layout labels
	CGFloat topPadding = 10.0;
	self.textLabel.frame = CGRectMake(leftPadding, topPadding, maxLabelWidth, titleSize.height);
	self.detailTextLabel.frame = CGRectMake(leftPadding, CGRectGetMaxY(self.textLabel.frame) + 2.0, maxLabelWidth, detailSize.height);

	// Determine content height (used for vertical centering of controls)
	CGFloat bottomPadding = 10.0;
	CGFloat computedContentHeight = MAX(CGRectGetMaxY(self.detailTextLabel.frame) + bottomPadding, switchHeight + topPadding + bottomPadding);
	CGFloat currentContentHeight = self.contentView.bounds.size.height > 0 ? self.contentView.bounds.size.height : computedContentHeight;

	// Layout right-side controls (switch, optional info)
	if (hasInfo) {
		// Place switch at the far right, info button to its left
		self.settingSwitch.frame = CGRectMake(self.contentView.frame.size.width - rightPadding - switchWidth - ios19Extra,
											  floor(currentContentHeight / 2.0 - switchHeight / 2.0),
											  switchWidth,
											  switchHeight);
		self.infoButton.frame = CGRectMake(CGRectGetMinX(self.settingSwitch.frame) - interControlSpacing - infoSize,
										   floor(currentContentHeight / 2.0 - infoSize / 2.0),
										   infoSize,
										   infoSize);
	} else {
		self.settingSwitch.frame = CGRectMake(self.contentView.frame.size.width - rightPadding - switchWidth - ios19Extra,
											  floor(currentContentHeight / 2.0 - switchHeight / 2.0),
											  switchWidth,
											  switchHeight);
	}
}
@end
