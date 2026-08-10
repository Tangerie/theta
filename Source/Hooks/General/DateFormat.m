#import "Include/ThetaTweakCommon.h"
#import <objc/runtime.h>

// Maps segment index to NSDateFormatter format pattern
// Indices match SettingsViewController Date Format options:
//   0=Default, 1=Short (MMM d), 2=Medium (MMM d yyyy),
//   3=12h, 4=24h, 5=ISO, 6=ISO+T
static NSString *THDateFormatPattern(NSInteger idx, BOOL withTime) {
    switch (idx) {
        case 1:  return @"MMM d";
        case 2:  return @"MMM d, yyyy";
        case 3:  return withTime ? @"MMM d 'at' h:mm a"  : @"MMM d";
        case 4:  return withTime ? @"MMM d 'at' HH:mm"   : @"MMM d";
        case 5:  return @"yyyy-MM-dd";
        case 6:  return withTime ? @"yyyy-MM-dd HH:mm"   : @"yyyy-MM-dd";
        default: return nil;
    }
}

static NSString *THFormattedDate(NSDate *date) {
    NSInteger idx = [[NSUserDefaults standardUserDefaults] integerForKey:@"Date Format_SegmentIndex"];
    if (idx <= 0) return nil;
    NSString *pattern = THDateFormatPattern(idx, YES);
    if (!pattern) return nil;
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; });
    df.dateFormat = pattern;
    return [df stringFromDate:date];
}

// Hook: formattedDateInMixedFormat (feed post timestamps)
static NSString *(*orig_mixedFormat)(NSDate *, SEL);
static NSString *hook_mixedFormat(NSDate *self, SEL _cmd) {
    NSString *r = THFormattedDate(self);
    return r ?: orig_mixedFormat(self, _cmd);
}

// Hook: formattedDateRelativeToNow (notes, comments, stories)
static NSString *(*orig_relativeNow)(NSDate *, SEL);
static NSString *hook_relativeNow(NSDate *self, SEL _cmd) {
    NSString *r = THFormattedDate(self);
    return r ?: orig_relativeNow(self, _cmd);
}

// Hook: shortenedFormattedDateRelativeToNow
static NSString *(*orig_shortRelNow)(NSDate *, SEL);
static NSString *hook_shortRelNow(NSDate *self, SEL _cmd) {
    NSString *r = THFormattedDate(self);
    return r ?: orig_shortRelNow(self, _cmd);
}

// Hook: shortenedFormattedDateRelativeToNowHideSeconds: (DMs)
static NSString *(*orig_shortRelHideSeconds)(NSDate *, SEL, NSInteger);
static NSString *hook_shortRelHideSeconds(NSDate *self, SEL _cmd, NSInteger hideSeconds) {
    NSString *r = THFormattedDate(self);
    return r ?: orig_shortRelHideSeconds(self, _cmd, hideSeconds);
}

void THRegisterDateFormatHooks(void) {
    Class cls = [NSDate class];

    SEL mixed = sel_registerName("formattedDateInMixedFormat");
    if ([cls instancesRespondToSelector:mixed]) {
        NullHookMessageEx(cls, mixed, (void *)hook_mixedFormat, &orig_mixedFormat);
    }

    SEL rel = sel_registerName("formattedDateRelativeToNow");
    if ([cls instancesRespondToSelector:rel]) {
        NullHookMessageEx(cls, rel, (void *)hook_relativeNow, &orig_relativeNow);
    }

    SEL shortRel = sel_registerName("shortenedFormattedDateRelativeToNow");
    if ([cls instancesRespondToSelector:shortRel]) {
        NullHookMessageEx(cls, shortRel, (void *)hook_shortRelNow, &orig_shortRelNow);
    }

    SEL shortRelHs = sel_registerName("shortenedFormattedDateRelativeToNowHideSeconds:");
    if ([cls instancesRespondToSelector:shortRelHs]) {
        NullHookMessageEx(cls, shortRelHs, (void *)hook_shortRelHideSeconds, &orig_shortRelHideSeconds);
    }
}
