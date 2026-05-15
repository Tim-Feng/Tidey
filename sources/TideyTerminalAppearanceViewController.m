#import "TideyTerminalAppearanceViewController.h"

#import "ITAddressBookMgr.h"
#import "TideyColorSwatchView.h"
#import "TideyTerminalAppearanceProfileAdapter.h"
#import "iTermFlippedView.h"
#import "iTermFontPanel.h"
#import "iTermRootTerminalView.h"

// ----- Card view: rounded rect with border -----
@interface TideySettingsCardView : NSView
@end

@implementation TideySettingsCardView

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
                                                         xRadius:13
                                                         yRadius:13];
    // Card background: rgba(255,255,255,0.04)
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.04] setFill];
    [path fill];

    // Card border: rgba(255,255,255,0.08)
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.08] setStroke];
    [path setLineWidth:1.0];
    [path stroke];
}

@end

// ----- Row divider line -----
@interface TideySettingsCardDivider : NSView
@end

@implementation TideySettingsCardDivider

- (void)drawRect:(NSRect)dirtyRect {
    // Separator: rgba(255,255,255,0.06)
    [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.06] setFill];
    NSRectFill(self.bounds);
}

@end

// ----- Colors -----
static NSColor *TideySettingsPrimaryTextColor(void) {
    return [NSColor colorWithSRGBRed:0xe8/255.0 green:0xe8/255.0 blue:0xe8/255.0 alpha:1.0];
}

static NSColor *TideySettingsSecondaryTextColor(void) {
    return [NSColor colorWithSRGBRed:0x88/255.0 green:0x88/255.0 blue:0x88/255.0 alpha:1.0];
}

// ----- Main VC -----
@interface TideyTerminalAppearanceViewController ()

@property(nonatomic, strong) TideyTerminalAppearanceProfileAdapter *adapter;
@property(nonatomic, strong) NSTextField *fontPreviewLabel;
@property(nonatomic, strong) NSTextField *fontSizeField;
@property(nonatomic, strong) NSStepper *fontSizeStepper;
@property(nonatomic, strong) NSMutableDictionary<NSString *, TideyColorSwatchView *> *coreColorWells;
@property(nonatomic, strong) NSMutableArray<TideyColorSwatchView *> *ansiColorWells;
@property(nonatomic, strong) NSFont *selectedFont;
@property(nonatomic, strong) NSTextField *browserHomepageField;
@property(nonatomic, strong) NSTextField *browserStatusLabel;

@end

@implementation TideyTerminalAppearanceViewController

#pragma mark - Constants

static const CGFloat kContentPadding = 20;
static const CGFloat kCardInternalPaddingH = 14;
static const CGFloat kCardRowHeight = 40;
static const CGFloat kSectionGap = 20;
static const CGFloat kSectionHeaderHeight = 16;
static const CGFloat kSectionHeaderToCardGap = 8;
static const CGFloat kAnsiWellSize = 28;
static const CGFloat kAnsiLabelHeight = 14;

#pragma mark - loadView

- (void)loadView {
    // The root view is an NSScrollView so content can scroll.
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 516)];
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Flipped container for top-down layout.
    iTermFlippedView *documentView = [[iTermFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 560, 800)];
    scrollView.documentView = documentView;
    self.view = scrollView;

    self.adapter = [[TideyTerminalAppearanceProfileAdapter alloc] init];
    self.coreColorWells = [NSMutableDictionary dictionary];
    self.ansiColorWells = [NSMutableArray array];

    CGFloat contentWidth = 560 - kContentPadding * 2;
    CGFloat y = 0; // top-down in flipped view

    // ===== FONT section =====
    y += [self addSectionHeader:@"FONT" toView:documentView atY:y width:contentWidth];
    y += [self buildFontCardInView:documentView atY:y width:contentWidth];
    y += kSectionGap;

    // ===== COLORS section =====
    y += [self addSectionHeader:@"COLORS" toView:documentView atY:y width:contentWidth];
    y += [self buildCoreColorsCardInView:documentView atY:y width:contentWidth];
    y += kSectionGap;

    // ===== ANSI PALETTE section =====
    y += [self addSectionHeader:@"ANSI PALETTE" toView:documentView atY:y width:contentWidth];
    y += [self buildANSICardInView:documentView atY:y width:contentWidth];
    y += kSectionGap;

    // ===== BROWSER section =====
    y += [self addSectionHeader:@"BROWSER" toView:documentView atY:y width:contentWidth];
    y += [self buildBrowserCardInView:documentView atY:y width:contentWidth];
    y += 24; // bottom padding

    // Set document view height to fit content
    NSRect docFrame = documentView.frame;
    docFrame.size.height = y;
    documentView.frame = docFrame;

    [self reloadValuesFromProfile];
}

