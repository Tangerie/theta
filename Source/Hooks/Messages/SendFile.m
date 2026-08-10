#import "Include/ThetaTweakCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL sTHFileMenuPending = NO;
static __weak UIViewController *sTHFileThreadVC = nil;

// MARK: - Document picker delegate

@interface _THFilePickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *threadVC;
@end

static _THFilePickerDelegate *sTHFilePickerDelegate = nil;

@implementation _THFilePickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url || !self.threadVC) return;

    id msgSenderFC = nil;
    @try { msgSenderFC = [self.threadVC valueForKey:@"messageSenderFeatureController"]; } @catch (__unused id e) {}
    if (!msgSenderFC) { return; }

    id sender = nil;
    @try { sender = [msgSenderFC valueForKey:@"messageSender"]; } @catch (__unused id e) {}
    if (!sender) { return; }

    SEL sendSel = NSSelectorFromString(@"sendFileWithURL:threadKey:attribution:replyMessagePk:quotedPublishedMessage:messageSentSpeedLogger:messageSentSpeedMarker:localSendSpeedLogger:localSendSpeedMarker:");
    if (![sender respondsToSelector:sendSel]) { return; }

    id threadKey = nil;
    @try { threadKey = [self.threadVC valueForKey:@"threadKey"]; } @catch (__unused id e) {}
    if (!threadKey) { return; }

    typedef void (*SendFn)(id, SEL, id, id, id, id, id, id, id, id, id);
    ((SendFn)objc_msgSend)(sender, sendSel, url, threadKey, nil, nil, nil, nil, nil, nil, nil);
}

@end

static void THShowFilePicker(UIViewController *threadVC) {
    sTHFilePickerDelegate = [_THFilePickerDelegate new];
    sTHFilePickerDelegate.threadVC = threadVC;

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                               inMode:UIDocumentPickerModeImport];
    picker.delegate = sTHFilePickerDelegate;
    picker.allowsMultipleSelection = NO;
    [threadVC presentViewController:picker animated:YES completion:nil];
}

// MARK: - Plus menu injection

static id (*orig_IGDSMenu_init)(id, SEL, NSArray *, BOOL, id);
static id hook_IGDSMenu_init(id self, SEL _cmd, NSArray *items, BOOL edr, id header) {
    if (!ENABLED(@"Send Files") || !sTHFileMenuPending) {
        return orig_IGDSMenu_init(self, _cmd, items, edr, header);
    }
    sTHFileMenuPending = NO;

    // Avoid duplicating the item
    for (id item in items) {
        if ([item respondsToSelector:NSSelectorFromString(@"title")]) {
            id title = [item valueForKey:@"title"];
            if ([title isKindOfClass:[NSString class]] && [title isEqualToString:@"Send File"]) {
                return orig_IGDSMenu_init(self, _cmd, items, edr, header);
            }
        }
    }

    Class itemClass = NSClassFromString(@"IGDSMenuItem");
    if (!itemClass) return orig_IGDSMenu_init(self, _cmd, items, edr, header);

    UIImage *img = [[UIImage systemImageNamed:@"doc"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    void (^handler)(void) = ^{
        if (sTHFileThreadVC) THShowFilePicker(sTHFileThreadVC);
    };

    SEL initSel = @selector(initWithTitle:image:handler:);
    if (![itemClass instancesRespondToSelector:initSel]) {
        return orig_IGDSMenu_init(self, _cmd, items, edr, header);
    }

    typedef id (*InitFn)(id, SEL, id, id, id);
    id fileItem = ((InitFn)objc_msgSend)([itemClass alloc], initSel, @"Send File", img, handler);
    if (!fileItem) return orig_IGDSMenu_init(self, _cmd, items, edr, header);

    NSMutableArray *newItems = [NSMutableArray arrayWithObject:fileItem];
    [newItems addObjectsFromArray:items];
    return orig_IGDSMenu_init(self, _cmd, newItems, edr, header);
}

// MARK: - Thread VC hook

static void (*orig_composerOverflow)(id, SEL, id);
static void hook_composerOverflow(id self, SEL _cmd, id plusButton) {
    orig_composerOverflow(self, _cmd, plusButton);
    if (!ENABLED(@"Send Files")) return;
    sTHFileThreadVC = (UIViewController *)self;
    sTHFileMenuPending = YES;
}

void THRegisterSendFileHooks(void) {
    Class menuCls = objc_getClass("IGDSMenu");
    SEL menuSel = @selector(initWithMenuItems:edr:headerLabelText:);
    NullHookMessageEx(menuCls, menuSel, (void *)hook_IGDSMenu_init, &orig_IGDSMenu_init);

    Class threadCls = objc_getClass("IGDirectThreadViewController");
    SEL overflowSel = @selector(composerOverflowButtonMenuWillPrepareExpandWithPlusButton:);
    NullHookMessageEx(threadCls, overflowSel, (void *)hook_composerOverflow, &orig_composerOverflow);
}
