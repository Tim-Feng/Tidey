#import <XCTest/XCTest.h>

#import "PseudoTerminal.h"
#import "PTYSession.h"
#import "PTYTextViewDataSource.h"
#import "ScreenChar.h"
#import "TideySocketServer.h"
#import "VT100Grid.h"

#import <objc/runtime.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>

static id TideySocketTestAutorelease(id object) {
#if __has_feature(objc_arc)
    return object;
#else
    return [object autorelease];
#endif
}

typedef NSDictionary * _Nullable (^TideySocketNativeTerminalSizeHandler)(
    NSString *action,
    NSString *panelID,
    NSString * _Nullable token,
    NSInteger columns,
    NSInteger rows);

@interface TideySocketServer (Testing)
+ (NSDictionary *)tideyResponseForRequestMessage:(NSDictionary *)message
                              workspaceSummaries:(NSArray<NSDictionary *> *)workspaceSummaries
                                sendInputHandler:(BOOL (^)(NSString *workspaceID, NSString *input))sendInputHandler
                            recentOutputProvider:(NSString * _Nullable (^)(NSString *workspaceID))recentOutputProvider;
+ (NSDictionary *)tideyNativeTerminalSizeResponseForRequestID:(NSString *)requestID
                                                        action:(NSString *)action
                                                        source:(NSDictionary *)source
                                                       handler:(TideySocketNativeTerminalSizeHandler)handler;
+ (NSArray<NSDictionary *> *)tideyWorkspaceSummaries:(NSArray<NSDictionary *> *)workspaceSummaries
                 filteredToWindowForListWorkspacesSource:(NSDictionary *)source;
- (void)acceptFileDescriptor:(int)fd;
- (void)cleanupStaleSockets:(NSString *)directory;
- (NSUInteger)tideyTestingConnectionCount;
- (NSDictionary *)trimmedRecentOutputSnapshot:(NSDictionary *)snapshot
                                     maxLines:(NSInteger)maxLines
                                     maxChars:(NSInteger)maxChars;
@end

@interface PseudoTerminal (TideyANSIGridTesting)
+ (NSDictionary *)tideySnapshotForGrid:(id<VT100GridReading>)grid
                          cursorVisible:(BOOL)cursorVisible;
+ (NSDictionary *)tideyPresentedSnapshotForCurrentGrid:(id<VT100GridReading>)currentGrid
                                          cursorVisible:(BOOL)cursorVisible
                                      synchronizedState:(id<PTYTextViewSynchronousUpdateStateReading>)synchronizedState;
+ (NSDictionary *)tideySnapshotForScreenCharacterRows:(NSArray<NSData *> *)screenCharacterRows
                                                 width:(NSInteger)width
                                                height:(NSInteger)height
                                               cursorX:(NSInteger)cursorX
                                               cursorY:(NSInteger)cursorY
                                         cursorVisible:(BOOL)cursorVisible;
+ (NSDictionary *)tideySnapshot:(NSDictionary *)snapshot
    byAddingScrollbackScreenCharacterRows:(NSArray<NSData *> *)screenCharacterRows
                                   width:(NSInteger)width;
@end

@interface PseudoTerminal (TideyNativeSessionPanelIdentityTesting)
+ (NSString *)tideyNativeSessionPanelIdentifierForCarrierPanelIdentifier:(NSString *)carrierPanelIdentifier
                                                  nativeSessionIdentifier:(NSString *)nativeSessionIdentifier;
+ (NSDictionary<NSString *, NSString *> *)tideyNativeSessionPanelIdentityFromPanelIdentifier:(NSString *)panelIdentifier;
+ (NSArray<NSDictionary *> *)tideyNativeSessionPanelSummariesForCarrierPanelIdentifier:(NSString *)carrierPanelIdentifier
                                                                    basePanelSummaries:(NSArray<NSDictionary *> *)basePanelSummaries;
+ (NSString *)tideyValidatedNativeSessionIdentifierForPanelIdentifier:(NSString *)panelIdentifier
                                         actualCarrierPanelIdentifier:(NSString *)actualCarrierPanelIdentifier;
+ (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)tideyNativeSessionPanelEventDiffFromPreviousSummaries:(NSArray<NSDictionary *> *)previousSummaries
                                                                                               currentSummaries:(NSArray<NSDictionary *> *)currentSummaries;
+ (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)tideyNativeSessionPanelEventDiffForCarrierPanelIdentifier:(NSString *)carrierPanelIdentifier
                                                                                                      summaryCache:(NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *)summaryCache
                                                                                                  currentSummaries:(NSArray<NSDictionary *> *)currentSummaries;
+ (BOOL)tideyRemoteSelectionShouldMutateMacForPanelIdentifier:(NSString *)panelIdentifier;
+ (BOOL)tideyCloseShouldUseCarrierForPanelIdentifier:(NSString *)panelIdentifier
                               nativeSessionAvailable:(BOOL)nativeSessionAvailable;
@end

@class TideyNativeTerminalSizeLease;

@interface PseudoTerminal (TideyNativeTerminalSizeLeaseTesting)
- (BOOL)tideySession:(PTYSession *)session
    shouldApplyNativeTerminalSize:(VT100GridSize)size;
- (void)tideySessionWillReplaceGUID:(PTYSession *)session;
- (void)tideyRestoreExpiredNativeTerminalSizeLease:(TideyNativeTerminalSizeLease *)lease
                                   resolvedSession:(PTYSession *)session;
@end

@interface PseudoTerminalTests : XCTestCase
@end

@interface TideyNativeTerminalSizeLease : NSObject
@property(nonatomic, readonly, copy) NSString *token;
@property(nonatomic, readonly) VT100GridSize leasedGrid;
@property(nonatomic, readonly) VT100GridSize savedMacGrid;
@property(nonatomic, readonly) NSTimeInterval lastHeartbeatAt;
@end

