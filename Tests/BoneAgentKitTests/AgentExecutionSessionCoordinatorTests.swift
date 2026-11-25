import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class AgentExecutionSessionCoordinatorTests: XCTestCase {
    func testSuccessfulTurnCommitsSnapshotAndCanResumeWithNewAgentInstance() async throws {
        let firstEngine = BoneScriptedInferenceEngine(script: [])
        let secondEngine = BoneScriptedInferenceEngine(script: [.init(text: "first answer")])
        let thirdEngine = BoneScriptedInferenceEngine(script: [.init(text: "second answer")])
        let sessionStore = TestSessionStore()
        let snapshotStore = sessionStore
        let binding = try fixtureBinding()
        let firstAgent = try makeAgent(firstEngine)
        let initial = try await firstAgent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: initial, binding: binding)
        let firstCoordinator = BoneAgentExecutionSessionCoordinator(
            agent: firstAgent,
            sessionStore: sessionStore,
            snapshotStore: snapshotStore,
            binding: binding
        )
        let started = try await firstCoordinator.start(
            session: session,
            conversation: initial,
            stepID: .init("step-1"),
            attemptID: .init("attempt-1")
        )
        XCTAssertEqual(started.state, .active)
        XCTAssertEqual(started.leaseGeneration, 1)
        XCTAssertNotNil(started.snapshotReference)

        let secondCoordinator = BoneAgentExecutionSessionCoordinator(
            agent: try makeAgent(secondEngine),
            sessionStore: sessionStore,
            snapshotStore: snapshotStore,
            binding: binding
        )
        let firstResult = try await secondCoordinator.run(sessionID: session.sessionID, userMessage: "first question")
        XCTAssertEqual(firstResult.output, .text("first answer"))
        let afterFirst = try await secondCoordinator.load(sessionID: session.sessionID)
        XCTAssertEqual(afterFirst.state, .active)
        XCTAssertEqual(afterFirst.leaseGeneration, 2)
        XCTAssertEqual(afterFirst.snapshotReference?.conversationRevision, 1)

        let thirdCoordinator = BoneAgentExecutionSessionCoordinator(
            agent: try makeAgent(thirdEngine),
            sessionStore: sessionStore,
            snapshotStore: snapshotStore,
            binding: binding
        )
        let secondResult = try await thirdCoordinator.run(sessionID: session.sessionID, userMessage: "second question")
        XCTAssertEqual(secondResult.output, .text("second answer"))
        let final = try await thirdCoordinator.load(sessionID: session.sessionID)
        XCTAssertEqual(final.state, .active)
        XCTAssertEqual(final.leaseGeneration, 3)
        XCTAssertEqual(final.snapshotReference?.conversationRevision, 2)
        let secondRequests = await secondEngine.receivedRequests()
        let thirdRequests = await thirdEngine.receivedRequests()
        XCTAssertEqual(secondRequests.count, 1)
        XCTAssertEqual(thirdRequests.count, 1)
    }

    func testMissingSnapshotEntersRecoveryWithoutCallingModel() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "must not run")])
        let store = TestSessionStore()
        let snapshotStore = store
        let binding = try fixtureBinding()
        let agent = try makeAgent(engine)
        let conversation = try await agent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: conversation, binding: binding)
        _ = try await store.open(session)
        let coordinator = BoneAgentExecutionSessionCoordinator(
            agent: agent,
            sessionStore: store,
            snapshotStore: snapshotStore,
            binding: binding
        )

        do {
            _ = try await coordinator.run(sessionID: session.sessionID, userMessage: "question")
            XCTFail("missing snapshot must stop before model call")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionCoordinatorError, .missingSnapshot)
        }
        let recovered = try await store.load(sessionID: session.sessionID)
        XCTAssertEqual(recovered.state, .recoveryRequired)
        XCTAssertEqual(recovered.attention, .recovery(reason: .missingSnapshot))
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testUnknownJointCommitStopsBeforeASecondModelCall() async throws {
        let firstEngine = BoneScriptedInferenceEngine(script: [.init(text: "answer")])
        let secondEngine = BoneScriptedInferenceEngine(script: [.init(text: "must not replay")])
        let store = TestSessionStore()
        let binding = try fixtureBinding()
        let firstAgent = try makeAgent(firstEngine)
        let conversation = try await firstAgent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: conversation, binding: binding)
        let firstCoordinator = BoneAgentExecutionSessionCoordinator(
            agent: firstAgent,
            sessionStore: store,
            snapshotStore: store,
            binding: binding
        )
        _ = try await firstCoordinator.start(
            session: session,
            conversation: conversation,
            stepID: .init("step-1"),
            attemptID: .init("attempt-1")
        )
        await store.injectUnknownSnapshotCommit()

        let secondCoordinator = BoneAgentExecutionSessionCoordinator(
            agent: try makeAgent(secondEngine),
            sessionStore: store,
            snapshotStore: store,
            binding: binding
        )
        do {
            _ = try await secondCoordinator.run(sessionID: session.sessionID, userMessage: "question")
            XCTFail("unknown joint commit must be surfaced")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionCoordinatorError, .persistenceOutcomeUnknown)
        }
        let requestsAfterFailure = await secondEngine.receivedRequests()
        XCTAssertEqual(requestsAfterFailure.count, 1)
        let persistedAfterFailure = try await store.load(sessionID: session.sessionID)
        XCTAssertEqual(persistedAfterFailure.state, .running)

        do {
            _ = try await secondCoordinator.run(sessionID: session.sessionID, userMessage: "retry")
            XCTFail("a session with an uncertain commit must not continue")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionCoordinatorError, .sessionNotRunnable)
        }
        let requestsAfterRetry = await secondEngine.receivedRequests()
        XCTAssertEqual(requestsAfterRetry.count, 1)
    }

    func testKnownEffectReceiptReturnsCommitActionWithoutReexecutingTool() async throws {
        let engine = BoneScriptedInferenceEngine(script: [])
        let sessionStore = TestSessionStore()
        let binding = try fixtureBinding()
        let agent = try makeAgent(engine)
        let conversation = try await agent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: conversation, binding: binding)
        _ = try await sessionStore.open(session)
        let coordinator = BoneAgentExecutionSessionCoordinator(
            agent: agent,
            sessionStore: sessionStore,
            snapshotStore: sessionStore,
            binding: binding
        )
        let started = try await coordinator.start(
            session: session,
            conversation: conversation,
            stepID: .init("step-1"),
            attemptID: .init("attempt-1")
        )
        let effectID = try BoneEffectID("effect-1")
        let effectStore = CoordinatorEffectStore(snapshot: try makeEffectSnapshot(
            effectID: effectID,
            leaseGeneration: started.leaseGeneration,
            receipt: try BoneEffectReceipt(
                effectID: effectID,
                outcome: .succeeded,
                resultDigest: String(repeating: "e", count: 64),
                leaseGeneration: started.leaseGeneration
            )
        ))
        let pipeline = BoneWorkflowToolExecutionPipeline(effectStore: effectStore)

        let decision = try await coordinator.recoverEffect(
            sessionID: session.sessionID,
            effectID: effectID,
            pipeline: pipeline
        )

        XCTAssertEqual(decision.action, .completed)
        XCTAssertEqual(decision.leaseGeneration, started.leaseGeneration)
        let facts = await effectStore.facts()
        XCTAssertEqual(facts.executionCount, 0)
        XCTAssertEqual(facts.commitRecoveredReceiptCount, 1)
        let current = try await sessionStore.load(sessionID: session.sessionID)
        XCTAssertEqual(current.state, .active)
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testUnknownEffectOutcomeEntersRecoveryWithoutReexecutingTool() async throws {
        let engine = BoneScriptedInferenceEngine(script: [])
        let sessionStore = TestSessionStore()
        let binding = try fixtureBinding()
        let agent = try makeAgent(engine)
        let conversation = try await agent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: conversation, binding: binding)
        _ = try await sessionStore.open(session)
        let coordinator = BoneAgentExecutionSessionCoordinator(
            agent: agent,
            sessionStore: sessionStore,
            snapshotStore: sessionStore,
            binding: binding
        )
        let started = try await coordinator.start(
            session: session,
            conversation: conversation,
            stepID: .init("step-1"),
            attemptID: .init("attempt-1")
        )
        let effectID = try BoneEffectID("effect-1")
        let effectStore = CoordinatorEffectStore(snapshot: try makeEffectSnapshot(
            effectID: effectID,
            leaseGeneration: started.leaseGeneration,
            receipt: nil
        ))
        let pipeline = BoneWorkflowToolExecutionPipeline(effectStore: effectStore)

        let decision = try await coordinator.recoverEffect(
            sessionID: session.sessionID,
            effectID: effectID,
            pipeline: pipeline
        )
        XCTAssertEqual(decision.action, .recoveryRequired(.outcomeUnknown))

        let recovered = try await sessionStore.load(sessionID: session.sessionID)
        XCTAssertEqual(recovered.state, .recoveryRequired)
        XCTAssertEqual(recovered.attention, .recovery(reason: .effectReceiptUnknown))
        let facts = await effectStore.facts()
        XCTAssertEqual(facts.executionCount, 0)
        XCTAssertEqual(facts.persistOutcomeUnknownCount, 1)
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testEffectFromAnotherRunCannotBeRecoveredThroughThisSession() async throws {
        let engine = BoneScriptedInferenceEngine(script: [])
        let sessionStore = TestSessionStore()
        let binding = try fixtureBinding()
        let agent = try makeAgent(engine)
        let conversation = try await agent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: conversation, binding: binding)
        _ = try await sessionStore.open(session)
        let coordinator = BoneAgentExecutionSessionCoordinator(
            agent: agent,
            sessionStore: sessionStore,
            snapshotStore: sessionStore,
            binding: binding
        )
        let started = try await coordinator.start(
            session: session,
            conversation: conversation,
            stepID: .init("step-1"),
            attemptID: .init("attempt-1")
        )
        let effectID = try BoneEffectID("foreign-effect")
        let effectStore = CoordinatorEffectStore(snapshot: try makeEffectSnapshot(
            effectID: effectID,
            runID: .init("other-run"),
            leaseGeneration: started.leaseGeneration,
            receipt: try BoneEffectReceipt(
                effectID: effectID,
                outcome: .succeeded,
                resultDigest: String(repeating: "e", count: 64),
                leaseGeneration: started.leaseGeneration
            )
        ))
        let pipeline = BoneWorkflowToolExecutionPipeline(effectStore: effectStore)

        do {
            _ = try await coordinator.recoverEffect(
                sessionID: session.sessionID,
                effectID: effectID,
                pipeline: pipeline
            )
            XCTFail("an Effect from another Run must be rejected")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionCoordinatorError, .identityMismatch)
        }

        let facts = await effectStore.facts()
        XCTAssertEqual(facts.commitRecoveredReceiptCount, 0)
    }

    private func makeEffectSnapshot(
        effectID: BoneEffectID,
        runID: BoneRunID? = nil,
        sessionID: String? = "session-1",
        leaseGeneration: UInt64,
        receipt: BoneEffectReceipt?
    ) throws -> BoneEffectRecoverySnapshot {
        let resolvedRunID = try runID ?? BoneRunID("run-1")
        return try BoneEffectRecoverySnapshot(
            intent: BoneEffectIntent(
                id: effectID,
                sessionID: sessionID,
                runID: resolvedRunID,
                stepID: .init("step-1"),
                attemptID: .init("attempt-1"),
                toolCallID: .init("tool-call-1"),
                recoveryStrategy: .naturallyIdempotent,
                idempotencyKey: nil,
                argumentsDigest: String(repeating: "a", count: 64),
                phase: .executionStarted,
                leaseGeneration: leaseGeneration
            ),
            receipt: receipt,
            stepCommitted: false,
            cancellationPersisted: false
        )
    }

    func testConfigurationDriftEntersRecoveryWithoutCallingModel() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "must not run")])
        let store = TestSessionStore()
        let snapshotStore = store
        let originalBinding = try fixtureBinding(configurationDigest: String(repeating: "a", count: 64))
        let changedBinding = try fixtureBinding(configurationDigest: String(repeating: "b", count: 64))
        let agent = try makeAgent(engine)
        let conversation = try await agent.makeConversation(modelID: "model-1", bindingID: "binding-1")
        let session = try await makeSession(conversation: conversation, binding: originalBinding)
        _ = try await store.open(session)
        let coordinator = BoneAgentExecutionSessionCoordinator(
            agent: agent,
            sessionStore: store,
            snapshotStore: snapshotStore,
            binding: changedBinding
        )

        do {
            _ = try await coordinator.run(sessionID: session.sessionID, userMessage: "question")
            XCTFail("configuration drift must stop before model call")
        } catch {
            XCTAssertEqual(error as? BoneAgentExecutionSessionCoordinatorError, .configurationDrift)
        }
        let recovered = try await store.load(sessionID: session.sessionID)
        XCTAssertEqual(recovered.state, .recoveryRequired)
        XCTAssertEqual(recovered.attention, .recovery(reason: .configurationDrift))
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    private func makeAgent(_ engine: any BoneInferenceEngine) throws -> BoneAgent {
        BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 2, inferenceCostEstimator: { _ in 0 })
        )
    }

    private func makeSession(
        conversation: BoneAgentConversation,
        binding: BoneAgentExecutionSessionBinding
    ) async throws -> BoneAgentExecutionSession {
        try .init(
            sessionID: "session-1",
            runID: .init("run-1"),
            conversationID: await conversation.id,
            modelID: await conversation.modelID,
            bindingID: await conversation.bindingID,
            workflowIdentity: binding.workflowIdentity,
            workflowRevision: binding.workflowRevision,
            configurationDigest: binding.configurationDigest,
            toolCatalogDigest: binding.toolCatalogDigest,
            promptProfileDigest: binding.promptProfileDigest
        )
    }

    private func fixtureBinding(configurationDigest: String = String(repeating: "a", count: 64)) throws -> BoneAgentExecutionSessionBinding {
        try .init(
            workflowIdentity: "workflow-1",
            workflowRevision: 1,
            configurationDigest: configurationDigest,
            toolCatalogDigest: String(repeating: "c", count: 64),
            promptProfileDigest: String(repeating: "d", count: 64)
        )
    }
}

