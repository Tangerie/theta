# Media pipeline: downloading and saving

Everything Theta saves goes through one of two paths: a **direct URL download** (photos, audio,
profile pictures) or the **DASH reel path** (separate video and audio representations that must be
fetched and muxed). The reel path is the complicated one.

## 1. Concurrency and cleanup invariants

A single global mutex serializes all saves (`Source/UI/ThetaHelper.m:198`):

```objc
[ThetaHelper tryBeginGlobalDownloadOrNotify]  // NO + "Download in progress" toast if busy
[ThetaHelper endGlobalDownload]
[ThetaHelper isGlobalDownloadInProgress]
```

It is a `@synchronized`-guarded `BOOL`, not a queue — a second save is refused, not queued.
`theta_tryBeginSaveJob()` (`Source/Hooks/Save/SavePosts.m:77`) bounces the acquisition to the main
thread with `dispatch_sync` when needed, because acquiring it shows UI. Some call sites check
`isGlobalDownloadInProgress` *before* showing their own "Saving media…" toast purely to avoid a
visual flash (`SavePosts.m:800`).

Every reel job gets a UUID work directory under `NSTemporaryDirectory()`
(`theta-save-<uuid>`, `SavePosts.m:71`) and a `finishJob` block that removes the directory and
releases the mutex exactly once (`__block BOOL jobFinished` guard). Two sweepers exist for
crash-leftovers:

- `theta_sweepStaleReelSaveFiles()` (`SavePosts.m:46`) runs at the start of each job and deletes
  fixed names (`video.mp4`, `audio.m4a`, `audio.aac`, `audio_lc.m4a`, `output.mp4`,
  `output_h264.mp4`) and any `theta_save_*` / `theta-save*` / `theta_bulk_*` entries from
  Documents, Caches, and tmp.
- `[ThetaHelper cleanupTemporaryMediaFiles]` (`ThetaHelper.m:170`) runs once at load: same sweep,
  plus removal of stray `.mp4`/`.aac`/`.m4a` files directly in `Documents` — **except** files
  named `Video-*`, which are the user's deliberately saved output.

Destinations, chosen by the `Save Method` segment:

| Index | Destination |
| --- | --- |
| 0 | Camera roll (Photos) |
| 1 | `Documents/AudioNotes/` — filename `Video-yyyyMMdd-HHmmss.mp4` for videos |

`Documents/AudioNotes` doubles as the "local folder" for audio notes, audio messages, and videos;
`AudioNotesViewController` browses it.

## 2. DASH manifest parsing

`Source/Media/ThetaDashManifest.m` parses the XML in `IGVideo.dashManifestData` with
`NSRegularExpression` and range searches — no XML parser. Exported API
(`Include/ThetaDashManifest.h`):

```objc
NSTimeInterval ThetaDashManifestDuration(NSString *manifest);
NSArray<ThetaDashVideoQuality *> *ThetaDashManifestVideoQualities(NSString *manifest,
                                                                 NSTimeInterval fallbackDuration);
NSString *IGDashManifestBestQualityURL(NSString *manifest);     // highest FBQualityLabel / bandwidth
NSString *IGDashManifestBestCompatibleURL(NSString *manifest);  // highest avc1/hvc1/hev1
NSString *IGDashManifestBestAudioURL(NSString *manifest);       // best-scoring audio codec
NSString *ThetaPrepareDashAudioForMerge(NSString *audioPath);
BOOL ThetaExportPhotosCompatibleMP4(NSString *videoPath, NSString *audioPath,
                                    BOOL hasAudio, NSString *outputPath);
void ThetaPhotoLibraryImportVideoFromURL(NSURL *fileURL,
                                         void (^completion)(BOOL, NSError *));
```

Details that matter:

- **Video selection.** `IGDashManifestBestCompatibleURL` (`:353`) locates the video
  `AdaptationSet` (six spelling variants tried), then matches `<Representation …>` tags with two
  regexes (codecs-before-quality and quality-before-codecs) and keeps the highest `FBQualityLabel`
  whose codec starts with `avc1`, `hvc1`, or `hev1`. Only if no compatible representation exists
  does it fall back to `IGDashManifestBestQualityURL`, which may return AV1 and therefore trigger
  transcoding later. `<BaseURL>` is read from the range following the winning tag, with `&amp;`
  unescaped.
- **Audio selection.** `IGDashManifestBestAudioURL` (`:452`) scores audio codecs by how well
  AVFoundation handles them: AAC-LC 400, HE-AAC 300, HE-AACv2 250, generic `mp4a` 200, Opus 80,
  `ac-3`/`ec-3` 60, and **xHE-AAC/USAC only 20** — this is why some IG audio can't be muxed
  natively. Ties break on bandwidth.
- **Quality list for the menu.** `ThetaDashManifestVideoQualities` (`:159`) produces
  `ThetaDashVideoQuality` objects carrying url, label, codecs, human codec name, width/height,
  quality (`…p`), bandwidth, frame rate, duration, and an **estimated output size**
  (`ThetaDashEstimateConvertedBytes`, `:117`) so the menu can show "1080p · H.264 · ~24.3 MB".
  Codec sort rank keeps compatible codecs above AV1.
- **Fragmented input needs precise timing.** Every asset read from a downloaded file is created as
  `AVURLAsset` with `AVURLAssetPreferPreciseDurationAndTimingKey: @YES`. IG serves fragmented MP4
  (`ftyp` compatible brands include `dash`/`cmfc`), where the `moov` is an init segment: `mvhd`,
  `tkhd` and `mdhd` durations are all **0** and the sample tables are empty, with the real duration
  only derivable from `sidx`/`moof`. Without the option `AVAsset.duration` comes back as zero while
  the tracks still load, which is what fed an invalid `CMTimeRange` into `insertTimeRange:`.
- **Audio fix-up before muxing.** `ThetaPrepareDashAudioForMerge` (`:586`) first tries renaming by
  magic bytes (`ThetaRenameAudioByMagic`) so AVFoundation recognizes the container, then attempts
  an AAC re-export (`ThetaTranscodeAudioToM4A`), and returns `nil` if no decodable audio track can
  be produced — the caller then continues video-only rather than failing the save.

## 3. Reel save flow (`downloadHDVideoSelectingURL`)

`Source/Hooks/Save/SavePosts.m:109`. The single most involved function in the tree; roughly:

```
0.  read IGVideo.dashManifestData → bail out silently if absent
1.  acquire the global download mutex, show a CustomToastView progress toast
2.  on a high-priority global queue:
      pick video URL  = explicit menu selection ?: IGDashManifestBestCompatibleURL()
      pick audio URL  = IGDashManifestBestAudioURL()
3.  sweep stale files, create theta-save-<uuid> work dir
4.  two NSURLSessionDownloadTasks (video → video.mp4, audio → audio.m4a) in a dispatch_group;
    dispatch_group_wait(FOREVER) on the background queue; each temp file moved with
    theta_moveReplace() (move, else copy+delete)
5.  verify video exists and is non-empty; run ThetaPrepareDashAudioForMerge on the audio,
    and drop to video-only if it returns nil
6.  probe the video codec via AVAsset formatDescriptions (loadValuesAsynchronouslyForKeys with a
    20 s semaphore wait)
        ├── codec == 'av01'  → FFmpeg branch (§4), then save, then RETURN
        └── otherwise        → AVMutableComposition branch (§5)
```

Both branches converge on the same "save and toast" logic, duplicated per branch, with
`finishJob()` on every exit path.

### 4. AV1 branch

AV1 is detected as the FourCC `0x61763031`. AVFoundation on the target OS won't compose it and
Photos may reject it, so:

1. `[AV1Transcoder transcodeAV1ToH264:outputPath:audioPath:error:progressBlock:]` — decodes AV1 and
   re-encodes H.264, muxing the separate audio file if present, reporting progress into the toast.