@interface TideyNativeTerminalSizeLeaseStore : NSObject
- (TideyNativeTerminalSizeLease *)acquireWithToken:(NSString *)token
                            carrierPanelIdentifier:(NSString *)carrierPanelIdentifier
                                       sessionGUID:(NSString *)sessionGUID
                                        leasedGrid:(VT100GridSize)leasedGrid
                                      savedMacGrid:(VT100GridSize)savedMacGrid
                                               now:(NSTimeInterval)now;
- (BOOL)shouldApplyGrid:(VT100GridSize)grid toSessionGUID:(NSString *)sessionGUID;
- (TideyNativeTerminalSizeLease *)leaseForSessionGUID:(NSString *)sessionGUID;
- (TideyNativeTerminalSizeLease *)takeLeaseForSessionGUID:(NSString *)sessionGUID
                                                    token:(NSString *)token;
- (TideyNativeTerminalSizeLease *)updateLeasedGrid:(VT100GridSize)leasedGrid
                                       sessionGUID:(NSString *)sessionGUID
                                             token:(NSString *)token
                                               now:(NSTimeInterval)now;
- (TideyNativeTerminalSizeLease *)heartbeatSessionGUID:(NSString *)sessionGUID
                                                 token:(NSString *)token
                                                   now:(NSTimeInterval)now;
- (NSArray<TideyNativeTerminalSizeLease *> *)takeExpiredLeasesAt:(NSTimeInterval)now
                                                         timeout:(NSTimeInterval)timeout;
@end

@interface TideyNativeTerminalSizeProbeSession : NSObject
@property(nonatomic, copy) NSString *guid;
@property(nonatomic) VT100GridSize appliedGrid;
@property(nonatomic) NSUInteger applyCount;
- (void)setSize:(VT100GridSize)size;
@end

@implementation TideyNativeTerminalSizeProbeSession

- (void)dealloc {
    [_guid release];
    [super dealloc];
}

- (void)setSize:(VT100GridSize)size {
    self.appliedGrid = size;
    self.applyCount += 1;
}

@end

@interface TideyNativeSessionRestartProbeTerminal : PseudoTerminal {
    BOOL _didRefreshNativeSessionProjection;
}
@property(nonatomic, assign) BOOL didRefreshNativeSessionProjection;
@end

@implementation TideyNativeSessionRestartProbeTerminal

@synthesize didRefreshNativeSessionProjection = _didRefreshNativeSessionProjection;

- (void)refreshTools {
}

- (void)numberOfSessionsDidChangeInTab:(PTYTab *)tab {
    self.didRefreshNativeSessionProjection = YES;
}

@end

static BOOL sTideyNativeSessionPreviousSummaryDidDeallocate;
static BOOL sTideyNativeSessionPreviousSummaryWasDeallocatedBeforeDiff;

@interface TideyNativeSessionPreviousSummaryDeallocProbe : NSObject
@end

@implementation TideyNativeSessionPreviousSummaryDeallocProbe

- (void)dealloc {
    sTideyNativeSessionPreviousSummaryDidDeallocate = YES;
    [super dealloc];
}

@end

@interface TideyNativeSessionCacheTransitionProbeTerminal : PseudoTerminal
@end

@implementation TideyNativeSessionCacheTransitionProbeTerminal

+ (NSDictionary<NSString *, NSArray<NSDictionary *> *> *)tideyNativeSessionPanelEventDiffFromPreviousSummaries:(NSArray<NSDictionary *> *)previousSummaries
                                                                                               currentSummaries:(NSArray<NSDictionary *> *)currentSummaries {
    sTideyNativeSessionPreviousSummaryWasDeallocatedBeforeDiff =
        sTideyNativeSessionPreviousSummaryDidDeallocate;
    return @{
        @"created": @[],
        @"updated": @[],
        @"closed": @[],
    };
}

@end

@implementation PseudoTerminalTests

- (void)testNativeSessionPanelIdentityRoundTrips {
    NSString *panelID = [PseudoTerminal
        tideyNativeSessionPanelIdentifierForCarrierPanelIdentifier:@"carrier-1"
                                           nativeSessionIdentifier:@"session-1"];

    XCTAssertEqualObjects(panelID, @"native-session:carrier-1:session-1");
    XCTAssertEqualObjects(
        [PseudoTerminal tideyNativeSessionPanelIdentityFromPanelIdentifier:panelID],
        (@{
            @"carrier_panel_id": @"carrier-1",
            @"native_session_id": @"session-1",
        }));
    XCTAssertNil([PseudoTerminal tideyNativeSessionPanelIdentityFromPanelIdentifier:@"carrier-1"]);
    XCTAssertNil([PseudoTerminal tideyNativeSessionPanelIdentityFromPanelIdentifier:@"native-session:carrier-1:"]);
    XCTAssertNil([PseudoTerminal tideyNativeSessionPanelIdentityFromPanelIdentifier:@"native-session:carrier-1:session-1:extra"]);
}

