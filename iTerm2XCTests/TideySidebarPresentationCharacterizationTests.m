#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"
#import "TideyNotificationStore.h"
#import "TideySidebarRowPresentation.h"
#import "TideySidebarViews.h"
#import "iTerm2SharedARC-Swift.h"

@interface iTermRootTerminalView (TideySidebarPresentationCharacterizationTests)
- (NSTableCellView *)newTideySidebarCellView;
+ (NSTableViewStyle)tideySidebarTableStyleForWarmTheme:(BOOL)warm;
+ (CGFloat)tideySidebarMinimumWidthForWarmTheme:(BOOL)warm;
+ (NSColor *)tideySidebarTableBackgroundOverrideColorForWarmTheme:(BOOL)warm;
+ (NSTableViewSelectionHighlightStyle)tideySidebarSelectionHighlightStyleForWarmTheme:(BOOL)warm;
- (void)configureTideySidebarCellView:(NSTableCellView *)cellView row:(NSInteger)row;
- (TideySidebarRowPresentation *)tideySidebarRowPresentationAtIndex:(NSInteger)row;
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row;
@end

@interface TideyCharacterizationSidebarTableView : TideySidebarTableView
@property(nonatomic) NSInteger forcedHoveredRow;
@property(nonatomic) NSInteger tideyVisibleRowCount;
@property(nonatomic, retain) NSMutableDictionary<NSNumber *, NSTableCellView *> *cellsByRow;
@end

@implementation TideyCharacterizationSidebarTableView

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

- (NSTableCellView *)viewAtColumn:(NSInteger)column
                              row:(NSInteger)row
                  makeIfNecessary:(BOOL)makeIfNecessary {
    return self.cellsByRow[@(row)];
}

- (NSRange)rowsInRect:(NSRect)rect {
    return NSMakeRange(0, self.tideyVisibleRowCount);
}

@end

@interface TideySidebarPresentationTestRootView : iTermRootTerminalView
@property(nonatomic, retain) NSArray<NSString *> *testWorkspaceIDs;
@property(nonatomic, retain) NSArray<NSString *> *testTitles;
@property(nonatomic, retain) NSArray<NSString *> *testSubtitles;
@property(nonatomic, retain) NSArray<NSNumber *> *testPinnedValues;
@property(nonatomic) NSInteger testSelectedWorkspaceIndex;
@end

@implementation TideySidebarPresentationTestRootView

- (void)dealloc {
    [_testWorkspaceIDs release];
    [_testTitles release];
    [_testSubtitles release];
    [_testPinnedValues release];
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
    return self.testPinnedValues[index].boolValue;
}

- (NSInteger)tideySidebarSelectedWorkspaceIndex {
    return self.testSelectedWorkspaceIndex;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.testWorkspaceIDs.count;
}

@end


static NSString *TideyCharacterizationWorkspaceID(void) {
    return NSUUID.UUID.UUIDString;
}

static TideySidebarPresentationTestRootView *TideyNewPresentationRootView(NSArray<NSString *> *titles,
                                                                          NSArray<NSString *> *subtitles,
                                                                          NSArray<NSNumber *> *pinnedValues) {
    TideySidebarPresentationTestRootView *view =
        [[TideySidebarPresentationTestRootView alloc] initWithFrame:NSZeroRect];
    NSMutableArray<NSString *> *workspaceIDs = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSInteger index = 0; index < titles.count; index++) {
        [workspaceIDs addObject:TideyCharacterizationWorkspaceID()];
    }
    view.testWorkspaceIDs = workspaceIDs;
    view.testTitles = titles;
    view.testSubtitles = subtitles;
    view.testPinnedValues = pinnedValues;
    view.testSelectedWorkspaceIndex = -1;
    return view;
}

static TideyCharacterizationSidebarTableView *TideyInstallPresentationTable(
    TideySidebarPresentationTestRootView *view,
    CGFloat width,
    CGFloat height,
    NSInteger hoveredRow) {
    TideyCharacterizationSidebarTableView *tableView =
        [[[TideyCharacterizationSidebarTableView alloc]
            initWithFrame:NSMakeRect(0, 0, width, height)] autorelease];
    tableView.forcedHoveredRow = hoveredRow;
    tableView.tideyVisibleRowCount = view.testWorkspaceIDs.count;
    [view setValue:tableView forKey:@"tideySidebarTableView"];
    return tableView;
}

static NSTableCellView *TideyConfiguredPresentationCell(TideySidebarPresentationTestRootView *view,
                                                         TideyCharacterizationSidebarTableView *tableView,
                                                         NSInteger row,
                                                         CGFloat width,
                                                         CGFloat height) {
    NSTableCellView *cellView = [view newTideySidebarCellView];
    cellView.frame = NSMakeRect(0, 0, width, height);
    tableView.cellsByRow[@(row)] = cellView;
    [view configureTideySidebarCellView:cellView row:row];
    cellView.needsLayout = YES;
    [cellView layoutSubtreeIfNeeded];
    return cellView;
}

