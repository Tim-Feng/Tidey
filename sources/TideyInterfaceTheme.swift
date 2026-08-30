import AppKit

@objcMembers
final class TideyInterfaceThemeController: NSObject {
    static let didChangeNotification = Notification.Name("TideyInterfaceThemeDidChangeNotification")
    static let defaultsKey = "TideyInterfaceTheme"
    static let shared = TideyInterfaceThemeController(userDefaults: applicationUserDefaults())

    static var availableThemes: [TideyInterfaceThemeDefinition] {
        TideyInterfaceThemeRegistry.shared.availableThemes
    }

    static var supportedThemeIdentifiers: [String] {
        TideyInterfaceThemeRegistry.shared.supportedThemeIdentifiers
    }

    static func applicationUserDefaults() -> UserDefaults {
        iTermUserDefaults.userDefaults()
    }

    private let userDefaults: UserDefaults
    private let registry: TideyInterfaceThemeRegistry
    private var selectedTheme: TideyInterfaceThemeDefinition

    @objc(initWithUserDefaults:)
    convenience init(userDefaults: UserDefaults) {
        self.init(userDefaults: userDefaults, registry: .shared)
    }

    @nonobjc
    init(userDefaults: UserDefaults, registry: TideyInterfaceThemeRegistry) {
        self.userDefaults = userDefaults
        self.registry = registry
        self.selectedTheme = registry.theme(forIdentifier: userDefaults.string(forKey: Self.defaultsKey))
        super.init()
    }

    var currentThemeIdentifier: String {
        get {
            selectedTheme.identifier
        }
        set {
            let theme = registry.theme(forIdentifier: newValue)
            guard theme.identifier != selectedTheme.identifier else {
                if userDefaults.string(forKey: Self.defaultsKey) != theme.identifier {
                    userDefaults.set(theme.identifier, forKey: Self.defaultsKey)
                }
                return
            }
            selectedTheme = theme
            userDefaults.set(theme.identifier, forKey: Self.defaultsKey)
            reapplyCurrentTheme()
        }
    }

    var currentTheme: TideyInterfaceThemeDefinition {
        selectedTheme
    }

    var currentTokens: TideyInterfaceThemeTokens {
        selectedTheme.tokens
    }

    static func normalizedThemeIdentifier(_ storedValue: String?) -> String {
        TideyInterfaceThemeRegistry.shared.normalizedThemeIdentifier(storedValue)
    }

    static func displayName(forIdentifier identifier: String) -> String {
        TideyInterfaceThemeRegistry.shared.theme(forIdentifier: identifier).displayName
    }

    func reapplyCurrentTheme() {
        selectedTheme = registry.theme(forIdentifier: userDefaults.string(forKey: Self.defaultsKey))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

@objcMembers
final class TideyInterfaceThemeTokens: NSObject {
    // Classic follows the same surface contract as Warm: chrome canvases use
    // one base fill and separators carry the pane hierarchy. This value also
    // matches Classic's historical Monaco canvas.
    private static let classicBaseSurfaceColor = NSColor(srgbRed: 0x16 / 255.0,
                                                         green: 0x18 / 255.0,
                                                         blue: 0x1D / 255.0,
                                                         alpha: 1)

    // One darker desk behind every paper-tab strip.
    private static let classicTabStripDeskColor = NSColor(srgbRed: 0x11 / 255.0,
                                                          green: 0x13 / 255.0,
                                                          blue: 0x18 / 255.0,
                                                          alpha: 1)

    static let classic = TideyInterfaceThemeTokens(
        baseSurfaceColor: classicBaseSurfaceColor,
        tabDeskColor: classicTabStripDeskColor,
        sidebarSelectionColor: color(hex: 0x1F2A3E),
        sidebarSelectionBorderColor: color(hex: 0x5FA0F0, alpha: 0.35),
        sidebarPrimaryTextColor: .white,
        sidebarSelectedPrimaryTextColor: color(hex: 0xF2F5FA),
        sidebarSecondaryTextColor: NSColor(white: 0.72, alpha: 1),
        sidebarSelectedSecondaryTextColor: color(hex: 0xB7C3D6),
        sidebarUnreadColor: .systemRed,
        sidebarIdleColor: .secondaryLabelColor,
        sidebarSelectedIdleColor: color(hex: 0x8E9AAE),
        sidebarRunningColor: .secondaryLabelColor,
        sidebarCloseColor: .tertiaryLabelColor,
        fileTreeTextColor: NSColor(white: 0.92, alpha: 1),
        fileTreeIconColor: NSColor(white: 0.78, alpha: 1),
        // Classic palette for the shared modern components: cool white
        // hairlines/outlines, dark blue-charcoal selection cards.
        fileTreeSelectionColor: color(hex: 0x1F2A3E),
        paneBoundaryColor: NSColor(white: 1, alpha: 0.14),
        paneResizerPullBarColor: NSColor(white: 1, alpha: 0.08),
        tabOutlineColor: NSColor(white: 1, alpha: 0.10),
        tabSelectedOutlineColor: NSColor(white: 1, alpha: 0.40),
        rightPanelSplitDividerColor: NSColor(white: 0.24, alpha: 1),
        rightPanelTabHoverColor: NSColor(white: 1, alpha: 0.06),
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
        sidebarPinColor: NSColor(white: 0.90, alpha: 1),
        sidebarUnreadTitleColor: .controlAccentColor,
        sidebarSelectedUnreadTitleColor: .white,
        browserToolbarBackgroundColor: NSColor(white: 0.15, alpha: 1),
        browserToolbarControlColor: .secondaryLabelColor,
        usesHostTitlebarTextColors: true)

    // Tim's Warm constraint: every chrome base surface (workspace column, tab
    // strips, canvas surround, file tree) shares this single fill; adjacent
    // regions are separated by paneBoundaryColor lines, never by shade steps.
    private static let warmBaseSurfaceColor = NSColor(srgbRed: 0x15 / 255.0,
                                                      green: 0x14 / 255.0,
                                                      blue: 0x13 / 255.0,
                                                      alpha: 1)

    // Tim 2026-08-29: the tab strips are the "desk" behind the paper tabs — one
    // step darker than the base surface so the focused tab (filled with the base
    // canvas color) reads as the front sheet.
    private static let warmTabStripDeskColor = NSColor(srgbRed: 0x10 / 255.0,
                                                       green: 0x0F / 255.0,
                                                       blue: 0x0E / 255.0,
                                                       alpha: 1)

    // Shared Warm accent: terminal tab underline, editor tab indicator, running state.
    static let warmSeaglassColor = NSColor(srgbRed: 0x7A / 255.0,
                                           green: 0xA8 / 255.0,
                                           blue: 0x9F / 255.0,
                                           alpha: 1)

    static let warm = TideyInterfaceThemeTokens(
        baseSurfaceColor: warmBaseSurfaceColor,
        tabDeskColor: warmTabStripDeskColor,
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
        paneResizerPullBarColor: NSColor(srgbRed: 240 / 255.0,
                                         green: 230 / 255.0,
                                         blue: 210 / 255.0,
                                         alpha: 0.06),
        tabOutlineColor: NSColor(srgbRed: 240 / 255.0,
                                 green: 230 / 255.0,
                                 blue: 210 / 255.0,
                                 alpha: 0.08),
        // Focused tab outline: cream, strong enough that its trailing fade
        // into the 0.12/0.08 separators is visible (0.16 was within 8 levels
        // of the separator and could not carry a gradient).
        tabSelectedOutlineColor: NSColor(srgbRed: 240 / 255.0,
                                         green: 230 / 255.0,
                                         blue: 210 / 255.0,
                                         alpha: 0.40),
        rightPanelSplitDividerColor: NSColor(srgbRed: 240 / 255.0,
                                             green: 230 / 255.0,
                                             blue: 210 / 255.0,
                                             alpha: 0.07),
        rightPanelTabHoverColor: NSColor(srgbRed: 0x1D / 255.0,
                                         green: 0x1C / 255.0,
                                         blue: 0x1A / 255.0,
                                         alpha: 1),
        rightPanelTabSelectionIndicatorColor: warmSeaglassColor,
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
                               alpha: 0.07))

    private static func color(hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: alpha)
    }

