#import <Foundation/Foundation.h>

@class TideyStatusEntry;

NS_ASSUME_NONNULL_BEGIN

@interface TideySidebarRowPresentation : NSObject

@property(nonatomic, readonly, copy) NSString *workspaceIdentifier;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy) NSString *subtitle;
@property(nonatomic, readonly) NSInteger unreadCount;
@property(nonatomic, readonly) BOOL pinned;
@property(nonatomic, readonly) BOOL selected;
@property(nonatomic, readonly, copy, nullable) NSString *latestUnreadTitle;
@property(nonatomic, readonly, copy, nullable) NSString *notificationBody;
@property(nonatomic, readonly, copy) NSArray<TideyStatusEntry *> *statusEntries;
@property(nonatomic, readonly) BOOL showsCloseButton;
@property(nonatomic, readonly, copy, nullable) NSString *shortcutHint;
@property(nonatomic, readonly) BOOL hasBody;
@property(nonatomic, readonly) BOOL hasStatus;

- (instancetype)initWithWorkspaceIdentifier:(NSString *)workspaceIdentifier
                                       title:(NSString *)title
                                    subtitle:(NSString *)subtitle
                                 unreadCount:(NSInteger)unreadCount
                                      pinned:(BOOL)pinned
                                    selected:(BOOL)selected
                           latestUnreadTitle:(nullable NSString *)latestUnreadTitle
                            notificationBody:(nullable NSString *)notificationBody
                               statusEntries:(NSArray<TideyStatusEntry *> *)statusEntries
                            showsCloseButton:(BOOL)showsCloseButton
                                shortcutHint:(nullable NSString *)shortcutHint NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
