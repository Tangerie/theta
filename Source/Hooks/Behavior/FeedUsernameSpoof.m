static id (*orig_feedItemHeader)(id self, SEL _cmd);
static id hook_feedItemHeader(id self, SEL _cmd) {
    if (!ENABLED(@"Easter Eggs")) {
        return orig_feedItemHeader(self, _cmd);
    }

    // NSArray for different strings that we can return each time the method is called
    static NSArray *easterEggs = nil;
    if (!easterEggs) {
        easterEggs = @[
            // all creepy easter eggs
            @"WE ARE WATCHING YOU!",
            @"we know what you did",
            @"𐌰𐌽𐌳𐌰𐌹𐌽𐌰𐌹𐌽𐌰",
            @"i'm behind you"
        ];
    }

    // Get a random index from the easterEggs array
    NSUInteger randomIndex = arc4random_uniform((uint32_t)easterEggs.count);
    // Return a random easter egg string
    return easterEggs[randomIndex];
}

void THRegisterFeedUsernameSpoofHooks(void) {
    // IGFeedItemHeader / similar username provider — best-effort across versions.
    Class cls = objc_getClass("IGFeedItemHeader");
    if (!cls) cls = objc_getClass("IGFeedItemHeaderViewModel");
    SEL sel = NSSelectorFromString(@"username");
    if (!sel || !cls) return;
    NullHookMessageIfPresent(cls, sel, (void *)hook_feedItemHeader, (void **)&orig_feedItemHeader);
}