- (void)testNativeTerminalSizeLeaseSuppressesMacResizeAndRestoresLatestGrid {
    TideyNativeTerminalSizeLeaseStore *store = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeLeaseStore alloc] init]);
    const VT100GridSize phoneGrid = VT100GridSizeMake(42, 20);
    const VT100GridSize originalMacGrid = VT100GridSizeMake(132, 48);
    const VT100GridSize latestMacGrid = VT100GridSizeMake(118, 44);

    [store acquireWithToken:@"token-1"
     carrierPanelIdentifier:@"carrier-1"
                sessionGUID:@"session-1"
                 leasedGrid:phoneGrid
               savedMacGrid:originalMacGrid
                        now:100];

    XCTAssertTrue([store shouldApplyGrid:phoneGrid toSessionGUID:@"session-1"]);
    XCTAssertFalse([store shouldApplyGrid:latestMacGrid toSessionGUID:@"session-1"]);
    TideyNativeTerminalSizeLease *liveLease =
        [store leaseForSessionGUID:@"session-1"];
    XCTAssertTrue(VT100GridSizeEquals(liveLease.leasedGrid, phoneGrid));
    XCTAssertTrue(VT100GridSizeEquals(liveLease.savedMacGrid, latestMacGrid));

    TideyNativeTerminalSizeLease *released =
        [store takeLeaseForSessionGUID:@"session-1" token:@"token-1"];
    XCTAssertTrue(VT100GridSizeEquals(released.savedMacGrid, latestMacGrid));
    XCTAssertNil([store takeLeaseForSessionGUID:@"session-1" token:@"token-1"]);
    XCTAssertTrue([store shouldApplyGrid:originalMacGrid toSessionGUID:@"session-1"]);
}

- (void)testNativeTerminalSizeLeaseSupersedeCarriesMacGridAndRejectsStaleToken {
    TideyNativeTerminalSizeLeaseStore *store = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeLeaseStore alloc] init]);
    const VT100GridSize firstPhoneGrid = VT100GridSizeMake(42, 20);
    const VT100GridSize secondPhoneGrid = VT100GridSizeMake(50, 22);
    const VT100GridSize latestMacGrid = VT100GridSizeMake(118, 44);

    [store acquireWithToken:@"token-1"
     carrierPanelIdentifier:@"carrier-1"
                sessionGUID:@"session-1"
                 leasedGrid:firstPhoneGrid
               savedMacGrid:VT100GridSizeMake(132, 48)
                        now:100];
    XCTAssertFalse([store shouldApplyGrid:latestMacGrid toSessionGUID:@"session-1"]);

    TideyNativeTerminalSizeLease *superseding =
        [store acquireWithToken:@"token-2"
         carrierPanelIdentifier:@"carrier-1"
                    sessionGUID:@"session-1"
                     leasedGrid:secondPhoneGrid
                   savedMacGrid:firstPhoneGrid
                            now:101];
    XCTAssertTrue(VT100GridSizeEquals(superseding.savedMacGrid, latestMacGrid));
    XCTAssertNil([store updateLeasedGrid:VT100GridSizeMake(60, 24)
                              sessionGUID:@"session-1"
                                    token:@"token-1"
                                      now:102]);
    XCTAssertNil([store heartbeatSessionGUID:@"session-1" token:@"token-1" now:102]);

    TideyNativeTerminalSizeLease *updated =
        [store updateLeasedGrid:VT100GridSizeMake(52, 23)
                    sessionGUID:@"session-1"
                          token:@"token-2"
                            now:103];
    XCTAssertTrue(VT100GridSizeEquals(updated.leasedGrid, VT100GridSizeMake(52, 23)));
    XCTAssertEqual(updated.lastHeartbeatAt, 103);
    XCTAssertEqual([store heartbeatSessionGUID:@"session-1"
                                          token:@"token-2"
                                            now:104].lastHeartbeatAt, 104);
}

- (void)testNativeTerminalSizeLeaseTimeoutRestoresOnceAndRejectsLateHeartbeat {
    TideyNativeTerminalSizeLeaseStore *store = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeLeaseStore alloc] init]);
    const VT100GridSize macGrid = VT100GridSizeMake(132, 48);

    [store acquireWithToken:@"token-1"
     carrierPanelIdentifier:@"carrier-1"
                sessionGUID:@"session-1"
                 leasedGrid:VT100GridSizeMake(42, 20)
               savedMacGrid:macGrid
                        now:100];
    [store heartbeatSessionGUID:@"session-1" token:@"token-1" now:103];

    XCTAssertEqual([store takeExpiredLeasesAt:107 timeout:5].count, 0u);
    NSArray<TideyNativeTerminalSizeLease *> *expired =
        [store takeExpiredLeasesAt:109 timeout:5];
    XCTAssertEqual(expired.count, 1u);
    XCTAssertTrue(VT100GridSizeEquals(expired[0].savedMacGrid, macGrid));
    XCTAssertNil([store leaseForSessionGUID:@"session-1"]);
    XCTAssertNil([store heartbeatSessionGUID:@"session-1" token:@"token-1" now:110]);
    XCTAssertEqual([store takeExpiredLeasesAt:120 timeout:5].count, 0u);
}

- (void)testNativeTerminalSizeLeaseGatesApplyAndRestoresBeforeGUIDReplacement {
    TideyNativeTerminalSizeLeaseStore *store = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeLeaseStore alloc] init]);
    PseudoTerminal *terminal = TideySocketTestAutorelease(
        class_createInstance([PseudoTerminal class], 0));
    [terminal setValue:store forKey:@"tideyNativeTerminalSizeLeaseStore"];
    TideyNativeTerminalSizeProbeSession *probe = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeProbeSession alloc] init]);
    probe.guid = @"session-1";
    const VT100GridSize phoneGrid = VT100GridSizeMake(42, 20);
    const VT100GridSize latestMacGrid = VT100GridSizeMake(118, 44);

    [store acquireWithToken:@"token-1"
     carrierPanelIdentifier:@"carrier-1"
                sessionGUID:probe.guid
                 leasedGrid:phoneGrid
               savedMacGrid:VT100GridSizeMake(132, 48)
                        now:100];

    XCTAssertTrue([terminal tideySession:(PTYSession *)probe
           shouldApplyNativeTerminalSize:phoneGrid]);
    XCTAssertFalse([terminal tideySession:(PTYSession *)probe
            shouldApplyNativeTerminalSize:latestMacGrid]);
    [terminal tideySessionWillReplaceGUID:(PTYSession *)probe];

    XCTAssertEqual(probe.applyCount, 1u);
    XCTAssertTrue(VT100GridSizeEquals(probe.appliedGrid, latestMacGrid));
    XCTAssertNil([store leaseForSessionGUID:probe.guid]);
    [terminal tideySessionWillReplaceGUID:(PTYSession *)probe];
    XCTAssertEqual(probe.applyCount, 1u);
}