#pragma mark - Section Header

- (CGFloat)addSectionHeader:(NSString *)title toView:(NSView *)parent atY:(CGFloat)y width:(CGFloat)width {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    label.textColor = TideySettingsSecondaryTextColor();
    label.frame = NSMakeRect(kContentPadding + 2, y, width, kSectionHeaderHeight);
    [parent addSubview:label];
    return kSectionHeaderHeight + kSectionHeaderToCardGap;
}

#pragma mark - Font Card

- (CGFloat)buildFontCardInView:(NSView *)parent atY:(CGFloat)y width:(CGFloat)width {
    CGFloat cardHeight = kCardRowHeight * 2 + 1; // 2 rows + 1 divider
    TideySettingsCardView *card = [[TideySettingsCardView alloc] initWithFrame:NSMakeRect(kContentPadding, y, width, cardHeight)];
    [parent addSubview:card];

    // Row 1: Font Family
    {
        NSTextField *label = [NSTextField labelWithString:@"Font Family"];
        label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        label.textColor = TideySettingsPrimaryTextColor();
        label.frame = NSMakeRect(kCardInternalPaddingH, 10, 150, 20);
        [card addSubview:label];

        NSButton *changeButton = [[NSButton alloc] initWithFrame:NSMakeRect(width - kCardInternalPaddingH - 70, 8, 70, 24)];
        changeButton.title = @"Change\u2026";
        changeButton.bezelStyle = NSBezelStyleRounded;
        changeButton.font = [NSFont systemFontOfSize:12];
        changeButton.target = self;
        changeButton.action = @selector(chooseFont:);
        [card addSubview:changeButton];

        self.fontPreviewLabel = [NSTextField labelWithString:@""];
        self.fontPreviewLabel.font = [NSFont systemFontOfSize:13];
        self.fontPreviewLabel.textColor = TideySettingsSecondaryTextColor();
        self.fontPreviewLabel.alignment = NSTextAlignmentRight;
        self.fontPreviewLabel.frame = NSMakeRect(150, 10, width - kCardInternalPaddingH - 70 - 150 - 8, 20);
        [card addSubview:self.fontPreviewLabel];
    }

    // Divider
    {
        TideySettingsCardDivider *div = [[TideySettingsCardDivider alloc] initWithFrame:NSMakeRect(kCardInternalPaddingH, kCardRowHeight, width - kCardInternalPaddingH * 2, 1)];
        [card addSubview:div];
    }

    // Row 2: Size
    {
        CGFloat row2Y = kCardRowHeight + 1;
        NSTextField *label = [NSTextField labelWithString:@"Size"];
        label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        label.textColor = TideySettingsPrimaryTextColor();
        label.frame = NSMakeRect(kCardInternalPaddingH, row2Y + 10, 60, 20);
        [card addSubview:label];

        self.fontSizeStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(width - kCardInternalPaddingH - 20, row2Y + 8, 20, 24)];
        self.fontSizeStepper.minValue = 6;
        self.fontSizeStepper.maxValue = 48;
        self.fontSizeStepper.increment = 1;
        self.fontSizeStepper.target = self;
        self.fontSizeStepper.action = @selector(fontSizeStepperDidChange:);
        [card addSubview:self.fontSizeStepper];

        self.fontSizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(width - kCardInternalPaddingH - 20 - 8 - 52, row2Y + 8, 52, 24)];
        self.fontSizeField.delegate = self;
        self.fontSizeField.alignment = NSTextAlignmentCenter;
        self.fontSizeField.font = [NSFont systemFontOfSize:13];
        [card addSubview:self.fontSizeField];
    }

    return cardHeight;
}

