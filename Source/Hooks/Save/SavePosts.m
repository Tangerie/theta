#import "Include/CustomToastView.h"
#import "Include/MediaSelectionViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "Include/ThetaHelper.h"
#import "Include/AV1Transcoder.h"
#import <Photos/Photos.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "Include/ThetaDashManifest.h"

// Helper functions for cleaner code
static void cleanupTemporaryFiles(NSString *videoPath, NSString *audioPath, NSString *outputPath) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSArray *paths = @[videoPath, audioPath, outputPath];
    NSArray *names = @[@"video file", @"audio file", @"output file"];
    
    for (int i = 0; i < paths.count; i++) {
        NSError *error;
        if ([fileManager removeItemAtPath:paths[i] error:&error]) {
            // do nothing
        }
    }
}

static void showCompletionToast(CustomToastView *progressToast, BOOL success, NSString *title, NSString *subtitle, UIImage *icon, NSURL *url) {
    if (progressToast) {
        [progressToast completeProgressWithTitle:title subtitle:subtitle icon:icon url:url];
        if (success) {
            // Haptic feedback for success
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [generator impactOccurred];
        }
    } else {
        [ThetaHelper showToastWithTitle:title subtitle:subtitle icon:icon autoHide:4 openURL:url];
    }
}

static void downloadHDVideo(IGVideo *inputVideo) {
    NSData *videoData = [inputVideo valueForKey:@"dashManifestData"];
    if (!videoData) {
        return;
    }
    
    // Show initial progress toast
    CustomToastView *progressToast = [CustomToastView showProgressToastWithTitle:@"Saving video" subtitle:@"Preparing..."];
    
    // Run everything on a background queue to avoid blocking UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *videoManifest = [[NSString alloc] initWithData:videoData encoding:NSUTF8StringEncoding];
        NSString *videoURLString = IGDashManifestBestCompatibleURL(videoManifest);
        NSString *audioURLString = IGDashManifestBestAudioURL(videoManifest);
        
        if (!videoURLString.length || ![NSURL URLWithString:videoURLString]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showCompletionToast(progressToast, NO, @"Error", @"Could not parse video URLs from manifest", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
            });
            return;
        }
        
        // Check if audio is available (ensure URL is valid)
        NSURL *audioTestURL = audioURLString.length > 0 ? [NSURL URLWithString:audioURLString] : nil;
        BOOL hasAudio = (audioURLString != nil && audioURLString.length > 0 && audioTestURL != nil);

        NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *videoPath = [documentsPath stringByAppendingPathComponent:@"video.mp4"];
        NSString *audioPath = [documentsPath stringByAppendingPathComponent:@"audio.aac"];
        // Ensure any previous temp files are removed before starting
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *preOutputPath = [documentsPath stringByAppendingPathComponent:@"output.mp4"];
        for (NSString *path in @[videoPath, audioPath, preOutputPath]) {
            if ([fm fileExistsAtPath:path]) {
                [fm removeItemAtPath:path error:nil];
            }
        }

    // Create dispatch group to wait for downloads
    dispatch_group_t downloadGroup = dispatch_group_create();
    
    // download video and audio to their respective paths
    NSURLSession *session = [NSURLSession sharedSession];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [progressToast updateProgressWithTitle:@"Downloading video" subtitle:@"Fetching video stream..."];
    });
    
    dispatch_group_enter(downloadGroup);
    NSURLSessionDownloadTask *videoTask = [session downloadTaskWithURL:[NSURL URLWithString:videoURLString] completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            NSLog(@"Error downloading video: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [progressToast completeProgressWithTitle:@"Error" subtitle:@"Failed to download video" icon:nil url:nil];
            });
        } else if (location) {
            [fm moveItemAtPath:location.path toPath:videoPath error:nil];
        }
        dispatch_group_leave(downloadGroup);
    }];
    [videoTask resume];
    
    if (hasAudio) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [progressToast updateProgressWithTitle:@"Downloading audio" subtitle:@"Fetching audio stream..."];
        });
        
        dispatch_group_enter(downloadGroup);
        NSURLSessionDownloadTask *audioTask = [session downloadTaskWithURL:[NSURL URLWithString:audioURLString] completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error downloading audio: %@", error);
            } else if (location) {
                [fm moveItemAtPath:location.path toPath:audioPath error:nil];
            }
            dispatch_group_leave(downloadGroup);
        }];
        [audioTask resume];
    }

    // Wait for both tasks to complete
    dispatch_group_wait(downloadGroup, DISPATCH_TIME_FOREVER);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [progressToast updateProgressWithTitle:@"Processing video" subtitle:@"Merging audio and video..."];
    });

    // verify both files exist and are non-empty
        NSDictionary *downloadedVideoAttrs = [fm attributesOfItemAtPath:videoPath error:nil];
        if (![fm fileExistsAtPath:videoPath] || !downloadedVideoAttrs || [downloadedVideoAttrs fileSize] == 0) {
            NSLog(@"Video file missing or empty: %@", videoPath);
            dispatch_async(dispatch_get_main_queue(), ^{
                showCompletionToast(progressToast, NO, @"Error", @"Failed to download video", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
            });
            return;
        }
        if (hasAudio) {
            NSDictionary *audioAttrs = [fm attributesOfItemAtPath:audioPath error:nil];
            if (![fm fileExistsAtPath:audioPath] || !audioAttrs || [audioAttrs fileSize] == 0) {
                NSLog(@"Audio file missing or empty; continuing with video only: %@", audioPath);
                hasAudio = NO;
            }
        }
        
        // Detect and log video encoding
        AVAsset *videoAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
        NSArray<AVAssetTrack *> *videoTracks = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
        BOOL isAV1Video = NO;
        if (videoTracks.count > 0) {
            AVAssetTrack *videoTrack = videoTracks[0];
            NSArray *formatDescriptions = [videoTrack formatDescriptions];
            if (formatDescriptions.count > 0) {
                CMFormatDescriptionRef formatDesc = (__bridge CMFormatDescriptionRef)formatDescriptions[0];
                FourCharCode codec = CMFormatDescriptionGetMediaSubType(formatDesc);
                NSString *codecString = [NSString stringWithFormat:@"%c%c%c%c", 
                                        (char)(codec >> 24), 
                                        (char)(codec >> 16), 
                                        (char)(codec >> 8), 
                                        (char)codec];
                
                // Check if this is AV1 - if so, skip AVAsset merge and use FFmpeg directly
                if (codec == 0x61763031) { // 'av01'
                    isAV1Video = YES;
                }
            }
        }
        
        // If AV1, skip AVAsset merge and go directly to FFmpeg transcoding
        if (isAV1Video) {
            
            NSString *h264OutputPath = [documentsPath stringByAppendingPathComponent:@"output_h264.mp4"];
            
            // Remove if exists
            if ([fm fileExistsAtPath:h264OutputPath]) {
                [fm removeItemAtPath:h264OutputPath error:nil];
            }
            
            // Transcode using FFmpeg - pass original video file (not merged)
            NSError *transcodeError = nil;
            BOOL success = [AV1Transcoder transcodeAV1ToH264:videoPath 
                                                   outputPath:h264OutputPath 
                                                    audioPath:hasAudio ? audioPath : nil
                                                        error:&transcodeError 
                                                progressBlock:^(NSString *status, float progress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Use the same native progress bar style as bulk, with no extra subtitle text
                    [progressToast updateProgressWithTitle:@"Downloading video..."
                                                  subtitle:@""
                                                  progress:progress];
                });
            }];
            
            if (!success) {
                NSLog(@"Transcoding failed: %@", transcodeError);
                dispatch_async(dispatch_get_main_queue(), ^{
                    showCompletionToast(progressToast, NO, @"Error", @"Video transcoding failed", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                });
                [ThetaHelper endGlobalDownload];
                return;
            }
            
            // Save the transcoded file
            dispatch_async(dispatch_get_main_queue(), ^{
                [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Preparing to save..."];
            });
            
            // Check save method preference
            NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
            
            if (saveMethod == 0) {
                // Save to camera roll
                dispatch_async(dispatch_get_main_queue(), ^{
                    [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Adding to camera roll..."];
                });
                
                #ifdef SIDELOAD
                    // For sideload builds, copy to Caches and use ALAssetsLibrary
                    NSDictionary *fileAttrs = [fm attributesOfItemAtPath:h264OutputPath error:nil];
                    unsigned long long fileSize = [fileAttrs fileSize];
                    
                    if (fileSize > 0 && fileAttrs) {
                        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
                        NSString *cachesDir = [paths firstObject];
                        NSString *cacheVideoPath = [cachesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"theta_save_%@.mp4", [[NSUUID UUID] UUIDString]]];
                        
                        NSError *copyError = nil;
                        if ([fm copyItemAtPath:h264OutputPath toPath:cacheVideoPath error:&copyError]) {
                            
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                            ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                            [library writeVideoAtPathToSavedPhotosAlbum:[NSURL fileURLWithPath:cacheVideoPath] completionBlock:^(NSURL *assetURL, NSError *error) {
                                if (assetURL && !error) {
                                    
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                        NSString *finalTitle = (saveMethod == 0) ? @"Saved to camera roll!" : @"Saved to local folder!";
                                        NSString *finalSubtitle = (saveMethod == 0) ? @"Tap here to go to camera roll." : @"";
                                        NSURL *finalURL = (saveMethod == 0) ? [NSURL URLWithString:@"photos-redirect://"] : nil;
                                        showCompletionToast(progressToast, YES, finalTitle, finalSubtitle, [UIImage systemImageNamed:@"checkmark.circle.fill"], finalURL);
                                    });
                                    
                                    // Clean up
                                    [fm removeItemAtPath:videoPath error:nil];
                                    if (hasAudio) [fm removeItemAtPath:audioPath error:nil];
                                    [fm removeItemAtPath:h264OutputPath error:nil];
                                    [fm removeItemAtPath:cacheVideoPath error:nil];
                                } else {
                                    NSLog(@"Failed to save video: %@", error);
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        showCompletionToast(progressToast, NO, @"Error", @"Failed to save", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                    });
                                }
                                [ThetaHelper endGlobalDownload];
                            }];
                            #pragma clang diagnostic pop
                        } else {
                            NSLog(@"Failed to copy to Caches: %@", copyError);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                showCompletionToast(progressToast, NO, @"Error", @"Failed to prepare video", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                            });
                            [ThetaHelper endGlobalDownload];
                        }
                    } else {
                        NSLog(@"Transcoded file is empty");
                        dispatch_async(dispatch_get_main_queue(), ^{
                            showCompletionToast(progressToast, NO, @"Error", @"Transcoded file is invalid", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                        });
                        [ThetaHelper endGlobalDownload];
                    }
                #else
                    // Jailbreak: use PHPhotoLibrary with file URL
                    NSURL *h264OutputURL = [NSURL fileURLWithPath:h264OutputPath];
                    ThetaPhotoLibraryImportVideoFromURL(h264OutputURL, ^(BOOL success, NSError *error) {
                        if (success) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                NSString *finalTitle = (saveMethod == 0) ? @"Saved to camera roll!" : @"Saved to local folder!";
                                NSString *finalSubtitle = (saveMethod == 0) ? @"Tap here to go to camera roll." : @"";
                                NSURL *finalURL = (saveMethod == 0) ? [NSURL URLWithString:@"photos-redirect://"] : nil;
                                showCompletionToast(progressToast, YES, finalTitle, finalSubtitle, [UIImage systemImageNamed:@"checkmark.circle.fill"], finalURL);
                            });
                            
                            // Clean up
                            [fm removeItemAtPath:videoPath error:nil];
                            if (hasAudio) [fm removeItemAtPath:audioPath error:nil];
                            [fm removeItemAtPath:h264OutputPath error:nil];
                        } else {
                            NSLog(@"Failed to save video: %@", error);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                showCompletionToast(progressToast, NO, @"Error", @"Failed to save", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                            });
                        }
                        [ThetaHelper endGlobalDownload];
                    });
                #endif
            } else {
                // Save to AudioNotes folder
                dispatch_async(dispatch_get_main_queue(), ^{
                    [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Moving to AudioNotes folder..."];
                });
                
                NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                if (![fm fileExistsAtPath:audioNotesDir]) {
                    [fm createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                
                NSDateFormatter *formatter = [NSDateFormatter new];
                [formatter setDateFormat:@"yyyyMMdd-HHmmss"];
                NSString *destName = [NSString stringWithFormat:@"Video-%@.mp4", [formatter stringFromDate:[NSDate date]]];
                NSString *destPath = [audioNotesDir stringByAppendingPathComponent:destName];
                
                NSError *moveError = nil;
                    if ([fm moveItemAtPath:h264OutputPath toPath:destPath error:&moveError]) {
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                        NSString *finalTitle = (saveMethod == 0) ? @"Saved to camera roll!" : @"Saved to local folder!";
                        NSString *finalSubtitle = (saveMethod == 0) ? @"Tap here to go to camera roll." : @"Saved to AudioNotes folder.";
                        NSURL *finalURL = (saveMethod == 0) ? [NSURL URLWithString:@"photos-redirect://"] : nil;
                        showCompletionToast(progressToast, YES, finalTitle, finalSubtitle, [UIImage systemImageNamed:@"checkmark.circle.fill"], finalURL);
                    });
                    
                    // Clean up
                    [fm removeItemAtPath:videoPath error:nil];
                    if (hasAudio) [fm removeItemAtPath:audioPath error:nil];
                } else {
                    NSLog(@"Error moving video to AudioNotes: %@", moveError);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        showCompletionToast(progressToast, NO, @"Error", @"Could not move video", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                    });
                }
                [ThetaHelper endGlobalDownload];
            }
            
            // Exit early - don't continue with AVAsset merge path
            return;
        }
        
        // Detect and log audio encoding if audio file exists
        if (hasAudio) {
            AVAsset *audioAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:audioPath]];
            NSArray<AVAssetTrack *> *audioTracks = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
            if (audioTracks.count > 0) {
                AVAssetTrack *audioTrack = audioTracks[0];
                NSArray *formatDescriptions = [audioTrack formatDescriptions];
                if (formatDescriptions.count > 0) {
                    CMFormatDescriptionRef formatDesc = (__bridge CMFormatDescriptionRef)formatDescriptions[0];
                    FourCharCode codec = CMFormatDescriptionGetMediaSubType(formatDesc);
                    NSString *codecString = [NSString stringWithFormat:@"%c%c%c%c", 
                                            (char)(codec >> 24), 
                                            (char)(codec >> 16), 
                                            (char)(codec >> 8), 
                                            (char)codec];
                }
            }
        }
        
        // Merge and export to a camera-roll-friendly MP4 (interleaved, AAC, moov placement suited for Photos)
        NSString *outputPath = [documentsPath stringByAppendingPathComponent:@"output.mp4"];
        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
        
        // Remove output file if it exists
        if ([fm fileExistsAtPath:outputPath]) {
            [fm removeItemAtPath:outputPath error:nil];
        }
        
        // Create composition
        AVMutableComposition *composition = [AVMutableComposition composition];
        AVMutableCompositionTrack *compositionVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        AVMutableCompositionTrack *compositionAudioTrack = nil;
        
        AVAsset *videoAssetForMerge = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
        AVAssetTrack *videoTrackForMerge = [[videoAssetForMerge tracksWithMediaType:AVMediaTypeVideo] firstObject];
        AVAsset *audioAssetForMerge = nil;
        AVAssetTrack *audioTrackForMerge = nil;
        if (hasAudio) {
            audioAssetForMerge = [AVAsset assetWithURL:[NSURL fileURLWithPath:audioPath]];
            audioTrackForMerge = [[audioAssetForMerge tracksWithMediaType:AVMediaTypeAudio] firstObject];
        }
        
        CMTime videoDur = videoAssetForMerge.duration;
        CMTime mergeDur = videoDur;
        if (audioTrackForMerge && audioAssetForMerge && CMTIME_IS_NUMERIC(audioAssetForMerge.duration)) {
            mergeDur = CMTimeMinimum(videoDur, audioAssetForMerge.duration);
        }
        if (!CMTIME_IS_NUMERIC(mergeDur) || CMTIME_COMPARE_INLINE(mergeDur, <=, kCMTimeZero)) {
            mergeDur = videoDur;
        }
        
        NSError *videoInsertError = nil;
        CMTimeRange mergeRange = CMTimeRangeMake(kCMTimeZero, mergeDur);
        if (videoTrackForMerge) {
            [compositionVideoTrack insertTimeRange:mergeRange ofTrack:videoTrackForMerge atTime:kCMTimeZero error:&videoInsertError];
            if (videoInsertError) {
                NSLog(@"Error adding video track: %@", videoInsertError);
                dispatch_async(dispatch_get_main_queue(), ^{
                    showCompletionToast(progressToast, NO, @"Error", @"Could not process video track", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                });
                return;
            }
        }
        
        if (hasAudio && audioTrackForMerge) {
            compositionAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            NSError *audioInsertError = nil;
            [compositionAudioTrack insertTimeRange:mergeRange ofTrack:audioTrackForMerge atTime:kCMTimeZero error:&audioInsertError];
            if (audioInsertError) {
                NSLog(@"Error adding audio track: %@", audioInsertError);
                dispatch_async(dispatch_get_main_queue(), ^{
                    showCompletionToast(progressToast, NO, @"Error", @"Could not merge audio", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                });
                return;
            }
        } else if (hasAudio) {
            NSLog(@"Warning: No decodable audio track in downloaded audio file");
        }
        
        AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
        exportSession.outputURL = outputURL;
        exportSession.outputFileType = AVFileTypeMPEG4;
        if ([exportSession respondsToSelector:@selector(setShouldOptimizeForNetworkUse:)]) {
            exportSession.shouldOptimizeForNetworkUse = YES;
        }
        
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                // Verify the merged output actually contains audio
                AVAsset *mergedAsset = [AVAsset assetWithURL:outputURL];
                NSArray<AVAssetTrack *> *mergedAudioTracks = [mergedAsset tracksWithMediaType:AVMediaTypeAudio];
                if (hasAudio && mergedAudioTracks.count <= 0) {
                    NSLog(@"ThetaSave: export completed without an audio track (DASH audio may be unsupported)");
                }
                
                // Check and request photo library authorization
                PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
                
                if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                    // Verify file exists and get file info
                    NSError *fileError = nil;
                    NSDictionary *fileAttrs = [fm attributesOfItemAtPath:outputPath error:&fileError];
                    if (fileError) {
                        NSLog(@"Error reading output file attributes: %@", fileError);
                    }
                    
                    BOOL fileExists = [fm fileExistsAtPath:outputPath];
                    
                    // Check if file is compatible with Photos library
                    // AV1 video may not be supported by Photos, need to re-encode to H.264
                    AVAsset *checkAsset = [AVAsset assetWithURL:outputURL];
                    NSArray<AVAssetTrack *> *checkVideoTracks = [checkAsset tracksWithMediaType:AVMediaTypeVideo];
                    if (checkVideoTracks.count > 0) {
                        AVAssetTrack *checkVideoTrack = checkVideoTracks[0];
                        NSArray *checkFormatDescriptions = [checkVideoTrack formatDescriptions];
                        if (checkFormatDescriptions.count > 0) {
                            CMFormatDescriptionRef formatDesc = (__bridge CMFormatDescriptionRef)checkFormatDescriptions[0];
                            FourCharCode codec = CMFormatDescriptionGetMediaSubType(formatDesc);
                            
                            // Check if codec is AV1 (av01)
                            if (codec == 0x61763031) { // 'av01'
                                NSString *h264OutputPath = [documentsPath stringByAppendingPathComponent:@"output_h264.mp4"];
                                
                                // Remove if exists
                                if ([fm fileExistsAtPath:h264OutputPath]) {
                                    [fm removeItemAtPath:h264OutputPath error:nil];
                                }
                                
                            // Transcode using our AV1Transcoder (uses dlopen for ffmpeg)
                            // Pass separate audio file if available (AVAsset can't read xHE-AAC from DASH)
                            NSError *transcodeError = nil;
                            BOOL success = [AV1Transcoder transcodeAV1ToH264:outputPath 
                                                                   outputPath:h264OutputPath 
                                                                    audioPath:hasAudio ? audioPath : nil
                                                                        error:&transcodeError 
                                                                progressBlock:^(NSString *status, float progress) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [progressToast updateProgressWithTitle:@"Downloading video..."
                                                                  subtitle:@""
                                                                  progress:progress];
                                });
                            }];
                            
                            if (success) {
                                // Warn user if audio was expected but not present
                                if (hasAudio) {
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        [progressToast updateProgressWithTitle:@"Note" subtitle:@"Video saved, but audio from DASH may be incompatible"];
                                    });
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                        [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Preparing to save..."];
                                    });
                                }
                                
                                // Check save method preference
                                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                
                                if (saveMethod == 0) {
                                    // Save to camera roll
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Adding to camera roll..."];
                                    });
                                    
                                    #ifdef SIDELOAD
                                        // For sideload builds, must load video into memory (file URLs don't work in sandbox)
                                        // Verify file exists and has content
                                        NSDictionary *fileAttrs = [fm attributesOfItemAtPath:h264OutputPath error:nil];
                                        unsigned long long fileSize = [fileAttrs fileSize];
                                        
                                        if (fileSize == 0 || !fileAttrs) {
                                            NSLog(@"Transcoded file is empty or doesn't exist");
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                showCompletionToast(progressToast, NO, @"Error", @"Transcoded video file is invalid", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                            });
                                            dispatch_semaphore_signal(semaphore);
                                        } else {
                                            // Load video data into memory (required for sandboxed apps)
                                            // Copy video to app's Library/Caches which is more accessible
                                            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
                                            NSString *cachesDir = [paths firstObject];
                                            NSString *cacheVideoPath = [cachesDir stringByAppendingPathComponent:[NSString stringWithFormat:@"theta_save_%@.mp4", [[NSUUID UUID] UUIDString]]];
                                            
                                            NSError *copyError = nil;
                                            if ([fm copyItemAtPath:h264OutputPath toPath:cacheVideoPath error:&copyError]) {
                                                
                                                // Use legacy ALAssetsLibrary with file URL from Caches
                                                #pragma clang diagnostic push
                                                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                                                ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
                                                [library writeVideoAtPathToSavedPhotosAlbum:[NSURL fileURLWithPath:cacheVideoPath] completionBlock:^(NSURL *assetURL, NSError *error) {
                                                    if (assetURL && !error) {
                                                        
                                                        dispatch_async(dispatch_get_main_queue(), ^{
                                                            NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                                            NSString *finalTitle = (saveMethod == 0) ? @"Saved to camera roll!" : @"Saved to local folder!";
                                                            NSString *finalSubtitle = (saveMethod == 0) ? @"Tap here to go to camera roll." : @"";
                                                            NSURL *finalURL = (saveMethod == 0) ? [NSURL URLWithString:@"photos-redirect://"] : nil;
                                                            showCompletionToast(progressToast, YES, finalTitle, finalSubtitle, [UIImage systemImageNamed:@"checkmark.circle.fill"], finalURL);
                                                        });
                                                        
                                                        // Clean up all temporary files
                                                        [fm removeItemAtPath:videoPath error:nil];
                                                        if (hasAudio) {
                                                            [fm removeItemAtPath:audioPath error:nil];
                                                        }
                                                        [fm removeItemAtPath:outputPath error:nil];
                                                        [fm removeItemAtPath:h264OutputPath error:nil];
                                                        [fm removeItemAtPath:cacheVideoPath error:nil];
                                                    } else {
                                                        NSLog(@"Failed to save video using ALAssetsLibrary: %@", error);
                                                        NSLog(@"Error domain: %@, code: %ld", error.domain, (long)error.code);
                                                        dispatch_async(dispatch_get_main_queue(), ^{
                                                            NSString *errorMsg = error.localizedDescription ?: @"Unknown error";
                                                            showCompletionToast(progressToast, NO, @"Error", [NSString stringWithFormat:@"Save failed: %@", errorMsg], [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                                        });
                                                        // Don't clean up so user can debug
                                                    }
                                                    dispatch_semaphore_signal(semaphore);
                                                }];
                                                #pragma clang diagnostic pop
                                            } else {
                                                NSLog(@"Failed to copy video to Caches: %@", copyError);
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    showCompletionToast(progressToast, NO, @"Error", @"Failed to prepare video", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                                });
                                                dispatch_semaphore_signal(semaphore);
                                            }
                                        }
                                    #else
                                        // For jailbreak builds, use file URL (faster, no memory copy)
                                        NSURL *h264OutputURL = [NSURL fileURLWithPath:h264OutputPath];
                                        ThetaPhotoLibraryImportVideoFromURL(h264OutputURL, ^(BOOL success, NSError * _Nullable error) {
                                            if (success) {
                                                
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                                    NSString *finalTitle = (saveMethod == 0) ? @"Saved to camera roll!" : @"Saved to local folder!";
                                                    NSString *finalSubtitle = (saveMethod == 0) ? @"Tap here to go to camera roll." : @"";
                                                    NSURL *finalURL = (saveMethod == 0) ? [NSURL URLWithString:@"photos-redirect://"] : nil;
                                                    showCompletionToast(progressToast, YES, finalTitle, finalSubtitle, [UIImage systemImageNamed:@"checkmark.circle.fill"], finalURL);
                                                });
                                                
                                                // Clean up all temporary files
                                                [fm removeItemAtPath:videoPath error:nil];
                                                if (hasAudio) {
                                                    [fm removeItemAtPath:audioPath error:nil];
                                                }
                                                [fm removeItemAtPath:outputPath error:nil];
                                                [fm removeItemAtPath:h264OutputPath error:nil];
                                            } else {
                                                NSLog(@"Failed to save H.264 video to camera roll: %@", error);
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    showCompletionToast(progressToast, NO, @"Error", @"Failed to save to camera roll", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                                });
                                            }
                                            dispatch_semaphore_signal(semaphore);
                                        });
                                    #endif
                                } else {
                                    // Save to AudioNotes folder
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Moving to AudioNotes folder..."];
                                    });
                                    
                                    NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                                    if (![fm fileExistsAtPath:audioNotesDir]) {
                                        [fm createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                                    }
                                    
                                    NSDateFormatter *formatter = [NSDateFormatter new];
                                    [formatter setDateFormat:@"yyyyMMdd-HHmmss"];
                                    NSString *destName = [NSString stringWithFormat:@"Video-%@.mp4", [formatter stringFromDate:[NSDate date]]];
                                    NSString *destPath = [audioNotesDir stringByAppendingPathComponent:destName];
                                    
                                    NSError *moveError = nil;
                                    if ([fm moveItemAtPath:h264OutputPath toPath:destPath error:&moveError]) {
                                        
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                            NSString *finalTitle = (saveMethod == 0) ? @"Saved to camera roll!" : @"Saved to local folder!";
                                            NSString *finalSubtitle = (saveMethod == 0) ? @"Tap here to go to camera roll." : @"Saved to local folder.";
                                            NSURL *finalURL = (saveMethod == 0) ? [NSURL URLWithString:@"photos-redirect://"] : nil;
                                            showCompletionToast(progressToast, YES, finalTitle, finalSubtitle, [UIImage systemImageNamed:@"checkmark.circle.fill"], finalURL);
                                        });
                                        
                                        // Clean up all temporary files except the final one
                                        [fm removeItemAtPath:videoPath error:nil];
                                        if (hasAudio) {
                                            [fm removeItemAtPath:audioPath error:nil];
                                        }
                                        [fm removeItemAtPath:outputPath error:nil];
                                        // Don't remove h264OutputPath - we moved it to AudioNotes
                                    } else {
                                        NSLog(@"Error moving video to AudioNotes: %@", moveError);
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            showCompletionToast(progressToast, NO, @"Error", @"Could not move video to AudioNotes.", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                        });
                                    }
                                    dispatch_semaphore_signal(semaphore);
                                }
                                } else {
                                    NSLog(@"Transcoding failed: %@", transcodeError);
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        showCompletionToast(progressToast, NO, @"Error", @"Transcoding failed", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                                    });
                                    dispatch_semaphore_signal(semaphore);
                                }
                                
                                return; // Exit early, we're handling this in the callbacks
                            }
                        }
                    }
                    
                // Try to save directly if not AV1
                dispatch_async(dispatch_get_main_queue(), ^{
                    [progressToast updateProgressWithTitle:@"Saving video" subtitle:@"Adding to camera roll..."];
                });
                
                ThetaPhotoLibraryImportVideoFromURL(outputURL, ^(BOOL success, NSError * _Nullable error) {
                    if (success) {
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [progressToast completeProgressWithTitle:@"Success!" subtitle:@"Video saved to camera roll" icon:nil url:nil];
                        });
                        
                        // Clean up temporary files after saving to camera roll
                        [fm removeItemAtPath:videoPath error:nil];
                        if (hasAudio) {
                            [fm removeItemAtPath:audioPath error:nil];
                        }
                        [fm removeItemAtPath:outputPath error:nil];
                    } else {
                        NSLog(@"Failed to save video to camera roll: %@", error);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [progressToast completeProgressWithTitle:@"Error" subtitle:@"Failed to save to camera roll" icon:nil url:nil];
                        });
                    }
                    dispatch_semaphore_signal(semaphore);
                });
                } else if (status == PHAuthorizationStatusNotDetermined) {
                    // Request authorization
                    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus newStatus) {
                        NSLog(@"Photo library authorization status after request: %ld", (long)newStatus);
                        if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                            ThetaPhotoLibraryImportVideoFromURL(outputURL, ^(BOOL success, NSError * _Nullable error) {
                                if (success) {
                                    
                                    // Clean up temporary files after saving to camera roll
                                    [fm removeItemAtPath:videoPath error:nil];
                                    if (hasAudio) {
                                        [fm removeItemAtPath:audioPath error:nil];
                                    }
                                    [fm removeItemAtPath:outputPath error:nil];
                                } else {
                                    NSLog(@"Failed to save video to camera roll: %@", error);
                                }
                                dispatch_semaphore_signal(semaphore);
                            });
                        } else {
                            NSLog(@"Photo library access denied by user");
                            dispatch_semaphore_signal(semaphore);
                        }
                    }];
                } else {
                    NSLog(@"Photo library access denied or restricted. Status: %ld", (long)status);
                    dispatch_semaphore_signal(semaphore);
                }
            } else {
                NSLog(@"Export failed with status: %ld, error: %@", (long)exportSession.status, exportSession.error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    showCompletionToast(progressToast, NO, @"Error", @"Could not prepare video for saving", [UIImage systemImageNamed:@"exclamationmark.triangle"], nil);
                });
                dispatch_semaphore_signal(semaphore);
            }
        }];
    });
}