static NSDictionary<NSString *, NSValue *> *TideyLaidOutSidebarGeometry(BOOL warm) {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = warm ? @"warm" : @"classic";
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Workspace" ], @[ @"~/project" ], @[ @NO ]);
    TideySidebarTableView *tableView = [[[TideySidebarTableView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, 120)] autorelease];
    tableView.delegate = view;
    tableView.dataSource = view;
    tableView.headerView = nil;
    tableView.intercellSpacing = NSMakeSize(0, 0);
    tableView.rowHeight = 60;
    if (@available(macOS 11.0, *)) {
        tableView.style = [iTermRootTerminalView tideySidebarTableStyleForWarmTheme:warm];
    }
    tableView.selectionHighlightStyle =
        [iTermRootTerminalView tideySidebarSelectionHighlightStyleForWarmTheme:warm];
    NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:@"Sidebar"] autorelease];
    column.width = 200;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [tableView addTableColumn:column];
    [view setValue:tableView forKey:@"tideySidebarTableView"];

    NSScrollView *scrollView = [[[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, 120)] autorelease];
    scrollView.drawsBackground = NO;
    scrollView.documentView = tableView;
    NSWindow *window = [[[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 200, 120)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView)
                    backing:NSBackingStoreBuffered
                      defer:NO] autorelease];
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    scrollView.frame = window.contentView.bounds;
    [window.contentView addSubview:scrollView];
    [tableView reloadData];
    [window.contentView layoutSubtreeIfNeeded];
    [scrollView layoutSubtreeIfNeeded];
    [tableView layoutSubtreeIfNeeded];

    NSTableRowView *rowView = [tableView rowViewAtRow:0 makeIfNecessary:YES];
    NSTableCellView *cellView = [tableView viewAtColumn:0 row:0 makeIfNecessary:YES];
    XCTAssertNotNil(rowView);
    XCTAssertNotNil(cellView);
    [cellView layoutSubtreeIfNeeded];
    NSRect rowRect = [rowView convertRect:rowView.bounds toView:tableView];
    NSRect cellRect = [cellView convertRect:cellView.bounds toView:tableView];
    NSRect titleRect = [cellView convertRect:cellView.textField.frame toView:tableView];
    NSRect visibleRowRect = [rowView convertRect:rowView.bounds toView:scrollView];
    NSRect visibleCellRect = [cellView convertRect:cellView.bounds toView:scrollView];
    NSRect visibleTitleRect = [cellView convertRect:cellView.textField.frame toView:scrollView];
    NSRect windowRowRect = [rowView convertRect:rowView.bounds toView:window.contentView];
    NSRect windowCellRect = [cellView convertRect:cellView.bounds toView:window.contentView];
    NSRect windowTitleRect = [cellView convertRect:cellView.textField.frame toView:window.contentView];
    NSInteger rowAtCenter = [tableView rowAtPoint:NSMakePoint(NSMidX(rowRect), NSMidY(rowRect))];
    NSInteger rowAboveFirst = [tableView rowAtPoint:NSMakePoint(NSMidX(rowRect), NSMinY(rowRect) - 1)];
    NSRange rowsAtCenter = [tableView rowsInRect:NSMakeRect(NSMinX(rowRect), NSMidY(rowRect), 1, 1)];
    NSRange rowsAboveFirst = [tableView rowsInRect:NSMakeRect(NSMinX(rowRect), NSMinY(rowRect) - 1, 1, 1)];
    NSRange visibleRows = [tableView rowsInRect:tableView.visibleRect];
    return @{
        @"row": [NSValue valueWithRect:rowRect],
        @"cell": [NSValue valueWithRect:cellRect],
        @"title": [NSValue valueWithRect:titleRect],
        @"visibleRow": [NSValue valueWithRect:visibleRowRect],
        @"visibleCell": [NSValue valueWithRect:visibleCellRect],
        @"visibleTitle": [NSValue valueWithRect:visibleTitleRect],
        @"windowRow": [NSValue valueWithRect:windowRowRect],
        @"windowCell": [NSValue valueWithRect:windowCellRect],
        @"windowTitle": [NSValue valueWithRect:windowTitleRect],
        @"rowAtCenter": @(rowAtCenter),
        @"rowAboveFirst": @(rowAboveFirst),
        @"rowsAtCenter": [NSValue valueWithRange:rowsAtCenter],
        @"rowsAboveFirst": [NSValue valueWithRange:rowsAboveFirst],
        @"visibleRows": [NSValue valueWithRange:visibleRows],
    };
}

static NSView *TideyPresentationSubview(NSTableCellView *cellView, NSString *identifier) {
    for (NSView *subview in cellView.subviews) {
        if ([subview.identifier isEqualToString:identifier]) {
            return subview;
        }
    }
    return nil;
}

static NSTextField *TideyPresentationTextField(NSTableCellView *cellView, NSInteger tag) {
    return (NSTextField *)[cellView viewWithTag:tag];
}

static void TideyAssertRect(NSRect actual, NSRect expected) {
    XCTAssertTrue(NSEqualRects(actual, expected),
                  @"Expected %@ but got %@",
                  NSStringFromRect(expected),
                  NSStringFromRect(actual));
}

