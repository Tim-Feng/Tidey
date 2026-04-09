//
//  iTermPathFinder.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/15/19.
//

#import "iTermPathFinder.h"

#import "DebugLogging.h"
#import "iTermPathCleaner.h"
#import "NSArray+CommonAdditions.h"
#import "NSFileManager+CommonAdditions.h"
#import "NSStringITerm.h"
#import "RegexKitLite.h"

static dispatch_queue_t iTermPathFinderQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.iterm2.path-finder", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface iTermPathFinder()
@property (atomic, readwrite) BOOL canceled;
@end

static const NSInteger iTermPathFinderInitialSuffixChunkLimit = 25;
static const NSInteger iTermPathFinderMaxExtendedSuffixChunks = 25;

@implementation iTermPathFinder {
    NSString *_beforeStringIn;
    NSString *_afterStringIn;
    NSString *_workingDirectory;
    BOOL _trimWhitespace;
}

- (instancetype)initWithPrefix:(NSString *)beforeStringIn
                        suffix:(NSString *)afterStringIn
              workingDirectory:(NSString *)workingDirectory
                trimWhitespace:(BOOL)trimWhitespace
                        ignore:(NSString *)pathsToIgnore
            allowNetworkMounts:(BOOL)allowNetworkMounts {
    self = [super init];
    if (self) {
        _beforeStringIn = [beforeStringIn copy];
        _afterStringIn = [afterStringIn copy];
        _workingDirectory = [workingDirectory copy];
        _trimWhitespace = trimWhitespace;
        _fileManager = [NSFileManager defaultManager];
        _pathsToIgnore = [pathsToIgnore copy];
        _allowNetworkMounts = allowNetworkMounts;
    }
    return self;
}

- (void)cancel {
    self.canceled = YES;
}

- (void)searchWithCompletion:(void (^)(void))completion {
    dispatch_async(iTermPathFinderQueue(), ^{
        [self searchSynchronously];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion();
        });
    });
}

- (void)searchSynchronously {
    BOOL workingDirectoryIsOk = [self fileExistsAtPathLocally:_workingDirectory];
    if (!workingDirectoryIsOk) {
        DLog(@"Working directory %@ is a network share or doesn't exist. Not using it for context.",
             _workingDirectory);
    }

    DLog(@"Brute force path from prefix <<%@>>, suffix <<%@>> directory=%@",
         _beforeStringIn, _afterStringIn, _workingDirectory);

    // Split "Foo Bar" to ["Foo", " ", "Bar"]
    NSArray *beforeChunks = [self splitString:_beforeStringIn];
    NSArray *afterChunks = [self splitString:_afterStringIn];

    NSMutableString *left = [NSMutableString string];
    int iterationsBeforeQuitting = 100;  // Bail after 100 iterations if nothing is still found.
    NSMutableSet *paths = [NSMutableSet set];
    NSCharacterSet *whitespaceCharset = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSInteger i = [beforeChunks count]; i >= 0; i--) {
        if (self.canceled) {
            _path = nil;
            return;
        }
        NSString *beforeChunk = @"";
        if (i < [beforeChunks count]) {
            beforeChunk = beforeChunks[i];
        }

        [left insertString:beforeChunk atIndex:0];
        NSMutableString *right = [NSMutableString string];
        // Limit how far we search into the suffix so leftward search still makes progress,
        // but allow enough room for long filenames with many space-separated words.
        for (int j = 0; j < MAX(1, afterChunks.count) && j < iTermPathFinderInitialSuffixChunkLimit; j++) {
            if (self.canceled) {
                _path = nil;
                return;
            }
            NSString *rightChunk = @"";
            if (j < afterChunks.count) {
                rightChunk = afterChunks[j];
            }
            [right appendString:rightChunk];

            NSString *possiblePath = [left stringByAppendingString:right];
            NSString *trimmedPath = possiblePath;
            if (_trimWhitespace) {
                trimmedPath = [trimmedPath stringByTrimmingCharactersInSet:whitespaceCharset];
            }
            if ([paths containsObject:[NSString stringWithString:trimmedPath]]) {
                continue;
            }
            [paths addObject:[trimmedPath copy]];

            // Replace \x with x for x in: space, (, [, ], \, ).
            NSString *removeEscapingSlashes = @"\\\\([ \\(\\[\\]\\\\)])";
            trimmedPath = [trimmedPath stringByReplacingOccurrencesOfRegex:removeEscapingSlashes withString:@"$1"];

            // Some programs will thoughtlessly print a filename followed by some silly suffix.
            // We'll try versions with and without a questionable suffix. The version
            // with the suffix is always preferred if it exists.
            static NSArray *questionableSuffixes;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                questionableSuffixes = @[ @"!", @"?", @".", @",", @";", @":", @"...", @"…" ];
            });
            NSDictionary *match = [self existingPathMatchForTrimmedPath:trimmedPath
                                                      workingDirectoryIsOk:workingDirectoryIsOk
                                                       questionableSuffixes:questionableSuffixes];
            if (!match && j + 1 < afterChunks.count) {
                match = [self extendedPathMatchFromLeft:left
                                                  right:right
                                             afterChunks:afterChunks
                                              startIndex:j + 1
                                    workingDirectoryIsOk:workingDirectoryIsOk
                                             seenPaths:paths
                                        whitespaceCharset:whitespaceCharset
                                     questionableSuffixes:questionableSuffixes];
            }
            if (match) {
                NSString *modifiedPossiblePath = match[@"modifiedPath"];
                NSString *matchedTrimmedPath = match[@"trimmedPath"];
                NSString *matchedRight = match[@"right"] ?: right;
                NSInteger nextAfterChunkIndex = match[@"nextAfterChunkIndex"] ? [match[@"nextAfterChunkIndex"] integerValue] : j + 1;
                NSString *extra = @"";
                if (nextAfterChunkIndex < afterChunks.count) {
                    extra = [self columnAndLineNumberFromChunks:[afterChunks subarrayFromIndex:nextAfterChunkIndex]];
                }
                NSString *extendedPath = [modifiedPossiblePath stringByAppendingString:extra];
                NSString *rightWithExtra = [matchedRight stringByAppendingString:extra];

                if (_trimWhitespace &&
                    [[rightWithExtra stringByTrimmingTrailingCharactersFromCharacterSet:whitespaceCharset] length] == 0) {
                    // trimmedPath is trim(left + right). If trim(right) is empty
                    // then we don't want to count trailing whitespace from left in the chars
                    // taken from prefix.
                    _prefixChars = (int)[[left stringByTrimmingTrailingCharactersFromCharacterSet:whitespaceCharset] length];
                } else {
                    _prefixChars = (int)left.length;
                }
                NSInteger lengthOfBadSuffix = extra.length ? 0 : matchedTrimmedPath.length - modifiedPossiblePath.length;
                int n;
                if (_trimWhitespace) {
                    n = (int)([[rightWithExtra stringByTrimmingTrailingCharactersFromCharacterSet:whitespaceCharset] length] - lengthOfBadSuffix);
                } else {
                    n = (int)(rightWithExtra.length - lengthOfBadSuffix);
                }
                _suffixChars = MAX(0, n);
                DLog(@"Using path %@", extendedPath);
                _path = [extendedPath copy];
                return;
            }
            if (--iterationsBeforeQuitting == 0) {
                _path = nil;
                return;
            }
        }
    }
    _path = nil;
    return;
}

