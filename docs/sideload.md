# Sideload, jailbreak, and packaging

Sideloading re-signs Instagram with a different team ID. That breaks two things the app depends on
— its keychain access group and its app-group container — and removes the system Substrate. Most of
the sideload-specific code exists to paper over exactly those three problems.

## 1. Compile-time switches

| Macro | Set by | Effect |
| --- | --- | --- |
| `SIDELOAD=1` | `make … SIDELOAD=1` (via `Theta_CFLAGS`) | enables the shims below; weak-links `CydiaSubstrate`; disables codesign in the Theos step (`CODESIGN_IPA = 0`, empty `TARGET_CODESIGN`/`LDID_FLAGS`); sets `THETA_PROJECT` to `"theta Jailed v<ver>"` |
| `ROOTLESS=1` | `make … ROOTLESS=1` | `THEOS_PACKAGE_SCHEME = rootless`; `ROOT_PATH_NS()` prefixes `/var/jb` |
| — | default | rootful jailbreak; `-lsubstrate`; `THETA_PROJECT` = `"theta v<ver>"` |

The Makefile errors out if `SIDELOAD` and `ROOTLESS` are both `1`.

Guard jailed-only code with `#ifdef SIDELOAD` and **always provide the opposite branch's
`THRegister…Hooks()` as an empty function**, so `InitializeHooks()` still links. Canonical example,
`Source/Hooks/Sideload/HideTestFlightNag.m:60`:

```objc
#ifdef SIDELOAD
void THRegisterHideTestFlightNagHooks(void) { /* … */ }
#else
void THRegisterHideTestFlightNagHooks(void) { }
#endif
```

`Source/Hooks/Behavior/DismissIGDSPromoDialog.m` takes the other approach: the register function
always exists and its body is `#ifdef SIDELOAD`.

## 2. Keychain: fishhook rebinding of `SecItem*`

`Source/Runtime/THSideloadFishhook.m`, installed from the constructor *before anything else*
(`THTweak.m` → `install_fishhook_rebindings()`), rebinds five symbols through `fishhook.c`:
`strlen`, `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`.

The problem it solves: Instagram writes session tokens under Meta's team-prefixed access group. In
a re-signed app those writes fail. Earlier attempts to fake success left the next cold launch with
no session, so instead **the access group is rewritten** onto the sideload app's own group.

```objc
// discovered at runtime by adding/reading a dummy generic-password item
keychainAccessGroup  ← kSecAttrAccessGroup of our own item   (Sideload.m:1, loadKeychainAccessGroup)

SideloadSecItemDictCopy(dict, isQuery)                        (THSideloadFishhook.m:82)
  ├── skip if no kSecAttrAccessGroup, or it starts with "com.apple.", or it already equals ours
  ├── otherwise replace kSecAttrAccessGroup with keychainAccessGroup
  └── normalize kSecAttrSynchronizable: queries → kSecAttrSynchronizableAny, writes → false
```

Behavioral details that are easy to break:

- **`errSecDuplicateItem` from `SecItemAdd` is reported as success** — the item already being in
  the sideload keychain *is* persistence.
- A failing `SecItemAdd` prints `[Theta] SecItemAdd failed status=… (session may not persist)` to
  stderr, because that is the symptom users report as "logged out on every launch".
- The **non-sideload** build of the same file does the opposite: `hooked_SecItemCopyMatching`
  returns `errSecItemNotFound` for Meta-looking queries (`isMetaKeychainQuery`) — but
  `isDeviceOrSessionKeychainQuery` first exempts anything whose service/account contains
  `device`, `report`, `essential`, `session`, `identifier`, `login`, `password`, `credential`,
  `save`, `token`, `auth`, `user`. Blocking those leaves a nil session or crashes.
- `strlen` is wrapped only to guard `strlen(NULL)` inside
  `IGDeviceReportWithEssentialInfo` under sideload. Only **one** symbol name is rebound (never
  `strlen` *and* `_platform_strlen` into the same `orig`), and the wrapper additionally checks
  `fn != safe_strlen_impl` — otherwise fishhook can overwrite `orig` with the hook and recurse
  until the stack blows.
