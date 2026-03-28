#import <XCTest/XCTest.h>

#import "iTermLayoutCalculator.h"

static inline void AssertCGRectEqual(CGRect actual, CGRect expected) {
    XCTAssertTrue(CGRectEqualToRect(actual, expected),
                  @"Expected %@ but got %@",
                  NSStringFromRect(NSRectFromCGRect(expected)),
                  NSStringFromRect(NSRectFromCGRect(actual)));
}

@interface iTermLayoutCalculatorTideyTests : XCTestCase
@end

@implementation iTermLayoutCalculatorTideyTests

- (iTermLayoutOutputs)sampleOutputs {
    iTermLayoutOutputs outputs = {0};
    outputs.tabViewFrame = CGRectMake(0, 22, 800, 578);
    outputs.statusBarFrame = CGRectMake(0, 0, 800, 22);
    outputs.toolbeltFrame = CGRectMake(800, 0, 240, 600);
    outputs.tabBarFrame = CGRectMake(0, 600, 800, 24);
    return outputs;
}

- (void)testApplyingSidebarWidthShiftsContentFramesRight {
    iTermLayoutOutputs outputs = [self sampleOutputs];
    outputs = [iTermLayoutCalculator layoutOutputs:outputs
                       byApplyingTideySidebarWidth:220
                                       editorWidth:0
                                   terminalVisible:YES];

    AssertCGRectEqual(outputs.tabViewFrame, CGRectMake(220, 22, 800, 578));
    AssertCGRectEqual(outputs.statusBarFrame, CGRectMake(220, 0, 800, 22));
    AssertCGRectEqual(outputs.toolbeltFrame, CGRectMake(1020, 0, 240, 600));
    AssertCGRectEqual(outputs.tabBarFrame, CGRectMake(220, 600, 800, 24));
}

- (void)testApplyingEditorWidthShrinksTerminalFacingFrames {
    iTermLayoutOutputs outputs = [self sampleOutputs];
    outputs = [iTermLayoutCalculator layoutOutputs:outputs
                       byApplyingTideySidebarWidth:0
                                       editorWidth:280
                                   terminalVisible:YES];

    AssertCGRectEqual(outputs.tabViewFrame, CGRectMake(0, 22, 520, 578));
    AssertCGRectEqual(outputs.statusBarFrame, CGRectMake(0, 0, 520, 22));
    AssertCGRectEqual(outputs.toolbeltFrame, CGRectMake(800, 0, 240, 600));
    AssertCGRectEqual(outputs.tabBarFrame, CGRectMake(0, 600, 520, 24));
}

- (void)testApplyingEditorWidthClampsTerminalFramesAtZero {
    iTermLayoutOutputs outputs = [self sampleOutputs];
    outputs = [iTermLayoutCalculator layoutOutputs:outputs
                       byApplyingTideySidebarWidth:100
                                       editorWidth:1000
                                   terminalVisible:YES];

    AssertCGRectEqual(outputs.tabViewFrame, CGRectMake(100, 22, 0, 578));
    AssertCGRectEqual(outputs.statusBarFrame, CGRectMake(100, 0, 0, 22));
    AssertCGRectEqual(outputs.toolbeltFrame, CGRectMake(900, 0, 240, 600));
    AssertCGRectEqual(outputs.tabBarFrame, CGRectMake(100, 600, 0, 24));
}

- (void)testHiddenTerminalZeroesTerminalFramesButKeepsToolbeltFrame {
    iTermLayoutOutputs outputs = [self sampleOutputs];
    outputs = [iTermLayoutCalculator layoutOutputs:outputs
                       byApplyingTideySidebarWidth:180
                                       editorWidth:320
                                   terminalVisible:NO];

    AssertCGRectEqual(outputs.tabViewFrame, CGRectMake(180, 22, 0, 578));
    AssertCGRectEqual(outputs.statusBarFrame, CGRectMake(180, 0, 0, 22));
    AssertCGRectEqual(outputs.toolbeltFrame, CGRectMake(980, 0, 240, 600));
    AssertCGRectEqual(outputs.tabBarFrame, CGRectMake(180, 600, 0, 24));
}

@end
