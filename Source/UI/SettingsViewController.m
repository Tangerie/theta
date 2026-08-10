#import "Include/SettingsViewController.h"
#import "Include/SubMenuViewController.h"
#import "Include/AudioNotesViewController.h"
#import "Include/CustomSwitchCell.h"
#import "Include/CustomToastView.h"
#import "Include/ThetaHelper.h"
#import <AudioToolbox/AudioToolbox.h>
#import "Include/InstagramHeaders.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <zlib.h>
#import <AVFoundation/AVFoundation.h>

#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]

// MARK: - Color serialization helpers
static NSString *THHexStringFromColor(UIColor *color) {
    if (!color) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGColorRef cg = color.CGColor;
        size_t num = CGColorGetNumberOfComponents(cg);
        const CGFloat *components = CGColorGetComponents(cg);
        if (components) {
            if (num >= 3) { r = components[0]; g = components[1]; b = components[2]; }
            else if (num >= 1) { r = g = b = components[0]; }
        }
    }
    int R = (int)lrintf(r * 255.0f);
    int G = (int)lrintf(g * 255.0f);
    int B = (int)lrintf(b * 255.0f);
    return [NSString stringWithFormat:@"%02X%02X%02X", R, G, B];
}

static UIColor *THColorFromHexString(NSString *hexString) {
    if (![hexString isKindOfClass:[NSString class]]) return nil;
    NSString *hex = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6) return nil;
    unsigned int r = 0, g = 0, b = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    unsigned int rgb = 0;
    if (![scanner scanHexInt:&rgb]) return nil;
    r = (rgb >> 16) & 0xFF;
    g = (rgb >> 8) & 0xFF;
    b = rgb & 0xFF;
    return [UIColor colorWithRed:(r/255.0f) green:(g/255.0f) blue:(b/255.0f) alpha:1.0f];
}

@interface SubMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy, nullable) NSString *iconName;
@end

@implementation SubMenuItem
@end

@interface SettingSearchResult : NSObject
@property (nonatomic, copy) NSString *settingTitle;
@property (nonatomic, copy) NSString *settingDetail;
@property (nonatomic, copy) NSString *parentSubMenuTitle;
@property (nonatomic, copy) NSString *settingType; // "switch" (default) or "color"
@property (nonatomic, strong, nullable) NSArray<NSString *> *segmentOptions; // for type == "segment"
@end

@interface LinkItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *linkDetail;
@property (nonatomic, copy) NSString *urlString;
@end

@implementation LinkItem
@end

@implementation SettingSearchResult
@end

@interface SettingsViewController () <UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating, UISearchBarDelegate, UIScrollViewDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) NSArray<SubMenuItem *> *filteredSubMenus;
@property (nonatomic, strong) NSArray<SettingSearchResult *> *filteredSettings;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<SubMenuItem *> *subMenus;
@property (nonatomic, strong) NSArray<LinkItem *> *linkItems;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<NSDictionary *> *> *settingsBySubMenu;
@property (nonatomic, strong) UIImageView *bannerImageView;
@property (nonatomic, assign) BOOL isSearchingSettings;
@property (nonatomic, strong) UIImageView *chevronImageView;
@property (nonatomic, strong) AVCaptureSession *qrSession;
@property (nonatomic, strong) UIViewController *qrScanVC;
@property (nonatomic, strong) NSString *instagramVersion;
@property (nonatomic, strong) NSString *thetaVersion;
@end

// Image generation moved to ThetaHelper

// Top view controller utility moved to ThetaHelper

// Haptic feedback moved to ThetaHelper

// Toast functionality moved to ThetaHelper

// Toast functionality moved to ThetaHelper

