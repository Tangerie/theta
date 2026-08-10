#import <UIKit/UIKit.h>
#define IOTA_PINK [UIColor colorWithRed:1.0 green:0.412 blue:0.706 alpha:1.0]

@interface CustomSwitchCell : UITableViewCell
@property (nonatomic, strong) UIControl *settingSwitch; // ThetaSwitch instance at runtime
@property (nonatomic, strong) UIButton *infoButton; // Optional info button shown when additional help is available
@end
