#import "Include/ThetaHelper.h"

static void theta_runVanishModeConfirmation(void (^invokeOrig)(void)) {
    if (!ENABLED(@"Disappearing DM Confirmation")) {
        invokeOrig();
        return;
    }
    [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!" description:@"Are you sure you want to toggle disappearing messages?" actions:@[
        @{
            @"title": @"Yes",
            @"handler": ^(__unused id sender) {
                invokeOrig();
            }
        },
        @{
            @"title": @"No",
            @"handler": ^(__unused id sender) {
            }
        }
    ]];
}

static void (*orig_handleBottomSwipeableScrollUpdate)(id self, SEL _cmd);
static void hook_handleBottomSwipeableScrollUpdate(id self, SEL _cmd) {
    theta_runVanishModeConfirmation(^{ orig_handleBottomSwipeableScrollUpdate(self, _cmd); });
}

void THRegisterVanishModeConfirmationHooks(void) {
    Class c = objc_getClass("IGDirectDisappearingModeSwipeHandler");
    if (!c)
        return;
    NullHookMessageEx(c, @selector(handleBottomSwipeableScrollUpdate), (void *)hook_handleBottomSwipeableScrollUpdate,
                      &orig_handleBottomSwipeableScrollUpdate);
}
