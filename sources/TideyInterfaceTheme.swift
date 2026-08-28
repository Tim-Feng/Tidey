import AppKit

@objc enum TideyInterfaceTheme: Int {
    case classic
    case warm
}

@objcMembers
final class TideyInterfaceThemeController: NSObject {
    static let didChangeNotification = Notification.Name("TideyInterfaceThemeDidChangeNotification")
    static let defaultsKey = "TideyInterfaceTheme"
    static let supportedThemeIdentifiers = ["classic", "warm"]
    static let shared = TideyInterfaceThemeController(userDefaults: applicationUserDefaults())

    static func applicationUserDefaults() -> UserDefaults {
        iTermUserDefaults.userDefaults()
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        super.init()
    }

    var currentThemeIdentifier: String {
        get {
            Self.normalizedThemeIdentifier(userDefaults.string(forKey: Self.defaultsKey))
        }
        set {
            let normalized = Self.normalizedThemeIdentifier(newValue)
            guard normalized != currentThemeIdentifier else {
                if userDefaults.string(forKey: Self.defaultsKey) != normalized {
                    userDefaults.set(normalized, forKey: Self.defaultsKey)
                }
                return
            }
            userDefaults.set(normalized, forKey: Self.defaultsKey)
            reapplyCurrentTheme()
        }
    }

    var currentTokens: TideyInterfaceThemeTokens {
        currentThemeIdentifier == "warm" ? .warm : .classic
    }

    static func normalizedThemeIdentifier(_ storedValue: String?) -> String {
        storedValue == "warm" ? "warm" : "classic"
    }

    static func displayName(forIdentifier identifier: String) -> String {
        normalizedThemeIdentifier(identifier) == "warm" ? "Warm" : "Classic"
    }

