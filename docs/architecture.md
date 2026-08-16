# Architecture

## 1. Two products from one source tree

| | Jailbreak | Sideload |
| --- | --- | --- |
| Artifact | `packages/com.theta.tweak_<ver>_iphoneos-arm[64].deb` | `output/Instagram_patched.ipa` |
| Injection | MobileSubstrate loads the dylib into processes matched by `Theta.plist` (`com.burbn.instagram`) | `tools/insert_dylib` adds `@executable_path/Theta.dylib` to the app binary's load commands |
| Substrate | `Depends: mobilesubstrate`; linked with `-lsubstrate` | Weak-linked `CydiaSubstrate.framework`, staged into the `.app` by `build.sh` |
| Compile flags | — | `-DSIDELOAD=1`, plus Substrate headers/framework search paths |
| Extra runtime work | — | Keychain access-group rewriting, fake app-group containers (see [sideload.md](sideload.md)) |

`ROOTLESS=1` selects Theos's rootless package scheme and defines `ROOTLESS=1`, which switches
`ROOT_PATH_NS()` (`Include/rootless.h`) to prefix absolute paths with `/var/jb`. `SIDELOAD` and
`ROOTLESS` are mutually exclusive — the Makefile hard-errors if both are set.

## 2. Build pipeline

`./build.sh [rootful|rootless|sideload]` is the supported entry point; `make package
[ROOTLESS=1|SIDELOAD=1]` is equivalent for the jailbreak targets.

```
before-all::
    rm -f TweakCOMPILE.xm
    python3 scripts/assemble.py        # generates the amalgamated TU
    mkdir -p ThetaResources.bundle
    mkdir -p "layout/Library/Application Support/ThetaResources.bundle"

    → theos tweak.mk compiles:
        TweakCOMPILE.xm                 (all Runtime + all Hooks, one TU)
        fishhook.c
        Source/UI/*.m                   (separate TUs)
        Source/Media/*.m                (separate TUs)
        Source/ProfileAnalyzer/*.m      (separate TUs)

after-all::
    rm -f TweakCOMPILE.xm
```

Toolchain requirements that are easy to get wrong:

- `SDKVERSION = 14.5` with the **patched** `iPhoneOS14.5.sdk` from `sdks/` unpacked into
  `$THEOS/sdks`. A stock Xcode SDK lacks the Theos private-framework stubs and will not build.
- `PREFIX = $(THEOS)/toolchain/Xcode14.xctoolchain/usr/bin/` — the non-obfuscating toolchain
  (there is no Hikari step in this rebuild).
- `build.sh` shells out to `codesign`, `install_name_tool`, `/usr/libexec/PlistBuddy`, `xattr`,
  `rsync`, and compiles `tools/insert_dylib.c` with `cc`. macOS only.

Sideload additionally: strips signatures (`codesign --remove-signature` then ad-hoc re-sign),
rewrites the dylib's install name and its Substrate dependency to `@executable_path/…`, copies
`ThetaResources.bundle` and (if present) `layout/Library/Application Support/ffmpeg.framework`
into the `.app`, cleans `.DS_Store`/xattrs, and zips `Payload` into the IPA.

### CI

`.github/workflows/build-sideload-dylib.yml` compiles the sideload dylib on `macos-14`
(`workflow_dispatch`, PRs, and pushes to `main`/`claude/**`, skipping markdown-only changes). It
installs Theos, unpacks the vendored `sdks/iPhoneOS14.5.sdk.tar.xz`, symlinks
`$THEOS/toolchain/Xcode14.xctoolchain` at the selected Xcode (the Makefile hard-codes that
`PREFIX`), fills in `$THEOS/vendor/lib/CydiaSubstrate.framework` from `third_party/` if the Theos
clone lacks it, runs `gmake SIDELOAD=1`, then applies the same `install_name_tool` rewrites and
ad-hoc signature `build.sh` applies when staging the dylib into an `.app`.

It is a **compile check**, not a release pipeline: it produces `Theta.dylib` as an artifact and
stops before injection, since `./build.sh sideload` needs a decrypted
`input/Payload/Instagram.app/Instagram` that cannot be committed. Nothing verifies runtime
behavior — that is still manual, on device.

There are **no tests or linters** in the repository. `Theta_CFLAGS` also suppresses
`-Wincompatible-pointer-types`, `-Wnullability-completeness`, `-Wunused-*`, and
`-Wdeprecated-declarations`, so the compiler catches noticeably less than usual — in particular
mismatched hook function signatures will compile silently.