- (void)testExpiredNativeTerminalSizeLeaseRestoresAfterCarrierMove {
    TideyNativeTerminalSizeLeaseStore *store = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeLeaseStore alloc] init]);
    TideyNativeTerminalSizeProbeSession *probe = TideySocketTestAutorelease(
        [[TideyNativeTerminalSizeProbeSession alloc] init]);
    probe.guid = @"session-1";
    const VT100GridSize macGrid = VT100GridSizeMake(132, 48);

    [store acquireWithToken:@"token-1"
     carrierPanelIdentifier:@"old-carrier"
                sessionGUID:probe.guid
                 leasedGrid:VT100GridSizeMake(42, 20)
               savedMacGrid:macGrid
                        now:100];
    TideyNativeTerminalSizeLease *expired =
        [store takeExpiredLeasesAt:106 timeout:5].firstObject;

    PseudoTerminal *terminal = TideySocketTestAutorelease(
        class_createInstance([PseudoTerminal class], 0));
    [terminal tideyRestoreExpiredNativeTerminalSizeLease:expired
                                         resolvedSession:(PTYSession *)probe];

    XCTAssertEqual(probe.applyCount, 1u);
    XCTAssertTrue(VT100GridSizeEquals(probe.appliedGrid, macGrid));
}

- (void)testNativeSessionProjectionFlattensTwoLeaves {
    NSArray<NSDictionary *> *projected = [PseudoTerminal
        tideyNativeSessionPanelSummariesForCarrierPanelIdentifier:@"carrier-1"
                                               basePanelSummaries:@[
        @{ @"native_session_id": @"session-1", @"title": @"Claude" },
        @{ @"native_session_id": @"session-2", @"title": @"Codex" },
    ]];

    XCTAssertEqual(projected.count, 2u);
    XCTAssertEqualObjects(projected[0][@"panel_id"], @"native-session:carrier-1:session-1");
    XCTAssertEqualObjects(projected[0][@"carrier_panel_id"], @"carrier-1");
    XCTAssertEqualObjects(projected[0][@"native_session_id"], @"session-1");
    XCTAssertEqualObjects(projected[0][@"logical_kind"], @"native_session");
    XCTAssertEqualObjects(projected[0][@"title"], @"Claude");
    XCTAssertEqualObjects(projected[1][@"panel_id"], @"native-session:carrier-1:session-2");
    XCTAssertEqualObjects(projected[1][@"title"], @"Codex");
}

- (void)testNativeSessionResolverRejectsCarrierMismatch {
    NSString *panelID = @"native-session:carrier-1:session-1";

    XCTAssertEqualObjects(
        [PseudoTerminal tideyValidatedNativeSessionIdentifierForPanelIdentifier:panelID
                                                  actualCarrierPanelIdentifier:@"carrier-1"],
        @"session-1");
    XCTAssertNil(
        [PseudoTerminal tideyValidatedNativeSessionIdentifierForPanelIdentifier:panelID
                                                  actualCarrierPanelIdentifier:@"carrier-2"]);
    XCTAssertNil(
        [PseudoTerminal tideyValidatedNativeSessionIdentifierForPanelIdentifier:@"carrier-1"
                                                  actualCarrierPanelIdentifier:@"carrier-1"]);
}

- (void)testNativeSessionEventDiffUsesExactLogicalIDs {
    NSDictionary *unchanged = @{
        @"panel_id": @"native-session:carrier-1:session-1",
        @"title": @"Claude",
    };
    NSDictionary *removed = @{
        @"panel_id": @"native-session:carrier-1:session-2",
        @"title": @"Codex",
    };
    NSDictionary *created = @{
        @"panel_id": @"native-session:carrier-1:session-3",
        @"title": @"Shell",
    };

    NSDictionary<NSString *, NSArray<NSDictionary *> *> *diff = [PseudoTerminal
        tideyNativeSessionPanelEventDiffFromPreviousSummaries:@[ unchanged, removed ]
                                             currentSummaries:@[ unchanged, created ]];

    XCTAssertEqualObjects(diff[@"created"], @[ created ]);
    XCTAssertEqualObjects(diff[@"updated"], @[]);
    XCTAssertEqualObjects(diff[@"closed"], @[ removed ]);
}

- (void)testNativeSessionEventDiffRetainsSoleOwnedPreviousCacheValue {
    sTideyNativeSessionPreviousSummaryDidDeallocate = NO;
    sTideyNativeSessionPreviousSummaryWasDeallocatedBeforeDiff = NO;

    NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *summaryCache =
        [NSMutableDictionary dictionary];
    TideyNativeSessionPreviousSummaryDeallocProbe *deallocProbe =
        [[TideyNativeSessionPreviousSummaryDeallocProbe alloc] init];
    NSDictionary *previousSummary = [[NSDictionary alloc] initWithObjectsAndKeys:
        deallocProbe, @"dealloc_probe", nil];
    NSArray<NSDictionary *> *previousSummaries =
        [[NSArray alloc] initWithObjects:previousSummary, nil];
    [deallocProbe release];
    [previousSummary release];
    summaryCache[@"carrier-1"] = previousSummaries;
    [previousSummaries release];

    NSArray<NSDictionary *> *currentSummaries = @[
        @{ @"panel_id": @"native-session:carrier-1:session-2" },
    ];
    NSDictionary *diff = [TideyNativeSessionCacheTransitionProbeTerminal
        tideyNativeSessionPanelEventDiffForCarrierPanelIdentifier:@"carrier-1"
                                                     summaryCache:summaryCache
                                                 currentSummaries:currentSummaries];

    XCTAssertFalse(sTideyNativeSessionPreviousSummaryWasDeallocatedBeforeDiff);
    XCTAssertTrue(sTideyNativeSessionPreviousSummaryDidDeallocate);
    XCTAssertEqualObjects(summaryCache[@"carrier-1"], currentSummaries);
    XCTAssertNotNil(diff);
}

