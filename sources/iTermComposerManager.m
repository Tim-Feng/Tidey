//
//  iTermComposerManager.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/31/20.
//

#import "iTermComposerManager.h"

#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermStatusBarComposerComponent.h"
#import "iTermStatusBarViewController.h"
#import "NSObject+iTerm.h"
#import "NSView+iTerm.h"

@interface iTermComposerManager()<iTermStatusBarComposerComponentDelegate>
@end

@implementation iTermComposerManager {
    iTermStatusBarComposerComponent *_component;
    iTermStatusBarViewController *_statusBarViewController;
    NSString *_saved;
    BOOL _preserveSaved;
}

- (void)setCommand:(NSString *)command {
    _saved = [command copy];
}

// Puts the command in the existing composer. Doesn't open the dropdown if a status bar composer is present.
- (void)placeCommandInComposer:(NSString *)command {
    [self setCommand:command];
    iTermStatusBarComposerComponent *component = [self statusBarComponentIfVisible];
    [component setStringValue:command];
}

- (iTermStatusBarComposerComponent *)statusBarComponentIfVisible {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    NSString *identifier = [iTermStatusBarComposerComponent statusBarComponentIdentifier];
    return [statusBarViewController visibleComponentWithIdentifier:identifier];
}

- (iTermStatusBarComposerComponent *)statusBarComponent {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    NSString *identifier = [iTermStatusBarComposerComponent statusBarComponentIdentifier];
    return [statusBarViewController componentWithIdentifier:identifier];
}

- (void)showCommandInLargeComposer:(NSString *)command {
    [self setCommand:command];
    [self toggle];
}

- (void)showOrAppendToDropdownWithString:(NSString *)string {
    _saved = [string copy];
}

- (BOOL)dropDownComposerIsFirstResponder {
    return NO;
}

- (void)makeDropDownComposerFirstResponder {
}

- (iTermStatusBarComposerComponent *)currentComponent {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    if (statusBarViewController) {
        iTermStatusBarComposerComponent *component = [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]];
        return component;
    }
    return nil;
}

- (void)setStringValue:(NSString *)command {
    _saved = [command copy];
    iTermStatusBarComposerComponent *component = [self currentComponent];
    component.stringValue = command;
}

- (void)showWithCommand:(NSString *)command {
    [self setStringValue:command];
    iTermStatusBarComposerComponent *component = [self currentComponent];
    if (component) {
        // Put into already-visible status bar component.
        [component makeFirstResponder];
        [component deselect];
        return;
    }
    // Nothing is currently visible. Reveal as usual.
    [self toggle];
}

- (BOOL)usingStatusBar {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    return (statusBarViewController && [self shouldRevealStatusBarComposerInViewController:statusBarViewController]) ;
}

- (void)toggle {
    if ([self usingStatusBar]) {
        iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
        [self showComposerInStatusBar:statusBarViewController];
    }
}

- (void)revealMakingFirstResponder:(BOOL)becomeFirstResponder {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    if (statusBarViewController && [self shouldRevealStatusBarComposerInViewController:statusBarViewController]) {
        [self showComposerInStatusBar:statusBarViewController];
    }
}

- (BOOL)shouldRevealStatusBarComposerInViewController:(iTermStatusBarViewController *)statusBarViewController {
    if ([iTermAdvancedSettingsModel alwaysUseStatusBarComposer]) {
        return YES;
    }
    return [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]] != nil;
}

- (void)revealMinimal {
    iTermStatusBarViewController *statusBarViewController = [self.delegate composerManagerStatusBarViewController:self];
    if (statusBarViewController) {
        iTermStatusBarComposerComponent *component = [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]];
        if (component) {
            [component makeFirstResponder];
        }
    }
}

