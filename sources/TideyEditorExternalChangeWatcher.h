#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (^TideyEditorExternalChangeStartWatchBlock)(NSString *path);
typedef void (^TideyEditorExternalChangeStopWatchBlock)(id token);
typedef NSString * _Nullable (^TideyEditorExternalChangeReadFileBlock)(NSString *path, NSError **error);
typedef void (^TideyEditorExternalChangeDidReloadBlock)(NSString *newContent);

@interface TideyEditorExternalChangeWatcher : NSObject

@property(nonatomic, copy, nullable) TideyEditorExternalChangeStartWatchBlock startWatching;
@property(nonatomic, copy, nullable) TideyEditorExternalChangeStopWatchBlock stopWatching;
@property(nonatomic, copy, nullable) TideyEditorExternalChangeReadFileBlock readFile;
@property(nonatomic, readonly, copy, nullable) NSString *watchedPath;
@property(nonatomic, readonly, strong, nullable) id watchToken;

- (void)syncToPath:(nullable NSString *)path;
- (void)stopWatchingCurrentPath;
- (void)handleExternalChangeForPath:(nullable NSString *)path
                              dirty:(BOOL)dirty
                     currentContent:(nullable NSString *)currentContent
                          didReload:(nullable TideyEditorExternalChangeDidReloadBlock)didReload;

@end

NS_ASSUME_NONNULL_END
