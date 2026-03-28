//
//  MainMenuMangler.swift
//  iTerm2
//
//  Created by George Nachman on 6/20/25.
//

import Cocoa

@objc(iTermMainMenuIconValidator)
final class MainMenuIconValidator: NSObject {
    private static let ignoredMissingIconIdentifiers: Set<String> = ["bogus", "sendSnippet:"]

    @objc(leafIdentifiersInMenu:)
    static func leafIdentifiers(in menu: NSMenu) -> [String] {
        Array(leafIdentifierSet(in: menu)).sorted()
    }

    @objc(iconMapIdentifiersMissingFromMenu:iconMap:)
    static func iconMapIdentifiersMissing(from menu: NSMenu, iconMap: NSDictionary) -> [String] {
        let iconIdentifiers = Set(iconMap.allKeys.compactMap { $0 as? String })
        let menuIdentifiers = leafIdentifierSet(in: menu)
        return Array(iconIdentifiers.subtracting(menuIdentifiers)).sorted()
    }

    @objc(menuIdentifiersMissingIconsFromMenu:iconMap:)
    static func menuIdentifiersMissingIcons(from menu: NSMenu, iconMap: NSDictionary) -> [String] {
        let iconIdentifiers = Set(iconMap.allKeys.compactMap { $0 as? String })
        let filtered = Set(leafIdentifierSet(in: menu).filter {
            !$0.hasPrefix("_NS") && !ignoredMissingIconIdentifiers.contains($0)
        })
        return Array(filtered.subtracting(iconIdentifiers)).sorted()
    }

    private static func leafIdentifierSet(in menu: NSMenu) -> Set<String> {
        var result = Set<String>()
        for item in menu.items {
            if item.isSeparatorItem {
                continue
            }
            if !item.hasSubmenu, let identifier = item.identifier?.rawValue {
                result.insert(identifier)
            }
            if item.hasSubmenu, let submenu = item.submenu {
                result.formUnion(leafIdentifierSet(in: submenu))
            }
        }
        return result
    }
}

/// Observes key-window and firstResponder changes and calls `updateMainMenu()` when either happens.
@objc(iTermMainMenuMangler)
class MainMenuMangler: NSObject {
    @objc static let instance = MainMenuMangler()
    private weak var observedWindow: NSWindow?
    private var web: NSMenuItem?

    // Track if the application is terminating to avoid accessing deallocated objects
    private var isTerminating = false

    // Store original key equivalents for web menu items
    private var originalWebKeyEquivalents: [(String, NSEvent.ModifierFlags)] = []

    // Store conflicting menu items that need their key equivalents restored
    private var conflictingMenuItems: [(menuItem: NSMenuItem, keyEquivalent: String, modifierMask: NSEvent.ModifierFlags)] = []

    private let iconMap = [
        // Tidey (app) menu – visible items only
        "Preferences...": "gear",
        "Hide Tidey": "eye.slash",
        "Hide Others": "eye.slash.fill",
        "Show All": "eye",
        "Quit Tidey": "power",

        // Shell menu
        "New Window": "plus",
        "New Tab": "plus.rectangle.on.folder",
        "Split Horizontally with Current Profile": "square.split.1x2.fill",
        "Split Vertically with Current Profile": "square.split.2x1.fill",
        "Split Horizontally…": "square.split.1x2",
        "Split Vertically…": "square.split.2x1",
        "Close": "xmark",

        // Edit menu
        "Undo": "arrow.uturn.backward",
        "Redo": "arrow.uturn.forward",
        "Cut": "scissors",
        "Copy": "document.on.document",
        "Paste": "document.on.clipboard",
        "Select All": "a.circle",
        "Find.Find...": "magnifyingglass",
        "Find.Find Next": "arrow.down",
        "Find.Find Previous": "arrow.up",

        // View menu
        "Toggle Full Screen": "arrow.up.left.and.arrow.down.right",
        "Find Cursor": "viewfinder",
        "Make Text Bigger": "textformat.size.larger",
        "Make Text Smaller": "textformat.size.smaller",
        "Make Text Normal Size": "textformat.size",

        // Toolbelt submenu – Tidey items
        "Show Tidey Sidebar": "sidebar.left",
        "Show Tidey Editor": "doc.text",
        "Show Tidey File Tree": "folder",
        "Select Workspace 1": "1.circle",
        "Select Workspace 2": "2.circle",
        "Select Workspace 3": "3.circle",
        "Previous Workspace": "arrow.left",
        "Next Workspace": "arrow.right",
        "Toggle Last Workspace": "arrow.uturn.backward",

        // Session menu
        "Restart Session": "arrow.clockwise",

        // Window menu
        "Minimize": "arrow.down.left.and.arrow.up.right",
        "Zoom": "arrow.up.left.and.arrow.down.right",
        "Bring All To Front": "macwindow",
        "Select Next Tab": "arrow.right",
        "Select Previous Tab": "arrow.left",
        "changeTabColorToMenuAction:": "paintpalette",

        // Help menu
        "Tidey Help": "questionmark.circle"]

