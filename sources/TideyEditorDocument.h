#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TideyEditorDocument : NSObject

@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *content;
@property(nonatomic, copy) NSString *language;
@property(nonatomic) BOOL dirty;
@property(nonatomic) BOOL editable;
@property(nonatomic, copy, nullable) NSString *path;
@property(nonatomic, copy, nullable) NSDate *lastKnownModificationDate;

@end

NS_ASSUME_NONNULL_END
