#import <XCTest/XCTest.h>

#import "iTerm2SharedARC-Swift.h"
#import "iTermPreferences.h"
#import "iTermRestorableStateDriver.h"
#import "iTermWarning.h"

@interface TideyNativeRestorableStateIndexSpy : NSObject <iTermRestorableStateIndex>
@property(nonatomic, strong) TideyRestorableStatePreflight *preflight;
@property(nonatomic) NSUInteger numberOfWindows;
@property(nonatomic) NSInteger recordRequestCount;
@end

@implementation TideyNativeRestorableStateIndexSpy

- (NSUInteger)restorableStateIndexNumberOfWindows {
    return self.numberOfWindows;
}

- (void)restorableStateIndexUnlink {
}

- (id<iTermRestorableStateRecord>)restorableStateRecordAtIndex:(NSUInteger)i {
    self.recordRequestCount += 1;
    return nil;
}

- (TideyRestorableStatePreflight *)restorableStateIndexPreflight {
    return self.preflight;
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
@end

@implementation TideyNativeRestorableStateSaverSpy

- (BOOL)saveSynchronously:(BOOL)synchronously
           withCompletion:(void (^)(void))completion {
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