- (void)testNativeSessionActionPoliciesPreserveFocusAndFailClosed {
    NSString *logicalPanelID = @"native-session:carrier-1:session-1";

    XCTAssertFalse([PseudoTerminal
        tideyRemoteSelectionShouldMutateMacForPanelIdentifier:logicalPanelID]);
    XCTAssertTrue([PseudoTerminal
        tideyRemoteSelectionShouldMutateMacForPanelIdentifier:@"carrier-1"]);

    XCTAssertFalse([PseudoTerminal
        tideyCloseShouldUseCarrierForPanelIdentifier:logicalPanelID
                              nativeSessionAvailable:YES]);
    XCTAssertFalse([PseudoTerminal
        tideyCloseShouldUseCarrierForPanelIdentifier:logicalPanelID
                              nativeSessionAvailable:NO]);
    XCTAssertTrue([PseudoTerminal
        tideyCloseShouldUseCarrierForPanelIdentifier:@"carrier-1"
                              nativeSessionAvailable:NO]);
}

- (void)testNativeSessionRestartRefreshesLogicalEventDiff {
    TideyNativeSessionRestartProbeTerminal *terminal = TideySocketTestAutorelease(
        class_createInstance([TideyNativeSessionRestartProbeTerminal class], 0));

    [terminal tab:nil sessionDidRestart:nil];

    XCTAssertTrue(terminal.didRefreshNativeSessionProjection);
}

- (void)testTideyGridSnapshotSeamMatchesExistingRowProjection {
    VT100Grid *grid = TideySocketTestAutorelease(
        [[VT100Grid alloc] initWithSize:VT100GridSizeMake(2, 1) delegate:nil]);
    screen_char_t *cells = [grid screenCharsAtLineNumber:0];
    cells[0].code = 'O';
    cells[1].code = 'K';
    grid.cursor = VT100GridCoordMake(1, 0);

    NSDictionary *fromGrid = [PseudoTerminal tideySnapshotForGrid:grid cursorVisible:NO];
    NSData *row = [NSData dataWithBytes:cells length:sizeof(screen_char_t) * 2];
    NSDictionary *fromRows = [PseudoTerminal tideySnapshotForScreenCharacterRows:@[ row ]
                                                                             width:2
                                                                            height:1
                                                                           cursorX:1
                                                                           cursorY:0
                                                                     cursorVisible:NO];

    XCTAssertEqualObjects(fromGrid, fromRows);
}

- (void)testTideySnapshotUsesSynchronizedVisibleGrid {
    VT100Grid *currentGrid = TideySocketTestAutorelease(
        [[VT100Grid alloc] initWithSize:VT100GridSizeMake(1, 1) delegate:nil]);
    [currentGrid screenCharsAtLineNumber:0][0].code = 'N';
    currentGrid.cursor = VT100GridCoordMake(1, 0);

    VT100Grid *visibleGrid = TideySocketTestAutorelease(
        [[VT100Grid alloc] initWithSize:VT100GridSizeMake(1, 1) delegate:nil]);
    [visibleGrid screenCharsAtLineNumber:0][0].code = 'S';
    visibleGrid.cursor = VT100GridCoordMake(0, 0);
    PTYTextViewSynchronousUpdateState *synchronizedState =
        TideySocketTestAutorelease([[PTYTextViewSynchronousUpdateState alloc] init]);
    synchronizedState.grid = visibleGrid;
    synchronizedState.cursorVisible = NO;

    NSDictionary *duringUpdate = [PseudoTerminal
        tideyPresentedSnapshotForCurrentGrid:currentGrid
                               cursorVisible:YES
                           synchronizedState:synchronizedState];
    XCTAssertEqualObjects(duringUpdate[@"output"], @"S");
    XCTAssertEqualObjects(duringUpdate[@"cursor_col"], @0);
    XCTAssertEqualObjects(duringUpdate[@"cursor_visible"], @NO);

    NSDictionary *afterUpdate = [PseudoTerminal
        tideyPresentedSnapshotForCurrentGrid:currentGrid
                               cursorVisible:YES
                           synchronizedState:nil];
    XCTAssertEqualObjects(afterUpdate[@"output"], @"N");
    XCTAssertEqualObjects(afterUpdate[@"cursor_col"], @1);
    XCTAssertEqualObjects(afterUpdate[@"cursor_visible"], @YES);
}

