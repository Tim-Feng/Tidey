//
//  PathTests.swift
//  iTerm2
//
//  Created by George Nachman on 2/4/26.
//

import XCTest
@testable import iTerm2SharedARC
import Darwin
import ObjectiveC.runtime

fileprivate final class URLActionTextDataSource: NSObject, iTermTextDataSource {
    private let line: ScreenCharArray
    private let widthValue: Int32
    private let externalAttributes: iTermExternalAttributeIndex?

    init(text: String,
         width: Int32,
         externalURL: String? = nil,
         externalRange: NSRange? = nil) {
        widthValue = width
        var buffer = [screen_char_t](repeating: screen_char_t(), count: Int(width) + 1)
        for (index, scalar) in text.unicodeScalars.enumerated() where index < Int(width) {
            buffer[index].code = unichar(scalar.value)
            buffer[index].complexChar = 0
        }
        var eol = screen_char_t()
        eol.code = unichar(EOL_HARD)
        line = ScreenCharArray(copyOfLine: buffer,
                               length: width,
                               continuation: eol)

        if let externalURL,
           let externalRange,
           let url = URL(string: externalURL) {
            let link = iTermURL(url: url, identifier: nil, target: nil)
            let attribute = iTermExternalAttribute(underlineColor: VT100TerminalColorValue(),
                                                   url: link,
                                                   blockIDList: nil,
                                                   controlCode: nil)
            let index = iTermExternalAttributeIndex()
            index.setAttributes(attribute,
                                at: Int32(externalRange.location),
                                count: Int32(externalRange.length))
            externalAttributes = index
        } else {
            externalAttributes = nil
        }
        super.init()
    }

    func width() -> Int32 {
        return widthValue
    }

    func numberOfLines() -> Int32 {
        return 1
    }

    func totalScrollbackOverflow() -> Int64 {
        return 0
    }

    func screenCharArray(forLine line: Int32) -> ScreenCharArray {
        return self.line
    }

    func screenCharArray(atScreenIndex index: Int32) -> ScreenCharArray {
        return line
    }

    func externalAttributeIndex(forLine y: Int32) -> (any iTermExternalAttributeIndexReading)? {
        return externalAttributes
    }

    func fetchLine(_ line: Int32, block: (ScreenCharArray) -> Any?) -> Any? {
        return block(self.line)
    }

    func date(forLine line: Int32) -> Date? {
        return nil
    }

    func commandMark(at coord: VT100GridCoord,
                     mustHaveCommand: Bool,
                     range: UnsafeMutablePointer<VT100GridWindowedRange>?) -> (any VT100ScreenMarkReading)? {
        return nil
    }

    func metadata(onLine lineNumber: Int32) -> iTermImmutableMetadata {
        return iTermImmutableMetadataDefault()
    }

    func isFirstLine(ofBlock lineNumber: Int32) -> Bool {
        return false
    }
}

/// Tests for path methods to verify correct behavior with and without custom suite names.
/// These tests establish baseline behavior and verify no regressions when --suite is not used.
final class PathTests: XCTestCase {
    private enum TideyURLClickOpenPolicy: Int {
        case none = 0
        case inAppBrowser = 1
        case externalDefaultBrowser = 2
        case semanticHistory = 3
    }

    private enum TideyURLActionType: Int {
        case openURL = 0
        case smartSelectionAction = 1
        case openExistingFile = 2
        case openImage = 3
    }

    private enum TideyWebURLOpenPolicy: UInt {
        case automatic = 0
        case externalDefaultBrowser = 1
    }

    private func urlClickOpenPolicy(clickCount: Int = 1,
                                    mouseDragged: Bool = false,
                                    modifierFlags: NSEvent.ModifierFlags = [],
                                    cmdClickEnabled: Bool = true,
                                    cmdPressed: Bool = false,
                                    mouseReporting: Bool = false) -> TideyURLClickOpenPolicy {
        guard let mouseHandlerClass = NSClassFromString("PTYMouseHandler") as? AnyClass else {
            XCTFail("Missing PTYMouseHandler")
            return .none
        }
        let selector = NSSelectorFromString("tideyURLClickOpenPolicyForClickCount:mouseDragged:modifierFlags:cmdClickEnabled:cmdPressed:mouseReporting:")
        guard let method = class_getClassMethod(mouseHandlerClass, selector) else {
            XCTFail("Missing URL click open policy helper")
            return .none
        }
        typealias Function = @convention(c) (AnyClass, Selector, Int, ObjCBool, UInt, ObjCBool, ObjCBool, ObjCBool) -> Int
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        let raw = function(mouseHandlerClass,
                           selector,
                           clickCount,
                           ObjCBool(mouseDragged),
                           modifierFlags.rawValue,
                           ObjCBool(cmdClickEnabled),
                           ObjCBool(cmdPressed),
                           ObjCBool(mouseReporting))
        return TideyURLClickOpenPolicy(rawValue: raw) ?? .none
    }

    private func actionClickOpenPolicy(clickCount: Int = 1,
                                       mouseDragged: Bool = false,
                                       modifierFlags: NSEvent.ModifierFlags = [],
                                       cmdClickEnabled: Bool = true,
                                       cmdPressed: Bool = false,
                                       mouseReporting: Bool = false,
                                       actionType: TideyURLActionType,
                                       hasCachedHoverAction: Bool = false) -> TideyURLClickOpenPolicy {
        guard let mouseHandlerClass = NSClassFromString("PTYMouseHandler") as? AnyClass else {
            XCTFail("Missing PTYMouseHandler")
            return .none
        }
        let selector = NSSelectorFromString("tideyActionClickOpenPolicyForClickCount:mouseDragged:modifierFlags:cmdClickEnabled:cmdPressed:mouseReporting:actionType:hasCachedHoverAction:")
        guard let method = class_getClassMethod(mouseHandlerClass, selector) else {
            XCTFail("Missing generic action click open policy helper")
            return .none
        }
        typealias Function = @convention(c) (AnyClass, Selector, Int, ObjCBool, UInt, ObjCBool, ObjCBool, ObjCBool, Int, ObjCBool) -> Int
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        let raw = function(mouseHandlerClass,
                           selector,
                           clickCount,
                           ObjCBool(mouseDragged),
                           modifierFlags.rawValue,
                           ObjCBool(cmdClickEnabled),
                           ObjCBool(cmdPressed),
                           ObjCBool(mouseReporting),
                           actionType.rawValue,
                           ObjCBool(hasCachedHoverAction))
        return TideyURLClickOpenPolicy(rawValue: raw) ?? .none
    }

