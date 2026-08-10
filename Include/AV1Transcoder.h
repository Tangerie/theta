#import <Foundation/Foundation.h>

typedef void (^AV1TranscoderProgressBlock)(NSString *status, float progress);

@interface AV1Transcoder : NSObject

+ (BOOL)transcodeAV1ToH264:(NSString *)inputPath 
                outputPath:(NSString *)outputPath 
                 audioPath:(NSString *)audioPath  // Optional: separate audio file to merge
                     error:(NSError **)error
              progressBlock:(AV1TranscoderProgressBlock)progressBlock;

@end

