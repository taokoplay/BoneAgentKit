import Foundation
import XCTest
@testable import BoneAgentKit

private enum StepStoreError: Error, Equatable {
    case invalidCheckpoint, revisionConflict, staleLease
}

/// Validates before writing; CAS and lease fencing are one atomic actor operation.
private actor StepStore {
    private(set) var stored: BoneAgentWorkflowStepCheckpoint
    private(set) var submissions = 0
    private(set) var invalidSubmissions = 0
    private(set) var events: [BoneAgentWorkflowStepEventKind] = []
    private var generation: UInt64

    init(_ checkpoint: BoneAgentWorkflowStepCheckpoint) {
        stored = checkpoint
        generation = checkpoint.leaseGeneration
    }

    nonisolated var persistence: BoneAgentWorkflowStepPersistence {
        .init { next, revision, lease in
            try await self.commit(next, revision: revision, lease: lease)
        }
    }

    nonisolated var eventSink: BoneAgentWorkflowStepEventSink {
        .init { await self.record($0.kind) }
    }

    private func record(_ event: BoneAgentWorkflowStepEventKind) { events.append(event) }
    func takeOver() { generation += 1 }

    func commit(_ next: BoneAgentWorkflowStepCheckpoint, revision: UInt64, lease: UInt64) throws -> BoneAgentWorkflowStepCheckpoint {
        submissions += 1
        let terminal: BoneAgentWorkflowStepTerminalState?
        switch next.state {
        case .succeeded: terminal = .succeeded
        case .failed: terminal = .failed
        case .cancelled: terminal = .cancelled
        default: terminal = nil
        }
        guard (next.state == .waiting) == (next.pendingAuthorizationTicketID != nil),
              next.terminalState == terminal,
              next.cancellationPersisted == (next.state == .cancelled),
              next.inferenceResponseCount >= 0, next.toolResultCount >= 0 else {
            invalidSubmissions += 1
            throw StepStoreError.invalidCheckpoint
        }
        guard lease == generation else { throw StepStoreError.staleLease }
        guard revision == stored.persistenceRevision else { throw StepStoreError.revisionConflict }
        stored = stepCopy(next, revision: revision + 1)
        return stored
    }
}

private func stepCopy(
    _ checkpoint: BoneAgentWorkflowStepCheckpoint,
    revision: UInt64? = nil,
    lease: UInt64? = nil,
    inferenceCount: Int? = nil,
    runID: BoneRunID? = nil
) -> BoneAgentWorkflowStepCheckpoint {
    .init(runID: runID ?? checkpoint.runID, stepID: checkpoint.stepID, attemptID: checkpoint.attemptID,
          state: checkpoint.state, inferenceResponseCount: inferenceCount ?? checkpoint.inferenceResponseCount,
          toolResultCount: checkpoint.toolResultCount, pendingAuthorizationTicketID: checkpoint.pendingAuthorizationTicketID,
          cancellationPersisted: checkpoint.cancellationPersisted, terminalState: checkpoint.terminalState,
          persistenceRevision: revision ?? checkpoint.persistenceRevision, leaseGeneration: lease ?? checkpoint.leaseGeneration)
}

/// A deterministic pre-CAS gate, without sleep or network operations.
private actor StepCommitGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() { release?.resume(); release = nil }
}

final class WorkflowStepControllerTests: XCTestCase {
    private func initial() throws -> BoneAgentWorkflowStepCheckpoint {
        .init(runID: try .init("run"), stepID: try .init("step"), attemptID: try .init("attempt"), leaseGeneration: 7)
    }

    private func controller(_ checkpoint: BoneAgentWorkflowStepCheckpoint, store: StepStore) throws -> BoneAgentWorkflowStepController {
        try .init(restoring: checkpoint, persistence: store.persistence, eventSink: store.eventSink)
    }

    private func assertError<E: Error & Equatable>(
        _ expected: E, file: StaticString = #filePath, line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? E, expected, file: file, line: line) }
    }

