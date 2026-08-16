# Feature catalogue

One file per feature under `Source/Hooks/<Category>/`, each exporting `THRegister…Hooks()` that is
called from `InitializeHooks()` in `Source/Runtime/THTweak.m`. This document lists what each one
attaches to and how it works. Setting names are the exact `NSUserDefaults` title strings — see
[settings-reference.md](settings-reference.md) for the key format.

Throughout: "gate" means the feature reads `ENABLED(@"<Setting>")` at call time, so toggles take
effect without reinstalling hooks (hooks are always installed; only their *behavior* is gated).
Settings marked "restart required" in the UI are ones where IG has already consumed the value by
the time you change it.

---

## Behavior

### Confirmation dialogs

A recurring pattern: hook the action, and if the gate is on, present
`[ThetaHelper showCustomAlertWithActions:…]` with the original invocation captured in a block so
"Yes" calls `orig` and "No" drops it.

| Setting | File | Hooked |
| --- | --- | --- |
| Like Confirmation | `Behavior/LikeConfirmation.m` | 6 like entry points: `IGVideoPlayerOverlayContainerView -handleDoubleTapGesture:` (Swift name first), `IGSundialViewerVideoCell -gestureController:didObserveDoubleTap:`, `IGFeedPhotoView -_onDoubleTap:`, `IGFeedItemUFICell -UFIButtonBarDidTapOnLike:`, `IGSundialViewerVerticalUFI -didTapLikeButton` / `-_didTapLikeButton` / `-_didTapLikeButton:` |
| Follow Confirmation | `Behavior/FollowConfirmation.m` | `IGFollowController -_didPressFollowButton`; only prompts when `user.followStatus == 2` (i.e. not already following) |
| Call Confirmation | `Behavior/CallConfirmation.m` | `IGDirectThreadCallButtonsCoordinator -_didTapAudioButton[:]` / `-_didTapVideoButton[:]`, arity probed with `respondsToSelector:` |
| Explore Refresh Confirmation | `Behavior/ExploreRefreshConfirmation.m` | `IGExploreGridViewController -_handleRefreshControlTriggered:` |
| Create Group Confirmation | `Behavior/CreateGroupConfirmation.m` | `IGShareSheet.IGSharesheetBottomButtonsView -secondaryButtonTappedWithButton:` |
| Disappearing DM Confirmation | `Messages/VanishModeConfirm.m` | `IGDirectDisappearingModeSwipeHandler -handleBottomSwipeableScrollUpdate` |

### Ads and feed filtering

Two cooperating files. `HideAds.m` handles sponsored/ad objects; `HideFeedFiltering.m` owns the
recommendation-unit filtering and exports `ThetaApplyHideFeedFiltering()`
(declared in `Include/ThetaTweakCommon.h`) so the home-feed adapter hook can chain both.

- **`Behavior/HideAds.m`** (`Disable Ads`, `Disable Suggested Posts`) hooks
  `IGMainFeedListAdapterDataSource -objectsForListAdapter:`,
  `IGStoryAdsResponseParser -parsedObjectFromResponse:`,
  `IGSundialAdsResponseParser -parsedObjectFromResponse:`,
  `IGFeedItemChain -allChainItems`, and
  `IGDiscoveryGridAdNoCTAOverlayView -configureWithAdItem:…`. Items are dropped when they are
  `IGAdItem`, or `IGFeedItem` answering `isSponsored`/`isSponsoredApp`, or an `IGMedia` with
  `explorePostInFeed == 1` and not organic. `THRegisterHideSuggestedReelsHooks()` additionally
  strips story-tray/group-header cells in `layoutSubviews`.
