static void (*orig_screenshotSuppression)(id self, SEL _cmd);
static void hook_screenshotSuppression(id self, SEL _cmd) {
    if (!ENABLED(@"Screenshot Suppression")) {
        return orig_screenshotSuppression(self, _cmd);
    }
}

static void (*orig_screenshotSuppression2)(id self, SEL _cmd, BOOL isProtected);
static void hook_screenshotSuppression2(id self, SEL _cmd, BOOL isProtected) {
    if (!ENABLED(@"Screenshot Suppression")) {
        return orig_screenshotSuppression2(self, _cmd, isProtected);
    }
    
    return orig_screenshotSuppression2(self, _cmd, NO);
}

static void (*orig_screenRecord)(id self, SEL _cmd, id state);
static void hook_screenRecord(id self, SEL _cmd, id state) {
    if (!ENABLED(@"Screenshot Suppression")) {
        return orig_screenRecord(self, _cmd, state);
    }
}

void THRegisterScreenshotProtectionProviderHooks(void) {
    NullHookMessageEx(objc_getClass("IGScreenCaptureProtection.IGScreenCaptureProtectionViewProvider"), @selector(setIsProtected:), (void *)hook_screenshotSuppression2, &orig_screenshotSuppression2);
    NullHookMessageEx(objc_getClass("IGScreenCaptureProtection.IGScreenCaptureProtectionViewProvider"), @selector(initWithIsProtected:), (void *)hook_screenshotSuppression2, &orig_screenshotSuppression2);
}

void THRegisterScreenshotObserverHook(void) {
    NullHookMessageEx(objc_getClass("IGScreenshotObserver"), @selector(_onTakenScreenshot), (void *)hook_screenshotSuppression, &orig_screenshotSuppression);
    NullHookMessageEx(objc_getClass("IGScreenshotObserver"), @selector(_screenCaptureStateDidChange:), (void *)hook_screenRecord, &orig_screenRecord);
}