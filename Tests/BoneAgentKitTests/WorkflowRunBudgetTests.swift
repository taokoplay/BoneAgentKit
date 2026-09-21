import Foundation
import XCTest
import BoneAgentKit

final class WorkflowRunBudgetTests: XCTestCase {
    func testFinalReserveAndDeniedAttemptsNeverConsumeFinalStock() throws {
        var state = try fixture()
        for _ in 0..<2 { state = try state.reserving(phase: .ordinary, now: now()).snapshot }
        let denied = try state.reserving(phase: .ordinary, now: now())
        XCTAssertEqual(denied.decision, .rejected(.requestLimit))
        XCTAssertEqual(denied.snapshot.usedRequests, 2)
        XCTAssertEqual(denied.snapshot.attemptedRequests, 3)
        let final = try denied.snapshot.reserving(phase: .final, now: now())
        XCTAssertEqual(final.decision, .granted)
        XCTAssertEqual(final.snapshot.usedRequests, 3)
        XCTAssertEqual(try final.snapshot.reserving(phase: .final, now: now()).decision, .rejected(.requestLimit))
    }

    func testGrantedRequestStaysSpentWhenDownstreamFails() throws {
        let spent = try fixture().reserving(phase: .ordinary, now: now()).snapshot
        // A downstream exception has no refund operation to call.
        let restored = try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: JSONEncoder().encode(spent))
        XCTAssertEqual(restored, spent)
        XCTAssertEqual(restored.usedRequests, 1)
    }

    func testBothDeadlinesAreExclusive() throws {
        for clock in [now(wall: 1100, uptime: 110), now(wall: 1099.5, uptime: 110)] {
            XCTAssertEqual(try fixture().reserving(phase: .final, now: clock).decision, .rejected(.deadline))
        }
        XCTAssertEqual(try fixture().reserving(phase: .final, now: now(wall: 1099.5, uptime: 109.5)).decision, .granted)
    }

    func testRollbackBootChangeAndEpochDriftLatchClosed() throws {
        let state = try fixture().reserving(phase: .ordinary, now: now(wall: 1010, uptime: 20)).snapshot
        for bad in [now(wall: 1009, uptime: 21), now(wall: 1011, uptime: 19), now(wall: 1011, uptime: 21, boot: "new"), now(wall: 1050, uptime: 21), now(wall: .nan), now(uptime: .infinity)] {
            let denied = try state.reserving(phase: .final, now: bad)
            XCTAssertEqual(denied.decision, .rejected(.clockInvalid))
            XCTAssertEqual(denied.snapshot.usedRequests, state.usedRequests)
            XCTAssertEqual(try denied.snapshot.reserving(phase: .final, now: now(wall: 1012, uptime: 22)).decision, .rejected(.clockInvalid))
        }
    }

    func testOpenDoesNotResetStartOrSpentRequests() async throws {
        let store = BoneInMemoryWorkflowRunBudgetStore()
        let state = try fixture()
        let initial = try await store.open(runID: state.runID, policy: state.policy, now: now())
        let spent = try await store.reserve(runID: state.runID, expectedRevision: initial.revision, phase: .ordinary, now: now())
        let reopened = try await store.open(runID: state.runID, policy: state.policy, now: now(wall: 9000, uptime: 1, boot: "new"))
        XCTAssertEqual(reopened, spent.snapshot)
    }

    func testPolicyAndVersionDriftAreRejectedWithoutMutation() async throws {
        let store = BoneInMemoryWorkflowRunBudgetStore()
        let original = try fixture()
        _ = try await store.open(runID: original.runID, policy: original.policy, now: now())
        for policy in [
            try BoneWorkflowRunBudget.Policy(versionTag: "v1", requestLimit: 4, reservedFinalRequests: 1, durationSeconds: 100),
            try .init(versionTag: "v2", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100)
        ] {
            do { _ = try await store.open(runID: original.runID, policy: policy, now: now()); XCTFail("Drift must fail") }
            catch { XCTAssertEqual(error as? BoneWorkflowRunBudgetError, .policyMismatch) }
        }
        let loaded = try await store.load(runID: original.runID)
        XCTAssertEqual(loaded, original)
    }

    func testConcurrentReservationsHaveOneCASWinner() async throws {
        let store = BoneInMemoryWorkflowRunBudgetStore()
        let state = try fixture()
        _ = try await store.open(runID: state.runID, policy: state.policy, now: now())
        let clock = now()
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask {
                do { _ = try await store.reserve(runID: state.runID, expectedRevision: 1, phase: .ordinary, now: clock); return true }
                catch { XCTAssertEqual(error as? BoneWorkflowRunBudgetError, .revisionConflict); return false }
            } }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let loaded = try await store.load(runID: state.runID)
        XCTAssertEqual(loaded.attemptedRequests, 1)
        XCTAssertEqual(loaded.usedRequests, 1)
    }

    func testCorruptEncodedCountersAreRejected() throws {
        let state = try fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["usedRequests"] = 99
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: data))
    }

    func testInvalidPoliciesAndUnrepresentableDeadlineAreRejected() throws {
        for make in [
            { try BoneWorkflowRunBudget.Policy(versionTag: "", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100) },
            { try .init(versionTag: "v1", requestLimit: 0, reservedFinalRequests: 0, durationSeconds: 100) },
            { try .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 4, durationSeconds: 100) },
            { try .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: .infinity) },
            { try .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100, bootEpochToleranceSeconds: -1) }
        ] {
            XCTAssertThrowsError(try make())
        }
        let original = try fixture()
        XCTAssertThrowsError(try BoneWorkflowRunBudget(runID: original.runID, policy: original.policy,
            started: now(wall: .greatestFiniteMagnitude, uptime: 0)))
    }

    func testAllRequestsCanBeReservedForFinalPhase() throws {
        let policy = try BoneWorkflowRunBudget.Policy(versionTag: "v1", requestLimit: 2, reservedFinalRequests: 2, durationSeconds: 100)
        let state = try BoneWorkflowRunBudget(runID: .init("all-final"), policy: policy, started: now())
        let denied = try state.reserving(phase: .ordinary, now: now())
        XCTAssertEqual(denied.decision, .rejected(.requestLimit))
        XCTAssertEqual(denied.snapshot.usedRequests, 0)
        XCTAssertEqual(try denied.snapshot.reserving(phase: .final, now: now()).decision, .granted)
    }

    func testDriftToleranceBoundaryIsExplicit() throws {
        XCTAssertEqual(try fixture().reserving(phase: .final, now: now(wall: 1011, uptime: 20)).decision, .granted)
        XCTAssertEqual(try fixture().reserving(phase: .final, now: now(wall: 1011.1, uptime: 20)).decision, .rejected(.clockInvalid))
    }

    func testInvalidEncodedPolicyAndFutureSchemaAreRejected() throws {
        let state = try fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: JSONSerialization.data(withJSONObject: json)))
        json["schemaVersion"] = 1
        var policy = try XCTUnwrap(json["policy"] as? [String: Any])
        policy["reservedFinalRequests"] = 99
        json["policy"] = policy
        XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testLoweringSpentCounterToUnreachableValueIsRejected() throws {
        var state = try fixture()
        for _ in 0..<2 { state = try state.reserving(phase: .ordinary, now: now()).snapshot }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["usedRequests"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: JSONSerialization.data(withJSONObject: json)))
        let denied = try state.reserving(phase: .ordinary, now: now()).snapshot
        XCTAssertEqual(try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: JSONEncoder().encode(denied)), denied)
    }

    func testCountersNeverWrap() throws {
        let state = try fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["usedRequests"] = 2
        json["revision"] = UInt64.max
        json["attemptedRequests"] = UInt64.max - 1
        let exhausted = try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try exhausted.reserving(phase: .ordinary, now: now())) {
            XCTAssertEqual($0 as? BoneWorkflowRunBudgetError, .counterOverflow)
        }
    }

    func testCancelledReservationDoesNotCreateAnAttempt() async throws {
        let store = BoneInMemoryWorkflowRunBudgetStore()
        let original = try fixture()
        _ = try await store.open(runID: original.runID, policy: original.policy, now: now())
        let clock = now()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.reserve(runID: original.runID, expectedRevision: 1, phase: .ordinary, now: clock)
        }
        do { _ = try await task.value; XCTFail("Cancelled pre-reserve must fail") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let loaded = try await store.load(runID: original.runID)
        XCTAssertEqual(loaded, original)
    }

    private func now(wall: Double = 1000, uptime: Double = 10, boot: String = "boot") -> BoneWorkflowRunBudget.Clock {
        .init(wallTime: wall, uptime: uptime, bootID: boot)
    }
    private func fixture() throws -> BoneWorkflowRunBudget {
        try .init(runID: .init("run"), policy: .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100), started: now())
    }
}
