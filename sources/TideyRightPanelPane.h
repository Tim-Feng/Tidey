#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class TideyEditorTab;
@class TideyBrowserEngine;

@interface TideyRightPanelPane : NSObject

@property(nonatomic, readonly) NSMutableArray<TideyEditorTab *> *tabs;
@property(nonatomic, strong) NSView *containerView;
@property(nonatomic, strong) NSView *tabStripView;
@property(nonatomic, strong) NSView *browserContainerView;
@property(nonatomic, strong) NSView *browserToolbarView;
@property(nonatomic, strong) WKWebView *editorWebView;
@property(nonatomic, strong) WKWebView *browserWebView;
@property(nonatomic, strong) TideyBrowserEngine *browserEngine;
@property(nonatomic, strong) NSTextField *browserURLField;
@property(nonatomic, strong) NSButton *browserBackButton;
@property(nonatomic, strong) NSButton *browserForwardButton;
@property(nonatomic, strong) NSButton *browserReloadButton;
@property(nonatomic, strong) NSProgressIndicator *browserLoadingIndicator;
@property(nonatomic, strong) id editorScriptMessageHandler;
@property(nonatomic) NSInteger selectedTabIndex;
@property(nonatomic) NSInteger expandedTabKind;
@property(nonatomic) BOOL editorGroupExpanded;
@property(nonatomic) BOOL browserGroupExpanded;
@property(nonatomic) BOOL editorReady;
@property(nonatomic) BOOL editorShellLoaded;
@property(nonatomic) CGFloat tabStripScrollOffset;
@property(nonatomic) CGFloat tabStripContentWidth;
@property(nonatomic, copy) NSString *pendingEditorValue;
@property(nonatomic, copy) NSString *pendingEditorLanguage;
@property(nonatomic, strong) NSNumber *pendingEditorEditable;
@property(nonatomic, copy) NSString *lastActiveEditorTabIdentifier;
@property(nonatomic, copy) NSString *lastActiveBrowserTabIdentifier;

@end
