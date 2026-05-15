#import "TideySettingsWindowController.h"

#import "TideyKeyboardShortcutsViewController.h"
#import "TideyTerminalAppearanceViewController.h"
#import "iTermRootTerminalView.h"
#import "iTerm2SharedARC-Swift.h"

@import CoreImage;

typedef NS_ENUM(NSInteger, TideySettingsPage) {
    TideySettingsPageAppearance = 0,
    TideySettingsPageShortcuts = 1,
    TideySettingsPageBrowser = 2,
    TideySettingsPageRemote = 3,
};

@interface TideySettingsTabButton : NSButton
@property(nonatomic, assign) BOOL isActiveTab;
@end

@implementation TideySettingsTabButton

- (void)drawRect:(NSRect)dirtyRect {
    if (self.isActiveTab) {
        // Accent dim background: rgba(88,178,220,0.12)
        NSColor *accentDim = [NSColor colorWithSRGBRed:88/255.0 green:178/255.0 blue:220/255.0 alpha:0.12];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6];
        [accentDim setFill];
        [path fill];
    }
    // Draw title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    NSColor *textColor;
    if (self.isActiveTab) {
        textColor = [NSColor colorWithSRGBRed:88/255.0 green:178/255.0 blue:220/255.0 alpha:1.0]; // accent #58B2DC
    } else {
        textColor = [NSColor colorWithSRGBRed:0x88/255.0 green:0x88/255.0 blue:0x88/255.0 alpha:1.0]; // secondary
    }
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: textColor,
        NSParagraphStyleAttributeName: style,
    };
    NSRect textRect = self.bounds;
    NSSize textSize = [self.title sizeWithAttributes:attrs];
    textRect.origin.y = (NSHeight(self.bounds) - textSize.height) / 2.0;
    textRect.size.height = textSize.height;
    [self.title drawInRect:textRect withAttributes:attrs];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

@end

@interface TideyFlippedView : NSView
@end

@implementation TideyFlippedView

- (BOOL)isFlipped {
    return YES;
}

@end

@interface TideyBrowserSettingsViewController : NSViewController
@property(nonatomic, strong) NSTextField *homepageField;
@property(nonatomic, strong) NSTextField *statusLabel;
@end

@implementation TideyBrowserSettingsViewController

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 636)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [self backgroundColor].CGColor;

    NSTextField *titleLabel = [self labelWithFrame:NSMakeRect(24, 28, 420, 20)
                                            string:@"Browser"
                                              font:[NSFont systemFontOfSize:17 weight:NSFontWeightSemibold]
                                             color:[self primaryTextColor]];
    [view addSubview:titleLabel];

    NSTextField *bodyLabel = [self labelWithFrame:NSMakeRect(24, 58, 472, 34)
                                           string:@"Choose the home page used by new Web tabs in Tidey's right panel."
                                             font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                            color:[self secondaryTextColor]];
    bodyLabel.maximumNumberOfLines = 2;
    bodyLabel.usesSingleLineMode = NO;
    bodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [view addSubview:bodyLabel];

    NSTextField *fieldLabel = [self labelWithFrame:NSMakeRect(24, 118, 160, 16)
                                            string:@"Homepage URL"
                                              font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
                                             color:[self secondaryTextColor]];
    [view addSubview:fieldLabel];

    self.homepageField = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 142, 408, 28)];
    self.homepageField.stringValue = [iTermRootTerminalView tideyBrowserHomepageURLString] ?: @"";
    self.homepageField.placeholderString = @"https://example.com";
    self.homepageField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    self.homepageField.target = self;
    self.homepageField.action = @selector(saveHomepage:);
    [view addSubview:self.homepageField];

    NSButton *saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(444, 141, 70, 30)];
    saveButton.title = @"Save";
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.target = self;
    saveButton.action = @selector(saveHomepage:);
    [view addSubview:saveButton];

    NSButton *resetButton = [[NSButton alloc] initWithFrame:NSMakeRect(24, 186, 98, 28)];
    resetButton.title = @"Reset Default";
    resetButton.bezelStyle = NSBezelStyleRounded;
    resetButton.target = self;
    resetButton.action = @selector(resetHomepage:);
    [view addSubview:resetButton];

    self.statusLabel = [self labelWithFrame:NSMakeRect(136, 192, 360, 16)
                                     string:@""
                                       font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                      color:[self secondaryTextColor]];
    [view addSubview:self.statusLabel];

    self.view = view;
}

- (void)saveHomepage:(id)sender {
    NSString *normalized = [iTermRootTerminalView tideyNormalizedBrowserURLString:self.homepageField.stringValue];
    NSURL *url = normalized.length > 0 ? [NSURL URLWithString:normalized] : nil;
    BOOL validURL = url.scheme.length > 0 && (url.host.length > 0 || (url.fileURL && url.path.length > 0));
    if (!validURL) {
        self.statusLabel.textColor = [NSColor colorWithSRGBRed:1.0 green:0.32 blue:0.28 alpha:1.0];
        self.statusLabel.stringValue = @"Enter a valid URL.";
        return;
    }
    [iTermRootTerminalView tideySetBrowserHomepageURLString:normalized];
    self.homepageField.stringValue = [iTermRootTerminalView tideyBrowserHomepageURLString] ?: @"";
    self.statusLabel.textColor = [self secondaryTextColor];
    self.statusLabel.stringValue = @"Saved. New browser tabs will use this home page.";
}

