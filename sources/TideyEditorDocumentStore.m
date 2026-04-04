#import "TideyEditorDocumentStore.h"

#import "TideyEditorDocument.h"

@interface TideyEditorDocumentStore ()
@property(nonatomic, strong) NSMutableDictionary<NSString *, TideyEditorDocument *> *documentsByIdentifier;
@end

@implementation TideyEditorDocumentStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _documentsByIdentifier = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (TideyEditorDocument *)documentForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    return self.documentsByIdentifier[identifier];
}

- (TideyEditorDocument *)documentForPath:(NSString *)path {
    NSString *normalizedPath = [path stringByStandardizingPath];
    TideyEditorDocument *existing = [self documentForIdentifier:normalizedPath];
    if (existing) {
        return existing;
    }
    TideyEditorDocument *document = [[TideyEditorDocument alloc] init];
    document.identifier = normalizedPath;
    document.path = normalizedPath;
    self.documentsByIdentifier[normalizedPath] = document;
    return document;
}

- (TideyEditorDocument *)createUntitledDocument {
    TideyEditorDocument *document = [[TideyEditorDocument alloc] init];
    document.identifier = [NSUUID UUID].UUIDString;
    self.documentsByIdentifier[document.identifier] = document;
    return document;
}

- (void)removeDocument:(TideyEditorDocument *)document {
    if (document.identifier.length == 0) {
        return;
    }
    [self.documentsByIdentifier removeObjectForKey:document.identifier];
}

@end
