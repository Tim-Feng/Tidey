//
//  TideyRightPanelTabGroupingTests.m
//  iTerm2XCTests
//

#import <XCTest/XCTest.h>
#import "iTermRootTerminalView.h"

typedef NS_ENUM(NSInteger, TideyRightPanelTabKind) {
    TideyRightPanelTabKindEditor = 0,
    TideyRightPanelTabKindBrowser = 1,
};

@interface TideyEditorTab : NSObject
@property(nonatomic) TideyRightPanelTabKind kind;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *identifier;
+ (instancetype)tabWithPath:(NSString *)path
                displayName:(NSString *)displayName
                   language:(NSString *)language
                    content:(NSString *)content;
@end

@interface TideyRightPanelTabGroupState : NSObject
@property(nonatomic) TideyRightPanelTabKind kind;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) BOOL expanded;
@property(nonatomic, strong) NSArray<TideyEditorTab *> *visibleTabs;
@end

@interface TideyRightPanelSelectionState : NSObject
@property(nonatomic) TideyRightPanelTabKind expandedKind;
@property(nonatomic, copy) NSString *selectedTabIdentifier;
@end

@interface iTermRootTerminalView (TideyRightPanelTabGroupingTests)
+ (NSArray<TideyRightPanelTabGroupState *> *)tideyRightPanelGroupStatesForTabs:(NSArray<TideyEditorTab *> *)tabs
                                                                 expandedKind:(TideyRightPanelTabKind)expandedKind;
+ (TideyRightPanelSelectionState *)tideyRightPanelSelectionStateForTabs:(NSArray<TideyEditorTab *> *)tabs
                                                    preferredExpandedKind:(TideyRightPanelTabKind)preferredExpandedKind
                                                currentSelectedTabIdentifier:(NSString *)currentSelectedTabIdentifier
                                                 lastActiveEditorTabIdentifier:(NSString *)lastActiveEditorTabIdentifier
                                                lastActiveBrowserTabIdentifier:(NSString *)lastActiveBrowserTabIdentifier;
+ (TideyEditorTab *)tideyRightPanelTabForShortcutNumber:(NSInteger)number
                                                   tabs:(NSArray<TideyEditorTab *> *)tabs
                                           expandedKind:(TideyRightPanelTabKind)expandedKind;
+ (BOOL)tideyResponder:(NSResponder *)responder isDescendantOfView:(NSView *)view;
@end

@interface TideyRightPanelTabGroupingTests : XCTestCase
@end

@implementation TideyRightPanelTabGroupingTests

- (TideyEditorTab *)tabNamed:(NSString *)name kind:(TideyRightPanelTabKind)kind {
    TideyEditorTab *tab = [TideyEditorTab tabWithPath:[@"/tmp" stringByAppendingPathComponent:name]
                                          displayName:name
                                             language:@"plaintext"
                                              content:@""];
    tab.kind = kind;
    return tab;
}

- (NSArray<NSString *> *)namesForTabs:(NSArray<TideyEditorTab *> *)tabs {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (TideyEditorTab *tab in tabs) {
        [names addObject:tab.displayName ?: @""];
    }
    return names;
}