2. If FFmpeg is unavailable or fails, fall back to `ThetaExportPhotosCompatibleMP4()` (pure
   AVFoundation re-export).
3. If that also fails, **the save fails** with "Couldn't convert video". It deliberately does *not*
   fall back to saving the raw download: IG's `<BaseURL>` is a fragmented DASH/CMAF segment whose
   `moov` advertises duration 0 with no sample tables, and whose audio is a separate representation
   that was never muxed in. Photos rejects such a file, and in folder mode it used to land in
   `Documents/AudioNotes` as a "saved" video that nothing could play. The bulk path in
   `MediaSelectionViewController.m` marks the item "Transcoding failed" for the same reason.

`Source/Media/AV1Transcoder.m` loads FFmpeg lazily with `dlopen` and resolves ~40 symbols with
`dlsym` through `FUNC_PTR`/`LOAD_FUNC` macros. Search order for the framework:

```
<main bundle>/ffmpeg.framework
<main bundle>/Frameworks/ffmpeg.framework
/var/jb/Library/Application Support/ffmpeg.framework
/Library/Application Support/ffmpeg.framework
```

Within each of those, `dylibs/<lib>` is tried first, then `<lib>.framework/<lib>`, then `<lib>`;
`libavutil`, `libswresample`, `libswscale`, `libavcodec`, `libavformat` are dlopened individually
in that (dependency) order with `RTLD_LOCAL`. FFmpeg headers are provided at compile time by
`-I"$(THEOS_PROJECT_DIR)/layout/Library/Application Support/ffmpeg.framework"` — headers only, no
link dependency. **FFmpeg must stay optional**: every call site has an AVFoundation fallback.

#### Install-name isolation (do not remove)

**Instagram ships its own stripped FFmpeg** — a ~530 KB `libavcodec` and a ~96 KB `libavutil` in
`Instagram.app/Frameworks/`, loaded at launch. Their install names are byte-for-byte the ones our
vendored FFmpeg uses (`@rpath/libavcodec.framework/libavcodec`, …), and **neither set carries an
`LC_RPATH`**, so `@rpath` only ever expands through the app's own `@executable_path/Frameworks`.
Consequences, all confirmed from a device crash report's image list:

- our `libavformat` binds to Instagram's stripped `libavcodec`/`libavutil` instead of ours;
- `libswresample`, which Instagram doesn't ship, can't be found at all, so the `dlopen` fails;
- `AV1Transcoder` reports "ffmpeg didn't load", every AV1 reel falls through to the AVFoundation
  fallback, and (before this was understood) the raw DASH segment got saved as an unplayable file.

`scripts/isolate-ffmpeg-dylibs.py` fixes this at build time: it moves each dylib to
`<ffmpeg.framework>/dylibs/<name>` and rewrites its own install name and its sibling dependencies
to `@loader_path/<name>`. Those strings are shorter than the `@rpath/…` ones they replace, so they
patch in place with no load-command resizing, and they can never match Instagram's copies in either
direction. It runs from `build.sh` (sideload staging) and from the Makefile's `after-stage::` hook
(`.deb` staging); it is idempotent and must only ever run against a *staged* copy, never against
`layout/` in the repo.

**Never "fix" this by deleting `Instagram.app/Frameworks/libav*.framework` — those are Instagram's
own libraries.**

Separately, `MediaSelectionViewController -convertFileToMP3:` (`:2298`) uses the higher-level
`FFmpegKit` ObjC class from the same framework via `dlopen` + `NSInvocation`, running
`-y -hide_banner -loglevel error -i <in> -vn -map a -c:a libmp3lame -q:a 0 <out>` on a serial
queue, and treats a non-empty output file as success even if the session return code isn't flagged
successful.

### 5. AVFoundation composition branch

