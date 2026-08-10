#import <objc/runtime.h>
#import "Include/ThetaHelper.h"
// Forward declaration of the BlockTarget category method from StoryGhost.m
@interface UIGestureRecognizer (BlockTarget)
- (void)addActionBlock:(void (^)(UIGestureRecognizer *sender))block;
@end

// Marker to ensure we only add our long press once per view
static char kThetaProfilePicLongPressKey;
static char kThetaProfilePicLongPressDelegateKey;

@interface ThetaGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation ThetaGestureDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
	return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
	return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
	return NO;
}
@end

static void (*orig_saveProfilePictures)(id self, SEL _cmd);
static void hook_saveProfilePictures(id self, SEL _cmd) {
    orig_saveProfilePictures(self, _cmd);

    if (ENABLED(@"Save Profile Pictures") || ENABLED(@"Fullscreen Profile Pictures")) {
		NSURL *imageURL = nil;
		@try {
			id imageView = [self valueForKey:@"_imageView"];
			if (imageView) {
				@try {
					id imageSpecifier = [imageView valueForKey:@"imageSpecifier"];
					if (imageSpecifier) {
						id urlValue = [imageSpecifier valueForKey:@"url"];
						if ([urlValue isKindOfClass:[NSURL class]]) {
							imageURL = (NSURL *)urlValue;
						} else if ([urlValue isKindOfClass:[NSString class]]) {
							imageURL = [NSURL URLWithString:(NSString *)urlValue];
						}
					}
				} @catch (NSException *exception) {
					// fall through to other strategies
				}
				
				if (!imageURL) {
					@try {
						imageURL = [imageView valueForKey:@"_imageURL"];
					} @catch (NSException *exception) {
						@try {
							imageURL = [imageView valueForKey:@"imageURL"];
						} @catch (NSException *exception) {
							@try {
								imageURL = [imageView valueForKey:@"_url"];
							} @catch (NSException *exception) {
								// no-op
							}
						}
					}
				}
			}
		} @catch (NSException *exception) {
			NSLog(@"Failed to resolve profile image URL: %@", exception);
		}
        
        NSMutableArray *actions = [NSMutableArray array];
        if (ENABLED(@"Save Profile Pictures")) {
            [actions addObject:@{
                @"title": @"Save",
				@"handler": ^{
					@try {
						if (imageURL) {
							NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
							if (saveMethod == 0) {
								PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
								if (status == PHAuthorizationStatusNotDetermined) {
									[PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authorizationStatus) {
										if (authorizationStatus == PHAuthorizationStatusAuthorized) {
											performProfilePictureDownloadWithURL(imageURL);
										} else {
											dispatch_async(dispatch_get_main_queue(), ^{
												if (ENABLED(@"Show Banners")) {
													[ThetaHelper showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
												}
											});
										}
									}];
								} else if (status == PHAuthorizationStatusAuthorized) {
									performProfilePictureDownloadWithURL(imageURL);
								} else {
									dispatch_async(dispatch_get_main_queue(), ^{
										if (ENABLED(@"Show Banners")) {
											[ThetaHelper showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
										}
									});
								}
							} else {
								performProfilePictureDownloadWithURL(imageURL);
							}
						} else {
							[ThetaHelper showCustomAlertWithActions:@"Profile Picture" description:@"Couldn't find the profile image URL." actions:@[@{ @"title": @"OK", @"handler": ^{ /* no-op */ } }]];
						}
					} @catch (NSException *exception) {
						NSLog(@"Error downloading profile picture: %@", exception);
					}
				}
            }];
        }
        if (ENABLED(@"Fullscreen Profile Pictures")) {
            [actions addObject:@{
                @"title": @"Fullscreen",
				@"handler": ^{
					@try {
						if (imageURL) {
							dispatch_async(dispatch_get_main_queue(), ^{
								MediaViewController *mediaVC = [MediaViewController new];
								[mediaVC initWithMediaURL:imageURL];
								mediaVC.modalPresentationStyle = UIModalPresentationFullScreen;
								[[ThetaHelper topViewController] presentViewController:mediaVC animated:YES completion:nil];
							});
						} else {
							[ThetaHelper showCustomAlertWithActions:@"Profile Picture" description:@"Couldn't find the profile image URL." actions:@[@{ @"title": @"OK", @"handler": ^{ /* no-op */ } }]];
						}
					} @catch (NSException *exception) {
						NSLog(@"Error presenting fullscreen profile picture: %@", exception);
					}
				}
            }];
        }
        [actions addObject:@{
            @"title": @"Cancel",
			@"handler": ^{
            }
        }];
        [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!" description:@"What would you like to do with this profile picture?" actions:actions];
    }
}

static void performProfilePictureDownloadWithURL(NSURL *imageURL) {
    @autoreleasepool {
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:imageURL completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error downloading profile picture: %@", error);
                return;
            }

            NSError *moveError;
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *newFilename = [NSString stringWithFormat:@"profile-%@.jpg", [[NSUUID UUID] UUIDString]];
            NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
            
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&moveError];
            if (moveError) {
                NSLog(@"Error moving downloaded file: %@", moveError);
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                if (saveMethod == 0) {
                    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                        [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                    } completionHandler:^(BOOL success, NSError *error) {
                        if (!success) {
                            NSLog(@"Error saving profile picture: %@", error);
                        }

                        // Clean up temporary file after photo library save
                        NSError *deleteError;
                        [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:&deleteError];
                        if (deleteError) {
                            NSLog(@"Error deleting temporary file: %@", deleteError);
                        }

                        if (success && ENABLED(@"Show Banners")) {
                            [ThetaHelper showToastWithTitle:@"Profile picture saved!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        }
                    }];
                } else {
                    // Local folder mode: move into Documents/AudioNotes
                    NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                    BOOL isDir = NO;
                    if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                        [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[permanentFilePath lastPathComponent]];
                    NSError *moveErr = nil;
                    if (![[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:&moveErr]) {
                        NSString *unique = [NSString stringWithFormat:@"profile-%@.jpg", [[NSUUID UUID] UUIDString]];
                        destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                        [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
                    }
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Profile picture saved!" subtitle:@"Saved to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:nil];
                    }
                }
            });
        }];
        [downloadTask resume];
    }
}

void THRegisterSaveProfilePicturesHooks(void) {
    NullHookMessageEx(objc_getClass("IGProfilePictureImageView"), @selector(buttonDidReceiveTouchDown), (void *)hook_saveProfilePictures, &orig_saveProfilePictures);
}