static void TideyAssertFont(NSFont *actual, NSFont *expected) {
    XCTAssertEqualWithAccuracy(actual.pointSize, expected.pointSize, 0.001);
    NSDictionary *actualTraits = actual.fontDescriptor.fontAttributes[NSFontTraitsAttribute];
    NSDictionary *expectedTraits = expected.fontDescriptor.fontAttributes[NSFontTraitsAttribute];
    XCTAssertEqualObjects(actualTraits[NSFontWeightTrait], expectedTraits[NSFontWeightTrait]);
}

static void TideyAssertColor(NSColor *actual, NSColor *expected, NSAppearance *appearance) {
    __block NSColor *resolvedActual = nil;
    __block NSColor *resolvedExpected = nil;
    [appearance performAsCurrentDrawingAppearance:^{
        resolvedActual = [actual colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        resolvedExpected = [expected colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    XCTAssertNotNil(resolvedActual);
    XCTAssertNotNil(resolvedExpected);
    XCTAssertEqualWithAccuracy(resolvedActual.redComponent, resolvedExpected.redComponent, 0.001);
    XCTAssertEqualWithAccuracy(resolvedActual.greenComponent, resolvedExpected.greenComponent, 0.001);
    XCTAssertEqualWithAccuracy(resolvedActual.blueComponent, resolvedExpected.blueComponent, 0.001);
    XCTAssertEqualWithAccuracy(resolvedActual.alphaComponent, resolvedExpected.alphaComponent, 0.001);
}

@interface TideySidebarPresentationCharacterizationTests : XCTestCase
@property(nonatomic, retain) id priorInterfaceThemeValue;
@end

@implementation TideySidebarPresentationCharacterizationTests

- (void)setUp {
    [super setUp];
    self.priorInterfaceThemeValue = [[NSUserDefaults standardUserDefaults]
        objectForKey:TideyInterfaceThemeController.defaultsKey];
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"classic";
    [[TideyNotificationStore sharedStore] clearAllNotifications];
    [self clearCharacterizationStatuses];
}

- (void)tearDown {
    [[TideyNotificationStore sharedStore] clearAllNotifications];
    [self clearCharacterizationStatuses];
    if (self.priorInterfaceThemeValue) {
        [[NSUserDefaults standardUserDefaults] setObject:self.priorInterfaceThemeValue
                                                  forKey:TideyInterfaceThemeController.defaultsKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:TideyInterfaceThemeController.defaultsKey];
    }
    self.priorInterfaceThemeValue = nil;
    [super tearDown];
}

- (void)clearCharacterizationStatuses {
    TideyStatusStore *store = [TideyStatusStore sharedStore];
    for (NSString *workspaceID in store.allWorkspaceIDs) {
        [store clearStatusForWorkspaceID:workspaceID key:@"shell"];
        [store clearStatusForWorkspaceID:workspaceID key:@"review"];
    }
}

- (void)testPlainRowsPreserveGeometryTypographyAndColorsAcrossWidthsAndTitles {
    NSArray<NSString *> *titles = @[
        @"Short",
        @"A workspace title that is intentionally much longer than the sidebar",
        @"備課／共讀",
        @"Workspace Four",
        @"Workspace Five",
        @"Workspace Six",
        @"第七個工作空間",
    ];
    NSArray<NSString *> *subtitles = @[
        @"~/short", @"~/a/very/long/project/path", @"~/備課", @"~/four", @"~/five", @"~/six", @"~/seven",
    ];
    NSArray<NSNumber *> *pinnedValues = @[ @NO, @NO, @NO, @NO, @NO, @NO, @NO ];
    NSArray<NSAppearanceName> *appearances = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];

    for (NSNumber *widthValue in @[ @160, @200, @320 ]) {
        const CGFloat width = widthValue.doubleValue;
        for (NSAppearanceName appearanceName in appearances) {
            NSAppearance *appearance = [NSAppearance appearanceNamed:appearanceName];
            TideySidebarPresentationTestRootView *view =
                TideyNewPresentationRootView(titles, subtitles, pinnedValues);
            view.appearance = appearance;
            TideyCharacterizationSidebarTableView *tableView =
                TideyInstallPresentationTable(view, width, 420, -1);
            NSTableCellView *cellView = TideyConfiguredPresentationCell(view, tableView, 6, width, 60);

            NSTextField *titleField = cellView.textField;
            NSTextField *subtitleField = TideyPresentationTextField(cellView, 1002);
            NSTextField *bodyField = TideyPresentationTextField(cellView, 1007);
            NSTextField *statusField = TideyPresentationTextField(cellView, 1008);
            NSView *badgeView = TideyPresentationSubview(cellView, @"TideySidebarBadgeView");
            NSImageView *pinView = (NSImageView *)[cellView viewWithTag:1003];
            NSView *closeView = TideyPresentationSubview(cellView, @"TideySidebarCloseView");

            XCTAssertEqualObjects(cellView.identifier, @"TideySidebarSessionCell");
            XCTAssertEqualObjects(titleField.stringValue, @"第七個工作空間");
            XCTAssertEqualObjects(subtitleField.stringValue, @"~/seven");
            TideyAssertRect(titleField.frame, NSMakeRect(8, 30, width - 56, 14));
            TideyAssertRect(subtitleField.frame, NSMakeRect(8, 12, width - 16, 14));
            TideyAssertFont(titleField.font, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]);
            TideyAssertFont(subtitleField.font, [NSFont systemFontOfSize:11 weight:NSFontWeightRegular]);
            TideyAssertColor(titleField.textColor, NSColor.whiteColor, appearance);
            TideyAssertColor(subtitleField.textColor,
                             [NSColor colorWithWhite:0.72 alpha:1],
                             appearance);
            XCTAssertTrue(bodyField.hidden);
            XCTAssertTrue(statusField.hidden);
            XCTAssertTrue(badgeView.hidden);
            XCTAssertTrue(pinView.hidden);
            XCTAssertTrue(closeView.hidden);
            XCTAssertTrue(titleField.translatesAutoresizingMaskIntoConstraints);
            XCTAssertTrue(subtitleField.translatesAutoresizingMaskIntoConstraints);
        }
    }
}

- (void)testWarmRowsPreserveProductionTypographyGeometryAndSemanticStatusColors {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Running workspace", @"Idle workspace" ],
                                     @[ @"~/running", @"~/idle" ],
                                     @[ @NO, @NO ]);
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 304, 120, -1);
    NSString *runningWorkspaceID = view.testWorkspaceIDs[0];
    NSString *idleWorkspaceID = view.testWorkspaceIDs[1];
    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:runningWorkspaceID
                                                       key:@"shell"
                                                     value:@"Running"
                                                      icon:@"bolt.fill"
                                                  colorHex:@"#007AFF"];
    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:idleWorkspaceID
                                                       key:@"shell"
                                                     value:@"Idle"
                                                      icon:@"pause.circle.fill"
                                                  colorHex:@"#007AFF"];

    NSTableCellView *runningCell = TideyConfiguredPresentationCell(view, tableView, 0, 304, 60);
    NSTableCellView *idleCell = TideyConfiguredPresentationCell(view, tableView, 1, 304, 60);
    NSTextField *runningSubtitle = TideyPresentationTextField(runningCell, 1002);
    NSTextField *runningStatus = TideyPresentationTextField(runningCell, 1008);
    NSTextField *idleStatus = TideyPresentationTextField(idleCell, 1008);
    NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    TideyAssertFont(runningCell.textField.font,
                    [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]);
    TideyAssertFont(runningSubtitle.font,
                    [NSFont systemFontOfSize:11 weight:NSFontWeightRegular]);
    TideyAssertFont(runningStatus.font,
                    [NSFont systemFontOfSize:10 weight:NSFontWeightRegular]);
    TideyAssertRect(runningCell.textField.frame, NSMakeRect(8, 38, 248, 14));
    TideyAssertRect(runningSubtitle.frame, NSMakeRect(8, 22, 288, 14));
    TideyAssertRect(runningStatus.frame, NSMakeRect(8, 6, 288, 12));
    TideyAssertColor(runningCell.textField.textColor,
                     TideyInterfaceThemeController.shared.currentTokens.sidebarPrimaryTextColor,
                     appearance);
    TideyAssertColor(runningStatus.textColor,
                     TideyInterfaceThemeController.shared.currentTokens.sidebarRunningColor,
                     appearance);
    TideyAssertColor(idleStatus.textColor,
                     TideyInterfaceThemeController.shared.currentTokens.sidebarIdleColor,
                     appearance);
}

