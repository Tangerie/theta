#import "Include/ThetaHelper.h"
#import <Photos/Photos.h>

// UIButton(BlockTarget) is implemented in StoryGhost.m (later in amalgamation); declare so CommentTextCopy can compile first.
@interface UIButton (BlockTarget)
- (void)handleControlEvent:(UIControlEvents)event withBlock:(void (^)(id sender))block;
@end

static void copyCommentText(id self);
static NSURL *findAnimatedImageURL(id self);
static void downloadAnimatedImage(NSURL *url);
static NSString *extractGifIDFromURL(NSURL *url);

// Wrapper function to safely call downloadAnimatedImage
static void safeDownloadAnimatedImage(NSURL *url) {
    if (!url) {
        return;
    }
    
    @try {
        downloadAnimatedImage(url);
    } @catch (NSException *exception) {
        @throw; // Re-throw to be caught by outer handler
    }
}

// Helper class for button action
@interface CommentTextCopyButtonHandler : NSObject
@end

@implementation CommentTextCopyButtonHandler
- (void)copyButtonTapped:(UIButton *)sender {
    static char kCommentTextCopyButtonCellKey;
    id commentCell = objc_getAssociatedObject(sender, &kCommentTextCopyButtonCellKey);
    if (commentCell) {
        copyCommentText(commentCell);
    }
}
@end

