# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Theta is an Instagram tweak (Objective-C, Theos) that runs inside `com.burbn.instagram` in two very different modes:

- **Jailbreak** — Substrate tweak `.deb` (rootful or rootless), loaded via `Theta.plist` bundle filter.
- **Sideload** — `Theta.dylib` injected into a decrypted Instagram binary, with Substrate bundled inside the IPA.

Targets Instagram **441.0.0**; hooks resolve IG classes/selectors by name at runtime, so version drift shows up as "hook install misses" rather than build failures.

In-depth documentation lives in `docs/` — [architecture](docs/architecture.md) (build, TU amalgamation, lifecycle), [hooking](docs/hooking.md) (helpers, pitfalls, adding a feature), [features](docs/features.md) (what each hook attaches to), [settings-reference](docs/settings-reference.md), [media-pipeline](docs/media-pipeline.md), [profile-analyzer](docs/profile-analyzer.md), [ui-layer](docs/ui-layer.md), [sideload](docs/sideload.md).

## Build

Builds require macOS + Xcode CLI tools + Theos (`build.sh` uses `codesign`, `PlistBuddy`, `install_name_tool`, `xattr`). **They cannot run in a Linux container** — expect to make changes by reading code, not by compiling.

```sh
./build.sh              # rootful .deb  → packages/
./build.sh rootless     # rootless .deb → packages/
./build.sh sideload     # inject into input/Payload → output/Instagram_patched.ipa
make package [ROOTLESS=1|SIDELOAD=1]   # equivalent
make install [ROOTLESS=1]              # needs THEOS_DEVICE_IP; reopens Instagram after
```

`SIDELOAD` and `ROOTLESS` are mutually exclusive (the Makefile errors out). Requires the patched `iPhoneOS14.5.sdk` from `sdks/` unpacked into `$THEOS/sdks` (see README) — a stock Xcode SDK will not work.

There are no tests or linters. Verification is manual on-device.

CI (`.github/workflows/build-sideload-dylib.yml`) builds `Theta.dylib` with `SIDELOAD=1` on a `macos-14` runner, uploads it as an artifact, and publishes a GitHub release tagged `v<control version>-<short sha>`. It runs on pushes to `main` only (plus manual `workflow_dispatch`), so branches get no CI. It stops before IPA injection, which needs a decrypted Instagram binary that can't be in the repo.

## Compilation model (read before adding files)

`scripts/assemble.py` concatenates sources into a single generated TU, `TweakCOMPILE.xm`, on every build (`before-all::`), and deletes it after (`after-all::`). It is gitignored — **never edit `TweakCOMPILE.xm`; edit the sources it concatenates.**

Concatenation order:

1. `Source/Runtime/THGlobalsAndHooking.m` — globals + swizzle helpers
2. `Source/Runtime/THNativeToast.m`, `THSideloadFishhook.m`, `THSubstrate.m`
3. `Source/Hooks/**/*.m` — `UI/GIFNameOverlay.m` first, then `os.walk` order with filenames sorted
4. `Source/Runtime/THTweak.m` — entry point, last

Consequences:

- Everything under `Source/Hooks/` shares one TU, so hook functions and `orig_*` pointers stay `static` and file-local without name collisions — but **`static` names must be unique across all hook files**. Only the `THRegister…Hooks()` functions are non-static.
- Hook files see the helpers from `THGlobalsAndHooking.m` (`ENABLED`, `NullHookMessageEx`, `NullHookMessageIfPresent`, `ThetaFirstClass`, `ThetaHookFirst`, `ThetaValueForKey`, …) with no imports. Hook files generally import nothing at all.
- `Source/UI/`, `Source/Media/`, `Source/ProfileAnalyzer/` are compiled as **separate TUs** via Makefile wildcards, so they must `#import` their own headers from `Include/` and cannot use those static helpers.
- The output is `.xm`, so Logos syntax works — but the codebase only uses `%c(Class)`. There are no `%hook`/`%orig` blocks; all hooking is manual swizzling.

## Adding a feature

1. Create `Source/Hooks/<Category>/MyFeature.m` with file-static `orig_*` pointers, `hook_*` replacements, and one exported `void THRegisterMyFeatureHooks(void)`. `assemble.py` picks up the file automatically.
2. Register it in `InitializeHooks()` in `Source/Runtime/THTweak.m` — nothing runs otherwise. Hooks needing a live view hierarchy go in the deferred `dispatch_async` block there.
3. Add the toggle to `self.settingsBySubMenu` in `Source/UI/SettingsViewController.m` (submenu → array of `@{@"title", @"detail", optional @"info", optional @"type"}`).
4. Gate behavior on `ENABLED(@"Exact Setting Title")`.

### Settings/preferences convention

Preferences are plain `NSUserDefaults` keyed off the **setting title string**, with no separate constants — the title in `SettingsViewController.m` and the string in `ENABLED(...)` must match exactly:

| `type` | Storage key | Read as |
| --- | --- | --- |
| (default switch) | `<Title>_Enabled` | `ENABLED(@"<Title>")` |
| `segment` (+ `options`) | `<Title>_SegmentIndex` | `integerForKey:` |
| `color` | `<Title>_Color` (`NSKeyedArchiver`-archived `UIColor`) | `[NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:… error:nil]` |
| `view` (+ `viewController`) | n/a — pushes a VC | — |

