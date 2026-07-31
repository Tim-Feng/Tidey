import Foundation

@objc(TideyRestorableStateSaveGeneration)
@objcMembers
final class TideyRestorableStateSaveGeneration: NSObject {
    let value: Int

    fileprivate init(value: Int) {
        self.value = value
    }
}

@objc(TideyRestorableStateDirtyTracker)
@objcMembers
final class TideyRestorableStateDirtyTracker: NSObject {
    static let shared = TideyRestorableStateDirtyTracker()

    private(set) var dirtyGeneration = 0
    private(set) var savedGeneration = 0

    var isDirty: Bool {
        it_assert(Thread.isMainThread)
        return dirtyGeneration > savedGeneration
    }

    func markDirty() {
        it_assert(Thread.isMainThread)
        guard dirtyGeneration < Int.max else {
            return
        }
        dirtyGeneration += 1
    }

    func captureGenerationForSave() -> TideyRestorableStateSaveGeneration? {
        it_assert(Thread.isMainThread)
        guard isDirty else {
            return nil
        }
        return TideyRestorableStateSaveGeneration(value: dirtyGeneration)
    }

    func acknowledgeSavedGeneration(
        _ generation: TideyRestorableStateSaveGeneration
    ) {
        it_assert(Thread.isMainThread)
        guard generation.value <= dirtyGeneration else {
            return
        }
        savedGeneration = max(savedGeneration, generation.value)
    }
}

@objc(TideyRestorableStateTickDriving)
protocol TideyRestorableStateTickDriving: NSObjectProtocol {
    @objc(startWithInterval:handler:)
    func start(
        interval: TimeInterval,
        handler: @escaping () -> Void
    )

    func stop()
}

@objc(TideyRestorableStateDebounceDriving)
protocol TideyRestorableStateDebounceDriving: NSObjectProtocol {
    @objc(scheduleOnceAfter:handler:)
    func scheduleOnce(
        after delay: TimeInterval,
        handler: @escaping () -> Void
    )

    func cancelPending()
}

@objc(TideyRestorableStatePeriodicSaveRequesting)
protocol TideyRestorableStatePeriodicSaveRequesting: NSObjectProtocol {
    var canRequestPeriodicSave: Bool { get }

    @objc(requestPeriodicSaveWithCompletion:)
    func requestPeriodicSave(
        completion: @escaping () -> Void
    ) -> Bool
}

@objc(TideyRestorableStateWorkspaceEventPolicy)
@objcMembers
final class TideyRestorableStateWorkspaceEventPolicy: NSObject {
    @objc(shouldRequestSaveSoonForEventKind:)
    static func shouldRequestSaveSoon(
        forEventKind kind: String
    ) -> Bool {
        switch kind {
        case "workspace_created",
             "workspace_closed",
             "workspace_updated",
             "panel_created",
             "panel_closed",
             "panel_updated":
            return true
        default:
            return false
        }
    }
}

@objc(TideyRestorableStateSaveScheduler)
@objcMembers
final class TideyRestorableStateSaveScheduler: NSObject {
    private enum SaveTrigger: Equatable {
        case ambient
        case prompt
    }

    private static let ambientSaveInterval: TimeInterval = 600
    private static let promptSaveDelay: TimeInterval = 5
    private static let maximumConsecutiveRefusalRetries = 3

    private let dirtyTracker: TideyRestorableStateDirtyTracker
    private let periodicTickDriver: TideyRestorableStateTickDriving
    private let debounceDriver: TideyRestorableStateDebounceDriving
    private weak var saveRequester:
        TideyRestorableStatePeriodicSaveRequesting?
    private var isRunning = false
    private var acceptedSaveInFlight = false
    private var promptSavePending = false
    private var promptDelayElapsed = false
    private var promptTimerScheduled = false
    private var consecutiveRefusalCount = 0

    init(
        dirtyTracker: TideyRestorableStateDirtyTracker,
        periodicTickDriver: TideyRestorableStateTickDriving,
        debounceDriver: TideyRestorableStateDebounceDriving,
        saveRequester: TideyRestorableStatePeriodicSaveRequesting
    ) {
        self.dirtyTracker = dirtyTracker
        self.periodicTickDriver = periodicTickDriver
        self.debounceDriver = debounceDriver
        self.saveRequester = saveRequester
        super.init()
    }

