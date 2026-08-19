import XCTest
@testable import iTerm2SharedARC

final class TideyBrowserAutomationStoreTests: XCTestCase {
    func testPrivateTabIdentityAndOwnershipSeam() {
        let state = TideyBrowserAutomationState(
            maxPrivateTabs: 8,
            handoffTTL: 30 * 60
        )

        XCTAssertEqual(state.maxPrivateTabs, 8)
        XCTAssertEqual(state.handoffTTL, 30 * 60)
        XCTAssertTrue(state.privateTabsByID.isEmpty)
        XCTAssertTrue(state.userClaimsByTabID.isEmpty)
        XCTAssertEqual(
            TideyBrowserAutomationTabMark.deliverable.rawValue,
            "deliverable"
        )
    }

    func testPrivateTabsAreBoundedAndFailClosedAcrossOwners() throws {
        var state = TideyBrowserAutomationState(maxPrivateTabs: 2)

        try state.registerPrivateTab(
            tabID: "private-1",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )
        try state.registerPrivateTab(
            tabID: "private-2",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )

        XCTAssertThrowsError(
            try state.registerPrivateTab(
                tabID: "private-3",
                workspaceID: "workspace-a",
                ownerSessionID: "session-a"
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .tabLimitReached)
        }
        XCTAssertThrowsError(
            try state.markPrivateTab(
                tabID: "private-1",
                workspaceID: "workspace-a",
                ownerSessionID: "session-b",
                mark: .deliverable
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .ownershipConflict)
        }
        XCTAssertThrowsError(
            try state.markPrivateTab(
                tabID: "private-1",
                workspaceID: "workspace-b",
                ownerSessionID: "session-a",
                mark: .deliverable
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .workspaceMismatch)
        }
    }

    func testDisconnectClosesAdoptsRetainsAndReleasesByMark() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var state = TideyBrowserAutomationState(handoffTTL: 1_800)
        for tabID in ["unmarked", "deliverable", "handoff"] {
            try state.registerPrivateTab(
                tabID: tabID,
                workspaceID: "workspace-a",
                ownerSessionID: "session-a"
            )
        }
        try state.markPrivateTab(
            tabID: "deliverable",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a",
            mark: .deliverable
        )
        try state.markPrivateTab(
            tabID: "handoff",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a",
            mark: .handoff
        )
        try state.claimUserTab(
            tabID: "user-tab",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )

        let plan = state.cleanupSession(ownerSessionID: "session-a", now: now)

        XCTAssertEqual(plan.privateTabIDsToClose, ["unmarked"])
        XCTAssertEqual(plan.privateTabIDsToAdopt, ["deliverable"])
        XCTAssertEqual(plan.privateTabIDsRetainedForHandoff, ["handoff"])
        XCTAssertEqual(plan.userTabIDsToRelease, ["user-tab"])
        XCTAssertNil(state.privateTabsByID["unmarked"])
        XCTAssertNil(state.privateTabsByID["deliverable"])
        XCTAssertEqual(state.privateTabsByID["handoff"]?.ownerSessionID, nil)
        XCTAssertEqual(
            state.privateTabsByID["handoff"]?.handoffExpiresAt,
            now.addingTimeInterval(1_800)
        )
        XCTAssertTrue(state.userClaimsByTabID.isEmpty)
    }

    func testHandoffCanBeReclaimedBeforeTTLAndExpiresAfterTTL() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        var state = TideyBrowserAutomationState(handoffTTL: 60)
        try state.registerPrivateTab(
            tabID: "handoff",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )
        try state.markPrivateTab(
            tabID: "handoff",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a",
            mark: .handoff
        )
        _ = state.cleanupSession(ownerSessionID: "session-a", now: now)

        XCTAssertThrowsError(
            try state.reclaimHandoff(
                tabID: "handoff",
                workspaceID: "workspace-b",
                ownerSessionID: "session-b",
                now: now.addingTimeInterval(30)
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .workspaceMismatch)
        }
        try state.reclaimHandoff(
            tabID: "handoff",
            workspaceID: "workspace-a",
            ownerSessionID: "session-b",
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(state.privateTabsByID["handoff"]?.ownerSessionID, "session-b")
        XCTAssertNil(state.privateTabsByID["handoff"]?.handoffExpiresAt)

        _ = state.cleanupSession(ownerSessionID: "session-b", now: now.addingTimeInterval(40))
        XCTAssertEqual(
            state.expireHandoffs(now: now.addingTimeInterval(101)),
            ["handoff"]
        )
        XCTAssertNil(state.privateTabsByID["handoff"])
        XCTAssertThrowsError(
            try state.reclaimHandoff(
                tabID: "handoff",
                workspaceID: "workspace-a",
                ownerSessionID: "session-c",
                now: now.addingTimeInterval(101)
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .targetGone)
        }
    }

    func testPresentationPreservesIdentityAndRequiresOwner() throws {
        var state = TideyBrowserAutomationState()
        try state.registerPrivateTab(
            tabID: "private-1",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )

        XCTAssertThrowsError(
            try state.takePrivateTabForPresentation(
                tabID: "private-1",
                workspaceID: "workspace-a",
                ownerSessionID: "session-b"
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .ownershipConflict)
        }
        let presented = try state.takePrivateTabForPresentation(
            tabID: "private-1",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )
        XCTAssertEqual(presented.tabID, "private-1")
        XCTAssertNil(state.privateTabsByID["private-1"])
    }

    func testUserTabClaimsAreExclusiveAndReleasedWithoutClosing() throws {
        var state = TideyBrowserAutomationState()
        try state.claimUserTab(
            tabID: "user-tab",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )
        try state.claimUserTab(
            tabID: "user-tab",
            workspaceID: "workspace-a",
            ownerSessionID: "session-a"
        )

        XCTAssertThrowsError(
            try state.claimUserTab(
                tabID: "user-tab",
                workspaceID: "workspace-a",
                ownerSessionID: "session-b"
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .ownershipConflict)
        }
        XCTAssertThrowsError(
            try state.claimUserTab(
                tabID: "user-tab",
                workspaceID: "workspace-b",
                ownerSessionID: "session-a"
            )
        ) { error in
            XCTAssertEqual(error as? TideyBrowserAutomationStateError, .workspaceMismatch)
        }

        let plan = state.cleanupSession(ownerSessionID: "session-a", now: Date())
        XCTAssertEqual(plan.userTabIDsToRelease, ["user-tab"])
        XCTAssertTrue(state.userClaimsByTabID.isEmpty)
    }
}
