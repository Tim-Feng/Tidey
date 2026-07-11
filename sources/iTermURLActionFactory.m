//
//  iTermURLActionFactory.m
//  iTerm2
//
//  Created by George Nachman on 2/26/17.
//
//

#import "iTermURLActionFactory.h"

#import "ContextMenuActionPrefsController.h"
#import "DebugLogging.h"
#import "iTerm2SharedARC-Swift.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermCancelable.h"
#import "iTermLocatedString.h"
#import "iTermPathFinder.h"
#import "iTermSemanticHistoryController.h"
#import "iTermTextExtractor.h"
#import "iTermURLStore.h"
#import "NSCharacterSet+iTerm.h"
#import "NSStringITerm.h"
#import "NSURL+iTerm.h"
#import "RegexKitLite.h"
#import "SCPPath.h"
#import "SmartSelectionController.h"
#import "URLAction.h"
#import "VT100RemoteHost.h"

typedef enum {
    iTermURLActionFactoryPhasePrompt,
    iTermURLActionFactoryPhaseHypertextLink,
    iTermURLActionFactoryPhaseExistingFile,
    iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines,
    iTermURLActionFactoryPhaseSmartSelectionAction,
    iTermURLActionFactoryPhaseAnyStringSemanticHistory,
    iTermURLActionFactoryPhaseURLLike,
    iTermURLActionFactoryPhaseSecureCopy,
    iTermURLActionFactoryPhaseFailed
} iTermURLActionFactoryPhase;

@interface iTermURLActionFactory()
@property (nonatomic) VT100GridCoord coord;
@property (nonatomic) BOOL respectHardNewlines;
@property (nonatomic) BOOL alternate;
@property (nonatomic, copy) NSString *workingDirectory;
@property (nonatomic, strong) id<VT100RemoteHostReading> remoteHost;
@property (nonatomic, strong) iTermVariableScope *scope;
@property (nonatomic, strong) id<iTermObject> owner;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *selectors;
@property (nonatomic, copy) NSArray *rules;
@property (nonatomic, strong) iTermTextExtractor *extractor;
@property (nonatomic, strong) iTermSemanticHistoryController *semanticHistoryController;
@property (nonatomic, copy) SCPPath *(^pathFactory)(NSString *, int);
@property (nonatomic, copy) void (^completion)(URLAction *);
@property (nonatomic) iTermURLActionFactoryPhase phase;
@property (nonatomic) BOOL workingDirectoryIsLocal;

@property (nonatomic, strong) iTermLocatedString *locatedPrefix;
@property (nonatomic, strong) iTermLocatedString *locatedSuffix;
@property (nonatomic, strong) iTermLocatedString *locatedPrefixRespectingHardNewlines;
@property (nonatomic, strong) iTermLocatedString *locatedSuffixRespectingHardNewlines;
@property (nonatomic, strong) iTermLocatedString *locatedPrefixIgnoringHardNewlines;
@property (nonatomic, strong) iTermLocatedString *locatedSuffixIgnoringHardNewlines;
@end

static NSMutableArray<iTermURLActionFactory *> *sFactories;

@interface iTermURLActionFactory (TideyTesting)
+ (BOOL)tideyShouldPreferRawExistingFileResult:(NSString *)rawFilename
                                rawPrefixChars:(int)rawPrefixChars
                                rawSuffixChars:(int)rawSuffixChars
                                  overFilename:(NSString *)filename
                                   prefixChars:(int)prefixChars
                                   suffixChars:(int)suffixChars;
+ (void)tideyExistingFileActionDictionaryAtX:(int)x
                                           y:(int)y
                                   extractor:(iTermTextExtractor *)extractor
                        respectHardNewlines:(BOOL)respectHardNewlines
                            workingDirectory:(NSString *)workingDirectory
                                  completion:(void (^)(NSDictionary *))completion;
+ (NSDictionary *)tideyOpenURLOrExistingFileActionDictionaryAtX:(int)x
                                                              y:(int)y
                                                      extractor:(iTermTextExtractor *)extractor
                                           respectHardNewlines:(BOOL)respectHardNewlines
                                               workingDirectory:(NSString *)workingDirectory;
@end

static NSCharacterSet *iTermCJKURLBoundaryCharacterSet(void) {
    static NSCharacterSet *characterSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSMutableCharacterSet alloc] init];
        [set addCharactersInRange:NSMakeRange(0x2E80, 0x9FFF - 0x2E80 + 1)];
        [set addCharactersInRange:NSMakeRange(0xF900, 0xFAFF - 0xF900 + 1)];
        [set addCharactersInRange:NSMakeRange(0xFF00, 0xFFEF - 0xFF00 + 1)];
        characterSet = [set copy];
    });
    return characterSet;
}

static BOOL iTermStringIsASCIIOnly(NSString *string) {
    for (NSUInteger i = 0; i < string.length; i++) {
        if ([string characterAtIndex:i] > 0x7f) {
            return NO;
        }
    }
    return YES;
}

static NSSet<NSString *> *iTermURLActionFactorySourceLikeExtensions(void) {
    static NSSet<NSString *> *sourceLikeExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sourceLikeExtensions = [NSSet setWithArray:@[
            @"sh", @"py", @"js", @"ts", @"m", @"h", @"c", @"cpp", @"swift",
            @"go", @"rs", @"java", @"rb", @"pl", @"md", @"txt", @"json",
            @"yaml", @"yml", @"xml", @"html", @"css", @"toml", @"cfg",
            @"conf", @"ini", @"log", @"csv"
        ]];
    });
    return sourceLikeExtensions;
}

static BOOL iTermURLActionFactoryStringIsSourceLikePath(NSString *string) {
    if ([string rangeOfString:@"://"].location != NSNotFound ||
        [string rangeOfString:@"/"].location == NSNotFound) {
        return NO;
    }
    NSString *lastPathComponent = [[string componentsSeparatedByString:@"/"] lastObject];
    NSString *extension = lastPathComponent.pathExtension.lowercaseString;
    return extension.length > 0 && [iTermURLActionFactorySourceLikeExtensions() containsObject:extension];
}

static NSRange iTermURLRangeByTrimmingFullWidthBoundaryPunctuation(NSString *string, NSRange range) {
    if (range.location == NSNotFound || range.length == 0 || NSMaxRange(range) > string.length) {
        return range;
    }
    NSString *candidate = [string substringWithRange:range];
    NSString *trimmed = [candidate stringByTrimmingTrailingCharactersFromCharacterSet:[NSCharacterSet it_fullWidthBoundaryPunctuationCharacterSet]];
    if (trimmed.length == candidate.length) {
        return range;
    }
    return NSMakeRange(range.location, trimmed.length);
}

static VT100GridWindowedRange iTermURLActionFactoryInvalidWindowedRange(void) {
    return VT100GridWindowedRangeMake(VT100GridCoordRangeInvalid, -1, -1);
}

static NSDictionary *iTermURLActionFactoryTideyDictionaryForAction(URLAction *action) {
    if (!action) {
        return nil;
    }
    return @{
        @"actionType": @(action.actionType),
        @"url": action.string ?: @"",
        @"rawFilename": action.rawFilename ?: [NSNull null],
        @"fullPath": action.fullPath ?: [NSNull null],
        @"startX": @(action.visualRange.coordRange.start.x),
        @"startY": @(action.visualRange.coordRange.start.y),
        @"endX": @(action.visualRange.coordRange.end.x),
        @"endY": @(action.visualRange.coordRange.end.y),
        @"osc8": @(action.osc8)
    };
}

@interface iTermURLHitCandidate : NSObject
@property (nonatomic, copy, readonly) NSString *URLString;
@property (nonatomic, readonly) NSRange rangeInSourceString;
@property (nonatomic, readonly) VT100GridCoord startCoord;
@property (nonatomic, readonly) VT100GridCoord endCoord;

+ (instancetype)candidateInString:(NSString *)string
                        clickIndex:(NSInteger)clickIndex
                           columns:(NSArray<NSNumber *> *)columns
                              rows:(NSArray<NSNumber *> *)rows
          allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery;
+ (instancetype)candidateInLocatedString:(iTermLocatedString *)locatedString
                              clickIndex:(NSInteger)clickIndex
                allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery;
+ (instancetype)candidateWithLocatedPrefix:(iTermLocatedString *)locatedPrefix
                              locatedSuffix:(iTermLocatedString *)locatedSuffix
                   allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery;
- (NSDictionary *)dictionaryRepresentation;
@end

@implementation iTermURLHitCandidate

- (instancetype)initWithURLString:(NSString *)URLString
              rangeInSourceString:(NSRange)rangeInSourceString
                        startCoord:(VT100GridCoord)startCoord
                          endCoord:(VT100GridCoord)endCoord {
    self = [super init];
    if (self) {
        _URLString = [URLString copy];
        _rangeInSourceString = rangeInSourceString;
        _startCoord = startCoord;
        _endCoord = endCoord;
    }
    return self;
}

+ (NSArray<NSValue *> *)coordsForColumns:(NSArray<NSNumber *> *)columns rows:(NSArray<NSNumber *> *)rows {
    if (columns.count != rows.count) {
        return nil;
    }

    NSMutableArray<NSValue *> *coords = [NSMutableArray arrayWithCapacity:columns.count];
    for (NSUInteger i = 0; i < columns.count; i++) {
        VT100GridCoord coord = VT100GridCoordMake(columns[i].intValue, rows[i].intValue);
        [coords addObject:[NSValue valueWithBytes:&coord objCType:@encode(VT100GridCoord)]];
    }
    return coords;
}

+ (NSArray<NSValue *> *)coordsForLocatedString:(iTermLocatedString *)locatedString {
    NSMutableArray<NSValue *> *coords = [NSMutableArray arrayWithCapacity:locatedString.gridCoords.count];
    for (NSUInteger i = 0; i < locatedString.gridCoords.count; i++) {
        VT100GridCoord coord = [locatedString.gridCoords coordAt:i];
        [coords addObject:[NSValue valueWithBytes:&coord objCType:@encode(VT100GridCoord)]];
    }
    return coords;
}

+ (BOOL)characterIsHardNewline:(unichar)c {
    return c == '\n' || c == '\r';
}

+ (BOOL)characterIsHardNewlineContinuationWhitespace:(unichar)c {
    return c == ' ' || c == '\t';
}

