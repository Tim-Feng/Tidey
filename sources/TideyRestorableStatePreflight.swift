import Foundation

@objc(TideyRestorableSessionServerKind)
enum TideyRestorableSessionServerKind: Int {
    case monoServer
    case multiServerChild
}

@objc(TideyRestorableSessionServerIdentifier)
@objcMembers
final class TideyRestorableSessionServerIdentifier: NSObject {
    let kind: TideyRestorableSessionServerKind
    let monoServerProcessID: NSNumber?
    let multiServerSocketNumber: NSNumber?
    let multiServerChildProcessID: NSNumber?

    init(monoServerProcessID: NSNumber) {
        kind = .monoServer
        self.monoServerProcessID = monoServerProcessID
        multiServerSocketNumber = nil
        multiServerChildProcessID = nil
    }

    init(
        multiServerSocketNumber: NSNumber,
        childProcessID: NSNumber
    ) {
        kind = .multiServerChild
        monoServerProcessID = nil
        self.multiServerSocketNumber = multiServerSocketNumber
        multiServerChildProcessID = childProcessID
    }

    fileprivate var stableIdentity: String {
        switch kind {
        case .monoServer:
            return "mono:\(monoServerProcessID?.intValue ?? -1)"
        case .multiServerChild:
            return [
                "multi",
                String(multiServerSocketNumber?.intValue ?? -1),
                String(multiServerChildProcessID?.intValue ?? -1),
            ].joined(separator: ":")
        }
    }
}

@objc(TideyRestorableStatePreflight)
@objcMembers
final class TideyRestorableStatePreflight: NSObject {
    static let currentSchemaVersion = 1

    let stateExists: Bool
    let isValid: Bool
    let numberOfWindows: Int
    let tideySchemaVersion: NSNumber?
    let sessionServerIdentifiers: [TideyRestorableSessionServerIdentifier]

    init(
        stateExists: Bool,
        isValid: Bool,
        numberOfWindows: Int,
        tideySchemaVersion: NSNumber?,
        sessionServerIdentifiers: [TideyRestorableSessionServerIdentifier]
    ) {
        self.stateExists = stateExists
        self.isValid = isValid
        self.numberOfWindows = max(0, numberOfWindows)
        self.tideySchemaVersion = tideySchemaVersion
        self.sessionServerIdentifiers = sessionServerIdentifiers
    }

    var hasRestorableWindows: Bool {
        stateExists && isValid && numberOfWindows > 0
    }

    var hasSupportedTideySchemaVersion: Bool {
        stateExists &&
            isValid &&
            tideySchemaVersion?.intValue == Self.currentSchemaVersion
    }

    var savedStateKind: TideyRestorationSavedStateKind {
        guard stateExists else {
            return .absent
        }
        guard isValid else {
            return .invalid
        }
        guard let tideySchemaVersion else {
            return .untagged
        }
        if tideySchemaVersion.intValue == Self.currentSchemaVersion {
            return .taggedSupported
        }
        return .taggedUnsupported
    }
}

@objc(TideyRestorableStatePreflightBuilder)
@objcMembers
final class TideyRestorableStatePreflightBuilder: NSObject {
    static let schemaVersionKey = "Tidey Restoration Schema Version"

    func preflight(
        stateExists: Bool,
        isValid: Bool,
        numberOfWindows: Int,
        rootPayload: Any?,
        windowPayloads: [Any]
    ) -> TideyRestorableStatePreflight {
        let rootDictionary = rootPayload as? [String: Any]
        let schemaVersion = rootDictionary?[Self.schemaVersionKey] as? NSNumber
        var identifiers = [TideyRestorableSessionServerIdentifier]()
        var seenIdentities = Set<String>()

        for payload in windowPayloads {
            collectServerIdentifiers(
                from: payload,
                into: &identifiers,
                seenIdentities: &seenIdentities
            )
        }

        return TideyRestorableStatePreflight(
            stateExists: stateExists,
            isValid: isValid,
            numberOfWindows: numberOfWindows,
            tideySchemaVersion: schemaVersion,
            sessionServerIdentifiers: identifiers
        )
    }