    // 落櫻繽紛: a low-fatigue rose-charcoal canvas. Pink is reserved for
    // focus and attention semantics while running remains distinct in green.
    static let sakura = TideyInterfaceThemeTokens(
        baseSurfaceColor: color(hex: 0x161214),
        tabDeskColor: color(hex: 0x110E10),
        sidebarSelectionColor: color(hex: 0x2A1F25),
        sidebarSelectionBorderColor: color(hex: 0xE8A0B4, alpha: 0.35),
        sidebarPrimaryTextColor: color(hex: 0xEFE6EA),
        sidebarSelectedPrimaryTextColor: color(hex: 0xF8F2F5),
        sidebarSecondaryTextColor: color(hex: 0xB8A8B0),
        sidebarSelectedSecondaryTextColor: color(hex: 0xD3C6CD),
        sidebarUnreadColor: color(hex: 0xEE9AB0),
        sidebarIdleColor: color(hex: 0x7E6F78),
        sidebarSelectedIdleColor: color(hex: 0x998A93),
        sidebarRunningColor: color(hex: 0x9CC39B),
        sidebarCloseColor: color(hex: 0x7E6F78),
        fileTreeTextColor: color(hex: 0xEFE6EA),
        fileTreeIconColor: color(hex: 0xB8A8B0),
        fileTreeSelectionColor: color(hex: 0x2A1F25),
        paneBoundaryColor: color(hex: 0xEFE6EA, alpha: 0.12),
        paneResizerPullBarColor: color(hex: 0xEFE6EA, alpha: 0.06),
        tabOutlineColor: color(hex: 0xEFE6EA, alpha: 0.08),
        tabSelectedOutlineColor: color(hex: 0xE8A0B4, alpha: 0.45),
        rightPanelSplitDividerColor: color(hex: 0xEFE6EA, alpha: 0.07),
        rightPanelTabHoverColor: color(hex: 0x201A1E),
        rightPanelTabSelectionIndicatorColor: color(hex: 0xE8A0B4),
        rightPanelTabSeparatorColor: color(hex: 0xEFE6EA, alpha: 0.07),
        rightPanelPrimaryTextColor: color(hex: 0xEFE6EA),
        rightPanelSecondaryTextColor: color(hex: 0xB8A8B0),
        rightPanelTertiaryTextColor: color(hex: 0x7E6F78),
        rightPanelGroupExpandedFillColor: color(hex: 0xE8A0B4, alpha: 0.14),
        rightPanelGroupCollapsedFillColor: color(hex: 0xEFE6EA, alpha: 0.06),
        rightPanelGroupExpandedTextColor: color(hex: 0xE8A0B4),
        rightPanelGroupCollapsedTextColor: color(hex: 0xB8A8B0),
        settingsPanelBackgroundColor: color(hex: 0x161214),
        settingsCardBackgroundColor: color(hex: 0x241C21),
        settingsCardBorderColor: color(hex: 0xEFE6EA, alpha: 0.07),
        settingsDividerColor: color(hex: 0xEFE6EA, alpha: 0.07),
        settingsPrimaryTextColor: color(hex: 0xEFE6EA),
        settingsSecondaryTextColor: color(hex: 0xB8A8B0),
        hairlineColor: color(hex: 0xEFE6EA, alpha: 0.07))

    // Surface component. All large chrome canvases and all paper-tab desks
    // derive from these two values; callers cannot configure them separately.
    let baseSurfaceColor: NSColor
    let tabDeskColor: NSColor
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
    let sidebarPinColor: NSColor
    let sidebarUnreadTitleColor: NSColor
    let sidebarSelectedUnreadTitleColor: NSColor

    let rightPanelBackgroundColor: NSColor
    let rightPanelTabStripBackgroundColor: NSColor
    let rightPanelActiveTabStripBackgroundColor: NSColor
    let rightPanelInactiveTabStripBackgroundColor: NSColor
    let rightPanelFileTreeBackgroundColor: NSColor
    let fileTreeTextColor: NSColor
    let fileTreeIconColor: NSColor
    let fileTreeSelectionColor: NSColor
    let paneBoundaryColor: NSColor
    let paneResizerPullBarColor: NSColor
    let tabOutlineColor: NSColor
    let tabSelectedOutlineColor: NSColor
    let rightPanelSplitDividerColor: NSColor
    let rightPanelTabHoverColor: NSColor
    let rightPanelTabSelectionIndicatorColor: NSColor
    let rightPanelTabSeparatorColor: NSColor
    let rightPanelPrimaryTextColor: NSColor
    let rightPanelSecondaryTextColor: NSColor
    let rightPanelTertiaryTextColor: NSColor
    let rightPanelGroupExpandedFillColor: NSColor
    let rightPanelGroupCollapsedFillColor: NSColor
    let rightPanelGroupExpandedTextColor: NSColor
    let rightPanelGroupCollapsedTextColor: NSColor
    let browserToolbarBackgroundColor: NSColor
    let browserToolbarControlColor: NSColor

    let terminalSurroundColor: NSColor
    let settingsPanelBackgroundColor: NSColor
    let settingsCardBackgroundColor: NSColor
    let settingsCardBorderColor: NSColor
    let settingsDividerColor: NSColor
    let settingsPrimaryTextColor: NSColor
    let settingsSecondaryTextColor: NSColor
    let hairlineColor: NSColor
    let usesHostTitlebarTextColors: Bool