static void downloadMedia(id self) {
	@try {
        NSMutableArray *igvideos = [NSMutableArray array];

        IGFeedItemUFICell *cell = [self valueForKey:@"delegate"];
		if (!cell) {
			return;
		}
        IGFeedItemUFICellConfigurableDelegateImpl *delegateImpl = [cell valueForKey:@"delegate"];
		if (!delegateImpl) {
			return;
		}
        IGMedia *currentMedia;
        if ([delegateImpl isKindOfClass:NSClassFromString(@"IGFeedItemUFICellConfigurableDelegateImpl")]) {
            currentMedia = [delegateImpl valueForKey:@"_media"];
        } else if ([delegateImpl isKindOfClass:NSClassFromString(@"IGFeedSectionController")]) {
            currentMedia = [[delegateImpl performSelector:@selector(mediaCell)] valueForKey:@"_media"];
        }

        if (!currentMedia) {
            return;
        }

        NSMutableArray *mediaItems = [NSMutableArray array];
        NSMutableArray *regularItems = [NSMutableArray array];
        NSString *toastTitle = currentMedia.items.count > 1 ? @"Fetching media..." : @"Saving media...";
        
        // Check if download is already in progress BEFORE showing toast to prevent flash
        if ([ThetaHelper isGlobalDownloadInProgress]) {
            // Show the "download in progress" notification immediately without the "saving media" flash
            [ThetaHelper tryBeginGlobalDownloadOrNotify];
            return;
        }
        
        if (ENABLED(@"Show Banners")) {
            UIImage *fetchingImage = [UIImage systemImageNamed:@"arrow.clockwise"];
            [ThetaHelper showToastWithTitle:toastTitle subtitle:@"This will only take a second." icon:fetchingImage autoHide:4 openURL:nil];
        }

        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            @autoreleasepool {
                for (IGPostItem *media in currentMedia.items) {
                    NSURL *url = nil;
                    UIImage *preview = nil;
                    BOOL isVideo = NO;

                    BOOL handled = NO;

                    if (!handled && [media respondsToSelector:@selector(itemMediaType)]) {
                        if (media.itemMediaType == 1) {
                            IGPhoto *photo = media.photo;
                            NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                            if (originalImageVersions.count > 1) {
                                id photoURL = [originalImageVersions lastObject];
                                url = [photoURL valueForKey:@"url"];
                                if (url) {
                                    NSData *imageData = [NSData dataWithContentsOfURL:url];
                                    if (imageData) {
                                        preview = [UIImage imageWithData:imageData];
                                    }
                                }
                            }
                        } else if (media.itemMediaType == 2) {
                            IGVideo *video = media.video;
                            [igvideos addObject:video];
                            isVideo = YES;
                        }
                        handled = YES;
                    }

                    if (!handled && [media respondsToSelector:@selector(mediaType)]) {
                        if (media.mediaType == 1) {
                            IGPhoto *photo = media.photo;
                            NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                            if (originalImageVersions.count > 1) {
                                id photoURL = [originalImageVersions lastObject];
                                url = [photoURL valueForKey:@"url"];
                                if (url) {
                                    NSData *imageData = [NSData dataWithContentsOfURL:url];
                                    if (imageData) {
                                        preview = [UIImage imageWithData:imageData];
                                    }
                                }
                            }
                        } else if (media.mediaType == 2) {
                            IGVideo *video = media.video;
                            [igvideos addObject:video];
                            isVideo = YES;
                        }
                        handled = YES;
                    }

                    // Add to appropriate arrays
                    if (url || isVideo) {
                        // Count all items for total count
                        NSDictionary *mediaDict = @{ @"url": url ? url.absoluteString : @"", @"preview": preview ?: [UIImage systemImageNamed:@"photo"] };
                        [mediaItems addObject:mediaDict];
                        
                        // Add non-video items to regularItems
                        if (!isVideo && url) {
                            [regularItems addObject:mediaDict];
                        }
                    }
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!weakSelf) return;

                    NSInteger totalItems = igvideos.count + regularItems.count;
                    
                    // Handle single item cases
                    if (totalItems == 1) {
                        if (igvideos.count == 1) {
                            downloadHDVideo(igvideos.firstObject);
                        } else if (regularItems.count == 1) {
                            NSDictionary *mediaDict = regularItems.firstObject;
                            NSURL *url = [NSURL URLWithString:mediaDict[@"url"]];
                            if (url) {
                                MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] init];
                                // Guard for camera roll save via mediaSelectionVC helper
                                if (![ThetaHelper tryBeginGlobalDownloadOrNotify]) {
                                    return;
                                }
                                [mediaSelectionVC downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension){
                                    [ThetaHelper endGlobalDownload];
                                    if (ENABLED(@"Show Banners")) {
                                        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                        if (saveMethod == 0) {
                                            [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                                        } else {
                                            [ThetaHelper showToastWithTitle:@"Saved!" subtitle:@"Saved to Documents." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:nil];
                                        }
                                    }
                                }];
                            }
                        }
                        return;
                    }
                    
                    // Handle multiple items
                    if (totalItems > 1) {
                        if (igvideos.count > 0) {
                            // Preload HD video thumbnails before showing the view controller
                            [MediaSelectionViewController preloadHDVideoThumbnails:igvideos completion:^{
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:regularItems hdVideos:igvideos withCount:totalItems];
                                    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
                                    [[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
                                });
                            }];
                        } else {
                            MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:regularItems withCount:totalItems];
                            UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
                            [[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
                        }
                    }
                });
            }
        });
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

