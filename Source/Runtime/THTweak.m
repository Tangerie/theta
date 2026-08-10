/*
 * Tweak entry point: install all feature hooks (no DRM / license gates).
 */

static void InitializeHooks(void) {
    if (hooksInitialized) return;
    hooksInitialized = YES;

    THRegisterStoryAutoAdvanceHooks();
    THRegisterTabBarHooks();
    THRegisterExternalBrowserHooks();
    THRegisterDateFormatHooks();
    THRegisterLiquidGlassHooks();
    THRegisterTapControlsHooks();
    THRegisterFullLastActiveHooks();
    THRegisterSendFileHooks();
    THRegisterNavigationHooks();
    THRegisterHideAdsCoreHooks();
    THRegisterHideFeedFilteringHooks();
    THRegisterSavePostHook();
    THRegisterHideTypingIndicatorHooks();
    THRegisterKeepDeletedMessagesHooks();
    THRegisterSaveProfilePicturesHooks();
    THRegisterScreenshotProtectionProviderHooks();
    THRegisterSundialViewerUFIHooks();
    THRegisterFollowStatusIndicatorHooks();
    THRegisterHideSearchesRecentStoreHooks();
    THRegisterLikeConfirmationHooks();
    THRegisterFollowConfirmationHooks();
    THRegisterLockInstagramHooks();
    THRegisterScreenshotObserverHook();
    THRegisterHideExploreGridHooks();
    THRegisterCallConfirmationHooks();
    THRegisterMarkAsSeenThreadAndReactionHooks();
    THRegisterPrivateVideoGhostHooks();
    THRegisterStorySeenLocalOnlyHooks();
    THRegisterStoryGhostHooks();
    THRegisterHideTabsHooks();
    THRegisterDismissIGDSPromoDialogHooks();
    THRegisterNoBrainrotHooks();
    THRegisterExploreRefreshConfirmationHooks();
    THRegisterBypassCharacterLimitHooks();
    THRegisterMarkAsSeenSeenOnSendHook();
    THRegisterShakeToOpenHooks();
    THRegisterSettingsButtonHooks();
    THRegisterCreateGroupConfirmationHooks();
    THRegisterHideCreateGroupButtonHooks();
    THRegisterBypassReelPasswordHooks();
    THRegisterHideSuggestedReelsHooks();
    THRegisterSaveAudioMessageHooks();
    THRegisterUploadAudioMessageHooks();
    THRegisterHideCreateButtonHooks();
    THRegisterVanishModeConfirmationHooks();
    THRegisterStorySeenOnHooks();
    THRegisterLiveBrowseTweaksHooks();
    THRegisterCommentTextCopyHooks();
    THRegisterGetStoryMentionsHooks();
    THRegisterSaveAudioNotesHooks();
    THRegisterSortUserGridPostsHooks();
    THRegisterFeedUsernameSpoofHooks();
    THRegisterToastDismissHooks();
    THRegisterHideTestFlightNagHooks();

    dispatch_async(dispatch_get_main_queue(), ^{
        THRegisterDeferredDBBHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (ENABLED(@"Load Banner")) {
                NSString *title = [NSString stringWithFormat:@"Theta %s | Instagram %s", THETA_VERSION, appVersion.UTF8String];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    UIImage *icon = [ThetaHelper imageFromEmojiString:@"🚀" width:300];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [ThetaHelper showLoadToast:@"Success!" subtitle:title icon:icon autoHide:4 openURL:nil];
                    });
                });
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // One-shot: mark seen BEFORE presenting so a present/NUX crash cannot loop forever.
            NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
            if ([defs objectForKey:@"ThetaFirst"]) return;
            [defs setValue:@"ThetaFirst" forKey:@"ThetaFirst"];
            [defs synchronize];

            @try {
                UIViewController *top = [ThetaHelper topViewController];
                if (!top || top.beingPresented || top.isBeingDismissed) return;
                // Avoid stacking on another fullscreen modal (e.g. TestFlight nag).
                if (top.presentedViewController) return;
                NSString *topName = NSStringFromClass(object_getClass(top));
                if ([topName containsString:@"TestFlight"] || [topName containsString:@"SecurityViewController"]) return;

                StoryGesturesNuxViewController *vc = [StoryGesturesNuxViewController new];
                vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
                [top presentViewController:vc animated:YES completion:nil];
            } @catch (NSException *e) {
                NSLog(@"[Theta] NUX presentation failed: %@", e);
            }
        });

        // Log remaining hook misses; don't block launch with an alert.
        // Use UTF8 %s so Console doesn't redact lines as <private>.
        FailedHooksEnsureInit();
        [sFailedHookLock lock];
        NSArray *failed = [sFailedHookLines copy];
        [sFailedHookLines removeAllObjects];
        [sFailedHookLock unlock];
        if (failed.count) {
            // fprintf bypasses os_log privacy redaction (<private>).
            fprintf(stderr, "[Theta] %lu hook install miss(es):\n", (unsigned long)failed.count);
            for (NSString *line in failed) {
                fprintf(stderr, "[Theta] miss: %s\n", line.UTF8String ?: "(null)");
            }
            fflush(stderr);
        }
    });
}