    @nonobjc
    init(baseSurfaceColor: NSColor,
                 tabDeskColor: NSColor,
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
                 fileTreeTextColor: NSColor,
                 fileTreeIconColor: NSColor,
                 fileTreeSelectionColor: NSColor,
                 paneBoundaryColor: NSColor,
                 paneResizerPullBarColor: NSColor,
                 tabOutlineColor: NSColor,
                 tabSelectedOutlineColor: NSColor,
                 rightPanelSplitDividerColor: NSColor,
                 rightPanelTabHoverColor: NSColor,
                 rightPanelTabSelectionIndicatorColor: NSColor,
                 rightPanelTabSeparatorColor: NSColor,
                 rightPanelPrimaryTextColor: NSColor,
                 rightPanelSecondaryTextColor: NSColor,
                 rightPanelTertiaryTextColor: NSColor,
                 rightPanelGroupExpandedFillColor: NSColor,
                 rightPanelGroupCollapsedFillColor: NSColor,
                 rightPanelGroupExpandedTextColor: NSColor,
                 rightPanelGroupCollapsedTextColor: NSColor,
                 settingsPanelBackgroundColor: NSColor,
                 settingsCardBackgroundColor: NSColor,
                 settingsCardBorderColor: NSColor,
                 settingsDividerColor: NSColor,
                 settingsPrimaryTextColor: NSColor,
                 settingsSecondaryTextColor: NSColor,
                 hairlineColor: NSColor,
                 sidebarPinColor: NSColor? = nil,
                 sidebarUnreadTitleColor: NSColor? = nil,
                 sidebarSelectedUnreadTitleColor: NSColor? = nil,
                 browserToolbarBackgroundColor: NSColor? = nil,
                 browserToolbarControlColor: NSColor? = nil,
                 usesHostTitlebarTextColors: Bool = false) {
        self.baseSurfaceColor = baseSurfaceColor
        self.tabDeskColor = tabDeskColor
        self.sidebarBackgroundColor = baseSurfaceColor
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
        self.sidebarPinColor = sidebarPinColor ?? sidebarSecondaryTextColor
        self.sidebarUnreadTitleColor = sidebarUnreadTitleColor ?? sidebarUnreadColor
        self.sidebarSelectedUnreadTitleColor = sidebarSelectedUnreadTitleColor ?? sidebarUnreadColor
        self.rightPanelBackgroundColor = baseSurfaceColor
        self.rightPanelTabStripBackgroundColor = tabDeskColor
        self.rightPanelActiveTabStripBackgroundColor = tabDeskColor
        self.rightPanelInactiveTabStripBackgroundColor = tabDeskColor
        self.rightPanelFileTreeBackgroundColor = baseSurfaceColor
        self.fileTreeTextColor = fileTreeTextColor
        self.fileTreeIconColor = fileTreeIconColor
        self.fileTreeSelectionColor = fileTreeSelectionColor
        self.paneBoundaryColor = paneBoundaryColor
        self.paneResizerPullBarColor = paneResizerPullBarColor
        self.tabOutlineColor = tabOutlineColor
        self.tabSelectedOutlineColor = tabSelectedOutlineColor
        self.rightPanelSplitDividerColor = rightPanelSplitDividerColor
        self.rightPanelTabHoverColor = rightPanelTabHoverColor
        self.rightPanelTabSelectionIndicatorColor = rightPanelTabSelectionIndicatorColor
        self.rightPanelTabSeparatorColor = rightPanelTabSeparatorColor
        self.rightPanelPrimaryTextColor = rightPanelPrimaryTextColor
        self.rightPanelSecondaryTextColor = rightPanelSecondaryTextColor
        self.rightPanelTertiaryTextColor = rightPanelTertiaryTextColor
        self.rightPanelGroupExpandedFillColor = rightPanelGroupExpandedFillColor
        self.rightPanelGroupCollapsedFillColor = rightPanelGroupCollapsedFillColor
        self.rightPanelGroupExpandedTextColor = rightPanelGroupExpandedTextColor
        self.rightPanelGroupCollapsedTextColor = rightPanelGroupCollapsedTextColor
        self.browserToolbarBackgroundColor = browserToolbarBackgroundColor ?? baseSurfaceColor
        self.browserToolbarControlColor = browserToolbarControlColor ?? rightPanelTertiaryTextColor
        self.terminalSurroundColor = baseSurfaceColor
        self.settingsPanelBackgroundColor = settingsPanelBackgroundColor
        self.settingsCardBackgroundColor = settingsCardBackgroundColor
        self.settingsCardBorderColor = settingsCardBorderColor
        self.settingsDividerColor = settingsDividerColor
        self.settingsPrimaryTextColor = settingsPrimaryTextColor
        self.settingsSecondaryTextColor = settingsSecondaryTextColor
        self.hairlineColor = hairlineColor
        self.usesHostTitlebarTextColors = usesHostTitlebarTextColors
        super.init()
    }
}

@objcMembers
final class TideyTerminalThemeAdapter: NSObject {
    let tokens: TideyInterfaceThemeTokens
    let colorOverrides: [NSNumber: NSColor]
    let terminalTabUnderlineColor: NSColor?
    let terminalTabNewOutputDotColor: NSColor?

    static let warmColorOverrides: [NSNumber: NSColor] = {
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

    static let sakuraColorOverrides: [NSNumber: NSColor] = {
        let namedColors: [(Int32, Int)] = [
            (kColorMapBackground, 0x161214),
            (kColorMapForeground, 0xEFE6EA),
            (kColorMapBold, 0xF8F2F5),
            (kColorMapCursor, 0xE8A0B4),
            (kColorMapCursorText, 0x161214),
            (kColorMapSelection, 0x2A1F25),
            (kColorMapSelectedText, 0xF8F2F5),
            (kColorMapLink, 0x8FB0D0),
        ]
        let ansiHexColors = [
            0x262024, 0xD97A85, 0x9CC39B, 0xD9B27A,
            0x8FA8CC, 0xD9A0C4, 0x8FBFB8, 0xD8CDD3,
            0x5C4F57, 0xE89AA3, 0xB5D5B4, 0xE8C795,
            0xA9BEDB, 0xE8B9D6, 0xA8D2CB, 0xF8F2F5,
        ]
        let ansiColors = ansiHexColors.enumerated().map { index, hex in
            (kColorMap8bitBase + Int32(index), hex)
        }

        return Dictionary(uniqueKeysWithValues: (namedColors + ansiColors).map { key, hex in
            (NSNumber(value: key), color(hex: hex))
        })
    }()

    @nonobjc
    init(tokens: TideyInterfaceThemeTokens,
         colorOverrides: [NSNumber: NSColor],
         terminalTabUnderlineColor: NSColor?,
         terminalTabNewOutputDotColor: NSColor?) {
        self.tokens = tokens
        self.colorOverrides = colorOverrides
        self.terminalTabUnderlineColor = terminalTabUnderlineColor
        self.terminalTabNewOutputDotColor = terminalTabNewOutputDotColor
        super.init()
    }

    @nonobjc
    static func themed(tokens: TideyInterfaceThemeTokens,
                       colorOverrides: [NSNumber: NSColor] = [:]) -> TideyTerminalThemeAdapter {
        TideyTerminalThemeAdapter(tokens: tokens,
                                  colorOverrides: colorOverrides,
                                  terminalTabUnderlineColor: tokens.rightPanelTabSelectionIndicatorColor,
                                  terminalTabNewOutputDotColor: tokens.sidebarUnreadColor)
    }

    @nonobjc
    static func profileCompatible(tokens: TideyInterfaceThemeTokens) -> TideyTerminalThemeAdapter {
        TideyTerminalThemeAdapter(tokens: tokens,
                                  colorOverrides: [:],
                                  terminalTabUnderlineColor: nil,
                                  terminalTabNewOutputDotColor: nil)
    }

    @objc(colorTableByApplyingTo:)
    func colorTable(byApplyingTo colorTable: [NSNumber: NSColor]) -> [NSNumber: NSColor] {
        var result = colorTable
        // Profile-compatible themes supply no overrides, so their render table
        // remains equivalent to the active terminal profile.
        colorOverrides.forEach { result[$0.key] = $0.value }
        return result
    }

    var terminalTabOutlineColor: NSColor? {
        tokens.tabOutlineColor
    }

    var terminalTabSelectedFillColor: NSColor? {
        tokens.rightPanelBackgroundColor
    }

    var terminalTabSelectedOutlineColor: NSColor? {
        tokens.tabSelectedOutlineColor
    }

    var terminalTabStripBackgroundColor: NSColor {
        tokens.rightPanelTabStripBackgroundColor
    }

    private static func color(hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }
}

@objcMembers
final class TideyEditorCanvasThemeAdapter: NSObject {
    let monacoThemeName: String
    let tokens: TideyInterfaceThemeTokens
    let terminalAdapter: TideyTerminalThemeAdapter
    let usesTerminalPaletteRules: Bool