- (void)showComposerInStatusBar:(iTermStatusBarViewController *)statusBarViewController {
    iTermStatusBarComposerComponent *component;
    component = [statusBarViewController visibleComponentWithIdentifier:[iTermStatusBarComposerComponent statusBarComponentIdentifier]];
    if (component) {
        [component makeFirstResponder];
        return;
    }
    component = [iTermStatusBarComposerComponent castFrom:_statusBarViewController.temporaryRightComponent];
    if (component && component == _component) {
        [component makeFirstResponder];
        return;
    }
    NSDictionary *knobs = @{ iTermStatusBarPriorityKey: @(INFINITY) };
    NSDictionary *configuration = @{ iTermStatusBarComponentConfigurationKeyKnobValues: knobs};
    iTermVariableScope *scope = [self.delegate composerManagerScope:self];
    component = [[iTermStatusBarComposerComponent alloc] initWithConfiguration:configuration
                                                                         scope:scope];
    _statusBarViewController = statusBarViewController;
    _statusBarViewController.temporaryRightComponent = component;
    _component = component;
    _component.stringValue = _saved ?: @"";
    component.composerDelegate = self;
    [component makeFirstResponder];
}

- (BOOL)dismiss {
    return [self dismissAnimated:NO];
}

- (BOOL)dismissAnimated:(BOOL)animated {
    DLog(@"dismissAnimated. isAutoComposer <- NO");
    self.isAutoComposer = NO;

    if (!_dropDownComposerViewIsVisible) {
        DLog(@"dismissAnimated: returning because dropdown not visible");
        return NO;
    }
    _dropDownComposerViewIsVisible = NO;
    [self.delegate composerManagerWillDismissMinimalView:self];
    [self.delegate composerManagerDidDismissMinimalView:self];
    return YES;
}

- (void)layout {
}

- (BOOL)isEmpty {
    DLog(@"isEmpty status bar stringvalue=%@", _component.stringValue);
    return _component.stringValue.length == 0;
}

- (NSString *)contents {
    return _component.stringValue;
}

- (NSString *)statusBarComposerContents {
    return [[self statusBarComponent] stringValue];
}

#pragma mark - iTermStatusBarComposerComponentDelegate

- (void)statusBarComposerComponentDidEndEditing:(iTermStatusBarComposerComponent *)component {
    if (_statusBarViewController.temporaryRightComponent == _component &&
        component == _component) {
        _saved = _component.stringValue;
        _statusBarViewController.temporaryRightComponent = nil;
        _component = nil;
        [self.delegate composerManagerDidRemoveTemporaryStatusBarComponent:self];
    }
}

- (void)updateFrame {
}

- (CGFloat)desiredHeight {
    return 0;
}

- (NSRect)dropDownFrame {
    return NSZeroRect;
}

- (void)setIsSeparatorVisible:(BOOL)isSeparatorVisible {
}

- (BOOL)isSeparatorVisible {
    return NO;
}

- (void)setSeparatorColor:(NSColor *)separatorColor {
}

- (NSColor *)separatorColor {
    return nil;
}

- (void)updateFont {
}

- (void)setPrefix:(NSMutableAttributedString *)prefix userData:(id)userData {
    self.haveShellProvidedText = NO;
    _prefixUserData = userData;
}

- (void)reset {
    DLog(@"Reset composer from\n%@", [NSThread callStackSymbols]);
    _saved = nil;
    _prefixUserData = nil;
}

- (void)clearStatusBar {
    [[self statusBarComponent] setStringValue:@""];
}

- (void)setPreferredOffsetFromTop:(CGFloat)offset {
}

- (void)insertText:(NSString *)string {
    [_component insertText:string];
    DLog(@"Appending to status bar composer");
}

- (void)deleteLastCharacter {
    // Not implemented for status bar, but it's not a bad idea to add later.
}

- (void)setTemporarilyHidden:(BOOL)temporarilyHidden {
    _temporarilyHidden = temporarilyHidden;
}

- (NSRect)cursorFrameInScreenCoordinates {
    return _component.cursorFrameInScreenCoordinates;
}

- (void)paste:(id)sender {
}

@end
