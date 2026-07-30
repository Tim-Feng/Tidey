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
    private(set) var dirtyGeneration = 0
    private(set) var savedGeneration = 0

    var isDirty: Bool {
        dirtyGeneration > savedGeneration
    }

    func markDirty() {
        guard dirtyGeneration < Int.max else {
            return
        }
        dirtyGeneration += 1
    }

    func captureGenerationForSave() -> TideyRestorableStateSaveGeneration? {
        guard isDirty else {
            return nil
        }
        return TideyRestorableStateSaveGeneration(value: dirtyGeneration)
    }

    func acknowledgeSavedGeneration(
        _ generation: TideyRestorableStateSaveGeneration
    ) {
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
