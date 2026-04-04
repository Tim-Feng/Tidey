#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TideyEditorDocument;

@interface TideyEditorDocumentStore : NSObject

- (nullable TideyEditorDocument *)documentForIdentifier:(NSString *)identifier;
- (TideyEditorDocument *)documentForPath:(NSString *)path;
- (TideyEditorDocument *)createUntitledDocument;
- (void)removeDocument:(TideyEditorDocument *)document;

@end

NS_ASSUME_NONNULL_END