    @nonobjc
    init(identifier: String,
         tokens: TideyInterfaceThemeTokens,
         terminalAdapter: TideyTerminalThemeAdapter,
         usesTerminalPaletteRules: Bool) {
        self.monacoThemeName = "tidey-\(identifier)"
        self.tokens = tokens
        self.terminalAdapter = terminalAdapter
        self.usesTerminalPaletteRules = usesTerminalPaletteRules
        super.init()
    }

    var pageBackgroundHex: String {
        Self.hexString(for: tokens.rightPanelBackgroundColor)
    }

    var themeDefinitionScript: String {
        "monaco.editor.defineTheme('\(monacoThemeName)', \(themeDefinitionJSON));"
    }

    @objc(hexStringForColor:)
    static func hexString(for color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    private var themeDefinitionJSON: String {
        guard usesTerminalPaletteRules else {
            let base = Self.hexString(for: tokens.baseSurfaceColor)
            return "{\"base\":\"vs-dark\",\"inherit\":true,\"rules\":[],\"colors\":{\"editor.background\":\"\(base)\",\"editorGutter.background\":\"\(base)\",\"minimap.background\":\"\(base)\"}}"
        }
        let palette = terminalAdapter.colorOverrides
        func ansi(_ index: Int32) -> String {
            Self.hexString(for: palette[NSNumber(value: kColorMap8bitBase + index)] ?? tokens.rightPanelPrimaryTextColor)
        }
        let base = Self.hexString(for: tokens.rightPanelBackgroundColor)
        let text = Self.hexString(for: tokens.rightPanelPrimaryTextColor)
        let secondary = Self.hexString(for: tokens.rightPanelSecondaryTextColor)
        let tertiary = Self.hexString(for: tokens.rightPanelTertiaryTextColor)
        let selection = Self.hexString(for: tokens.sidebarSelectionColor)
        let hover = Self.hexString(for: tokens.rightPanelTabHoverColor)
        let raised = Self.hexString(for: tokens.settingsCardBackgroundColor)
        let accent = Self.hexString(for: tokens.rightPanelTabSelectionIndicatorColor)
        let cursor = Self.hexString(for: palette[NSNumber(value: kColorMapCursor)] ?? tokens.rightPanelTabSelectionIndicatorColor)
        let colors: [(String, String)] = [
            ("editor.background", base),
            ("editor.foreground", text),
            ("editorGutter.background", base),
            ("editorLineNumber.foreground", tertiary),
            ("editorLineNumber.activeForeground", secondary),
            ("editorCursor.foreground", cursor),
            ("editor.selectionBackground", selection),
            ("editor.inactiveSelectionBackground", ansi(0)),
            ("editor.lineHighlightBackground", hover),
            ("editor.lineHighlightBorder", hover),
            ("editorIndentGuide.background", ansi(0)),
            ("editorIndentGuide.activeBackground", ansi(8)),
            ("editorBracketMatch.background", hover),
            ("editorBracketMatch.border", accent),
            ("editorWidget.background", raised),
            ("editorWidget.border", raised),
            ("editorSuggestWidget.background", raised),
            ("editorHoverWidget.background", raised),
            ("input.background", base),
            ("scrollbarSlider.background", ansi(8) + "80"),
            ("scrollbarSlider.hoverBackground", ansi(8) + "b0"),
            ("scrollbarSlider.activeBackground", ansi(8) + "b0"),
            ("editorLink.activeForeground", accent),
            ("minimap.background", base),
        ]
        let rules: [(String, String)] = [
            ("comment", tertiary),
            ("keyword", ansi(4)),
            ("string", ansi(2)),
            ("number", ansi(3)),
            ("type", ansi(6)),
            ("variable", text),
            ("delimiter", secondary),
            ("operator", secondary),
            ("tag", ansi(1)),
            ("attribute.name", ansi(3)),
        ]
        let colorEntries = colors.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",")
        let ruleEntries = rules.map { "{\"token\":\"\($0.0)\",\"foreground\":\"\($0.1.dropFirst())\"}" }.joined(separator: ",")
        return "{\"base\":\"vs-dark\",\"inherit\":true,\"rules\":[\(ruleEntries)],\"colors\":{\(colorEntries)}}"
    }
}

@objcMembers
final class TideyStatusSemanticsThemeAdapter: NSObject {
    let tokens: TideyInterfaceThemeTokens
    let usesSemanticStatusColors: Bool

    @nonobjc
    init(tokens: TideyInterfaceThemeTokens, usesSemanticStatusColors: Bool) {
        self.tokens = tokens
        self.usesSemanticStatusColors = usesSemanticStatusColors
        super.init()
    }