    private func shouldSuppressMouseReportingForPlainURLClick(clickCount: Int = 1,
                                                              mouseDragged: Bool = false,
                                                              modifierFlags: NSEvent.ModifierFlags = [],
                                                              mouseReporting: Bool = true,
                                                              urlHit: Bool = true) -> Bool {
        guard let mouseHandlerClass = NSClassFromString("PTYMouseHandler") as? AnyClass else {
            XCTFail("Missing PTYMouseHandler")
            return false
        }
        let selector = NSSelectorFromString("tideyShouldSuppressMouseReportingForPlainURLClickWithClickCount:mouseDragged:modifierFlags:mouseReporting:urlHit:")
        guard let method = class_getClassMethod(mouseHandlerClass, selector) else {
            XCTFail("Missing tmux URL click mouse reporting helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, Int, ObjCBool, UInt, ObjCBool, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(mouseHandlerClass,
                        selector,
                        clickCount,
                        ObjCBool(mouseDragged),
                        modifierFlags.rawValue,
                        ObjCBool(mouseReporting),
                        ObjCBool(urlHit)).boolValue
    }

    private func shouldOpenWebURLInApp(_ string: String,
                                       webPolicy: TideyWebURLOpenPolicy,
                                       hasRootView: Bool) -> Bool {
        let selector = NSSelectorFromString("tideyShouldOpenWebURLInAppForURL:webPolicy:hasRootView:")
        guard let method = class_getClassMethod(NSWorkspace.self, selector) else {
            XCTFail("Missing NSWorkspace web URL policy helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSURL, UInt, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(NSWorkspace.self,
                        selector,
                        NSURL(string: string)!,
                        webPolicy.rawValue,
                        ObjCBool(hasRootView)).boolValue
    }

    private func shouldFocusInAppBrowserAfterOpen(webPolicy: TideyWebURLOpenPolicy,
                                                  inBackground: Bool,
                                                  hasRootView: Bool) -> Bool {
        let selector = NSSelectorFromString("tideyShouldFocusInAppBrowserAfterOpeningWebURLWithWebPolicy:inBackground:hasRootView:")
        guard let method = class_getClassMethod(NSWorkspace.self, selector) else {
            XCTFail("Missing NSWorkspace browser focus decision helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, UInt, ObjCBool, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(NSWorkspace.self,
                        selector,
                        webPolicy.rawValue,
                        ObjCBool(inBackground),
                        ObjCBool(hasRootView)).boolValue
    }

    private func urlHoverAffordance(actionType: Int,
                                    modifierFlags: NSEvent.ModifierFlags = []) -> Bool {
        guard let textViewClass = NSClassFromString("PTYTextView") as? AnyClass else {
            XCTFail("Missing PTYTextView")
            return false
        }
        let selector = NSSelectorFromString("tideyShouldShowURLHoverAffordanceForActionType:modifierFlags:")
        guard let method = class_getClassMethod(textViewClass, selector) else {
            XCTFail("Missing URL hover affordance helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, Int, UInt) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(textViewClass,
                        selector,
                        actionType,
                        modifierFlags.rawValue).boolValue
    }

    private func urlHoverMouseMovementTracking(modifierFlags: NSEvent.ModifierFlags = []) -> Bool {
        guard let textViewClass = NSClassFromString("PTYTextView") as? AnyClass else {
            XCTFail("Missing PTYTextView")
            return false
        }
        let selector = NSSelectorFromString("tideyShouldTrackMouseMovementForURLHoverWithModifierFlags:")
        guard let method = class_getClassMethod(textViewClass, selector) else {
            XCTFail("Missing URL hover mouse movement tracking helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, UInt) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(textViewClass,
                        selector,
                        modifierFlags.rawValue).boolValue
    }

    private func objectiveCCharacterSet(named selectorName: String) -> CharacterSet {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(NSCharacterSet.self, selector) else {
            XCTFail("Missing NSCharacterSet.\(selectorName)")
            return CharacterSet()
        }
        typealias Function = @convention(c) (AnyClass, Selector) -> AnyObject
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(NSCharacterSet.self, selector) as? CharacterSet ?? CharacterSet()
    }

    private func semanticHistoryRouteShouldOpen(_ url: URL) -> Bool {
        let controller = iTermSemanticHistoryController()
        controller.prefs = [:]
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(iTermURLActionHelper.self, allocSelector) else {
            XCTFail("Missing iTermURLActionHelper alloc")
            return false
        }
        typealias AllocFunction = @convention(c) (AnyClass, Selector) -> AnyObject
        let allocImplementation = method_getImplementation(allocMethod)
        let allocate = unsafeBitCast(allocImplementation, to: AllocFunction.self)
        let uninitializedHelper = allocate(iTermURLActionHelper.self, allocSelector)

        let selector = NSSelectorFromString("initWithSemanticHistoryController:")
        guard let method = class_getInstanceMethod(iTermURLActionHelper.self, selector) else {
            XCTFail("Missing iTermURLActionHelper initializer")
            return false
        }
        typealias InitFunction = @convention(c) (AnyObject, Selector, iTermSemanticHistoryController) -> AnyObject
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: InitFunction.self)
        let helper = function(uninitializedHelper, selector, controller)

        let shouldOpenSelector = NSSelectorFromString("shouldOpenFileURLWithSemanticHistory:")
        guard let shouldOpenMethod = class_getInstanceMethod(iTermURLActionHelper.self, shouldOpenSelector) else {
            XCTFail("Missing semantic history routing helper")
            return false
        }
        typealias ShouldOpenFunction = @convention(c) (AnyObject, Selector, NSURL) -> ObjCBool
        let shouldOpenImplementation = method_getImplementation(shouldOpenMethod)
        let shouldOpen = unsafeBitCast(shouldOpenImplementation, to: ShouldOpenFunction.self)
        return shouldOpen(helper, shouldOpenSelector, url as NSURL).boolValue
    }

    private func preferredURLLikeCandidate(primaryJoined: String,
                                           fallbackJoined: String,
                                           clickIndex: Int,
                                           respectHardNewlines: Bool) -> String? {
        guard let factoryClass = NSClassFromString("iTermURLActionFactory") as? AnyClass else {
            XCTFail("Missing iTermURLActionFactory")
            return nil
        }
        let selector = NSSelectorFromString("tideyPreferredURLLikeCandidateWithPrimaryJoinedString:fallbackJoinedString:clickIndex:respectHardNewlines:")
        guard let method = class_getClassMethod(factoryClass, selector) else {
            XCTFail("Missing iTermURLActionFactory URL-like candidate helper")
            return nil
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSString, NSString, Int, ObjCBool) -> NSString?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(factoryClass,
                        selector,
                        primaryJoined as NSString,
                        fallbackJoined as NSString,
                        clickIndex,
                        ObjCBool(respectHardNewlines)) as String?
    }

    private func urlHitCandidate(logicalString: String,
                                 clickIndex: Int,
                                 columns: [Int],
                                 rows: [Int],
                                 allowHardNewlineRecovery: Bool = false) -> [String: Any]? {
        guard let factoryClass = NSClassFromString("iTermURLActionFactory") as? AnyClass else {
            XCTFail("Missing iTermURLActionFactory")
            return nil
        }
        let selector = NSSelectorFromString("tideyURLHitCandidateDictionaryForLogicalString:clickIndex:columns:rows:allowHardNewlineRecovery:")
        guard let method = class_getClassMethod(factoryClass, selector) else {
            XCTFail("Missing iTermURLActionFactory URL hit candidate helper")
            return nil
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSString, Int, NSArray, NSArray, ObjCBool) -> NSDictionary?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(factoryClass,
                        selector,
                        logicalString as NSString,
                        clickIndex,
                        columns.map(NSNumber.init(value:)) as NSArray,
                        rows.map(NSNumber.init(value:)) as NSArray,
                        ObjCBool(allowHardNewlineRecovery)) as? [String: Any]
    }

    private func openURLAction(text: String,
                               clickIndex: Int,
                               externalURL: String? = nil,
                               externalRange: NSRange? = nil) -> [String: Any]? {
        guard let factoryClass = NSClassFromString("iTermURLActionFactory") as? AnyClass else {
            XCTFail("Missing iTermURLActionFactory")
            return nil
        }
        let selector = NSSelectorFromString("tideyOpenURLActionDictionaryAtX:y:extractor:respectHardNewlines:")
        guard let method = class_getClassMethod(factoryClass, selector) else {
            XCTFail("Missing Tidey open URL action helper")
            return nil
        }
        let width = Int32(max(80, (text as NSString).length + 1))
        let dataSource = URLActionTextDataSource(text: text,
                                                 width: width,
                                                 externalURL: externalURL,
                                                 externalRange: externalRange)
        let extractor = iTermTextExtractor(dataSource: dataSource)
        typealias Function = @convention(c) (AnyClass, Selector, Int32, Int32, iTermTextExtractor, ObjCBool) -> NSDictionary?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(factoryClass,
                        selector,
                        Int32(clickIndex),
                        0,
                        extractor,
                        true) as? [String: Any]
    }

    private func gridCoordinates(for string: String, width: Int) -> (columns: [Int], rows: [Int]) {
        var columns: [Int] = []
        var rows: [Int] = []
        var x = 0
        var y = 0
        let length = (string as NSString).length
        for _ in 0..<length {
            columns.append(x)
            rows.append(y)
            x += 1
            if x >= width {
                x = 0
                y += 1
            }
        }
        return (columns, rows)
    }

    private func resolvedPath(prefix: String,
                              suffix: String,
                              workingDirectory: String,
                              trimWhitespace: Bool = false,
                              ignore: String = "",
                              allowNetworkMounts: Bool = false) -> String? {
        guard let pathFinderClass = NSClassFromString("iTermPathFinder") as? NSObject.Type else {
            XCTFail("Missing iTermPathFinder")
            return nil
        }
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(pathFinderClass, allocSelector) else {
            XCTFail("Missing iTermPathFinder alloc")
            return nil
        }
        typealias AllocFunction = @convention(c) (AnyClass, Selector) -> AnyObject
        let allocImplementation = method_getImplementation(allocMethod)
        let allocate = unsafeBitCast(allocImplementation, to: AllocFunction.self)
        let uninitializedFinder = allocate(pathFinderClass, allocSelector)

        let initSelector = NSSelectorFromString("initWithPrefix:suffix:workingDirectory:trimWhitespace:ignore:allowNetworkMounts:")
        guard let initMethod = class_getInstanceMethod(pathFinderClass, initSelector) else {
            XCTFail("Missing iTermPathFinder initializer")
            return nil
        }
        typealias InitFunction = @convention(c) (AnyObject, Selector, NSString, NSString, NSString, Bool, NSString, Bool) -> AnyObject
        let initImplementation = method_getImplementation(initMethod)
        let initialize = unsafeBitCast(initImplementation, to: InitFunction.self)
        let finder = initialize(uninitializedFinder,
                                initSelector,
                                prefix as NSString,
                                suffix as NSString,
                                workingDirectory as NSString,
                                trimWhitespace,
                                ignore as NSString,
                                allowNetworkMounts)

        let searchSelector = NSSelectorFromString("searchSynchronously")
        guard let searchMethod = class_getInstanceMethod(pathFinderClass, searchSelector) else {
            XCTFail("Missing iTermPathFinder search")
            return nil
        }
        typealias SearchFunction = @convention(c) (AnyObject, Selector) -> Void
        let searchImplementation = method_getImplementation(searchMethod)
        let search = unsafeBitCast(searchImplementation, to: SearchFunction.self)
        search(finder, searchSelector)

        return finder.value(forKey: "path") as? String
    }

    private func tideyPanelOrderState(visibleTabs: [NSObject],
                                      workspacePanels: [NSObject],
                                      currentTab: NSObject?,
                                      fallbackSelection: Int) -> [String: Any] {
        let selector = NSSelectorFromString("tideyPanelOrderStateByApplyingVisibleTabOrder:toWorkspacePanels:currentTab:fallbackSelection:")
        guard let method = class_getClassMethod(PseudoTerminal.self, selector) else {
            XCTFail("Missing PseudoTerminal reorder helper")
            return [:]
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSArray, NSArray, AnyObject?, NSNumber) -> NSDictionary
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PseudoTerminal.self,
                        selector,
                        visibleTabs as NSArray,
                        workspacePanels as NSArray,
                        currentTab,
                        NSNumber(value: fallbackSelection)) as? [String: Any] ?? [:]
    }

    private func tideyShouldInsertPendingPanelIntoVisibleTabs(selectedWorkspaceIndex: Int,
                                                              targetWorkspaceIndex: Int,
                                                              createWorkspace: Bool,
                                                              showingSidebar: Bool = true,
                                                              rebuildingVisibleWorkspace: Bool = false) -> Bool {
        let selector = NSSelectorFromString("tideyShouldInsertPanelIntoVisibleTabViewForSelectedWorkspaceIndex:targetWorkspaceIndex:createWorkspace:showingSidebar:rebuildingVisibleWorkspace:")
        guard let method = class_getClassMethod(PseudoTerminal.self, selector) else {
            XCTFail("Missing PseudoTerminal visible insert helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, Int, Int, ObjCBool, ObjCBool, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PseudoTerminal.self,
                        selector,
                        selectedWorkspaceIndex,
                        targetWorkspaceIndex,
                        ObjCBool(createWorkspace),
                        ObjCBool(showingSidebar),
                        ObjCBool(rebuildingVisibleWorkspace)).boolValue
    }

    private func tideyShouldManagePendingPanelInsert(showingSidebar: Bool = true,
                                                     pendingWorkspaceIndex: Int,
                                                     createWorkspace: Bool) -> Bool {
        let selector = NSSelectorFromString("tideyShouldManagePendingPanelInsertForShowingSidebar:pendingWorkspaceIndex:createWorkspace:")
        guard let method = class_getClassMethod(PseudoTerminal.self, selector) else {
            XCTFail("Missing PseudoTerminal pending insert helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, ObjCBool, Int, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PseudoTerminal.self,
                        selector,
                        ObjCBool(showingSidebar),
                        pendingWorkspaceIndex,
                        ObjCBool(createWorkspace)).boolValue
    }

    private func tideyShouldUpdateSelectedPanelFromVisibleSelection(showingSidebar: Bool = true,
                                                                    switchingWorkspace: Bool = false,
                                                                    rebuildingVisibleWorkspace: Bool = false,
                                                                    readingSidebarSelection: Bool = false) -> Bool {
        let selector = NSSelectorFromString("tideyShouldUpdateSelectedPanelIndexFromVisibleSelectionForShowingSidebar:switchingWorkspace:rebuildingVisibleWorkspace:readingSidebarSelection:")
        guard let method = class_getClassMethod(PseudoTerminal.self, selector) else {
            XCTFail("Missing PseudoTerminal selected panel update helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, ObjCBool, ObjCBool, ObjCBool, ObjCBool) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PseudoTerminal.self,
                        selector,
                        ObjCBool(showingSidebar),
                        ObjCBool(switchingWorkspace),
                        ObjCBool(rebuildingVisibleWorkspace),
                        ObjCBool(readingSidebarSelection)).boolValue
    }

    private func tideyShouldForwardSidebarSelectionChange(ignoreNextSelection: Bool,
                                                          selectedRow: Int,
                                                          modelSelectedRow: Int,
                                                          numberOfRows: Int) -> Bool {
        let selector = NSSelectorFromString("tideyShouldForwardSidebarSelectionChangeWithIgnoreNextSelection:selectedRow:modelSelectedRow:numberOfRows:")
        guard let rootTerminalViewClass = NSClassFromString("iTermRootTerminalView"),
              let method = class_getClassMethod(rootTerminalViewClass, selector) else {
            XCTFail("Missing iTermRootTerminalView sidebar selection helper")
            return false
        }
        typealias Function = @convention(c) (AnyClass, Selector, ObjCBool, Int, Int, Int) -> ObjCBool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(rootTerminalViewClass,
                        selector,
                        ObjCBool(ignoreNextSelection),
                        selectedRow,
                        modelSelectedRow,
                        numberOfRows).boolValue
    }

    private func scrubbedTerminalIdentityEnvironment(_ environment: [String: String]) -> [String: String] {
        let selector = NSSelectorFromString("tideyEnvironmentByScrubbingExternalTerminalIdentityFromEnvironment:")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession environment scrub helper")
            return [:]
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSDictionary) -> NSDictionary
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self, selector, environment as NSDictionary) as? [String: String] ?? [:]
    }

    private func tmuxEnvironmentCleanupCommand(_ environment: [String: String]) -> String {
        let selector = NSSelectorFromString("tideyTmuxEnvironmentCleanupCommandForEnvironment:")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession tmux cleanup helper")
            return ""
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSDictionary) -> NSString
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self, selector, environment as NSDictionary) as String
    }

    private func tmuxEnvironmentCleanupCommand(tmuxBinaryPath: String) -> String {
        let selector = NSSelectorFromString("tideyTmuxEnvironmentCleanupCommandForTmuxBinaryPath:")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession tmux cleanup command builder")
            return ""
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSString) -> NSString
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self, selector, tmuxBinaryPath as NSString) as String
    }