static void copyCommentText(id self) {
    // Debounce: prevent spam calling (only allow once per 1 second)
    static NSTimeInterval lastCopyTime = 0;
    static NSString *lastCopiedText = nil;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    // Check debounce to prevent multiple executions
    if (currentTime - lastCopyTime < 1.0) {
        return;
    }

    @try {
        Class coreTextViewClass = NSClassFromString(@"IGCoreTextView");
        if (!coreTextViewClass) {
            return;
        }

        UIView *coreTextView = nil;
        UIView *view = nil;
        
        if ([self isKindOfClass:[UIView class]]) {
            view = (UIView *)self;
        } else {
            return;
        }
        
        // Check if the view is already an IGCoreTextView
        if ([view isKindOfClass:coreTextViewClass]) {
            coreTextView = view;
        } else {
            // Otherwise, search for it in the view hierarchy
            NSArray *subviews = view.subviews;
            
            if (!subviews || subviews.count == 0) {
                return;
            }

            // Find the first object with the class "IGCommentCellView.IGCommentCellContentView"
            Class contentViewClass = NSClassFromString(@"IGCommentCellView.IGCommentCellContentView");
            if (!contentViewClass) {
                return;
            }

            UIView *contentView = nil;
            for (UIView *subview in subviews) {
                if ([subview isKindOfClass:contentViewClass]) {
                    contentView = subview;
                    break;
                }
            }

            if (!contentView) {
                // If no content view found, try searching all subviews for IGCoreTextView
                for (UIView *subview in subviews) {
                    if ([subview isKindOfClass:coreTextViewClass]) {
                        coreTextView = subview;
                        break;
                    }
                }
                if (!coreTextView) {
                    return;
                }
            } else {
                // Get the subviews for the content view
                NSArray *contentSubviews = contentView.subviews;
                if (!contentSubviews || contentSubviews.count == 0) {
                    return;
                }

                // Find the object with the class "IGCoreTextView"
                for (UIView *subview in contentSubviews) {
                    if ([subview isKindOfClass:coreTextViewClass]) {
                        coreTextView = subview;
                        break;
                    }
                }

                if (!coreTextView) {
                    return;
                }
            }
        }
        
        // Get the text from IGCoreTextView and copy it to clipboard
        NSString *text = nil;
        @try {
            // Try different ways to get the text
            if ([coreTextView respondsToSelector:@selector(text)]) {
                text = [coreTextView performSelector:@selector(text)];
            } else if ([coreTextView respondsToSelector:@selector(valueForKey:)]) {
                text = [coreTextView valueForKey:@"text"];
                if (!text) {
                    text = [coreTextView valueForKey:@"attributedText"];
                    if ([text isKindOfClass:[NSAttributedString class]]) {
                        text = [(NSAttributedString *)text string];
                    }
                }
            }
        } @catch (NSException *e) {
            return;
        }

        if (!text || text.length == 0) {
            return;
        }

        // Remove the first line (username and timestamp) but keep all other text
        // Format: "username timestamp\nactual comment content\nmore content\netc"
        // OR: "username timestamp actual comment content\nmore content\netc" (no newline after timestamp)
        // We want to exclude only the username + timestamp, keep everything else including newlines
        // IMPORTANT: We must find the timestamp first, then extract everything after it,
        // because newlines can appear in the comment content itself
        NSString *commentText = text;
        
        // Use regex to find timestamp pattern first
        // Pattern: number(s) followed by letter (d, h, w, m, s, y) possibly wrapped in Unicode marks
        // Examples: "1d", "3h", "2w", "⁨1d⁩", "⁨3h⁩"
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d+[dhwmsy]|⁨\\d+[dhwmsy]⁩" options:0 error:&error];
        
        if (!error) {
            NSRange timestampRange = [regex rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
            if (timestampRange.location != NSNotFound) {
                // Found timestamp, extract everything after it (including any newlines in the content)
                NSUInteger startIndex = timestampRange.location + timestampRange.length;
                if (startIndex < text.length) {
                    commentText = [text substringFromIndex:startIndex];
                    // Only trim leading whitespace, preserve all content including newlines in the middle
                    NSCharacterSet *whitespaceSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
                    NSUInteger start = 0;
                    NSRange range = [commentText rangeOfCharacterFromSet:whitespaceSet];
                    while (range.location == start && range.location != NSNotFound) {
                        start = range.location + range.length;
                        if (start >= commentText.length) break;
                        range = [commentText rangeOfCharacterFromSet:whitespaceSet options:0 range:NSMakeRange(start, commentText.length - start)];
                    }
                    if (start > 0) {
                        commentText = [commentText substringFromIndex:start];
                    }
                }
            } else {
                // No timestamp found - try to find newline after username
                // Fallback: try to find where username ends (first space after username)
                NSRange firstSpaceRange = [text rangeOfString:@" "];
                if (firstSpaceRange.location != NSNotFound) {
                    NSString *afterUsername = [text substringFromIndex:firstSpaceRange.location + 1];
                    NSRange timestampRange2 = [regex rangeOfFirstMatchInString:afterUsername options:0 range:NSMakeRange(0, afterUsername.length)];
                    if (timestampRange2.location != NSNotFound) {
                        NSUInteger startIndex = firstSpaceRange.location + 1 + timestampRange2.location + timestampRange2.length;
                        if (startIndex < text.length) {
                            commentText = [text substringFromIndex:startIndex];
                            // Only trim leading whitespace, preserve all content including newlines
                            NSCharacterSet *whitespaceSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
                            NSUInteger start = 0;
                            NSRange range = [commentText rangeOfCharacterFromSet:whitespaceSet];
                            while (range.location == start && range.location != NSNotFound) {
                                start = range.location + range.length;
                                if (start >= commentText.length) break;
                                range = [commentText rangeOfCharacterFromSet:whitespaceSet options:0 range:NSMakeRange(start, commentText.length - start)];
                            }
                            if (start > 0) {
                                commentText = [commentText substringFromIndex:start];
                            }
                        }
                    } else {
                        // No timestamp pattern found - try to find first newline as fallback
                        NSRange newlineRange = [text rangeOfString:@"\n"];
                        if (newlineRange.location == NSNotFound) {
                            newlineRange = [text rangeOfString:@"\r\n"];
                        }
                        if (newlineRange.location == NSNotFound) {
                            newlineRange = [text rangeOfString:@"\r"];
                        }
                        if (newlineRange.location != NSNotFound) {
                            NSUInteger startIndex = newlineRange.location + newlineRange.length;
                            if (startIndex < text.length) {
                                commentText = [text substringFromIndex:startIndex];
                                // Only trim leading whitespace, preserve all content including newlines
                                NSCharacterSet *whitespaceSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
                                NSUInteger start = 0;
                                NSRange range = [commentText rangeOfCharacterFromSet:whitespaceSet];
                                while (range.location == start && range.location != NSNotFound) {
                                    start = range.location + range.length;
                                    if (start >= commentText.length) break;
                                    range = [commentText rangeOfCharacterFromSet:whitespaceSet options:0 range:NSMakeRange(start, commentText.length - start)];
                                }
                                if (start > 0) {
                                    commentText = [commentText substringFromIndex:start];
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Remove "· ⁨by author⁩" if it appears anywhere in the text (but keep everything else)
        commentText = [commentText stringByReplacingOccurrencesOfString:@"·  ⁨by author⁩" withString:@""];
        
        // Only trim trailing whitespace at the very end, don't remove newlines in the middle
        NSCharacterSet *whitespaceSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSUInteger end = commentText.length;
        while (end > 0) {
            unichar lastChar = [commentText characterAtIndex:end - 1];
            if ([whitespaceSet characterIsMember:lastChar]) {
                end--;
            } else {
                break;
            }
        }
        if (end < commentText.length) {
            commentText = [commentText substringToIndex:end];
        }
        
        // Check if extracted text is "·  ⁨by author⁩" (trimmed)
        NSString *trimmedCommentText = [commentText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL isAuthorOnly = [trimmedCommentText isEqualToString:@"·  ⁨by author⁩"];
        
        // Check for GIF/image first (if GIF found, there's no text to copy)
        NSURL *imageURL = findAnimatedImageURL(self);
        
        if (imageURL) {
            // GIF/image found - show alert with options
            NSURL *capturedURL = imageURL;
            NSString *gifID = extractGifIDFromURL(capturedURL);
            BOOL isGiphyGif = (gifID != nil);
            
            NSMutableArray *actions = [NSMutableArray array];
            
            [actions addObject:@{
                @"title": @"Copy URL",
                @"handler": ^(id sender) {
                    [UIPasteboard generalPasteboard].string = capturedURL.absoluteString;
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Copied" subtitle:@"Media URL copied to clipboard." icon:[UIImage systemImageNamed:@"doc.on.doc.fill"] autoHide:2 openURL:nil];
                    }
                }
            }];
            
            if (isGiphyGif) {
                [actions addObject:@{
                    @"title": @"Copy GIF Name",
                    @"handler": ^(id sender) {
                        NSString *capturedGifID = gifID;
                        [IGGifOverlayManager fetchGifName:capturedGifID completion:^(NSString *name) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (name && name.length > 0) {
                                    [UIPasteboard generalPasteboard].string = name;
                                    if (ENABLED(@"Show Banners")) {
                                        [ThetaHelper showToastWithTitle:@"GIF name copied" subtitle:name icon:[UIImage systemImageNamed:@"doc.on.doc.fill"] autoHide:2 openURL:nil];
                                    }
                                } else {
                                    if (ENABLED(@"Show Banners")) {
                                        [ThetaHelper showToastWithTitle:@"Failed" subtitle:@"Could not fetch GIF name." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                                    }
                                }
                            });
                        }];
                    }
                }];
            }
            
            [actions addObject:@{
                @"title": @"Download",
                @"handler": ^(id sender) {
                    NSURL *urlToDownload = [capturedURL copy];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        @try {
                            safeDownloadAnimatedImage(urlToDownload);
                        } @catch (NSException *exception) {
                            if (ENABLED(@"Show Banners")) {
                                [ThetaHelper showToastWithTitle:@"Download Failed" subtitle:[NSString stringWithFormat:@"Error: %@", exception.reason] icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                            }
                        }
                    });
                }
            }];
            
            [actions addObject:@{
                @"title": @"Cancel",
                @"handler": ^(id sender) {
                    // Do nothing
                }
            }];
            
            [ThetaHelper showCustomAlertWithActions:@"Media Found" description:@"This comment contains a GIF or image. What would you like to do?" actions:actions];
            return;
        }
        
        // No GIF/image found - check for text to copy
        // If no text or only "·  ⁨by author⁩", do nothing
        if (!commentText || commentText.length == 0 || isAuthorOnly) {
            return;
        }
        
        // Normal text copy
        if (commentText && commentText.length > 0 && ![commentText isEqualToString:lastCopiedText]) {
            lastCopiedText = commentText;
            lastCopyTime = currentTime;
            [UIPasteboard generalPasteboard].string = commentText;
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Copied" subtitle:@"Comment text copied to clipboard." icon:[UIImage systemImageNamed:@"doc.on.doc.fill"] autoHide:2 openURL:nil];
            }
        }
    } @catch (NSException *exception) {
        // Silent fail
    }
}

// Find IGAnimatedImageView in commentContentView and get its animatedImageURL
static NSURL *findAnimatedImageURL(id self) {
    @try {
        // Get commentContentView property from self
        id commentContentView = nil;
        if ([self respondsToSelector:@selector(commentContentView)]) {
            commentContentView = [self performSelector:@selector(commentContentView)];
        } else if ([self respondsToSelector:@selector(valueForKey:)]) {
            commentContentView = [self valueForKey:@"commentContentView"];
        }
        
        if (!commentContentView || ![commentContentView isKindOfClass:[UIView class]]) {
            return nil;
        }
        
        UIView *contentView = (UIView *)commentContentView;
        NSArray *subviews = contentView.subviews;
        
        if (!subviews || subviews.count == 0) {
            return nil;
        }
        
        // Find IGAnimatedImageView in subviews
        Class animatedImageViewClass = NSClassFromString(@"IGAnimatedImageView");
        if (!animatedImageViewClass) {
            return nil;
        }
        
        for (UIView *subview in subviews) {
            if ([subview isKindOfClass:animatedImageViewClass]) {
                // Get animatedImageURL property
                NSURL *imageURL = nil;
                if ([subview respondsToSelector:@selector(animatedImageURL)]) {
                    imageURL = [subview performSelector:@selector(animatedImageURL)];
                } else if ([subview respondsToSelector:@selector(valueForKey:)]) {
                    imageURL = [subview valueForKey:@"animatedImageURL"];
                }
                
                if (imageURL && [imageURL isKindOfClass:[NSURL class]]) {
                    return imageURL;
                }
            }
        }
    } @catch (NSException *exception) {
        // Silent fail
    }
    
    return nil;
}

// Extract GIF ID from Giphy URL
static NSString *extractGifIDFromURL(NSURL *url) {
    if (!url) return nil;
    
    NSString *urlString = url.absoluteString;
    if (!urlString || ![urlString containsString:@"giphy.com"]) return nil;
    
    // Giphy URLs typically have format: https://mediaX.giphy.com/media/.../GIF_ID/size.gif
    // Extract the GIF ID which is typically the second-to-last path component
    NSArray *pathComponents = url.pathComponents;
    if (pathComponents.count < 2) return nil;
    
    // Look for the GIF ID (usually alphanumeric, can be various lengths)
    // It's typically the component before the last one (which is usually "200.gif" or similar)
    // The last component is usually the size like "200.gif", so the GIF ID is second-to-last
    if (pathComponents.count >= 2) {
        NSString *lastComponent = [pathComponents lastObject];
        // Check if last component looks like a size (e.g., "200.gif", "480w.gif", etc.)
        if ([lastComponent containsString:@"."] || [lastComponent rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) {
            // Get the second-to-last component as the GIF ID
            NSString *gifID = pathComponents[pathComponents.count - 2];
            // GIF IDs are alphanumeric, typically at least 5 characters
            if (gifID && gifID.length >= 5) {
                NSCharacterSet *alphanumeric = [NSCharacterSet alphanumericCharacterSet];
                if ([gifID rangeOfCharacterFromSet:[alphanumeric invertedSet]].location == NSNotFound) {
                    return gifID;
                }
            }
        }
    }
    
    return nil;
}

// Download the animated image/GIF
static void downloadAnimatedImage(NSURL *url) {
    if (!url) {
        return;
    }
    
    @try {
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Download Failed" subtitle:@"Failed to download media." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                    }
                });
                return;
            }
            
            if (!location) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Download Failed" subtitle:@"No file location received." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                    }
                });
                return;
            }
            
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            
            // Determine file extension from URL or MIME type
            NSString *fileExtension = [[url pathExtension] lowercaseString];
            
            if (fileExtension.length == 0) {
                NSString *mime = [[response MIMEType] lowercaseString];
                if ([mime hasPrefix:@"image/gif"]) {
                    fileExtension = @"gif";
                } else if ([mime hasPrefix:@"image/"]) {
                    if ([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/jpg"]) {
                        fileExtension = @"jpg";
                    } else if ([mime isEqualToString:@"image/png"]) {
                        fileExtension = @"png";
                    } else if ([mime isEqualToString:@"image/webp"]) {
                        fileExtension = @"webp";
                    } else {
                        fileExtension = @"jpg";
                    }
                } else {
                    fileExtension = @"gif"; // Default to gif for animated images
                }
            }
            
            NSString *newFilename = [NSString stringWithFormat:@"image-%@.%@", [[NSUUID UUID] UUIDString], fileExtension];
            NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
            
            NSError *fileError;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&fileError];
            if (fileError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Download Failed" subtitle:@"Failed to save media file." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                    }
                });
                return;
            }
            
            // Verify file exists before proceeding
            if (![[NSFileManager defaultManager] fileExistsAtPath:permanentFilePath]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Download Failed" subtitle:@"File not found after download." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                    }
                });
                return;
            }
            
            NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
            
            if (saveMethod == 0) {
                // Save to camera roll - must be on main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                            NSURL *fileURL = [NSURL fileURLWithPath:permanentFilePath];
                            BOOL isGIF = [fileExtension isEqualToString:@"gif"];
                            
                            if (isGIF) {
                                // For GIFs, always use file URL to preserve animation
                                // Using creationRequestForAssetFromImage: converts GIFs to static images
                                [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL];
                            } else {
                                // For regular images, use file URL
                                [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL];
                            }
                        } completionHandler:^(BOOL success, NSError * _Nullable error) {
                            if (error) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (ENABLED(@"Show Banners")) {
                                        [ThetaHelper showToastWithTitle:@"Save Failed" subtitle:[NSString stringWithFormat:@"Failed to save to Photos: %@", error.localizedDescription] icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
                                    }
                                });
                            } else if (success) {
                                // Clean up temp file after saving to Photos
                                [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:nil];
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (ENABLED(@"Show Banners")) {
                                        [ThetaHelper showToastWithTitle:@"Saved to Camera Roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:2 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                                    }
                                });
                            }
                        }];
                    } @catch (NSException *exception) {
                        // Silent fail
                    }
                });
            } else {
                // Local folder: move into Documents/AudioNotes
                NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                BOOL isDir = NO;
                if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                }
                NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[permanentFilePath lastPathComponent]];
                NSError *moveErr = nil;
                if (![[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:&moveErr]) {
                    NSString *unique = [NSString stringWithFormat:@"image-%@.%@", [[NSUUID UUID] UUIDString], fileExtension];
                    destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                    [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Saved" subtitle:@"Media saved to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:2 openURL:nil];
                    }
                });
            }
        }];
        
        [downloadTask resume];
    } @catch (NSException *exception) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Download Failed" subtitle:[NSString stringWithFormat:@"Error: %@", exception.reason] icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:2 openURL:nil];
            }
        });
    }
}

