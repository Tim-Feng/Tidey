import Foundation

enum TmuxInteractivePTYSessionCandidateBuilderError: Error, Equatable {
    case routeUnavailable
    case unsafeWindowSizePolicy(TmuxInteractiveWindowSizeMigrationNoOpReason)
    case invalidMigration(TmuxInteractiveWindowSizeMigration)
    case sessionBindingMismatch
}

final class TmuxInteractivePTYSessionCandidateBuilder: @unchecked Sendable {
    typealias MigrateWindow = @Sendable (
        _ socket: OrdinaryTmuxSocketSelector,
        _ windowID: String
    ) throws -> TmuxInteractiveWindowSizeMigrationOutcome
    typealias SessionFactory = @Sendable (
        TmuxInteractivePTYSessionStartRequest
    ) throws -> TmuxInteractivePTYConnectionSession

    private let routeResolver: OrdinaryTmuxRouteResolving
    private let migrateWindow: MigrateWindow
    private let sessionFactory: SessionFactory
    private let tmuxExecutablePath: String

    init(
        routeResolver: OrdinaryTmuxRouteResolving,
        migrateWindow: @escaping MigrateWindow,
        sessionFactory: @escaping SessionFactory,
        tmuxExecutablePath: String
    ) {
        self.routeResolver = routeResolver
        self.migrateWindow = migrateWindow
        self.sessionFactory = sessionFactory
        self.tmuxExecutablePath = tmuxExecutablePath
    }

    func build(
        _ subscribe: TmuxInteractiveSubscribe
    ) throws -> TmuxInteractivePTYConnectionSession {
        guard let route = try routeResolver.route(
            forPanelID: subscribe.panelID,
            workspaceID: subscribe.workspaceID
        ),
        route.workspaceID == subscribe.workspaceID,
        route.panelID == subscribe.panelID else {
            throw TmuxInteractivePTYSessionCandidateBuilderError.routeUnavailable
        }

        let migrationOutcome = try migrateWindow(route.socket, route.windowID)
        switch migrationOutcome {
        case .migrated(let migration):
            guard migration.windowID == route.windowID,
                  migration.restoredPolicy == "latest" else {
                throw TmuxInteractivePTYSessionCandidateBuilderError.invalidMigration(
                    migration
                )
            }
        case .notEligible(.currentPolicyNotOwned(let currentPolicy))
            where currentPolicy == "latest":
            break
        case .notEligible(let reason):
            throw TmuxInteractivePTYSessionCandidateBuilderError
                .unsafeWindowSizePolicy(reason)
        }

        let session = try sessionFactory(
            TmuxInteractivePTYSessionStartRequest(
                subscribe: subscribe,
                route: route,
                tmuxExecutablePath: tmuxExecutablePath
            )
        )
        guard session.binding == subscribe.binding else {
            try? session.close()
            throw TmuxInteractivePTYSessionCandidateBuilderError.sessionBindingMismatch
        }
        return session
    }
}
