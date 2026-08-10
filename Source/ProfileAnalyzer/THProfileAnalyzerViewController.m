#import "Include/THProfileAnalyzerViewController.h"
#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]
#import "Include/THProfileAnalyzerTypes.h"
#import "Include/THProfileAnalyzerAPIClient.h"
#import "Include/THProfileAnalyzerService.h"
#import "Include/THProfileAnalyzerDiffEngine.h"
#import "Include/THProfileAnalyzerStorage.h"
#import "Include/ThetaHelper.h"
#import "Include/InstagramHeaders.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kTHProfileAnalyzerMaxTotal = 13000;

static NSString * const kTHProfileAnalyzerPinnedPKsKey = @"THProfileAnalyzerPinnedPKs";
static NSString * const kTHProfileAnalyzerIgnoredPKsKey = @"THProfileAnalyzerIgnoredPKs";
static NSString * const kTHProfileAnalyzerAPICountsPrefix = @"THProfileAnalyzerAPICounts_";

static NSMutableSet<NSString *> *THProfileAnalyzerMutableSetForKey(NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *arr = [d objectForKey:key];
    if (![arr isKindOfClass:[NSArray class]]) return [NSMutableSet set];
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (id v in arr) if ([v isKindOfClass:[NSString class]]) [set addObject:v];
    return set;
}

static void THProfileAnalyzerSaveSetForKey(NSSet<NSString *> *set, NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:set.allObjects forKey:key];
    [d synchronize];
}

/* Get object's ivar by name (works for private ivars when valueForKey: does not). */
static id _Nullable THGetIvar(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    Class c = [obj class];
    while (c) {
        Ivar iv = class_getInstanceVariable(c, ivarName);
        if (iv) return object_getIvar(obj, iv);
        c = class_getSuperclass(c);
    }
    return nil;
}

/* Get Instagram's API networker: (1) Regram-style delegate chain with runtime ivars, (2) IGWindow → userSession → userActions → networker. */
static id _Nullable THProfileAnalyzerGetNetworker(void) {
    id networker = nil;
    @try {
        id delegate = [[UIApplication sharedApplication] delegate];
        if (!delegate) return nil;
        id appCoordinator = THGetIvar(delegate, "_appCoordinator");
        if (!appCoordinator) appCoordinator = [delegate valueForKey:@"_appCoordinator"];
        if (!appCoordinator) appCoordinator = THGetIvar([delegate valueForKey:@"_delegate"], "_appCoordinator");
        if (appCoordinator) {
            id sessionManager = THGetIvar(appCoordinator, "_sessionManager");
            if (!sessionManager) sessionManager = [appCoordinator valueForKey:@"_sessionManager"];
            if (sessionManager) {
                id activeUserSessions = THGetIvar(sessionManager, "_activeUserSessions");
                if (!activeUserSessions) activeUserSessions = [sessionManager valueForKey:@"_activeUserSessions"];
                if (activeUserSessions) {
                    id session = [activeUserSessions valueForKey:@"presentedUserSession"];
                    if (!session && [activeUserSessions respondsToSelector:@selector(presentedUserSession)])
                        session = [activeUserSessions performSelector:@selector(presentedUserSession)];
                    if (session) {
                        id userActions = [session valueForKey:@"userActions"];
                        if (!userActions) userActions = THGetIvar(session, "_userActions");
                        if (userActions) {
                            networker = [userActions valueForKey:@"networker"];
                            if (!networker) networker = THGetIvar(userActions, "_networker");
                        }
                    }
                }
            }
        }
        /* Fallback: IGWindow → userSession → userActions → networker (same object as above on many builds). */
        if (!networker) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            if ([windows isKindOfClass:[NSArray class]]) {
                Class igWindowClass = NSClassFromString(@"IGWindow");
                for (UIWindow *w in windows) {
                    if (!w || !igWindowClass || ![w isKindOfClass:igWindowClass]) continue;
                    id userSession = THGetIvar(w, "_userSession");
                    if (!userSession) userSession = [w valueForKey:@"userSession"];
                    if (!userSession) continue;
                    id userActions = [userSession valueForKey:@"userActions"];
                    if (!userActions) userActions = THGetIvar(userSession, "_userActions");
                    if (!userActions) continue;
                    networker = [userActions valueForKey:@"networker"];
                    if (!networker) networker = THGetIvar(userActions, "_networker");
                    if (networker) break;
                }
            }
        }
    } @catch (NSException *e) { (void)e; }
    return networker;
}

/* Build request via IGAPIRequestBuilder (path relative to api/v1). Returns nil if unavailable. */
static NSURLRequest * _Nullable THProfileAnalyzerBuildIGRequest(NSString *path, NSDictionary<NSString *, NSString *> * _Nullable queryParams, NSInteger method) {
    Class builderClass = NSClassFromString(@"IGAPIRequestBuilder");
    if (!builderClass) return nil;
    id builder = [[builderClass alloc] init];
    if (!builder) return nil;
    NSString *pathTrimmed = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    @try {
        [builder setValue:pathTrimmed forKey:@"_path"];
        [builder setValue:@(method) forKey:@"_HTTPMethod"];
        if (queryParams && queryParams.count) [builder setValue:[queryParams copy] forKey:@"_parameters"];
        if (![builder respondsToSelector:@selector(request)]) return nil;
        id req = [builder performSelector:@selector(request)];
        return [req isKindOfClass:[NSURLRequest class]] ? req : nil;
    } @catch (NSException *e) { (void)e; return nil; }
}

/* Build request via IGURLRequest – full URL, method 0 = GET (Instagram enum), forceIGAPIHeaders YES. */
static NSURLRequest * _Nullable THProfileAnalyzerBuildIGURLRequest(NSURL *url, NSInteger method) {
    Class reqClass = NSClassFromString(@"IGURLRequest");
    if (!reqClass || ![reqClass instancesRespondToSelector:@selector(initWithURL:HTTPMethod:module:forceIGAPIHeaders:)]) return nil;
    SEL sel = @selector(initWithURL:HTTPMethod:module:forceIGAPIHeaders:);
    id req = nil;
    @try {
        id alloced = [reqClass alloc];
        typedef id (*InitFn)(id, SEL, NSURL *, NSInteger, id, BOOL);
        req = ((InitFn)objc_msgSend)(alloced, sel, url, (NSInteger)method, nil, YES);
        return [req isKindOfClass:[NSURLRequest class]] ? req : (id)req; /* IGURLRequest may be NSURLRequest subclass */
    } @catch (NSException *e) { (void)e; return nil; }
}

/* Parse URL from our API base into endpoint path (after api/v1/) and query params. */
static void THProfileAnalyzerParseAPIURL(NSURL *url, NSString * _Nullable *outPath, NSDictionary<NSString *, NSString *> * _Nullable *outParams) {
    if (outPath) *outPath = nil;
    if (outParams) *outParams = nil;
    NSString *path = url.path;
    NSString *prefix = @"/api/v1/";
    if (![path hasPrefix:prefix]) return;
    NSString *endpoint = [path substringFromIndex:prefix.length];
    if (outPath) *outPath = endpoint;
    if (outParams && url.query.length) {
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        for (NSString *pair in [url.query componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count >= 2) {
                NSString *key = [kv[0] stringByRemovingPercentEncoding];
                NSString *val = [[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="];
                if (key.length) params[key ?: @""] = [val stringByRemovingPercentEncoding] ?: @"";
            }
        }
        if (outParams) *outParams = params;
    }
}

static void THProfileAnalyzerOpenProfileForUsername(NSString *username) {
    if (!username.length) return;
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (!encoded.length) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"instagram://user?username=%@", encoded]];
    if (!url) return;
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:url];
    }
}

@interface THProfileAnalyzerUserHistoryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithUserPK:(NSString *)userPK username:(NSString * _Nullable)username currentUserPK:(NSString *)currentUserPK;
@end

@class THProfileAnalyzerScanHistoryViewController;

@interface THProfileAnalyzerScanCompareGraphView : UIView
@property (nonatomic, copy) NSArray<THProfileAnalyzerSnapshot *> *scans;
@property (nonatomic, assign) BOOL isDarkMode;
@end

@interface THProfileAnalyzerScanCompareViewController : UIViewController
- (instancetype)initWithScans:(NSArray<THProfileAnalyzerSnapshot *> *)scans;
@end

@interface THProfileAnalyzerListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
- (instancetype)initWithTitle:(NSString *)title users:(NSArray<THProfileAnalyzerUser *> *)users;
@property (nonatomic, copy) NSString *currentUserPK;
@end

@implementation THProfileAnalyzerListViewController {
    NSString *_listTitle;
    NSString *_currentUserPK;
    NSArray<THProfileAnalyzerUser *> *_allUsers;
    NSArray<THProfileAnalyzerUser *> *_users;
    UITableView *_tableView;
    UISearchController *_searchController;
}

- (instancetype)initWithTitle:(NSString *)title users:(NSArray<THProfileAnalyzerUser *> *)users {
    if (self = [super init]) {
        _listTitle = [title copy];
        NSArray<THProfileAnalyzerUser *> *source = [users copy] ?: @[];
        // Sort users by username (fallback to PK)
        _allUsers = [source sortedArrayUsingComparator:^NSComparisonResult(THProfileAnalyzerUser *a, THProfileAnalyzerUser *b) {
            NSString *nameA = a.username.length ? a.username : a.pk;
            NSString *nameB = b.username.length ? b.username : b.pk;
            return [nameA caseInsensitiveCompare:nameB];
        }];
        _users = _allUsers;
    }
    return self;
}

- (void)setCurrentUserPK:(NSString *)currentUserPK {
    _currentUserPK = [currentUserPK copy];
}

- (BOOL)listVC_isDarkMode {
    if (@available(iOS 12.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES;
}
- (UIColor *)listVC_backgroundColor {
    return [self listVC_isDarkMode] ? [UIColor colorWithWhite:0.12f alpha:1.0f] : [UIColor colorWithWhite:0.96f alpha:1.0f];
}
- (UIColor *)listVC_cellBackgroundColor {
    return [self listVC_isDarkMode] ? [UIColor colorWithWhite:0.2f alpha:1.0f] : [UIColor whiteColor];
}
- (UIColor *)listVC_primaryTextColor {
    return [self listVC_isDarkMode] ? [UIColor whiteColor] : [UIColor colorWithWhite:0.1f alpha:1.0f];
}
- (UIColor *)listVC_secondaryTextColor {
    return [self listVC_isDarkMode] ? [UIColor lightGrayColor] : [UIColor colorWithWhite:0.45f alpha:1.0f];
}
- (UIColor *)listVC_avatarPlaceholderColor {
    return [self listVC_isDarkMode] ? [UIColor colorWithWhite:0.35f alpha:1.0f] : [UIColor colorWithWhite:0.92f alpha:1.0f];
}
- (void)listVC_applyTheme {
    self.view.backgroundColor = [self listVC_backgroundColor];
    if (_tableView) {
        _tableView.backgroundColor = [self listVC_backgroundColor];
        [_tableView reloadData];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _listTitle;
    self.view.backgroundColor = [self listVC_backgroundColor];

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchResultsUpdater = self;
    _searchController.searchBar.placeholder = @"Search users";
    self.navigationItem.searchController = _searchController;
    self.definesPresentationContext = YES;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = [self listVC_backgroundColor];
    [self.view addSubview:_tableView];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [_tableView addGestureRecognizer:longPress];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self listVC_applyTheme];
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _users.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    static const CGFloat kAvatarSize = 32;
    static const CGFloat kPadding = 12;
    CGFloat w = cell.contentView.bounds.size.width;
    UIImageView *avatar = [cell.contentView viewWithTag:9001];
    if (avatar) {
        avatar.layer.cornerRadius = kAvatarSize / 2.0f;
        avatar.frame = CGRectMake(w - kPadding - kAvatarSize, (56 - kAvatarSize) / 2.0f, kAvatarSize, kAvatarSize);
    }
    CGFloat textWidth = w - kPadding * 2 - kAvatarSize - 8;
    cell.textLabel.frame = CGRectMake(kPadding, 8, textWidth, 22);
    cell.detailTextLabel.frame = CGRectMake(kPadding, 30, textWidth, 18);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"UserCell";
    static const CGFloat kAvatarSize = 32;
    static NSInteger kAvatarTag = 9001;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        UIImageView *avatar = [[UIImageView alloc] initWithFrame:CGRectZero];
        avatar.tag = kAvatarTag;
        avatar.clipsToBounds = YES;
        avatar.contentMode = UIViewContentModeScaleAspectFill;
        [cell.contentView addSubview:avatar];
    }
    UIImageView *avatar = [cell.contentView viewWithTag:kAvatarTag];
    avatar.image = nil;
    avatar.backgroundColor = [self listVC_avatarPlaceholderColor];
    THProfileAnalyzerUser *u = _users[indexPath.row];
    cell.textLabel.text = u.username.length ? u.username : u.pk;
    cell.detailTextLabel.text = u.fullName.length ? u.fullName : nil;
    cell.textLabel.textColor = [self listVC_primaryTextColor];
    cell.detailTextLabel.textColor = [self listVC_secondaryTextColor];
    cell.backgroundColor = [self listVC_cellBackgroundColor];
    if (u.profilePicURL.length) {
        NSURL *url = [NSURL URLWithString:u.profilePicURL];
        if (url) {
            __weak UITableViewCell *weakCell = cell;
            NSIndexPath *pathCopy = [indexPath copy];
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                if (!data.length) return;
                UIImage *img = [UIImage imageWithData:data];
                if (!img) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UITableViewCell *c = weakCell;
                    if (!c) return;
                    UIImageView *av = [c.contentView viewWithTag:kAvatarTag];
                    if (av && pathCopy && [tableView indexPathForCell:c] && [tableView indexPathForCell:c].row == pathCopy.row)
                        av.image = img;
                });
            }];
            [task resume];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)_users.count) return;
    THProfileAnalyzerUser *u = _users[indexPath.row];
    NSString *username = u.username.length ? u.username : nil;
    if (!username.length && u.pk.length) username = u.pk;
    if (username.length) THProfileAnalyzerOpenProfileForUsername(username);
}

