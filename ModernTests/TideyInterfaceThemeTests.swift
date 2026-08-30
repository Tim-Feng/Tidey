import AppKit
import XCTest
@testable import iTerm2SharedARC

final class TideyInterfaceThemeTests: XCTestCase {
    func testApplicationControllerUsesTideySuiteAwareDefaultsStore() {
        XCTAssertTrue(TideyInterfaceThemeController.applicationUserDefaults() ===
                      iTermUserDefaults.userDefaults())
    }

    func testClassicTokensUseAcceptedCoolPalette() {
        let tokens = TideyInterfaceThemeTokens.classic

        assertColor(tokens.sidebarBackgroundColor, hex: 0x16181D)
        assertColor(tokens.rightPanelBackgroundColor, hex: 0x16181D)
        assertColor(tokens.rightPanelTabStripBackgroundColor, hex: 0x111318)
        assertColor(tokens.rightPanelFileTreeBackgroundColor, hex: 0x16181D)
        assertColor(tokens.terminalSurroundColor, hex: 0x16181D)
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
        assertColor(tokens.sidebarSelectionColor, hex: 0x1F2A3E)
        assertColor(tokens.sidebarSelectionBorderColor, hex: 0x5FA0F0, alpha: 0.35)
        assertColor(tokens.sidebarSelectedPrimaryTextColor, hex: 0xF2F5FA)
        assertColor(tokens.sidebarSelectedSecondaryTextColor, hex: 0xB7C3D6)
        assertColor(tokens.sidebarSelectedIdleColor, hex: 0x8E9AAE)
        // Classic palette for the shared modern components.
        assertColor(tokens.paneBoundaryColor, white: 1, alpha: 0.14)
        assertColor(tokens.paneResizerPullBarColor, white: 1, alpha: 0.08)
        assertColor(tokens.tabOutlineColor, white: 1, alpha: 0.10)
        assertColor(tokens.tabSelectedOutlineColor, white: 1, alpha: 0.40)
        assertColor(tokens.fileTreeTextColor, white: 0.92)
        assertColor(tokens.fileTreeIconColor, white: 0.78)
        assertColor(tokens.fileTreeSelectionColor, hex: 0x1F2A3E)
        XCTAssertEqual(TideyChromeLayoutPolicy.sidebarSelectionCornerRadius, 8)
        XCTAssertEqual(TideyChromeLayoutPolicy.rightPanelTabCornerRadius, 0)
    }

    func testBuiltInFocusedWorkspaceCardsKeepLowFatigueDarkHierarchy() {
        for tokens in [TideyInterfaceThemeTokens.classic,
                       TideyInterfaceThemeTokens.warm,
                       TideyInterfaceThemeTokens.sakura] {
            XCTAssertLessThan(relativeLuminance(tokens.sidebarSelectionColor), 0.035)
            XCTAssertGreaterThan(tokens.sidebarSelectionBorderColor.alphaComponent, 0)
        }
    }

