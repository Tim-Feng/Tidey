#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"
#import "PSMTabBarControl.h"
#import "PSMTabBarCell.h"

@interface TideyShortcutHintDescriptor : NSObject
@property(nonatomic, readonly, copy) NSString *text;
@property(nonatomic, readonly) NSRect frame;
@end

@interface TideyEditorTabItemView : NSView
@end

@interface TideyTestTabBarControl : PSMTabBarControl
@property(nonatomic, assign) id itermTabBarDelegate;
@end

@implementation TideyTestTabBarControl
@synthesize itermTabBarDelegate;
@end

@interface iTermRootTerminalView (TideyCmdLongPressPanelHintsTests)
+ (NSArray<TideyShortcutHintDescriptor *> *)tideyShortcutHintDescriptorsForEditorTabViews:(NSArray<NSView *> *)tabViews;
+ (NSArray<TideyShortcutHintDescriptor *> *)tideyShortcutHintDescriptorsForTabBarCells:(NSArray<PSMTabBarCell *> *)cells;
+ (void)tideySyncShortcutHintDescriptors:(NSArray<TideyShortcutHintDescriptor *> *)descriptors
                         inContainerView:(NSView *)containerView
                               hintViews:(NSMutableArray<NSView *> *)hintViews;
- (void)tideyUpdatePanelShortcutHints;
- (void)tideyDismissShortcutHints;
@end

static NSString *TideyHintLabelText(NSView *hintView) {
    for (NSView *subview in hintView.subviews) {
        if ([subview isKindOfClass:[NSTextField class]]) {
            return [(NSTextField *)subview stringValue];
        }
    }
    return nil;
}

static iTermRootTerminalView *TideyNewPanelHintRootView(void) {
    iTermRootTerminalView *view = [[[iTermRootTerminalView alloc] initWithFrame:NSZeroRect
                                                                          color:[NSColor blackColor]] autorelease];
    [view setValue:[NSMutableArray array] forKey:@"tideyEditorTabs"];
    [view setValue:[NSMutableArray array] forKey:@"tideyEditorPanelHintViews"];
    [view setValue:[NSMutableArray array] forKey:@"tideyTerminalPanelHintViews"];
    return view;
}

@interface TideyCmdLongPressPanelHintsTests : XCTestCase
@end

@implementation TideyCmdLongPressPanelHintsTests

- (void)testEditorTabHintDescriptorsUseCtrlNumberLabelsAndTrailingHintFrames {
    NSView *tab1 = [[[NSView alloc] initWithFrame:NSMakeRect(10, 0, 120, 34)] autorelease];
    NSView *tab2 = [[[NSView alloc] initWithFrame:NSMakeRect(130, 0, 112, 34)] autorelease];
    NSView *tab3 = [[[NSView alloc] initWithFrame:NSMakeRect(242, 0, 160, 34)] autorelease];

    NSArray<TideyShortcutHintDescriptor *> *descriptors =
        [iTermRootTerminalView tideyShortcutHintDescriptorsForEditorTabViews:@[ tab1, tab2, tab3 ]];

    XCTAssertEqual(descriptors.count, 3);
    XCTAssertEqualObjects(descriptors[0].text, @"⌃1");
    XCTAssertEqualObjects(descriptors[1].text, @"⌃2");
    XCTAssertEqualObjects(descriptors[2].text, @"⌃3");
    XCTAssertTrue(NSEqualRects(descriptors[0].frame, NSMakeRect(94, 8, 28, 18)));
    XCTAssertTrue(NSEqualRects(descriptors[1].frame, NSMakeRect(206, 8, 28, 18)));
    XCTAssertTrue(NSEqualRects(descriptors[2].frame, NSMakeRect(366, 8, 28, 18)));
}

