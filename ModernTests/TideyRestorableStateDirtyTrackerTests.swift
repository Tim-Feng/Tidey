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
