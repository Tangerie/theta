#import "Include/AudioNotesViewController.h"
#import "Include/CustomToastView.h"
#import "Include/InstagramHeaders.h"
#import "Include/ThetaHelper.h"
#import "Include/MediaViewController.h"
#import <AVFoundation/AVFoundation.h>



@interface AudioFileItem : NSObject
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) NSDate *modificationDate;
@property (nonatomic, assign) unsigned long long fileSize;
@end

@implementation AudioFileItem
@end

@interface AudioNotesViewController () <AVAudioPlayerDelegate>
@property (nonatomic, assign) AudioNotesContentMode contentMode;
@property (nonatomic, strong) NSArray<AudioFileItem *> *audioFiles;
@property (nonatomic, strong) NSArray<NSString *> *userNames;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<AudioFileItem *> *> *audioFilesByUser;
@property (nonatomic, strong) NSString *audioNotesDirectory;
@property (nonatomic, strong) NSString *savedMediaDirectory;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSString *currentlyPlayingFile;
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
- (void)loadContent;

// Inline audio player UI
@property (nonatomic, strong) UIView *playerView;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UILabel *trackTitleLabel;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign) BOOL isScrubbing;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, strong) UIView *playerCardView;
@end

// Forward declare category methods so call sites compile without adding to the primary class contract
@interface AudioNotesViewController (PlayerUI)
- (void)showPlayerForAudioFile:(AudioFileItem *)audioFile;
- (void)hidePlayerUI;
- (void)buildPlayerUI;
- (void)startProgressTimer;
- (void)invalidateProgressTimer;
- (void)startAutoHideTimer;
- (void)cancelAutoHideTimer;
- (void)onAutoHideTimerFired;
- (void)onProgressTick;
- (void)onPlayPauseTapped;
- (void)onSliderTouchDown;
- (void)onSliderValueChanged:(UISlider *)slider;
- (void)onSliderTouchUp:(UISlider *)slider;
- (NSString *)formattedTimeString:(NSTimeInterval)time;
- (AudioFileItem *)findAudioItemByFilename:(NSString *)filename;
- (BOOL)isAtEndOfTrack;
@end



@implementation AudioNotesViewController

- (instancetype)initWithMode:(AudioNotesContentMode)mode {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _contentMode = mode;
    }
    return self;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    AudioNotesContentMode newMode = (sender.selectedSegmentIndex == 0) ? AudioNotesContentModeSavedMedia : AudioNotesContentModeAudioNotes;
    if (newMode != self.contentMode) {
        self.contentMode = newMode;
        self.title = self.contentMode == AudioNotesContentModeSavedMedia ? @"Saved Media" : @"Audio Notes";
        [self loadContent];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = self.contentMode == AudioNotesContentModeSavedMedia ? @"Saved Media" : @"Audio Notes";
    
    // Setup navigation bar
    	self.navigationController.navigationBar.tintColor = [ThetaHelper iotaPinkColor];
    
    // Setup table view
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    
    // Add segmented control under the navigation bar
    NSArray *segments = @[ @"Saved Media", @"Audio Notes" ];
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:segments];
    self.segmentedControl.selectedSegmentIndex = (self.contentMode == AudioNotesContentModeSavedMedia) ? 0 : 1;
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.segmentedControl.apportionsSegmentWidthsByContent = YES;
    if (@available(iOS 13.0, *)) {
        self.segmentedControl.selectedSegmentTintColor = [ThetaHelper iotaPinkColor];
        NSDictionary *attrs = @{ NSForegroundColorAttributeName: UIColor.whiteColor };
        [self.segmentedControl setTitleTextAttributes:attrs forState:UIControlStateSelected];
    }
    CGFloat headerHeight = 48.0;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, headerHeight)];
    header.backgroundColor = [UIColor clearColor];
    CGSize segSize = [self.segmentedControl sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat controlHeight = MAX(segSize.height, 30.0);
    CGFloat controlWidth = segSize.width;
    CGFloat controlX = (self.view.bounds.size.width - controlWidth) / 2.0;
    self.segmentedControl.frame = CGRectMake(controlX, (headerHeight - controlHeight) / 2.0, controlWidth, controlHeight);
    self.segmentedControl.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [header addSubview:self.segmentedControl];
    self.tableView.tableHeaderView = header;
    
    // Add refresh control
    self.refreshControl = [[UIRefreshControl alloc] init];
    	self.refreshControl.tintColor = [ThetaHelper iotaPinkColor];
    [self.refreshControl addTarget:self action:@selector(refreshAudioFiles) forControlEvents:UIControlEventValueChanged];
    
    // Load initial content
    [self loadContent];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Refresh the list when returning to this view (in case files were deleted)
    [self loadContent];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Stop any playing audio when leaving this view
    [self stopAudioPlayback];
}

