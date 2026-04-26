#import "TideySettingsWindowController.h"

#import "TideyKeyboardShortcutsViewController.h"
#import "TideyTerminalAppearanceViewController.h"

@import CoreImage;

typedef NS_ENUM(NSInteger, TideySettingsPage) {
    TideySettingsPageAppearance = 0,
    TideySettingsPageShortcuts = 1,
    TideySettingsPageRemote = 2,
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

@interface TideyRemoteSettingsViewController : NSViewController

@property(nonatomic, strong) NSTextField *endpointValueLabel;
@property(nonatomic, strong) NSTextField *countdownLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSImageView *qrImageView;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSStackView *devicesStackView;
@property(nonatomic, strong) NSTextField *devicesStatusLabel;
@property(nonatomic, strong) NSTimer *countdownTimer;
@property(nonatomic, strong) NSDate *expiresAt;

- (void)remotePageDidBecomeVisible;

@end

@implementation TideyRemoteSettingsViewController

- (void)dealloc {
    [self.countdownTimer invalidate];
}

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 520)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor colorWithSRGBRed:0x1a/255.0 green:0x1a/255.0 blue:0x1a/255.0 alpha:1.0].CGColor;

    NSTextField *titleLabel = [self labelWithFrame:NSMakeRect(32, 468, 496, 28)
                                             string:@"Sync to Remote"
                                               font:[NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]
                                              color:[NSColor colorWithSRGBRed:0xf4/255.0 green:0xf4/255.0 blue:0xf4/255.0 alpha:1.0]];
    [view addSubview:titleLabel];

    NSTextField *bodyLabel = [self labelWithFrame:NSMakeRect(32, 424, 496, 38)
                                            string:@"Pair Tidey Remote on your phone with this Mac. The LAN QR code will appear here once the Bridge is available."
                                              font:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
                                             color:[NSColor colorWithSRGBRed:0x9a/255.0 green:0x9a/255.0 blue:0x9a/255.0 alpha:1.0]];
    bodyLabel.maximumNumberOfLines = 2;
    [view addSubview:bodyLabel];

    NSView *cardView = [[NSView alloc] initWithFrame:NSMakeRect(32, 224, 496, 186)];
    cardView.wantsLayer = YES;
    cardView.layer.backgroundColor = [NSColor colorWithSRGBRed:0x22/255.0 green:0x22/255.0 blue:0x22/255.0 alpha:1.0].CGColor;
    cardView.layer.cornerRadius = 12;
    cardView.layer.borderWidth = 1;
    cardView.layer.borderColor = [NSColor colorWithSRGBRed:0x33/255.0 green:0x33/255.0 blue:0x33/255.0 alpha:1.0].CGColor;
    [view addSubview:cardView];

    self.qrImageView = [[NSImageView alloc] initWithFrame:NSMakeRect(24, 24, 138, 138)];
    self.qrImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.qrImageView.wantsLayer = YES;
    self.qrImageView.layer.backgroundColor = NSColor.whiteColor.CGColor;
    self.qrImageView.layer.cornerRadius = 10;
    [cardView addSubview:self.qrImageView];

    NSTextField *endpointTitleLabel = [self labelWithFrame:NSMakeRect(188, 138, 276, 20)
                                                    string:@"LAN endpoint"
                                                      font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
                                                     color:[NSColor colorWithSRGBRed:0x88/255.0 green:0x88/255.0 blue:0x88/255.0 alpha:1.0]];
    [cardView addSubview:endpointTitleLabel];

    self.endpointValueLabel = [self labelWithFrame:NSMakeRect(188, 112, 276, 24)
                                            string:@"Loading..."
                                              font:[NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular]
                                             color:[NSColor colorWithSRGBRed:0xf4/255.0 green:0xf4/255.0 blue:0xf4/255.0 alpha:1.0]];
    [cardView addSubview:self.endpointValueLabel];

    self.countdownLabel = [self labelWithFrame:NSMakeRect(188, 82, 276, 22)
                                        string:@""
                                          font:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
                                         color:[NSColor colorWithSRGBRed:88/255.0 green:178/255.0 blue:220/255.0 alpha:1.0]];
    [cardView addSubview:self.countdownLabel];

    self.statusLabel = [self labelWithFrame:NSMakeRect(188, 44, 276, 34)
                                     string:@""
                                       font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                      color:[NSColor colorWithSRGBRed:0xaa/255.0 green:0xaa/255.0 blue:0xaa/255.0 alpha:1.0]];
    self.statusLabel.maximumNumberOfLines = 2;
    [cardView addSubview:self.statusLabel];

    self.refreshButton = [NSButton buttonWithTitle:@"Refresh"
                                            target:self
                                            action:@selector(refreshPairPayload:)];
    self.refreshButton.frame = NSMakeRect(188, 12, 120, 28);
    self.refreshButton.bezelStyle = NSBezelStyleRounded;
    [cardView addSubview:self.refreshButton];

    NSView *devicesCardView = [[NSView alloc] initWithFrame:NSMakeRect(32, 36, 496, 164)];
    devicesCardView.wantsLayer = YES;
    devicesCardView.layer.backgroundColor = [NSColor colorWithSRGBRed:0x22/255.0 green:0x22/255.0 blue:0x22/255.0 alpha:1.0].CGColor;
    devicesCardView.layer.cornerRadius = 12;
    devicesCardView.layer.borderWidth = 1;
    devicesCardView.layer.borderColor = [NSColor colorWithSRGBRed:0x33/255.0 green:0x33/255.0 blue:0x33/255.0 alpha:1.0].CGColor;
    [view addSubview:devicesCardView];

    NSTextField *devicesTitleLabel = [self labelWithFrame:NSMakeRect(20, 126, 220, 22)
                                                   string:@"Paired devices"
                                                     font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
                                                    color:[NSColor colorWithSRGBRed:0xf4/255.0 green:0xf4/255.0 blue:0xf4/255.0 alpha:1.0]];
    [devicesCardView addSubview:devicesTitleLabel];

    self.devicesStatusLabel = [self labelWithFrame:NSMakeRect(20, 100, 456, 20)
                                            string:@"Loading paired devices..."
                                              font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular]
                                             color:[NSColor colorWithSRGBRed:0xaa/255.0 green:0xaa/255.0 blue:0xaa/255.0 alpha:1.0]];
    [devicesCardView addSubview:self.devicesStatusLabel];

    self.devicesStackView = [[NSStackView alloc] initWithFrame:NSMakeRect(20, 16, 456, 78)];
    self.devicesStackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.devicesStackView.alignment = NSLayoutAttributeLeading;
    self.devicesStackView.distribution = NSStackViewDistributionFillEqually;
    self.devicesStackView.spacing = 8;
    [devicesCardView addSubview:self.devicesStackView];

    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshPairPayload:nil];
}