+ (instancetype)candidateInLocatedString:(iTermLocatedString *)locatedString
                              clickIndex:(NSInteger)clickIndex
                allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery {
    return [self candidateInString:locatedString.string
                        clickIndex:clickIndex
                            coords:[self coordsForLocatedString:locatedString]
          allowHardNewlineRecovery:allowHardNewlineRecovery];
}

+ (instancetype)candidateWithLocatedPrefix:(iTermLocatedString *)locatedPrefix
                              locatedSuffix:(iTermLocatedString *)locatedSuffix
                   allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery {
    if (!locatedPrefix || !locatedSuffix) {
        return nil;
    }

    iTermLocatedString *joined = [[iTermLocatedString alloc] init];
    [joined appendLocatedString:locatedPrefix];
    [joined appendLocatedString:locatedSuffix];
    return [self candidateInLocatedString:joined
                               clickIndex:locatedPrefix.string.length
                 allowHardNewlineRecovery:allowHardNewlineRecovery];
}

+ (instancetype)candidateInString:(NSString *)string
                        clickIndex:(NSInteger)clickIndex
                           columns:(NSArray<NSNumber *> *)columns
                              rows:(NSArray<NSNumber *> *)rows
          allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery {
    return [self candidateInString:string
                        clickIndex:clickIndex
                            coords:[self coordsForColumns:columns rows:rows]
          allowHardNewlineRecovery:allowHardNewlineRecovery];
}

+ (instancetype)candidateInString:(NSString *)string
                        clickIndex:(NSInteger)clickIndex
                            coords:(NSArray<NSValue *> *)coords
          allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery {
    if (!string || clickIndex < 0 || clickIndex >= (NSInteger)string.length || coords.count < string.length) {
        return nil;
    }

    NSMutableString *searchString = [NSMutableString stringWithCapacity:string.length];
    NSMutableArray<NSNumber *> *searchIndexToSourceIndex = [NSMutableArray arrayWithCapacity:string.length];
    NSMutableArray<NSNumber *> *sourceIndexToSearchIndex = [NSMutableArray arrayWithCapacity:string.length];
    for (NSUInteger i = 0; i < string.length; i++) {
        [sourceIndexToSearchIndex addObject:@(-1)];
    }

    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if (allowHardNewlineRecovery && [self characterIsHardNewline:c]) {
            while (i + 1 < string.length &&
                   [self characterIsHardNewlineContinuationWhitespace:[string characterAtIndex:i + 1]]) {
                i++;
            }
            continue;
        }

        NSUInteger searchIndex = searchString.length;
        [searchString appendString:[NSString stringWithCharacters:&c length:1]];
        [searchIndexToSourceIndex addObject:@(i)];
        sourceIndexToSearchIndex[i] = @(searchIndex);
    }

    NSInteger searchClickIndex = sourceIndexToSearchIndex[clickIndex].integerValue;
    if (searchClickIndex < 0) {
        return nil;
    }

    int prefixChars = 0;
    NSString *possibleURL = [searchString substringIncludingOffset:(int)searchClickIndex
                                                 fromCharacterSet:[NSCharacterSet urlCharacterSet]
                                             charsTakenFromPrefix:&prefixChars];
    NSRange URLRangeInPossibleURL = [possibleURL rangeOfURLInString];
    if (URLRangeInPossibleURL.location == NSNotFound) {
        return nil;
    }
    URLRangeInPossibleURL = iTermURLRangeByTrimmingFullWidthBoundaryPunctuation(possibleURL, URLRangeInPossibleURL);

    NSInteger possibleURLStart = searchClickIndex - prefixChars;
    NSRange URLRangeInSearchString =
        NSMakeRange(possibleURLStart + URLRangeInPossibleURL.location,
                    URLRangeInPossibleURL.length);
    if (searchClickIndex < (NSInteger)URLRangeInSearchString.location ||
        searchClickIndex >= (NSInteger)NSMaxRange(URLRangeInSearchString) ||
        NSMaxRange(URLRangeInSearchString) > searchIndexToSourceIndex.count) {
        return nil;
    }

    NSUInteger sourceStart = searchIndexToSourceIndex[URLRangeInSearchString.location].unsignedIntegerValue;
    NSUInteger sourceEnd = searchIndexToSourceIndex[NSMaxRange(URLRangeInSearchString) - 1].unsignedIntegerValue;
    VT100GridCoord startCoord;
    VT100GridCoord endCoord;
    [coords[sourceStart] getValue:&startCoord];
    [coords[sourceEnd] getValue:&endCoord];
    NSString *URLString = [possibleURL substringWithRange:URLRangeInPossibleURL];
    return [[self alloc] initWithURLString:URLString
                       rangeInSourceString:NSMakeRange(sourceStart, sourceEnd - sourceStart + 1)
                                startCoord:startCoord
                                  endCoord:endCoord];
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"url": self.URLString ?: @"",
        @"startX": @(self.startCoord.x),
        @"startY": @(self.startCoord.y),
        @"endX": @(self.endCoord.x),
        @"endY": @(self.endCoord.y),
        @"sourceLocation": @(self.rangeInSourceString.location),
        @"sourceLength": @(self.rangeInSourceString.length),
    };
}

@end

typedef struct {
    int line;
    int contentStart;
    int contentEnd;
    int contentRight;
    int firstTokenX;
    int lastTokenX;
    unichar firstTokenChar;
    unichar lastTokenChar;
    BOOL hasContent;
    BOOL hasToken;
    BOOL containsSlash;
    int eol;
} iTermCanonicalClickLineInfo;

@interface iTermCanonicalClickContext : NSObject
@property(nonatomic, strong) iTermLocatedString *locatedPrefix;
@property(nonatomic, strong) iTermLocatedString *locatedSuffix;
+ (instancetype)contextAtCoord:(VT100GridCoord)coord
                      extractor:(iTermTextExtractor *)extractor
                       maxChars:(int)maxChars;
@end

static BOOL iTermCanonicalClickScreenCharIsNull(screen_char_t c) {
    return !c.complexChar && !c.image && c.code == 0;
}

static BOOL iTermCanonicalClickScreenCharIsSkipped(screen_char_t c) {
    return (!c.complexChar &&
            (ScreenCharIsDWC_RIGHT(c) || ScreenCharIsDWC_SKIP(c)));
}

static NSString *iTermCanonicalClickStringForScreenChar(screen_char_t c) {
    if (iTermCanonicalClickScreenCharIsNull(c) ||
        iTermCanonicalClickScreenCharIsSkipped(c) ||
        c.image) {
        return nil;
    }
    if (!c.complexChar && c.code == TAB_FILLER) {
        return nil;
    }
    return ScreenCharToStr(&c);
}

static BOOL iTermCanonicalClickCharacterIsWhitespace(unichar c) {
    return [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c];
}

static BOOL iTermCanonicalClickStringIsWhitespace(NSString *string) {
    if (!string.length) {
        return NO;
    }
    for (NSUInteger i = 0; i < string.length; i++) {
        if (!iTermCanonicalClickCharacterIsWhitespace([string characterAtIndex:i])) {
            return NO;
        }
    }
    return YES;
}

static BOOL iTermCanonicalClickCharacterIsPathToken(unichar c) {
    if (iTermCanonicalClickCharacterIsWhitespace(c)) {
        return NO;
    }
    return [[NSCharacterSet filenameCharacterSet] characterIsMember:c];
}

static iTermCanonicalClickLineInfo iTermCanonicalClickLineInfoMake(iTermTextExtractor *extractor,
                                                                   int lineNumber) {
    iTermCanonicalClickLineInfo info = {
        .line = lineNumber,
        .contentStart = 0,
        .contentEnd = 0,
        .contentRight = 0,
        .firstTokenX = -1,
        .lastTokenX = -1,
        .firstTokenChar = 0,
        .lastTokenChar = 0,
        .hasContent = NO,
        .hasToken = NO,
        .containsSlash = NO,
        .eol = EOL_HARD
    };

    id<iTermTextDataSource> dataSource = extractor.dataSource;
    if (!dataSource || lineNumber < 0 || lineNumber >= [dataSource numberOfLines]) {
        return info;
    }

    ScreenCharArray *line = [dataSource screenCharArrayForLine:lineNumber];
    info.eol = line.eol;

    const int width = [dataSource width];
    VT100GridRange logicalWindow = extractor.logicalWindow;
    int left = logicalWindow.length ? logicalWindow.location : 0;
    int right = logicalWindow.length ? logicalWindow.location + logicalWindow.length : width;
    left = MAX(0, MIN(left, width));
    right = MAX(left, MIN(right, MIN(width, line.length)));
    info.contentRight = right;

    for (int x = left; x < right; x++) {
        NSString *string = iTermCanonicalClickStringForScreenChar(line.line[x]);
        if (!string.length) {
            continue;
        }
        if (!info.hasContent) {
            info.contentStart = x;
        }
        info.contentEnd = x + 1;
        info.hasContent = YES;
        if ([string rangeOfString:@"/"].location != NSNotFound) {
            info.containsSlash = YES;
        }
    }

    if (!info.hasContent) {
        info.contentStart = left;
        info.contentEnd = left;
        return info;
    }

    for (int x = info.contentStart; x < info.contentEnd; x++) {
        NSString *string = iTermCanonicalClickStringForScreenChar(line.line[x]);
        if (!string.length || iTermCanonicalClickStringIsWhitespace(string)) {
            continue;
        }
        info.firstTokenX = x;
        info.firstTokenChar = [string characterAtIndex:0];
        info.hasToken = YES;
        break;
    }

    for (int x = info.contentEnd - 1; x >= info.contentStart; x--) {
        NSString *string = iTermCanonicalClickStringForScreenChar(line.line[x]);
        if (!string.length || iTermCanonicalClickStringIsWhitespace(string)) {
            continue;
        }
        info.lastTokenX = x;
        info.lastTokenChar = [string characterAtIndex:string.length - 1];
        break;
    }

    return info;
}