- (void)testTideyANSIGridSnapshotPreservesForegroundAndTextStyles {
    screen_char_t cells[3] = { 0 };
    cells[0].code = 'A';
    cells[0].foregroundColorMode = ColorModeNormal;
    cells[0].foregroundColor = kiTermScreenCharAnsiColorCyan;
    cells[0].bold = 1;

    cells[1].code = 'B';
    cells[1].foregroundColorMode = ColorModeAlternate;
    cells[1].foregroundColor = ALTSEM_DEFAULT;
    cells[1].backgroundColorMode = ColorModeAlternate;
    cells[1].backgroundColor = ALTSEM_DEFAULT;
    cells[1].faint = 1;
    cells[1].italic = 1;
    cells[1].underline = 1;
    cells[1].inverse = 1;

    cells[2].code = 'C';
    cells[2].foregroundColorMode = ColorModeAlternate;
    cells[2].foregroundColor = ALTSEM_DEFAULT;
    cells[2].backgroundColorMode = ColorModeNormal;
    cells[2].backgroundColor = kiTermScreenCharAnsiColorGreen;
    cells[2].blink = 1;
    cells[2].invisible = 1;
    cells[2].strikethrough = 1;

    NSData *row = [NSData dataWithBytes:cells length:sizeof(cells)];
    NSDictionary *snapshot = [PseudoTerminal tideySnapshotForScreenCharacterRows:@[ row ]
                                                                             width:3
                                                                            height:1
                                                                           cursorX:2
                                                                           cursorY:0
                                                                     cursorVisible:NO];

    XCTAssertEqualObjects(snapshot[@"output"], @"ABC");
    XCTAssertEqualObjects(snapshot[@"terminal_grid_version"], @1);
    XCTAssertEqualObjects(snapshot[@"cols"], @3);
    XCTAssertEqualObjects(snapshot[@"rows"], @1);
    XCTAssertEqualObjects(snapshot[@"cursor_row"], @0);
    XCTAssertEqualObjects(snapshot[@"cursor_col"], @2);
    XCTAssertEqualObjects(snapshot[@"cursor_visible"], @NO);

    NSData *captureData = [[NSData alloc] initWithBase64EncodedString:snapshot[@"ansi_active_capture_base64"]
                                                              options:0];
    NSString *capture = [[NSString alloc] initWithData:captureData encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(capture,
                          @"\033[0;36;1mA\033[0;2;3;4;7mB\033[0;42;5;8;9mC\033[0m");
}

- (void)testTideyANSIGridSnapshotAddsStyledScrollbackCapture {
    screen_char_t firstCells[3] = { 0 };
    firstCells[0].code = 'O';
    firstCells[0].foregroundColorMode = ColorModeNormal;
    firstCells[0].foregroundColor = kiTermScreenCharAnsiColorCyan;
    firstCells[0].bold = 1;
    firstCells[1].code = 'L';
    firstCells[1].foregroundColorMode = ColorModeNormal;
    firstCells[1].foregroundColor = kiTermScreenCharAnsiColorCyan;
    firstCells[1].bold = 1;
    firstCells[2].code = 'D';
    firstCells[2].foregroundColorMode = ColorModeNormal;
    firstCells[2].foregroundColor = kiTermScreenCharAnsiColorCyan;
    firstCells[2].bold = 1;

    screen_char_t secondCells[3] = { 0 };
    secondCells[0].code = 'L';
    secondCells[1].code = 'S';
    NSData *firstRow = [NSData dataWithBytes:firstCells length:sizeof(firstCells)];
    NSData *secondRow = [NSData dataWithBytes:secondCells length:sizeof(secondCells)];
    NSDictionary *activeSnapshot = @{
        @"output": @"NOW",
        @"cursor_row": @0,
        @"cursor_col": @3,
        @"cursor_visible": @YES,
        @"terminal_grid_version": @1,
        @"ansi_active_capture_base64": [[@"NOW" dataUsingEncoding:NSUTF8StringEncoding]
            base64EncodedStringWithOptions:0],
        @"cols": @3,
        @"rows": @1,
    };

    NSDictionary *snapshot = [PseudoTerminal
        tideySnapshot:activeSnapshot
        byAddingScrollbackScreenCharacterRows:@[ firstRow, secondRow ]
        width:3];

    XCTAssertEqualObjects(snapshot[@"output"], @"NOW");
    XCTAssertEqualObjects(snapshot[@"ansi_active_capture_base64"],
                          activeSnapshot[@"ansi_active_capture_base64"]);
    XCTAssertEqualObjects(snapshot[@"scrollback_rows"], @2);
    NSString *encodedScrollback = snapshot[@"ansi_scrollback_capture_base64"];
    XCTAssertNotNil(encodedScrollback);
    if (!encodedScrollback) {
        return;
    }
    NSData *captureData = [[NSData alloc]
        initWithBase64EncodedString:encodedScrollback
        options:0];
    NSString *capture = [[NSString alloc] initWithData:captureData
                                               encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(capture, @"\033[0;36;1mOLD\033[0m\r\nLS");
}

@end

@interface TideySocketServerTests : XCTestCase
@end

@implementation TideySocketServerTests

- (void)testPingRequestReturnsPong {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-1",
        @"action": @"ping",
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"id"], @"req-1");
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"pong"], @YES);
}

- (void)testListWorkspacesReturnsWorkspacesArray {
    NSArray *workspaces = @[
        @{ @"workspace_id": @"ws-1", @"title": @"Claude", @"state": @"running" },
        @{ @"workspace_id": @"ws-2", @"title": @"Codex", @"state": @"idle" },
    ];
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-2",
        @"action": @"list_workspaces",
    }
                                                                  workspaceSummaries:workspaces
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"workspaces"], workspaces);
}

- (void)testListWorkspacesCanScopeToSourceWorkspaceWindow {
    NSArray *workspaces = @[
        @{ @"workspace_id": @"ws-other", @"title": @"Other Window", @"window_guid": @"window-1" },
        @{ @"workspace_id": @"ws-source", @"title": @"Current", @"window_guid": @"window-2" },
        @{ @"workspace_id": @"ws-sibling", @"title": @"Sibling", @"window_guid": @"window-2" },
    ];
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-scoped",
        @"action": @"list_workspaces",
        @"params": @{ @"source_workspace_id": @"ws-source" },
    }
                                                                  workspaceSummaries:workspaces
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"workspaces"], (@[
        workspaces[1],
        workspaces[2],
    ]));
}

- (void)testListWorkspacesCanScopeToExplicitWindowGUID {
    NSArray *workspaces = @[
        @{ @"workspace_id": @"ws-other", @"title": @"Other Window", @"window_guid": @"window-1" },
        @{ @"workspace_id": @"ws-current", @"title": @"Current", @"window_guid": @"window-2" },
    ];
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-window",
        @"action": @"list_workspaces",
        @"params": @{ @"source_window_guid": @"window-2" },
    }
                                                                  workspaceSummaries:workspaces
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"workspaces"], (@[ workspaces[1] ]));
}

