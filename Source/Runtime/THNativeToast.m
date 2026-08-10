/* Instagram native toast presenter helpers */
static UIViewController *s_toastPresenterOwnerVC = nil;

static id getActionableConfirmationToastPresenter(void) {
    s_toastPresenterOwnerVC = nil;
    Class presenterClass = NSClassFromString(@"IGActionableConfirmationToastPresenter");
    if (!presenterClass) return nil;

    // 1) Try IGRootViewController property (common: root VC holds the presenter)
    UIViewController *root = nil;
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isKeyWindow) continue;
        keyWindow = w;
        root = w.rootViewController;
        break;
    }
    if (!root) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    if (!root && keyWindow) {
        root = keyWindow.rootViewController;
    }

    while (root && root.presentedViewController) {
        root = root.presentedViewController;
    }
    if ([root isKindOfClass:NSClassFromString(@"IGRootViewController")]) {
        for (NSString *key in @[ @"actionableConfirmationToastPresenter", @"toastPresenter" ]) {
            if ([root respondsToSelector:NSSelectorFromString(key)]) {
                id p = [root valueForKey:key];
                if (p && [p isKindOfClass:presenterClass]) {
                    s_toastPresenterOwnerVC = root;
                    return p;
                }
            }
        }
    }

    // 2) Walk all VCs in the hierarchy and ask for the presenter
    if (!root) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIViewController *vc = [stack lastObject];
        [stack removeLastObject];
        if (!vc || ![vc isKindOfClass:[UIViewController class]]) continue;
        for (NSString *key in @[ @"actionableConfirmationToastPresenter", @"toastPresenter" ]) {
            if ([vc respondsToSelector:NSSelectorFromString(key)]) {
                id p = [vc valueForKey:key];
                if (p && [p isKindOfClass:presenterClass]) {
                    s_toastPresenterOwnerVC = vc;
                    return p;
                }
            }
        }
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        if (vc.childViewControllers.count) [stack addObjectsFromArray:vc.childViewControllers];
    }

    return nil;
}

/// IGActionableConfirmationToastView.delegate = IGActionableConfirmationToastController, which has ivar IGNotificationPresenter.
static id getToastControllerFromPresenter(id presenter) {
    if (!presenter) return nil;
    Class controllerClass = NSClassFromString(@"IGActionableConfirmationToastController");
    if (!controllerClass) return nil;
    for (NSString *key in @[ @"controller", @"toastController", @"actionableConfirmationToastController", @"queueCoordinator", @"delegate" ]) {
        if ([presenter respondsToSelector:NSSelectorFromString(key)]) {
            id obj = [presenter valueForKey:key];
            if (obj && [obj isKindOfClass:controllerClass]) return obj;
        }
    }
    // Discover controller via runtime: scan all ivars of presenter's class for type matching controller.
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([presenter class], &count);
    for (unsigned int i = 0; ivars && i < count; i++) {
        Ivar iv = ivars[i];
        const char *name = ivar_getName(iv);
        const char *type = ivar_getTypeEncoding(iv);
        if (!name || !type || type[0] != '@') continue;
        id val = object_getIvar(presenter, iv);
        if (val && [val isKindOfClass:controllerClass]) {
            NSLog(@"Theta: found controller on presenter via ivar %s", name);
            free(ivars);
            return val;
        }
    }
    if (ivars) free(ivars);
    return nil;
}

static UIView *findToastViewOnly(UIView *view, Class viewClass) {
    if ([view isKindOfClass:viewClass]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = findToastViewOnly(sub, viewClass);
        if (found) return found;
    }
    return nil;
}

static id findToastViewInView(UIView *view, Class viewClass, Class controllerClass) {
    if ([view isKindOfClass:viewClass] && [view respondsToSelector:@selector(delegate)]) {
        id delegate = [(id)view valueForKey:@"delegate"];
        if (delegate && [delegate isKindOfClass:controllerClass]) return delegate;
    }
    for (UIView *sub in view.subviews) {
        id found = findToastViewInView(sub, viewClass, controllerClass);
        if (found) return found;
    }
    return nil;
}

