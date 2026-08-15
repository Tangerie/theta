#import <objc/runtime.h>
#import <stdlib.h>

static void (*orig_deviceLockedStatusLogger)(id self, SEL _cmd, id source, id ndid, id extra);
static void hook_deviceLockedStatusLogger(id self, SEL _cmd, id source, id ndid, id extra) {
    NSLog(@"device status logger returning nothing");
    return;
}

static void (*orig_forcedLogoutPushHandler)(id self, SEL _cmd, id userID, id token, id authLoginType);
static void hook_forcedLogoutPushHandler(id self, SEL _cmd, id userID, id token, id authLoginType) {
    NSLog(@"forced logout push handler returning nothing");
    return;
}

static void (*orig_handleForcedLogoutLoginPush)(id self, SEL _cmd, id push, id presentedUserSession, id deviceSession, id appNavigationHandler, id completion);
static void hook_handleForcedLogoutLoginPush(id self, SEL _cmd, id push, id presentedUserSession, id deviceSession, id appNavigationHandler, id completion) {
    NSLog(@"handle forced logout login push returning nothing");
    if (completion) {
        ((void (^)(void))completion)();
    }
    return;
}

static id (*orig_objectForKey)(id self, SEL _cmd, NSString *key);
static id hook_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"com.facebook.deviceLockedStatusFlag"] || [key isEqualToString:@"fb_locked_device_flag"]) {
        return nil;
    }
    if (!orig_objectForKey) return nil;
    return orig_objectForKey(self, _cmd, key);
}

static BOOL (*orig_boolForKey)(id self, SEL _cmd, NSString *key);
static BOOL hook_boolForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"com.facebook.deviceLockedStatusFlag"] || [key isEqualToString:@"fb_locked_device_flag"]) {
        return NO;
    }
    if (!orig_boolForKey) return NO;
    return orig_boolForKey(self, _cmd, key);
}

void THRegisterDeferredDBBHooks(void) {
    SEL sel = @selector(queryAndLogDeviceLockedStatusWithSource:ndid:extra:);
    const char *classNames[] = {
        "_TtC24DeviceLockedStatusLogger26IGDeviceLockedStatusLogger",
        "IGDeviceLockedStatusLogger",
        NULL
    };
    for (int i = 0; classNames[i]; i++) {
        Class c = objc_getClass(classNames[i]);
        if (c && class_getInstanceMethod(c, sel)) {
            NullHookMessageEx(c, sel, (void *)hook_deviceLockedStatusLogger, (void *)&orig_deviceLockedStatusLogger);
            break;
        }
    }

    SEL selPush = @selector(_handleForcedLogoutLoginPush:presentedUserSession:deviceSession:appNavigationHandler:completion:);
    SEL selForce = @selector(handleForceLogoutLoginWithUserID:token:authLoginType:);

    BOOL didHookPush = NO;
    BOOL didHookForce = NO;
    const char *pushHandlerNames[] = {
        "_TtC17IGPushCoordinator25IGForcedLogoutPushHandler",
        "IGForcedLogoutPushHandler",
        NULL
    };
    for (int i = 0; pushHandlerNames[i]; i++) {
        Class pushHandler = objc_getClass(pushHandlerNames[i]);
        if (!pushHandler) continue;
        if (!didHookForce && class_getInstanceMethod(pushHandler, selForce)) {
            NullHookMessageIfPresent(pushHandler, selForce, (void *)hook_forcedLogoutPushHandler, (void *)&orig_forcedLogoutPushHandler);
            didHookForce = YES;
        }
        if (!didHookPush && class_getInstanceMethod(pushHandler, selPush)) {
            NullHookMessageIfPresent(pushHandler, selPush, (void *)hook_handleForcedLogoutLoginPush, (void *)&orig_handleForcedLogoutLoginPush);
            didHookPush = YES;
        }
    }

    if (!didHookPush) {
        int n = objc_getClassList(NULL, 0);
        if (n > 0) {
            Class *classes = (Class *)malloc((size_t)n * sizeof(Class));
            n = objc_getClassList(classes, n);
            for (int i = 0; i < n; i++) {
                if (class_getInstanceMethod(classes[i], selPush)) {
                    NullHookMessageEx(classes[i], selPush, (void *)hook_handleForcedLogoutLoginPush, (void *)&orig_handleForcedLogoutLoginPush);
                    break;
                }
            }
            free(classes);
        }
    }

    // NSUserDefaults is hot-path — only install if we successfully capture orig.
    Class ud = objc_getClass("NSUserDefaults");
    if (ud) {
        if (!ThetaInstallMessageHook(ud, @selector(objectForKey:), (void *)hook_objectForKey, (void *)&orig_objectForKey, NO) || !orig_objectForKey) {
            orig_objectForKey = NULL;
            NSLog(@"[Theta] DBB: skipped objectForKey: hook (no orig)");
        }
        if (!ThetaInstallMessageHook(ud, @selector(boolForKey:), (void *)hook_boolForKey, (void *)&orig_boolForKey, NO) || !orig_boolForKey) {
            // If bool hook installed without orig, undo is hard; null-check in hook avoids PC=0.
            if (!orig_boolForKey) NSLog(@"[Theta] DBB: boolForKey: hook missing orig");
        }
    }
}