- (void)testWarmSelectedRowUsesSharpFocusTextHierarchyWithoutChangingStatusSemantics {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Selected workspace", @"Normal workspace" ],
                                     @[ @"~/selected", @"~/normal" ],
                                     @[ @NO, @NO ]);
    view.testSelectedWorkspaceIndex = 0;
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 200, 120, -1);
    NSString *selectedWorkspaceID = view.testWorkspaceIDs[0];
    NSString *normalWorkspaceID = view.testWorkspaceIDs[1];
    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:selectedWorkspaceID
                                                       key:@"shell"
                                                     value:@"Idle"
                                                      icon:@"pause.circle.fill"
                                                  colorHex:nil];
    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:normalWorkspaceID
                                                       key:@"shell"
                                                     value:@"Idle"
                                                      icon:@"pause.circle.fill"
                                                  colorHex:nil];

    NSTableCellView *selectedCell = TideyConfiguredPresentationCell(view, tableView, 0, 200, 60);
    NSTableCellView *normalCell = TideyConfiguredPresentationCell(view, tableView, 1, 200, 60);
    NSTextField *selectedSubtitle = TideyPresentationTextField(selectedCell, 1002);
    NSTextField *selectedStatus = TideyPresentationTextField(selectedCell, 1008);
    NSTextField *normalSubtitle = TideyPresentationTextField(normalCell, 1002);
    NSTextField *normalStatus = TideyPresentationTextField(normalCell, 1008);
    TideyInterfaceThemeTokens *tokens = TideyInterfaceThemeController.shared.currentTokens;
    NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    TideyAssertColor(selectedCell.textField.textColor,
                     tokens.sidebarSelectedPrimaryTextColor,
                     appearance);
    TideyAssertColor(selectedSubtitle.textColor,
                     tokens.sidebarSelectedSecondaryTextColor,
                     appearance);
    TideyAssertColor(selectedStatus.textColor,
                     tokens.sidebarSelectedIdleColor,
                     appearance);
    TideyAssertColor(normalCell.textField.textColor,
                     tokens.sidebarPrimaryTextColor,
                     appearance);
    TideyAssertColor(normalSubtitle.textColor,
                     tokens.sidebarSecondaryTextColor,
                     appearance);
    TideyAssertColor(normalStatus.textColor,
                     tokens.sidebarIdleColor,
                     appearance);
}

