#import "Include/MessagesManager.h"
#import "Include/CustomToastView.h"
#import "Include/ThetaHelper.h"

#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]

@implementation MessagesManager

NSString *const plistFileName = @"deleted_messages.plist";

// Image generation moved to ThetaHelper

// Toast functionality moved to ThetaHelper

// Haptic feedback moved to ThetaHelper

+ (instancetype)sharedManager {
    static MessagesManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (NSString *)plistPath {
    NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [documentsDirectory stringByAppendingPathComponent:plistFileName];
}

- (NSMutableDictionary *)loadPlistData {
    NSString *path = [self plistPath];
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!data) {
        data = [NSMutableDictionary dictionary];
    }
    return data;
}

- (void)savePlistData:(NSDictionary *)data {
    NSString *path = [self plistPath];
    [data writeToFile:path atomically:YES];
}

- (void)saveDeletedMessageWithID:(NSString *)messageID {
    if (messageID.length == 0) {
        NSLog(@"Message ID cannot be empty.");
        return;
    }
    
    NSMutableDictionary *plistData = [self loadPlistData];
    NSString *currentDate = [[NSDate date] description];
    plistData[messageID] = currentDate;
    [self savePlistData:plistData];

    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Someone deleted a message." subtitle:nil icon:[ThetaHelper imageFromEmojiString:@"🗑️" width:60] autoHide:4 openURL:nil];
    }
}

- (BOOL)messageExistsWithID:(NSString *)messageID {
    if (messageID.length == 0) {
        NSLog(@"Message ID cannot be empty.");
        return NO;
    }
    
    NSMutableDictionary *plistData = [self loadPlistData];
    return plistData[messageID] != nil;
}

- (NSString *)dateForDeletedMessageWithID:(NSString *)messageID {
    if (messageID.length == 0) {
        NSLog(@"Message ID cannot be empty.");
        return nil;
    }
    
    NSMutableDictionary *plistData = [self loadPlistData];
    return plistData[messageID];
}
@end