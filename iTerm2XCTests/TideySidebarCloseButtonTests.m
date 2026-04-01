#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"
#import "TideyNotificationStore.h"

@interface TideySidebarTableView : NSTableView
- (BOOL)tideyShouldShowCloseButtonForRow:(NSInteger)row;
- (void)updateTideyCloseButtonVisibility;
@end

@interface iTermRootTerminalView (TideySidebarCloseButtonTests)
- (NSTableCellView *)newTideySidebarCellView;
- (void)configureTideySidebarCellView:(NSTableCellView *)cellView row:(NSInteger)row;
@end

@interface TideyTestSidebarTableView : TideySidebarTableView
@property(nonatomic) NSInteger forcedHoveredRow;
@property(nonatomic) NSInteger tideyVisibleRowCount;
@property(nonatomic, retain) NSMutableDictionary<NSNumber *, NSTableCellView *> *cellsByRow;
@end

@implementation TideyTestSidebarTableView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _forcedHoveredRow = -1;
        _cellsByRow = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_cellsByRow release];
    [super dealloc];
}

- (NSInteger)tideyHoveredRowForCurrentMouseLocation {
    return self.forcedHoveredRow;
}

- (NSTableCellView *)viewAtColumn:(NSInteger)column row:(NSInteger)row makeIfNecessary:(BOOL)makeIfNecessary {
    return self.cellsByRow[@(row)];
}

- (NSRange)rowsInRect:(NSRect)rect {
    return NSMakeRange(0, self.tideyVisibleRowCount);
}

@end

@interface TideySidebarCloseButtonTestRootView : iTermRootTerminalView
@property(nonatomic, retain) NSArray<NSString *> *testWorkspaceIDs;
@property(nonatomic, retain) NSArray<NSString *> *testTitles;
@property(nonatomic, retain) NSArray<NSString *> *testSubtitles;
@property(nonatomic) NSInteger testSelectedWorkspaceIndex;
@end

@implementation TideySidebarCloseButtonTestRootView

- (void)dealloc {
    [_testWorkspaceIDs release];
    [_testTitles release];
    [_testSubtitles release];
    [super dealloc];
}

- (NSInteger)numberOfTideySidebarWorkspaces {
    return self.testWorkspaceIDs.count;
}

- (NSString *)tideySidebarWorkspaceIdentifierAtIndex:(NSInteger)index {
    return self.testWorkspaceIDs[index];
}

- (NSString *)tideySidebarWorkspaceTitleAtIndex:(NSInteger)index {
    return self.testTitles[index];
}

- (NSString *)tideySidebarWorkspaceSubtitleAtIndex:(NSInteger)index {
    return self.testSubtitles[index];
}

- (BOOL)tideySidebarWorkspacePinnedAtIndex:(NSInteger)index {
    return NO;
}

- (NSInteger)tideySidebarSelectedWorkspaceIndex {
    return self.testSelectedWorkspaceIndex;
}

@end

static NSView *TideySidebarCloseView(NSTableCellView *cellView) {
    for (NSView *subview in cellView.subviews) {
        if ([subview.identifier isEqualToString:@"TideySidebarCloseView"]) {
            return subview;
        }
    }
    return nil;
}

static NSString *TideyUniqueWorkspaceID(void) {
    return NSUUID.UUID.UUIDString;
}

static TideySidebarCloseButtonTestRootView *TideyNewSidebarRootView(void) {
    TideySidebarCloseButtonTestRootView *view =
        [[[TideySidebarCloseButtonTestRootView alloc] initWithFrame:NSZeroRect
                                                              color:[NSColor blackColor]] autorelease];
    view.testSelectedWorkspaceIndex = -1;
    return view;
}

@interface TideySidebarCloseButtonTests : XCTestCase
@end

@implementation TideySidebarCloseButtonTests

- (void)setUp {
    [super setUp];
    [[TideyNotificationStore sharedStore] clearAllNotifications];
}

