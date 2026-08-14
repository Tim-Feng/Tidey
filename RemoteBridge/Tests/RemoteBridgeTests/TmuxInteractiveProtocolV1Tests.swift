import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractiveProtocolV1Tests: XCTestCase {
    func testProtocolValuesFenceEveryMutableAndEmittedValueBySubscriptionAndGeneration() {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-7",
            generation: 19
        )
        let viewport = TmuxInteractiveViewport(columns: 80, rows: 24)
        let subscribe = TmuxInteractiveSubscribe(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:/private/tmp/tmux-501/default:$7:@11",
            binding: binding,
            viewport: viewport
        )
        let input = TmuxInteractiveInput(binding: binding, bytes: Data([0x02, 0x64]))
        let resize = TmuxInteractiveResize(binding: binding, viewport: viewport)
        let unsubscribe = TmuxInteractiveUnsubscribe(binding: binding)
        let start = TmuxInteractiveAuthoritativeStart(
            binding: binding,
            viewport: viewport,
            initialBytes: Data([0x1b, 0x5b, 0x48])
        )
        let output = TmuxInteractiveOutputChunk(
            binding: binding,
            sequence: 1,
            bytes: Data([0xff, 0x00])
        )
        let state = TmuxInteractiveStateChange(
            binding: binding,
            state: .detached,
            message: nil
        )

        XCTAssertEqual(TmuxInteractiveProtocolV1.capability, "tmux_interactive_v1")
        XCTAssertEqual(BridgeProtocolCapability.tmuxInteractive, "tmux_interactive_v1")
        XCTAssertEqual(TmuxInteractiveProtocolV1.subscribeAction, "subscribe_tmux_interactive")
        XCTAssertEqual(TmuxInteractiveProtocolV1.inputAction, "tmux_interactive_input")
        XCTAssertEqual(TmuxInteractiveProtocolV1.resizeAction, "tmux_interactive_resize")
        XCTAssertEqual(TmuxInteractiveProtocolV1.unsubscribeAction, "unsubscribe_tmux_interactive")
        XCTAssertEqual(TmuxInteractiveProtocolV1.outputEventType, "tmux_interactive_output")
        XCTAssertEqual(TmuxInteractiveProtocolV1.stateEventType, "tmux_interactive_state")
        XCTAssertEqual(subscribe.binding, binding)
        XCTAssertEqual(input.binding, binding)
        XCTAssertEqual(resize.binding, binding)
        XCTAssertEqual(unsubscribe.binding, binding)
        XCTAssertEqual(start.binding, binding)
        XCTAssertEqual(output.binding, binding)
        XCTAssertEqual(state.binding, binding)
        XCTAssertEqual(output.bytes, Data([0xff, 0x00]))
        XCTAssertEqual(state.state, .detached)
    }
}
