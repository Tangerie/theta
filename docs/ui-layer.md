# UI layer

`Source/UI/` and the view controllers in `Source/Media/` are compiled as ordinary, separate
translation units — they `#import` from `Include/` and cannot use the hook helpers. Several of them
redefine the `ENABLED` macro locally.

## 1. Entry points into Theta's settings

Three ways in, all presenting `SettingsViewController` inside a `UINavigationController` with
`UIModalPresentationPageSheet`:

| Trigger | Implemented in |
| --- | --- |
| Gear button in the home-feed header (tag `777`) | `Hooks/UI/SettingsButton.m` — suppressed while `Shake To Open` is on |
| Long-press the home tab | `Hooks/UI/tabbar.m` — hooks `IGTabBarController -_homeButtonLongPressed:` |
| Long-press the DM tab (Messenger Mode only) | `Hooks/UI/tabbar.m` — recognizer attached to `_directInboxButton` in `-_layoutTabBar`; the home-tab long-press reverts to IG's default |
| Shake the device | `Hooks/Behavior/ShakeToOpen.m` — hooks `UIMotionEvent -setShakeState:` |

## 2. `SettingsViewController` (~2k lines)

A `UITableViewController` (inset-grouped) built entirely in code. Structure:

- **`self.subMenus`** — eight `SubMenuItem`s (General, Feed, Messages, Media, Reels, Navigation,
  Interface, Miscellaneous), each with a title, one-line detail, and SF Symbol name.
- **`self.settingsBySubMenu`** — the declarative settings dictionary (see
  [settings-reference.md](settings-reference.md)). This is the single source of truth: search,
  export, import, reset, and the submenu screens all iterate it.
- **`self.linkItems`** — the Twitter/X and Discord rows.
- **Search** — a `UISearchController` in the navigation item. `updateSearchResultsForSearchController:`
  filters submenus *and* flattens every setting into `SettingSearchResult` objects (carrying the
  parent submenu title, type, and segment options) so a matched setting is rendered with its real
  control — switch, color well, or segmented control — directly in the results list.
- **Navigation-bar buttons** — `chevron.down` to dismiss, `folder` to open
  `AudioNotesViewController`, and a `gearshape` that holds the action menu.

### The gear menu

```
gearshape
├── Apply Settings   → Confirm / Cancel
├── Import/Export Settings
│   ├── Import Settings → Import QR Code (photo library) · Scan QR Code (camera) · Import from Clipboard
│   └── Export Settings → Export QR Code · Show QR Code · Export to Clipboard
└── Reset Settings   → Confirm (destructive) / Cancel
```

- **Apply Settings** re-writes each `_Enabled` key to its current value, `synchronize`s, toasts
  "Settings Applied! App will need to be restarted", then after 3 s calls
  `-[UIApplication suspend]` and `exit(0)` — i.e. it force-quits Instagram so restart-required
  settings take effect.
- **Reset Settings** removes every `<Title>_Enabled` key and every `<Title>_Color` key. (Segment
  indices are not cleared.)
- **Reset Colors** (an `action` row in Interface) removes just the four color keys
  (`SettingsViewController.m:1705`, `SubMenuViewController.m:609`).
- **Clear App Cache** (an `action` row in Miscellaneous) walks `NSCachesDirectory` and friends,
  deleting files and reporting how many and how much.

### Settings transfer format

Export builds a dictionary keyed by submenu title, each value an array of
`@{ @"title", @"enabled", optional @"colorHex", optional @"selectedIndex" }`, then:

```
JSON → zlib deflate (compressData, Source/UI/SettingsViewController.m:604)
     → base64 → either the clipboard or a CIQRCodeGenerator image
```

Import reverses it (base64 → `decompressData:` → JSON) and writes `_Enabled` booleans,
`_SegmentIndex` integers, and colors — converting `colorHex` back into an
`NSKeyedArchiver`-archived `UIColor` for the `_Color` key. Three import routes exist:
a QR image picked from the photo library (`CIDetectorTypeQRCode`), a live camera scan
(`AVCaptureSession` + `AVCaptureMetadataOutput`, with `SettingsViewController` as the
`AVCaptureMetadataOutputObjectsDelegate`), and the clipboard.

Note the asymmetry: the transfer format speaks **hex colors**, while `NSUserDefaults` stores
**archived `UIColor` objects**. The conversion happens at the import/export boundary.

## 3. `SubMenuViewController`

Renders one submenu's array of setting descriptors. Cell selection by `type`:

| `type` | Cell |
| --- | --- |
| (default) | `CustomSwitchCell` with a `ThetaSwitch` and an optional ⓘ button when `info` is present |
| `color` | `UIColorWell` (alpha off) whose `accessibilityIdentifier` is the storage key; reads existing values with `unarchivedObjectOfClass:` and falls back to legacy `unarchiveObjectWithData:` |
| `segment` | `UISegmentedControl`; ≥4 options switch to a stacked layout (title/detail above, full-width control below) |
| `view` | pushes `NSClassFromString(viewController)`, passing `listKey`/`listTitle` for `ThetaUserListEditorViewController` |
| `action` | a pink icon button running `resetColors` or `clearAppCache` |

`requiresBiometrics: @YES` rows (only *Lock Instagram*) are disabled with an explanation when
`LAContext` reports no passcode/biometry enrolled.