-(void)loadContent {
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    self.audioNotesDirectory = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
    self.savedMediaDirectory = documentsPath;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;

    NSArray *audioExtensions = @[@"mp3", @"aac", @"m4a", @"wav"];
    NSArray *mediaExtensions = @[@"mp4", @"mov", @"m4v", @"png", @"jpg", @"jpeg", @"heic"];

    NSMutableDictionary *userFilesDict = [NSMutableDictionary dictionary];
    NSMutableArray *allFiles = [NSMutableArray array];

    if (self.contentMode == AudioNotesContentModeAudioNotes) {
        BOOL isDir = NO;
        BOOL exists = [fileManager fileExistsAtPath:self.audioNotesDirectory isDirectory:&isDir];
        if (!exists || !isDir) {
            self.audioFiles = @[];
            self.userNames = @[];
            self.audioFilesByUser = @{};
            [self.tableView reloadData];
            return;
        }

        NSArray *userFolderNames = [fileManager contentsOfDirectoryAtPath:self.audioNotesDirectory error:&error];
        if (error) {
            NSLog(@"Error reading AudioNotes directory: %@", error.localizedDescription);
            self.audioFiles = @[];
            self.userNames = @[];
            self.audioFilesByUser = @{};
            [self.tableView reloadData];
            return;
        }

        for (NSString *userFolderName in userFolderNames) {
            NSString *userFolderPath = [self.audioNotesDirectory stringByAppendingPathComponent:userFolderName];
            BOOL isUserDir = NO;
            if ([fileManager fileExistsAtPath:userFolderPath isDirectory:&isUserDir] && isUserDir) {
                NSArray *fileNames = [fileManager contentsOfDirectoryAtPath:userFolderPath error:&error];
                if (error) { NSLog(@"Error reading user folder %@: %@", userFolderName, error.localizedDescription); continue; }
                NSMutableArray *userItems = [NSMutableArray array];
                for (NSString *filename in fileNames) {
                    NSString *ext = [[filename pathExtension] lowercaseString];
                    if (![audioExtensions containsObject:ext]) continue;
                    NSString *filePath = [userFolderPath stringByAppendingPathComponent:filename];
                    NSDictionary *attrs = [fileManager attributesOfItemAtPath:filePath error:nil];
                    if (!attrs) continue;
                    AudioFileItem *item = [AudioFileItem new];
                    item.filename = filename;
                    item.filePath = filePath;
                    item.modificationDate = attrs[NSFileModificationDate];
                    item.fileSize = [attrs[NSFileSize] unsignedLongLongValue];
                    [userItems addObject:item];
                    [allFiles addObject:item];
                }
                if (userItems.count > 0) {
                    NSArray *sorted = [userItems sortedArrayUsingComparator:^NSComparisonResult(AudioFileItem *a, AudioFileItem *b) { return [b.modificationDate compare:a.modificationDate]; }];
                    userFilesDict[userFolderName] = sorted;
                }
            }
        }

        // Also include audio files placed directly in AudioNotes (no user subfolder)
        NSError *rootError = nil;
        NSArray *rootEntries = [fileManager contentsOfDirectoryAtPath:self.audioNotesDirectory error:&rootError];
        if (rootError) {
            NSLog(@"Error reading AudioNotes root: %@", rootError.localizedDescription);
        } else {
            NSMutableArray *rootItems = [NSMutableArray array];
            for (NSString *entry in rootEntries) {
                NSString *entryPath = [self.audioNotesDirectory stringByAppendingPathComponent:entry];
                BOOL isDir = NO;
                if (![fileManager fileExistsAtPath:entryPath isDirectory:&isDir] || isDir) continue;
                NSString *ext = [[entry pathExtension] lowercaseString];
                if (![audioExtensions containsObject:ext]) continue;
                NSDictionary *attrs = [fileManager attributesOfItemAtPath:entryPath error:nil];
                if (!attrs) continue;
                AudioFileItem *item = [AudioFileItem new];
                item.filename = entry;
                item.filePath = entryPath;
                item.modificationDate = attrs[NSFileModificationDate];
                item.fileSize = [attrs[NSFileSize] unsignedLongLongValue];
                [rootItems addObject:item];
                [allFiles addObject:item];
            }
            if (rootItems.count > 0) {
                NSArray *sorted = [rootItems sortedArrayUsingComparator:^NSComparisonResult(AudioFileItem *a, AudioFileItem *b) { return [b.modificationDate compare:a.modificationDate]; }];
                userFilesDict[@"Audio Notes"] = sorted;
            }
        }
    } else {
        // Saved media (flat in Documents) + include videos from Documents/AudioNotes
        NSArray *fileNames = [fileManager contentsOfDirectoryAtPath:self.savedMediaDirectory error:&error];
        if (error) { NSLog(@"Error reading Documents: %@", error.localizedDescription); fileNames = @[]; }
        NSMutableArray *mediaItems = [NSMutableArray array];
        NSMutableSet *addedPaths = [NSMutableSet set];
        
        // Add media in Documents (images + videos)
        for (NSString *filename in fileNames) {
            NSString *ext = [[filename pathExtension] lowercaseString];
            if (![mediaExtensions containsObject:ext]) continue;
            NSString *filePath = [self.savedMediaDirectory stringByAppendingPathComponent:filename];
            NSDictionary *attrs = [fileManager attributesOfItemAtPath:filePath error:nil];
            if (!attrs) continue;
            AudioFileItem *item = [AudioFileItem new];
            item.filename = filename;
            item.filePath = filePath;
            item.modificationDate = attrs[NSFileModificationDate];
            item.fileSize = [attrs[NSFileSize] unsignedLongLongValue];
            [mediaItems addObject:item];
            [allFiles addObject:item];
            [addedPaths addObject:filePath];
        }
        
        // Also include media files in Documents/AudioNotes (images + videos)
        BOOL isDir = NO;
        if ([fileManager fileExistsAtPath:self.audioNotesDirectory isDirectory:&isDir] && isDir) {
            NSError *notesError = nil;
            NSArray *notesFiles = [fileManager contentsOfDirectoryAtPath:self.audioNotesDirectory error:&notesError];
            if (notesError) {
                NSLog(@"Error reading AudioNotes folder for media: %@", notesError.localizedDescription);
            } else {
                for (NSString *filename in notesFiles) {
                    NSString *ext = [[filename pathExtension] lowercaseString];
                    if (![mediaExtensions containsObject:ext]) continue;
                    NSString *filePath = [self.audioNotesDirectory stringByAppendingPathComponent:filename];
                    if ([addedPaths containsObject:filePath]) continue;
                    NSDictionary *attrs = [fileManager attributesOfItemAtPath:filePath error:nil];
                    if (!attrs) continue;
                    AudioFileItem *item = [AudioFileItem new];
                    item.filename = filename;
                    item.filePath = filePath;
                    item.modificationDate = attrs[NSFileModificationDate];
                    item.fileSize = [attrs[NSFileSize] unsignedLongLongValue];
                    [mediaItems addObject:item];
                    [allFiles addObject:item];
                    [addedPaths addObject:filePath];
                }
            }
        }
        
        if (mediaItems.count > 0) {
            NSArray *sorted = [mediaItems sortedArrayUsingComparator:^NSComparisonResult(AudioFileItem *a, AudioFileItem *b) { return [b.modificationDate compare:a.modificationDate]; }];
            userFilesDict[@"Media"] = sorted;
        }
    }

    NSArray *sortedUserNames = [userFilesDict.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *u1, NSString *u2) {
        AudioFileItem *a = [userFilesDict[u1] firstObject];
        AudioFileItem *b = [userFilesDict[u2] firstObject];
        return [b.modificationDate compare:a.modificationDate];
    }];

    self.audioFiles = [allFiles copy];
    self.userNames = sortedUserNames;
    self.audioFilesByUser = [userFilesDict copy];

    if (self.userNames.count == 0) {
        self.audioFiles = @[];
    }

    [self.tableView reloadData];
}