- (void)tableView:(UITableView *)tableView didLongPressRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)_users.count) return;
    THProfileAnalyzerUser *u = _users[indexPath.row];
    if (!u.pk.length) return;
    NSString *pk = u.pk;
    NSMutableSet<NSString *> *pinned = THProfileAnalyzerMutableSetForKey(kTHProfileAnalyzerPinnedPKsKey);
    NSMutableSet<NSString *> *ignored = THProfileAnalyzerMutableSetForKey(kTHProfileAnalyzerIgnoredPKsKey);
    BOOL isPinned = [pinned containsObject:pk];
    BOOL isIgnored = [ignored containsObject:pk];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:u.username.length ? u.username : pk
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *pinTitle = isPinned ? @"Unpin" : @"Pin";
    [ac addAction:[UIAlertAction actionWithTitle:pinTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (isPinned) [pinned removeObject:pk]; else [pinned addObject:pk];
        THProfileAnalyzerSaveSetForKey(pinned, kTHProfileAnalyzerPinnedPKsKey);
    }]];
    NSString *ignoreTitle = isIgnored ? @"Remove ignore" : @"Ignore in not-following lists";
    [ac addAction:[UIAlertAction actionWithTitle:ignoreTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (isIgnored) [ignored removeObject:pk]; else [ignored addObject:pk];
        THProfileAnalyzerSaveSetForKey(ignored, kTHProfileAnalyzerIgnoredPKsKey);
    }]];
    if (_currentUserPK.length) {
        [ac addAction:[UIAlertAction actionWithTitle:@"View history" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            THProfileAnalyzerUserHistoryViewController *historyVC = [[THProfileAnalyzerUserHistoryViewController alloc] initWithUserPK:pk username:u.username.length ? u.username : nil currentUserPK:_currentUserPK];
            [self.navigationController pushViewController:historyVC animated:YES];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text ?: @"";
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) {
        _users = _allUsers;
        [_tableView reloadData];
        return;
    }
    NSString *lower = trimmed.lowercaseString;
    NSMutableArray<THProfileAnalyzerUser *> *filtered = [NSMutableArray array];
    for (THProfileAnalyzerUser *u in _allUsers) {
        NSString *username = u.username.lowercaseString ?: @"";
        NSString *full = u.fullName.lowercaseString ?: @"";
        if ((username.length && [username containsString:lower]) ||
            (full.length && [full containsString:lower])) {
            [filtered addObject:u];
        }
    }
    _users = filtered;
    [_tableView reloadData];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gesture locationInView:_tableView];
    NSIndexPath *indexPath = [_tableView indexPathForRowAtPoint:p];
    if (!indexPath) return;
    [self tableView:_tableView didLongPressRowAtIndexPath:indexPath];
}

@end

static NSInteger THProfileAnalyzerEffectiveFollowersCount(THProfileAnalyzerSnapshot *s) {
    return s.apiFollowersCount >= 0 ? s.apiFollowersCount : (NSInteger)s.followers.count;
}
static NSInteger THProfileAnalyzerEffectiveFollowingCount(THProfileAnalyzerSnapshot *s) {
    return s.apiFollowingCount >= 0 ? s.apiFollowingCount : (NSInteger)s.following.count;
}

// MARK: - Scan History
@interface THProfileAnalyzerScanHistoryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
/** Called whenever rows are deleted so the analyzer dashboard reloads latest snapshot/diff state. */
@property (nonatomic, copy, nullable) void (^onScanHistoryDidMutateStorage)(void);
- (instancetype)initWithCurrentUserPK:(NSString *)userPK currentSnapshot:(THProfileAnalyzerSnapshot * _Nullable)currentSnapshot;
@end

@implementation THProfileAnalyzerScanHistoryViewController {
    NSString *_currentUserPK;
    THProfileAnalyzerSnapshot *_currentSnapshot;
    NSArray<THProfileAnalyzerSnapshot *> *_scans; /** Table order: oldest at row 0, newest at bottom. Compare to loadSnapshotAtIndex:0 == newest (newest-first index = count-1-row). */
    UITableView *_tableView;
    UILabel *_emptyLabel;
    BOOL _selectionMode;
    NSMutableIndexSet *_selectedIndexes;
}

- (instancetype)initWithCurrentUserPK:(NSString *)userPK currentSnapshot:(THProfileAnalyzerSnapshot * _Nullable)currentSnapshot {
    if (self = [super init]) {
        _currentUserPK = [userPK copy];
        _currentSnapshot = currentSnapshot;
        _selectedIndexes = [NSMutableIndexSet indexSet];
    }
    return self;
}

- (BOOL)scanHistory_isDarkMode {
    if (@available(iOS 12.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES;
}
- (UIColor *)scanHistory_backgroundColor {
    return [self scanHistory_isDarkMode] ? [UIColor colorWithWhite:0.12f alpha:1.0f] : [UIColor colorWithWhite:0.96f alpha:1.0f];
}
- (UIColor *)scanHistory_cellBackgroundColor {
    return [self scanHistory_isDarkMode] ? [UIColor colorWithWhite:0.2f alpha:1.0f] : [UIColor whiteColor];
}
- (UIColor *)scanHistory_primaryTextColor {
    return [self scanHistory_isDarkMode] ? [UIColor whiteColor] : [UIColor colorWithWhite:0.1f alpha:1.0f];
}
- (UIColor *)scanHistory_secondaryTextColor {
    return [self scanHistory_isDarkMode] ? [UIColor lightGrayColor] : [UIColor colorWithWhite:0.45f alpha:1.0f];
}
- (UIColor *)scanHistory_tertiaryTextColor {
    return [self scanHistory_isDarkMode] ? [UIColor colorWithWhite:0.6f alpha:1.0f] : [UIColor colorWithWhite:0.45f alpha:1.0f];
}
- (void)scanHistory_applyTheme {
    self.view.backgroundColor = [self scanHistory_backgroundColor];
    if (_tableView) {
        _tableView.backgroundColor = [self scanHistory_backgroundColor];
        [_tableView reloadData];
    }
    if (_emptyLabel) _emptyLabel.textColor = [self scanHistory_tertiaryTextColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Scan history";
    self.view.backgroundColor = [self scanHistory_backgroundColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = [self scanHistory_backgroundColor];
    [self.view addSubview:_tableView];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, self.view.bounds.size.width - 40, 60)];
    _emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _emptyLabel.text = @"No scans yet.\nRun a scan from the main screen.";
    _emptyLabel.numberOfLines = 2;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [self scanHistory_tertiaryTextColor];
    _emptyLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    [_tableView addSubview:_emptyLabel];

    [self scanHistory_reloadFromStorage];
}

- (void)scanHistory_reloadFromStorageNotifyParent:(BOOL)notify {
    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    NSMutableArray<THProfileAnalyzerSnapshot *> *scans = [NSMutableArray array];
    for (NSInteger idx = 0; ; idx++) {
        THProfileAnalyzerSnapshot *snap = [storage loadSnapshotAtIndex:idx forUserPK:_currentUserPK error:NULL];
        if (!snap) break;
        [scans addObject:snap];
    }
    _scans = [[[scans reverseObjectEnumerator] allObjects] copy]; // table: oldest first (row 0)
    THProfileAnalyzerSnapshot *latest = [storage loadSnapshotAtIndex:0 forUserPK:_currentUserPK error:NULL];
    _currentSnapshot = latest;

    if (_selectionMode) {
        [_selectedIndexes removeAllIndexes];
        if (_scans.count < 2)
            _selectionMode = NO;
    }

    _emptyLabel.hidden = (_scans.count > 0);
    [_tableView reloadData];
    [self scanHistory_updateBarButtons];
    if (notify && self.onScanHistoryDidMutateStorage)
        self.onScanHistoryDidMutateStorage();
}

- (void)scanHistory_reloadFromStorage {
    [self scanHistory_reloadFromStorageNotifyParent:NO];
}

- (NSInteger)scanHistory_newestFirstIndexForTableRow:(NSInteger)row {
    if (row < 0 || !_scans.count) return NSNotFound;
    return (_scans.count - 1) - row;
}

- (void)scanHistory_promptClearAll {
    if (!_scans.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete all scans?" message:@"This removes every saved Profile Analyzer snapshot for this account from this device. It cannot be undone." preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) wself = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete all" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        typeof(self) s = wself;
        if (!s) return;
        (void)action;
        THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
        NSError *err = nil;
        BOOL ok = [storage deleteAllSnapshotsForUserPK:s->_currentUserPK error:&err];
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *eAlert = [UIAlertController alertControllerWithTitle:@"Could not delete" message:(err.localizedDescription.length ? err.localizedDescription : @"Unable to erase history.") preferredStyle:UIAlertControllerStyleAlert];
                [eAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [s presentViewController:eAlert animated:YES completion:nil];
            });
            return;
        }
        [s scanHistory_reloadFromStorageNotifyParent:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)scanHistory_deleteSelectedRows {
    if (!_selectedIndexes.count) return;
    NSInteger n = (NSInteger)_selectedIndexes.count;
    NSString *msg = [NSString stringWithFormat:@"Remove %zd selected scan%@ from history?", n, (n == 1) ? @"" : @"s"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete scans?" message:msg preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) wself = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        typeof(self) s = wself;
        if (!s) return;
        (void)action;
        NSMutableOrderedSet<NSNumber *> *offsets = [[NSMutableOrderedSet alloc] init];
        [s->_selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL * _Nonnull stop) {
            NSInteger off = [s scanHistory_newestFirstIndexForTableRow:(NSInteger)row];
            if (off != NSNotFound) [offsets addObject:@(off)];
        }];
        NSArray<NSNumber *> *sorted = [offsets.array sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
        THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
        for (NSNumber *num in sorted) {
            [storage deleteSnapshotAtNewestFirstIndex:num.integerValue forUserPK:s->_currentUserPK error:NULL];
        }
        [s scanHistory_reloadFromStorageNotifyParent:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self scanHistory_applyTheme];
        }
    }
}

- (void)scanHistory_updateBarButtons {
    self.navigationItem.rightBarButtonItems = nil;

    if (_scans.count == 0) {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }

    UIColor *destructiveTint = [UIColor redColor];
    if (@available(iOS 13.0, *))
        destructiveTint = [UIColor systemRedColor];

    if (_selectionMode) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(scanHistory_toggleSelectionMode)];
        NSInteger sel = (NSInteger)_selectedIndexes.count;
        UIBarButtonItem *bulkDel = [[UIBarButtonItem alloc] initWithTitle:(sel >= 1 ? [NSString stringWithFormat:@"Delete (%td)", sel] : @"Delete") style:UIBarButtonItemStylePlain target:self action:@selector(scanHistory_deleteSelectedRows)];
        bulkDel.enabled = (sel >= 1);
        bulkDel.tintColor = destructiveTint;
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:NULL];
        NSString *compareTitle = sel >= 2 ? [NSString stringWithFormat:@"Compare (%td)", sel] : @"Compare";
        UIBarButtonItem *compare = [[UIBarButtonItem alloc] initWithTitle:compareTitle style:UIBarButtonItemStyleDone target:self action:@selector(scanHistory_compareSelected)];
        compare.enabled = (sel >= 2);
        self.navigationItem.rightBarButtonItems = @[ bulkDel, flex, compare ];
        return;
    }

    UIBarButtonItem *clearAll = [[UIBarButtonItem alloc] initWithTitle:@"Clear all" style:UIBarButtonItemStylePlain target:self action:@selector(scanHistory_promptClearAll)];
    clearAll.tintColor = destructiveTint;
    self.navigationItem.leftBarButtonItem = nil;
    self.navigationItem.rightBarButtonItems = nil;
    if (_scans.count >= 2) {
        UIBarButtonItem *compare = [[UIBarButtonItem alloc] initWithTitle:@"Compare" style:UIBarButtonItemStylePlain target:self action:@selector(scanHistory_toggleSelectionMode)];
        /* First item sits closer to the title; second is the trailing (right edge) button. */
        self.navigationItem.rightBarButtonItems = @[ compare, clearAll ];
    } else {
        self.navigationItem.rightBarButtonItem = clearAll;
    }
}