    func reapplyCurrentTheme() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

@objcMembers
final class TideyInterfaceThemeTokens: NSObject {
    static let classic = TideyInterfaceThemeTokens(
        sidebarBackgroundColor: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
        sidebarSelectionColor: .selectedContentBackgroundColor,
        sidebarSelectionBorderColor: .clear,
        sidebarPrimaryTextColor: .white,
        sidebarSelectedPrimaryTextColor: .white,
        sidebarSecondaryTextColor: NSColor(white: 0.72, alpha: 1),
        sidebarSelectedSecondaryTextColor: NSColor(white: 1, alpha: 0.8),
        sidebarUnreadColor: .systemRed,
        sidebarIdleColor: .secondaryLabelColor,
        sidebarSelectedIdleColor: NSColor(white: 1, alpha: 0.8),
        sidebarRunningColor: .secondaryLabelColor,
        sidebarCloseColor: .tertiaryLabelColor,
        rightPanelBackgroundColor: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1),
        rightPanelTabStripBackgroundColor: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
        rightPanelActiveTabStripBackgroundColor: NSColor(srgbRed: 0.118, green: 0.126, blue: 0.155, alpha: 1),
        rightPanelInactiveTabStripBackgroundColor: NSColor(srgbRed: 0.102, green: 0.108, blue: 0.135, alpha: 1),
        rightPanelFileTreeBackgroundColor: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1),
        fileTreeTextColor: NSColor(white: 0.92, alpha: 1),
        fileTreeIconColor: NSColor(white: 0.78, alpha: 1),
        fileTreeSelectionColor: .clear,
        paneBoundaryColor: .clear,
        rightPanelSplitDividerColor: NSColor(white: 0.24, alpha: 1),
        rightPanelTabHoverColor: NSColor(white: 1, alpha: 0.06),
        rightPanelTabSelectionColor: .clear,
        rightPanelTabSelectionBorderColor: .clear,
        rightPanelTabSelectionIndicatorColor: .controlAccentColor,
        rightPanelTabSeparatorColor: NSColor(white: 0.25, alpha: 1),
        rightPanelPrimaryTextColor: .labelColor,
        rightPanelSecondaryTextColor: .secondaryLabelColor,
        rightPanelTertiaryTextColor: .tertiaryLabelColor,
        rightPanelGroupExpandedFillColor: NSColor(srgbRed: 1,
                                                   green: 177.0 / 255.0,
                                                   blue: 27.0 / 255.0,
                                                   alpha: 0.20),
        rightPanelGroupCollapsedFillColor: NSColor(srgbRed: 1,
                                                    green: 177.0 / 255.0,
                                                    blue: 27.0 / 255.0,
                                                    alpha: 0.10),
        rightPanelGroupExpandedTextColor: NSColor(srgbRed: 1,
                                                   green: 177.0 / 255.0,
                                                   blue: 27.0 / 255.0,
                                                   alpha: 1),
        rightPanelGroupCollapsedTextColor: NSColor(srgbRed: 209.0 / 255.0,
                                                    green: 152.0 / 255.0,
                                                    blue: 38.0 / 255.0,
                                                    alpha: 1),
        terminalSurroundColor: .clear,
        settingsPanelBackgroundColor: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        settingsCardBackgroundColor: NSColor(white: 1, alpha: 0.04),
        settingsCardBorderColor: NSColor(white: 1, alpha: 0.08),
        settingsDividerColor: NSColor(white: 1, alpha: 0.06),
        settingsPrimaryTextColor: NSColor(srgbRed: 0xe8 / 255.0,
                                           green: 0xe8 / 255.0,
                                           blue: 0xe8 / 255.0,
                                           alpha: 1),
        settingsSecondaryTextColor: NSColor(srgbRed: 0x88 / 255.0,
                                             green: 0x88 / 255.0,
                                             blue: 0x88 / 255.0,
                                             alpha: 1),
        hairlineColor: NSColor(white: 0.25, alpha: 1),
        usesRaisedSidebarSelection: false,
        usesRaisedRightPanelTabs: false,
        sidebarSelectionCornerRadius: 8,
        rightPanelTabCornerRadius: 0)

    // Tim's Warm constraint: every chrome base surface (workspace column, tab
    // strips, canvas surround, file tree) shares this single fill; adjacent
    // regions are separated by paneBoundaryColor lines, never by shade steps.
    private static let warmBaseSurfaceColor = NSColor(srgbRed: 0x15 / 255.0,
                                                      green: 0x14 / 255.0,
                                                      blue: 0x13 / 255.0,
                                                      alpha: 1)

    static let warm = TideyInterfaceThemeTokens(
        sidebarBackgroundColor: warmBaseSurfaceColor,
        sidebarSelectionColor: NSColor(srgbRed: 0x2F / 255.0,
                                       green: 0x2C / 255.0,
                                       blue: 0x28 / 255.0,
                                       alpha: 1),
        sidebarSelectionBorderColor: NSColor(srgbRed: 240 / 255.0,
                                             green: 230 / 255.0,
                                             blue: 210 / 255.0,
                                             alpha: 0.16),
        sidebarPrimaryTextColor: NSColor(srgbRed: 0xEA / 255.0,
                                         green: 0xE4 / 255.0,
                                         blue: 0xD4 / 255.0,
                                         alpha: 1),
        sidebarSelectedPrimaryTextColor: NSColor(srgbRed: 0xF3 / 255.0,
                                                 green: 0xEE / 255.0,
                                                 blue: 0xDF / 255.0,
                                                 alpha: 1),
        sidebarSecondaryTextColor: NSColor(srgbRed: 0xA8 / 255.0,
                                           green: 0x9F / 255.0,
                                           blue: 0x8D / 255.0,
                                           alpha: 1),
        sidebarSelectedSecondaryTextColor: NSColor(srgbRed: 0xC6 / 255.0,
                                                   green: 0xBE / 255.0,
                                                   blue: 0xAC / 255.0,
                                                   alpha: 1),
        sidebarUnreadColor: NSColor(srgbRed: 0xD1 / 255.0,
                                    green: 0x9A / 255.0,
                                    blue: 0x66 / 255.0,
                                    alpha: 1),
        sidebarIdleColor: NSColor(srgbRed: 0x6F / 255.0,
                                  green: 0x6A / 255.0,
                                  blue: 0x60 / 255.0,
                                  alpha: 1),
        sidebarSelectedIdleColor: NSColor(srgbRed: 0x8A / 255.0,
                                          green: 0x84 / 255.0,
                                          blue: 0x78 / 255.0,
                                          alpha: 1),
        sidebarRunningColor: NSColor(srgbRed: 0x7F / 255.0,
                                     green: 0xB4 / 255.0,
                                     blue: 0xA3 / 255.0,
                                     alpha: 1),
        sidebarCloseColor: NSColor(srgbRed: 0x6F / 255.0,
                                   green: 0x6A / 255.0,
                                   blue: 0x60 / 255.0,
                                   alpha: 1),
        rightPanelBackgroundColor: warmBaseSurfaceColor,
        rightPanelTabStripBackgroundColor: warmBaseSurfaceColor,
        rightPanelActiveTabStripBackgroundColor: warmBaseSurfaceColor,
        rightPanelInactiveTabStripBackgroundColor: warmBaseSurfaceColor,
        rightPanelFileTreeBackgroundColor: warmBaseSurfaceColor,
        fileTreeTextColor: NSColor(srgbRed: 0xEA / 255.0,
                                   green: 0xE4 / 255.0,
                                   blue: 0xD4 / 255.0,
                                   alpha: 1),
        fileTreeIconColor: NSColor(srgbRed: 0xA8 / 255.0,
                                   green: 0x9F / 255.0,
                                   blue: 0x8D / 255.0,
                                   alpha: 1),
        fileTreeSelectionColor: NSColor(srgbRed: 0x2F / 255.0,
                                        green: 0x2C / 255.0,
                                        blue: 0x28 / 255.0,
                                        alpha: 1),
        paneBoundaryColor: NSColor(srgbRed: 240 / 255.0,
                                   green: 230 / 255.0,
                                   blue: 210 / 255.0,
                                   alpha: 0.12),
        rightPanelSplitDividerColor: NSColor(srgbRed: 240 / 255.0,
                                             green: 230 / 255.0,
                                             blue: 210 / 255.0,
                                             alpha: 0.07),
        rightPanelTabHoverColor: NSColor(srgbRed: 0x1D / 255.0,
                                         green: 0x1C / 255.0,
                                         blue: 0x1A / 255.0,
                                         alpha: 1),
        rightPanelTabSelectionColor: NSColor(srgbRed: 0x23 / 255.0,
                                             green: 0x21 / 255.0,
                                             blue: 0x20 / 255.0,
                                             alpha: 1),
        rightPanelTabSelectionBorderColor: NSColor(srgbRed: 240 / 255.0,
                                                   green: 230 / 255.0,
                                                   blue: 210 / 255.0,
                                                   alpha: 0.07),
        rightPanelTabSelectionIndicatorColor: .clear,
        rightPanelTabSeparatorColor: NSColor(srgbRed: 240 / 255.0,
                                             green: 230 / 255.0,
                                             blue: 210 / 255.0,
                                             alpha: 0.07),
        rightPanelPrimaryTextColor: NSColor(srgbRed: 0xEA / 255.0,
                                            green: 0xE4 / 255.0,
                                            blue: 0xD4 / 255.0,
                                            alpha: 1),
        rightPanelSecondaryTextColor: NSColor(srgbRed: 0xA8 / 255.0,
                                              green: 0x9F / 255.0,
                                              blue: 0x8D / 255.0,
                                              alpha: 1),
        rightPanelTertiaryTextColor: NSColor(srgbRed: 0x6F / 255.0,
                                             green: 0x6A / 255.0,
                                             blue: 0x60 / 255.0,
                                             alpha: 1),
        rightPanelGroupExpandedFillColor: NSColor(srgbRed: 0xD1 / 255.0,
                                                  green: 0x9A / 255.0,
                                                  blue: 0x66 / 255.0,
                                                  alpha: 0.14),
        rightPanelGroupCollapsedFillColor: NSColor(srgbRed: 240 / 255.0,
                                                   green: 230 / 255.0,
                                                   blue: 210 / 255.0,
                                                   alpha: 0.06),
        rightPanelGroupExpandedTextColor: NSColor(srgbRed: 0xD1 / 255.0,
                                                  green: 0x9A / 255.0,
                                                  blue: 0x66 / 255.0,
                                                  alpha: 1),
        rightPanelGroupCollapsedTextColor: NSColor(srgbRed: 0xA8 / 255.0,
                                                   green: 0x9F / 255.0,
                                                   blue: 0x8D / 255.0,
                                                   alpha: 1),
        terminalSurroundColor: warmBaseSurfaceColor,
        settingsPanelBackgroundColor: NSColor(srgbRed: 0x15 / 255.0,
                                              green: 0x14 / 255.0,
                                              blue: 0x13 / 255.0,
                                              alpha: 1),
        settingsCardBackgroundColor: NSColor(srgbRed: 0x23 / 255.0,
                                             green: 0x21 / 255.0,
                                             blue: 0x20 / 255.0,
                                             alpha: 1),
        settingsCardBorderColor: NSColor(srgbRed: 240 / 255.0,
                                         green: 230 / 255.0,
                                         blue: 210 / 255.0,
                                         alpha: 0.07),
        settingsDividerColor: NSColor(srgbRed: 240 / 255.0,
                                      green: 230 / 255.0,
                                      blue: 210 / 255.0,
                                      alpha: 0.07),
        settingsPrimaryTextColor: NSColor(srgbRed: 0xEA / 255.0,
                                          green: 0xE4 / 255.0,
                                          blue: 0xD4 / 255.0,
                                          alpha: 1),
        settingsSecondaryTextColor: NSColor(srgbRed: 0xA8 / 255.0,
                                            green: 0x9F / 255.0,
                                            blue: 0x8D / 255.0,
                                            alpha: 1),
        hairlineColor: NSColor(srgbRed: 240 / 255.0,
                               green: 230 / 255.0,
                               blue: 210 / 255.0,
                               alpha: 0.07),
        usesRaisedSidebarSelection: true,
        usesRaisedRightPanelTabs: true,
        sidebarSelectionCornerRadius: 8,
        rightPanelTabCornerRadius: 8)

    let sidebarBackgroundColor: NSColor
    let sidebarSelectionColor: NSColor
    let sidebarSelectionBorderColor: NSColor
    let sidebarPrimaryTextColor: NSColor
    let sidebarSelectedPrimaryTextColor: NSColor
    let sidebarSecondaryTextColor: NSColor
    let sidebarSelectedSecondaryTextColor: NSColor
    let sidebarUnreadColor: NSColor
    let sidebarIdleColor: NSColor
    let sidebarSelectedIdleColor: NSColor
    let sidebarRunningColor: NSColor
    let sidebarCloseColor: NSColor

    let rightPanelBackgroundColor: NSColor
    let rightPanelTabStripBackgroundColor: NSColor
    let rightPanelActiveTabStripBackgroundColor: NSColor
    let rightPanelInactiveTabStripBackgroundColor: NSColor
    let rightPanelFileTreeBackgroundColor: NSColor
    let fileTreeTextColor: NSColor
    let fileTreeIconColor: NSColor
    let fileTreeSelectionColor: NSColor
    let paneBoundaryColor: NSColor
    let rightPanelSplitDividerColor: NSColor
    let rightPanelTabHoverColor: NSColor
    let rightPanelTabSelectionColor: NSColor
    let rightPanelTabSelectionBorderColor: NSColor
    let rightPanelTabSelectionIndicatorColor: NSColor
    let rightPanelTabSeparatorColor: NSColor
    let rightPanelPrimaryTextColor: NSColor
    let rightPanelSecondaryTextColor: NSColor
    let rightPanelTertiaryTextColor: NSColor
    let rightPanelGroupExpandedFillColor: NSColor
    let rightPanelGroupCollapsedFillColor: NSColor
    let rightPanelGroupExpandedTextColor: NSColor
    let rightPanelGroupCollapsedTextColor: NSColor

    let terminalSurroundColor: NSColor
    let settingsPanelBackgroundColor: NSColor
    let settingsCardBackgroundColor: NSColor
    let settingsCardBorderColor: NSColor
    let settingsDividerColor: NSColor
    let settingsPrimaryTextColor: NSColor
    let settingsSecondaryTextColor: NSColor
    let hairlineColor: NSColor

    let usesRaisedSidebarSelection: Bool
    let usesRaisedRightPanelTabs: Bool
    let sidebarSelectionCornerRadius: CGFloat
    let rightPanelTabCornerRadius: CGFloat

    private init(sidebarBackgroundColor: NSColor,
                 sidebarSelectionColor: NSColor,
                 sidebarSelectionBorderColor: NSColor,
                 sidebarPrimaryTextColor: NSColor,
                 sidebarSelectedPrimaryTextColor: NSColor,
                 sidebarSecondaryTextColor: NSColor,
                 sidebarSelectedSecondaryTextColor: NSColor,
                 sidebarUnreadColor: NSColor,
                 sidebarIdleColor: NSColor,
                 sidebarSelectedIdleColor: NSColor,
                 sidebarRunningColor: NSColor,
                 sidebarCloseColor: NSColor,
                 rightPanelBackgroundColor: NSColor,
                 rightPanelTabStripBackgroundColor: NSColor,
                 rightPanelActiveTabStripBackgroundColor: NSColor,
                 rightPanelInactiveTabStripBackgroundColor: NSColor,
                 rightPanelFileTreeBackgroundColor: NSColor,
                 fileTreeTextColor: NSColor,
                 fileTreeIconColor: NSColor,
                 fileTreeSelectionColor: NSColor,
                 paneBoundaryColor: NSColor,
                 rightPanelSplitDividerColor: NSColor,
                 rightPanelTabHoverColor: NSColor,
                 rightPanelTabSelectionColor: NSColor,
                 rightPanelTabSelectionBorderColor: NSColor,
                 rightPanelTabSelectionIndicatorColor: NSColor,
                 rightPanelTabSeparatorColor: NSColor,
                 rightPanelPrimaryTextColor: NSColor,
                 rightPanelSecondaryTextColor: NSColor,
                 rightPanelTertiaryTextColor: NSColor,
                 rightPanelGroupExpandedFillColor: NSColor,
                 rightPanelGroupCollapsedFillColor: NSColor,
                 rightPanelGroupExpandedTextColor: NSColor,
                 rightPanelGroupCollapsedTextColor: NSColor,
                 terminalSurroundColor: NSColor,
                 settingsPanelBackgroundColor: NSColor,
                 settingsCardBackgroundColor: NSColor,
                 settingsCardBorderColor: NSColor,
                 settingsDividerColor: NSColor,
                 settingsPrimaryTextColor: NSColor,
                 settingsSecondaryTextColor: NSColor,
                 hairlineColor: NSColor,
                 usesRaisedSidebarSelection: Bool,
                 usesRaisedRightPanelTabs: Bool,
                 sidebarSelectionCornerRadius: CGFloat,
                 rightPanelTabCornerRadius: CGFloat) {
        self.sidebarBackgroundColor = sidebarBackgroundColor
        self.sidebarSelectionColor = sidebarSelectionColor
        self.sidebarSelectionBorderColor = sidebarSelectionBorderColor
        self.sidebarPrimaryTextColor = sidebarPrimaryTextColor
        self.sidebarSelectedPrimaryTextColor = sidebarSelectedPrimaryTextColor
        self.sidebarSecondaryTextColor = sidebarSecondaryTextColor
        self.sidebarSelectedSecondaryTextColor = sidebarSelectedSecondaryTextColor
        self.sidebarUnreadColor = sidebarUnreadColor
        self.sidebarIdleColor = sidebarIdleColor
        self.sidebarSelectedIdleColor = sidebarSelectedIdleColor
        self.sidebarRunningColor = sidebarRunningColor
        self.sidebarCloseColor = sidebarCloseColor
        self.rightPanelBackgroundColor = rightPanelBackgroundColor
        self.rightPanelTabStripBackgroundColor = rightPanelTabStripBackgroundColor
        self.rightPanelActiveTabStripBackgroundColor = rightPanelActiveTabStripBackgroundColor
        self.rightPanelInactiveTabStripBackgroundColor = rightPanelInactiveTabStripBackgroundColor
        self.rightPanelFileTreeBackgroundColor = rightPanelFileTreeBackgroundColor
        self.fileTreeTextColor = fileTreeTextColor
        self.fileTreeIconColor = fileTreeIconColor
        self.fileTreeSelectionColor = fileTreeSelectionColor
        self.paneBoundaryColor = paneBoundaryColor
        self.rightPanelSplitDividerColor = rightPanelSplitDividerColor
        self.rightPanelTabHoverColor = rightPanelTabHoverColor
        self.rightPanelTabSelectionColor = rightPanelTabSelectionColor
        self.rightPanelTabSelectionBorderColor = rightPanelTabSelectionBorderColor
        self.rightPanelTabSelectionIndicatorColor = rightPanelTabSelectionIndicatorColor
        self.rightPanelTabSeparatorColor = rightPanelTabSeparatorColor
        self.rightPanelPrimaryTextColor = rightPanelPrimaryTextColor
        self.rightPanelSecondaryTextColor = rightPanelSecondaryTextColor
        self.rightPanelTertiaryTextColor = rightPanelTertiaryTextColor
        self.rightPanelGroupExpandedFillColor = rightPanelGroupExpandedFillColor
        self.rightPanelGroupCollapsedFillColor = rightPanelGroupCollapsedFillColor
        self.rightPanelGroupExpandedTextColor = rightPanelGroupExpandedTextColor
        self.rightPanelGroupCollapsedTextColor = rightPanelGroupCollapsedTextColor
        self.terminalSurroundColor = terminalSurroundColor
        self.settingsPanelBackgroundColor = settingsPanelBackgroundColor
        self.settingsCardBackgroundColor = settingsCardBackgroundColor
        self.settingsCardBorderColor = settingsCardBorderColor
        self.settingsDividerColor = settingsDividerColor
        self.settingsPrimaryTextColor = settingsPrimaryTextColor
        self.settingsSecondaryTextColor = settingsSecondaryTextColor
        self.hairlineColor = hairlineColor
        self.usesRaisedSidebarSelection = usesRaisedSidebarSelection
        self.usesRaisedRightPanelTabs = usesRaisedRightPanelTabs
        self.sidebarSelectionCornerRadius = sidebarSelectionCornerRadius
        self.rightPanelTabCornerRadius = rightPanelTabCornerRadius
        super.init()
    }
}