/// Alternative: find IGActionableConfirmationToastView in the key window (recursive) and return its delegate (the controller).
static id getToastControllerFromViewInHierarchy(void) {
    Class viewClass = NSClassFromString(@"IGActionableConfirmationToastView");
    Class controllerClass = NSClassFromString(@"IGActionableConfirmationToastController");
    if (!viewClass || !controllerClass) return nil;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return nil;
    return findToastViewInView(window, viewClass, controllerClass);
}

static id getNotificationPresenterFromController(id controller) {
    if (!controller) return nil;
    Class npClass = NSClassFromString(@"IGNotificationPresenter");
    if (!npClass) return nil;
    for (NSString *key in @[ @"notificationPresenter", @"_notificationPresenter" ]) {
        if ([controller respondsToSelector:NSSelectorFromString(key)]) {
            id obj = [controller valueForKey:key];
            if (obj && [obj isKindOfClass:npClass]) return obj;
        }
    }
    // Discover via runtime: scan all ivars of controller for type IGNotificationPresenter.
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([controller class], &count);
    for (unsigned int i = 0; ivars && i < count; i++) {
        Ivar iv = ivars[i];
        const char *name = ivar_getName(iv);
        const char *type = ivar_getTypeEncoding(iv);
        if (!name || !type || type[0] != '@') continue;
        id val = object_getIvar(controller, iv);
        if (val && [val isKindOfClass:npClass]) {
            free(ivars);
            return val;
        }
    }
    if (ivars) free(ivars);
    return nil;
}

