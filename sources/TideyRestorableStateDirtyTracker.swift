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

@objc(TideyRestorableStatePeriodicSaveRequesting)
protocol TideyRestorableStatePeriodicSaveRequesting: NSObjectProtocol {
    var canRequestPeriodicSave: Bool { get }

    @objc(requestPeriodicSaveWithCompletion:)
    func requestPeriodicSave(
        completion: @escaping () -> Void
    ) -> Bool
}

@objc(TideyRestorableStatePeriodicSaver)
@objcMembers
final class TideyRestorableStatePeriodicSaver: NSObject {
    private static let saveInterval: TimeInterval = 30

    private let dirtyTracker: TideyRestorableStateDirtyTracker
    private let tickDriver: TideyRestorableStateTickDriving
    private weak var saveRequester:
        TideyRestorableStatePeriodicSaveRequesting?

    init(
        dirtyTracker: TideyRestorableStateDirtyTracker,
        tickDriver: TideyRestorableStateTickDriving,
        saveRequester: TideyRestorableStatePeriodicSaveRequesting
    ) {
        self.dirtyTracker = dirtyTracker
        self.tickDriver = tickDriver
        self.saveRequester = saveRequester
        super.init()
    }

    func start() {
        it_assert(Thread.isMainThread)
        tickDriver.start(interval: Self.saveInterval) { [weak self] in
            self?.saveIfNeeded()
        }
    }

    func stop() {
        it_assert(Thread.isMainThread)
        tickDriver.stop()
    }

    private func saveIfNeeded() {
        it_assert(Thread.isMainThread)
        guard let saveRequester,
              saveRequester.canRequestPeriodicSave,
              let generation = dirtyTracker.captureGenerationForSave() else {
            return
        }
        _ = saveRequester.requestPeriodicSave { [weak self] in
            guard let self else {
                return
            }
            it_assert(Thread.isMainThread)
            self.dirtyTracker.acknowledgeSavedGeneration(generation)
        }
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