    @objc(colorForStatusValues:producerColor:selected:)
    func color(forStatusValues values: [String],
               producerColor: NSColor?,
               selected: Bool) -> NSColor {
        guard usesSemanticStatusColors else {
            return selected ? tokens.sidebarSelectedSecondaryTextColor
                            : (producerColor ?? NSColor.secondaryLabelColor)
        }
        if values.contains("Needs input") {
            return tokens.sidebarUnreadColor
        }
        if values.contains("Running") {
            return tokens.sidebarRunningColor
        }
        if values.contains("Idle") {
            return selected ? tokens.sidebarSelectedIdleColor : tokens.sidebarIdleColor
        }
        return tokens.sidebarSecondaryTextColor
    }
}

@objcMembers
final class TideySettingsThemeAdapter: NSObject {
    let mainWindowBackgroundColor: NSColor
    let panelBackgroundColor: NSColor
    let cardBackgroundColor: NSColor
    let cardBorderColor: NSColor
    let dividerColor: NSColor
    let primaryTextColor: NSColor
    let secondaryTextColor: NSColor
    let tertiaryTextColor: NSColor
    let accentColor: NSColor
    let tabSelectionBackgroundColor: NSColor
    let tabSelectionTextColor: NSColor
    let tabTextColor: NSColor

    @nonobjc
    init(tokens: TideyInterfaceThemeTokens,
         mainWindowBackgroundColor: NSColor? = nil,
         panelBackgroundColor: NSColor? = nil,
         cardBackgroundColor: NSColor? = nil,
         cardBorderColor: NSColor? = nil,
         dividerColor: NSColor? = nil,
         primaryTextColor: NSColor? = nil,
         secondaryTextColor: NSColor? = nil,
         tertiaryTextColor: NSColor? = nil,
         accentColor: NSColor? = nil,
         tabSelectionBackgroundColor: NSColor? = nil,
         tabSelectionTextColor: NSColor? = nil,
         tabTextColor: NSColor? = nil) {
        self.mainWindowBackgroundColor = mainWindowBackgroundColor ?? tokens.settingsPanelBackgroundColor
        self.panelBackgroundColor = panelBackgroundColor ?? tokens.settingsPanelBackgroundColor
        self.cardBackgroundColor = cardBackgroundColor ?? tokens.settingsCardBackgroundColor
        self.cardBorderColor = cardBorderColor ?? tokens.settingsCardBorderColor
        self.dividerColor = dividerColor ?? tokens.settingsDividerColor
        self.primaryTextColor = primaryTextColor ?? tokens.settingsPrimaryTextColor
        self.secondaryTextColor = secondaryTextColor ?? tokens.settingsSecondaryTextColor
        self.tertiaryTextColor = tertiaryTextColor ?? tokens.rightPanelTertiaryTextColor
        self.accentColor = accentColor ?? tokens.sidebarRunningColor
        self.tabSelectionBackgroundColor = tabSelectionBackgroundColor ?? tokens.settingsCardBackgroundColor
        self.tabSelectionTextColor = tabSelectionTextColor ?? tokens.sidebarRunningColor
        self.tabTextColor = tabTextColor ?? tokens.settingsSecondaryTextColor
        super.init()
    }
}

@objcMembers
final class TideyInterfaceThemeDefinition: NSObject {
    let identifier: String
    let displayName: String
    let tokens: TideyInterfaceThemeTokens
    let terminalAdapter: TideyTerminalThemeAdapter
    let editorCanvasAdapter: TideyEditorCanvasThemeAdapter
    let statusSemanticsAdapter: TideyStatusSemanticsThemeAdapter
    let settingsAdapter: TideySettingsThemeAdapter

    @nonobjc
    init(identifier: String,
         displayName: String,
         tokens: TideyInterfaceThemeTokens,
         terminalAdapter: TideyTerminalThemeAdapter? = nil,
         editorCanvasAdapter: TideyEditorCanvasThemeAdapter? = nil,
         statusSemanticsAdapter: TideyStatusSemanticsThemeAdapter? = nil,
         settingsAdapter: TideySettingsThemeAdapter? = nil) {
        let canonicalIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedTerminalAdapter = terminalAdapter ?? .themed(tokens: tokens)
        self.identifier = canonicalIdentifier
        self.displayName = displayName
        self.tokens = tokens
        self.terminalAdapter = resolvedTerminalAdapter
        self.editorCanvasAdapter = editorCanvasAdapter ?? TideyEditorCanvasThemeAdapter(
            identifier: canonicalIdentifier,
            tokens: tokens,
            terminalAdapter: resolvedTerminalAdapter,
            usesTerminalPaletteRules: true)
        self.statusSemanticsAdapter = statusSemanticsAdapter ?? TideyStatusSemanticsThemeAdapter(
            tokens: tokens,
            usesSemanticStatusColors: true)
        self.settingsAdapter = settingsAdapter ?? TideySettingsThemeAdapter(tokens: tokens)
        super.init()
    }

    static let classic: TideyInterfaceThemeDefinition = {
        let tokens = TideyInterfaceThemeTokens.classic
        let terminal = TideyTerminalThemeAdapter.profileCompatible(tokens: tokens)
        let editor = TideyEditorCanvasThemeAdapter(identifier: "classic",
                                                    tokens: tokens,
                                                    terminalAdapter: terminal,
                                                    usesTerminalPaletteRules: false)
        let status = TideyStatusSemanticsThemeAdapter(tokens: tokens,
                                                      usesSemanticStatusColors: false)
        let settings = TideySettingsThemeAdapter(
            tokens: tokens,
            mainWindowBackgroundColor: NSColor(srgbRed: 0x1a / 255.0,
                                               green: 0x1a / 255.0,
                                               blue: 0x1a / 255.0,
                                               alpha: 1),
            panelBackgroundColor: NSColor(srgbRed: 0x1e / 255.0,
                                          green: 0x1e / 255.0,
                                          blue: 0x1e / 255.0,
                                          alpha: 1),
            cardBackgroundColor: NSColor(srgbRed: 0x2a / 255.0,
                                         green: 0x2a / 255.0,
                                         blue: 0x2c / 255.0,
                                         alpha: 1),
            cardBorderColor: NSColor(white: 1, alpha: 0.06),
            dividerColor: NSColor(white: 1, alpha: 0.07),
            primaryTextColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
            secondaryTextColor: NSColor(srgbRed: 235 / 255.0,
                                        green: 235 / 255.0,
                                        blue: 245 / 255.0,
                                        alpha: 0.55),
            tertiaryTextColor: NSColor(srgbRed: 235 / 255.0,
                                       green: 235 / 255.0,
                                       blue: 245 / 255.0,
                                       alpha: 0.28),
            accentColor: NSColor(srgbRed: 0x0a / 255.0,
                                 green: 0x84 / 255.0,
                                 blue: 0xff / 255.0,
                                 alpha: 1),
            tabSelectionBackgroundColor: NSColor(srgbRed: 88 / 255.0,
                                                 green: 178 / 255.0,
                                                 blue: 220 / 255.0,
                                                 alpha: 0.12),
            tabSelectionTextColor: NSColor(srgbRed: 88 / 255.0,
                                           green: 178 / 255.0,
                                           blue: 220 / 255.0,
                                           alpha: 1),
            tabTextColor: NSColor(srgbRed: 0x88 / 255.0,
                                  green: 0x88 / 255.0,
                                  blue: 0x88 / 255.0,
                                  alpha: 1))
        return TideyInterfaceThemeDefinition(identifier: "classic",
                                             displayName: "Classic · 經典藍調",
                                             tokens: tokens,
                                             terminalAdapter: terminal,
                                             editorCanvasAdapter: editor,
                                             statusSemanticsAdapter: status,
                                             settingsAdapter: settings)
    }()

