static NSMutableSet<NSString *> *thetaThreadsShownBanner = nil;
static NSMutableDictionary<NSString *, NSString *> *thetaLastTextByKey = nil;
static NSMutableDictionary<NSString *, NSNumber *> *thetaLastShownAtByKey = nil;
static NSMutableDictionary<NSString *, NSNumber *> *thetaEmptySinceByKey = nil;
static NSMutableDictionary<NSString *, NSString *> *thetaPinnedKeyByVC = nil;
static NSString *const kThetaGlobalKey = @"__theta_global__";
static const NSTimeInterval kThetaShowThrottleSeconds = 5.0; // prevent rapid re-triggering
extern BOOL theta_hasUnreadFromRecipient(id threadVC);
void theta_showMarkedAsSeenToastDeferred(void);
void theta_performMarkLastMessageAsSeen(id threadViewController, id listViewController);
id theta_activeDirectThreadViewController(void);
static const NSTimeInterval kThetaEmptyStableSeconds = 0.75; // require empty to be stable before reset
static void (*orig_directComposer2)(id self, SEL _cmd);
static void hook_directComposer2(id self, SEL _cmd) {
    @try {
        orig_directComposer2(self, _cmd);

        if (ENABLED(@"Seen On Typing")) {
            IGUser *lastSender = nil;

            UIViewController *viewController = [ThetaHelper nearestViewController:self];
            UIViewController *ballsThreadVC = nil;
            id msgListDataSource = nil;
            if ([viewController isKindOfClass:NSClassFromString(@"IGDirectComposerViewController")]) {
                ballsThreadVC = [viewController valueForKey:@"delegate"];
                msgListDataSource = [ballsThreadVC valueForKey:@"_messageListDataSource"];
                id lastSenderImg = [msgListDataSource performSelector:@selector(mostRecentMessageSenderProfileImage)];
                //lastSender = [lastSenderImg valueForKey:@"_profileImage_user"];
                
                // check if lastSenderImg has ivar '_profileImage_user' or '_profileImageModel_user'
                Ivar profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImage_user");
                if (profileImageUserIvar) {
                    lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
                } else {
                    profileImageUserIvar = class_getInstanceVariable([lastSenderImg class], "_profileImageModel_user");
                    if (profileImageUserIvar) {
                        lastSender = object_getIvar(lastSenderImg, profileImageUserIvar);
                    }
                }
            }
            if (!ballsThreadVC) {
                Class threadCls = NSClassFromString(@"IGDirectThreadViewController");
                UIResponder *r = viewController;
                while (r) {
                    if (threadCls && [r isKindOfClass:threadCls]) { ballsThreadVC = (id)r; break; }
                    r = [r nextResponder];
                }
            }

            NSString *currentText = [self valueForKey:@"text"];

            // Resolve a stable thread identifier for deduping the toast across multiple composers of the same thread
            NSString *threadIdentifier = nil;
            @try {
                id thread = nil;
                if (ballsThreadVC) {
                    @try { thread = [ballsThreadVC valueForKey:@"thread"]; } @catch (__unused NSException *e) {}
                    if (!thread) {
                        @try { thread = [ballsThreadVC valueForKey:@"_thread"]; } @catch (__unused NSException *e) {}
                    }
                }
                if (!thread && msgListDataSource) {
                    @try { thread = [msgListDataSource valueForKey:@"thread"]; } @catch (__unused NSException *e) {}
                    if (!thread) {
                        @try { thread = [msgListDataSource valueForKey:@"_thread"]; } @catch (__unused NSException *e) {}
                    }
                }

                id candidate = nil;
                if (thread) {
                    @try { candidate = [thread valueForKey:@"threadId"]; } @catch (__unused NSException *e) {}
                    if (!candidate) { @try { candidate = [thread valueForKey:@"threadID"]; } @catch (__unused NSException *e) {} }
                    if (!candidate) { @try { candidate = [thread valueForKey:@"identifier"]; } @catch (__unused NSException *e) {} }
                    if (!candidate) { @try { candidate = [thread valueForKey:@"pk"]; } @catch (__unused NSException *e) {} }
                }
                if (!candidate && ballsThreadVC) {
                    @try { candidate = [ballsThreadVC valueForKey:@"threadId"]; } @catch (__unused NSException *e) {}
                    if (!candidate) { @try { candidate = [ballsThreadVC valueForKey:@"threadID"]; } @catch (__unused NSException *e) {} }
                }

                if ([candidate isKindOfClass:[NSNumber class]]) {
                    threadIdentifier = [(NSNumber *)candidate stringValue];
                } else if ([candidate isKindOfClass:[NSString class]]) {
                    threadIdentifier = (NSString *)candidate;
                }
            } @catch (__unused NSException *e) {}

            // Build a stable dedupe key: prefer thread id, else sender id/username, else global.
            // Pin the chosen key per thread VC so it doesn't flap between candidates.
            NSString *candidateKey = nil;
            if (threadIdentifier.length > 0) {
                candidateKey = threadIdentifier;
            } else if (lastSender) {
                id senderId = nil;
                @try { senderId = [lastSender valueForKey:@"pk"]; } @catch (__unused NSException *e) {}
                if (!senderId) { @try { senderId = [lastSender valueForKey:@"identifier"]; } @catch (__unused NSException *e) {} }
                if (!senderId) { @try { senderId = [lastSender valueForKey:@"username"]; } @catch (__unused NSException *e) {} }
                if ([senderId isKindOfClass:[NSNumber class]]) {
                    candidateKey = [(NSNumber *)senderId stringValue];
                } else if ([senderId isKindOfClass:[NSString class]]) {
                    candidateKey = (NSString *)senderId;
                }
            }
            if (candidateKey.length == 0) {
                candidateKey = kThetaGlobalKey;
            }

            if (thetaPinnedKeyByVC == nil) {
                thetaPinnedKeyByVC = [NSMutableDictionary dictionary];
            }
            NSString *vcKey = nil;
            if (ballsThreadVC) {
                vcKey = [NSString stringWithFormat:@"%p", ballsThreadVC];
            } else if (viewController) {
                vcKey = [NSString stringWithFormat:@"%p", viewController];
            } else {
                vcKey = @"__no_vc__";
            }
            NSString *stableKey = thetaPinnedKeyByVC[vcKey];
            if (stableKey.length == 0) {
                stableKey = candidateKey ?: kThetaGlobalKey;
                thetaPinnedKeyByVC[vcKey] = stableKey;
            }

            if (thetaLastTextByKey == nil) { thetaLastTextByKey = [NSMutableDictionary dictionary]; }
            if (thetaThreadsShownBanner == nil) { thetaThreadsShownBanner = [NSMutableSet set]; }
            if (thetaLastShownAtByKey == nil) { thetaLastShownAtByKey = [NSMutableDictionary dictionary]; }
            if (thetaEmptySinceByKey == nil) { thetaEmptySinceByKey = [NSMutableDictionary dictionary]; }

            NSString *previousTextForKey = thetaLastTextByKey[stableKey];
            NSString *normalizedCurrent = currentText ?: @"";

            // First observation for this key: store and do not trigger
            if (previousTextForKey == nil) {
                thetaLastTextByKey[stableKey] = normalizedCurrent;
            } else if (![normalizedCurrent isEqualToString:previousTextForKey]) {
                // Text actually changed for this conversation/user
                BOOL alreadyShown = [thetaThreadsShownBanner containsObject:stableKey];
                BOOL transitionedFromEmptyToNonEmpty = (previousTextForKey.length == 0 && normalizedCurrent.length > 0);
                NSTimeInterval now = CACurrentMediaTime();
                NSNumber *lastShownNum = thetaLastShownAtByKey[stableKey];
                NSTimeInterval lastShown = lastShownNum != nil ? [lastShownNum doubleValue] : 0.0;
                BOOL throttled = (now - lastShown) < kThetaShowThrottleSeconds;

                id unreadHint = theta_activeDirectThreadViewController() ?: ballsThreadVC;
                if (transitionedFromEmptyToNonEmpty && lastSender && !alreadyShown && !throttled && theta_hasUnreadFromRecipient(unreadHint)) {
                    [thetaThreadsShownBanner addObject:stableKey];
                    thetaLastShownAtByKey[stableKey] = @(now);
                    id composerView = self;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        Class threadCls = NSClassFromString(@"IGDirectThreadViewController");
                        id threadVC = nil;
                        UIResponder *r = composerView;
                        while (r) {
                            if (threadCls && [r isKindOfClass:threadCls]) { threadVC = (id)r; break; }
                            r = [r nextResponder];
                        }
                        if (!threadVC) threadVC = theta_activeDirectThreadViewController();
                        if (!threadVC) threadVC = unreadHint;
                        if (!threadVC) return;
                        theta_performMarkLastMessageAsSeen(threadVC, nil);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            id retryVC = threadVC;
                            if (!retryVC || ![retryVC isKindOfClass:[UIViewController class]]) {
                                retryVC = theta_activeDirectThreadViewController();
                            }
                            if (retryVC && theta_hasUnreadFromRecipient(retryVC)) {
                                theta_performMarkLastMessageAsSeen(retryVC, nil);
                            }
                            theta_showMarkedAsSeenToastDeferred();
                        });
                    });
                }
                thetaLastTextByKey[stableKey] = normalizedCurrent;
            }

            // Only clear the shown flag if input has been empty continuously for a short period
            NSTimeInterval now = CACurrentMediaTime();
            if (normalizedCurrent.length == 0) {
                NSNumber *emptySinceNum = thetaEmptySinceByKey[stableKey];
                if (!emptySinceNum) {
                    thetaEmptySinceByKey[stableKey] = @(now);
                } else if ((now - [emptySinceNum doubleValue]) >= kThetaEmptyStableSeconds) {
                    [thetaThreadsShownBanner removeObject:stableKey];
                }
            } else {
                [thetaEmptySinceByKey removeObjectForKey:stableKey];
            }
        }

        if (!ENABLED(@"Bypass Character Limit")) {
            return;
        }
        
        if (!self) {
            return;
        }
        
        Ivar characterLimitIvar = class_getInstanceVariable([self class], "_characterLimit");
        if (!characterLimitIvar) {
            NSLog(@"Character limit ivar not found");
            return;
        }
        
        NSInteger characterLimit = 99999999;
        object_setIvar(self, characterLimitIvar, @(characterLimit));
    } @catch (NSException *exception) {
        NSLog(@"Error in character limit bypass: %@", exception);
    }
}

void THRegisterBypassCharacterLimitHooks(void) {
    Class composer = ThetaFirstClass(@[
        @"IGDirectComposer",
        @"_TtC16IGDirectComposer16IGDirectComposer",
    ]);
    NullHookMessageIfPresent(composer, @selector(layoutSubviews), (void *)hook_directComposer2, &orig_directComposer2);
}