- (void)refreshAudioFiles {
    [self loadContent];
    [self.refreshControl endRefreshing];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.userNames.count > 0) {
        return self.userNames.count + 1; // User sections + Actions section
    } else {
        return 1; // Just Actions section
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.userNames.count == 0) {
        return 1; // Empty state
    } else if (section < self.userNames.count) {
        NSString *userName = self.userNames[section];
        NSArray *userFiles = self.audioFilesByUser[userName];
        return userFiles.count;
    } else {
        return 1; // Actions section
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < self.userNames.count) {
        NSString *userName = self.userNames[section];
        NSArray *userFiles = self.audioFilesByUser[userName];
        return [NSString stringWithFormat:@"%@ (%lu)", userName, (unsigned long)userFiles.count];
    } else {
        return @"Actions";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"AudioFileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
    }
    
    if (self.userNames.count == 0) {
        // Empty state cell
        if (self.contentMode == AudioNotesContentModeAudioNotes) {
            cell.textLabel.text = @"No Audio Notes Found";
            cell.detailTextLabel.text = @"Go download some audio notes!";
            cell.imageView.image = [UIImage systemImageNamed:@"music.note.list"];
        } else if (self.contentMode == AudioNotesContentModeSavedMedia) {
            cell.textLabel.text = @"No Saved Media Found";
            cell.detailTextLabel.text = @"Go download some media!";
            cell.imageView.image = [UIImage systemImageNamed:@"photo"];
        }
        cell.textLabel.textColor = [UIColor labelColor];
        cell.imageView.tintColor = [UIColor systemGrayColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section < self.userNames.count) {
        // Audio file cell
        NSString *userName = self.userNames[indexPath.section];
        NSArray *userFiles = self.audioFilesByUser[userName];
        AudioFileItem *audioFile = userFiles[indexPath.row];
            
            // Display filename without extension
            NSString *displayName = [audioFile.filename stringByDeletingPathExtension];
            cell.textLabel.text = displayName;
            cell.textLabel.textColor = [UIColor labelColor]; // Reset to default color
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            
            // Format file info
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"MMM dd, yyyy 'at' hh:mm"];
            NSString *dateString = [formatter stringFromDate:audioFile.modificationDate];
            
            NSString *sizeString;
            if (audioFile.fileSize < 1024) {
                sizeString = [NSString stringWithFormat:@"%llu B", audioFile.fileSize];
            } else if (audioFile.fileSize < 1024 * 1024) {
                sizeString = [NSString stringWithFormat:@"%.1f KB", audioFile.fileSize / 1024.0];
            } else {
                sizeString = [NSString stringWithFormat:@"%.1f MB", audioFile.fileSize / (1024.0 * 1024.0)];
            }
            
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", dateString, sizeString];
            cell.imageView.image = [UIImage systemImageNamed:@"music.note"];
            	cell.imageView.tintColor = [ThetaHelper iotaPinkColor];
    } else {
        // Delete all button
        cell.textLabel.text = self.contentMode == AudioNotesContentModeSavedMedia ? @"Delete All Saved Media" : @"Delete All Audio Notes";
        if (self.contentMode == AudioNotesContentModeSavedMedia) {
            cell.detailTextLabel.text = self.audioFiles.count == 1 ? @"Remove 1 item" : [NSString stringWithFormat:@"Remove all %lu items", (unsigned long)self.audioFiles.count];
        } else {
            cell.detailTextLabel.text = self.audioFiles.count == 1 ? @"Remove 1 audio note" : [NSString stringWithFormat:@"Remove all %lu audio notes", (unsigned long)self.audioFiles.count];
        }
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor systemRedColor];
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    // Style the cell
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    
    return cell;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (self.userNames.count == 0) {
        // Empty state - do nothing
        return;
    } else if (indexPath.section < self.userNames.count) {
        // Audio file selected
        NSString *userName = self.userNames[indexPath.section];
        NSArray *userFiles = self.audioFilesByUser[userName];
        AudioFileItem *audioFile = userFiles[indexPath.row];
        [self showOptionsForAudioFile:audioFile];
    } else {
        // Delete all selected
        [self confirmDeleteAllAudioFiles];
    }
}