@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"THETA";

    self.tableView.delegate = self;

    SubMenuItem *general = [SubMenuItem new];
    general.title = @"General";
    general.detail = @"General Theta behavior on Instagram.";
    general.iconName = @"gearshape";

    SubMenuItem *feed = [SubMenuItem new];
    feed.title = @"Feed";
    feed.detail = @"Hide suggested rails and promo rows.";
    feed.iconName = @"rectangle.stack";

    SubMenuItem *messages = [SubMenuItem new];
    messages.title = @"Messages";
    messages.detail = @"Settings related to Instagram messages.";
    messages.iconName = @"message";

    SubMenuItem *media = [SubMenuItem new];
    media.title = @"Media";
    media.detail = @"Various media options for Theta.";
    media.iconName = @"photo";
    
    SubMenuItem *reels = [SubMenuItem new];
    reels.title = @"Reels";
    reels.detail = @"Tap controls, scrubber, and reel behavior.";
    reels.iconName = @"play.rectangle";

    SubMenuItem *navigation = [SubMenuItem new];
    navigation.title = @"Navigation";
    navigation.detail = @"Tab bar order, visibility, and launch behavior.";
    navigation.iconName = @"square.grid.2x2";

    SubMenuItem *interface = [SubMenuItem new];
    interface.title = @"Interface";
    interface.detail = @"Customize the interface of Instagram.";
    interface.iconName = @"paintbrush";

    SubMenuItem *misc = [SubMenuItem new];
    misc.title = @"Miscellaneous";
    misc.detail = @"Other settings and options.";
    misc.iconName = @"ellipsis";

    self.subMenus = @[general, feed, messages, media, reels, navigation, interface, misc];
    self.filteredSubMenus = self.subMenus;

    self.settingsBySubMenu = @{
        @"General": @[
            @{@"title": @"Profile Analyzer", @"detail": @"Track who follows and unfollows you.", @"type": @"view", @"viewController": @"THProfileAnalyzerViewController", @"info": @"Scans your current followers and following lists and compares them to the last scan. Results show new followers, unfollowers, who you followed/unfollowed, mutual followers, and who doesn't follow you back. Data is stored locally. Scan history (from the analyzer screen) supports clearing all, swipe-to-delete for a single snapshot, or Compare mode to delete several at once. Requests are paced to reduce Instagram throttling; very large lists (13,000+ total) may still be limited by Instagram."},
            @{@"title": @"Screenshot Suppression", @"detail": @"Prevents screenshot and screen recording notifications."},
            @{@"title": @"Like Confirmation", @"detail": @"Display an alert when you like a post."},
            @{@"title": @"Follow Confirmation", @"detail": @"Display an alert when you follow someone."},
            @{@"title": @"Call Confirmation", @"detail": @"Display an alert when you call someone."},
            @{@"title": @"Disable Ads", @"detail": @"Removes all ads from the app."},
            @{@"title": @"Explore Refresh Confirmation", @"detail": @"Confirm before refreshing the explore page."},
            @{@"title": @"Comment Options", @"detail": @"Have some options when viewing a comment.", @"info": @"When enabled, you will see a button on comments.\n\nIf there is media attached to the comment, you will see an options button. If there is no media attached to the comment, you will see a copy button."},
            @{@"title": @"Date Format", @"detail": @"Custom timestamp format for feed, notes, comments, stories, and DMs.", @"type": @"segment", @"options": @[@"Default", @"Short", @"Medium", @"12h", @"24h", @"ISO", @"ISO+T"]},
            @{@"title": @"Open Links in External Browser", @"detail": @"Opens links from Instagram in your default browser instead of the in-app browser."},
            @{@"title": @"Strip Tracking from Links", @"detail": @"Removes tracking parameters (UTM, fbclid, igshid, etc.) from links before opening them."},
            @{@"title": @"Enable Liquid Glass Buttons", @"detail": @"Enables experimental liquid glass-style action buttons throughout the app.", @"info": @"Requires an app restart to take effect. This feature relies on hidden Instagram experiments and may not work on all accounts or app versions."},
            @{@"title": @"Enable Liquid Glass Surfaces", @"detail": @"Enables the floating liquid glass tab bar and other glassmorphic UI surfaces.", @"info": @"Requires an app restart to take effect. This enables the floating tab bar and other surfaces powered by Instagram's Homecoming/Lucent navigation experiment."},
        ],
        @"Feed": @[
            @{@"title": @"Hide Suggested Posts", @"detail": @"Inline suggested rails and previews."},
            @{@"title": @"Hide Suggested Reels", @"detail": @"Reels preview row."},
            @{@"title": @"Hide People You May Know", @"detail": @"Suggested people carousels."},
            @{@"title": @"Hide Threads Carousel", @"detail": @"Threads promos in feed."},
            @{@"title": @"Hide Home Stories", @"detail": @"Top story tray on home."},
            @{@"title": @"Mute Entire Home Feed", @"detail": @"Blank feed list; keeps chrome."},
            @{@"title": @"Hide End-of-Feed Footer", @"detail": @"Clears end-of-feed suggestion text."},
        ],
        @"Messages": @[
            @{@"title": @"Keep Deleted Messages", @"detail": @"Keep messages even after deletion.", @"info": @"Whenever messages are deleted (either from yourself or the other person), they will be kept locally as long as you don't refresh your chat feed.\n\nDeleted messages will be colored with the color you choose below."},
            @{@"title": @"Deleted Message Color", @"detail": @"Choose the color used for deleted messages.", @"type": @"color"},
            @{@"title": @"Save Audio Messages", @"detail": @"Save audio messages to device.", @"info": @"When enabled, you will be able to download audio messages after they have finished playing."},
            @{@"title": @"Upload Audio Messages", @"detail": @"Upload audio messages.", @"info": @"When enabled, whenever you press the voice message button, you will get a dialog asking if you want to upload audio from a video that's in your camera roll or record a new one."},
            @{@"title": @"Bypass Character Limit", @"detail": @"Bypass the character limit in messages."},
            @{@"title": @"Hide Typing Indicator", @"detail": @"Recipients won't know you're typing."},
            @{@"title": @"Mark As Seen", @"detail": @"Mark messages as seen with a button."},
            @{@"title": @"Mark As Seen Auto-Mark List", @"detail": @"Users in this list: their DMs are marked seen automatically.", @"type": @"view", @"viewController": @"ThetaUserListEditorViewController", @"listKey": @"Theta_MarkAsSeen_AutoMarkUserIds", @"listTitle": @"Mark as seen auto-mark list"},
            @{@"title": @"Seen On Typing", @"detail": @"Mark messages as seen when typing."},
            @{@"title": @"Seen On React", @"detail": @"Mark messages as seen when reacting."},
            @{@"title": @"Seen On Send", @"detail": @"Mark messages as seen when sending."},
            @{@"title": @"Private Media Ghost", @"detail": @"Manually mark photos/videos in DMs as seen."},
            @{@"title": @"Disappearing DM Confirmation", @"detail": @"Confirm disappearing messages.", @"info": @"When enabled and swiping up in a DM to toggle disappearing messages, a confirmation will be asked before enabling/disabling disappearing messages."},
            @{@"title": @"Hide \"Create Group\" Button", @"detail": @"Hides the Create Group button.", @"info": @"When selecting multiple recipients to send a post/reel to, the Create Group button will be hidden."},
            @{@"title": @"Create Group Confirmation", @"detail": @"Asks before creating a group.", @"info": @"When selecting multiple recipients to send a post/reel to, a confirmation will be asked before creating a group."},
            @{@"title": @"Hide Blend Button", @"detail": @"Hide the 'Blend' button in DMs."},
            @{@"title": @"Hide Call Buttons", @"detail": @"Hide the audio and video call buttons in DMs."},
            @{@"title": @"Full Last Active Date", @"detail": @"Replaces 'Active Xm ago' with the exact date and time in DM conversations.", @"info": @"Shows the full timestamp (e.g. 'May 13 at 2:45 PM') instead of the relative 'Active X minutes ago' text in DM conversation headers."},
            @{@"title": @"Send Files", @"detail": @"Adds a 'Send File' option to the DM plus menu to send any file from your device.", @"info": @"When enabled, a 'Send File' button appears in the DM composer plus menu. Tapping it opens a document picker so you can send any file type directly in a DM thread."},
        ],
        @"Media": @[
            @{@"title": @"Live Without Viewer List", @"detail": @"Stop IG from polling viewer counts during live broadcasts (you remain anonymous in the attendee list mechanics)."},
            @{@"title": @"Live Comments Sheet Toggle", @"detail": @"While watching a live story, long-press the heart to hide or reveal the floating comment strip for this session only.", @"info": @"This only affects layout on your device until you leave the live. Useful if you want a cleaner stage without losing quick access."},
            @{@"title": @"Story Ghost", @"detail": @"Manually mark stories as seen."},
            @{@"title": @"Story Ghost Auto-Mark List", @"detail": @"Users in this list: their stories are marked seen when you view.", @"type": @"view", @"viewController": @"ThetaUserListEditorViewController", @"listKey": @"Theta_StoryGhost_AutoMarkUserIds", @"listTitle": @"Story Ghost auto-mark list"},
            @{@"title": @"Story Seen On Reply", @"detail": @"Mark stories as seen when replying to a story."},
            @{@"title": @"Seen Receipts Stay Local", @"detail": @"Keep story rings cleared on this phone but pause server-side seen receipts.", @"info": @"Shows a phone icon on the story overlay (with Save / Ghost / mentions). Tap marks the current slide seen only on this device; long-press marks every slide in this reel the same way. Works alongside Story Ghost—the eye is for normal mark-as-seen; the phone icon is always local-only."},
            @{@"title": @"Skip On Seen", @"detail": @"Skip to the next story when marked as seen."},
            @{@"title": @"See Story Mentions", @"detail": @"Use a button to see who is mentioned in a story."},
            @{@"title": @"Save Media", @"detail": @"Save media to your camera roll."},
            @{@"title": @"Save Profile Pictures", @"detail": @"Save profile pictures to your camera roll.", @"info": @"When enabled, you will be able to long press on a profile picture to get an alert asking if you want to save the profile picture."},
            @{@"title": @"Save Profile Posts", @"detail": @"Bulk save profile posts.", @"info": @"When enabled, you will see a pink save button on a user's profile page. Tap it and it will gather all loaded posts and will either save them to your camera roll or save them to a local folder.\n\nThe save button will only be able to gather posts that are actively loaded. If you want to save everything, make sure to scroll all the way to the bottom of the user's profile and tap the save button."},
            @{@"title": @"Save Method", @"detail": @"Save media to camera roll or local folder.", @"type": @"segment", @"options": @[ @"Camera Roll", @"Folder"]},
            @{@"title": @"Save Audio Notes", @"detail": @"Save audio notes to your device."},
            @{@"title": @"Fullscreen Posts", @"detail": @"View posts in fullscreen mode."},
            @{@"title": @"Fullscreen Profile Pictures", @"detail": @"View profile pictures in fullscreen mode.", @"info": @"When enabled, you will be able to long press on a profile picture to get an alert asking if you want to view the profile picture in fullscreen mode."},
            @{@"title": @"Disable Auto Advance", @"detail": @"Turn off the annoying auto advance."},
            @{@"title": @"Bypass Reel Password", @"detail": @"Bypass reels that require a password.", @"info": @"When enabled and you view a reel that requires a password, you will see a button to bypass the password requirement."},
            @{@"title": @"Disable Scrolling Reels", @"detail": @"GET RID OF THE BRAINROT 2."},
        ],
        @"Reels": @[
            @{@"title": @"Tap Controls", @"detail": @"Choose what a single tap does while watching a reel.", @"type": @"segment", @"options": @[@"Default", @"Pause/Play", @"Mute"]},
            @{@"title": @"Always Show Scrubber", @"detail": @"Always show the progress scrubber on reels, regardless of video length.", @"info": @"By default Instagram only shows the progress scrubber on longer videos. This forces it to always appear so you can seek in any reel."},
        ],
        @"Navigation": @[
            @{@"title": @"Tab Icon Order", @"detail": @"Reorder the tab bar icons.", @"type": @"segment", @"options": @[@"Default", @"Classic", @"Standard", @"Alternate"], @"info": @"Requires an app restart to take effect.\n\nClassic: Feed · Explore · Create · Reels · Profile\nStandard: Feed · Explore · Reels · Messages · Profile\nAlternate: Feed · Reels · Create · Messages · Profile"},
            @{@"title": @"Swipe Between Tabs", @"detail": @"Control whether you can swipe horizontally to switch between tabs.", @"type": @"segment", @"options": @[@"Default", @"Enabled", @"Disabled"]},
            @{@"title": @"Launch Tab", @"detail": @"Choose which tab the app opens to on launch.", @"type": @"segment", @"options": @[@"Default", @"Home", @"Explore", @"Reels", @"Messages", @"Profile"]},
            @{@"title": @"Hide Feed Tab", @"detail": @"Removes the Home/Feed tab from the tab bar.", @"info": @"Requires an app restart to take effect."},
            @{@"title": @"Hide Explore Tab", @"detail": @"Removes the Explore tab from the tab bar.", @"info": @"Requires an app restart to take effect."},
            @{@"title": @"Hide Reels Tab", @"detail": @"GET RID OF THE BRAINROT.", @"info": @"Requires an app restart to take effect."},
            @{@"title": @"Hide Messages Tab", @"detail": @"Removes the Direct Messages tab from the tab bar.", @"info": @"Requires an app restart to take effect."},
            @{@"title": @"Messenger Mode", @"detail": @"Only Profile and Direct tabs; long-press the messages tab for Theta settings.", @"info": @"Hides all other tab bar items and swipe surfaces except Profile and Direct messages. When enabled, open Theta settings with a long press on the Direct messages tab (home tab long press is restored to Instagram\'s default). Requires an app restart."},
        ],
        @"Interface": @[
            @{@"title": @"Hide Create Tab/Button", @"detail": @"Hides the create tab and button."},
            @{@"title": @"Hide Explore Grid", @"detail": @"Hides the explore grid view."},
            @{@"title": @"Hide Recent Searches", @"detail": @"Hide the recent searches in the search tab."},
            @{@"title": @"Follow Status Indicator", @"detail": @"Indicates if a user follows you.", @"info": @"When enabled, you will see a \"✅\" or \"❌\" next to a user's name on their profile page based on whether they follow you or not."},
            @{@"title": @"Hide Repost Button", @"detail": @"Hides the repost button in the feed/reels."},
            @{@"title": @"Hide Theta From Screenshots", @"detail": @"Hides Theta buttons from screenshots and screen recordings.", @"info": @"When enabled, Theta UI elements (such as Mark as Seen, Save, Story Ghost buttons, etc.) will be invisible in screenshots and screen recordings, but still visible on screen."},
            @{@"title": @"Mentions Button Color", @"detail": @"Choose the color used for mentions buttons.", @"type": @"color"},
            @{@"title": @"Save Button Color", @"detail": @"Choose the color used for save buttons.", @"type": @"color"},
            @{@"title": @"Seen Button Color", @"detail": @"Choose the color used for seen buttons.", @"type": @"color"},
            @{@"title": @"Reset Colors", @"detail": @"Reset all colors back to default.", @"type": @"action"}
        ],
        @"Miscellaneous": @[
            @{@"title": @"Load Banner", @"detail": @"When Theta loads, see a banner."},
            @{@"title": @"Show Banners", @"detail": @"Upon certain actions, show a banner."},
            @{@"title": @"Haptic Feedback", @"detail": @"Enables haptic feedback for certain actions."},
            @{@"title": @"Lock Instagram", @"detail": @"Protect Instagram with Face ID/passcode.", @"requiresBiometrics": @YES},
            @{@"title": @"Shake To Open", @"detail": @"Open Theta's settings with a shake."},
            @{@"title": @"Easter Eggs", @"detail": @"Enable fun easter eggs."},
            @{@"title": @"Clear App Cache", @"detail": @"Clear all cached files and data.", @"type": @"action"},
        ]
    };

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.showsHorizontalScrollIndicator = NO;

    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;

    CGFloat spacerHeight = 10.0;
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, spacerHeight)];
    spacer.backgroundColor = [UIColor clearColor];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search Theta Settings";
    self.searchController.searchBar.delegate = self;
    self.searchController.searchBar.tintColor = [ThetaHelper iotaPinkColor];
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;

    self.tableView.tableHeaderView = spacer;

    UIImage *backImage = [UIImage systemImageNamed:@"chevron.down"];
    backImage = [backImage imageWithTintColor:[ThetaHelper iotaPinkColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:backImage
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(dismissViewController)];

    UIImage *applyImage = [UIImage systemImageNamed:@"gearshape"];
    applyImage = [applyImage imageWithTintColor:[ThetaHelper iotaPinkColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithImage:applyImage
                                                                    style:UIBarButtonItemStyleDone
                                                                   target:self
                                                                   action:nil];

    UIImage *audioNotesImage = [UIImage systemImageNamed:@"folder"];
    audioNotesImage = [audioNotesImage imageWithTintColor:[ThetaHelper iotaPinkColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIBarButtonItem *audioNotesButton = [[UIBarButtonItem alloc] initWithImage:audioNotesImage
                                                                         style:UIBarButtonItemStylePlain
                                                                        target:self
                                                                        action:@selector(openAudioNotes)];

    UIAction *applyAction = [UIAction actionWithTitle:@"Confirm"
                                                image:[UIImage systemImageNamed:@"checkmark"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self applySettings];
    }];

    UIAction *cancelAction = [UIAction actionWithTitle:@"Cancel"
                                                image:[UIImage systemImageNamed:@"xmark"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
                                            
                                        }];

    UIMenu *applyMenu = [UIMenu menuWithTitle:@"Apply Settings" children:@[applyAction, cancelAction]];

    UIAction *resetAction = [UIAction actionWithTitle:@"Confirm"
                                                image:[UIImage systemImageNamed:@"arrow.clockwise"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self resetSettings];
    }];
    UIAction *cancelAction2 = [UIAction actionWithTitle:@"Cancel"
                                                image:[UIImage systemImageNamed:@"xmark"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
                                            
                                        }];
    resetAction.attributes = UIMenuElementAttributesDestructive;
    UIMenu *resetMenu = [UIMenu menuWithTitle:@"Reset Settings" children:@[resetAction, cancelAction2]];

    UIAction *exportSettingsActionQR = [UIAction actionWithTitle:@"Export QR Code"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self exportSettingsQR];
    }];

    // Rename existing to clarify behavior
    UIAction *exportSettingsAction = [UIAction actionWithTitle:@"Show QR Code"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self exportSettings];
    }];

    // New: actually copy JSON to clipboard
    UIAction *exportSettingsClipboardJSON = [UIAction actionWithTitle:@"Export to Clipboard"
                                                image:[UIImage systemImageNamed:@"doc.on.doc"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self exportSettingsToClipboard];
    }];

    UIMenu *exportMenu = [UIMenu menuWithTitle:@"Export Settings" children:@[exportSettingsActionQR, exportSettingsAction, exportSettingsClipboardJSON]];

    UIAction *importSettingsActionScan = [UIAction actionWithTitle:@"Scan QR Code"
                                                image:[UIImage systemImageNamed:@"qrcode.viewfinder"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self importSettingsQRScan];
    }];

    UIAction *importSettingsAction = [UIAction actionWithTitle:@"Import QR Code"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self importSettingsQR];
    }];

    UIAction *importSettingsAction2 = [UIAction actionWithTitle:@"Import from Clipboard"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self importSettings];
    }];

    UIMenu *importMenu = [UIMenu menuWithTitle:@"Import Settings" children:@[importSettingsAction, importSettingsActionScan, importSettingsAction2]];

    UIMenu *importExportMenu = [UIMenu menuWithTitle:@"Import/Export Settings" children:@[importMenu, exportMenu]];

    UIMenu *mainMenu = [UIMenu menuWithTitle:@"" children:@[applyMenu, importExportMenu, resetMenu]];
    [applyButton setMenu:mainMenu];
    if (@available(iOS 14.0, *)) {
        SEL sel = NSSelectorFromString(@"setShowsMenuAsPrimaryAction:");
        if ([applyButton respondsToSelector:sel]) {
            ((void (*)(id, SEL, BOOL))[applyButton methodForSelector:sel])(applyButton, sel, YES);
        }
    }

    // Conditionally add audioNotesButton only if "Save Audio Notes" is enabled
    NSMutableArray *rightBarButtonItems = [NSMutableArray arrayWithObject:applyButton];
    [rightBarButtonItems addObject:audioNotesButton];
    self.navigationItem.rightBarButtonItems = rightBarButtonItems;

    self.navigationController.navigationBar.tintColor = [ThetaHelper iotaPinkColor];

    LinkItem *twitter = [LinkItem new];
    twitter.title = @"Follow @objcmsgsend on X";
    twitter.linkDetail = @"Stay updated with the latest news and updates.";
    twitter.urlString = @"https://twitter.com/objcmsgsend";

    LinkItem *discord = [LinkItem new];
    discord.title = @"Join the Discord Server";
    discord.linkDetail = @"Join the community for support and discussions.";
    discord.urlString = @"https://discord.gg/8b36UrNPEw";

    self.linkItems = @[twitter, discord];

    [self setupAnimatedTitle];
    [self setupVersionStrings];
}