Builds an `AVMutableComposition`, inserts the video track and (if usable) the audio track over
`CMTimeMinimum(videoDuration, audioDuration)` so a longer audio stream can't stretch the result,
then exports with `AVAssetExportPresetHighestQuality` to `AVFileTypeMPEG4` with
`shouldOptimizeForNetworkUse = YES` (Photos-friendly `moov` placement). After export it re-probes
the output: if the composed file is *still* AV1 it runs the FFmpeg branch on it, and it logs a
warning when audio was expected but no audio track survived (the usual cause being xHE-AAC).

### 6. Getting the file into Photos

`ThetaPhotoLibraryImportVideoFromURL` (`ThetaDashManifest.m:697`) is the normal path
(`PHAssetCreationRequest`), and `PHPhotoLibrary` authorization is requested when
`PHAuthorizationStatusNotDetermined`.

The AV1 camera-roll path has a **sideload-specific** variant (`SavePosts.m`, `#ifdef SIDELOAD`):
the file is copied into the work dir as `import.mp4` and imported with the deprecated
`ALAssetsLibrary -writeVideoAtPathToSavedPhotosAlbum:`, because file URLs from the normal location
don't work under the re-signed sandbox. On failure it deliberately does **not** clean up, so the
file can be inspected.

## 7. Multi-item and bulk saves

`downloadMedia()` (`SavePosts.m:772`, feed posts) and `downloadSundialMedia()` (`:1100`, reels)
walk `IGMedia.items`, splitting into photo URLs (from
`IGPhoto._originalImageVersions.lastObject.url`) and `IGVideo`s, handling both `itemMediaType` and
`mediaType` selector spellings because IG has both. Then:

- **1 item** — save directly (`downloadHDVideo` for video, `downloadMediaToTemp:` for a photo).
- **>1 item** — `[MediaSelectionViewController preloadHDVideoThumbnails:completion:]`, then present
  `MediaSelectionViewController` in a `UINavigationController`: a selectable grid with previews
  (`NSCache`-backed, prefetching via `UICollectionViewDataSourcePrefetching`), "select all", and a
  bulk download that drives per-item progress bars in the toast
  (`setupPerItemProgressWithCount:` / `updatePerItemProgressAtIndex:title:progress:`).

Thread-safety in these functions is explicit: results are accumulated under a serial
`dispatch_queue` (`com.theta.mediaSync`) and copied before use on the main queue.

## 8. Per-quality download menu

For reels, the download button's menu is built lazily with `UIDeferredMenuElement`
(`SavePosts.m:1595`) so the manifest is parsed only when the menu opens:

- exactly one video in the media → parse the manifest and list every quality, with a subtitle
  (set through the private `subtitle` KVC key on `UIAction`, falling back to appending to the
  title if that throws), and codec shown in the title only when two representations share the
  same `…p` label;
- no manifest or no qualities → a single "Download" action;
- multiple videos → a single "Download" action that routes to the selection UI.

Picking an entry calls `downloadHDVideoSelectingURL(video, url)` with that exact representation
URL, bypassing the compatible-codec preference — so choosing an AV1 entry deliberately opts into
the transcode path.

## 9. Fullscreen viewing

`Fullscreen Posts` / `Fullscreen Profile Pictures` resolve the item's URL and present
`MediaViewController` (`Source/Media/MediaViewController.m`) full screen — a zoomable
`UIScrollView` + `UIImageView` for photos and an `AVPlayerViewController` for videos.

## 10. Progress UI

`Source/UI/CustomToastView.m` is the only progress surface. `showProgressToastWithTitle:subtitle:`
returns a persistent toast (`isProgressType = YES`) that is updated in place with
`updateProgressWithTitle:subtitle:[icon:|progress:]` and closed with
`completeProgressWithTitle:subtitle:icon:url:`. It supports a single overall `UIProgressView` or a
stack of per-item bars, recalculates its own width, pauses auto-hide while the user is holding it,
and can carry a tap URL — save completions pass `photos-redirect://` so tapping the toast opens
Photos. `Hooks/Behavior/ToastDismiss.m` keeps IG's own toast chrome from fighting with it.
