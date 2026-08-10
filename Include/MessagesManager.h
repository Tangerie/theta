#import <Foundation/Foundation.h>

@interface MessagesManager : NSObject
+(instancetype)sharedManager;
-(void)saveDeletedMessageWithID:(NSString *)messageID;
-(BOOL)messageExistsWithID:(NSString *)messageID;
-(NSString *)dateForDeletedMessageWithID:(NSString *)messageID;
-(NSMutableDictionary *)loadPlistData;
-(void)savePlistData:(NSDictionary *)data;
@end
