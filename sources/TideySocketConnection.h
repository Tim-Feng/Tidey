#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TideySocketConnection : NSObject

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                        messageHandler:(void (^)(NSDictionary *message))messageHandler
                           closeHandler:(void (^)(TideySocketConnection *connection))closeHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)close;

@end

NS_ASSUME_NONNULL_END