- (void)testWarmLongTitlePreservesProductionFieldGeometryAndBehavior {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Tidey UI Redesign Workspace" ],
                                     @[ @"~/Tidey-UI-Redesign" ],
                                     @[ @NO ]);
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 160, 60, -1);
    NSTableCellView *cellView = TideyConfiguredPresentationCell(view, tableView, 0, 160, 60);
    NSTextField *titleField = cellView.textField;

    // Warm anchors the title to the top slot (y=38) per the accepted
    // workspace-card hierarchy; width/height/clipping stay production.
    TideyAssertRect(titleField.frame, NSMakeRect(8, 38, 104, 14));
    XCTAssertEqual(titleField.lineBreakMode, NSLineBreakByWordWrapping);
    XCTAssertFalse(titleField.usesSingleLineMode);
    XCTAssertTrue(titleField.cell.wraps);
    XCTAssertFalse(titleField.cell.truncatesLastVisibleLine);
}

- (void)testWarmOverridesSourceListChromeWithoutChangingItsGeometryStyle {
    if (@available(macOS 11.0, *)) {
        XCTAssertEqual([iTermRootTerminalView tideySidebarTableStyleForWarmTheme:YES],
                       NSTableViewStyleSourceList);
        XCTAssertEqual([iTermRootTerminalView tideySidebarTableStyleForWarmTheme:NO],
                       NSTableViewStyleSourceList);
    }
    NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    TideyAssertColor([iTermRootTerminalView tideySidebarTableBackgroundOverrideColorForWarmTheme:YES],
                     NSColor.clearColor,
                     appearance);
    XCTAssertNil([iTermRootTerminalView tideySidebarTableBackgroundOverrideColorForWarmTheme:NO]);
    XCTAssertEqual([iTermRootTerminalView tideySidebarSelectionHighlightStyleForWarmTheme:YES],
                   NSTableViewSelectionHighlightStyleNone);
    XCTAssertEqual([iTermRootTerminalView tideySidebarSelectionHighlightStyleForWarmTheme:NO],
                   NSTableViewSelectionHighlightStyleSourceList);
}

- (void)testWarmAndClassicSidebarTableLayoutsUseTheSameVisibleGeometry {
    NSDictionary<NSString *, NSValue *> *classic = TideyLaidOutSidebarGeometry(NO);
    NSDictionary<NSString *, NSValue *> *warm = TideyLaidOutSidebarGeometry(YES);

    TideyAssertRect(warm[@"row"].rectValue, classic[@"row"].rectValue);
    TideyAssertRect(warm[@"cell"].rectValue, classic[@"cell"].rectValue);
    TideyAssertRect(warm[@"visibleRow"].rectValue, classic[@"visibleRow"].rectValue);
    TideyAssertRect(warm[@"visibleCell"].rectValue, classic[@"visibleCell"].rectValue);
    TideyAssertRect(warm[@"windowRow"].rectValue, classic[@"windowRow"].rectValue);
    TideyAssertRect(warm[@"windowCell"].rectValue, classic[@"windowCell"].rectValue);
    // Table/row/cell geometry and hit-testing stay production-identical. The
    // title differs only by the accepted Warm card anchor: 8pt higher in the
    // cell (y 30 -> 38), which reads as -8 in flipped table coordinates and
    // +8 in unflipped window coordinates. Everything else about the title
    // frame (x, width, height) must match classic exactly.
    const CGFloat warmTitleAnchorDelta = 8;
    TideyAssertRect(warm[@"title"].rectValue,
                    NSOffsetRect(classic[@"title"].rectValue, 0, -warmTitleAnchorDelta));
    TideyAssertRect(warm[@"visibleTitle"].rectValue,
                    NSOffsetRect(classic[@"visibleTitle"].rectValue, 0, -warmTitleAnchorDelta));
    TideyAssertRect(warm[@"windowTitle"].rectValue,
                    NSOffsetRect(classic[@"windowTitle"].rectValue, 0, warmTitleAnchorDelta));
    XCTAssertEqualObjects(warm[@"rowAtCenter"], classic[@"rowAtCenter"]);
    XCTAssertEqualObjects(warm[@"rowAboveFirst"], classic[@"rowAboveFirst"]);
    XCTAssertEqualObjects(warm[@"rowsAtCenter"], classic[@"rowsAtCenter"]);
    XCTAssertEqualObjects(warm[@"rowsAboveFirst"], classic[@"rowsAboveFirst"]);
    XCTAssertEqualObjects(warm[@"visibleRows"], classic[@"visibleRows"]);
}