- Real implementations are resolved with `dlsym` **before** `rebind_symbols`, because afterwards
  `dlsym` returns our own hooks.

## 3. Keychain: Objective-C wrapper classes

`RunSideloadSetupOnce()` in `THTweak.m` additionally swizzles the access-group accessors of every
keychain wrapper Instagram/Meta ships (all with `NullHookMessageIfPresent`, since which exist
varies):

```
FBSDKKeychainStore            -accessGroup
FBKeychainItemController      -accessGroup
UICKeyChainStore              -accessGroup, +keyChainStoreWithService:accessGroup:
LSKeychainItemController      -initWithServiceID:accessGroup:userID:[isSynchronizable:]
                             -initSynchronizableItemWithServiceID:accessGroup:userID:
NSDictionary                 -queryWithAccessGroupKey:
FWAFBKeychainSecureStore     +keychainSecureStoreByInferringBundleIDWithAccessGroup:
IGCloudTrustTokenCloudStore  -initWithAccessGroup:
```

The `extern` declarations for these hook/orig pairs live in `Include.h` (they cross TU boundaries
between `Sideload.m` and `THTweak.m`).

## 4. App-group containers

`Source/Hooks/Sideload/Sideload.m` hooks
`NSFileManager -containerURLForSecurityApplicationGroupIdentifier:` and returns a path under
`<app home>/Documents/FakeGroupContainers/<groupIdentifier>`, pre-creating `Library`,
`Library/Caches`, and `Library/Preferences` inside it. `RunSideloadSetupOnce()` also pre-creates
`MobileConfig` and `FBMobileConfig` directories in Caches and Application Support.

The ordering constraint is explicit in `THTweak.m`: the `-createDirectoryAtPath:…` hook must be
installed **before** the `containerURL…` hook, because the container hook creates directories using
`orig_createDirectoryAtPath` — going through `NSFileManager`'s public API would re-enter Theta's
own hook.

## 5. Substrate

- **Jailbreak**: `Theta_LIBRARIES += substrate`; `/usr/lib/libsubstrate.dylib` is present.
- **Sideload**: `-weak_framework CydiaSubstrate` plus header search paths, and
  `build.sh stage_substrate_framework()` copies a `CydiaSubstrate.framework` into the `.app`.
  It looks in `$SUBSTRATE_FRAMEWORK_PATH`, then `third_party/CydiaSubstrate.framework`, then scans
  `~/Library/Application Support/Sideloadly`, `~/Downloads`, `~/Desktop`, and `packages/`, and
  finally runs `scripts/extract-substrate-from-deb.py` to pull it out of a `mobilesubstrate` `.deb`.
  It normalizes `CydiaSubstrate.dylib` → `CydiaSubstrate`, sets the install name to
  `@executable_path/CydiaSubstrate.framework/CydiaSubstrate`, and strips/ad-hoc-signs it.
- At runtime `ThetaSubstrateLoad()` (`Source/Runtime/THSubstrate.m`) dlopens the first of
  `/usr/lib/libsubstrate.dylib`, `@executable_path/CydiaSubstrate.framework/CydiaSubstrate`,
  `@executable_path/Frameworks/…`, or bare `CydiaSubstrate`, so the same code path works in both
  products. If none resolve, `ThetaMSHookFunction` no-ops. Under `SIDELOAD` the only caller is
  compiled out anyway (§9), so Substrate is effectively unused there — it is still staged and
  weak-linked so the dylib loads either way.

## 6. Other sideload-only differences

- **Photos import**: the AV1 camera-roll path uses the deprecated
  `ALAssetsLibrary -writeVideoAtPathToSavedPhotosAlbum:` with the file copied into the work
  directory, because plain file URLs don't work in the re-signed sandbox. See
  [media-pipeline.md](media-pipeline.md) §6.
- **FFmpeg lookup** searches the app bundle and `privateFrameworksPath` instead of
  `/Library/Application Support` (`MediaSelectionViewController.m:2323`,
  `AV1Transcoder.m:87`).