- (void)remotePageDidBecomeVisible {
    [self refreshPairedDevices];
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
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
    self.expiresAt = nil;
    self.refreshButton.enabled = NO;
    self.endpointValueLabel.stringValue = @"Loading...";
    self.countdownLabel.stringValue = @"";
    self.statusLabel.stringValue = @"Requesting a new pairing code from the Bridge.";
    self.qrImageView.image = nil;

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        [self showError:[NSString stringWithFormat:@"Pair token unavailable: %@", tokenError.localizedDescription ?: @"unknown error"]];
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
    self.devicesStatusLabel.stringValue = @"Loading paired devices...";
    [self clearDeviceRows];

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        self.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Pair token unavailable: %@", tokenError.localizedDescription ?: @"unknown error"];
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
                strongSelf.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Device list failed: %@", error.localizedDescription];
                return;
            }
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode != 200 || !data.length) {
                strongSelf.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Bridge returned HTTP %ld.", (long)statusCode];
                return;
            }
            [strongSelf handlePairedDevicesData:data];
        });
    }];
    [task resume];
}

- (void)handlePairedDevicesData:(NSData *)data {
    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    NSArray *devices = [payload isKindOfClass:NSDictionary.class] && [payload[@"devices"] isKindOfClass:NSArray.class] ? payload[@"devices"] : nil;
    if (!devices) {
        self.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Invalid device list: %@", jsonError.localizedDescription ?: @"not a JSON object"];
        return;
    }
    [self clearDeviceRows];
    if (!devices.count) {
        self.devicesStatusLabel.stringValue = @"No paired devices yet.";
        return;
    }
    self.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"%lu paired device%@", (unsigned long)devices.count, devices.count == 1 ? @"" : @"s"];
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
}

