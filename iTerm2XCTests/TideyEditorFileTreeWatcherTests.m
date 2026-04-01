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

@interface TideyReloadResettingRootView : iTermRootTerminalView
@end

@implementation TideyReloadResettingRootView

- (void)reloadTideyEditorFileTree {
    [super reloadTideyEditorFileTree];
    NSScrollView *scrollView = [self valueForKey:@"tideyEditorFileTreeScrollView"];
    [[scrollView contentView] scrollToPoint:NSZeroPoint];
    [scrollView reflectScrolledClipView:[scrollView contentView]];
}

@end

static TideyReloadResettingRootView *TideyNewResettingFileTreeRootView(void) {
    return [[[TideyReloadResettingRootView alloc] initWithFrame:NSZeroRect
                                                         color:[NSColor blackColor]] autorelease];
}

static NSOutlineView *TideyFileTreeView(iTermRootTerminalView *view) {
    return [view valueForKey:@"tideyEditorFileTreeView"];
}

static NSScrollView *TideyFileTreeScrollView(iTermRootTerminalView *view) {
    return [view valueForKey:@"tideyEditorFileTreeScrollView"];
}

static TideyEditorFileNode *TideyTopLevelNodeNamed(iTermRootTerminalView *view, NSString *name) {
    TideyEditorFileNode *rootNode = [view valueForKey:@"tideyEditorFileTreeRootNode"];
    for (TideyEditorFileNode *child in [rootNode loadChildren]) {
        if ([child.displayName isEqualToString:name]) {
            return child;
        }
    }
    return nil;
}

static void TideyConfigureFileTreeScrollGeometry(iTermRootTerminalView *view) {
    NSScrollView *scrollView = TideyFileTreeScrollView(view);
    NSOutlineView *outlineView = TideyFileTreeView(view);
    scrollView.frame = NSMakeRect(0, 0, 240, 80);
    outlineView.frame = NSMakeRect(0, 0, 240, MAX(400, outlineView.rowHeight * MAX(1, outlineView.numberOfRows)));
}

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

- (void)testFileTreeReloadPreservesScrollPosition {
    TideyReloadResettingRootView *view = TideyNewResettingFileTreeRootView();
    NSString *rootPath = TideyMakeTemporaryDirectory();
    for (NSInteger i = 0; i < 40; i++) {
        TideyCreateFile(rootPath, [NSString stringWithFormat:@"file-%02ld.txt", (long)i]);
    }
    [view setValue:rootPath forKey:@"tideyEditorRootOverridePath"];
    [view reloadTideyEditorFileTree];
    TideyConfigureFileTreeScrollGeometry(view);

    NSScrollView *scrollView = TideyFileTreeScrollView(view);
    CGFloat expectedY = 120;
    [[scrollView contentView] scrollToPoint:NSMakePoint(0, expectedY)];
    [scrollView reflectScrolledClipView:[scrollView contentView]];

    TideyCreateFile(rootPath, @"new.txt");
    [view tideyHandleEditorFileTreeRootDidChange];

    CGFloat actualY = NSMinY([[scrollView contentView] bounds]);
    XCTAssertEqualWithAccuracy(actualY, expectedY, 0.5);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

- (void)testFileTreeReloadDoesNotReexpandSelectedCollapsedFolder {
    iTermRootTerminalView *view = TideyNewFileTreeRootView();
    NSString *rootPath = TideyMakeTemporaryDirectory();
    NSString *folderPath = [rootPath stringByAppendingPathComponent:@"Folder"];
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:folderPath
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:nil];
    XCTAssertTrue(created);
    TideyCreateFile(folderPath, @"child.txt");
    [view setValue:rootPath forKey:@"tideyEditorRootOverridePath"];
    [view reloadTideyEditorFileTree];

    NSOutlineView *outlineView = TideyFileTreeView(view);
    TideyEditorFileNode *folderNode = TideyTopLevelNodeNamed(view, @"Folder");
    XCTAssertNotNil(folderNode);
    [outlineView expandItem:folderNode];
    NSInteger folderRow = [outlineView rowForItem:folderNode];
    XCTAssertNotEqual(folderRow, -1);
    [outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:folderRow] byExtendingSelection:NO];
    [outlineView collapseItem:folderNode];
    XCTAssertFalse([outlineView isItemExpanded:folderNode]);

    TideyCreateFile(rootPath, @"peer.txt");
    [view tideyHandleEditorFileTreeRootDidChange];

    folderNode = TideyTopLevelNodeNamed(view, @"Folder");
    XCTAssertNotNil(folderNode);
    XCTAssertFalse([outlineView isItemExpanded:folderNode]);
    TideyEditorFileNode *selectedNode = [outlineView itemAtRow:outlineView.selectedRow];
    XCTAssertEqualObjects(selectedNode.path, folderNode.path);

    [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
}

@end