- **TestFlight nag** and the **IGDS promo dialog** are dismissed only under sideload.
- `#ifndef SIDELOAD` in `MediaSelectionViewController.m` uses `ROOT_PATH_NS()` for the jailbreak
  ffmpeg path; under sideload the bundle paths are used directly.

## 7. Rootless

Under `ROOTLESS=1`, absolute filesystem paths must be wrapped:

```objc
#import "Include/rootless.h"
NSString *p = ROOT_PATH_NS(@"/Library/Application Support/ffmpeg.framework");  // → /var/jb/...
```

`ROOT_PATH_NS` is a no-op when `ROOTLESS` is undefined, is idempotent (skips paths already starting
with `/var/jb`), and leaves relative paths alone. Currently only
`Source/Media/MediaSelectionViewController.m` uses it; other places hard-code both variants in a
candidate list (e.g. the `ThetaResources.bundle` lookup in `StoryGhost.m:951-954`, the FFmpeg framework
search in `AV1Transcoder.m:89`).

## 8. Packaging walkthrough (`./build.sh sideload`)

```
1. locate input/Payload/*.app and its CFBundleExecutable (PlistBuddy, with fallbacks)
2. make clean && make package SIDELOAD=1
3. find the built dylib in .theos/obj/Theta.dylib or the staged
   Library/MobileSubstrate/DynamicLibraries / usr/lib/TweakInject paths
4. compile tools/insert_dylib.c if needed
5. copy input/Payload → output/Payload
6. insert_dylib "@executable_path/Theta.dylib" <binary> --all-yes --inplace
   then remove signature + ad-hoc re-sign the binary
7. copy Theta.dylib into the .app; install_name_tool:
     -id @executable_path/Theta.dylib
     -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate → @executable_path/…
     -change @rpath/CydiaSubstrate.framework/CydiaSubstrate            → @executable_path/…
8. stage CydiaSubstrate.framework (see §5)
9. copy ThetaResources.bundle and, if present, ffmpeg.framework into the .app, then run
   scripts/isolate-ffmpeg-dylibs.py over the staged ffmpeg.framework so its install names
   can't collide with Instagram's own bundled FFmpeg (see media-pipeline.md §4)
10. delete .DS_Store, xattr -rc, zip -9 -r output/Instagram_patched.ipa Payload
```

The resulting IPA still needs signing by Sideloadly / AltStore / SideStore, or installing with
TrollStore.

Jailbreak packaging is just `make package [ROOTLESS=1]` → `packages/*.deb`, with
`Theta.plist` (`{ Filter = { Bundles = ( "com.burbn.instagram" ); }; }`) restricting injection to
Instagram, and `control` declaring `Depends: mobilesubstrate`.

## 9. Known-broken on sideload

The Navigation features — Tab Icon Order, Swipe Between Tabs, Launch Tab, Hide Feed/Explore/Reels/
Messages Tab, and Messenger Mode — do not work in sideload builds.

**Liquid Glass's C-symbol overrides are jailbreak-only, and must stay that way.** Substrate patches
a function by making its page writable and writing a branch into it. In a re-signed app that page
is left `rw-` and no longer matches the code signature, so the first call into it is killed by the
kernel: `EXC_BAD_ACCESS` / `KERN_PROTECTION_FAILURE`, termination namespace `CODESIGNING`,
indicator `Invalid Page`. Observed on IG 441.0.0 / iOS 26.6 as a 100% launch crash inside
`FBSharedFramework`'s `__TEXT` at `IGFloatingTabBarEnabled`, reached from
`METARunPreApplicationMain`. `theta_tryInstallLiquidGlassTabBarCSymbolHooks()` is therefore
compiled out under `SIDELOAD`; the ObjC swizzles in the same feature are safe because they only
rewrite runtime dispatch tables. Any future `ThetaMSHookFunction` call site needs the same guard.

Everything else is expected to work in both products. This is documented in the README's issue table and is the first thing to
check before debugging a tab-related report.
