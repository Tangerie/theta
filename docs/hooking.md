# Hooking: the toolkit, the rules, and adding a feature

Every hook in Theta is installed by hand at runtime. Nothing is resolved at link time, and
nothing uses Logos `%hook`. This document is the reference for the helpers, the failure modes
they exist to avoid, and the mechanical steps for a new feature.

## 1. Objective-C method hooks

### The primitive

```objc
static BOOL ThetaInstallMessageHook(Class cls, SEL sel, void *replacement,
                                    void *original, BOOL reportMissing);
```
`Source/Runtime/THGlobalsAndHooking.m:148`. Handles instance and class methods, captures the real
IMP before touching the class, and copes with the inherited-method case. Returns `NO` if the
class or method is missing.

### The wrappers you should actually call

```objc
NullHookMessageEx(cls, sel, replacement, &orig);        // records a miss if absent
NullHookMessageIfPresent(cls, sel, replacement, &orig); // silent if absent
NullHookMessage(cls, sel, replacement);                 // ADDS a new "v@:" method
```

Pick `Ex` when the symbol should exist on IG 441 and its absence is a bug worth seeing in the
miss log. Pick `IfPresent` when the class is genuinely optional: Swift-renamed variants, classes
that only exist under sideload (`FBSDKKeychainStore`, `UICKeyChainStore`, …), or legacy selectors
kept as fallbacks.

`NullHookMessage` hard-codes the `"v@:"` type encoding. If you need to *add* a method with a
different signature, do it directly — `Source/Hooks/Behavior/GetStoryMentions.m:42` adds
`-bigTest` returning `NSArray *` with the explicit `"@@:"` encoding for exactly this reason.

### Version-tolerant resolution

```objc
Class ThetaFirstClass(NSArray<NSString *> *names);
BOOL  ThetaHookFirst(NSArray<NSString *> *classNames,
                     NSArray<NSString *> *selectorNames,
                     void *replacement, void *original);
```

`ThetaFirstClass` returns the first `NSClassFromString` hit; `ThetaHookFirst` additionally tries
each selector in order and hooks the first that exists, silently. Prefer them wherever IG has
moved a class into a Swift module or renamed a selector. Real examples from the tree:

```objc
// Swift-mangled name first, ObjC name as fallback
Class ufi = ThetaFirstClass(@[ @"_TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI",
                               @"IGSundialViewerVerticalUFI" ]);

// same method under two names across versions
ThetaHookFirst(@[ @"IGDirectAudioPlayer" ],
               @[ @"playWithAudio:progressInSeconds:assetId:offlineAssetId:messageProductType:threadKey:",
                  @"playWithAudio:progress:assetId:offlineAssetId:messageProductType:threadKey:" ],
               (void *)hook_audioMessage, &orig_audioMessage);
```

Other patterns in use for the same problem:

- Explicit app-version branch — `Source/Hooks/Behavior/StorySeenOn.m:46` compares `appVersion`
  against `423.0.0` with `NSNumericSearch` and picks a different class name on each side.
- `respondsToSelector:`/`class_getInstanceMethod` probing before installing, so a mismatched arity
  doesn't get a hook with the wrong signature — `Source/Hooks/Behavior/CallConfirmation.m:38`
  (`_didTapAudioButton:` vs `_didTapAudioButton`),
  `Source/Hooks/Messages/UploadAudioMessage.m:573` (three candidate record selectors).
- Whole-runtime scan as a last resort — `Source/Hooks/Behavior/DBB.m:82` walks
  `objc_getClassList` looking for any class implementing
  `_handleForcedLogoutLoginPush:…` when the known class names fail.
- Class-method hooks must target the metaclass:
  `object_getClass(NSClassFromString(@"IGMainAppSurfaceIntent"))`
  (`Source/Hooks/General/LiquidGlass.m:459`).

## 2. C-function and inline hooks

`Include/ThetaSubstrate.h` exports three functions, implemented in
`Source/Runtime/THSubstrate.m`:

```objc
bool  ThetaSubstrateLoad(void);                              // idempotent; dlopens Substrate
void  ThetaMSHookFunction(void *symbol, void *replace, void **result);
void *ThetaResolveInstagramExecutableSymbol(const char *name);
```

`ThetaSubstrateLoad` tries `dlsym(RTLD_DEFAULT, "MSHookFunction")` first, then dlopens
`/usr/lib/libsubstrate.dylib`, `@executable_path/CydiaSubstrate.framework/CydiaSubstrate`,
`@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`, and bare
`CydiaSubstrate` — so the same code works jailed and jailbroken. If none resolve,
`ThetaMSHookFunction` is a silent no-op, which is the correct degradation for optional
inline hooks.

