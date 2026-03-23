#import "TideySocketConnection.h"

#import "DebugLogging.h"

@interface TideySocketConnection ()
@property(nonatomic, strong) NSFileHandle *fileHandle;
@property(nonatomic, strong) NSMutableData *buffer;
@property(nonatomic, copy) void (^messageHandler)(NSDictionary *message);
@property(nonatomic, copy) void (^closeHandler)(TideySocketConnection *connection);
@property(nonatomic) BOOL closed;
@end

@implementation TideySocketConnection

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                        messageHandler:(void (^)(NSDictionary *message))messageHandler
                          closeHandler:(void (^)(TideySocketConnection *connection))closeHandler {
    self = [super init];
    if (self) {
        _fileHandle = [[NSFileHandle alloc] initWithFileDescriptor:fileDescriptor closeOnDealloc:YES];
        _buffer = [[NSMutableData alloc] init];
        _messageHandler = [messageHandler copy];
        _closeHandler = [closeHandler copy];
        [self startReading];
    }
    return self;
}

- (void)startReading {
    __weak __typeof(self) weakSelf = self;
    self.fileHandle.readabilityHandler = ^(NSFileHandle *handle) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.closed) {
            return;
        }
        NSData *data = handle.availableData;
        if (data.length == 0) {
            [strongSelf close];
            return;
        }
        [strongSelf.buffer appendData:data];
        [strongSelf drainBuffer];
    };
}

- (void)drainBuffer {
    const char *bytes = self.buffer.bytes;
    NSUInteger length = self.buffer.length;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < length; i++) {
        if (bytes[i] != '\n') {
            continue;
        }
        NSData *lineData = [self.buffer subdataWithRange:NSMakeRange(start, i - start)];
        if (lineData.length > 0) {
            [self handleLineData:lineData];
        }
        start = i + 1;
    }
    if (start > 0) {
        NSData *remaining = [self.buffer subdataWithRange:NSMakeRange(start, length - start)];
        self.buffer = [remaining mutableCopy];
    }
}

- (void)handleLineData:(NSData *)lineData {
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:&error];
    NSDictionary *dict = [object isKindOfClass:[NSDictionary class]] ? object : nil;
    if (!dict) {
        DLog(@"Ignoring invalid Tidey socket payload: %@", error.localizedDescription);
        return;
    }
    if (self.messageHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.messageHandler(dict);
        });
    }
}

- (void)close {
    if (self.closed) {
        return;
    }
    self.closed = YES;
    self.fileHandle.readabilityHandler = nil;
    [self.fileHandle closeFile];
    if (self.closeHandler) {
        self.closeHandler(self);
    }
}

@end
