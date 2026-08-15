import Foundation

struct TmuxInteractivePTYRuntime: Sendable {
    let activation: TmuxInteractivePTYActivation
    let ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext

    private init(
        activation: TmuxInteractivePTYActivation,
        ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext
    ) {
        self.activation = activation
        self.ordinaryTmuxProjectionContext = ordinaryTmuxProjectionContext
    }

    static func disabled() -> TmuxInteractivePTYRuntime {
        TmuxInteractivePTYRuntime(
            activation: .disabled,
            ordinaryTmuxProjectionContext: OrdinaryTmuxProjectionContext()
        )
    }

    static func production(
        tmuxExecutablePath: String? = TmuxStateResolver.discoverTmuxBinaryPath()
    ) -> TmuxInteractivePTYRuntime {
        guard let tmuxExecutablePath,
              tmuxExecutablePath.first == "/" else {
            return disabled()
        }
        return enabled(tmuxExecutablePath: tmuxExecutablePath)
    }

    static func enabled(
        tmuxExecutablePath: String
    ) -> TmuxInteractivePTYRuntime {
        let migrator = TmuxInteractiveWindowSizeMigrator(
            tmuxExecutablePath: tmuxExecutablePath
        )
        return enabled(
            tmuxExecutablePath: tmuxExecutablePath,
            controller: TmuxInteractivePTYController(),
            attachProver: TmuxInteractiveAttachProver(
                tmuxExecutablePath: tmuxExecutablePath
            ),
            migrateWindow: { socket, windowID in
                try migrator.migrateIfEligible(
                    socket: socket,
                    windowID: windowID,
                    hasLaterPolicyChangeEvidence: false
                )
            }
        )
    }

    static func enabled(
        tmuxExecutablePath: String,
        controller: TmuxInteractivePTYControlling,
        attachProver: TmuxInteractiveAttachProving,
        migrateWindow: @escaping
            TmuxInteractivePTYSessionCandidateBuilder.MigrateWindow
    ) -> TmuxInteractivePTYRuntime {
        let projectionContext = OrdinaryTmuxProjectionContext(
            windowSizePolicyReconciliationMode:
                .preserveForInteractiveSizing
        )
        let candidateBuilder = TmuxInteractivePTYSessionCandidateBuilder(
            routeResolver: OrdinaryTmuxRouteResolver(
                registry: projectionContext.registry
            ),
            migrateWindow: migrateWindow,
            sessionFactory: { request in
                let owner = TmuxInteractivePTYSessionOwner(
                    admissionStore: projectionContext.inputSubmissionStore,
                    controller: controller,
                    attachProver: attachProver,
                    authoritativeStartQuiescenceNanoseconds:
                        TmuxInteractivePTYSessionOwner
                            .productionAuthoritativeStartQuiescenceNanoseconds
                )
                try owner.begin(request)
                return TmuxInteractivePTYConnectionSession(
                    binding: request.subscribe.binding,
                    owner: owner
                )
            },
            tmuxExecutablePath: tmuxExecutablePath
        )
        return TmuxInteractivePTYRuntime(
            activation: .enabled(candidateBuilder),
            ordinaryTmuxProjectionContext: projectionContext
        )
    }
}