- (void)scanHistory_toggleSelectionMode {
    _selectionMode = !_selectionMode;
    if (!_selectionMode) {
        [_selectedIndexes removeAllIndexes];
        self.navigationItem.rightBarButtonItems = nil;
    }
    [self scanHistory_updateBarButtons];
    [_tableView reloadData];
}

- (void)scanHistory_compareSelected {
    if (_selectedIndexes.count < 2) return;
    NSMutableArray<THProfileAnalyzerSnapshot *> *selected = [NSMutableArray array];
    [_selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx < _scans.count) [selected addObject:_scans[idx]];
    }];
    [selected sortUsingComparator:^NSComparisonResult(THProfileAnalyzerSnapshot *a, THProfileAnalyzerSnapshot *b) {
        return [a.scannedAt compare:b.scannedAt];
    }];
    THProfileAnalyzerScanCompareViewController *compareVC = [[THProfileAnalyzerScanCompareViewController alloc] initWithScans:[selected copy]];
    [self.navigationController pushViewController:compareVC animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _scans.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"ScanCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    }
    cell.textLabel.textColor = [self scanHistory_primaryTextColor];
    cell.detailTextLabel.textColor = [self scanHistory_secondaryTextColor];
    cell.backgroundColor = [self scanHistory_cellBackgroundColor];
    THProfileAnalyzerSnapshot *snap = _scans[indexPath.row];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterMediumStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    cell.textLabel.text = [fmt stringFromDate:snap.scannedAt];
    NSInteger f = THProfileAnalyzerEffectiveFollowersCount(snap), g = THProfileAnalyzerEffectiveFollowingCount(snap);
    NSMutableString *sub = [NSMutableString stringWithFormat:@"%td followers  ·  %td following", f, g];
    if (_currentSnapshot && snap != _currentSnapshot) {
        NSInteger curF = THProfileAnalyzerEffectiveFollowersCount(_currentSnapshot), curG = THProfileAnalyzerEffectiveFollowingCount(_currentSnapshot);
        [sub appendFormat:@"  (Δ vs now: %+td %+td)", f - curF, g - curG];
    }
    cell.detailTextLabel.text = [sub copy];
    if (_selectionMode) {
        cell.accessoryType = [_selectedIndexes containsIndex:indexPath.row] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_selectionMode) {
        if ([_selectedIndexes containsIndex:indexPath.row])
            [_selectedIndexes removeIndex:indexPath.row];
        else
            [_selectedIndexes addIndex:indexPath.row];
        [self scanHistory_updateBarButtons];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return !_selectionMode;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_selectionMode || editingStyle != UITableViewCellEditingStyleDelete) return;
    NSInteger newestFirst = [self scanHistory_newestFirstIndexForTableRow:indexPath.row];
    if (newestFirst == NSNotFound) return;
    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    if ([storage deleteSnapshotAtNewestFirstIndex:newestFirst forUserPK:_currentUserPK error:NULL])
        [self scanHistory_reloadFromStorageNotifyParent:YES];
}

@end

// MARK: - Scan Compare (graph view)
@implementation THProfileAnalyzerScanCompareGraphView
- (void)setScans:(NSArray<THProfileAnalyzerSnapshot *> *)scans {
    _scans = [scans copy];
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    if (_scans.count == 0) return;
    NSInteger maxVal = 0;
    for (THProfileAnalyzerSnapshot *s in _scans) {
        NSInteger f = s.apiFollowersCount >= 0 ? s.apiFollowersCount : (NSInteger)s.followers.count;
        NSInteger g = s.apiFollowingCount >= 0 ? s.apiFollowingCount : (NSInteger)s.following.count;
        if (f > maxVal) maxVal = f;
        if (g > maxVal) maxVal = g;
    }
    if (maxVal <= 0) maxVal = 1;
    CGFloat chartTop = 28, chartBottom = rect.size.height - 44, chartLeft = 52, chartRight = rect.size.width - 16;
    CGFloat chartW = chartRight - chartLeft, chartH = chartBottom - chartTop;
    if (chartW <= 0 || chartH <= 0) return;

    NSInteger n = (NSInteger)_scans.count;
    CGFloat yScale = (CGFloat)maxVal > 0 ? chartH / (CGFloat)maxVal : 0;
    CGFloat stepX = (n > 1) ? chartW / (CGFloat)(n - 1) : 0;

    UIColor *followersColor = _isDarkMode ? [UIColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1.0] : [UIColor colorWithRed:0.2 green:0.45 blue:0.9 alpha:1.0];
    UIColor *followingColor = _isDarkMode ? [UIColor colorWithRed:1.0 green:0.6 blue:0.35 alpha:1.0] : [UIColor colorWithRed:0.9 green:0.5 blue:0.2 alpha:1.0];
    UIColor *axisColor = _isDarkMode ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.6 alpha:1.0];
    UIColor *labelColor = _isDarkMode ? [UIColor colorWithWhite:0.85 alpha:1.0] : [UIColor colorWithWhite:0.2 alpha:1.0];
    UIColor *gridColor = _isDarkMode ? [UIColor colorWithWhite:0.22 alpha:1.0] : [UIColor colorWithWhite:0.88 alpha:1.0];

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    // Grid lines (horizontal)
    for (NSInteger g = 0; g <= 4; g++) {
        CGFloat y = chartBottom - chartH * (CGFloat)g / 4.0f;
        CGContextSetStrokeColorWithColor(ctx, gridColor.CGColor);
        CGContextSetLineWidth(ctx, 1.0f / (self.window.screen ? self.window.screen.scale : 1));
        CGContextMoveToPoint(ctx, chartLeft, y);
        CGContextAddLineToPoint(ctx, chartRight, y);
        CGContextStrokePath(ctx);
    }

    // Build points for followers and following lines
    CGMutablePathRef followersPath = CGPathCreateMutable();
    CGMutablePathRef followingPath = CGPathCreateMutable();
    CGPoint *fPts = (CGPoint *)malloc((size_t)n * sizeof(CGPoint));
    CGPoint *gPts = (CGPoint *)malloc((size_t)n * sizeof(CGPoint));
    for (NSInteger i = 0; i < n; i++) {
        THProfileAnalyzerSnapshot *s = _scans[i];
        NSInteger fCount = s.apiFollowersCount >= 0 ? s.apiFollowersCount : (NSInteger)s.followers.count;
        NSInteger gCount = s.apiFollowingCount >= 0 ? s.apiFollowingCount : (NSInteger)s.following.count;
        CGFloat x = (n > 1) ? (chartLeft + (CGFloat)i * stepX) : (chartLeft + chartW / 2);
        CGFloat fY = chartBottom - (CGFloat)fCount * yScale;
        CGFloat gY = chartBottom - (CGFloat)gCount * yScale;
        fPts[i] = CGPointMake(x, fY);
        gPts[i] = CGPointMake(x, gY);
        if (i == 0) {
            CGPathMoveToPoint(followersPath, NULL, x, fY);
            CGPathMoveToPoint(followingPath, NULL, x, gY);
        } else {
            CGPathAddLineToPoint(followersPath, NULL, x, fY);
            CGPathAddLineToPoint(followingPath, NULL, x, gY);
        }
    }

    // Gradient fill under followers line
    CGMutablePathRef fillPathF = CGPathCreateMutable();
    CGPathMoveToPoint(fillPathF, NULL, fPts[0].x, fPts[0].y);
    for (NSInteger i = 1; i < n; i++) CGPathAddLineToPoint(fillPathF, NULL, fPts[i].x, fPts[i].y);
    CGPathAddLineToPoint(fillPathF, NULL, fPts[n - 1].x, chartBottom);
    CGPathAddLineToPoint(fillPathF, NULL, fPts[0].x, chartBottom);
    CGPathCloseSubpath(fillPathF);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, fillPathF);
    CGContextClip(ctx);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[4] = { 0.35f, 0.6f, 1.0f, _isDarkMode ? 0.22f : 0.18f };
    if (!_isDarkMode) { comps[0] = 0.2f; comps[1] = 0.45f; comps[2] = 0.9f; }
    CGColorRef c = CGColorCreate(cs, comps);
    CGContextSetFillColorWithColor(ctx, c);
    CGContextFillRect(ctx, CGRectMake(chartLeft, chartTop, chartW, chartH));
    CGColorRelease(c);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);
    CGPathRelease(fillPathF);

    // Gradient fill under following line
    CGMutablePathRef fillPathG = CGPathCreateMutable();
    CGPathMoveToPoint(fillPathG, NULL, gPts[0].x, gPts[0].y);
    for (NSInteger i = 1; i < n; i++) CGPathAddLineToPoint(fillPathG, NULL, gPts[i].x, gPts[i].y);
    CGPathAddLineToPoint(fillPathG, NULL, gPts[n - 1].x, chartBottom);
    CGPathAddLineToPoint(fillPathG, NULL, gPts[0].x, chartBottom);
    CGPathCloseSubpath(fillPathG);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, fillPathG);
    CGContextClip(ctx);
    cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps2[4] = { 1.0f, 0.6f, 0.35f, _isDarkMode ? 0.22f : 0.18f };
    if (!_isDarkMode) { comps2[0] = 0.9f; comps2[1] = 0.5f; comps2[2] = 0.2f; }
    c = CGColorCreate(cs, comps2);
    CGContextSetFillColorWithColor(ctx, c);
    CGContextFillRect(ctx, CGRectMake(chartLeft, chartTop, chartW, chartH));
    CGColorRelease(c);
    CGColorSpaceRelease(cs);
    CGContextRestoreGState(ctx);
    CGPathRelease(fillPathG);

    // Stroke the lines (rounded join/cap)
    CGContextSetLineWidth(ctx, 2.5f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextAddPath(ctx, followersPath);
    CGContextSetStrokeColorWithColor(ctx, followersColor.CGColor);
    CGContextStrokePath(ctx);
    CGContextAddPath(ctx, followingPath);
    CGContextSetStrokeColorWithColor(ctx, followingColor.CGColor);
    CGContextStrokePath(ctx);

    // Data point circles
    CGFloat dotRadius = 4.0f;
    for (NSInteger i = 0; i < n; i++) {
        CGContextSetFillColorWithColor(ctx, followersColor.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(fPts[i].x - dotRadius, fPts[i].y - dotRadius, dotRadius * 2, dotRadius * 2));
        CGContextSetStrokeColorWithColor(ctx, _isDarkMode ? [UIColor colorWithWhite:0.15 alpha:1].CGColor : [UIColor whiteColor].CGColor);
        CGContextSetLineWidth(ctx, 1.5f);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(fPts[i].x - dotRadius, fPts[i].y - dotRadius, dotRadius * 2, dotRadius * 2));
        CGContextSetFillColorWithColor(ctx, followingColor.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(gPts[i].x - dotRadius, gPts[i].y - dotRadius, dotRadius * 2, dotRadius * 2));
        CGContextSetStrokeColorWithColor(ctx, _isDarkMode ? [UIColor colorWithWhite:0.15 alpha:1].CGColor : [UIColor whiteColor].CGColor);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(gPts[i].x - dotRadius, gPts[i].y - dotRadius, dotRadius * 2, dotRadius * 2));
    }
    free(fPts);
    free(gPts);
    CGPathRelease(followersPath);
    CGPathRelease(followingPath);

    // Axes
    CGContextSetStrokeColorWithColor(ctx, axisColor.CGColor);
    CGContextSetLineWidth(ctx, 1.0f);
    CGContextMoveToPoint(ctx, chartLeft, chartTop);
    CGContextAddLineToPoint(ctx, chartLeft, chartBottom);
    CGContextAddLineToPoint(ctx, chartRight, chartBottom);
    CGContextStrokePath(ctx);

    // Labels
    NSDictionary *fontAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightRegular], NSForegroundColorAttributeName: labelColor };
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"M/d";
    for (NSInteger i = 0; i < n; i++) {
        THProfileAnalyzerSnapshot *s = _scans[i];
        CGFloat cx = (n > 1) ? (chartLeft + (CGFloat)i * stepX) : (chartLeft + chartW / 2);
        NSString *label = [fmt stringFromDate:s.scannedAt];
        CGSize size = [label sizeWithAttributes:fontAttrs];
        [label drawAtPoint:CGPointMake(cx - size.width / 2, chartBottom + 6) withAttributes:fontAttrs];
    }
    NSString *maxLabel = [NSString stringWithFormat:@"%td", maxVal];
    CGSize maxSize = [maxLabel sizeWithAttributes:fontAttrs];
    [maxLabel drawAtPoint:CGPointMake(chartLeft - maxSize.width - 4, chartTop - maxSize.height/2) withAttributes:fontAttrs];
}

