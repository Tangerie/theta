static void (*orig_storyAutoAdvance)(id self, SEL _cmd, NSInteger arg1);
static void hook_storyAutoAdvance(id self, SEL _cmd, NSInteger arg1) {
    if (arg1 == 6 && ENABLED(@"Disable Auto Advance")) {
        return;
    }

    return orig_storyAutoAdvance(self, _cmd, arg1);
}

void THRegisterStoryAutoAdvanceHooks(void) {
    NullHookMessageEx(objc_getClass("IGStoryFullscreenSectionController"), @selector(advanceToNextItemWithNavigationAction:), (void *)hook_storyAutoAdvance, &orig_storyAutoAdvance);
}