- (void)resetHomepage:(id)sender {
    [iTermRootTerminalView tideySetBrowserHomepageURLString:nil];
    self.homepageField.stringValue = [iTermRootTerminalView tideyBrowserHomepageURLString] ?: @"";
    self.statusLabel.textColor = [self secondaryTextColor];
    self.statusLabel.stringValue = @"Reset to Tidey's default home page.";
}

- (NSTextField *)labelWithFrame:(NSRect)frame
                         string:(NSString *)string
                           font:(NSFont *)font
                          color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = string ?: @"";
    label.font = font;
    label.textColor = color;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

- (NSColor *)backgroundColor {
    return [NSColor colorWithSRGBRed:0x1e/255.0 green:0x1e/255.0 blue:0x1e/255.0 alpha:1.0];
}

- (NSColor *)primaryTextColor {
    return [NSColor colorWithSRGBRed:0.92 green:0.92 blue:0.92 alpha:1.0];
}

- (NSColor *)secondaryTextColor {
    return [NSColor colorWithSRGBRed:0.70 green:0.70 blue:0.72 alpha:1.0];
}

@end

@interface TideyRemoteSettingsViewController : NSViewController

@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *bridgeSetupLabel;
@property(nonatomic, strong) NSImageView *qrImageView;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *reinstallBridgeButton;
@property(nonatomic, strong) NSView *devicesCardView;
@property(nonatomic, strong) NSScrollView *devicesScrollView;
@property(nonatomic, strong) NSView *devicesDocumentView;
@property(nonatomic, strong) NSStackView *devicesStackView;
@property(nonatomic, strong) NSTextField *devicesStatusLabel;
@property(nonatomic, strong) NSTextField *uploadsStatusLabel;
@property(nonatomic, strong) NSTextField *uploadsRetentionLabel;
@property(nonatomic, strong) NSView *uploadsCardView;
@property(nonatomic, strong) NSButton *uploadsRevealButton;
@property(nonatomic, strong) NSButton *uploadsCleanButton;
@property(nonatomic, strong) NSTimer *countdownTimer;
@property(nonatomic, strong) NSTimer *devicesRefreshTimer;
@property(nonatomic, strong) NSDate *expiresAt;
@property(nonatomic, assign) BOOL bridgeReady;
@property(nonatomic, assign) BOOL bridgeInstallInProgress;

- (void)remotePageDidBecomeVisible;
- (void)remotePageDidBecomeHidden;

@end

@implementation TideyRemoteSettingsViewController