- (void)testWarmAndClassicUseProductionMinimumWidth {
    XCTAssertEqualWithAccuracy([iTermRootTerminalView tideySidebarMinimumWidthForWarmTheme:YES],
                               160,
                               0.001);
    XCTAssertEqualWithAccuracy([iTermRootTerminalView tideySidebarMinimumWidthForWarmTheme:NO],
                               160,
                               0.001);
}

- (void)testPinnedHoveredRowPreservesPinAndCloseControlGeometry {
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Pinned" ], @[ @"~/pinned" ], @[ @YES ]);
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 200, 60, 0);
    NSTableCellView *cellView = TideyConfiguredPresentationCell(view, tableView, 0, 200, 60);
    NSImageView *pinView = (NSImageView *)[cellView viewWithTag:1003];
    NSView *closeView = TideyPresentationSubview(cellView, @"TideySidebarCloseView");

    XCTAssertFalse(pinView.hidden);
    TideyAssertRect(pinView.frame, NSMakeRect(158, 34, 12, 12));
    XCTAssertFalse(closeView.hidden);
    XCTAssertEqualWithAccuracy(closeView.alphaValue, 1.0, 0.001);
    TideyAssertRect(closeView.frame, NSMakeRect(180, 34, 16, 16));
}

- (void)testUnreadNotificationWithoutBodyPreservesBadgeAndAccentSubtitle {
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Workspace" ], @[ @"~/project" ], @[ @NO ]);
    NSString *workspaceID = view.testWorkspaceIDs[0];
    [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:workspaceID
                                                                  title:@"Build finished"
                                                               subtitle:nil
                                                                   body:@""];
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 200, 60, -1);
    NSTableCellView *cellView = TideyConfiguredPresentationCell(view, tableView, 0, 200, 60);
    NSTextField *subtitleField = TideyPresentationTextField(cellView, 1002);
    NSTextField *bodyField = TideyPresentationTextField(cellView, 1007);
    NSView *badgeView = TideyPresentationSubview(cellView, @"TideySidebarBadgeView");

    XCTAssertEqualObjects(subtitleField.stringValue, @"Build finished");
    TideyAssertColor(subtitleField.textColor,
                     NSColor.controlAccentColor,
                     [NSAppearance appearanceNamed:NSAppearanceNameAqua]);
    XCTAssertTrue(bodyField.hidden);
    XCTAssertFalse(badgeView.hidden);
    TideyAssertRect(badgeView.frame, NSMakeRect(1, 34, 6, 6));
}

- (void)testRowPresentationCapturesWorkspaceStateAndTransientControls {
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Selected" ], @[ @"~/selected" ], @[ @YES ]);
    view.testSelectedWorkspaceIndex = 0;
    [view setValue:@YES forKey:@"tideyShowingShortcutHints"];
    NSString *workspaceID = view.testWorkspaceIDs[0];
    [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:workspaceID
                                                                  title:@"Needs input"
                                                               subtitle:nil
                                                                   body:@"Please review the generated output"];
    TideyStatusStore *statusStore = [TideyStatusStore sharedStore];
    [statusStore setStatusForWorkspaceID:workspaceID
                                     key:@"shell"
                                   value:@"Running"
                                    icon:nil
                                colorHex:@"#00FF00"];
    [statusStore setStatusForWorkspaceID:workspaceID
                                     key:@"review"
                                   value:@"Review"
                                    icon:nil
                                colorHex:nil];
    TideyInstallPresentationTable(view, 200, 82, 0);

    TideySidebarRowPresentation *presentation = [view tideySidebarRowPresentationAtIndex:0];

    XCTAssertEqualObjects(presentation.workspaceIdentifier, workspaceID);
    XCTAssertEqualObjects(presentation.title, @"Selected");
    XCTAssertEqualObjects(presentation.subtitle, @"~/selected");
    XCTAssertEqual(presentation.unreadCount, 1);
    XCTAssertTrue(presentation.pinned);
    XCTAssertTrue(presentation.selected);
    XCTAssertEqualObjects(presentation.latestUnreadTitle, @"Needs input");
    XCTAssertEqualObjects(presentation.notificationBody, @"Please review the generated output");
    XCTAssertEqual(presentation.statusEntries.count, 2);
    XCTAssertTrue(presentation.showsCloseButton);
    XCTAssertEqualObjects(presentation.shortcutHint, @"⌘1");
}

