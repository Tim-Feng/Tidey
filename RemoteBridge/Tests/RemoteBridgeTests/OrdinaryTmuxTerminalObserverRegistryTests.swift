import Foundation
import XCTest
@testable import RemoteBridge

final class OrdinaryTmuxTerminalObserverRegistryTests: XCTestCase {
    private final class RecordingControlProcess: OrdinaryTmuxControlModeProcessManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var addedStorage = [(name: String, paneID: String)]()
        private var removedStorage = [String]()
        private var detachStorage = 0

        func addSubscription(name: String, paneID: String) throws {
            lock.lock()
            addedStorage.append((name, paneID))
            lock.unlock()
        }

        func removeSubscription(name: String) throws {
            lock.lock()
            removedStorage.append(name)
            lock.unlock()
        }

        func detachAndWait() {
            lock.lock()
            detachStorage += 1
            lock.unlock()
        }

        var added: [(name: String, paneID: String)] {
            lock.lock()
            defer { lock.unlock() }
            return addedStorage
        }

        var removed: [String] {
            lock.lock()
            defer { lock.unlock() }
            return removedStorage
        }

        var detachCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return detachStorage
        }
    }

    private final class ProcessFactoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var starts = [(socket: OrdinaryTmuxSocketSelector, sessionID: String)]()
        let process = RecordingControlProcess()

        func make(
            socket: OrdinaryTmuxSocketSelector,
            sessionID: String,
            onOutput: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Error?) -> Void
        ) throws -> OrdinaryTmuxControlModeProcessManaging {
            lock.lock()
            starts.append((socket, sessionID))
            lock.unlock()
            return process
        }

        var startCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return starts.count
        }
    }

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [String]()

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class StubControlProcess: OrdinaryTmuxControlModeProcessManaging, @unchecked Sendable {
        func addSubscription(name: String, paneID: String) throws {}
        func removeSubscription(name: String) throws {}
        func detachAndWait() {}
    }

    private final class StubLease: OrdinaryTmuxTerminalObserverLeasing, @unchecked Sendable {
        func stop() {}
    }

    private struct StubObserver: OrdinaryTmuxTerminalObserving {
        func observe(
            _ request: OrdinaryTmuxTerminalObservationRequest
        ) throws -> OrdinaryTmuxTerminalObserverLeasing {
            XCTAssertEqual(request.route.activePaneID, "%21")
            XCTAssertEqual(request.subscriptionID, "strict-1")
            XCTAssertEqual(request.expectedFingerprint.columns, 132)
            return StubLease()
        }
    }

    func testObserverContractCompiles() throws {
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:runtime-default:$1:@2",
            carrierPanelID: "carrier-1",
            socket: .defaultSocket,
            sessionID: "$1",
            sessionName: "work",
            windowID: "@2",
            windowIndex: 2,
            activePaneID: "%21",
            cwd: nil,
            currentCommand: nil
        )
        let fingerprint = OrdinaryTmuxTerminalFingerprintV1(
            paneID: "%21",
            columns: 132,
            rows: 40,
            alternateOn: false
        )
        let request = OrdinaryTmuxTerminalObservationRequest(
            route: route,
            subscriptionID: "strict-1",
            expectedFingerprint: fingerprint,
            onRebootstrapRequired: { _ in }
        )

        let lease = try StubObserver().observe(request)
        lease.stop()
    }

    func testManagedControlProcessContractCompiles() throws {
        let factory: OrdinaryTmuxControlModeProcessFactory = {
            socket,
            sessionID,
            onOutput,
            onExit in
            XCTAssertEqual(socket, .defaultSocket)
            XCTAssertEqual(sessionID, "$1")
            onOutput(Data("%session-changed $1 work\n".utf8))
            onExit(nil)
            return StubControlProcess()
        }

        let process = try factory(.defaultSocket, "$1", { _ in }, { _ in })
        try process.addSubscription(name: "tidey-1", paneID: "%21")
        try process.removeSubscription(name: "tidey-1")
        process.detachAndWait()
    }

    func testManagedProcessBuildsReadOnlyExactSubscriptionsWithoutResizeCommands() throws {
        XCTAssertEqual(
            OrdinaryTmuxManagedControlModeProcess.launchArguments(
                socket: .path("/private/tmp/tmux-501/default"),
                sessionID: "$1"
            ),
            [
                "-S", "/private/tmp/tmux-501/default",
                "-f", "/dev/null",
                "-C", "attach-session",
                "-t", "$1",
                "-f", "read-only,ignore-size,no-output",
            ]
        )

        let commands = StringBox()
        let process = OrdinaryTmuxManagedControlModeProcess(
            writeLine: { commands.append($0) },
            waitForExit: {}
        )

        try process.addSubscription(name: "tidey-A1", paneID: "%21")
        try process.removeSubscription(name: "tidey-A1")
        process.detachAndWait()

        XCTAssertEqual(
            commands.values,
            [
                "refresh-client -B 'tidey-A1:%21:#{pane_id},pane=#{pane_width}x#{pane_height},window=#{window_width}x#{window_height},alternate=#{alternate_on}'",
                "refresh-client -B 'tidey-A1'",
                "detach-client",
            ]
        )
        XCTAssertFalse(commands.values.contains { $0.contains("refresh-client -C") })
    }

    func testRegistryReusesOneSessionProcessAndDetachesAfterLastExactLease() throws {
        let factory = ProcessFactoryRecorder()
        let registry = OrdinaryTmuxTerminalObserverRegistry(
            makeProcess: { socket, sessionID, onOutput, onExit in
                try factory.make(
                    socket: socket,
                    sessionID: sessionID,
                    onOutput: onOutput,
                    onExit: onExit
                )
            }
        )

        let first = try registry.observe(
            makeRequest(subscriptionID: "strict-1", paneID: "%21", windowID: "@2")
        )
        let firstSibling = try registry.observe(
            makeRequest(subscriptionID: "strict-1b", paneID: "%21", windowID: "@2")
        )
        let second = try registry.observe(
            makeRequest(subscriptionID: "strict-2", paneID: "%22", windowID: "@3")
        )

        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.process.added.map(\.paneID), ["%21", "%22"])
        XCTAssertEqual(Set(factory.process.added.map(\.name)).count, 2)

        first.stop()
        XCTAssertEqual(factory.process.removed, [])
        firstSibling.stop()
        XCTAssertEqual(factory.process.removed, [factory.process.added[0].name])
        XCTAssertEqual(factory.process.detachCount, 0)

        second.stop()
        second.stop()
        XCTAssertEqual(
            factory.process.removed,
            factory.process.added.map(\.name)
        )
        XCTAssertEqual(factory.process.detachCount, 1)
    }

    private func makeRequest(
        subscriptionID: String,
        paneID: String,
        windowID: String
    ) -> OrdinaryTmuxTerminalObservationRequest {
        let route = OrdinaryTmuxPanelRoute(
            workspaceID: "workspace-1",
            panelID: "ordinary-tmux:runtime-default:$1:\(windowID)",
            carrierPanelID: "carrier-1",
            socket: .defaultSocket,
            sessionID: "$1",
            sessionName: "work",
            windowID: windowID,
            windowIndex: 2,
            activePaneID: paneID,
            cwd: nil,
            currentCommand: nil
        )
        return OrdinaryTmuxTerminalObservationRequest(
            route: route,
            subscriptionID: subscriptionID,
            expectedFingerprint: OrdinaryTmuxTerminalFingerprintV1(
                paneID: paneID,
                columns: 132,
                rows: 40,
                alternateOn: false
            ),
            onRebootstrapRequired: { _ in }
        )
    }
}
