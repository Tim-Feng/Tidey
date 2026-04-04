#import "TideyEditorDocument.h"

@implementation TideyEditorDocument

- (instancetype)init {
    self = [super init];
    if (self) {
        _content = @"";
        _language = @"plaintext";
        _editable = YES;
    }
    return self;
}

@end