static BOOL iTermCanonicalClickLineNeedsHardJoin(iTermCanonicalClickLineInfo previous,
                                                 iTermCanonicalClickLineInfo next) {
    if (previous.eol != EOL_HARD) {
        return NO;
    }
    if (!previous.hasToken || !next.hasToken) {
        return NO;
    }
    // Full-screen TUIs lay out text inside their own content area and paint each visual row with
    // cursor addressing. Those rows have EOL_HARD and may end well before the PTY's right edge.
    // Treat a filename-character boundary as a possible continuation here. The reconstructed
    // string is only accepted later if iTermPathFinder verifies that it names an existing file.
    return (iTermCanonicalClickCharacterIsPathToken(previous.lastTokenChar) &&
            iTermCanonicalClickCharacterIsPathToken(next.firstTokenChar));
}

static BOOL iTermCanonicalClickShouldJoin(iTermCanonicalClickLineInfo previous,
                                          iTermCanonicalClickLineInfo next) {
    if (previous.eol != EOL_HARD) {
        return previous.hasContent && next.hasContent;
    }
    return iTermCanonicalClickLineNeedsHardJoin(previous, next);
}

@implementation iTermCanonicalClickContext

+ (instancetype)contextAtCoord:(VT100GridCoord)coord
                      extractor:(iTermTextExtractor *)extractor
                       maxChars:(int)maxChars {
    id<iTermTextDataSource> dataSource = extractor.dataSource;
    if (!dataSource ||
        coord.y < 0 ||
        coord.y >= [dataSource numberOfLines] ||
        coord.x < 0 ||
        coord.x >= [dataSource width]) {
        return nil;
    }

    iTermCanonicalClickLineInfo clickedInfo = iTermCanonicalClickLineInfoMake(extractor, coord.y);
    if (!clickedInfo.hasContent || coord.x < clickedInfo.contentStart || coord.x >= clickedInfo.contentEnd) {
        return nil;
    }

    int startLine = coord.y;
    int endLine = coord.y;
    int estimatedChars = clickedInfo.contentEnd - clickedInfo.contentStart;
    BOOL sawHardJoin = NO;

    while (startLine > 0 && estimatedChars < maxChars) {
        iTermCanonicalClickLineInfo current = iTermCanonicalClickLineInfoMake(extractor, startLine);
        iTermCanonicalClickLineInfo previous = iTermCanonicalClickLineInfoMake(extractor, startLine - 1);
        if (!iTermCanonicalClickShouldJoin(previous, current)) {
            break;
        }
        if (iTermCanonicalClickLineNeedsHardJoin(previous, current)) {
            sawHardJoin = YES;
        }
        startLine--;
        estimatedChars += MAX(0, previous.contentEnd - previous.contentStart);
    }

    while (endLine + 1 < [dataSource numberOfLines] && estimatedChars < maxChars) {
        iTermCanonicalClickLineInfo current = iTermCanonicalClickLineInfoMake(extractor, endLine);
        iTermCanonicalClickLineInfo next = iTermCanonicalClickLineInfoMake(extractor, endLine + 1);
        if (!iTermCanonicalClickShouldJoin(current, next)) {
            break;
        }
        if (iTermCanonicalClickLineNeedsHardJoin(current, next)) {
            sawHardJoin = YES;
        }
        endLine++;
        estimatedChars += MAX(0, next.contentEnd - next.contentStart);
    }

    if (!sawHardJoin) {
        return nil;
    }

    iTermLocatedString *prefix = [[iTermLocatedString alloc] init];
    iTermLocatedString *suffix = [[iTermLocatedString alloc] init];
    BOOL includedClickCoord = NO;

    for (int y = startLine; y <= endLine; y++) {
        iTermCanonicalClickLineInfo info = iTermCanonicalClickLineInfoMake(extractor, y);
        if (!info.hasContent) {
            continue;
        }

        int startX = info.contentStart;
        BOOL hardJoinedFromPrevious = NO;
        if (y > startLine) {
            iTermCanonicalClickLineInfo previous = iTermCanonicalClickLineInfoMake(extractor, y - 1);
            if (iTermCanonicalClickLineNeedsHardJoin(previous, info)) {
                startX = info.firstTokenX;
                hardJoinedFromPrevious = YES;
            }
        }

        if (hardJoinedFromPrevious) {
            VT100GridCoord markerCoord = VT100GridCoordMake(startX, y);
            iTermLocatedString *target = (y <= coord.y) ? prefix : suffix;
            [target appendString:iTermPathFinderOptionalHardWrapSeparator at:markerCoord];
        }

        ScreenCharArray *line = [dataSource screenCharArrayForLine:y];
        for (int x = startX; x < info.contentEnd; x++) {
            NSString *string = iTermCanonicalClickStringForScreenChar(line.line[x]);
            if (!string.length) {
                continue;
            }

            VT100GridCoord charCoord = VT100GridCoordMake(x, y);
            if (VT100GridCoordEquals(charCoord, coord)) {
                includedClickCoord = YES;
            }
            iTermLocatedString *target =
                (VT100GridCoordOrder(charCoord, coord) == NSOrderedAscending) ? prefix : suffix;
            [target appendString:string at:charCoord];
        }
    }

    if (!includedClickCoord || !suffix.length) {
        return nil;
    }

    iTermCanonicalClickContext *context = [[self alloc] init];
    context.locatedPrefix = prefix;
    context.locatedSuffix = suffix;
    return context;
}

@end

@implementation iTermURLActionFactory {
    BOOL _finished;
    id<iTermCancelable> _pathFinderCanceler;
}

+ (BOOL)tideyShouldPreferRawExistingFileResult:(NSString *)rawFilename
                                rawPrefixChars:(int)rawPrefixChars
                                rawSuffixChars:(int)rawSuffixChars
                                  overFilename:(NSString *)filename
                                   prefixChars:(int)prefixChars
                                   suffixChars:(int)suffixChars {
    if (rawFilename.length == 0) {
        return NO;
    }
    if (filename.length == 0) {
        return YES;
    }
    if ([rawFilename isEqualToString:filename]) {
        return NO;
    }
    if ([rawFilename rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound) {
        return NO;
    }

    const int rawChars = MAX(0, rawPrefixChars) + MAX(0, rawSuffixChars);
    const int initialChars = MAX(0, prefixChars) + MAX(0, suffixChars);
    return rawChars > initialChars;
}

+ (void)tideyExistingFileActionDictionaryAtX:(int)x
                                           y:(int)y
                                   extractor:(iTermTextExtractor *)extractor
                        respectHardNewlines:(BOOL)respectHardNewlines
                            workingDirectory:(NSString *)workingDirectory
                                  completion:(void (^)(NSDictionary *))completion {
    iTermSemanticHistoryController *semanticHistoryController = [[iTermSemanticHistoryController alloc] init];
    [self urlActionAtCoord:VT100GridCoordMake(x, y)
       respectHardNewlines:respectHardNewlines
                 alternate:NO
          workingDirectory:workingDirectory ?: @""
                     scope:nil
                     owner:nil
                remoteHost:nil
                 selectors:@{}
                     rules:@[]
                 extractor:extractor
 semanticHistoryController:semanticHistoryController
               pathFactory:^SCPPath *(NSString *path, int line) {
        return nil;
    }
                completion:^(URLAction *action) {
        if (!action) {
            completion(@{ @"action": [NSNull null] });
            return;
        }
        completion(@{
            @"actionType": @(action.actionType),
            @"string": action.string ?: @"",
            @"rawFilename": action.rawFilename ?: [NSNull null],
            @"fullPath": action.fullPath ?: [NSNull null],
            @"startX": @(action.visualRange.coordRange.start.x),
            @"startY": @(action.visualRange.coordRange.start.y),
            @"endX": @(action.visualRange.coordRange.end.x),
            @"endY": @(action.visualRange.coordRange.end.y)
        });
    }];
}

+ (instancetype)urlActionAtCoord:(VT100GridCoord)coord
             respectHardNewlines:(BOOL)respectHardNewlines
                       alternate:(BOOL)alternate
                workingDirectory:(NSString *)workingDirectory
                           scope:(iTermVariableScope *)scope
                           owner:(id<iTermObject>)owner
                      remoteHost:(id<VT100RemoteHostReading>)remoteHost
                       selectors:(NSDictionary<NSNumber *, NSString *> *)selectors
                           rules:(NSArray *)rules
                       extractor:(iTermTextExtractor *)extractor
       semanticHistoryController:(iTermSemanticHistoryController *)semanticHistoryController
                     pathFactory:(SCPPath *(^)(NSString *, int))pathFactory
                      completion:(void (^)(URLAction *))completion {
    DLog(@"URLActionFactory start at %@", VT100GridCoordDescription(coord));

    iTermURLActionFactory *factory = [[iTermURLActionFactory alloc] init];
    factory.coord = coord;
    factory.respectHardNewlines = respectHardNewlines;
    factory.alternate = alternate;
    factory.workingDirectory = workingDirectory;
    factory.remoteHost = remoteHost;
    factory.scope = scope;
    factory.owner = owner;
    factory.selectors = selectors;
    factory.rules = rules;
    factory.extractor = extractor;
    factory.semanticHistoryController = semanticHistoryController;
    factory.pathFactory = pathFactory;
    factory.completion = completion;
    factory.phase = iTermURLActionFactoryPhasePrompt;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sFactories = [NSMutableArray array];
    });
    DLog(@"Created %@", self);

    [sFactories addObject:factory];
    [factory tryCurrentPhase];
    return factory;
}

- (void)cancelOperation {
    DLog(@"Cancel %@", self);
    [_pathFinderCanceler cancelOperation];
    [sFactories removeObject:self];
}

- (iTermTextExtractor *)extractor {
    VT100GridRange logicalWindow = _extractor.logicalWindow;
    const int width = [_extractor.dataSource width];
    if (logicalWindow.location >= width) {
        logicalWindow.location = MAX(0, width - 1);
    }
    if (logicalWindow.location + logicalWindow.length > width) {
        logicalWindow.length = width - logicalWindow.location;
    }
    _extractor.logicalWindow = logicalWindow;
    return _extractor;
}

// This is always eventually callsed.
- (void)completeWithAction:(URLAction *)action {
    DLog(@"Phase completed successfully with action %@", action);
    _finished = YES;
    self.completion(action);
    [sFactories removeObject:self];
}

- (void)fail {
    DLog(@"Phase failed");
    self.phase = [self phaseAfter:self.phase];
    [self tryCurrentPhase];
}