static id ThetaToastViewModelCreate(NSString *title, NSString * _Nullable subtitle, id _Nullable thumbnail) {
    Class cls = NSClassFromString(@"IGActionableConfirmationToastViewModel");
    if (!cls) {
        NSLog(@"Theta: IGActionableConfirmationToastViewModel class not found (not loaded?)");
        return nil;
    }
    NSString *sub = subtitle ?: @"";
    // Try class factory first (often non-failable)
    SEL factorySel = NSSelectorFromString(@"viewModelWithTitle:subtitle:thumbnail:");
    if ([cls respondsToSelector:factorySel]) {
        NSMethodSignature *sig = [cls methodSignatureForSelector:factorySel];
        if (sig && sig.numberOfArguments >= 5) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:cls];
            [inv setSelector:factorySel];
            [inv setArgument:&title atIndex:2];
            [inv setArgument:&sub atIndex:3];
            [inv setArgument:&thumbnail atIndex:4];
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            if (result) {
                NSLog(@"Theta: viewModel from viewModelWithTitle:subtitle:thumbnail:");
                return result;
            }
        }
    }
    // Try instance init with non-nil subtitle — each { } scope ends ARC lifetime for `attempt` (+1 alloc) before the next try.
    SEL sel3 = NSSelectorFromString(@"initWithTitle:subtitle:thumbnail:");
    {
        id attempt = [cls alloc];
        if ([attempt respondsToSelector:sel3]) {
            NSMethodSignature *sig = [attempt methodSignatureForSelector:sel3];
            if (sig && sig.numberOfArguments >= 5) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:attempt];
                [inv setSelector:sel3];
                [inv setArgument:&title atIndex:2];
                [inv setArgument:&sub atIndex:3];
                [inv setArgument:&thumbnail atIndex:4];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                if (result) {
                    NSLog(@"Theta: viewModel from initWithTitle:subtitle:thumbnail:");
                    return result;
                }
            }
        }
    }
    SEL sel2 = NSSelectorFromString(@"initWithTitle:subtitle:");
    {
        id attempt = [cls alloc];
        if ([attempt respondsToSelector:sel2]) {
            NSMethodSignature *sig = [attempt methodSignatureForSelector:sel2];
            if (sig && sig.numberOfArguments >= 4) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:attempt];
                [inv setSelector:sel2];
                [inv setArgument:&title atIndex:2];
                [inv setArgument:&sub atIndex:3];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                if (result) {
                    NSLog(@"Theta: viewModel from initWithTitle:subtitle:");
                    return result;
                }
            }
        }
    }
    // Last resort: alloc only (no init), set title/subtitle via every likely key so the toast shows text.
    id raw = [cls alloc];
    if (raw) {
        NSMutableArray *keysForTitle = [NSMutableArray array];
        NSMutableArray *keysForSubtitle = [NSMutableArray array];
        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pc);
        for (unsigned int i = 0; props && i < pc; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
            if ([name rangeOfString:@"subtitle" options:NSCaseInsensitiveSearch].length) [keysForSubtitle addObject:name];
            else if ([name rangeOfString:@"title" options:NSCaseInsensitiveSearch].length) [keysForTitle addObject:name];
            else if ([name isEqualToString:@"primaryText"] || [name isEqualToString:@"text"]) [keysForTitle addObject:name];
            else if ([name isEqualToString:@"secondaryText"] || [name isEqualToString:@"message"]) [keysForSubtitle addObject:name];
        }
        if (props) free(props);
        unsigned int ic = 0;
        Ivar *ivars = class_copyIvarList(cls, &ic);
        for (unsigned int i = 0; ivars && i < ic; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
            if ([name rangeOfString:@"subtitle" options:NSCaseInsensitiveSearch].length || ([name rangeOfString:@"sub" options:NSCaseInsensitiveSearch].length && [name rangeOfString:@"title" options:NSCaseInsensitiveSearch].length)) [keysForSubtitle addObject:name];
            else if ([name rangeOfString:@"title" options:NSCaseInsensitiveSearch].length) [keysForTitle addObject:name];
        }
        if (ivars) free(ivars);
        for (NSString *key in keysForTitle) { @try { [raw setValue:title forKey:key]; } @catch (id e) {} }
        for (NSString *key in keysForSubtitle) { @try { [raw setValue:sub forKey:key]; } @catch (id e) {} }
        for (NSString *key in @[ @"title", @"subtitle", @"_title", @"_subtitle", @"titleText", @"subtitleText", @"primaryText", @"secondaryText" ]) {
            @try { [raw setValue:([key rangeOfString:@"sub" options:NSCaseInsensitiveSearch].length ? sub : title) forKey:key]; } @catch (id e) {}
        }
        const double kDisplayDuration = 3.0;
        NSNumber *durationNum = @(kDisplayDuration);
        NSMutableArray *durationKeys = [NSMutableArray array];
        unsigned int dc = 0;
        objc_property_t *dprops = class_copyPropertyList(cls, &dc);
        for (unsigned int i = 0; dprops && i < dc; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(dprops[i])];
            if ([name rangeOfString:@"duration" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"dismiss" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"delay" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"displayTime" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"visible" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"interval" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"autoHide" options:NSCaseInsensitiveSearch].length)
                [durationKeys addObject:name];
        }
        if (dprops) free(dprops);
        unsigned int di = 0;
        Ivar *divars = class_copyIvarList(cls, &di);
        for (unsigned int i = 0; divars && i < di; i++) {
            const char *t = ivar_getTypeEncoding(divars[i]);
            if (!t) continue;
            NSString *name = [NSString stringWithUTF8String:ivar_getName(divars[i])];
            if ([name rangeOfString:@"duration" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"dismiss" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"delay" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"displayTime" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"visible" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"interval" options:NSCaseInsensitiveSearch].length ||
                [name rangeOfString:@"autoHide" options:NSCaseInsensitiveSearch].length)
                [durationKeys addObject:name];
        }
        if (divars) free(divars);
        for (NSString *key in durationKeys) {
            @try {
                [raw setValue:durationNum forKey:key];
            } @catch (id e) {}
        }
        for (NSString *key in @[ @"duration", @"displayDuration", @"dismissDuration", @"autoDismissDuration", @"displayTime", @"dismissDelay", @"visibleDuration" ]) {
            @try { [raw setValue:durationNum forKey:key]; } @catch (id e) {}
        }
        if (thumbnail) {
            NSMutableArray *thumbKeys = [NSMutableArray array];
            unsigned int tc = 0;
            objc_property_t *tprops = class_copyPropertyList(cls, &tc);
            for (unsigned int i = 0; tprops && i < tc; i++) {
                NSString *name = [NSString stringWithUTF8String:property_getName(tprops[i])];
                if ([name rangeOfString:@"thumbnail" options:NSCaseInsensitiveSearch].length || [name rangeOfString:@"image" options:NSCaseInsensitiveSearch].length || [name rangeOfString:@"icon" options:NSCaseInsensitiveSearch].length) [thumbKeys addObject:name];
            }
            if (tprops) free(tprops);
            unsigned int ti = 0;
            Ivar *tivars = class_copyIvarList(cls, &ti);
            for (unsigned int i = 0; tivars && i < ti; i++) {
                const char *t = ivar_getTypeEncoding(tivars[i]);
                if (!t || t[0] != '@') continue;
                NSString *name = [NSString stringWithUTF8String:ivar_getName(tivars[i])];
                if ([name rangeOfString:@"thumbnail" options:NSCaseInsensitiveSearch].length || [name rangeOfString:@"image" options:NSCaseInsensitiveSearch].length || [name rangeOfString:@"icon" options:NSCaseInsensitiveSearch].length) [thumbKeys addObject:name];
            }
            if (tivars) free(tivars);
            for (NSString *key in thumbKeys) { @try { [raw setValue:thumbnail forKey:key]; } @catch (id e) {} }
            for (NSString *key in @[ @"thumbnail", @"_thumbnail", @"thumbnailImage", @"image", @"icon" ]) { @try { [raw setValue:thumbnail forKey:key]; } @catch (id e) {} }
        }
        return raw;
    }
    NSLog(@"Theta: viewModel nil - class exists but factory, inits, and alloc failed");
    return nil;
}

