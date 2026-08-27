import AppKit
import XCTest
@testable import iTerm2SharedARC

final class TideyInterfaceThemeTests: XCTestCase {
    func testClassicTokensPreserveExistingChromeColors() {
        let tokens = TideyInterfaceThemeTokens.classic

        assertColor(tokens.sidebarBackgroundColor, red: 0.11, green: 0.12, blue: 0.15)
        assertColor(tokens.rightPanelBackgroundColor, red: 0.10, green: 0.11, blue: 0.14)
        assertColor(tokens.rightPanelTabStripBackgroundColor, red: 0.09, green: 0.10, blue: 0.13)
        assertColor(tokens.rightPanelFileTreeBackgroundColor, red: 0.12, green: 0.13, blue: 0.17)
        assertColor(tokens.rightPanelSplitDividerColor, white: 0.24)
        assertColor(tokens.rightPanelTabHoverColor, white: 1.0, alpha: 0.06)
        assertColor(tokens.rightPanelTabSeparatorColor, white: 0.25)
        assertColor(tokens.rightPanelGroupExpandedFillColor,
                    red: 1.0,
                    green: 177.0 / 255.0,
                    blue: 27.0 / 255.0,
                    alpha: 0.20)
        assertColor(tokens.rightPanelGroupCollapsedFillColor,
                    red: 1.0,
                    green: 177.0 / 255.0,
                    blue: 27.0 / 255.0,
                    alpha: 0.10)
        assertColor(tokens.rightPanelGroupExpandedTextColor,
                    red: 1.0,
                    green: 177.0 / 255.0,
                    blue: 27.0 / 255.0)
        assertColor(tokens.rightPanelGroupCollapsedTextColor,
                    red: 209.0 / 255.0,
                    green: 152.0 / 255.0,
                    blue: 38.0 / 255.0)
        XCTAssertFalse(tokens.usesRaisedSidebarSelection)
        XCTAssertFalse(tokens.usesRaisedRightPanelTabs)
    }

    func testControllerReapplyPostsOneNotificationWithoutChangingClassicTheme() {
        let suiteName = "TideyInterfaceThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = TideyInterfaceThemeController(userDefaults: defaults)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: TideyInterfaceThemeController.didChangeNotification,
            object: controller,
            queue: nil
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.reapplyCurrentTheme()

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(controller.currentThemeIdentifier, "classic")
        XCTAssertTrue(controller.currentTokens === TideyInterfaceThemeTokens.classic)
    }

    private func assertColor(_ color: NSColor,
                             red: CGFloat,
                             green: CGFloat,
                             blue: CGFloat,
                             alpha: CGFloat = 1,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let converted = color.usingColorSpace(.sRGB) else {
            return XCTFail("Color is not convertible to sRGB", file: file, line: line)
        }
        XCTAssertEqual(converted.redComponent, red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.greenComponent, green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.blueComponent, blue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.alphaComponent, alpha, accuracy: 0.001, file: file, line: line)
    }

    private func assertColor(_ color: NSColor,
                             white: CGFloat,
                             alpha: CGFloat = 1,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        assertColor(color,
                    red: white,
                    green: white,
                    blue: white,
                    alpha: alpha,
                    file: file,
                    line: line)
    }
}
