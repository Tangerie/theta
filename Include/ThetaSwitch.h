#import <UIKit/UIKit.h>

// Thin wrapper control that embeds Instagram's IGDSSwitch at runtime (if available),
// otherwise falls back to a compact UISwitch. Exposes a minimal on/off API.

@interface ThetaSwitch : UIControl
@property (nonatomic, assign, getter=isOn) BOOL on;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end


