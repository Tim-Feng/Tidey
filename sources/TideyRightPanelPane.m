#import "TideyRightPanelPane.h"

@implementation TideyRightPanelPane

- (instancetype)init {
    self = [super init];
    if (self) {
        _tabs = [[NSMutableArray alloc] init];
        _selectedTabIndex = -1;
        _expandedTabKind = 0;
        _editorGroupExpanded = YES;
        _browserGroupExpanded = NO;
        _editorReady = NO;
        _editorShellLoaded = NO;
        _tabStripScrollOffset = 0;
        _tabStripContentWidth = 0;
    }
    return self;
}

@end