private actor TestSessionStore: BoneAgentExecutionSessionStore, BoneWorkflowAgentExecutionSnapshotStore {
    private var sessions: [String: BoneAgentExecutionSession] = [:]
    private var snapshots: [String: BoneWorkflowAgentExecutionSnapshot] = [:]
    private var shouldFailNextSnapshotCommit: Bool

    init(failNextSnapshotCommit: Bool = false) {
        self.shouldFailNextSnapshotCommit = failNextSnapshotCommit
    }

    func open(_ session: BoneAgentExecutionSession) throws -> BoneAgentExecutionSession {
        if let current = sessions[session.sessionID] {
            guard current == session else { throw BoneAgentExecutionSessionError.identityReused }
            return current
        }
        sessions[session.sessionID] = session
        return session
    }

    func load(sessionID: String) throws -> BoneAgentExecutionSession {
        guard let session = sessions[sessionID] else { throw BoneAgentExecutionSessionError.missingSession }
        return session
    }

    func commit(
        _ session: BoneAgentExecutionSession,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        try commitChecked(session, snapshot: nil, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
    }

    func commit(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        try commitChecked(session, snapshot: snapshot, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
    }

    func injectUnknownSnapshotCommit() {
        shouldFailNextSnapshotCommit = true
    }

    func acquireLease(sessionID: String, expectedRevision: UInt64) throws -> BoneAgentExecutionSession {
        guard let current = sessions[sessionID], current.revision == expectedRevision else {
            throw BoneAgentExecutionSessionError.revisionConflict
        }
        let next = try current.acquiringLease()
        sessions[sessionID] = next
        return next
    }

    func load(reference: BoneWorkflowAgentExecutionSnapshotReference) throws -> BoneWorkflowAgentExecutionSnapshot {
        guard let snapshot = snapshots[reference.referenceID] else {
            throw BoneWorkflowAgentExecutionSnapshotError.missingSnapshot
        }
        return snapshot
    }

    func commit(
        _ snapshot: BoneWorkflowAgentExecutionSnapshot,
        expectedReference: BoneWorkflowAgentExecutionSnapshotReference?,
        leaseGeneration: UInt64
    ) throws -> BoneWorkflowAgentExecutionSnapshot {
        guard snapshot.reference.leaseGeneration == leaseGeneration,
              expectedReference == nil || expectedReference == snapshot.reference else {
            throw BoneWorkflowAgentExecutionSnapshotError.revisionConflict
        }
        snapshots[snapshot.reference.referenceID] = snapshot
        return snapshot
    }

    private func commitChecked(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        guard let current = sessions[session.sessionID],
              current.revision == expectedRevision,
              current.leaseGeneration == leaseGeneration,
              session.revision == expectedRevision + 1,
              session.leaseGeneration == leaseGeneration else {
            throw BoneAgentExecutionSessionError.revisionConflict
        }
        if let snapshot {
            guard snapshot.reference == session.snapshotReference else {
                throw BoneAgentExecutionSessionError.identityMismatch
            }
            if shouldFailNextSnapshotCommit {
                shouldFailNextSnapshotCommit = false
                throw TestUnknownPersistenceError.commitResultUnknown
            }
            snapshots[snapshot.reference.referenceID] = snapshot
        }
        sessions[session.sessionID] = session
        return session
    }
}


private actor CoordinatorEffectStore: BoneWorkflowEffectStore {
    struct Facts: Sendable {
        let executionCount: Int
        let commitRecoveredReceiptCount: Int
        let persistOutcomeUnknownCount: Int
    }

    private var storedSnapshot: BoneEffectRecoverySnapshot?
    private var executionCount = 0
    private var commitRecoveredReceiptCount = 0
    private var persistOutcomeUnknownCount = 0

    init(snapshot: BoneEffectRecoverySnapshot) {
        storedSnapshot = snapshot
    }

    func consumeAuthorizationAndPersistIntent(
        _ validation: BoneAuthorizationValidation,
        intent: BoneEffectIntent
    ) async throws {}

    func persistCancellation(effectID: BoneEffectID, leaseGeneration: UInt64) async throws {}

    func markExecutionStarted(effectID: BoneEffectID, leaseGeneration: UInt64) async throws {
        executionCount += 1
    }

    func recordReceipt(_ receipt: BoneEffectReceipt) async throws {}

    func commitReceipt(effectID: BoneEffectID, leaseGeneration: UInt64) async throws {}

    func recoverySnapshot(
        effectID: BoneEffectID,
        currentLeaseGeneration: UInt64
    ) async throws -> BoneEffectRecoverySnapshot? {
        guard storedSnapshot?.intent.id == effectID else { return nil }
        return storedSnapshot
    }

    func persistOutcomeUnknown(effectID: BoneEffectID, currentLeaseGeneration: UInt64) async throws {
        persistOutcomeUnknownCount += 1
    }

    func resumePreparedEffect(
        effectID: BoneEffectID,
        expectedExecutionLeaseGeneration: UInt64,
        currentLeaseGeneration: UInt64
    ) async throws {
        executionCount += 1
    }

    func commitRecoveredReceipt(
        effectID: BoneEffectID,
        receiptLeaseGeneration: UInt64,
        currentLeaseGeneration: UInt64
    ) async throws {
        commitRecoveredReceiptCount += 1
    }

    func recordRecoveredReceipt(
        _ receipt: BoneEffectReceipt,
        expectedExecutionLeaseGeneration: UInt64,
        currentLeaseGeneration: UInt64
    ) async throws {}

    func facts() -> Facts {
        Facts(
            executionCount: executionCount,
            commitRecoveredReceiptCount: commitRecoveredReceiptCount,
            persistOutcomeUnknownCount: persistOutcomeUnknownCount
        )
    }
}

private enum TestUnknownPersistenceError: Error {
    case commitResultUnknown
}