#pragma mark - Private

#pragma mark Filesystem

- (BOOL)fileExistsAtPathLocally:(NSString *)path {
    _workingDirectoryIsLocal = [self.fileManager fileIsLocal:path
                                      additionalNetworkPaths:[_pathsToIgnore componentsSeparatedByString:@","]
                                          allowNetworkMounts:_allowNetworkMounts];
    if (!_workingDirectoryIsLocal) {
        return NO;
    }
    return [self.fileManager fileExistsAtPath:path];
}

- (BOOL)fileHasForbiddenPrefix:(NSString *)path {
    return [self.fileManager fileHasForbiddenPrefix:path
                             additionalNetworkPaths:[_pathsToIgnore componentsSeparatedByString:@","]];
}

#pragma mark String Manipulation

- (NSArray<NSString *> *)splitString:(NSString *)string {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    __block NSRange lastRange = NSMakeRange(0, 0);
    [string enumerateStringsMatchedByRegex:@"([^\t ():\",]*)([\t ():\",])"
                                   options:0
                                   inRange:NSMakeRange(0, string.length)
                                     error:nil
                        enumerationOptions:0
                                usingBlock:^(NSInteger captureCount,
                                             NSString *const __unsafe_unretained *capturedStrings,
                                             const NSRange *capturedRanges,
                                             volatile BOOL *const stop) {
                                    [parts addObject:capturedStrings[1]];
                                    [parts addObject:capturedStrings[2]];
                                    lastRange = capturedRanges[2];
                                }];
    const NSInteger suffixStartIndex = NSMaxRange(lastRange);
    if (suffixStartIndex < string.length) {
        [parts addObject:[string substringFromIndex:suffixStartIndex]];
    }
    return parts;
}

- (NSArray *)pathsFromPath:(NSString *)source byRemovingBadSuffixes:(NSArray *)badSuffixes {
    NSMutableArray *result = [NSMutableArray array];
    [result addObject:source];
    for (NSString *badSuffix in badSuffixes) {
        if ([source hasSuffix:badSuffix]) {
            NSString *stripped = [source substringToIndex:source.length - badSuffix.length];
            if (stripped.length) {
                [result addObject:stripped];
            }
        }
    }
    return result;
}

