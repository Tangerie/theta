#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>

#import "Include/SettingsViewController.h"
#import "Include/SubMenuViewController.h"
#import "Include/CustomToastView.h"
#import "Include/MediaSelectionViewController.h"
#import "Include/MediaViewController.h"
#import "Include/SecurityViewController.h"
#import "Include/MessagesManager.h"
#import "Include/StoryGesturesNuxViewController.h"
#import "Include/InstagramHeaders.h"

#define IOTA_PINK [UIColor colorWithRed:1.0 green:0.412 blue:0.706 alpha:1.0]
static BOOL isFirstRecentSearchCall = YES;

// Top view controller utility moved to ThetaHelper

// Function declarations
static void downloadProfilePicture(id self);
static void performProfilePictureDownloadWithURL(NSURL *imageURL);
static void performStoryDownloadWithURL(NSURL *url);

typedef void (^GestureActionBlock)(UIGestureRecognizer *recognizer);

@interface UIGestureRecognizer (Block)
@property (nonatomic, copy) GestureActionBlock actionBlock;
@end

// Externs for sideload accessGroup hooks (see Source/Hooks/Sideload)
extern NSString *(*orig_accessGroup_FBSDKKeychainStore)(id self, SEL _cmd);
extern NSString *(*orig_accessGroup_FBKeychainItemController)(id self, SEL _cmd);
extern NSString *(*orig_accessGroup_UICKeyChainStore)(id self, SEL _cmd);
extern NSString *hook_accessGroup_FBSDKKeychainStore(id self, SEL _cmd);
extern NSString *hook_accessGroup_FBKeychainItemController(id self, SEL _cmd);
extern NSString *hook_accessGroup_UICKeyChainStore(id self, SEL _cmd);

extern id (*orig_LS_initWithServiceIDAccessGroupUserIDSync)(id self, SEL _cmd, id serviceID, id accessGroup, id userID, BOOL sync);
extern id hook_LS_initWithServiceIDAccessGroupUserIDSync(id self, SEL _cmd, id serviceID, id accessGroup, id userID, BOOL sync);
extern id (*orig_LS_initWithServiceIDAccessGroupUserID)(id self, SEL _cmd, id serviceID, id accessGroup, id userID);
extern id hook_LS_initWithServiceIDAccessGroupUserID(id self, SEL _cmd, id serviceID, id accessGroup, id userID);
extern id (*orig_LS_initSynchronizableItem)(id self, SEL _cmd, id serviceID, id accessGroup, id userID);
extern id hook_LS_initSynchronizableItem(id self, SEL _cmd, id serviceID, id accessGroup, id userID);
extern id (*orig_UIC_keyChainStoreWithServiceAccessGroup)(id self, SEL _cmd, id service, id accessGroup);
extern id hook_UIC_keyChainStoreWithServiceAccessGroup(id self, SEL _cmd, id service, id accessGroup);
extern id (*orig_NSDictionary_queryWithAccessGroupKey)(id self, SEL _cmd, id accessGroup);
extern id hook_NSDictionary_queryWithAccessGroupKey(id self, SEL _cmd, id accessGroup);
extern id (*orig_FWA_keychainSecureStoreByInferring)(id self, SEL _cmd, id accessGroup);
extern id hook_FWA_keychainSecureStoreByInferring(id self, SEL _cmd, id accessGroup);
extern id (*orig_IGCloudTrust_initWithAccessGroup)(id self, SEL _cmd, id accessGroup);
extern id hook_IGCloudTrust_initWithAccessGroup(id self, SEL _cmd, id accessGroup);

@implementation UIGestureRecognizer (Block)
- (void)setActionBlock:(GestureActionBlock)block {
    objc_setAssociatedObject(self, @selector(actionBlock), block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self addTarget:self action:@selector(handleActionBlock:)];
}
- (GestureActionBlock)actionBlock {
    return objc_getAssociatedObject(self, @selector(actionBlock));
}
- (void)handleActionBlock:(UIGestureRecognizer *)recognizer {
    if (self.actionBlock) self.actionBlock(recognizer);
}
@end