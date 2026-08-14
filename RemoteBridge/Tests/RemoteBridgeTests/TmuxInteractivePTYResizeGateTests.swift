import Foundation
import XCTest

@testable import RemoteBridge

final class TmuxInteractivePTYResizeGateTests: XCTestCase {
    private final class ControllerProbe: TmuxInteractivePTYControlling, @unchecked Sendable {
        private(set) var resizeAttempts = [TmuxInteractivePTYSize]()
        var failNextResize = false

        func spawn(_ command: TmuxInteractivePTYAttachCommand) throws -> TmuxInteractivePTYHandle {
            TmuxInteractivePTYHandle(masterFileDescriptor: 17, childProcessID: 23)
        }

        func resize(masterFileDescriptor: Int32, to size: TmuxInteractivePTYSize) throws {
            XCTAssertEqual(masterFileDescriptor, 17)
            resizeAttempts.append(size)
            if failNextResize {
                failNextResize = false
                throw TmuxInteractivePTYControllerError.operationFailed(
                    operation: "resize",
                    code: EIO
                )
            }
        }

        func close(masterFileDescriptor: Int32) throws {}

        func reap(
            childProcessID: Int32,
            blocking: Bool
        ) throws -> TmuxInteractivePTYChildExit? {
            nil
        }

        func read(
            masterFileDescriptor: Int32,
            maximumBytes: Int
        ) throws -> TmuxInteractivePTYReadResult {
            .wouldBlock
        }

        func write(
            _ bytes: Data,
            masterFileDescriptor: Int32
        ) throws -> TmuxInteractivePTYWriteResult {
            .written(bytes.count)
        }
    }

    func testResizeGateRejectsInvalidStaleDuplicateFailedAndRetiredRequests() throws {
        let binding = TmuxInteractiveSubscriptionBinding(
            subscriptionID: "interactive-1",
            generation: 4
        )
        let controller = ControllerProbe()
        let gate = TmuxInteractivePTYResizeGate(
            binding: binding,
            masterFileDescriptor: 17,
            initialSize: TmuxInteractivePTYSize(columns: 80, rows: 24),
            controller: controller
        )

        XCTAssertFalse(
            try gate.apply(
                TmuxInteractiveResize(
                    binding: TmuxInteractiveSubscriptionBinding(
                        subscriptionID: binding.subscriptionID,
                        generation: binding.generation - 1
                    ),
                    viewport: TmuxInteractiveViewport(columns: -1, rows: -1)
                )
            )
        )
        for invalidViewport in [
            TmuxInteractiveViewport(columns: -1, rows: 24),
            TmuxInteractiveViewport(columns: 80, rows: 0),
            TmuxInteractiveViewport(columns: Int(UInt16.max) + 1, rows: 24),
            TmuxInteractiveViewport(columns: 80, rows: Int(UInt16.max) + 1),
        ] {
            XCTAssertThrowsError(
                try gate.apply(
                    TmuxInteractiveResize(binding: binding, viewport: invalidViewport)
                )
            ) { error in
                XCTAssertEqual(
                    error as? TmuxInteractivePTYResizeGateError,
                    .invalidViewport(invalidViewport)
                )
            }
        }
        XCTAssertTrue(
            try gate.apply(
                TmuxInteractiveResize(
                    binding: binding,
                    viewport: TmuxInteractiveViewport(columns: 100, rows: 30)
                )
            )
        )
        XCTAssertFalse(
            try gate.apply(
                TmuxInteractiveResize(
                    binding: binding,
                    viewport: TmuxInteractiveViewport(columns: 100, rows: 30)
                )
            )
        )

        controller.failNextResize = true
        let retryViewport = TmuxInteractiveViewport(columns: 120, rows: 40)
        XCTAssertThrowsError(
            try gate.apply(TmuxInteractiveResize(binding: binding, viewport: retryViewport))
        )
        XCTAssertTrue(
            try gate.apply(TmuxInteractiveResize(binding: binding, viewport: retryViewport))
        )

        gate.retire()
        XCTAssertFalse(
            try gate.apply(
                TmuxInteractiveResize(
                    binding: binding,
                    viewport: TmuxInteractiveViewport(columns: 140, rows: 45)
                )
            )
        )
        XCTAssertEqual(
            controller.resizeAttempts,
            [
                TmuxInteractivePTYSize(columns: 100, rows: 30),
                TmuxInteractivePTYSize(columns: 120, rows: 40),
                TmuxInteractivePTYSize(columns: 120, rows: 40),
            ]
        )
    }
}