- (void)showOptionsForAudioFile:(AudioFileItem *)audioFile {
    NSString *ext = [[audioFile.filename pathExtension] lowercaseString];
    NSSet *videoExts = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v"]];
    NSSet *imageExts = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"heic"]];
    BOOL isVideo = [videoExts containsObject:ext];
    BOOL isImage = [imageExts containsObject:ext];

    NSMutableArray *actions = [NSMutableArray array];

    if (isVideo) {
        [actions addObject:@{
            @"title": @"Play Video",
            @"handler": ^{
                NSString *tempDir = NSTemporaryDirectory();
                NSString *uniqueName = [NSString stringWithFormat:@"%@-%@", [[NSUUID UUID] UUIDString], audioFile.filename];
                NSString *tempPath = [tempDir stringByAppendingPathComponent:uniqueName];
                NSError *copyError = nil;
                if (![[NSFileManager defaultManager] copyItemAtPath:audioFile.filePath toPath:tempPath error:&copyError]) {
                    NSLog(@"Error copying video to temp: %@", copyError);
                    [ThetaHelper showToastWithTitle:@"Playback Error" subtitle:@"Unable to prepare video for playback" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
                    return;
                }
                NSURL *url = [NSURL fileURLWithPath:tempPath];
                MediaViewController *mediaVC = [[MediaViewController alloc] initWithMediaURL:url];
                mediaVC.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:mediaVC animated:YES completion:nil];
            }
        }];
    } else if (isImage) {
        [actions addObject:@{
            @"title": @"View Photo",
            @"handler": ^{
                NSURL *url = [NSURL fileURLWithPath:audioFile.filePath];
                MediaViewController *mediaVC = [[MediaViewController alloc] initWithMediaURL:url];
                mediaVC.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:mediaVC animated:YES completion:nil];
            }
        }];
    } else {
        [actions addObject:@{
            @"title": @"Play Audio",
            @"handler": ^{
                [self playAudioFile:audioFile];
            }
        }];
    }

    [actions addObject:@{
        @"title": @"Share",
        @"handler": ^{
            NSURL *fileURL = [NSURL fileURLWithPath:audioFile.filePath];
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
            
            // For iPad support
            if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                activityVC.popoverPresentationController.sourceView = self.view;
                activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 0, 0);
            }
            
            [self presentViewController:activityVC animated:YES completion:nil];
        }
    }];

    [actions addObject:@{
        @"title": @"Rename",
        @"handler": ^{
            [self showRenameDialogForAudioFile:audioFile];
        }
    }];

    [actions addObject:@{
        @"title": @"Delete",
        @"handler": ^{
            [self confirmDeleteAudioFile:audioFile];
        }
    }];

    [actions addObject:@{
        @"title": @"Cancel",
        @"handler": ^{ /* do nothing */ }
    }];
    
    NSString *desc = isVideo ? @"What would you like to do with this video?" : (isImage ? @"What would you like to do with this photo?" : @"What would you like to do with this audio note?");
    [ThetaHelper showCustomAlertWithActions:[audioFile.filename stringByDeletingPathExtension] 
                                 description:desc 
                                     actions:actions];
}