- (void)testRightPanelTabsReceiveStableIdentifiers {
    TideyEditorTab *first = [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *second = [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor];

    XCTAssertEqual(first.kind, TideyRightPanelTabKindEditor);
    XCTAssertGreaterThan(first.identifier.length, 0U);
    XCTAssertGreaterThan(second.identifier.length, 0U);
    XCTAssertNotEqualObjects(first.identifier, second.identifier);
}

- (void)testMixedRightPanelTabsOnlyExposeExpandedGroupTabs {
    NSArray<TideyRightPanelTabGroupState *> *groups =
        [iTermRootTerminalView tideyRightPanelGroupStatesForTabs:@[
            [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor],
            [self tabNamed:@"Browser A" kind:TideyRightPanelTabKindBrowser],
            [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor],
            [self tabNamed:@"Browser B" kind:TideyRightPanelTabKindBrowser],
        ]
                                                     expandedKind:TideyRightPanelTabKindBrowser];

    XCTAssertEqual(groups.count, 2U);
    XCTAssertEqual(groups[0].kind, TideyRightPanelTabKindEditor);
    XCTAssertEqualObjects(groups[0].label, @"Code");
    XCTAssertFalse(groups[0].expanded);
    XCTAssertEqual(groups[0].visibleTabs.count, 0U);

    XCTAssertEqual(groups[1].kind, TideyRightPanelTabKindBrowser);
    XCTAssertEqualObjects(groups[1].label, @"Web");
    XCTAssertTrue(groups[1].expanded);
    XCTAssertEqualObjects([self namesForTabs:groups[1].visibleTabs], (@[ @"Browser A", @"Browser B" ]));
}

- (void)testSelectionStateSwitchesToRememberedTabInExpandedGroup {
    TideyEditorTab *editorA = [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *editorB = [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *browserA = [self tabNamed:@"Browser A" kind:TideyRightPanelTabKindBrowser];
    TideyEditorTab *browserB = [self tabNamed:@"Browser B" kind:TideyRightPanelTabKindBrowser];

    TideyRightPanelSelectionState *state =
        [iTermRootTerminalView tideyRightPanelSelectionStateForTabs:@[ editorA, browserA, editorB, browserB ]
                                               preferredExpandedKind:TideyRightPanelTabKindBrowser
                                           currentSelectedTabIdentifier:editorA.identifier
                                            lastActiveEditorTabIdentifier:editorB.identifier
                                           lastActiveBrowserTabIdentifier:browserB.identifier];

    XCTAssertEqual(state.expandedKind, TideyRightPanelTabKindBrowser);
    XCTAssertEqualObjects(state.selectedTabIdentifier, browserB.identifier);
}

- (void)testSelectionStateFallsBackToCodeWhenLastWebTabCloses {
    TideyEditorTab *editorA = [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *editorB = [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor];

    TideyRightPanelSelectionState *state =
        [iTermRootTerminalView tideyRightPanelSelectionStateForTabs:@[ editorA, editorB ]
                                               preferredExpandedKind:TideyRightPanelTabKindBrowser
                                           currentSelectedTabIdentifier:@"missing-browser-tab"
                                            lastActiveEditorTabIdentifier:editorB.identifier
                                           lastActiveBrowserTabIdentifier:@"missing-browser-tab"];

    XCTAssertEqual(state.expandedKind, TideyRightPanelTabKindEditor);
    XCTAssertEqualObjects(state.selectedTabIdentifier, editorB.identifier);
}

- (void)testShortcutSelectionUsesExpandedGroupTabsOnly {
    TideyEditorTab *editorA = [self tabNamed:@"Editor A" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *browserA = [self tabNamed:@"Browser A" kind:TideyRightPanelTabKindBrowser];
    TideyEditorTab *editorB = [self tabNamed:@"Editor B" kind:TideyRightPanelTabKindEditor];
    TideyEditorTab *browserB = [self tabNamed:@"Browser B" kind:TideyRightPanelTabKindBrowser];

    TideyEditorTab *selected =
        [iTermRootTerminalView tideyRightPanelTabForShortcutNumber:1
                                                              tabs:@[ editorA, browserA, editorB, browserB ]
                                                      expandedKind:TideyRightPanelTabKindBrowser];

    XCTAssertEqualObjects(selected.identifier, browserA.identifier);
}

- (void)testShortcutSelectionUsesLastVisibleTabForControlNine {
    TideyEditorTab *browserA = [self tabNamed:@"Browser A" kind:TideyRightPanelTabKindBrowser];
    TideyEditorTab *browserB = [self tabNamed:@"Browser B" kind:TideyRightPanelTabKindBrowser];

    TideyEditorTab *selected =
        [iTermRootTerminalView tideyRightPanelTabForShortcutNumber:9
                                                              tabs:@[ browserA, browserB ]
                                                      expandedKind:TideyRightPanelTabKindBrowser];

    XCTAssertEqualObjects(selected.identifier, browserB.identifier);
}

- (void)testResponderChainDescendantMatchesAncestorView {
    NSView *panelView = [[NSView alloc] initWithFrame:NSZeroRect];
    NSView *browserView = [[NSView alloc] initWithFrame:NSZeroRect];
    NSResponder *proxyResponder = [[NSResponder alloc] init];
    [panelView addSubview:browserView];
    proxyResponder.nextResponder = browserView;

    XCTAssertTrue([iTermRootTerminalView tideyResponder:proxyResponder isDescendantOfView:panelView]);
}

@end
