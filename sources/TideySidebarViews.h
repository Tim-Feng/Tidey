#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern const CGFloat kTideySidebarBadgeSize;
extern const CGFloat kTideySidebarBadgeLeadingInset;
extern const CGFloat kTideySidebarCloseButtonTopInset;
extern const CGFloat kTideySidebarCloseButtonTrailingInset;
extern const CGFloat kTideySidebarCloseButtonSize;

extern NSUserInterfaceItemIdentifier const kTideySidebarCloseViewIdentifier;
extern NSUserInterfaceItemIdentifier const kTideySidebarBadgeViewIdentifier;

FOUNDATION_EXPORT NSView *_Nullable TideyFindCloseView(NSView *container);

@protocol TideySidebarCloseAction <NSObject>
- (void)tideySidebarCloseWorkspaceAtIndex:(NSInteger)row;
@end

@interface TideySidebarTableView : NSTableView {
    NSTrackingArea *_tideyTrackingArea;
    NSInteger _tideyHoveredRow;
}
@property(nonatomic, weak, nullable) id<TideySidebarCloseAction> tideyCloseActionTarget;
- (BOOL)tideyShouldShowCloseButtonForRow:(NSInteger)row;
- (void)updateTideyCloseButtonVisibility;
@end

@interface TideySidebarRowView : NSTableRowView
@end

@interface TideySidebarCellView : NSTableCellView
@end

NS_ASSUME_NONNULL_END