- (void)testBodyAndMultipleStatusesPreserveExpandedSelectedPresentation {
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Selected" ], @[ @"~/selected" ], @[ @YES ]);
    view.testSelectedWorkspaceIndex = 0;
    NSString *workspaceID = view.testWorkspaceIDs[0];
    [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:workspaceID
                                                                  title:@"Needs input"
                                                               subtitle:nil
                                                                   body:@"Please review the generated output"];
    TideyStatusStore *statusStore = [TideyStatusStore sharedStore];
    [statusStore setStatusForWorkspaceID:workspaceID
                                     key:@"shell"
                                   value:@"Running"
                                    icon:nil
                                colorHex:@"#00FF00"];
    [statusStore setStatusForWorkspaceID:workspaceID
                                     key:@"review"
                                   value:@"Review"
                                    icon:nil
                                colorHex:nil];
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 200, 82, 0);
    NSTableCellView *cellView = TideyConfiguredPresentationCell(view, tableView, 0, 200, 82);
    NSTextField *subtitleField = TideyPresentationTextField(cellView, 1002);
    NSTextField *bodyField = TideyPresentationTextField(cellView, 1007);
    NSTextField *statusField = TideyPresentationTextField(cellView, 1008);
    NSView *badgeView = TideyPresentationSubview(cellView, @"TideySidebarBadgeView");
    NSImageView *pinView = (NSImageView *)[cellView viewWithTag:1003];
    NSView *closeView = TideyPresentationSubview(cellView, @"TideySidebarCloseView");
    NSAppearance *appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSColor *selectedSecondary = [NSColor colorWithWhite:1 alpha:0.8];

    TideyAssertRect(cellView.textField.frame, NSMakeRect(8, 65, 144, 14));
    TideyAssertRect(bodyField.frame, NSMakeRect(8, 30, 184, 28));
    TideyAssertRect(subtitleField.frame, NSMakeRect(8, 16, 184, 14));
    TideyAssertRect(statusField.frame, NSMakeRect(8, 2, 184, 12));
    TideyAssertRect(badgeView.frame, NSMakeRect(1, 69, 6, 6));
    TideyAssertRect(pinView.frame, NSMakeRect(158, 65, 12, 12));
    TideyAssertRect(closeView.frame, NSMakeRect(180, 56, 16, 16));
    XCTAssertEqualObjects(bodyField.stringValue, @"Please review the generated output");
    XCTAssertEqualObjects(subtitleField.stringValue, @"~/selected");
    XCTAssertTrue([statusField.stringValue containsString:@"Running"]);
    XCTAssertTrue([statusField.stringValue containsString:@"Review"]);
    XCTAssertFalse(bodyField.hidden);
    XCTAssertFalse(statusField.hidden);
    XCTAssertFalse(badgeView.hidden);
    XCTAssertFalse(pinView.hidden);
    XCTAssertFalse(closeView.hidden);
    TideyAssertColor(bodyField.textColor, selectedSecondary, appearance);
    TideyAssertColor(subtitleField.textColor, selectedSecondary, appearance);
    TideyAssertColor(statusField.textColor, selectedSecondary, appearance);
}

- (void)testRichUnselectedDynamicColorsResolveInLightAndDarkAppearances {
    for (NSAppearanceName appearanceName in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        NSAppearance *appearance = [NSAppearance appearanceNamed:appearanceName];
        TideySidebarPresentationTestRootView *view =
            TideyNewPresentationRootView(@[ @"Workspace" ], @[ @"~/project" ], @[ @NO ]);
        view.appearance = appearance;
        NSString *workspaceID = view.testWorkspaceIDs[0];
        [[TideyNotificationStore sharedStore] addNotificationForWorkspaceID:workspaceID
                                                                      title:@"Notice"
                                                                   subtitle:nil
                                                                       body:@"A notification body"];
        [[TideyStatusStore sharedStore] setStatusForWorkspaceID:workspaceID
                                                            key:@"shell"
                                                          value:@"Idle"
                                                           icon:nil
                                                       colorHex:nil];
        TideyCharacterizationSidebarTableView *tableView =
            TideyInstallPresentationTable(view, 200, 82, -1);
        NSTableCellView *cellView = TideyConfiguredPresentationCell(view, tableView, 0, 200, 82);
        NSTextField *subtitleField = TideyPresentationTextField(cellView, 1002);
        NSTextField *bodyField = TideyPresentationTextField(cellView, 1007);
        NSTextField *statusField = TideyPresentationTextField(cellView, 1008);

        TideyAssertColor(bodyField.textColor, NSColor.secondaryLabelColor, appearance);
        TideyAssertColor(subtitleField.textColor, NSColor.secondaryLabelColor, appearance);
        TideyAssertColor(statusField.textColor, NSColor.secondaryLabelColor, appearance);
    }
}

- (void)testSidebarRowViewKeepsCustomSelectionClassAndEmphasisContract {
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Workspace" ], @[ @"~/project" ], @[ @NO ]);
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 200, 60, -1);
    NSTableRowView *rowView = [view tableView:tableView rowViewForRow:0];

    XCTAssertEqualObjects(NSStringFromClass(rowView.class), @"TideySidebarRowView");
    XCTAssertTrue(rowView.isEmphasized);
    XCTAssertTrue(rowView.translatesAutoresizingMaskIntoConstraints);
}

