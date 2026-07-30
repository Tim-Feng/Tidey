import XCTest
@testable import iTerm2SharedARC

final class TideyRestorableStateDirtyTrackerTests: XCTestCase {
    func testDirtyGenerationAndTickDriverSeamsCompile() throws {
        let tracker = TideyRestorableStateDirtyTracker()
        let tickDriver = TideyRestorableStateTickDriverSpy()

        tickDriver.start(interval: 30) {
            tracker.markDirty()
        }
        XCTAssertEqual(tickDriver.startedInterval, 30)
        tickDriver.fire()

        let capturedGeneration = try XCTUnwrap(
            tracker.captureGenerationForSave()
        )
        XCTAssertEqual(capturedGeneration.value, 1)

        tracker.markDirty()
        tracker.acknowledgeSavedGeneration(capturedGeneration)

        XCTAssertTrue(tracker.isDirty)
        XCTAssertEqual(tracker.dirtyGeneration, 2)
        XCTAssertEqual(tracker.savedGeneration, 1)

        tickDriver.stop()
        XCTAssertTrue(tickDriver.didStop)
    }

    func testPeriodicTickSavesOnlyDirtyReadyStateAndPreservesConcurrentMutation() {
        let tracker = TideyRestorableStateDirtyTracker()
        let tickDriver = TideyRestorableStateTickDriverSpy()
        let saveRequester = TideyRestorableStatePeriodicSaveRequesterSpy()
        let periodicSaver = TideyRestorableStatePeriodicSaver(
            dirtyTracker: tracker,
            tickDriver: tickDriver,
            saveRequester: saveRequester
        )

        periodicSaver.start()

        XCTAssertEqual(tickDriver.startedInterval, 30)

        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 0)

        tracker.markDirty()
        saveRequester.stateRestorationEnabled = false
        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 0)

        saveRequester.stateRestorationEnabled = true
        saveRequester.isReady = false
        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 0)

        saveRequester.isReady = true
        saveRequester.isRestoring = true
        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 0)

        saveRequester.isRestoring = false
        saveRequester.acceptsNextSave = false
        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 1)
        XCTAssertTrue(tracker.isDirty)

        saveRequester.acceptsNextSave = true
        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 2)
        XCTAssertTrue(tracker.isDirty)

        tracker.markDirty()
        saveRequester.completeNextSave()

        XCTAssertTrue(tracker.isDirty)
        XCTAssertEqual(tracker.dirtyGeneration, 2)
        XCTAssertEqual(tracker.savedGeneration, 1)

        tickDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 3)
        saveRequester.completeNextSave()

        XCTAssertFalse(tracker.isDirty)
        XCTAssertEqual(tracker.savedGeneration, 2)

        periodicSaver.stop()
        XCTAssertTrue(tickDriver.didStop)
    }
}

private final class TideyRestorableStateTickDriverSpy:
    NSObject,
    TideyRestorableStateTickDriving {
    private var handler: (() -> Void)?
    private(set) var startedInterval: TimeInterval?
    private(set) var didStop = false

    func start(
        interval: TimeInterval,
        handler: @escaping () -> Void
    ) {
        startedInterval = interval
        self.handler = handler
    }

    func stop() {
        didStop = true
        handler = nil
    }

    func fire() {
        handler?()
    }
}

private final class TideyRestorableStatePeriodicSaveRequesterSpy:
    NSObject,
    TideyRestorableStatePeriodicSaveRequesting {
    var stateRestorationEnabled = true
    var isReady = true
    var isRestoring = false
    var acceptsNextSave = true
    private(set) var requestCount = 0
    private var completions = [() -> Void]()

    var canRequestPeriodicSave: Bool {
        stateRestorationEnabled && isReady && !isRestoring
    }

    func requestPeriodicSave(
        completion: @escaping () -> Void
    ) -> Bool {
        requestCount += 1
        guard acceptsNextSave else {
            return false
        }
        completions.append(completion)
        return true
    }

    func completeNextSave() {
        completions.removeFirst()()
    }
}