- (void)dealloc {
    [self.countdownTimer invalidate];
    [self.devicesRefreshTimer invalidate];
}

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 636)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [self windowBackgroundColor].CGColor;

    static const CGFloat contentX = 20;
    static const CGFloat contentWidth = 520;
    static const CGFloat documentWidth = 560;
    static const CGFloat bottomPadding = 48;
    NSRect introFrame = NSMakeRect(24, 22, 460, 36);
    NSRect pairCardFrame = NSMakeRect(contentX, 76, contentWidth, 334);
    NSRect devicesTitleFrame = NSMakeRect(24, 442, 300, 18);
    NSRect devicesCardFrame = NSMakeRect(contentX, 468, contentWidth, 58);
    NSRect uploadsTitleFrame = NSMakeRect(24, 558, 220, 18);
    NSRect uploadsCardFrame = NSMakeRect(contentX, 584, contentWidth, 62);
    CGFloat documentHeight = NSMaxY(uploadsCardFrame) + bottomPadding;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:view.bounds];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    [view addSubview:scrollView];

    TideyFlippedView *documentView = [[TideyFlippedView alloc] initWithFrame:NSMakeRect(0, 0, documentWidth, documentHeight)];
    documentView.autoresizingMask = NSViewWidthSizable;
    documentView.wantsLayer = YES;
    documentView.layer.backgroundColor = [self windowBackgroundColor].CGColor;
    scrollView.documentView = documentView;

    NSTextField *bodyLabel = [self labelWithFrame:introFrame
                                            string:@"Pair Tidey Remote on iPhone to control this Mac's terminal sessions remotely."
                                              font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                             color:[self secondaryTextColor]];
    bodyLabel.maximumNumberOfLines = 2;
    bodyLabel.usesSingleLineMode = NO;
    bodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [documentView addSubview:bodyLabel];

    NSView *qrCardView = [self cardViewWithFrame:pairCardFrame];
    [documentView addSubview:qrCardView];

    self.qrImageView = [[NSImageView alloc] initWithFrame:NSMakeRect(162, 28, 196, 196)];
    self.qrImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.qrImageView.wantsLayer = YES;
    self.qrImageView.layer.backgroundColor = NSColor.whiteColor.CGColor;
    self.qrImageView.layer.cornerRadius = 4;
    [qrCardView addSubview:self.qrImageView];

    NSTextField *captionLabel = [self labelWithFrame:NSMakeRect(24, 238, 472, 18)
                                              string:@"Scan with Tidey Remote on iPhone"
                                                font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                               color:[self secondaryTextColor]];
    captionLabel.alignment = NSTextAlignmentCenter;
    [qrCardView addSubview:captionLabel];

    self.bridgeSetupLabel = [self labelWithFrame:NSMakeRect(24, 260, 472, 16)
                                          string:@""
                                            font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                           color:[self secondaryTextColor]];
    self.bridgeSetupLabel.alignment = NSTextAlignmentCenter;
    self.bridgeSetupLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [qrCardView addSubview:self.bridgeSetupLabel];

    [qrCardView addSubview:[self dividerWithFrame:NSMakeRect(0, 286, contentWidth, 0.5)]];

    NSTextField *expiresPrefixLabel = [self labelWithFrame:NSMakeRect(18, 301, 62, 16)
                                                    string:@"Expires in"
                                                      font:[self tabularFontOfSize:12 weight:NSFontWeightRegular]
                                                     color:[self secondaryTextColor]];
    [qrCardView addSubview:expiresPrefixLabel];

    self.statusLabel = [self labelWithFrame:NSMakeRect(80, 301, 160, 16)
                                     string:@""
                                       font:[self tabularFontOfSize:12 weight:NSFontWeightMedium]
                                      color:[self accentColor]];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [qrCardView addSubview:self.statusLabel];

    self.refreshButton = [self actionButtonWithTitle:@"Refresh"
                                               frame:NSMakeRect(404, 297, 100, 26)
                                              action:@selector(refreshPairPayload:)
                                         destructive:NO];
    [qrCardView addSubview:self.refreshButton];

    self.reinstallBridgeButton = [self actionButtonWithTitle:@"Reinstall Bridge"
                                                       frame:NSMakeRect(276, 297, 120, 26)
                                                      action:@selector(reinstallBridge:)
                                                 destructive:NO];
    self.reinstallBridgeButton.hidden = YES;
    self.reinstallBridgeButton.toolTip = @"Copy the bundled Tidey Remote Bridge into Application Support and restart its LaunchAgent.";
    [qrCardView addSubview:self.reinstallBridgeButton];

    NSTextField *devicesTitleLabel = [self labelWithFrame:devicesTitleFrame
                                                   string:@"Paired Devices"
                                                     font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                                    color:[self primaryTextColor]];
    [documentView addSubview:devicesTitleLabel];

    self.devicesCardView = [self cardViewWithFrame:devicesCardFrame];
    [documentView addSubview:self.devicesCardView];

    self.devicesStatusLabel = [self labelWithFrame:NSMakeRect(16, 12, 488, 34)
                                            string:@"Loading paired devices..."
                                              font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                             color:[self tertiaryTextColor]];
    self.devicesStatusLabel.maximumNumberOfLines = 2;
    self.devicesStatusLabel.usesSingleLineMode = NO;
    self.devicesStatusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.devicesCardView addSubview:self.devicesStatusLabel];

    self.devicesScrollView = [[NSScrollView alloc] initWithFrame:self.devicesCardView.bounds];
    self.devicesScrollView.drawsBackground = NO;
    self.devicesScrollView.hasVerticalScroller = YES;
    self.devicesScrollView.autohidesScrollers = YES;
    self.devicesScrollView.borderType = NSNoBorder;
    self.devicesScrollView.hidden = YES;
    [self.devicesCardView addSubview:self.devicesScrollView];

    self.devicesDocumentView = [[TideyFlippedView alloc] initWithFrame:NSMakeRect(0, 0, contentWidth, NSHeight(devicesCardFrame))];
    self.devicesScrollView.documentView = self.devicesDocumentView;

    self.devicesStackView = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, contentWidth, 0)];
    self.devicesStackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.devicesStackView.alignment = NSLayoutAttributeLeading;
    self.devicesStackView.distribution = NSStackViewDistributionFill;
    self.devicesStackView.spacing = 0;
    [self.devicesDocumentView addSubview:self.devicesStackView];

    NSTextField *uploadsTitleLabel = [self labelWithFrame:uploadsTitleFrame
                                                   string:@"Remote Uploads"
                                                     font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                                    color:[self primaryTextColor]];
    [documentView addSubview:uploadsTitleLabel];

    self.uploadsCardView = [self cardViewWithFrame:uploadsCardFrame];
    [documentView addSubview:self.uploadsCardView];

    self.uploadsStatusLabel = [self labelWithFrame:NSMakeRect(16, 12, 220, 18)
                                            string:@"Loading upload usage..."
                                              font:[self tabularFontOfSize:13 weight:NSFontWeightMedium]
                                             color:[self primaryTextColor]];
    [self.uploadsCardView addSubview:self.uploadsStatusLabel];

    self.uploadsRetentionLabel = [self labelWithFrame:NSMakeRect(16, 32, 240, 16)
                                               string:@"Uploads are kept for 7 days"
                                                 font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                                color:[self secondaryTextColor]];
    [self.uploadsCardView addSubview:self.uploadsRetentionLabel];

    self.uploadsRevealButton = [self actionButtonWithTitle:@"Reveal"
                                                     frame:NSMakeRect(332, 18, 72, 26)
                                                    action:@selector(revealUploadsDirectory:)
                                               destructive:NO];
    [self.uploadsCardView addSubview:self.uploadsRevealButton];

    self.uploadsCleanButton = [self actionButtonWithTitle:@"Clean Now"
                                                    frame:NSMakeRect(412, 18, 92, 26)
                                                   action:@selector(cleanUploadsNow:)
                                              destructive:NO];
    [self.uploadsCardView addSubview:self.uploadsCleanButton];

    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self ensureBridgeAndRefresh:NO];
}

- (void)remotePageDidBecomeVisible {
    if (self.bridgeReady) {
        [self startDevicesRefreshTimer];
        [self refreshPairedDevices];
        [self refreshUploadStats];
        return;
    }
    [self ensureBridgeAndRefresh:NO];
}

- (void)remotePageDidBecomeHidden {
    [self stopDevicesRefreshTimer];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self stopDevicesRefreshTimer];
}

- (NSColor *)windowBackgroundColor {
    return [NSColor colorWithSRGBRed:0x1e/255.0 green:0x1e/255.0 blue:0x1e/255.0 alpha:1.0];
}