- (void)testListWorkspacesIgnoresBareWorkspaceIDForCompatibility {
    NSArray *workspaces = @[
        @{ @"workspace_id": @"ws-other", @"title": @"Other Window", @"window_guid": @"window-1" },
        @{ @"workspace_id": @"ws-current", @"title": @"Current", @"window_guid": @"window-2" },
    ];
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-bare-workspace",
        @"action": @"list_workspaces",
        @"params": @{ @"workspace_id": @"ws-current" },
    }
                                                                  workspaceSummaries:workspaces
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"workspaces"], workspaces);
}

- (void)testSendInputRequiresParams {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-3",
        @"action": @"send_input",
        @"params": @{ @"workspace_id": @"ws-1" },
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:^BOOL(NSString *workspaceID, NSString *input) {
                                                                        return YES;
                                                                    }
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects(response[@"error"][@"code"], @"invalid_params");
}

- (void)testGetRecentOutputRequiresWorkspaceID {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-4",
        @"action": @"get_recent_output",
        @"params": @{ @"max_lines": @10 },
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:^NSString *(NSString *workspaceID) {
                                                                    return @"ignored";
                                                                }];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects(response[@"error"][@"code"], @"invalid_params");
}

- (void)testNativeTerminalSizeActionDispatchValidatesExactIdentityDimensionsAndToken {
    __block NSMutableArray<NSDictionary *> *calls = [NSMutableArray array];
    TideySocketNativeTerminalSizeHandler handler = ^NSDictionary *(
        NSString *action,
        NSString *panelID,
        NSString *token,
        NSInteger columns,
        NSInteger rows) {
        [calls addObject:@{
            @"action": action,
            @"panel_id": panelID,
            @"token": token ?: @"",
            @"cols": @(columns),
            @"rows": @(rows),
        }];
        return @{
            @"accepted": @YES,
            @"token": token ?: @"new-token",
            @"expires_in_ms": @5000,
        };
    };
    NSString *panelID = @"native-session:carrier-1:session-1";

    NSDictionary *acquire = [TideySocketServer
        tideyNativeTerminalSizeResponseForRequestID:@"acquire"
        action:@"native_terminal_size_acquire"
        source:@{ @"panel_id": panelID, @"cols": @42, @"rows": @20 }
        handler:handler];
    XCTAssertEqualObjects(acquire[@"ok"], @YES);
    XCTAssertEqualObjects(acquire[@"result"][@"token"], @"new-token");

    NSDictionary *update = [TideySocketServer
        tideyNativeTerminalSizeResponseForRequestID:@"update"
        action:@"native_terminal_size_update"
        source:@{ @"panel_id": panelID, @"token": @"token-1", @"cols": @50, @"rows": @22 }
        handler:handler];
    XCTAssertEqualObjects(update[@"ok"], @YES);

    NSDictionary *heartbeat = [TideySocketServer
        tideyNativeTerminalSizeResponseForRequestID:@"heartbeat"
        action:@"native_terminal_size_heartbeat"
        source:@{ @"panel_id": panelID, @"token": @"token-1" }
        handler:handler];
    XCTAssertEqualObjects(heartbeat[@"ok"], @YES);

    NSDictionary *release = [TideySocketServer
        tideyNativeTerminalSizeResponseForRequestID:@"release"
        action:@"native_terminal_size_release"
        source:@{ @"panel_id": panelID, @"token": @"token-1" }
        handler:handler];
    XCTAssertEqualObjects(release[@"ok"], @YES);
    XCTAssertEqual(calls.count, 4u);
    XCTAssertEqualObjects(calls[0][@"cols"], @42);
    XCTAssertEqualObjects(calls[1][@"rows"], @22);
    XCTAssertEqualObjects(calls[2][@"cols"], @0);
    XCTAssertEqualObjects(calls[3][@"rows"], @0);

    for (NSDictionary *invalidSource in @[
        @{ @"panel_id": @"carrier-1", @"cols": @42, @"rows": @20 },
        @{ @"panel_id": panelID, @"cols": @0, @"rows": @20 },
        @{ @"panel_id": panelID, @"cols": @42, @"rows": @1001 },
    ]) {
        NSDictionary *invalid = [TideySocketServer
            tideyNativeTerminalSizeResponseForRequestID:@"invalid"
            action:@"native_terminal_size_acquire"
            source:invalidSource
            handler:handler];
        XCTAssertEqualObjects(invalid[@"ok"], @NO);
        XCTAssertEqualObjects(invalid[@"error"][@"code"], @"invalid_params");
    }

    NSDictionary *missingToken = [TideySocketServer
        tideyNativeTerminalSizeResponseForRequestID:@"missing-token"
        action:@"native_terminal_size_update"
        source:@{ @"panel_id": panelID, @"cols": @42, @"rows": @20 }
        handler:handler];
    XCTAssertEqualObjects(missingToken[@"ok"], @NO);
    XCTAssertEqualObjects(missingToken[@"error"][@"code"], @"invalid_params");

    NSDictionary *stale = [TideySocketServer
        tideyNativeTerminalSizeResponseForRequestID:@"stale"
        action:@"native_terminal_size_release"
        source:@{ @"panel_id": panelID, @"token": @"stale-token" }
        handler:^NSDictionary *(NSString *action, NSString *panelID, NSString *token, NSInteger columns, NSInteger rows) {
            return @{ @"accepted": @NO, @"error_code": @"stale_lease" };
        }];
    XCTAssertEqualObjects(stale[@"ok"], @NO);
    XCTAssertEqualObjects(stale[@"error"][@"code"], @"stale_lease");
}

