static BOOL (*orig_recentSearchStore)(id self, SEL _cmd, id item);
static BOOL hook_recentSearchStore(id self, SEL _cmd, id item) {
    if (!ENABLED(@"Hide Recent Searches")) {
        storeUserSearch = orig_recentSearchStore(self, _cmd, item);
    } else if ([item isKindOfClass:NSClassFromString(@"IGUser")]) {
        storeUserSearch = NO;
    }
    return storeUserSearch;
}

void THRegisterHideSearchesRecentStoreHooks(void) {
    NullHookMessageIfPresent(objc_getClass("IGRecentSearchStore"), @selector(addItem:), (void *)hook_recentSearchStore, &orig_recentSearchStore);
}