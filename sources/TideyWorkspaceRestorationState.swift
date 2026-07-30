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

@objc(TideyWorkspaceRestorationStateDictionaryCodec)
@objcMembers
final class TideyWorkspaceRestorationStateDictionaryCodec: NSObject,
                                                            TideyWorkspaceRestorationStateDictionaryCoding {
    func encode(_ state: TideyWorkspaceRestorationState) throws -> [String: Any] {
        try validate(state)

        var dictionary: [String: Any] = [
            "schema_version": state.schemaVersion,
            "workspaces": state.workspaces.map(encodeWorkspace)
        ]
        if let selectedWorkspaceID = state.selectedWorkspaceID {
            dictionary["selected_workspace_id"] = selectedWorkspaceID
        }
        return dictionary
    }

    func decode(_ dictionary: [String: Any]) throws -> TideyWorkspaceRestorationState {
        guard let schemaVersion = dictionary["schema_version"] as? Int else {
            throw TideyWorkspaceRestorationStateCodecError.malformedField("schema_version")
        }
        guard schemaVersion == TideyWorkspaceRestorationState.currentSchemaVersion else {
            throw TideyWorkspaceRestorationStateCodecError.unsupportedSchemaVersion(schemaVersion)
        }
        let selectedWorkspaceID = try optionalIdentity(
            dictionary["selected_workspace_id"],
            field: "selected_workspace_id"
        )
        guard let encodedWorkspaces = dictionary["workspaces"] as? [Any] else {
            throw TideyWorkspaceRestorationStateCodecError.malformedField("workspaces")
        }

        let workspaces = try encodedWorkspaces.map(decodeWorkspace)
        let state = TideyWorkspaceRestorationState(
            schemaVersion: schemaVersion,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces
        )
        try validate(state)
        return state
    }

    private func encodeWorkspace(_ workspace: TideyWorkspaceState) -> [String: Any] {
        var dictionary: [String: Any] = [
            "workspace_id": workspace.workspaceID,
            "pinned": workspace.pinned,
            "panel_ids": workspace.panelIDs
        ]
        if let title = workspace.title {
            dictionary["title"] = title
        }
        if let selectedPanelID = workspace.selectedPanelID {
            dictionary["selected_panel_id"] = selectedPanelID
        }
        return dictionary
    }

    private func decodeWorkspace(_ value: Any) throws -> TideyWorkspaceState {
        guard let dictionary = value as? [String: Any] else {
            throw TideyWorkspaceRestorationStateCodecError.malformedField("workspaces")
        }
        let workspaceID = try requiredIdentity(dictionary["workspace_id"], field: "workspace_id")
        let title: String?
        if let value = dictionary["title"] {
            guard let decodedTitle = value as? String else {
                throw TideyWorkspaceRestorationStateCodecError.malformedField("title")
            }
            title = decodedTitle
        } else {
            title = nil
        }
        guard let pinned = dictionary["pinned"] as? Bool else {
            throw TideyWorkspaceRestorationStateCodecError.malformedField("pinned")
        }
        guard let encodedPanelIDs = dictionary["panel_ids"] as? [Any] else {
            throw TideyWorkspaceRestorationStateCodecError.malformedField("panel_ids")
        }
        let panelIDs = try encodedPanelIDs.map {
            try requiredIdentity($0, field: "panel_ids")
        }
        let selectedPanelID = try optionalIdentity(
            dictionary["selected_panel_id"],
            field: "selected_panel_id"
        )

        return TideyWorkspaceState(
            workspaceID: workspaceID,
            title: title,
            pinned: pinned,
            panelIDs: panelIDs,
            selectedPanelID: selectedPanelID
        )
    }

    private func requiredIdentity(_ value: Any?, field: String) throws -> String {
        guard let identity = value as? String, !identity.isEmpty else {
            throw TideyWorkspaceRestorationStateCodecError.malformedField(field)
        }
        return identity
    }

    private func optionalIdentity(_ value: Any?, field: String) throws -> String? {
        guard let value else {
            return nil
        }
        return try requiredIdentity(value, field: field)
    }

    private func validate(_ state: TideyWorkspaceRestorationState) throws {
        guard state.schemaVersion == TideyWorkspaceRestorationState.currentSchemaVersion else {
            throw TideyWorkspaceRestorationStateCodecError.unsupportedSchemaVersion(state.schemaVersion)
        }
        if let selectedWorkspaceID = state.selectedWorkspaceID {
            _ = try requiredIdentity(selectedWorkspaceID, field: "selected_workspace_id")
        }

        var workspaceIDs = Set<String>()
        var panelIDs = Set<String>()
        for workspace in state.workspaces {
            let workspaceID = try requiredIdentity(workspace.workspaceID, field: "workspace_id")
            guard workspaceIDs.insert(workspaceID).inserted else {
                throw TideyWorkspaceRestorationStateCodecError.duplicateWorkspaceID(workspaceID)
            }
            if let selectedPanelID = workspace.selectedPanelID {
                _ = try requiredIdentity(selectedPanelID, field: "selected_panel_id")
            }
            for panelID in workspace.panelIDs {
                let panelID = try requiredIdentity(panelID, field: "panel_ids")
                guard panelIDs.insert(panelID).inserted else {
                    throw TideyWorkspaceRestorationStateCodecError.duplicatePanelID(panelID)
                }
            }
        }
    }
}
