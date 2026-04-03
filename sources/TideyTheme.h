//
//  TideyTheme.h
//  iTerm2SharedARC
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TideyTheme : NSObject

@property (nonatomic, readonly) NSColor *bgBase;
@property (nonatomic, readonly) NSColor *bgSurface;
@property (nonatomic, readonly) NSColor *bgControl;
@property (nonatomic, readonly) NSColor *bgHover;

@property (nonatomic, readonly) NSColor *borderDefault;
@property (nonatomic, readonly) NSColor *borderStrong;
@property (nonatomic, readonly) NSColor *lineActive;
@property (nonatomic, readonly) NSColor *lineHairline;

@property (nonatomic, readonly) NSColor *textPrimary;
@property (nonatomic, readonly) NSColor *textSecondary;
@property (nonatomic, readonly) NSColor *textTertiary;
@property (nonatomic, readonly) NSColor *textOnAccent;

@property (nonatomic, readonly) NSColor *accentPrimary;
@property (nonatomic, readonly) NSColor *accentMuted;
@property (nonatomic, readonly) NSColor *accentIndicator;

@property (nonatomic, readonly) NSColor *stateSuccess;
@property (nonatomic, readonly) NSColor *stateWarning;
@property (nonatomic, readonly) NSColor *stateError;

@property (nonatomic, readonly) NSColor *ansiBlack;
@property (nonatomic, readonly) NSColor *ansiRed;
@property (nonatomic, readonly) NSColor *ansiGreen;
@property (nonatomic, readonly) NSColor *ansiYellow;
@property (nonatomic, readonly) NSColor *ansiBlue;
@property (nonatomic, readonly) NSColor *ansiMagenta;
@property (nonatomic, readonly) NSColor *ansiCyan;
@property (nonatomic, readonly) NSColor *ansiWhite;

@property (nonatomic, readonly) NSColor *ansiBrightBlack;
@property (nonatomic, readonly) NSColor *ansiBrightRed;
@property (nonatomic, readonly) NSColor *ansiBrightGreen;
@property (nonatomic, readonly) NSColor *ansiBrightYellow;
@property (nonatomic, readonly) NSColor *ansiBrightBlue;
@property (nonatomic, readonly) NSColor *ansiBrightMagenta;
@property (nonatomic, readonly) NSColor *ansiBrightCyan;
@property (nonatomic, readonly) NSColor *ansiBrightWhite;

@property (nonatomic, readonly) NSColor *background;
@property (nonatomic, readonly) NSColor *foreground;
@property (nonatomic, readonly) NSColor *cursor;
@property (nonatomic, readonly) NSColor *imeCursor;
@property (nonatomic, readonly) NSColor *selection;

- (instancetype)initWithDictionary:(NSDictionary<NSString *, NSColor *> *)dictionary NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
