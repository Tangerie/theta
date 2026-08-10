/// `seenButtonPressedCurrent` is defined in StoryGhost.m (same amalgamation TU, ordered before this file).

/// Resolves `contentViewForAnimation` as an `IGStoryFullscreenCell` when `viewController` is an `IGStoryViewerViewController`.
static IGStoryFullscreenCell *theta_storyFullscreenCellFromViewer(UIViewController *viewController) {
    if (!viewController) {
        return nil;
    }
    Class storyViewerClass = NSClassFromString(@"IGStoryViewerViewController");
    Class cellClass = NSClassFromString(@"IGStoryFullscreenCell");
    if (!storyViewerClass || !cellClass || ![viewController isKindOfClass:storyViewerClass]) {
        return nil;
    }
    id contentViewForAnimation = nil;
    @try {
        contentViewForAnimation = [viewController valueForKey:@"contentViewForAnimation"];
    } @catch (NSException *e) {
        NSLog(@"[Theta] contentViewForAnimation: %@", e);
        return nil;
    }
    if (!contentViewForAnimation || ![contentViewForAnimation isKindOfClass:cellClass]) {
        return nil;
    }
    return (IGStoryFullscreenCell *)contentViewForAnimation;
}

static void (*orig_seenStoryOnReply)(id self, SEL _cmd, id inputView, id text, id quotedContent, id animatedEmojiCharacterRanges, id defaultPowerupsMetadata, id imageGlyphLocations, id replayBarGroupRecipients);
static void hook_seenStoryOnReply(id self, SEL _cmd, id inputView, id text, id quotedContent, id animatedEmojiCharacterRanges, id defaultPowerupsMetadata, id imageGlyphLocations, id replayBarGroupRecipients) {
    orig_seenStoryOnReply(self, _cmd, inputView, text, quotedContent, animatedEmojiCharacterRanges, defaultPowerupsMetadata, imageGlyphLocations, replayBarGroupRecipients);

    if (!ENABLED(@"Story Seen On Reply")) {
        return;
    }

    @try {
        UIViewController *viewController = [ThetaHelper nearestViewController:self];
        IGStoryFullscreenCell *cell = theta_storyFullscreenCellFromViewer(viewController);
        if (cell) {
            seenButtonPressedCurrent(cell);
        }
    } @catch (NSException *exception) {
        NSLog(@"[Theta] hook_seenStoryOnReply: %@", exception);
    }
}

void THRegisterStorySeenOnHooks(void) {
    if ([appVersion compare:@"423.0.0" options:NSNumericSearch] == NSOrderedAscending) {
        NullHookMessageEx(objc_getClass("IGStoryFullscreenDefaultFooterView"), @selector(inputView:didTapSendButtonWithText:quotedContent:animatedEmojiCharacterRanges:defaultPowerupsMetadata:imageGlyphLocations:replyBarGroupRecipients:), (void *)hook_seenStoryOnReply, &orig_seenStoryOnReply);
    } else {
        NullHookMessageEx(objc_getClass("IGStoryDefaultFooter.IGStoryFullscreenDefaultFooterView"), @selector(inputView:didTapSendButtonWithText:quotedContent:animatedEmojiCharacterRanges:defaultPowerupsMetadata:imageGlyphLocations:replyBarGroupRecipients:), (void *)hook_seenStoryOnReply, &orig_seenStoryOnReply);
    }
}
