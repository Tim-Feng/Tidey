import XCTest
@testable import iTerm2SharedARC

final class TideyRestorableStateDirtyTrackerTests: XCTestCase {
    func testWorkspaceEventPolicyRequestsPromptSaveOnlyForImportantMutations() {
        let importantKinds = [
            "workspace_created",
            "workspace_closed",
            "workspace_updated",
            "panel_created",
            "panel_closed",
            "panel_updated",
        ]

        for kind in importantKinds {
            XCTAssertTrue(
                TideyRestorableStateWorkspaceEventPolicy
                    .shouldRequestSaveSoon(forEventKind: kind),
                kind
            )
        }
        XCTAssertFalse(
            TideyRestorableStateWorkspaceEventPolicy
                .shouldRequestSaveSoon(
                    forEventKind: "workspace_selected"
                )
        )
        XCTAssertFalse(
            TideyRestorableStateWorkspaceEventPolicy
                .shouldRequestSaveSoon(forEventKind: "panel_selected")
        )
        XCTAssertFalse(
            TideyRestorableStateWorkspaceEventPolicy
                .shouldRequestSaveSoon(forEventKind: "future_event")
        )
    }

    func testSaveSchedulerAndDebounceDriverSeamsCompile() {
        let scheduler = TideyRestorableStateSaveScheduler(
            dirtyTracker: TideyRestorableStateDirtyTracker(),
            periodicTickDriver: TideyRestorableStateTickDriverSpy(),
            debounceDriver: TideyRestorableStateDebounceDriverSpy(),
            saveRequester: TideyRestorableStatePeriodicSaveRequesterSpy()
        )

        scheduler.requestSaveSoon()
        scheduler.stop()
    }

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
        let debounceDriver = TideyRestorableStateDebounceDriverSpy()
        let saveRequester = TideyRestorableStatePeriodicSaveRequesterSpy()
        let periodicSaver = TideyRestorableStateSaveScheduler(
            dirtyTracker: tracker,
            periodicTickDriver: tickDriver,
            debounceDriver: debounceDriver,
            saveRequester: saveRequester
        )

        periodicSaver.start()

        XCTAssertEqual(tickDriver.startedInterval, 600)

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

    func testSaveSchedulerUsesTenMinuteFallbackAndTrailingEdgePromptSaves() {
        let tracker = TideyRestorableStateDirtyTracker()
        let tickDriver = TideyRestorableStateTickDriverSpy()
        let debounceDriver = TideyRestorableStateDebounceDriverSpy()
        let saveRequester = TideyRestorableStatePeriodicSaveRequesterSpy()
        let scheduler = TideyRestorableStateSaveScheduler(
            dirtyTracker: tracker,
            periodicTickDriver: tickDriver,
            debounceDriver: debounceDriver,
            saveRequester: saveRequester
        )

        scheduler.start()
        XCTAssertEqual(tickDriver.startedInterval, 600)

        tracker.markDirty()
        scheduler.requestSaveSoon()
        scheduler.requestSaveSoon()

        XCTAssertEqual(debounceDriver.scheduledDelay, 5)
        XCTAssertEqual(debounceDriver.scheduleCount, 2)
        XCTAssertEqual(saveRequester.requestCount, 0)

        debounceDriver.fire()

        XCTAssertEqual(saveRequester.requestCount, 1)
        XCTAssertTrue(tracker.isDirty)

        saveRequester.completeNextSave()

        XCTAssertFalse(tracker.isDirty)
    }

    func testSaveSchedulerRetriesRefusedPromptAndPreservesConcurrentMutation() {
        let tracker = TideyRestorableStateDirtyTracker()
        let debounceDriver = TideyRestorableStateDebounceDriverSpy()
        let saveRequester = TideyRestorableStatePeriodicSaveRequesterSpy()
        let scheduler = TideyRestorableStateSaveScheduler(
            dirtyTracker: tracker,
            periodicTickDriver: TideyRestorableStateTickDriverSpy(),
            debounceDriver: debounceDriver,
            saveRequester: saveRequester
        )

        scheduler.start()
        tracker.markDirty()
        saveRequester.acceptsNextSave = false
        scheduler.requestSaveSoon()
        debounceDriver.fire()

        XCTAssertEqual(saveRequester.requestCount, 1)
        XCTAssertTrue(tracker.isDirty)
        XCTAssertEqual(debounceDriver.scheduleCount, 2)

        saveRequester.acceptsNextSave = true
        debounceDriver.fire()
        XCTAssertEqual(saveRequester.requestCount, 2)

        tracker.markDirty()
        scheduler.requestSaveSoon()
        debounceDriver.fire()

        XCTAssertEqual(saveRequester.requestCount, 2)

        saveRequester.completeNextSave()

        XCTAssertTrue(tracker.isDirty)
        XCTAssertEqual(saveRequester.requestCount, 3)

        saveRequester.completeNextSave()

        XCTAssertFalse(tracker.isDirty)
        XCTAssertEqual(tracker.savedGeneration, 2)
    }

    func testSaveSchedulerBoundsConsecutiveRefusalRetries() {
        let tracker = TideyRestorableStateDirtyTracker()
        let debounceDriver = TideyRestorableStateDebounceDriverSpy()
        let saveRequester = TideyRestorableStatePeriodicSaveRequesterSpy()
        let scheduler = TideyRestorableStateSaveScheduler(
            dirtyTracker: tracker,
            periodicTickDriver: TideyRestorableStateTickDriverSpy(),
            debounceDriver: debounceDriver,
            saveRequester: saveRequester
        )

        scheduler.start()
        tracker.markDirty()
        saveRequester.acceptsNextSave = false
        scheduler.requestSaveSoon()

        debounceDriver.fire()
        debounceDriver.fire()
        debounceDriver.fire()
        debounceDriver.fire()
        debounceDriver.fire()

        XCTAssertEqual(saveRequester.requestCount, 4)
        XCTAssertEqual(debounceDriver.scheduleCount, 4)
        XCTAssertTrue(tracker.isDirty)
    }
}

private final class TideyRestorableStateDebounceDriverSpy:
    NSObject,
    TideyRestorableStateDebounceDriving {
    private var handler: (() -> Void)?
    private(set) var scheduledDelay: TimeInterval?
    private(set) var scheduleCount = 0
    private(set) var didCancel = false

    func scheduleOnce(
        after delay: TimeInterval,
        handler: @escaping () -> Void
    ) {
        scheduleCount += 1
        scheduledDelay = delay
        self.handler = handler
    }

    func cancelPending() {
        didCancel = true
        handler = nil
    }

    func fire() {
        let handler = handler
        self.handler = nil
        handler?()
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