- (void)setupAnimatedTitle {
    @try {
        UIView *titleContainer = [[UIView alloc] init];
        titleContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.navigationItem.titleView = titleContainer;
        
        NSString *titleText = @"THETA";
        UIFont *nativeFont = [UIFont fontWithName:@"HelveticaNeue-Bold" size:24.0];
        
        if (!nativeFont) {
            NSLog(@"[DEBUG] Error: 'AvenirNext-Bold' font not found. Falling back to system font.");
            nativeFont = [UIFont boldSystemFontOfSize:24.0];
        }
        
        UIStackView *stackView = [[UIStackView alloc] init];
        stackView.axis = UILayoutConstraintAxisHorizontal;
        stackView.alignment = UIStackViewAlignmentCenter;
        stackView.spacing = 5.0;
        stackView.translatesAutoresizingMaskIntoConstraints = NO;
        
        [titleContainer addSubview:stackView];
        
        NSMutableArray<UILabel *> *letterLabels = [NSMutableArray array];
        for (NSUInteger i = 0; i < titleText.length; i++) {
            NSString *letter = [titleText substringWithRange:NSMakeRange(i, 1)];
            
            UILabel *letterLabel = [[UILabel alloc] init];
            letterLabel.text = letter;
            letterLabel.font = nativeFont;
            	letterLabel.textColor = [ThetaHelper iotaPinkColor];
            letterLabel.alpha = 0.0;
            letterLabel.translatesAutoresizingMaskIntoConstraints = NO;
            
            [stackView addArrangedSubview:letterLabel];
            [letterLabels addObject:letterLabel];
        }
        
        [NSLayoutConstraint activateConstraints:@[
            [stackView.centerXAnchor constraintEqualToAnchor:titleContainer.centerXAnchor],
            [stackView.centerYAnchor constraintEqualToAnchor:titleContainer.centerYAnchor]
        ]];
        
        CGFloat delayIncrement = 0.08;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (NSUInteger i = 0; i < letterLabels.count; i++) {
                UILabel *label = letterLabels[i];
                
                [UIView animateWithDuration:0.5
                                      delay:i * delayIncrement
                                    options:UIViewAnimationOptionCurveEaseInOut
                                 animations:^{
                    label.alpha = 1.0;
                } completion:nil];
            }
        });
    } @catch (NSException *exception) {
        NSLog(@"Error: %@", exception);
    }
}

- (void)setupVersionStrings {
    // Get Instagram app version
    self.instagramVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!self.instagramVersion) {
        self.instagramVersion = @"Unknown";
    }
    
    // Get Theta build version from THEOS_PACKAGE_BASE_VERSION
    #ifdef THETA_VERSION
        self.thetaVersion = @THETA_VERSION;
    #else
        self.thetaVersion = @"Unknown";
    #endif
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchText = searchController.searchBar.text;
    if (searchText.length == 0) {
        self.isSearchingSettings = NO;
        self.filteredSubMenus = self.subMenus;
        [self.tableView reloadData];
        return;
    }

    NSMutableArray<SettingSearchResult *> *allSettings = [NSMutableArray array];
    for (SubMenuItem *subMenu in self.subMenus) {
        NSArray *subMenuSettings = self.settingsBySubMenu[subMenu.title];
        for (NSDictionary *setting in subMenuSettings) {
            SettingSearchResult *result = [SettingSearchResult new];
            result.settingTitle = setting[@"title"];
            result.settingDetail = setting[@"detail"];
            result.parentSubMenuTitle = subMenu.title;
            result.settingType = setting[@"type"] ?: @"switch";
            if ([result.settingType isEqualToString:@"segment"]) {
                NSArray *options = setting[@"options"];
                if ([options isKindOfClass:[NSArray class]]) {
                    result.segmentOptions = options;
                }
            }
            [allSettings addObject:result];
        }
    }

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(SettingSearchResult *result, NSDictionary *bindings) {
        return [result.settingTitle localizedCaseInsensitiveContainsString:searchText] ||
               [result.settingDetail localizedCaseInsensitiveContainsString:searchText] ||
               [result.parentSubMenuTitle localizedCaseInsensitiveContainsString:searchText];
    }];
    self.filteredSettings = [allSettings filteredArrayUsingPredicate:predicate];
    self.isSearchingSettings = YES;
    [self.tableView reloadData];
}

- (void)dismissViewController {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showAudioNotesMenu {
    // Deprecated menu flow; replaced by direct open
}

- (void)openAudioNotes {
    AudioNotesViewController *vc = [[AudioNotesViewController alloc] initWithMode:AudioNotesContentModeSavedMedia];
    [self.navigationController pushViewController:vc animated:YES];
}



- (void)applySettings {
    for (SubMenuItem *subMenu in self.subMenus) {
        NSArray *settings = self.settingsBySubMenu[subMenu.title];
        for (NSDictionary *setting in settings) {
            NSString *key = [NSString stringWithFormat:@"%@_Enabled", setting[@"title"]];
            BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:key];
            [[NSUserDefaults standardUserDefaults] setBool:isEnabled forKey:key];
        }
    }

    [[NSUserDefaults standardUserDefaults] synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        [ThetaHelper showToastWithTitle:@"Settings Applied!" subtitle:@"App will need to be restarted." icon:[ThetaHelper imageFromEmojiString:@"✅" width:300] autoHide:3 openURL:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            exit(0);
        });
    });
}

- (void)resetSettings {
    for (SubMenuItem *subMenu in self.subMenus) {
        NSArray *settings = self.settingsBySubMenu[subMenu.title];
        for (NSDictionary *setting in settings) {
            NSString *key = [NSString stringWithFormat:@"%@_Enabled", setting[@"title"]];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        }
    }

    // Also clear any persisted color preferences
    for (SubMenuItem *subMenu in self.subMenus) {
        NSArray *settings = self.settingsBySubMenu[subMenu.title];
        for (NSDictionary *setting in settings) {
            NSString *type = setting[@"type"] ?: @"switch";
            if ([type isEqualToString:@"color"]) {
                NSString *colorKey = [NSString stringWithFormat:@"%@_Color", setting[@"title"]];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:colorKey];
            }
        }
    }

    [[NSUserDefaults standardUserDefaults] synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        UILocalNotification *localNotification = [[UILocalNotification alloc] init];
        localNotification.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
        localNotification.alertTitle = @"Settings Reset!";
        localNotification.alertBody = @"Restart the app to see the changes.";
        localNotification.soundName = UILocalNotificationDefaultSoundName;
        [[UIApplication sharedApplication] scheduleLocalNotification:localNotification];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            exit(0);
        });
    });
}