/// Scan object's object-type ivars for one that is viewModelClass.
static id findViewModelInIvars(id obj, Class viewModelClass) {
    if (!obj || !viewModelClass) return nil;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    for (unsigned int i = 0; ivars && i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') continue;
        id val = object_getIvar(obj, ivars[i]);
        if (val && [val isKindOfClass:viewModelClass]) {
            free(ivars);
            return val;
        }
    }
    if (ivars) free(ivars);
    return nil;
}

/// Steal an existing view model from controller, presenter, or toast view in hierarchy; set title/subtitle via KVC if possible.
static id getExistingViewModelFromHierarchy(id controllerOrNil, id presenterOrNil, NSString *title, NSString *subtitle) {
    Class viewModelClass = NSClassFromString(@"IGActionableConfirmationToastViewModel");
    Class viewClass = NSClassFromString(@"IGActionableConfirmationToastView");
    if (!viewModelClass) return nil;
    id viewModel = nil;
    if (controllerOrNil) {
        for (NSString *key in @[ @"viewModel", @"_viewModel", @"currentViewModel", @"pendingViewModel" ]) {
            if ([controllerOrNil respondsToSelector:NSSelectorFromString(key)]) {
                id vm = [controllerOrNil valueForKey:key];
                if (vm && [vm isKindOfClass:viewModelClass]) { viewModel = vm; break; }
            }
        }
        if (!viewModel) viewModel = findViewModelInIvars(controllerOrNil, viewModelClass);
        if (viewModel) NSLog(@"Theta: viewModel from controller");
    }
    if (!viewModel && presenterOrNil) {
        viewModel = findViewModelInIvars(presenterOrNil, viewModelClass);
        if (viewModel) NSLog(@"Theta: viewModel from presenter ivar scan");
    }
    if (!viewModel && viewClass) {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIView *toastView = window ? findToastViewOnly(window, viewClass) : nil;
        if (toastView) {
            for (NSString *key in @[ @"viewModel", @"_viewModel" ]) {
                if ([toastView respondsToSelector:NSSelectorFromString(key)]) {
                    id vm = [toastView valueForKey:key];
                    if (vm && [vm isKindOfClass:viewModelClass]) { viewModel = vm; break; }
                }
            }
            if (!viewModel) viewModel = findViewModelInIvars(toastView, viewModelClass);
            if (!viewModel && [toastView respondsToSelector:@selector(delegate)]) {
                id ctrl = [(id)toastView valueForKey:@"delegate"];
                for (NSString *key in @[ @"viewModel", @"_viewModel", @"currentViewModel" ]) {
                    if ([ctrl respondsToSelector:NSSelectorFromString(key)]) {
                        id vm = [ctrl valueForKey:key];
                        if (vm && [vm isKindOfClass:viewModelClass]) { viewModel = vm; break; }
                    }
                }
                if (!viewModel) viewModel = findViewModelInIvars(ctrl, viewModelClass);
            }
        }
    }
    if (!viewModel) return nil;
    if (title && [viewModel respondsToSelector:NSSelectorFromString(@"setTitle:")])
        [viewModel setValue:title forKey:@"title"];
    if (subtitle && [viewModel respondsToSelector:NSSelectorFromString(@"setSubtitle:")])
        [viewModel setValue:subtitle forKey:@"subtitle"];
    NSLog(@"Theta: using existing viewModel from hierarchy (title/subtitle set via KVC)");
    return viewModel;
}

