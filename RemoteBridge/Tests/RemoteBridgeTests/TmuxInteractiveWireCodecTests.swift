import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractiveWireCodecTests: XCTestCase {
    func testStreamingStartupEventsEncodeExactTypedEnvelopesWhileDormant() throws {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-7",
            generation: 19
        )
        let proof = TmuxInteractiveAttachProof(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:path:$7:@11",
            sessionID: "$7",
            windowID: "@11",
            paneID: "%19"
        )
        let initialBytes = Data([0x1b, 0x5b, 0x3e, 0x63])
        let attached = TmuxInteractiveAttached(
            binding: binding,
            attachProof: proof,
            viewport: TmuxInteractiveViewport(columns: 80, rows: 24),
            initialBytes: initialBytes,
            sequence: 1
        )
        let ready = TmuxInteractiveReady(binding: binding, sequence: 3)
        let attachedEnvelope = TmuxInteractiveWireCodec.envelope(for: attached)
        let readyEnvelope = TmuxInteractiveWireCodec.envelope(for: ready)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(
                TmuxInteractiveAttachedEnvelope.self,
                from: encoder.encode(attachedEnvelope)
            ),
            attachedEnvelope
        )
        XCTAssertEqual(
            try decoder.decode(
                TmuxInteractiveReadyEnvelope.self,
                from: encoder.encode(readyEnvelope)
            ),
            readyEnvelope
        )
        let attachedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(attachedEnvelope)
            ) as? [String: Any]
        )
        XCTAssertEqual(attachedObject["type"] as? String, "tmux_interactive_attached")
        XCTAssertEqual(attachedObject["subscription_id"] as? String, binding.subscriptionID)
        XCTAssertEqual(attachedObject["generation"] as? Int, Int(binding.generation))
        XCTAssertEqual(attachedObject["workspace_id"] as? String, proof.workspaceID)
        XCTAssertEqual(attachedObject["panel_id"] as? String, proof.panelID)
        XCTAssertEqual(attachedObject["session_id"] as? String, proof.sessionID)
        XCTAssertEqual(attachedObject["window_id"] as? String, proof.windowID)
        XCTAssertEqual(attachedObject["pane_id"] as? String, proof.paneID)
        XCTAssertEqual(attachedObject["cols"] as? Int, 80)
        XCTAssertEqual(attachedObject["rows"] as? Int, 24)
        XCTAssertEqual(attachedObject["data_base64"] as? String, initialBytes.base64EncodedString())
        XCTAssertEqual(attachedObject["sequence"] as? Int, 1)
        XCTAssertEqual(readyEnvelope.type, "tmux_interactive_ready")
        XCTAssertEqual(readyEnvelope.subscriptionID, binding.subscriptionID)
        XCTAssertEqual(readyEnvelope.generation, binding.generation)
        XCTAssertEqual(readyEnvelope.sequence, 3)
    }

    func testExactV1ActionsAndEventsRoundTripOpaqueBytesAndBinding() throws {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-7",
            generation: 19
        )
        let viewport = TmuxInteractiveViewport(columns: 80, rows: 24)
        let opaqueBytes = Data([0x00, 0x1b, 0xff, 0x02, 0x64])
        let common: [String: JSONValue] = [
            "subscription_id": .string(binding.subscriptionID),
            "generation": .number(Double(binding.generation)),
        ]
        let requestsAndActions: [(BridgeRequest, TmuxInteractiveWireAction)] = [
            (
                BridgeRequest(
                    id: "subscribe",
                    action: TmuxInteractiveProtocolV1.subscribeAction,
                    params: common.merging([
                        "workspace_id": .string("workspace-1"),
                        "panel_id": .string("ordinary-tmux:path:$7:@11"),
                        "cols": .number(80),
                        "rows": .number(24),
                    ]) { _, new in new }
                ),
                .subscribe(
                    TmuxInteractiveSubscribe(
                        workspaceID: "workspace-1",
                        panelID: "ordinary-tmux:path:$7:@11",
                        binding: binding,
                        viewport: viewport
                    )
                )
            ),
            (
                BridgeRequest(
                    id: "input",
                    action: TmuxInteractiveProtocolV1.inputAction,
                    params: common.merging([
                        "data_base64": .string(opaqueBytes.base64EncodedString()),
                    ]) { _, new in new }
                ),
                .input(TmuxInteractiveInput(binding: binding, bytes: opaqueBytes))
            ),
            (
                BridgeRequest(
                    id: "resize",
                    action: TmuxInteractiveProtocolV1.resizeAction,
                    params: common.merging([
                        "cols": .number(80),
                        "rows": .number(24),
                    ]) { _, new in new }
                ),
                .resize(TmuxInteractiveResize(binding: binding, viewport: viewport))
            ),
            (
                BridgeRequest(
                    id: "unsubscribe",
                    action: TmuxInteractiveProtocolV1.unsubscribeAction,
                    params: common
                ),
                .unsubscribe(TmuxInteractiveUnsubscribe(binding: binding))
            ),
        ]

        for (request, expectedAction) in requestsAndActions {
            XCTAssertEqual(try TmuxInteractiveWireCodec.decode(request), expectedAction)
        }
        XCTAssertNil(
            try TmuxInteractiveWireCodec.decode(
                BridgeRequest(id: "other", action: "list_panels", params: nil)
            )
        )

        for invalidGeneration in [-1, 1.5, 9_007_199_254_740_992] {
            XCTAssertThrowsError(
                try TmuxInteractiveWireCodec.decode(
                    BridgeRequest(
                        id: "bad-generation",
                        action: TmuxInteractiveProtocolV1.unsubscribeAction,
                        params: [
                            "subscription_id": .string(binding.subscriptionID),
                            "generation": .number(invalidGeneration),
                        ]
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? TmuxInteractiveWireCodecError,
                    .invalidField("generation")
                )
            }
        }
        XCTAssertThrowsError(
            try TmuxInteractiveWireCodec.decode(
                BridgeRequest(
                    id: "bad-base64",
                    action: TmuxInteractiveProtocolV1.inputAction,
                    params: common.merging(["data_base64": .string("%%%")]) { _, new in new }
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveWireCodecError,
                .invalidField("data_base64")
            )
        }
        XCTAssertThrowsError(
            try TmuxInteractiveWireCodec.decode(
                BridgeRequest(
                    id: "oversized-input",
                    action: TmuxInteractiveProtocolV1.inputAction,
                    params: common.merging([
                        "data_base64": .string(
                            Data(
                                repeating: 0x61,
                                count: TmuxInteractiveWireCodec.maximumInputBytes + 1
                            ).base64EncodedString()
                        ),
                    ]) { _, new in new }
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveWireCodecError,
                .invalidField("data_base64")
            )
        }
        XCTAssertThrowsError(
            try TmuxInteractiveWireCodec.decode(
                BridgeRequest(
                    id: "bad-viewport",
                    action: TmuxInteractiveProtocolV1.resizeAction,
                    params: common.merging([
                        "cols": .number(0),
                        "rows": .number(24),
                    ]) { _, new in new }
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TmuxInteractiveWireCodecError,
                .invalidField("cols")
            )
        }

        let start = TmuxInteractiveAuthoritativeStart(
            binding: binding,
            attachProof: TmuxInteractiveAttachProof(
                workspaceID: "workspace-1",
                panelID: "ordinary-tmux:path:$7:@11",
                sessionID: "$7",
                windowID: "@11",
                paneID: "%19"
            ),
            bootstrapPhase: TmuxInteractiveBootstrapPhase(
                viewport: TmuxInteractiveViewport(columns: 80, rows: 23),
                bytes: Data("bootstrap-state".utf8)
            ),
            viewport: viewport,
            initialBytes: opaqueBytes
        )
        let output = TmuxInteractiveOutputChunk(
            binding: binding,
            sequence: 3,
            bytes: opaqueBytes
        )
        let state = TmuxInteractiveStateChange(
            binding: binding,
            state: .detached,
            message: nil
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let startEnvelope = TmuxInteractiveWireCodec.envelope(for: start)
        let outputEnvelope = TmuxInteractiveWireCodec.envelope(for: output)
        let stateEnvelope = TmuxInteractiveWireCodec.envelope(for: state)

        XCTAssertEqual(
            try decoder.decode(
                TmuxInteractiveAuthoritativeStartEnvelope.self,
                from: encoder.encode(startEnvelope)
            ),
            startEnvelope
        )
        XCTAssertEqual(
            try decoder.decode(
                TmuxInteractiveOutputEnvelope.self,
                from: encoder.encode(outputEnvelope)
            ),
            outputEnvelope
        )
        XCTAssertEqual(
            try decoder.decode(
                TmuxInteractiveStateEnvelope.self,
                from: encoder.encode(stateEnvelope)
            ),
            stateEnvelope
        )
        let startObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(startEnvelope)) as? [String: Any]
        )
        XCTAssertEqual(startObject["type"] as? String, "tmux_interactive_start")
        XCTAssertEqual(startObject["subscription_id"] as? String, binding.subscriptionID)
        XCTAssertEqual(startObject["generation"] as? Int, Int(binding.generation))
        XCTAssertEqual(startObject["workspace_id"] as? String, start.attachProof.workspaceID)
        XCTAssertEqual(startObject["panel_id"] as? String, start.attachProof.panelID)
        XCTAssertEqual(startObject["session_id"] as? String, start.attachProof.sessionID)
        XCTAssertEqual(startObject["window_id"] as? String, start.attachProof.windowID)
        XCTAssertEqual(startObject["pane_id"] as? String, start.attachProof.paneID)
        XCTAssertEqual(startObject["cols"] as? Int, viewport.columns)
        XCTAssertEqual(startObject["rows"] as? Int, viewport.rows)
        XCTAssertEqual(startObject["bootstrap_cols"] as? Int, viewport.columns)
        XCTAssertEqual(startObject["bootstrap_rows"] as? Int, 23)
        XCTAssertEqual(
            startObject["bootstrap_data_base64"] as? String,
            Data("bootstrap-state".utf8).base64EncodedString()
        )
        XCTAssertEqual(startObject["data_base64"] as? String, opaqueBytes.base64EncodedString())
        XCTAssertEqual(outputEnvelope.dataBase64, opaqueBytes.base64EncodedString())
        XCTAssertEqual(outputEnvelope.sequence, 3)
        XCTAssertEqual(stateEnvelope.state, "detached")
        XCTAssertNil(stateEnvelope.message)
    }
}