`ThetaResolveInstagramExecutableSymbol` matters more than it looks. A plain
`dlsym(RTLD_DEFAULT, name)` can return a framework's GOT stub rather than the definition inside
the app binary, and hooking the stub does nothing. The implementation therefore:

1. `dlsym`s, then `dladdr`s the result and accepts it only if the owning image path matches
   `Instagram.app/Instagram` (and is not inside a `.framework`) or is
   `FBSharedFramework.framework/FBSharedFramework`.
2. Otherwise walks `_dyld_image_count()` / `_dyld_get_image_name()`, dlopening each matching
   image with `RTLD_NOLOAD` first and `dlsym`ing inside it.

The only current consumer is the Liquid Glass feature
(`Source/Hooks/General/LiquidGlass.m:377`), which patches six boolean/style C functions
(`IGFloatingTabBarEnabled`, `IGTabBarDynamicSizingEnabled`,
`IGTabBarEnhancedDynamicSizingEnabled`, `IGTabBarHomecomingWithFloatingTabEnabled`,
`IGTabBarViewPointFixEnabled`, `IGTabBarStyleForLauncherSet`). Each is guarded by its own `done`
flag and retried on several run-loop turns, because the images may not be loaded when the
constructor runs.

Symbol **rebinding** (as opposed to inline patching) uses `fishhook.c` and is sideload-only; see
[sideload.md](sideload.md).

## 3. Reading and writing IG state

IG's Objective-C and Swift objects are frequently not KVC-compliant, and a `valueForKey:` throw
inside a swizzled method takes the app down. Two helpers wrap it:

```objc
id   ThetaValueForKey(id obj, NSString *key);          // nil instead of NSException
void ThetaSetValueForKey(id obj, id value, NSString *key);
```

Use them instead of raw KVC in hook code. Where the ivar is known and KVC is unreliable, the
codebase drops to the runtime API directly — `class_getInstanceVariable` +
`object_getIvar`/`object_setIvar` (e.g. `Source/Hooks/Messages/FullLastActive.m:23`,
`Source/Hooks/General/ExternalBrowser.m:63`), and in one case computes the ivar offset and writes
a `BOOL` through a raw pointer because the value isn't an object
(`Source/Hooks/Behavior/LiveBrowseTweaks.m:22`).

For calling methods that may not exist or whose signature is unusual, the tree uses
`objc_msgSend` with an explicit function-pointer cast, and `NSInvocation` where the return value
has to be fetched dynamically (`Source/Media/MediaSelectionViewController.m:2363`, calling
`+[FFmpegKit execute:]` from a `dlopen`ed framework).

## 4. Rules that come from real crashes

Each of these is documented in-tree next to the code that enforces it.

1. **Never use `class_replaceMethod`'s return value as `orig`.** It returns `NULL` when adding an
   override for an inherited method. Go through `ThetaInstallMessageHook`.
   (`Source/Runtime/THGlobalsAndHooking.m:136-146`)
2. **Wrap hook bodies in `@try/@catch`.** An `NSException` propagating out of a swizzled IG
   method kills the app. Nearly every hook in the tree does this.
3. **Null-check `orig` before calling it** when the hook was installed with a wrapper that can
   succeed without capturing one. `Source/Hooks/Behavior/DBB.m:96` refuses to install the
   `NSUserDefaults -objectForKey:` hook at all unless an `orig` was captured, because that method
   is on a hot path and a NULL call would be immediately fatal.
4. **Don't touch KVC paths you don't need.** `hook_savePost`
   (`Source/Hooks/Save/SavePosts.m:1003`) returns early unless `Save Media` or `Fullscreen Posts`
   is on, precisely because reading `_sendView` throws on many UFI layouts.
5. **Don't `setValue:forKey:` IG ivars to reorganize layout.** `SavePosts.m:1318` and
   `HideTabs.m:60` instead detach the whole `UIStackView` arranged-subview slot
   (`removeArrangedSubview:` + `removeFromSuperview`) so the space collapses instead of leaving a
   gap or crashing.
6. **Never rebind two aliases of one C symbol into the same `orig` pointer.** Rebinding both
   `strlen` and `_platform_strlen` into `original_strlen_fn` lets fishhook overwrite `orig` with
   the hook itself and recurse until the stack blows; `THSideloadFishhook.m:135` hooks one name
   only and additionally guards `fn != safe_strlen_impl`.
