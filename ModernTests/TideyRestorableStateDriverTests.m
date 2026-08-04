#import <XCTest/XCTest.h>

#import "iTerm2SharedARC-Swift.h"
#import "iTermEncoderGraphRecord.h"
#import "iTermPreferences.h"
#import "iTermRestorableStateController.h"
#import "iTermRestorableStateDriver.h"
#import "iTermWarning.h"

@interface iTermRestorableStateController (TideyHydrationTesting)
- (instancetype)initWithDriverForTesting:
    (iTermRestorableStateDriver *)driver;
- (void)tideyBeginHydrationTracking;
- (void)tideyCompleteHydrationTracking;
- (BOOL)tideyHydrationComplete;
- (void)tideyNotifyWhenHydrationCompletes:(void (^)(void))completion;
- (BOOL)requestPeriodicSaveWithCompletion:(void (^)(void))completion;
- (void)applicationWillTerminate:(NSNotification *)notification;
@end

@interface TideyNativeRestorableStateRecordSpy :
    NSObject <iTermRestorableStateRecord>
@property(nonatomic, copy) NSString *identifier;
@end

@implementation TideyNativeRestorableStateRecordSpy

- (void)didFinishRestoring {
}

- (NSKeyedUnarchiver *)unarchiver {
    return nil;
}

- (NSInteger)windowNumber {
    return 0;
}

- (id<iTermRestorableStateRecord>)recordWithPayload:(id)payload {
    return self;
}

@end

@interface TideyNativeRestorableStateIndexSpy : NSObject <iTermRestorableStateIndex>
@property(nonatomic, strong) TideyRestorableStatePreflight *preflight;
@property(nonatomic) NSUInteger numberOfWindows;
@property(nonatomic) NSInteger recordRequestCount;
@property(nonatomic, copy)
    NSArray<id<iTermRestorableStateRecord>> *records;
@end

@implementation TideyNativeRestorableStateIndexSpy

- (NSUInteger)restorableStateIndexNumberOfWindows {
    return self.numberOfWindows;
}

- (void)restorableStateIndexUnlink {
}

- (id<iTermRestorableStateRecord>)restorableStateRecordAtIndex:(NSUInteger)i {
    self.recordRequestCount += 1;
    return i < self.records.count ? self.records[i] : nil;
}

- (TideyRestorableStatePreflight *)restorableStateIndexPreflight {
    return self.preflight;
}

@end

@interface TideyNativeHydrationRestorerSpy :
    NSObject <iTermRestorableStateRestorer>
@property(nonatomic, strong) id<iTermRestorableStateIndex> index;
@property(nonatomic, weak) id<iTermRestorableStateRestoring> delegate;
@end

@implementation TideyNativeHydrationRestorerSpy

- (void)loadRestorableStateIndexWithCompletion:
    (void (^)(id<iTermRestorableStateIndex>))completion {
    completion(self.index);
}

- (void)restoreWindowWithRecord:(id<iTermRestorableStateRecord>)record
                     completion:
    (void (^)(NSString *windowIdentifier, NSWindow *window))completion {
    iTermEncoderGraphRecord *graphRecord =
        [iTermEncoderGraphRecord withPODs:@{}
                                  graphs:@[]
                              generation:0
                                     key:@"window"
                              identifier:record.identifier
                                   rowid:nil];
    [self.delegate
        restorableStateRestoreWithRecord:graphRecord
        identifier:record.identifier
        completion:^(NSWindow *window, NSError *error) {
            completion(record.identifier, window);
        }];
}

- (void)restoreApplicationState {
}

- (void)eraseStateRestorationDataSynchronously:(BOOL)sync {
}

@end

@interface TideyNativeHydrationWindowControllerSpy :
    NSObject <NSWindowDelegate, iTermRestorableWindowController>
@property(nonatomic, copy) void (^onHydrate)(void);
@end


@implementation TideyNativeHydrationWindowControllerSpy

- (void)didFinishRestoringWindow {
    if (self.onHydrate) {
        self.onHydrate();
    }
}

@end


