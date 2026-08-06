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
        private var outputHandlers = [@Sendable (Data) -> Void]()
        private var exitHandlers = [@Sendable (Error?) -> Void]()
        let process = RecordingControlProcess()

        func make(
            socket: OrdinaryTmuxSocketSelector,
            sessionID: String,
            onOutput: @escaping @Sendable (Data) -> Void,
            onExit: @escaping @Sendable (Error?) -> Void
        ) throws -> OrdinaryTmuxControlModeProcessManaging {
            lock.lock()
            starts.append((socket, sessionID))
            outputHandlers.append(onOutput)
            exitHandlers.append(onExit)
            lock.unlock()
            return process
        }

        func sendOutput(_ string: String, processIndex: Int = 0) {
            lock.lock()
            let handler = outputHandlers[processIndex]
            lock.unlock()
            handler(Data(string.utf8))
        }

        func exit(_ error: Error? = nil, processIndex: Int = 0) {
            lock.lock()
            let handler = exitHandlers[processIndex]
            lock.unlock()
            handler(error)
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

    private final class FingerprintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [OrdinaryTmuxTerminalFingerprintV1?]()

        func append(_ fingerprint: OrdinaryTmuxTerminalFingerprintV1?) {
            lock.lock()
            storage.append(fingerprint)
            lock.unlock()
        }

        var values: [OrdinaryTmuxTerminalFingerprintV1?] {
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
                "refresh-client -B 'tidey-A1:%21:#{pane_id},pane=#{pane_width}x#{pane_height},window=#{window_width}x#{window_height}'",
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

    func testRegistryIgnoresInitialFingerprintAndRoutesExactChangesByWindow() throws {
        let factory = ProcessFactoryRecorder()
        let firstChanges = FingerprintBox()
        let secondChanges = FingerprintBox()
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
            makeRequest(
                subscriptionID: "strict-1",
                paneID: "%21",
                windowID: "@2",
                onRebootstrapRequired: { firstChanges.append($0) }
            )
        )
        let second = try registry.observe(
            makeRequest(
                subscriptionID: "strict-2",
                paneID: "%22",
                windowID: "@3",
                onRebootstrapRequired: { secondChanges.append($0) }
            )
        )
        let firstName = factory.process.added[0].name
        let secondName = factory.process.added[1].name

        factory.sendOutput(
            "%subscription-changed \(firstName) $1 @2 0 %21 : %21,pane=132x40,window=132x40\n"
        )
        factory.sendOutput(
            "%subscription-changed unknown $1 @2 0 %21 : %21,pane=80x24,window=80x24\n"
        )
        registry.waitForIdleForTesting()
        XCTAssertEqual(firstChanges.values.count, 0)
        XCTAssertEqual(secondChanges.values.count, 0)

        factory.sendOutput(
            "%subscription-changed \(firstName) $1 @2 0 %21 future : %21,pane=120x40,window=120x40\n"
        )
        factory.sendOutput("%layout-change @3 layout visible flags\n")
        factory.sendOutput("%window-pane-changed @2 %99\n")
        factory.sendOutput(
            "%subscription-changed \(secondName) $1 @3 1 %22 : %22,pane=90x30,window=90x30\n"
        )
        registry.waitForIdleForTesting()

        XCTAssertEqual(
            firstChanges.values,
            [
                OrdinaryTmuxTerminalFingerprintV1(
                    paneID: "%21",
                    columns: 120,
                    rows: 40,
                    alternateOn: false
                ),
            ]
        )
        XCTAssertEqual(secondChanges.values.count, 1)
        XCTAssertNil(secondChanges.values[0])

        first.stop()
        second.stop()
    }

    private func makeRequest(
        subscriptionID: String,
        paneID: String,
        windowID: String,
        onRebootstrapRequired: @escaping @Sendable (
            OrdinaryTmuxTerminalFingerprintV1?
        ) -> Void = { _ in }
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
            onRebootstrapRequired: onRebootstrapRequired
        )
    }
}
