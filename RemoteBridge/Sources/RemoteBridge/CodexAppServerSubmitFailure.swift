import Foundation

// Outcomes proven to have zero semantic effect. Every other submit failure
// remains indeterminate because the request may have reached app-server.
enum CodexAppServerSubmitFailure: Error, Equatable {
    case busyWithoutTurnID
    case rejected(String)
    case unavailableBeforeSend(String)
}