@objcMembers
final class TideyTerminalPalettePolicy: NSObject {
    static let warmTabUnderlineColor = color(hex: 0x7AA89F)

    static let warmColorTable: [NSNumber: NSColor] = {
        let namedColors: [(Int32, Int)] = [
            (kColorMapBackground, 0x151413),
            (kColorMapForeground, 0xEAE4D4),
            (kColorMapBold, 0xF3EEDF),
            (kColorMapCursor, 0x7FB4A3),
            (kColorMapCursorText, 0x151413),
            (kColorMapSelection, 0x2F2C28),
            (kColorMapSelectedText, 0xF3EEDF),
            (kColorMapLink, 0x7E9CB8),
        ]
        let ansiHexColors = [
            0x24211E, 0xC97A6D, 0x9BB584, 0xD9B26C,
            0x7E9CB8, 0xB693A5, 0x7AA89F, 0xD5CDBB,
            0x57524A, 0xE09186, 0xB4CC9E, 0xE8C787,
            0x97B4CE, 0xCBA9BB, 0x93C0B6, 0xF3EEDF,
        ]
        let ansiColors = ansiHexColors.enumerated().map { index, hex in
            (kColorMap8bitBase + Int32(index), hex)
        }

        return Dictionary(uniqueKeysWithValues: (namedColors + ansiColors).map { key, hex in
            (NSNumber(value: key), color(hex: hex))
        })
    }()

    @objc(colorTableByApplyingWarmPaletteTo:factoryColorTable:warmEnabled:)
    static func colorTable(byApplyingWarmPaletteTo colorTable: [NSNumber: NSColor],
                           factoryColorTable _: [NSNumber: NSColor],
                           warmEnabled: Bool) -> [NSNumber: NSColor] {
        guard warmEnabled else {
            return colorTable
        }

        var result = colorTable
        warmColorTable.forEach { result[$0.key] = $0.value }
        return result
    }

    @objc(terminalTabUnderlineColorWithWarmEnabled:)
    static func terminalTabUnderlineColor(warmEnabled: Bool) -> NSColor? {
        warmEnabled ? warmTabUnderlineColor : nil
    }

    private static func color(hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }
}