NSData *compressData(NSData *uncompressedData) {
	if (!uncompressedData || [uncompressedData length] == 0) return nil;

	z_stream strm;
	strm.zalloc = Z_NULL;
	strm.zfree = Z_NULL;
	strm.opaque = Z_NULL;
	strm.total_out = 0;
	strm.next_in = (Bytef *)[uncompressedData bytes];
	strm.avail_in = (uInt)[uncompressedData length];

	// Compress level can be Z_DEFAULT_COMPRESSION, or between 0 and 9: 1 gives best speed, 9 gives best compression, 0 gives no compression.
	if (deflateInit(&strm, 1) != Z_OK) return nil;

	NSMutableData *compressed = [NSMutableData dataWithLength:16384];

	do {
		if (strm.total_out >= [compressed length])
			[compressed increaseLengthBy: 16384];
		
		strm.next_out = [compressed mutableBytes] + strm.total_out;
		strm.avail_out = (uInt)([compressed length] - strm.total_out);

		deflate(&strm, Z_FINISH);
		
	} while (strm.avail_out == 0);

	deflateEnd(&strm);

	[compressed setLength: strm.total_out];
	return compressed;
}

- (NSData *)decompressData:(NSData *)compressedData {
    if (!compressedData || [compressedData length] == 0) return nil;
    z_stream strm;
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    strm.avail_in = (uInt)[compressedData length];
    strm.next_in = (Bytef *)[compressedData bytes];

    if (inflateInit(&strm) != Z_OK) return nil;

    NSMutableData *decompressed = [NSMutableData dataWithLength:[compressedData length] * 4];
    int status;
    do {
        if (strm.total_out >= [decompressed length])
            [decompressed increaseLengthBy:[compressedData length] / 2];
        strm.next_out = [decompressed mutableBytes] + strm.total_out;
        strm.avail_out = (uInt)([decompressed length] - strm.total_out);
        status = inflate(&strm, Z_SYNC_FLUSH);
        if (status == Z_STREAM_ERROR || status == Z_DATA_ERROR || status == Z_MEM_ERROR) {
            inflateEnd(&strm);
            return nil;
        }
    } while (status != Z_STREAM_END);
    inflateEnd(&strm);
    [decompressed setLength:strm.total_out];
    return decompressed;
}