#pragma mark - Core Colors Card

- (CGFloat)buildCoreColorsCardInView:(NSView *)parent atY:(CGFloat)y width:(CGFloat)width {
    NSArray<NSArray<NSString *> *> *coreRows = @[
        @[ @"Background", KEY_BACKGROUND_COLOR ],
        @[ @"Foreground", KEY_FOREGROUND_COLOR ],
        @[ @"Cursor", KEY_CURSOR_COLOR ],
        @[ @"Selection", KEY_SELECTION_COLOR ],
    ];

    NSInteger rowCount = (NSInteger)coreRows.count;
    CGFloat cardHeight = kCardRowHeight * rowCount + (rowCount - 1); // rows + dividers
    TideySettingsCardView *card = [[TideySettingsCardView alloc] initWithFrame:NSMakeRect(kContentPadding, y, width, cardHeight)];
    [parent addSubview:card];

    CGFloat rowY = 0;
    for (NSInteger i = 0; i < rowCount; i++) {
        if (i > 0) {
            TideySettingsCardDivider *div = [[TideySettingsCardDivider alloc] initWithFrame:NSMakeRect(kCardInternalPaddingH, rowY, width - kCardInternalPaddingH * 2, 1)];
            [card addSubview:div];
            rowY += 1;
        }

        NSTextField *label = [NSTextField labelWithString:coreRows[i][0]];
        label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        label.textColor = TideySettingsPrimaryTextColor();
        label.frame = NSMakeRect(kCardInternalPaddingH, rowY + 10, 200, 20);
        [card addSubview:label];

        TideyColorSwatchView *well = [[TideyColorSwatchView alloc] initWithFrame:NSMakeRect(width - kCardInternalPaddingH - 24, rowY + 8, 24, 24)];
        well.target = self;
        well.action = @selector(coreColorWellDidChange:);
        well.identifier = coreRows[i][1];
        [card addSubview:well];
        self.coreColorWells[coreRows[i][1]] = well;

        rowY += kCardRowHeight;
    }

    return cardHeight;
}

#pragma mark - ANSI Palette Card

- (CGFloat)buildANSICardInView:(NSView *)parent atY:(CGFloat)y width:(CGFloat)width {
    // 2 rows of 8 wells, each well has a number label below
    CGFloat gridPadding = 14;
    CGFloat availableWidth = width - gridPadding * 2;
    CGFloat cellSpacing = (availableWidth - kAnsiWellSize * 8) / 7.0;
    CGFloat rowHeight = kAnsiWellSize + kAnsiLabelHeight + 4; // well + gap + label
    CGFloat gridHeight = 12 + rowHeight + 6 + rowHeight + 12; // top padding + row1 + gap + row2 + bottom padding
    TideySettingsCardView *card = [[TideySettingsCardView alloc] initWithFrame:NSMakeRect(kContentPadding, y, width, gridHeight)];
    [parent addSubview:card];

    for (NSInteger i = 0; i < 16; i++) {
        NSInteger row = i / 8;
        NSInteger col = i % 8;
        CGFloat cellX = gridPadding + col * (kAnsiWellSize + cellSpacing);
        CGFloat cellY = 12 + row * (rowHeight + 6);

        TideyColorSwatchView *well = [[TideyColorSwatchView alloc] initWithFrame:NSMakeRect(cellX, cellY, kAnsiWellSize, kAnsiWellSize)];
        well.target = self;
        well.action = @selector(ansiColorWellDidChange:);
        [well setTag:i];
        [card addSubview:well];
        [self.ansiColorWells addObject:well];

        NSTextField *numLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld", (long)i]];
        numLabel.font = [NSFont systemFontOfSize:9];
        numLabel.textColor = [NSColor colorWithSRGBRed:0x55/255.0 green:0x55/255.0 blue:0x55/255.0 alpha:1.0];
        numLabel.alignment = NSTextAlignmentCenter;
        numLabel.frame = NSMakeRect(cellX - 2, cellY + kAnsiWellSize + 2, kAnsiWellSize + 4, kAnsiLabelHeight);
        [card addSubview:numLabel];
    }

    return gridHeight;
}

