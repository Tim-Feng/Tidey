import Foundation

final class TerminalStreamConnectionAdmission: @unchecked Sendable {
    enum ReservationState: Equatable, Sendable {
        case reserved
        case claimed
        case canceled
        case finalized
    }

    final class Reservation: @unchecked Sendable {
        let sequence: UInt64
        let panelID: String
        let owner: TerminalStreamSubscriptionOwner
        fileprivate var state: ReservationState = .reserved
        fileprivate var isVetoed = false

        fileprivate init(sequence: UInt64,
                         panelID: String,
                         owner: TerminalStreamSubscriptionOwner) {
            self.sequence = sequence
            self.panelID = panelID
            self.owner = owner
        }
    }

    private let lock = NSLock()
    private var isRetired = false

    func reserveSubscribe(sequence: UInt64,
                          panelID: String,
                          owner: TerminalStreamSubscriptionOwner) -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        return nil
    }

    func claimForPhysicalMutation(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return false
    }

    func finalizeSubscribe(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return false
    }

    func abandonSubscribe(_ reservation: Reservation) {
        lock.lock()
        lock.unlock()
    }

    @discardableResult
    func prepareIdentifiedUnsubscribe(panelID: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return false
    }

    @discardableResult
    func prepareLegacyUnsubscribe(sequence: UInt64, panelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return false
    }

    @discardableResult
    func prepareUnsubscribeAll(sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return false
    }

    func retire() {
        lock.lock()
        defer { lock.unlock() }
        isRetired = true
    }

    func state(of reservation: Reservation) -> ReservationState {
        lock.lock()
        defer { lock.unlock() }
        return reservation.state
    }
}