    func testWaitingCancelClearsTicketAndRestoresTerminalCheckpoint() async throws {
        try await verifyWaitingTerminal(nil)
    }

    func testWaitingFinishFailedClearsTicketAndRestoresTerminalCheckpoint() async throws {
        try await verifyWaitingTerminal(.failed)
    }

    func testWaitingFinishCancelledClearsTicketAndRestoresTerminalCheckpoint() async throws {
        try await verifyWaitingTerminal(.cancelled)
    }

    private func verifyWaitingTerminal(_ terminal: BoneAgentWorkflowStepTerminalState?) async throws {
        let seed = try initial()
        let store = StepStore(seed)
        let subject = try controller(seed, store: store)
        let ticket = try BoneAuthorizationTicketID("ticket")
        try await subject.waitForAuthorization(ticketID: ticket)
        if let terminal { try await subject.finish(terminal) } else { try await subject.cancel() }
        let saved = await store.stored
        let local = await subject.checkpoint
        let invalid = await store.invalidSubmissions
        XCTAssertEqual(invalid, 0)
        XCTAssertEqual(local, saved)
        XCTAssertNil(saved.pendingAuthorizationTicketID)
        XCTAssertEqual(saved.terminalState, terminal ?? .cancelled)
        XCTAssertEqual(saved.cancellationPersisted, terminal != .failed)
        XCTAssertEqual(saved.persistenceRevision, 2)
        let decoded = try JSONDecoder().decode(BoneAgentWorkflowStepCheckpoint.self, from: JSONEncoder().encode(saved))
        let restored = try controller(decoded, store: store)
        await assertError(BoneAgentWorkflowStepError.terminalState) { try await restored.receive(.inferenceResponsePrepared(step: 1, kind: .finish)) }
        await assertError(BoneAgentWorkflowStepError.terminalState) { try await restored.resumeAfterAuthorization(ticketID: ticket) }
        await assertError(BoneAgentWorkflowStepError.terminalState) { try await restored.resume() }
        await assertError(BoneAgentWorkflowStepError.terminalState) { try await restored.finish(.succeeded) }
        await assertError(BoneAgentWorkflowStepError.terminalState) { try await restored.cancel() }
        let count = await store.submissions
        let events = await store.events
        XCTAssertEqual(count, 2)
        XCTAssertEqual(events, [.waitingForAuthorization, terminal == .failed ? .failed : .cancelled])
    }

    func testWaitingCannotSucceedBeforeExplicitAuthorizationResume() async throws {
        let seed = try initial()
        let store = StepStore(seed)
        let subject = try controller(seed, store: store)
        let ticket = try BoneAuthorizationTicketID("ticket")
        try await subject.waitForAuthorization(ticketID: ticket)
        let waiting = await subject.checkpoint
        await assertError(BoneAgentWorkflowStepError.invalidState) { try await subject.finish(.succeeded) }
        let count = await store.submissions
        let invalid = await store.invalidSubmissions
        let after = await subject.checkpoint
        XCTAssertEqual(count, 1, "Disallowed transitions must not reach persistence")
        XCTAssertEqual(invalid, 0)
        XCTAssertEqual(after, waiting)
        await assertError(BoneAgentWorkflowStepError.authorizationTicketMismatch) {
            try await subject.resumeAfterAuthorization(ticketID: .init("wrong"))
        }
        try await subject.resumeAfterAuthorization(ticketID: ticket)
        try await subject.finish(.succeeded)
        let saved = await store.stored
        XCTAssertEqual(saved.state, .succeeded)
        XCTAssertNil(saved.pendingAuthorizationTicketID)
    }

    func testLateProgressAfterCancellationDoesNotWriteOrPublish() async throws {
        let seed = try initial()
        let store = StepStore(seed)
        let subject = try controller(seed, store: store)
        let sink = subject.progressSink()
        try await subject.cancel()
        for progress: BoneAgentProgress in [.inferenceResponsePrepared(step: 1, kind: .finish), .toolResultPrepared(step: 1, ordinal: 0), .inferenceFailed(.network)] {
            await assertError(BoneAgentWorkflowStepError.terminalState) { try await sink.receive(progress) }
        }
        let count = await store.submissions
        let events = await store.events
        XCTAssertEqual(count, 1)
        XCTAssertEqual(events, [.cancelled])
    }

