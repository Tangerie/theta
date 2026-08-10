#import "Include/InstagramHeaders.h"
#import "Include/CustomToastView.h"

// Forward declaration
@class IGVideo;

@interface MediaSelectionViewController : UIViewController <UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDataSourcePrefetching, CAAnimationDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<NSDictionary *> *mediaItems;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedIndexes;
@property (nonatomic, strong) UIBarButtonItem *downloadButton;
@property (nonatomic, strong) UIButton *selectAllButton;
@property (nonatomic, strong) UILabel *instructionLabel;
@property (nonatomic, strong) NSCache *previewCache;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, strong) NSMutableDictionary *videoPlayersCache;
@property (nonatomic, strong) NSOperationQueue *fetchQueue;

// New properties for HD video support
@property (nonatomic, strong) NSArray<IGVideo *> *hdVideos;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedVideoIndexes;

-(instancetype)initWithMediaItems:(NSArray<NSDictionary *> *)mediaItems withCount:(NSInteger)count;
-(instancetype)initWithMediaItems:(NSArray<NSDictionary *> *)mediaItems hdVideos:(NSArray<IGVideo *> *)hdVideos withCount:(NSInteger)count;
-(void)downloadMediaToTemp:(NSURL *)url completion:(void (^)(NSString *filePath, NSString *fileExtension))completion;
- (void)saveFilesToCameraRoll:(NSArray<NSString *> *)filePaths extensions:(NSArray<NSString *> *)fileExtensions;
- (void)performDownloadWithURL:(NSURL *)url completion:(void(^)(NSString *filePath, NSString *fileExtension))completion;
// Force-save directly to Documents/AudioNotes, ignoring Save Method
- (void)performDownloadToAudioNotesWithURL:(NSURL *)url completion:(void(^)(NSString *filePath, NSString *fileExtension))completion;
// Convert a media file to MP3 (libmp3lame -q:a 0). On success, returns new path.
- (void)convertFileToMP3:(NSString *)inputPath completion:(void(^)(NSString *outputPath, NSError *error))completion;

// New methods for HD video support
- (void)downloadHDVideosBulk:(NSArray<IGVideo *> *)videos progressToast:(CustomToastView *)progressToast completed:(NSInteger)completedItems total:(NSInteger)totalItems failed:(NSInteger)failedItems;
- (void)showCompletionToast:(CustomToastView *)progressToast completed:(NSInteger)completed total:(NSInteger)total failed:(NSInteger)failed;

// Class methods for preloading
+ (void)preloadHDVideoThumbnails:(NSArray<IGVideo *> *)hdVideos completion:(void(^)(void))completion;
+ (NSCache *)sharedPreviewCache;
@end