- (nullable NSDictionary<NSString *, id> *)existingPathMatchForTrimmedPath:(NSString *)trimmedPath
                                                      workingDirectoryIsOk:(BOOL)workingDirectoryIsOk
                                                       questionableSuffixes:(NSArray<NSString *> *)questionableSuffixes {
    for (NSString *modifiedPossiblePath in [self pathsFromPath:trimmedPath byRemovingBadSuffixes:questionableSuffixes]) {
        if (self.canceled) {
            return nil;
        }
        BOOL exists = NO;
        if (workingDirectoryIsOk || [modifiedPossiblePath hasPrefix:@"/"]) {
            iTermPathCleaner *cleaner = [[iTermPathCleaner alloc] initWithPath:modifiedPossiblePath
                                                                        suffix:nil
                                                              workingDirectory:_workingDirectory
                                                                        ignore:_pathsToIgnore
                                                            allowNetworkMounts:_allowNetworkMounts];
            cleaner.reqid = self.reqid;
            cleaner.fileManager = self.fileManager;
            cleaner.tryFallback = ![modifiedPossiblePath hasPrefix:@"/"];
            [cleaner cleanSynchronously];
            exists = (cleaner.cleanPath != nil);
        }
        if (exists) {
            return @{
                @"modifiedPath": modifiedPossiblePath,
                @"trimmedPath": trimmedPath,
            };
        }
    }
    return nil;
}

- (nullable NSDictionary<NSString *, id> *)extendedPathMatchFromLeft:(NSString *)left
                                                               right:(NSString *)right
                                                          afterChunks:(NSArray<NSString *> *)afterChunks
                                                           startIndex:(NSInteger)startIndex
                                                 workingDirectoryIsOk:(BOOL)workingDirectoryIsOk
                                                            seenPaths:(NSMutableSet<NSString *> *)paths
                                                      whitespaceCharset:(NSCharacterSet *)whitespaceCharset
                                                   questionableSuffixes:(NSArray<NSString *> *)questionableSuffixes {
    NSMutableString *extendedRight = [right mutableCopy];
    NSInteger nextAfterChunkIndex = startIndex;
    NSInteger chunksAdded = 0;
    while (nextAfterChunkIndex < afterChunks.count && chunksAdded < iTermPathFinderMaxExtendedSuffixChunks) {
        if (self.canceled) {
            return nil;
        }
        [extendedRight appendString:afterChunks[nextAfterChunkIndex]];
        nextAfterChunkIndex++;
        chunksAdded++;

        NSString *trimmedPath = [left stringByAppendingString:extendedRight];
        if (_trimWhitespace) {
            trimmedPath = [trimmedPath stringByTrimmingCharactersInSet:whitespaceCharset];
        }
        if ([paths containsObject:trimmedPath]) {
            continue;
        }
        [paths addObject:[trimmedPath copy]];

        NSString *removeEscapingSlashes = @"\\\\([ \\(\\[\\]\\\\)])";
        trimmedPath = [trimmedPath stringByReplacingOccurrencesOfRegex:removeEscapingSlashes withString:@"$1"];

        NSDictionary *match = [self existingPathMatchForTrimmedPath:trimmedPath
                                               workingDirectoryIsOk:workingDirectoryIsOk
                                                questionableSuffixes:questionableSuffixes];
        if (match) {
            NSMutableDictionary *result = [match mutableCopy];
            result[@"right"] = [extendedRight copy];
            result[@"nextAfterChunkIndex"] = @(nextAfterChunkIndex);
            return result;
        }
    }
    return nil;
}

#pragma mark - Line Numbers

// Note that this can only see stuff *after* the filename.
- (NSString *)columnAndLineNumberFromChunks:(NSArray<NSString *> *)afterChunks {
    NSString *suffix = [afterChunks componentsJoinedByString:@""];
    NSArray<NSString *> *regexes = @[ @"^(:\\d+:\\d+)",
                                      @"^(:\\d+)",
                                      @"^(\\[\\d+, ?\\d+])",
                                      @"^(\", line \\d+, column \\d+)",
                                      @"^(\", line \\d+, in)",
                                      @"^(\\(\\d+, ?\\d+\\))",
                                      @"^(\\(\\d+\\))",
                                      @"^( line \\d+:$)"];
    // NOTE: If you change this also update regexes in iTermPathCleaner.
    for (NSString *regex in regexes) {
        NSString *value = [suffix stringByMatching:regex capture:1];
        if (value) {
            return value;
        }
    }
    return @"";
}

@end
