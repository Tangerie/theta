static NSArray *hook_bigTest(id self, SEL _cmd) {
    IGStoryFullscreenSectionController *sectionController = [self valueForKey:@"delegate"];
    if (!sectionController) {
        return nil;
    }

    IGMedia *media = [sectionController valueForKey:@"currentStoryItem"];
    if (!media) {
        return nil;
    }

    NSArray *reelMentions = [media performSelector:@selector(reelMentions)];
    NSMutableArray *mentions = [NSMutableArray array];
    // for each mention, make sure to get the user (ivar "user" in mentions), and then get the name and username (name is ivar "secondaryName" in user, username is performing the selector "name" in user). Example: "John Doe (@johndoe)"
    for (id mention in reelMentions) {
        id user = [mention valueForKey:@"user"];
        NSString *name = [user valueForKey:@"secondaryName"];
        NSString *username = [user performSelector:@selector(name)];
        [mentions addObject:[NSString stringWithFormat:@"%@ (@%@)", name, username]];
    }
    return mentions;
}

void THRegisterGetStoryMentionsHooks(void) {
    NullHookMessage(objc_getClass("IGStoryFullscreenCell"), @selector(bigTest), (void *)hook_bigTest);
}