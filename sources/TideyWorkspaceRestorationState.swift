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
    let runtimeDescriptorsByPanelID:
        [String: TideyRuntimeResumeDescriptor]

    init(schemaVersion: Int,
         selectedWorkspaceID: String?,
         workspaces: [TideyWorkspaceState],
         runtimeDescriptorsByPanelID:
            [String: TideyRuntimeResumeDescriptor]) {
        self.schemaVersion = schemaVersion
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
        self.runtimeDescriptorsByPanelID =
            runtimeDescriptorsByPanelID
    }

    convenience init(schemaVersion: Int,
                     selectedWorkspaceID: String?,
                     workspaces: [TideyWorkspaceState]) {
        self.init(
            schemaVersion: schemaVersion,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces,
            runtimeDescriptorsByPanelID: [:]
        )
    }
}

@objc(TideyWorkspaceRestorationPanelInput)
@objcMembers
final class TideyWorkspaceRestorationPanelInput: NSObject {
    let panelID: String
    let hasSessions: Bool
    let isNativeTmux: Bool
    let runtimeResumeDescriptor: TideyRuntimeResumeDescriptor?

    init(panelID: String,
         hasSessions: Bool,
         isNativeTmux: Bool,
         runtimeResumeDescriptor: TideyRuntimeResumeDescriptor?) {
        self.panelID = panelID
        self.hasSessions = hasSessions
        self.isNativeTmux = isNativeTmux
        self.runtimeResumeDescriptor = runtimeResumeDescriptor
    }

    convenience init(panelID: String,
                     hasSessions: Bool,
                     isNativeTmux: Bool) {
        self.init(
            panelID: panelID,
            hasSessions: hasSessions,
            isNativeTmux: isNativeTmux,
            runtimeResumeDescriptor: nil
        )
    }
}

@objc(TideyWorkspaceRestorationWorkspaceInput)
@objcMembers
final class TideyWorkspaceRestorationWorkspaceInput: NSObject {
    let workspaceID: String
    let title: String?
    let pinned: Bool
    let panels: [TideyWorkspaceRestorationPanelInput]
    let selectedPanelID: String?

    init(workspaceID: String,
         title: String?,
         pinned: Bool,
         panels: [TideyWorkspaceRestorationPanelInput],
         selectedPanelID: String?) {
        self.workspaceID = workspaceID
        self.title = title
        self.pinned = pinned
        self.panels = panels
        self.selectedPanelID = selectedPanelID
    }
}

@objc(TideyWorkspaceRestorationCapturePlan)
@objcMembers
final class TideyWorkspaceRestorationCapturePlan: NSObject {
    let state: TideyWorkspaceRestorationState
    let flattenedNativePanelIDs: [String]

    init(state: TideyWorkspaceRestorationState,
         flattenedNativePanelIDs: [String]) {
        self.state = state
        self.flattenedNativePanelIDs = flattenedNativePanelIDs
    }
}

@objc(TideyWorkspaceRestorationPlanning)
protocol TideyWorkspaceRestorationPlanning: NSObjectProtocol {
    @objc(capturePlanWithWorkspaces:visiblePanels:selectedWorkspaceID:)
    func capturePlan(
        workspaces: [TideyWorkspaceRestorationWorkspaceInput],
        visiblePanels: [TideyWorkspaceRestorationPanelInput],
        selectedWorkspaceID: String?
    ) -> TideyWorkspaceRestorationCapturePlan

    @objc(hydrationStateWithSavedState:availablePanelIDs:panelIDRemap:)
    func hydrationState(
        savedState: TideyWorkspaceRestorationState,
        availablePanelIDs: [String],
        panelIDRemap: [String: String]
    ) -> TideyWorkspaceRestorationState
}

