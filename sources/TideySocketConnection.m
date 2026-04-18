#import "TideySocketConnection.h"

#import "DebugLogging.h"

@interface TideySocketConnection ()
@property(nonatomic, strong) NSFileHandle *fileHandle;
@property(nonatomic, strong) NSMutableData *buffer;
@property(nonatomic, copy) void (^messageHandler)(TideySocketConnection *connection, NSDictionary *message);
@property(nonatomic, copy) void (^closeHandler)(TideySocketConnection *connection);
@property(nonatomic) BOOL closed;
@end

@implementation TideySocketConnection

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                        messageHandler:(void (^)(TideySocketConnection *connection, NSDictionary *message))messageHandler
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
        // Try the legacy space-delimited plaintext format:
        //   <action> <state> [--key=value ...]
        dict = [self parsePlaintextLineData:lineData];
        if (!dict) {
            DLog(@"Ignoring invalid Tidey socket payload: %@", error.localizedDescription);
            return;
        }
    }
    if (self.messageHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.messageHandler(self, dict);
        });
    }
}

- (void)sendJSONObject:(NSDictionary *)object {
    if (self.closed || object.count == 0) {
        return;
    }
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!json) {
        DLog(@"Ignoring Tidey socket response serialization failure: %@", error.localizedDescription);
        return;
    }
    NSMutableData *payload = [json mutableCopy];
    [payload appendData:[NSData dataWithBytes:"\n" length:1]];
    @try {
        [self.fileHandle writeData:payload];
    } @catch (NSException *exception) {
        DLog(@"Failed to write Tidey socket response: %@", exception);
        [self close];
    }
}

- (NSDictionary *)parsePlaintextLineData:(NSData *)lineData {
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
    if (line.length == 0) {
        return nil;
    }
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *s, NSDictionary *bindings) {
        return s.length > 0;
    }]];
    if (parts.count < 2) {
        return nil;
    }

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"action"] = parts[0];
    dict[@"state"] = parts[1];

    // Parse optional --key=value pairs.
    for (NSUInteger i = 2; i < parts.count; i++) {
        NSString *part = parts[i];
        if ([part hasPrefix:@"--"] && part.length > 2) {
            NSString *kvString = [part substringFromIndex:2];
            NSRange eqRange = [kvString rangeOfString:@"="];
            if (eqRange.location != NSNotFound) {
                NSString *key = [kvString substringToIndex:eqRange.location];
                NSString *value = [kvString substringFromIndex:eqRange.location + 1];
                if (key.length > 0) {
                    dict[key] = value;
                }
            }
        }
    }

    return dict;
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