- (void)exportSettingsQR {
    NSMutableDictionary *exportedSettings = [NSMutableDictionary dictionary];
    for (SubMenuItem *subMenu in self.subMenus) {
        NSArray *settings = self.settingsBySubMenu[subMenu.title];
        NSMutableArray *exportedSubMenuSettings = [NSMutableArray array];
        for (NSDictionary *setting in settings) {
            NSString *key = [NSString stringWithFormat:@"%@_Enabled", setting[@"title"]];
            BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:key];
            NSMutableDictionary *exportedSetting = [@{
                @"title": setting[@"title"] ?: @"",
                @"enabled": @(isEnabled)
            } mutableCopy];
            // Include extra data for certain types
            NSString *type = setting[@"type"] ?: @"switch";
            if ([type isEqualToString:@"color"]) {
                NSString *colorKey = [NSString stringWithFormat:@"%@_Color", setting[@"title"]];
                NSData *storedData = [[NSUserDefaults standardUserDefaults] objectForKey:colorKey];
                if (storedData) {
                    UIColor *storedColor = nil;
                    @try {
                        storedColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:storedData error:nil];
                    } @catch (__unused NSException *e) {}
                    NSString *hex = THHexStringFromColor(storedColor);
                    if (hex) exportedSetting[@"colorHex"] = hex;
                }
            } else if ([type isEqualToString:@"segment"]) {
                NSString *segKey = [NSString stringWithFormat:@"%@_SegmentIndex", setting[@"title"]];
                NSInteger idx = [[NSUserDefaults standardUserDefaults] integerForKey:segKey];
                exportedSetting[@"selectedIndex"] = @(idx);
            }
            [exportedSubMenuSettings addObject:exportedSetting];
        }
        exportedSettings[subMenu.title] = exportedSubMenuSettings;
    }

    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportedSettings options:NSJSONWritingPrettyPrinted error:&error];
    if (!jsonData) {
        NSLog(@"Error exporting settings: %@", error);
        return;
    }

    NSData *compressedData = compressData(jsonData);
    NSString *base64EncodedString = [compressedData base64EncodedStringWithOptions:0];

    if (base64EncodedString.length > 0) {
        @try {
            NSData *qrData = [base64EncodedString dataUsingEncoding:NSUTF8StringEncoding];
            CIFilter *qrFilter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
            [qrFilter setValue:qrData forKey:@"inputMessage"];
            CIImage *qrImage = qrFilter.outputImage;

            if (!qrImage) {
                NSLog(@"Error: qrImage is nil");
                [ThetaHelper showToastWithTitle:@"QR Error" subtitle:@"Failed to generate QR code image." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
                return;
            }

            CGAffineTransform transform = CGAffineTransformMakeScale(10.0, 10.0);
            CIImage *scaledQRImage = [qrImage imageByApplyingTransform:transform];

            if (!scaledQRImage) {
                NSLog(@"Error: scaledQRImage is nil");
                [ThetaHelper showToastWithTitle:@"QR Error" subtitle:@"Failed to scale QR code image." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
                return;
            }

            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cgImage = [context createCGImage:scaledQRImage fromRect:scaledQRImage.extent];
            if (!cgImage) {
                NSLog(@"Error: cgImage is nil");
                [ThetaHelper showToastWithTitle:@"QR Error" subtitle:@"Failed to create CGImage from QR code." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
                return;
            }
            UIImage *qrUIImage = [UIImage imageWithCGImage:cgImage];
            CGImageRelease(cgImage);

            if (!qrUIImage) {
                NSLog(@"Error: qrUIImage is nil");
                [ThetaHelper showToastWithTitle:@"QR Error" subtitle:@"Failed to create UIImage from QR code." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
                return;
            }

            UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[qrUIImage] applicationActivities:nil];
            [[ThetaHelper topViewController] presentViewController:activityViewController animated:YES completion:nil];
        } @catch (NSException *exception) {
            NSLog(@"Error generating QR code: %@", exception);
        }
    } else {
        NSLog(@"Base64 encoded string is empty, cannot generate QR code");
    }
}

- (void)importSettingsQRScan {
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
        [ThetaHelper showToastWithTitle:@"Camera Error" subtitle:@"Unable to access camera." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
        return;
    }
    [session addInput:input];

    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    [session addOutput:output];

    UIViewController *scanVC = [[UIViewController alloc] init];
    AVCaptureVideoPreviewLayer *previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    previewLayer.frame = [UIScreen mainScreen].bounds;
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [scanVC.view.layer addSublayer:previewLayer];

    [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];

    // Store references for delegate
    self.qrSession = session;
    self.qrScanVC = scanVC;

    [self presentViewController:scanVC animated:YES completion:^{
        [session startRunning];
    }];
}

- (void)exportSettings {
    @try {
        // Build grouped export (matches import structure) and include colorHex where applicable
        NSMutableDictionary *exportedSettings = [NSMutableDictionary dictionary];
        for (SubMenuItem *subMenu in self.subMenus) {
            NSArray *settingsArray = self.settingsBySubMenu[subMenu.title];
            NSMutableArray *exportedSubMenuSettings = [NSMutableArray array];
            for (NSDictionary *setting in settingsArray) {
                NSString *title = setting[@"title"] ?: @"";
                NSString *enabledKey = [NSString stringWithFormat:@"%@_Enabled", title];
                BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:enabledKey];
                NSMutableDictionary *exportedSetting = [@{ @"title": title, @"enabled": @(isEnabled) } mutableCopy];
                NSString *type = setting[@"type"] ?: @"switch";
                if ([type isEqualToString:@"color"]) {
                    NSString *colorKey = [NSString stringWithFormat:@"%@_Color", title];
                    NSData *storedData = [[NSUserDefaults standardUserDefaults] objectForKey:colorKey];
                    if (storedData) {
                        UIColor *storedColor = nil;
                        @try {
                            storedColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:storedData error:nil];
                        } @catch (__unused NSException *e) {}
                        NSString *hex = THHexStringFromColor(storedColor);
                        if (hex) exportedSetting[@"colorHex"] = hex;
                    }
                } else if ([type isEqualToString:@"segment"]) {
                    NSString *segKey = [NSString stringWithFormat:@"%@_SegmentIndex", title];
                    NSInteger idx = [[NSUserDefaults standardUserDefaults] integerForKey:segKey];
                    exportedSetting[@"selectedIndex"] = @(idx);
                }
                [exportedSubMenuSettings addObject:exportedSetting];
            }
            exportedSettings[subMenu.title] = exportedSubMenuSettings;
        }
        
        // Convert to JSON
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportedSettings options:NSJSONWritingPrettyPrinted error:&error];
        if (error) {
            NSLog(@"Error exporting settings: %@", error);
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to export settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (!jsonString) {
            NSLog(@"Failed to create JSON string");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to create settings data." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        // Compress data
        NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) {
            NSLog(@"Failed to convert JSON string to data");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to process settings data." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        uLong compressedLength = compressBound((uLong)data.length);
        NSMutableData *compressedData = [NSMutableData dataWithLength:compressedLength];
        
        int result = compress(compressedData.mutableBytes, &compressedLength, data.bytes, (uLong)data.length);
        if (result != Z_OK) {
            NSLog(@"Compression failed with error: %d", result);
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to compress settings data." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        [compressedData setLength:compressedLength];
        
        // Base64 encode
        NSString *base64String = [compressedData base64EncodedStringWithOptions:0];
        if (!base64String) {
            NSLog(@"Failed to base64 encode compressed data");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to encode settings data." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        // Create QR code
        CIFilter *qrFilter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        if (!qrFilter) {
            NSLog(@"QR filter not available");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"QR code generation not available." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        NSData *qrData = [base64String dataUsingEncoding:NSUTF8StringEncoding];
        if (!qrData) {
            NSLog(@"Error: qrData is nil");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to process QR data." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        [qrFilter setValue:qrData forKey:@"inputMessage"];
        
        CIImage *qrImage = qrFilter.outputImage;
        if (!qrImage) {
            NSLog(@"Error: qrImage is nil");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to generate QR image." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        // Scale QR code
        CGAffineTransform transform = CGAffineTransformMakeScale(10, 10);
        CIImage *scaledQRImage = [qrImage imageByApplyingTransform:transform];
        if (!scaledQRImage) {
            NSLog(@"Error: scaledQRImage is nil");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to scale QR image." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:scaledQRImage fromRect:scaledQRImage.extent];
        if (!cgImage) {
            NSLog(@"Error: cgImage is nil");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to create CG image." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        UIImage *qrUIImage = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        
        if (!qrUIImage) {
            NSLog(@"Error: qrUIImage is nil");
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to create UIImage." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        
        // Present QR code
        UIViewController *qrVC = [[UIViewController alloc] init];
        qrVC.view.backgroundColor = [UIColor whiteColor];
        
        UIImageView *qrImageView = [[UIImageView alloc] initWithImage:qrUIImage];
        qrImageView.contentMode = UIViewContentModeScaleAspectFit;
        qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [qrVC.view addSubview:qrImageView];
        
        [NSLayoutConstraint activateConstraints:@[
            [qrImageView.centerXAnchor constraintEqualToAnchor:qrVC.view.centerXAnchor],
            [qrImageView.centerYAnchor constraintEqualToAnchor:qrVC.view.centerYAnchor],
            [qrImageView.widthAnchor constraintEqualToConstant:250],
            [qrImageView.heightAnchor constraintEqualToConstant:250]
        ]];
        
        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:qrVC];
        navController.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:navController animated:YES completion:nil];
        
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Settings Exported!" subtitle:@"Scan the QR code to import settings." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:nil];
        }
        
    } @catch (NSException *exception) {
        NSLog(@"Error generating QR code: %@", exception);
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"An error occurred while exporting settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
    }
}

- (void)exportSettingsToClipboard {
    @try {
        // Build grouped export, including colorHex
        NSMutableDictionary *exportedSettings = [NSMutableDictionary dictionary];
        for (SubMenuItem *subMenu in self.subMenus) {
            NSArray *settingsArray = self.settingsBySubMenu[subMenu.title];
            NSMutableArray *exportedSubMenuSettings = [NSMutableArray array];
            for (NSDictionary *setting in settingsArray) {
                NSString *title = setting[@"title"] ?: @"";
                NSString *enabledKey = [NSString stringWithFormat:@"%@_Enabled", title];
                BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:enabledKey];
                NSMutableDictionary *exportedSetting = [@{ @"title": title, @"enabled": @(isEnabled) } mutableCopy];
                NSString *type = setting[@"type"] ?: @"switch";
                if ([type isEqualToString:@"color"]) {
                    NSString *colorKey = [NSString stringWithFormat:@"%@_Color", title];
                    NSData *storedData = [[NSUserDefaults standardUserDefaults] objectForKey:colorKey];
                    if (storedData) {
                        UIColor *storedColor = nil;
                        @try { storedColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:storedData error:nil]; } @catch (__unused NSException *e) {}
                        if (!storedColor) {
                            @try { storedColor = [NSKeyedUnarchiver unarchiveObjectWithData:storedData]; } @catch (__unused NSException *e) {}
                        }
                        NSString *hex = THHexStringFromColor(storedColor);
                        if (hex) exportedSetting[@"colorHex"] = hex;
                    }
                }
                [exportedSubMenuSettings addObject:exportedSetting];
            }
            exportedSettings[subMenu.title] = exportedSubMenuSettings;
        }

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportedSettings options:NSJSONWritingPrettyPrinted error:&error];
        if (!jsonData) {
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to build settings JSON." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (!jsonString) {
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Failed to encode JSON string." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            }
            return;
        }
        [UIPasteboard generalPasteboard].string = jsonString;
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Exported" subtitle:@"Settings JSON copied to clipboard." icon:[UIImage systemImageNamed:@"doc.on.doc.fill"] autoHide:3 openURL:nil];
        }
    } @catch (__unused NSException *e) {
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Export Failed" subtitle:@"Unexpected error." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
    }
}

- (void)importSettingsQR {
    // Present image picker for QR code selection
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = (id<UINavigationControllerDelegate, UIImagePickerControllerDelegate>)self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importSettings {
    NSString *encryptedString = [[UIPasteboard generalPasteboard] string];
    NSLog(@"Encrypted string: %@", encryptedString);

    if (!encryptedString || encryptedString.length == 0) {
        [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"No settings string provided." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
        return;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:encryptedString options:0];
    if (!data) {
        [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Invalid base64 string." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
        return;
    }

    NSData *decompressedData = [self decompressData:data];
    NSLog(@"Decompressed data: %@", decompressedData);
    if (!decompressedData) {
        [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Decompression failed." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
        return;
    }

    NSError *error = nil;
    NSDictionary *importedSettings = [NSJSONSerialization JSONObjectWithData:decompressedData options:0 error:&error];
    if (!importedSettings || error) {
        [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Invalid JSON." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
        return;
    }

    // Import title/enabled and optional colorHex for each setting
    for (SubMenuItem *subMenu in self.subMenus) {
        NSArray *importedArray = importedSettings[subMenu.title];
        if (importedArray) {
            for (NSDictionary *setting in importedArray) {
                NSString *title = setting[@"title"];
                NSNumber *enabled = setting[@"enabled"];
                if (title && enabled) {
                    NSString *key = [NSString stringWithFormat:@"%@_Enabled", title];
                    [[NSUserDefaults standardUserDefaults] setBool:enabled.boolValue forKey:key];
                }
                NSString *hex = setting[@"colorHex"];
                if (title && [hex isKindOfClass:[NSString class]] && hex.length > 0) {
                    UIColor *color = THColorFromHexString(hex);
                    if (color) {
                        NSString *colorKey = [NSString stringWithFormat:@"%@_Color", title];
                        NSError *err = nil;
                        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&err];
                        if (data) {
                            [[NSUserDefaults standardUserDefaults] setObject:data forKey:colorKey];
                        }
                    }
                }
                NSNumber *selectedIndex = setting[@"selectedIndex"];
                if (title && [selectedIndex isKindOfClass:[NSNumber class]]) {
                    NSString *segKey = [NSString stringWithFormat:@"%@_SegmentIndex", title];
                    [[NSUserDefaults standardUserDefaults] setInteger:selectedIndex.integerValue forKey:segKey];
                }
            }
        }
    }

    [[NSUserDefaults standardUserDefaults] synchronize];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UILocalNotification *localNotification = [[UILocalNotification alloc] init];
        localNotification.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
        localNotification.alertTitle = @"Settings Imported!";
        localNotification.alertBody = @"Launching the app will have the new settings.";
        localNotification.soundName = UILocalNotificationDefaultSoundName;
        [[UIApplication sharedApplication] scheduleLocalNotification:localNotification];

        [[UIApplication sharedApplication] performSelector:@selector(suspend)];
        exit(0);
    });
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    if (metadataObjects.count == 0) return;
    AVMetadataMachineReadableCodeObject *obj = metadataObjects.firstObject;
    if (![obj.type isEqualToString:AVMetadataObjectTypeQRCode]) return;
    NSString *qrString = obj.stringValue;
    if (!qrString) return;

    // Stop scanning and dismiss camera
    [self.qrSession stopRunning];
    [self.qrScanVC dismissViewControllerAnimated:YES completion:^{
        NSData *data = [[NSData alloc] initWithBase64EncodedString:qrString options:0];
        if (!data) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Invalid base64 string." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        NSData *decompressedData = [self decompressData:data];
        if (!decompressedData) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Decompression failed." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        NSError *error = nil;
        NSDictionary *importedSettings = [NSJSONSerialization JSONObjectWithData:decompressedData options:0 error:&error];
        if (!importedSettings || error) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Invalid JSON." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        for (SubMenuItem *subMenu in self.subMenus) {
            NSArray *importedArray = importedSettings[subMenu.title];
            if (importedArray) {
                for (NSDictionary *setting in importedArray) {
                    NSString *title = setting[@"title"];
                    NSNumber *enabled = setting[@"enabled"];
                    if (title && enabled) {
                        NSString *key = [NSString stringWithFormat:@"%@_Enabled", title];
                        [[NSUserDefaults standardUserDefaults] setBool:enabled.boolValue forKey:key];
                    }
                    NSString *hex = setting[@"colorHex"];
                    if (title && [hex isKindOfClass:[NSString class]] && hex.length > 0) {
                        UIColor *color = THColorFromHexString(hex);
                        if (color) {
                            NSString *colorKey = [NSString stringWithFormat:@"%@_Color", title];
                            NSError *err = nil;
                            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&err];
                            if (data) {
                                [[NSUserDefaults standardUserDefaults] setObject:data forKey:colorKey];
                            }
                        }
                    }
                }
            }
        }
        [[NSUserDefaults standardUserDefaults] synchronize];
        [ThetaHelper showToastWithTitle:@"Settings Imported!" subtitle:@"App will need to be restarted." icon:[ThetaHelper imageFromEmojiString:@"✅" width:300] autoHide:2 openURL:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            exit(0);
        });
    }];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!selectedImage) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"No image selected." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        // Detect QR code from image
        CIImage *ciImage = [[CIImage alloc] initWithImage:selectedImage];
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{CIDetectorAccuracy:CIDetectorAccuracyHigh}];
        NSArray *features = [detector featuresInImage:ciImage];
        if (features.count == 0) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"No QR code found." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        CIQRCodeFeature *qrFeature = features.firstObject;
        NSString *qrString = qrFeature.messageString;
        if (!qrString) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"QR code unreadable." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        // Decode base64 and decompress
        NSData *compressedData = [[NSData alloc] initWithBase64EncodedString:qrString options:0];
        if (!compressedData) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Base64 decode failed." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        // Decompress
        NSData *jsonData = [self decompressData:compressedData];
        if (!jsonData) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"Decompression failed." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        NSError *error = nil;
        NSDictionary *importedSettings = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (!importedSettings || error) {
            [ThetaHelper showToastWithTitle:@"Import Error" subtitle:@"JSON decode failed." icon:[ThetaHelper imageFromEmojiString:@"❌" width:200] autoHide:2 openURL:nil];
            return;
        }
        // Import settings (including colorHex when present)
        for (NSString *subMenuTitle in importedSettings) {
            NSArray *settingsArray = importedSettings[subMenuTitle];
            for (NSDictionary *setting in settingsArray) {
                NSString *title = setting[@"title"];
                NSNumber *enabled = setting[@"enabled"];
                if (title && enabled) {
                    NSString *key = [NSString stringWithFormat:@"%@_Enabled", title];
                    [[NSUserDefaults standardUserDefaults] setBool:enabled.boolValue forKey:key];
                }
                NSString *hex = setting[@"colorHex"];
                if (title && [hex isKindOfClass:[NSString class]] && hex.length > 0) {
                    UIColor *color = THColorFromHexString(hex);
                    if (color) {
                        NSString *colorKey = [NSString stringWithFormat:@"%@_Color", title];
                        NSError *err = nil;
                        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&err];
                        if (data) {
                            [[NSUserDefaults standardUserDefaults] setObject:data forKey:colorKey];
                        }
                    }
                }
                NSNumber *selectedIndex = setting[@"selectedIndex"];
                if (title && [selectedIndex isKindOfClass:[NSNumber class]]) {
                    NSString *segKey = [NSString stringWithFormat:@"%@_SegmentIndex", title];
                    [[NSUserDefaults standardUserDefaults] setInteger:selectedIndex.integerValue forKey:segKey];
                }
            }
        }
        [[NSUserDefaults standardUserDefaults] synchronize];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UILocalNotification *localNotification = [[UILocalNotification alloc] init];
            localNotification.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
            localNotification.alertTitle = @"Settings Imported!";
            localNotification.alertBody = @"Launching the app will have the new settings.";
            localNotification.soundName = UILocalNotificationDefaultSoundName;
            [[UIApplication sharedApplication] scheduleLocalNotification:localNotification];

            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            exit(0);
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.isSearchingSettings) {
        return 1;
    }
    return 2; // SubMenus + Links
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.isSearchingSettings) {
        return self.filteredSettings.count;
    }
    if (section == 0) {
        return self.filteredSubMenus.count;
    } else if (section == 1) {
        return self.linkItems.count;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (self.isSearchingSettings) {
		SettingSearchResult *result = self.filteredSettings[indexPath.row];
		NSString *settingType = result.settingType ?: @"switch";

		// Use section rect width for more accurate content width in InsetGrouped style
		CGFloat tableWidth = [tableView rectForSection:indexPath.section].size.width;
		if (tableWidth <= 0.0) tableWidth = tableView.bounds.size.width;
		CGFloat leftPadding = 20.0;
		CGFloat rightPadding = 12.0;
		CGFloat textToControlSpacing = 12.0;
		CGFloat minHeight = 54.0;
		CGFloat topPadding = 12.0;
		CGFloat interLabelSpacing = 2.0;
		CGFloat bottomPadding = 12.0;

		NSString *osVersion = [[UIDevice currentDevice] systemVersion];
		CGFloat ios19Extra = (osVersion.floatValue >= 19.0) ? 4.0 : 0.0;

		CGFloat reservedRight = 0.0;
		if ([settingType isEqualToString:@"color"]) {
			CGFloat colorWellSize = 30.0;
			reservedRight = rightPadding + colorWellSize + textToControlSpacing;
		} else if ([settingType isEqualToString:@"segment"]) {
			CGFloat segWidth = MIN(240.0, tableWidth * 0.45);
			reservedRight = rightPadding + segWidth + textToControlSpacing;
		} else if ([settingType isEqualToString:@"action"]) {
			CGFloat buttonSize = 30.0;
			reservedRight = rightPadding + buttonSize + textToControlSpacing;
		} else {
			// switch (default)
			BOOL hasInfo = NO;
			NSArray *source = self.settingsBySubMenu[result.parentSubMenuTitle] ?: @[];
			for (NSDictionary *d in source) { if ([d[@"title"] isEqualToString:result.settingTitle]) { hasInfo = [d[@"info"] isKindOfClass:[NSString class]] && [d[@"info"] length] > 0; break; } }
			CGFloat switchWidth = 52.0;
			CGFloat infoSize = 28.0;
			CGFloat interControlSpacing = 8.0;
			reservedRight = rightPadding + switchWidth + ios19Extra + (hasInfo ? (interControlSpacing + infoSize) : 0.0) + textToControlSpacing;
		}

		CGFloat contentWidth = tableWidth - leftPadding - reservedRight;
		if (contentWidth < 60.0) contentWidth = 60.0;

		UIFont *titleFont = [UIFont systemFontOfSize:17.0];
		CGFloat subtitleSize = 13.0;
		if (@available(iOS 16.0, *)) { subtitleSize = 12.0; }
		UIFont *detailFont = [UIFont systemFontOfSize:subtitleSize];

		CGFloat titleHeight = ceilf([result.settingTitle boundingRectWithSize:CGSizeMake(contentWidth, CGFLOAT_MAX)
																	 options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading
																  attributes:@{ NSFontAttributeName: titleFont }
																	 context:nil].size.height);

		NSString *detailText = [NSString stringWithFormat:@"%@ — %@", result.parentSubMenuTitle, result.settingDetail ?: @""];
		CGFloat detailHeight = ceilf([detailText boundingRectWithSize:CGSizeMake(contentWidth, CGFLOAT_MAX)
															  options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading
														   attributes:@{ NSFontAttributeName: detailFont }
															  context:nil].size.height);

		CGFloat total = topPadding + titleHeight + interLabelSpacing + detailHeight + bottomPadding + 2.0; // small fudge for rounding
		return MAX(minHeight, total);
	} else {
		return 54.0;
	}
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
    }

    cell.accessoryView = nil;

    // --- Get app version once ---
    static NSString *cachedAppVersion = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedAppVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    });

    // Helper to compare version strings
    BOOL (^isAppVersionAtMost313_0_2)(void) = ^BOOL{
        if (!cachedAppVersion) return NO;
        NSArray *parts = [cachedAppVersion componentsSeparatedByString:@"."];
        NSInteger major = parts.count > 0 ? [parts[0] integerValue] : 0;
        NSInteger minor = parts.count > 1 ? [parts[1] integerValue] : 0;
        NSInteger patch = parts.count > 2 ? [parts[2] integerValue] : 0;
        if (major < 313) return YES;
        if (major > 313) return NO;
        if (minor < 0) return YES;
        if (minor > 0) return NO;
        if (patch <= 2) return YES;
        return NO;
    };

    if (self.isSearchingSettings) {
        SettingSearchResult *result = self.filteredSettings[indexPath.row];
        NSString *settingType = result.settingType ?: @"switch";

        if ([settingType isEqualToString:@"color"]) {
            static NSString *colorCellIdentifier = @"SearchColorCell";
            UITableViewCell *colorCell = [tableView dequeueReusableCellWithIdentifier:colorCellIdentifier];
            if (!colorCell) {
                colorCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:colorCellIdentifier];
                colorCell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            colorCell.textLabel.text = result.settingTitle;
            CGFloat subtitleSize = 13.0;
            if (@available(iOS 16.0, *)) { subtitleSize = 12.0; }
            colorCell.detailTextLabel.font = [UIFont systemFontOfSize:subtitleSize];
            colorCell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", result.parentSubMenuTitle, result.settingDetail ?: @""];
            colorCell.imageView.image = nil;
            colorCell.textLabel.font = [UIFont systemFontOfSize:17];
            colorCell.textLabel.textColor = [UIColor labelColor];
            colorCell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            colorCell.textLabel.numberOfLines = 0;
            colorCell.detailTextLabel.numberOfLines = 0;
            colorCell.preservesSuperviewLayoutMargins = NO;
            colorCell.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 0);
            colorCell.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);
            colorCell.contentView.preservesSuperviewLayoutMargins = NO;
            if (@available(iOS 11.0, *)) {
                colorCell.contentView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 20, 0, 0);
            }

            if (@available(iOS 14.0, *)) {
                UIColorWell *colorWell = [[UIColorWell alloc] init];
                colorWell.supportsAlpha = NO;
                NSString *colorKey = [NSString stringWithFormat:@"%@_Color", result.settingTitle];
                NSData *storedData = [[NSUserDefaults standardUserDefaults] objectForKey:colorKey];
                UIColor *storedColor = nil;
                if (storedData) {
                    @try {
                        storedColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:storedData error:nil];
                    } @catch (__unused NSException *e) {}
                    if (!storedColor) {
                        @try { storedColor = [NSKeyedUnarchiver unarchiveObjectWithData:storedData]; } @catch (__unused NSException *e) {}
                    }
                }
                colorWell.selectedColor = storedColor ?: [UIColor labelColor];
                colorWell.accessibilityIdentifier = colorKey;
                [colorWell addTarget:self action:@selector(searchColorWellChanged:) forControlEvents:UIControlEventValueChanged];
                // Ensure proper sizing when used as accessoryView
                CGFloat side = 30.0;
                colorWell.frame = CGRectMake(0, 0, side, side);
                [colorWell sizeToFit];
                colorCell.accessoryView = colorWell;
            }

            return colorCell;
        } else {
            if ([settingType isEqualToString:@"segment"]) {
                static NSString *segmentCellIdentifier = @"SearchSegmentCell";
                UITableViewCell *segmentCell = [tableView dequeueReusableCellWithIdentifier:segmentCellIdentifier];
                if (!segmentCell) {
                    segmentCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:segmentCellIdentifier];
                    segmentCell.selectionStyle = UITableViewCellSelectionStyleNone;
                }
                segmentCell.textLabel.text = result.settingTitle;
                CGFloat segSubtitleSize = 13.0;
                if (@available(iOS 16.0, *)) { segSubtitleSize = 12.0; }
                segmentCell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", result.parentSubMenuTitle, result.settingDetail ?: @""];
                segmentCell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                segmentCell.detailTextLabel.font = [UIFont systemFontOfSize:segSubtitleSize];
                segmentCell.textLabel.numberOfLines = 0;
                segmentCell.detailTextLabel.numberOfLines = 0;
                segmentCell.preservesSuperviewLayoutMargins = NO;
                segmentCell.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 0);

                NSArray<NSString *> *options = result.segmentOptions;
                UISegmentedControl *seg = nil;
                if ([segmentCell.accessoryView isKindOfClass:[UISegmentedControl class]]) {
                    seg = (UISegmentedControl *)segmentCell.accessoryView;
                    [seg removeAllSegments];
                } else {
                    seg = [[UISegmentedControl alloc] init];
                }
                [options enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    [seg insertSegmentWithTitle:obj atIndex:idx animated:NO];
                }];
                NSString *key = [NSString stringWithFormat:@"%@_SegmentIndex", result.settingTitle];
                NSInteger selected = [[NSUserDefaults standardUserDefaults] integerForKey:key];
                if (selected < 0 || selected >= (NSInteger)options.count) selected = 0;
                seg.selectedSegmentIndex = selected;
                seg.tag = indexPath.row;
                seg.accessibilityIdentifier = result.settingTitle;
                [seg removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
                [seg addTarget:self action:@selector(handleSegmentChange:) forControlEvents:UIControlEventValueChanged];
                [seg sizeToFit];
                seg.transform = CGAffineTransformMakeScale(0.8, 0.8);
                segmentCell.accessoryView = seg;
                return segmentCell;
            }
            if ([settingType isEqualToString:@"action"]) {
                static NSString *actionSearchCellIdentifier = @"ActionSearchCell";
                UITableViewCell *actionCell = [tableView dequeueReusableCellWithIdentifier:actionSearchCellIdentifier];
                if (!actionCell) {
                    actionCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:actionSearchCellIdentifier];
                    actionCell.selectionStyle = UITableViewCellSelectionStyleNone;
                }
                actionCell.textLabel.text = result.settingTitle;
                CGFloat actSubtitleSize = 13.0;
                if (@available(iOS 16.0, *)) { actSubtitleSize = 12.0; }
                actionCell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", result.parentSubMenuTitle, result.settingDetail ?: @""];
                actionCell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                actionCell.detailTextLabel.font = [UIFont systemFontOfSize:actSubtitleSize];
                actionCell.textLabel.numberOfLines = 0;
                actionCell.detailTextLabel.numberOfLines = 0;
                actionCell.preservesSuperviewLayoutMargins = NO;
                actionCell.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 0);

                UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
                NSString *iconName = @"arrow.clockwise";
                SEL actionSelector = @selector(resetButtonColorsFromSearch);
                NSString *accessibilityLabel = @"Reset Colors";
                
                if ([result.settingTitle isEqualToString:@"Clear App Cache"]) {
                    iconName = @"trash";
                    actionSelector = @selector(clearAppCacheFromSearch);
                    accessibilityLabel = @"Clear App Cache";
                }
                
                UIImage *baseIcon = [UIImage systemImageNamed:iconName];
                UIImage *icon = [baseIcon imageWithTintColor:[ThetaHelper iotaPinkColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
                [button setImage:icon forState:UIControlStateNormal];
                button.tintColor = [ThetaHelper iotaPinkColor];
                button.accessibilityLabel = accessibilityLabel;
                [button addTarget:self action:actionSelector forControlEvents:UIControlEventTouchUpInside];
                [button sizeToFit];
                actionCell.accessoryView = button;
                return actionCell;
            }
            static NSString *switchCellIdentifier = @"CustomSwitchCell";
            CustomSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:switchCellIdentifier];
            if (!cell) {
                cell = [[CustomSwitchCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:switchCellIdentifier];
            }

            cell.textLabel.text = result.settingTitle;
            CGFloat swSubtitleSize = 13.0;
            if (@available(iOS 16.0, *)) { swSubtitleSize = 12.0; }
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", result.parentSubMenuTitle, result.settingDetail ?: @""];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:swSubtitleSize];
            cell.imageView.image = nil;

            NSString *key = [NSString stringWithFormat:@"%@_Enabled", result.settingTitle];
            if ([cell.settingSwitch respondsToSelector:@selector(setOn:animated:)]) {
                BOOL isOn = [[NSUserDefaults standardUserDefaults] boolForKey:key];
                ((void(*)(id,SEL,BOOL,BOOL))[cell.settingSwitch methodForSelector:@selector(setOn:animated:)])(cell.settingSwitch, @selector(setOn:animated:), isOn, NO);
            }
            cell.settingSwitch.tag = indexPath.row;
            [cell.settingSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            [cell.settingSwitch addTarget:self action:@selector(searchSwitchChanged:) forControlEvents:UIControlEventValueChanged];

            cell.textLabel.font = [UIFont systemFontOfSize:17];
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.numberOfLines = 0;

            // Optional info button in search results (look up original dict)
            NSString *infoText = nil;
            NSArray *source = self.settingsBySubMenu[result.parentSubMenuTitle] ?: @[];
            for (NSDictionary *d in source) { if ([d[@"title"] isEqualToString:result.settingTitle]) { infoText = d[@"info"]; break; } }
            if ([infoText isKindOfClass:[NSString class]] && infoText.length > 0) {
                cell.infoButton.hidden = NO;
                cell.infoButton.accessibilityIdentifier = result.settingTitle;
                [cell.infoButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
                [cell.infoButton addTarget:self action:@selector(didTapInfoFromSearch:) forControlEvents:UIControlEventTouchUpInside];
            } else {
                cell.infoButton.hidden = YES;
            }

            // Disable "Keep Deleted Messages" if app version <= 313.0.2
            if ([result.settingTitle isEqualToString:@"Keep Deleted Messages"] && isAppVersionAtMost313_0_2()) {
                cell.settingSwitch.enabled = NO;
                cell.textLabel.textColor = [UIColor systemGrayColor];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@ (Requires app version > 313.0.2)", result.parentSubMenuTitle, result.settingDetail ?: @""];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
                [[NSUserDefaults standardUserDefaults] synchronize];
            } else {
                cell.settingSwitch.enabled = YES;
            }

            return cell;
        }
    } else {
        if (indexPath.section == 0) {
            // SubMenuItem cell
            static NSString *cellIdentifier = @"Cell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
            }
            cell.accessoryView = nil;
            SubMenuItem *subMenu = self.filteredSubMenus[indexPath.row];
            cell.textLabel.text = subMenu.title;
            cell.detailTextLabel.text = subMenu.detail;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            if (subMenu.iconName) {
                UIImage *icon = [UIImage systemImageNamed:subMenu.iconName];
                cell.imageView.image = icon;
                cell.imageView.tintColor = [ThetaHelper iotaPinkColor];
            } else {
                cell.imageView.image = nil;
            }
            cell.textLabel.font = [UIFont systemFontOfSize:17];
            cell.textLabel.textColor = [UIColor labelColor];
            NSString *osVersion = [[UIDevice currentDevice] systemVersion];
            if (osVersion.floatValue >= 19.0) {
                cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
            } else {
                cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
            }
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        } else if (indexPath.section == 1) {
            // Link cell
            static NSString *linkCellIdentifier = @"LinkCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:linkCellIdentifier];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:linkCellIdentifier];
            }
            LinkItem *link = self.linkItems[indexPath.row];
            cell.textLabel.text = link.title;
            cell.detailTextLabel.text = link.linkDetail;
            cell.textLabel.textColor = [ThetaHelper iotaPinkColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.imageView.image = [UIImage systemImageNamed:@"link"];
            cell.imageView.tintColor = [ThetaHelper iotaPinkColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
    }

    // iOS 16+ has larger default toggles; add trailing content inset for alignment
    if (@available(iOS 16.0, *)) {
        cell.separatorInset = UIEdgeInsetsMake(0, 20, 0, 20);
        cell.contentView.layoutMargins = UIEdgeInsetsMake(0, 20, 0, 20);
    }
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    return cell;
}

- (void)didTapInfoFromSearch:(UIButton *)sender {
    NSString *title = sender.accessibilityIdentifier ?: @"Info";
    NSString *message = @"";
    for (NSString *section in self.settingsBySubMenu.allKeys) {
        for (NSDictionary *d in self.settingsBySubMenu[section]) {
            if ([d[@"title"] isEqualToString:title]) { message = d[@"info"] ?: d[@"detail"] ?: @""; break; }
        }
    }
    [ThetaHelper showCustomAlertWithActions:title description:message actions:@[@{ @"title": @"OK", @"handler": ^(id s) {} }]];
}

- (void)searchSwitchChanged:(UISwitch *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= self.filteredSettings.count) return;
    SettingSearchResult *result = self.filteredSettings[row];
    NSString *key = [NSString stringWithFormat:@"%@_Enabled", result.settingTitle];
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if ([result.settingTitle isEqualToString:@"Easter Eggs"] && sender.isOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ThetaHelper showToastWithTitle:@"Easter Eggs not implemented yet!" subtitle:@"Will be soon, stay tuned!" icon:[ThetaHelper imageFromEmojiString:@"🐥" width:300] autoHide:4 openURL:nil];
        });
    }

    static NSSet *sSearchRestartRequired;
    static dispatch_once_t sSearchRestartOnce;
    dispatch_once(&sSearchRestartOnce, ^{
        sSearchRestartRequired = [NSSet setWithArray:@[
            @"Messenger Mode", @"Hide Explore Grid", @"Hide Reels Tab",
            @"Hide Explore Tab", @"Hide Feed Tab", @"Hide Messages Tab",
            @"Hide Create Tab/Button", @"Enable Liquid Glass Buttons",
            @"Enable Liquid Glass Surfaces",
        ]];
    });
    if ([sSearchRestartRequired containsObject:result.settingTitle]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ThetaHelper showToastWithTitle:@"App Restart Required" subtitle:@"Restart the app for changes to apply." icon:[ThetaHelper imageFromEmojiString:@"⚠️" width:300] autoHide:4 openURL:nil];
        });
    }
}