- (NSColor *)cardBackgroundColor {
    return [NSColor colorWithSRGBRed:0x2a/255.0 green:0x2a/255.0 blue:0x2c/255.0 alpha:1.0];
}

- (NSColor *)cardBorderColor {
    return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.06];
}

- (NSColor *)dividerColor {
    return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.07];
}

- (NSColor *)primaryTextColor {
    return [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.92];
}

- (NSColor *)secondaryTextColor {
    return [NSColor colorWithSRGBRed:235/255.0 green:235/255.0 blue:245/255.0 alpha:0.55];
}

- (NSColor *)tertiaryTextColor {
    return [NSColor colorWithSRGBRed:235/255.0 green:235/255.0 blue:245/255.0 alpha:0.28];
}

- (NSColor *)accentColor {
    return [NSColor colorWithSRGBRed:0x0a/255.0 green:0x84/255.0 blue:0xff/255.0 alpha:1.0];
}

- (NSColor *)destructiveColor {
    return [NSColor colorWithSRGBRed:0xff/255.0 green:0x45/255.0 blue:0x3a/255.0 alpha:1.0];
}

- (NSFont *)tabularFontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    return [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
}

- (NSView *)cardViewWithFrame:(NSRect)frame {
    TideyFlippedView *view = [[TideyFlippedView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [self cardBackgroundColor].CGColor;
    view.layer.cornerRadius = 10;
    view.layer.borderWidth = 0.5;
    view.layer.borderColor = [self cardBorderColor].CGColor;
    return view;
}

- (NSView *)dividerWithFrame:(NSRect)frame {
    NSView *view = [[NSView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [self dividerColor].CGColor;
    return view;
}

- (NSButton *)actionButtonWithTitle:(NSString *)title frame:(NSRect)frame action:(SEL)action destructive:(BOOL)destructive {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title
                                                             attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: destructive ? [self destructiveColor] : [self primaryTextColor],
        NSParagraphStyleAttributeName: style,
    }];
    return button;
}

- (NSTextField *)labelWithFrame:(NSRect)frame string:(NSString *)string font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = string;
    label.font = font;
    label.textColor = color;
    label.drawsBackground = NO;
    label.bezeled = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

- (void)refreshPairPayload:(id)sender {
    [self ensureBridgeAndRefresh:NO];
}

- (void)reinstallBridge:(id)sender {
    [self ensureBridgeAndRefresh:YES];
}

- (void)ensureBridgeAndRefresh:(BOOL)forceReinstall {
    if (self.bridgeInstallInProgress) {
        return;
    }

    self.bridgeInstallInProgress = YES;
    self.bridgeReady = NO;
    [self setBridgeSetupInstalling];

    __weak __typeof(self) weakSelf = self;
    void (^completion)(TideyRemoteBridgeInstallResult *) = ^(TideyRemoteBridgeInstallResult *result) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.bridgeInstallInProgress = NO;
        strongSelf.bridgeReady = result.bridgeReady;
        if (!result.bridgeReady) {
            [strongSelf setBridgeSetupFailedWithResult:result];
            return;
        }
        [strongSelf setBridgeSetupRunningWithResult:result];
        [strongSelf startDevicesRefreshTimer];
        [strongSelf fetchPairPayload];
        [strongSelf refreshPairedDevices];
        [strongSelf refreshUploadStats];
    };

    if (forceReinstall) {
        [[TideyRemoteBridgeInstaller shared] reinstallWithCompletion:completion];
    } else {
        [[TideyRemoteBridgeInstaller shared] ensureInstalledWithCompletion:completion];
    }
}

- (void)setBridgeSetupInstalling {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
    self.expiresAt = nil;
    self.refreshButton.enabled = NO;
    self.reinstallBridgeButton.hidden = YES;
    self.bridgeSetupLabel.textColor = [self secondaryTextColor];
    self.bridgeSetupLabel.stringValue = @"Setting up Tidey Remote Bridge...";
    self.bridgeSetupLabel.toolTip = @"Tidey is installing the local Bridge service used by Tidey Remote.";
    self.statusLabel.stringValue = @"Setting up...";
    self.statusLabel.toolTip = nil;
    self.qrImageView.image = nil;
    self.devicesStatusLabel.hidden = NO;
    self.devicesScrollView.hidden = YES;
    self.devicesStatusLabel.stringValue = @"Setting up Tidey Remote Bridge...";
    self.uploadsStatusLabel.stringValue = @"Bridge setup pending";
}

- (void)setBridgeSetupRunningWithResult:(TideyRemoteBridgeInstallResult *)result {
    self.refreshButton.enabled = YES;
    self.reinstallBridgeButton.hidden = YES;
    self.bridgeSetupLabel.textColor = result.cloudflaredAvailable ? [self secondaryTextColor] : [self tertiaryTextColor];
    self.bridgeSetupLabel.stringValue = result.detailMessage.length ? result.detailMessage : @"Bridge running.";
    self.bridgeSetupLabel.toolTip = result.detailMessage;
}

- (void)setBridgeSetupFailedWithResult:(TideyRemoteBridgeInstallResult *)result {
    self.refreshButton.enabled = YES;
    self.reinstallBridgeButton.hidden = NO;
    self.bridgeSetupLabel.textColor = [self destructiveColor];
    self.bridgeSetupLabel.stringValue = result.detailMessage.length ? [NSString stringWithFormat:@"Setup failed: %@", result.detailMessage] : @"Setup failed. Use Reinstall Bridge to retry.";
    self.bridgeSetupLabel.toolTip = result.detailMessage;
    self.statusLabel.stringValue = @"Setup failed";
    self.statusLabel.toolTip = result.detailMessage ?: result.userMessage;
    self.qrImageView.image = nil;
    self.devicesStatusLabel.hidden = NO;
    self.devicesScrollView.hidden = YES;
    self.devicesStatusLabel.stringValue = result.detailMessage.length ? [NSString stringWithFormat:@"Bridge setup failed: %@", result.detailMessage] : @"Bridge setup failed.";
    self.uploadsStatusLabel.stringValue = @"Bridge setup failed";
}

- (void)fetchPairPayload {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
    self.expiresAt = nil;
    self.refreshButton.enabled = NO;
    self.statusLabel.stringValue = @"Loading...";
    self.statusLabel.toolTip = nil;
    self.qrImageView.image = nil;

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        [self showError:@"Tidey Remote Bridge is starting. Refresh again in a moment."];
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4817/admin/pair_payload"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.refreshButton.enabled = YES;
            if (error) {
                [strongSelf showError:[NSString stringWithFormat:@"Bridge request failed: %@", error.localizedDescription]];
                return;
            }
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200 || !data.length) {
                [strongSelf showError:[NSString stringWithFormat:@"Bridge returned HTTP %ld.", (long)statusCode]];
                return;
            }
            [strongSelf handlePairPayloadData:data];
        });
    }];
    [task resume];
}

