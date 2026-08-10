static void (*orig_audioMessage)(id self, SEL _cmd, id audio, CGFloat progress, id assetId, id offlineAssetId, NSInteger messageProductType, id threadKey);
static char theta_audio_url_key;
static void hook_audioMessage(id self, SEL _cmd, id audio, CGFloat progress, id assetId, id offlineAssetId, NSInteger messageProductType, id threadKey) {
    orig_audioMessage(self, _cmd, audio, progress, assetId, offlineAssetId, messageProductType, threadKey);

    @try {
        if (ENABLED(@"Save Audio Messages")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                id serverAudio = nil;
                Ivar iv = class_getInstanceVariable([audio class], "_server_audio");
                if (iv) {
                    serverAudio = object_getIvar(audio, iv);
                } else {
                    @try { serverAudio = [audio valueForKey:@"_server_audio"]; } @catch (__unused NSException *e) {}
                }

                if (serverAudio) {
                    NSURL *url = nil;
                    if ([serverAudio respondsToSelector:@selector(playbackURL)]) {
                        url = ((NSURL *(*)(id, SEL))objc_msgSend)(serverAudio, @selector(playbackURL));
                    } else {
                        @try { url = [serverAudio valueForKey:@"playbackURL"]; } @catch (__unused NSException *e) {}
                    }
                    if (url) {
                        objc_setAssociatedObject(self, &theta_audio_url_key, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                }
            });
        }
    } @catch (NSException *exception) {
        NSLog(@"Error saving audio message: %@", exception);
    }
}

static void (*orig_audioPlayerDidPlayToEnd)(id self, SEL _cmd, id arg1);
static void hook_audioPlayerDidPlayToEnd(id self, SEL _cmd, id arg1) {
    orig_audioPlayerDidPlayToEnd(self, _cmd, arg1);
    
    if (ENABLED(@"Save Audio Messages")) {
        NSURL *url = objc_getAssociatedObject(self, &theta_audio_url_key);
        if (url) {
            [ThetaHelper showCustomAlertWithActions:@"Audio Message Download Confirmation" description:@"Would you like to download the audio from this message?" actions:@[
                @{
                    @"title": @"Yes, download it!",
                    @"handler": ^(id sender) {
                        MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] init];
                        if (mediaSelectionVC) {
                            [mediaSelectionVC performDownloadToAudioNotesWithURL:url completion:^(NSString *filePath, NSString *fileExtension){
                                if (!filePath) {
                                    [ThetaHelper showToastWithTitle:@"Audio Download Failed" subtitle:@"The audio download failed." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                                    return;
                                }

                                if (fileExtension && [[fileExtension lowercaseString] isEqualToString:@"mp3"]) {
                                    [ThetaHelper showToastWithTitle:@"Audio Downloaded" subtitle:@"Saved to Documents/AudioNotes as MP3" icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:2 openURL:nil];
                                    return;
                                }

                                [mediaSelectionVC convertFileToMP3:filePath completion:^(NSString *outputPath, NSError *error) {
                                    if (outputPath) {
                                        NSString *ext = [[outputPath pathExtension] lowercaseString];
                                        BOOL isMP3 = [ext isEqualToString:@"mp3"];
                                        [ThetaHelper showToastWithTitle:@"Audio Downloaded" subtitle:@"Saved audio to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:2 openURL:nil];

                                        // clear theta_audio_url_key
                                        objc_setAssociatedObject(self, &theta_audio_url_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                    } else {
                                        NSLog(@"MP3 convert error: %@", error);
                                        [ThetaHelper showToastWithTitle:@"Audio Conversion Failed" subtitle:@"Could not convert to MP3." icon:[UIImage systemImageNamed:@"xmark.circle.fill"] autoHide:2 openURL:nil];
                                    }
                                }];
                            }];
                        }
                    }
                },
                @{
                    @"title": @"No, I'm good.",
                    @"handler": ^(id sender) {
                    }
                }
            ]];
        }
    }
}

void THRegisterSaveAudioMessageHooks(void) {
    Class player = objc_getClass("IGDirectAudioPlayer");
    // IG renamed progress: → progressInSeconds:
    ThetaHookFirst(
        @[ @"IGDirectAudioPlayer" ],
        @[ @"playWithAudio:progressInSeconds:assetId:offlineAssetId:messageProductType:threadKey:",
           @"playWithAudio:progress:assetId:offlineAssetId:messageProductType:threadKey:" ],
        (void *)hook_audioMessage, &orig_audioMessage);
    NullHookMessageIfPresent(player, @selector(audioPlayerDidPlayToEnd:), (void *)hook_audioPlayerDidPlayToEnd, &orig_audioPlayerDidPlayToEnd);
}