    func testWarmBrowserToolbarUsesOneExactContentRow() {
        let tokens = TideyInterfaceThemeTokens.warm
        let toolbarHeight = TideyBrowserToolbarPolicy.toolbarHeight()

        XCTAssertEqual(toolbarHeight, 28)
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldHeight(), 22)
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldFrame(
                toolbarHeight: toolbarHeight,
                contentWidth: 500),
            NSRect(x: 92, y: 3, width: 380, height: 22)
        )
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldTextRect(
                fieldBounds: NSRect(x: 0, y: 0, width: 380, height: 22)),
            NSRect(x: 4, y: 3, width: 372, height: 16)
        )
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.toolbarBackgroundColor(tokens: tokens),
            tokens.rightPanelBackgroundColor
        )
        XCTAssertNotEqual(tokens.rightPanelBackgroundColor,
                          tokens.rightPanelTabStripBackgroundColor)
    }

    func testClassicBrowserToolbarSharesModernGeometryAndKeepsClassicColors() {
        let tokens = TideyInterfaceThemeTokens.classic
        let toolbarHeight = TideyBrowserToolbarPolicy.toolbarHeight()

        XCTAssertEqual(toolbarHeight, 28)
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldHeight(), 22)
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldFrame(
                toolbarHeight: toolbarHeight,
                contentWidth: 500),
            NSRect(x: 92, y: 3, width: 380, height: 22)
        )
        // Same inner text rect as Warm: the address field is one component.
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldTextRect(
                fieldBounds: NSRect(x: 0, y: 0, width: 380, height: 22)),
            NSRect(x: 4, y: 3, width: 372, height: 16)
        )
        assertColor(
            TideyBrowserToolbarPolicy.toolbarBackgroundColor(tokens: tokens),
            white: 0.15
        )
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

    func testStoredThemeParsingAcceptsBuiltInThemesAndFallsBackToClassic() {
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier(nil), "classic")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("classic"), "classic")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("warm"), "warm")
        XCTAssertEqual(TideyInterfaceThemeController.normalizedThemeIdentifier("sakura"), "sakura")
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
        assertColor(tokens.rightPanelTabStripBackgroundColor, hex: 0x100F0E)
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
        // Focused tab outline: same cream as the workspace focus edge but strong
        // enough (0.40) for its trailing fade into the separators to be visible.
        assertColor(tokens.tabSelectedOutlineColor,
                    red: 240.0 / 255.0,
                    green: 230.0 / 255.0,
                    blue: 210.0 / 255.0,
                    alpha: 0.40)
        // Editor tabs reuse the production flat-tab component and the
        // selection indicator line carries seaglass.
        XCTAssertEqual(TideyChromeLayoutPolicy.sidebarSelectionCornerRadius, 8)
        XCTAssertEqual(TideyChromeLayoutPolicy.rightPanelTabCornerRadius, 0)
        assertColor(tokens.rightPanelTabSelectionIndicatorColor, hex: 0x7AA89F)
        XCTAssertEqual(tokens.rightPanelTabSelectionIndicatorColor,
                       TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabUnderlineColor)
    }

    func testSakuraTokensMatchFrozenDesignValues() {
        let tokens = TideyInterfaceThemeTokens.sakura

        assertColor(tokens.baseSurfaceColor, hex: 0x161214)
        assertColor(tokens.tabDeskColor, hex: 0x110E10)
        assertColor(tokens.sidebarBackgroundColor, hex: 0x161214)
        assertColor(tokens.sidebarSelectionColor, hex: 0x2A1F25)
        assertColor(tokens.sidebarSelectionBorderColor, hex: 0xE8A0B4, alpha: 0.35)
        assertColor(tokens.sidebarPrimaryTextColor, hex: 0xEFE6EA)
        assertColor(tokens.sidebarSelectedPrimaryTextColor, hex: 0xF8F2F5)
        assertColor(tokens.sidebarSecondaryTextColor, hex: 0xB8A8B0)
        assertColor(tokens.sidebarSelectedSecondaryTextColor, hex: 0xD3C6CD)
        assertColor(tokens.sidebarUnreadColor, hex: 0xEE9AB0)
        assertColor(tokens.sidebarIdleColor, hex: 0x7E6F78)
        assertColor(tokens.sidebarSelectedIdleColor, hex: 0x998A93)
        assertColor(tokens.sidebarRunningColor, hex: 0x9CC39B)
        assertColor(tokens.sidebarCloseColor, hex: 0x7E6F78)
        assertColor(tokens.sidebarPinColor, hex: 0xB8A8B0)
        assertColor(tokens.sidebarUnreadTitleColor, hex: 0xEE9AB0)
        assertColor(tokens.sidebarSelectedUnreadTitleColor, hex: 0xEE9AB0)

        assertColor(tokens.rightPanelBackgroundColor, hex: 0x161214)
        assertColor(tokens.rightPanelTabStripBackgroundColor, hex: 0x110E10)
        assertColor(tokens.rightPanelActiveTabStripBackgroundColor, hex: 0x110E10)
        assertColor(tokens.rightPanelInactiveTabStripBackgroundColor, hex: 0x110E10)
        assertColor(tokens.rightPanelFileTreeBackgroundColor, hex: 0x161214)
        assertColor(tokens.fileTreeTextColor, hex: 0xEFE6EA)
        assertColor(tokens.fileTreeIconColor, hex: 0xB8A8B0)
        assertColor(tokens.fileTreeSelectionColor, hex: 0x2A1F25)
        assertColor(tokens.paneBoundaryColor, hex: 0xEFE6EA, alpha: 0.12)
        assertColor(tokens.paneResizerPullBarColor, hex: 0xEFE6EA, alpha: 0.06)
        assertColor(tokens.tabOutlineColor, hex: 0xEFE6EA, alpha: 0.08)
        assertColor(tokens.tabSelectedOutlineColor, hex: 0xE8A0B4, alpha: 0.45)
        assertColor(tokens.rightPanelSplitDividerColor, hex: 0xEFE6EA, alpha: 0.07)
        assertColor(tokens.rightPanelTabHoverColor, hex: 0x201A1E)
        assertColor(tokens.rightPanelTabSelectionIndicatorColor, hex: 0xE8A0B4)
        assertColor(tokens.rightPanelTabSeparatorColor, hex: 0xEFE6EA, alpha: 0.07)
        assertColor(tokens.rightPanelPrimaryTextColor, hex: 0xEFE6EA)
        assertColor(tokens.rightPanelSecondaryTextColor, hex: 0xB8A8B0)
        assertColor(tokens.rightPanelTertiaryTextColor, hex: 0x7E6F78)
        assertColor(tokens.rightPanelGroupExpandedFillColor, hex: 0xE8A0B4, alpha: 0.14)
        assertColor(tokens.rightPanelGroupCollapsedFillColor, hex: 0xEFE6EA, alpha: 0.06)
        assertColor(tokens.rightPanelGroupExpandedTextColor, hex: 0xE8A0B4)
        assertColor(tokens.rightPanelGroupCollapsedTextColor, hex: 0xB8A8B0)
        assertColor(tokens.browserToolbarBackgroundColor, hex: 0x161214)
        assertColor(tokens.browserToolbarControlColor, hex: 0x7E6F78)

        assertColor(tokens.terminalSurroundColor, hex: 0x161214)
        assertColor(tokens.settingsPanelBackgroundColor, hex: 0x161214)
        assertColor(tokens.settingsCardBackgroundColor, hex: 0x241C21)
        assertColor(tokens.settingsCardBorderColor, hex: 0xEFE6EA, alpha: 0.07)
        assertColor(tokens.settingsDividerColor, hex: 0xEFE6EA, alpha: 0.07)
        assertColor(tokens.settingsPrimaryTextColor, hex: 0xEFE6EA)
        assertColor(tokens.settingsSecondaryTextColor, hex: 0xB8A8B0)
        assertColor(tokens.hairlineColor, hex: 0xEFE6EA, alpha: 0.07)
        XCTAssertFalse(tokens.usesHostTitlebarTextColors)
    }

    func testPaperTabPolicyIsSharedByTerminalAndEditorTabs() {
        XCTAssertEqual(TideyPaperTabPolicy.outlineWidth, 1)
        XCTAssertEqual(TideyPaperTabPolicy.topCornerRadius, 4)
        XCTAssertEqual(TideyPaperTabPolicy.unselectedTopInset, 2)
        XCTAssertEqual(TideyPaperTabPolicy.selectionIndicatorHeight, 2)
        XCTAssertEqual(TideyPaperTabPolicy.pullBarWidth, 2)
        XCTAssertEqual(TideyPaperTabPolicy.pullBarLength, 34)
        XCTAssertEqual(TideyPaperTabPolicy.boundaryJoinGradientLength, 14)

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

        // Terminal tab bar receives each theme's own outline colors.
        XCTAssertEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabOutlineColor,
                       TideyInterfaceThemeTokens.classic.tabOutlineColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabOutlineColor,
                       TideyInterfaceThemeTokens.warm.tabOutlineColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.sakura.terminalAdapter.terminalTabOutlineColor,
                       TideyInterfaceThemeTokens.sakura.tabOutlineColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabSelectedOutlineColor,
                       TideyInterfaceThemeTokens.classic.tabSelectedOutlineColor)
        // Tab new-output dot shares the workspace unread accent in Warm.
        XCTAssertNil(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabNewOutputDotColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabNewOutputDotColor,
                       TideyInterfaceThemeTokens.warm.sidebarUnreadColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.sakura.terminalAdapter.terminalTabNewOutputDotColor,
                       TideyInterfaceThemeTokens.sakura.sidebarUnreadColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabSelectedOutlineColor,
                       TideyInterfaceThemeTokens.warm.tabSelectedOutlineColor)
        XCTAssertEqual(TideyInterfaceThemeDefinition.sakura.terminalAdapter.terminalTabSelectedOutlineColor,
                       TideyInterfaceThemeTokens.sakura.tabSelectedOutlineColor)
    }

    func testPaperTabBoundaryJoinGradientStartsAtTheTabEdgeAndSettlesQuickly() {
        XCTAssertEqual(TideyPaperTabPolicy.boundaryJoinGradientLocations(forBoundaryHeight: 100)
            .map(\.doubleValue), [0, 0.14, 1])
        XCTAssertEqual(TideyPaperTabPolicy.boundaryJoinGradientLocations(forBoundaryHeight: 7)
            .map(\.doubleValue), [0, 1, 1])
        XCTAssertEqual(TideyPaperTabPolicy.boundaryJoinGradientLocations(forBoundaryHeight: 0)
            .map(\.doubleValue), [0, 1, 1])
    }

    func testFocusedPaperTabTrailingCornerGeometryHandsTheLegToTheFadeRenderer() {
        let tab = NSRect(x: 20, y: 0, width: 100, height: 30)
        // Leading side + top end where the trailing leg starts, so the leg is never double-stroked.
        let leadingAndTop = TideyPaperTabPolicy.selectedLeadingAndTopOutlinePath(for: tab)
        XCTAssertEqual(leadingAndTop.currentPoint.x, 119.5, accuracy: 0.001)
        XCTAssertEqual(leadingAndTop.currentPoint.y, 4.5, accuracy: 0.001)
        // Trailing leg: the tab's last column, from below the arc to just above the corner pixel.
        XCTAssertEqual(TideyPaperTabPolicy.trailingLegRect(forTabRect: tab),
                       NSRect(x: 119, y: 4.5, width: 1, height: 24.5))
        // Baseline fade: starts at the corner pixel, 24pt when room allows, clamped otherwise.
        XCTAssertEqual(TideyPaperTabPolicy.trailingBaselineRect(forTabRect: tab, availableTrailingWidth: 200),
                       NSRect(x: 119, y: 29, width: 25, height: 1))
        XCTAssertEqual(TideyPaperTabPolicy.trailingBaselineRect(forTabRect: tab, availableTrailingWidth: 6),
                       NSRect(x: 119, y: 29, width: 7, height: 1))
        XCTAssertEqual(TideyPaperTabPolicy.trailingFadeVerticalLength, 14)
        XCTAssertEqual(TideyPaperTabPolicy.trailingFadeHorizontalLength, 24)
    }

    func testEditorTrailingOverlayPreservesTheSelectedTabsFullCornerRadius() {
        let reference = TideyPaperTabPolicy.trailingOverlayReferenceTabRect(
            tabWidth: 478,
            tabHeight: 30)
        // The overlay's x=0 column is the selected tab's trailing column, but
        // the reference rect retains the real tab width. A 2pt dummy rect
        // would collapse the 4pt radius to 1pt and double-paint the top-right
        // arc with the trailing leg.
        XCTAssertEqual(reference, NSRect(x: -477, y: 0, width: 478, height: 30))
        XCTAssertEqual(TideyPaperTabPolicy.trailingLegRect(forTabRect: reference),
                       NSRect(x: 0, y: 4.5, width: 1, height: 24.5))
    }

    func testFocusedNonLeadingPaperTabHandsBothLegsToCornerRenderers() {
        let tab = NSRect(x: 80, y: 0, width: 100, height: 30)
        let topOnly = TideyPaperTabPolicy.selectedTopOutlinePath(for: tab)
        XCTAssertEqual(topOnly.currentPoint.x, 179.5, accuracy: 0.001)
        XCTAssertEqual(topOnly.currentPoint.y, 4.5, accuracy: 0.001)
        XCTAssertEqual(TideyPaperTabPolicy.leadingLegRect(forTabRect: tab),
                       NSRect(x: 80, y: 4.5, width: 1, height: 24.5))
        XCTAssertEqual(TideyPaperTabPolicy.leadingBaselineRect(forTabRect: tab, availableLeadingWidth: 60),
                       NSRect(x: 56, y: 29, width: 25, height: 1))
        XCTAssertEqual(TideyPaperTabPolicy.leadingBaselineRect(forTabRect: tab, availableLeadingWidth: 6),
                       NSRect(x: 74, y: 29, width: 7, height: 1))
    }

    func testWorkspaceSeparatorJoinGradientRequiresTheFocusedTabAtTheLeadingEdge() {
        let strip = NSRect(x: 0, y: 0, width: 500, height: 30)
        XCTAssertTrue(TideyPaperTabPolicy.selectedTabConnectsToLeadingBoundary(
            selectedTabFrame: NSRect(x: 0, y: 0, width: 120, height: 30),
            stripBounds: strip))
        XCTAssertFalse(TideyPaperTabPolicy.selectedTabConnectsToLeadingBoundary(
            selectedTabFrame: NSRect(x: 120, y: 0, width: 120, height: 30),
            stripBounds: strip))
        XCTAssertFalse(TideyPaperTabPolicy.selectedTabConnectsToLeadingBoundary(
            selectedTabFrame: .zero,
            stripBounds: strip))
    }

    func testFocusedPaperTabLeadingCornerRampIsVisibleAndContinuousInPixels() throws {
        let width = 200, height = 40
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: width,
                                                 pixelsHigh: height,
                                                 bitsPerSample: 8,
                                                 samplesPerPixel: 4,
                                                 hasAlpha: true,
                                                 isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0,
                                                 bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let tokens = TideyInterfaceThemeTokens.warm
        let strip = tokens.rightPanelTabStripBackgroundColor
        let outline = tokens.tabSelectedOutlineColor
        let separator = tokens.paneBoundaryColor
        let tab = NSRect(x: 80, y: 0, width: 100, height: 30)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        strip.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        separator.setFill()
        NSRect(x: 0, y: 29, width: width, height: 1).fill()
        TideyPaperTabPolicy.drawLeadingCorner(forTabRect: tab,
                                              availableLeadingWidth: 60,
                                              outlineColor: outline,
                                              separatorColor: separator,
                                              stripBackgroundColor: strip)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        func luma(_ x: Int, _ y: Int) -> CGFloat {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let stripLuma = luma(5, 5)
        let separatorLuma = luma(40, 29)
        let legTop = luma(80, 8)
        let legMid = luma(80, 22)
        let corner = luma(80, 29)
        let baselineNear = luma(74, 29)
        let baselineFar = luma(60, 29)
        let baselineAfter = luma(50, 29)

        XCTAssertGreaterThan(legTop, stripLuma + 0.10)
        XCTAssertGreaterThan(legTop, legMid + 0.02)
        XCTAssertGreaterThan(legMid, corner)
        XCTAssertGreaterThan(corner, baselineNear - 0.005)
        XCTAssertGreaterThan(baselineNear, baselineFar)
        XCTAssertGreaterThan(baselineFar, separatorLuma - 0.005)
        XCTAssertEqual(baselineAfter, separatorLuma, accuracy: 0.01)
        XCTAssertGreaterThan(corner, separatorLuma)
        XCTAssertEqual(luma(79, 8), stripLuma, accuracy: 0.01)
        XCTAssertEqual(luma(80, 31), stripLuma, accuracy: 0.01)
    }

    /// Renders the shared trailing-corner ramp into a bitmap and checks the
    /// actual pixels: solid focus color at the top of the leg, a visible
    /// monotonic fade down to the corner, the corner pixel itself, then a fade
    /// along the baseline that ends at the plain separator value.
    func testFocusedPaperTabTrailingCornerRampIsVisibleAndContinuousInPixels() throws {
        let width = 200, height = 40
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: width,
                                                 pixelsHigh: height,
                                                 bitsPerSample: 8,
                                                 samplesPerPixel: 4,
                                                 hasAlpha: true,
                                                 isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0,
                                                 bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let tokens = TideyInterfaceThemeTokens.warm
        let strip = tokens.rightPanelTabStripBackgroundColor
        let outline = tokens.tabSelectedOutlineColor
        let separator = tokens.paneBoundaryColor
        let tab = NSRect(x: 20, y: 0, width: 100, height: 30)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Flip so the policy's flipped (y-down) coordinates map onto bitmap rows.
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        strip.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // Host separator that the fade must replace under its baseline run.
        separator.setFill()
        NSRect(x: 0, y: 29, width: width, height: 1).fill()
        TideyPaperTabPolicy.drawTrailingCorner(forTabRect: tab,
                                               availableTrailingWidth: 80,
                                               outlineColor: outline,
                                               separatorColor: separator,
                                               stripBackgroundColor: strip)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        func luma(_ x: Int, _ y: Int) -> CGFloat {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let stripLuma = luma(5, 5)
        let separatorLuma = luma(180, 29)      // untouched host separator far right
        let legTop = luma(119, 8)              // solid part of the trailing leg
        let legMid = luma(119, 22)             // inside the vertical fade
        let corner = luma(119, 29)             // corner pixel
        let baselineNear = luma(125, 29)       // early in the baseline fade
        let baselineFar = luma(140, 29)        // late in the baseline fade
        let baselineAfter = luma(150, 29)      // beyond the fade: plain separator again

        XCTAssertGreaterThan(legTop, stripLuma + 0.10, "focus outline must read clearly against the strip")
        XCTAssertGreaterThan(legTop, legMid + 0.02, "leg must already be fading before its endpoint")
        XCTAssertGreaterThan(legMid, corner, "fade continues down to the corner")
        XCTAssertGreaterThan(corner, baselineNear - 0.005, "no color reset at the turn")
        XCTAssertGreaterThan(baselineNear, baselineFar, "baseline keeps fading")
        XCTAssertGreaterThan(baselineFar, separatorLuma - 0.005, "fade settles into the separator")
        XCTAssertEqual(baselineAfter, separatorLuma, accuracy: 0.01)
        XCTAssertGreaterThan(corner, separatorLuma, "corner is still visibly brighter than the plain separator")
        // Nothing stroked on the leg's right neighbour or below the baseline.
        XCTAssertEqual(luma(120, 8), stripLuma, accuracy: 0.01)
        XCTAssertEqual(luma(119, 31), stripLuma, accuracy: 0.01)
    }

    func testEditorCanvasPolicyKeepsClassicMonacoAndJoinsEachBaseSurface() {
        let classicAdapter = TideyInterfaceThemeDefinition.classic.editorCanvasAdapter
        let warmAdapter = TideyInterfaceThemeDefinition.warm.editorCanvasAdapter
        XCTAssertEqual(classicAdapter.monacoThemeName, "tidey-classic")
        XCTAssertEqual(classicAdapter.pageBackgroundHex, "#16181d")
        XCTAssertEqual(classicAdapter.pageBackgroundHex,
                       TideyEditorCanvasThemeAdapter.hexString(for: TideyInterfaceThemeTokens.classic.rightPanelBackgroundColor))
        let classicScript = classicAdapter.themeDefinitionScript
        XCTAssertTrue(classicScript.hasPrefix("monaco.editor.defineTheme('tidey-classic',"))
        XCTAssertTrue(classicScript.contains("\"editor.background\":\"#16181d\""))
        XCTAssertTrue(classicScript.contains("\"editorGutter.background\":\"#16181d\""))

        XCTAssertEqual(warmAdapter.monacoThemeName, "tidey-warm")
        XCTAssertEqual(warmAdapter.pageBackgroundHex, "#151413")
        let script = warmAdapter.themeDefinitionScript
        XCTAssertTrue(script.hasPrefix("monaco.editor.defineTheme('tidey-warm',"))
        XCTAssertTrue(script.contains("\"base\":\"vs-dark\""))
        XCTAssertTrue(script.contains("\"editor.background\":\"#151413\""))
        XCTAssertTrue(script.contains("\"editor.foreground\":\"#eae4d4\""))
        XCTAssertTrue(script.contains("\"editorCursor.foreground\":\"#7fb4a3\""))
        XCTAssertTrue(script.contains("\"editor.selectionBackground\":\"#2f2c28\""))
        XCTAssertEqual(TideyEditorCanvasThemeAdapter.hexString(for: TideyInterfaceThemeTokens.warm.rightPanelBackgroundColor),
                       "#151413")
    }

    func testWarmBaseSurfacesShareOneColorAndBoundariesComeFromSeparators() {
        let tokens = TideyInterfaceThemeTokens.warm
        let base = tokens.rightPanelBackgroundColor
        // Workspace column, canvas surroundings, and file tree share one base
        // surface. The tab strips are the one deliberate exception (Tim
        // 2026-08-29): a darker "desk" behind the paper tabs, so the focused tab
        // filled with the base color reads as the front sheet.
        XCTAssertEqual(tokens.sidebarBackgroundColor, base)
        XCTAssertEqual(tokens.rightPanelFileTreeBackgroundColor, base)
        let desk = tokens.rightPanelTabStripBackgroundColor
        XCTAssertEqual(tokens.rightPanelActiveTabStripBackgroundColor, desk)
        XCTAssertEqual(tokens.rightPanelInactiveTabStripBackgroundColor, desk)
        XCTAssertLessThan(desk.usingColorSpace(.sRGB)!.redComponent, base.usingColorSpace(.sRGB)!.redComponent)
        XCTAssertEqual(TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabSelectedFillColor, base)
        XCTAssertEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabSelectedFillColor,
                       TideyInterfaceThemeTokens.classic.rightPanelBackgroundColor)
        XCTAssertEqual(tokens.terminalSurroundColor, base)
        assertColor(TideyTerminalThemeAdapter.warmColorOverrides[NSNumber(value: kColorMapBackground)]!,
                    hex: 0x151413)
        XCTAssertGreaterThan(tokens.paneBoundaryColor.alphaComponent, 0)
        XCTAssertGreaterThan(TideyInterfaceThemeTokens.classic.paneBoundaryColor.alphaComponent, 0)
    }

    func testClassicBaseSurfacesShareOneColorAndTabStripsShareOneDeskColor() {
        let tokens = TideyInterfaceThemeTokens.classic
        let base = tokens.rightPanelBackgroundColor
        XCTAssertEqual(tokens.sidebarBackgroundColor, base)
        XCTAssertEqual(tokens.rightPanelFileTreeBackgroundColor, base)
        XCTAssertEqual(tokens.terminalSurroundColor, base)
        XCTAssertEqual(TideyInterfaceThemeDefinition.classic.editorCanvasAdapter.pageBackgroundHex,
                       TideyEditorCanvasThemeAdapter.hexString(for: base))

        let desk = tokens.rightPanelTabStripBackgroundColor
        XCTAssertEqual(tokens.rightPanelActiveTabStripBackgroundColor, desk)
        XCTAssertEqual(tokens.rightPanelInactiveTabStripBackgroundColor, desk)
        XCTAssertEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabStripBackgroundColor, desk)
        XCTAssertLessThan(desk.usingColorSpace(.sRGB)!.redComponent,
                          base.usingColorSpace(.sRGB)!.redComponent)
    }

    /// Built-in themes share one layout/component policy and differ only in
    /// their resolved component colors.
    func testBuiltInThemesShareLayoutPolicyButKeepDistinctPalettes() {
        let classic = TideyInterfaceThemeTokens.classic
        let warm = TideyInterfaceThemeTokens.warm
        let sakura = TideyInterfaceThemeTokens.sakura
        // Same browser chrome geometry.
        XCTAssertEqual(TideyBrowserToolbarPolicy.toolbarHeight(), 28)
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldHeight(), 22)
        let fieldBounds = NSRect(x: 0, y: 0, width: 380, height: 22)
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldTextRect(fieldBounds: fieldBounds),
                       NSRect(x: 4, y: 3, width: 372, height: 16))
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldFrame(toolbarHeight: 28, contentWidth: 500),
                       NSRect(x: 92, y: 3, width: 380, height: 22))
        XCTAssertNotEqual(TideyBrowserToolbarPolicy.toolbarBackgroundColor(tokens: classic),
                          TideyBrowserToolbarPolicy.toolbarBackgroundColor(tokens: warm))
        XCTAssertNotEqual(TideyBrowserToolbarPolicy.toolbarBackgroundColor(tokens: warm),
                          TideyBrowserToolbarPolicy.toolbarBackgroundColor(tokens: sakura))
        // Distinct palettes for the same components.
        for (name, colors) in [
            ("sidebarBackground", [classic.sidebarBackgroundColor, warm.sidebarBackgroundColor, sakura.sidebarBackgroundColor]),
            ("sidebarSelection", [classic.sidebarSelectionColor, warm.sidebarSelectionColor, sakura.sidebarSelectionColor]),
            ("tabOutline", [classic.tabOutlineColor, warm.tabOutlineColor, sakura.tabOutlineColor]),
            ("tabSelectedOutline", [classic.tabSelectedOutlineColor, warm.tabSelectedOutlineColor, sakura.tabSelectedOutlineColor]),
            ("paneBoundary", [classic.paneBoundaryColor, warm.paneBoundaryColor, sakura.paneBoundaryColor]),
            ("paneResizer", [classic.paneResizerPullBarColor, warm.paneResizerPullBarColor, sakura.paneResizerPullBarColor]),
            ("fileTreeSelection", [classic.fileTreeSelectionColor, warm.fileTreeSelectionColor, sakura.fileTreeSelectionColor]),
            ("tabStrip", [classic.rightPanelTabStripBackgroundColor, warm.rightPanelTabStripBackgroundColor, sakura.rightPanelTabStripBackgroundColor]),
        ] {
            XCTAssertNotEqual(colors[0], colors[1], "Classic/Warm \(name)")
            XCTAssertNotEqual(colors[0], colors[2], "Classic/Sakura \(name)")
            XCTAssertNotEqual(colors[1], colors[2], "Warm/Sakura \(name)")
        }
        XCTAssertNotEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabOutlineColor,
                          TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabOutlineColor)
        XCTAssertNotEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabSelectedFillColor,
                          TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabSelectedFillColor)
        XCTAssertNotEqual(TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabSelectedFillColor,
                          TideyInterfaceThemeDefinition.sakura.terminalAdapter.terminalTabSelectedFillColor)
    }

    func testTerminalTabStripUsesEachThemeDeskColor() {
        assertColor(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabStripBackgroundColor,
                    hex: 0x111318)
        XCTAssertEqual(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabStripBackgroundColor,
                       TideyInterfaceThemeTokens.classic.rightPanelTabStripBackgroundColor)
        let warmColor = TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabStripBackgroundColor
        assertColor(warmColor, hex: 0x100F0E)
        XCTAssertEqual(warmColor, TideyInterfaceThemeTokens.warm.rightPanelTabStripBackgroundColor)
        let sakuraColor = TideyInterfaceThemeDefinition.sakura.terminalAdapter.terminalTabStripBackgroundColor
        assertColor(sakuraColor, hex: 0x110E10)
        XCTAssertEqual(sakuraColor, TideyInterfaceThemeTokens.sakura.rightPanelTabStripBackgroundColor)
    }

    func testWarmTerminalPaletteMatchesFrozenDesignValues() {
        let palette = TideyTerminalThemeAdapter.warmColorOverrides
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

    func testSakuraTerminalEditorStatusAndSettingsAdaptersMatchDesign() {
        let theme = TideyInterfaceThemeDefinition.sakura
        let palette = TideyTerminalThemeAdapter.sakuraColorOverrides
        let expected: [(Int32, Int)] = [
            (kColorMapBackground, 0x161214),
            (kColorMapForeground, 0xEFE6EA),
            (kColorMapBold, 0xF8F2F5),
            (kColorMapCursor, 0xE8A0B4),
            (kColorMapCursorText, 0x161214),
            (kColorMapSelection, 0x2A1F25),
            (kColorMapSelectedText, 0xF8F2F5),
            (kColorMapLink, 0x8FB0D0),
        ] + [
            0x262024, 0xD97A85, 0x9CC39B, 0xD9B27A,
            0x8FA8CC, 0xD9A0C4, 0x8FBFB8, 0xD8CDD3,
            0x5C4F57, 0xE89AA3, 0xB5D5B4, 0xE8C795,
            0xA9BEDB, 0xE8B9D6, 0xA8D2CB, 0xF8F2F5,
        ].enumerated().map { index, hex in
            (kColorMap8bitBase + Int32(index), hex)
        }

        XCTAssertEqual(theme.identifier, "sakura")
        XCTAssertEqual(theme.displayName, "Sakura Fubuki · 落櫻繽紛")
        XCTAssertTrue(theme.tokens === TideyInterfaceThemeTokens.sakura)
        XCTAssertEqual(palette.count, expected.count)
        for (key, hex) in expected {
            guard let color = palette[NSNumber(value: key)] else {
                XCTFail("Missing Sakura terminal palette key \(key)")
                continue
            }
            assertColor(color, hex: hex)
        }
        assertColor(theme.terminalAdapter.terminalTabUnderlineColor!, hex: 0xE8A0B4)
        assertColor(theme.terminalAdapter.terminalTabNewOutputDotColor!, hex: 0xEE9AB0)

        let input = terminalColorTable(seed: 0x404040)
        let original = input
        let rendered = theme.terminalAdapter.colorTable(byApplyingTo: input)
        assertColor(rendered[NSNumber(value: kColorMapBackground)]!, hex: 0x161214)
        assertColor(rendered[NSNumber(value: kColorMap8bitBase + 4)]!, hex: 0x8FA8CC)
        assertColorTablesEqual(input, original)

        let editor = theme.editorCanvasAdapter
        XCTAssertEqual(editor.monacoThemeName, "tidey-sakura")
        XCTAssertEqual(editor.pageBackgroundHex, "#161214")
        let script = editor.themeDefinitionScript
        XCTAssertTrue(script.contains("\"editor.background\":\"#161214\""))
        XCTAssertTrue(script.contains("\"editor.foreground\":\"#efe6ea\""))
        XCTAssertTrue(script.contains("\"editorCursor.foreground\":\"#e8a0b4\""))
        XCTAssertTrue(script.contains("\"editor.selectionBackground\":\"#2a1f25\""))
        XCTAssertTrue(script.contains("\"token\":\"keyword\",\"foreground\":\"8fa8cc\""))
        XCTAssertTrue(script.contains("\"token\":\"string\",\"foreground\":\"9cc39b\""))

        let status = theme.statusSemanticsAdapter
        assertColor(status.color(forStatusValues: ["Needs input"],
                                 producerColor: nil,
                                 selected: false),
                    hex: 0xEE9AB0)
        assertColor(status.color(forStatusValues: ["Running"],
                                 producerColor: nil,
                                 selected: false),
                    hex: 0x9CC39B)
        assertColor(status.color(forStatusValues: ["Idle"],
                                 producerColor: nil,
                                 selected: false),
                    hex: 0x7E6F78)

        let settings = theme.settingsAdapter
        assertColor(settings.mainWindowBackgroundColor, hex: 0x161214)
        assertColor(settings.panelBackgroundColor, hex: 0x161214)
        assertColor(settings.cardBackgroundColor, hex: 0x241C21)
        assertColor(settings.accentColor, hex: 0xE8A0B4)
        assertColor(settings.tabSelectionBackgroundColor, hex: 0xE8A0B4, alpha: 0.12)
        assertColor(settings.tabSelectionTextColor, hex: 0xE8A0B4)
    }

    func testTerminalTabUnderlineUsesWarmSeaglassAndClassicSystemFallback() {
        XCTAssertNil(TideyInterfaceThemeDefinition.classic.terminalAdapter.terminalTabUnderlineColor)
        assertColor(TideyInterfaceThemeDefinition.warm.terminalAdapter.terminalTabUnderlineColor!,
                    hex: 0x7AA89F)
    }

    func testClassicTerminalAdapterPreservesProfilePaletteWithoutMutatingInput() {
        let factory = terminalColorTable(seed: 0x101010)
        let original = factory

        let result = TideyInterfaceThemeDefinition.classic.terminalAdapter.colorTable(
            byApplyingTo: factory)

        assertColorTablesEqual(result, factory)
        assertColorTablesEqual(factory, original)
    }

    func testSettingsAdaptersPreserveClassicOverridesAndWarmTokenDefaults() {
        let classic = TideyInterfaceThemeDefinition.classic.settingsAdapter
        assertColor(classic.mainWindowBackgroundColor, hex: 0x1A1A1A)
        assertColor(classic.panelBackgroundColor, hex: 0x1E1E1E)
        assertColor(classic.cardBackgroundColor, hex: 0x2A2A2C)
        assertColor(classic.cardBorderColor, white: 1, alpha: 0.06)
        assertColor(classic.dividerColor, white: 1, alpha: 0.07)
        assertColor(classic.primaryTextColor, white: 1, alpha: 0.92)
        assertColor(classic.secondaryTextColor,
                    red: 235.0 / 255.0,
                    green: 235.0 / 255.0,
                    blue: 245.0 / 255.0,
                    alpha: 0.55)
        assertColor(classic.tertiaryTextColor,
                    red: 235.0 / 255.0,
                    green: 235.0 / 255.0,
                    blue: 245.0 / 255.0,
                    alpha: 0.28)
        assertColor(classic.accentColor, hex: 0x0A84FF)

        let warmTheme = TideyInterfaceThemeDefinition.warm
        let warm = warmTheme.settingsAdapter
        XCTAssertEqual(warm.mainWindowBackgroundColor, warmTheme.tokens.settingsPanelBackgroundColor)
        XCTAssertEqual(warm.panelBackgroundColor, warmTheme.tokens.settingsPanelBackgroundColor)
        XCTAssertEqual(warm.cardBackgroundColor, warmTheme.tokens.settingsCardBackgroundColor)
        XCTAssertEqual(warm.cardBorderColor, warmTheme.tokens.settingsCardBorderColor)
        XCTAssertEqual(warm.dividerColor, warmTheme.tokens.settingsDividerColor)
        XCTAssertEqual(warm.primaryTextColor, warmTheme.tokens.settingsPrimaryTextColor)
        XCTAssertEqual(warm.secondaryTextColor, warmTheme.tokens.settingsSecondaryTextColor)
        XCTAssertEqual(warm.tertiaryTextColor, warmTheme.tokens.rightPanelTertiaryTextColor)
        XCTAssertEqual(warm.accentColor, warmTheme.tokens.sidebarRunningColor)
    }

    func testTerminalPalettePolicyAppliesWarmToFactoryPaletteWithoutMutation() {
        let factory = terminalColorTable(seed: 0x202020)
        let original = factory

        let result = TideyInterfaceThemeDefinition.warm.terminalAdapter.colorTable(
            byApplyingTo: factory)

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

        let result = TideyInterfaceThemeDefinition.warm.terminalAdapter.colorTable(
            byApplyingTo: custom)

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

    func testThemePickerExposesBuiltInThemesInStableOrder() {
        XCTAssertEqual(TideyInterfaceThemeController.supportedThemeIdentifiers,
                       ["classic", "warm", "sakura"])
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "classic"),
                       "Classic · 經典藍調")
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "warm"),
                       "Amber Night · 琥珀夜色")
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "sakura"),
                       "Sakura Fubuki · 落櫻繽紛")
        XCTAssertEqual(TideyInterfaceThemeController.displayName(forIdentifier: "tech"),
                       "Classic · 經典藍調")

        let suiteName = "TideyInterfaceThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = TideyInterfaceThemeController(userDefaults: defaults)

        controller.currentThemeIdentifier = "sakura"

        XCTAssertTrue(controller.currentTheme === TideyInterfaceThemeDefinition.sakura)
        XCTAssertEqual(defaults.string(forKey: TideyInterfaceThemeController.defaultsKey), "sakura")
    }

    func testRegistryAcceptsAnOrderedSyntheticThirdThemeAndRejectsDuplicates() {
        let synthetic = TideyInterfaceThemeDefinition(
            identifier: "midnight",
            displayName: "Midnight",
            tokens: .warm)
        let invalid = TideyInterfaceThemeDefinition(
            identifier: "not valid",
            displayName: "Invalid",
            tokens: .classic)
        let registry = TideyInterfaceThemeRegistry(
            themes: [.classic, .warm],
            fallbackIdentifier: "classic")

        XCTAssertTrue(registry.register(synthetic))
        XCTAssertFalse(registry.register(synthetic))
        XCTAssertFalse(registry.register(invalid))
        XCTAssertEqual(registry.supportedThemeIdentifiers, ["classic", "warm", "midnight"])
        XCTAssertTrue(registry.theme(forIdentifier: " MIDNIGHT ") === synthetic)
        XCTAssertTrue(registry.theme(forIdentifier: "missing") === TideyInterfaceThemeDefinition.classic)
        XCTAssertEqual(synthetic.editorCanvasAdapter.monacoThemeName, "tidey-midnight")
        XCTAssertEqual(synthetic.terminalAdapter.terminalTabSelectedFillColor,
                       synthetic.tokens.rightPanelBackgroundColor)
        XCTAssertEqual(synthetic.settingsAdapter.primaryTextColor,
                       synthetic.tokens.settingsPrimaryTextColor)
    }

    func testInjectedRegistryLetsControllerSelectAndPersistAThirdTheme() {
        let suiteName = "TideyInterfaceThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let synthetic = TideyInterfaceThemeDefinition(
            identifier: "midnight",
            displayName: "Midnight",
            tokens: .warm)
        let registry = TideyInterfaceThemeRegistry(
            themes: [.classic, .warm, synthetic],
            fallbackIdentifier: "classic")
        let controller = TideyInterfaceThemeController(userDefaults: defaults, registry: registry)

        controller.currentThemeIdentifier = "midnight"

        XCTAssertTrue(controller.currentTheme === synthetic)
        XCTAssertEqual(controller.currentThemeIdentifier, "midnight")
        XCTAssertEqual(defaults.string(forKey: TideyInterfaceThemeController.defaultsKey), "midnight")
    }

    func testControllerCachesResolvedThemeUntilExplicitReapply() {
        let suiteName = "TideyInterfaceThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("warm", forKey: TideyInterfaceThemeController.defaultsKey)
        let controller = TideyInterfaceThemeController(userDefaults: defaults)

        defaults.set("classic", forKey: TideyInterfaceThemeController.defaultsKey)
        XCTAssertTrue(controller.currentTheme === TideyInterfaceThemeDefinition.warm)

        controller.reapplyCurrentTheme()
        XCTAssertTrue(controller.currentTheme === TideyInterfaceThemeDefinition.classic)
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

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let converted = color.usingColorSpace(.sRGB) else {
            XCTFail("Color is not convertible to sRGB")
            return 1
        }
        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(converted.redComponent) +
               0.7152 * linearized(converted.greenComponent) +
               0.0722 * linearized(converted.blueComponent)
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