@objc(TideyWorkspaceRestorationPlanner)
@objcMembers
final class TideyWorkspaceRestorationPlanner: NSObject, TideyWorkspaceRestorationPlanning {
    func capturePlan(
        workspaces: [TideyWorkspaceRestorationWorkspaceInput],
        visiblePanels: [TideyWorkspaceRestorationPanelInput],
        selectedWorkspaceID: String?
    ) -> TideyWorkspaceRestorationCapturePlan {
        guard !workspaces.isEmpty else {
            let restorablePanels = restorablePanels(in: visiblePanels)
            return TideyWorkspaceRestorationCapturePlan(
                state: TideyWorkspaceRestorationState(
                    schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
                    selectedWorkspaceID: nil,
                    workspaces: [],
                    runtimeDescriptorsByPanelID:
                        runtimeDescriptors(in: restorablePanels)
                ),
                flattenedNativePanelIDs:
                    restorablePanels.map(\.panelID)
            )
        }

        var flattenedPanelIDs = [String]()
        var workspaceStates = [TideyWorkspaceState]()
        var runtimeDescriptorsByPanelID =
            [String: TideyRuntimeResumeDescriptor]()
        for workspace in workspaces {
            let restorablePanels =
                restorablePanels(in: workspace.panels)
            let panelIDs = restorablePanels.map(\.panelID)
            guard !panelIDs.isEmpty else {
                continue
            }
            flattenedPanelIDs.append(contentsOf: panelIDs)
            runtimeDescriptorsByPanelID.merge(
                runtimeDescriptors(in: restorablePanels)
            ) { _, replacement in
                replacement
            }
            let selectedPanelID = workspace.selectedPanelID.flatMap {
                panelIDs.contains($0) ? $0 : nil
            }
            workspaceStates.append(
                TideyWorkspaceState(
                    workspaceID: workspace.workspaceID,
                    title: workspace.title,
                    pinned: workspace.pinned,
                    panelIDs: panelIDs,
                    selectedPanelID: selectedPanelID
                )
            )
        }

        let capturedWorkspaceIDs = Set(workspaceStates.map(\.workspaceID))
        let capturedSelectedWorkspaceID = selectedWorkspaceID.flatMap {
            capturedWorkspaceIDs.contains($0) ? $0 : nil
        }
        return TideyWorkspaceRestorationCapturePlan(
            state: TideyWorkspaceRestorationState(
                schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
                selectedWorkspaceID: capturedSelectedWorkspaceID,
                workspaces: workspaceStates,
                runtimeDescriptorsByPanelID:
                    runtimeDescriptorsByPanelID
            ),
            flattenedNativePanelIDs: flattenedPanelIDs
        )
    }

    func hydrationState(
        savedState: TideyWorkspaceRestorationState,
        availablePanelIDs: [String],
        panelIDRemap: [String: String]
    ) -> TideyWorkspaceRestorationState {
        let availablePanelIDSet = Set(availablePanelIDs)
        var claimedPanelIDs = Set<String>()
        let hydratedWorkspaces: [TideyWorkspaceState] = savedState.workspaces.compactMap {
            workspace -> TideyWorkspaceState? in
            let panelIDs = workspace.panelIDs.compactMap { savedPanelID -> String? in
                let actualPanelID = panelIDRemap[savedPanelID] ?? savedPanelID
                guard availablePanelIDSet.contains(actualPanelID),
                      claimedPanelIDs.insert(actualPanelID).inserted else {
                    return nil
                }
                return actualPanelID
            }
            guard !panelIDs.isEmpty else {
                return nil
            }
            let selectedPanelID = workspace.selectedPanelID
                .map { panelIDRemap[$0] ?? $0 }
                .flatMap { panelIDs.contains($0) ? $0 : nil }
            return TideyWorkspaceState(
                workspaceID: workspace.workspaceID,
                title: workspace.title,
                pinned: workspace.pinned,
                panelIDs: panelIDs,
                selectedPanelID: selectedPanelID
            )
        }
        let hydratedWorkspaceIDs = Set(hydratedWorkspaces.map(\.workspaceID))
        let selectedWorkspaceID = savedState.selectedWorkspaceID.flatMap {
            hydratedWorkspaceIDs.contains($0) ? $0 : nil
        }
        var hydratedDescriptors =
            [String: TideyRuntimeResumeDescriptor]()
        for savedPanelID in
                savedState.runtimeDescriptorsByPanelID.keys.sorted() {
            let actualPanelID =
                panelIDRemap[savedPanelID] ?? savedPanelID
            guard availablePanelIDSet.contains(actualPanelID),
                  hydratedDescriptors[actualPanelID] == nil,
                  let descriptor =
                    savedState.runtimeDescriptorsByPanelID[savedPanelID] else {
                continue
            }
            hydratedDescriptors[actualPanelID] = descriptor
        }
        return TideyWorkspaceRestorationState(
            schemaVersion: savedState.schemaVersion,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: hydratedWorkspaces,
            runtimeDescriptorsByPanelID: hydratedDescriptors
        )
    }

