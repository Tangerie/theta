#import <UIKit/UIKit.h>
@interface AudioNotesViewController : UITableViewController
typedef NS_ENUM(NSInteger, AudioNotesContentMode) {
    AudioNotesContentModeAudioNotes = 0,
    AudioNotesContentModeSavedMedia = 1
};

- (instancetype)initWithMode:(AudioNotesContentMode)mode;

@end