    private func collectServerIdentifiers(
        from value: Any,
        into identifiers: inout [TideyRestorableSessionServerIdentifier],
        seenIdentities: inout Set<String>
    ) {
        if let dictionary = value as? [String: Any] {
            if let processID = dictionary["Server PID"] as? NSNumber,
               processID.intValue > 0 {
                append(
                    TideyRestorableSessionServerIdentifier(
                        monoServerProcessID: processID
                    ),
                    into: &identifiers,
                    seenIdentities: &seenIdentities
                )
            }
            if let serverDictionary = dictionary["Server Dict"] as? [String: Any],
               let socketNumber = serverDictionary["Socket"] as? NSNumber,
               let childProcessID = serverDictionary["Child PID"] as? NSNumber,
               socketNumber.intValue >= 0,
               childProcessID.intValue > 0 {
                append(
                    TideyRestorableSessionServerIdentifier(
                        multiServerSocketNumber: socketNumber,
                        childProcessID: childProcessID
                    ),
                    into: &identifiers,
                    seenIdentities: &seenIdentities
                )
            }
            for child in dictionary.values {
                collectServerIdentifiers(
                    from: child,
                    into: &identifiers,
                    seenIdentities: &seenIdentities
                )
            }
            return
        }

        if let array = value as? [Any] {
            for child in array {
                collectServerIdentifiers(
                    from: child,
                    into: &identifiers,
                    seenIdentities: &seenIdentities
                )
            }
        }
    }

    private func append(
        _ identifier: TideyRestorableSessionServerIdentifier,
        into identifiers: inout [TideyRestorableSessionServerIdentifier],
        seenIdentities: inout Set<String>
    ) {
        guard seenIdentities.insert(identifier.stableIdentity).inserted else {
            return
        }
        identifiers.append(identifier)
    }
}

@objc(TideyRestorationWindowRestoring)
protocol TideyRestorationWindowRestoring: NSObjectProtocol {
    func restoreAcceptedState()
}

@objc(TideyRestorationStateErasing)
protocol TideyRestorationStateErasing: NSObjectProtocol {
    func eraseRejectedState()
}

@objc(TideyRestorationOrphanAdoptionDiscarding)
protocol TideyRestorationOrphanAdoptionDiscarding: NSObjectProtocol {
    func discardOrphanAdoptionForLaunch()
}

@objc(TideyRestorationRejectedServerTerminating)
protocol TideyRestorationRejectedServerTerminating: NSObjectProtocol {
    func terminateRejectedSessionServers(
        _ identifiers: [TideyRestorableSessionServerIdentifier]
    )
}

@objc(TideyOrphanAdoptionGate)
@objcMembers
final class TideyOrphanAdoptionGate:
    NSObject,
    TideyRestorationOrphanAdoptionDiscarding {
    private(set) var shouldDiscardOrphanAdoptionForLaunch = false

    func discardOrphanAdoptionForLaunch() {
        shouldDiscardOrphanAdoptionForLaunch = true
    }
}

@objc(TideyRestorationMonoServerTerminating)
protocol TideyRestorationMonoServerTerminating: NSObjectProtocol {
    func terminateRejectedMonoServer(
        _ identifier: TideyRestorableSessionServerIdentifier
    )
}

@objc(TideyRestorationMultiServerChildTerminating)
protocol TideyRestorationMultiServerChildTerminating: NSObjectProtocol {
    func terminateRejectedMultiServerChild(
        _ identifier: TideyRestorableSessionServerIdentifier
    )
}

@objc(TideyRestorationRejectedServerTerminator)
@objcMembers
final class TideyRestorationRejectedServerTerminator:
    NSObject,
    TideyRestorationRejectedServerTerminating {
    private let monoServerTerminator:
        TideyRestorationMonoServerTerminating
    private let multiServerChildTerminator:
        TideyRestorationMultiServerChildTerminating

    init(
        monoServerTerminator: TideyRestorationMonoServerTerminating,
        multiServerChildTerminator:
            TideyRestorationMultiServerChildTerminating
    ) {
        self.monoServerTerminator = monoServerTerminator
        self.multiServerChildTerminator = multiServerChildTerminator
    }

    func terminateRejectedSessionServers(
        _ identifiers: [TideyRestorableSessionServerIdentifier]
    ) {
        for identifier in identifiers {
            switch identifier.kind {
            case .monoServer:
                monoServerTerminator.terminateRejectedMonoServer(
                    identifier
                )
            case .multiServerChild:
                multiServerChildTerminator
                    .terminateRejectedMultiServerChild(identifier)
            }
        }
    }
}
