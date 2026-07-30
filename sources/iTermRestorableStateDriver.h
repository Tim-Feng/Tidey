//
//  iTermRestorableStateDriver.h
//  iTerm2SharedARC
//
//  Created by George Nachman on 7/28/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class NSWindow;
@class TideyRestorableStatePreflight;
@protocol TideyRestorationOrphanAdoptionDiscarding;
@protocol TideyRestorationRejectedServerTerminating;
@protocol TideyRestorationStateErasing;

@protocol iTermRestorableStateRecord<NSObject>
- (void)didFinishRestoring;
- (NSKeyedUnarchiver * _Nullable)unarchiver;
- (NSString *)identifier;
- (NSInteger)windowNumber;
// withPlaintext
- (id<iTermRestorableStateRecord>)recordWithPayload:(id)payload;
@end

@protocol iTermRestorableStateIndex<NSObject>

- (NSUInteger)restorableStateIndexNumberOfWindows;

- (void)restorableStateIndexUnlink;

- (id<iTermRestorableStateRecord> _Nullable)restorableStateRecordAtIndex:(NSUInteger)i;

@property (nonatomic, readonly) TideyRestorableStatePreflight *restorableStateIndexPreflight;

@end

@protocol iTermRestorableStateRestorer<NSObject>

- (void)loadRestorableStateIndexWithCompletion:(void (^)(id<iTermRestorableStateIndex> _Nullable))completion;

- (void)restoreWindowWithRecord:(id<iTermRestorableStateRecord>)record
                     completion:(void (^)(NSString *windowIdentifier, NSWindow *window))completion;

- (void)restoreApplicationState;

- (void)eraseStateRestorationDataSynchronously:(BOOL)sync;

@end

@protocol iTermRestorableStateSaving<NSObject>
- (NSArray<NSWindow *> *)restorableStateWindows;

- (BOOL)restorableStateWindowNeedsRestoration:(NSWindow *)window;

- (void)restorableStateEncodeWithCoder:(NSCoder *)coder
                                window:(NSWindow *)window;

@end

@protocol iTermRestorableStateSaver<NSObject>
@property (nonatomic, weak) id<iTermRestorableStateSaving> delegate;
// Returns NO if an async request couldn't be done because it's busy. Completion is not called in
// that case.
- (BOOL)saveSynchronously:(BOOL)synchronously withCompletion:(void (^)(void))completion;
@end

@interface iTermRestorableStateDriver : NSObject
@property (nonatomic, weak) id<iTermRestorableStateRestorer> restorer;
@property (nonatomic, weak) id<iTermRestorableStateSaver> saver;
@property (nonatomic, readonly) BOOL restoring;
@property (nonatomic, readonly) NSInteger numberOfWindowsRestored;
@property (nonatomic) BOOL needsSave;
@property (nonatomic) BOOL previousExitWasUnclean;
@property (nonatomic, strong, nullable)
    id<TideyRestorationStateErasing> rejectedStateEraser;
@property (nonatomic, strong, nullable)
    id<TideyRestorationOrphanAdoptionDiscarding> orphanAdoptionDiscarder;
@property (nonatomic, strong, nullable)
    id<TideyRestorationRejectedServerTerminating> rejectedServerTerminator;

// callbacks will be removed when they are used and won't be mutated after completion runs.
// ready is called after all windows have been asked to restore.
// completion is called when they are actually restored.
- (void)restoreWithSystemCallbacks:(NSMutableDictionary<NSString *, void (^)(NSWindow *, NSError *)> *)callbacks
                             ready:(void (^)(void))ready
                        completion:(void (^)(void))completion;
- (void)save;
// Main thread. Returns NO when the async save request was not accepted. In that case completion is
// not called.
- (BOOL)saveWithCompletion:(void (^)(void))completion;
// Returns YES only after the synchronous native save was accepted and completed.
- (BOOL)saveSynchronously;
- (void)eraseSynchronously:(BOOL)sync;

@end

NS_ASSUME_NONNULL_END