    private func restorablePanels(
        in panels: [TideyWorkspaceRestorationPanelInput]
    ) -> [TideyWorkspaceRestorationPanelInput] {
        panels.filter { panel in
            guard panel.hasSessions,
                  !panel.isNativeTmux,
                  !panel.panelID.isEmpty else {
                return false
            }
            return true
        }
    }

    private func runtimeDescriptors(
        in panels: [TideyWorkspaceRestorationPanelInput]
    ) -> [String: TideyRuntimeResumeDescriptor] {
        Dictionary(
            panels.compactMap { panel in
                panel.runtimeResumeDescriptor.map {
                    (panel.panelID, $0)
                }
            },
            uniquingKeysWith: { _, replacement in
                replacement
            }
        )
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
            "workspaces": state.workspaces.map(encodeWorkspace),
            "runtime_descriptors_by_panel_id":
                encodeRuntimeDescriptors(
                    state.runtimeDescriptorsByPanelID
                )
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
        let runtimeDescriptors = decodeRuntimeDescriptors(
            dictionary["runtime_descriptors_by_panel_id"]
        )
        let state = TideyWorkspaceRestorationState(
            schemaVersion: schemaVersion,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces,
            runtimeDescriptorsByPanelID: runtimeDescriptors
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

    private func encodeRuntimeDescriptors(
        _ descriptors: [String: TideyRuntimeResumeDescriptor]
    ) -> [String: Any] {
        let codec = TideyRuntimeResumeDescriptorDictionaryCodec()
        var encoded = [String: Any]()
        for panelID in descriptors.keys.sorted()
        where !panelID.isEmpty {
            guard let descriptor = descriptors[panelID],
                  let dictionary = try? codec.encode(descriptor) else {
                continue
            }
            encoded[panelID] = dictionary
        }
        return encoded
    }

    private func decodeRuntimeDescriptors(
        _ value: Any?
    ) -> [String: TideyRuntimeResumeDescriptor] {
        guard let dictionaries = value as? [String: Any] else {
            return [:]
        }
        let codec = TideyRuntimeResumeDescriptorDictionaryCodec()
        var descriptors =
            [String: TideyRuntimeResumeDescriptor]()
        for panelID in dictionaries.keys.sorted()
        where !panelID.isEmpty {
            guard let dictionary =
                    dictionaries[panelID] as? [String: Any],
                  let descriptor = try? codec.decode(dictionary) else {
                continue
            }
            descriptors[panelID] = descriptor
        }
        return descriptors
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

@objc(TideyWorkspaceRestorationGraphCodec)
@objcMembers
final class TideyWorkspaceRestorationGraphCodec: NSObject {
    static let recordKey = "Tidey Workspace Restoration State"

    @objc(encodeState:withEncoder:)
    func encode(
        state: TideyWorkspaceRestorationState,
        with encoder: iTermGraphEncoder
    ) -> Bool {
        guard let dictionary = try? TideyWorkspaceRestorationStateDictionaryCodec().encode(state) else {
            // Workspace metadata is ancillary to the native window graph.
            return true
        }
        return encoder.encodeChild(
            withKey: Self.recordKey,
            identifier: "",
            generation: iTermGenerationAlwaysEncode
        ) { subencoder in
            let adapter = iTermGraphEncoderAdapter(graphEncoder: subencoder)
            adapter.merge(dictionary)
            return true
        }
    }

    @objc(decodeWindowArrangement:)
    func decode(windowArrangement: [String: Any]) -> TideyWorkspaceRestorationState? {
        guard let dictionary = windowArrangement[Self.recordKey] as? [String: Any] else {
            return nil
        }
        return try? TideyWorkspaceRestorationStateDictionaryCodec().decode(dictionary)
    }
}