- (NSView *)rowViewForDevice:(NSDictionary *)device {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 456, 34)];
    NSString *deviceID = [device[@"device_id"] isKindOfClass:NSString.class] ? device[@"device_id"] : @"";
    NSString *deviceName = [device[@"device_name"] isKindOfClass:NSString.class] ? device[@"device_name"] : @"Unknown device";
    NSDate *pairedAt = [self dateFromISOString:[device[@"paired_at"] isKindOfClass:NSString.class] ? device[@"paired_at"] : nil];
    NSDate *lastSeenAt = [self dateFromISOString:[device[@"last_connected_at"] isKindOfClass:NSString.class] ? device[@"last_connected_at"] : nil];

    NSTextField *nameLabel = [self labelWithFrame:NSMakeRect(0, 16, 330, 18)
                                           string:deviceName
                                             font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
                                            color:[NSColor colorWithSRGBRed:0xf4/255.0 green:0xf4/255.0 blue:0xf4/255.0 alpha:1.0]];
    [row addSubview:nameLabel];

    NSString *detail = [NSString stringWithFormat:@"Paired %@ · Last seen %@",
                        [self shortStringForDate:pairedAt] ?: @"unknown",
                        [self shortStringForDate:lastSeenAt] ?: @"never"];
    NSTextField *detailLabel = [self labelWithFrame:NSMakeRect(0, 0, 330, 16)
                                             string:detail
                                               font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                                              color:[NSColor colorWithSRGBRed:0x99/255.0 green:0x99/255.0 blue:0x99/255.0 alpha:1.0]];
    [row addSubview:detailLabel];

    NSButton *revokeButton = [NSButton buttonWithTitle:@"Revoke"
                                                target:self
                                                action:@selector(revokeDevice:)];
    revokeButton.frame = NSMakeRect(356, 4, 96, 26);
    revokeButton.bezelStyle = NSBezelStyleRounded;
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
    NSString *deviceID = sender.identifier;
    if (!deviceID.length) {
        return;
    }
    sender.enabled = NO;

    NSError *tokenError = nil;
    NSString *token = [self legacyPairTokenWithError:&tokenError];
    if (!token.length) {
        sender.enabled = YES;
        self.devicesStatusLabel.stringValue = [NSString stringWithFormat:@"Pair token unavailable: %@", tokenError.localizedDescription ?: @"unknown error"];
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
                                 userInfo:@{ NSLocalizedDescriptionKey: @"pair-token.json does not contain token" }];
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
        self.endpointValueLabel.stringValue = @"No LAN endpoint";
        self.countdownLabel.stringValue = @"";
        self.statusLabel.stringValue = @"No active LAN endpoint found. Connect this Mac to Wi-Fi or Ethernet, then refresh.";
        self.qrImageView.image = nil;
        return;
    }

    self.endpointValueLabel.stringValue = [self displayStringForEndpoint:endpoints.firstObject];
    NSString *expiresAtString = [payload[@"expires_at"] isKindOfClass:NSString.class] ? payload[@"expires_at"] : nil;
    self.expiresAt = [self dateFromISOString:expiresAtString];
    self.qrImageView.image = [self qrImageForString:[self base64URLStringForData:data]];
    self.statusLabel.stringValue = @"Scan this code with Tidey Remote on your phone.";
    [self startCountdownTimer];
}

- (NSString *)displayStringForEndpoint:(NSDictionary *)endpoint {
    if (![endpoint isKindOfClass:NSDictionary.class]) {
        return @"Unknown";
    }
    NSString *scheme = [endpoint[@"scheme"] isKindOfClass:NSString.class] ? endpoint[@"scheme"] : @"ws";
    NSString *host = [endpoint[@"host"] isKindOfClass:NSString.class] ? endpoint[@"host"] : @"";
    NSNumber *port = [endpoint[@"port"] isKindOfClass:NSNumber.class] ? endpoint[@"port"] : nil;
    NSString *path = [endpoint[@"path"] isKindOfClass:NSString.class] ? endpoint[@"path"] : @"/";
    NSString *displayHost = [host containsString:@":"] ? [NSString stringWithFormat:@"[%@]", host] : host;
    return [NSString stringWithFormat:@"%@://%@%@%@", scheme, displayHost, port ? [NSString stringWithFormat:@":%@", port] : @"", path ?: @"/"];
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
        self.countdownLabel.stringValue = @"Expires in 5:00";
        return;
    }
    NSTimeInterval remaining = [self.expiresAt timeIntervalSinceNow];
    if (remaining <= 0) {
        [self.countdownTimer invalidate];
        self.countdownTimer = nil;
        self.countdownLabel.stringValue = @"Expired";
        self.statusLabel.stringValue = @"This pairing code expired. Press Refresh to create a new one.";
        return;
    }
    NSInteger seconds = (NSInteger)ceil(remaining);
    self.countdownLabel.stringValue = [NSString stringWithFormat:@"Expires in %ld:%02ld",
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
    self.endpointValueLabel.stringValue = @"Unavailable";
    self.countdownLabel.stringValue = @"";
    self.statusLabel.stringValue = message ?: @"Unable to create a pairing code.";
    self.qrImageView.image = nil;
}

