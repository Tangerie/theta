static NSArray *hook_bigTest(id self, SEL _cmd) {
    @try {
        id sectionController = ThetaValueForKey(self, @"delegate");
        if (!sectionController) return nil;

        id media = ThetaValueForKey(sectionController, @"currentStoryItem");
        if (!media) return nil;

        NSArray *reelMentions = nil;
        if ([media respondsToSelector:@selector(reelMentions)]) {
            reelMentions = [media performSelector:@selector(reelMentions)];
        } else {
            reelMentions = ThetaValueForKey(media, @"reelMentions");
        }
        if (![reelMentions isKindOfClass:[NSArray class]]) return nil;

        NSMutableArray *mentions = [NSMutableArray array];
        for (id mention in reelMentions) {
            id user = ThetaValueForKey(mention, @"user");
            if (!user) continue;
            NSString *name = ThetaValueForKey(user, @"secondaryName");
            NSString *username = nil;
            @try {
                if ([user respondsToSelector:@selector(name)]) {
                    username = [user performSelector:@selector(name)];
                }
            } @catch (__unused NSException *e) {}
            if (![name isKindOfClass:[NSString class]]) name = @"";
            if (![username isKindOfClass:[NSString class]]) username = @"";
            [mentions addObject:[NSString stringWithFormat:@"%@ (@%@)", name, username]];
        }
        return mentions;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

void THRegisterGetStoryMentionsHooks(void) {
    Class cls = objc_getClass("IGStoryFullscreenCell");
    if (!cls) return;
    // Correct type encoding for NSArray * return (NullHookMessage defaults to void).
    if (!class_addMethod(cls, @selector(bigTest), (IMP)hook_bigTest, "@@:")) {
        Method m = class_getInstanceMethod(cls, @selector(bigTest));
        if (m) method_setImplementation(m, (IMP)hook_bigTest);
    }
}
