import Foundation

struct TerminalStreamConnectionState {
    enum SubscribeDecision {
        case accepted(displacedLease: OrdinaryTmuxTerminalStreamLease?)
        case rejected
    }

    enum ReleaseDecision {
        case accepted([OrdinaryTmuxTerminalStreamLease])
        case rejected
    }

    struct Retirement {
        let preRetireCount: Int
        let leases: [OrdinaryTmuxTerminalStreamLease]
    }

    private(set) var isRetired = false
    private var unsubscribeAllHighWater: UInt64 = 0
    private var panelHighWater = [String: UInt64]()
    private var ownedByPanel = [String: OrdinaryTmuxTerminalStreamLease]()

    var count: Int {
        ownedByPanel.count
    }

    mutating func commitSubscribe(sequence: UInt64,
                                  panelID: String,
                                  lease: OrdinaryTmuxTerminalStreamLease,
                                  onInvalidated: @escaping @Sendable () -> Void) -> SubscribeDecision {
        .rejected
    }

    mutating func commitUnsubscribe(sequence: UInt64,
                                    panelID: String) -> ReleaseDecision {
        .rejected
    }

    mutating func commitUnsubscribeAll(sequence: UInt64) -> ReleaseDecision {
        .rejected
    }

    @discardableResult
    mutating func removeIfOwned(panelID: String, token: UInt64) -> Bool {
        false
    }

    mutating func retire() -> Retirement {
        isRetired = true
        return Retirement(preRetireCount: ownedByPanel.count,
                          leases: Array(ownedByPanel.values))
    }
}