- (void)confirmDeleteAudioFile:(AudioFileItem *)audioFile {
    NSArray *actions = @[
        @{
            @"title": @"Delete",
            @"handler": ^{
                NSError *error;
                BOOL success = [[NSFileManager defaultManager] removeItemAtPath:audioFile.filePath error:&error];
                
                if (success) {
                    [ThetaHelper showToastWithTitle:@"Audio File Deleted" subtitle:[NSString stringWithFormat:@"\"%@\" has been deleted", audioFile.filename] icon:[UIImage systemImageNamed:@"trash"] autoHide:2 openURL:nil];
                    [self loadContent]; // Refresh the list
                } else {
                    NSLog(@"Error deleting file: %@", error.localizedDescription);
                    [ThetaHelper showToastWithTitle:@"Delete Failed" subtitle:@"Unable to delete the audio file" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
                }
            }
        },
        @{
            @"title": @"Cancel",
            @"handler": ^{ /* do nothing */ }
        }
    ];
    
    [ThetaHelper showCustomAlertWithActions:@"Delete Audio Note" 
                                 description:[NSString stringWithFormat:@"Are you sure you want to delete \"%@\"? This action cannot be undone.", [audioFile.filename stringByDeletingPathExtension]] 
                                     actions:actions];
}

- (void)showRenameDialogForAudioFile:(AudioFileItem *)audioFile {
    // Extract filename without extension
    NSString *currentFilename = audioFile.filename;
    NSString *fileExtension = [currentFilename pathExtension];
    NSString *filenameWithoutExtension = [currentFilename stringByDeletingPathExtension];
    
    // Create a UIAlertController with text input
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Rename Audio Note" 
                                                                             message:@"Enter a new name for this audio note:" 
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    // Add text field
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = filenameWithoutExtension;
        textField.placeholder = @"Enter new filename";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
        textField.autocorrectionType = UITextAutocorrectionTypeDefault;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    
    // Rename action
    UIAlertAction *renameAction = [UIAlertAction actionWithTitle:@"Rename" 
                                                           style:UIAlertActionStyleDefault 
                                                         handler:^(UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSString *newFilename = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        if (newFilename.length == 0) {
            [ThetaHelper showToastWithTitle:@"Rename Failed" subtitle:@"Please enter a valid filename" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            return;
        }
        
        // Add the original extension back
        NSString *newFullFilename = [NSString stringWithFormat:@"%@.%@", newFilename, fileExtension];
        
        // Check if the new filename already exists
        NSString *newFilePath = [[audioFile.filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:newFullFilename];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:newFilePath]) {
            [ThetaHelper showToastWithTitle:@"Rename Failed" subtitle:@"A file with this name already exists" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
            return;
        }
        
        // Perform the rename
        NSError *error;
        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:audioFile.filePath toPath:newFilePath error:&error];
        
        if (success) {
            [ThetaHelper showToastWithTitle:@"File Renamed" subtitle:[NSString stringWithFormat:@"Renamed to \"%@\"", newFullFilename] icon:[UIImage systemImageNamed:@"checkmark.circle"] autoHide:2 openURL:nil];
            [self loadContent]; // Refresh the list
        } else {
            NSLog(@"Error renaming file: %@", error.localizedDescription);
            [ThetaHelper showToastWithTitle:@"Rename Failed" subtitle:@"Unable to rename the audio file" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
    }];
    
    // Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" 
                                                           style:UIAlertActionStyleCancel 
                                                         handler:nil];
    
    [alertController addAction:renameAction];
    [alertController addAction:cancelAction];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)confirmDeleteAllAudioFiles {
    NSArray *actions = @[
        @{
            @"title": @"Delete All",
            @"handler": ^{
                NSFileManager *fileManager = [NSFileManager defaultManager];
                NSInteger deletedCount = 0;
                NSInteger failedCount = 0;
                
                for (AudioFileItem *audioFile in self.audioFiles) {
                    NSError *error;
                    BOOL success = [fileManager removeItemAtPath:audioFile.filePath error:&error];
                    
                    if (success) {
                        deletedCount++;
                    } else {
                        failedCount++;
                        NSLog(@"Error deleting file %@: %@", audioFile.filename, error.localizedDescription);
                    }
                }
                
                // Also remove empty user folders
                NSArray *userFolderNames = [fileManager contentsOfDirectoryAtPath:self.audioNotesDirectory error:nil];
                for (NSString *userFolderName in userFolderNames) {
                    NSString *userFolderPath = [self.audioNotesDirectory stringByAppendingPathComponent:userFolderName];
                    BOOL isDirectory;
                    if ([fileManager fileExistsAtPath:userFolderPath isDirectory:&isDirectory] && isDirectory) {
                        NSArray *remainingFiles = [fileManager contentsOfDirectoryAtPath:userFolderPath error:nil];
                        if (remainingFiles.count == 0) {
                            // Remove empty user folder
                            [fileManager removeItemAtPath:userFolderPath error:nil];
                        }
                    }
                }
                
                if (failedCount == 0) {
                    [ThetaHelper showToastWithTitle:@"All Audio Notes Deleted" subtitle:[NSString stringWithFormat:@"Successfully deleted %ld audio note%@", (long)deletedCount, deletedCount == 1 ? @"" : @"s"] icon:[UIImage systemImageNamed:@"trash"] autoHide:3 openURL:nil];
                } else {
                    [ThetaHelper showToastWithTitle:@"Deletion Completed" subtitle:[NSString stringWithFormat:@"Deleted %ld audio note%@, %ld failed", (long)deletedCount, deletedCount == 1 ? @"" : @"s", (long)failedCount] icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:nil];
                }
                
                [self loadContent]; // Refresh the list
            }
        },
        @{
            @"title": @"Cancel",
            @"handler": ^{ /* do nothing */ }
        }
    ];
    
    [ThetaHelper showCustomAlertWithActions:(self.contentMode == AudioNotesContentModeSavedMedia ? @"Delete All Saved Media" : @"Delete All Audio Notes") 
                                 description:[NSString stringWithFormat:@"Are you sure you want to delete all %lu audio note%@? This action cannot be undone.", (unsigned long)self.audioFiles.count, self.audioFiles.count == 1 ? @"" : @"s"] 
                                     actions:actions];
}

- (void)playAudioFile:(AudioFileItem *)audioFile {
    // Stop any currently playing audio
    if (self.audioPlayer && self.audioPlayer.isPlaying) {
        [self.audioPlayer stop];
        self.audioPlayer = nil;
    }
    
    // Check if user is trying to play the same file that's already loaded
    if ([self.currentlyPlayingFile isEqualToString:audioFile.filename] && self.audioPlayer) {
        // Resume playing if paused, ensure UI is visible and in sync
        if (!self.audioPlayer.isPlaying) {
            [self showPlayerForAudioFile:audioFile];
            BOOL ok = [self.audioPlayer play];
            if (ok) {
                [self.playPauseButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
                [self startProgressTimer];
                [self cancelAutoHideTimer];
            }
        }
        return;
    }
    
    NSError *error;
    NSURL *fileURL = [NSURL fileURLWithPath:audioFile.filePath];
    
    // Configure audio session for exclusive playback (prevent other app audio while note is playing)
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [audioSession setCategory:AVAudioSessionCategoryPlayback withOptions:0 error:&error];
    if (error) {
        NSLog(@"Error setting audio session category: %@", error.localizedDescription);
    }
    [audioSession setActive:YES error:&error];
    if (error) {
        NSLog(@"Error activating audio session: %@", error.localizedDescription);
    }
    
    // Create and configure audio player
    self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&error];
    if (error) {
        NSLog(@"Error creating audio player: %@ (OSStatus: %ld)", error.localizedDescription, (long)error.code);
        
        NSString *errorMessage;
        if (error.code == 1937337955) { // kAudioFileUnsupportedFileTypeError
            errorMessage = @"This audio format is not supported for playback. Try converting to MP3 or M4A format.";
        } else if (error.code == 1954115647) { // kAudioFileUnsupportedDataFormatError
            errorMessage = @"The audio encoding is not supported. The file may be corrupted.";
        } else if (error.code == -43) { // File not found
            errorMessage = @"Audio file not found. It may have been moved or deleted.";
        } else {
            errorMessage = [NSString stringWithFormat:@"Unable to play this audio file (Error: %ld)", (long)error.code];
        }
        
        // Try fallback method for unsupported formats
        if (error.code == 1937337955) {
            [self tryFallbackPlayback:audioFile];
        } else {
            [ThetaHelper showToastWithTitle:@"Playback Error" subtitle:errorMessage icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:nil];
        }
        return;
    }
    
    self.audioPlayer.delegate = self;
    self.currentlyPlayingFile = audioFile.filename;
    
    // Prepare and show player UI
    [self showPlayerForAudioFile:audioFile];
    
    // Start playback
    BOOL success = [self.audioPlayer play];
    if (success) {
        [self.playPauseButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
        [self startProgressTimer];
        [self cancelAutoHideTimer];
    } else {
        [ThetaHelper showToastWithTitle:@"Playback Error" subtitle:@"Failed to start audio playback" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
    }
}

- (void)stopAudioPlayback {
    if (self.audioPlayer) {
        if (self.audioPlayer.isPlaying) {
            [self.audioPlayer stop];
        }
        self.audioPlayer = nil;
    }
    self.currentlyPlayingFile = nil;
    [self invalidateProgressTimer];
    [self cancelAutoHideTimer];
    [self hidePlayerUI];
    
    // Deactivate and notify others so feed videos or other audio can resume
    NSError *error;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    if (error) {
        NSLog(@"Error deactivating audio session: %@", error.localizedDescription);
    }
}

- (void)tryFallbackPlayback:(AudioFileItem *)audioFile {
    // Fallback: Use the system's default audio player via UIDocumentInteractionController
    NSURL *fileURL = [NSURL fileURLWithPath:audioFile.filePath];
    
    // Create a temporary document interaction controller
    UIDocumentInteractionController *documentController = [UIDocumentInteractionController interactionControllerWithURL:fileURL];
    documentController.delegate = (id<UIDocumentInteractionControllerDelegate>)self;
    
    // Try to preview the audio file
    BOOL canPreview = [documentController presentPreviewAnimated:YES];
    if (canPreview) {
        [ThetaHelper showToastWithTitle:@"Opening Audio Player" subtitle:@"Playing selected audio file" icon:[UIImage systemImageNamed:@"play.circle"] autoHide:3 openURL:nil];
    } else {
        // If preview fails, try opening with external apps
        BOOL canOpen = [documentController presentOpenInMenuFromRect:CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 0, 0) 
                                                               inView:self.view 
                                                             animated:YES];
        if (canOpen) {
            [ThetaHelper showToastWithTitle:@"Opening Audio File" subtitle:@"Choose an app to play this audio file" icon:[UIImage systemImageNamed:@"square.and.arrow.up"] autoHide:3 openURL:nil];
        } else {
            [ThetaHelper showToastWithTitle:@"Playback Error" subtitle:@"This audio format is not supported. The file may be corrupted or use an unsupported encoding." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:nil];
        }
    }
}

#pragma mark - UIDocumentInteractionControllerDelegate

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    return self;
}

- (void)documentInteractionControllerDidEndPreview:(UIDocumentInteractionController *)controller {
    // Clean up when preview ends
    NSLog(@"Audio preview ended");
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    // Clean up
    self.audioPlayer = nil;
    // Keep currentlyPlayingFile so the user can tap play to restart
    [self.playPauseButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    [self invalidateProgressTimer];
    if (self.progressSlider) {
        self.progressSlider.value = self.progressSlider.maximumValue;
    }
    // Auto-hide player after a short delay when nothing is playing
    [self startAutoHideTimer];
    
    // Deactivate and notify others so feed videos or other audio can resume
    NSError *error;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    if (error) {
        NSLog(@"Error deactivating audio session: %@", error.localizedDescription);
    }
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    NSLog(@"Audio player decode error: %@", error.localizedDescription);
    [ThetaHelper showToastWithTitle:@"Playback Error" subtitle:@"Audio decode error occurred" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
    
    // Clean up
    self.audioPlayer = nil;
    self.currentlyPlayingFile = nil;
}

- (void)dealloc {
    // Stop any playing audio when the view controller is deallocated
    [self stopAudioPlayback];
}

@end

// MARK: - Inline Audio Player UI

@implementation AudioNotesViewController (PlayerUI)

- (void)showPlayerForAudioFile:(AudioFileItem *)audioFile {
    if (!self.playerView) {
        [self buildPlayerUI];
    }
    self.trackTitleLabel.text = [audioFile.filename stringByDeletingPathExtension];
    self.progressSlider.minimumValue = 0.0f;
    self.progressSlider.maximumValue = (float)self.audioPlayer.duration;
    self.progressSlider.value = (float)self.audioPlayer.currentTime;
    self.currentTimeLabel.text = [self formattedTimeString:0];
    self.durationLabel.text = [self formattedTimeString:self.audioPlayer.duration];

    // Prepare for fade-in
    self.playerView.alpha = 0.0;
    // Attach to table footer so it is visible
    self.tableView.tableFooterView = self.playerView;
    // Ensure footer and card have the correct width
    CGFloat width = self.view.bounds.size.width;
    CGRect frame = self.playerView.frame;
    frame.size.width = width;
    self.playerView.frame = frame;
    CGFloat horizontalInset = 16.0;
    CGFloat verticalInset = 8.0;
    self.playerCardView.frame = CGRectMake(horizontalInset, verticalInset, width - horizontalInset * 2.0, self.playerCardView.frame.size.height);
    // Re-layout subviews inside card on width change
    CGFloat contentWidth = self.playerCardView.bounds.size.width;
    CGFloat left = 12.0 + 36.0 + 12.0;
    CGFloat rightPadding = 12.0;
    self.playPauseButton.frame = CGRectMake(12.0, 26.0, 36.0, 36.0);
    self.trackTitleLabel.frame = CGRectMake(left, 10.0, contentWidth - left - rightPadding, 22.0);
    self.progressSlider.frame = CGRectMake(left, CGRectGetMaxY(self.trackTitleLabel.frame) + 8.0, contentWidth - left - rightPadding, 20.0);
    self.currentTimeLabel.frame = CGRectMake(left, CGRectGetMaxY(self.progressSlider.frame) + 6.0, 60.0, 16.0);
    self.durationLabel.frame = CGRectMake(contentWidth - rightPadding - 60.0, CGRectGetMaxY(self.progressSlider.frame) + 6.0, 60.0, 16.0);

    // Fade in animation
    [UIView animateWithDuration:0.25 animations:^{
        self.playerView.alpha = 1.0;
    }];
}

- (void)hidePlayerUI {
    if (!self.playerView) { return; }
    [self invalidateProgressTimer];
    [self cancelAutoHideTimer];
    [UIView animateWithDuration:0.25 animations:^{
        self.playerView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.tableView.tableFooterView = nil;
        self.playPauseButton = nil;
        self.progressSlider = nil;
        self.currentTimeLabel = nil;
        self.durationLabel = nil;
        self.trackTitleLabel = nil;
        self.playerCardView = nil;
        self.playerView = nil;
    }];
}

- (void)buildPlayerUI {
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = 110.0;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    container.backgroundColor = [UIColor clearColor];

    // Card view with rounded corners to match grouped cells
    CGFloat horizontalInset = 16.0;
    CGFloat verticalInset = 8.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(horizontalInset, verticalInset, width - horizontalInset * 2.0, height - verticalInset * 2.0)];
    if (@available(iOS 13.0, *)) {
        card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        card.backgroundColor = [UIColor whiteColor];
    }
    card.layer.cornerRadius = 12.0;
    card.layer.masksToBounds = YES;
    [container addSubview:card];
    self.playerCardView = card;

    UIButton *playPause = [UIButton buttonWithType:UIButtonTypeSystem];
    playPause.tintColor = [ThetaHelper iotaPinkColor];
    [playPause setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    [playPause addTarget:self action:@selector(onPlayPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:playPause];
    self.playPauseButton = playPause;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:title];
    self.trackTitleLabel = title;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
    slider.minimumValue = 0.0f;
    slider.maximumValue = 1.0f;
    [slider addTarget:self action:@selector(onSliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(onSliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [slider addTarget:self action:@selector(onSliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [card addSubview:slider];
    self.progressSlider = slider;

    UILabel *cur = [[UILabel alloc] initWithFrame:CGRectZero];
    cur.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    cur.textColor = [UIColor secondaryLabelColor];
    cur.text = @"0:00";
    [card addSubview:cur];
    self.currentTimeLabel = cur;

    UILabel *dur = [[UILabel alloc] initWithFrame:CGRectZero];
    dur.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    dur.textColor = [UIColor secondaryLabelColor];
    dur.textAlignment = NSTextAlignmentRight;
    dur.text = @"0:00";
    [card addSubview:dur];
    self.durationLabel = dur;

    // Simple frames layout inside card
    CGFloat contentWidth = card.bounds.size.width;
    CGFloat left = 12.0 + 36.0 + 12.0; // button + padding
    CGFloat rightPadding = 12.0;
    playPause.frame = CGRectMake(12.0, 26.0, 36.0, 36.0);
    title.frame = CGRectMake(left, 10.0, contentWidth - left - rightPadding, 22.0);
    slider.frame = CGRectMake(left, CGRectGetMaxY(title.frame) + 8.0, contentWidth - left - rightPadding, 20.0);
    cur.frame = CGRectMake(left, CGRectGetMaxY(slider.frame) + 6.0, 60.0, 16.0);
    dur.frame = CGRectMake(contentWidth - rightPadding - 60.0, CGRectGetMaxY(slider.frame) + 6.0, 60.0, 16.0);

    self.playerView = container;
}

- (void)startProgressTimer {
    [self invalidateProgressTimer];
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(onProgressTick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.progressTimer forMode:NSRunLoopCommonModes];
}

- (void)invalidateProgressTimer {
    if (self.progressTimer) {
        [self.progressTimer invalidate];
        self.progressTimer = nil;
    }
}

- (void)startAutoHideTimer {
    [self cancelAutoHideTimer];
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(onAutoHideTimerFired) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.autoHideTimer forMode:NSRunLoopCommonModes];
}

- (void)cancelAutoHideTimer {
    if (self.autoHideTimer) {
        [self.autoHideTimer invalidate];
        self.autoHideTimer = nil;
    }
}

- (void)onAutoHideTimerFired {
    // Only hide if no audio is currently playing AND we're truly at end of track
    if ((!self.audioPlayer || !self.audioPlayer.isPlaying) && [self isAtEndOfTrack]) {
        [self hidePlayerUI];
    }
}

- (void)onProgressTick {
    if (!self.audioPlayer || self.isScrubbing) { return; }
    self.progressSlider.value = (float)self.audioPlayer.currentTime;
    self.currentTimeLabel.text = [self formattedTimeString:self.audioPlayer.currentTime];
}

- (void)onPlayPauseTapped {
    if (self.audioPlayer) {
        if (self.audioPlayer.isPlaying) {
            [self.audioPlayer pause];
            [self.playPauseButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
            [self invalidateProgressTimer];
            // Only start auto-hide if we're truly at the end
            if ([self isAtEndOfTrack]) {
                [self startAutoHideTimer];
            } else {
                [self cancelAutoHideTimer];
            }
            // Deactivate and notify others so feed videos or other audio can resume while paused
            NSError *deactErr;
            [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&deactErr];
            if (deactErr) {
                NSLog(@"Error deactivating audio session (pause): %@", deactErr.localizedDescription);
            }
        } else {
            BOOL ok = [self.audioPlayer play];
            if (ok) {
                [self.playPauseButton setImage:[UIImage systemImageNamed:@"pause.fill"] forState:UIControlStateNormal];
                [self startProgressTimer];
                [self cancelAutoHideTimer];
                // Reactivate session for exclusive playback
                NSError *actErr;
                AVAudioSession *audioSession = [AVAudioSession sharedInstance];
                [audioSession setCategory:AVAudioSessionCategoryPlayback withOptions:0 error:&actErr];
                if (actErr) {
                    NSLog(@"Error setting category on resume: %@", actErr.localizedDescription);
                }
                [audioSession setActive:YES error:&actErr];
                if (actErr) {
                    NSLog(@"Error activating on resume: %@", actErr.localizedDescription);
                }
            }
        }
    } else if (self.currentlyPlayingFile.length > 0) {
        // Recreate player for the last file and start playback
        AudioFileItem *item = [self findAudioItemByFilename:self.currentlyPlayingFile];
        if (item) {
            [self playAudioFile:item];
        }
    }
}

- (void)onSliderTouchDown {
    self.isScrubbing = YES;
}

- (void)onSliderValueChanged:(UISlider *)slider {
    // Update time label while scrubbing
    self.currentTimeLabel.text = [self formattedTimeString:slider.value];
}

- (void)onSliderTouchUp:(UISlider *)slider {
    if (self.audioPlayer) {
        self.audioPlayer.currentTime = slider.value;
        self.currentTimeLabel.text = [self formattedTimeString:slider.value];
        if (self.audioPlayer.isPlaying == NO) {
            // Leave paused; do not auto-resume
        }
    }
    // Start/cancel auto-hide based on whether we're at the end
    if ([self isAtEndOfTrack]) {
        [self startAutoHideTimer];
    } else {
        [self cancelAutoHideTimer];
    }
    self.isScrubbing = NO;
}

- (NSString *)formattedTimeString:(NSTimeInterval)time {
    if (isnan(time) || time < 0) { time = 0; }
    NSInteger totalSeconds = (NSInteger)llround(time);
    NSInteger hours = totalSeconds / 3600;
    NSInteger minutes = (totalSeconds % 3600) / 60;
    NSInteger seconds = totalSeconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)seconds];
    } else {
        return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
    }
}

- (AudioFileItem *)findAudioItemByFilename:(NSString *)filename {
    for (AudioFileItem *item in self.audioFiles) {
        if ([item.filename isEqualToString:filename]) { return item; }
    }
    // Fallback: search grouped dicts
    for (NSString *key in self.audioFilesByUser) {
        for (AudioFileItem *it in self.audioFilesByUser[key]) {
            if ([it.filename isEqualToString:filename]) { return it; }
        }
    }
    return nil;
}

- (BOOL)isAtEndOfTrack {
    // Prefer slider value if UI exists; otherwise inspect the player
    float duration = 0.0f;
    float current = 0.0f;
    if (self.progressSlider) {
        duration = self.progressSlider.maximumValue;
        current = self.progressSlider.value;
    } else if (self.audioPlayer) {
        duration = (float)self.audioPlayer.duration;
        current = (float)self.audioPlayer.currentTime;
    }
    if (duration <= 0.0f) { return NO; }
    const float epsilon = 0.25f; // 250 ms tolerance
    return current >= (duration - epsilon);
}

@end