@interface TideyNativeRestorableStateControllerDelegateSpy :
    NSObject <iTermRestorableStateControllerDelegate>
@property(nonatomic, copy) NSDictionary<NSString *, NSWindow *> *windows;
@end


@implementation TideyNativeRestorableStateControllerDelegateSpy

- (void)restorableStateDidFinishRequestingRestorations:
    (iTermRestorableStateController *)sender {
}

- (void)restorableStateRestoreWithRecord:(iTermEncoderGraphRecord *)record
                              identifier:(NSString *)identifier
                              completion:
    (void (^)(NSWindow *, NSError *))completion {
    completion(self.windows[identifier], nil);
}

- (void)restorableStateRestoreApplicationStateWithRecord:
    (iTermEncoderGraphRecord *)record {
}

- (void)restorableStateRestoreWithCoder:(NSCoder *)coder
                             identifier:(NSString *)identifier
                             completion:
    (void (^)(NSWindow *, NSError *))completion {
    completion(nil, nil);
}

- (NSArray<NSWindow *> *)restorableStateWindows {
    return self.windows.allValues;
}

- (BOOL)restorableStateWindowNeedsRestoration:(NSWindow *)window {
    return YES;
}

- (void)restorableStateEncodeWithCoder:(NSCoder *)coder
                                window:(NSWindow *)window {
}

@end

@interface TideyNativeRestorableStateRestorerSpy : NSObject <iTermRestorableStateRestorer>
@property(nonatomic, strong) id<iTermRestorableStateIndex> index;
@property(nonatomic) NSInteger restoreWindowCallCount;
@end

@implementation TideyNativeRestorableStateRestorerSpy

- (void)loadRestorableStateIndexWithCompletion:
    (void (^)(id<iTermRestorableStateIndex>))completion {
    completion(self.index);
}

- (void)restoreWindowWithRecord:(id<iTermRestorableStateRecord>)record
                     completion:
    (void (^)(NSString *windowIdentifier, NSWindow *window))completion {
    self.restoreWindowCallCount += 1;
}

- (void)restoreApplicationState {
}

- (void)eraseStateRestorationDataSynchronously:(BOOL)sync {
}

@end

@interface TideyNativeWarningHandlerSpy : NSObject <iTermWarningHandler>
@property(nonatomic, copy) void (^onWarning)(void);
@property(nonatomic) NSInteger warningCount;
@property(nonatomic) NSModalResponse response;
@end

@implementation TideyNativeWarningHandlerSpy

- (NSModalResponse)warningWouldShowAlert:(NSAlert *)alert
                              identifier:(NSString *)identifier {
    self.warningCount += 1;
    if (self.onWarning) {
        self.onWarning();
    }
    return self.response;
}

@end

@interface TideyNativeRejectedStateEraserSpy :
    NSObject <TideyRestorationStateErasing>
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end

@implementation TideyNativeRejectedStateEraserSpy

- (void)eraseRejectedState {
    [self.events addObject:@"erase"];
}

@end

@interface TideyNativeOrphanAdoptionDiscarderSpy :
    NSObject <TideyRestorationOrphanAdoptionDiscarding>
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end

@implementation TideyNativeOrphanAdoptionDiscarderSpy

- (void)discardOrphanAdoptionForLaunch {
    [self.events addObject:@"discard"];
}

@end

@interface TideyNativeRejectedServerTerminatorSpy :
    NSObject <TideyRestorationRejectedServerTerminating>
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, copy)
    NSArray<TideyRestorableSessionServerIdentifier *> *identifiers;
@end

@implementation TideyNativeRejectedServerTerminatorSpy

- (void)terminateRejectedSessionServers:
    (NSArray<TideyRestorableSessionServerIdentifier *> *)identifiers {
    [self.events addObject:@"terminate"];
    self.identifiers = identifiers;
}

@end

@interface TideyNativeRestorableStateSaverSpy : NSObject <iTermRestorableStateSaver>
@property(nonatomic, weak) id<iTermRestorableStateSaving> delegate;
@property(nonatomic, copy, nullable) void (^saveCompletion)(void);
@property(nonatomic) NSInteger saveCallCount;
@end

