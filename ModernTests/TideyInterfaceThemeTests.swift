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

    func testWarmBrowserToolbarUsesOneExactContentRow() {
        let tokens = TideyInterfaceThemeTokens.warm
        let toolbarHeight = TideyBrowserToolbarPolicy.toolbarHeight(warmEnabled: true)

        XCTAssertEqual(toolbarHeight, 28)
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldHeight(warmEnabled: true), 22)
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldFrame(
                toolbarHeight: toolbarHeight,
                contentWidth: 500,
                warmEnabled: true),
            NSRect(x: 92, y: 3, width: 380, height: 22)
        )
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldTextRect(
                fieldBounds: NSRect(x: 0, y: 0, width: 380, height: 22),
                warmEnabled: true),
            NSRect(x: 8, y: 3, width: 364, height: 16)
        )
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.toolbarBackgroundColor(
                tokens: tokens,
                warmEnabled: true),
            tokens.rightPanelBackgroundColor
        )
        XCTAssertNotEqual(tokens.rightPanelBackgroundColor,
                          tokens.rightPanelTabStripBackgroundColor)
    }

    func testClassicBrowserToolbarGeometryAndColorRemainUnchanged() {
        let tokens = TideyInterfaceThemeTokens.classic
        let toolbarHeight = TideyBrowserToolbarPolicy.toolbarHeight(warmEnabled: false)

        XCTAssertEqual(toolbarHeight, 28)
        XCTAssertEqual(TideyBrowserToolbarPolicy.urlFieldHeight(warmEnabled: false), 22)
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldFrame(
                toolbarHeight: toolbarHeight,
                contentWidth: 500,
                warmEnabled: false),
            NSRect(x: 92, y: 3, width: 380, height: 22)
        )
        XCTAssertEqual(
            TideyBrowserToolbarPolicy.urlFieldTextRect(
                fieldBounds: NSRect(x: 0, y: 0, width: 380, height: 22),
                warmEnabled: false),
            NSRect(x: 0, y: 0, width: 380, height: 22)
        )
        assertColor(
            TideyBrowserToolbarPolicy.toolbarBackgroundColor(
                tokens: tokens,
                warmEnabled: false),
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
        assertColor(tokens.rightPanelTabStripBackgroundColor, hex: 0x100F0E)
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
        // Focused tab outline: same cream as the workspace focus edge but strong
        // enough (0.40) for its trailing fade into the separators to be visible.
        assertColor(tokens.tabSelectedOutlineColor,
                    red: 240.0 / 255.0,
                    green: 230.0 / 255.0,
                    blue: 210.0 / 255.0,
                    alpha: 0.40)
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

        // Terminal tab bar receives the same outline color; Classic gets nil.
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabOutlineColor(warmEnabled: false))
        XCTAssertEqual(TideyTerminalPalettePolicy.terminalTabOutlineColor(warmEnabled: true),
                       TideyInterfaceThemeTokens.warm.tabOutlineColor)
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabSelectedOutlineColor(warmEnabled: false))
        // Tab new-output dot shares the workspace unread accent in Warm.
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabNewOutputDotColor(warmEnabled: false))
        XCTAssertEqual(TideyTerminalPalettePolicy.terminalTabNewOutputDotColor(warmEnabled: true),
                       TideyInterfaceThemeTokens.warm.sidebarUnreadColor)
        XCTAssertEqual(TideyTerminalPalettePolicy.terminalTabSelectedOutlineColor(warmEnabled: true),
                       TideyInterfaceThemeTokens.warm.tabSelectedOutlineColor)
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
        XCTAssertEqual(TideyTerminalPalettePolicy.terminalTabSelectedFillColor(warmEnabled: true), base)
        XCTAssertNil(TideyTerminalPalettePolicy.terminalTabSelectedFillColor(warmEnabled: false))
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
        assertColor(warmColor, hex: 0x100F0E)
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
