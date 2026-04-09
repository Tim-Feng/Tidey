#import <XCTest/XCTest.h>

#import "iTermPathFinder.h"

#include <stdlib.h>
#include <string.h>

@interface iTermPathFinderTests : XCTestCase
@end

@implementation iTermPathFinderTests

- (void)testSearchFindsRelativePathWithSpacesByExtendingSuffixChunks {
    NSString *root = [self temporaryDirectory];
    NSString *relativePath = @"thoughts/raw/Agent-native Architectures.md";
    NSString *fullPath = [root stringByAppendingPathComponent:relativePath];
    [self createFileAtPath:fullPath];

    iTermPathFinder *finder = [[iTermPathFinder alloc] initWithPrefix:@"thoughts/raw/Agent-native"
                                                               suffix:@" Architectures.md"
                                                     workingDirectory:root
                                                       trimWhitespace:YES
                                                               ignore:@""
                                                   allowNetworkMounts:NO];
    [finder searchSynchronously];

    XCTAssertEqualObjects(finder.path, relativePath);
}

- (void)testSearchStillFindsRelativePathWithoutSpaces {
    NSString *root = [self temporaryDirectory];
    NSString *relativePath = @"thoughts/raw/architectures.md";
    NSString *fullPath = [root stringByAppendingPathComponent:relativePath];
    [self createFileAtPath:fullPath];

    iTermPathFinder *finder = [[iTermPathFinder alloc] initWithPrefix:@"thoughts/raw/architectures"
                                                               suffix:@".md"
                                                     workingDirectory:root
                                                       trimWhitespace:YES
                                                               ignore:@""
                                                   allowNetworkMounts:NO];
    [finder searchSynchronously];

    XCTAssertEqualObjects(finder.path, relativePath);
}

- (NSString *)temporaryDirectory {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iterm-pathfinder-tests.XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    char *result = mkdtemp(buffer);
    NSString *directory = result ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:result
                                                                                                 length:strlen(result)] : nil;
    free(buffer);
    XCTAssertNotNil(directory);
    return directory;
}

- (void)createFileAtPath:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    XCTAssertTrue([fileManager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:nil]);
    XCTAssertTrue([fileManager createFileAtPath:path
                                       contents:[NSData data]
                                     attributes:nil]);
}

@end