- (iTermURLActionFactoryPhase)phaseAfter:(iTermURLActionFactoryPhase)phase {
    if ([iTermAdvancedSettingsModel disableSmartSelectionActionsOnClick]) {
        switch (phase) {
            case iTermURLActionFactoryPhasePrompt:
                return iTermURLActionFactoryPhaseHypertextLink;
            case iTermURLActionFactoryPhaseHypertextLink:
                return iTermURLActionFactoryPhaseExistingFile;
            case iTermURLActionFactoryPhaseExistingFile:
                return iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines;
            case iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines:
                return iTermURLActionFactoryPhaseAnyStringSemanticHistory;
            case iTermURLActionFactoryPhaseAnyStringSemanticHistory:
                return iTermURLActionFactoryPhaseURLLike;
            case iTermURLActionFactoryPhaseURLLike:
                return iTermURLActionFactoryPhaseSecureCopy;
            case iTermURLActionFactoryPhaseSecureCopy:
                return iTermURLActionFactoryPhaseFailed;
            case iTermURLActionFactoryPhaseFailed:
                return iTermURLActionFactoryPhaseFailed;

            case iTermURLActionFactoryPhaseSmartSelectionAction:
            default:
                return iTermURLActionFactoryPhaseFailed;
        }
    }
    if ([iTermAdvancedSettingsModel prioritizeSmartSelectionActions]) {
        switch (phase) {
            case iTermURLActionFactoryPhasePrompt:
                return iTermURLActionFactoryPhaseHypertextLink;
            case iTermURLActionFactoryPhaseHypertextLink:
                return iTermURLActionFactoryPhaseSmartSelectionAction;
            case iTermURLActionFactoryPhaseSmartSelectionAction:
                return iTermURLActionFactoryPhaseExistingFile;
            case iTermURLActionFactoryPhaseExistingFile:
                return iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines;
            case iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines:
                return iTermURLActionFactoryPhaseAnyStringSemanticHistory;
            case iTermURLActionFactoryPhaseAnyStringSemanticHistory:
                return iTermURLActionFactoryPhaseURLLike;
            case iTermURLActionFactoryPhaseURLLike:
                return iTermURLActionFactoryPhaseSecureCopy;
            case iTermURLActionFactoryPhaseSecureCopy:
                return iTermURLActionFactoryPhaseFailed;
            case iTermURLActionFactoryPhaseFailed:
                return iTermURLActionFactoryPhaseFailed;
            default:
                return iTermURLActionFactoryPhaseFailed;
        }
    }
    return phase + 1;
}

- (void)tryCurrentPhase {
    if (self.extractor.dataSource == nil) {
        [self completeWithAction:nil];
        return;
    }
    DLog(@"Try phase %@", @(self.phase));
    switch (self.phase) {
        case iTermURLActionFactoryPhasePrompt:
            [self tryPrompt];
            break;
        case iTermURLActionFactoryPhaseHypertextLink:
            [self tryHypertextLink];
            break;
        case iTermURLActionFactoryPhaseExistingFile:
            [self tryExistingFileRespectingHardNewlines:self.respectHardNewlines];
            break;
        case iTermURLActionFactoryPhaseExistingFileRespectingHardNewlines:
            [self tryExistingFileRespectingHardNewlines:!self.respectHardNewlines];
            break;
        case iTermURLActionFactoryPhaseSmartSelectionAction:
            [self trySmartSelectionAction];
            break;
        case iTermURLActionFactoryPhaseAnyStringSemanticHistory:
            [self tryAnyStringSemanticHistory];
            break;
        case iTermURLActionFactoryPhaseURLLike:
            [self tryURLLike];
            break;
        case iTermURLActionFactoryPhaseSecureCopy:
            [self trySecureCopy];
            break;
        case iTermURLActionFactoryPhaseFailed:
            [self completeWithAction:nil];
            break;
    }
}

- (void)tryPrompt {
    if (![iTermAdvancedSettingsModel enableCmdClickPromptForShowCommandInfo]) {
        [self fail];
        return;
    }
    URLAction *action = [self urlActionForPrompt];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}
- (void)tryHypertextLink {
    URLAction *action;
    action = [self urlActionForHypertextLink];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (void)tryExistingFileRespectingHardNewlines:(BOOL)respectHardNewlines {
    const int maxChars = [iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix];
    __weak __typeof(self) weakSelf = self;
    void (^tryWrappedContext)(void) = ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        iTermLocatedString *locatedPrefix =
            [strongSelf.extractor wrappedLocatedStringAt:strongSelf.coord
                                                 forward:NO
                                     respectHardNewlines:respectHardNewlines
                                                maxChars:maxChars
                                       continuationChars:[NSMutableIndexSet indexSet]
                                     convertNullsToSpace:NO];
        if (respectHardNewlines) {
            strongSelf.locatedPrefixRespectingHardNewlines = locatedPrefix;
        } else {
            strongSelf.locatedPrefixIgnoringHardNewlines = locatedPrefix;
        }

        iTermLocatedString *locatedSuffix =
            [strongSelf.extractor wrappedLocatedStringAt:strongSelf.coord
                                                 forward:YES
                                     respectHardNewlines:respectHardNewlines
                                                maxChars:maxChars
                                       continuationChars:[NSMutableIndexSet indexSet]
                                     convertNullsToSpace:NO];
        if (respectHardNewlines) {
            strongSelf.locatedSuffixRespectingHardNewlines = locatedSuffix;
        } else {
            strongSelf.locatedSuffixIgnoringHardNewlines = locatedSuffix;
        }

        [strongSelf urlActionForExistingFileWithPrefix:locatedPrefix
                                                suffix:locatedSuffix
                                            completion:^(URLAction *action, BOOL workingDirectoryIsLocal) {
            strongSelf.workingDirectoryIsLocal = workingDirectoryIsLocal;
            if (action) {
                [strongSelf completeWithAction:action];
            } else {
                [strongSelf fail];
            }
        }];
    };

    iTermCanonicalClickContext *canonicalContext =
        [iTermCanonicalClickContext contextAtCoord:self.coord
                                         extractor:self.extractor
                                          maxChars:maxChars];
    if (!canonicalContext) {
        tryWrappedContext();
        return;
    }

    [self urlActionForExistingFileWithPrefix:canonicalContext.locatedPrefix
                                      suffix:canonicalContext.locatedSuffix
                                  completion:^(URLAction *action, BOOL workingDirectoryIsLocal) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.workingDirectoryIsLocal = workingDirectoryIsLocal;
        if (action) {
            [strongSelf completeWithAction:action];
        } else {
            tryWrappedContext();
        }
    }];
}

- (void)trySmartSelectionAction {
    [self computeURLActionForSmartSelection:^(URLAction *action) {
        if (action) {
            [self completeWithAction:action];
        } else {
            [self fail];
        }
    }];
}

