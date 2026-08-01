import XCTest
@testable import iTerm2SharedARC

final class TideyWorkspaceRestorationTests: XCTestCase {
    func testRestoredWorkspaceIdentityResolverSeamCompiles() {
        XCTAssertEqual(
            PseudoTerminal.tideyResolvedWorkspaceIdentifier(
                forGraphLookupResult: "graph-workspace",
                tabOwnIdentifier: "tab-workspace",
                selectedWorkspaceIdentifier: "selected-workspace"
            ),
            "graph-workspace"
        )
    }

    func testNativeTabArrangementGUIDSeamCompiles() {
        let arrangement = ["Tab GUID": "saved-panel-guid"]

        XCTAssertEqual(
            PTYTab.guid(inArrangement: arrangement),
            "saved-panel-guid"
        )
    }

    func testWindowArrangementRoundTripsHiddenOrdinaryPanelsThroughNativeTabEncoding() throws {
        let planner = TideyWorkspaceRestorationPlanner()
        let editor = panelInput("panel-editor")
        let hiddenReview = panelInput("panel-review")
        let buildWorkspace = TideyWorkspaceRestorationWorkspaceInput(
            workspaceID: UUID().uuidString,
            title: "Build",
            pinned: true,
            panels: [editor],
            selectedPanelID: editor.panelID
        )
        let reviewWorkspace = TideyWorkspaceRestorationWorkspaceInput(
            workspaceID: UUID().uuidString,
            title: "Review",
            pinned: false,
            panels: [hiddenReview],
            selectedPanelID: hiddenReview.panelID
        )
        let capturePlan = planner.capturePlan(
            workspaces: [buildWorkspace, reviewWorkspace],
            visiblePanels: [editor],
            selectedWorkspaceID: reviewWorkspace.workspaceID
        )
        let encoder = iTermGraphEncoder(
            key: "window",
            identifier: "window-1",
            generation: iTermGenerationAlwaysEncode
        )
        let adapter = iTermGraphEncoderAdapter(graphEncoder: encoder)
        adapter.encodeArray(
            withKey: TERMINAL_ARRANGEMENT_TABS,
            identifiers: capturePlan.flattenedNativePanelIDs,
            generation: iTermGenerationAlwaysEncode
        ) { subencoder, _, identifier, _ in
            subencoder.merge([
                "Tab GUID": identifier,
                "Native Payload": "native-\(identifier)"
            ])
            return true
        }

        let graphCodec = TideyWorkspaceRestorationGraphCodec()
        XCTAssertTrue(graphCodec.encode(state: capturePlan.state, with: encoder))
        let record = try XCTUnwrap(encoder.record)
        XCTAssertEqual(
            record.graphRecords.filter {
                $0.key == TideyWorkspaceRestorationGraphCodec.recordKey &&
                    $0.identifier.isEmpty
            }.count,
            1
        )

        let windowArrangement = try XCTUnwrap(
            record.propertyListValue as? [String: Any]
        )
        let nativeTabs = try XCTUnwrap(
            windowArrangement[TERMINAL_ARRANGEMENT_TABS] as? [[String: Any]]
        )
        XCTAssertEqual(
            nativeTabs.compactMap { $0["Tab GUID"] as? String },
            ["panel-editor", "panel-review"]
        )
        XCTAssertEqual(
            nativeTabs.compactMap { $0["Native Payload"] as? String },
            ["native-panel-editor", "native-panel-review"]
        )

        let decodedState = try XCTUnwrap(
            graphCodec.decode(windowArrangement: windowArrangement)
        )
        let hydrated = planner.hydrationState(
            savedState: decodedState,
            availablePanelIDs: nativeTabs.compactMap { $0["Tab GUID"] as? String },
            panelIDRemap: [:]
        )

        XCTAssertEqual(
            hydrated.workspaces.map(\.workspaceID),
            [buildWorkspace.workspaceID, reviewWorkspace.workspaceID]
        )
        XCTAssertEqual(hydrated.workspaces.map(\.title), ["Build", "Review"])
        XCTAssertEqual(hydrated.workspaces.map(\.pinned), [true, false])
        XCTAssertEqual(
            hydrated.workspaces.map(\.panelIDs),
            [["panel-editor"], ["panel-review"]]
        )
        XCTAssertEqual(
            hydrated.workspaces.map(\.selectedPanelID),
            ["panel-editor", "panel-review"]
        )
        XCTAssertEqual(hydrated.selectedWorkspaceID, reviewWorkspace.workspaceID)
    }

