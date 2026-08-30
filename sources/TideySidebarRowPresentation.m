#import "TideySidebarRowPresentation.h"

@implementation TideySidebarRowPresentation

- (instancetype)initWithWorkspaceIdentifier:(NSString *)workspaceIdentifier
                                       title:(NSString *)title
                                    subtitle:(NSString *)subtitle
                                 unreadCount:(NSInteger)unreadCount
                                      pinned:(BOOL)pinned
                                    selected:(BOOL)selected
                           latestUnreadTitle:(NSString *_Nullable)latestUnreadTitle
                            notificationBody:(NSString *_Nullable)notificationBody
                               statusEntries:(NSArray<TideyStatusEntry *> *)statusEntries
                            showsCloseButton:(BOOL)showsCloseButton
                                shortcutHint:(NSString *_Nullable)shortcutHint {
    self = [super init];
    if (self) {
        _workspaceIdentifier = [workspaceIdentifier copy];
        _title = [title copy];
        _subtitle = [subtitle copy];
        _unreadCount = unreadCount;
        _pinned = pinned;
        _selected = selected;
        _latestUnreadTitle = [latestUnreadTitle copy];
        _notificationBody = [notificationBody copy];
        _statusEntries = [statusEntries copy];
        _showsCloseButton = showsCloseButton;
        _shortcutHint = [shortcutHint copy];
    }
    return self;
}

- (BOOL)hasBody {
    return self.notificationBody.length > 0;
}

- (BOOL)hasStatus {
    return self.statusEntries.count > 0;
}

@end