    static let warm: TideyInterfaceThemeDefinition = {
        let tokens = TideyInterfaceThemeTokens.warm
        let terminal = TideyTerminalThemeAdapter.themed(
            tokens: tokens,
            colorOverrides: TideyTerminalThemeAdapter.warmColorOverrides)
        let editor = TideyEditorCanvasThemeAdapter(identifier: "warm",
                                                    tokens: tokens,
                                                    terminalAdapter: terminal,
                                                    usesTerminalPaletteRules: true)
        return TideyInterfaceThemeDefinition(identifier: "warm",
                                             displayName: "Amber Night · 琥珀夜色",
                                             tokens: tokens,
                                             terminalAdapter: terminal,
                                             editorCanvasAdapter: editor)
    }()

    static let sakura: TideyInterfaceThemeDefinition = {
        let tokens = TideyInterfaceThemeTokens.sakura
        let terminal = TideyTerminalThemeAdapter.themed(
            tokens: tokens,
            colorOverrides: TideyTerminalThemeAdapter.sakuraColorOverrides)
        let accent = tokens.rightPanelTabSelectionIndicatorColor
        let settings = TideySettingsThemeAdapter(
            tokens: tokens,
            accentColor: accent,
            tabSelectionBackgroundColor: accent.withAlphaComponent(0.12),
            tabSelectionTextColor: accent)
        return TideyInterfaceThemeDefinition(identifier: "sakura",
                                             displayName: "Sakura Fubuki · 落櫻繽紛",
                                             tokens: tokens,
                                             terminalAdapter: terminal,
                                             settingsAdapter: settings)
    }()
}

@objcMembers
final class TideyInterfaceThemeRegistry: NSObject {
    static let shared = TideyInterfaceThemeRegistry(
        themes: [.classic, .warm, .sakura],
        fallbackIdentifier: "classic")

    private let lock = NSLock()
    private var orderedThemes: [TideyInterfaceThemeDefinition]
    private var themesByIdentifier: [String: TideyInterfaceThemeDefinition]
    let fallbackIdentifier: String

    @nonobjc
    init(themes: [TideyInterfaceThemeDefinition], fallbackIdentifier: String) {
        precondition(!themes.isEmpty, "A theme registry needs at least one theme")
        self.orderedThemes = []
        self.themesByIdentifier = [:]
        for theme in themes where Self.isValid(identifier: theme.identifier) {
            guard self.themesByIdentifier[theme.identifier] == nil else { continue }
            self.orderedThemes.append(theme)
            self.themesByIdentifier[theme.identifier] = theme
        }
        precondition(!self.orderedThemes.isEmpty, "A theme registry needs at least one valid theme")
        let canonicalFallback = Self.canonical(identifier: fallbackIdentifier)
        self.fallbackIdentifier = self.themesByIdentifier[canonicalFallback] != nil
            ? canonicalFallback
            : self.orderedThemes[0].identifier
        super.init()
    }

    var availableThemes: [TideyInterfaceThemeDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return orderedThemes
    }

    var supportedThemeIdentifiers: [String] {
        availableThemes.map(\.identifier)
    }

    @objc(registerTheme:)
    @discardableResult
    func register(_ theme: TideyInterfaceThemeDefinition) -> Bool {
        guard Self.isValid(identifier: theme.identifier) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard themesByIdentifier[theme.identifier] == nil else { return false }
        orderedThemes.append(theme)
        themesByIdentifier[theme.identifier] = theme
        return true
    }

    @objc(themeForIdentifier:)
    func theme(forIdentifier identifier: String?) -> TideyInterfaceThemeDefinition {
        let canonical = Self.canonical(identifier: identifier)
        lock.lock()
        defer { lock.unlock() }
        return themesByIdentifier[canonical] ?? themesByIdentifier[fallbackIdentifier] ?? orderedThemes[0]
    }

    @objc(normalizedThemeIdentifier:)
    func normalizedThemeIdentifier(_ identifier: String?) -> String {
        theme(forIdentifier: identifier).identifier
    }