@end

@implementation THProfileAnalyzerScanCompareViewController {
    NSArray<THProfileAnalyzerSnapshot *> *_scans;
    THProfileAnalyzerScanCompareGraphView *_graphView;
    UIScrollView *_scrollView;
    UILabel *_legendFollowers;
    UILabel *_legendFollowing;
}

- (instancetype)initWithScans:(NSArray<THProfileAnalyzerSnapshot *> *)scans {
    if (self = [super init]) {
        _scans = [scans copy];
    }
    return self;
}

- (BOOL)compare_isDarkMode {
    if (@available(iOS 12.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Compare scans";
    UIColor *bg = [self compare_isDarkMode] ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor colorWithWhite:0.96 alpha:1];
    self.view.backgroundColor = bg;

    CGFloat w = self.view.bounds.size.width;
    CGFloat graphHeight = 220;
    CGFloat legendH = 36;

    _graphView = [[THProfileAnalyzerScanCompareGraphView alloc] initWithFrame:CGRectMake(0, 0, w, graphHeight)];
    _graphView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _graphView.scans = _scans;
    _graphView.isDarkMode = [self compare_isDarkMode];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.backgroundColor = bg;
    _scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:_scrollView];

    [_scrollView addSubview:_graphView];

    UIColor *followersColor = [self compare_isDarkMode] ? [UIColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1.0] : [UIColor colorWithRed:0.2 green:0.45 blue:0.9 alpha:1.0];
    UIColor *followingColor = [self compare_isDarkMode] ? [UIColor colorWithRed:1.0 green:0.6 blue:0.35 alpha:1.0] : [UIColor colorWithRed:0.9 green:0.5 blue:0.2 alpha:1.0];
    _legendFollowers = [[UILabel alloc] initWithFrame:CGRectMake(16, graphHeight + 8, w - 32, 18)];
    _legendFollowers.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _legendFollowers.textColor = followersColor;
    _legendFollowers.text = @"— Followers";
    _legendFollowers.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_scrollView addSubview:_legendFollowers];

    _legendFollowing = [[UILabel alloc] initWithFrame:CGRectMake(16, graphHeight + 26, w - 32, 18)];
    _legendFollowing.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _legendFollowing.textColor = followingColor;
    _legendFollowing.text = @"— Following";
    _legendFollowing.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_scrollView addSubview:_legendFollowing];

    CGFloat contentH = graphHeight + legendH + 20;
    _scrollView.contentSize = CGSizeMake(w, contentH);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            BOOL dark = [self compare_isDarkMode];
            self.view.backgroundColor = dark ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor colorWithWhite:0.96 alpha:1];
            _scrollView.backgroundColor = self.view.backgroundColor;
            _graphView.isDarkMode = dark;
            [_graphView setNeedsDisplay];
            UIColor *followersColor = dark ? [UIColor colorWithRed:0.35 green:0.6 blue:1.0 alpha:1.0] : [UIColor colorWithRed:0.2 green:0.45 blue:0.9 alpha:1.0];
            UIColor *followingColor = dark ? [UIColor colorWithRed:1.0 green:0.6 blue:0.35 alpha:1.0] : [UIColor colorWithRed:0.9 green:0.5 blue:0.2 alpha:1.0];
            _legendFollowers.textColor = followersColor;
            _legendFollowing.textColor = followingColor;
        }
    }
}

@end

// MARK: - User history (per-user timeline)
typedef NS_ENUM(NSInteger, THProfileAnalyzerUserHistoryRowKind) {
    THProfileAnalyzerUserHistoryRowSummaryFirst,
    THProfileAnalyzerUserHistoryRowSummaryLast,
    THProfileAnalyzerUserHistoryRowSummaryCount,
    THProfileAnalyzerUserHistoryRowScan
};

@implementation THProfileAnalyzerUserHistoryViewController {
    NSString *_userPK;
    NSString *_username;
    NSString *_currentUserPK;
    NSArray<THProfileAnalyzerSnapshot *> *_scans; // newest first
    NSArray<NSDictionary *> *_scanStatus; // @[ @{ @"date": NSDate, @"followsYou": @YES/NO, @"youFollow": @YES/NO }, ... ]
    NSDate *_firstSeen;
    NSDate *_lastSeen;
    NSInteger _appearanceCount;
    UITableView *_tableView;
}

- (instancetype)initWithUserPK:(NSString *)userPK username:(NSString * _Nullable)username currentUserPK:(NSString *)currentUserPK {
    if (self = [super init]) {
        _userPK = [userPK copy];
        _username = [username copy] ?: userPK;
        _currentUserPK = [currentUserPK copy];
    }
    return self;
}

static BOOL _userPKInArray(NSString *pk, NSArray<THProfileAnalyzerUser *> *arr) {
    if (!pk.length) return NO;
    for (THProfileAnalyzerUser *u in arr) if ([u.pk isEqualToString:pk]) return YES;
    return NO;
}

- (BOOL)userHistory_isDarkMode {
    if (@available(iOS 12.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES;
}
- (UIColor *)userHistory_backgroundColor {
    return [self userHistory_isDarkMode] ? [UIColor colorWithWhite:0.12f alpha:1.0f] : [UIColor colorWithWhite:0.96f alpha:1.0f];
}
- (UIColor *)userHistory_cellBackgroundColor {
    return [self userHistory_isDarkMode] ? [UIColor colorWithWhite:0.2f alpha:1.0f] : [UIColor whiteColor];
}
- (UIColor *)userHistory_primaryTextColor {
    return [self userHistory_isDarkMode] ? [UIColor whiteColor] : [UIColor colorWithWhite:0.1f alpha:1.0f];
}
- (UIColor *)userHistory_secondaryTextColor {
    return [self userHistory_isDarkMode] ? [UIColor lightGrayColor] : [UIColor colorWithWhite:0.45f alpha:1.0f];
}
- (void)userHistory_applyTheme {
    self.view.backgroundColor = [self userHistory_backgroundColor];
    if (_tableView) {
        _tableView.backgroundColor = [self userHistory_backgroundColor];
        [_tableView reloadData];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _username.length ? _username : @"History";
    self.view.backgroundColor = [self userHistory_backgroundColor];

    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    NSMutableArray<THProfileAnalyzerSnapshot *> *scans = [NSMutableArray array];
    for (NSInteger idx = 0; ; idx++) {
        THProfileAnalyzerSnapshot *snap = [storage loadSnapshotAtIndex:idx forUserPK:_currentUserPK error:NULL];
        if (!snap) break;
        [scans addObject:snap];
    }
    _scans = [[[scans reverseObjectEnumerator] allObjects] copy];

    NSMutableArray<NSDictionary *> *status = [NSMutableArray array];
    NSDate *first = nil, *last = nil;
    NSInteger count = 0;
    NSArray<THProfileAnalyzerSnapshot *> *scansNewestFirst = _scans;
    for (NSInteger i = 0; i < (NSInteger)scansNewestFirst.count; i++) {
        THProfileAnalyzerSnapshot *snap = scansNewestFirst[i];
        BOOL followsYou = _userPKInArray(_userPK, snap.followers);
        BOOL youFollow = _userPKInArray(_userPK, snap.following);
        NSMutableArray<NSString *> *events = [NSMutableArray array];
        if (i + 1 < (NSInteger)scansNewestFirst.count) {
            THProfileAnalyzerSnapshot *older = scansNewestFirst[i + 1];
            BOOL prevFY = _userPKInArray(_userPK, older.followers);
            BOOL prevYF = _userPKInArray(_userPK, older.following);
            if (!prevFY && followsYou) [events addObject:@"Started following you"];
            if (prevFY && !followsYou) [events addObject:@"Stopped following you"];
            if (!prevYF && youFollow) [events addObject:@"You followed"];
            if (prevYF && !youFollow) [events addObject:@"You unfollowed"];
        }
        [status addObject:@{
            @"date": snap.scannedAt,
            @"followsYou": @(followsYou),
            @"youFollow": @(youFollow),
            @"events": [events copy]
        }];
        if (followsYou || youFollow) {
            if (!first) first = snap.scannedAt;
            last = snap.scannedAt;
            count++;
        }
    }
    _scanStatus = [status copy];
    _firstSeen = first;
    _lastSeen = last;
    _appearanceCount = count;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = [self userHistory_backgroundColor];
    [self.view addSubview:_tableView];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self userHistory_applyTheme];
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // Summary, Timeline
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    return _scanStatus.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        NSDictionary *s = _scanStatus[indexPath.row];
        NSArray *events = s[@"events"];
        if ([events isKindOfClass:[NSArray class]] && ((NSArray *)events).count > 0) return 64;
    }
    return 56;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Summary" : @"By scan";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    }
    cell.textLabel.textColor = [self userHistory_primaryTextColor];
    cell.detailTextLabel.textColor = [self userHistory_secondaryTextColor];
    cell.backgroundColor = [self userHistory_cellBackgroundColor];
    if (indexPath.section == 0) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"First seen";
            cell.detailTextLabel.text = _firstSeen ? [fmt stringFromDate:_firstSeen] : @"—";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Last seen";
            cell.detailTextLabel.text = _lastSeen ? [fmt stringFromDate:_lastSeen] : @"—";
        } else {
            cell.textLabel.text = @"In scans";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%td", _appearanceCount];
        }
        return cell;
    }
    NSDictionary *s = _scanStatus[indexPath.row];
    NSDate *date = s[@"date"];
    BOOL followsYou = [s[@"followsYou"] boolValue];
    BOOL youFollow = [s[@"youFollow"] boolValue];
    NSArray<NSString *> *events = s[@"events"];
    if (![events isKindOfClass:[NSArray class]]) events = @[];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    cell.textLabel.text = [fmt stringFromDate:date];
    NSMutableString *sub = [NSMutableString string];
    if (followsYou) [sub appendString:@"Follows you"];
    if (youFollow) [sub appendString:sub.length ? @"  ·  You follow" : @"You follow"];
    if (!sub.length) [sub appendString:@"—"];
    if (events.count) {
        [sub appendFormat:@"\n%@", [events componentsJoinedByString:@"  ·  "]];
    }
    cell.detailTextLabel.text = [sub copy];
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
}

@end

@interface THProfileAnalyzerNetworkDelegate : NSObject <THProfileAnalyzerAPIClientNetworkDelegate>
@end

