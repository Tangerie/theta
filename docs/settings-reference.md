# Settings reference

Every setting is declared in `self.settingsBySubMenu` in
`Source/UI/SettingsViewController.m` (from line 155). The dictionary key is the submenu name; the
value is an ordered array of setting descriptors:

```objc
@{ @"title":          @"Save Media",              // REQUIRED — also the preference key stem
   @"detail":         @"Save media to your camera roll.",   // one-line subtitle
   @"info":           @"Longer help text…",       // optional ⓘ button
   @"type":           @"segment",                 // optional: segment | color | view | action
   @"options":        @[@"Default", @"Pause/Play"],// segment only
   @"viewController": @"THProfileAnalyzerViewController",  // view only
   @"listKey":        @"Theta_StoryGhost_AutoMarkUserIds", // view (list editor) only
   @"listTitle":      @"Story Ghost auto-mark list",       // view (list editor) only
   @"requiresBiometrics": @YES }                   // disables the row if no passcode/biometry
```

## Storage format

| `type` | `NSUserDefaults` key | Value | Read with |
| --- | --- | --- | --- |
| absent (switch) | `<Title>_Enabled` | `BOOL` | `ENABLED(@"<Title>")` |
| `segment` | `<Title>_SegmentIndex` | `NSInteger`, 0 = "Default" | `integerForKey:` |
| `color` | `<Title>_Color` | `NSData` — `NSKeyedArchiver`-archived `UIColor` (secure coding) | `[NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:… error:nil]` |
| `view` | none | — | pushes `NSClassFromString(viewController)` |
| `action` | none | — | runs `resetColors` / `clearAppCache` |

Note the color format: the *archived object* is what lives in `NSUserDefaults`. Hex strings
(`THHexStringFromColor` / `THColorFromHexString`) appear only inside the QR/clipboard
import-export payload, which is converted to and from archived data at the boundary
(`SettingsViewController.m:1233`). `SubMenuViewController.m:222` also falls back to the legacy
non-secure `unarchiveObjectWithData:` when the modern call fails.

Segment index 0 always means "don't override" — each consumer falls through to IG's original
value for 0.

## Full setting list

### General

| Setting | Type | Implemented in |
| --- | --- | --- |
| Profile Analyzer | view → `THProfileAnalyzerViewController` | `Source/ProfileAnalyzer/**` |
| Screenshot Suppression | switch | `Hooks/Behavior/ScreenshotSuppression.m` |
| Like Confirmation | switch | `Hooks/Behavior/LikeConfirmation.m` |
| Follow Confirmation | switch | `Hooks/Behavior/FollowConfirmation.m` |
| Call Confirmation | switch | `Hooks/Behavior/CallConfirmation.m` |
| Disable Ads | switch | `Hooks/Behavior/HideAds.m`, `Hooks/Behavior/HideFeedFiltering.m` |
| Explore Refresh Confirmation | switch | `Hooks/Behavior/ExploreRefreshConfirmation.m` |
| Comment Options | switch | `Hooks/Behavior/CommentTextCopy.m` |
| Date Format | segment: Default, Short, Medium, 12h, 24h, ISO, ISO+T | `Hooks/General/DateFormat.m` |
| Open Links in External Browser | switch | `Hooks/General/ExternalBrowser.m` |
| Strip Tracking from Links | switch | `Hooks/General/ExternalBrowser.m` |
| Enable Liquid Glass Buttons | switch (restart) | `Hooks/General/LiquidGlass.m` |
| Enable Liquid Glass Surfaces | switch (restart) | `Hooks/General/LiquidGlass.m` |

### Feed

| Setting | Type | Implemented in |
| --- | --- | --- |
| Hide Suggested Posts | switch | `Hooks/Behavior/HideFeedFiltering.m` |
| Hide Suggested Reels | switch | `Hooks/Behavior/HideFeedFiltering.m` |
| Hide People You May Know | switch | `Hooks/Behavior/HideFeedFiltering.m` |
| Hide Threads Carousel | switch | `Hooks/Behavior/HideFeedFiltering.m` |
| Hide Home Stories | switch | `Hooks/Behavior/HideFeedFiltering.m` |
| Mute Entire Home Feed | switch | `Hooks/Behavior/HideFeedFiltering.m` |
| Hide End-of-Feed Footer | switch | `Hooks/Behavior/HideFeedFiltering.m` |