- (void)testTerminalPanelHintDescriptorsSkipOverflowCellsAndLimitToNine {
    NSMutableArray<PSMTabBarCell *> *cells = [NSMutableArray array];
    for (NSInteger i = 0; i < 10; i++) {
        PSMTabBarCell *cell = [[[PSMTabBarCell alloc] init] autorelease];
        cell.frame = NSMakeRect(100 * i, 0, 100, 24);
        cell.isInOverflowMenu = (i == 9);
        [cells addObject:cell];
    }

    NSArray<TideyShortcutHintDescriptor *> *descriptors =
        [iTermRootTerminalView tideyShortcutHintDescriptorsForTabBarCells:cells];

    XCTAssertEqual(descriptors.count, 9);
    XCTAssertEqualObjects(descriptors.firstObject.text, @"⌃1");
    XCTAssertEqualObjects(descriptors.lastObject.text, @"⌃9");
    XCTAssertTrue(NSEqualRects(descriptors.firstObject.frame, NSMakeRect(64, 3, 28, 18)));
    XCTAssertTrue(NSEqualRects(descriptors.lastObject.frame, NSMakeRect(864, 3, 28, 18)));
}

- (void)testSyncShortcutHintDescriptorsCreatesVisibleHintViewsWithMatchingLabels {
    NSView *containerView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 40)] autorelease];
    NSMutableArray<NSView *> *hintViews = [NSMutableArray array];
    NSArray<TideyShortcutHintDescriptor *> *descriptors =
        [iTermRootTerminalView tideyShortcutHintDescriptorsForEditorTabViews:@[
            [[[NSView alloc] initWithFrame:NSMakeRect(10, 0, 120, 34)] autorelease],
            [[[NSView alloc] initWithFrame:NSMakeRect(130, 0, 112, 34)] autorelease],
        ]];

    [iTermRootTerminalView tideySyncShortcutHintDescriptors:descriptors
                                            inContainerView:containerView
                                                  hintViews:hintViews];

    XCTAssertEqual(hintViews.count, 2);
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[0]), @"⌃1");
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[1]), @"⌃2");
    XCTAssertFalse(hintViews[0].hidden);
    XCTAssertFalse(hintViews[1].hidden);
    XCTAssertTrue(NSEqualRects(hintViews[0].frame, NSMakeRect(94, 8, 28, 18)));
    XCTAssertTrue(NSEqualRects(hintViews[1].frame, NSMakeRect(206, 8, 28, 18)));
}

- (void)testSyncShortcutHintDescriptorsSupportsTerminalPanelDescriptors {
    NSView *containerView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 24)] autorelease];
    NSMutableArray<NSView *> *hintViews = [NSMutableArray array];
    PSMTabBarCell *cell1 = [[[PSMTabBarCell alloc] init] autorelease];
    PSMTabBarCell *cell2 = [[[PSMTabBarCell alloc] init] autorelease];
    cell1.frame = NSMakeRect(0, 0, 100, 24);
    cell2.frame = NSMakeRect(100, 0, 100, 24);
    NSArray<TideyShortcutHintDescriptor *> *descriptors =
        [iTermRootTerminalView tideyShortcutHintDescriptorsForTabBarCells:@[ cell1, cell2 ]];

    [iTermRootTerminalView tideySyncShortcutHintDescriptors:descriptors
                                            inContainerView:containerView
                                                  hintViews:hintViews];

    XCTAssertEqual(hintViews.count, 2);
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[0]), @"⌃1");
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[1]), @"⌃2");
    XCTAssertTrue(NSEqualRects(hintViews[0].frame, NSMakeRect(64, 3, 28, 18)));
    XCTAssertTrue(NSEqualRects(hintViews[1].frame, NSMakeRect(164, 3, 28, 18)));
}