- **`Behavior/HideFeedFiltering.m`** hooks `objectsForListAdapter:` on `IGSundialFeedDataSource`,
  `IGContextualFeedViewController`, `IGVideoFeedViewController`,
  `IGChainingFeedViewController`, `IGExploreListKitDataSource` (+ its Swift twin), and
  `IGEndOfFeedDemarcatorCellTopOfFeed -configureWithViewConfig:`. Filtering is by view-model
  class: `IGMedia`+`explorePostInFeed` / group header titled "suggested posts" /
  `IGInFeedStoriesTrayModel` (Hide Suggested Posts), `IGFeedScrollableClipsModel` (Hide Suggested
  Reels), `IGHScrollAYMFModel` + `IGSuggestedUserInReelsModel` (Hide People You May Know),
  `IGBloksFeedUnitModel` / `IGThreadsInFeedModels.IGThreadsInFeedModel` / `IGSundialNetegoItem`
  (Hide Threads Carousel), `IGStoryDataController` (Hide Home Stories), and — for
  `Mute Entire Home Feed` — `IGPostCreationManager`, `IGMedia`,
  `IGEndOfFeedDemarcatorModel`, `IGSpinnerLabelViewModel`. When ≤5 items survive on the main
  feed, spinner rows are also removed so the empty feed doesn't spin forever.
  `Hide End-of-Feed Footer` blanks the demarcator's `_titleLabel` text.

### Stories: seen state

Three features layer on the same IG story machinery; understanding the split matters.

- **Story Ghost** (`Behavior/StoryGhost.m`, 1641 lines) hooks
  `IGStoryFullscreenCell -mediaView` to inject Theta's overlay controls, and
  `IGStoryViewerViewController -fullscreenSectionController:didMarkItemAsSeen:` to suppress
  automatic mark-as-seen. The overlay is built in `setupButtons()` (`:1063`) and can contain up to
  four tagged (`77001`) buttons — download (`arrow.down`), seen (`eye`), local-only seen
  (`iphone`), mentions (`@`, with a count badge) — each tinted from its own color preference and
  each with tap + long-press handlers (long-press = "all slides in this reel"). Rebuilds are
  suppressed unless the story owner changed (`lastSetupOwnerForCell`). An **auto-mark list**
  (`Theta_StoryGhost_AutoMarkUserIds`) exempts specific usernames so their stories mark seen
  normally.
- **Seen Receipts Stay Local** (`Behavior/StorySeenLocalOnly.m`) is the "clear the ring locally,
  don't tell the server" path. Rather than blocking one selector, it *nils out* the networking
  ivars on seen-upload objects and restores them later: `theta_recordNilNetworkishIvar()` walks
  each candidate object's ivar list, accepts only names hinting at network transport
  (`networker`, `graphql`, `tigon`, `bladerunner`, `msi`) on classes hinting at seen-state
  ownership (`*SeenStateUploader`, `IGSundialSeenStateManager`, `*PendingSeen*`, …), records the
  previous value keyed by `obj|ivar`, and sets it to nil. Story viewer / section controllers are
  deliberately excluded from the aggressive strip because nil'ing their `state`/`upload` ivars
  crashes `didMarkItemAsSeen`. It additionally hooks a long list of legacy and Swift upload
  selectors on `IGStoryPendingSeenStateStore`, `IGSundialSeenStateManager`,
  `IGStorySeenStateUploader`, and `IGStoryFullscreenSectionController`, all with
  `NullHookMessageIfPresent` since which ones exist varies by version.
- **Story Seen On Reply** (`Behavior/StorySeenOn.m`) hooks the story footer's
  `inputView:didTapSendButtonWithText:…` (class name differs above/below IG 423.0.0) and calls
  `seenButtonPressedCurrent()` — a `static` defined in `StoryGhost.m`, reachable because both
  files are in the same generated TU and `StoryGhost.m` is concatenated first.
- **Disable Auto Advance** (`Behavior/StoryAutoAdvance.m`) drops
  `IGStoryFullscreenSectionController -advanceToNextItemWithNavigationAction:` when the action
  argument is `6` (the auto-advance action), leaving manual navigation intact.
- **Skip On Seen** is consumed inside `StoryGhost.m` (`thetaStorySkipIfEnabled`) after a manual
  mark.

### Privacy / anti-telemetry

- **Screenshot Suppression** (`Behavior/ScreenshotSuppression.m`) no-ops
  `IGScreenshotObserver -_onTakenScreenshot` and `-_screenCaptureStateDidChange:`, and forces
  `IGScreenCaptureProtection.IGScreenCaptureProtectionViewProvider setIsProtected:`/`initWithIsProtected:`
  to `NO`.
- **Hide Typing Indicator** (`Behavior/HideTypingIndicator.m`) swallows
  `IGDirectTypingStatusService -updateOutgoingStatusIsActive:threadKey:threadMetadata:typingStatusType:`.
