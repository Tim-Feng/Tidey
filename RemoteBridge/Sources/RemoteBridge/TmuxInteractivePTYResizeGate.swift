import Foundation

enum TmuxInteractivePTYResizeGateError: Error, Equatable {
    case invalidViewport(TmuxInteractiveViewport)
}

final class TmuxInteractivePTYResizeGate: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.tidey.remote-bridge.tmux-interactive-pty-resize-gate"
    )
    private let binding: TmuxInteractiveSubscriptionBinding
    private let masterFileDescriptor: Int32
    private let controller: TmuxInteractivePTYControlling
    private var lastAppliedSize: TmuxInteractivePTYSize
    private var isActive = true

    init(
        binding: TmuxInteractiveSubscriptionBinding,
        masterFileDescriptor: Int32,
        initialSize: TmuxInteractivePTYSize,
        controller: TmuxInteractivePTYControlling
    ) {
        self.binding = binding
        self.masterFileDescriptor = masterFileDescriptor
        lastAppliedSize = initialSize
        self.controller = controller
    }

    func apply(_ request: TmuxInteractiveResize) throws -> Bool {
        try queue.sync {
            guard isActive, request.binding == binding else {
                return false
            }
            let size = try Self.validatedSize(request.viewport)
            guard size != lastAppliedSize else {
                return false
            }
            try controller.resize(masterFileDescriptor: masterFileDescriptor, to: size)
            lastAppliedSize = size
            return true
        }
    }

    func retire() {
        queue.sync {
            isActive = false
        }
    }

    private static func validatedSize(
        _ viewport: TmuxInteractiveViewport
    ) throws -> TmuxInteractivePTYSize {
        guard viewport.columns > 0,
              viewport.rows > 0,
              viewport.columns <= Int(UInt16.max),
              viewport.rows <= Int(UInt16.max) else {
            throw TmuxInteractivePTYResizeGateError.invalidViewport(viewport)
        }
        return TmuxInteractivePTYSize(
            columns: UInt16(viewport.columns),
            rows: UInt16(viewport.rows)
        )
    }
}