@implementation TideyNativeRestorableStateSaverSpy

- (BOOL)saveSynchronously:(BOOL)synchronously
           withCompletion:(void (^)(void))completion {
    self.saveCallCount += 1;
    self.saveCompletion = completion;
    return YES;
}

- (void)completeSave {
    void (^completion)(void) = self.saveCompletion;
    self.saveCompletion = nil;
    completion();
}

@end

@interface TideyRestorableStateDriverTests : XCTestCase
@end

@implementation TideyRestorableStateDriverTests

- (void)testHydrationGateSeamsCompile {
    iTermRestorableStateDriver *driver =
        [[iTermRestorableStateDriver alloc] init];
    iTermRestorableStateController *controller =
        [[iTermRestorableStateController alloc]
            initWithDriverForTesting:driver];

    XCTAssertTrue([controller tideyHydrationComplete]);
    [controller tideyBeginHydrationTracking];
    XCTAssertFalse([controller tideyHydrationComplete]);
    [controller tideyCompleteHydrationTracking];
    XCTAssertTrue([controller tideyHydrationComplete]);
}

- (void)testPeriodicSaveStaysClosedUntilAllRestoredWindowsHydrate {
    const BOOL previousPreference =
        [iTermPreferences
            boolForKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    [iTermPreferences
        setBool:YES
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];

    TideyNativeRestorableStateRecordSpy *firstRecord =
        [[TideyNativeRestorableStateRecordSpy alloc] init];
    firstRecord.identifier = @"first-window";
    TideyNativeRestorableStateRecordSpy *secondRecord =
        [[TideyNativeRestorableStateRecordSpy alloc] init];
    secondRecord.identifier = @"second-window";
    TideyNativeRestorableStateIndexSpy *index =
        [[TideyNativeRestorableStateIndexSpy alloc] init];
    index.numberOfWindows = 2;
    index.records = @[ firstRecord, secondRecord ];
    index.preflight =
        [[TideyRestorableStatePreflight alloc]
            initWithStateExists:YES
            isValid:YES
            numberOfWindows:2
            tideySchemaVersion:
                @(TideyRestorableStatePreflight.currentSchemaVersion)
            sessionServerIdentifiers:@[]];

    TideyNativeHydrationRestorerSpy *restorer =
        [[TideyNativeHydrationRestorerSpy alloc] init];
    restorer.index = index;
    TideyNativeRestorableStateSaverSpy *saver =
        [[TideyNativeRestorableStateSaverSpy alloc] init];
    iTermRestorableStateDriver *driver =
        [[iTermRestorableStateDriver alloc] init];
    driver.restorer = restorer;
    driver.saver = saver;
    iTermRestorableStateController *controller =
        [[iTermRestorableStateController alloc]
            initWithDriverForTesting:driver];
    restorer.delegate =
        (id<iTermRestorableStateRestoring>)controller;

    NSWindow *firstWindow =
        [[NSWindow alloc] initWithContentRect:NSZeroRect
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    NSWindow *secondWindow =
        [[NSWindow alloc] initWithContentRect:NSZeroRect
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    TideyNativeHydrationWindowControllerSpy *firstWindowController =
        [[TideyNativeHydrationWindowControllerSpy alloc] init];
    TideyNativeHydrationWindowControllerSpy *secondWindowController =
        [[TideyNativeHydrationWindowControllerSpy alloc] init];
    firstWindow.delegate = firstWindowController;
    secondWindow.delegate = secondWindowController;

    __block NSInteger hydrationCount = 0;
    __block NSMutableArray<NSNumber *> *saveAcceptanceDuringHydration =
        [NSMutableArray array];
    void (^onHydrate)(void) = ^{
        hydrationCount += 1;
        [saveAcceptanceDuringHydration addObject:@(
            [controller requestPeriodicSaveWithCompletion:^{}])];
        if (hydrationCount == 1) {
            [controller applicationWillTerminate:nil];
        }
    };
    firstWindowController.onHydrate = onHydrate;
    secondWindowController.onHydrate = onHydrate;

    TideyNativeRestorableStateControllerDelegateSpy *delegate =
        [[TideyNativeRestorableStateControllerDelegateSpy alloc] init];
    delegate.windows = @{
        firstRecord.identifier: firstWindow,
        secondRecord.identifier: secondWindow,
    };
    controller.delegate = delegate;

    XCTestExpectation *completionExpectation =
        [self expectationWithDescription:@"hydration precedes readiness"];
    [controller restoreWindowsWithCompletion:^{
        XCTAssertEqual(hydrationCount, 2);
        XCTAssertEqualObjects(saveAcceptanceDuringHydration,
                              (@[ @NO, @NO ]));
        XCTAssertEqual(saver.saveCallCount, 0);
        XCTAssertFalse(controller.restoring);
        XCTAssertTrue(
            [controller requestPeriodicSaveWithCompletion:^{}]);
        [completionExpectation fulfill];
    }];

    [self waitForExpectations:@[ completionExpectation ] timeout:2];
    [iTermPreferences
        setBool:previousPreference
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
}

- (void)testBlankLaunchErasesRejectedStateAndDiscardsMatchingOrphanJobs {
    const BOOL previousPreference =
        [iTermPreferences
            boolForKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    [iTermPreferences
        setBool:YES
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    id<iTermWarningHandler> previousHandler = iTermWarning.warningHandler;

    TideyRestorableSessionServerIdentifier *monoServer =
        [[TideyRestorableSessionServerIdentifier alloc]
            initWithMonoServerProcessID:@42];
    TideyRestorableSessionServerIdentifier *multiServer =
        [[TideyRestorableSessionServerIdentifier alloc]
            initWithMultiServerSocketNumber:@7
            childProcessID:@99];
    TideyNativeRestorableStateIndexSpy *index =
        [[TideyNativeRestorableStateIndexSpy alloc] init];
    index.numberOfWindows = 1;
    index.preflight =
        [[TideyRestorableStatePreflight alloc]
            initWithStateExists:YES
            isValid:YES
            numberOfWindows:1
            tideySchemaVersion:
                @(TideyRestorableStatePreflight.currentSchemaVersion)
            sessionServerIdentifiers:@[ monoServer, multiServer ]];
    TideyNativeRestorableStateRestorerSpy *restorer =
        [[TideyNativeRestorableStateRestorerSpy alloc] init];
    restorer.index = index;
    iTermRestorableStateDriver *driver =
        [[iTermRestorableStateDriver alloc] init];
    driver.restorer = restorer;
    driver.previousExitWasUnclean = YES;

    NSMutableArray<NSString *> *events = [NSMutableArray array];
    TideyNativeRejectedStateEraserSpy *eraser =
        [[TideyNativeRejectedStateEraserSpy alloc] init];
    eraser.events = events;
    TideyNativeOrphanAdoptionDiscarderSpy *discarder =
        [[TideyNativeOrphanAdoptionDiscarderSpy alloc] init];
    discarder.events = events;
    TideyNativeRejectedServerTerminatorSpy *terminator =
        [[TideyNativeRejectedServerTerminatorSpy alloc] init];
    terminator.events = events;
    driver.rejectedStateEraser = eraser;
    driver.orphanAdoptionDiscarder = discarder;
    driver.rejectedServerTerminator = terminator;

    TideyNativeWarningHandlerSpy *warningHandler =
        [[TideyNativeWarningHandlerSpy alloc] init];
    warningHandler.response = NSAlertSecondButtonReturn;
    [iTermWarning setWarningHandler:warningHandler];

    __block NSInteger readyCount = 0;
    __block NSInteger completionCount = 0;
    [driver
        restoreWithSystemCallbacks:[NSMutableDictionary dictionary]
        ready:^{
            readyCount += 1;
        }
        completion:^{
            completionCount += 1;
        }];

    XCTAssertEqualObjects(events, (@[ @"erase", @"discard", @"terminate" ]));
    XCTAssertEqual(terminator.identifiers.count, 2);
    XCTAssertTrue(terminator.identifiers[0] == monoServer);
    XCTAssertTrue(terminator.identifiers[1] == multiServer);
    XCTAssertEqual(index.recordRequestCount, 0);
    XCTAssertEqual(restorer.restoreWindowCallCount, 0);
    XCTAssertEqual(readyCount, 1);
    XCTAssertEqual(completionCount, 1);

    [iTermWarning setWarningHandler:previousHandler];
    [iTermPreferences
        setBool:previousPreference
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
}

- (void)testPolicyBlankWithoutCrashPromptDoesNotEraseRejectedState {
    const BOOL previousPreference =
        [iTermPreferences
            boolForKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    [iTermPreferences
        setBool:NO
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    id<iTermWarningHandler> previousHandler = iTermWarning.warningHandler;

    TideyNativeRestorableStateIndexSpy *index =
        [[TideyNativeRestorableStateIndexSpy alloc] init];
    index.numberOfWindows = 1;
    index.preflight =
        [[TideyRestorableStatePreflight alloc]
            initWithStateExists:YES
            isValid:YES
            numberOfWindows:1
            tideySchemaVersion:
                @(TideyRestorableStatePreflight.currentSchemaVersion)
            sessionServerIdentifiers:@[
                [[TideyRestorableSessionServerIdentifier alloc]
                    initWithMonoServerProcessID:@42]
            ]];
    TideyNativeRestorableStateRestorerSpy *restorer =
        [[TideyNativeRestorableStateRestorerSpy alloc] init];
    restorer.index = index;
    iTermRestorableStateDriver *driver =
        [[iTermRestorableStateDriver alloc] init];
    driver.restorer = restorer;
    driver.previousExitWasUnclean = YES;

    NSMutableArray<NSString *> *events = [NSMutableArray array];
    TideyNativeRejectedStateEraserSpy *eraser =
        [[TideyNativeRejectedStateEraserSpy alloc] init];
    eraser.events = events;
    TideyNativeOrphanAdoptionDiscarderSpy *discarder =
        [[TideyNativeOrphanAdoptionDiscarderSpy alloc] init];
    discarder.events = events;
    TideyNativeRejectedServerTerminatorSpy *terminator =
        [[TideyNativeRejectedServerTerminatorSpy alloc] init];
    terminator.events = events;
    driver.rejectedStateEraser = eraser;
    driver.orphanAdoptionDiscarder = discarder;
    driver.rejectedServerTerminator = terminator;

    TideyNativeWarningHandlerSpy *warningHandler =
        [[TideyNativeWarningHandlerSpy alloc] init];
    warningHandler.response = NSAlertSecondButtonReturn;
    [iTermWarning setWarningHandler:warningHandler];

    __block NSInteger readyCount = 0;
    __block NSInteger completionCount = 0;
    [driver
        restoreWithSystemCallbacks:[NSMutableDictionary dictionary]
        ready:^{
            readyCount += 1;
        }
        completion:^{
            completionCount += 1;
        }];

    XCTAssertEqual(warningHandler.warningCount, 0);
    XCTAssertTrue(events.count == 0);
    XCTAssertEqual(index.recordRequestCount, 0);
    XCTAssertEqual(restorer.restoreWindowCallCount, 0);
    XCTAssertEqual(readyCount, 1);
    XCTAssertEqual(completionCount, 1);

    [iTermWarning setWarningHandler:previousHandler];
    [iTermPreferences
        setBool:previousPreference
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
}

- (void)testUncleanTaggedStatePromptsBeforeAnyWindowRestore {
    const BOOL previousPreference =
        [iTermPreferences
            boolForKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    [iTermPreferences
        setBool:YES
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    id<iTermWarningHandler> previousHandler = iTermWarning.warningHandler;

    TideyNativeRestorableStateIndexSpy *index =
        [[TideyNativeRestorableStateIndexSpy alloc] init];
    index.numberOfWindows = 1;
    index.preflight =
        [[TideyRestorableStatePreflight alloc]
            initWithStateExists:YES
            isValid:YES
            numberOfWindows:1
            tideySchemaVersion:
                @(TideyRestorableStatePreflight.currentSchemaVersion)
            sessionServerIdentifiers:@[]];
    TideyNativeRestorableStateRestorerSpy *restorer =
        [[TideyNativeRestorableStateRestorerSpy alloc] init];
    restorer.index = index;
    iTermRestorableStateDriver *driver =
        [[iTermRestorableStateDriver alloc] init];
    driver.restorer = restorer;
    driver.previousExitWasUnclean = YES;

    TideyNativeWarningHandlerSpy *warningHandler =
        [[TideyNativeWarningHandlerSpy alloc] init];
    warningHandler.response = NSAlertSecondButtonReturn;
    __block BOOL promptedBeforeWindowRestore = NO;
    warningHandler.onWarning = ^{
        promptedBeforeWindowRestore =
            (index.recordRequestCount == 0 &&
             restorer.restoreWindowCallCount == 0);
    };
    [iTermWarning setWarningHandler:warningHandler];

    __block NSInteger readyCount = 0;
    __block NSInteger completionCount = 0;
    [driver
        restoreWithSystemCallbacks:[NSMutableDictionary dictionary]
        ready:^{
            readyCount += 1;
        }
        completion:^{
            completionCount += 1;
        }];

    XCTAssertEqual(warningHandler.warningCount, 1);
    XCTAssertTrue(promptedBeforeWindowRestore);
    XCTAssertEqual(index.recordRequestCount, 0);
    XCTAssertEqual(restorer.restoreWindowCallCount, 0);
    XCTAssertEqual(readyCount, 1);
    XCTAssertEqual(completionCount, 1);

    [iTermWarning setWarningHandler:previousHandler];
    [iTermPreferences
        setBool:previousPreference
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
}

- (void)testUntaggedStateRequestsMigrationSaveWhenTideySavingIsEnabled {
    const BOOL previousPreference =
        [iTermPreferences
            boolForKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
    [iTermPreferences
        setBool:YES
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];

    TideyNativeRestorableStateIndexSpy *index =
        [[TideyNativeRestorableStateIndexSpy alloc] init];
    index.preflight =
        [[TideyRestorableStatePreflight alloc]
            initWithStateExists:YES
            isValid:YES
            numberOfWindows:0
            tideySchemaVersion:nil
            sessionServerIdentifiers:@[]];
    TideyNativeRestorableStateRestorerSpy *restorer =
        [[TideyNativeRestorableStateRestorerSpy alloc] init];
    restorer.index = index;
    iTermRestorableStateDriver *driver =
        [[iTermRestorableStateDriver alloc] init];
    driver.restorer = restorer;

    __block NSInteger readyCount = 0;
    __block NSInteger completionCount = 0;
    [driver
        restoreWithSystemCallbacks:[NSMutableDictionary dictionary]
        ready:^{
            readyCount += 1;
        }
        completion:^{
            completionCount += 1;
        }];

    XCTAssertEqual(readyCount, 1);
    XCTAssertEqual(completionCount, 1);
    XCTAssertTrue(driver.needsSave);

    [iTermPreferences
        setBool:previousPreference
        forKey:kPreferenceKeyTideyRestorePreviousWorkspaces];
}

- (void)testNativeSaveCompletionSeamCompiles {
    iTermRestorableStateDriver *driver = [[iTermRestorableStateDriver alloc] init];
    TideyNativeRestorableStateSaverSpy *saver =
        [[TideyNativeRestorableStateSaverSpy alloc] init];
    driver.saver = saver;

    XCTAssertTrue([driver respondsToSelector:@selector(saveWithCompletion:)]);
    if (![driver respondsToSelector:@selector(saveWithCompletion:)]) {
        return;
    }

    __block NSInteger completionCount = 0;
    const BOOL accepted = [driver saveWithCompletion:^{
        completionCount += 1;
    }];

    XCTAssertTrue(accepted);
    XCTAssertEqual(completionCount, 0);

    [saver completeSave];

    XCTAssertEqual(completionCount, 1);
}

@end
