import AppKit
import XCTest
@testable import iTerm2SharedARC

final class TideyInterfaceThemeTests: XCTestCase {
    func testApplicationControllerUsesTideySuiteAwareDefaultsStore() {
        XCTAssertTrue(TideyInterfaceThemeController.applicationUserDefaults() ===
                      iTermUserDefaults.userDefaults())
    }

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
        assertColor(tokens.sidebarSelectedPrimaryTextColor, white: 1.0)
        assertColor(tokens.sidebarSelectedIdleColor, white: 1.0, alpha: 0.8)
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

    func testStoredThemeParsingAcceptsWarmAndFallsBackToClassic() {
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier(nil), "classic")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("classic"), "classic")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("warm"), "warm")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("tech"), "classic")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("unexpected"), "classic")
    }

    func testWarmTokensMatchFrozenDesignValues() {
        let tokens = TideyInterfaceThemeTokens.warm

        assertColor(tokens.sidebarBackgroundColor, hex: 0x171615)
        assertColor(tokens.sidebarSelectionColor, hex: 0x2F2C28)
        assertColor(tokens.sidebarSelectionBorderColor,
                    red: 240.0 / 255.0,
                    green: 230.0 / 255.0,
                    blue: 210.0 / 255.0,
                    alpha: 0.16)
        assertColor(tokens.sidebarPrimaryTextColor, hex: 0xEAE4D4)
        assertColor(tokens.sidebarSelectedPrimaryTextColor, hex: 0xF3EEDF)
        assertColor(tokens.sidebarSecondaryTextColor, hex: 0xA89F8D)
        assertColor(tokens.sidebarSelectedSecondaryTextColor, hex: 0xC6BEAC)
        assertColor(tokens.sidebarIdleColor, hex: 0x6F6A60)
        assertColor(tokens.sidebarSelectedIdleColor, hex: 0x8A8478)
        assertColor(tokens.sidebarRunningColor, hex: 0x7FB4A3)
        assertColor(tokens.sidebarUnreadColor, hex: 0xD19A66)
        assertColor(tokens.rightPanelBackgroundColor, hex: 0x151413)
        assertColor(tokens.rightPanelTabStripBackgroundColor, hex: 0x191817)
        assertColor(tokens.rightPanelTabSelectionColor, hex: 0x232120)
        assertColor(tokens.terminalSurroundColor, hex: 0x100F0E)
        XCTAssertTrue(tokens.usesRaisedSidebarSelection)
        XCTAssertTrue(tokens.usesRaisedRightPanelTabs)
        XCTAssertEqual(tokens.sidebarSelectionCornerRadius, 8)
        XCTAssertEqual(tokens.rightPanelTabCornerRadius, 8)
    }

    func testControllerPersistsEffectiveThemeAndNotifiesOnlyOnChange() {
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

        controller.currentThemeIdentifier = "warm"

        XCTAssertEqual(controller.currentThemeIdentifier, "warm")
        XCTAssertEqual(defaults.string(forKey: TideyInterfaceThemeController.defaultsKey), "warm")
        XCTAssertTrue(controller.currentTokens === TideyInterfaceThemeTokens.warm)
        XCTAssertEqual(notifications, 1)

        controller.currentThemeIdentifier = "warm"
        XCTAssertEqual(notifications, 1)

        controller.currentThemeIdentifier = "tech"
        XCTAssertEqual(controller.currentThemeIdentifier, "classic")
        XCTAssertEqual(defaults.string(forKey: TideyInterfaceThemeController.defaultsKey), "classic")
        XCTAssertTrue(controller.currentTokens === TideyInterfaceThemeTokens.classic)
        XCTAssertEqual(notifications, 2)
    }

    func testThemePickerExposesOnlySupportedThemesInStableOrder() {
        XCTAssertEqual(TideyInterfaceThemeController.supportedThemeIdentifiers,
                       ["classic", "warm"])
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "classic"),
                       "Classic")
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "warm"),
                       "Warm")
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "tech"),
                       "Classic")
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
                             hex: Int,
                             alpha: CGFloat = 1,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        assertColor(color,
                    red: CGFloat((hex >> 16) & 0xff) / 255,
                    green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255,
                    alpha: alpha,
                    file: file,
                    line: line)
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