static void fullscreenMediaItem(id self) {
    @try {
        IGFeedItemUFICell *cell = [self valueForKey:@"delegate"];
        IGFeedItemPageIndicator *pageControl = [cell valueForKey:@"_pageControl"];
        NSUInteger currentIndex = [[pageControl valueForKey:@"_currentPage"] unsignedIntegerValue];
        IGFeedItemUFICellConfigurableDelegateImpl *delegateImpl = [cell valueForKey:@"delegate"];
        IGMedia *currentMedia;
        if ([delegateImpl isKindOfClass:NSClassFromString(@"IGFeedItemUFICellConfigurableDelegateImpl")]) {
            currentMedia = [delegateImpl valueForKey:@"_media"];
        } else if ([delegateImpl isKindOfClass:NSClassFromString(@"IGFeedSectionController")]) {
            currentMedia = [[delegateImpl performSelector:@selector(mediaCell)] valueForKey:@"_media"];
        }

        IGPostItem *media = [currentMedia.items objectAtIndex:currentIndex];
        NSURL *url = nil;

        if ([media respondsToSelector:@selector(itemMediaType)]) {
            if (media.itemMediaType == 1) {
                IGPhoto *photo = media.photo;
                NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                if (originalImageVersions.count > 1) {
                    id photoURL = [originalImageVersions lastObject];
                    url = [photoURL valueForKey:@"url"];
                }
            } else if (media.itemMediaType == 2) {
                IGVideo *video = media.video;
                NSSet *videoURLs = [video allVideoURLs];
                url = [videoURLs anyObject];
            }
        }

        if ([media respondsToSelector:@selector(mediaType)]) {
            if (media.mediaType == 1) {
                IGPhoto *photo = media.photo;
                NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                if (originalImageVersions.count > 1) {
                    id photoURL = [originalImageVersions lastObject];
                    url = [photoURL valueForKey:@"url"];
                }
            } else if (media.mediaType == 2) {
                IGVideo *video = media.video;
                NSSet *videoURLs = [video allVideoURLs];
                url = [videoURLs anyObject];
            }	
        }

        MediaViewController *mediaVC = [MediaViewController new];
        [mediaVC initWithMediaURL:url];
        mediaVC.modalPresentationStyle = UIModalPresentationFullScreen;
        [[ThetaHelper topViewController] presentViewController:mediaVC animated:YES completion:nil];
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

static void (*orig_savePost)(id self, SEL _cmd);
static void hook_savePost(id self, SEL _cmd) {
    if (orig_savePost) orig_savePost(self, _cmd);

    if (ENABLED(@"Hide Repost Button")) {
        id repostView = ThetaValueForKey(self, @"_repostView");
        if ([repostView respondsToSelector:@selector(setHidden:)]) {
            [repostView setHidden:YES];
        }
    }

    // Don't touch KVC unless a save/fullscreen feature is on — _sendView throws on many UFI layouts.
    if (!(ENABLED(@"Save Media") || ENABLED(@"Fullscreen Posts"))) {
        return;
    }

    if ([self viewWithTag:999] != nil) {
        return;
    }

    UIView *sendView = ThetaValueForKey(self, @"_sendView");
    if (![sendView isKindOfClass:[UIView class]]) {
        sendView = ThetaValueForKey(self, @"sendView");
    }
    if (![sendView isKindOfClass:[UIView class]]) {
        return;
    }

    UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    downloadButton.tag = 999;
    [downloadButton setTintColor:UIColor.labelColor];
    
    // Use iOS 16+ SF Symbol with fallback for older versions
    UIImage *buttonImage;
    if (@available(iOS 16.0, *)) {
        buttonImage = [UIImage systemImageNamed:@"arrow.down.to.line"];
    } else {
        // Fallback for iOS 15 - use a different symbol or create a custom image
        buttonImage = [UIImage systemImageNamed:@"arrow.down"];
    }
    [downloadButton setImage:buttonImage forState:UIControlStateNormal];
    
    [downloadButton setTranslatesAutoresizingMaskIntoConstraints:NO];

    ThetaSetCaptureHiding(downloadButton);
    if (ENABLED(@"Save Media") || ENABLED(@"Fullscreen Posts")) {
		[self addSubview:downloadButton];
        [NSLayoutConstraint activateConstraints:@[
            [downloadButton.topAnchor constraintEqualToAnchor:sendView.topAnchor constant:3],
            [downloadButton.leadingAnchor constraintEqualToAnchor:sendView.trailingAnchor],
            [downloadButton.widthAnchor constraintEqualToConstant:40],
            [downloadButton.heightAnchor constraintEqualToConstant:40]
        ]];
        
        // Only set up the menu if the button was successfully added
        if (downloadButton.superview) {
            NSMutableArray *actions = [NSMutableArray array];

            if (ENABLED(@"Save Media")) {
                __weak typeof(self) weakSelf = self;
                
                // Use iOS 16+ SF Symbol with fallback for older versions
                UIImage *actionImage;
                if (@available(iOS 16.0, *)) {
                    actionImage = [UIImage systemImageNamed:@"arrow.down.to.line"];
                } else {
                    actionImage = [UIImage systemImageNamed:@"arrow.down"];
                }
                
                UIAction *downloadBtn = [UIAction actionWithTitle:@"Download Media"
                                                        image:actionImage
                                                    identifier:nil
                                                        handler:^(__kindof UIAction * _Nonnull action) {
                                                            downloadMedia(weakSelf);
                                                        [ThetaHelper performHapticFeedbackIfEnabled];
                                                        }];
                [actions addObject:downloadBtn];
            }

            if (ENABLED(@"Fullscreen Posts")) {
                __weak typeof(self) weakSelf = self;
                
                // Use iOS 16+ SF Symbol with fallback for older versions
                UIImage *fullscreenImage;
                if (@available(iOS 16.0, *)) {
                    fullscreenImage = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"];
                } else {
                    // Fallback for iOS 15 - use a different symbol
                    fullscreenImage = [UIImage systemImageNamed:@"arrow.up.left"];
                }
                
                UIAction *fullscreenBtn = [UIAction actionWithTitle:@"Fullscreen Current Media"
                                                            image:fullscreenImage
                                                        identifier:nil
                                                        handler:^(__kindof UIAction * _Nonnull action) {
                                                                fullscreenMediaItem(weakSelf);
                                                            [ThetaHelper performHapticFeedbackIfEnabled];
                                                        }];
                [actions addObject:fullscreenBtn];
            }

            UIMenu *mainMenu = [UIMenu menuWithTitle:@"" children:actions];
            [downloadButton setMenu:mainMenu];
            downloadButton.showsMenuAsPrimaryAction = YES;
        }
    }
}

static void downloadSundialMedia(id self) {
    IGSundialViewerControlsOverlayView *delegate = [self valueForKey:@"delegate"];
    IGMedia *media = nil;
    @try {
        media = [delegate valueForKey:@"_media"];
    } @catch (NSException *exception) {
        @try {
            media = delegate.media;
        } @catch (NSException *exception) {
            NSLog(@"Error: %@", exception);
            return; // Early return if we can't get media
        }
    }
    
    if (!media) {
        NSLog(@"Error: No media found");
        return;
    }
    
    // Create thread-safe arrays with synchronization queue
    NSMutableArray *hdvideoss = [NSMutableArray array];
    NSMutableArray *normalItems = [NSMutableArray array];
    dispatch_queue_t syncQueue = dispatch_queue_create("com.theta.mediaSync", DISPATCH_QUEUE_SERIAL);

    NSArray *mediaItems = [media valueForKey:@"items"];
    if (!mediaItems || mediaItems.count == 0) {
        NSLog(@"Error: No media items found");
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        for (IGPostItem *mediaItem in mediaItems) {
            if (!mediaItem) continue;
            
            NSURL *url = nil;
            UIImage *preview = nil;
            IGVideo *video = nil;

            BOOL handled = NO;

            if (!handled && [mediaItem respondsToSelector:@selector(itemMediaType)]) {
                if (mediaItem.itemMediaType == 1) {
                    IGPhoto *photo = mediaItem.photo;
                    if (photo) {
                        NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                        if (originalImageVersions.count > 1) {
                            id photoURL = [originalImageVersions lastObject];
                            url = [photoURL valueForKey:@"url"];
                            if (url) {
                                NSData *imageData = [NSData dataWithContentsOfURL:url];
                                if (imageData) {
                                    preview = [UIImage imageWithData:imageData];
                                }
                            }
                        }
                    }
                } else if (mediaItem.itemMediaType == 2) {
                    video = mediaItem.video;
                    if (video) {
                        dispatch_sync(syncQueue, ^{
                            [hdvideoss addObject:video];
                        });
                    }
                }
                handled = YES;
            }

            if (!handled && [mediaItem respondsToSelector:@selector(mediaType)]) {
                if (mediaItem.mediaType == 1) {
                    IGPhoto *photo = mediaItem.photo;
                    if (photo) {
                        NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                        if (originalImageVersions.count > 1) {
                            id photoURL = [originalImageVersions lastObject];
                            url = [photoURL valueForKey:@"url"];
                            if (url) {
                                NSData *imageData = [NSData dataWithContentsOfURL:url];
                                if (imageData) {
                                    preview = [UIImage imageWithData:imageData];
                                }
                            }
                        }
                    }
                } else if (mediaItem.mediaType == 2) {
                    video = mediaItem.video;
                    if (video) {
                        dispatch_sync(syncQueue, ^{
                            [hdvideoss addObject:video];
                        });
                    }
                }
                handled = YES;
            }

            if (url) {
                NSDictionary *mediaDict = @{ @"url": url.absoluteString, @"preview": preview ?: [UIImage systemImageNamed:@"photo"] };
                dispatch_sync(syncQueue, ^{
                    [normalItems addObject:mediaDict];
                });
            }
        }
        
        // Process results on main queue with thread-safe copies
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            // Create thread-safe copies of arrays
            __block NSArray *finalHDVideos = nil;
            __block NSArray *finalNormalItems = nil;
            dispatch_sync(syncQueue, ^{
                finalHDVideos = [hdvideoss copy];
                finalNormalItems = [normalItems copy];
            });

            // Handle single HD video
            if (finalHDVideos.count == 1) {
                IGVideo *video = finalHDVideos.firstObject;
                if (video) {
                    downloadHDVideo(video);
                }
            } 
            // Handle multiple HD videos
            else if (finalHDVideos.count > 1) {
                [MediaSelectionViewController preloadHDVideoThumbnails:finalHDVideos completion:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!weakSelf) return;
                        MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:finalNormalItems hdVideos:finalHDVideos withCount:mediaItems.count];
                        if (mediaSelectionVC) {
                            UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
                            if (navController) {
                                [[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
                            }
                        }
                    });
                }];
            }
            
            // Handle single media item (non-HD)
            if (mediaItems.count == 1 && finalHDVideos.count == 0) {
                IGPostItem *mediaItem = mediaItems.firstObject;
                if (!mediaItem) return;
                
                NSURL *url = nil;
                // Extract URL from the actual media item, not from normalItems array
                if ([mediaItem respondsToSelector:@selector(itemMediaType)]) {
                    if (mediaItem.itemMediaType == 1) {
                        IGPhoto *photo = mediaItem.photo;
                        if (photo) {
                            NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                            if (originalImageVersions.count > 1) {
                                id photoURL = [originalImageVersions lastObject];
                                url = [photoURL valueForKey:@"url"];
                            }
                        }
                    }
                } else if ([mediaItem respondsToSelector:@selector(mediaType)]) {
                    if (mediaItem.mediaType == 1) {
                        IGPhoto *photo = mediaItem.photo;
                        if (photo) {
                            NSArray *originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
                            if (originalImageVersions.count > 1) {
                                id photoURL = [originalImageVersions lastObject];
                                url = [photoURL valueForKey:@"url"];
                            }
                        }
                    }
                }
                
                if (url) {
                    MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] init];
                    if (mediaSelectionVC) {
                        [mediaSelectionVC downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension){
                            if (ENABLED(@"Show Banners")) {
                                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                                if (saveMethod == 0) {
                                    [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                                } else {
                                    [ThetaHelper showToastWithTitle:@"Saved!" subtitle:@"Saved to Documents." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:nil];
                                }
                            }
                        }];
                    }
                }
            }

            // Handle multiple media items
            if (mediaItems.count > 1) {
                // Preload HD video thumbnails before showing the view controller
                if (finalHDVideos.count > 0) {
                    [MediaSelectionViewController preloadHDVideoThumbnails:finalHDVideos completion:^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (!weakSelf) return;
                            MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:finalNormalItems hdVideos:finalHDVideos withCount:mediaItems.count];
                            if (mediaSelectionVC) {
                                UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
                                if (navController) {
                                    [[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
                                }
                            }
                        });
                    }];
                } else if (finalNormalItems.count > 0) {
                    MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:finalNormalItems withCount:mediaItems.count];
                    if (mediaSelectionVC) {
                        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
                        if (navController) {
                            [[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
                        }
                    }
                }
            }
        });
    });
}

