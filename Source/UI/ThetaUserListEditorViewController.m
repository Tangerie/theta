#import "Include/ThetaUserListEditorViewController.h"
#import "Include/ThetaHelper.h"

static NSString *const kCellId = @"UserCell";

@implementation ThetaUserListEditorViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if (self = [super initWithStyle:UITableViewStyleInsetGrouped]) {
        _listKey = nil;
        _listTitle = @"List";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.listTitle.length > 0 ? self.listTitle : @"List";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                              target:self
                                                                              action:@selector(addUsername)];
    addItem.tintColor = [ThetaHelper iotaPinkColor];
    self.navigationItem.rightBarButtonItem = addItem;

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellId];
}

- (NSMutableArray<NSString *> *)currentList {
    if (!self.listKey.length) return [NSMutableArray array];
    NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:self.listKey];
    if (![stored isKindOfClass:[NSArray class]]) return [NSMutableArray array];
    NSMutableArray *arr = [NSMutableArray array];
    for (id obj in stored) {
        if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
            [arr addObject:[(NSString *)obj lowercaseString]];
        }
    }
    return arr;
}

- (void)saveList:(NSArray<NSString *> *)list {
    if (!self.listKey.length) return;
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:self.listKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)addUsername {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add username"
                                                                   message:@"Enter Instagram username (without @)."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"username";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *input = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (input.length == 0) return;
        NSString *username = [input lowercaseString];
        if ([username hasPrefix:@"@"]) {
            username = [username substringFromIndex:1];
        }
        NSMutableArray *list = [weakSelf currentList];
        if ([list containsObject:username]) return;
        [list addObject:username];
        [weakSelf saveList:list];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentList].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellId forIndexPath:indexPath];
    NSArray *list = [self currentList];
    if (indexPath.row < (NSInteger)list.count) {
        cell.textLabel.text = [NSString stringWithFormat:@"@%@", list[indexPath.row]];
    }
    cell.textLabel.textColor = [UIColor labelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *list = [self currentList];
    if (indexPath.row >= (NSInteger)list.count) return;
    [list removeObjectAtIndex:indexPath.row];
    [self saveList:list];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self.listKey isEqualToString:@"Theta_MarkAsSeen_AutoMarkUserIds"]) {
        return @"Users in this list will be auto-marked as seen in DMs.\n\nTo add someone, tap + and enter their username, or use the list toggle button next to the eye icon in a DM thread (Mark As Seen setting must be enabled).\n\nIf the button above doesn't work, you may need a kickstart to this by manually adding the user to this list. Then when you send/receive a message from them, the button should work.";
    }
    if ([self.listKey isEqualToString:@"Theta_StoryGhost_AutoMarkUserIds"]) {
        return @"Users in this list will be auto-marked as seen in Story Ghost when you view their stories (unless you enable Skip On Seen).\n\nTo add someone, tap + and enter their username, or long-press the Story Ghost seen button on their story (Story Ghost setting must be enabled).";
    }
    return nil;
}

@end