static void presentTextOnlyToast(id presenter, UIViewController *fromVC) {
    id viewModel = ThetaToastViewModelCreate(@"Done!", @"Your action completed successfully.", nil);
    if (!viewModel) return;
    Class contextClass = NSClassFromString(@"IGActionableConfirmationToastPresentationContext");
    if (!contextClass) return;
    id context = [[contextClass alloc] initWithPresentingViewController:fromVC
                                        onlyShowOnSpecifiedViewController:NO];
    if (!context) return;

    void (^presentedHandler)(UIView *) = ^(UIView * _Nullable toastView) { NSLog(@"Theta: toast did appear"); };
    void (^dismissedHandler)(UIView *) = ^(UIView * _Nullable toastView) { NSLog(@"Theta: toast did dismiss"); };

    SEL internalSel = NSSelectorFromString(@"_showAlertWithViewModel:presentationContext:isAnimated:animationDuration:presentationPriority:origin:toastType:tapActionBlock:tapToastBlock:presentedHandler:dismissedHandler:");
    if ([presenter respondsToSelector:internalSel]) {
        BOOL animated = YES;
        double duration = 0.3;
        NSInteger priority = 0;
        id origin = nil;
        NSInteger toastType = 0;
        NSMethodSignature *sig = [presenter methodSignatureForSelector:internalSel];
        if (sig && sig.numberOfArguments >= 13) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:presenter];
            [inv setSelector:internalSel];
            [inv setArgument:&viewModel atIndex:2];
            [inv setArgument:&context atIndex:3];
            [inv setArgument:&animated atIndex:4];
            [inv setArgument:&duration atIndex:5];
            [inv setArgument:&priority atIndex:6];
            [inv setArgument:&origin atIndex:7];
            [inv setArgument:&toastType atIndex:8];
            id nilBlock = nil;
            [inv setArgument:&nilBlock atIndex:9];
            [inv setArgument:&nilBlock atIndex:10];
            [inv setArgument:&presentedHandler atIndex:11];
            [inv setArgument:&dismissedHandler atIndex:12];
            [inv invoke];
            return;
        }
    }

    [presenter showAlertWithViewModel:viewModel
                   presentationContext:context
                           isAnimated:YES
                    animationDuration:0.3
                presentationPriority:0
                       tapActionBlock:nil
                     presentedHandler:presentedHandler
                     dismissedHandler:dismissedHandler];
}

static void presentToastWithImage(id presenter,
                           UIViewController *fromVC,
                           NSString *title,
                           NSString *subtitle,
                           UIImage *image) {
    id thumbnail = nil;
    Class thumbnailClass = NSClassFromString(@"IGActionableConfirmationToastViewThumbnail");
    if (image && thumbnailClass && [thumbnailClass instancesRespondToSelector:@selector(initWithImage:)])
        thumbnail = [[thumbnailClass alloc] initWithImage:image];

    id viewModel = ThetaToastViewModelCreate(title, subtitle, thumbnail);
    if (!viewModel) return;
    Class contextClass = NSClassFromString(@"IGActionableConfirmationToastPresentationContext");
    if (!contextClass) return;
    id context = [[contextClass alloc] initWithPresentingViewController:fromVC
                                        onlyShowOnSpecifiedViewController:NO];
    if (!context) return;
    [presenter showAlertWithViewModel:viewModel
                   presentationContext:context
                           isAnimated:YES
                    animationDuration:0.3
                presentationPriority:0
                       tapActionBlock:nil
                     presentedHandler:nil
                     dismissedHandler:nil];
}