- (void)tryAnyStringSemanticHistory {
    URLAction *action = [self urlActionForAnyStringSemanticHistory];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (void)tryURLLike {
    // No luck. Look for something vaguely URL-like.
    URLAction *action = [self urlActionForURLLike];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

- (iTermLocatedString *)locatedPrefixForURLLikeRespectingHardNewlines:(BOOL)respectHardNewlines {
    return respectHardNewlines ? self.locatedPrefixRespectingHardNewlines : self.locatedPrefixIgnoringHardNewlines;
}

- (iTermLocatedString *)locatedSuffixForURLLikeRespectingHardNewlines:(BOOL)respectHardNewlines {
    return respectHardNewlines ? self.locatedSuffixRespectingHardNewlines : self.locatedSuffixIgnoringHardNewlines;
}

+ (NSString *)tideyURLLikeCandidateInJoinedString:(NSString *)joined clickIndex:(NSInteger)clickIndex {
    if (!joined || clickIndex < 0 || clickIndex > joined.length) {
        return nil;
    }
    int prefixChars = 0;
    NSString *possibleUrl = [joined substringIncludingOffset:(int)clickIndex
                                            fromCharacterSet:[NSCharacterSet urlCharacterSet]
                                        charsTakenFromPrefix:&prefixChars];
    NSRange rangeWithoutNearbyPunctuation = [possibleUrl rangeOfURLInString];
    if (rangeWithoutNearbyPunctuation.location == NSNotFound) {
        return nil;
    }
    rangeWithoutNearbyPunctuation = iTermURLRangeByTrimmingFullWidthBoundaryPunctuation(possibleUrl, rangeWithoutNearbyPunctuation);
    return [possibleUrl substringWithRange:rangeWithoutNearbyPunctuation];
}

+ (NSString *)tideyPreferredURLLikeCandidateWithPrimaryJoinedString:(NSString *)primaryJoined
                                               fallbackJoinedString:(NSString *)fallbackJoined
                                                         clickIndex:(NSInteger)clickIndex
                                               respectHardNewlines:(BOOL)respectHardNewlines {
    NSString *joined = respectHardNewlines ? primaryJoined : fallbackJoined;
    return [self tideyURLLikeCandidateInJoinedString:joined clickIndex:clickIndex];
}

+ (BOOL)tideyShouldSuppressURLLikeCandidate:(NSString *)primaryCandidate
                          whenRecoveredForm:(NSString *)recoveredCandidate {
    if (!primaryCandidate.length || !recoveredCandidate.length) {
        return NO;
    }
    if (recoveredCandidate.length <= primaryCandidate.length ||
        ![recoveredCandidate hasPrefix:primaryCandidate]) {
        return NO;
    }
    return iTermURLActionFactoryStringIsSourceLikePath(recoveredCandidate);
}

+ (NSDictionary *)tideyURLHitCandidateDictionaryForLogicalString:(NSString *)logicalString
                                                      clickIndex:(NSInteger)clickIndex
                                                         columns:(NSArray<NSNumber *> *)columns
                                                            rows:(NSArray<NSNumber *> *)rows
                                        allowHardNewlineRecovery:(BOOL)allowHardNewlineRecovery {
    return [[iTermURLHitCandidate candidateInString:logicalString
                                         clickIndex:clickIndex
                                            columns:columns
                                               rows:rows
                           allowHardNewlineRecovery:allowHardNewlineRecovery] dictionaryRepresentation];
}

+ (VT100GridWindowedRange)tideyOpenURLWindowedRangeAtCoord:(VT100GridCoord)visualCoord
                                                  extractor:(iTermTextExtractor *)extractor
                                       respectHardNewlines:(BOOL)respectHardNewlines {
    URLAction *action = [self tideyOpenURLActionAtCoord:visualCoord
                                              extractor:extractor
                                   respectHardNewlines:respectHardNewlines];
    if (!action) {
        return iTermURLActionFactoryInvalidWindowedRange();
    }
    return action.visualRange;
}

+ (URLAction *)tideyOpenURLActionAtCoord:(VT100GridCoord)visualCoord
                               extractor:(iTermTextExtractor *)extractor
                    respectHardNewlines:(BOOL)respectHardNewlines {
    if (!extractor.dataSource || visualCoord.y < 0) {
        return nil;
    }

    extractor.supportBidi = [iTermPreferences bidiEnabled];
    VT100GridCoord logicalCoord = [extractor logicalCoordForVisualCoord:visualCoord];
    if ([extractor characterAt:logicalCoord].code == 0) {
        return nil;
    }
    [extractor restrictToLogicalWindowIncludingCoord:visualCoord];

    iTermURLActionFactory *factory = [[iTermURLActionFactory alloc] init];
    factory.coord = visualCoord;
    factory.extractor = extractor;
    URLAction *hypertextAction = [factory urlActionForHypertextLink];
    if (hypertextAction) {
        return hypertextAction;
    }

    iTermLocatedString *prefix =
        [extractor wrappedLocatedStringAt:logicalCoord
                                  forward:NO
                      respectHardNewlines:respectHardNewlines
                                 maxChars:[iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix]
                        continuationChars:[NSMutableIndexSet indexSet]
                      convertNullsToSpace:NO];
    iTermLocatedString *suffix =
        [extractor wrappedLocatedStringAt:logicalCoord
                                  forward:YES
                      respectHardNewlines:respectHardNewlines
                                 maxChars:[iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix]
                        continuationChars:[NSMutableIndexSet indexSet]
                      convertNullsToSpace:NO];
    iTermURLHitCandidate *candidate =
        [iTermURLHitCandidate candidateWithLocatedPrefix:prefix
                                           locatedSuffix:suffix
                                allowHardNewlineRecovery:YES];
    if (!candidate.URLString.length ||
        [candidate.URLString rangeOfString:@"://"].location == NSNotFound) {
        return nil;
    }

    NSURL *url = [NSURL URLWithUserSuppliedString:candidate.URLString];
    if (!url || [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url] == nil) {
        return nil;
    }

    factory.extractor = extractor;
    return [factory urlActionForURLHitCandidate:candidate];
}

+ (URLAction *)tideyOpenURLOrExistingFileActionAtCoord:(VT100GridCoord)visualCoord
                                             extractor:(iTermTextExtractor *)extractor
                                  respectHardNewlines:(BOOL)respectHardNewlines
                                     workingDirectory:(NSString *)workingDirectory
                            semanticHistoryController:(iTermSemanticHistoryController *)semanticHistoryController {
    if (!extractor.dataSource || visualCoord.y < 0) {
        return nil;
    }

    extractor.supportBidi = [iTermPreferences bidiEnabled];
    VT100GridCoord logicalCoord = [extractor logicalCoordForVisualCoord:visualCoord];
    if ([extractor characterAt:logicalCoord].code == 0) {
        return nil;
    }
    [extractor restrictToLogicalWindowIncludingCoord:visualCoord];

    iTermURLActionFactory *factory = [[iTermURLActionFactory alloc] init];
    factory.coord = logicalCoord;
    factory.respectHardNewlines = respectHardNewlines;
    factory.workingDirectory = workingDirectory ?: @"";
    factory.extractor = extractor;
    factory.semanticHistoryController = semanticHistoryController;

    URLAction *hypertextAction = [factory urlActionForHypertextLink];
    if (hypertextAction) {
        return hypertextAction;
    }

    URLAction *existingFileAction =
        [factory tideySynchronousExistingFileActionRespectingHardNewlines:respectHardNewlines];
    if (existingFileAction) {
        return existingFileAction;
    }

    existingFileAction =
        [factory tideySynchronousExistingFileActionRespectingHardNewlines:!respectHardNewlines];
    if (existingFileAction) {
        return existingFileAction;
    }

    return [self tideyOpenURLActionAtCoord:visualCoord
                                 extractor:extractor
                      respectHardNewlines:respectHardNewlines];
}

+ (NSDictionary *)tideyOpenURLActionDictionaryAtX:(int)x
                                                y:(int)y
                                        extractor:(iTermTextExtractor *)extractor
                             respectHardNewlines:(BOOL)respectHardNewlines {
    URLAction *action = [self tideyOpenURLActionAtCoord:VT100GridCoordMake(x, y)
                                              extractor:extractor
                                   respectHardNewlines:respectHardNewlines];
    return iTermURLActionFactoryTideyDictionaryForAction(action);
}

+ (NSDictionary *)tideyOpenURLOrExistingFileActionDictionaryAtX:(int)x
                                                              y:(int)y
                                                      extractor:(iTermTextExtractor *)extractor
                                           respectHardNewlines:(BOOL)respectHardNewlines
                                               workingDirectory:(NSString *)workingDirectory {
    iTermSemanticHistoryController *semanticHistoryController = [[iTermSemanticHistoryController alloc] init];
    URLAction *action = [self tideyOpenURLOrExistingFileActionAtCoord:VT100GridCoordMake(x, y)
                                                            extractor:extractor
                                                 respectHardNewlines:respectHardNewlines
                                                    workingDirectory:workingDirectory
                                           semanticHistoryController:semanticHistoryController];
    return iTermURLActionFactoryTideyDictionaryForAction(action);
}

- (void)trySecureCopy {
    // TODO: We usually don't get here because "foo.txt" looks enough like a URL that we do a DNS
    // lookup and fail. It'd be nice to fallback to an SCP file path.
    // See if we can conjure up a secure copy path.
    URLAction *action = [self urlActionWithSecureCopy];
    if (action) {
        [self completeWithAction:action];
    } else {
        [self fail];
    }
}

#pragma mark - Sub-factories

- (URLAction *)urlActionForPrompt {
    if (![iTermAdvancedSettingsModel enableCmdClickPromptForShowCommandInfo]) {
        return nil;
    }
    VT100GridWindowedRange range = { 0 };
    id<VT100ScreenMarkReading> mark = [self.extractor.dataSource commandMarkAt:self.coord
                                                               mustHaveCommand:YES
                                                                         range:&range];
    if (!mark ||
        mark.promptRange.start.x < 0 ||
        !mark.command ||
        !VT100GridWindowedRangeContainsCoord(range, self.coord)) {
        return nil;
    }
    URLAction *action = [URLAction actionToShowCommandInfoForMark:mark
                                                            coord:self.coord];
    action.logicalRange = range;
    action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];
    return action;
}
- (URLAction *)urlActionForHypertextLink {
    iTermTextExtractor *extractor = self.extractor;
    iTermExternalAttribute *oea = [extractor externalAttributesAt:self.coord];
    NSString *urlId = nil;
    NSString *target = nil;
    NSURL *url = [extractor urlOfHypertextLinkAt:self.coord urlId:&urlId target:&target];
    if (url != nil) {
        DLog(@"Found hypertext url %@", url);
        URLAction *action = [URLAction urlActionToOpenURL:url.absoluteString];
        action.hover = YES;
        // file: URLs with a fragment go through semantic history and therefore need a workingDirectory.
        action.workingDirectory = self.workingDirectory;
        action.osc8 = YES;
        action.target = target;
        action.logicalRange = [extractor rangeOfCoordinatesAround:self.coord
                                                  maximumDistance:1000
                                                      passingTest:^BOOL(screen_char_t *c,
                                                                        iTermExternalAttribute *ea,
                                                                        VT100GridCoord coord) {
            if ([NSObject object:ea.url isEqualToObject:oea.url]) {
                return YES;
            }
            NSString *thisId;
            NSString *thisTarget;
            NSURL *thisURL = [extractor urlOfHypertextLinkAt:coord urlId:&thisId target:&thisTarget];
            // Hover together only if URL, ID, and target are equal.
            return ([thisURL isEqual:url] &&
                    (thisId == urlId || [thisId isEqualToString:urlId]) &&
                    [NSObject object:thisTarget isEqualToObject:target]);
        }];
        action.visualRange = [extractor visualWindowedRangeForLogical:action.logicalRange];
        return action;
    } else {
        return nil;
    }
}

- (void)urlActionForExistingFileWithPrefix:(iTermLocatedString *)locatedPrefix
                                  suffix:(iTermLocatedString *)locatedSuffix
                                completion:(void (^)(URLAction *, BOOL workingDirectoryIsLocal))completion {
    NSMutableCharacterSet *prefixCharacterSet = [[NSCharacterSet filenameCharacterSet] mutableCopy];
    [prefixCharacterSet addCharactersInString:iTermPathFinderOptionalHardWrapSeparator];
    NSString *possibleFilePart1 =
    [locatedPrefix.string substringIncludingOffset:[locatedPrefix.string length] - 1
                                  fromCharacterSet:prefixCharacterSet
                              charsTakenFromPrefix:NULL];

    // Allow quotes and commas in the suffix to pick up Python line numbers like:
    //   File "/path/to/file.py", line 12, in <module>
    NSMutableCharacterSet *suffixCharacterSet = [[NSCharacterSet filenameCharacterSet] mutableCopy];
    [suffixCharacterSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@"\","]];
    [suffixCharacterSet addCharactersInString:iTermPathFinderOptionalHardWrapSeparator];

    NSString *possibleFilePart2 =
    [locatedSuffix.string substringIncludingOffset:0
                                  fromCharacterSet:suffixCharacterSet
                              charsTakenFromPrefix:NULL];
    NSString *rawPrefix = locatedPrefix.string ?: @"";
    NSString *rawSuffix = locatedSuffix.string ?: @"";
    DLog(@"Prefix=%@", possibleFilePart1);
    DLog(@"Suffix=%@", possibleFilePart2);
    DLog(@"URLActionFactory sending request for %@ + %@",
         [possibleFilePart1 substringFromIndex:MAX(10, possibleFilePart1.length) - 10],
         [possibleFilePart2 substringToIndex:MIN(possibleFilePart2.length, 10)]);
    BOOL shouldRetryWithRawContext =
        (([rawPrefix containsString:@" "] || [rawSuffix containsString:@" "]) &&
         (![rawPrefix isEqualToString:possibleFilePart1] || ![rawSuffix isEqualToString:possibleFilePart2]));

    __weak __typeof(self) weakSelf = self;
    __block void (^request)(NSString *, NSString *, BOOL, NSString *, int, int, BOOL);
    request = ^(NSString *prefix,
                NSString *suffix,
                BOOL usingRawContext,
                NSString *originalFilename,
                int originalPrefixChars,
                int originalSuffixChars,
                BOOL originalWorkingDirectoryIsLocal) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            completion(nil, NO);
            return;
        }
        strongSelf->_pathFinderCanceler =
            [strongSelf.semanticHistoryController pathOfExistingFileFoundWithPrefix:prefix
                                                                             suffix:suffix
                                                                   workingDirectory:strongSelf.workingDirectory
                                                                     trimWhitespace:NO
                                                                         completion:^(NSString *filename,
                                                                                      int prefixChars,
                                                                                      int suffixChars,
                                                                                      BOOL workingDirectoryIsLocal) {
            DLog(@"Semantic history controller returned filename %@ with %@ prefix and %@ suffix chars", filename, @(prefixChars), @(suffixChars));
            if (!usingRawContext && shouldRetryWithRawContext) {
                DLog(@"Retry existing-file lookup with raw located strings");
                request(rawPrefix,
                        rawSuffix,
                        YES,
                        filename,
                        prefixChars,
                        suffixChars,
                        workingDirectoryIsLocal);
                return;
            }
            BOOL finalWorkingDirectoryIsLocal = workingDirectoryIsLocal;
            if (usingRawContext &&
                originalFilename &&
                ![iTermURLActionFactory tideyShouldPreferRawExistingFileResult:filename
                                                                rawPrefixChars:prefixChars
                                                                rawSuffixChars:suffixChars
                                                                  overFilename:originalFilename
                                                                   prefixChars:originalPrefixChars
                                                                   suffixChars:originalSuffixChars]) {
                filename = originalFilename;
                prefixChars = originalPrefixChars;
                suffixChars = originalSuffixChars;
                finalWorkingDirectoryIsLocal = originalWorkingDirectoryIsLocal;
            }
            URLAction *action = [strongSelf urlActionForFilename:filename
                                                   locatedPrefix:locatedPrefix
                                                   locatedSuffix:locatedSuffix
                                                     prefixChars:prefixChars
                                                     suffixChars:suffixChars];
            completion(action, finalWorkingDirectoryIsLocal);
        }];
    };
    request(possibleFilePart1, possibleFilePart2, NO, nil, 0, 0, NO);
}