@implementation THProfileAnalyzerNetworkDelegate
- (void)performGETRequestWithURL:(NSURL *)url success:(void (^)(NSDictionary * _Nullable))success failure:(void (^)(NSError * _Nonnull))failure {
    id networker = THProfileAnalyzerGetNetworker();
    NSString *endpointPath = nil;
    NSDictionary *queryParams = nil;
    THProfileAnalyzerParseAPIURL(url, &endpointPath, &queryParams);

    /* Instagram calls success with (response, result): arg1=NSHTTPURLResponse, arg2=parsed body. Pass only a real NSDictionary so the fetcher's json[@"users"] works. */
    void (^onSuccess)(id, id) = ^(id a, id b) {
        NSDictionary *jsonToPass = nil;
        if ([b isKindOfClass:[NSDictionary class]])
            jsonToPass = (NSDictionary *)b;
        else if ([a isKindOfClass:[NSDictionary class]])
            jsonToPass = (NSDictionary *)a;
        else if (b && [b respondsToSelector:@selector(objectForKey:)] && [b respondsToSelector:@selector(allKeys)]) {
            /* Custom dict-like: copy to real NSDictionary; normalize keys; convert user objects to dicts. */
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            for (id key in [b allKeys]) {
                id val = [b objectForKey:key];
                if (!key || !val) continue;
                if ([key isEqual:@"users"] || [key isEqual:@"Users"]) {
                    NSArray *arr = [val isKindOfClass:[NSArray class]] ? (NSArray *)val : nil;
                    if (arr) {
                        NSMutableArray *outArr = [NSMutableArray arrayWithCapacity:arr.count];
                        for (id u in arr) {
                            if ([u isKindOfClass:[NSDictionary class]]) {
                                [outArr addObject:u];
                            } else if (u && [u respondsToSelector:@selector(objectForKey:)] && [u respondsToSelector:@selector(allKeys)]) {
                                NSMutableDictionary *ud = [NSMutableDictionary dictionary];
                                for (id k in [u allKeys]) { id v = [u objectForKey:k]; if (k && v) ud[k] = v; }
                                ud[@"pk"] = ud[@"pk"] ?: ud[@"PK"];
                                ud[@"username"] = ud[@"username"] ?: ud[@"Username"];
                                ud[@"full_name"] = ud[@"full_name"] ?: ud[@"fullName"];
                                ud[@"profile_pic_url"] = ud[@"profile_pic_url"] ?: ud[@"profilePicUrl"];
                                id ppid = ud[@"profile_pic_id"] ?: ud[@"profilePicId"];
                                if (ppid && !ud[@"profile_pic_id"]) ud[@"profile_pic_id"] = [ppid respondsToSelector:@selector(stringValue)] ? [(id)ppid stringValue] : ppid;
                                [outArr addObject:ud];
                            }
                        }
                        m[@"users"] = outArr;
                    }
                    continue;
                }
                m[key] = val;
            }
            id next = m[@"next_max_id"] ?: m[@"nextMaxId"] ?: m[@"NextMaxId"];
            if (next) m[@"next_max_id"] = next;
            if (m.count) jsonToPass = m;
        }
        NSDictionary *finalJson = jsonToPass;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                success(finalJson);
            } @catch (NSException *ex) {
            }
        });
    };
    void (^onFailure)(id) = ^(id err) {
        NSError *e = nil;
        if ([err isKindOfClass:[NSError class]]) {
            e = (NSError *)err;
        } else if ([err isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger code = [(NSHTTPURLResponse *)err statusCode];
            NSString *msg = [NSString stringWithFormat:@"Server returned %ld", (long)code];
            if (code == 405) msg = @"Method not allowed (405). Request may be using wrong HTTP method.";
            e = [NSError errorWithDomain:@"THProfileAnalyzer" code:code userInfo:@{ NSLocalizedDescriptionKey: msg }];
        } else {
            e = [NSError errorWithDomain:@"THProfileAnalyzer" code:401 userInfo:@{ NSLocalizedDescriptionKey: err ? [err description] : @"Request failed" }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ failure(e); });
    };

    /* 1) Use Instagram's networker + signed request (Regram-style). Try IGAPIRequestBuilder first, then IGURLRequest with full URL. */
    /* Use method 0 for GET (Instagram may use 0=GET, 1=POST; 405 = Method Not Allowed when we sent 1). */
    if (networker) {
        id igRequest = nil;
        if (endpointPath.length)
            igRequest = THProfileAnalyzerBuildIGRequest(endpointPath, queryParams, 0);
        if (!igRequest)
            igRequest = THProfileAnalyzerBuildIGURLRequest(url, 0);
        if (igRequest) {
            if ([networker respondsToSelector:@selector(startAPIRequest:policy:successHandler:failureHandler:)]) {
                typedef void (*StartAPIReqFn)(id, SEL, id, id, id, id);
                ((StartAPIReqFn)objc_msgSend)(networker, @selector(startAPIRequest:policy:successHandler:failureHandler:), igRequest, (id)0, onSuccess, onFailure);
                return;
            }
            if ([networker respondsToSelector:@selector(startAPIRequest:successHandler:failureHandler:)]) {
                typedef void (*StartAPIReqShortFn)(id, SEL, id, id, id);
                ((StartAPIReqShortFn)objc_msgSend)(networker, @selector(startAPIRequest:successHandler:failureHandler:), igRequest, onSuccess, onFailure);
                return;
            }
        }
    }

    /* 2) Fallback: manual request (often 401). */
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Instagram 329.0.0.0.0 (iPhone; iOS 17_0; en_US; en; scale=3.00; 1179x2556; 0)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"124024574287414" forHTTPHeaderField:@"X-IG-App-ID"];
    [request setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [request setValue:@"en-US" forHTTPHeaderField:@"Accept-Language"];
    [request setValue:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"https://i.instagram.com/" forHTTPHeaderField:@"Referer"];
    NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
    if (cookies.count) {
        NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
        if (cookieHeader.length) [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    }
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ failure(error); });
            return;
        }
        NSInteger code = 200;
        if (response && [response isKindOfClass:[NSHTTPURLResponse class]])
            code = [(NSHTTPURLResponse *)response statusCode];
        if (code != 200 && code != 0) {
            NSString *msg = nil;
            NSDictionary *errJson = (data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil);
            if ([errJson isKindOfClass:[NSDictionary class]]) {
                id m = errJson[@"message"];
                if ([m isKindOfClass:[NSString class]] && ((NSString *)m).length) {
                    msg = (NSString *)m;
                } else if ([m isKindOfClass:[NSArray class]]) {
                    NSArray *arr = (NSArray *)m;
                    NSMutableArray *parts = [NSMutableArray array];
                    for (id item in arr)
                        if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length) [parts addObject:item];
                    if (parts.count) msg = [parts componentsJoinedByString:@" "];
                }
                if (!msg.length) {
                    id fe = errJson[@"feedback_message"] ?: errJson[@"error_message"];
                    if ([fe isKindOfClass:[NSString class]]) msg = fe;
                }
            }
            if (!msg.length && code == 401) msg = @"Not authorized (401).";
            if (!msg.length) msg = [NSString stringWithFormat:NSLocalizedString(@"Server returned %ld", @""), (long)code];
            dispatch_async(dispatch_get_main_queue(), ^{ failure([NSError errorWithDomain:@"THProfileAnalyzer" code:code userInfo:@{ NSLocalizedDescriptionKey: msg }]); });
            return;
        }
        NSDictionary *json = (data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil);
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ success(json); });
    }] resume];
}
@end

typedef NS_ENUM(NSInteger, THProfileAnalyzerMetric) {
    THProfileAnalyzerMetricNewFollowers,
    THProfileAnalyzerMetricLostFollowers,
    THProfileAnalyzerMetricYouFollowed,
    THProfileAnalyzerMetricYouUnfollowed,
    THProfileAnalyzerMetricNotFollowingYouBack,
    THProfileAnalyzerMetricYouDontFollowBack,
    THProfileAnalyzerMetricMutualFollowers,
    THProfileAnalyzerMetricCount
};

@interface THProfileAnalyzerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIView *statsHeaderView;
@property (nonatomic, strong) UIView *headerCardView; /* rounded background for profile section */
@property (nonatomic, strong) UIImageView *profileImageView;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UILabel *followersFollowingLabel;
@property (nonatomic, strong) UIButton *scanNowButton;
@property (nonatomic, strong) UIView *scanButtonFooterView; /* container for table footer */
@property (nonatomic, strong) UIButton *infoButton;
@property (nonatomic, strong) UITableView *metricsTableView;
@property (nonatomic, strong) UIActivityIndicatorView *activityView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong, nullable) THProfileAnalyzerResult *result;
@property (nonatomic, strong, nullable) THProfileAnalyzerDiffResult *previousDiff;
@property (nonatomic, copy) NSString *currentUserPK;
@property (nonatomic, assign) NSInteger scanCount;
@property (nonatomic, assign) NSInteger apiFollowersCount;  /* -1 = not loaded; label is driven only from API */
@property (nonatomic, assign) NSInteger apiFollowingCount;
@property (nonatomic, strong) id networkDelegate;
@property (nonatomic, strong, nullable) THProfileAnalyzerService *profileAnalyzerScanner;
@end

@implementation THProfileAnalyzerViewController

#pragma mark - Theme (dark / light)

- (BOOL)pa_isDarkMode {
    if (@available(iOS 12.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES; /* default to dark when unspecified */
}

- (UIColor *)pa_backgroundColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.12f alpha:1.0f] : [UIColor colorWithWhite:0.96f alpha:1.0f];
}
- (UIColor *)pa_cardBackgroundColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.18f alpha:1.0f] : [UIColor whiteColor];
}
- (UIColor *)pa_profileImagePlaceholderColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.28f alpha:1.0f] : [UIColor colorWithWhite:0.92f alpha:1.0f];
}
- (UIColor *)pa_primaryTextColor {
    return [self pa_isDarkMode] ? [UIColor whiteColor] : [UIColor colorWithWhite:0.1f alpha:1.0f];
}
- (UIColor *)pa_secondaryTextColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.75f alpha:1.0f] : [UIColor colorWithWhite:0.4f alpha:1.0f];
}
- (UIColor *)pa_tertiaryTextColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.6f alpha:1.0f] : [UIColor colorWithWhite:0.45f alpha:1.0f];
}
- (UIColor *)pa_scanButtonBackgroundColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.25f alpha:1.0f] : [UIColor colorWithWhite:0.9f alpha:1.0f];
}
- (UIColor *)pa_accessoryTintColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.6f alpha:1.0f] : [UIColor colorWithWhite:0.5f alpha:1.0f];
}
- (UIColor *)pa_scanHistoryDetailColor {
    return [self pa_isDarkMode] ? [UIColor colorWithWhite:0.7f alpha:1.0f] : [UIColor colorWithWhite:0.5f alpha:1.0f];
}

- (void)pa_applyTheme {
    UIColor *bg = [self pa_backgroundColor];
    self.view.backgroundColor = bg;
    if (_metricsTableView) _metricsTableView.backgroundColor = bg;
    if (_scanButtonFooterView) _scanButtonFooterView.backgroundColor = bg;
    if (_headerCardView) _headerCardView.backgroundColor = [self pa_cardBackgroundColor];
    if (_profileImageView) _profileImageView.backgroundColor = [self pa_profileImagePlaceholderColor];
    if (_usernameLabel) _usernameLabel.textColor = [self pa_primaryTextColor];
    if (_followersFollowingLabel) _followersFollowingLabel.textColor = [self pa_secondaryTextColor];
    if (_statusLabel) _statusLabel.textColor = [self pa_tertiaryTextColor];
    if (_scanNowButton) _scanNowButton.backgroundColor = [self pa_scanButtonBackgroundColor];
    if (_metricsTableView) [_metricsTableView reloadData];
}

+ (NSString *)currentUserPKFromInstagram {
    @try {
        NSArray *windows = [UIApplication sharedApplication].windows;
        if (![windows isKindOfClass:[NSArray class]]) return nil;
        Class igWindowClass = NSClassFromString(@"IGWindow");
        if (!igWindowClass) return nil;
        for (UIWindow *w in windows) {
            if (!w || ![w isKindOfClass:igWindowClass]) continue;
            id session = nil;
            @try { session = [w valueForKey:@"userSession"]; } @catch (NSException *e) { continue; }
            if (!session) continue;
            id user = nil;
            @try { user = [session valueForKey:@"user"]; } @catch (NSException *e) { continue; }
            if (!user) continue;
            NSString *pk = nil;
            @try { pk = [user valueForKey:@"pk"]; } @catch (NSException *e) { continue; }
            if ([pk isKindOfClass:[NSNumber class]]) pk = [(NSNumber *)pk stringValue];
            if ([pk isKindOfClass:[NSString class]] && pk.length) return pk;
            if ([user respondsToSelector:@selector(pk)]) {
                id pkVal = nil;
                @try { pkVal = [user performSelector:@selector(pk)]; } @catch (NSException *e) { continue; }
                if ([pkVal isKindOfClass:[NSString class]] && ((NSString *)pkVal).length) return pkVal;
                if ([pkVal isKindOfClass:[NSNumber class]]) return [(NSNumber *)pkVal stringValue];
            }
        }
    } @catch (NSException *e) {
        return nil;
    }
    return nil;
}

