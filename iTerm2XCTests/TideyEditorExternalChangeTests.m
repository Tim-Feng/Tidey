#import <XCTest/XCTest.h>

#import "TideyEditorExternalChangeWatcher.h"

@interface TideyEditorExternalChangeTests : XCTestCase
@end

@implementation TideyEditorExternalChangeTests

static NSString *TideyMakeTempDir(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"tidey-editor-watch-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

static NSString *TideyWriteFile(NSString *dir, NSString *name, NSString *content) {
    NSString *path = [dir stringByAppendingPathComponent:name];
    [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

- (void)testSelectingSaveableEditorTabStartsWatchingItsPath {
    TideyEditorExternalChangeWatcher *watcher = [[[TideyEditorExternalChangeWatcher alloc] init] autorelease];
    NSMutableArray<NSString *> *startedPaths = [NSMutableArray array];
    __block id startedToken = nil;
    watcher.startWatching = ^id(NSString *path) {
        [startedPaths addObject:path];
        startedToken = [[[NSObject alloc] init] autorelease];
        return startedToken;
    };

    NSString *rootPath = TideyMakeTempDir();
    NSString *filePath = TideyWriteFile(rootPath, @"current.txt", @"before");

    [watcher syncToPath:filePath];

    XCTAssertEqualObjects(startedPaths, @[ filePath ]);
    XCTAssertEqualObjects(watcher.watchedPath, filePath);
    XCTAssertEqualObjects(watcher.watchToken, startedToken);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testExternalChangeReloadsCurrentCleanTabFromDisk {
    TideyEditorExternalChangeWatcher *watcher = [[[TideyEditorExternalChangeWatcher alloc] init] autorelease];
    NSString *rootPath = TideyMakeTempDir();
    NSString *filePath = TideyWriteFile(rootPath, @"current.txt", @"before");
    __block NSString *appliedValue = nil;
    __block NSInteger startCallCount = 0;
    __block NSInteger stopCallCount = 0;

    watcher.startWatching = ^id(NSString *path) {
        startCallCount += 1;
        return [[[NSObject alloc] init] autorelease];
    };
    watcher.stopWatching = ^(id token) {
        stopCallCount += 1;
    };

    [watcher syncToPath:filePath];
    TideyWriteFile(rootPath, @"current.txt", @"after");

    [watcher handleExternalChangeForPath:filePath
                                   dirty:NO
                          currentContent:@"before"
                               didReload:^(NSString *newContent) {
        appliedValue = [newContent copy];
    }];

    XCTAssertEqualObjects(appliedValue, @"after");
    XCTAssertEqual(startCallCount, 2);
    XCTAssertEqual(stopCallCount, 1);
    XCTAssertEqualObjects(watcher.watchedPath, filePath);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testExternalChangeDoesNotClobberDirtyCurrentTab {
    TideyEditorExternalChangeWatcher *watcher = [[[TideyEditorExternalChangeWatcher alloc] init] autorelease];
    NSString *rootPath = TideyMakeTempDir();
    NSString *filePath = TideyWriteFile(rootPath, @"current.txt", @"before");
    __block NSString *appliedValue = nil;
    __block NSInteger startCallCount = 0;
    __block NSInteger stopCallCount = 0;

    watcher.startWatching = ^id(NSString *path) {
        startCallCount += 1;
        return [[[NSObject alloc] init] autorelease];
    };
    watcher.stopWatching = ^(id token) {
        stopCallCount += 1;
    };

    [watcher syncToPath:filePath];
    TideyWriteFile(rootPath, @"current.txt", @"after");

    [watcher handleExternalChangeForPath:filePath
                                   dirty:YES
                          currentContent:@"local edits"
                               didReload:^(NSString *newContent) {
        appliedValue = [newContent copy];
    }];

    XCTAssertNil(appliedValue);
    XCTAssertEqual(startCallCount, 2);
    XCTAssertEqual(stopCallCount, 1);
    XCTAssertEqualObjects(watcher.watchedPath, filePath);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testEditorFileWatcherRetargetsWhenSelectedTabPathChanges {
    TideyEditorExternalChangeWatcher *watcher = [[[TideyEditorExternalChangeWatcher alloc] init] autorelease];
    NSMutableArray<NSString *> *startedPaths = [NSMutableArray array];
    __block NSInteger stopCallCount = 0;
    __block id firstToken = nil;
    __block id lastStoppedToken = nil;

    watcher.startWatching = ^id(NSString *path) {
        [startedPaths addObject:path];
        id token = [[[NSObject alloc] init] autorelease];
        if (!firstToken) {
            firstToken = token;
        }
        return token;
    };
    watcher.stopWatching = ^(id token) {
        stopCallCount += 1;
        lastStoppedToken = token;
    };

    NSString *rootPath = TideyMakeTempDir();
    NSString *firstPath = TideyWriteFile(rootPath, @"first.txt", @"first");
    NSString *secondPath = TideyWriteFile(rootPath, @"second.txt", @"second");

    [watcher syncToPath:firstPath];
    [watcher syncToPath:secondPath];

    XCTAssertEqualObjects(startedPaths, (@[ firstPath, secondPath ]));
    XCTAssertEqual(stopCallCount, 1);
    XCTAssertEqualObjects(lastStoppedToken, firstToken);
    XCTAssertEqualObjects(watcher.watchedPath, secondPath);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

@end