    func start() {
        it_assert(Thread.isMainThread)
        isRunning = true
        periodicTickDriver.start(
            interval: Self.ambientSaveInterval
        ) { [weak self] in
            self?.saveIfNeeded(trigger: .ambient)
        }
    }

    func requestSaveSoon() {
        it_assert(Thread.isMainThread)
        guard isRunning else {
            return
        }
        promptSavePending = true
        promptDelayElapsed = false
        consecutiveRefusalCount = 0
        armPromptTimer()
    }

    func stop() {
        it_assert(Thread.isMainThread)
        isRunning = false
        promptSavePending = false
        promptDelayElapsed = false
        promptTimerScheduled = false
        consecutiveRefusalCount = 0
        periodicTickDriver.stop()
        debounceDriver.cancelPending()
    }

    private func armPromptTimer() {
        it_assert(Thread.isMainThread)
        guard isRunning else {
            return
        }
        promptTimerScheduled = true
        debounceDriver.scheduleOnce(
            after: Self.promptSaveDelay
        ) { [weak self] in
            self?.promptTimerDidFire()
        }
    }

    private func promptTimerDidFire() {
        it_assert(Thread.isMainThread)
        promptTimerScheduled = false
        guard isRunning else {
            return
        }
        promptDelayElapsed = true
        saveIfNeeded(trigger: .prompt)
    }

    private func saveIfNeeded(trigger: SaveTrigger) {
        it_assert(Thread.isMainThread)
        guard isRunning,
              !acceptedSaveInFlight else {
            return
        }
        guard let saveRequester,
              saveRequester.canRequestPeriodicSave,
              let generation = dirtyTracker.captureGenerationForSave() else {
            if trigger == .prompt {
                clearPromptRequest()
            }
            return
        }
        acceptedSaveInFlight = true
        let accepted = saveRequester.requestPeriodicSave { [weak self] in
            guard let self else {
                return
            }
            self.didCompleteSave(generation: generation)
        }
        guard accepted else {
            acceptedSaveInFlight = false
            retryAfterRefusal()
            return
        }
        consecutiveRefusalCount = 0
        if trigger == .prompt {
            clearPromptRequest()
        }
    }

    private func retryAfterRefusal() {
        it_assert(Thread.isMainThread)
        consecutiveRefusalCount += 1
        guard consecutiveRefusalCount <=
                Self.maximumConsecutiveRefusalRetries else {
            clearPromptRequest()
            return
        }
        promptSavePending = true
        promptDelayElapsed = false
        armPromptTimer()
    }

    private func didCompleteSave(
        generation: TideyRestorableStateSaveGeneration
    ) {
        it_assert(Thread.isMainThread)
        dirtyTracker.acknowledgeSavedGeneration(generation)
        acceptedSaveInFlight = false
        guard isRunning,
              promptSavePending,
              promptDelayElapsed,
              !promptTimerScheduled else {
            return
        }
        saveIfNeeded(trigger: .prompt)
    }

    private func clearPromptRequest() {
        promptSavePending = false
        promptDelayElapsed = false
        promptTimerScheduled = false
    }
}

@objc(TideyRestorableStateTimerTickDriver)
@objcMembers
final class TideyRestorableStateTimerTickDriver:
    NSObject,
    TideyRestorableStateTickDriving {
    private var timer: Timer?

    func start(
        interval: TimeInterval,
        handler: @escaping () -> Void
    ) {
        it_assert(Thread.isMainThread)
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            handler()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        it_assert(Thread.isMainThread)
        timer?.invalidate()
        timer = nil
    }
}

@objc(TideyRestorableStateTimerDebounceDriver)
@objcMembers
final class TideyRestorableStateTimerDebounceDriver:
    NSObject,
    TideyRestorableStateDebounceDriving {
    private var timer: Timer?

    func scheduleOnce(
        after delay: TimeInterval,
        handler: @escaping () -> Void
    ) {
        it_assert(Thread.isMainThread)
        cancelPending()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            handler()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancelPending() {
        it_assert(Thread.isMainThread)
        timer?.invalidate()
        timer = nil
    }
}