7. **Resolve real function pointers before rebinding.** After `rebind_symbols`, `dlsym` returns
   *our* hook, so `install_fishhook_rebindings()` captures `real_SecItem*` first
   (`THSideloadFishhook.m:190`).
8. **Guard re-entrancy when hooking Foundation.** The sideload `NSFileManager` container hook
   creates directories via the captured original IMP, never via `NSFileManager` APIs that would
   re-enter the hook (`Source/Hooks/Sideload/Sideload.m:40`).
9. **Idempotency for view injection.** Injected controls are tagged and checked for before being
   added again, since `layoutSubviews` runs constantly: numeric tags (`999` reel/post download
   button, `777` feed settings gear, `424242` profile save button,
   `0x54485345`/`0x54484C53` for the DM bar-button pair), associated objects as
   once-flags (`Source/Hooks/UI/SettingsButton.m:6`), or an owner-key cache
   (`StoryGhost.m:1089`).
10. **Only remove your own views.** `StoryGhost.m:1091` filters by Theta's own tag before
    removing subviews rather than stripping every `UIButton`.

## 5. Adding a feature

1. **Create `Source/Hooks/<Category>/MyFeature.m`.** No header, no imports needed for the
   standard helpers. Choose `static` names that are unique across the whole `Source/Hooks/` tree.

```objc
static void (*orig_myThing)(id self, SEL _cmd, id arg1);
static void hook_myThing(id self, SEL _cmd, id arg1) {
    if (orig_myThing) orig_myThing(self, _cmd, arg1);
    if (!ENABLED(@"My Feature")) return;
    @try {
        // ... work here; use ThetaValueForKey / ThetaSetValueForKey for IG state
    } @catch (NSException *e) {
        NSLog(@"[Theta] MyFeature: %@", e);
    }
}

void THRegisterMyFeatureHooks(void) {
    Class cls = ThetaFirstClass(@[ @"_TtC…SwiftName", @"IGObjCName" ]);
    NullHookMessageIfPresent(cls, @selector(myThing:), (void *)hook_myThing, &orig_myThing);
}
```

2. **Register it** in `InitializeHooks()` in `Source/Runtime/THTweak.m`. `assemble.py` picks the
   file up automatically, but nothing runs until it is called. If the hook needs a live view
   hierarchy or post-auth classes, put the call in the deferred `dispatch_async(main)` block
   instead (and consider whether you also need an imperative "apply now" pass, like
   `HideTabs.m`).

3. **Add the setting** to `self.settingsBySubMenu` in `Source/UI/SettingsViewController.m`
   (~line 155): pick the submenu, append
   `@{@"title": @"My Feature", @"detail": @"One-line description.", @"info": @"Longer help text."}`.
   Add `@"type"` for `segment` (+ `@"options"`), `color`, `view` (+ `@"viewController"`), or
   `action`.

4. **Gate the behavior** on `ENABLED(@"My Feature")` — string-identical to the title. For a
   segment, read `integerForKey:@"My Feature_SegmentIndex"`; for a color, unarchive
   `objectForKey:@"My Feature_Color"`.

5. **If the feature injects UI**, call `ThetaSetCaptureHiding(view)` so it honors
   "Hide Theta From Screenshots", tag it, and check for the tag before re-adding.

6. **If it is jailbreak-only**, wrap in `#ifdef SIDELOAD` … `#else` and provide an empty
   `THRegisterMyFeatureHooks(void) {}` in the other branch so `THTweak.m` still links. See
   `Source/Hooks/Sideload/HideTestFlightNag.m:60`.

7. **If it downloads media**, take the global mutex: `[ThetaHelper tryBeginGlobalDownloadOrNotify]`
   (shows a "Download in progress" toast and returns `NO` if busy) and pair every exit path with
   `[ThetaHelper endGlobalDownload]`.

## 6. Debugging on device

- Watch stderr/Console for `[Theta] miss:` lines ~1 s after launch — that is the first thing to
  check when a feature stops working after an IG update.
- `NSLog` output from hook bodies is redacted for `%@` in Console; use `%s` with `.UTF8String`
  (or `fprintf(stderr, …)`) when you need the value to be readable, as the launch diagnostics do.
- `Source/Hooks/UI/GIFNameOverlay.m` keeps `_retainedObjects` deliberately, retaining the last 10
  inspected objects so they can be examined in FLEX.
- `make install ROOTLESS=1` re-installs and relaunches Instagram
  (`after-install:: install.exec "uiopen --bundleid com.burbn.instagram"`); `THEOS_DEVICE_IP`
  must be set.