    private static func canonical(identifier: String?) -> String {
        (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isValid(identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return identifier.unicodeScalars.allSatisfy { allowed.contains($0) } &&
               identifier.first?.isLetter == true
    }
}

// Geometry and component structure are shared by every theme. Keeping these
// values outside theme tokens prevents a palette from silently forking layout.
@objcMembers
final class TideyChromeLayoutPolicy: NSObject {
    static let sidebarSelectionCornerRadius: CGFloat = 8
    static let rightPanelTabCornerRadius: CGFloat = 0
}

// Browser toolbar geometry is one shared component. Themes provide only the
// two color tokens used to paint it.
@objcMembers
final class TideyBrowserToolbarPolicy: NSObject {
    static func toolbarHeight() -> CGFloat {
        28
    }

    static func urlFieldHeight() -> CGFloat {
        22
    }

    @objc(urlFieldFrameForToolbarHeight:contentWidth:)
    static func urlFieldFrame(toolbarHeight: CGFloat,
                              contentWidth: CGFloat) -> NSRect {
        let fieldX: CGFloat = 92
        let fieldRight: CGFloat = 28
        let fieldHeight = urlFieldHeight()
        let fieldY = floor((toolbarHeight - fieldHeight) / 2)
        return NSRect(x: fieldX,
                      y: fieldY,
                      width: max(50, contentWidth - fieldX - fieldRight),
                      height: fieldHeight)
    }

    @objc(urlFieldTextRectForFieldBounds:)
    static func urlFieldTextRect(fieldBounds: NSRect) -> NSRect {
        NSRect(x: fieldBounds.minX + 4,
               y: fieldBounds.minY + 3,
               width: max(0, fieldBounds.width - 8),
               height: max(0, fieldBounds.height - 6))
    }

    @objc(toolbarBackgroundColorWithTokens:)
    static func toolbarBackgroundColor(tokens: TideyInterfaceThemeTokens) -> NSColor {
        tokens.browserToolbarBackgroundColor
    }
}

// Shared paper-tab contract (every theme; colors come from the theme's
// tokens). Both the terminal tab bar (PSMMinimalTabStyle)
// and the right-panel tab strip (TideyEditorTabItemView) render this silhouette:
// a hairline outline with small top corners, the selected tab full height and
// open at the bottom so it joins its content, unselected tabs set back behind
// it by `unselectedTopInset`. Coordinates are flipped (minY is the top edge).
@objcMembers
final class TideyPaperTabPolicy: NSObject {
    static let outlineWidth: CGFloat = 1
    static let topCornerRadius: CGFloat = 4
    static let unselectedTopInset: CGFloat = 2
    static let selectionIndicatorHeight: CGFloat = 2

    /// Parked pull-bar experiment (not active in any theme): boundaries are
    /// full-height 1pt lines; these constants only size a bar wider than 1pt.
    static let pullBarWidth: CGFloat = 2
    static let pullBarLength: CGFloat = 34

    /// Distance over which a paper-tab leading edge settles into the fainter
    /// pane separator below the tab row.
    static let boundaryJoinGradientLength: CGFloat = 14

    @objc(boundaryJoinGradientLocationsForBoundaryHeight:)
    static func boundaryJoinGradientLocations(forBoundaryHeight height: CGFloat) -> [NSNumber] {
        let settledLocation = height > 0
            ? min(1, boundaryJoinGradientLength / height)
            : 1
        return [0, NSNumber(value: Double(settledLocation)), 1]
    }

    /// Focused tab trailing edge: the vertical outline fades over its lowest
    /// `trailingFadeVerticalLength` points, turns the lower-right corner at the
    /// blended corner color, and keeps fading along the strip baseline for
    /// `trailingFadeHorizontalLength` points until it is the plain separator.
    static let trailingFadeVerticalLength: CGFloat = 14
    static let trailingFadeHorizontalLength: CGFloat = 24

    /// Reference geometry for a trailing-corner overlay whose local x=0 is
    /// the selected tab's trailing pixel column. Preserve the real tab width
    /// so `trailingLegRect` uses the same 4pt top radius as the tab outline;
    /// a narrow dummy rect would shrink the radius and overlap the top arc.
    @objc(trailingOverlayReferenceTabRectForTabWidth:tabHeight:)
    static func trailingOverlayReferenceTabRect(tabWidth: CGFloat,
                                                tabHeight: CGFloat) -> NSRect {
        guard tabWidth > 0, tabHeight > 0 else {
            return .zero
        }
        let width = max(outlineWidth, tabWidth)
        return NSRect(x: outlineWidth - width,
                      y: 0,
                      width: width,
                      height: tabHeight)
    }

    /// Whether the selected tab's leading edge is the strip's own leading
    /// boundary. Only that state may continue into the workspace separator;
    /// a selected tab farther right instead turns into the strip baseline.
    @objc(selectedTabConnectsToLeadingBoundaryWithSelectedTabFrame:stripBounds:)
    static func selectedTabConnectsToLeadingBoundary(selectedTabFrame: NSRect,
                                                      stripBounds: NSRect) -> Bool {
        guard selectedTabFrame.width > 0,
              selectedTabFrame.height > 0,
              stripBounds.width > 0,
              stripBounds.height > 0 else {
            return false
        }
        return abs(selectedTabFrame.minX - stripBounds.minX) < outlineWidth
    }

    /// Left side + rounded top for the focused tab; the trailing leg is drawn
    /// by `drawTrailingCorner…` so it is never stroked twice. Ends exactly
    /// where the trailing leg begins: (maxX - 0.5, minY + radius).
    @objc(selectedLeadingAndTopOutlinePathForRect:)
    static func selectedLeadingAndTopOutlinePath(for rect: NSRect) -> NSBezierPath {
        let inset = outlineWidth / 2
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let top = rect.minY + inset
        let bottom = rect.maxY
        let radius = min(topCornerRadius, (right - left) / 2)
        let path = NSBezierPath()
        path.lineWidth = outlineWidth
        path.move(to: NSPoint(x: left, y: bottom))
        path.line(to: NSPoint(x: left, y: top + radius))
        path.appendArc(withCenter: NSPoint(x: left + radius, y: top + radius),
                       radius: radius,
                       startAngle: 180,
                       endAngle: 270,
                       clockwise: false)
        path.line(to: NSPoint(x: right - radius, y: top))
        path.appendArc(withCenter: NSPoint(x: right - radius, y: top + radius),
                       radius: radius,
                       startAngle: 270,
                       endAngle: 360,
                       clockwise: false)
        return path
    }

    /// Rounded top only. A non-leading focused tab hands both vertical legs to
    /// the corner renderers so each can fade continuously into its baseline.
    @objc(selectedTopOutlinePathForRect:)
    static func selectedTopOutlinePath(for rect: NSRect) -> NSBezierPath {
        let inset = outlineWidth / 2
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let top = rect.minY + inset
        let radius = min(topCornerRadius, (right - left) / 2)
        let path = NSBezierPath()
        path.lineWidth = outlineWidth
        path.move(to: NSPoint(x: left, y: top + radius))
        path.appendArc(withCenter: NSPoint(x: left + radius, y: top + radius),
                       radius: radius,
                       startAngle: 180,
                       endAngle: 270,
                       clockwise: false)
        path.line(to: NSPoint(x: right - radius, y: top))
        path.appendArc(withCenter: NSPoint(x: right - radius, y: top + radius),
                       radius: radius,
                       startAngle: 270,
                       endAngle: 360,
                       clockwise: false)
        return path
    }

    /// 1pt leading column of a focused non-leading tab. It mirrors the
    /// trailing leg and ends immediately above the baseline corner pixel.
    @objc(leadingLegRectForTabRect:)
    static func leadingLegRect(forTabRect rect: NSRect) -> NSRect {
        let radius = min(topCornerRadius, rect.width / 2)
        let top = rect.minY + outlineWidth / 2 + radius
        let bottom = rect.maxY - outlineWidth
        return NSRect(x: rect.minX,
                      y: top,
                      width: outlineWidth,
                      height: max(0, bottom - top))
    }

    /// Baseline row ending at the focused non-leading tab's lower-left corner.
    @objc(leadingBaselineRectForTabRect:availableLeadingWidth:)
    static func leadingBaselineRect(forTabRect rect: NSRect,
                                    availableLeadingWidth: CGFloat) -> NSRect {
        let length = min(trailingFadeHorizontalLength, max(0, availableLeadingWidth))
        return NSRect(x: rect.minX - length,
                      y: rect.maxY - outlineWidth,
                      width: length + outlineWidth,
                      height: outlineWidth)
    }

    /// Mirror of `drawTrailingCorner`: fade down the selected tab's leading
    /// leg, turn the lower-left corner, and continue leftward into the ordinary
    /// strip baseline.
    @objc(drawLeadingCornerForTabRect:availableLeadingWidth:outlineColor:separatorColor:stripBackgroundColor:)
    static func drawLeadingCorner(forTabRect rect: NSRect,
                                  availableLeadingWidth: CGFloat,
                                  outlineColor: NSColor,
                                  separatorColor: NSColor,
                                  stripBackgroundColor: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let leg = leadingLegRect(forTabRect: rect)
        let baseline = leadingBaselineRect(forTabRect: rect,
                                           availableLeadingWidth: availableLeadingWidth)
        let cornerColor = trailingCornerColor(outlineColor: outlineColor,
                                              separatorColor: separatorColor)
        let fadeLength = min(trailingFadeVerticalLength, leg.height)

        context.saveGState()
        if leg.height - fadeLength > 0 {
            context.setFillColor(outlineColor.cgColor)
            context.fill(NSRect(x: leg.minX,
                                y: leg.minY,
                                width: leg.width,
                                height: leg.height - fadeLength))
        }
        if fadeLength > 0 {
            let fadeRect = NSRect(x: leg.minX,
                                  y: leg.maxY - fadeLength,
                                  width: leg.width,
                                  height: fadeLength)
            drawLinearGradient(context,
                               from: outlineColor,
                               to: cornerColor,
                               in: fadeRect,
                               start: CGPoint(x: fadeRect.midX, y: fadeRect.minY),
                               end: CGPoint(x: fadeRect.midX, y: fadeRect.maxY))
        }
        context.setFillColor(stripBackgroundColor.cgColor)
        context.fill(baseline)
        drawLinearGradient(context,
                           from: separatorColor,
                           to: cornerColor,
                           in: baseline,
                           start: CGPoint(x: baseline.minX, y: baseline.midY),
                           end: CGPoint(x: baseline.maxX, y: baseline.midY))
        context.restoreGState()
    }

    /// 1pt trailing column of the focused tab, from just below the top-right
    /// arc down to (but excluding) the corner pixel. Flipped coordinates.
    @objc(trailingLegRectForTabRect:)
    static func trailingLegRect(forTabRect rect: NSRect) -> NSRect {
        let radius = min(topCornerRadius, rect.width / 2)
        let top = rect.minY + outlineWidth / 2 + radius
        let bottom = rect.maxY - outlineWidth
        return NSRect(x: rect.maxX - outlineWidth, y: top, width: outlineWidth, height: max(0, bottom - top))
    }

    /// Baseline row starting at the corner pixel and running right for the
    /// horizontal fade length (clamped to the available strip width).
    @objc(trailingBaselineRectForTabRect:availableTrailingWidth:)
    static func trailingBaselineRect(forTabRect rect: NSRect, availableTrailingWidth: CGFloat) -> NSRect {
        let length = min(trailingFadeHorizontalLength, max(0, availableTrailingWidth))
        return NSRect(x: rect.maxX - outlineWidth,
                      y: rect.maxY - outlineWidth,
                      width: outlineWidth + length,
                      height: outlineWidth)
    }

    @objc(trailingCornerColorWithOutlineColor:separatorColor:)
    static func trailingCornerColor(outlineColor: NSColor, separatorColor: NSColor) -> NSColor {
        outlineColor.blended(withFraction: 0.5, of: separatorColor) ?? separatorColor
    }

    /// Draws the focused tab's trailing leg, corner, and baseline fade as one
    /// continuous ramp: solid outline color, fading over the last
    /// `trailingFadeVerticalLength` points to the corner color, then from the
    /// corner color to `separatorColor` along the baseline. The baseline row
    /// under the fade is first repainted with `stripBackgroundColor` so the
    /// host's plain separator does not show through. Flipped coordinates;
    /// rects are pixel-aligned so the 1pt ramps survive Retina rasterization.
    @objc(drawTrailingCornerForTabRect:availableTrailingWidth:outlineColor:separatorColor:stripBackgroundColor:)
    static func drawTrailingCorner(forTabRect rect: NSRect,
                                   availableTrailingWidth: CGFloat,
                                   outlineColor: NSColor,
                                   separatorColor: NSColor,
                                   stripBackgroundColor: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let leg = trailingLegRect(forTabRect: rect)
        let baseline = trailingBaselineRect(forTabRect: rect, availableTrailingWidth: availableTrailingWidth)
        let cornerColor = trailingCornerColor(outlineColor: outlineColor, separatorColor: separatorColor)
        let fadeLength = min(trailingFadeVerticalLength, leg.height)

        context.saveGState()
        // Solid part of the trailing leg.
        if leg.height - fadeLength > 0 {
            context.setFillColor(outlineColor.cgColor)
            context.fill(NSRect(x: leg.minX, y: leg.minY, width: leg.width, height: leg.height - fadeLength))
        }
        // Fading part of the leg down to the corner.
        if fadeLength > 0 {
            let fadeRect = NSRect(x: leg.minX, y: leg.maxY - fadeLength, width: leg.width, height: fadeLength)
            drawLinearGradient(context, from: outlineColor, to: cornerColor, in: fadeRect,
                               start: CGPoint(x: fadeRect.midX, y: fadeRect.minY),
                               end: CGPoint(x: fadeRect.midX, y: fadeRect.maxY))
        }
        // Baseline: clear the host separator under the fade, then ramp.
        context.setFillColor(stripBackgroundColor.cgColor)
        context.fill(baseline)
        drawLinearGradient(context, from: cornerColor, to: separatorColor, in: baseline,
                           start: CGPoint(x: baseline.minX, y: baseline.midY),
                           end: CGPoint(x: baseline.maxX, y: baseline.midY))
        context.restoreGState()
    }

    private static func drawLinearGradient(_ context: CGContext,
                                           from startColor: NSColor,
                                           to endColor: NSColor,
                                           in rect: NSRect,
                                           start: CGPoint,
                                           end: CGPoint) {
        guard !rect.isEmpty,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [startColor.cgColor, endColor.cgColor] as CFArray,
                                        locations: [0, 1]) else {
            return
        }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    @objc(outlineRectForTabBounds:selected:)
    static func outlineRect(forTabBounds bounds: NSRect, selected: Bool) -> NSRect {
        guard !selected else {
            return bounds
        }
        return NSRect(x: bounds.minX,
                      y: bounds.minY + unselectedTopInset,
                      width: bounds.width,
                      height: max(0, bounds.height - unselectedTopInset))
    }

    /// Outline path in flipped coordinates: left side, rounded top corners,
    /// right side. Bottom is intentionally open.
    @objc(outlinePathForRect:)
    static func outlinePath(for rect: NSRect) -> NSBezierPath {
        let inset = outlineWidth / 2
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let top = rect.minY + inset
        let bottom = rect.maxY
        let radius = min(topCornerRadius, (right - left) / 2)
        let path = NSBezierPath()
        path.lineWidth = outlineWidth
        path.move(to: NSPoint(x: left, y: bottom))
        path.line(to: NSPoint(x: left, y: top + radius))
        path.appendArc(withCenter: NSPoint(x: left + radius, y: top + radius),
                       radius: radius,
                       startAngle: 180,
                       endAngle: 270,
                       clockwise: false)
        path.line(to: NSPoint(x: right - radius, y: top))
        path.appendArc(withCenter: NSPoint(x: right - radius, y: top + radius),
                       radius: radius,
                       startAngle: 270,
                       endAngle: 360,
                       clockwise: false)
        path.line(to: NSPoint(x: right, y: bottom))
        return path
    }
}
