#import "Include/ThetaHelper.h"

static void (*orig_followConfirmation)(id self, SEL _cmd);
static void hook_followConfirmation(id self, SEL _cmd) {
    if (!ENABLED(@"Follow Confirmation")) {
        orig_followConfirmation(self, _cmd);
        return;
    }
    
    NSInteger userFollowStatus = [[[self valueForKey:@"user"] valueForKey:@"followStatus"] integerValue];
    
    if (userFollowStatus == 2) {
        [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!" description:@"Are you sure you want to follow this user?" actions:@[
            @{
                @"title": @"Yes, follow them!",
                @"handler": ^(id sender) {
                    orig_followConfirmation(self, _cmd);
                }
            },
            @{
                @"title": @"No, I'm good.",
                @"handler": ^(id sender) {
                    // Do nothing, just cancel
                }
            }
        ]];
    } else {
        orig_followConfirmation(self, _cmd);
    }
}

void THRegisterFollowConfirmationHooks(void) {
    NullHookMessageEx(objc_getClass("IGFollowController"), @selector(_didPressFollowButton), (void *)hook_followConfirmation, &orig_followConfirmation);
}