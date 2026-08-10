static void (*orig_hideBrainBot)(IGUnifiedVideoCollectionView *self, SEL _cmd);
static void hook_hideBrainBot(IGUnifiedVideoCollectionView *self, SEL _cmd) {
    orig_hideBrainBot(self, _cmd);
    
    if (ENABLED(@"Disable Scrolling Reels")) {
        self.scrollEnabled = NO;
    }
}

void THRegisterNoBrainrotHooks(void) {
    NullHookMessageEx(objc_getClass("IGUnifiedVideoCollectionView"), @selector(didMoveToWindow), (void *)hook_hideBrainBot, &orig_hideBrainBot);
}