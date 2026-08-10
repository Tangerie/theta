#import "Include/ThetaHelper.h"

static void (*orig_exploreRefresh)(id self, SEL _cmd, id arg1);
static void hook_exploreRefresh(id self, SEL _cmd, id arg1) {
    if (!ENABLED(@"Explore Refresh Confirmation")) {
        orig_exploreRefresh(self, _cmd, arg1);
        return;
    }

    [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!" description:@"Are you sure you want to refresh the Explore page?" actions:@[
        @{
            @"title": @"Yes, refresh it!",
            @"handler": ^(id sender) {
                orig_exploreRefresh(self, _cmd, arg1);
                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Refreshing now!" subtitle:@"This will only take a second." icon:[ThetaHelper imageFromEmojiString:@"🔄" width:60] autoHide:4 openURL:nil];
                }
            }
        },
        @{
            @"title": @"No, I'm good.",
            @"handler": ^(id sender) {
            }
        }
    ]];
}

void THRegisterExploreRefreshConfirmationHooks(void) {
    NullHookMessageEx(objc_getClass("IGExploreGridViewController"), @selector(_handleRefreshControlTriggered:), (void *)hook_exploreRefresh, &orig_exploreRefresh);
}