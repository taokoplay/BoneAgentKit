import Foundation
import XCTest
@testable import BoneAgentKit

final class AgentExecutionSessionTests: XCTestCase {
    func testNewSessionStartsActiveWithoutLease() throws {
        let session = try fixture()
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.revision, 1)
        XCTAssertEqual(session.leaseGeneration, 0)
        XCTAssertNil(session.attention)
        XCTAssertNil(session.snapshotReference)
    }

    func testAttentionStatesRoundTripThroughCodable() throws {
        let cases: [BoneAgentExecutionAttention] = [
            try .init(userInput: "input-1"),
            try .init(authorization: .init("ticket-1")),
            try .init(review: "review-1"),
            try .init(externalEvent: "event-1"),
            .recovery(reason: .toolOutcomeUnknown)
        ]
        for attention in cases {
            let data = try JSONEncoder().encode(attention)
            XCTAssertEqual(try JSONDecoder().decode(BoneAgentExecutionAttention.self, from: data), attention)
        }
    }

    func testWaitingStateRequiresMatchingAttention() throws {
        let session = try fixture()
        XCTAssertThrowsError(try session.transitioned(to: .waitingForAuthorization)) {
            XCTAssertEqual($0 as? BoneAgentExecutionSessionError, .attentionMismatch)
        }
        let waiting = try session.transitioned(
            to: .waitingForAuthorization,
            attention: .authorization(ticketID: try .init("ticket-1"))
        )
        XCTAssertEqual(waiting.state, .waitingForAuthorization)
        XCTAssertEqual(waiting.revision, 2)
        XCTAssertThrowsError(try JSONDecoder().decode(
            BoneAgentExecutionSession.self,
            from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "sessionID": "session-1",
                "runID": "run-1",
                "workflowIdentity": "workflow",
                "workflowRevision": 1,
                "configurationDigest": String(repeating: "a", count: 64),
                "toolCatalogDigest": String(repeating: "b", count: 64),
                "state": "waitingForAuthorization",
                "revision": 2,
                "leaseGeneration": 0,
                "attention": ["kind": "userInput", "requestID": "input-1"]
            ])
        ))
    }

    func testTerminalStateCannotResume() throws {
        let session = try fixture()
        let completed = try session.transitioned(to: .cancelled)
        XCTAssertThrowsError(try completed.transitioned(to: .active)) {
            XCTAssertEqual($0 as? BoneAgentExecutionSessionError, .invalidTransition)
        }
        XCTAssertThrowsError(try completed.acquiringLease()) {
            XCTAssertEqual($0 as? BoneAgentExecutionSessionError, .terminalState)
        }
    }

    func testLeaseAcquisitionAdvancesRevisionAndGeneration() throws {
        let session = try fixture()
        let leased = try session.acquiringLease()
        XCTAssertEqual(leased.revision, 2)
        XCTAssertEqual(leased.leaseGeneration, 1)
        XCTAssertEqual(leased.state, .active)
        XCTAssertEqual(try JSONDecoder().decode(BoneAgentExecutionSession.self, from: JSONEncoder().encode(leased)), leased)
    }

    func testStoreRejectsStaleRevisionAndLease() async throws {
        let store = BoneInMemoryAgentExecutionSessionStore()
        let session = try fixture()
        _ = try await store.open(session)
        let leased = try await store.acquireLease(sessionID: session.sessionID, expectedRevision: 1)
        let paused = try leased.transitioned(to: .paused)
        _ = try await store.commit(paused, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
        do {
            _ = try await store.commit(paused, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
            XCTFail("旧 revision 不应再次提交")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionError, .revisionConflict)
        }
        let running = try paused.transitioned(to: .running)
        do {
            _ = try await store.commit(running, expectedRevision: paused.revision, leaseGeneration: 0)
            XCTFail("旧 lease 不应提交新状态")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionError, .leaseConflict)
        }
    }

    func testStoreOpenIsIdempotentButRejectsIdentityReuse() async throws {
        let store = BoneInMemoryAgentExecutionSessionStore()
        let session = try fixture()
        let first = try await store.open(session)
        XCTAssertEqual(first, session)
        let second = try await store.open(session)
        XCTAssertEqual(second, session)
        let changed = try BoneAgentExecutionSession(
            sessionID: session.sessionID,
            runID: try .init("different-run"),
            conversationID: session.conversationID,
            modelID: session.modelID,
            bindingID: session.bindingID,
            workflowIdentity: session.workflowIdentity,
            workflowRevision: session.workflowRevision,
            configurationDigest: session.configurationDigest,
            toolCatalogDigest: session.toolCatalogDigest
        )
        do {
            _ = try await store.open(changed)
            XCTFail("相同 Session ID 不应接受不同身份")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionError, .identityReused)
        }
    }

    func testConfigurationBindingAndSnapshotIdentityAreValidated() throws {
        let session = try fixture()
        let leased = try session.acquiringLease()
        let reference = try BoneWorkflowAgentExecutionSnapshotReference(
            referenceID: "snapshot-1",
            schemaVersion: 1,
            runID: leased.runID,
            stepID: try .init("step-1"),
            attemptID: try .init("attempt-1"),
            conversationRevision: 1,
            contextRevision: 0,
            effectLedgerRevision: 0,
            checkpointRevision: 1,
            leaseGeneration: leased.leaseGeneration
        )
        let bound = try leased.binding(snapshot: reference)
        XCTAssertEqual(bound.snapshotReference, reference)
        XCTAssertEqual(bound.revision, leased.revision + 1)
        let wrongRunReference = try BoneWorkflowAgentExecutionSnapshotReference(
            referenceID: "snapshot-2",
            schemaVersion: 1,
            runID: try .init("other-run"),
            stepID: try .init("step-1"),
            attemptID: try .init("attempt-1"),
            conversationRevision: 1,
            contextRevision: 0,
            effectLedgerRevision: 0,
            checkpointRevision: 1,
            leaseGeneration: leased.leaseGeneration
        )
        XCTAssertThrowsError(try leased.binding(snapshot: wrongRunReference)) {
            XCTAssertEqual($0 as? BoneAgentExecutionSessionError, .leaseConflict)
        }
    }

    func testSessionStepAndSnapshotBindingValidatorRequiresOneRecoveryBoundary() throws {
        let session = try fixture().acquiringLease()
        let reference = try BoneWorkflowAgentExecutionSnapshotReference(
            referenceID: "snapshot-1",
            schemaVersion: 1,
            runID: session.runID,
            stepID: .init("step-1"),
            attemptID: .init("attempt-1"),
            conversationRevision: 1,
            contextRevision: 0,
            effectLedgerRevision: 0,
            checkpointRevision: 1,
            leaseGeneration: session.leaseGeneration
        )
        let boundSession = try session.binding(snapshot: reference)
        let checkpoint = BoneWorkflowAgentStepCheckpoint(
            runID: boundSession.runID,
            stepID: reference.stepID,
            attemptID: reference.attemptID,
            state: .running,
            persistenceRevision: reference.checkpointRevision,
            leaseGeneration: reference.leaseGeneration,
            executionSnapshotReference: reference
        )
        let snapshot = try BoneWorkflowAgentExecutionSnapshot(
            reference: reference,
            privateConversationState: Data("private-state".utf8)
        )

        XCTAssertNoThrow(try BoneAgentExecutionSessionBindingValidator.validate(
            session: boundSession,
            checkpoint: checkpoint,
            snapshot: snapshot
        ))

        let mismatchedCheckpoint = BoneWorkflowAgentStepCheckpoint(
            runID: boundSession.runID,
            stepID: reference.stepID,
            attemptID: reference.attemptID,
            state: .running,
            persistenceRevision: reference.checkpointRevision + 1,
            leaseGeneration: reference.leaseGeneration,
            executionSnapshotReference: reference
        )
        XCTAssertThrowsError(try BoneAgentExecutionSessionBindingValidator.validate(
            session: boundSession,
            checkpoint: mismatchedCheckpoint,
            snapshot: snapshot
        )) {
            XCTAssertEqual($0 as? BoneAgentExecutionSessionBindingError, .revisionMismatch)
        }
    }

    func testInvalidDigestAndFutureSchemaAreRejected() throws {
        XCTAssertThrowsError(try BoneAgentExecutionSession(
            sessionID: "session-1",
            runID: try .init("run-1"),
            conversationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            modelID: "model-1",
            bindingID: "binding-1",
            workflowIdentity: "workflow",
            workflowRevision: 1,
            configurationDigest: "bad",
            toolCatalogDigest: String(repeating: "b", count: 64)
        ))
        let session = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(BoneAgentExecutionSession.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    private func fixture() throws -> BoneAgentExecutionSession {
        try .init(
            sessionID: "session-1",
            runID: .init("run-1"),
            conversationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            modelID: "model-1",
            bindingID: "binding-1",
            workflowIdentity: "workflow",
            workflowRevision: 1,
            configurationDigest: String(repeating: "a", count: 64),
            toolCatalogDigest: String(repeating: "b", count: 64),
            promptProfileDigest: String(repeating: "c", count: 64)
        )
    }
}
