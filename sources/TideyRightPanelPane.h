#import <Cocoa/Cocoa.h>

@class TideyEditorTab;

@interface TideyRightPanelPane : NSObject

@property(nonatomic, readonly) NSMutableArray<TideyEditorTab *> *tabs;
@property(nonatomic) NSInteger selectedTabIndex;
@property(nonatomic) NSInteger expandedTabKind;
@property(nonatomic) BOOL editorGroupExpanded;
@property(nonatomic) BOOL browserGroupExpanded;
@property(nonatomic) CGFloat tabStripScrollOffset;
@property(nonatomic) CGFloat tabStripContentWidth;
@property(nonatomic, copy) NSString *lastActiveEditorTabIdentifier;
@property(nonatomic, copy) NSString *lastActiveBrowserTabIdentifier;

@end