- (URLAction *)tideySynchronousURLActionForExistingFileWithPrefix:(iTermLocatedString *)locatedPrefix
                                                           suffix:(iTermLocatedString *)locatedSuffix {
    NSMutableCharacterSet *prefixCharacterSet = [[NSCharacterSet filenameCharacterSet] mutableCopy];
    [prefixCharacterSet addCharactersInString:iTermPathFinderOptionalHardWrapSeparator];
    NSString *possibleFilePart1 =
    [locatedPrefix.string substringIncludingOffset:[locatedPrefix.string length] - 1
                                  fromCharacterSet:prefixCharacterSet
                              charsTakenFromPrefix:NULL];

    NSMutableCharacterSet *suffixCharacterSet = [[NSCharacterSet filenameCharacterSet] mutableCopy];
    [suffixCharacterSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@"\","]];
    [suffixCharacterSet addCharactersInString:iTermPathFinderOptionalHardWrapSeparator];

    NSString *possibleFilePart2 =
    [locatedSuffix.string substringIncludingOffset:0
                                  fromCharacterSet:suffixCharacterSet
                              charsTakenFromPrefix:NULL];
    NSString *rawPrefix = locatedPrefix.string ?: @"";
    NSString *rawSuffix = locatedSuffix.string ?: @"";
    BOOL shouldRetryWithRawContext =
        (([rawPrefix containsString:@" "] || [rawSuffix containsString:@" "]) &&
         (![rawPrefix isEqualToString:possibleFilePart1] || ![rawSuffix isEqualToString:possibleFilePart2]));

    int prefixChars = 0;
    int suffixChars = 0;
    NSString *filename =
        [self.semanticHistoryController pathOfExistingFileFoundWithPrefix:possibleFilePart1
                                                                   suffix:possibleFilePart2
                                                         workingDirectory:self.workingDirectory
                                                     charsTakenFromPrefix:&prefixChars
                                                     charsTakenFromSuffix:&suffixChars
                                                           trimWhitespace:NO];
    if (shouldRetryWithRawContext) {
        int rawPrefixChars = 0;
        int rawSuffixChars = 0;
        NSString *rawFilename =
            [self.semanticHistoryController pathOfExistingFileFoundWithPrefix:rawPrefix
                                                                       suffix:rawSuffix
                                                             workingDirectory:self.workingDirectory
                                                         charsTakenFromPrefix:&rawPrefixChars
                                                         charsTakenFromSuffix:&rawSuffixChars
                                                               trimWhitespace:NO];
        if ([iTermURLActionFactory tideyShouldPreferRawExistingFileResult:rawFilename
                                                           rawPrefixChars:rawPrefixChars
                                                           rawSuffixChars:rawSuffixChars
                                                             overFilename:filename
                                                              prefixChars:prefixChars
                                                              suffixChars:suffixChars]) {
            filename = rawFilename;
            prefixChars = rawPrefixChars;
            suffixChars = rawSuffixChars;
        }
    }

    return [self urlActionForFilename:filename
                        locatedPrefix:locatedPrefix
                        locatedSuffix:locatedSuffix
                          prefixChars:prefixChars
                          suffixChars:suffixChars];
}

- (URLAction *)tideySynchronousExistingFileActionRespectingHardNewlines:(BOOL)respectHardNewlines {
    const int maxChars = [iTermAdvancedSettingsModel maxSemanticHistoryPrefixOrSuffix];
    URLAction *(^wrappedContextAction)(void) = ^{
        iTermLocatedString *locatedPrefix =
            [self.extractor wrappedLocatedStringAt:self.coord
                                           forward:NO
                               respectHardNewlines:respectHardNewlines
                                          maxChars:maxChars
                                 continuationChars:[NSMutableIndexSet indexSet]
                               convertNullsToSpace:NO];
        iTermLocatedString *locatedSuffix =
            [self.extractor wrappedLocatedStringAt:self.coord
                                           forward:YES
                               respectHardNewlines:respectHardNewlines
                                          maxChars:maxChars
                                 continuationChars:[NSMutableIndexSet indexSet]
                               convertNullsToSpace:NO];
        return [self tideySynchronousURLActionForExistingFileWithPrefix:locatedPrefix
                                                                 suffix:locatedSuffix];
    };

    iTermCanonicalClickContext *canonicalContext =
        [iTermCanonicalClickContext contextAtCoord:self.coord
                                         extractor:self.extractor
                                          maxChars:maxChars];
    if (canonicalContext) {
        URLAction *action =
            [self tideySynchronousURLActionForExistingFileWithPrefix:canonicalContext.locatedPrefix
                                                              suffix:canonicalContext.locatedSuffix];
        if (action) {
            return action;
        }
    }

    return wrappedContextAction();
}

- (URLAction *)urlActionForFilename:(NSString *)filename
                      locatedPrefix:(iTermLocatedString *)locatedPrefix
                      locatedSuffix:(iTermLocatedString *)locatedSuffix
                        prefixChars:(int)prefixChars
                        suffixChars:(int)suffixChars {
    if (self.extractor.dataSource == nil) {
        return nil;
    }
    // Don't consider / to be a valid filename because it's useless and single/double slashes are
    // pretty common.
    if (filename.length == 0 ||
        [[filename stringByReplacingOccurrencesOfString:@"//" withString:@"/"] isEqualToString:@"/"]) {
        DLog(@"filename is bogus, reject");
        return nil;
    }

    DLog(@"Accepting filename from brute force search: %@", filename);
    // If you clicked on an existing filename, use it.
    URLAction *action = [URLAction urlActionToOpenExistingFile:filename];
    VT100GridWindowedRange range;

    if (locatedPrefix.gridCoords.count > 0 && prefixChars > 0) {
        NSInteger i = MAX(0, (NSInteger)locatedPrefix.gridCoords.count - prefixChars);
        range.coordRange.start = [locatedPrefix.gridCoords coordAt:i];
    } else {
        // Everything is coming from the suffix (e.g., when mouse is on first char of filename)
        range.coordRange.start = [locatedSuffix.gridCoords  coordAt:0];
    }
    VT100GridCoord lastCoord;
    // Ensure we don't run off the end of suffixCoords if something unexpected happens.
    // Subtract 1 because the 0th index into suffixCoords corresponds to 1 suffix char being used, etc.
    NSInteger i = MIN((NSInteger)locatedSuffix.gridCoords.count - 1, suffixChars - 1);
    if (i >= 0) {
        lastCoord = [locatedSuffix.gridCoords coordAt:i];
    } else {
        // This shouldn't happen, but better safe than sorry
        lastCoord = [locatedPrefix.gridCoords last];
    }
    range.coordRange.end = [self.extractor successorOfCoord:lastCoord];
    range.columnWindow = self.extractor.logicalWindow;
    action.logicalRange = range;
    action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];

    NSString *lineNumber = nil;
    NSString *columnNumber = nil;
    action.rawFilename = filename;
    action.fullPath = [self.semanticHistoryController cleanedUpPathFromPath:filename
                                                                     suffix:[locatedSuffix.string substringFromIndex:suffixChars]
                                                           workingDirectory:self.workingDirectory
                                                        extractedLineNumber:&lineNumber
                                                               columnNumber:&columnNumber];
    action.lineNumber = lineNumber;
    action.columnNumber = columnNumber;
    action.workingDirectory = self.workingDirectory;
    return action;
}