- (void)testSyncShortcutHintDescriptorsHidesUnusedHintViewsWhenDismissed {
    NSView *containerView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 40)] autorelease];
    NSMutableArray<NSView *> *hintViews = [NSMutableArray array];
    NSArray<TideyShortcutHintDescriptor *> *descriptors =
        [iTermRootTerminalView tideyShortcutHintDescriptorsForEditorTabViews:@[
            [[[NSView alloc] initWithFrame:NSMakeRect(10, 0, 120, 34)] autorelease],
            [[[NSView alloc] initWithFrame:NSMakeRect(130, 0, 112, 34)] autorelease],
        ]];

    [iTermRootTerminalView tideySyncShortcutHintDescriptors:descriptors
                                            inContainerView:containerView
                                                  hintViews:hintViews];
    [iTermRootTerminalView tideySyncShortcutHintDescriptors:@[]
                                            inContainerView:containerView
                                                  hintViews:hintViews];

    XCTAssertEqual(hintViews.count, 2);
    XCTAssertTrue(hintViews[0].hidden);
    XCTAssertTrue(hintViews[1].hidden);
}

- (void)testUpdatePanelShortcutHintsShowsCtrlNumberHintsOnVisibleEditorTabs {
    iTermRootTerminalView *view = TideyNewPanelHintRootView();
    NSView *tabStripView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 34)] autorelease];
    TideyEditorTabItemView *tab1 = [[[TideyEditorTabItemView alloc] initWithFrame:NSMakeRect(0, 0, 120, 34)] autorelease];
    TideyEditorTabItemView *tab2 = [[[TideyEditorTabItemView alloc] initWithFrame:NSMakeRect(120, 0, 120, 34)] autorelease];
    NSView *overlayView = [[[NSView alloc] initWithFrame:tabStripView.bounds] autorelease];
    [tabStripView addSubview:tab1];
    [tabStripView addSubview:tab2];
    [tabStripView addSubview:overlayView];

    [view setValue:tabStripView forKey:@"tideyEditorTabStripView"];
    [view setValue:overlayView forKey:@"tideyEditorPanelHintOverlayView"];
    [view setValue:[NSMutableArray arrayWithObjects:@"one", @"two", nil] forKey:@"tideyEditorTabs"];
    [view setValue:@YES forKey:@"shouldShowTideyEditorPanel"];
    [view setValue:@YES forKey:@"tideyShowingShortcutHints"];

    [view tideyUpdatePanelShortcutHints];

    NSArray<NSView *> *hintViews = [view valueForKey:@"tideyEditorPanelHintViews"];
    XCTAssertEqual(hintViews.count, 2);
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[0]), @"⌃1");
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[1]), @"⌃2");
    XCTAssertFalse(hintViews[0].hidden);
    XCTAssertFalse(hintViews[1].hidden);
    XCTAssertTrue(NSEqualRects(hintViews[0].frame, NSMakeRect(84, 8, 28, 18)));
    XCTAssertTrue(NSEqualRects(hintViews[1].frame, NSMakeRect(204, 8, 28, 18)));
}

- (void)testUpdatePanelShortcutHintsShowsCtrlNumberHintsOnVisibleTerminalPanels {
    iTermRootTerminalView *view = TideyNewPanelHintRootView();
    TideyTestTabBarControl *tabBarControl = [[[TideyTestTabBarControl alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)] autorelease];
    NSView *overlayView = [[[NSView alloc] initWithFrame:tabBarControl.bounds] autorelease];
    PSMTabBarCell *cell1 = [[[PSMTabBarCell alloc] init] autorelease];
    PSMTabBarCell *cell2 = [[[PSMTabBarCell alloc] init] autorelease];
    cell1.frame = NSMakeRect(0, 0, 100, 24);
    cell2.frame = NSMakeRect(100, 0, 100, 24);
    [tabBarControl setValue:[NSMutableArray arrayWithObjects:cell1, cell2, nil] forKey:@"cells"];
    [tabBarControl addSubview:overlayView];

    [view setValue:tabBarControl forKey:@"tabBarControl"];
    [view setValue:overlayView forKey:@"tideyTerminalPanelHintOverlayView"];
    [view setValue:@YES forKey:@"shouldShowTideyTerminal"];
    [view setValue:@YES forKey:@"shouldShowTideySidebar"];
    [view setValue:@YES forKey:@"tideyShowingShortcutHints"];

    [view tideyUpdatePanelShortcutHints];

    NSArray<NSView *> *hintViews = [view valueForKey:@"tideyTerminalPanelHintViews"];
    XCTAssertEqual(hintViews.count, 2);
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[0]), @"⌃1");
    XCTAssertEqualObjects(TideyHintLabelText(hintViews[1]), @"⌃2");
    XCTAssertFalse(hintViews[0].hidden);
    XCTAssertFalse(hintViews[1].hidden);
    XCTAssertTrue(NSEqualRects(hintViews[0].frame, NSMakeRect(64, 3, 28, 18)));
    XCTAssertTrue(NSEqualRects(hintViews[1].frame, NSMakeRect(164, 3, 28, 18)));
}