    @available(macOS 26, *)
    @objc func setIcons() {
        // Find all menu items by traversing the main menu
        if let mainMenu = NSApp.mainMenu {
            setIcons(map: iconMap, in: mainMenu)
        }
    }

    @objc func checkIcons() {
        checkIcons(map: iconMap, in: NSApp.mainMenu!)
    }

    private func checkIcons(map iconMap: [String: String], in menu: NSMenu) {
        let missingFromMenu = MainMenuIconValidator.iconMapIdentifiersMissing(from: menu, iconMap: iconMap as NSDictionary)
        if !missingFromMenu.isEmpty {
            NSFuckingLog("%@", "Some keys have wrong identifiers: \(missingFromMenu)")
            it_fatalError()
        }
        let missingIcons = MainMenuIconValidator.menuIdentifiersMissingIcons(from: menu, iconMap: iconMap as NSDictionary)
        if !missingIcons.isEmpty {
            NSFuckingLog("%@", "These identifiers lack icons: \(missingIcons)")
        }
    }

    private func setIcons(map iconMap: [String: String], in menu: NSMenu) {
        for item in menu.items {
            if let identifier = item.identifier?.rawValue,
               let iconName = iconMap[identifier] {
                #if(DEBUG)
                if item.hasSubmenu {
                    it_fatalError("Submenus should not have icons: \(identifier)")
                }
                #endif
                item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            }
            if item.hasSubmenu, let submenu = item.submenu {
                setIcons(map: iconMap, in: submenu)
            }
        }
    }

