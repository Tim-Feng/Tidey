//
//  TideySidebarStatusRefreshPolicyTests.m
//  ModernTests
//

#import <XCTest/XCTest.h>

#import "iTermRootTerminalView.h"

@interface TideySidebarStatusRefreshPolicyTests : XCTestCase
@end

@implementation TideySidebarStatusRefreshPolicyTests

- (void)testInvalidRefreshInputsUseFullReload {
    XCTAssertFalse([iTermRootTerminalView tideyShouldTargetSidebarStatusRefreshForWorkspaceIdentifier:nil
                                                                                         resolvedRow:0
                                                                                    tableColumnCount:1]);
    XCTAssertFalse([iTermRootTerminalView tideyShouldTargetSidebarStatusRefreshForWorkspaceIdentifier:@""
                                                                                         resolvedRow:0
                                                                                    tableColumnCount:1]);
    XCTAssertFalse([iTermRootTerminalView tideyShouldTargetSidebarStatusRefreshForWorkspaceIdentifier:@"*"
                                                                                         resolvedRow:0
                                                                                    tableColumnCount:1]);
    XCTAssertFalse([iTermRootTerminalView tideyShouldTargetSidebarStatusRefreshForWorkspaceIdentifier:@"workspace-1"
                                                                                         resolvedRow:NSNotFound
                                                                                    tableColumnCount:1]);
    XCTAssertFalse([iTermRootTerminalView tideyShouldTargetSidebarStatusRefreshForWorkspaceIdentifier:@"workspace-1"
                                                                                         resolvedRow:0
                                                                                    tableColumnCount:0]);
}

@end