static void presentMinimalToast(id presenter, NSString *title, NSString *subtitle) {
    id viewModel = ThetaToastViewModelCreate(title, subtitle, nil);
    if (!viewModel) return;
    [presenter showAlertWithViewModel:viewModel
                         isAnimated:YES
                  animationDuration:0.3
              presentationPriority:0
                     tapActionBlock:nil
                   presentedHandler:nil
                   dismissedHandler:nil];
}

/// Try showing via IGActionableConfirmationToastController -> IGNotificationPresenter (the ivar that may actually display).
/// On NO, outFailureReason (if non-NULL) is set to the exact reason so one log line can show it.
static BOOL tryShowViaNotificationPresenter(id presenter, id viewModel, id context, NSString **outFailureReason) {
    #define SET_FAIL(s) do { if (outFailureReason) *outFailureReason = (s); } while(0)
    id controller = getToastControllerFromPresenter(presenter);
    if (!controller) controller = getToastControllerFromViewInHierarchy();
    if (!controller) {
        SET_FAIL(@"no IGActionableConfirmationToastController (presenter or view hierarchy)");
        return NO;
    }
    id notificationPresenter = getNotificationPresenterFromController(controller);
    if (!notificationPresenter) {
        SET_FAIL(@"controller found but no IGNotificationPresenter on it");
        return NO;
    }
    SEL sel = NSSelectorFromString(@"showWithViewModel:presentationContext:");
    if (![notificationPresenter respondsToSelector:sel]) sel = NSSelectorFromString(@"showWithConfig:");
    if (![notificationPresenter respondsToSelector:sel]) sel = NSSelectorFromString(@"_showWithViewModel:presentationContext:");
    if (![notificationPresenter respondsToSelector:sel]) sel = NSSelectorFromString(@"_showWithConfig:");
    if (![notificationPresenter respondsToSelector:sel]) sel = NSSelectorFromString(@"_showWithViewModel:");
    if (![notificationPresenter respondsToSelector:sel]) {
        NSMutableArray *allMethods = [NSMutableArray array];
        unsigned int mc = 0;
        Method *methods = class_copyMethodList([notificationPresenter class], &mc);
        for (unsigned int i = 0; methods && i < mc && allMethods.count < 80; i++) {
            [allMethods addObject:NSStringFromSelector(method_getName(methods[i]))];
        }
        if (methods) free(methods);
        NSString *msg = [NSString stringWithFormat:@"IGNotificationPresenter has no show method; all methods: %@", [allMethods componentsJoinedByString:@", "]];
        SET_FAIL(msg);
        return NO;
    }
    NSMethodSignature *sig = [notificationPresenter methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 4) {
        SET_FAIL(@"show method signature has < 4 args");
        return NO;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:notificationPresenter];
    [inv setSelector:sel];
    [inv setArgument:&viewModel atIndex:2];
    [inv setArgument:&context atIndex:3];
    [inv invoke];
    return YES;
    #undef SET_FAIL
}