    @objc func start(web: NSMenuItem) {
        self.web = web

        // Remove from menu initially if browser not allowed
        if !iTermBrowserGateway.browserAllowed(checkIfNo: false) {
            if NSApp.mainMenu?.items.contains(web) ?? false {
                NSApp.mainMenu?.removeItem(web)
            }
        }

        // Store original web menu key equivalents and scan for conflicts
        scanForKeyEquivalentConflicts()

        // Watch for any window becoming or resigning key
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(currentTerminalDidChange(_:)),
            name: Notification.Name("iTermWindowBecameKey"),
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(currentSessionDidChange(_:)),
            name: Notification.Name(rawValue: iTermCurrentSessionDidChange),
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(currentSessionDidChange(_:)),
            name: Notification.Name(kCurrentSessionDidChange),
            object: nil)
        // Re-check when browser plugin state changes (e.g., user installs plugin)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(browserStateDidChange(_:)),
            name: iTermBrowserGateway.didChange,
            object: nil)
        // Stop observing before iTermController is released during app termination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: Notification.Name(rawValue: iTermApplicationWillTerminate),
            object: nil)
        update()
    }

    @objc private func applicationWillTerminate(_ note: Notification) {
        isTerminating = true
        stopObserving()
    }

    @objc private func browserStateDidChange(_ note: Notification) {
        updateMainMenu()
    }

    deinit {
        stopObserving()
    }

    // MARK: – Notification handlers

    @objc private func currentTerminalDidChange(_ note: Notification) {
        update()
    }

    @objc private func currentSessionDidChange(_ note: Notification) {
        updateMainMenu()
    }

    private func update() {
        // Don't access iTermController during app termination - it may be deallocated
        guard !isTerminating else { return }

        let currentTerminalWindow = iTermController.sharedInstance().currentTerminal?.window()
        if currentTerminalWindow == observedWindow {
            return
        }
        stopObserving()
        if let currentTerminalWindow {
            startObserving(window: currentTerminalWindow)
        }
    }

    // MARK: – KVO for firstResponder

    private func startObserving(window: NSWindow) {
        // If it’s already our observed window, nothing to do
        guard observedWindow !== window else { return }

        // Tear down old observation
        stopObserving()

        // Begin observing the new window’s firstResponder
        observedWindow = window
        DLog("Start observing \(window)")
        window.addObserver(
            self,
            forKeyPath: "firstResponder",
            options: [.old, .new],
            context: nil)

        // Trigger one update immediately
        updateMainMenu()
    }

    private func stopObserving() {
        if let window = observedWindow {
            DLog("Stop observing \(window)")
            window.removeObserver(self, forKeyPath: "firstResponder")
            observedWindow = nil
        }
        updateMainMenu()
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?) {
        // Only care about firstResponder changes on our observed window
        if keyPath == "firstResponder",
           let win = object as? NSWindow,
           win === observedWindow {
            updateMainMenu()
        } else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
        }
    }

    // MARK: – Key equivalent conflict management
    
    private func scanForKeyEquivalentConflicts() {
        guard let web = web, let webSubmenu = web.submenu else { return }
        
        // Store original web menu key equivalents
        originalWebKeyEquivalents = webSubmenu.items.map { 
            ($0.keyEquivalent, $0.keyEquivalentModifierMask) 
        }
        
        // Find conflicting menu items in the main menu
        conflictingMenuItems.removeAll()
        
        guard let mainMenu = NSApp.mainMenu else { return }
        
        for webMenuItem in webSubmenu.items {
            let webKeyEquiv = webMenuItem.keyEquivalent
            let webModifiers = webMenuItem.keyEquivalentModifierMask
            
            // Skip empty key equivalents
            if webKeyEquiv.isEmpty { continue }
            
            // Search through all main menu items for conflicts
            scanMenuForConflicts(menu: mainMenu, 
                                webKeyEquiv: webKeyEquiv, 
                                webModifiers: webModifiers)
        }
    }
    
    private func scanMenuForConflicts(menu: NSMenu, webKeyEquiv: String, webModifiers: NSEvent.ModifierFlags) {
        for item in menu.items {
            // Check if this item conflicts with the web key equivalent
            if item.keyEquivalent == webKeyEquiv && item.keyEquivalentModifierMask == webModifiers {
                conflictingMenuItems.append((
                    menuItem: item,
                    keyEquivalent: item.keyEquivalent,
                    modifierMask: item.keyEquivalentModifierMask
                ))
            }
            
            // Recursively check submenus
            if let submenu = item.submenu {
                scanMenuForConflicts(menu: submenu, webKeyEquiv: webKeyEquiv, webModifiers: webModifiers)
            }
        }
    }
    
    private func restoreWebKeyEquivalents() {
        guard let web = web, let webSubmenu = web.submenu else { return }
        
        // Restore original key equivalents for web menu items
        for (index, item) in webSubmenu.items.enumerated() {
            if index < originalWebKeyEquivalents.count {
                let (keyEquiv, modifiers) = originalWebKeyEquivalents[index]
                item.keyEquivalent = keyEquiv
                item.keyEquivalentModifierMask = modifiers
            }
        }
    }
    
    private func restoreConflictingMenuItems() {
        for conflict in conflictingMenuItems {
            conflict.menuItem.keyEquivalent = conflict.keyEquivalent
            conflict.menuItem.keyEquivalentModifierMask = conflict.modifierMask
        }
    }

    // MARK: – Hook for your menu-modification logic

    private var existingWebIndex: Int? {
        return web.compactMap { NSApp.mainMenu?.items.firstIndex(of: $0) }
    }

    func updateMainMenu() {
        // Don't access iTermController during app termination - it may be deallocated
        guard !isTerminating else { return }

        guard let web else {
            DLog("updateMainMenu: web is nil, returning early")
            return
        }
        let currentSessionIsWeb: Bool
        if let term = iTermController.sharedInstance().currentTerminal {
            currentSessionIsWeb = term.currentSession()?.isBrowserSession() ?? false
            DLog("updateMainMenu: currentTerminal=\(term), currentSession=\(term.currentSession().d), isBrowser=\(currentSessionIsWeb)")
        } else {
            currentSessionIsWeb = false
            DLog("updateMainMenu: no currentTerminal")
        }

        // Only show web menu if browser is allowed (plugin installed) and current session is a browser
        if currentSessionIsWeb && iTermBrowserGateway.browserAllowed(checkIfNo: false) {
            if existingWebIndex == nil, let menu = NSApp.mainMenu {
                DLog("Show web menu")
                // Clear conflicting key equivalents before adding web menu
                for conflict in conflictingMenuItems {
                    conflict.menuItem.keyEquivalent = ""
                    conflict.menuItem.keyEquivalentModifierMask = []
                }
                if let i = menu.items.firstIndex(where: { $0.identifier?.rawValue == "Session" }) {
                    menu.insertItem(web, at: i + 1)
                }

                // Restore web menu key equivalents after adding to menu
                restoreWebKeyEquivalents()
            }
        } else if existingWebIndex != nil {
            DLog("Remove web menu")
            NSApp.mainMenu?.removeItem(web)
            
            // Restore conflicting menu items' key equivalents when web menu is removed
            restoreConflictingMenuItems()
        }
    }
}
