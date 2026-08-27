#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"
#import "TideyNotificationStore.h"
#import "TideySidebarRowPresentation.h"
#import "TideySidebarViews.h"
#import "iTerm2SharedARC-Swift.h"

@interface iTermRootTerminalView (TideySidebarPresentationCharacterizationTests)
- (NSTableCellView *)newTideySidebarCellView;
+ (NSTableViewStyle)tideySidebarTableStyleForWarmTheme:(BOOL)warm;
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

- (void)testWarmRowsUseFrozenTypographyAndSemanticRunningIdleColors {
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
                    [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]);
    TideyAssertFont(runningSubtitle.font,
                    [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular]);
    TideyAssertFont(runningStatus.font,
                    [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular]);
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

- (void)testWarmSidebarUsesPlainTableChromeAndClassicRestoresSourceListChrome {
    if (@available(macOS 11.0, *)) {
        XCTAssertEqual([iTermRootTerminalView tideySidebarTableStyleForWarmTheme:YES],
                       NSTableViewStylePlain);
        XCTAssertEqual([iTermRootTerminalView tideySidebarTableStyleForWarmTheme:NO],
                       NSTableViewStyleSourceList);
    }
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

- (void)testRegularStyleSelectedSidebarRowDrawsWarmSelectionCard {
    TideyInterfaceThemeController.shared.currentThemeIdentifier = @"warm";
    TideySidebarRowView *rowView = [[[TideySidebarRowView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, 60)] autorelease];
    rowView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
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
    [rowView drawSelectionInRect:rowView.bounds];
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

@end
