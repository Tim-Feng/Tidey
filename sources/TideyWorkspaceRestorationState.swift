import Foundation

@objc(TideyWorkspaceState)
@objcMembers
final class TideyWorkspaceState: NSObject {
    let workspaceID: String
    let title: String?
    let pinned: Bool
    let panelIDs: [String]
    let selectedPanelID: String?

    init(workspaceID: String,
         title: String?,
         pinned: Bool,
         panelIDs: [String],
         selectedPanelID: String?) {
        self.workspaceID = workspaceID
        self.title = title
        self.pinned = pinned
        self.panelIDs = panelIDs
        self.selectedPanelID = selectedPanelID
    }
}

@objc(TideyWorkspaceRestorationState)
@objcMembers
final class TideyWorkspaceRestorationState: NSObject {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let selectedWorkspaceID: String?
    let workspaces: [TideyWorkspaceState]

    init(schemaVersion: Int,
         selectedWorkspaceID: String?,
         workspaces: [TideyWorkspaceState]) {
        self.schemaVersion = schemaVersion
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }
}

protocol TideyWorkspaceRestorationStateDictionaryCoding {
    func encode(_ state: TideyWorkspaceRestorationState) throws -> [String: Any]
    func decode(_ dictionary: [String: Any]) throws -> TideyWorkspaceRestorationState
}

enum TideyWorkspaceRestorationStateCodecError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case malformedField(String)
    case duplicateWorkspaceID(String)
    case duplicatePanelID(String)
}