## 3. The amalgamated translation unit

`scripts/assemble.py` concatenates sources in a fixed order into `TweakCOMPILE.xm`:

1. `Source/Runtime/THGlobalsAndHooking.m` — globals, swizzle helpers, KVC helpers, miss recording
2. `Source/Runtime/THNativeToast.m` — reflection-driven use of IG's own toast presenter
3. `Source/Runtime/THSideloadFishhook.m` — `SecItem*` / `strlen` rebindings (bodies are
   `#ifdef SIDELOAD`-guarded internally)
4. `Source/Runtime/THSubstrate.m` — Substrate loader / `MSHookFunction` wrapper
5. `Source/Hooks/UI/GIFNameOverlay.m` — **forced first** among hooks
6. The rest of `Source/Hooks/**/*.m` — `os.walk` order, filenames sorted within each directory
7. `Source/Runtime/THTweak.m` — entry point, last

The file is gitignored and deleted after every build. **Never edit `TweakCOMPILE.xm`** — edit the
sources it concatenates.

### Why it is done this way

Because everything lands in one TU:

- Hook files can keep `orig_*` pointers and `hook_*` functions `static` (file-local in intent)
  without needing headers, and without exporting dozens of symbols. Only the
  `THRegister…Hooks()` functions are non-static.
- Hook files get `THGlobalsAndHooking.m`'s statics for free with no imports: `ENABLED`,
  `NullHookMessage`, `NullHookMessageEx`, `NullHookMessageIfPresent`, `ThetaInstallMessageHook`,
  `ThetaFirstClass`, `ThetaHookFirst`, `ThetaValueForKey`, `ThetaSetValueForKey`,
  `ThetaSetCaptureHiding`, plus globals like `appVersion`. Most hook files import nothing at all.
- Cross-file `static` reuse works, and it is used deliberately:
  - `Source/Hooks/Behavior/StorySeenOn.m` calls `seenButtonPressedCurrent()` defined in
    `Source/Hooks/Behavior/StoryGhost.m` — legal only because `StoryGhost.m` sorts before
    `StorySeenOn.m` in the same directory.
  - `Source/Hooks/Behavior/CommentTextCopy.m:285` calls `[IGGifOverlayManager fetchGifName:…]`,
    a class defined in `Source/Hooks/UI/GIFNameOverlay.m` — which is exactly why `assemble.py`
    forces that file to the front.

The corresponding constraints:

- **`static` names must be unique across every file under `Source/Hooks/`.** Two files declaring
  `static void hook_layout(...)` will collide at compile time.
- Ordering is load-bearing. A new cross-file `static` dependency only works in
  concatenation order.
- `Source/UI/`, `Source/Media/`, and `Source/ProfileAnalyzer/` are compiled as **separate** TUs
  via Makefile wildcards. They must `#import` their own headers from `Include/`, they cannot see
  the hook helpers, and several of them redefine `ENABLED` locally
  (e.g. `Source/UI/SettingsViewController.m:13`, `Source/UI/MessagesManager.m:5`).
- The output extension is `.xm`, so Logos preprocessing runs. The only directive used is
  `%c(Class)` (22 occurrences); there are no `%hook`/`%orig`/`%new` blocks anywhere.

## 4. Load and initialization order

`Source/Runtime/THTweak.m`:

```
__attribute__((constructor)) ThetaLoad()
├── #ifdef SIDELOAD: install_fishhook_rebindings(); RunSideloadSetupOnce()   ← must be earliest
├── THRegisterLiquidGlassTabBarEarlyHooks()      ← C-symbol hooks, before IG reads the flags
├── appVersion = CFBundleShortVersionString
├── [ThetaHelper cleanupTemporaryMediaFiles]     ← sweep leftovers from previous runs
├── dispatch_async(main) → ObserveAppLifecycle()
│     ├── observe UIApplicationDidFinishLaunching → StartTweakWhenReady()
│     ├── observe UIApplicationDidBecomeActive    → StartTweakWhenReady() + PA image prefetch
│     └── StartTweakWhenReady() immediately too
└── dispatch_after(2s) → [THProfileAnalyzerViewController prefetchProfileImageIfNeeded]

StartTweakWhenReady()
└── on main queue: if applicationState == Background → retry in 100 ms; else InitializeHooks()

InitializeHooks()          ← guarded by the `hooksInitialized` flag, runs exactly once
├── 54 THRegister…Hooks() calls, synchronous, main thread
└── dispatch_async(main):
      ├── THRegisterDeferredDBBHooks()           ← needs classes that only exist post-auth
      ├── dispatch_after(1s):  "Load Banner" toast (if enabled)
      ├── dispatch_after(3s):  first-run StoryGesturesNuxViewController (one-shot)
      └── flush collected hook misses to stderr
```