#pragma mark - Browser Card

- (CGFloat)buildBrowserCardInView:(NSView *)parent atY:(CGFloat)y width:(CGFloat)width {
    CGFloat cardHeight = 64;
    TideySettingsCardView *card = [[TideySettingsCardView alloc] initWithFrame:NSMakeRect(kContentPadding, y, width, cardHeight)];
    [parent addSubview:card];

    // Vertically center label / field / button around rowCenterY (card center);
    // status label sits below, anchored to the card bottom.
    CGFloat saveButtonWidth = 60;
    CGFloat saveButtonHeight = 24;
    CGFloat fieldHeight = 24;
    CGFloat labelHeight = 20;
    CGFloat rowCenterY = cardHeight / 2.0;

    NSTextField *homepageLabel = [NSTextField labelWithString:@"Homepage"];
    homepageLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    homepageLabel.textColor = TideySettingsPrimaryTextColor();
    homepageLabel.frame = NSMakeRect(kCardInternalPaddingH, rowCenterY - labelHeight / 2.0, 80, labelHeight);
    [card addSubview:homepageLabel];

    CGFloat fieldX = kCardInternalPaddingH + 80 + 8;
    CGFloat saveButtonX = width - kCardInternalPaddingH - saveButtonWidth;
    CGFloat fieldWidth = saveButtonX - fieldX - 8;
    self.browserHomepageField = [[NSTextField alloc] initWithFrame:NSMakeRect(fieldX, rowCenterY - fieldHeight / 2.0, fieldWidth, fieldHeight)];
    self.browserHomepageField.font = [NSFont systemFontOfSize:13];
    self.browserHomepageField.placeholderString = @"https://example.com";
    self.browserHomepageField.bezelStyle = NSTextFieldRoundedBezel;
    self.browserHomepageField.target = self;
    self.browserHomepageField.action = @selector(saveBrowserHomepage:);
    [card addSubview:self.browserHomepageField];

    // NSBezelStyleRounded has uneven top/bottom bezel padding inside the frame.
    // Push the button down 1pt so its visual center aligns with the homepage
    // field's text baseline instead of its frame center.
    NSButton *saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(saveButtonX, rowCenterY - saveButtonHeight / 2.0 + 1, saveButtonWidth, saveButtonHeight)];
    saveButton.title = @"Save";
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.font = [NSFont systemFontOfSize:12];
    saveButton.target = self;
    saveButton.action = @selector(saveBrowserHomepage:);
    [card addSubview:saveButton];

    self.browserStatusLabel = [NSTextField labelWithString:@""];
    self.browserStatusLabel.font = [NSFont systemFontOfSize:11];
    self.browserStatusLabel.textColor = TideySettingsSecondaryTextColor();
    self.browserStatusLabel.frame = NSMakeRect(kCardInternalPaddingH, cardHeight - 18, width - kCardInternalPaddingH * 2, 14);
    self.browserStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:self.browserStatusLabel];

    return cardHeight;
}

#pragma mark - Profile Read/Write

