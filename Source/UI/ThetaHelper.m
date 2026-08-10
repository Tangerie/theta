#import "Include/ThetaHelper.h"
#import "Include/InstagramHeaders.h"
#import "Include/CustomToastView.h"
#import <AudioToolbox/AudioToolbox.h>

#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]

@implementation ThetaHelper

static volatile BOOL sGlobalDownloadInProgress = NO;

#pragma mark - Constants

+ (UIColor *)iotaPinkColor {
    return [UIColor colorWithRed:1.0 green:0.412 blue:0.706 alpha:1.0];
}

+ (NSTimeInterval)cooldownPeriod {
    return 30.0;
}

+(NSString *)hexFromColour:(UIColor *)colour {
	CGFloat red, green, blue, alpha;
	[colour getRed:&red green:&green blue:&blue alpha:&alpha];
	return [NSString stringWithFormat:@"%02lX%02lX%02lX", lroundf(red * 255), lroundf(green * 255), lroundf(blue * 255)];
}

+(UIColor *)colourFromHex:(NSString *)hexString {
	if (hexString && hexString.length > 0) {
		unsigned rgbValue = 0;
		NSScanner *scanner = [NSScanner scannerWithString:hexString];
		[scanner scanHexInt:&rgbValue];
		return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0x00FF00) >> 8)/255.0 blue:(rgbValue & 0x0000FF)/255.0 alpha:1.0];
	}
	return [UIColor labelColor];
}

#pragma mark - Alert Management

+ (void)showCustomAlertWithActions:(NSString *)title description:(NSString *)description actions:(NSArray<NSDictionary *> *)actions {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSMutableArray *buttons = [NSMutableArray array];
            for (NSDictionary *actionDict in actions) {
                IGCustomAlertAction *action = [[NSClassFromString(@"IGCustomAlertAction") alloc] init];
                [action setValue:actionDict[@"handler"] forKey:@"handler"];
                [action setValue:actionDict[@"title"] forKey:@"title"];
                
                NSString *titleText = actionDict[@"title"];
                if ([titleText isEqualToString:@"No, cancel."] || 
                    [titleText isEqualToString:@"Cancel"] || 
                    [titleText isEqualToString:@"No, I'm good."] || 
                    [titleText isEqualToString:@"No"]) {
                    [action setValue:@4 forKey:@"style"];
                }
                [buttons addObject:action];
            }
            
            IGDSAlertDialogView *alert = [[NSClassFromString(@"IGDSAlertDialogView") alloc] initWithStyle:@1 titleText:title descriptionText:description actions:buttons showHorizontalButtons:NO];
            NSArray *buttonsArray = [alert valueForKey:@"buttons"];
            [alert show];
            
            for (IGDSAlertDialogActionButton *button in buttonsArray) {
                if ([button.titleLabel.text isEqualToString:@"Let's Go!"]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        button.titleLabel.textColor = [self iotaPinkColor];
                    });
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"Error showing custom alert: %@", exception);
        }
    });
}

#pragma mark - Toast Management

+ (void)showToastWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon autoHide:(int)seconds openURL:(NSURL *)openURL {
    if (ENABLED(@"Show Banners")) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CustomToastView *toast = [[CustomToastView alloc] initWithTitle:title subtitle:subtitle icon:icon autoHide:seconds openURL:openURL];
            [toast presentToast];
        });
        [self performHapticFeedbackIfEnabled];
    }
}

+ (void)showLoadToast:(NSString *)title subtitle:(NSString *)subtitle icon:(UIImage *)icon autoHide:(int)seconds openURL:(NSURL *)openURL {
    dispatch_async(dispatch_get_main_queue(), ^{
        CustomToastView *toast = [[CustomToastView alloc] initWithTitle:title subtitle:subtitle icon:icon autoHide:seconds openURL:openURL];
        [toast presentToast];
    });
    [self performHapticFeedbackIfEnabled];
}

#pragma mark - Haptic Feedback

+ (void)performHapticFeedbackIfEnabled {
    if (ENABLED(@"Haptic Feedback")) {
        AudioServicesPlaySystemSound(1519);
    }
}

#pragma mark - Image Utilities

+ (UIImage *)imageFromEmojiString:(NSString *)emojiString width:(CGFloat)width {
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    
    CGFloat fontSize = width * 0.8;
    
    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:emojiString attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:fontSize],
        NSParagraphStyleAttributeName: paragraphStyle
    }];
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, width), NO, 0);
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, width, width)];
    label.attributedText = attributedString;
    label.textAlignment = NSTextAlignmentCenter;
    label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    
    [label drawTextInRect:label.bounds];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return image;
}

#pragma mark - File Management

+ (void)createDirectoryIfNotExists:(NSURL *)URL {
    if (![URL checkResourceIsReachableAndReturnError:nil]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:URL withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

+ (void)cleanupTemporaryMediaFiles {
    NSURL *documentsURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:documentsURL.path error:nil];
    
    for (NSString *file in files) {
        if ([file hasSuffix:@".mp4"] || [file hasSuffix:@".aac"]) {
            NSURL *fileURL = [documentsURL URLByAppendingPathComponent:file];
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error];
            if (error) {
                NSLog(@"Error removing file %@: %@", fileURL.path, error.localizedDescription);
            } else {
                NSLog(@"Removed file: %@", fileURL.path);
            }
        }
    }
}

#pragma mark - Download Management

+ (BOOL)tryBeginGlobalDownloadOrNotify {
    @synchronized(self) {
        if (sGlobalDownloadInProgress) {
            UIImage *hourglass = [UIImage systemImageNamed:@"hourglass"];
            hourglass = [hourglass imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            CustomToastView *toast = [[CustomToastView alloc] initWithTitle:@"Download in progress" subtitle:@"Please wait for download to finish." icon:hourglass autoHide:2 openURL:nil];
            if (toast.progressIconView) {
                toast.progressIconView.tintColor = [UIColor labelColor];
            }
            toast.isProgressType = NO;
            [toast presentToast];
            return NO;
        }
        sGlobalDownloadInProgress = YES;
        return YES;
    }
}

+ (void)endGlobalDownload {
    @synchronized(self) {
        sGlobalDownloadInProgress = NO;
    }
}

+ (BOOL)isGlobalDownloadInProgress {
    @synchronized(self) {
        return sGlobalDownloadInProgress;
    }
}

#pragma mark - Utility Functions

+ (UIViewController *)nearestViewController:(UIView *)view {
    UIResponder *nextResponder = [view nextResponder];
    
    if ([nextResponder isKindOfClass:[UIViewController class]]) {
        return (UIViewController *)nextResponder;
    }
    
    return [self nearestViewController:[view superview]];
}

+ (UIViewController *)topViewController {
    UIWindow *window = nil;
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (!window) window = ((UIWindowScene *)scene).windows.firstObject;
            if (window) break;
        }
    }
    if (!window) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        window = app.keyWindow ?: app.windows.firstObject;
        if (!window && [app.delegate respondsToSelector:@selector(window)]) {
            window = [app.delegate window];
        }
#pragma clang diagnostic pop
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

+ (void)storeSegmentIndex:(NSInteger)index forSettingTitle:(NSString *)title {
    if (title.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"%@_SegmentIndex", title];
    [[NSUserDefaults standardUserDefaults] setInteger:index forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end 