- (void)testHoveredRowKeepsCloseButtonVisibleAfterSelectionChange {
    TideySidebarCloseButtonTestRootView *view = TideyNewSidebarRootView();
    NSString *workspaceID = TideyUniqueWorkspaceID();
    view.testWorkspaceIDs = @[ workspaceID ];
    view.testTitles = @[ @"Workspace" ];
    view.testSubtitles = @[ @"~/project" ];

    TideyTestSidebarTableView *tableView =
        [[[TideyTestSidebarTableView alloc] initWithFrame:NSMakeRect(0, 0, 220, 60)] autorelease];
    tableView.forcedHoveredRow = 0;
    tableView.tideyVisibleRowCount = 1;
    [view setValue:tableView forKey:@"tideySidebarTableView"];

    NSTableCellView *cellView = [view newTideySidebarCellView];
    cellView.frame = NSMakeRect(0, 0, 220, 60);
    tableView.cellsByRow[@0] = cellView;

    [view configureTideySidebarCellView:cellView row:0];
    [tableView updateTideyCloseButtonVisibility];

    NSView *closeView = TideySidebarCloseView(cellView);
    XCTAssertNotNil(closeView);
    XCTAssertFalse(closeView.hidden);
    XCTAssertEqualWithAccuracy(closeView.alphaValue, 1.0, 0.001);

    view.testSelectedWorkspaceIndex = 0;
    [view configureTideySidebarCellView:cellView row:0];
    [tableView updateTideyCloseButtonVisibility];

    XCTAssertFalse(closeView.hidden);
    XCTAssertEqualWithAccuracy(closeView.alphaValue, 1.0, 0.001);
}

- (void)testCloseButtonVerticalPositionIsFixedAcrossRowLayouts {
    TideySidebarCloseButtonTestRootView *view = TideyNewSidebarRootView();
    NSString *plainWorkspaceID = TideyUniqueWorkspaceID();
    NSString *richWorkspaceID = TideyUniqueWorkspaceID();
    view.testWorkspaceIDs = @[ plainWorkspaceID, richWorkspaceID ];
    view.testTitles = @[ @"Plain", @"Rich" ];
    view.testSubtitles = @[ @"~/plain", @"~/rich" ];

    TideyTestSidebarTableView *tableView =
        [[[TideyTestSidebarTableView alloc] initWithFrame:NSMakeRect(0, 0, 220, 82)] autorelease];
    tableView.forcedHoveredRow = -1;
    tableView.tideyVisibleRowCount = 2;
    [view setValue:tableView forKey:@"tideySidebarTableView"];

    [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:richWorkspaceID
                                                                  title:@"Build failed"
                                                               subtitle:@""
                                                                   body:@"Long notification body"];
    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:richWorkspaceID
                                                        key:@"shell"
                                                      value:@"Running"
                                                       icon:nil
                                                   colorHex:nil];

    NSTableCellView *plainCell = [view newTideySidebarCellView];
    plainCell.frame = NSMakeRect(0, 0, 220, 60);
    tableView.cellsByRow[@0] = plainCell;
    [view configureTideySidebarCellView:plainCell row:0];

    NSTableCellView *richCell = [view newTideySidebarCellView];
    richCell.frame = NSMakeRect(0, 0, 220, 82);
    tableView.cellsByRow[@1] = richCell;
    [view configureTideySidebarCellView:richCell row:1];

    NSView *plainCloseView = TideySidebarCloseView(plainCell);
    NSView *richCloseView = TideySidebarCloseView(richCell);
    XCTAssertNotNil(plainCloseView);
    XCTAssertNotNil(richCloseView);

    CGFloat plainTopInset = NSHeight(plainCell.bounds) - NSMaxY(plainCloseView.frame);
    CGFloat richTopInset = NSHeight(richCell.bounds) - NSMaxY(richCloseView.frame);
    XCTAssertEqualWithAccuracy(plainTopInset, richTopInset, 0.001);
    XCTAssertEqualWithAccuracy(plainTopInset, 10.0, 0.001);

    [[TideyStatusStore sharedStore] clearStatusForWorkspaceID:richWorkspaceID key:@"shell"];
}

@end
