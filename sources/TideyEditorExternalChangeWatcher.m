#import "TideyEditorExternalChangeWatcher.h"

@interface TideyEditorExternalChangeWatcher ()
@property(nonatomic, readwrite, copy, nullable) NSString *watchedPath;
@property(nonatomic, readwrite, strong, nullable) id watchToken;
@end

@implementation TideyEditorExternalChangeWatcher

- (void)syncToPath:(NSString *)path {
    if (path.length == 0) {
        [self stopWatchingCurrentPath];
        return;
    }
    if ([self.watchedPath isEqualToString:path]) {
        return;
    }
    if (self.watchToken) {
        [self stopWatchingCurrentPath];
    }
    id token = self.startWatching ? self.startWatching(path) : nil;
    self.watchToken = token;
    self.watchedPath = token ? [path copy] : nil;
}

- (void)stopWatchingCurrentPath {
    if (self.watchToken && self.stopWatching) {
        self.stopWatching(self.watchToken);
    }
    self.watchToken = nil;
    self.watchedPath = nil;
}

- (void)handleExternalChangeForPath:(NSString *)path
                              dirty:(BOOL)dirty
                     currentContent:(NSString *)currentContent
                          didReload:(TideyEditorExternalChangeDidReloadBlock)didReload {
    if (path.length == 0) {
        [self stopWatchingCurrentPath];
        return;
    }
    if (dirty) {
        [self stopWatchingCurrentPath];
        [self syncToPath:path];
        return;
    }
    NSError *error = nil;
    TideyEditorExternalChangeReadFileBlock readFile = self.readFile;
    NSString *contents = readFile
        ? readFile(path, &error)
        : [NSString stringWithContentsOfFile:path
                                    encoding:NSUTF8StringEncoding
                                       error:&error];
    if (contents != nil && ![contents isEqualToString:(currentContent ?: @"")]) {
        if (didReload) {
            didReload(contents);
        }
    }
    [self stopWatchingCurrentPath];
    [self syncToPath:path];
}

@end
