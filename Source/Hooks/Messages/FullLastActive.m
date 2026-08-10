#import "Include/ThetaTweakCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSDateFormatter *THDMDateFormatter(void) {
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"MMM d 'at' h:mm a";
    });
    return df;
}

// Replace "Active Xm/h ago" with a full formatted timestamp
static void THUpdateSubtitleLabel(UIView *titleView) {
    if (!ENABLED(@"Full Last Active Date")) return;

    Ivar subIvar = class_getInstanceVariable([titleView class], "_subtitleLabel");
    if (!subIvar) return;
    UILabel *label = object_getIvar(titleView, subIvar);
    if (![label isKindOfClass:[UILabel class]]) return;

    NSString *text = label.text;
    if (!text.length) return;

    // Only replace "Active X ago" patterns
    if (![text hasPrefix:@"Active "] || ![text hasSuffix:@"ago"]) return;

    // Try to get lastActiveDate from view model
    Ivar vmIvar = class_getInstanceVariable([titleView class], "_titleViewModel");
    id vm = vmIvar ? object_getIvar(titleView, vmIvar) : nil;
    NSDate *activeDate = nil;

    if (vm) {
        for (NSString *key in @[@"lastActiveDate", @"lastActive", @"activeDate"]) {
            if ([vm respondsToSelector:NSSelectorFromString(key)]) {
                id val = [vm valueForKey:key];
                if ([val isKindOfClass:[NSDate class]]) { activeDate = val; break; }
                if ([val isKindOfClass:[NSNumber class]]) {
                    activeDate = [NSDate dateWithTimeIntervalSince1970:[(NSNumber *)val doubleValue]];
                    break;
                }
            }
        }
    }

    // Fallback: parse the label text
    if (!activeDate) {
        NSTimeInterval delta = 0;
        NSScanner *scanner = [NSScanner scannerWithString:text];
        [scanner scanString:@"Active " intoString:nil];
        double val = 0;
        if ([scanner scanDouble:&val]) {
            NSString *rest = [text substringFromIndex:scanner.scanLocation];
            if ([rest hasPrefix:@"m"])      delta = val * 60;
            else if ([rest hasPrefix:@"h"]) delta = val * 3600;
            else if ([rest hasPrefix:@"d"]) delta = val * 86400;
        }
        if (delta > 0) activeDate = [NSDate dateWithTimeIntervalSinceNow:-delta];
    }

    if (!activeDate) return;

    NSString *formatted = [THDMDateFormatter() stringFromDate:activeDate];
    if (!formatted.length) return;

    label.text = formatted;

    Ivar svIvar = class_getInstanceVariable([titleView class], "_subtitleView");
    if (svIvar) {
        id sv = object_getIvar(titleView, svIvar);
        if ([sv isKindOfClass:[UILabel class]]) [(UILabel *)sv setText:formatted];
    }
    Ivar tsIvar = class_getInstanceVariable([titleView class], "_transitionalSubtitleLabel");
    if (tsIvar) {
        id ts = object_getIvar(titleView, tsIvar);
        if ([ts isKindOfClass:[UILabel class]]) [(UILabel *)ts setText:formatted];
    }
}

static void (*orig_setTitleViewModel)(id, SEL, id);
static void hook_setTitleViewModel(id self, SEL _cmd, id vm) {
    orig_setTitleViewModel(self, _cmd, vm);
    THUpdateSubtitleLabel(self);
}

static void (*orig_animCoordDidUpdate)(id, SEL, id);
static void hook_animCoordDidUpdate(id self, SEL _cmd, id coordinator) {
    orig_animCoordDidUpdate(self, _cmd, coordinator);
    THUpdateSubtitleLabel(self);
}

void THRegisterFullLastActiveHooks(void) {
    Class cls = objc_getClass("IGDirectLeftAlignedTitleView");
    NullHookMessageEx(cls, @selector(setTitleViewModel:), (void *)hook_setTitleViewModel, &orig_setTitleViewModel);
    NullHookMessageEx(cls, @selector(animationCoordinatorDidUpdate:), (void *)hook_animCoordDidUpdate, &orig_animCoordDidUpdate);
}