- (void)handleSegmentChange:(UISegmentedControl *)sender {
    NSString *title = sender.accessibilityIdentifier;
    if (title.length > 0) {
        [ThetaHelper storeSegmentIndex:sender.selectedSegmentIndex forSettingTitle:title];
    }
}

- (void)searchColorWellChanged:(id)sender {
    if (@available(iOS 14.0, *)) {
        UIColorWell *colorWell = (UIColorWell *)sender;
        NSString *colorKey = colorWell.accessibilityIdentifier;
        if (colorKey.length > 0) {
            UIColor *color = colorWell.selectedColor ?: [UIColor labelColor];
            NSError *error = nil;
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&error];
            if (data) {
                [[NSUserDefaults standardUserDefaults] setObject:data forKey:colorKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
    }
}

- (void)resetButtonColorsFromSearch {
    NSArray<NSString *> *keys = @[ @"Save Button Color_Color", @"Seen Button Color_Color", @"Deleted Message Color_Color", @"Mentions Button Color_Color" ];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in keys) {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];

    if (@available(iOS 14.0, *)) {
        for (UITableViewCell *cell in self.tableView.visibleCells) {
            if ([cell.accessoryView isKindOfClass:[UIColorWell class]]) {
                UIColorWell *well = (UIColorWell *)cell.accessoryView;
                well.selectedColor = [UIColor labelColor];
            }
        }
    }

    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Colors Reset" subtitle:@"Button colors restored to default." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:nil];
    }
}

