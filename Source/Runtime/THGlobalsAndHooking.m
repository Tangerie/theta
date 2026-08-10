/*
 * Shared tweak globals + ObjC method swizzle helpers.
 * Concatenated first into TweakCOMPILE.xm by scripts/assemble.py.
 */

#import "Include/ThetaTweakCommon.h"
#import "Include.h"
#import "Include/THProfileAnalyzerViewController.h"
#import "fishhook.h"
#import <Photos/Photos.h>
#import "Include/ThetaHelper.h"
#import <os/log.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <UserNotifications/UserNotifications.h>
#import <mach-o/loader.h>
#import <Security/Security.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#import <Foundation/Foundation.h>

NSString *appVersion;
NSString *keychainAccessGroup;
NSURL *fakeGroupContainerURL;
static BOOL shouldBeSeen = false;
static BOOL storeUserSearch = NO;
static NSTimeInterval lastSpamTime = 0;
static BOOL hooksInitialized = NO;
static NSTimeInterval s_lastToastShowTime = 0;

static NSMutableArray *sFailedHookLines;
static NSLock *sFailedHookLock;

static void FailedHooksEnsureInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFailedHookLines = [NSMutableArray array];
        sFailedHookLock = [[NSLock alloc] init];
    });
}

static void RecordFailedHookLine(NSString *line) {
    if (!line.length) return;
    FailedHooksEnsureInit();
    [sFailedHookLock lock];
    [sFailedHookLines addObject:[line copy]];
    [sFailedHookLock unlock];
}

static UIViewController *ThetaPresenterForAlert(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *window = app.keyWindow;
    if (!window) {
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow && !w.hidden) {
                window = w;
                break;
            }
        }
    }
    if (!window && app.windows.count) {
        window = app.windows[0];
    }
    if (!window) return nil;
    UIViewController *vc = window.rootViewController;
    while (vc && vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

static void PresentAggregatedHookFailureAlert(void) {
    FailedHooksEnsureInit();
    NSArray *lines;
    [sFailedHookLock lock];
    lines = [sFailedHookLines copy];
    [sFailedHookLines removeAllObjects];
    [sFailedHookLock unlock];
    if (lines.count == 0) return;

    NSUInteger n = lines.count;
    NSString *title = [NSString stringWithFormat:@"Theta Hook Errors (%lu)", (unsigned long)n];
    NSString *message = [lines componentsJoinedByString:@"\n"];
    const NSUInteger kMaxLen = 3500;
    if (message.length > kMaxLen) {
        message = [[message substringToIndex:kMaxLen] stringByAppendingString:@"…"];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

    UIViewController *root = ThetaPresenterForAlert();
    if (root) {
        [root presentViewController:alert animated:YES completion:nil];
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *retry = ThetaPresenterForAlert();
            if (retry) {
                [retry presentViewController:alert animated:YES completion:nil];
            }
        });
    }
}

/** KVC that never throws (Swift/ObjC ivars often aren't KVC-compliant). */
static id ThetaValueForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void ThetaSetValueForKey(id obj, id value, NSString *key) {
    if (!obj || !key.length) return;
    @try {
        [obj setValue:value forKey:key];
    } @catch (__unused NSException *e) {
    }
}

static void ThetaSetCaptureHiding(UIView *view) {
    if (!view) return;
    if (ENABLED(@"Hide Theta From Screenshots")) {
        ThetaSetValueForKey(view.layer, @((1 << 1) | (1 << 4)), @"disableUpdateMask");
    }
}

/**
 * Safe ObjC swizzle.
 *
 * IMPORTANT: class_replaceMethod() returns NULL when it *adds* an override for an
 * inherited method. Using that return value as `orig` leaves a NULL function
 * pointer and crashes on first call (EXC_BAD_ACCESS / PC=0). Always capture the
 * IMP via method_getImplementation / class_addMethod+method_setImplementation.
 */
