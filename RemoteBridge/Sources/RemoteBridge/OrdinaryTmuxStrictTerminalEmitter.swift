import Foundation

final class OrdinaryTmuxStrictTerminalEmitter: @unchecked Sendable {
    typealias DeltaHandler = @Sendable (OrdinaryTmuxTerminalDeltaV1) -> Void

    let subscriptionID: String
    let expectedFingerprint: OrdinaryTmuxTerminalFingerprintV1

    private let queue: DispatchQueue
    private let onDelta: DeltaHandler
    private var nextSequence: UInt64 = 1
    private var isQuarantined = false

    init(subscriptionID: String,
         expectedFingerprint: OrdinaryTmuxTerminalFingerprintV1,
         queue: DispatchQueue? = nil,
         onDelta: @escaping DeltaHandler) {
        self.subscriptionID = subscriptionID
        self.expectedFingerprint = expectedFingerprint
        self.queue = queue ?? DispatchQueue(
            label: "com.tidey.remote-bridge.strict-terminal-emitter.\(subscriptionID)"
        )
        self.onDelta = onDelta
    }

    func emit(chunk: Data,
              currentFingerprint: OrdinaryTmuxTerminalFingerprintV1?) {
        queue.sync {
            guard isQuarantined == false else {
                return
            }

            let fingerprint = currentFingerprint ?? expectedFingerprint
            let requiresRebootstrap = currentFingerprint != expectedFingerprint
            let delta = OrdinaryTmuxTerminalDeltaV1(
                subscriptionID: subscriptionID,
                sequence: nextSequence,
                fingerprint: fingerprint,
                rebootstrapRequired: requiresRebootstrap,
                chunk: chunk
            )
            nextSequence &+= 1
            if requiresRebootstrap {
                isQuarantined = true
            }
            onDelta(delta)
        }
    }

    func requireRebootstrap(
        currentFingerprint: OrdinaryTmuxTerminalFingerprintV1? = nil
    ) {
        queue.sync {
            guard isQuarantined == false else {
                return
            }
            let delta = OrdinaryTmuxTerminalDeltaV1(
                subscriptionID: subscriptionID,
                sequence: nextSequence,
                fingerprint: currentFingerprint ?? expectedFingerprint,
                rebootstrapRequired: true,
                chunk: Data()
            )
            nextSequence &+= 1
            isQuarantined = true
            onDelta(delta)
        }
    }
}