- (void)computeURLActionForSmartSelection:(void (^)(URLAction *action))completion {
    // Next, see if smart selection matches anything with an action.
    VT100GridWindowedRange smartRange;
    SmartMatch *smartMatch = [self.extractor smartSelectionAt:self.coord
                                                    withRules:self.rules
                                               actionRequired:YES
                                                        range:&smartRange
                                             ignoringNewlines:!self.respectHardNewlines];
    NSArray *actions = [SmartSelectionController actionsInRule:smartMatch.rule];
    DLog(@"  Smart selection produces these actions: %@", actions);
    if (actions.count) {
        NSString *content = smartMatch.components[0];
        if (!self.respectHardNewlines) {
            content = [content stringByReplacingOccurrencesOfString:@"\n" withString:@""];
        }
        DLog(@"  Actions match this content: %@", content);
        URLAction *action = [URLAction urlActionToPerformSmartSelectionRule:smartMatch.rule
                                                                   onString:content];
        action.logicalRange = smartRange;
        action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];
        NSInteger index = 0;
        if (self.alternate && actions.count > 1) {
            DLog(@"Selecting alternate action from %@", actions);
            index = 1;
        }
        ContextMenuActions value = [ContextMenuActionPrefsController actionForActionDict:actions[index]];
        action.selector = NSSelectorFromString(self.selectors[@(value)]);
        if ([ContextMenuActionPrefsController actionForActionDict:actions[index]] == kOpenUrlContextMenuAction) {
            action.hover = YES;
        }
        action.representedObject = @{ iTermSmartSelectionActionContextKeyAction: actions[index],
                                      iTermSmartSelectionActionContextKeyComponents: smartMatch.components,
                                      iTermSmartSelectionActionContextKeyWorkingDirectory: self.workingDirectory ?: [NSNull null],
                                      iTermSmartSelectionActionContextKeyRemoteHost: (id)self.remoteHost ?: [NSNull null]};
        completion(action);
    } else {
        completion(nil);
    }
}

- (URLAction *)urlActionForAnyStringSemanticHistory {
    if (self.semanticHistoryController.activatesOnAnyString) {
        DLog(@"Semantic history accepts any input. Doing a smart match.");
        // Just do smart selection and let Semantic History take it.
        VT100GridWindowedRange smartRange;
        SmartMatch *smartMatch = [self.extractor smartSelectionAt:self.coord
                                                        withRules:self.rules
                                                   actionRequired:NO
                                                            range:&smartRange
                                                 ignoringNewlines:!self.respectHardNewlines];
        if (!VT100GridCoordEquals(smartRange.coordRange.start,
                                  smartRange.coordRange.end)) {
            NSString *name = smartMatch.components[0];
            DLog(@"Good enough for me. name=%@", name);
            URLAction *action = [URLAction urlActionToOpenExistingFile:name];
            action.rawFilename = name;
            action.logicalRange = smartRange;
            action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];
            action.fullPath = name;
            action.workingDirectory = self.workingDirectory;
            return action;
        }
    }
    return nil;
}

- (NSString *)urlLikeCandidateStringWithLocatedPrefix:(iTermLocatedString *)locatedPrefix
                                         locatedSuffix:(iTermLocatedString *)locatedSuffix {
    if (!locatedPrefix || !locatedSuffix) {
        return nil;
    }
    NSString *joined = [locatedPrefix.string stringByAppendingString:locatedSuffix.string];
    int prefixChars = 0;
    NSString *possibleUrl = [joined substringIncludingOffset:[locatedPrefix.string length]
                                            fromCharacterSet:[NSCharacterSet urlCharacterSet]
                                        charsTakenFromPrefix:&prefixChars];
    NSRange rangeWithoutNearbyPunctuation = [possibleUrl rangeOfURLInString];
    if (rangeWithoutNearbyPunctuation.location == NSNotFound) {
        return nil;
    }
    rangeWithoutNearbyPunctuation = iTermURLRangeByTrimmingFullWidthBoundaryPunctuation(possibleUrl, rangeWithoutNearbyPunctuation);
    return [possibleUrl substringWithRange:rangeWithoutNearbyPunctuation];
}

- (URLAction *)urlActionForURLLikeWithLocatedPrefix:(iTermLocatedString *)locatedPrefix
                                      locatedSuffix:(iTermLocatedString *)locatedSuffix {
    if (!locatedPrefix || !locatedSuffix) {
        return nil;
    }
    self.locatedPrefix = locatedPrefix;
    self.locatedSuffix = locatedSuffix;
    NSString *joined = [self.locatedPrefix.string stringByAppendingString:self.locatedSuffix.string];
    DLog(@"Smart selection found nothing. Look for URL-like things in %@ around offset %d",
         joined, (int)[self.locatedPrefix.string length]);
    int prefixChars = 0;
    NSString *possibleUrl = [joined substringIncludingOffset:[self.locatedPrefix.string length]
                                            fromCharacterSet:[NSCharacterSet urlCharacterSet]
                                        charsTakenFromPrefix:&prefixChars];
    DLog(@"String of just permissible chars is <<%@>> with prefix length %d", possibleUrl, prefixChars);

    // Remove punctuation, parens, brackets, etc.
    NSRange rangeWithoutNearbyPunctuation = [possibleUrl rangeOfURLInString];
    if (rangeWithoutNearbyPunctuation.location == NSNotFound) {
        DLog(@"No URL found");
        return nil;
    }
    rangeWithoutNearbyPunctuation = iTermURLRangeByTrimmingFullWidthBoundaryPunctuation(possibleUrl, rangeWithoutNearbyPunctuation);
    prefixChars -= rangeWithoutNearbyPunctuation.location;
    DLog(@"Range excluding punctuation is %@. Adjust prefixChars down to %d", NSStringFromRange(rangeWithoutNearbyPunctuation), prefixChars);
    NSString *stringWithoutNearbyPunctuation = [possibleUrl substringWithRange:rangeWithoutNearbyPunctuation];
    DLog(@"String without nearby punctuation: %@", stringWithoutNearbyPunctuation);

    if ([iTermAdvancedSettingsModel conservativeURLGuessing]) {
        DLog(@"Using conservative URL guessing");
        if (![self stringLooksLikeURL:stringWithoutNearbyPunctuation]) {
            DLog(@"Doesn't look URL-like to me, abort");
            return nil;
        }

        NSString *schemeRegex = @"^[a-z]+://";
        // Hostname with two components
        NSString *hostnameRegex = @"(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)+([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])";
        NSString *portRegex = @"(:[1-9][0-9]{0,4})?";
        NSString *pathRegex = @"(/|$)";
        NSString *urlRegex = [NSString stringWithFormat:@"%@%@%@%@", schemeRegex, hostnameRegex, portRegex, pathRegex];
        if ([stringWithoutNearbyPunctuation rangeOfRegex:urlRegex].location != NSNotFound) {
            DLog(@"LGTM, using %@ with range %@ and prefix %d", stringWithoutNearbyPunctuation, NSStringFromRange(rangeWithoutNearbyPunctuation), prefixChars);
            return [self urlActionForString:stringWithoutNearbyPunctuation
                                      range:rangeWithoutNearbyPunctuation
                                prefixChars:prefixChars];
        }

        return nil;
    }

    DLog(@"Not using conservative URL guessing");

    const BOOL hasColon = ([stringWithoutNearbyPunctuation rangeOfString:@":"].location != NSNotFound);
    BOOL looksLikeURL;
    if (hasColon) {
        DLog(@"Has a colon, looks like a URL to me");
        // The test later on for whether an app exists to open the URL is sufficient.
        DLog(@"Contains a colon so it looks like a URL to me");
        looksLikeURL = YES;
    } else {
        // Only try to use HTTP if the string has something especially HTTP URL-like about it, such as
        // containing a slash. This helps reduce the number of random strings that are misinterpreted
        // as URLs.
        looksLikeURL = [self stringLooksLikeURL:[possibleUrl substringWithRange:rangeWithoutNearbyPunctuation]];

        if (looksLikeURL) {
            if (!self.workingDirectoryIsLocal && ![stringWithoutNearbyPunctuation containsString:@"/"]) {
                DLog(@"The working directory is not local and there's no slash in the filename or colon for a scheme, so this might be a file on a remote filesystem. Don't treat it as a URL.");
                return nil;
            }
            DLog(@"There's no colon but it seems like it could be an HTTP URL. Let's give that a try.");
            NSString *defaultScheme;
            if ([self stringIsSingleDomainWord:[self hostnameInSchemelessPossibleURL:stringWithoutNearbyPunctuation]]) {
                DLog(@"Use http because it's a single word");
                defaultScheme = @"http://";
            } else {
                defaultScheme = [[iTermAdvancedSettingsModel defaultURLScheme] stringByAppendingString:@"://"];
                DLog(@"Use default scheme of %@", defaultScheme);
            }
            stringWithoutNearbyPunctuation = [defaultScheme stringByAppendingString:stringWithoutNearbyPunctuation];
        } else {
            DLog(@"Doesn't look enough like a URL to guess that it's an HTTP URL");
        }
    }

    if (looksLikeURL) {
        if ([stringWithoutNearbyPunctuation rangeOfString:@"://"].location != NSNotFound) {
            NSURL *candidateURL = [NSURL URLWithUserSuppliedString:stringWithoutNearbyPunctuation];
            if (candidateURL.host.length > 0 && iTermStringIsASCIIOnly(candidateURL.host)) {
                NSString *trimmed = [stringWithoutNearbyPunctuation stringByTrimmingTrailingCharactersFromCharacterSet:iTermCJKURLBoundaryCharacterSet()];
                if (trimmed.length != stringWithoutNearbyPunctuation.length) {
                    rangeWithoutNearbyPunctuation.length -= (stringWithoutNearbyPunctuation.length - trimmed.length);
                    stringWithoutNearbyPunctuation = trimmed;
                }
            }
        }
        DLog(@"Looks like a URL. Return %@ with range %@ and prefix %d", stringWithoutNearbyPunctuation, NSStringFromRange(rangeWithoutNearbyPunctuation), prefixChars);
        // If the string contains non-ascii characters, percent escape them. URLs are limited to ASCII.
        return [self urlActionForString:stringWithoutNearbyPunctuation
                                  range:rangeWithoutNearbyPunctuation
                            prefixChars:prefixChars];
    }

    return nil;
}

- (URLAction *)urlActionForURLHitCandidate:(iTermURLHitCandidate *)candidate {
    if (!candidate.URLString.length ||
        [candidate.URLString rangeOfString:@"://"].location == NSNotFound) {
        return nil;
    }

    NSURL *url = [NSURL URLWithUserSuppliedString:candidate.URLString];
    if (!url || [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url] == nil) {
        return nil;
    }

    VT100GridWindowedRange range;
    range.coordRange.start = candidate.startCoord;
    range.coordRange.end = [self.extractor successorOfCoord:candidate.endCoord];
    range.columnWindow = self.extractor.logicalWindow;

    URLAction *action = [URLAction urlActionToOpenURL:candidate.URLString];
    action.logicalRange = range;
    action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];
    return action;
}