    func testCASConflictDoesNotMutateLosingControllerOrPublishEvent() async throws {
        let seed = try initial()
        let store = StepStore(seed)
        let winner = try controller(seed, store: store)
        let loser = try controller(seed, store: store)
        try await winner.cancel()
        await assertError(StepStoreError.revisionConflict) { try await loser.pause() }
        let local = await loser.checkpoint
        let events = await store.events
        XCTAssertEqual(local, seed)
        XCTAssertEqual(events, [.cancelled])
    }

    func testOldLeaseCannotCommitAfterTakeover() async throws {
        let seed = try initial()
        let store = StepStore(seed)
        let subject = try controller(seed, store: store)
        await store.takeOver()
        await assertError(StepStoreError.staleLease) { try await subject.cancel() }
        let local = await subject.checkpoint
        let saved = await store.stored
        let events = await store.events
        XCTAssertEqual(local, seed)
        XCTAssertEqual(saved, seed)
        XCTAssertTrue(events.isEmpty)
    }

    func testInFlightProgressCannotOverwriteCommittedCancellation() async throws {
        let seed = try initial()
        let store = StepStore(seed)
        let gate = StepCommitGate()
        let subject = try BoneAgentWorkflowStepController(restoring: seed, persistence: .init { next, revision, lease in
            if next.inferenceResponseCount == 1 { await gate.suspend() }
            return try await store.commit(next, revision: revision, lease: lease)
        }, eventSink: store.eventSink)
        let progress = Task { try await subject.receive(.inferenceResponsePrepared(step: 1, kind: .finish)) }
        await gate.waitUntilEntered()
        try await subject.cancel()
        await gate.open()
        await assertError(StepStoreError.revisionConflict) { try await progress.value }
        let local = await subject.checkpoint
        let saved = await store.stored
        let events = await store.events
        XCTAssertEqual(local, saved)
        XCTAssertEqual(local.state, .cancelled)
        XCTAssertEqual(local.inferenceResponseCount, 0)
        XCTAssertEqual(events, [.cancelled])
    }

    func testInvalidStoreResponsesAreRejectedWithoutLocalMutationOrEvents() async throws {
        let seed = try initial()
        // Preserve post-write validation of state invariants, content, revision, identity and lease.
        for mode in 0..<5 {
            let probe = StepStore(seed)
            let subject = try BoneAgentWorkflowStepController(restoring: seed, persistence: .init { next, revision, lease in
                switch mode {
                case 0: return stepCopy(next, revision: revision + 1, inferenceCount: -1)
                case 1: return stepCopy(next, revision: revision + 1, inferenceCount: 4)
                case 2: return stepCopy(next, revision: revision)
                case 3: return stepCopy(next, revision: revision + 1, lease: lease + 1)
                default: return stepCopy(next, revision: revision + 1, runID: try .init("other-run"))
                }
            }, eventSink: probe.eventSink)
            await assertError(BoneAgentWorkflowStepError.invalidState) { try await subject.pause() }
            let local = await subject.checkpoint
            let events = await probe.events
            XCTAssertEqual(local, seed)
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testRestoreRejectsTerminalCheckpointWithPendingTicket() throws {
        let seed = try initial()
        let invalid = BoneAgentWorkflowStepCheckpoint(runID: seed.runID, stepID: seed.stepID, attemptID: seed.attemptID,
            state: .cancelled, pendingAuthorizationTicketID: try .init("ticket"), cancellationPersisted: true, terminalState: .cancelled)
        XCTAssertThrowsError(try controller(invalid, store: StepStore(seed))) {
            XCTAssertEqual($0 as? BoneAgentWorkflowStepError, .invalidState)
        }
    }
}
