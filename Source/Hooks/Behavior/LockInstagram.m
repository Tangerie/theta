static BOOL isAuthenticationShowed = FALSE;
static void (*orig_applicationDidBecomeActive)(id self, SEL _cmd, id arg1);
static void hook_applicationDidBecomeActive(id self, SEL _cmd, id arg1) {
    orig_applicationDidBecomeActive(self, _cmd, arg1);

    if (ENABLED(@"Lock Instagram") && !isAuthenticationShowed) {
        UIViewController *rootController = [[self window] rootViewController];
		SecurityViewController *securityViewController = [SecurityViewController new];
		securityViewController.modalPresentationStyle = UIModalPresentationOverFullScreen;
		[rootController presentViewController:securityViewController animated:YES completion:nil];
		isAuthenticationShowed = TRUE;
    }
}

static void (*orig_applicationWillEnterForeground)(id self, SEL _cmd, id arg1);
static void hook_applicationWillEnterForeground(id self, SEL _cmd, id arg1) {
    orig_applicationWillEnterForeground(self, _cmd, arg1);
    isAuthenticationShowed = FALSE;
}

void THRegisterLockInstagramHooks(void) {
    NullHookMessageEx(objc_getClass("IGInstagramAppDelegate"), @selector(applicationDidBecomeActive:), (void *)hook_applicationDidBecomeActive, &orig_applicationDidBecomeActive);
    NullHookMessageEx(objc_getClass("IGInstagramAppDelegate"), @selector(applicationWillEnterForeground:), (void *)hook_applicationWillEnterForeground, &orig_applicationWillEnterForeground);
}