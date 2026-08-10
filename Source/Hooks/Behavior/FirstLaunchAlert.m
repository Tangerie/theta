#import "Include/ThetaHelper.h"

static id (*orig_userSession)(id self, SEL _cmd);
static id hook_userSession(id self, SEL _cmd) {
    static BOOL alertShown = NO;
    
    if (!alertShown && ![[NSUserDefaults standardUserDefaults] objectForKey:@"ThetaFirst"]) {
        alertShown = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (![[NSUserDefaults standardUserDefaults] objectForKey:@"ThetaFirst"]) {
                [ThetaHelper showCustomAlertWithActions:@"Hello and Welcome!" description:@"Thank you for using Theta!\n\nPlease make sure to report any bugs or issues in the Discord server in Theta settings.\n\nTo open Theta's settings, tap and hold the home tab in the bottom left.\n\nEnjoy!" actions:@[
                    @{
                        @"title": @"Let's Go!",
                        @"handler": ^(id sender) {
                            [[NSUserDefaults standardUserDefaults] setValue:@"ThetaFirst" forKey:@"ThetaFirst"];
                            [[NSUserDefaults standardUserDefaults] synchronize];
                        }
                    }
                ]];
            }
        });
    }
    
    return orig_userSession(self, _cmd);
}