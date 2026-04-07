#import "TideyTerminalAppearanceViewController.h"

#import "ITAddressBookMgr.h"
#import "TideyTerminalAppearanceProfileAdapter.h"
#import "iTermFontPanel.h"

@interface TideyTerminalAppearanceViewController ()

@property(nonatomic, strong) TideyTerminalAppearanceProfileAdapter *adapter;
@property(nonatomic, strong) NSTextField *fontPreviewLabel;
@property(nonatomic, strong) NSTextField *fontSizeField;
@property(nonatomic, strong) NSStepper *fontSizeStepper;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSColorWell *> *coreColorWells;
@property(nonatomic, strong) NSMutableArray<NSColorWell *> *ansiColorWells;
@property(nonatomic, strong) NSFont *selectedFont;

@end

@implementation TideyTerminalAppearanceViewController

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 480)];
    self.view = view;
    self.adapter = [[TideyTerminalAppearanceProfileAdapter alloc] init];
    self.coreColorWells = [NSMutableDictionary dictionary];
    self.ansiColorWells = [NSMutableArray array];

    NSTextField *title = [NSTextField labelWithString:@"Terminal Appearance"];
    title.font = [NSFont boldSystemFontOfSize:15];
    title.frame = NSMakeRect(24, 432, 260, 22);
    [view addSubview:title];

    NSTextField *subtitle = [NSTextField labelWithString:@"Font, core colors, and ANSI palette for the default terminal profile."];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor secondaryLabelColor];
    subtitle.frame = NSMakeRect(24, 408, 420, 18);
    [view addSubview:subtitle];

    [self buildFontSectionInView:view];
    [self buildCoreColorsSectionInView:view];
    [self buildANSISectionInView:view];
    [self reloadValuesFromProfile];
}

- (void)buildFontSectionInView:(NSView *)view {
    NSTextField *fontLabel = [NSTextField labelWithString:@"Font"];
    fontLabel.font = [NSFont boldSystemFontOfSize:13];
    fontLabel.frame = NSMakeRect(24, 360, 120, 18);
    [view addSubview:fontLabel];

    self.fontPreviewLabel = [NSTextField labelWithString:@""];
    self.fontPreviewLabel.frame = NSMakeRect(24, 332, 360, 18);
    [view addSubview:self.fontPreviewLabel];

    NSButton *chooseFontButton = [NSButton buttonWithTitle:@"Choose Font…"
                                                    target:self
                                                    action:@selector(chooseFont:)];
    chooseFontButton.frame = NSMakeRect(24, 294, 120, 30);
    [view addSubview:chooseFontButton];

    NSTextField *sizeLabel = [NSTextField labelWithString:@"Size"];
    sizeLabel.frame = NSMakeRect(170, 300, 40, 18);
    [view addSubview:sizeLabel];

    self.fontSizeField = [[NSTextField alloc] initWithFrame:NSMakeRect(214, 295, 52, 24)];
    self.fontSizeField.delegate = self;
    [view addSubview:self.fontSizeField];

    self.fontSizeStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(272, 294, 20, 24)];
    self.fontSizeStepper.minValue = 6;
    self.fontSizeStepper.maxValue = 48;
    self.fontSizeStepper.increment = 1;
    self.fontSizeStepper.target = self;
    self.fontSizeStepper.action = @selector(fontSizeStepperDidChange:);
    [view addSubview:self.fontSizeStepper];
}

- (void)buildCoreColorsSectionInView:(NSView *)view {
    NSTextField *coreColorsLabel = [NSTextField labelWithString:@"Core Colors"];
    coreColorsLabel.font = [NSFont boldSystemFontOfSize:13];
    coreColorsLabel.frame = NSMakeRect(24, 246, 120, 18);
    [view addSubview:coreColorsLabel];

    NSArray<NSArray<NSString *> *> *coreRows = @[
        @[ @"Foreground", KEY_FOREGROUND_COLOR ],
        @[ @"Background", KEY_BACKGROUND_COLOR ],
        @[ @"Cursor", KEY_CURSOR_COLOR ],
        @[ @"Selection", KEY_SELECTION_COLOR ],
    ];

    CGFloat x = 24;
    for (NSArray<NSString *> *row in coreRows) {
        NSTextField *label = [NSTextField labelWithString:row[0]];
        label.alignment = NSTextAlignmentCenter;
        label.frame = NSMakeRect(x, 214, 96, 18);
        [view addSubview:label];

        NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(x + 28, 176, 40, 28)];
        well.target = self;
        well.action = @selector(coreColorWellDidChange:);
        well.identifier = row[1];
        [view addSubview:well];
        self.coreColorWells[row[1]] = well;

        x += 116;
    }
}

- (void)buildANSISectionInView:(NSView *)view {
    NSTextField *ansiLabel = [NSTextField labelWithString:@"ANSI Palette"];
    ansiLabel.font = [NSFont boldSystemFontOfSize:13];
    ansiLabel.frame = NSMakeRect(24, 134, 160, 18);
    [view addSubview:ansiLabel];

    CGFloat startX = 24;
    CGFloat startY = 90;
    CGFloat cellSize = 28;
    CGFloat gap = 10;
    for (NSInteger i = 0; i < 16; i++) {
        NSInteger row = i / 8;
        NSInteger column = i % 8;
        CGFloat x = startX + column * (cellSize + gap + 24);
        CGFloat y = startY - row * 54;

        NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld", (long)i]];
        label.alignment = NSTextAlignmentCenter;
        label.frame = NSMakeRect(x - 2, y + 30, 32, 16);
        [view addSubview:label];

        NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(x, y, cellSize, cellSize)];
        well.target = self;
        well.action = @selector(ansiColorWellDidChange:);
        well.tag = i;
        [view addSubview:well];
        [self.ansiColorWells addObject:well];
    }
}

- (void)reloadValuesFromProfile {
    self.selectedFont = [self.adapter normalFont];
    [self updateFontControls];
    for (NSString *key in self.coreColorWells) {
        self.coreColorWells[key].color = [self.adapter colorForKey:key];
    }
    for (NSInteger i = 0; i < self.ansiColorWells.count; i++) {
        self.ansiColorWells[i].color = [self.adapter ansiColorAtIndex:i];
    }
}

- (void)updateFontControls {
    self.fontPreviewLabel.stringValue = [NSString stringWithFormat:@"%@ %.0f", self.selectedFont.displayName ?: self.selectedFont.fontName, self.selectedFont.pointSize];
    self.fontPreviewLabel.font = self.selectedFont;
    self.fontSizeField.doubleValue = self.selectedFont.pointSize;
    self.fontSizeStepper.doubleValue = self.selectedFont.pointSize;
}

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

- (void)coreColorWellDidChange:(NSColorWell *)sender {
    [self.adapter updateColor:sender.color forKey:sender.identifier];
}

- (void)ansiColorWellDidChange:(NSColorWell *)sender {
    [self.adapter updateANSIColor:sender.color atIndex:sender.tag];
}

// Keep the font panel limited to family/face/size.
- (NSUInteger)validModesForFontPanel:(NSFontPanel *)fontPanel {
    (void)fontPanel;
    return kValidModesForFontPanel;
}

@end
