import Foundation
import XCTest
import BoneAgentKit

final class WorkflowExecutionSessionTests: XCTestCase {
    func testAdmissionHashIsExactBytesAndValidatesDecode() throws {
        let draft = try request(sequence: 0, admission: Data("abc".utf8))
        XCTAssertEqual(draft.admissionHash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let session = try BoneWorkflowSessionLedger(runID: .init("run"), initial: draft).current
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json["admission"] = Data("other".utf8).base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowExecutionSession.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testSequenceAndSingleUseNonce() throws {
        var ledger = try initial().applying(.finish(.completed))
        let next = try request(sequence: 1)
        ledger = try ledger.applying(.prepare(next, nonce: "nonce-1"))
        ledger = try ledger.applying(.consume(next, nonce: "nonce-1"))
        XCTAssertEqual(ledger.current.sequence, 1)
        XCTAssertEqual(ledger.current.state, .active)
        XCTAssertNil(ledger.pendingPermit)
        ledger = try ledger.applying(.finish(.completed))
        XCTAssertThrowsError(try ledger.applying(.prepare(request(sequence: 2), nonce: "nonce-1"))) {
            XCTAssertEqual($0 as? BoneWorkflowExecutionSessionError, .nonceAlreadyUsed)
        }
    }

    func testUnpreparedContinuationCannotCreateSession() throws {
        let ledger = try initial().applying(.finish(.completed))
        XCTAssertThrowsError(try ledger.applying(.consume(request(sequence: 1), nonce: "fresh"))) {
            XCTAssertEqual($0 as? BoneWorkflowExecutionSessionError, .missingPermit)
        }
    }

    func testActiveAndRecoveryRequiredCannotContinue() throws {
        let active = try initial()
        XCTAssertThrowsError(try active.applying(.prepare(request(sequence: 1), nonce: "nonce")))
        let recovery = try active.applying(.finish(.recoveryRequired))
        XCTAssertThrowsError(try recovery.applying(.prepare(request(sequence: 1), nonce: "nonce")))
    }

    func testHashBindingAndSequenceCannotBeChangedAfterPrepare() throws {
        let next = try request(sequence: 1)
        let ledger = try initial().applying(.finish(.completed)).applying(.prepare(next, nonce: "nonce"))
        for changed in [try request(sequence: 1, admission: Data([0xfe])), try request(sequence: 2), try request(sequence: 1, binding: String(repeating: "b", count: 64))] {
            XCTAssertThrowsError(try ledger.applying(.consume(changed, nonce: "nonce")))
        }
        XCTAssertThrowsError(try ledger.applying(.consume(next, nonce: "different")))
        XCTAssertEqual(ledger.sessions.count, 1)
    }

    func testRevokedNonceCannotBeReissued() throws {
        let next = try request(sequence: 1)
        var ledger = try initial().applying(.finish(.completed)).applying(.prepare(next, nonce: "nonce"))
        ledger = try ledger.applying(.revoke)
        XCTAssertNil(ledger.pendingPermit)
        XCTAssertThrowsError(try ledger.applying(.prepare(next, nonce: "nonce")))
        XCTAssertEqual(try ledger.applying(.prepare(next, nonce: "new")).pendingPermit?.nextSequence, 1)
    }

    func testTwoHostPayloadShapesRemainOpaque() throws {
        for bytes in [Data("{\"custom\":true}".utf8), Data([0xff, 0x00, 0xfe])] {
            let session = try BoneWorkflowSessionLedger(runID: .init("run"), initial: request(sequence: 0, admission: bytes)).current
            XCTAssertEqual(session.admission, bytes)
            XCTAssertEqual(try JSONDecoder().decode(BoneWorkflowExecutionSession.self, from: JSONEncoder().encode(session)), session)
        }
    }

    func testEncodedLedgerPreservesNonceTombstonesWithoutRawNonce() throws {
        let next = try request(sequence: 1)
        let ledger = try initial().applying(.finish(.completed)).applying(.prepare(next, nonce: "private-nonce-value"))
        let bytes = try JSONEncoder().encode(ledger)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-nonce-value"))
        let restored = try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: bytes)
        XCTAssertEqual(restored, ledger)
        let consumed = try restored.applying(.consume(next, nonce: "private-nonce-value"))
        XCTAssertEqual(try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: JSONEncoder().encode(consumed)), consumed)
        let revoked = try restored.applying(.revoke)
        XCTAssertEqual(try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: JSONEncoder().encode(revoked)), revoked)
    }

    func testCorruptLedgerSequenceRevisionPermitAndTombstonesReject() throws {
        let prepared = try initial().applying(.finish(.completed)).applying(.prepare(request(sequence: 1), nonce: "nonce"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any])
        for mutation in 0..<5 {
            var json = original
            switch mutation {
            case 0: json["revision"] = 1
            case 1: json["issuedNonceHashes"] = []
            case 2:
                var permit = try XCTUnwrap(json["pendingPermit"] as? [String: Any])
                permit["nextSequence"] = 8
                json["pendingPermit"] = permit
            case 3:
                var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                sessions[0]["sequence"] = 5
                json["sessions"] = sessions
            default: json["schemaVersion"] = 999
            }
            XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testOperationAndEffectIdentitiesCannotBeReused() throws {
        let ledger = try initial().applying(.finish(.completed))
        for request in [
            try BoneWorkflowExecutionSession.Request(sequence: 1, operationID: "operation-0", effectID: .init("fresh"), bindingHash: String(repeating: "a", count: 64), admission: Data()),
            try .init(sequence: 1, operationID: "fresh", effectID: .init("effect-0"), bindingHash: String(repeating: "a", count: 64), admission: Data())
        ] {
            XCTAssertThrowsError(try ledger.applying(.prepare(request, nonce: "nonce"))) {
                XCTAssertEqual($0 as? BoneWorkflowExecutionSessionError, .identityReused)
            }
        }
    }

    func testSessionStateCannotReviveOrPrepareOverPendingPermit() throws {
        let completed = try initial().applying(.finish(.completed))
        XCTAssertThrowsError(try completed.applying(.finish(.active)))
        XCTAssertThrowsError(try completed.applying(.finish(.failed)))
        let prepared = try completed.applying(.prepare(request(sequence: 1), nonce: "first"))
        XCTAssertThrowsError(try prepared.applying(.prepare(request(sequence: 1), nonce: "second")))
        XCTAssertEqual(prepared.issuedNonceHashes.count, 1)
    }

    func testInvalidAdmissionBindingAndNonceInputsReject() throws {
        XCTAssertThrowsError(try request(sequence: 0, binding: "invalid"))
        XCTAssertThrowsError(try request(sequence: 0, admission: Data(repeating: 1, count: BoneWorkflowExecutionSession.maximumAdmissionByteCount + 1)))
        let completed = try initial().applying(.finish(.completed))
        for nonce in ["", "   ", String(repeating: "n", count: 129)] {
            XCTAssertThrowsError(try completed.applying(.prepare(request(sequence: 1), nonce: nonce)))
        }
    }

    func testSecondRunCannotConsumeAnUnpreparedPermit() async throws {
        let store = BoneInMemoryWorkflowExecutionSessionStore()
        let a = try await store.open(runID: .init("a"), initial: request(sequence: 0))
        let b = try await store.open(runID: .init("b"), initial: request(sequence: 0))
        let finishedA = try await store.apply(runID: a.runID, expectedRevision: 1, command: .finish(.completed))
        let finishedB = try await store.apply(runID: b.runID, expectedRevision: 1, command: .finish(.completed))
        _ = try await store.apply(runID: a.runID, expectedRevision: finishedA.revision, command: .prepare(request(sequence: 1), nonce: "same"))
        do {
            _ = try await store.apply(runID: b.runID, expectedRevision: finishedB.revision, command: .consume(request(sequence: 1), nonce: "same"))
            XCTFail("Other Run has no prepared permit")
        } catch { XCTAssertEqual(error as? BoneWorkflowExecutionSessionError, .missingPermit) }
        let unchanged = try await store.load(runID: b.runID)
        XCTAssertEqual(unchanged, finishedB)
    }

    func testImpossibleInitialNonceHistoryRejectsButLaterHistoryRoundTrips() throws {
        for state in [try initial(), try initial().applying(.finish(.recoveryRequired))] {
            XCTAssertEqual(try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: JSONEncoder().encode(state)), state)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            json["issuedNonceHashes"] = [String(repeating: "a", count: 64)]
            json["revision"] = state.revision + 2
            XCTAssertThrowsError(try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        let next = try request(sequence: 1)
        let later = try initial().applying(.finish(.completed)).applying(.prepare(next, nonce: "nonce")).applying(.consume(next, nonce: "nonce"))
        for state in [later, try later.applying(.finish(.recoveryRequired))] {
            XCTAssertEqual(try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: JSONEncoder().encode(state)), state)
        }
    }

    private func initial() throws -> BoneWorkflowSessionLedger {
        try .init(runID: .init("run"), initial: request(sequence: 0))
    }
    private func request(sequence: UInt64, admission: Data = Data([0xff, 0x00]), binding: String = String(repeating: "a", count: 64)) throws -> BoneWorkflowExecutionSession.Request {
        try .init(sequence: sequence, operationID: "operation-\(sequence)", effectID: .init("effect-\(sequence)"), bindingHash: binding, admission: admission)
    }
}