@end

@interface TideySettingsWindowController ()

@property(nonatomic, strong) TideySettingsTabButton *appearanceTabButton;
@property(nonatomic, strong) TideySettingsTabButton *shortcutsTabButton;
@property(nonatomic, strong) TideySettingsTabButton *remoteTabButton;
@property(nonatomic, strong) NSView *contentContainerView;
@property(nonatomic, strong) TideyTerminalAppearanceViewController *appearanceViewController;
@property(nonatomic, strong) TideyKeyboardShortcutsViewController *shortcutsViewController;
@property(nonatomic, strong) TideyRemoteSettingsViewController *remoteViewController;
@property(nonatomic, strong) NSViewController *currentViewController;

@end

@implementation TideySettingsWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 580)
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
    CGFloat windowHeight = 580;

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
    [contentView addSubview:self.appearanceTabButton];

    self.shortcutsTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + tabButtonWidth + 2, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.shortcutsTabButton.title = @"Shortcuts";
    self.shortcutsTabButton.bordered = NO;
    self.shortcutsTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.shortcutsTabButton.target = self;
    self.shortcutsTabButton.action = @selector(tabButtonClicked:);
    self.shortcutsTabButton.tag = TideySettingsPageShortcuts;
    [contentView addSubview:self.shortcutsTabButton];

    self.remoteTabButton = [[TideySettingsTabButton alloc] initWithFrame:NSMakeRect(tabBarX + (tabButtonWidth + 2) * 2, tabBarY, tabButtonWidth, tabButtonHeight)];
    self.remoteTabButton.title = @"Remote";
    self.remoteTabButton.bordered = NO;
    self.remoteTabButton.bezelStyle = NSBezelStyleSmallSquare;
    self.remoteTabButton.target = self;
    self.remoteTabButton.action = @selector(tabButtonClicked:);
    self.remoteTabButton.tag = TideySettingsPageRemote;
    [contentView addSubview:self.remoteTabButton];

    // Content container below tab bar
    CGFloat contentTop = tabBarY - 12; // 12pt padding below tab bar
    self.contentContainerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, windowWidth, contentTop)];
    [contentView addSubview:self.contentContainerView];
}

- (void)tabButtonClicked:(TideySettingsTabButton *)sender {
    [self selectPage:(TideySettingsPage)sender.tag];
}

- (void)selectPage:(TideySettingsPage)page {
    self.appearanceTabButton.isActiveTab = (page == TideySettingsPageAppearance);
    self.shortcutsTabButton.isActiveTab = (page == TideySettingsPageShortcuts);
    self.remoteTabButton.isActiveTab = (page == TideySettingsPageRemote);
    [self.appearanceTabButton setNeedsDisplay:YES];
    [self.shortcutsTabButton setNeedsDisplay:YES];
    [self.remoteTabButton setNeedsDisplay:YES];

    NSViewController *nextViewController;
    switch (page) {
        case TideySettingsPageAppearance:
            nextViewController = self.appearanceViewController;
            break;
        case TideySettingsPageShortcuts:
            nextViewController = self.shortcutsViewController;
            break;
        case TideySettingsPageRemote:
            nextViewController = self.remoteViewController;
            break;
    }
    BOOL isRemotePage = (page == TideySettingsPageRemote);
    if (self.currentViewController == nextViewController) {
        if (isRemotePage) {
            [self.remoteViewController remotePageDidBecomeVisible];
        }
        return;
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