- (URLAction *)urlActionForURLLike {
    iTermLocatedString *primaryPrefix = [self locatedPrefixForURLLikeRespectingHardNewlines:self.respectHardNewlines];
    iTermLocatedString *primarySuffix = [self locatedSuffixForURLLikeRespectingHardNewlines:self.respectHardNewlines];
    iTermURLHitCandidate *primaryCandidate =
        [iTermURLHitCandidate candidateWithLocatedPrefix:primaryPrefix
                                           locatedSuffix:primarySuffix
                                allowHardNewlineRecovery:YES];
    URLAction *primaryAction = [self urlActionForURLHitCandidate:primaryCandidate];
    if (primaryAction) {
        return primaryAction;
    }

    iTermLocatedString *fallbackPrefix = [self locatedPrefixForURLLikeRespectingHardNewlines:!self.respectHardNewlines];
    iTermLocatedString *fallbackSuffix = [self locatedSuffixForURLLikeRespectingHardNewlines:!self.respectHardNewlines];
    iTermURLHitCandidate *fallbackCandidate =
        [iTermURLHitCandidate candidateWithLocatedPrefix:fallbackPrefix
                                           locatedSuffix:fallbackSuffix
                                allowHardNewlineRecovery:YES];
    URLAction *fallbackAction = [self urlActionForURLHitCandidate:fallbackCandidate];
    if (fallbackAction) {
        return fallbackAction;
    }

    URLAction *primaryGenericAction = [self urlActionForURLLikeWithLocatedPrefix:primaryPrefix
                                                                     locatedSuffix:primarySuffix];
    if (!primaryGenericAction) {
        return [self urlActionForURLLikeWithLocatedPrefix:fallbackPrefix
                                             locatedSuffix:fallbackSuffix];
    }

    NSString *recoveredCandidate = [self urlLikeCandidateStringWithLocatedPrefix:fallbackPrefix
                                                                   locatedSuffix:fallbackSuffix];
    if ([[self class] tideyShouldSuppressURLLikeCandidate:primaryGenericAction.string
                                        whenRecoveredForm:recoveredCandidate]) {
        return nil;
    }
    return primaryGenericAction;
}

- (NSString *)hostnameInSchemelessPossibleURL:(NSString *)url {
    const NSInteger index = [url rangeOfString:@"/"].location;
    if (index == NSNotFound) {
        return url;
    }
    return [url substringToIndex:index];
}

- (BOOL)stringIsSingleDomainWord:(NSString *)string {
    static NSCharacterSet *nonAlnum;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *lowercase = [NSCharacterSet characterSetWithRange:NSMakeRange('a', 26)];
        NSCharacterSet *uppercase = [NSCharacterSet characterSetWithRange:NSMakeRange('A', 26)];
        NSCharacterSet *digits = [NSCharacterSet characterSetWithRange:NSMakeRange('0', 10)];
        NSMutableCharacterSet *temp = [[NSMutableCharacterSet alloc] init];
        [temp formUnionWithCharacterSet:lowercase];
        [temp formUnionWithCharacterSet:uppercase];
        [temp formUnionWithCharacterSet:digits];
        [temp invert];
        nonAlnum = temp;
    });
    return (string.length > 0 &&
            !isdigit([string characterAtIndex:0]) &&
            [string rangeOfCharacterFromSet:nonAlnum].location == NSNotFound);
}

- (URLAction *)urlActionForString:(NSString *)string
                            range:(NSRange)stringRange
                      prefixChars:(int)prefixChars {
    DLog(@"urlActionForString:%@ range:%@ prefixChars:%@", string, NSStringFromRange(stringRange), @(prefixChars));
    NSURL *url = [NSURL URLWithUserSuppliedString:string];
    DLog(@"See if I can open %@, aka %@", string, url);
    // If something can handle the scheme then we're all set.
    BOOL openable = (url &&
                     [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url] != nil &&
                     prefixChars >= 0 &&
                     prefixChars <= self.locatedPrefix.string.length);

    if (openable) {
        DLog(@"%@ is openable", url);
        VT100GridWindowedRange range;
        NSInteger j = self.locatedPrefix.string.length - prefixChars;
        DLog(@"j=%@-%@=%@", @(self.locatedPrefix.string.length), @(prefixChars), @(j));
        if (j >= 0 && j < self.locatedPrefix.gridCoords.count) {
            DLog(@"j=%@ < self.locatedPrefix.gridCoords.count=%@", @(j), @(self.locatedPrefix.gridCoords.count));
            range.coordRange.start = [self.locatedPrefix.gridCoords coordAt:j];
            DLog(@"range.coordRange.start=%@", VT100GridCoordDescription(range.coordRange.start));
        } else if (j == self.locatedPrefix.gridCoords.count && j > 0) {
            DLog(@"j=%@ == self.locatedPrefix.gridCoords.count && j > 0", @(j));
            range.coordRange.start = [self.extractor successorOfCoord:[self.locatedPrefix.gridCoords coordAt:j - 1]];
            DLog(@"range.coordRange.start=%@ which is successor of last prefix coord %@",
                 VT100GridCoordDescription(range.coordRange.start),
                 VT100GridCoordDescription([self.locatedPrefix.gridCoords coordAt:j - 1]));
        } else {
            DLog(@"prefixCoordscount=%@ j=%@", @(self.locatedPrefix.gridCoords.count), @(j));
            return nil;
        }
        NSInteger i = stringRange.length - prefixChars;
        DLog(@"i=%@-%@=%@", @(stringRange.length), @(prefixChars), @(i));
        if (i >= 0 && i < self.locatedSuffix.gridCoords.count) {
            DLog(@"i < suffixCoords.count=%@", @(self.locatedSuffix.gridCoords.count));
            range.coordRange.end = [self.locatedSuffix.gridCoords coordAt:i];
            DLog(@"range.coordRange.end=%@", VT100GridCoordDescription([self.locatedSuffix.gridCoords coordAt:i]));
        } else if (i > 0 && i == self.locatedSuffix.gridCoords.count) {
            DLog(@"i == suffixCoords.count");
            range.coordRange.end = [self.extractor successorOfCoord:[self.locatedSuffix.gridCoords coordAt:i - 1]];
            DLog(@"range.coordRange.end=%@, successor of %@",
                 VT100GridCoordDescription(range.coordRange.end),
                 VT100GridCoordDescription([self.locatedSuffix.gridCoords coordAt:i - 1]));
        } else {
            DLog(@"i=%@ suffixcoords.count=%@", @(i), @(self.locatedSuffix.gridCoords.count));
            return nil;
        }
        range.columnWindow = self.extractor.logicalWindow;
        URLAction *action = [URLAction urlActionToOpenURL:string];
        action.logicalRange = range;
        action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];
        return action;
    } else {
        DLog(@"%@ is not openable (couldn't convert it to a URL [%@] or no scheme handler",
             string, url);
    }
    return nil;
}

- (URLAction *)urlActionWithSecureCopy {
    DLog(@"Let's see if I can secure copy it. Do a smart selection");
    VT100GridWindowedRange smartRange;
    SmartMatch *smartMatch = [self.extractor smartSelectionAt:self.coord
                                                   withRules:self.rules
                                              actionRequired:NO
                                                       range:&smartRange
                                            ignoringNewlines:!self.respectHardNewlines];
    if (smartMatch) {
        DLog(@"Found a smart match");
        SCPPath *scpPath = self.pathFactory([smartMatch.components firstObject], self.coord.y);
        if (scpPath) {
            DLog(@"was able to cobble together a SCPPath of %@", scpPath);
            URLAction *action = [URLAction urlActionToSecureCopyFile:scpPath];
            action.logicalRange = smartRange;
            action.visualRange = [self.extractor visualWindowedRangeForLogical:action.logicalRange];
            return action;
        }
    }

    return nil;
}

#pragma mark - Helpers

- (BOOL)stringLooksLikeURL:(NSString*)s {
    // This is much harder than it sounds.
    // [NSURL URLWithString] is supposed to do this, but it doesn't accept IDN-encoded domains like
    // http://例子.测试
    // Just about any word can be a URL in the local search path. The code that calls this prefers false
    // positives, so just make sure it's not empty and doesn't have illegal characters.
    if ([s rangeOfCharacterFromSet:[[NSCharacterSet urlCharacterSet] invertedSet]].location != NSNotFound) {
        return NO;
    }
    if ([s length] == 0) {
        return NO;
    }

    NSRange slashRange = [s rangeOfString:@"/"];
    if (slashRange.location == 0) {
        // URLs never start with a slash
        return NO;
    }
    if (slashRange.length > 0) {
        if ([s rangeOfString:@"://"].location == NSNotFound) {
            static NSCharacterSet *cjkCharacterSet;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                NSMutableCharacterSet *set = [[NSMutableCharacterSet alloc] init];
                [set addCharactersInRange:NSMakeRange(0x2E80, 0x9FFF - 0x2E80 + 1)];
                [set addCharactersInRange:NSMakeRange(0xF900, 0xFAFF - 0xF900 + 1)];
                [set addCharactersInRange:NSMakeRange(0xFF00, 0xFFEF - 0xFF00 + 1)];
                cjkCharacterSet = [set copy];
            });
            NSString *prefix = [s substringToIndex:slashRange.location];
            if ([prefix rangeOfCharacterFromSet:cjkCharacterSet].location != NSNotFound) {
                return NO;
            }
            if (iTermURLActionFactoryStringIsSourceLikePath(s)) {
                return NO;
            }
        }
        // Contains a slash but does not start with it.
        return YES;
    }
    if ([iTermAdvancedSettingsModel requireSlashInURLGuess] && slashRange.location == NSNotFound) {
        return NO;
    }

    NSString *ipRegex = @"^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$";
    if ([s rangeOfRegex:ipRegex].location != NSNotFound) {
        // IP addresses as dotted quad
        return YES;
    }

    NSString *hostnameRegex = @"^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)+([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\\-]*[A-Za-z0-9])$";
    if ([s rangeOfRegex:hostnameRegex].location != NSNotFound) {
        // A hostname with at least two components.
        return YES;
    }

    return NO;
}

@end
