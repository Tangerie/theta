static char kThetaSortGridLongPressOnceKey;
static char kThetaSortGridAscendingKey;
static char kThetaSortApplyOnceKey;
static char kThetaSortLastToggleTimeKey;
static char kThetaOrigObjectsIMPKey;
static NSArray *theta_sortedObjectsForListAdapter(id selfObj, SEL _cmd, id adapter);

static void theta_installObjectsHookIfNeeded(id dataSource) {
    if (!dataSource) return;
    Class cls = [dataSource class];
    if (!cls) return;
    if (objc_getAssociatedObject(cls, &kThetaOrigObjectsIMPKey)) {
        return; // already installed
    }
    SEL sel = NSSelectorFromString(@"objectsForListAdapter:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    objc_setAssociatedObject(cls, &kThetaOrigObjectsIMPKey, [NSValue valueWithPointer:(const void *)orig], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    class_replaceMethod(cls, sel, (IMP)theta_sortedObjectsForListAdapter, method_getTypeEncoding(m));
}

static NSTimeInterval theta_timestampForItem(id item) {
    @try {
        id taken = [item valueForKeyPath:@"media.takenAtDate"];
        if ([taken isKindOfClass:[NSDate class]]) return [(NSDate *)taken timeIntervalSince1970];
        if ([taken respondsToSelector:@selector(doubleValue)]) return [taken doubleValue];
    } @catch (__unused NSException *e) {}
    @try {
        id taken = [item valueForKeyPath:@"feedItem.media.takenAtDate"];
        if ([taken isKindOfClass:[NSDate class]]) return [(NSDate *)taken timeIntervalSince1970];
        if ([taken respondsToSelector:@selector(doubleValue)]) return [taken doubleValue];
    } @catch (__unused NSException *e) {}
    @try {
        id media = [item respondsToSelector:@selector(media)] ? [item performSelector:@selector(media)] : [item valueForKey:@"media"];
        id taken = [media valueForKey:@"takenAtDate"];
        if ([taken isKindOfClass:[NSDate class]]) return [(NSDate *)taken timeIntervalSince1970];
        if ([taken respondsToSelector:@selector(doubleValue)]) return [taken doubleValue];
    } @catch (__unused NSException *e) {}
    @try {
        id vm = [item valueForKey:@"viewModel"];
        if (vm) {
            id media = [vm valueForKey:@"media"];
            id taken = [media valueForKey:@"takenAtDate"];
            if ([taken isKindOfClass:[NSDate class]]) return [(NSDate *)taken timeIntervalSince1970];
            if ([taken respondsToSelector:@selector(doubleValue)]) return [taken doubleValue];
        }
    } @catch (__unused NSException *e) {}
    @try {
        id m = [item valueForKeyPath:@"_media"] ?: [item valueForKeyPath:@"model.media"];
        id taken = [m valueForKey:@"takenAtDate"];
        if ([taken isKindOfClass:[NSDate class]]) return [(NSDate *)taken timeIntervalSince1970];
        if ([taken respondsToSelector:@selector(doubleValue)]) return [taken doubleValue];
    } @catch (__unused NSException *e) {}
    return 0;
}

static NSArray *theta_sortedObjectsForListAdapter(id selfObj, SEL _cmd, id adapter) {
    NSValue *v = objc_getAssociatedObject([selfObj class], &kThetaOrigObjectsIMPKey);
    IMP orig = (IMP)[v pointerValue];
    NSArray *objects = nil;
    if (orig) {
        NSArray *(*origCall)(id, SEL, id) = (NSArray *(*)(id, SEL, id))orig;
        objects = origCall(selfObj, _cmd, adapter);
    }
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0) return objects;

    NSNumber *ascNum = objc_getAssociatedObject(adapter, &kThetaSortGridAscendingKey);
    if (!ascNum) return objects;
    BOOL ascending = ascNum.boolValue;

    NSUInteger count = objects.count;
    NSMutableArray<NSNumber *> *times = [NSMutableArray arrayWithCapacity:count];
    for (id obj in objects) {
        [times addObject:@(theta_timestampForItem(obj))];
    }
    NSMutableString *sampleLog = [NSMutableString stringWithString:@"["]; 
    NSUInteger sample = MIN((NSUInteger)6, count);
    for (NSUInteger i = 0; i < sample; i++) {
        id obj = objects[i];
        NSTimeInterval t = times[i].doubleValue;
        [sampleLog appendFormat:@"(%@, %.0f)", NSStringFromClass([obj class]), t];
        if (i + 1 < sample) [sampleLog appendString:@", "];
    }
    [sampleLog appendString:@"]"]; 

    NSMutableArray *sortableObjects = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sortablePositions = [NSMutableArray array];
    for (NSUInteger i = 0; i < objects.count; i++) {
        id obj = objects[i];
        NSTimeInterval ts = theta_timestampForItem(obj);
        if (ts > 0) {
            [sortableObjects addObject:obj];
            [sortablePositions addObject:@(i)];
        }
    }

    if (sortableObjects.count <= 1) {
        NSLog(@"[SortUserGridPosts] objectsForListAdapter: not enough sortable items; returning original. sample=%@", sampleLog);
        return objects;
    }

    [sortableObjects sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSTimeInterval tA = theta_timestampForItem(a);
        NSTimeInterval tB = theta_timestampForItem(b);
        if (ascending) {
            if (tA < tB) return NSOrderedAscending;
            if (tA > tB) return NSOrderedDescending;
        } else {
            if (tA > tB) return NSOrderedAscending;
            if (tA < tB) return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSMutableArray *rebuilt = [objects mutableCopy];
    for (NSUInteger k = 0; k < sortablePositions.count; k++) {
        NSUInteger pos = sortablePositions[k].unsignedIntegerValue;
        rebuilt[pos] = sortableObjects[k];
    }

    NSLog(@"[SortUserGridPosts] objectsForListAdapter: reordered sortable=%@ (ascending=%@) sample=%@", @(sortableObjects.count), ascending ? @"YES" : @"NO", sampleLog);
    return rebuilt;
}
static void (*orig_sortUserPostsGrid)(id self, SEL _cmd);
static void hook_sortUserPostsGrid(id self, SEL _cmd) {
    if (orig_sortUserPostsGrid) orig_sortUserPostsGrid(self, _cmd);

    // Property access — valueForKey: can throw on some UICollectionView subclasses during layout.
    NSString *accessibilityLabel = nil;
    if ([self respondsToSelector:@selector(accessibilityLabel)]) {
        accessibilityLabel = [self accessibilityLabel];
    }
    if (![accessibilityLabel isKindOfClass:[NSString class]]) return;
    if ([accessibilityLabel isEqualToString:@"Grid"]) {
        NSNumber *alreadyAdded = objc_getAssociatedObject(self, &kThetaSortGridLongPressOnceKey);
        if ([alreadyAdded boolValue]) return;

        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] init];
        longPress.minimumPressDuration = 0.5;
        longPress.cancelsTouchesInView = NO;
        __weak typeof(self) weakSelf = self;
        longPress.actionBlock = ^(UIGestureRecognizer *recognizer) {
            if (recognizer.state != UIGestureRecognizerStateBegan) return;
            NSNumber *lastTsNum = objc_getAssociatedObject(self, &kThetaSortLastToggleTimeKey);
            CFAbsoluteTime nowTs = CFAbsoluteTimeGetCurrent();
            if (lastTsNum && (nowTs - lastTsNum.doubleValue) < 0.8) return;
            objc_setAssociatedObject(self, &kThetaSortLastToggleTimeKey, @(nowTs), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf isKindOfClass:[UIView class]]) return;

            UIViewController *nearestViewController = [ThetaHelper nearestViewController:(UIView *)strongSelf];
            if (![nearestViewController isKindOfClass:NSClassFromString(@"IGProfileViewController")]) {
                NSLog(@"[SortUserGridPosts] Not on profile view controller; aborting");
                return;
            }
            NSLog(@"[SortUserGridPosts] On IGProfileViewController");

            id currentPage = [nearestViewController valueForKey:@"currentPageViewController"];
            if (!currentPage) {
                NSLog(@"[SortUserGridPosts] currentPageViewController missing; aborting");
                return;
            }

            UIView *currentPageView = nil;
            if ([currentPage respondsToSelector:@selector(view)]) {
                currentPageView = [currentPage valueForKey:@"view"];
            }
            if (![currentPageView isKindOfClass:[UIView class]]) {
                NSLog(@"[SortUserGridPosts] currentPage view not a UIView; aborting");
                return;
            }

            UIView *collectionView = nil;
            for (UIView *subview in currentPageView.subviews) {
                if ([subview isKindOfClass:NSClassFromString(@"IGProfileTabCollectionView")]) {
                    collectionView = subview;
                    break;
                }
            }
            if (!collectionView) {
                NSLog(@"[SortUserGridPosts] IGProfileTabCollectionView not found; aborting");
                return;
            }

            NSMutableArray<UIView *> *cells = [NSMutableArray array];
            for (UIView *subview in collectionView.subviews) {
                if ([subview isKindOfClass:NSClassFromString(@"IGMediaThumbnailCell")]) {
                    [cells addObject:subview];
                }
            }
            if (cells.count == 0) {
                NSLog(@"[SortUserGridPosts] No IGMediaThumbnailCell subviews found; aborting");
                return;
            }
            NSLog(@"[SortUserGridPosts] Found %lu IGMediaThumbnailCell views", (unsigned long)cells.count);

            NSTimeInterval (^timestampForCell)(UIView *) = ^NSTimeInterval(UIView *cell) {
                id taken = [cell valueForKeyPath:@"delegate.media.takenAtDate"];
                if ([taken isKindOfClass:[NSDate class]]) {
                    return [(NSDate *)taken timeIntervalSince1970];
                }
                if ([taken respondsToSelector:@selector(doubleValue)]) {
                    return [taken doubleValue];
                }
                return 0;
            };

            BOOL currentAscending = NO;   // oldest -> newest
            BOOL currentDescending = NO;  // newest -> oldest
            for (NSUInteger i = 0; i + 1 < cells.count; i++) {
                NSTimeInterval t0 = timestampForCell(cells[i]);
                NSTimeInterval t1 = timestampForCell(cells[i + 1]);
                if (t0 < t1) { currentAscending = YES; break; }
                if (t0 > t1) { currentDescending = YES; break; }
            }
            NSString *detected = currentAscending ? @"ascending (oldest->newest)" : (currentDescending ? @"descending (newest->oldest)" : @"unknown/equal");
            NSLog(@"[SortUserGridPosts] Detected current order: %@", detected);

            NSNumber *storedAscending = objc_getAssociatedObject(collectionView, &kThetaSortGridAscendingKey);
            BOOL targetAscending;
            if (storedAscending != nil) {
                targetAscending = !storedAscending.boolValue;
                NSLog(@"[SortUserGridPosts] Stored order exists (%@); toggling", storedAscending.boolValue ? @"ascending" : @"descending");
            } else {
                if (currentAscending) {
                    targetAscending = NO;
                } else if (currentDescending) {
                    targetAscending = YES;
                } else {
                    targetAscending = YES;
                }
                NSLog(@"[SortUserGridPosts] No stored order; toggling relative to detected current order");
            }
            NSLog(@"[SortUserGridPosts] Target order: %@", targetAscending ? @"ascending (oldest->newest)" : @"descending (newest->oldest)");

            @try {
                UIViewController *topController = nearestViewController;
                id feedSourcesManager = [topController valueForKey:@"_feedSourcesManager"];
                if (!feedSourcesManager) {
                    NSLog(@"[SortUserGridPosts] feedSourcesManager not found; cannot reorder data source");
                } else {
                    NSMutableDictionary *sources = [feedSourcesManager valueForKey:@"_sources"];
                    id source = sources.count > 0 ? [sources allValues][0] : nil;
                    if (!source || ![source isKindOfClass:NSClassFromString(@"IGProfileFeedSource")]) {
                        NSLog(@"[SortUserGridPosts] IGProfileFeedSource source not found; cannot reorder data source");
                    } else {
                        NSLog(@"[SortUserGridPosts] _gridItems present; skipping direct mutation, using adapter sorting only");
                        UICollectionView *cv = (UICollectionView *)collectionView;

                        id ds = cv.dataSource;
                        id dl = cv.delegate;
                        NSLog(@"[SortUserGridPosts] cv=%@ ds=%@ dl=%@", NSStringFromClass([cv class]), NSStringFromClass([ds class]), NSStringFromClass([dl class]));
                        NSInteger sectionsBefore = [cv numberOfSections];
                        NSLog(@"[SortUserGridPosts] Sections before: %ld", (long)sectionsBefore);

                        [cv reloadData];
                        [cv.collectionViewLayout invalidateLayout];
                        [cv setNeedsLayout];
                        [cv layoutIfNeeded];
                        NSLog(@"[SortUserGridPosts] Collection view reloaded after data reorder");

                        NSInteger sectionsAfter = [cv numberOfSections];
                        NSLog(@"[SortUserGridPosts] Sections after: %ld", (long)sectionsAfter);

                        if (sectionsAfter > 0) {
                            NSIndexSet *all = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, sectionsAfter)];
                            [cv reloadSections:all];
                            NSLog(@"[SortUserGridPosts] Called reloadSections on all sections");
                        }

                        [cv setNeedsDisplay];

                        void (^tryAdapterReload)(id) = ^(id candidate) {
                            if (!candidate) return;
                            @try {
                                SEL selReloadWithCompletion = NSSelectorFromString(@"reloadDataWithCompletion:");
                                SEL selPerformUpdates = NSSelectorFromString(@"performUpdatesAnimated:completion:");
                                if ([candidate respondsToSelector:selReloadWithCompletion]) {
                                    NSLog(@"[SortUserGridPosts] Invoking adapter reloadDataWithCompletion:");
                                    void (*msgSend)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                                    msgSend(candidate, selReloadWithCompletion, nil);
                                } else if ([candidate respondsToSelector:selPerformUpdates]) {
                                    NSLog(@"[SortUserGridPosts] Invoking adapter performUpdatesAnimated:NO");
                                    void (*msgSendBoolBlock)(id, SEL, BOOL, id) = (void (*)(id, SEL, BOOL, id))objc_msgSend;
                                    msgSendBoolBlock(candidate, selPerformUpdates, NO, nil);
                                }
                            } @catch (__unused NSException *e) {
                                NSLog(@"[SortUserGridPosts] Exception while reloading adapter: %@", e);
                            }
                        };

                        id adapter = nil;
                        @try { adapter = [nearestViewController valueForKey:@"listAdapter"]; } @catch (__unused NSException *e) {}
                        if (!adapter) { @try { adapter = [currentPage valueForKey:@"listAdapter"]; } @catch (__unused NSException *e) {} }
                        if (!adapter) { @try { adapter = [cv valueForKey:@"listAdapter"]; } @catch (__unused NSException *e) {} }
                        if (!adapter) { @try { adapter = [nearestViewController valueForKey:@"_listAdapter"]; } @catch (__unused NSException *e) {} }
                        if (!adapter) { @try { adapter = [currentPage valueForKey:@"_listAdapter"]; } @catch (__unused NSException *e) {} }
                        if (!adapter) {
                            id dsLocal = cv.dataSource;
                            if (dsLocal && [NSStringFromClass([dsLocal class]) containsString:@"IGListAdapter"]) {
                                adapter = dsLocal;
                                NSLog(@"[SortUserGridPosts] Using dataSource as adapter: %@", NSStringFromClass([adapter class]));
                            }
                        }
                                if (adapter) {
                            NSLog(@"[SortUserGridPosts] Found IGListAdapter-like candidate: %@", NSStringFromClass([adapter class]));
                            id dataSource = nil;
                            @try { dataSource = [adapter valueForKey:@"dataSource"]; } @catch (__unused NSException *e) {}
                            if (dataSource) {
                                theta_installObjectsHookIfNeeded(dataSource);
                                        objc_setAssociatedObject(adapter, &kThetaSortGridAscendingKey, @(targetAscending), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                        objc_setAssociatedObject(adapter, &kThetaSortApplyOnceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                NSLog(@"[SortUserGridPosts] Installed objectsForListAdapter: hook and set ascending=%@", targetAscending ? @"YES" : @"NO");
                            }
                            tryAdapterReload(adapter);
                        } else {
                            NSLog(@"[SortUserGridPosts] No IGListAdapter found via KVC; relying on reloadData");
                        }

                        dispatch_async(dispatch_get_main_queue(), ^{
                            [cv performBatchUpdates:^{} completion:^(BOOL finished) {
                                [cv.collectionViewLayout invalidateLayout];
                                [cv setNeedsLayout];
                                [cv layoutIfNeeded];
                                NSLog(@"[SortUserGridPosts] Final layout invalidate after data reorder (finished=%@)", finished ? @"YES" : @"NO");
                            }];
                        });

                        unsigned int ivarCount = 0;
                        Ivar *ivars = class_copyIvarList([ds class], &ivarCount);
                        NSMutableArray *ivarNames = [NSMutableArray array];
                        for (unsigned int i = 0; i < ivarCount; i++) {
                            const char *name = ivar_getName(ivars[i]);
                            if (name) [ivarNames addObject:[NSString stringWithUTF8String:name]];
                        }
                        free(ivars);
                        NSLog(@"[SortUserGridPosts] DataSource ivars: %@", ivarNames);
                    }
                }
            } @catch (NSException *exception) {
                NSLog(@"[SortUserGridPosts] Exception while reordering data source: %@", exception);
            }

            objc_setAssociatedObject(collectionView, &kThetaSortGridAscendingKey, @(targetAscending), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSLog(@"[SortUserGridPosts] Stored order flag set to %@", targetAscending ? @"ascending" : @"descending");
        };
        [(UIView *)self addGestureRecognizer:longPress];

        objc_setAssociatedObject(self, &kThetaSortGridLongPressOnceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void THRegisterSortUserGridPostsHooks(void) {
    NullHookMessageIfPresent([UICollectionView class], @selector(layoutSubviews), (void *)hook_sortUserPostsGrid, (void **)&orig_sortUserPostsGrid);
}