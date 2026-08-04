//
//  TideyMetalRedrawWatchdogTests.swift
//  ModernTests
//

import XCTest
@testable import iTerm2SharedARC

@MainActor
final class TideyMetalRedrawWatchdogTests: XCTestCase {
    func testPeriodicRedrawSkippedWhenMiniaturized() {
        XCTAssertTrue(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: false,
                                                                 alphaValue: 1,
                                                                 width: 100,
                                                                 height: 100,
                                                                 hasWindow: true,
                                                                 windowIsMiniaturized: true))
    }

    func testPeriodicRedrawProceedsWhenVisibleAndNotMiniaturized() {
        XCTAssertFalse(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: false,
                                                                  alphaValue: 1,
                                                                  width: 100,
                                                                  height: 100,
                                                                  hasWindow: true,
                                                                  windowIsMiniaturized: false))
    }

    func testPeriodicRedrawStillSkipsExistingInvisibleStates() {
        XCTAssertTrue(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: true,
                                                                 alphaValue: 1,
                                                                 width: 100,
                                                                 height: 100,
                                                                 hasWindow: true,
                                                                 windowIsMiniaturized: false))
        XCTAssertTrue(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: false,
                                                                 alphaValue: 0,
                                                                 width: 100,
                                                                 height: 100,
                                                                 hasWindow: true,
                                                                 windowIsMiniaturized: false))
        XCTAssertTrue(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: false,
                                                                 alphaValue: 1,
                                                                 width: 0,
                                                                 height: 100,
                                                                 hasWindow: true,
                                                                 windowIsMiniaturized: false))
        XCTAssertTrue(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: false,
                                                                 alphaValue: 1,
                                                                 width: 100,
                                                                 height: 0,
                                                                 hasWindow: true,
                                                                 windowIsMiniaturized: false))
        XCTAssertTrue(iTermMTKView.tideyShouldSkipPeriodicRedraw(isHidden: false,
                                                                 alphaValue: 1,
                                                                 width: 100,
                                                                 height: 100,
                                                                 hasWindow: false,
                                                                 windowIsMiniaturized: false))
    }
}