- (void)refreshPairedDevices {
    [self refreshPairedDevicesShowingLoading:YES];
}

- (void)pollPairedDevices {
    [self refreshPairedDevicesShowingLoading:NO];
}

- (void)refreshPairedDevicesShowingLoading:(BOOL)showLoading {
    if (!self.bridgeReady) {
        self.devicesStatusLabel.hidden = NO;
        self.devicesScrollView.hidden = YES;
        self.devicesStatusLabel.stringValue = self.bridgeInstallInProgress ? @"Setting up Tidey Remote Bridge..." : @"Tidey Remote Bridge is not ready.";
        [self clearDeviceRows];
        return;
    }

    if (showLoading) {
        self.devicesStatusLabel.hidden = NO;
        self.devicesScrollView.hidden = YES;
        self.devicesStatusLabel.stringValue = @"Loading paired devices...";
        [self clearDeviceRows];
    }

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        self.devicesStatusLabel.hidden = NO;
        self.devicesScrollView.hidden = YES;
        self.devicesStatusLabel.stringValue = @"Tidey Remote Bridge is starting. Refresh again in a moment.";
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4817/admin/devices"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (error) {
                strongSelf.devicesStatusLabel.hidden = NO;
                strongSelf.devicesScrollView.hidden = YES;
                strongSelf.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Device list failed: %@", error.localizedDescription];
                return;
            }
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200 || !data.length) {
                strongSelf.devicesStatusLabel.hidden = NO;
                strongSelf.devicesScrollView.hidden = YES;
                strongSelf.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Bridge returned HTTP %ld.", (long)statusCode];
                return;
            }
            [strongSelf handlePairedDevicesData:data];
        });
    }];
    [task resume];
}

- (void)refreshUploadStats {
    if (!self.bridgeReady) {
        self.uploadsStatusLabel.stringValue = self.bridgeInstallInProgress ? @"Bridge setup pending" : @"Bridge not ready";
        return;
    }

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        self.uploadsStatusLabel.stringValue = @"Bridge is starting";
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4817/admin/uploads/stats"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (error) {
                strongSelf.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"Upload stats failed: %@", error.localizedDescription];
                return;
            }
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200 || !data.length) {
                strongSelf.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"Bridge returned HTTP %ld.", (long)statusCode];
                return;
            }
            [strongSelf handleUploadStatsData:data];
        });
    }];
    [task resume];
}

- (void)handleUploadStatsData:(NSData *)data {
    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![payload isKindOfClass:NSDictionary.class]) {
        self.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"Invalid upload stats: %@", jsonError.localizedDescription ?: @"not a JSON object"];
        return;
    }
    NSNumber *fileCount = [payload[@"file_count"] isKindOfClass:NSNumber.class] ? payload[@"file_count"] : @(0);
    NSNumber *totalBytes = [payload[@"total_bytes"] isKindOfClass:NSNumber.class] ? payload[@"total_bytes"] : @(0);
    self.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"%@ file%@ · %@",
                                           fileCount,
                                           fileCount.integerValue == 1 ? @"" : @"s",
                                           [self byteCountString:totalBytes.longLongValue]];
}

- (void)cleanUploadsNow:(id)sender {
    if (!self.bridgeReady) {
        [self ensureBridgeAndRefresh:NO];
        return;
    }

    self.uploadsCleanButton.enabled = NO;
    self.uploadsStatusLabel.stringValue = @"Cleaning uploads...";

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        self.uploadsCleanButton.enabled = YES;
        self.uploadsStatusLabel.stringValue = @"Bridge is starting";
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4817/admin/uploads/sweep"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.uploadsCleanButton.enabled = YES;
            if (error) {
                strongSelf.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"Clean failed: %@", error.localizedDescription];
                return;
            }
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200 || !data.length) {
                strongSelf.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"Clean returned HTTP %ld.", (long)statusCode];
                return;
            }
            NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSNumber *removed = [payload isKindOfClass:NSDictionary.class] && [payload[@"removed_file_count"] isKindOfClass:NSNumber.class] ? payload[@"removed_file_count"] : @(0);
            NSNumber *freed = [payload isKindOfClass:NSDictionary.class] && [payload[@"freed_bytes"] isKindOfClass:NSNumber.class] ? payload[@"freed_bytes"] : @(0);
            strongSelf.uploadsStatusLabel.stringValue = [NSString stringWithFormat:@"Cleaned %@ file%@ · freed %@",
                                                         removed,
                                                         removed.integerValue == 1 ? @"" : @"s",
                                                         [strongSelf byteCountString:freed.longLongValue]];
            [strongSelf refreshUploadStats];
        });
    }];
    [task resume];
}

