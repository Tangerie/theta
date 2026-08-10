static void (*orig_shakeToOpen)(id self, SEL _cmd, int arg1);
static void hook_shakeToOpen(id self, SEL _cmd, int arg1) {
    @try {
        if (!ENABLED(@"Shake To Open")) {
            orig_shakeToOpen(self, _cmd, arg1);
            return;
        }
        
        if (arg1 == 1) {
            UIViewController *topController = [ThetaHelper topViewController];
            if (!topController) {
                return;
            }
            
            // Check if settings are already open
            if ([topController isKindOfClass:NSClassFromString(@"SettingsViewController")] || 
                [topController.presentedViewController isKindOfClass:NSClassFromString(@"SettingsViewController")] ||
                [topController isKindOfClass:[%c(IGPartialModalSheetViewController) class]]) {
                return;
            }
            
            // Present settings
            SettingsViewController *vc = [[SettingsViewController alloc] init];
            if (!vc) {
                NSLog(@"Failed to create SettingsViewController");
                return;
            }
            
            UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:vc];
            if (!navController) {
                NSLog(@"Failed to create NavigationController");
                return;
            }
            
            navController.modalPresentationStyle = UIModalPresentationPageSheet;
            UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
            if (!rootViewController) {
                NSLog(@"No root view controller found");
                return;
            }
            
            [rootViewController presentViewController:navController animated:YES completion:nil];
        }
    } @catch (NSException *exception) {
        NSLog(@"Error in shake to open: %@", exception);
        // Fallback to original behavior
        orig_shakeToOpen(self, _cmd, arg1);
    }
}

void THRegisterShakeToOpenHooks(void) {
    NullHookMessageEx(objc_getClass("UIMotionEvent"), @selector(setShakeState:), (void *)hook_shakeToOpen, &orig_shakeToOpen);
}