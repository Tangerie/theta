static void (*orig_hideCreateButton)(id self, SEL _cmd);
static void hook_hideCreateButton(id self, SEL _cmd) {
    if (orig_hideCreateButton) orig_hideCreateButton(self, _cmd);

    if (ENABLED(@"Hide Create Tab/Button")) {
        // Swift home header may not expose _createButton to KVC — never let that abort layout.
        id createButton = ThetaValueForKey(self, @"_createButton");
        if (!createButton) createButton = ThetaValueForKey(self, @"createButton");
        if ([createButton isKindOfClass:[UIView class]]) {
            [(UIView *)createButton removeFromSuperview];
        }
    }
}

static void (*orig_hideCreateButton2)(id self, SEL _cmd);
static void hook_hideCreateButton2(id self, SEL _cmd) {
    if (orig_hideCreateButton2) orig_hideCreateButton2(self, _cmd);

    if (ENABLED(@"Hide Create Tab/Button")) {
        for (UIView *view in [self subviews]) {
            if ([view isKindOfClass:NSClassFromString(@"IGUnifiedVideoCameraEntryPointButton")]) {
                [view removeFromSuperview];
                break;
            }
        }
    }
}

static void (*orig_hideCreateButton3)(id self, SEL _cmd);
static void hook_hideCreateButton3(id self, SEL _cmd) {
    if (orig_hideCreateButton3) orig_hideCreateButton3(self, _cmd);

    if (ENABLED(@"Hide Create Tab/Button")) {
        NSMutableArray *buttonsToRemove = [NSMutableArray array];
        NSArray *leftButtons = ThetaValueForKey(self, @"_leftButtons");
        if (![leftButtons isKindOfClass:[NSArray class]] || leftButtons.count == 0) {
            return;
        }

        for (UIView *view in leftButtons) {
            if ([view isKindOfClass:NSClassFromString(@"IGProfileNavigationHeaderViewButton")]) {
                UIView *buttonView = ThetaValueForKey(view, @"_view");
                if ([buttonView isKindOfClass:[UIView class]]) {
                    NSString *accessibilityLabel = buttonView.accessibilityLabel;
                    if ([accessibilityLabel isEqualToString:@"Tap to open creation menu"]) {
                        if (buttonView.superview) {
                            [buttonView removeFromSuperview];
                        }
                        [buttonsToRemove addObject:view];
                        break;
                    }
                }
            }
        }

        NSMutableArray *mutableLeft = ThetaValueForKey(self, @"_leftButtons");
        if ([mutableLeft isKindOfClass:[NSMutableArray class]]) {
            [mutableLeft removeObjectsInArray:buttonsToRemove];
        }
    }
}

static id (*orig_hideCreateButton4)(id self, SEL _cmd);
static id hook_hideCreateButton4(id self, SEL _cmd) {
    id titleView = orig_hideCreateButton4(self, _cmd);
    if (ENABLED(@"Hide Create Tab/Button")) {
        // get subviews in self (there will only be 1 UIView subview)
        for (UIView *subview in [self subviews]) {
            if ([subview isKindOfClass:NSClassFromString(@"UIView")]) {
                // get subviews in subview (there will only be 1 UIView subview)
                for (UIView *subview2 in subview.subviews) {
                    if ([subview2 isKindOfClass:NSClassFromString(@"IGBadgedNavigationButton")]) {
                        if ([subview2.accessibilityLabel isEqualToString:@"Tap to open creation menu"]) {
                            [subview2 removeFromSuperview];
                        }
                    }
                }
            }
        }
    }
    return titleView;
}

void THRegisterHideCreateButtonHooks(void) {
    Class homeHeader = ThetaFirstClass(@[
        @"_TtC16IGHomeFeedHeader20IGHomeFeedHeaderView",
        @"IGHomeFeedHeaderView"
    ]);
    NullHookMessageIfPresent(homeHeader, @selector(layoutSubviews), (void *)hook_hideCreateButton, &orig_hideCreateButton);

    Class sundialNav = ThetaFirstClass(@[
        @"_TtC33IGSundialViewerNavigationBarSwift28IGSundialViewerNavigationBar",
        @"IGSundialViewerNavigationBarOld"
    ]);
    NullHookMessageIfPresent(sundialNav, @selector(layoutSubviews), (void *)hook_hideCreateButton2, &orig_hideCreateButton2);

    Class profileNav = ThetaFirstClass(@[
        @"_TtC24IGProfileNavigationSwift29IGProfileNavigationHeaderView",
        @"IGProfileNavigationHeaderView",
        @"IGProfileNavigationSwift.IGProfileNavigationHeaderView"
    ]);
    NullHookMessageIfPresent(profileNav, @selector(layoutSubviews), (void *)hook_hideCreateButton3, &orig_hideCreateButton3);
    NullHookMessageIfPresent(profileNav, @selector(titleView), (void *)hook_hideCreateButton4, &orig_hideCreateButton4);
}