/// Removes the whole repost “column” from a horizontal `UIStackView` so space collapses (same idea as HideTabs `theta_detachTabSlotForLabel`).
static void theta_sundialDetachRepostUFISlot(UIView *start, UIView *ufiRoot) {
    if (!start || !ufiRoot || ![start isDescendantOfView:ufiRoot]) {
        return;
    }
    Class stackClass = NSClassFromString(@"UIStackView");
    UIView *v = start;
    while (v.superview && v.superview != ufiRoot) {
        UIView *p = v.superview;
        if (stackClass && [p isKindOfClass:stackClass]) {
            if ([p respondsToSelector:@selector(removeArrangedSubview:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [p performSelector:@selector(removeArrangedSubview:) withObject:v];
#pragma clang diagnostic pop
            }
            [v removeFromSuperview];
            return;
        }
        if (p.subviews.count >= 2U) {
            [v removeFromSuperview];
            return;
        }
        v = p;
    }
    if (v.superview == ufiRoot && ufiRoot.subviews.count >= 2U) {
        [v removeFromSuperview];
    }
}

/// `_lazyRepostCountButton` is often a non-`UIView` wrapper; the real subtree is under ivar `_view`.
static UIView *theta_sundialLazyRepostCountInnerView(id lazyRepostCountButton) {
    if (!lazyRepostCountButton) {
        return nil;
    }
    @try {
        id inner = [lazyRepostCountButton valueForKey:@"_view"];
        if ([inner isKindOfClass:[UIView class]]) {
            return (UIView *)inner;
        }
    } @catch (__unused NSException *e) {
    }
    if ([lazyRepostCountButton isKindOfClass:[UIView class]]) {
        return (UIView *)lazyRepostCountButton;
    }
    return nil;
}

/// Count is often a *separate* horizontal stack item from the main repost control — detach both.
static void theta_sundialStripLazyRepostCountIfPresent(UIView *ufi) {
    if (!ufi) {
        return;
    }
    id lazyCount = nil;
    @try {
        lazyCount = [ufi valueForKey:@"_lazyRepostCountButton"];
    } @catch (__unused NSException *e) {
    }
    UIView *lazyInner = theta_sundialLazyRepostCountInnerView(lazyCount);
    if (lazyInner && [lazyInner isDescendantOfView:ufi]) {
        theta_sundialDetachRepostUFISlot(lazyInner, ufi);
    }
}

static void theta_sundialHideRepostControls(UIView *ufi) {
    id repost = nil;
    id lazyCount = nil;
    @try {
        repost = [ufi valueForKey:@"_repostButton"];
    } @catch (__unused NSException *e) {
    }
    @try {
        lazyCount = [ufi valueForKey:@"_lazyRepostCountButton"];
    } @catch (__unused NSException *e) {
    }

    if ([repost isKindOfClass:[UIView class]] && [(UIView *)repost isDescendantOfView:ufi]) {
        theta_sundialDetachRepostUFISlot((UIView *)repost, ufi);
    }

    @try {
        lazyCount = [ufi valueForKey:@"_lazyRepostCountButton"];
    } @catch (__unused NSException *e) {
    }
    {
        UIView *lazyInner = theta_sundialLazyRepostCountInnerView(lazyCount);
        if (lazyInner && [lazyInner isDescendantOfView:ufi]) {
            theta_sundialDetachRepostUFISlot(lazyInner, ufi);
        }
    }

    @try {
        id lazyBtn = [ufi valueForKey:@"_lazyRepostCountButton"];
        UIView *inner = theta_sundialLazyRepostCountInnerView(lazyBtn);
        if (inner) {
            inner.hidden = YES;
            inner.alpha = 0;
            inner.userInteractionEnabled = NO;
            [inner removeFromSuperview];
        }
    } @catch (__unused NSException *inner) {
    }
    @try {
        id v = [ufi valueForKey:@"_repostButton"];
        if ([v isKindOfClass:[UIView class]]) {
            UIView *uv = (UIView *)v;
            uv.hidden = YES;
            uv.alpha = 0;
            uv.userInteractionEnabled = NO;
            [uv removeFromSuperview];
        }
    } @catch (__unused NSException *inner) {
    }

    SEL invSel = @selector(invalidateIntrinsicContentSize);
    if ([ufi respondsToSelector:invSel]) {
        ((void (*)(id, SEL))objc_msgSend)(ufi, invSel);
    }
    [ufi setNeedsLayout];
    [ufi layoutIfNeeded];
}

static void (*orig_sundialUFILayoutSubviews)(id self, SEL _cmd);
static void hook_sundialUFILayoutSubviews(id self, SEL _cmd) {
    orig_sundialUFILayoutSubviews(self, _cmd);
    if (!ENABLED(@"Hide Repost Button")) {
        return;
    }
    @try {
        theta_sundialStripLazyRepostCountIfPresent((UIView *)self);
    } @catch (__unused NSException *e) {
    }
}

static void (*orig_sundialViewerVerticalUFI)(IGSundialViewerVerticalUFI *self, SEL _cmd, IGSundialViewerUFIViewModel *viewModel);
static void hook_sundialViewerVerticalUFI(IGSundialViewerVerticalUFI *self, SEL _cmd, IGSundialViewerUFIViewModel *viewModel) {
    orig_sundialViewerVerticalUFI(self, _cmd, viewModel);

    if (ENABLED(@"Hide Repost Button")) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            IGSundialViewerVerticalUFI *ufi = weakSelf;
            if (!ufi) {
                return;
            }
            @try {
                // Do not use setValue:forKey: on ivars — can crash. Detach whole stack slot to avoid empty gap.
                theta_sundialHideRepostControls(ufi);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    IGSundialViewerVerticalUFI *again = weakSelf;
                    if (!again) {
                        return;
                    }
                    theta_sundialHideRepostControls(again);
                });
            } @catch (NSException *exception) {
                NSLog(@"Error hiding repost button: %@", exception);
            }
        });
    }

    @try {
        if (ENABLED(@"Save Media")) {
            if ([self viewWithTag:999] != nil) {
				return;
			}

			UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
			downloadButton.tag = 999;
			[downloadButton setTintColor:UIColor.labelColor];
			[downloadButton setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
			[downloadButton setTranslatesAutoresizingMaskIntoConstraints:false];
			downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
			downloadButton.layer.shadowOpacity = 0.4;
			downloadButton.layer.shadowOffset = CGSizeMake(-2, 0);
			downloadButton.layer.shadowRadius = 3;
			downloadButton.layer.masksToBounds = NO;

			ThetaSetCaptureHiding(downloadButton);
			[self addSubview:downloadButton];
            __weak typeof(self) weakSelf = self;
            [downloadButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
                [ThetaHelper performHapticFeedbackIfEnabled];
                downloadSundialMedia(weakSelf);
            }] forControlEvents:UIControlEventTouchUpInside];

			if ([self respondsToSelector:@selector(ufiLikeButton)]) {
				[NSLayoutConstraint activateConstraints:@[
					[downloadButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
					[downloadButton.bottomAnchor constraintEqualToAnchor:self.ufiLikeButton.topAnchor constant:15],
					[downloadButton.widthAnchor constraintEqualToConstant:44],
					[downloadButton.heightAnchor constraintEqualToConstant:44],
				]];
			} else if ([self respondsToSelector:@selector(likeButton)]) {

				UIButton *likeButton = [self valueForKey:@"likeButton"];

				[NSLayoutConstraint activateConstraints:@[
					[downloadButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
					[downloadButton.bottomAnchor constraintEqualToAnchor:likeButton.topAnchor],
					[downloadButton.widthAnchor constraintEqualToConstant:44],
					[downloadButton.heightAnchor constraintEqualToConstant:44],
				]];
			}
        }
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

void THRegisterSavePostHook(void) {
    NullHookMessageIfPresent(objc_getClass("IGUFIInteractionCountsView"), @selector(layoutSubviews), (void *)hook_savePost, &orig_savePost);
}

void THRegisterSundialViewerUFIHooks(void) {
    Class ufiClass = ThetaFirstClass(@[
        @"_TtC26IGSundialViewerVerticalUFI26IGSundialViewerVerticalUFI",
        @"IGSundialViewerVerticalUFI"
    ]);
    NullHookMessageIfPresent(ufiClass, @selector(configureWithViewModel:), (void *)hook_sundialViewerVerticalUFI, &orig_sundialViewerVerticalUFI);
    NullHookMessageIfPresent(ufiClass, @selector(layoutSubviews), (void *)hook_sundialUFILayoutSubviews, &orig_sundialUFILayoutSubviews);
}