    private func ordinaryTmuxAttachMetadata(processName: String = "tmux",
                                            argv0: String = "tmux",
                                            commandLine: String,
                                            tty: String = "/dev/ttys001",
                                            isTmuxClient: Bool = false) -> [String: String]? {
        let selector = NSSelectorFromString("tideyOrdinaryTmuxAttachMetadataForProcessName:argv0:commandLine:tty:isTmuxClient:")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession ordinary tmux attach detector")
            return nil
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSString, NSString, NSString, NSString, ObjCBool) -> NSDictionary?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self,
                        selector,
                        processName as NSString,
                        argv0 as NSString,
                        commandLine as NSString,
                        tty as NSString,
                        ObjCBool(isTmuxClient)) as? [String: String]
    }

    private func resolvedExecutablePath(name: String,
                                        searchPATH: String,
                                        fallbackPaths: [String]) -> String? {
        let selector = NSSelectorFromString("tideyResolvedExecutablePathForName:searchPATH:fallbackPaths:")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession executable path resolver")
            return nil
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSString, NSString, NSArray) -> NSString?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self,
                        selector,
                        name as NSString,
                        searchPATH as NSString,
                        fallbackPaths as NSArray) as String?
    }

    private func tmuxBinaryFallbackPaths() -> [String] {
        let selector = NSSelectorFromString("tideyTmuxBinaryFallbackPaths")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession tmux fallback paths helper")
            return []
        }
        typealias Function = @convention(c) (AnyClass, Selector) -> NSArray
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self, selector) as? [String] ?? []
    }

    private func preparedTerminalEnvironmentAndCleanup(_ environment: [String: String]) -> [String: Any] {
        let selector = NSSelectorFromString("tideyPreparedEnvironmentAndTmuxCleanupCommandForEnvironment:")
        guard let method = class_getClassMethod(PTYSession.self, selector) else {
            XCTFail("Missing PTYSession prepared environment helper")
            return [:]
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSDictionary) -> NSDictionary
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(PTYSession.self, selector, environment as NSDictionary) as? [String: Any] ?? [:]
    }

    // MARK: - Application Support Directory Tests

    func testApplicationSupportDirectory_DefaultSuite() {
        // Given: No custom suite is set (default behavior)
        // Note: We can't easily reset the suite in tests since it's set once at startup

        // When
        let path = FileManager.default.applicationSupportDirectory()

        // Then
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.contains("Application Support"))
        // Default should use iTerm2 as the directory name
        XCTAssertTrue(path!.hasSuffix("/iTerm2") || path!.contains("iTerm2"))
    }

    func testApplicationSupportDirectoryWithoutCreating_DefaultSuite() {
        // When
        let path = FileManager.default.applicationSupportDirectoryWithoutCreating()

        // Then
        XCTAssertNotNil(path)
        XCTAssertTrue(path!.contains("Application Support"))
        XCTAssertTrue(path!.hasSuffix("/iTerm2") || path!.contains("iTerm2"))
    }

    // MARK: - Home Directory Dot-Dir Tests

    func testHomeDirectoryDotDir_DefaultSuite() {
        // When
        let path = FileManager.default.homeDirectoryDotDir()

        // Then
        XCTAssertNotNil(path)
        // Should be ~/.config/iterm2 or ~/.iterm2 (or custom preferredBaseDir)
        let homedir = NSHomeDirectory()
        XCTAssertTrue(
            path!.hasPrefix(homedir),
            "Path should be under home directory"
        )
        // Should contain iterm2 somewhere in the path
        let lowercasePath = path!.lowercased()
        XCTAssertTrue(
            lowercasePath.contains("iterm2") || lowercasePath.contains(".iterm2"),
            "Path should contain 'iterm2'"
        )
    }

    // MARK: - Custom Suite Name Accessor Tests

    func testCustomSuiteName_ReturnsNilOrSetValue() {
        // This test documents the behavior of customSuiteName accessor
        // The actual value depends on whether --suite was passed at startup
        let suiteName = iTermUserDefaults.customSuiteName()

        // The test passes regardless of value - we're just documenting that the method exists
        // and returns either nil (no suite) or a string (custom suite)
        if let name = suiteName {
            XCTAssertFalse(name.isEmpty, "If a suite name is set, it should not be empty")
        }
        // nil is also valid - means no custom suite
    }

    // MARK: - Integration Tests

    func testScriptsPath_UsesApplicationSupportDirectory() {
        // When
        let scriptsPath = FileManager.default.scriptsPath()

        // Then
        XCTAssertNotNil(scriptsPath)
        // Scripts path should be under Application Support (unless custom folder is set)
        let appSupport = FileManager.default.applicationSupportDirectory()
        if appSupport != nil {
            // Either it's under app support or it's a custom scripts folder
            let isUnderAppSupport = scriptsPath!.hasPrefix(appSupport!)
            let isCustomFolder = iTermPreferences.bool(forKey: kPreferenceKeyUseCustomScriptsFolder)
            XCTAssertTrue(isUnderAppSupport || isCustomFolder,
                          "Scripts path should be under app support or custom folder")
        }
    }

    func testFilenameCharacterSetStopsAtFullWidthParentheticalSuffix() {
        let source = "~/.claude/skills/skill-creator/SKILL.md（Project Conventions 改成新預設）" as NSString
        let offset = source.range(of: "SKILL.md").location + "SKILL.md".count - 1
        let extracted = source.substring(includingOffset: Int32(offset),
                                         from: objectiveCCharacterSet(named: "filenameCharacterSet"),
                                         charsTakenFromPrefix: nil)

        XCTAssertEqual(extracted, "~/.claude/skills/skill-creator/SKILL.md")
    }

    func testURLCharacterSetStopsAtFullWidthParentheticalSuffix() {
        let source = "https://example.com/docs/shared-resource-patterns.md（2845 bytes，新）" as NSString
        let offset = source.range(of: "patterns.md").location + "patterns.md".count - 1
        let extracted = source.substring(includingOffset: Int32(offset),
                                         from: objectiveCCharacterSet(named: "urlCharacterSet"),
                                         charsTakenFromPrefix: nil)

        XCTAssertEqual(extracted, "https://example.com/docs/shared-resource-patterns.md")
    }

    func testPathFinderIgnoresFullWidthParentheticalSuffixAfterTildePath() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/TideyPathBoundaryTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fileURL = root.appendingPathComponent("shared-resource-patterns.md")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let relativePath = fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        XCTAssertEqual(resolvedPath(prefix: relativePath,
                                    suffix: "（2845 bytes，新）",
                                    workingDirectory: NSHomeDirectory()),
                       fileURL.path)
    }

    func testFileURLWithoutFragmentUsesSemanticHistoryRoute() {
        let url = URL(fileURLWithPath: "/Users/timfeng/GitHub/life-system/TODO.md")

        XCTAssertTrue(semanticHistoryRouteShouldOpen(url))
    }

    func testFileURLWithFragmentUsesSemanticHistoryRoute() {
        let url = URL(string: "file:///Users/timfeng/GitHub/life-system/TODO.md#12:3")!

        XCTAssertTrue(semanticHistoryRouteShouldOpen(url))
    }

    func testNonFileURLsDoNotUseSemanticHistoryRoute() {
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "https://example.com/path")!))
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "iterm2://open?foo=bar")!))
    }

    func testFileURLsWithoutPathsDoNotUseSemanticHistoryRoute() {
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "file://")!))
        XCTAssertFalse(semanticHistoryRouteShouldOpen(URL(string: "file:///")!))
    }

    func testURLLikeCandidateUsesPrimaryStringWhenRespectingHardNewlines() {
        let primary = "prefix https://example.com/path\nother text"
        let fallback = "prefix https://example.com/pathother text"
        let clickIndex = (primary as NSString).range(of: "example").location

        let candidate = preferredURLLikeCandidate(primaryJoined: primary,
                                                  fallbackJoined: fallback,
                                                  clickIndex: clickIndex,
                                                  respectHardNewlines: true)

        XCTAssertEqual(candidate, "https://example.com/path")
    }

    func testURLLikeCandidateUsesIgnoringHardNewlineStringWhenConfigured() {
        let primary = "prefix https://example.com/very/long/\npath?query=1"
        let fallback = "prefix https://example.com/very/long/path?query=1"
        let clickIndex = (primary as NSString).range(of: "example").location

        let candidate = preferredURLLikeCandidate(primaryJoined: primary,
                                                  fallbackJoined: fallback,
                                                  clickIndex: clickIndex,
                                                  respectHardNewlines: false)

        XCTAssertEqual(candidate, "https://example.com/very/long/path?query=1")
    }

    func testURLHitCandidateKeepsSoftWrappedHostTogether() {
        let url = "https://api.somelongverylongsubdomain.example.com/v1/users/12345/repos"
        let coordinates = gridCoordinates(for: url, width: 44)
        let clickIndex = (url as NSString).range(of: "example").location

        let candidate = urlHitCandidate(logicalString: url,
                                        clickIndex: clickIndex,
                                        columns: coordinates.columns,
                                        rows: coordinates.rows)

        XCTAssertEqual(candidate?["url"] as? String, url)
        XCTAssertEqual(candidate?["startX"] as? Int, 0)
        XCTAssertEqual(candidate?["startY"] as? Int, 0)
        XCTAssertGreaterThan(candidate?["endY"] as? Int ?? 0, 0)
    }

    func testURLHitCandidateKeepsLogicalURLStableAcrossResizeMappings() {
        let url = "https://api.somelongverylongsubdomain.example.com/v1/users/12345/repos"
        let clickIndex = (url as NSString).range(of: "example").location
        let narrowCoordinates = gridCoordinates(for: url, width: 32)
        let wideCoordinates = gridCoordinates(for: url, width: 120)

        let narrow = urlHitCandidate(logicalString: url,
                                     clickIndex: clickIndex,
                                     columns: narrowCoordinates.columns,
                                     rows: narrowCoordinates.rows)
        let wide = urlHitCandidate(logicalString: url,
                                   clickIndex: clickIndex,
                                   columns: wideCoordinates.columns,
                                   rows: wideCoordinates.rows)

        XCTAssertEqual(narrow?["url"] as? String, url)
        XCTAssertEqual(wide?["url"] as? String, url)
        XCTAssertGreaterThan(narrow?["endY"] as? Int ?? 0, 0)
        XCTAssertEqual(wide?["endY"] as? Int, 0)
    }

    func testURLHitCandidateRecoversHostSplitByHardNewline() {
        let text = "prefix https://git\nhub.com/org/repo suffix"
        let coordinates = gridCoordinates(for: text, width: 200)
        let clickIndex = (text as NSString).range(of: "git").location

        let candidate = urlHitCandidate(logicalString: text,
                                        clickIndex: clickIndex,
                                        columns: coordinates.columns,
                                        rows: coordinates.rows,
                                        allowHardNewlineRecovery: true)

        XCTAssertEqual(candidate?["url"] as? String, "https://github.com/org/repo")
        XCTAssertEqual(candidate?["startX"] as? Int, (text as NSString).range(of: "https").location)
        XCTAssertEqual(candidate?["endX"] as? Int, (text as NSString).range(of: "repo").location + 3)
    }

    func testURLLikeCandidateStopsBeforeChineseTrailingPunctuation() {
        let suffixes = ["、", "，", "。", "「", "」", "！", "？", "；", "：", "（", "）", "【", "】"]
        for suffix in suffixes {
            let text = "進 https://claude.ai/admin-settings/claude-code\(suffix)看是否有"
            let clickIndex = (text as NSString).range(of: "claude").location
            let coordinates = gridCoordinates(for: text, width: 200)

            let candidate = urlHitCandidate(logicalString: text,
                                            clickIndex: clickIndex,
                                            columns: coordinates.columns,
                                            rows: coordinates.rows)
            let joinedCandidate = preferredURLLikeCandidate(primaryJoined: text,
                                                            fallbackJoined: text,
                                                            clickIndex: clickIndex,
                                                            respectHardNewlines: true)
            let action = openURLAction(text: text, clickIndex: clickIndex)

            XCTAssertEqual(candidate?["url"] as? String,
                           "https://claude.ai/admin-settings/claude-code",
                           "suffix: \(suffix)")
            XCTAssertEqual(joinedCandidate,
                           "https://claude.ai/admin-settings/claude-code",
                           "suffix: \(suffix)")
            XCTAssertEqual(action?["url"] as? String,
                           "https://claude.ai/admin-settings/claude-code",
                           "suffix: \(suffix)")
        }
    }

    func testURLLikeCandidateStartsAfterChineseLeadingPunctuation() {
        let prefixes = ["網址：", "（", "【", "「"]
        for prefix in prefixes {
            let text = "\(prefix)https://claude.ai/admin-settings/claude-code"
            let clickIndex = (text as NSString).range(of: "claude").location
            let coordinates = gridCoordinates(for: text, width: 200)

            let candidate = urlHitCandidate(logicalString: text,
                                            clickIndex: clickIndex,
                                            columns: coordinates.columns,
                                            rows: coordinates.rows)
            let joinedCandidate = preferredURLLikeCandidate(primaryJoined: text,
                                                            fallbackJoined: text,
                                                            clickIndex: clickIndex,
                                                            respectHardNewlines: true)
            let action = openURLAction(text: text, clickIndex: clickIndex)

            XCTAssertEqual(candidate?["url"] as? String,
                           "https://claude.ai/admin-settings/claude-code",
                           "prefix: \(prefix)")
            XCTAssertEqual(joinedCandidate,
                           "https://claude.ai/admin-settings/claude-code",
                           "prefix: \(prefix)")
            XCTAssertEqual(action?["url"] as? String,
                           "https://claude.ai/admin-settings/claude-code",
                           "prefix: \(prefix)")
        }
    }

    func testOSC8LabelPlainClickCandidateOpensExternalURL() {
        let text = "download DMG"
        let url = "https://github.com/Tim-Feng/Tidey/releases/download/v0.3.1/Tidey.dmg"
        let action = openURLAction(text: text,
                                   clickIndex: 2,
                                   externalURL: url,
                                   externalRange: NSRange(location: 0, length: (text as NSString).length))

        XCTAssertEqual(action?["url"] as? String, url)
        XCTAssertEqual(action?["osc8"] as? Bool, true)
        XCTAssertEqual(action?["startX"] as? Int, 0)
    }

    func testVisibleURLPlainClickCandidateStillOpensExternalURL() {
        let text = "visit https://github.com now"
        let clickIndex = (text as NSString).range(of: "github").location
        let action = openURLAction(text: text, clickIndex: clickIndex)

        XCTAssertEqual(action?["url"] as? String, "https://github.com")
        XCTAssertEqual(action?["osc8"] as? Bool, false)
    }

    func testPlainClickCandidateRejectsNonURLLabelWithoutOSC8() {
        let action = openURLAction(text: "download DMG", clickIndex: 2)

        XCTAssertNil(action)
    }

    func testPlainURLClickPolicyOpensExternalDefaultBrowser() {
        XCTAssertEqual(urlClickOpenPolicy(), .externalDefaultBrowser)
    }

    func testURLClickPolicyKeepsCommandClickInApp() {
        XCTAssertEqual(urlClickOpenPolicy(modifierFlags: .command, cmdPressed: true), .inAppBrowser)
        XCTAssertEqual(urlClickOpenPolicy(modifierFlags: .command,
                                          cmdPressed: true,
                                          mouseReporting: true), .inAppBrowser)
    }

    func testURLClickPolicyRejectsDragSelectionAndMouseReporting() {
        XCTAssertEqual(urlClickOpenPolicy(mouseDragged: true), .none)
        XCTAssertEqual(urlClickOpenPolicy(mouseReporting: true), .none)
        XCTAssertEqual(urlClickOpenPolicy(modifierFlags: .shift), .none)
        XCTAssertEqual(urlClickOpenPolicy(clickCount: 2), .none)
    }

    func testGenericURLActionClickPolicyOpensURLAndFileActions() {
        XCTAssertEqual(actionClickOpenPolicy(actionType: .openURL), .externalDefaultBrowser)
        XCTAssertEqual(actionClickOpenPolicy(modifierFlags: .command,
                                             cmdPressed: true,
                                             actionType: .openURL), .inAppBrowser)

        XCTAssertEqual(actionClickOpenPolicy(actionType: .openExistingFile), .semanticHistory)
        XCTAssertEqual(actionClickOpenPolicy(modifierFlags: .command,
                                             cmdPressed: true,
                                             actionType: .openExistingFile), .semanticHistory)
    }

    func testGenericURLActionClickPolicyProtectsMouseReportingWithoutCachedHoverAction() {
        XCTAssertEqual(actionClickOpenPolicy(mouseReporting: true,
                                             actionType: .openURL,
                                             hasCachedHoverAction: false), .none)
        XCTAssertEqual(actionClickOpenPolicy(mouseReporting: true,
                                             actionType: .openExistingFile,
                                             hasCachedHoverAction: false), .none)

        XCTAssertEqual(actionClickOpenPolicy(mouseReporting: true,
                                             actionType: .openURL,
                                             hasCachedHoverAction: true), .externalDefaultBrowser)
        XCTAssertEqual(actionClickOpenPolicy(mouseReporting: true,
                                             actionType: .openExistingFile,
                                             hasCachedHoverAction: true), .semanticHistory)
    }

    func testGenericURLActionClickPolicyRejectsDragSelectionModifiersAndOtherActions() {
        XCTAssertEqual(actionClickOpenPolicy(mouseDragged: true,
                                             actionType: .openExistingFile), .none)
        XCTAssertEqual(actionClickOpenPolicy(clickCount: 2,
                                             actionType: .openExistingFile), .none)
        XCTAssertEqual(actionClickOpenPolicy(modifierFlags: .shift,
                                             actionType: .openExistingFile), .none)
        XCTAssertEqual(actionClickOpenPolicy(modifierFlags: .option,
                                             actionType: .openExistingFile), .none)
        XCTAssertEqual(actionClickOpenPolicy(modifierFlags: .control,
                                             actionType: .openExistingFile), .none)
        XCTAssertEqual(actionClickOpenPolicy(actionType: .smartSelectionAction), .none)
        XCTAssertEqual(actionClickOpenPolicy(actionType: .openImage), .none)
    }

    func testTmuxURLClickDecisionSuppressesMouseReportingForPlainURLHit() {
        XCTAssertTrue(shouldSuppressMouseReportingForPlainURLClick())
    }

    func testTmuxURLClickDecisionReportsPlainNonURLClicksToHost() {
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(urlHit: false))
    }

    func testTmuxURLClickDecisionDoesNotSuppressDragModifierOrMultiClick() {
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(mouseDragged: true))
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(modifierFlags: .command))
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(modifierFlags: .shift))
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(modifierFlags: .option))
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(modifierFlags: .control))
        XCTAssertFalse(shouldSuppressMouseReportingForPlainURLClick(clickCount: 2))
    }

    func testExternalDefaultBrowserPolicyBypassesInAppBrowserInterception() {
        XCTAssertTrue(shouldOpenWebURLInApp("https://example.com",
                                            webPolicy: .automatic,
                                            hasRootView: true))
        XCTAssertFalse(shouldOpenWebURLInApp("https://example.com",
                                             webPolicy: .externalDefaultBrowser,
                                             hasRootView: true))
        XCTAssertFalse(shouldOpenWebURLInApp("https://example.com",
                                             webPolicy: .automatic,
                                             hasRootView: false))
    }

    func testBrowserFocusDecisionAllowsAutomaticForegroundInAppOpen() {
        XCTAssertTrue(shouldFocusInAppBrowserAfterOpen(webPolicy: .automatic,
                                                       inBackground: false,
                                                       hasRootView: true))
    }

    func testBrowserFocusDecisionRejectsBackgroundExternalAndMissingRootView() {
        XCTAssertFalse(shouldFocusInAppBrowserAfterOpen(webPolicy: .automatic,
                                                        inBackground: true,
                                                        hasRootView: true))
        XCTAssertFalse(shouldFocusInAppBrowserAfterOpen(webPolicy: .externalDefaultBrowser,
                                                        inBackground: false,
                                                        hasRootView: true))
        XCTAssertFalse(shouldFocusInAppBrowserAfterOpen(webPolicy: .automatic,
                                                        inBackground: false,
                                                        hasRootView: false))
    }

    func testURLHoverAffordanceAllowsPlainURLAndPlainFilePath() {
        XCTAssertTrue(urlHoverAffordance(actionType: 0))
        XCTAssertTrue(urlHoverAffordance(actionType: 2))
        XCTAssertTrue(urlHoverAffordance(actionType: 2, modifierFlags: .command))
    }

    func testURLHoverAffordanceRejectsOtherActionsAndSelectionModifiers() {
        XCTAssertFalse(urlHoverAffordance(actionType: 1))
        XCTAssertFalse(urlHoverAffordance(actionType: 0, modifierFlags: .shift))
        XCTAssertFalse(urlHoverAffordance(actionType: 2, modifierFlags: .option))
    }

    func testURLHoverMouseMovementTrackingAllowsPlainAndCommandHover() {
        XCTAssertTrue(urlHoverMouseMovementTracking())
        XCTAssertTrue(urlHoverMouseMovementTracking(modifierFlags: .command))
    }

    func testURLHoverMouseMovementTrackingRejectsSelectionModifiers() {
        XCTAssertFalse(urlHoverMouseMovementTracking(modifierFlags: .shift))
        XCTAssertFalse(urlHoverMouseMovementTracking(modifierFlags: .option))
        XCTAssertFalse(urlHoverMouseMovementTracking(modifierFlags: .control))
    }

    func testWorkspacePanelsFollowVisibleTabOrderAfterReorder() {
        let panelA = NSObject()
        let panelB = NSObject()
        let panelC = NSObject()

        let state = tideyPanelOrderState(visibleTabs: [panelB, panelA, panelC],
                                         workspacePanels: [panelA, panelB, panelC],
                                         currentTab: panelB,
                                         fallbackSelection: 1)

        let orderedPanels = state["panels"] as? [NSObject]
        let selectedPanelIndex = state["selectedPanelIndex"] as? NSNumber
        XCTAssertEqual(orderedPanels ?? [], [panelB, panelA, panelC])
        XCTAssertEqual(selectedPanelIndex?.intValue, 0)
    }

    func testWorkspacePanelSelectionFollowsCurrentTabAfterReorder() {
        let panelA = NSObject()
        let panelB = NSObject()
        let panelC = NSObject()

        let state = tideyPanelOrderState(visibleTabs: [panelB, panelA, panelC],
                                         workspacePanels: [panelA, panelB, panelC],
                                         currentTab: panelA,
                                         fallbackSelection: 0)

        let selectedPanelIndex = state["selectedPanelIndex"] as? NSNumber
        XCTAssertEqual(selectedPanelIndex?.intValue, 1)
    }

    func testWorkspacePanelOrderRemainsStableAcrossMultipleReorders() {
        let panelA = NSObject()
        let panelB = NSObject()
        let panelC = NSObject()

        let firstState = tideyPanelOrderState(visibleTabs: [panelB, panelA, panelC],
                                              workspacePanels: [panelA, panelB, panelC],
                                              currentTab: panelB,
                                              fallbackSelection: 1)
        let secondState = tideyPanelOrderState(visibleTabs: [panelC, panelB, panelA],
                                               workspacePanels: firstState["panels"] as? [NSObject] ?? [],
                                               currentTab: panelC,
                                               fallbackSelection: (firstState["selectedPanelIndex"] as? NSNumber)?.intValue ?? 0)

        let orderedPanels = secondState["panels"] as? [NSObject]
        let selectedPanelIndex = secondState["selectedPanelIndex"] as? NSNumber
        XCTAssertEqual(orderedPanels ?? [], [panelC, panelB, panelA])
        XCTAssertEqual(selectedPanelIndex?.intValue, 0)
    }

    func testSidebarSelectionQueryDoesNotOverwriteSelectedPanel() {
        XCTAssertFalse(tideyShouldUpdateSelectedPanelFromVisibleSelection(readingSidebarSelection: true))
    }

    func testWorkspaceSwitchRebuildDoesNotOverwriteSelectedPanelFromTransientTabSelection() {
        XCTAssertFalse(tideyShouldUpdateSelectedPanelFromVisibleSelection(switchingWorkspace: true))
        XCTAssertFalse(tideyShouldUpdateSelectedPanelFromVisibleSelection(rebuildingVisibleWorkspace: true))
    }

    func testUserPanelSelectionStillUpdatesSelectedPanel() {
        XCTAssertTrue(tideyShouldUpdateSelectedPanelFromVisibleSelection())
    }

    func testStaleSidebarIgnoreDoesNotSwallowUserWorkspaceClick() {
        XCTAssertTrue(tideyShouldForwardSidebarSelectionChange(ignoreNextSelection: true,
                                                              selectedRow: 1,
                                                              modelSelectedRow: 0,
                                                              numberOfRows: 3))
    }

    func testProgrammaticSidebarSelectionChangeStillDoesNotForward() {
        XCTAssertFalse(tideyShouldForwardSidebarSelectionChange(ignoreNextSelection: true,
                                                               selectedRow: 1,
                                                               modelSelectedRow: 1,
                                                               numberOfRows: 3))
    }

    func testSidebarSelectionRejectsInvalidRows() {
        XCTAssertFalse(tideyShouldForwardSidebarSelectionChange(ignoreNextSelection: false,
                                                               selectedRow: -1,
                                                               modelSelectedRow: 0,
                                                               numberOfRows: 3))
        XCTAssertFalse(tideyShouldForwardSidebarSelectionChange(ignoreNextSelection: false,
                                                               selectedRow: 3,
                                                               modelSelectedRow: 0,
                                                               numberOfRows: 3))
    }

    func testPendingPanelInsertIntoBackgroundWorkspaceDoesNotUseVisibleTabView() {
        XCTAssertTrue(tideyShouldManagePendingPanelInsert(pendingWorkspaceIndex: 0, createWorkspace: false))
        XCTAssertFalse(tideyShouldInsertPendingPanelIntoVisibleTabs(selectedWorkspaceIndex: 1,
                                                                    targetWorkspaceIndex: 0,
                                                                    createWorkspace: false))
    }

    func testPendingPanelInsertIntoCurrentWorkspaceUsesVisibleTabView() {
        XCTAssertTrue(tideyShouldManagePendingPanelInsert(pendingWorkspaceIndex: 1, createWorkspace: false))
        XCTAssertTrue(tideyShouldInsertPendingPanelIntoVisibleTabs(selectedWorkspaceIndex: 1,
                                                                   targetWorkspaceIndex: 1,
                                                                   createWorkspace: false))
    }

    func testPendingPanelInsertForNewWorkspaceDoesNotUseVisibleTabView() {
        XCTAssertTrue(tideyShouldManagePendingPanelInsert(pendingWorkspaceIndex: 2, createWorkspace: true))
        XCTAssertFalse(tideyShouldInsertPendingPanelIntoVisibleTabs(selectedWorkspaceIndex: 1,
                                                                    targetWorkspaceIndex: 2,
                                                                    createWorkspace: true))
    }

    func testVisibleWorkspaceRebuildAlwaysUsesVisibleTabView() {
        XCTAssertFalse(tideyShouldManagePendingPanelInsert(pendingWorkspaceIndex: -1, createWorkspace: false))
        XCTAssertTrue(tideyShouldInsertPendingPanelIntoVisibleTabs(selectedWorkspaceIndex: 1,
                                                                   targetWorkspaceIndex: 0,
                                                                   createWorkspace: false,
                                                                   rebuildingVisibleWorkspace: true))
    }

    func testTerminalEnvironmentScrubRemovesOnlyBundleIdentifier() {
        let scrubbed = scrubbedTerminalIdentityEnvironment([
            "CMUX_SURFACE_ID": "surface",
            "CMUX_PANEL_ID": "panel",
            "GHOSTTY_BIN_DIR": "/Applications/cmux.app/Contents/MacOS",
            "__CFBundleIdentifier": "com.cmuxterm.app",
            "PATH": "/usr/bin:/bin",
            "TIDEY_SOCKET_PATH": "/tmp/tidey.sock",
        ])

        XCTAssertEqual(scrubbed["CMUX_SURFACE_ID"], "surface")
        XCTAssertEqual(scrubbed["CMUX_PANEL_ID"], "panel")
        XCTAssertEqual(scrubbed["GHOSTTY_BIN_DIR"], "/Applications/cmux.app/Contents/MacOS")
        XCTAssertNil(scrubbed["__CFBundleIdentifier"])
        XCTAssertEqual(scrubbed["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(scrubbed["TIDEY_SOCKET_PATH"], "/tmp/tidey.sock")
    }

    func testTmuxEnvironmentCleanupCommandRemovesOnlyBundleIdentifier() {
        let command = tmuxEnvironmentCleanupCommand(tmuxBinaryPath: "/opt/homebrew/bin/tmux")

        XCTAssertTrue(command.contains("set-environment -gu __CFBundleIdentifier"))
        XCTAssertFalse(command.contains("set-environment -gu CMUX_SURFACE_ID"))
        XCTAssertFalse(command.contains("set-environment -gu GHOSTTY_BIN_DIR"))
        XCTAssertFalse(command.contains("CMUX_SOCKET_PATH"))
        XCTAssertTrue(command.contains("TIDEY_SOCKET_PATH"))
        XCTAssertTrue(command.contains("TIDEY_WORKSPACE_ID"))
        XCTAssertTrue(command.contains("TIDEY_PANEL_ID"))
    }

    func testOrdinaryTmuxAttachDetectorFindsTargetSession() {
        let metadata = ordinaryTmuxAttachMetadata(commandLine: "tmux a -t genesis-extraction")

        XCTAssertEqual(metadata?["target_session"], "genesis-extraction")
        XCTAssertEqual(metadata?["attach_command"], "a")
        XCTAssertEqual(metadata?["client_tty"], "/dev/ttys001")
    }

    func testOrdinaryTmuxAttachDetectorCapturesSocketPathAndAttachSession() {
        let metadata = ordinaryTmuxAttachMetadata(commandLine: "tmux -S /tmp/tmux-501/default attach-session -t genesis-extraction")

        XCTAssertEqual(metadata?["socket_path"], "/tmp/tmux-501/default")
        XCTAssertEqual(metadata?["target_session"], "genesis-extraction")
        XCTAssertEqual(metadata?["attach_command"], "attach-session")
    }

    func testOrdinaryTmuxAttachDetectorIgnoresControlModeTmux() {
        let metadata = ordinaryTmuxAttachMetadata(commandLine: "tmux -CC attach -t genesis-extraction")

        XCTAssertNil(metadata)
    }

    func testOrdinaryTmuxAttachDetectorIgnoresExistingTmuxClientSession() {
        let metadata = ordinaryTmuxAttachMetadata(commandLine: "tmux a -t genesis-extraction",
                                                  isTmuxClient: true)

        XCTAssertNil(metadata)
    }

    func testOrdinaryTmuxAttachDetectorIgnoresNonAttachCommands() {
        let metadata = ordinaryTmuxAttachMetadata(commandLine: "tmux list-windows -t genesis-extraction")

        XCTAssertNil(metadata)
    }

    func testPreparedTerminalEnvironmentUsesPreScrubBundleIdentifierForTmuxCleanup() {
        let prepared = preparedTerminalEnvironmentAndCleanup([
            "CMUX_SURFACE_ID": "surface",
            "GHOSTTY_BIN_DIR": "/Applications/cmux.app/Contents/MacOS",
            "PATH": "/usr/bin:/bin",
        ])

        let scrubbed = prepared["environment"] as? [String: String]
        let command = prepared["tmuxCleanupCommand"] as? String

        XCTAssertEqual(scrubbed?["CMUX_SURFACE_ID"], "surface")
        XCTAssertEqual(scrubbed?["GHOSTTY_BIN_DIR"], "/Applications/cmux.app/Contents/MacOS")
        XCTAssertNil(scrubbed?["__CFBundleIdentifier"])
        XCTAssertEqual(scrubbed?["PATH"], "/usr/bin:/bin")
        XCTAssertTrue(command == nil || command?.contains("set-environment -gu __CFBundleIdentifier") == true)
    }

    func testResolvedExecutablePathUsesSearchPathBeforeFallbacks() {
        let resolved = resolvedExecutablePath(name: "sh",
                                              searchPATH: "/bin:/usr/bin",
                                              fallbackPaths: ["/definitely/not/here/sh"])
        XCTAssertEqual(resolved, "/bin/sh")
    }

    func testResolvedExecutablePathFallsBackToKnownLocations() {
        let resolved = resolvedExecutablePath(name: "sh",
                                              searchPATH: "",
                                              fallbackPaths: ["/definitely/not/here/sh", "/bin/sh"])
        XCTAssertEqual(resolved, "/bin/sh")
    }

    func testResolvedExecutablePathReturnsNilWhenNoCandidateIsExecutable() {
        let resolved = resolvedExecutablePath(name: "missing-binary",
                                              searchPATH: "/definitely/not/here",
                                              fallbackPaths: ["/also/missing/binary"])
        XCTAssertNil(resolved)
    }

    func testTmuxBinaryFallbackPathsCoverCommonInstallLocations() {
        let fallbacks = tmuxBinaryFallbackPaths()
        XCTAssertEqual(fallbacks, [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ])
    }
}

final class ClaudeHookRegistryTests: XCTestCase {
    func testClaudeHookInputContextReadsSessionIDTranscriptPathAndCWD() throws {
        let stdinJSON = """
        {
          "session_id": "c211f108-d22f-4813-bde4-a72c5241034a",
          "transcript_path": "~/Library/Application Support/Claude/test.jsonl",
          "cwd": "/Users/timfeng/GitHub/Tidey",
          "hook_event_name": "SessionStart",
          "last_assistant_message": "Done"
        }
        """

        let context = TideyCLICommandFormatter.claudeHookInputContext(stdinData: stdinJSON.data(using: .utf8))

        XCTAssertEqual(context?.sessionID, "c211f108-d22f-4813-bde4-a72c5241034a")
        XCTAssertEqual(context?.transcriptPath, "~/Library/Application Support/Claude/test.jsonl")
        XCTAssertEqual(context?.cwd, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(context?.lastAssistantMessage, "Done")
    }

    func testClaudeHookInputContextFallsBackToTranscriptFilenameForSessionID() throws {
        let stdinJSON = """
        {
          "transcript_path": "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl",
          "cwd": "/Users/timfeng"
        }
        """

        let context = TideyCLICommandFormatter.claudeHookInputContext(stdinData: stdinJSON.data(using: .utf8))

        XCTAssertEqual(context?.sessionID, "c211f108-d22f-4813-bde4-a72c5241034a")
    }

    func testClaudeStopNotificationPrefersHookPayloadOverTranscript() throws {
        let stdinJSON = """
        {
          "session_id": "c211f108-d22f-4813-bde4-a72c5241034a",
          "transcript_path": "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl",
          "cwd": "/Users/timfeng/GitHub/Tidey",
          "hook_event_name": "Stop",
          "last_assistant_message": "Latest assistant reply"
        }
        """

        let transcript = """
        {"message":{"role":"assistant","content":[{"type":"text","text":"Older assistant reply"}]}}
        """

        let messages = TideyCLICommandFormatter.messages(forClaudeHookEvent: "stop",
                                                         workspaceID: "ws-1",
                                                         stdinJSON: stdinJSON,
                                                         transcriptContent: transcript)

        XCTAssertEqual(messages, [
            "{\"action\":\"notification.create\",\"workspace_id\":\"ws-1\",\"title\":\"Claude Code\",\"body\":\"Latest assistant reply\"}",
            "report_shell_state prompt --workspace_id=ws-1"
        ])
    }

    func testClaudeStopNotificationFallsBackToTranscriptWhenHookPayloadIsMissing() throws {
        let stdinJSON = """
        {
          "session_id": "c211f108-d22f-4813-bde4-a72c5241034a",
          "transcript_path": "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl",
          "cwd": "/Users/timfeng/GitHub/Tidey",
          "hook_event_name": "Stop"
        }
        """

        let transcript = """
        {"message":{"role":"assistant","content":[{"type":"text","text":"Transcript assistant reply"}]}}
        """

        let messages = TideyCLICommandFormatter.messages(forClaudeHookEvent: "stop",
                                                         workspaceID: "ws-1",
                                                         stdinJSON: stdinJSON,
                                                         transcriptContent: transcript)

        XCTAssertEqual(messages, [
            "{\"action\":\"notification.create\",\"workspace_id\":\"ws-1\",\"title\":\"Claude Code\",\"body\":\"Transcript assistant reply\"}",
            "report_shell_state prompt --workspace_id=ws-1"
        ])
    }

    func testWriteAndRemoveClaudeRegistryFile() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let writtenURL = try TideyCLICommandFormatter.writeClaudeRegistryFile(
            registryRoot: tempRoot,
            workspaceID: "ws-1",
            sessionID: "c211f108-d22f-4813-bde4-a72c5241034a",
            panelID: "panel-1",
            pid: 12345,
            cwd: "/Users/timfeng/GitHub/Tidey",
            createdAt: "2026-04-13T03:35:00Z",
            transcriptPath: "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl"
        )

        let data = try Data(contentsOf: writtenURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(object?["version"] as? Int, 1)
        XCTAssertEqual(object?["vendor"] as? String, "claude")
        XCTAssertEqual(object?["workspace_id"] as? String, "ws-1")
        XCTAssertEqual(object?["session_id"] as? String, "c211f108-d22f-4813-bde4-a72c5241034a")
        XCTAssertEqual(object?["panel_id"] as? String, "panel-1")
        XCTAssertEqual(object?["pid"] as? Int, 12345)
        XCTAssertEqual(object?["cwd"] as? String, "/Users/timfeng/GitHub/Tidey")
        XCTAssertEqual(object?["created_at"] as? String, "2026-04-13T03:35:00Z")
        XCTAssertEqual(object?["transcript_path"] as? String, "/Users/timfeng/.claude/projects/-Users-timfeng/c211f108-d22f-4813-bde4-a72c5241034a.jsonl")

        try TideyCLICommandFormatter.removeClaudeRegistryFile(registryRoot: tempRoot,
                                                              sessionID: "c211f108-d22f-4813-bde4-a72c5241034a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))
    }
}

final class CodexWrapperRegistryTests: XCTestCase {
    func testCodexWrapperWritesRegistryUsingLauncherChildRollout() throws {
        let sessionID = "22222222-2222-2222-2222-222222222222"
        let environment = try makeCodexWrapperTestEnvironment(initialSessionID: sessionID)
        let process = try launchCodexWrapper(environment: environment)
        defer { terminate(process) }

        let registryURL = environment.registryRoot.appendingPathComponent("codex-\(sessionID).json")
        let object = try waitForRegistryJSON(at: registryURL)

        XCTAssertEqual(object["session_id"] as? String, sessionID)
        XCTAssertEqual(object["workspace_id"] as? String, "ws-test")
        XCTAssertEqual(object["panel_id"] as? String, "panel-test")
        XCTAssertEqual(object["rollout_path"] as? String, environment.initialRolloutPath)
        XCTAssertEqual(object["transcript_path"] as? String, environment.initialRolloutPath)
    }

    func testCodexWrapperRewritesRegistryWhenLauncherChildRolloutChanges() throws {
        let firstSessionID = "22222222-2222-2222-2222-222222222222"
        let secondSessionID = "33333333-3333-3333-3333-333333333333"
        let environment = try makeCodexWrapperTestEnvironment(initialSessionID: firstSessionID,
                                                              nextSessionID: secondSessionID)
        let process = try launchCodexWrapper(environment: environment)
        defer { terminate(process) }

        let firstRegistryURL = environment.registryRoot.appendingPathComponent("codex-\(firstSessionID).json")
        _ = try waitForRegistryJSON(at: firstRegistryURL)

        let secondRegistryURL = environment.registryRoot.appendingPathComponent("codex-\(secondSessionID).json")
        let object = try waitForRegistryJSON(at: secondRegistryURL, timeout: 5.0)

        XCTAssertEqual(object["session_id"] as? String, secondSessionID)
        XCTAssertEqual(object["rollout_path"] as? String, environment.nextRolloutPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRegistryURL.path))
    }

    private func makeCodexWrapperTestEnvironment(initialSessionID: String,
                                                 nextSessionID: String? = nil) throws -> CodexWrapperTestEnvironment {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let fakeHome = root.appendingPathComponent("home", isDirectory: true)
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        let registryRoot = fakeHome
            .appendingPathComponent("Library/Application Support/Tidey Remote Bridge/agent-sessions/codex",
                                    isDirectory: true)
        let codexSessionsRoot = fakeHome.appendingPathComponent(".codex/sessions/2099/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSessionsRoot, withIntermediateDirectories: true)

        let initialRolloutPath = codexSessionsRoot
            .appendingPathComponent("rollout-test-\(initialSessionID).jsonl").path
        FileManager.default.createFile(atPath: initialRolloutPath,
                                       contents: Data("{\"event\":\"initial\"}\n".utf8))

        let nextRolloutPath: String?
        if let nextSessionID {
            let path = codexSessionsRoot
                .appendingPathComponent("rollout-test-\(nextSessionID).jsonl").path
            FileManager.default.createFile(atPath: path,
                                           contents: Data("{\"event\":\"next\"}\n".utf8))
            nextRolloutPath = path
        } else {
            nextRolloutPath = nil
        }

        let rolloutStateFile = root.appendingPathComponent("rollout-state.txt")
        try initialRolloutPath.write(to: rolloutStateFile, atomically: true, encoding: .utf8)

        try writeExecutable(at: fakeBin.appendingPathComponent("pgrep"), contents: """
        #!/usr/bin/env bash
        if [[ "${1:-}" == "-P" ]]; then
            printf '%s\\n' "${FAKE_CODEX_CHILD_PID:-99999}"
        fi
        """)

        try writeExecutable(at: fakeBin.appendingPathComponent("lsof"), contents: """
        #!/usr/bin/env bash
        pid=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == "-p" && $# -ge 2 ]]; then
                pid="$2"
                shift 2
                continue
            fi
            shift
        done
        if [[ "$pid" == "${FAKE_CODEX_CHILD_PID:-99999}" && -f "$FAKE_ROLLOUT_STATE_FILE" ]]; then
            path="$(cat "$FAKE_ROLLOUT_STATE_FILE")"
            if [[ -n "$path" ]]; then
                printf 'n%s\\n' "$path"
            fi
        fi
        """)

        try writeExecutable(at: fakeBin.appendingPathComponent("codex"), contents: """
        #!/usr/bin/env bash
        if [[ -n "${FAKE_NEXT_ROLLOUT_PATH:-}" ]]; then
            sleep 1
            printf '%s' "$FAKE_NEXT_ROLLOUT_PATH" > "$FAKE_ROLLOUT_STATE_FILE"
            sleep 2
        else
            sleep 2
        fi
        """)

        let socketPath = root.appendingPathComponent("tidey.sock").path
        let socketHandle = try UNIXSocketFile(path: socketPath)
        addTeardownBlock {
            socketHandle.close()
        }

        return CodexWrapperTestEnvironment(root: root,
                                           fakeHome: fakeHome,
                                           fakeBin: fakeBin,
                                           registryRoot: registryRoot,
                                           rolloutStateFile: rolloutStateFile.path,
                                           initialRolloutPath: initialRolloutPath,
                                           nextRolloutPath: nextRolloutPath,
                                           socketPath: socketPath)
    }

    private func launchCodexWrapper(environment: CodexWrapperTestEnvironment) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/timfeng/GitHub/Tidey/Resources/bin/codex")
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = environment.fakeHome.path
        env["PATH"] = "\(environment.fakeBin.path):/usr/bin:/bin"
        env["TIDEY_SOCKET_PATH"] = environment.socketPath
        env["TIDEY_WORKSPACE_ID"] = "ws-test"
        env["TIDEY_PANEL_ID"] = "panel-test"
        env["FAKE_CODEX_CHILD_PID"] = "99999"
        env["FAKE_ROLLOUT_STATE_FILE"] = environment.rolloutStateFile
        if let nextRolloutPath = environment.nextRolloutPath {
            env["FAKE_NEXT_ROLLOUT_PATH"] = nextRolloutPath
        }
        process.environment = env
        try process.run()
        return process
    }

    private func waitForRegistryJSON(at url: URL, timeout: TimeInterval = 3.0) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for registry at \(url.path)")
        return [:]
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct CodexWrapperTestEnvironment {
    let root: URL
    let fakeHome: URL
    let fakeBin: URL
    let registryRoot: URL
    let rolloutStateFile: String
    let initialRolloutPath: String
    let nextRolloutPath: String?
    let socketPath: String
}

private final class UNIXSocketFile {
    private let path: String
    private var fd: Int32

    init(path: String) throws {
        self.path = path
        self.fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            path.withCString { source in
                strncpy(pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { $0 },
                        source,
                        maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        listen(fd, 1)
    }

    func close() {
        guard fd >= 0 else {
            unlink(path)
            return
        }
        Darwin.close(fd)
        fd = -1
        unlink(path)
    }

    deinit {
        close()
    }
}
