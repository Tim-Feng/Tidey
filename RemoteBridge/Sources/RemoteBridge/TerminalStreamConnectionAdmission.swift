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
    private var unsubscribeAllHighWater: UInt64 = 0
    private var latestSubscribeHighWater = [String: UInt64]()
    private var legacyOwnerHighWater = [String: UInt64]()
    private var consumedIdentifiedOwnerIDs = Set<String>()
    private var reservationsBySequence = [UInt64: Reservation]()
    private var identifiedReservationsByID = [String: Reservation]()
    private var legacyReservationsByPanel = [String: Reservation]()

    func reserveSubscribe(sequence: UInt64,
                          panelID: String,
                          owner: TerminalStreamSubscriptionOwner) -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        guard isRetired == false else {
            return nil
        }
        if case .identified(let id) = owner {
            guard consumedIdentifiedOwnerIDs.contains(id) == false else {
                return nil
            }
            consumedIdentifiedOwnerIDs.insert(id)
        }
        guard sequence > max(unsubscribeAllHighWater,
                             latestSubscribeHighWater[panelID] ?? 0) else {
            return nil
        }
        if case .legacy = owner {
            guard sequence > (legacyOwnerHighWater[panelID] ?? 0) else {
                return nil
            }
        }

        let superseded = reservationsBySequence.values.filter {
            $0.panelID == panelID && $0.sequence < sequence
        }
        superseded.forEach(cancelLocked)

        let reservation = Reservation(sequence: sequence,
                                      panelID: panelID,
                                      owner: owner)
        latestSubscribeHighWater[panelID] = sequence
        reservationsBySequence[sequence] = reservation
        switch owner {
        case .identified(let id):
            identifiedReservationsByID[id] = reservation
        case .legacy:
            legacyOwnerHighWater[panelID] = sequence
            legacyReservationsByPanel[panelID] = reservation
        }
        return reservation
    }

    func claimForPhysicalMutation(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRetired == false,
              reservation.state == .reserved,
              reservation.isVetoed == false,
              reservationsBySequence[reservation.sequence] === reservation,
              reservation.sequence > unsubscribeAllHighWater,
              latestSubscribeHighWater[reservation.panelID] == reservation.sequence else {
            return false
        }
        reservation.state = .claimed
        return true
    }

    func finalizeSubscribe(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRetired == false,
              reservation.state == .claimed,
              reservation.isVetoed == false,
              reservation.sequence > unsubscribeAllHighWater,
              latestSubscribeHighWater[reservation.panelID] == reservation.sequence else {
            return false
        }
        if case .legacy = reservation.owner {
            guard legacyOwnerHighWater[reservation.panelID] == reservation.sequence else {
                return false
            }
        }
        reservation.state = .finalized
        removeIndexesLocked(for: reservation)
        return true
    }

    func abandonSubscribe(_ reservation: Reservation) {
        lock.lock()
        if reservation.state != .finalized {
            reservation.isVetoed = true
            reservation.state = .canceled
            removeIndexesLocked(for: reservation)
        }
        lock.unlock()
    }

    @discardableResult
    func prepareIdentifiedUnsubscribe(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRetired == false else {
            return false
        }
        consumedIdentifiedOwnerIDs.insert(id)
        if let reservation = identifiedReservationsByID[id] {
            cancelLocked(reservation)
        }
        return true
    }

    @discardableResult
    func prepareLegacyUnsubscribe(sequence: UInt64, panelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRetired == false,
              sequence > (legacyOwnerHighWater[panelID] ?? 0) else {
            return false
        }
        legacyOwnerHighWater[panelID] = sequence
        if let reservation = legacyReservationsByPanel[panelID],
           reservation.sequence < sequence {
            cancelLocked(reservation)
        }
        return true
    }

    @discardableResult
    func prepareUnsubscribeAll(sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRetired == false,
              sequence > unsubscribeAllHighWater else {
            return false
        }
        unsubscribeAllHighWater = sequence
        let olderReservations = reservationsBySequence.values.filter {
            $0.sequence < sequence
        }
        olderReservations.forEach(cancelLocked)
        return true
    }

    func retire() {
        lock.lock()
        defer { lock.unlock() }
        isRetired = true
        let reservations = Array(reservationsBySequence.values)
        reservations.forEach(cancelLocked)
    }

    func state(of reservation: Reservation) -> ReservationState {
        lock.lock()
        defer { lock.unlock() }
        return reservation.state
    }

    private func cancelLocked(_ reservation: Reservation) {
        switch reservation.state {
        case .reserved:
            reservation.state = .canceled
        case .claimed:
            reservation.isVetoed = true
        case .canceled, .finalized:
            break
        }
        removeIndexesLocked(for: reservation)
    }

    private func removeIndexesLocked(for reservation: Reservation) {
        if reservationsBySequence[reservation.sequence] === reservation {
            reservationsBySequence.removeValue(forKey: reservation.sequence)
        }
        switch reservation.owner {
        case .identified(let id):
            if identifiedReservationsByID[id] === reservation {
                identifiedReservationsByID.removeValue(forKey: id)
            }
        case .legacy:
            if legacyReservationsByPanel[reservation.panelID] === reservation {
                legacyReservationsByPanel.removeValue(forKey: reservation.panelID)
            }
        }
    }
}
