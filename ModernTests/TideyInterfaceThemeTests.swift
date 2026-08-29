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
        XCTAssertEqual(tokens.paneBoundaryColor, .clear)
        XCTAssertEqual(tokens.paneResizerPullBarColor, .clear)
        XCTAssertEqual(tokens.tabOutlineColor, .clear)
        XCTAssertEqual(tokens.tabSelectedOutlineColor, .clear)
        assertColor(tokens.fileTreeTextColor, white: 0.92)
        assertColor(tokens.fileTreeIconColor, white: 0.78)
        XCTAssertEqual(tokens.fileTreeSelectionColor, .clear)
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

        assertColor(tokens.sidebarBackgroundColor, hex: 0x151413)
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
        assertColor(tokens.rightPanelTabStripBackgroundColor, hex: 0x151413)
        assertColor(tokens.rightPanelTabSelectionColor, hex: 0x232120)
        assertColor(tokens.terminalSurroundColor, hex: 0x151413)
        assertColor(tokens.paneBoundaryColor,
                    red: 240.0 / 255.0,
                    green: 230.0 / 255.0,
                    blue: 210.0 / 255.0,
                    alpha: 0.12)
        assertColor(tokens.fileTreeTextColor, hex: 0xEAE4D4)
        assertColor(tokens.fileTreeIconColor, hex: 0xA89F8D)
        assertColor(tokens.fileTreeSelectionColor, hex: 0x2F2C28)
        assertColor(tokens.paneResizerPullBarColor,
                    red: 240.0 / 255.0,
                    green: 230.0 / 255.0,
                    blue: 210.0 / 255.0,
                    alpha: 0.06)
        assertColor(tokens.tabOutlineColor,
                    red: 240.0 / 255.0,
                    green: 230.0 / 255.0,
                    blue: 210.0 / 255.0,
                    alpha: 0.08)
        // Focused tab outline shares the workspace focus card edge color.
        XCTAssertEqual(tokens.tabSelectedOutlineColor, tokens.sidebarSelectionBorderColor)
        XCTAssertTrue(tokens.usesRaisedSidebarSelection)
        // Editor tabs reuse the production flat-tab component: no raised card,
        // no corner radius, and the selection indicator line carries seaglass.
        XCTAssertFalse(tokens.usesRaisedRightPanelTabs)
        XCTAssertEqual(tokens.sidebarSelectionCornerRadius, 8)
        XCTAssertEqual(tokens.rightPanelTabCornerRadius, 0)
        assertColor(tokens.rightPanelTabSelectionIndicatorColor, hex: 0x7AA89F)
        XCTAssertEqual(tokens.rightPanelTabSelectionIndicatorColor,
                       TideyTerminalPalettePolicy.terminalTabUnderlineColor(warmEnabled: true))
    }

    func testPaperTabPolicyIsSharedByTerminalAndEditorTabs() {
        XCTAssertEqual(TideyPaperTabPolicy.outlineWidth, 1)
        XCTAssertEqual(TideyPaperTabPolicy.topCornerRadius, 4)
        XCTAssertEqual(TideyPaperTabPolicy.unselectedTopInset, 2)
        XCTAssertEqual(TideyPaperTabPolicy.selectionIndicatorHeight, 2)
        XCTAssertEqual(TideyPaperTabPolicy.pullBarWidth, 2)
        XCTAssertEqual(TideyPaperTabPolicy.pullBarLength, 34)

        let bounds = NSRect(x: 10, y: 0, width: 120, height: 30)
        // Selected tab: full height, in front, open at the bottom.
        XCTAssertEqual(TideyPaperTabPolicy.outlineRect(forTabBounds: bounds, selected: true), bounds)
        // Unselected tab: set back by the top inset (flipped coordinates).
        XCTAssertEqual(TideyPaperTabPolicy.outlineRect(forTabBounds: bounds, selected: false),
                       NSRect(x: 10, y: 2, width: 120, height: 28))

        let path = TideyPaperTabPolicy.outlinePath(for: bounds)
        XCTAssertEqual(path.lineWidth, 1)
        XCTAssertEqual(path.currentPoint, NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        XCTAssertFalse(path.isEmpty)

        // Terminal tab bar receives the same outline color; Classic gets nil.
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabOutlineColor(warmEnabled: false))
        XCTAssertEqual(TideyTerminalPalettePolicy.terminalTabOutlineColor(warmEnabled: true),
                       TideyInterfaceThemeTokens.warm.tabOutlineColor)
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabSelectedOutlineColor(warmEnabled: false))
        XCTAssertEqual(TideyTerminalPalettePolicy.terminalTabSelectedOutlineColor(warmEnabled: true),
                       TideyInterfaceThemeTokens.warm.sidebarSelectionBorderColor)
    }

    func testEditorCanvasPolicyKeepsClassicMonacoAndJoinsWarmBaseSurface() {
        XCTAssertEqual(TideyEditorCanvasPolicy.monacoThemeName(warmEnabled: false), "vs-dark")
        XCTAssertEqual(TideyEditorCanvasPolicy.pageBackgroundHex(warmEnabled: false), "#16181d")
        XCTAssertEqual(TideyEditorCanvasPolicy.themeDefinitionScript(warmEnabled: false), "")

        XCTAssertEqual(TideyEditorCanvasPolicy.monacoThemeName(warmEnabled: true), "tidey-warm")
        XCTAssertEqual(TideyEditorCanvasPolicy.pageBackgroundHex(warmEnabled: true), "#151413")
        let script = TideyEditorCanvasPolicy.themeDefinitionScript(warmEnabled: true)
        XCTAssertTrue(script.hasPrefix("monaco.editor.defineTheme('tidey-warm',"))
        XCTAssertTrue(script.contains("\"base\":\"vs-dark\""))
        XCTAssertTrue(script.contains("\"editor.background\":\"#151413\""))
        XCTAssertTrue(script.contains("\"editor.foreground\":\"#eae4d4\""))
        XCTAssertTrue(script.contains("\"editorCursor.foreground\":\"#7fb4a3\""))
        XCTAssertTrue(script.contains("\"editor.selectionBackground\":\"#2f2c28\""))
        XCTAssertEqual(TideyEditorCanvasPolicy.hexString(for: TideyInterfaceThemeTokens.warm.rightPanelBackgroundColor),
                       "#151413")
    }

    func testWarmBaseSurfacesShareOneColorAndBoundariesComeFromSeparators() {
        let tokens = TideyInterfaceThemeTokens.warm
        let base = tokens.rightPanelBackgroundColor
        // Tim's constraint: no base-surface color difference between the workspace
        // column, tab strips, canvas surroundings, and file tree. Structure comes
        // from separator lines, not background shades.
        XCTAssertEqual(tokens.sidebarBackgroundColor, base)
        XCTAssertEqual(tokens.rightPanelTabStripBackgroundColor, base)
        XCTAssertEqual(tokens.rightPanelActiveTabStripBackgroundColor, base)
        XCTAssertEqual(tokens.rightPanelInactiveTabStripBackgroundColor, base)
        XCTAssertEqual(tokens.rightPanelFileTreeBackgroundColor, base)
        XCTAssertEqual(tokens.terminalSurroundColor, base)
        assertColor(TideyTerminalPalettePolicy.warmColorTable[NSNumber(value: kColorMapBackground)]!,
                    hex: 0x151413)
        XCTAssertGreaterThan(tokens.paneBoundaryColor.alphaComponent, 0)
        XCTAssertEqual(TideyInterfaceThemeTokens.classic.paneBoundaryColor, .clear)
    }

    func testTerminalTabStripUsesThemeBaseAndPreservesClassicColor() {
        assertColor(TideyTerminalPalettePolicy.terminalTabStripBackgroundColor(warmEnabled: false),
                    red: 0.102,
                    green: 0.108,
                    blue: 0.135)
        let warmColor = TideyTerminalPalettePolicy.terminalTabStripBackgroundColor(warmEnabled: true)
        assertColor(warmColor, hex: 0x151413)
        XCTAssertEqual(warmColor, TideyInterfaceThemeTokens.warm.rightPanelTabStripBackgroundColor)
    }

    func testWarmTerminalPaletteMatchesFrozenDesignValues() {
        let palette = TideyTerminalPalettePolicy.warmColorTable
        let expected: [(Int32, Int)] = [
            (kColorMapBackground, 0x151413),
            (kColorMapForeground, 0xEAE4D4),
            (kColorMapBold, 0xF3EEDF),
            (kColorMapCursor, 0x7FB4A3),
            (kColorMapCursorText, 0x151413),
            (kColorMapSelection, 0x2F2C28),
            (kColorMapSelectedText, 0xF3EEDF),
            (kColorMapLink, 0x7E9CB8),
        ] + [
            0x24211E, 0xC97A6D, 0x9BB584, 0xD9B26C,
            0x7E9CB8, 0xB693A5, 0x7AA89F, 0xD5CDBB,
            0x57524A, 0xE09186, 0xB4CC9E, 0xE8C787,
            0x97B4CE, 0xCBA9BB, 0x93C0B6, 0xF3EEDF,
        ].enumerated().map { index, hex in
            (kColorMap8bitBase + Int32(index), hex)
        }

        XCTAssertEqual(palette.count, expected.count)
        for (key, hex) in expected {
            guard let color = palette[NSNumber(value: key)] else {
                XCTFail("Missing terminal palette key \(key)")
                continue
            }
            assertColor(color, hex: hex)
        }
    }

    func testTerminalTabUnderlineUsesWarmSeaglassAndClassicSystemFallback() {
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabUnderlineColor(warmEnabled: false))
        assertColor(TideyTerminalPalettePolicy.terminalTabUnderlineColor(warmEnabled: true)!,
                    hex: 0x7AA89F)
    }

    func testTerminalPalettePolicyLeavesClassicColorTableAndInputsUnchanged() {
        let factory = terminalColorTable(seed: 0x101010)
        let original = factory

        let result = TideyTerminalPalettePolicy.colorTable(
            byApplyingWarmPaletteTo: factory,
            factoryColorTable: factory,
            warmEnabled: false)

        assertColorTablesEqual(result, factory)
        assertColorTablesEqual(factory, original)
    }

    func testTerminalPalettePolicyAppliesWarmToFactoryPaletteWithoutMutation() {
        let factory = terminalColorTable(seed: 0x202020)
        let original = factory

        let result = TideyTerminalPalettePolicy.colorTable(
            byApplyingWarmPaletteTo: factory,
            factoryColorTable: factory,
            warmEnabled: true)

        XCTAssertEqual(result.count, factory.count)
        assertColor(result[NSNumber(value: kColorMapBackground)]!, hex: 0x151413)
        assertColor(result[NSNumber(value: kColorMapForeground)]!, hex: 0xEAE4D4)
        assertColor(result[NSNumber(value: kColorMap8bitBase + 4)]!, hex: 0x7E9CB8)
        assertColorTablesEqual(factory, original)
    }

    func testTerminalPalettePolicyAppliesWarmToCustomPaletteWithoutMutation() {
        let factory = terminalColorTable(seed: 0x303030)
        var custom = factory
        custom[NSNumber(value: kColorMapBackground)] = color(hex: 0x010203)
        let original = custom

        let result = TideyTerminalPalettePolicy.colorTable(
            byApplyingWarmPaletteTo: custom,
            factoryColorTable: factory,
            warmEnabled: true)

        assertColor(result[NSNumber(value: kColorMapBackground)]!, hex: 0x151413)
        assertColor(result[NSNumber(value: kColorMapForeground)]!, hex: 0xEAE4D4)
        assertColor(result[NSNumber(value: kColorMap8bitBase + 4)]!, hex: 0x7E9CB8)
        assertColorTablesEqual(custom, original)
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

    private func terminalColorTable(seed: Int) -> [NSNumber: NSColor] {
        let managedKeys = [
            kColorMapForeground,
            kColorMapBackground,
            kColorMapBold,
            kColorMapSelection,
            kColorMapSelectedText,
            kColorMapCursor,
            kColorMapCursorText,
            kColorMapLink,
        ] + (0..<16).map { kColorMap8bitBase + Int32($0) }

        return Dictionary(uniqueKeysWithValues: managedKeys.enumerated().map { index, key in
            let component = (seed + index * 0x030303) & 0xFFFFFF
            return (NSNumber(value: key), color(hex: component))
        })
    }

    private func assertColorTablesEqual(_ lhs: [NSNumber: NSColor],
                                        _ rhs: [NSNumber: NSColor],
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertEqual(Set(lhs.keys), Set(rhs.keys), file: file, line: line)
        for key in lhs.keys {
            guard let left = lhs[key], let right = rhs[key] else {
                XCTFail("Missing color for key \(key)", file: file, line: line)
                continue
            }
            XCTAssertTrue(left.isEqual(right), "Colors differ for key \(key)", file: file, line: line)
        }
    }

    private func color(hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
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