- (void)clearAppCacheFromSearch {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSUInteger totalSize = 0;
    NSUInteger filesDeleted = 0;
    
    // Clear Caches directory
    NSArray *cachePaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (cachePaths.count > 0) {
        NSString *cacheDir = cachePaths[0];
        NSArray *cacheContents = [fileManager contentsOfDirectoryAtPath:cacheDir error:&error];
        if (!error && cacheContents) {
            for (NSString *item in cacheContents) {
                NSString *itemPath = [cacheDir stringByAppendingPathComponent:item];
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:itemPath error:nil];
                if (attributes) {
                    totalSize += [attributes[NSFileSize] unsignedIntegerValue];
                }
                if ([fileManager removeItemAtPath:itemPath error:&error]) {
                    filesDeleted++;
                }
            }
        }
    }
    
    // Clear temporary files in Documents directory
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSArray *documentsContents = [fileManager contentsOfDirectoryAtPath:documentsPath error:&error];
    if (!error && documentsContents) {
        for (NSString *item in documentsContents) {
            // Skip important files like plists
            if ([item hasSuffix:@".plist"]) {
                continue;
            }
            NSString *itemPath = [documentsPath stringByAppendingPathComponent:item];
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:itemPath error:nil];
            if (attributes) {
                totalSize += [attributes[NSFileSize] unsignedIntegerValue];
            }
            if ([fileManager removeItemAtPath:itemPath error:&error]) {
                filesDeleted++;
            }
        }
    }
    
    // Clear Library/Caches if it exists
    NSArray *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (libraryPaths.count > 0) {
        NSString *libraryCacheDir = [[libraryPaths[0] stringByAppendingPathComponent:@"Caches"] stringByStandardizingPath];
        if ([fileManager fileExistsAtPath:libraryCacheDir]) {
            NSArray *libraryCacheContents = [fileManager contentsOfDirectoryAtPath:libraryCacheDir error:&error];
            if (!error && libraryCacheContents) {
                for (NSString *item in libraryCacheContents) {
                    NSString *itemPath = [libraryCacheDir stringByAppendingPathComponent:item];
                    NSDictionary *attributes = [fileManager attributesOfItemAtPath:itemPath error:nil];
                    if (attributes) {
                        totalSize += [attributes[NSFileSize] unsignedIntegerValue];
                    }
                    if ([fileManager removeItemAtPath:itemPath error:&error]) {
                        filesDeleted++;
                    }
                }
            }
        }
    }
    
    // Format size for display
    NSString *sizeString = @"";
    if (totalSize > 0) {
        if (totalSize < 1024) {
            sizeString = [NSString stringWithFormat:@"%lu bytes", (unsigned long)totalSize];
        } else if (totalSize < 1024 * 1024) {
            sizeString = [NSString stringWithFormat:@"%.1f KB", totalSize / 1024.0];
        } else {
            sizeString = [NSString stringWithFormat:@"%.1f MB", totalSize / (1024.0 * 1024.0)];
        }
    }
    
    if (ENABLED(@"Show Banners")) {
        NSString *subtitle = filesDeleted > 0 ? [NSString stringWithFormat:@"Cleared %lu file%@ (%@)", (unsigned long)filesDeleted, filesDeleted == 1 ? @"" : @"s", sizeString] : @"Cache cleared.";
        [ThetaHelper showToastWithTitle:@"Cache Cleared" subtitle:subtitle icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:nil];
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (self.isSearchingSettings) {
        return nil; // No footer when searching
    }
    
    if (section == 1) { // LinkItems section
        UIView *footerView = [[UIView alloc] init];
        footerView.backgroundColor = [UIColor clearColor];
        
        UILabel *versionLabel = [[UILabel alloc] init];
        versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        versionLabel.numberOfLines = 2;
        versionLabel.textAlignment = NSTextAlignmentCenter;
        versionLabel.font = [UIFont systemFontOfSize:12];
        
        // Set light grey color regardless of dark mode
        versionLabel.textColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0];
        
        NSString *versionText = [NSString stringWithFormat:@"Made with ❤️ by @objc_msgSend\nInstagram v%@ | Theta %@", 
                                self.instagramVersion, self.thetaVersion];
        versionLabel.text = versionText;
        
        [footerView addSubview:versionLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:footerView.centerXAnchor],
            [versionLabel.centerYAnchor constraintEqualToAnchor:footerView.centerYAnchor],
            [versionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:footerView.leadingAnchor constant:20],
            [versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:footerView.trailingAnchor constant:-20]
        ]];
        
        return footerView;
    }
    
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (self.isSearchingSettings) {
        return 0; // No footer when searching
    }
    
    if (section == 1) { // LinkItems section
        return 60; // Height for the version footer
    }
    
    return UITableViewAutomaticDimension;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.isSearchingSettings) {
        if (indexPath.row >= (NSInteger)self.filteredSettings.count) return;
        SettingSearchResult *result = self.filteredSettings[indexPath.row];
        if ([result.settingType isEqualToString:@"view"]) {
            NSDictionary *settingDict = nil;
            for (NSDictionary *d in self.settingsBySubMenu[result.parentSubMenuTitle] ?: @[]) {
                if ([d[@"title"] isEqualToString:result.settingTitle]) { settingDict = d; break; }
            }
            NSString *vcClassName = settingDict[@"viewController"];
            if ([vcClassName isKindOfClass:[NSString class]] && vcClassName.length) {
                Class vcClass = NSClassFromString(vcClassName);
                if (vcClass) {
                    UIViewController *vc = [[vcClass alloc] init];
                    if (vc) [self.navigationController pushViewController:vc animated:YES];
                }
            }
        }
        return;
    }

    if (indexPath.section == 0) {
        // SubMenuItem tap
        SubMenuItem *subMenu = self.filteredSubMenus[indexPath.row];
        SubMenuViewController *subMenuViewController = [[SubMenuViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        subMenuViewController.title = subMenu.title;
        NSArray *subMenuSettings = self.settingsBySubMenu[subMenu.title] ?: @[];
        subMenuViewController.settings = subMenuSettings;
        [self.navigationController pushViewController:subMenuViewController animated:YES];
    } else if (indexPath.section == 1) {
        // Link tap
        LinkItem *link = self.linkItems[indexPath.row];
        NSURL *url = [NSURL URLWithString:link.urlString];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }
}

#pragma mark - Navbar Management

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadNavbarItems {
    // Reload the navbar items based on current "Save Audio Notes" setting
    UIImage *audioNotesImage = [UIImage systemImageNamed:@"folder"];
    audioNotesImage = [audioNotesImage imageWithTintColor:[ThetaHelper iotaPinkColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIBarButtonItem *audioNotesButton = [[UIBarButtonItem alloc] initWithImage:audioNotesImage
                                                                         style:UIBarButtonItemStylePlain
                                                                        target:self
                                                                        action:@selector(openAudioNotes)];
    
    UIImage *applyImage = [UIImage systemImageNamed:@"gearshape"];
    applyImage = [applyImage imageWithTintColor:[ThetaHelper iotaPinkColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithImage:applyImage
                                                                    style:UIBarButtonItemStyleDone
                                                                   target:self
                                                                   action:nil];
    
    // Recreate the apply menu
    UIAction *applyAction = [UIAction actionWithTitle:@"Confirm"
                                                image:[UIImage systemImageNamed:@"checkmark"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self applySettings];
    }];
    
    UIAction *cancelAction = [UIAction actionWithTitle:@"Cancel"
                                                image:[UIImage systemImageNamed:@"xmark"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
                                            
                                        }];
    
    UIMenu *applyMenu = [UIMenu menuWithTitle:@"Apply Settings" children:@[applyAction, cancelAction]];
    
    UIAction *resetAction = [UIAction actionWithTitle:@"Confirm"
                                                image:[UIImage systemImageNamed:@"arrow.clockwise"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self resetSettings];
    }];
    UIAction *cancelAction2 = [UIAction actionWithTitle:@"Cancel"
                                                image:[UIImage systemImageNamed:@"xmark"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
                                            
                                        }];
    resetAction.attributes = UIMenuElementAttributesDestructive;
    UIMenu *resetMenu = [UIMenu menuWithTitle:@"Reset Settings" children:@[resetAction, cancelAction2]];
    
    UIAction *exportSettingsActionQR = [UIAction actionWithTitle:@"Export QR Code"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self exportSettingsQR];
    }];
    
    // Rename existing to clarify behavior
    UIAction *exportSettingsAction = [UIAction actionWithTitle:@"Show QR Code"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self exportSettings];
    }];
    
    // New: actually copy JSON to clipboard
    UIAction *exportSettingsClipboardJSON = [UIAction actionWithTitle:@"Export to Clipboard"
                                                image:[UIImage systemImageNamed:@"doc.on.doc"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self exportSettingsToClipboard];
    }];
    
    UIMenu *exportMenu = [UIMenu menuWithTitle:@"Export Settings" children:@[exportSettingsActionQR, exportSettingsAction, exportSettingsClipboardJSON]];
    
    UIAction *importSettingsActionScan = [UIAction actionWithTitle:@"Scan QR Code"
                                                image:[UIImage systemImageNamed:@"qrcode.viewfinder"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self importSettingsQRScan];
    }];
    
    UIAction *importSettingsAction = [UIAction actionWithTitle:@"Import QR Code"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self importSettingsQR];
    }];
    
    UIAction *importSettingsAction2 = [UIAction actionWithTitle:@"Import from Clipboard"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                        identifier:nil
                                            handler:^(UIAction *action) {
        [self importSettings];
    }];
    
    UIMenu *importMenu = [UIMenu menuWithTitle:@"Import Settings" children:@[importSettingsAction, importSettingsActionScan, importSettingsAction2]];
    
    UIMenu *importExportMenu = [UIMenu menuWithTitle:@"Import/Export Settings" children:@[importMenu, exportMenu]];
    
    UIMenu *mainMenu = [UIMenu menuWithTitle:@"" children:@[applyMenu, importExportMenu, resetMenu]];
    [applyButton setMenu:mainMenu];
    if (@available(iOS 14.0, *)) {
        SEL sel = NSSelectorFromString(@"setShowsMenuAsPrimaryAction:");
        if ([applyButton respondsToSelector:sel]) {
            ((void (*)(id, SEL, BOOL))[applyButton methodForSelector:sel])(applyButton, sel, YES);
        }
    }
    
    // Conditionally add audioNotesButton only if "Save Audio Notes" is enabled
    NSMutableArray *rightBarButtonItems = [NSMutableArray arrayWithObject:applyButton];
    if (ENABLED(@"Save Audio Notes")) {
        [rightBarButtonItems addObject:audioNotesButton];
    }
    self.navigationItem.rightBarButtonItems = rightBarButtonItems;
}

@end