- (void)testDismissShortcutHintsHidesPanelHintViews {
    iTermRootTerminalView *view = TideyNewPanelHintRootView();
    NSView *tabStripView = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 34)] autorelease];
    TideyEditorTabItemView *tab1 = [[[TideyEditorTabItemView alloc] initWithFrame:NSMakeRect(0, 0, 120, 34)] autorelease];
    TideyEditorTabItemView *tab2 = [[[TideyEditorTabItemView alloc] initWithFrame:NSMakeRect(120, 0, 120, 34)] autorelease];
    NSView *editorOverlayView = [[[NSView alloc] initWithFrame:tabStripView.bounds] autorelease];
    [tabStripView addSubview:tab1];
    [tabStripView addSubview:tab2];
    [tabStripView addSubview:editorOverlayView];

    TideyTestTabBarControl *tabBarControl = [[[TideyTestTabBarControl alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)] autorelease];
    NSView *terminalOverlayView = [[[NSView alloc] initWithFrame:tabBarControl.bounds] autorelease];
    PSMTabBarCell *cell1 = [[[PSMTabBarCell alloc] init] autorelease];
    PSMTabBarCell *cell2 = [[[PSMTabBarCell alloc] init] autorelease];
    cell1.frame = NSMakeRect(0, 0, 100, 24);
    cell2.frame = NSMakeRect(100, 0, 100, 24);
    [tabBarControl setValue:[NSMutableArray arrayWithObjects:cell1, cell2, nil] forKey:@"cells"];
    [tabBarControl addSubview:terminalOverlayView];

    [view setValue:tabStripView forKey:@"tideyEditorTabStripView"];
    [view setValue:editorOverlayView forKey:@"tideyEditorPanelHintOverlayView"];
    [view setValue:[NSMutableArray arrayWithObjects:@"one", @"two", nil] forKey:@"tideyEditorTabs"];
    [view setValue:@YES forKey:@"shouldShowTideyEditorPanel"];
    [view setValue:tabBarControl forKey:@"tabBarControl"];
    [view setValue:terminalOverlayView forKey:@"tideyTerminalPanelHintOverlayView"];
    [view setValue:@YES forKey:@"shouldShowTideyTerminal"];
    [view setValue:@YES forKey:@"shouldShowTideySidebar"];
    [view setValue:@YES forKey:@"tideyShowingShortcutHints"];

    [view tideyUpdatePanelShortcutHints];
    [view tideyDismissShortcutHints];

    NSArray<NSView *> *editorHintViews = [view valueForKey:@"tideyEditorPanelHintViews"];
    NSArray<NSView *> *terminalHintViews = [view valueForKey:@"tideyTerminalPanelHintViews"];
    XCTAssertEqual(editorHintViews.count, 2);
    XCTAssertEqual(terminalHintViews.count, 2);
    XCTAssertTrue(editorHintViews[0].hidden);
    XCTAssertTrue(editorHintViews[1].hidden);
    XCTAssertTrue(terminalHintViews[0].hidden);
    XCTAssertTrue(terminalHintViews[1].hidden);
    XCTAssertEqualObjects([view valueForKey:@"tideyShowingShortcutHints"], @NO);
}

@end