- (void)revealUploadsDirectory:(id)sender {
    NSString *path = [self uploadsDirectoryPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path isDirectory:YES]];
}

- (void)startDevicesRefreshTimer {
    if (self.devicesRefreshTimer) {
        return;
    }
    self.devicesRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:4
                                                                target:self
                                                              selector:@selector(pollPairedDevices)
                                                              userInfo:nil
                                                               repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.devicesRefreshTimer forMode:NSRunLoopCommonModes];
}

- (void)stopDevicesRefreshTimer {
    [self.devicesRefreshTimer invalidate];
    self.devicesRefreshTimer = nil;
}

- (void)handlePairedDevicesData:(NSData *)data {
    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    NSArray *devices = [payload isKindOfClass:NSDictionary.class] && [payload[@"devices"] isKindOfClass:NSArray.class] ? payload[@"devices"] : nil;
    if (!devices) {
        self.devicesStatusLabel.hidden = NO;
        self.devicesScrollView.hidden = YES;
        self.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Invalid device list: %@", jsonError.localizedDescription ?: @"not a JSON object"];
        return;
    }
    [self clearDeviceRows];
    if (!devices.count) {
        self.devicesStatusLabel.hidden = NO;
        self.devicesScrollView.hidden = YES;
        self.devicesStatusLabel.stringValue = @"No devices paired. Scan the QR code with Tidey Remote on your iPhone to pair.";
        return;
    }
    self.devicesStatusLabel.hidden = YES;
    self.devicesScrollView.hidden = NO;
    [self updateDeviceRowsFrameForCount:devices.count];
    for (NSDictionary *device in devices) {
        if (![device isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self.devicesStackView addArrangedSubview:[self rowViewForDevice:device]];
    }
}

- (void)clearDeviceRows {
    for (NSView *view in self.devicesStackView.arrangedSubviews.copy) {
        [self.devicesStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSView *view in self.devicesStackView.subviews.copy) {
        [view removeFromSuperview];
    }
    [self updateDeviceRowsFrameForCount:0];
}

- (void)updateDeviceRowsFrameForCount:(NSUInteger)count {
    static const CGFloat rowHeight = 58;
    static const CGFloat rowSpacing = 0;
    static const CGFloat width = 520;
    static const CGFloat visibleHeight = 58;
    CGFloat contentHeight = count == 0 ? 0 : rowHeight * count + rowSpacing * (count - 1);
    CGFloat documentHeight = MAX(visibleHeight, contentHeight);
    self.devicesDocumentView.frame = NSMakeRect(0, 0, width, documentHeight);
    self.devicesStackView.frame = NSMakeRect(0, 0, width, contentHeight);
    [self.devicesScrollView.contentView scrollToPoint:NSMakePoint(0, 0)];
    [self.devicesScrollView reflectScrolledClipView:self.devicesScrollView.contentView];
}

- (NSView *)rowViewForDevice:(NSDictionary *)device {
    TideyFlippedView *row = [[TideyFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 520, 58)];
    [row.heightAnchor constraintEqualToConstant:58].active = YES;
    NSString *deviceID = [device[@"device_id"] isKindOfClass:NSString.class] ? device[@"device_id"] : @"";
    NSString *deviceName = [device[@"device_name"] isKindOfClass:NSString.class] ? device[@"device_name"] : @"Unknown device";
    NSDate *pairedAt = [self dateFromISOString:[device[@"paired_at"] isKindOfClass:NSString.class] ? device[@"paired_at"] : nil];
    NSDate *lastSeenAt = [self dateFromISOString:[device[@"last_connected_at"] isKindOfClass:NSString.class] ? device[@"last_connected_at"] : nil];

    NSTextField *nameLabel = [self labelWithFrame:NSMakeRect(16, 12, 360, 18)
                                           string:deviceName
                                             font:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]
                                            color:[self primaryTextColor]];
    [row addSubview:nameLabel];

    NSString *detail = [NSString stringWithFormat:@"Paired %@ · Last seen %@",
                        [self shortStringForDate:pairedAt] ?: @"unknown",
                        [self shortStringForDate:lastSeenAt] ?: @"never"];
    NSTextField *detailLabel = [self labelWithFrame:NSMakeRect(16, 32, 360, 16)
                                             string:detail
                                               font:[self tabularFontOfSize:11 weight:NSFontWeightRegular]
                                              color:[self secondaryTextColor]];
    [row addSubview:detailLabel];

    NSButton *revokeButton = [self actionButtonWithTitle:@"Revoke"
                                                   frame:NSMakeRect(408, 16, 96, 26)
                                                  action:@selector(revokeDevice:)
                                             destructive:YES];
    revokeButton.identifier = deviceID ?: @"";
    revokeButton.enabled = deviceID.length > 0;
    [row addSubview:revokeButton];

    return row;
}

- (NSString *)shortStringForDate:(NSDate *)date {
    if (!date) {
        return nil;
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date];
}

- (void)revokeDevice:(NSButton *)sender {
    if (!self.bridgeReady) {
        [self ensureBridgeAndRefresh:NO];
        return;
    }

    NSString *deviceID = sender.identifier;
    if (!deviceID.length) {
        return;
    }
    sender.enabled = NO;

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        sender.enabled = YES;
        self.devicesStatusLabel.stringValue = @"Bridge is starting. Try again in a moment.";
        return;
    }

    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:4817/admin/devices/revoke"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 8;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"device_id": deviceID } options:0 error:nil];

    __weak __typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (error) {
                sender.enabled = YES;
                strongSelf.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Revoke failed: %@", error.localizedDescription];
                return;
            }
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200) {
                sender.enabled = YES;
                strongSelf.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Revoke returned HTTP %ld.", (long)statusCode];
                return;
            }
            [strongSelf refreshPairedDevices];
        });
    }];
    [task resume];
}