static void (*orig_copyCommentText)(id self, SEL _cmd);
static void hook_copyCommentText(id self, SEL _cmd) {
    orig_copyCommentText(self, _cmd);

    if (!ENABLED(@"Comment Options")) {
        return;
    }

    if (![self isKindOfClass:[UIView class]]) {
        return;
    }

    @try {
        // First, check subviews to count UIButton objects
        UIView *selfView = (UIView *)self;
        NSArray *subviews = selfView.subviews;
        NSMutableArray *buttonSubviews = [NSMutableArray array];
        
        for (UIView *subview in subviews) {
            if ([subview isKindOfClass:[UIButton class]]) {
                [buttonSubviews addObject:subview];
            }
        }
        
        // Find the replyButton property
        UIButton *replyButton = nil;
        if ([self respondsToSelector:@selector(replyButton)]) {
            replyButton = [self performSelector:@selector(replyButton)];
        } else if ([self respondsToSelector:@selector(valueForKey:)]) {
            replyButton = [self valueForKey:@"replyButton"];
        }
        
        if (!replyButton || ![replyButton isKindOfClass:[UIButton class]]) {
            return;
        }
        
        // Determine which button to position relative to
        UIButton *referenceButton = replyButton;
        BOOL hasTranslationButton = (buttonSubviews.count >= 2);
        
        if (hasTranslationButton) {
            // Find the translation button by accessibility label
            for (UIButton *button in buttonSubviews) {
                if ([button.accessibilityLabel isEqualToString:@"Toggle the translation for this comment"]) {
                    referenceButton = button;
                    break;
                }
            }
        }
        
        // Check if copyButton already exists
        static char kCommentTextCopyButtonKey;
        UIButton *existingCopyButton = objc_getAssociatedObject(self, &kCommentTextCopyButtonKey);
        if (existingCopyButton && existingCopyButton.superview) {
            // Update position in case reference button moved
            CGRect referenceFrame = referenceButton.frame;
            CGRect copyFrame = existingCopyButton.frame;
            copyFrame.origin.y = referenceFrame.origin.y - 4; // Move up 4px
            copyFrame.origin.x = referenceFrame.origin.x + referenceFrame.size.width + 15 - 6; // 15px spacing to the right, then left 6px
            existingCopyButton.frame = copyFrame;
            return; // Button already added
        }
        
        // Create copy button based on reference button (reply or translation)
        UIButton *copyButton = [UIButton buttonWithType:referenceButton.buttonType];
        copyButton.frame = referenceButton.frame;
        
        // Set button text + attributes to match the screenshot
        BOOL hasMedia = (findAnimatedImageURL(self) != nil);
        NSString *buttonTitle = hasMedia ? @"Options" : @"Copy";
        UIFont *optionsFont = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        UIColor *optionsColor = [UIColor colorWithRed:0.635 green:0.667 blue:0.706 alpha:1.0];
        NSDictionary *optionsAttributes = @{
            NSFontAttributeName: optionsFont,
            NSForegroundColorAttributeName: optionsColor
        };
        NSAttributedString *optionsTitle = [[NSAttributedString alloc] initWithString:buttonTitle
                                                                           attributes:optionsAttributes];
        [copyButton setAttributedTitle:optionsTitle forState:UIControlStateNormal];
        [copyButton setAttributedTitle:optionsTitle forState:UIControlStateHighlighted];
        copyButton.titleLabel.font = optionsFont;
        
        // Size the button to fit the text
        [copyButton sizeToFit];
        
        // Position it directly to the right of the reference button with 15px spacing
        // Then adjust: move up 4px and left 6px
        CGRect referenceFrame = referenceButton.frame;
        CGRect copyFrame = copyButton.frame;
        copyFrame.origin.y = referenceFrame.origin.y - 4; // Move up 4px
        copyFrame.origin.x = referenceFrame.origin.x + referenceFrame.size.width + 15 - 6; // 15px spacing to the right, then left 6px
        
        copyButton.frame = copyFrame;
        
        // Ensure button is enabled and visible
        copyButton.enabled = YES;
        copyButton.hidden = NO;
        copyButton.userInteractionEnabled = YES;
        
        // Store self in associated object so we can access it in the action
        static char kCommentTextCopyButtonCellKey;
        objc_setAssociatedObject(copyButton, &kCommentTextCopyButtonCellKey, self, OBJC_ASSOCIATION_ASSIGN);
        
        // Create handler and add target-action
        static CommentTextCopyButtonHandler *handler = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            handler = [[CommentTextCopyButtonHandler alloc] init];
        });
        
        [copyButton addTarget:handler action:@selector(copyButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        
        // Also try using the block-based approach if available
        if ([copyButton respondsToSelector:@selector(handleControlEvent:withBlock:)]) {
            [copyButton handleControlEvent:UIControlEventTouchUpInside withBlock:^(UIButton *sender) {
                id commentCell = objc_getAssociatedObject(sender, &kCommentTextCopyButtonCellKey);
                if (commentCell) {
                    copyCommentText(commentCell);
                }
            }];
        }
        
        // Add to the same superview as reference button
        if (referenceButton.superview) {
            ThetaSetCaptureHiding(copyButton);
            [referenceButton.superview addSubview:copyButton];
            objc_setAssociatedObject(self, &kCommentTextCopyButtonKey, copyButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (NSException *exception) {
        // Silent fail
    }
}

void THRegisterCommentTextCopyHooks(void) {
    NullHookMessageEx(objc_getClass("IGCommentCellView.IGCommentCellView"), @selector(layoutSubviews), (void *)hook_copyCommentText, &orig_copyCommentText);
}