All seven have legacy `"Strip …"` key names migrated on load by
`THMigrateFeedSettingTitles()` (`HideFeedFiltering.m:8`).

### Messages

| Setting | Type | Implemented in |
| --- | --- | --- |
| Keep Deleted Messages | switch | `Hooks/Messages/KeepDeletedMessages.m` |
| Deleted Message Color | color | `Hooks/Messages/KeepDeletedMessages.m` |
| Save Audio Messages | switch | `Hooks/Messages/SaveAudioMessage.m` |
| Upload Audio Messages | switch | `Hooks/Messages/UploadAudioMessage.m` |
| Bypass Character Limit | switch | `Hooks/Messages/BypassCharacterLimit.m` |
| Hide Typing Indicator | switch | `Hooks/Behavior/HideTypingIndicator.m` |
| Mark As Seen | switch | `Hooks/Messages/MarkAsSeen.m` |
| Mark As Seen Auto-Mark List | view → `ThetaUserListEditorViewController`, list key `Theta_MarkAsSeen_AutoMarkUserIds` | `Hooks/Messages/MarkAsSeen.m` |
| Seen On Typing | switch | `Hooks/Messages/BypassCharacterLimit.m` (+ `MarkAsSeen.m`) |
| Seen On React | switch | `Hooks/Messages/MarkAsSeen.m` |
| Seen On Send | switch | `Hooks/Messages/MarkAsSeen.m` |
| Private Media Ghost | switch | `Hooks/Messages/PrivateVideoGhost.m` |
| Disappearing DM Confirmation | switch | `Hooks/Messages/VanishModeConfirm.m` |
| Hide "Create Group" Button | switch | `Hooks/UI/HideCreateGroupButton.m` |
| Create Group Confirmation | switch | `Hooks/Behavior/CreateGroupConfirmation.m` |
| Hide Blend Button | switch | `Hooks/Messages/MarkAsSeen.m` (nav-bar items hook) |
| Hide Call Buttons | switch | `Hooks/Messages/MarkAsSeen.m` (nav-bar items hook) |
| Full Last Active Date | switch | `Hooks/Messages/FullLastActive.m` |
| Send Files | switch | `Hooks/Messages/SendFile.m` |

### Media

| Setting | Type | Implemented in |
| --- | --- | --- |
| Live Without Viewer List | switch | `Hooks/Behavior/LiveBrowseTweaks.m` |
| Live Comments Sheet Toggle | switch | `Hooks/Behavior/LiveBrowseTweaks.m` |
| Story Ghost | switch | `Hooks/Behavior/StoryGhost.m` |
| Story Ghost Auto-Mark List | view → `ThetaUserListEditorViewController`, list key `Theta_StoryGhost_AutoMarkUserIds` | `Hooks/Behavior/StoryGhost.m` |
| Story Seen On Reply | switch | `Hooks/Behavior/StorySeenOn.m` |
| Seen Receipts Stay Local | switch | `Hooks/Behavior/StorySeenLocalOnly.m`, `StoryGhost.m` |
| Skip On Seen | switch | `Hooks/Behavior/StoryGhost.m` |
| See Story Mentions | switch | `Hooks/Behavior/GetStoryMentions.m`, `StoryGhost.m` |
| Save Media | switch | `Hooks/Save/SavePosts.m`, `StoryGhost.m`, `PrivateVideoGhost.m` |
| Save Profile Pictures | switch | `Hooks/Save/SaveProfilePictures.m` |
| Save Profile Posts | switch | `Hooks/UI/FollowStatusIndicator.m` |
| Save Method | segment: Camera Roll, Folder | read by every save path |
| Save Audio Notes | switch | `Hooks/Save/AudioNote.m` |
| Fullscreen Posts | switch | `Hooks/Save/SavePosts.m` |
| Fullscreen Profile Pictures | switch | `Hooks/Save/SaveProfilePictures.m` |
| Disable Auto Advance | switch | `Hooks/Behavior/StoryAutoAdvance.m` |
| Bypass Reel Password | switch | `Hooks/Behavior/BypassReelPassword.m` |
| Disable Scrolling Reels | switch | `Hooks/Behavior/NoBrainrot.m` |

`Save Method` is unusual: index `0` means Camera Roll and `1` means a local folder
(`Documents/AudioNotes`), so unlike other segments there is no "Default".

