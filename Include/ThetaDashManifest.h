#import <Foundation/Foundation.h>

@class NSURL;

FOUNDATION_EXPORT NSString *IGDashManifestBestQualityURL(NSString *manifest);
FOUNDATION_EXPORT NSString *IGDashManifestBestCompatibleURL(NSString *manifest);
FOUNDATION_EXPORT NSString *IGDashManifestBestAudioURL(NSString *manifest);

/** Saves a finished video into Photos (creation-request path when supported). */
FOUNDATION_EXPORT void ThetaPhotoLibraryImportVideoFromURL(NSURL *fileURL, void (^completion)(BOOL success, NSError *_Nullable error));