- (NSString *)uploadsDirectoryPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tidey Remote Bridge/uploads"];
}

- (NSString *)byteCountString:(long long)bytes {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseKB | NSByteCountFormatterUseMB | NSByteCountFormatterUseGB;
    return [formatter stringFromByteCount:bytes];
}

- (NSString *)legacyPairTokenWithError:(NSError **)error {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tidey Remote Bridge/pair-token.json"];
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data.length) {
        return nil;
    }
    NSDictionary *record = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSString *token = [record isKindOfClass:NSDictionary.class] ? record[@"token"] : nil;
    if (!token.length && error) {
        *error = [NSError errorWithDomain:@"TideyRemoteSettings"
                                     code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: @"Bridge pairing credentials are not ready yet" }];
    }
    return token;
}

- (void)handlePairPayloadData:(NSData *)data {
    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![payload isKindOfClass:NSDictionary.class]) {
        [self showError:[NSString stringWithFormat:@"Invalid pair payload: %@", jsonError.localizedDescription ?: @"not a JSON object"]];
        return;
    }

    NSArray *endpoints = [payload[@"lan_endpoints"] isKindOfClass:NSArray.class] ? payload[@"lan_endpoints"] : @[];
    if (!endpoints.count) {
        self.statusLabel.stringValue = @"Unavailable";
        self.statusLabel.toolTip = @"Connect this Mac to Wi-Fi or Ethernet, then refresh.";
        self.qrImageView.image = nil;
        return;
    }

    NSString *expiresAtString = [payload[@"expires_at"] isKindOfClass:NSString.class] ? payload[@"expires_at"] : nil;
    self.expiresAt = [self dateFromISOString:expiresAtString];
    self.qrImageView.image = [self qrImageForString:[self base64URLStringForData:data]];
    self.statusLabel.toolTip = nil;
    [self startCountdownTimer];
}

- (NSDate *)dateFromISOString:(NSString *)string {
    if (!string.length) {
        return nil;
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter dateFromString:string];
}

- (void)startCountdownTimer {
    [self.countdownTimer invalidate];
    [self updateCountdown];
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                           target:self
                                                         selector:@selector(updateCountdown)
                                                         userInfo:nil
                                                          repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.countdownTimer forMode:NSRunLoopCommonModes];
}

- (void)updateCountdown {
    if (!self.expiresAt) {
        self.statusLabel.stringValue = @"Loading...";
        return;
    }
    NSTimeInterval remaining = [self.expiresAt timeIntervalSinceNow];
    if (remaining <= 0) {
        [self.countdownTimer invalidate];
        self.countdownTimer = nil;
        self.statusLabel.stringValue = @"Expired";
        return;
    }
    NSInteger seconds = (NSInteger)ceil(remaining);
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Expires in %ld:%02ld",
                                    (long)(seconds / 60),
                                    (long)(seconds % 60)];
}

- (NSString *)base64URLStringForData:(NSData *)data {
    NSString *base64 = [data base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return base64;
}

- (NSImage *)qrImageForString:(NSString *)string {
    NSData *message = [string dataUsingEncoding:NSUTF8StringEncoding];
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:message forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *outputImage = filter.outputImage;
    if (!outputImage) {
        return nil;
    }
    CIImage *scaledImage = [outputImage imageByApplyingTransform:CGAffineTransformMakeScale(8, 8)];
    NSCIImageRep *representation = [NSCIImageRep imageRepWithCIImage:scaledImage];
    NSImage *image = [[NSImage alloc] initWithSize:representation.size];
    [image addRepresentation:representation];
    return image;
}

- (void)showError:(NSString *)message {
    self.refreshButton.enabled = YES;
    self.statusLabel.stringValue = @"Unavailable";
    self.statusLabel.toolTip = message ?: @"Unable to create a pairing code.";
    self.qrImageView.image = nil;
}

@end

@interface TideySettingsWindowController ()

@property(nonatomic, strong) TideySettingsTabButton *appearanceTabButton;
@property(nonatomic, strong) TideySettingsTabButton *shortcutsTabButton;
@property(nonatomic, strong) TideySettingsTabButton *browserTabButton;
@property(nonatomic, strong) TideySettingsTabButton *remoteTabButton;
@property(nonatomic, strong) NSView *contentContainerView;
@property(nonatomic, strong) TideyTerminalAppearanceViewController *appearanceViewController;
@property(nonatomic, strong) TideyKeyboardShortcutsViewController *shortcutsViewController;
@property(nonatomic, strong) TideyBrowserSettingsViewController *browserViewController;
@property(nonatomic, strong) TideyRemoteSettingsViewController *remoteViewController;
@property(nonatomic, strong) NSViewController *currentViewController;

@end

@implementation TideySettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 700)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        window.title = @"Settings";
        window.backgroundColor = [NSColor colorWithSRGBRed:0x1a/255.0 green:0x1a/255.0 blue:0x1a/255.0 alpha:1.0];
        [window center];
        [window setFrameAutosaveName:@"TideySettingsWindow"];

        _appearanceViewController = [[TideyTerminalAppearanceViewController alloc] init];
        _shortcutsViewController = [[TideyKeyboardShortcutsViewController alloc] init];
        _browserViewController = [[TideyBrowserSettingsViewController alloc] init];
        _remoteViewController = [[TideyRemoteSettingsViewController alloc] init];

        [self buildUI];
        [self selectPage:TideySettingsPageAppearance];
    }
    return self;
}

