import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserNavigationGateTests: XCTestCase {
    func testLimitsConcurrentNavigationsGloballyAndPerOrigin() async throws {
        let gate = TideyBrowserNavigationGate(
            maximumConcurrent: 4,
            maximumPerOrigin: 2,
            maximumQueued: 8
        )
        let a1 = try await gate.acquire(origin: "https://a.example")
        let a2 = try await gate.acquire(origin: "https://a.example")
        let b1 = try await gate.acquire(origin: "https://b.example")
        let b2 = try await gate.acquire(origin: "https://b.example")

        let queued = Task {
            try await gate.acquire(origin: "https://c.example")
        }
        try await waitUntil { await gate.snapshot().queuedCount == 1 }

        var snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeCount, 4)
        XCTAssertEqual(snapshot.activeByOrigin["https://a.example"], 2)
        XCTAssertEqual(snapshot.activeByOrigin["https://b.example"], 2)

        await gate.release(a1)
        let c1 = try await queued.value
        snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeCount, 4)
        XCTAssertEqual(snapshot.activeByOrigin["https://c.example"], 1)

        await gate.release(a2)
        await gate.release(b1)
        await gate.release(b2)
        await gate.release(c1)
        snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeCount, 0)
    }

    func testPerOriginWaiterDoesNotBlockAnotherOrigin() async throws {
        let gate = TideyBrowserNavigationGate(
            maximumConcurrent: 3,
            maximumPerOrigin: 2,
            maximumQueued: 8
        )
        let a1 = try await gate.acquire(origin: "https://a.example")
        let a2 = try await gate.acquire(origin: "https://a.example")
        let queuedA = Task { try await gate.acquire(origin: "https://a.example") }
        try await waitUntil { await gate.snapshot().queuedCount == 1 }

        let b1 = try await gate.acquire(origin: "https://b.example")
        var snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.activeCount, 3)
        await gate.release(b1)
        snapshot = await gate.snapshot()
        XCTAssertEqual(snapshot.queuedCount, 1)

        await gate.release(a1)
        let a3 = try await queuedA.value
        await gate.release(a2)
        await gate.release(a3)
    }

    func testRejectsWhenBoundedQueueIsFull() async throws {
        let gate = TideyBrowserNavigationGate(
            maximumConcurrent: 1,
            maximumPerOrigin: 1,
            maximumQueued: 1
        )
        let active = try await gate.acquire(origin: "https://a.example")
        let queued = Task { try await gate.acquire(origin: "https://b.example") }
        try await waitUntil { await gate.snapshot().queuedCount == 1 }

        do {
            _ = try await gate.acquire(origin: "https://c.example")
            XCTFail("Expected bounded queue rejection")
        } catch let error as TideyBrowserAutomationProtocolError {
            XCTAssertEqual(error.code, .busy)
        }

        await gate.release(active)
        let b1 = try await queued.value
        await gate.release(b1)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for navigation gate state")
    }
}
