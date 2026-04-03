//
//  TideyThemeManager.h
//  iTerm2SharedARC
//

#import <Cocoa/Cocoa.h>

#import "iTermPreferences.h"
#import "TideyTheme.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const TideyThemeDidChangeNotification;

@interface TideyThemeManager : NSObject

@property (nonatomic, readonly) TideyTheme *currentTheme;

+ (instancetype)shared;
+ (TideyTheme *)themeForStyle:(TideyThemeStyle)style;
- (void)setTheme:(TideyTheme *)theme;

@end

NS_ASSUME_NONNULL_END
