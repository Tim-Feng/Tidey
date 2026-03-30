#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"
#import "SCEvents.h"

@interface TideyEditorFileNode : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic) BOOL directory;
@property(nonatomic) BOOL childrenLoaded;
@property(nonatomic, retain) NSArray<TideyEditorFileNode *> *children;
- (NSArray<TideyEditorFileNode *> *)loadChildren;
@end

@interface TideyTestSCEvents : SCEvents
@property(nonatomic, copy) NSArray<NSString *> *lastStartedPaths;
@property(nonatomic) NSInteger startCallCount;
@property(nonatomic) NSInteger stopCallCount;
@end

@implementation TideyTestSCEvents

- (BOOL)startWatchingPaths:(NSArray *)paths {
    self.lastStartedPaths = paths;
    self.startCallCount += 1;
    return YES;
}

- (BOOL)stopWatchingPaths {
    self.stopCallCount += 1;
    return YES;
}

@end

@interface iTermRootTerminalView (TideyEditorFileTreeWatcherTests)
- (void)reloadTideyEditorFileTree;
- (void)tideySyncEditorFileTreeWatcher;
- (void)tideyHandleEditorFileTreeRootDidChange;
@end

static iTermRootTerminalView *TideyNewFileTreeRootView(void) {
    return [[[iTermRootTerminalView alloc] initWithFrame:NSZeroRect
                                                   color:[NSColor blackColor]] autorelease];
}

static NSString *TideyMakeTemporaryDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tidey-file-tree-%@", NSUUID.UUID.UUIDString]];
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:path
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:nil];
    XCTAssertTrue(created);
    return path;
}

static void TideyCreateFile(NSString *directory, NSString *name) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    BOOL created = [[NSFileManager defaultManager] createFileAtPath:path
                                                           contents:[NSData data]
                                                         attributes:nil];
    XCTAssertTrue(created);
}

static NSArray<NSString *> *TideyChildDisplayNames(iTermRootTerminalView *view) {
    TideyEditorFileNode *rootNode = [view valueForKey:@"tideyEditorFileTreeRootNode"];
    NSArray<TideyEditorFileNode *> *children = [rootNode loadChildren];
    return [children valueForKey:@"displayName"];
}

@interface TideyEditorFileTreeWatcherTests : XCTestCase
@end

@implementation TideyEditorFileTreeWatcherTests

- (void)testSyncEditorFileTreeWatcherStartsWatchingCurrentRootPath {
    iTermRootTerminalView *view = TideyNewFileTreeRootView();
    TideyTestSCEvents *watcher = [[[TideyTestSCEvents alloc] init] autorelease];
    NSString *rootPath = TideyMakeTemporaryDirectory();
    [view setValue:rootPath forKey:@"tideyEditorRootOverridePath"];
    [view setValue:@YES forKey:@"shouldShowTideyEditorPanel"];
    [view setValue:@YES forKey:@"shouldShowTideyEditorFileTree"];
    [view setValue:watcher forKey:@"tideyEditorFileTreeWatcher"];

    [view tideySyncEditorFileTreeWatcher];

    XCTAssertEqual(watcher.startCallCount, 1);
    XCTAssertEqual(watcher.stopCallCount, 0);
    XCTAssertEqualObjects(watcher.lastStartedPaths, @[ rootPath ]);
    XCTAssertEqualObjects([view valueForKey:@"tideyEditorFileTreeWatchedRootPath"], rootPath);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testFileTreeReloadsWhenWatchedRootAddsFile {
    iTermRootTerminalView *view = TideyNewFileTreeRootView();
    NSString *rootPath = TideyMakeTemporaryDirectory();
    TideyCreateFile(rootPath, @"existing.txt");
    [view setValue:rootPath forKey:@"tideyEditorRootOverridePath"];
    [view reloadTideyEditorFileTree];

    XCTAssertEqualObjects(TideyChildDisplayNames(view), @[ @"existing.txt" ]);

    TideyCreateFile(rootPath, @"new.txt");
    [view tideyHandleEditorFileTreeRootDidChange];

    XCTAssertEqualObjects(TideyChildDisplayNames(view), (@[ @"existing.txt", @"new.txt" ]));

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testFileTreeReloadsWhenWatchedRootDeletesFile {
    iTermRootTerminalView *view = TideyNewFileTreeRootView();
    NSString *rootPath = TideyMakeTemporaryDirectory();
    TideyCreateFile(rootPath, @"delete-me.txt");
    TideyCreateFile(rootPath, @"keep.txt");
    [view setValue:rootPath forKey:@"tideyEditorRootOverridePath"];
    [view reloadTideyEditorFileTree];

    XCTAssertEqualObjects(TideyChildDisplayNames(view), (@[ @"delete-me.txt", @"keep.txt" ]));

    NSString *deletedPath = [rootPath stringByAppendingPathComponent:@"delete-me.txt"];
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:deletedPath error:nil];
    XCTAssertTrue(removed);
    [view tideyHandleEditorFileTreeRootDidChange];

    XCTAssertEqualObjects(TideyChildDisplayNames(view), @[ @"keep.txt" ]);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testFileTreeWatcherRetargetsWhenRootPathChanges {
    iTermRootTerminalView *view = TideyNewFileTreeRootView();
    TideyTestSCEvents *watcher = [[[TideyTestSCEvents alloc] init] autorelease];
    NSString *firstRoot = TideyMakeTemporaryDirectory();
    NSString *secondRoot = TideyMakeTemporaryDirectory();
    [view setValue:@YES forKey:@"shouldShowTideyEditorPanel"];
    [view setValue:@YES forKey:@"shouldShowTideyEditorFileTree"];
    [view setValue:watcher forKey:@"tideyEditorFileTreeWatcher"];
    [view setValue:firstRoot forKey:@"tideyEditorRootOverridePath"];

    [view reloadTideyEditorFileTree];
    XCTAssertEqualObjects(watcher.lastStartedPaths, @[ firstRoot ]);
    XCTAssertEqual(watcher.startCallCount, 1);

    [view setValue:secondRoot forKey:@"tideyEditorRootOverridePath"];
    [view reloadTideyEditorFileTree];

    XCTAssertEqual(watcher.stopCallCount, 1);
    XCTAssertEqual(watcher.startCallCount, 2);
    XCTAssertEqualObjects(watcher.lastStartedPaths, @[ secondRoot ]);
    XCTAssertEqualObjects([view valueForKey:@"tideyEditorFileTreeWatchedRootPath"], secondRoot);

    [[NSFileManager defaultManager] removeItemAtPath:firstRoot error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:secondRoot error:nil];
}

@end