- (void)testWarmRowDrawsSelectionCardWithNativeHighlightDisabled {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";
    TideySidebarRowView *rowView = [[[TideySidebarRowView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, 60)] autorelease];
    rowView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    rowView.selected = YES;

    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:200
                      pixelsHigh:60
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0] autorelease];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [rowView drawBackgroundInRect:rowView.bounds];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    NSColor *centerColor = [[bitmap colorAtX:100 y:30]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *expectedColor = [TideyInterfaceThemeController.shared.currentTokens.sidebarSelectionColor
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertEqualWithAccuracy(centerColor.redComponent, expectedColor.redComponent, 0.003);
    XCTAssertEqualWithAccuracy(centerColor.greenComponent, expectedColor.greenComponent, 0.003);
    XCTAssertEqualWithAccuracy(centerColor.blueComponent, expectedColor.blueComponent, 0.003);
    XCTAssertEqualWithAccuracy(centerColor.alphaComponent, expectedColor.alphaComponent, 0.001);
}

- (void)testWarmWorkspaceCardAnchorsHierarchyAndCornersCloseControl {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";
    TideySidebarPresentationTestRootView *view =
        TideyNewPresentationRootView(@[ @"Hovered workspace", @"Status workspace" ],
                                     @[ @"~/hovered", @"~/status" ],
                                     @[ @NO, @NO ]);
    TideyCharacterizationSidebarTableView *tableView =
        TideyInstallPresentationTable(view, 200, 120, 0);
    NSString *statusWorkspaceID = view.testWorkspaceIDs[1];
    [[TideyStatusStore sharedStore] setStatusForWorkspaceID:statusWorkspaceID
                                                       key:@"shell"
                                                     value:@"Running"
                                                      icon:nil
                                                  colorHex:nil];

    // Row 0: hovered, no status entries. Warm anchors the hierarchy to the top
    // of the card instead of re-centering into the rejected two-line layout,
    // and the close control tucks into the card's upper-right corner.
    NSTableCellView *hoveredCell = TideyConfiguredPresentationCell(view, tableView, 0, 200, 60);
    NSTextField *hoveredTitle = hoveredCell.textField;
    NSTextField *hoveredSubtitle = TideyPresentationTextField(hoveredCell, 1002);
    NSTextField *hoveredStatus = TideyPresentationTextField(hoveredCell, 1008);
    NSView *hoveredClose = TideyFindCloseView(hoveredCell);
    XCTAssertEqualWithAccuracy(hoveredTitle.frame.origin.y, 38, 0.001);
    XCTAssertEqualWithAccuracy(hoveredSubtitle.frame.origin.y, 22, 0.001);
    XCTAssertTrue(hoveredStatus.hidden);
    XCTAssertFalse(hoveredClose.hidden);
    XCTAssertTrue(NSEqualRects(hoveredClose.frame,
                               NSMakeRect(200 - kTideySidebarWarmCloseButtonTrailingInset -
                                              kTideySidebarCloseButtonSize,
                                          60 - kTideySidebarWarmCloseButtonTopInset -
                                              kTideySidebarCloseButtonSize,
                                          kTideySidebarCloseButtonSize,
                                          kTideySidebarCloseButtonSize)),
                  @"close frame %@", NSStringFromRect(hoveredClose.frame));

    // Row 1: authoritative status entry present. The same anchored hierarchy
    // holds and the status renders in the bottom slot with production font.
    NSTableCellView *statusCell = TideyConfiguredPresentationCell(view, tableView, 1, 200, 60);
    NSTextField *statusTitle = statusCell.textField;
    NSTextField *statusSubtitle = TideyPresentationTextField(statusCell, 1002);
    NSTextField *statusStatus = TideyPresentationTextField(statusCell, 1008);
    XCTAssertEqualWithAccuracy(statusTitle.frame.origin.y, 38, 0.001);
    XCTAssertEqualWithAccuracy(statusSubtitle.frame.origin.y, 22, 0.001);
    XCTAssertFalse(statusStatus.hidden);
    XCTAssertEqualWithAccuracy(statusStatus.frame.origin.y, 6, 0.001);
    XCTAssertTrue([statusStatus.attributedStringValue.string containsString:@"Running"]);

    // Classic keeps its existing centering and close geometry untouched.
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"classic";
    TideySidebarPresentationTestRootView *classicView =
        TideyNewPresentationRootView(@[ @"Classic workspace" ], @[ @"~/classic" ], @[ @NO ]);
    TideyCharacterizationSidebarTableView *classicTable =
        TideyInstallPresentationTable(classicView, 200, 60, 0);
    NSTableCellView *classicCell =
        TideyConfiguredPresentationCell(classicView, classicTable, 0, 200, 60);
    NSView *classicClose = TideyFindCloseView(classicCell);
    XCTAssertEqualWithAccuracy(classicCell.textField.frame.origin.y, 30, 0.001);
    XCTAssertEqualWithAccuracy(TideyPresentationTextField(classicCell, 1002).frame.origin.y,
                               12,
                               0.001);
    XCTAssertTrue(NSEqualRects(classicClose.frame,
                               NSMakeRect(200 - kTideySidebarCloseButtonTrailingInset -
                                              kTideySidebarCloseButtonSize,
                                          60 - kTideySidebarCloseButtonTopInset -
                                              kTideySidebarCloseButtonSize,
                                          kTideySidebarCloseButtonSize,
                                          kTideySidebarCloseButtonSize)),
                  @"classic close frame %@", NSStringFromRect(classicClose.frame));
}

@end