- (void)reloadValuesFromProfile {
    self.selectedFont = [self.adapter normalFont];
    [self updateFontControls];
    for (NSString *key in self.coreColorWells) {
        self.coreColorWells[key].color = [self.adapter colorForKey:key];
    }
    for (NSInteger i = 0; i < (NSInteger)self.ansiColorWells.count; i++) {
        self.ansiColorWells[i].color = [self.adapter ansiColorAtIndex:i];
    }
    self.browserHomepageField.stringValue = [iTermRootTerminalView tideyBrowserHomepageURLString] ?: @"";
    self.browserStatusLabel.stringValue = @"";
}

- (void)updateFontControls {
    self.fontPreviewLabel.stringValue = self.selectedFont.displayName ?: self.selectedFont.fontName;
    self.fontSizeField.doubleValue = self.selectedFont.pointSize;
    self.fontSizeStepper.doubleValue = self.selectedFont.pointSize;
}

#pragma mark - Font Actions

- (void)chooseFont:(id)sender {
    (void)sender;
    [iTermFontPanel makeDefault];
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    fontManager.target = self;
    [fontManager setSelectedFont:self.selectedFont isMultiple:NO];
    [[fontManager fontPanel:YES] makeKeyAndOrderFront:nil];
}

- (IBAction)changeFont:(id)sender {
    NSFontManager *fontManager = sender;
    NSFont *newFont = [fontManager convertFont:self.selectedFont ?: [self.adapter normalFont]];
    if (!newFont) {
        return;
    }
    self.selectedFont = newFont;
    [self updateFontControls];
    [self.adapter updateNormalFont:newFont];
}

- (void)fontSizeStepperDidChange:(NSStepper *)sender {
    [self applyFontSize:sender.doubleValue];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.fontSizeField) {
        [self applyFontSize:self.fontSizeField.doubleValue];
    }
}

- (void)applyFontSize:(CGFloat)pointSize {
    CGFloat clamped = MIN(48, MAX(6, pointSize));
    NSFont *resized = [NSFont fontWithName:self.selectedFont.fontName size:clamped];
    self.selectedFont = resized ?: [self.adapter normalFont];
    [self updateFontControls];
    [self.adapter updateNormalFont:self.selectedFont];
}

#pragma mark - Color Actions

- (void)coreColorWellDidChange:(TideyColorSwatchView *)sender {
    [self.adapter updateColor:sender.color forKey:sender.identifier];
}

- (void)ansiColorWellDidChange:(TideyColorSwatchView *)sender {
    [self.adapter updateANSIColor:sender.color atIndex:sender.tag];
}

#pragma mark - Browser Actions

- (void)saveBrowserHomepage:(id)sender {
    (void)sender;
    NSString *input = self.browserHomepageField.stringValue ?: @"";
    NSString *normalized = [iTermRootTerminalView tideyNormalizedBrowserURLString:input];
    NSURL *url = normalized.length > 0 ? [NSURL URLWithString:normalized] : nil;
    BOOL validURL = url.scheme.length > 0 && (url.host.length > 0 || (url.fileURL && url.path.length > 0));
    if (!validURL) {
        self.browserStatusLabel.textColor = [NSColor colorWithSRGBRed:1.0 green:0.32 blue:0.28 alpha:1.0];
        self.browserStatusLabel.stringValue = @"Enter a valid URL.";
        return;
    }
    [iTermRootTerminalView tideySetBrowserHomepageURLString:normalized];
    self.browserHomepageField.stringValue = [iTermRootTerminalView tideyBrowserHomepageURLString] ?: @"";
    self.browserStatusLabel.textColor = TideySettingsSecondaryTextColor();
    self.browserStatusLabel.stringValue = @"Saved.";
}

// Keep the font panel limited to family/face/size.
- (NSUInteger)validModesForFontPanel:(NSFontPanel *)fontPanel {
    (void)fontPanel;
    return kValidModesForFontPanel;
}

@end