+ (NSString *)currentUserUsernameFromInstagram {
    @try {
        NSArray *windows = [UIApplication sharedApplication].windows;
        if (![windows isKindOfClass:[NSArray class]]) return nil;
        Class igWindowClass = NSClassFromString(@"IGWindow");
        if (!igWindowClass) return nil;
        for (UIWindow *w in windows) {
            if (!w || ![w isKindOfClass:igWindowClass]) continue;
            id session = THGetIvar(w, "_userSession");
            if (!session) session = [w valueForKey:@"userSession"];
            if (!session) continue;
            id user = THGetIvar(session, "_user");
            if (!user) user = [session valueForKey:@"user"];
            if (!user) continue;
            NSString *name = nil;
            if ([user respondsToSelector:@selector(username)]) {
                id val = nil;
                @try { val = [user performSelector:@selector(username)]; } @catch (NSException *e) { }
                if ([val isKindOfClass:[NSString class]] && ((NSString *)val).length) name = (NSString *)val;
            }
            if (!name.length) {
                @try { name = [user valueForKey:@"username"]; } @catch (NSException *e) { }
            }
            if (name.length) return name;
        }
    } @catch (NSException *e) { return nil; }
    return nil;
}

+ (NSString *)currentUserProfilePicURLFromInstagram {
    id user = nil;
    @try {
        NSArray *windows = [UIApplication sharedApplication].windows;
        if (![windows isKindOfClass:[NSArray class]]) return nil;
        Class igWindowClass = NSClassFromString(@"IGWindow");
        if (!igWindowClass) return nil;
        for (UIWindow *w in windows) {
            if (!w || ![w isKindOfClass:igWindowClass]) continue;
            id session = THGetIvar(w, "_userSession");
            if (!session) session = [w valueForKey:@"userSession"];
            if (!session) continue;
            user = THGetIvar(session, "_user");
            if (!user) user = [session valueForKey:@"user"];
            if (user) break;
        }
    } @catch (NSException *e) { return nil; }
    if (!user) return nil;

    NSString *url = nil;
    for (NSString *selName in @[@"HDProfilePicURL", @"hdProfilePicURL"]) {
        SEL hdSel = NSSelectorFromString(selName);
        if ([user respondsToSelector:hdSel]) {
            typedef NSURL * (*URLMsgSend)(id, SEL);
            URLMsgSend fn = (URLMsgSend)objc_msgSend;
            NSURL *hdURL = fn(user, hdSel);
            if ([hdURL isKindOfClass:[NSURL class]] && hdURL.absoluteString.length) {
                url = hdURL.absoluteString;
                break;
            }
        }
    }
    if (!url.length) {
        SEL sel = NSSelectorFromString(@"profilePicURL");
        if ([user respondsToSelector:sel]) {
            typedef id (*ObjCMsgSend)(id, SEL);
            id picURL = ((ObjCMsgSend)objc_msgSend)(user, sel);
            if ([picURL isKindOfClass:[NSURL class]]) url = [(NSURL *)picURL absoluteString];
            else if ([picURL isKindOfClass:[NSString class]] && ((NSString *)picURL).length) url = (NSString *)picURL;
        }
    }
    if (!url.length) {
        for (NSString *key in @[@"profilePicURL", @"profile_pic_url", @"profilePictureURL", @"profilePicUrl"]) {
            @try {
                id val = [user valueForKey:key];
                if ([val isKindOfClass:[NSString class]] && ((NSString *)val).length) { url = val; break; }
                if ([val isKindOfClass:[NSURL class]] && ((NSURL *)val).absoluteString.length) { url = ((NSURL *)val).absoluteString; break; }
            } @catch (NSException *e) { continue; }
        }
    }
    return url;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Profile Analyzer";
    self.view.backgroundColor = [self pa_backgroundColor];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    _currentUserPK = [THProfileAnalyzerViewController currentUserPKFromInstagram];
    if (!_currentUserPK.length) {
        _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, self.view.bounds.size.width - 40, 80)];
        _statusLabel.text = @"Could not get current user. Make sure you are logged in.";
        _statusLabel.numberOfLines = 0;
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.textColor = [self pa_tertiaryTextColor];
        [self.view addSubview:_statusLabel];
        return;
    }

    [self buildDashboardUI];
    _apiFollowersCount = -1;
    _apiFollowingCount = -1;
    [self loadSavedAPICounts];
    [self loadLastResultAndRefresh];
    [self loadCurrentUserProfileImage];
    [self pa_applyTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    /* Force layout when we're visible so scan bar has correct frame after returning from a metric. */
    if (_metricsTableView && _scanButtonFooterView) {
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self pa_applyTheme];
        }
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_statsHeaderView || !_metricsTableView) return;
    /* Only update table/scan bar frames when we're the visible VC. Avoids applying transitional layout when returning from a pushed screen (stops button jumping up then down). */
    UINavigationController *nav = self.navigationController;
    if (nav && nav.topViewController != self) return;

    CGFloat w = self.view.bounds.size.width;
    static const CGFloat kHeaderSectionH = 90; /* profile + followers label only */
    static const CGFloat kHeaderVerticalInset = 12;
    static const CGFloat kHeaderHorizontalInset = 16;
    CGFloat headerH = kHeaderSectionH + kHeaderVerticalInset * 2;
    static const CGFloat kScanButtonFooterPadding = 20;
    CGFloat scanButtonH = 34;
    if (@available(iOS 26.0, *)) {
        scanButtonH = 50;
    }
    CGFloat tableH = self.view.bounds.size.height;
    CGFloat bottomInset = 0;
    if (@available(iOS 11.0, *)) {
        bottomInset = self.view.safeAreaInsets.bottom;
    }
    /* Button bar fixed at bottom of screen (not in table) so it's always visible without scrolling. */
    CGFloat buttonBarH = scanButtonH + kScanButtonFooterPadding * 2 + bottomInset;
    CGFloat tableHeight = tableH - buttonBarH;

    _statsHeaderView.frame = CGRectMake(0, 0, w, headerH);
    CGFloat cardW = w - kHeaderHorizontalInset * 2;
    CGFloat cardH = headerH - kHeaderVerticalInset * 2;
    _headerCardView.frame = CGRectMake(kHeaderHorizontalInset, kHeaderVerticalInset, cardW, cardH);

    static const CGFloat kProfileSize = 64;
    static const CGFloat kPadding = 20;
    static const CGFloat kUsernameH = 24;
    static const CGFloat kFollowersH = 24;
    static const CGFloat kTextGap = 4;
    CGFloat textBlockH = kUsernameH + kTextGap + kFollowersH;
    CGFloat centerY = cardH / 2.0f;
    _profileImageView.frame = CGRectMake(kPadding, centerY - kProfileSize / 2.0f, kProfileSize, kProfileSize);
    CGFloat textLeft = kPadding + kProfileSize + 16;
    CGFloat infoRight = 48;
    CGFloat textWidth = cardW - textLeft - infoRight;
    CGFloat textBlockTop = centerY - textBlockH / 2.0f;
    _usernameLabel.frame = CGRectMake(textLeft, textBlockTop, textWidth, kUsernameH);
    _followersFollowingLabel.frame = CGRectMake(textLeft, textBlockTop + kUsernameH + kTextGap, textWidth, kFollowersH);
    static const CGFloat kInfoButtonH = 40;
    _infoButton.frame = CGRectMake(cardW - 48, centerY - kInfoButtonH / 2.0f, 40, kInfoButtonH);

    _metricsTableView.frame = CGRectMake(0, 0, w, tableHeight);
    _metricsTableView.tableHeaderView = _statsHeaderView;
    _scanButtonFooterView.frame = CGRectMake(0, tableHeight, w, buttonBarH);
    _scanNowButton.frame = CGRectMake(kHeaderHorizontalInset, kScanButtonFooterPadding, w - kHeaderHorizontalInset * 2, scanButtonH);
    _activityView.center = CGPointMake(w / 2.0f, tableHeight / 2.0f);
    _statusLabel.frame = CGRectMake(kPadding, tableHeight / 2.0f - 30, w - kPadding * 2, 50);
}

static NSArray<NSString *> *THProfileAnalyzerMetricTitles(void) {
    return @[
        @"New followers",
        @"Lost followers",
        @"You followed",
        @"You unfollowed",
        @"Not following you back",
        @"You don't follow back",
        @"Mutual followers"
    ];
}

- (void)buildDashboardUI {
    CGFloat w = self.view.bounds.size.width;
    CGFloat headerH = 90 + 12 * 2; /* profile section + vertical insets for card */

    _statsHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, headerH)];
    _statsHeaderView.backgroundColor = [UIColor clearColor];

    _headerCardView = [[UIView alloc] initWithFrame:CGRectZero];
    _headerCardView.backgroundColor = [self pa_cardBackgroundColor];
    /* Match metrics table corner radius: iOS 26 uses table’s inset-grouped radius; older iOS keep 12. */
    if (@available(iOS 26.0, *)) {
        _headerCardView.layer.cornerRadius = 25;
    } else {
        _headerCardView.layer.cornerRadius = 12;
    }
    _headerCardView.clipsToBounds = YES;
    [_statsHeaderView addSubview:_headerCardView];

    _profileImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _profileImageView.contentMode = UIViewContentModeScaleAspectFill;
    _profileImageView.layer.cornerRadius = 32;
    _profileImageView.clipsToBounds = YES;
    _profileImageView.backgroundColor = [self pa_profileImagePlaceholderColor];
    [_headerCardView addSubview:_profileImageView];

    _usernameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _usernameLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _usernameLabel.textColor = [self pa_primaryTextColor];
    _usernameLabel.text = [THProfileAnalyzerViewController currentUserUsernameFromInstagram] ?: @"—";
    [_headerCardView addSubview:_usernameLabel];

    _followersFollowingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _followersFollowingLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    _followersFollowingLabel.textColor = [self pa_secondaryTextColor];
    _followersFollowingLabel.text = @"—  ·  —";
    _followersFollowingLabel.numberOfLines = 1;
    [_headerCardView addSubview:_followersFollowingLabel];

    _infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_infoButton setTitle:@"ⓘ" forState:UIControlStateNormal];
    _infoButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    [_infoButton setTitleColor:[ThetaHelper iotaPinkColor] forState:UIControlStateNormal];
    [_infoButton addTarget:self action:@selector(infoTapped) forControlEvents:UIControlEventTouchUpInside];
    [_headerCardView addSubview:_infoButton];

    _metricsTableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, w, self.view.bounds.size.height) style:UITableViewStyleInsetGrouped];
    _metricsTableView.dataSource = self;
    _metricsTableView.delegate = self;
    _metricsTableView.backgroundColor = [self pa_backgroundColor];
    _metricsTableView.tableHeaderView = _statsHeaderView;
    _metricsTableView.scrollIndicatorInsets = UIEdgeInsetsZero;
    _metricsTableView.tableFooterView = nil; /* Scan button is pinned to bottom of screen below table */
    [self.view addSubview:_metricsTableView];

    static const CGFloat kScanButtonFooterPadding = 20;
    CGFloat scanButtonH = 34;
    if (@available(iOS 26.0, *)) {
        scanButtonH = 50;
    }
    _scanButtonFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, scanButtonH + kScanButtonFooterPadding * 2)];
    _scanButtonFooterView.backgroundColor = [self pa_backgroundColor];
    _scanNowButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _scanNowButton.backgroundColor = [self pa_scanButtonBackgroundColor];
    [_scanNowButton setTitle:@"Scan now" forState:UIControlStateNormal];
    [_scanNowButton setTitleColor:[ThetaHelper iotaPinkColor] forState:UIControlStateNormal];
    _scanNowButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    if (@available(iOS 26.0, *)) {
        _scanNowButton.layer.cornerRadius = 25;
    } else {
        _scanNowButton.layer.cornerRadius = 8;
    }
    [_scanNowButton addTarget:self action:@selector(scanNowTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scanButtonFooterView addSubview:_scanNowButton];
    [self.view addSubview:_scanButtonFooterView];

    _activityView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _activityView.color = [ThetaHelper iotaPinkColor];
    _activityView.hidesWhenStopped = YES;
    [self.view addSubview:_activityView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, w - 40, 44)];
    _statusLabel.text = @"";
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.textColor = [self pa_tertiaryTextColor];
    _statusLabel.font = [UIFont systemFontOfSize:14];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];
}

