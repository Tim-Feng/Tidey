#import <XCTest/XCTest.h>

#import "iTerm2SharedARC-Swift.h"
#import "iTermPreferences.h"
#import "iTermRestorableStateDriver.h"

@interface TideyNativeRestorableStateIndexSpy : NSObject <iTermRestorableStateIndex>
@property(nonatomic, strong) TideyRestorableStatePreflight *preflight;
@end

@implementation TideyNativeRestorableStateIndexSpy

- (NSUInteger)restorableStateIndexNumberOfWindows {
    return 0;
}

- (void)restorableStateIndexUnlink {
}

- (id<iTermRestorableStateRecord>)restorableStateRecordAtIndex:(NSUInteger)i {
    return nil;
}

- (TideyRestorableStatePreflight *)restorableStateIndexPreflight {
    return self.preflight;
}

@end

@interface TideyNativeRestorableStateRestorerSpy : NSObject <iTermRestorableStateRestorer>
@property(nonatomic, strong) id<iTermRestorableStateIndex> index;
@end

@implementation TideyNativeRestorableStateRestorerSpy

- (void)loadRestorableStateIndexWithCompletion:
    (void (^)(id<iTermRestorableStateIndex>))completion {
    completion(self.index);
}

- (void)restoreWindowWithRecord:(id<iTermRestorableStateRecord>)record
                     completion:
    (void (^)(NSString *windowIdentifier, NSWindow *window))completion {
}

- (void)restoreApplicationState {
}

- (void)eraseStateRestorationDataSynchronously:(BOOL)sync {
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