`ThetaSwitch` (`Include/ThetaSwitch.h`) is a `UIControl` that embeds Instagram's own `IGDSSwitch`
at runtime when the class exists, and otherwise falls back to a compact `UISwitch` — so Theta's
toggles look native without a hard dependency on an IG class.

## 4. Toasts and alerts

Two toast systems, deliberately:

- **`CustomToastView`** (`Source/UI/CustomToastView.m`, 782 lines) — Theta's own banner, 50 pt from
  the key window's top. Supports a plain auto-hiding toast, a **persistent progress toast**
  (`showProgressToastWithTitle:subtitle:`, updated in place, closed with
  `completeProgressWithTitle:…`), a single overall `UIProgressView`, and a **stack of per-item
  bars** for bulk saves. It recalculates its own width, holds open while the user's finger is down
  (`isUserHolding`), and can carry a tap URL (save completions pass `photos-redirect://`).
- **`ThetaShowNativeToast` / `ThetaShowNativeToastWithEmoji`**
  (`Source/Runtime/THNativeToast.m`, 604 lines) — drives *Instagram's* toast UI so a message looks
  completely native. It is almost entirely reflection: locate an
  `IGActionableConfirmationToastPresenter` (or dig a toast controller out of the view hierarchy),
  construct IG's toast view-model, and present through the notification presenter — with three
  progressively simpler fallbacks (`presentToastWithImage`, `presentTextOnlyToast`,
  `presentMinimalToast`) when a step can't be resolved.

`Hooks/Behavior/ToastDismiss.m` reconciles the two: it delays IG's `dismissAnimated:` by 4 s if a
Theta toast appeared in the last 1.5 s, and translates IG toast views to the same 50 pt top margin.

`ThetaHelper` provides the shared conveniences:

```objc
+ showToastWithTitle:subtitle:icon:autoHide:openURL:      // gated by "Show Banners" at call sites
+ showLoadToast:subtitle:icon:autoHide:openURL:
+ showCustomAlertWithActions:description:actions:          // array of @{@"title", @"handler"}
+ performHapticFeedbackIfEnabled                           // gated by "Haptic Feedback"
+ imageFromEmojiString:width:                              // renders an emoji into a UIImage
+ nearestViewController: / + topViewController
+ createDirectoryIfNotExists: / + cleanupTemporaryMediaFiles
+ tryBeginGlobalDownloadOrNotify / + endGlobalDownload / + isGlobalDownloadInProgress
+ storeSegmentIndex:forSettingTitle:
+ iotaPinkColor / + cooldownPeriod
+ hexFromColour: / + colourFromHex:
```

`showCustomAlertWithActions:` is the basis of every confirmation feature — callers pass the
original invocation in a handler block.

## 5. Auxiliary view controllers

| Class | Purpose |
| --- | --- |
| `SecurityViewController` | The app lock. Dark blur + "Tap to Authenticate", runs `LAContext` evaluation on appear, allows 3 attempts and a 30 s timeout; on failure/timeout it toasts and terminates the app through a cascade of `exit(0)` → `terminateWithSuccess` → `kill(getpid(), SIGKILL)` → `abort()` |
| `ThetaUserListEditorViewController` | Generic editor for an array of usernames in `NSUserDefaults`; configured with `listKey` + `listTitle`. Backs both auto-mark lists |
| `AudioNotesViewController` | Browser for saved files, with two modes (`AudioNotesContentModeAudioNotes`, `…SavedMedia`) over `Documents/AudioNotes` |
| `StoryGesturesNuxViewController` | One-shot first-run explainer, presented 3 s after launch by `THTweak.m` |
| `MediaSelectionViewController` | Bulk download grid — see [media-pipeline.md](media-pipeline.md) |
| `MediaViewController` | Fullscreen zoomable photo / `AVPlayerViewController` video viewer |
| `THProfileAnalyzerViewController` (+ four sibling VCs) | see [profile-analyzer.md](profile-analyzer.md) |
| `MessagesManager` | Not a VC: a singleton persisting deleted-message IDs → timestamps in `Documents/deleted_messages.plist`, and toasting "Someone deleted a message." when `Show Banners` is on |

## 6. Look and feel conventions

- Accent color is `IOTA_PINK` (`#FF69B4`), available as `[ThetaHelper iotaPinkColor]` and as a
  macro in three headers.
- Icons are SF Symbols, with `@available(iOS 16, *)` alternates where a symbol is newer
  (e.g. `arrow.down.to.line` → `arrow.down`).
- The one bundled asset is `ThetaResources.bundle/ig_icon_story_mention_pano_outline_24_Normal2x.png`
  (the story-mentions glyph). Lookup tries the main bundle, the bundle's `resourcePath`, and
  `/Library/Application Support/ThetaResources.bundle` plus the `/var/jb` variant
  (`Hooks/Behavior/StoryGhost.m:943`), so the same code works rootful, rootless, and sideloaded.
- Injected controls call `ThetaSetCaptureHiding()` so they honor *Hide Theta From Screenshots*.
- Version strings shown in the UI come from the `THETA_VERSION` / `THETA_PROJECT` macros, derived
  from `control`'s `Version:` by the Makefile.
