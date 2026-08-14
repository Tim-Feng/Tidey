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
}