#pragma mark - Metrics table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return THProfileAnalyzerMetricCount + 1; // metrics + scan history row
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 52;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"MetricCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.backgroundColor = [self pa_cardBackgroundColor];
    cell.textLabel.textColor = [self pa_primaryTextColor];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cell.tintColor = [self pa_accessoryTintColor];
    NSInteger row = indexPath.row;
    if (row >= THProfileAnalyzerMetricCount) {
        // Scan history row
        cell.textLabel.text = @"Scan history";
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        cell.detailTextLabel.text = _scanCount > 0 ? [NSString stringWithFormat:@"%td scans", _scanCount] : @"View past scans";
        cell.detailTextLabel.textColor = [self pa_scanHistoryDetailColor];
        return cell;
    }
    NSInteger tag = row;
    NSArray<NSString *> *titles = THProfileAnalyzerMetricTitles();
    cell.textLabel.text = tag < (NSInteger)titles.count ? titles[tag] : @"";
    NSInteger count = [self countForMetric:(THProfileAnalyzerMetric)tag];
    NSInteger prev = [self previousCountForMetric:(THProfileAnalyzerMetric)tag];
    /* Only show ↑/↓ delta when current count > 0, so we don't show "0 ↓1" after a no-change scan. */
    BOOL showDelta = (prev >= 0 && _previousDiff && count != prev && count > 0);
    if (showDelta) {
        NSInteger delta = count - prev;
        cell.detailTextLabel.text = delta > 0 ? [NSString stringWithFormat:@"%td  ↑%td", count, delta] : [NSString stringWithFormat:@"%td  ↓%td", count, -delta];
        cell.detailTextLabel.textColor = delta > 0
            ? [UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1.0]   /* green for gained */
            : [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];  /* red for lost */
    } else {
        cell.detailTextLabel.text = _result ? [NSString stringWithFormat:@"%td", count] : @"—";
        cell.detailTextLabel.textColor = [ThetaHelper iotaPinkColor]; /* accent same in both themes */
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;
    if (row == THProfileAnalyzerMetricCount) {
        [self openScanHistory];
        return;
    }
    NSInteger tag = row;
    if (tag < 0 || tag >= THProfileAnalyzerMetricCount || !_result.diff) return;
    [self openMetricListForTag:tag];
}

static NSString *THProfileAnalyzerProfileImageCachePath(NSString *userPK) {
    if (!userPK.length) return nil;
    return [[[THProfileAnalyzerStorage profileAnalyzerDirectory] stringByAppendingPathComponent:userPK] stringByAppendingPathComponent:@"profile.jpg"];
}

/* Download image from URL and write to cache path. Call from any queue; no UI updates. */
static void THProfileAnalyzerDownloadAndCacheProfileImage(NSString *urlString, NSString *userPK) {
    if (!urlString.length || !userPK.length) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSString *cachePath = THProfileAnalyzerProfileImageCachePath(userPK);
    if (!cachePath) return;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        (void)response;
        (void)error;
        if (!data.length) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        NSString *dir = [cachePath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [data writeToFile:cachePath atomically:YES];
    }];
    [task resume];
}

+ (void)prefetchProfileImageIfNeeded {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *pk = [self currentUserPKFromInstagram];
        if (!pk.length) return;
        NSString *cachePath = THProfileAnalyzerProfileImageCachePath(pk);
        if ([[NSFileManager defaultManager] fileExistsAtPath:cachePath]) return;

        NSString *urlString = [self currentUserProfilePicURLFromInstagram];
        if (urlString.length) {
            THProfileAnalyzerDownloadAndCacheProfileImage(urlString, pk);
            return;
        }

        /* Fallback: fetch users/{pk}/info/ and cache profile_pic_url. API must run on main (IG networker). */
        dispatch_async(dispatch_get_main_queue(), ^{
            THProfileAnalyzerAPIClient *client = [[THProfileAnalyzerAPIClient alloc] init];
            client.networkDelegate = [[THProfileAnalyzerNetworkDelegate alloc] init];
            NSString *path = [NSString stringWithFormat:@"users/%@/info/", pk];
            [client GETWithEndpointPath:path queryParams:nil success:^(NSDictionary * _Nullable json) {
                if (!json) return;
                NSDictionary *user = json[@"user"];
                if (![user isKindOfClass:[NSDictionary class]]) user = json[@"User"];
                if (![user isKindOfClass:[NSDictionary class]]) return;
                NSString *picURL = user[@"profile_pic_url"];
                if (![picURL isKindOfClass:[NSString class]] || !((NSString *)picURL).length)
                    picURL = user[@"profilePicURL"] ?: user[@"profilePicUrl"];
                if (![picURL isKindOfClass:[NSString class]] || !((NSString *)picURL).length) {
                    id hd = user[@"hd_profile_pic_url_info"];
                    if ([hd isKindOfClass:[NSDictionary class]]) picURL = ((NSDictionary *)hd)[@"url"];
                }
                if ([picURL isKindOfClass:[NSString class]] && ((NSString *)picURL).length)
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        THProfileAnalyzerDownloadAndCacheProfileImage((NSString *)picURL, pk);
                    });
            } failure:^(NSError * _Nonnull err) {
                (void)err;
            }];
        });
    });
}

- (void)setProfileImageWithURLString:(NSString *)urlString forUserPK:(NSString * _Nullable)userPK {
    if (!urlString.length) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    __weak typeof(self) wself = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!data.length) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        if (userPK.length) {
            NSString *cachePath = THProfileAnalyzerProfileImageCachePath(userPK);
            if (cachePath) {
                NSString *dir = [cachePath stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
                [data writeToFile:cachePath atomically:YES];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            wself.profileImageView.image = img;
        });
    }];
    [task resume];
}

- (void)loadCurrentUserProfileImage {
    if (_currentUserPK.length) {
        NSString *cachePath = THProfileAnalyzerProfileImageCachePath(_currentUserPK);
        if (cachePath.length) {
            UIImage *cached = [UIImage imageWithContentsOfFile:cachePath];
            if (cached) {
                _profileImageView.image = cached;
                return;
            }
        }
    }
    NSString *urlString = [THProfileAnalyzerViewController currentUserProfilePicURLFromInstagram];
    if (urlString.length) {
        [self setProfileImageWithURLString:urlString forUserPK:_currentUserPK];
        return;
    }
    /* Fallback: fetch current user info from API and use profile_pic_url from response */
    if (!_currentUserPK.length) return;
    THProfileAnalyzerAPIClient *client = [[THProfileAnalyzerAPIClient alloc] init];
    client.networkDelegate = [[THProfileAnalyzerNetworkDelegate alloc] init];
    NSString *path = [NSString stringWithFormat:@"users/%@/info/", _currentUserPK];
    __weak typeof(self) wself = self;
    [client GETWithEndpointPath:path queryParams:nil success:^(NSDictionary * _Nullable json) {
        if (!json) return;
        NSDictionary *user = json[@"user"];
        if (![user isKindOfClass:[NSDictionary class]]) user = json[@"User"];
        if (![user isKindOfClass:[NSDictionary class]]) return;
        NSString *picURL = user[@"profile_pic_url"];
        if (![picURL isKindOfClass:[NSString class]] || !((NSString *)picURL).length)
            picURL = user[@"profilePicURL"] ?: user[@"profilePicUrl"];
        if (![picURL isKindOfClass:[NSString class]] || !((NSString *)picURL).length) {
            id hd = user[@"hd_profile_pic_url_info"];
            if ([hd isKindOfClass:[NSDictionary class]]) picURL = ((NSDictionary *)hd)[@"url"];
        }
        if ([picURL isKindOfClass:[NSString class]] && ((NSString *)picURL).length)
            [wself setProfileImageWithURLString:(NSString *)picURL forUserPK:wself.currentUserPK];
    } failure:^(NSError * _Nonnull error) {
        (void)error;
    }];
}

/* Parse follower/following counts from Instagram user dict (API or in-memory). Handles multiple key variants. */
static void THProfileAnalyzerParseCountsFromUser(NSDictionary *user, NSInteger *outFollowers, NSInteger *outFollowing) {
    *outFollowers = -1;
    *outFollowing = -1;
    if (![user isKindOfClass:[NSDictionary class]]) return;
    id fc = user[@"follower_count"] ?: user[@"followerCount"] ?: user[@"followers_count"];
    id fg = user[@"following_count"] ?: user[@"followingCount"] ?: user[@"following_count"];
    NSDictionary *counts = user[@"counts"];
    if (![fc isKindOfClass:[NSNumber class]] && [counts isKindOfClass:[NSDictionary class]]) {
        fc = counts[@"followed_by"] ?: counts[@"followedBy"] ?: counts[@"follower_count"];
        fg = counts[@"follows"] ?: counts[@"following_count"];
    }
    if ([fc isKindOfClass:[NSNumber class]]) *outFollowers = [(NSNumber *)fc integerValue];
    else if ([fc isKindOfClass:[NSString class]]) *outFollowers = [(NSString *)fc integerValue];
    if ([fg isKindOfClass:[NSNumber class]]) *outFollowing = [(NSNumber *)fg integerValue];
    else if ([fg isKindOfClass:[NSString class]]) *outFollowing = [(NSString *)fg integerValue];
}

- (void)updateFollowersFollowingLabelFromAPI {
    if (_apiFollowersCount >= 0 && _apiFollowingCount >= 0)
        _followersFollowingLabel.text = [NSString stringWithFormat:@"%td followers  ·  %td following", _apiFollowersCount, _apiFollowingCount];
    else
        _followersFollowingLabel.text = @"—  ·  —";
}

- (void)loadSavedAPICounts {
    if (!_currentUserPK.length) return;
    NSString *keyBase = [kTHProfileAnalyzerAPICountsPrefix stringByAppendingString:_currentUserPK];
    NSString *followersKey = [keyBase stringByAppendingString:@"_followers"];
    NSString *followingKey = [keyBase stringByAppendingString:@"_following"];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:followersKey] == nil || [d objectForKey:followingKey] == nil) return;
    NSInteger fc = (NSInteger)[d integerForKey:followersKey];
    NSInteger fg = (NSInteger)[d integerForKey:followingKey];
    if (fc >= 0 && fg >= 0) {
        _apiFollowersCount = fc;
        _apiFollowingCount = fg;
    }
}

- (void)saveAPICounts {
    if (!_currentUserPK.length || _apiFollowersCount < 0 || _apiFollowingCount < 0) return;
    NSString *keyBase = [kTHProfileAnalyzerAPICountsPrefix stringByAppendingString:_currentUserPK];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:_apiFollowersCount forKey:[keyBase stringByAppendingString:@"_followers"]];
    [d setInteger:_apiFollowingCount forKey:[keyBase stringByAppendingString:@"_following"]];
    [d synchronize];
}

- (void)scanNowTapped {
    [self runScan];
}

- (void)infoTapped {
    /*UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Profile Analyzer" message:@"Scan your profile to see new followers, unfollowers, who you follow, who doesn't follow back, and more. Tap \"Scan now\" to run a scan, then tap a metric to see the list." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];*/

    [ThetaHelper showCustomAlertWithActions:@"Profile Analyzer" description:@"Scan your profile to see new followers, unfollowers, who you follow, who doesn't follow back, and more. Tap \"Scan now\" to run a scan, then tap a metric to see the list." actions:@[
        @{
            @"title": @"OK",
            @"handler": ^(id sender) {
            }
        }
    ]];
}