/// Presents the native Instagram toast with the given title, subtitle, and optional image.
/// Pass nil for subtitle or image to show text-only or no thumbnail. Falls back to ThetaHelper toast if native path fails.
void ThetaShowNativeToast(NSString *title, NSString * _Nullable subtitle, UIImage * _Nullable image) {
    if (!title) title = @"";
    NSString *sub = subtitle ?: @"";
    id thumbnail = nil;
    if (image) {
        Class thumbClass = NSClassFromString(@"IGActionableConfirmationToastViewThumbnail");
        if (thumbClass && [thumbClass instancesRespondToSelector:@selector(initWithImage:)])
            thumbnail = [[thumbClass alloc] initWithImage:image];
    }
    id presenter = getActionableConfirmationToastPresenter();
    if (!presenter) {
        [ThetaHelper showToastWithTitle:title subtitle:sub icon:image ?: [ThetaHelper imageFromEmojiString:@"✅" width:60] autoHide:4 openURL:nil];
        return;
    }
    id viewModel = ThetaToastViewModelCreate(title, sub, thumbnail);
    id controller = getToastControllerFromPresenter(presenter);
    if (!controller) controller = getToastControllerFromViewInHierarchy();
    if (!viewModel) viewModel = getExistingViewModelFromHierarchy(controller, presenter, title, sub);
    UIViewController *vc = s_toastPresenterOwnerVC ?: [ThetaHelper topViewController];
    if (!vc) {
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw) {
            vc = kw.rootViewController;
        }
    }
    id context = nil;
    Class ctxClass = NSClassFromString(@"IGActionableConfirmationToastPresentationContext");
    if (vc && ctxClass) context = [[ctxClass alloc] initWithPresentingViewController:vc onlyShowOnSpecifiedViewController:NO];
    NSString *failReason = nil;
    if (viewModel && context && tryShowViaNotificationPresenter(presenter, viewModel, context, &failReason)) {
        return;
    }
    if (viewModel && context && vc) {
        s_lastToastShowTime = [[NSDate date] timeIntervalSince1970];
        void (^presentedHandler)(UIView *) = nil;
        SEL internalSel = NSSelectorFromString(@"_showAlertWithViewModel:presentationContext:isAnimated:animationDuration:presentationPriority:origin:toastType:tapActionBlock:tapToastBlock:presentedHandler:dismissedHandler:");
        NSMethodSignature *sig = [presenter methodSignatureForSelector:internalSel];
        if (sig && sig.numberOfArguments >= 13) {
            BOOL animated = YES;
            double displayDuration = 3.0;
            NSInteger priority = 0;
            id origin = nil;
            NSInteger toastType = 1;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:presenter];
            [inv setSelector:internalSel];
            [inv setArgument:&viewModel atIndex:2];
            [inv setArgument:&context atIndex:3];
            [inv setArgument:&animated atIndex:4];
            [inv setArgument:&displayDuration atIndex:5];
            [inv setArgument:&priority atIndex:6];
            [inv setArgument:&origin atIndex:7];
            [inv setArgument:&toastType atIndex:8];
            id nilBlock = nil;
            [inv setArgument:&nilBlock atIndex:9];
            [inv setArgument:&nilBlock atIndex:10];
            [inv setArgument:&presentedHandler atIndex:11];
            [inv setArgument:&nilBlock atIndex:12];
            [inv invoke];
        } else if ([presenter respondsToSelector:@selector(showAlertWithViewModel:presentationContext:isAnimated:animationDuration:presentationPriority:tapActionBlock:presentedHandler:dismissedHandler:)]) {
            [presenter showAlertWithViewModel:viewModel presentationContext:context isAnimated:YES animationDuration:0.3 presentationPriority:0 tapActionBlock:nil presentedHandler:presentedHandler dismissedHandler:nil];
        } else {
            [ThetaHelper showToastWithTitle:title subtitle:sub icon:image ?: [ThetaHelper imageFromEmojiString:@"✅" width:60] autoHide:3 openURL:nil];
        }
    } else {
        [ThetaHelper showToastWithTitle:title subtitle:sub icon:image ?: [ThetaHelper imageFromEmojiString:@"✅" width:60] autoHide:3 openURL:nil];
    }
}

/// Same as ThetaShowNativeToast but builds the thumbnail from an emoji using ThetaHelper imageFromEmojiString. Pass nil for emojiString for no thumbnail.
void ThetaShowNativeToastWithEmoji(NSString *title, NSString * _Nullable subtitle, NSString * _Nullable emojiString, CGFloat width) {
    UIImage *image = (emojiString.length > 0) ? [ThetaHelper imageFromEmojiString:emojiString width:(width > 0 ? width : 60)] : nil;
    ThetaShowNativeToast(title, subtitle, image);
}