Two timing subtleties worth knowing:

- **Early vs deferred.** `THRegisterLiquidGlassTabBarEarlyHooks()` runs in the constructor
  because it patches C functions (`IGFloatingTabBarEnabled`, `IGTabBarStyleForLauncherSet`, …)
  that IG evaluates during startup; it retries on several run-loop turns and again at 300 ms and
  2 s because the owning images may not be loaded yet. Conversely, `THRegisterDeferredDBBHooks()`
  and tab-hiding fix-ups run *after* first layout, because the classes/views don't exist earlier.
- **Hooks install post-auth**, so `viewWillAppear:` has often already fired for the visible tab
  bar. `THRegisterHideTabsHooks()` therefore also applies its changes imperatively via
  `THApplyTabHidingNow()` on the next run-loop turn and again 500 ms later
  (`Source/Hooks/UI/HideTabs.m:622`).

The first-run NUX marks itself seen in `NSUserDefaults` (`ThetaFirst`) **before** presenting, so
a crash inside the NUX can't produce an infinite loop, and it refuses to present on top of
another modal or of a `TestFlight`/`SecurityViewController` screen.

`__attribute__((destructor)) ThetaUnload()` just logs.

There is one other constructor: `THMigrateFeedSettingTitles()` in
`Source/Hooks/Behavior/HideFeedFiltering.m:8` copies six legacy `"Strip …"` preference keys onto
their current `"Hide …"` names.

## 5. Hook installation and diagnostics

All swizzling funnels through `ThetaInstallMessageHook()`
(`Source/Runtime/THGlobalsAndHooking.m:148`). Its contract:

- Looks up the instance method first, then the class method; hooks whichever exists.
- Captures the real IMP with `method_getImplementation` **before** modifying anything.
- If `class_addMethod` succeeds, the method was inherited and we just added an override — the
  captured IMP (the superclass implementation) becomes `orig`. If it fails, the method already
  exists on this class and `method_setImplementation` swaps it, returning the previous IMP.
- Writes the result to `*original` and returns whether an `orig` was obtained.

This exists because `class_replaceMethod` returns `NULL` when it *adds* an override for an
inherited method. Using that return value as `orig` leaves a NULL function pointer that crashes
(`EXC_BAD_ACCESS`, PC=0) on first call. The comment at
`Source/Runtime/THGlobalsAndHooking.m:141` documents it; never bypass the wrappers.

Three public wrappers:

| Wrapper | Records a miss when absent? | Use for |
| --- | --- | --- |
| `NullHookMessageEx` | yes | symbols expected to exist on the target IG version |
| `NullHookMessageIfPresent` | no | classes that legitimately vary by IG version, or exist only under sideload |
| `NullHookMessage` | yes (on `class_addMethod` failure) | *adding* a new no-arg method (`"v@:"` encoding) |

Misses are appended to a lock-protected array (`RecordFailedHookLine`) and flushed ~1 s after
launch from the deferred block in `InitializeHooks()`:

```
[Theta] N hook install miss(es):
[Theta] miss: -[IGSomeClass someSelector] — method not found
```

They are printed with `fprintf(stderr, …)` deliberately: `os_log`/`NSLog` redacts `%@` arguments
as `<private>` in Console, which would make the diagnostics useless.
`PresentAggregatedHookFailureAlert()` exists for showing the same list in a `UIAlertController`
but is not wired into the launch path — launch is not blocked by an alert.

Because every lookup is by name, an Instagram update that renames a class or selector shows up as
a miss line and a silently missing feature — never a build error. That is the intended failure
mode; see [hooking.md](hooking.md) for the multi-candidate resolution helpers that soften it.

## 6. Preferences plumbing

There is no preference bundle, no `defaults` domain juggling, and no constants file. Settings are
plain `NSUserDefaults` values under keys derived from the **setting title string**:

| Setting `type` | Key | Written by | Read as |
| --- | --- | --- | --- |
| (default switch) | `<Title>_Enabled` | `CustomSwitchCell` toggle | `ENABLED(@"<Title>")` |
| `segment` | `<Title>_SegmentIndex` | `[ThetaHelper storeSegmentIndex:forSettingTitle:]` | `integerForKey:` |
| `color` | `<Title>_Color` | `UIColorWell` → `NSKeyedArchiver` | `NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class]` |
| `view` | — | pushes `viewController` by name | — |
| `action` | — | runs a selector (`clearAppCache`, `resetColors`) | — |

`ENABLED` is defined in `Include/ThetaTweakCommon.h:11` as
`boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]`, and redefined identically in the
separately-compiled UI files. The title in `SettingsViewController.m` and the literal inside
`ENABLED(...)` are the same string — a typo in either silently disables the feature. Details and
the full key list are in [settings-reference.md](settings-reference.md) and
[ui-layer.md](ui-layer.md).

## 7. Subsystem map

```
Source/
  Runtime/            amalgamated into TweakCOMPILE.xm
    THGlobalsAndHooking.m   swizzle helpers, safe KVC, miss recording, screenshot-hiding helper
    THNativeToast.m         drives IG's own toast presenter/view-model by reflection
    THSideloadFishhook.m    SecItem*/strlen rebinding via fishhook.c
    THSubstrate.m           dlopen Substrate at 4 paths; resolve symbols in the IG executable
    THTweak.m               constructor, lifecycle observers, InitializeHooks()
  Hooks/              one feature per file, one THRegister…Hooks() each
    Behavior/ General/ Media/ Messages/ Save/ UI/ Sideload/
  UI/                 separate TUs
    SettingsViewController.m (~2k lines), SubMenuViewController.m, CustomSwitchCell.m,
    ThetaSwitch.m (wraps IGDSSwitch if present), CustomToastView.m (progress toasts),
    ThetaHelper.m (toasts, haptics, top-VC lookup, temp cleanup, global download mutex),
    SecurityViewController.m (app lock), MessagesManager.m (deleted-message plist),
    ThetaUserListEditorViewController.m, StoryGesturesNuxViewController.m
  Media/              separate TUs
    ThetaDashManifest.m (DASH parsing + Photos-compatible export helpers),
    AV1Transcoder.m (FFmpeg via dlopen), MediaSelectionViewController.m (~2.4k lines,
    bulk download UI), MediaViewController.m (fullscreen viewer),
    AudioNotesViewController.m (saved-files browser)
  ProfileAnalyzer/    separate TUs
    APIClient (URL building) · Service (pagination, pacing, backoff) ·
    DiffEngine (set math) · Storage (raw sqlite3) · Types · ViewController (~2.2k lines)
Include/            headers, incl. InstagramHeaders.h (595 lines of IG interfaces)
Include.h           umbrella header + sideload extern declarations + UIGestureRecognizer block category
```

Cross-subsystem coupling is deliberately thin and explicit: `Include/ThetaTweakCommon.h` exports
exactly one cross-file function (`ThetaApplyHideFeedFiltering`), `Include/ThetaDashManifest.h`
exports the DASH/Photos helpers used by both `SavePosts.m` and `MediaSelectionViewController.m`,
and `Include/ThetaSubstrate.h` exports the three Substrate entry points.

## 8. Known dead / vestigial code

Useful to know so you don't go looking for the wiring:

- `Source/Hooks/Behavior/FirstLaunchAlert.m` defines `hook_userSession`/`orig_userSession` but
  exports **no** `THRegister…` function, so it is compiled and never installed. The first-run
  experience is handled by `THTweak.m`'s `StoryGesturesNuxViewController` block instead.
- `Source/Hooks/Messages/KeepDeletedMessages.m` keeps a large commented-out
  `hook_directMessageCell` implementation (the "deleted at" trash-badge UI) alongside the live
  `hook_directMessageCell_configure`.
- `Source/Hooks/Behavior/HideAds.m:26-45` double-counts sponsored items into `adsToRemove`
  (harmless — `removeObjectsInArray:` is idempotent for the same object).
- `cleanupTemporaryFiles()` is defined and never called in both
  `Source/Hooks/Save/SavePosts.m:13` and `Source/Media/MediaSelectionViewController.m:20`,
  superseded by the per-job work-directory sweep (`theta_makeReelSaveWorkDir` / `finishJob`) and
  `[ThetaHelper cleanupTemporaryMediaFiles]`.