    func testInvalidWorkspaceMetadataDoesNotRejectNativeWindowGraph() throws {
        let encoder = iTermGraphEncoder(
            key: "window",
            identifier: "window-1",
            generation: iTermGenerationAlwaysEncode
        )
        let adapter = iTermGraphEncoderAdapter(graphEncoder: encoder)
        adapter.encodeArray(
            withKey: TERMINAL_ARRANGEMENT_TABS,
            identifiers: ["panel-native"],
            generation: iTermGenerationAlwaysEncode
        ) { subencoder, _, identifier, _ in
            subencoder.merge([
                "Tab GUID": identifier,
                "Native Payload": "native-\(identifier)"
            ])
            return true
        }
        let invalidState = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: nil,
            workspaces: [
                TideyWorkspaceState(
                    workspaceID: "workspace-first",
                    title: nil,
                    pinned: false,
                    panelIDs: ["panel-native"],
                    selectedPanelID: "panel-native"
                ),
                TideyWorkspaceState(
                    workspaceID: "workspace-second",
                    title: nil,
                    pinned: false,
                    panelIDs: ["panel-native"],
                    selectedPanelID: "panel-native"
                )
            ]
        )

        XCTAssertTrue(
            TideyWorkspaceRestorationGraphCodec().encode(
                state: invalidState,
                with: encoder
            )
        )
        let record = try XCTUnwrap(encoder.record)
        XCTAssertFalse(
            record.graphRecords.contains {
                $0.key == TideyWorkspaceRestorationGraphCodec.recordKey
            }
        )
        let windowArrangement = try XCTUnwrap(
            record.propertyListValue as? [String: Any]
        )
        let nativeTabs = try XCTUnwrap(
            windowArrangement[TERMINAL_ARRANGEMENT_TABS] as? [[String: Any]]
        )
        XCTAssertEqual(
            nativeTabs.compactMap { $0["Tab GUID"] as? String },
            ["panel-native"]
        )
        XCTAssertEqual(
            nativeTabs.compactMap { $0["Native Payload"] as? String },
            ["native-panel-native"]
        )
    }

    func testModelSeamCompiles() {
        let workspace = TideyWorkspaceState(
            workspaceID: "workspace-1",
            title: "Build",
            pinned: true,
            panelIDs: ["panel-1", "panel-2"],
            selectedPanelID: "panel-2"
        )
        let state = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: workspace.workspaceID,
            workspaces: [workspace]
        )

        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertEqual(state.selectedWorkspaceID, "workspace-1")
        XCTAssertEqual(state.workspaces.first?.panelIDs, ["panel-1", "panel-2"])
    }

    func testPanelFlatteningAndHydrationSeamsCompile() {
        let panel = TideyWorkspaceRestorationPanelInput(
            panelID: "panel-1",
            hasSessions: true,
            isNativeTmux: false
        )
        let workspace = TideyWorkspaceRestorationWorkspaceInput(
            workspaceID: "workspace-1",
            title: "Build",
            pinned: true,
            panels: [panel],
            selectedPanelID: panel.panelID
        )
        let state = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: workspace.workspaceID,
            workspaces: []
        )
        let planner: TideyWorkspaceRestorationPlanning = WorkspaceRestorationPlanningSpy(state: state)

        let capturePlan = planner.capturePlan(
            workspaces: [workspace],
            visiblePanels: [panel],
            selectedWorkspaceID: workspace.workspaceID
        )
        let hydrationState = planner.hydrationState(
            savedState: state,
            availablePanelIDs: [panel.panelID],
            panelIDRemap: [:]
        )

        XCTAssertEqual(capturePlan.flattenedNativePanelIDs, [panel.panelID])
        XCTAssertTrue(hydrationState === state)
    }

    func testFlattenedNativePanelIDsPreserveWorkspaceAndPanelOrder() {
        let planner = TideyWorkspaceRestorationPlanner()
        let editor = panelInput("panel-editor")
        let tests = panelInput("panel-tests")
        let nativeTmux = panelInput("panel-native-tmux", isNativeTmux: true)
        let empty = panelInput("panel-empty", hasSessions: false)
        let review = panelInput("panel-review")
        let excludedWorkspacePanel = panelInput(
            "panel-excluded-native-tmux",
            isNativeTmux: true
        )
        let workspaces = [
            TideyWorkspaceRestorationWorkspaceInput(
                workspaceID: "workspace-build",
                title: "Build",
                pinned: true,
                panels: [editor, nativeTmux, tests, empty],
                selectedPanelID: tests.panelID
            ),
            TideyWorkspaceRestorationWorkspaceInput(
                workspaceID: "workspace-review",
                title: nil,
                pinned: false,
                panels: [review],
                selectedPanelID: review.panelID
            ),
            TideyWorkspaceRestorationWorkspaceInput(
                workspaceID: "workspace-excluded",
                title: "Excluded",
                pinned: false,
                panels: [excludedWorkspacePanel],
                selectedPanelID: excludedWorkspacePanel.panelID
            )
        ]

        let plan = planner.capturePlan(
            workspaces: workspaces,
            visiblePanels: [editor, tests],
            selectedWorkspaceID: "workspace-review"
        )
        let fallback = planner.capturePlan(
            workspaces: [],
            visiblePanels: [nativeTmux, empty, review],
            selectedWorkspaceID: nil
        )

        XCTAssertEqual(plan.flattenedNativePanelIDs, [
            "panel-editor",
            "panel-tests",
            "panel-review"
        ])
        XCTAssertEqual(plan.state.selectedWorkspaceID, "workspace-review")
        XCTAssertEqual(plan.state.workspaces.map(\.workspaceID), [
            "workspace-build",
            "workspace-review"
        ])
        XCTAssertEqual(plan.state.workspaces.map(\.panelIDs), [
            ["panel-editor", "panel-tests"],
            ["panel-review"]
        ])
        XCTAssertEqual(plan.state.workspaces.map(\.selectedPanelID), [
            "panel-tests",
            "panel-review"
        ])
        XCTAssertEqual(fallback.flattenedNativePanelIDs, ["panel-review"])
        XCTAssertTrue(fallback.state.workspaces.isEmpty)
    }

    func testHydrationUsesDecoderGUIDRemapAfterCollision() {
        let planner = TideyWorkspaceRestorationPlanner()
        let build = TideyWorkspaceState(
            workspaceID: "workspace-build",
            title: "Build",
            pinned: true,
            panelIDs: [
                "panel-editor",
                "panel-colliding",
                "panel-unmapped"
            ],
            selectedPanelID: "panel-colliding"
        )
        let review = TideyWorkspaceState(
            workspaceID: "workspace-review",
            title: nil,
            pinned: false,
            panelIDs: ["panel-review"],
            selectedPanelID: "panel-review"
        )
        let savedState = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: build.workspaceID,
            workspaces: [build, review]
        )

        let hydrated = planner.hydrationState(
            savedState: savedState,
            availablePanelIDs: [
                "panel-editor",
                "panel-collision-actual",
                "panel-unmapped",
                "panel-unmapped-actual",
                "panel-review"
            ],
            panelIDRemap: [
                "panel-colliding": "panel-collision-actual",
                "panel-not-in-state": "panel-irrelevant"
            ]
        )

        XCTAssertEqual(hydrated.schemaVersion, savedState.schemaVersion)
        XCTAssertEqual(hydrated.selectedWorkspaceID, "workspace-build")
        XCTAssertEqual(hydrated.workspaces.map(\.workspaceID), [
            "workspace-build",
            "workspace-review"
        ])
        XCTAssertEqual(hydrated.workspaces.map(\.panelIDs), [
            [
                "panel-editor",
                "panel-collision-actual",
                "panel-unmapped"
            ],
            ["panel-review"]
        ])
        XCTAssertEqual(hydrated.workspaces.map(\.selectedPanelID), [
            "panel-collision-actual",
            "panel-review"
        ])
    }

    func testHydrationKeepsFirstSavedReferenceWhenRemapsCollide() {
        let planner = TideyWorkspaceRestorationPlanner()
        let first = TideyWorkspaceState(
            workspaceID: "workspace-first",
            title: "First",
            pinned: false,
            panelIDs: ["panel-saved-first"],
            selectedPanelID: "panel-saved-first"
        )
        let second = TideyWorkspaceState(
            workspaceID: "workspace-second",
            title: "Second",
            pinned: false,
            panelIDs: ["panel-saved-second"],
            selectedPanelID: "panel-saved-second"
        )
        let savedState = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: second.workspaceID,
            workspaces: [first, second]
        )

        let hydrated = planner.hydrationState(
            savedState: savedState,
            availablePanelIDs: ["panel-actual-shared"],
            panelIDRemap: [
                "panel-saved-first": "panel-actual-shared",
                "panel-saved-second": "panel-actual-shared"
            ]
        )

        XCTAssertEqual(hydrated.workspaces.map(\.workspaceID), ["workspace-first"])
        XCTAssertEqual(hydrated.workspaces.first?.panelIDs, ["panel-actual-shared"])
        XCTAssertEqual(hydrated.workspaces.first?.selectedPanelID, "panel-actual-shared")
        XCTAssertNil(hydrated.selectedWorkspaceID)
    }

    func testHydrationRestoresWorkspaceMetadataBeforeShowingSelectedWorkspace() {
        let planner = TideyWorkspaceRestorationPlanner()
        let build = TideyWorkspaceState(
            workspaceID: "workspace-build",
            title: "Build",
            pinned: true,
            panelIDs: [
                "panel-editor",
                "panel-missing",
                "panel-colliding"
            ],
            selectedPanelID: "panel-colliding"
        )
        let review = TideyWorkspaceState(
            workspaceID: "workspace-review",
            title: "Review",
            pinned: false,
            panelIDs: ["panel-review"],
            selectedPanelID: "panel-review"
        )
        let missingSelection = TideyWorkspaceState(
            workspaceID: "workspace-missing-selection",
            title: nil,
            pinned: false,
            panelIDs: [
                "panel-survives",
                "panel-selected-missing"
            ],
            selectedPanelID: "panel-selected-missing"
        )
        let emptyAfterHydration = TideyWorkspaceState(
            workspaceID: "workspace-empty",
            title: "Missing",
            pinned: false,
            panelIDs: ["panel-gone"],
            selectedPanelID: "panel-gone"
        )
        let savedState = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: review.workspaceID,
            workspaces: [
                build,
                emptyAfterHydration,
                review,
                missingSelection
            ]
        )

        let hydrated = planner.hydrationState(
            savedState: savedState,
            availablePanelIDs: [
                "panel-editor",
                "panel-collision-actual",
                "panel-review",
                "panel-survives",
                "panel-unreferenced"
            ],
            panelIDRemap: [
                "panel-colliding": "panel-collision-actual"
            ]
        )
        let emptyRemapHydrated = planner.hydrationState(
            savedState: TideyWorkspaceRestorationState(
                schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
                selectedWorkspaceID: "workspace-empty-selected",
                workspaces: [
                    TideyWorkspaceState(
                        workspaceID: "workspace-plain",
                        title: nil,
                        pinned: false,
                        panelIDs: [
                            "panel-plain",
                            "panel-plain-missing"
                        ],
                        selectedPanelID: "panel-plain"
                    ),
                    TideyWorkspaceState(
                        workspaceID: "workspace-empty-selected",
                        title: nil,
                        pinned: false,
                        panelIDs: ["panel-empty-selected-missing"],
                        selectedPanelID: "panel-empty-selected-missing"
                    )
                ]
            ),
            availablePanelIDs: ["panel-plain"],
            panelIDRemap: [:]
        )

        XCTAssertEqual(hydrated.schemaVersion, savedState.schemaVersion)
        XCTAssertEqual(hydrated.selectedWorkspaceID, "workspace-review")
        XCTAssertEqual(hydrated.workspaces.map(\.workspaceID), [
            "workspace-build",
            "workspace-review",
            "workspace-missing-selection"
        ])
        XCTAssertEqual(hydrated.workspaces.map(\.title), [
            "Build",
            "Review",
            nil
        ])
        XCTAssertEqual(hydrated.workspaces.map(\.pinned), [
            true,
            false,
            false
        ])
        XCTAssertEqual(hydrated.workspaces.map(\.panelIDs), [
            [
                "panel-editor",
                "panel-collision-actual"
            ],
            ["panel-review"],
            ["panel-survives"]
        ])
        XCTAssertEqual(hydrated.workspaces.map(\.selectedPanelID), [
            "panel-collision-actual",
            "panel-review",
            nil
        ])
        XCTAssertFalse(hydrated.workspaces.flatMap(\.panelIDs).contains("panel-unreferenced"))
        XCTAssertNil(emptyRemapHydrated.selectedWorkspaceID)
        XCTAssertEqual(emptyRemapHydrated.workspaces.map(\.workspaceID), ["workspace-plain"])
        XCTAssertEqual(emptyRemapHydrated.workspaces.first?.panelIDs, ["panel-plain"])
    }

    func testWorkspaceStateRoundTripsStableIdentitiesAndSelections() throws {
        let codec = TideyWorkspaceRestorationStateDictionaryCodec()
        let build = TideyWorkspaceState(
            workspaceID: "workspace-build",
            title: "Build",
            pinned: true,
            panelIDs: ["panel-editor", "panel-tests"],
            selectedPanelID: "panel-tests"
        )
        let review = TideyWorkspaceState(
            workspaceID: "workspace-review",
            title: nil,
            pinned: false,
            panelIDs: ["panel-review"],
            selectedPanelID: "panel-review"
        )
        let original = TideyWorkspaceRestorationState(
            schemaVersion: TideyWorkspaceRestorationState.currentSchemaVersion,
            selectedWorkspaceID: review.workspaceID,
            workspaces: [build, review]
        )

        var encoded = try codec.encode(original)
        encoded["future_root_field"] = ["ignored": true]
        var encodedWorkspaces = try XCTUnwrap(encoded["workspaces"] as? [[String: Any]])
        encodedWorkspaces[0]["future_workspace_field"] = 42
        encoded["workspaces"] = encodedWorkspaces

        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.selectedWorkspaceID, "workspace-review")
        XCTAssertEqual(decoded.workspaces.map(\.workspaceID), ["workspace-build", "workspace-review"])
        XCTAssertEqual(decoded.workspaces.map(\.title), ["Build", nil])
        XCTAssertEqual(decoded.workspaces.map(\.pinned), [true, false])
        XCTAssertEqual(decoded.workspaces.map(\.panelIDs), [
            ["panel-editor", "panel-tests"],
            ["panel-review"]
        ])
        XCTAssertEqual(decoded.workspaces.map(\.selectedPanelID), ["panel-tests", "panel-review"])
    }

    func testWorkspaceStateDecodeRejectsDuplicateWorkspaceIDs() {
        let dictionary: [String: Any] = [
            "schema_version": 1,
            "workspaces": [
                workspaceDictionary(id: "workspace-1", panelIDs: ["panel-1"]),
                workspaceDictionary(id: "workspace-1", panelIDs: ["panel-2"])
            ]
        ]

        XCTAssertThrowsError(try TideyWorkspaceRestorationStateDictionaryCodec().decode(dictionary)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .duplicateWorkspaceID("workspace-1"))
        }
    }

    func testWorkspaceStateDecodeRejectsDuplicatePanelMembership() {
        let dictionary: [String: Any] = [
            "schema_version": 1,
            "workspaces": [
                workspaceDictionary(id: "workspace-1", panelIDs: ["panel-shared"]),
                workspaceDictionary(id: "workspace-2", panelIDs: ["panel-shared"])
            ]
        ]

        XCTAssertThrowsError(try TideyWorkspaceRestorationStateDictionaryCodec().decode(dictionary)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .duplicatePanelID("panel-shared"))
        }
    }

    func testWorkspaceStateDecodeRejectsMalformedIdentitiesAndUnsupportedVersion() {
        let codec = TideyWorkspaceRestorationStateDictionaryCodec()
        let malformed: [String: Any] = [
            "schema_version": 1,
            "workspaces": [
                workspaceDictionary(id: "", panelIDs: ["panel-1"])
            ]
        ]
        let futureVersion: [String: Any] = [
            "schema_version": 2,
            "workspaces": []
        ]

        XCTAssertThrowsError(try codec.decode(malformed)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .malformedField("workspace_id"))
        }
        XCTAssertThrowsError(try codec.decode(futureVersion)) { error in
            XCTAssertEqual(error as? TideyWorkspaceRestorationStateCodecError,
                           .unsupportedSchemaVersion(2))
        }
    }

    private func workspaceDictionary(id: String, panelIDs: [String]) -> [String: Any] {
        [
            "workspace_id": id,
            "pinned": false,
            "panel_ids": panelIDs
        ]
    }

    private func panelInput(
        _ panelID: String,
        hasSessions: Bool = true,
        isNativeTmux: Bool = false
    ) -> TideyWorkspaceRestorationPanelInput {
        TideyWorkspaceRestorationPanelInput(
            panelID: panelID,
            hasSessions: hasSessions,
            isNativeTmux: isNativeTmux
        )
    }
}

private final class WorkspaceRestorationPlanningSpy: NSObject, TideyWorkspaceRestorationPlanning {
    private let state: TideyWorkspaceRestorationState

    init(state: TideyWorkspaceRestorationState) {
        self.state = state
    }

    func capturePlan(
        workspaces: [TideyWorkspaceRestorationWorkspaceInput],
        visiblePanels: [TideyWorkspaceRestorationPanelInput],
        selectedWorkspaceID: String?
    ) -> TideyWorkspaceRestorationCapturePlan {
        TideyWorkspaceRestorationCapturePlan(
            state: state,
            flattenedNativePanelIDs: visiblePanels.map(\.panelID)
        )
    }

    func hydrationState(
        savedState: TideyWorkspaceRestorationState,
        availablePanelIDs: [String],
        panelIDRemap: [String: String]
    ) -> TideyWorkspaceRestorationState {
        savedState
    }
}