- (void)runScan {
    if (self.profileAnalyzerScanner.isRunning) return;
    _scanNowButton.enabled = NO;
    [self.activityView startAnimating];
    _statusLabel.hidden = NO;
    _statusLabel.text = @"Starting scan…";

    THProfileAnalyzerAPIClient *client = [[THProfileAnalyzerAPIClient alloc] init];
    self.networkDelegate = [[THProfileAnalyzerNetworkDelegate alloc] init];
    client.networkDelegate = self.networkDelegate;
    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    THProfileAnalyzerSnapshot *previous = [storage loadMostRecentSnapshotForUserPK:_currentUserPK error:NULL];
    THProfileAnalyzerService *scanner = [[THProfileAnalyzerService alloc] initWithAPIClient:client userPK:_currentUserPK];
    self.profileAnalyzerScanner = scanner;

    __weak typeof(self) wself = self;
    [scanner runForSelfWithHeaderInfo:^(NSDictionary *userInfo) {
        if (![userInfo isKindOfClass:[NSDictionary class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *uname = userInfo[@"username"];
            if ([uname isKindOfClass:[NSString class]] && ((NSString *)uname).length)
                wself.usernameLabel.text = uname;
            NSInteger fc = -1, fg = -1;
            THProfileAnalyzerParseCountsFromUser(userInfo, &fc, &fg);
            if (fc >= 0 && fg >= 0) {
                wself.apiFollowersCount = fc;
                wself.apiFollowingCount = fg;
                [wself saveAPICounts];
                [wself updateFollowersFollowingLabelFromAPI];
            }
        });
    } progress:^(NSString *status, double fraction) {
        (void)fraction;
        dispatch_async(dispatch_get_main_queue(), ^{
            wself.statusLabel.text = status ?: @"";
        });
    } completion:^(THProfileAnalyzerSnapshot * _Nullable snapshot, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            wself.profileAnalyzerScanner = nil;
            wself.scanNowButton.enabled = YES;
            [wself.activityView stopAnimating];
            if (error) {
                wself.statusLabel.text = [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Profile Analyzer" subtitle:error.localizedDescription icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:nil];
                }
                return;
            }
            if (!snapshot) {
                wself.statusLabel.text = @"No data returned.";
                return;
            }
            NSInteger total = snapshot.followers.count + snapshot.following.count;
            if (kTHProfileAnalyzerMaxTotal > 0 && total > kTHProfileAnalyzerMaxTotal) {
                wself.statusLabel.text = [NSString stringWithFormat:@"Followers + following (%td) exceeds %td. Instagram limits.", total, (NSInteger)kTHProfileAnalyzerMaxTotal];
                return;
            }
            wself.statusLabel.text = @"Comparing…";
            NSMutableDictionary *usersByPK = [[THProfileAnalyzerDiffEngine usersByPKFromSnapshot:snapshot] mutableCopy];
            if (previous) {
                for (THProfileAnalyzerUser *u in previous.followers) if (u.pk.length && !usersByPK[u.pk]) usersByPK[u.pk] = u;
                for (THProfileAnalyzerUser *u in previous.following) if (u.pk.length && !usersByPK[u.pk]) usersByPK[u.pk] = u;
            }
            THProfileAnalyzerDiffResult *diff = [THProfileAnalyzerDiffEngine diffBetweenPreviousSnapshot:previous currentSnapshot:snapshot usersByPK:usersByPK];
            [storage saveSnapshot:snapshot error:NULL];
            THProfileAnalyzerResult *result = [[THProfileAnalyzerResult alloc] init];
            result.currentSnapshot = snapshot;
            result.previousSnapshot = previous;
            result.diff = diff;
            result.followersCount = snapshot.followers.count;
            result.followingCount = snapshot.following.count;
            wself.result = result;
            wself.previousDiff = nil;
            [wself loadPreviousDiffFromStorage];
            NSInteger newCount = 1;
            for (NSInteger idx = 1; ; idx++) {
                if (![storage loadSnapshotAtIndex:idx forUserPK:wself.currentUserPK error:NULL]) break;
                newCount++;
            }
            wself.scanCount = newCount;
            [wself refreshDashboard];
            wself.statusLabel.hidden = YES;
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Scan complete" subtitle:[NSString stringWithFormat:@"%td followers, %td following", result.followersCount, result.followingCount] icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:nil];
            }
        });
    }];
}

- (void)loadPreviousDiffFromStorage {
    if (!_result.previousSnapshot || !_currentUserPK.length) return;
    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    THProfileAnalyzerSnapshot *prevPrev = [storage loadSnapshotAtIndex:2 forUserPK:_currentUserPK error:NULL];
    if (!prevPrev) return;
    NSMutableDictionary *usersByPK = [[THProfileAnalyzerDiffEngine usersByPKFromSnapshot:_result.previousSnapshot] mutableCopy];
    for (THProfileAnalyzerUser *u in prevPrev.followers) if (u.pk.length && !usersByPK[u.pk]) usersByPK[u.pk] = u;
    for (THProfileAnalyzerUser *u in prevPrev.following) if (u.pk.length && !usersByPK[u.pk]) usersByPK[u.pk] = u;
    self.previousDiff = [THProfileAnalyzerDiffEngine diffBetweenPreviousSnapshot:prevPrev currentSnapshot:_result.previousSnapshot usersByPK:usersByPK];
}

- (void)loadLastResultAndRefresh {
    if (!_currentUserPK.length) return;
    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    THProfileAnalyzerSnapshot *current = [storage loadSnapshotAtIndex:0 forUserPK:_currentUserPK error:NULL];
    THProfileAnalyzerSnapshot *previous = [storage loadSnapshotAtIndex:1 forUserPK:_currentUserPK error:NULL];
    if (!current) {
        self.scanCount = 0;
        [self refreshDashboard];
        return;
    }
    NSInteger scanCount = 1;
    for (NSInteger idx = 1; ; idx++) {
        if (![storage loadSnapshotAtIndex:idx forUserPK:_currentUserPK error:NULL]) break;
        scanCount++;
    }
    self.scanCount = scanCount;

    NSMutableDictionary *usersByPK = [[THProfileAnalyzerDiffEngine usersByPKFromSnapshot:current] mutableCopy];
    if (previous) {
        for (THProfileAnalyzerUser *u in previous.followers) if (u.pk.length && !usersByPK[u.pk]) usersByPK[u.pk] = u;
        for (THProfileAnalyzerUser *u in previous.following) if (u.pk.length && !usersByPK[u.pk]) usersByPK[u.pk] = u;
    }
    THProfileAnalyzerDiffResult *diff = [THProfileAnalyzerDiffEngine diffBetweenPreviousSnapshot:previous currentSnapshot:current usersByPK:usersByPK];
    THProfileAnalyzerResult *result = [[THProfileAnalyzerResult alloc] init];
    result.currentSnapshot = current;
    result.previousSnapshot = previous;
    result.diff = diff;
    result.followersCount = current.followers.count;
    result.followingCount = current.following.count;
    self.result = result;
    self.previousDiff = nil;
    if (previous) {
        THProfileAnalyzerSnapshot *prevPrev = [storage loadSnapshotAtIndex:2 forUserPK:_currentUserPK error:NULL];
        if (prevPrev) {
            NSMutableDictionary *prevUsers = [[THProfileAnalyzerDiffEngine usersByPKFromSnapshot:previous] mutableCopy];
            for (THProfileAnalyzerUser *u in prevPrev.followers) if (u.pk.length && !prevUsers[u.pk]) prevUsers[u.pk] = u;
            for (THProfileAnalyzerUser *u in prevPrev.following) if (u.pk.length && !prevUsers[u.pk]) prevUsers[u.pk] = u;
            self.previousDiff = [THProfileAnalyzerDiffEngine diffBetweenPreviousSnapshot:prevPrev currentSnapshot:previous usersByPK:prevUsers];
        }
    }
    [self refreshDashboard];
}

- (NSInteger)countForMetric:(THProfileAnalyzerMetric)metric {
    if (!_result.diff) return 0;
    THProfileAnalyzerDiffResult *d = _result.diff;
    switch (metric) {
        case THProfileAnalyzerMetricNewFollowers: return d.followersGained.count;
        case THProfileAnalyzerMetricLostFollowers: return d.followersLost.count;
        case THProfileAnalyzerMetricYouFollowed: return d.followingAdded.count;
        case THProfileAnalyzerMetricYouUnfollowed: return d.followingRemoved.count;
        case THProfileAnalyzerMetricNotFollowingYouBack: return d.notFollowingMeBack.count;
        case THProfileAnalyzerMetricYouDontFollowBack: return d.youDontFollowBack.count;
        case THProfileAnalyzerMetricMutualFollowers: return d.mutualFollowers.count;
        default: return 0;
    }
}

- (NSInteger)previousCountForMetric:(THProfileAnalyzerMetric)metric {
    if (!_previousDiff) return 0;
    THProfileAnalyzerDiffResult *d = _previousDiff;
    switch (metric) {
        case THProfileAnalyzerMetricNewFollowers: return d.followersGained.count;
        case THProfileAnalyzerMetricLostFollowers: return d.followersLost.count;
        case THProfileAnalyzerMetricYouFollowed: return d.followingAdded.count;
        case THProfileAnalyzerMetricYouUnfollowed: return d.followingRemoved.count;
        case THProfileAnalyzerMetricNotFollowingYouBack: return d.notFollowingMeBack.count;
        case THProfileAnalyzerMetricYouDontFollowBack: return d.youDontFollowBack.count;
        case THProfileAnalyzerMetricMutualFollowers: return d.mutualFollowers.count;
        default: return 0;
    }
}

- (void)refreshDashboard {
    [self updateFollowersFollowingLabelFromAPI];
    [_metricsTableView reloadData];
}

- (void)openScanHistory {
    if (!_currentUserPK.length) return;
    THProfileAnalyzerStorage *storage = [[THProfileAnalyzerStorage alloc] init];
    THProfileAnalyzerSnapshot *any = [storage loadSnapshotAtIndex:0 forUserPK:_currentUserPK error:NULL];
    if (!any) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Scan history" message:@"No scans yet. Run a scan first." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    THProfileAnalyzerScanHistoryViewController *vc = [[THProfileAnalyzerScanHistoryViewController alloc] initWithCurrentUserPK:_currentUserPK currentSnapshot:_result.currentSnapshot];
    __weak typeof(self) wParent = self;
    vc.onScanHistoryDidMutateStorage = ^{
        typeof(self) s = wParent;
        if (!s) return;
        [s loadLastResultAndRefresh];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openMetricListForTag:(NSInteger)tag {
    if (tag < 0 || tag >= THProfileAnalyzerMetricCount || !_result.diff) return;
    NSArray<THProfileAnalyzerUser *> *users = nil;
    NSString *listTitle = nil;
    THProfileAnalyzerDiffResult *d = _result.diff;
    switch ((THProfileAnalyzerMetric)tag) {
        case THProfileAnalyzerMetricNewFollowers: users = d.followersGained; listTitle = @"New followers"; break;
        case THProfileAnalyzerMetricLostFollowers: users = d.followersLost; listTitle = @"Lost followers"; break;
        case THProfileAnalyzerMetricYouFollowed: users = d.followingAdded; listTitle = @"You followed"; break;
        case THProfileAnalyzerMetricYouUnfollowed: users = d.followingRemoved; listTitle = @"You unfollowed"; break;
        case THProfileAnalyzerMetricNotFollowingYouBack: users = d.notFollowingMeBack; listTitle = @"Not following you back"; break;
        case THProfileAnalyzerMetricYouDontFollowBack: users = d.youDontFollowBack; listTitle = @"You don't follow back"; break;
        case THProfileAnalyzerMetricMutualFollowers: users = d.mutualFollowers; listTitle = @"Mutual followers"; break;
        default: break;
    }
    if (!users.count) return;
    NSMutableSet<NSString *> *pinned = THProfileAnalyzerMutableSetForKey(kTHProfileAnalyzerPinnedPKsKey);
    NSMutableSet<NSString *> *ignored = THProfileAnalyzerMutableSetForKey(kTHProfileAnalyzerIgnoredPKsKey);
    BOOL shouldFilterIgnored = ((THProfileAnalyzerMetric)tag == THProfileAnalyzerMetricNotFollowingYouBack ||
                                (THProfileAnalyzerMetric)tag == THProfileAnalyzerMetricYouDontFollowBack);
    NSMutableArray<THProfileAnalyzerUser *> *filtered = [NSMutableArray array];
    for (THProfileAnalyzerUser *u in users) {
        if (shouldFilterIgnored && u.pk.length && [ignored containsObject:u.pk]) continue;
        [filtered addObject:u];
    }
    NSArray<THProfileAnalyzerUser *> *finalUsers = filtered;
    if (!finalUsers.count) return;
    NSArray<THProfileAnalyzerUser *> *sorted = [finalUsers sortedArrayUsingComparator:^NSComparisonResult(THProfileAnalyzerUser *a, THProfileAnalyzerUser *b) {
        BOOL aPinned = a.pk.length && [pinned containsObject:a.pk];
        BOOL bPinned = b.pk.length && [pinned containsObject:b.pk];
        if (aPinned != bPinned) return aPinned ? NSOrderedAscending : NSOrderedDescending;
        NSString *nameA = a.username.length ? a.username : a.pk;
        NSString *nameB = b.username.length ? b.username : b.pk;
        return [nameA caseInsensitiveCompare:nameB];
    }];
    THProfileAnalyzerListViewController *listVC = [[THProfileAnalyzerListViewController alloc] initWithTitle:listTitle users:sorted ?: @[]];
    listVC.currentUserPK = _currentUserPK;
    [self.navigationController pushViewController:listVC animated:YES];
}

@end