### Hooking rules

- Use `NullHookMessageEx` (records a miss if the class/selector is absent) or `NullHookMessageIfPresent` (silent — for classes that legitimately vary by IG version or only exist under sideload). Misses are collected and printed to stderr ~1s after launch as `[Theta] miss: …`.
- **Never use `class_replaceMethod`'s return value as `orig`** — it returns NULL when adding an override for an inherited method, which crashes on first call. `ThetaInstallMessageHook` in `THGlobalsAndHooking.m` handles this; go through the wrappers.
- Prefer `ThetaFirstClass(@[...])` / `ThetaHookFirst(...)` with several candidate class/selector names (including Swift-mangled names like `_TtC29IGCoreRootTestFlightNagPlugin35…`) so a renamed IG symbol degrades instead of breaking.
- Wrap hook bodies in `@try/@catch`; a throw inside a swizzled IG method takes down the app.
- Use `ThetaValueForKey` / `ThetaSetValueForKey` instead of raw KVC — IG/Swift ivars are frequently not KVC-compliant.
- C-symbol / inline hooking goes through `ThetaMSHookFunction` and `ThetaResolveInstagramExecutableSymbol` (`Include/ThetaSubstrate.h`), which dlopen Substrate at several paths so the same code works jailed and jailbroken.
- IG class/method declarations belong in `Include/InstagramHeaders.h`.

## Sideload vs jailbreak

Guard jailed-only code with `#ifdef SIDELOAD` (set by `Theta_CFLAGS`); provide an empty `THRegister…Hooks()` in the `#else` branch so `THTweak.m` still links (see `Hooks/Sideload/HideTestFlightNag.m`).

Sideload requires extra shimming because the app is re-signed under a different team ID:

- `Source/Runtime/THSideloadFishhook.m` rebinds `SecItem*` (and `strlen`) via `fishhook.c` to rewrite Meta's keychain access group onto the sideload group. Device/session/login queries are deliberately passed through — faking them leaves a nil session or crashes. Real function pointers are resolved *before* rebinding (post-rebind `dlsym` returns our own hook).
- `Source/Hooks/Sideload/Sideload.m` fakes app-group containers under `Documents/FakeGroupContainers` and swizzles the keychain `accessGroup` accessors listed in `Include.h`.
- Substrate is weak-linked; `build.sh` stages `CydiaSubstrate.framework` into the app and rewrites install names to `@executable_path/…`.
- Under `ROOTLESS=1`, wrap absolute filesystem paths in `ROOT_PATH_NS()` (`Include/rootless.h`) to prefix `/var/jb`.

Known broken on sideload only: the Navigation features (tab order, swipe between tabs, launch tab, hide tabs, Messenger mode).

## Subsystems

- **`Source/Runtime/`** — `THTweak.m` is the `__attribute__((constructor))` entry point: installs early hooks, waits for `UIApplicationDidFinishLaunching`/`DidBecomeActive`, then runs `InitializeHooks()` once on the main thread (it retries while backgrounded).
- **`Source/UI/`** — `SettingsViewController` (~2k lines: submenu list, search, QR, color/segment cells), `SubMenuViewController`, `ThetaHelper` (toasts, haptics, top-VC lookup, temp-file cleanup, global download mutex via `tryBeginGlobalDownloadOrNotify`/`endGlobalDownload`), `SecurityViewController` (app lock).
- **`Source/Media/`** — download/selection UI, `ThetaDashManifest` (DASH parsing), `AV1Transcoder`. FFmpeg is `dlopen`ed at runtime from `layout/Library/Application Support/ffmpeg.framework` (headers come in via `-I` only); reel saving falls back to AVFoundation when it is absent, so never make FFmpeg a hard dependency.
- **`Source/ProfileAnalyzer/`** — follower/following diffing. Talks to `https://i.instagram.com/api/v1/` (`THProfileAnalyzerAPIClient`), stores snapshots locally in `Stats.sqlite` via raw `sqlite3` (`THProfileAnalyzerStorage`, linked with `-lsqlite3`), diffs in `THProfileAnalyzerDiffEngine`. Requests are deliberately paced to avoid IG throttling.
- **`Source/Hooks/`** — one feature per file, grouped `Behavior/ General/ Media/ Messages/ Save/ UI/ Sideload/`. Cross-file coupling is explicit and rare (e.g. `HideAds.m` chains `ThetaApplyHideFeedFiltering` declared in `Include/ThetaTweakCommon.h`).

## Conventions

- ARC is on (`-fobjc-arc`); many warning classes are suppressed in `Theta_CFLAGS`, so the compiler will not catch nullability or pointer-type mistakes for you.
- `Theta` / `TH` prefixes for globals and exported functions; `IOTA_PINK` / `[ThetaHelper iotaPinkColor]` is the accent color.
- Version strings come from macros `THETA_VERSION` and `THETA_PROJECT`, derived from `control`'s `Version:`.
- Image assets live in `ThetaResources.bundle`, looked up across main-bundle and `/Library/Application Support` (and `/var/jb/...`) paths.
