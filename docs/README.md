# Theta — internals documentation

Theta is an Instagram tweak: Objective-C, built with Theos, running inside `com.burbn.instagram`
(version **441.0.0**) either as a Substrate tweak on a jailbroken device or as a dylib injected
into a decrypted IPA for sideloading.

This directory documents how it actually works — the build's code-generation step, the hook
installation machinery, every feature and the IG class it attaches to, the media-save pipeline,
the follower-analytics subsystem, the settings UI, and the sideload shims.

| Document | What it covers |
| --- | --- |
| [architecture.md](architecture.md) | Build pipeline, the single-TU amalgamation, load/lifecycle order, hook diagnostics |
| [hooking.md](hooking.md) | The hook toolkit (`NullHookMessage*`, `ThetaHookFirst`, `ThetaMSHookFunction`), pitfalls, how to add a feature |
| [features.md](features.md) | Every feature: what it hooks and how it works, grouped by category |
| [settings-reference.md](settings-reference.md) | Every setting: submenu, type, `NSUserDefaults` key, implementing file |
| [media-pipeline.md](media-pipeline.md) | Download/save: DASH parsing, quality menu, AVFoundation merge, AV1/FFmpeg, Photos import |
| [profile-analyzer.md](profile-analyzer.md) | Follower/following scanning, IG-networker reuse, pacing/backoff, SQLite storage, diffing |
| [ui-layer.md](ui-layer.md) | Settings VC, submenus, preference storage formats, import/export, toasts, aux view controllers |
| [sideload.md](sideload.md) | `SIDELOAD` vs jailbreak, fishhook keychain rebinding, app-group faking, packaging, rootless |

## Orientation in 60 seconds

- **Entry point** — `Source/Runtime/THTweak.m`. A `__attribute__((constructor))` runs at load,
  installs a couple of early hooks, then waits for the app to become active and calls
  `InitializeHooks()` once, which calls ~55 `THRegister…Hooks()` functions.
- **One feature per file** under `Source/Hooks/<Category>/`, each exporting one
  `THRegister…Hooks()`. Everything in that tree is concatenated by `scripts/assemble.py` into a
  single generated translation unit (`TweakCOMPILE.xm`) at build time.
- **All hooking is manual swizzling.** There are no Logos `%hook` blocks; the only Logos syntax
  used is `%c(Class)`. Original implementations are held in file-static `orig_*` function
  pointers.
- **Every IG symbol is resolved by name at runtime**, usually with several candidate names
  (including Swift-mangled ones). A renamed IG class produces a logged "miss", not a crash and
  not a build failure.
- **Settings are `NSUserDefaults` keyed off the human-readable setting title** — the string in
  `Source/UI/SettingsViewController.m` and the string in `ENABLED(...)` must match exactly.
- **Builds need macOS + Theos + a patched iOS 14.5 SDK.** They cannot run in a Linux container;
  verification is manual, on device.

## Caveats about this documentation

Line references were accurate at the time of writing and are given as
`path:line` so they can be re-checked. Everything here was derived from the source in this
repository, not from external documentation of Instagram internals; the IG class and selector
names are those the code tries to resolve, and they can disappear with any Instagram release.
