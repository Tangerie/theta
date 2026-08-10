static void (*orig_hideTypingIndicator)(id self, SEL _cmd, BOOL updateOutgoingStatusIsActive, id threadKey, id threadMetadata, NSInteger typingStatusType);
static void hook_hideTypingIndicator(id self, SEL _cmd, BOOL updateOutgoingStatusIsActive, id threadKey, id threadMetadata, NSInteger typingStatusType) {
    if (!ENABLED(@"Hide Typing Indicator")) {
        orig_hideTypingIndicator(self, _cmd, updateOutgoingStatusIsActive, threadKey, threadMetadata, typingStatusType);
    }
}

void THRegisterHideTypingIndicatorHooks(void) {
    NullHookMessageEx(objc_getClass("IGDirectTypingStatusService"), @selector(updateOutgoingStatusIsActive:threadKey:threadMetadata:typingStatusType:), (void *)hook_hideTypingIndicator, &orig_hideTypingIndicator);
}