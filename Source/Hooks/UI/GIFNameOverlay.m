#define MAIN_THREAD(block) dispatch_async(dispatch_get_main_queue(), block)

static NSMutableArray *_processedIDs;
static NSMutableArray *_overlayQueue;
static dispatch_queue_t _syncQueue;
static NSMutableArray *_retainedObjects; // For debugging - retains objects to inspect in FLEX
static const NSUInteger kMaxProcessedIDs = 50;
static const NSUInteger kMaxRetainedObjects = 10; // Keep last 10 objects for inspection
static const NSTimeInterval kOverlayDisplayDuration = 5.0;
static const NSTimeInterval kFetchDelay = 1.0;

@interface IGGifOverlayManager : NSObject
+ (void)presentOverlay:(NSString *)msg;
+ (void)fetchMeta:(NSString *)mid;
+ (void)fetchGifName:(NSString *)mid completion:(void(^)(NSString *name))completion;
@end

@implementation IGGifOverlayManager

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _processedIDs = [NSMutableArray new];
        _overlayQueue = [NSMutableArray new];
        _syncQueue = dispatch_queue_create("com.theta.gifoverlay.sync", DISPATCH_QUEUE_SERIAL);
    });
}

+ (void)presentOverlay:(NSString *)msg {
    if (!msg || msg.length == 0) return;
    
    MAIN_THREAD(^{
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (!win) return;
        
        UIFont *font = [UIFont boldSystemFontOfSize:12];
        CGFloat maxW = win.frame.size.width - 40;
        
        CGRect rect = [msg boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                                        options:NSStringDrawingUsesLineFragmentOrigin
                                     attributes:@{NSFontAttributeName: font}
                                        context:nil];
        
        CGFloat w = MIN(rect.size.width + 30, maxW);
        CGFloat h = MAX(rect.size.height + 16, 30);
        CGFloat yPos = 60;
        
        __block UIView *lastOverlay = nil;
        dispatch_sync(_syncQueue, ^{
            if (_overlayQueue.count > 0) {
                lastOverlay = [_overlayQueue lastObject];
            }
        });
        
        if (lastOverlay && lastOverlay.superview) {
            yPos = lastOverlay.frame.origin.y + lastOverlay.frame.size.height + 8;
        }
        
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, yPos, w, h)];
        lbl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        lbl.textColor = [UIColor whiteColor];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.font = font;
        lbl.text = msg;
        lbl.numberOfLines = 0;
        lbl.layer.cornerRadius = 8;
        lbl.clipsToBounds = YES;
        lbl.alpha = 0;

        ThetaSetCaptureHiding(lbl);
        [win addSubview:lbl];

        dispatch_async(_syncQueue, ^{
            [_overlayQueue addObject:lbl];
        });
        
        [UIView animateWithDuration:0.3 animations:^{
            lbl.alpha = 1;
        }];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOverlayDisplayDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!lbl.superview) return;
            
            [UIView animateWithDuration:0.5 animations:^{
                lbl.alpha = 0;
            } completion:^(BOOL finished) {
                [lbl removeFromSuperview];
                dispatch_async(_syncQueue, ^{
                    [_overlayQueue removeObject:lbl];
                });
            }];
        });
    });
}

+ (void)fetchMeta:(NSString *)mid {
    if (!mid || mid.length < 5) return;

    NSString *escapedID = [mid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    if (!escapedID) return;
    
    NSString *urlStr = [NSString stringWithFormat:@"https://giphy.com/gifs/%@", escapedID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.cachePolicy = NSURLRequestReturnCacheDataElseLoad;
    req.timeoutInterval = 10.0;
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) return;
        
        if (![response isKindOfClass:[NSHTTPURLResponse class]]) return;
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) return;
        
        NSString *abs = response.URL.absoluteString;
        if (!abs || ![abs containsString:@"/gifs/"]) return;
        
        NSArray *components = [abs componentsSeparatedByString:@"/gifs/"];
        if (components.count < 2) return;
        
        NSString *slug = components[1];
        if (!slug || slug.length == 0) return;
        
        NSRange range = [slug rangeOfString:@"-" options:NSBackwardsSearch];
        if (range.location == NSNotFound || range.location == 0) return;
        
        NSString *raw = [slug substringToIndex:range.location];
        if (raw.length == 0) return;
        
        NSString *final = [[raw stringByReplacingOccurrencesOfString:@"-" withString:@" "] capitalizedString];
        if (final.length == 0) return;
        
        NSString *out = [NSString stringWithFormat:@"GIF: %@", final];
        [IGGifOverlayManager presentOverlay:out];
    }] resume];
}

+ (void)fetchGifName:(NSString *)mid completion:(void(^)(NSString *name))completion {
    if (!mid || mid.length < 5 || !completion) {
        if (completion) completion(nil);
        return;
    }

    NSString *escapedID = [mid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    if (!escapedID) {
        completion(nil);
        return;
    }
    
    NSString *urlStr = [NSString stringWithFormat:@"https://giphy.com/gifs/%@", escapedID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        completion(nil);
        return;
    }
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.cachePolicy = NSURLRequestReturnCacheDataElseLoad;
    req.timeoutInterval = 10.0;
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil);
            return;
        }
        
        if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
            completion(nil);
            return;
        }
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            completion(nil);
            return;
        }
        
        NSString *abs = response.URL.absoluteString;
        if (!abs || ![abs containsString:@"/gifs/"]) {
            completion(nil);
            return;
        }
        
        NSArray *components = [abs componentsSeparatedByString:@"/gifs/"];
        if (components.count < 2) {
            completion(nil);
            return;
        }
        
        NSString *slug = components[1];
        if (!slug || slug.length == 0) {
            completion(nil);
            return;
        }
        
        NSRange range = [slug rangeOfString:@"-" options:NSBackwardsSearch];
        if (range.location == NSNotFound || range.location == 0) {
            completion(nil);
            return;
        }
        
        NSString *raw = [slug substringToIndex:range.location];
        if (raw.length == 0) {
            completion(nil);
            return;
        }
        
        NSString *final = [[raw stringByReplacingOccurrencesOfString:@"-" withString:@" "] capitalizedString];
        if (final.length == 0) {
            completion(nil);
            return;
        }
        
        completion(final);
    }] resume];
}

@end