- **Hide Recent Searches** (`UI/HideSearches.m`) returns `NO` from `IGRecentSearchStore -addItem:`
  for `IGUser` items, so profile visits aren't recorded.
- **Live Without Viewer List** (`Behavior/LiveBrowseTweaks.m`) reaches into
  `IGLiveFeedbackController._viewCountPuller`, writes `_isActive = NO` through the raw ivar offset
  (it is a `BOOL`, not an object) and invalidates `_nextFetchTimer`, so viewer-count polling stops.
- **DBB** (`Behavior/DBB.m`, deferred) neutralizes device-lock reporting and forced-logout pushes:
  no-ops `IGDeviceLockedStatusLogger -queryAndLogDeviceLockedStatusWithSource:ndid:extra:`,
  no-ops `IGForcedLogoutPushHandler -handleForceLogoutLoginWithUserID:token:authLoginType:`,
  and for `-_handleForcedLogoutLoginPush:…` invokes the completion block and returns without doing
  the work (falling back to an `objc_getClassList` scan if the class names don't resolve). It also
  hooks `NSUserDefaults -objectForKey:`/`-boolForKey:` to hide
  `com.facebook.deviceLockedStatusFlag` / `fb_locked_device_flag`, and refuses to install those
  two hot-path hooks unless a real `orig` was captured. This feature has **no settings toggle** —
  it is unconditional.

### Miscellaneous behavior

| Setting | File | How |
| --- | --- | --- |
| Lock Instagram | `Behavior/LockInstagram.m` | Hooks `IGInstagramAppDelegate -applicationDidBecomeActive:` to present `SecurityViewController` over full screen (once per foreground cycle; the flag resets in `-applicationWillEnterForeground:`) |
| Shake To Open | `Behavior/ShakeToOpen.m` | Hooks `UIMotionEvent -setShakeState:`; on state `1` presents Theta settings unless settings or an `IGPartialModalSheetViewController` is already up. When enabled, `UI/SettingsButton.m` omits the feed gear |
| Disable Scrolling Reels | `Behavior/NoBrainrot.m` | Sets `scrollEnabled = NO` on `IGUnifiedVideoCollectionView` in `didMoveToWindow` |
| Bypass Reel Password | `Behavior/BypassReelPassword.m` | Hooks `IGMediaOverlayProfileWithPasswordView -layoutSubviews`, reads `_answer` and `_passwordTextField`, injects a "Bypass" button plus a hot/cold proximity meter (`UIProgressView` + label) that scores typed input against the answer. Tracks per-view teardown state through a set of associated-object keys, a `CADisplayLink`, and observers, and hides itself while a share sheet (`IGDirectShareSheetContainerViewController` / `IGDSPartialModalSheetNavigationController`) is presented |
| Easter Eggs | `Behavior/FeedUsernameSpoof.m` | Replaces `IGFeedItemHeader.username` with strings from a rotating list |
| See Story Mentions | `Behavior/GetStoryMentions.m` + `StoryGhost.m` | Adds a `-bigTest` method (explicit `"@@:"` encoding) to `IGStoryFullscreenCell` returning mentioned `IGUser`s; the overlay's `@` button presents them as a `UIMenu` or alert, tappable to open profiles |
| Comment Options | `Behavior/CommentTextCopy.m` | Hooks `IGCommentCellView.IGCommentCellView -layoutSubviews`. For text comments: a copy button that strips the leading `username · timestamp` header and the `· ⁨by author⁩` suffix. For attached media: an options alert with Copy URL / Copy GIF Name (Giphy slug resolved through `IGGifOverlayManager` in `UI/GIFNameOverlay.m`, which scrapes the redirect target of `giphy.com/gifs/<id>`) / Download / Cancel |
| Live Comments Sheet Toggle | `Behavior/LiveBrowseTweaks.m` | Long-press the heart in a live to hide/show the floating comment strip; session-local, tracked with a weak reference to the active `IGLiveCommentsContainerViewController` |
| — (no toggle) | `Behavior/ToastDismiss.m` | Defers `IGNotificationPresenter -dismissAnimated:` by 4 s if a Theta toast appeared in the last 1.5 s, and translates IG toast views to the same 50 pt top margin Theta's own toasts use |
| — (sideload only) | `Behavior/DismissIGDSPromoDialog.m` | Hooks `IGDSPromoDialog.IGDSPromoDialogView -didMoveToWindow` and tears the overlay down (once, remembered under `Theta_DSPromoDialogSeen`) |

---

## General

- **Open Links in External Browser / Strip Tracking from Links** (`General/ExternalBrowser.m`):
  hooks `IGBrowserNavigationController -viewWillAppear:`, reads the request out of
  `browserSession._urlRequest` via the runtime API, unwraps `l.instagram.com/?u=…` redirects, and
  either opens the cleaned URL with `UIApplication -openURL:` and dismisses the in-app browser, or
  (strip-only mode) writes a cleaned `NSURLRequest` back into the ivar. Stripped parameters:
  `utm_*`, `fbclid`, `igshid`, `igsh`, `ig_rid`, `campaign_id`, `ad_id`, `aem`.
- **Date Format** (`General/DateFormat.m`): hooks four `NSDate` category methods IG adds —
  `formattedDateInMixedFormat`, `formattedDateRelativeToNow`,
  `shortenedFormattedDateRelativeToNow`, `shortenedFormattedDateRelativeToNowHideSeconds:` — and
  returns a formatted string per the segment index (1 `MMM d`, 2 `MMM d, yyyy`, 3 12-hour,
  4 24-hour, 5 `yyyy-MM-dd`, 6 `yyyy-MM-dd HH:mm`), falling through to `orig` for index 0.
- **Liquid Glass** (`General/LiquidGlass.m`): the most invasive feature. Three layers:
  1. **C symbols** patched with Substrate (`ThetaMSHookFunction`) — `IGFloatingTabBarEnabled`,
     `IGTabBarDynamicSizingEnabled`, `IGTabBarEnhancedDynamicSizingEnabled`,
     `IGTabBarHomecomingWithFloatingTabEnabled`, `IGTabBarViewPointFixEnabled`,
     `IGTabBarStyleForLauncherSet` — installed from the constructor and retried up to 2 s.
  2. **Experiment/launcher flags** — `IGLiquidGlassSwizzle.IGLiquidGlassSwizzleToggle -isEnabled`,
     `IGLiquidGlassExperimentHelper.IGLiquidGlassNavigationExperimentHelper -isEnabled` /
     `-isHomeFeedHeaderEnabled`, and six `IGDSLauncherConfig` predicates (in-app notification,
     context menu, toast, toast peek, alert dialog, icon bar button).
  3. **Homecoming plumbing** — `IGTabBarViewControllerManager -_isHomecomingEnabled`,
     `IGSundialFeedViewController -_isHomecomingEnabled` / `-_isHomeComingHomeFeed`,
     the class method `+[IGMainAppSurfaceIntent resolvedHomeAppSurfaceIntentWithIsHomecomingEnabled:]`
     (hooked via the metaclass), and
     `IGSundialViewerManagedRequestItem -initWithMedia:launcherSet:isHomecomingEnabled:`.

  It also writes IG's own override key `instagram.override.project.lucent.navigation` into
  `NSUserDefaults` to match the "Buttons" toggle. Both toggles are documented as
  restart-required.

---

## Media (reels playback)

- **Tap Controls / Always Show Scrubber** (`Media/TapControls.m`): hooks the 9-argument
  `IGSundialPlaybackControlsTestConfiguration -initWithLauncherSet:tapToPauseEnabled:…` and
  rewrites arguments before calling through — `tapToPauseEnabled` per segment index (1 = pause/play,
  2 = mute), and for the scrubber `minScrubberDurationSec = 0`,
  `persistentScrubberMinVideoDuration = 0`, `isScrubberForShortVideoEnabled = YES`.

---

## Messages

- **Mark As Seen** (`Messages/MarkAsSeen.m`, 1446 lines) is the largest DM feature. Pieces:
  - `ThetaHookShouldUpdateLastSeen()` (`:1391`) hooks `-shouldUpdateLastSeenMessage` on the first
    of `IGDirectThreadViewListAdapterDataSource`, `IGDirectMessageListDataSourceAdapter`,
    `IGDirectMessageListDataSource` that implements it, and otherwise scans `objc_getClassList`
    for any class whose name contains `Direct` that implements it *itself* rather than inheriting
    it. The hook returns `NO` to suppress automatic read receipts — but takes a fast path back to
    `orig` when no relevant setting is on **and** the auto-mark list is empty, to avoid KVC on IG
    441 data sources that throws. If a thread participant is on the auto-mark list, normal
    behavior is restored for that thread.
  - Injects two bar-button items into DM thread navigation (`IGTallNavigationBarView
    -setRightBarButtonItems:` and `UINavigationItem -setRightBarButtonItems:`): an `eye` that
    marks the last message seen, and a `plus.circle`/`checkmark.circle.fill` that toggles the
    current recipient in the auto-mark list. Both are tagged (`'THSE'`/`'THLS'`) and
    de-duplicated. `Hide Blend Button` and `Hide Call Buttons` are implemented in the same
    bar-items hook.
  - `theta_performMarkLastMessageAsSeen()` deliberately resolves the Swift message-list view
    controller (or a "last seen tracker") before calling `markLastMessageAsSeen` — calling it on
    an arbitrary delegate silently no-ops, which is documented in-tree as the bug that broke
    Seen On Typing.
  - Resolving *which* thread/username is on screen is done defensively through many fallbacks:
    thread VC from view → from window → first VC with participants; username from view model, from
    participants, or scraped from visible nav-bar text.
  - `Seen On React` hooks four arities of the reaction-selection delegate plus
    `performDoubleTapActionForCell:withViewModel:[animated:]`; `Seen On Send` hooks the composer's
    `didTapSend` / `_didTapSend` / `_didTapSend:`, falling back to
    `IGDirectComposerSendController`.
- **Seen On Typing** lives in `Messages/BypassCharacterLimit.m`'s composer `layoutSubviews` hook,
  which watches composer text transitions with throttling maps (`kThetaShowThrottleSeconds` 5 s,
  `kThetaEmptyStableSeconds` 0.75 s) so a single typing session marks once.
- **Bypass Character Limit** (same file): hooks `IGDirectComposer -layoutSubviews`
  (Swift name fallback) and adjusts the composer so long text is accepted.
- **Keep Deleted Messages** (`Messages/KeepDeletedMessages.m`): hooks
  `IGDirectCacheUpdatesApplicator -_applyThreadUpdates:completion:[userAccess:]`, digs out
  `threadUpdates[0]._messageUpdate._removeMessages_messageKeys`, and if every key is an
  `IGDirectMessageUpdateMessageKey` with a `_messageServerId`, records the ID via
  `[[MessagesManager sharedManager] saveDeletedMessageWithID:]` and **returns without calling
  `orig`** — the deletion never reaches the cache, so the bubble stays until the thread reloads.
  `hook_directMessageCell_configure` then recolors known-deleted bubbles using
  `Deleted Message Color`.
- **Private Media Ghost** (`Messages/PrivateVideoGhost.m`): hooks
  `IGDirectVisualMessageViewerController -viewDidLoad` to add up to two buttons (download, manual
  seen) into the viewer container, and `-storyPlayerMediaViewDidPlay:` /
  `IGStoryPhotoView -progressImageView:didLoadImage:…` to withhold the automatic seen report.
  The manual seen button replays the appropriate delegate call on the real media view.
- **Save Audio Messages** (`Messages/SaveAudioMessage.m`): hooks `IGDirectAudioPlayer
  -playWithAudio:progress[InSeconds]:…` to stash `_server_audio.playbackURL` on the player as an
  associated object, then on `-audioPlayerDidPlayToEnd:` offers to download it — through
  `performDownloadToAudioNotesWithURL:` and, if not already MP3, `convertFileToMP3:`
  (FFmpegKit, `libmp3lame -q:a 0`).
- **Upload Audio Messages** (`Messages/UploadAudioMessage.m`): hooks
  `IGDirectThreadViewVoiceController -startRecordingWithButtonTapFromEntryPoint:` and replaces the
  tap with a three-way alert — Camera Roll (`UIImagePickerController`), Files
  (`UIDocumentPickerViewController`, `public.mpeg-4-audio`/`public.mp3`), or record normally. The
  chosen file is fed into the real recording pipeline via whichever of three candidate record
  selectors exists.
- **Send Files** (`Messages/SendFile.m`): hooks
  `IGDirectThreadViewController -composerOverflowButtonMenuWillPrepareExpandWithPlusButton:` to
  arm a flag, then intercepts the next `IGDSMenu -initWithMenuItems:edr:headerLabelText:` and
  prepends an `IGDSMenuItem` titled "Send File". Picking a document calls
  `messageSenderFeatureController.messageSender`'s
  `sendFileWithURL:threadKey:attribution:…` (9 arguments, the rest nil).
- **Full Last Active Date** (`Messages/FullLastActive.m`): hooks
  `IGDirectLeftAlignedTitleView -setTitleViewModel:` and `-animationCoordinatorDidUpdate:`, and
  rewrites `_subtitleLabel` (plus `_subtitleView` and `_transitionalSubtitleLabel`) when the text
  matches `Active … ago`, preferring a real `lastActiveDate` from the view model and falling back
  to parsing the relative string.

---

## Save

See [media-pipeline.md](media-pipeline.md) for the download/transcode/import machinery; this
section covers where the buttons come from.

- **`Save/SavePosts.m`** (1705 lines) hooks two UFI surfaces:
  - `IGUFIInteractionCountsView -layoutSubviews` — injects a tag-`999` button next to `_sendView`
    with a `UIMenu` containing "Download Media" (`Save Media`) and "Fullscreen Current Media"
    (`Fullscreen Posts`). Also implements `Hide Repost Button` by hiding `_repostView`.
  - `IGSundialViewerVerticalUFI -configureWithViewModel:` / `-layoutSubviews` — injects the reel
    download button above the like button, with a `UIDeferredMenuElement` that builds a
    **per-quality menu** at open time from the DASH manifest (label, codec, resolution, estimated
    size), plus the repost-column removal logic that detaches the whole stack slot.
- **`Save/SaveProfilePictures.m`**: hooks `IGProfilePictureImageView
  -buttonDidReceiveTouchDown`, attaches a long-press recognizer (with a permissive gesture
  delegate so it coexists with IG's own gestures), resolves the URL through
  `_imageView.imageSpecifier.url`, and offers save and/or fullscreen per
  `Save Profile Pictures` / `Fullscreen Profile Pictures`.
- **`Save/AudioNote.m`** (`Save Audio Notes`): hooks `layoutSubviews` on
  `IGMusicStickerAudioIndicatorView`, `IGVinylMusicSticker`, and `IGSmallAlbumArtMusicSticker`,
  resolves the audio URL (via `IGDashManifestBestAudioURL` when the sticker carries a manifest),
  and downloads with an `NSURLSessionDownloadDelegate` that drives a progress toast.
- **Save Profile Posts / Follow Status Indicator** (`UI/FollowStatusIndicator.m`): hooks
  `IGProfileHeaderIdentity.IGProfileHeaderIdentityNameView -layoutSubviews`. Appends ` | ✅` or
  ` | ❌` to the profile name's styled string based on `user.followsCurrentUser` (removing any
  previous suffix first, and never on your own profile), and injects a pink save button
  (tag `424242`) that gathers the loaded posts on the profile and hands them to the bulk save
  path. Both read their preferences with raw `boolForKey:@"…_Enabled"` rather than the `ENABLED`
  macro — same keys, same result.

---

## UI

- **Settings entry points**:
  - `UI/SettingsButton.m` — gear button (tag `777`) in `IGHomeFeedHeaderView`, skipped when
    `Shake To Open` is on. Guarded by a per-instance associated-object flag.
  - `UI/tabbar.m` — `IGTabBarController -_homeButtonLongPressed:` opens Theta settings, *unless*
    `Messenger Mode` is on, in which case IG's default long-press is restored and a long-press
    recognizer is attached to `_directInboxButton` instead (attached/detached in
    `-_layoutTabBar`).
  - `Behavior/ShakeToOpen.m` — shake gesture.
- **`UI/HideTabs.m`** (632 lines) implements the four `Hide … Tab` toggles and `Messenger Mode` by
  mutating IG's tab-bar state in three places, since hiding only the button leaves navigation
  inconsistent: the `_buttons` array (matched by accessibility label — "Home"/"Feed", "Explore",
  "Reels", "Direct messages"/"Messages"), the swipe coordinator's `_surfaces`, and
  `_tabBarSurfaces` (matched by `tabStringFromSurfaceIntent` → `FEED`/`CLIPS`/`SEARCH`/`DIRECT`).
  Removals work on mutable copies written back via KVC; view removal detaches the enclosing
  `UIStackView` slot so the remaining tabs re-space; afterwards it re-lays out the tab bar, syncs
  the swipe coordinator and selection, and reloads tab-bar collection views. Because hooks install
  after the first `viewWillAppear:`, `THApplyTabHidingNow()` is also invoked directly on the next
  run-loop turn and 500 ms later.
- **`UI/Navigation.m`** covers the three navigation segments:
  `_TtC18IGNavConfiguration18IGNavConfiguration -tabOrdering` (maps segment 1/2/3 → IG ordering
  0/1/2), `-isTabSwipingEnabled`, and `Launch Tab` — which hooks
  `IGTabBarController -viewWillAppear:` and, once per launch, sends the matching private selector
  (`_timelineButtonPressed`, `_exploreButtonPressed`, `_discoverVideoButtonPressed`,
  `_directInboxButtonPressed`, `_profileButtonPressed`). Suppressed entirely under
  `Messenger Mode`. **All Navigation features are known-broken on sideload.**
- **`UI/HideCreateButton.m`** (`Hide Create Tab/Button`) removes the create affordance from three
  surfaces: `IGHomeFeedHeaderView._createButton`, the
  `IGUnifiedVideoCameraEntryPointButton` subview of the sundial nav bar, and the profile nav
  header's `_leftButtons` entry whose accessibility label is "Tap to open creation menu"
  (also patching `-titleView`).
- **`UI/HideCreateGroupButton.m`** (`Hide "Create Group" Button`) hooks three share-sheet classes:
  the bottom buttons view's `secondaryButtonTappedWithButton:`, the container's
  `setSecondaryButtonEnabled:animated:`, and the facepile button's `layoutSubviews`.
- **`UI/HideExploreGrid.m`** removes `IGListCollectionView` from its superview during
  `layoutSubviews` when the enclosing view controller is `IGExploreGridViewController`.
- **`UI/SortUserGridPosts.m`** — **not exposed in settings**. Hooks
  `UICollectionView -layoutSubviews` globally, and on any collection view whose accessibility
  label is "Grid" inside `IGProfileViewController` attaches a long-press that toggles
  ascending/descending ordering of the profile grid. Implementation is unusual: it lazily
  `class_replaceMethod`s `objectsForListAdapter:` on the *data source's class* (stashing the
  original IMP in an associated object on the class), sets an ascending flag on the adapter, then
  forces a reload through `reloadData` → `reloadSections:` →
  `reloadDataWithCompletion:`/`performUpdatesAnimated:completion:` → `performBatchUpdates:`.
  It is also very chatty with `NSLog`.