#ifdef SIDELOAD
static void RunSideloadSetupOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            fakeGroupContainerURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"] isDirectory:YES];
            loadKeychainAccessGroup();
            NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
            if (caches) {
                [ThetaHelper createDirectoryIfNotExists:[NSURL fileURLWithPath:[caches stringByAppendingPathComponent:@"MobileConfig"] isDirectory:YES]];
                [ThetaHelper createDirectoryIfNotExists:[NSURL fileURLWithPath:[caches stringByAppendingPathComponent:@"FBMobileConfig"] isDirectory:YES]];
            }
            if (appSupport) {
                [ThetaHelper createDirectoryIfNotExists:[NSURL fileURLWithPath:[appSupport stringByAppendingPathComponent:@"MobileConfig"] isDirectory:YES]];
                [ThetaHelper createDirectoryIfNotExists:[NSURL fileURLWithPath:[appSupport stringByAppendingPathComponent:@"FBMobileConfig"] isDirectory:YES]];
            }
            // Optional IG/FB classes — silent if absent (avoids noisy "1 miss" + nil-class records).
            NullHookMessageIfPresent(objc_getClass("FBSDKKeychainStore"), @selector(accessGroup), (void *)hook_accessGroup_FBSDKKeychainStore, &orig_accessGroup_FBSDKKeychainStore);
            NullHookMessageIfPresent(objc_getClass("FBKeychainItemController"), @selector(accessGroup), (void *)hook_accessGroup_FBKeychainItemController, &orig_accessGroup_FBKeychainItemController);
            NullHookMessageIfPresent(objc_getClass("UICKeyChainStore"), @selector(accessGroup), (void *)hook_accessGroup_UICKeyChainStore, &orig_accessGroup_UICKeyChainStore);
            // Install mkdir hook before containerURL — containerURL uses orig_createDirectoryAtPath.
            NullHookMessageEx(objc_getClass("NSFileManager"), @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), (void *)hook_createDirectoryAtPath, &orig_createDirectoryAtPath);
            NullHookMessageEx(objc_getClass("NSFileManager"), @selector(containerURLForSecurityApplicationGroupIdentifier:), (void *)hook_NSFileManager, &orig_NSFileManager);
            if (!orig_NSFileManager || !orig_createDirectoryAtPath) {
                NSLog(@"[Theta] Sideload NSFileManager hooks incomplete (orig_container=%p orig_mkdir=%p)",
                      orig_NSFileManager, orig_createDirectoryAtPath);
            } else {
                NSLog(@"[Theta] Sideload keychain/container hooks installed");
            }
        } @catch (NSException *e) {
            NSLog(@"[Theta] Sideload setup exception: %@", e);
        }
    });
}
#endif

static void StartTweakWhenReady(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplicationState state = UIApplication.sharedApplication.applicationState;
        if (state == UIApplicationStateBackground) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                StartTweakWhenReady();
            });
            return;
        }
        InitializeHooks();
    });
}

static void ObserveAppLifecycle(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        StartTweakWhenReady();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        StartTweakWhenReady();
        [THProfileAnalyzerViewController prefetchProfileImageIfNeeded];
    }];
    StartTweakWhenReady();
#ifdef SIDELOAD
    RunSideloadSetupOnce();
#endif
    [THProfileAnalyzerViewController prefetchProfileImageIfNeeded];
}

__attribute__((constructor))
static void ThetaLoad(void) {
#ifdef SIDELOAD
    install_fishhook_rebindings();
    RunSideloadSetupOnce();
    dispatch_async(dispatch_get_main_queue(), ^{ RunSideloadSetupOnce(); });
#endif

    THRegisterLiquidGlassTabBarEarlyHooks();

    appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *thetaProject = [NSString stringWithUTF8String:THETA_PROJECT];
    if ([thetaProject hasPrefix:@"theta "]) {
        thetaProject = [thetaProject substringFromIndex:6];
    }
    NSLog(@"Theta %@ | Instagram %s | Hello!", thetaProject, appVersion.UTF8String);

    [ThetaHelper cleanupTemporaryMediaFiles];

    dispatch_async(dispatch_get_main_queue(), ^{
        ObserveAppLifecycle();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [THProfileAnalyzerViewController prefetchProfileImageIfNeeded];
    });
}

__attribute__((destructor))
static void ThetaUnload(void) {
    NSLog(@"Theta %s | Instagram %s | Goodbye!", THETA_VERSION, appVersion.UTF8String);
}
