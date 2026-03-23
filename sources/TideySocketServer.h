#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TideySocketServer : NSObject

+ (instancetype)sharedServer;
+ (NSString *)socketDirectory;
+ (NSString *)socketPath;

- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
