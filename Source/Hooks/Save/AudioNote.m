#import <objc/runtime.h>
#import "Include/ThetaDashManifest.h"

// UIView category for finding nearest view controller
@interface UIView (FindNearestViewController)
- (UIViewController *)findNearestViewController;
@end

@implementation UIView (FindNearestViewController)
- (UIViewController *)findNearestViewController {
    // Find the nearest view controller by traversing up the responder chain
    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = [responder nextResponder];
    }
    return (UIViewController *)responder;
}
@end

// Download delegate for progress tracking
@interface AudioDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, weak) CustomToastView *progressToast;
@property (nonatomic, strong) NSString *audioURL;
@end

@implementation AudioDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (totalBytesExpectedToWrite > 0 && self.progressToast) {
            double progress = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
            int percentage = (int)(progress * 100);
            
            [self.progressToast updateProgressWithTitle:@"Downloading Audio" 
                                               subtitle:[NSString stringWithFormat:@"%d%%", percentage]];
        }
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    // This method is called automatically, completion handler in the download task will handle the file processing
}

@end

static void (*orig_saveNoteAudio)(id self, SEL _cmd);
static void hook_saveNoteAudio(id self, SEL _cmd) {
    if (orig_saveNoteAudio) orig_saveNoteAudio(self, _cmd);

    if (ENABLED(@"Save Audio Notes")) {
        // Check if gesture recognizer already exists to avoid adding multiple
        BOOL hasLongPressGesture = NO;
        for (UIGestureRecognizer *recognizer in [self gestureRecognizers]) {
            if ([recognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
                hasLongPressGesture = YES;
                break;
            }
        }
        
        if (!hasLongPressGesture) {
            // Ensure the view can receive touch events
            UIView *view = (UIView *)self;
            view.userInteractionEnabled = YES;
            
            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] init];
            longPress.minimumPressDuration = 0.5;
            longPress.numberOfTouchesRequired = 1;
            longPress.cancelsTouchesInView = NO; // Allow other gestures to work
            
            // Use block-based approach
            [longPress addActionBlock:^(UIGestureRecognizer *recognizer) {
                if (((UILongPressGestureRecognizer *)recognizer).state == UIGestureRecognizerStateBegan) {
                    UIView *pressedView = recognizer.view;
                    
                    // Get music info and extract audio URL
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        @try {
                            Ivar musicInfo = class_getInstanceVariable([pressedView class], "_musicInfo");
            if (musicInfo) {
                                id musicInfoValue = object_getIvar(pressedView, musicInfo);
                                if (musicInfoValue) {
                id musicAssets = [musicInfoValue performSelector:@selector(musicAssetInfo)];
                if (musicAssets) {
                    NSString *xml = [musicAssets performSelector:@selector(dashManifest)];
                                        if (xml && xml.length > 0) {
                        NSString *audioURL = IGDashManifestBestAudioURL(xml);
                                            if (audioURL && audioURL.length > 0) {
                                                // Show confirmation dialog
                                                NSArray *actions = @[
                                                    @{ @"title": @"Yes, Save Audio", @"handler": ^{ 
                                                        // Show progress toast
                                                        CustomToastView *progressToast = [CustomToastView showProgressToastWithTitle:@"Downloading Audio" 
                                                                                                                            subtitle:@"0%"];
                                                        
                                                        // Create delegate for progress tracking
                                                        AudioDownloadDelegate *delegate = [[AudioDownloadDelegate alloc] init];
                                                        delegate.progressToast = progressToast;
                                                        delegate.audioURL = audioURL;
                                                        
                                                        // Download audio with progress tracking
                                                        NSURL *url = [NSURL URLWithString:audioURL];
                                                        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
                                                        NSURLSession *session = [NSURLSession sessionWithConfiguration:config 
                                                                                                            delegate:delegate 
                                                                                                        delegateQueue:[NSOperationQueue mainQueue]];
                                                        
                                                        NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url 
                                                                                                            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                                if (error) {
                                                                    NSLog(@"Download failed: %@", error.localizedDescription);
                                                                    [progressToast completeProgressWithTitle:@"Download Failed" 
                                                                                                    subtitle:error.localizedDescription 
                                                                                                        icon:[UIImage systemImageNamed:@"xmark.circle.fill"] 
                                                                                                        url:nil];
                                                                    [progressToast hideAfter:3.0];
                                                                    return;
                                                                }
                                                                
                                                                if (!location) {
                                                                    NSLog(@"No download location provided");
                                                                    [progressToast completeProgressWithTitle:@"Download Failed" 
                                                                                                    subtitle:@"No data received" 
                                                                                                        icon:[UIImage systemImageNamed:@"xmark.circle.fill"] 
                                                                                                        url:nil];
                                                                    [progressToast hideAfter:3.0];
                                                                    return;
                                                                }
                                                                
                                                                // Read downloaded data
                                                                NSData *data = [NSData dataWithContentsOfURL:location];
                                                                if (!data) {
                                                                    NSLog(@"Failed to read downloaded data");
                                                                    [progressToast completeProgressWithTitle:@"Download Failed" 
                                                                                                    subtitle:@"Failed to read downloaded data" 
                                                                                                        icon:[UIImage systemImageNamed:@"xmark.circle.fill"] 
                                                                                                        url:nil];
                                                                    [progressToast hideAfter:3.0];
                                                                    return;
                                                                }
                                                                
                                                                // Determine file extension based on URL or audio format
                                                                NSString *extension = @"aac"; // Default to AAC
                                                                NSString *urlString = audioURL.lowercaseString;
                                                                
                                                                if ([urlString containsString:@"mp3"] || [urlString containsString:@"mpeg"]) {
                                                                    extension = @"mp3";
                                                                } else if ([urlString containsString:@"aac"] || [urlString containsString:@"mp4a"]) {
                                                                    extension = @"aac";
                                                                } else {
                                                                    // Try to detect format from data headers
                                                                    const unsigned char *bytes = (const unsigned char *)[data bytes];
                                                                    if (data.length >= 4) {
                                                                        // Check for MP3 header (ID3 tag or frame sync)
                                                                        if ((bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) || // MPEG frame sync
                                                                            (bytes[0] == 'I' && bytes[1] == 'D' && bytes[2] == '3')) { // ID3 tag
                                                                            extension = @"mp3";
                                                                        }
                                                                        // AAC files often start with specific patterns
                                                                        else if (data.length >= 7 && bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0) {
                                                                            extension = @"aac";
                                                                        }
                                                                    }
                                                                }
                                                                
                                                                // Generate filename with timestamp
                                                                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                                                                [formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
                                                                NSString *timestamp = [formatter stringFromDate:[NSDate date]];
                                                                NSString *filename = [NSString stringWithFormat:@"AudioNote_%@.%@", timestamp, extension];
                                                                
                                                                // Get user name for folder organization
                                                                NSString *userFolderName = @"Unknown User";
                                                                UIViewController *nearestVC = [pressedView findNearestViewController];
                                                                if (nearestVC) {
                                                                    @try {
                                                                        Ivar replyToUserIvar = class_getInstanceVariable([nearestVC class], "_replyToUser");
                                                                        if (replyToUserIvar) {
                                                                            id replyToUser = object_getIvar(nearestVC, replyToUserIvar);
                                                                            if (replyToUser) {
                                                                                NSString *userName = [replyToUser performSelector:@selector(name)];
                                                                                if (userName && userName.length > 0) {
                                                                                    userFolderName = userName;
                                                                                }
                                                                            }
                                                                        }
                                                                    } @catch (NSException *exception) {
                                                                        NSLog(@"Exception getting user name: %@", exception.reason);
                                                                        // Keep default "Unknown User" folder name
                                                                    }
                                                                }
                                                                
                                                                // Create AudioNotes directory if it doesn't exist
                                                                NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                                                                NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                                                                
                                                                // Create user-specific subfolder
                                                                NSString *userFolderPath = [audioNotesDir stringByAppendingPathComponent:userFolderName];
                                                                
                                                                NSFileManager *fileManager = [NSFileManager defaultManager];
                                                                BOOL isDirectory;
                                                                BOOL dirExists = [fileManager fileExistsAtPath:audioNotesDir isDirectory:&isDirectory];
                                                                
                                                                if (!dirExists || !isDirectory) {
                                                                    NSError *createDirError = nil;
                                                                    BOOL dirCreated = [fileManager createDirectoryAtPath:audioNotesDir 
                                                                                            withIntermediateDirectories:YES 
                                                                                                            attributes:nil 
                                                                                                                    error:&createDirError];
                                                                    if (!dirCreated) {
                                                                        NSLog(@"Failed to create AudioNotes directory: %@", createDirError.localizedDescription);
                                                                        [progressToast completeProgressWithTitle:@"Save Failed" 
                                                                                                        subtitle:@"Failed to create AudioNotes folder" 
                                                                                                            icon:[UIImage systemImageNamed:@"xmark.circle.fill"] 
                                                                                                            url:nil];
                                                                        [progressToast hideAfter:3.0];
                                                                        return;
                                                                    }
                                                                    NSLog(@"Created AudioNotes directory at: %@", audioNotesDir);
                                                                }
                                                                
                                                                // Create user subfolder if it doesn't exist
                                                                BOOL userDirExists = [fileManager fileExistsAtPath:userFolderPath isDirectory:&isDirectory];
                                                                if (!userDirExists || !isDirectory) {
                                                                    NSError *createUserDirError = nil;
                                                                    BOOL userDirCreated = [fileManager createDirectoryAtPath:userFolderPath 
                                                                                            withIntermediateDirectories:YES 
                                                                                                            attributes:nil 
                                                                                                                    error:&createUserDirError];
                                                                    if (!userDirCreated) {
                                                                        NSLog(@"Failed to create user directory: %@", createUserDirError.localizedDescription);
                                                                        [progressToast completeProgressWithTitle:@"Save Failed" 
                                                                                                        subtitle:@"Failed to create user folder" 
                                                                                                            icon:[UIImage systemImageNamed:@"xmark.circle.fill"] 
                                                                                                            url:nil];
                                                                        [progressToast hideAfter:3.0];
                                                                        return;
                                                                    }
                                                                    NSLog(@"Created user directory at: %@", userFolderPath);
                                                                }
                                                                
                                                                NSString *filePath = [userFolderPath stringByAppendingPathComponent:filename];
                                                                
                                                                // Save the file
                                                                BOOL success = [data writeToFile:filePath atomically:YES];
                                                                
                                                                if (success) {
                                                                    // Show success completion
                                                                    [progressToast completeProgressWithTitle:@"Audio Downloaded!" 
                                                                                                    subtitle:[NSString stringWithFormat:@"Audio saved to your device."] 
                                                                                                        icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] 
                                                                                                        url:nil];
                                                                    [progressToast hideAfter:3.0];
                                                                } else {
                                                                    NSLog(@"Failed to save audio file to: %@", filePath);
                                                                    [progressToast completeProgressWithTitle:@"Save Failed" 
                                                                                                    subtitle:@"Failed to save audio file" 
                                                                                                        icon:[UIImage systemImageNamed:@"xmark.circle.fill"] 
                                                                                                        url:nil];
                                                                    [progressToast hideAfter:3.0];
                                                                }
                                                            });
                                                        }];
                                                        
                                                        [downloadTask resume];
                                                    }},
                                                    @{ @"title": @"Cancel", @"handler": ^{ /* do nothing */ }}
                                                ];
                                                [ThetaHelper showCustomAlertWithActions:@"Save Audio Note" 
                                                                            description:@"Would you like to save this audio note to your device?"
                                                                                actions:actions];
                                            } else {
                                                NSLog(@"No audio URL found in manifest");
                                                NSArray *actions = @[@{ @"title": @"OK", @"handler": ^{ /* do nothing */ }}];
                                                [ThetaHelper showCustomAlertWithActions:@"Audio Note" 
                                                                            description:@"No audio URL found in manifest"
                                                                                actions:actions];
                                            }
                                        } else {
                                            NSLog(@"No dash manifest found");
                                            NSArray *actions = @[@{ @"title": @"OK", @"handler": ^{ /* do nothing */ }}];
                                            [ThetaHelper showCustomAlertWithActions:@"Audio Note" 
                                                                        description:@"No dash manifest found"
                                                                            actions:actions];
                                        }
                                    } else {
                                        NSLog(@"No music assets found");
                                        NSArray *actions = @[@{ @"title": @"OK", @"handler": ^{ /* do nothing */ }}];
                                        [ThetaHelper showCustomAlertWithActions:@"Audio Note" 
                                                                    description:@"No music assets found"
                                                                        actions:actions];
                                    }
                                } else {
                                    NSLog(@"No music info value found");
                                    NSArray *actions = @[@{ @"title": @"OK", @"handler": ^{ /* do nothing */ }}];
                                    [ThetaHelper showCustomAlertWithActions:@"Audio Note" 
                                                                description:@"No music info value found"
                                                                    actions:actions];
                                }
                            } else {
                                NSLog(@"No music info ivar found");
                                NSArray *actions = @[@{ @"title": @"OK", @"handler": ^{ /* do nothing */ }}];
                                [ThetaHelper showCustomAlertWithActions:@"Audio Note" 
                                                            description:@"No music info ivar found"
                                                                actions:actions];
                            }
                        } @catch (NSException *exception) {
                            NSLog(@"Exception in long press handler: %@", exception.reason);
                            NSArray *actions = @[@{ @"title": @"OK", @"handler": ^{ /* do nothing */ }}];
                            [ThetaHelper showCustomAlertWithActions:@"Audio Note Error" 
                                                        description:[NSString stringWithFormat:@"Exception: %@", exception.reason]
                                                            actions:actions];
                        }
                    });
                }
            }];
            
            [self addGestureRecognizer:longPress];
        }
    }
}

void THRegisterSaveAudioNotesHooks(void) {
    SEL layout = @selector(layoutSubviews);
    NSArray<NSString *> *classes = @[
        @"IGMusicStickerAudioIndicatorView",
        @"IGVinylMusicSticker",
        @"IGSmallAlbumArtMusicSticker",
    ];
    for (NSString *name in classes) {
        NullHookMessageIfPresent(NSClassFromString(name), layout, (void *)hook_saveNoteAudio, (void **)&orig_saveNoteAudio);
    }
}