import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxStrictTerminalEmitterTests: XCTestCase {
    private final class DeltaBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [OrdinaryTmuxTerminalDeltaV1]()

        func append(_ delta: OrdinaryTmuxTerminalDeltaV1) {
            lock.lock()
            storage.append(delta)
            lock.unlock()
        }

        var deltas: [OrdinaryTmuxTerminalDeltaV1] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testEmitterSequencesMatchingChunksAndQuarantinesMismatchBeforeLaterChunks() {
        let expected = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 132,
            rows: 40,
            alternateOn: false
        )
        let changed = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 132,
            rows: 40,
            alternateOn: true
        )
        let box = DeltaBox()
        let emitter = OrdinaryTmuxStrictTerminalEmitter(
            subscriptionID: "subscription-1",
            expectedFingerprint: expected,
            onDelta: { box.append($0) }
        )

        emitter.emit(chunk: Data("one".utf8), currentFingerprint: expected)
        emitter.emit(chunk: Data("two".utf8), currentFingerprint: expected)
        emitter.emit(chunk: Data("transition".utf8), currentFingerprint: changed)
        emitter.emit(chunk: Data("must-drop".utf8), currentFingerprint: changed)

        XCTAssertEqual(
            box.deltas,
            [
                OrdinaryTmuxTerminalDeltaV1(
                    subscriptionID: "subscription-1",
                    sequence: 1,
                    fingerprint: expected,
                    rebootstrapRequired: false,
                    chunk: Data("one".utf8)
                ),
                OrdinaryTmuxTerminalDeltaV1(
                    subscriptionID: "subscription-1",
                    sequence: 2,
                    fingerprint: expected,
                    rebootstrapRequired: false,
                    chunk: Data("two".utf8)
                ),
                OrdinaryTmuxTerminalDeltaV1(
                    subscriptionID: "subscription-1",
                    sequence: 3,
                    fingerprint: changed,
                    rebootstrapRequired: true,
                    chunk: Data("transition".utf8)
                ),
            ]
        )
    }

    func testEmitterFailsClosedWhenFingerprintCannotBeRead() {
        let expected = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 80,
            rows: 24,
            alternateOn: false
        )
        let box = DeltaBox()
        let emitter = OrdinaryTmuxStrictTerminalEmitter(
            subscriptionID: "subscription-1",
            expectedFingerprint: expected,
            onDelta: { box.append($0) }
        )

        emitter.emit(chunk: Data("untrusted".utf8), currentFingerprint: nil)
        emitter.emit(chunk: Data("later".utf8), currentFingerprint: expected)

        XCTAssertEqual(box.deltas.count, 1)
        XCTAssertEqual(box.deltas.first?.sequence, 1)
        XCTAssertEqual(box.deltas.first?.fingerprint, expected)
        XCTAssertEqual(box.deltas.first?.rebootstrapRequired, true)
        XCTAssertEqual(box.deltas.first?.chunk, Data("untrusted".utf8))
    }
}