- (void)testTrimmedRecentOutputSnapshotPreservesCursorVisibility {
    TideySocketServer *server = [[TideySocketServer alloc] init];

    NSDictionary *trimmed = [server trimmedRecentOutputSnapshot:@{
        @"output": @"first\nsecond",
        @"cursor_row": @1,
        @"cursor_col": @3,
        @"cursor_visible": @NO,
    }
                                                        maxLines:1
                                                        maxChars:20];

    XCTAssertEqualObjects(trimmed[@"cursor_visible"], @NO);
}

- (void)testTrimmedRecentOutputSnapshotPreservesUntrimmedANSIGridMetadata {
    TideySocketServer *server = [[TideySocketServer alloc] init];
    NSString *ansiCapture = [[@"\033[38;5;6mfirst\033[0m\nsecond"
        dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    NSString *scrollbackCapture = [[@"older\r\nold"
        dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    NSDictionary *snapshot = @{
        @"output": @"first\nsecond",
        @"cursor_row": @1,
        @"cursor_col": @3,
        @"cursor_visible": @NO,
        @"terminal_grid_version": @1,
        @"ansi_active_capture_base64": ansiCapture,
        @"ansi_scrollback_capture_base64": scrollbackCapture,
        @"scrollback_rows": @2,
        @"cols": @6,
        @"rows": @2,
    };

    NSDictionary *untrimmed = [server trimmedRecentOutputSnapshot:snapshot
                                                          maxLines:2
                                                          maxChars:20];
    XCTAssertEqualObjects(untrimmed[@"terminal_grid_version"], @1);
    XCTAssertEqualObjects(untrimmed[@"ansi_active_capture_base64"], ansiCapture);
    XCTAssertEqualObjects(untrimmed[@"ansi_scrollback_capture_base64"],
                          scrollbackCapture);
    XCTAssertEqualObjects(untrimmed[@"scrollback_rows"], @2);
    XCTAssertEqualObjects(untrimmed[@"cols"], @6);
    XCTAssertEqualObjects(untrimmed[@"rows"], @2);

    NSDictionary *trimmed = [server trimmedRecentOutputSnapshot:snapshot
                                                        maxLines:1
                                                        maxChars:20];
    XCTAssertNil(trimmed[@"terminal_grid_version"]);
    XCTAssertNil(trimmed[@"ansi_active_capture_base64"]);
    XCTAssertNil(trimmed[@"ansi_scrollback_capture_base64"]);
    XCTAssertNil(trimmed[@"scrollback_rows"]);
    XCTAssertNil(trimmed[@"cols"]);
    XCTAssertNil(trimmed[@"rows"]);
}

- (void)testUnsupportedActionReturnsError {
    NSDictionary *response = [TideySocketServer tideyResponseForRequestMessage:@{
        @"id": @"req-5",
        @"action": @"bogus",
    }
                                                                  workspaceSummaries:nil
                                                                    sendInputHandler:nil
                                                                recentOutputProvider:nil];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects(response[@"error"][@"code"], @"unsupported_action");
}

- (void)testCleanupStaleSocketsRemovesDeadSocketFile {
    NSString *directory = [self temporarySocketDirectory];
    NSString *socketPath = [directory stringByAppendingPathComponent:@"dead.sock"];
    int fd = [self createBoundUnixSocketAtPath:socketPath listen:NO];
    XCTAssertGreaterThanOrEqual(fd, 0);
    close(fd);

    TideySocketServer *server = [[TideySocketServer alloc] init];
    [server cleanupStaleSockets:directory];

    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:socketPath]);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testCleanupStaleSocketsKeepsLiveSocketFile {
    NSString *directory = [self temporarySocketDirectory];
    NSString *socketPath = [directory stringByAppendingPathComponent:@"live.sock"];
    int fd = [self createBoundUnixSocketAtPath:socketPath listen:YES];
    XCTAssertGreaterThanOrEqual(fd, 0);

    TideySocketServer *server = [[TideySocketServer alloc] init];
    [server cleanupStaleSockets:directory];

    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:socketPath]);

    close(fd);
    unlink(socketPath.UTF8String);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}

- (void)testConnectionSetSurvivesRapidAcceptAndClose {
    TideySocketServer *server = [[TideySocketServer alloc] init];
    dispatch_queue_t closeQueue = dispatch_queue_create("com.tidey.tests.socket-close", DISPATCH_QUEUE_CONCURRENT);

    for (NSUInteger i = 0; i < 200; i++) {
        int fds[2] = { -1, -1 };
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
        [server acceptFileDescriptor:fds[0]];
        int writeFD = fds[1];
        dispatch_async(closeQueue, ^{
            close(writeFD);
        });
    }

    XCTAssertTrue([self waitForServer:server connectionCount:0 timeout:3]);
}

- (BOOL)waitForServer:(TideySocketServer *)server connectionCount:(NSUInteger)expected timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        if ([server tideyTestingConnectionCount] == expected) {
            return YES;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return [server tideyTestingConnectionCount] == expected;
}

- (NSString *)temporarySocketDirectory {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tidey-socket-tests.XXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    char *result = mkdtemp(buffer);
    NSString *directory = result ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:result
                                                                                                 length:strlen(result)] : nil;
    free(buffer);
    XCTAssertNotNil(directory);
    return directory;
}

- (int)createBoundUnixSocketAtPath:(NSString *)path listen:(BOOL)shouldListen {
    unlink(path.UTF8String);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return fd;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    NSData *pathData = [path dataUsingEncoding:NSUTF8StringEncoding];
    memcpy(addr.sun_path, pathData.bytes, pathData.length);
    addr.sun_path[pathData.length] = '\0';
    if (bind(fd, (const struct sockaddr *)&addr, (socklen_t)sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    if (shouldListen && listen(fd, 1) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

@end
