# Theta

DRM-free, non-obfuscated rebuild of Theta.

## Layout

```
Source/
  Runtime/          Hook helpers, Substrate loader, sideload shims, entrypoint
  Hooks/
    Behavior/       Ads, stories, confirmations, privacy, live, …
    General/        Date format, external browser, liquid glass
    Media/          Reel tap controls
    Messages/       DM features
    Save/           Media / profile / audio saves
    UI/             Tabs, navigation, settings entry points
    Sideload/       Keychain / app-group fakes
  UI/               Settings, toasts, helpers, lock screen
  Media/            Download UI, AV1 transcoder, DASH
  ProfileAnalyzer/  Follower analytics
Include/            Public headers
scripts/assemble.py Builds TweakCOMPILE.xm (single TU for static hooks)
```

## Build

Requires [Theos](https://theos.dev). Prefer `./build.sh`:

```sh
./build.sh              # rootful .deb → packages/
./build.sh rootless     # rootless .deb → packages/
./build.sh sideload     # inject into input/Payload → output/Instagram_patched.ipa
```

### Sideload

1. Unpack a decrypted Instagram IPA so you have `input/Payload/Instagram.app/…`
2. Run `./build.sh sideload`
3. Sideload `output/Instagram_patched.ipa`

FFmpeg frameworks are expected under:

`layout/Library/Application Support/ffmpeg.framework`