static BOOL ThetaInstallMessageHook(Class cls, SEL sel, void *replacement, void *original, BOOL reportMissing) {
    if (!cls || !replacement) {
        if (reportMissing && !cls) {
            RecordFailedHookLine([NSString stringWithFormat:@"Class is nil for %@", NSStringFromSelector(sel)]);
        }
        return NO;
    }

    Method instanceMethod = class_getInstanceMethod(cls, sel);
    Method classMethod = instanceMethod ? NULL : class_getClassMethod(cls, sel);
    Method method = instanceMethod ?: classMethod;
    if (!method) {
        if (reportMissing) {
            NSLog(@"-[%@ %@] not found", NSStringFromClass(cls), NSStringFromSelector(sel));
            RecordFailedHookLine([NSString stringWithFormat:@"-[%@ %@] — method not found", NSStringFromClass(cls), NSStringFromSelector(sel)]);
        }
        return NO;
    }

    const char *types = method_getTypeEncoding(method);
    IMP real = method_getImplementation(method);
    if (!real) {
        if (reportMissing) {
            RecordFailedHookLine([NSString stringWithFormat:@"-[%@ %@] — NULL IMP", NSStringFromClass(cls), NSStringFromSelector(sel)]);
        }
        return NO;
    }

    Class targetClass = instanceMethod ? cls : object_getClass((id)cls);
    IMP previous = NULL;

    if (class_addMethod(targetClass, sel, (IMP)replacement, types)) {
        // Method was inherited; we added an override. `real` is the super IMP.
        previous = real;
    } else {
        // Method already exists on this class — swap implementation.
        Method local = instanceMethod ? class_getInstanceMethod(targetClass, sel)
                                      : class_getClassMethod(cls, sel);
        if (!local) local = method;
        previous = method_setImplementation(local, (IMP)replacement);
        if (!previous) previous = real;
    }

    if (original) {
        *(IMP *)original = previous;
    }
    return previous != NULL;
}

static void NullHookMessageEx(Class cls, SEL sel, void *replacement, void *original) {
    (void)ThetaInstallMessageHook(cls, sel, replacement, original, YES);
}

/** Silent install when class/selector may be absent across IG versions. */
static void NullHookMessageIfPresent(Class cls, SEL sel, void *replacement, void *original) {
    (void)ThetaInstallMessageHook(cls, sel, replacement, original, NO);
}

static void NullHookMessage(Class cls, SEL sel, void *replacement) {
    if (!cls) {
        RecordFailedHookLine(@"class_addMethod: target class is nil");
        return;
    }
    if (!class_addMethod(cls, sel, (IMP)replacement, "v@:")) {
        RecordFailedHookLine([NSString stringWithFormat:@"-[%@ %@] — class_addMethod failed", NSStringFromClass(cls), NSStringFromSelector(sel)]);
    }
}

/** First NSClassFromString hit across ObjC + Swift mangled names. */
static Class ThetaFirstClass(NSArray<NSString *> *names) {
    if (!names.count) return Nil;
    for (NSString *name in names) {
        if (![name isKindOfClass:[NSString class]] || !name.length) continue;
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }
    return Nil;
}

/** Hook first available (class, selector) pair; silent if none match. */
static BOOL ThetaHookFirst(NSArray<NSString *> *classNames, NSArray<NSString *> *selectorNames, void *replacement, void *original) {
    Class cls = ThetaFirstClass(classNames);
    if (!cls) return NO;
    for (NSString *selName in selectorNames) {
        if (![selName isKindOfClass:[NSString class]] || !selName.length) continue;
        SEL sel = NSSelectorFromString(selName);
        if (!sel) continue;
        Method method = class_getInstanceMethod(cls, sel) ?: class_getClassMethod(cls, sel);
        if (!method) continue;
        NullHookMessageIfPresent(cls, sel, replacement, original);
        return YES;
    }
    return NO;
}
