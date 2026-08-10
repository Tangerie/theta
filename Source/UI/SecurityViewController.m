#import "Include/SecurityViewController.h"
#import "Include/ThetaHelper.h"

#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]

// Maximum authentication attempts
static NSInteger maxAuthAttempts = 3;
static NSInteger currentAuthAttempts = 0;
static NSTimer *authTimeoutTimer = nil;

static void closeApp(void) {
	// Enhanced app termination with multiple fallback methods
	@try {
		// Method 1: Standard exit
		exit(0);
	} @catch (NSException *exception) {
		@try {
			// Method 2: Force quit
			[[UIApplication sharedApplication] performSelector:@selector(terminateWithSuccess)];
		} @catch (NSException *exception) {
			@try {
				// Method 3: Kill process
				kill(getpid(), SIGKILL);
			} @catch (NSException *exception) {
				// Method 4: Abort
				abort();
			}
		}
	}
}

static void closeAppWithAnimation(void) {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[UIApplication sharedApplication] performSelector:@selector(suspend)];
		[NSTimer scheduledTimerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *timer) {
			closeApp();
		}];
	});
}







@implementation SecurityViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Reset authentication attempts
    currentAuthAttempts = 0;
    
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.frame = self.view.bounds;
    [self.view addSubview:blurView];
    
    UIButton *authenticateButton = [[UIButton alloc] initWithFrame:CGRectMake(20, 20, 200, 60)];
    [authenticateButton setTitle:@"Tap to Authenticate" forState:UIControlStateNormal];
    authenticateButton.center = self.view.center;
    [authenticateButton addTarget:self action:@selector(authenticateButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:authenticateButton];
    
    // Start authentication timeout
    [self startAuthTimeout];
    
    [self authenticate];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [authTimeoutTimer invalidate];
    authTimeoutTimer = nil;
}

- (void)startAuthTimeout {
    [authTimeoutTimer invalidate];
    authTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:NO block:^(NSTimer *timer) {
        // Timeout reached, close app
        		[ThetaHelper showToastWithTitle:@"Authentication Timeout" subtitle:@"Please try again." icon:[ThetaHelper imageFromEmojiString:@"⏰" width:60] autoHide:2 openURL:nil];
        closeAppWithAnimation();
    }];
}

- (void)authenticateButtonTapped:(id)sender {
    [self authenticate];
}

- (void)authenticate {
    // Check if max attempts reached
    if (currentAuthAttempts >= maxAuthAttempts) {
        		[ThetaHelper showToastWithTitle:@"Too Many Attempts" subtitle:@"Please restart the app." icon:[ThetaHelper imageFromEmojiString:@"🚫" width:60] autoHide:3 openURL:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            closeAppWithAnimation();
        });
        return;
    }
    
    currentAuthAttempts++;
    
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;
    
    // Check if device supports biometric authentication
    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"Authentication is required to access Instagram.";
        
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL success, NSError *authenticationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [authTimeoutTimer invalidate];
                authTimeoutTimer = nil;
                
                if (success) {
                    [self dismissViewControllerAnimated:YES completion:nil];
                    		[ThetaHelper showToastWithTitle:@"Thanks for authenticating!" subtitle:@"You're all set." icon:[ThetaHelper imageFromEmojiString:@"✅" width:60] autoHide:4 openURL:nil];
					[ThetaHelper performHapticFeedbackIfEnabled];
                } else {
                    // Handle specific authentication errors
                    NSString *errorMessage = @"Authentication failed. Please try again.";
                    
                    if (authenticationError) {
                        switch (authenticationError.code) {
                            case LAErrorUserCancel:
                                errorMessage = @"Authentication cancelled.";
                                break;
                            case LAErrorUserFallback:
                                errorMessage = @"Please use passcode.";
                                break;
                            case LAErrorSystemCancel:
                                errorMessage = @"Authentication was interrupted.";
                                break;
                            case LAErrorPasscodeNotSet:
                                errorMessage = @"No passcode set. Please set a passcode in Settings.";
                                break;
                            case LAErrorBiometryNotAvailable:
                                errorMessage = @"Biometric authentication not available.";
                                break;
                            case LAErrorBiometryNotEnrolled:
                                errorMessage = @"No biometric data enrolled. Please set up Face ID or Touch ID.";
                                break;
                            default:
                                errorMessage = [NSString stringWithFormat:@"Authentication failed: %@", authenticationError.localizedDescription];
                                break;
                        }
                    }
                    
                    		[ThetaHelper showToastWithTitle:@"Authentication Failed" subtitle:errorMessage icon:[ThetaHelper imageFromEmojiString:@"❌" width:60] autoHide:3 openURL:nil];
                    
                    // If max attempts reached, close app after delay
                    if (currentAuthAttempts >= maxAuthAttempts) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            closeAppWithAnimation();
                        });
                    } else {
                        // Restart timeout for next attempt
                        [self startAuthTimeout];
                    }
                }
            });
        }];
    } else {
        // Device doesn't support biometric authentication
        		[ThetaHelper showToastWithTitle:@"Authentication Not Available" subtitle:@"Please set up Face ID, Touch ID, or passcode in Settings." icon:[ThetaHelper imageFromEmojiString:@"⚙️" width:60] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            closeAppWithAnimation();
        });
    }
}

@end