- **`UI/GIFNameOverlay.m`** — no hooks and no register function. Provides
  `IGGifOverlayManager` (Giphy name lookup + a queued on-screen overlay, 5 s per message,
  50-ID dedupe ring) used by `CommentTextCopy.m`. `assemble.py` forces this file to the front of
  the hook concatenation so that dependency resolves.
- **Hide Theta From Screenshots** is not a hook but a helper: `ThetaSetCaptureHiding()`
  (`THGlobalsAndHooking.m:130`) sets the private `disableUpdateMask` on a view's layer
  (bits 1 and 4), and injected controls throughout the tree call it.

---

## Sideload-only

| File | Purpose |
| --- | --- |
| `Sideload/Sideload.m` | Fakes app-group containers under `Documents/FakeGroupContainers` (hooking `NSFileManager -containerURLForSecurityApplicationGroupIdentifier:` and `-createDirectoryAtPath:…`), and discovers the real sideload keychain access group by probing with a dummy item |
| `Sideload/HideTestFlightNag.m` | Dismisses `_TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController` from `viewDidLoad`/`viewWillAppear:`/`viewDidAppear:`. Ships an empty `THRegisterHideTestFlightNagHooks()` in the `#else` branch so `THTweak.m` links on jailbreak |
| `Behavior/DismissIGDSPromoDialog.m` | Registration body is `#ifdef SIDELOAD`-only |

Full details in [sideload.md](sideload.md).