- (void)showWindowSelectingAppearance {
    [self selectPage:TideySettingsPageAppearance];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showWindowSelectingRemote {
    [self selectPage:TideySettingsPageRemote];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)buildUI {
    NSView *contentView = self.window.contentView;
    CGFloat windowWidth = 560;
    CGFloat windowHeight = 700;

    // Tab bar area: two pill buttons near the top
    CGFloat tabBarY = windowHeight - 52;
    CGFloat tabButtonWidth = 100;
    CGFloat tabButtonHeight = 28;
    CGFloat tabBarX = 20;

    self.appearanceTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.appearanceTabButton.title = @"Appearance";
    self.appearanceTabButton.bordered = NO;
    self.appearanceTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.appearanceTabButton.target = self;
    self.appearanceTabButton.action = @selector(tabButtonClicked:);
    self.appearanceTabButton.tag = TideySettingsPageAppearance;
    self.appearanceTabButton.autoresizingMask = NSViewMinYMargin;
    [contentView addSubview:self.appearanceTabButton];

    self.shortcutsTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + tabButtonWidth + 2, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.shortcutsTabButton.title = @"Shortcuts";
    self.shortcutsTabButton.bordered = NO;
    self.shortcutsTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.shortcutsTabButton.target = self;
    self.shortcutsTabButton.action = @selector(tabButtonClicked:);
    self.shortcutsTabButton.tag = TideySettingsPageShortcuts;
    self.shortcutsTabButton.autoresizingMask = NSViewMinYMargin;
    [contentView addSubview:self.shortcutsTabButton];

    self.browserTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + (tabButtonWidth + 2) * 2, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.browserTabButton.title = @"Browser";
    self.browserTabButton.bordered = NO;
    self.browserTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.browserTabButton.target = self;
    self.browserTabButton.action = @selector(tabButtonClicked:);
    self.browserTabButton.tag = TideySettingsPageBrowser;
    self.browserTabButton.autoresizingMask = NSViewMinYMargin;
    [contentView addSubview:self.browserTabButton];

    self.remoteTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + (tabButtonWidth + 2) * 3, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.remoteTabButton.title = @"Remote";
    self.remoteTabButton.bordered = NO;
    self.remoteTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.remoteTabButton.target = self;
    self.remoteTabButton.action = @selector(tabButtonClicked:);
    self.remoteTabButton.tag = TideySettingsPageRemote;
    self.remoteTabButton.autoresizingMask = NSViewMinYMargin;
    [contentView addSubview:self.remoteTabButton];

    // Content container below tab bar
    CGFloat contentTop = tabBarY - 12; // 12pt padding below tab bar
    self.contentContainerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, windowWidth, contentTop)];
    self.contentContainerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:self.contentContainerView];
}

- (void)tabButtonClicked:(TideySettingsTabButton *)sender {
    [self selectPage:(TideySettingsPage)sender.tag];
}

- (void)selectPage:(TideySettingsPage)page {
    self.appearanceTabButton.isActiveTab = (page == TideySettingsPageAppearance);
    self.shortcutsTabButton.isActiveTab = (page == TideySettingsPageShortcuts);
    self.browserTabButton.isActiveTab = (page == TideySettingsPageBrowser);
    self.remoteTabButton.isActiveTab = (page == TideySettingsPageRemote);
    [self.appearanceTabButton setNeedsDisplay:YES];
    [self.shortcutsTabButton setNeedsDisplay:YES];
    [self.browserTabButton setNeedsDisplay:YES];
    [self.remoteTabButton setNeedsDisplay:YES];

    NSViewController *nextViewController;
    switch (page) {
        case TideySettingsPageAppearance:
            nextViewController = self.appearanceViewController;
            break;
        case TideySettingsPageShortcuts:
            nextViewController = self.shortcutsViewController;
            break;
        case TideySettingsPageBrowser:
            nextViewController = self.browserViewController;
            break;
        case TideySettingsPageRemote:
            nextViewController = self.remoteViewController;
            break;
    }
    BOOL isRemotePage = (page == TideySettingsPageRemote);
    BOOL wasRemotePage = (self.currentViewController == self.remoteViewController);
    if (self.currentViewController == nextViewController) {
        if (isRemotePage) {
            [self.remoteViewController remotePageDidBecomeVisible];
        }
        return;
    }
    if (wasRemotePage && !isRemotePage) {
        [self.remoteViewController remotePageDidBecomeHidden];
    }
    [self.currentViewController.view removeFromSuperview];
    self.currentViewController = nextViewController;
    NSView *view = nextViewController.view;
    view.frame = self.contentContainerView.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.contentContainerView addSubview:view];
    if (isRemotePage) {
        [self.remoteViewController remotePageDidBecomeVisible];
    }
}

@end