### Reels

| Setting | Type | Implemented in |
| --- | --- | --- |
| Tap Controls | segment: Default, Pause/Play, Mute | `Hooks/Media/TapControls.m` |
| Always Show Scrubber | switch | `Hooks/Media/TapControls.m` |

### Navigation

**All of these are known-broken under sideload.**

| Setting | Type | Implemented in |
| --- | --- | --- |
| Tab Icon Order | segment: Default, Classic, Standard, Alternate (restart) | `Hooks/UI/Navigation.m` |
| Swipe Between Tabs | segment: Default, Enabled, Disabled | `Hooks/UI/Navigation.m` |
| Launch Tab | segment: Default, Home, Explore, Reels, Messages, Profile | `Hooks/UI/Navigation.m` |
| Hide Feed Tab | switch (restart) | `Hooks/UI/HideTabs.m` |
| Hide Explore Tab | switch (restart) | `Hooks/UI/HideTabs.m` |
| Hide Reels Tab | switch (restart) | `Hooks/UI/HideTabs.m` |
| Hide Messages Tab | switch (restart) | `Hooks/UI/HideTabs.m` |
| Messenger Mode | switch (restart) | `Hooks/UI/HideTabs.m`, `Hooks/UI/tabbar.m` |

### Interface

| Setting | Type | Implemented in |
| --- | --- | --- |
| Hide Create Tab/Button | switch | `Hooks/UI/HideCreateButton.m` |
| Hide Explore Grid | switch | `Hooks/UI/HideExploreGrid.m` |
| Hide Recent Searches | switch | `Hooks/UI/HideSearches.m` |
| Follow Status Indicator | switch | `Hooks/UI/FollowStatusIndicator.m` |
| Hide Repost Button | switch | `Hooks/Save/SavePosts.m` |
| Hide Theta From Screenshots | switch | `ThetaSetCaptureHiding()` in `Runtime/THGlobalsAndHooking.m:130` |
| Mentions Button Color | color | `Hooks/Behavior/StoryGhost.m` |
| Save Button Color | color | `StoryGhost.m`, `PrivateVideoGhost.m` |
| Seen Button Color | color | `StoryGhost.m`, `PrivateVideoGhost.m` |
| Reset Colors | action → `resetColors` | `SubMenuViewController.m:609`, `SettingsViewController.m:1705` |

### Miscellaneous

| Setting | Type | Implemented in |
| --- | --- | --- |
| Load Banner | switch | `Runtime/THTweak.m` (launch toast) |
| Show Banners | switch | read by ~15 files before showing any toast |
| Haptic Feedback | switch | `[ThetaHelper performHapticFeedbackIfEnabled]` |
| Lock Instagram | switch, `requiresBiometrics` | `Hooks/Behavior/LockInstagram.m` + `UI/SecurityViewController.m` |
| Shake To Open | switch | `Hooks/Behavior/ShakeToOpen.m` (also suppresses the feed gear) |
| Easter Eggs | switch | `Hooks/Behavior/FeedUsernameSpoof.m` |
| Clear App Cache | action → `clearAppCache` | `SubMenuViewController.m` |

## Keys that are not settings rows

| Key | Meaning |
| --- | --- |
| `ThetaFirst` | first-run NUX shown (set *before* presenting, on purpose) |
| `Theta_DSPromoDialogSeen` | IGDS promo dialog dismissed (sideload) |
| `Theta_StoryGhost_AutoMarkUserIds` | array of usernames, edited by the list editor |
| `Theta_MarkAsSeen_AutoMarkUserIds` | array of usernames, edited by the list editor |
| `instagram.override.project.lucent.navigation` | **Instagram's own** experiment override, written by `LiquidGlass.m` to mirror the Buttons toggle |
| `Strip Inline Suggested Posts_Enabled` (+5 more) | legacy Feed keys, migrated once at load |

## Behavior with no setting at all

- `Hooks/Behavior/DBB.m` — device-lock reporting / forced-logout suppression, always on.
- `Hooks/UI/SortUserGridPosts.m` — long-press to reorder the profile grid, always on.
- `Hooks/Behavior/ToastDismiss.m` — toast timing/positioning fix-ups, always on.
- `Hooks/Sideload/*` — sideload shims, always on in sideload builds.
