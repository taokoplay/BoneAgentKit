import Foundation
import XCTest
@testable import BoneAgentKit

final class WorkflowWorkReconciliationTests: XCTestCase {
    typealias Ledger = BoneWorkflowWorkLedger
    func testRecordedResponseCanCommitAcrossLeaseWithoutRewritingOrigin() throws {
        let old = try inflight(recorded: true)
        let taken = try old.advancingLease(expectedGeneration: 1, newGeneration: 3)
        let request = try resolution(taken)
        let saved = try taken.reconciling(request)
        let unit = try saved.unit(id: "unit")
        XCTAssertEqual(unit.pages.last?.phase, .committed)
        XCTAssertEqual(unit.pages.last?.leaseGeneration, 1)
        XCTAssertEqual(unit.pages.last?.reconciliation, request)
        XCTAssertEqual(unit.artifact, Data([7]))
        XCTAssertEqual(unit.nextPage, 1)
        XCTAssertEqual(unit.requestCount, 1)
        XCTAssertEqual(try saved.preflight(unitID: "unit"), .ready)
        XCTAssertEqual(try saved.applying(.reserve(unitID: "unit", page: 1), leaseGeneration: 3).unit(id: "unit").pages.last?.leaseGeneration, 3)
        XCTAssertThrowsError(try saved.reconciling(request))
    }
    func testConfirmedFailureRetainsProgressAndConsumedPageIdentity() throws {
        let old = try inflight(recorded: false)
        let taken = try old.advancingLease(expectedGeneration: 1, newGeneration: 2)
        let saved = try taken.reconciling(resolution(taken, outcome: .knownFailure))
        XCTAssertEqual(try saved.unit(id: "unit").state, .partial)
        XCTAssertEqual(try saved.unit(id: "unit").nextPage, 1)
        XCTAssertEqual(try saved.unit(id: "unit").pages.last?.phase, .knownFailure)
        XCTAssertEqual(try saved.preflight(unitID: "unit"), .ready)
    }
    func testRecordedResponseCannotBeReplacedOrDowngradedToFailure() throws {
        let taken = try inflight(recorded: true).advancingLease(expectedGeneration: 1, newGeneration: 2)
        for outcome: Ledger.Reconciliation.Outcome in [.knownFailure, .committed(response: Data([99]), cursor: nil, artifact: Data(), completed: false)] {
            XCTAssertThrowsError(try taken.reconciling(resolution(taken, outcome: outcome)))
        }
    }
    func testExactTargetAndCurrentLeaseRevisionRequired() throws {
        let taken = try inflight(recorded: true).advancingLease(expectedGeneration: 1, newGeneration: 3)
        let cases: [(String, String, UInt64, UInt64, UInt64, UInt64)] = [
            ("other", "unit", 0, 1, 3, taken.revision), ("run", "other", 0, 1, 3, taken.revision),
            ("run", "unit", 1, 1, 3, taken.revision), ("run", "unit", 0, 2, 3, taken.revision),
            ("run", "unit", 0, 1, 2, taken.revision), ("run", "unit", 0, 1, 3, taken.revision - 1)
        ]
        for (index, item) in cases.enumerated() {
            let (run, unit, page, source, current, revision) = item
            let request = try Ledger.Reconciliation(runID: .init(run), unitID: unit, page: page, sourceGeneration: source,
                resolvingGeneration: current, expectedRevision: revision, evidenceID: "evidence", outcome: .committed(response: Data([4]), cursor: nil, artifact: Data(), completed: false))
            let expected: [BoneWorkflowWorkLedgerError] = [.invalidInput, .missingUnit, .pageConflict, .leaseConflict, .leaseConflict, .revisionConflict]
            XCTAssertThrowsError(try taken.reconciling(request)) { XCTAssertEqual($0 as? BoneWorkflowWorkLedgerError, expected[index]) }
        }
    }
    func testReconciliationRoundTripAndInvalidDecode() throws {
        let taken = try inflight(recorded: true).advancingLease(expectedGeneration: 1, newGeneration: 2)
        let request = try resolution(taken)
        let bytes = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(Ledger.Reconciliation.self, from: bytes), request)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["resolvingGeneration"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(Ledger.Reconciliation.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testReservedRequiresFailureNotSyntheticSuccess() throws {
        let state = try Ledger(runID: .init("run"), leaseGeneration: 1, units: [.init(id: "unit", payload: Data())])
            .applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
            .advancingLease(expectedGeneration: 1, newGeneration: 2)
        XCTAssertThrowsError(try state.reconciling(resolution(state)))
        let failed = try state.reconciling(resolution(state, outcome: .knownFailure))
        XCTAssertEqual(try failed.unit(id: "unit").pages.last?.phase, .knownFailure)
    }
    func testDispatchedCanRecoverConfirmedCompletionAndCannotRevive() throws {
        let taken = try inflight(recorded: false).advancingLease(expectedGeneration: 1, newGeneration: 2)
        let outcome = Ledger.Reconciliation.Outcome.committed(response: Data([4]), cursor: nil, artifact: Data([8]), completed: true)
        let saved = try taken.reconciling(resolution(taken, outcome: outcome))
        XCTAssertEqual(try saved.preflight(unitID: "unit"), .terminal(.completed))
        XCTAssertThrowsError(try saved.reconciling(resolution(saved, outcome: outcome)))
        XCTAssertThrowsError(try saved.applying(.reserve(unitID: "unit", page: 1), leaseGeneration: 2))
        let advanced = try saved.advancingLease(expectedGeneration: 2, newGeneration: 5)
        XCTAssertEqual(try advanced.unit(id: "unit"), try saved.unit(id: "unit"))
    }
    func testInvalidProofShapeAndBoundedPayloadsReject() throws {
        let state = try inflight(recorded: false).advancingLease(expectedGeneration: 1, newGeneration: 2)
        for (source, current, revision, evidence): (UInt64, UInt64, UInt64, String) in [
            (0, 2, 1, "e"), (1, 1, 1, "e"), (2, 1, 1, "e"), (1, 2, 0, "e"),
            (1, 2, 1, "   "), (1, 2, 1, String(repeating: "e", count: 129))
        ] {
            XCTAssertThrowsError(try Ledger.Reconciliation(runID: state.runID, unitID: "unit", page: 0,
                sourceGeneration: source, resolvingGeneration: current, expectedRevision: revision, evidenceID: evidence, outcome: .knownFailure))
        }
        let oversized = Data(repeating: 0, count: Ledger.maximumDataByteCount + 1)
        for outcome: Ledger.Reconciliation.Outcome in [
            .committed(response: oversized, cursor: nil, artifact: Data(), completed: false),
            .committed(response: Data(), cursor: oversized, artifact: Data(), completed: false),
            .committed(response: Data(), cursor: nil, artifact: oversized, completed: false)
        ] { XCTAssertThrowsError(try resolution(state, outcome: outcome)) }
    }
    func testNewTakeoverInvalidatesPreparedReconciliation() throws {
        let taken = try inflight(recorded: true).advancingLease(expectedGeneration: 1, newGeneration: 2)
        let request = try resolution(taken)
        let later = try taken.advancingLease(expectedGeneration: 2, newGeneration: 4)
        XCTAssertThrowsError(try later.reconciling(request))
        let staleOwner = try Ledger.Reconciliation(runID: later.runID, unitID: "unit", page: 0,
            sourceGeneration: 1, resolvingGeneration: 2, expectedRevision: later.revision, evidenceID: "e", outcome: .committed(response: Data([4]), cursor: nil, artifact: Data(), completed: false))
        XCTAssertThrowsError(try later.reconciling(staleOwner)) { XCTAssertEqual($0 as? BoneWorkflowWorkLedgerError, .leaseConflict) }
        let committed = try later.reconciling(resolution(later))
        XCTAssertEqual(try committed.unit(id: "unit").pages.last?.leaseGeneration, 1)
    }

    func testDecodeRejectsInvalidIDsCountersAndAllOversizedPayloadFields() throws {
        let state = try inflight(recorded: true).advancingLease(expectedGeneration: 1, newGeneration: 2)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolution(state))) as? [String: Any])
        for (key, value) in [("unitID", " "), ("evidenceID", "")] {
            var json = original
            json[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(Ledger.Reconciliation.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        for key in ["sourceGeneration", "expectedRevision"] {
            var json = original
            json[key] = 0
            XCTAssertThrowsError(try JSONDecoder().decode(Ledger.Reconciliation.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        let maximum = Data(repeating: 0xff, count: Ledger.maximumDataByteCount)
        let accepted = try resolution(state, outcome: .committed(response: maximum, cursor: maximum, artifact: maximum, completed: false))
        XCTAssertEqual(try JSONDecoder().decode(Ledger.Reconciliation.self, from: JSONEncoder().encode(accepted)), accepted)
        let oversized = Data(repeating: 0, count: Ledger.maximumDataByteCount + 1).base64EncodedString()
        for field in ["response", "cursor", "artifact"] {
            var json = original
            var outcome = try XCTUnwrap(json["outcome"] as? [String: Any])
            var committed = try XCTUnwrap(outcome["committed"] as? [String: Any])
            committed[field] = oversized
            outcome["committed"] = committed
            json["outcome"] = outcome
            XCTAssertThrowsError(try JSONDecoder().decode(Ledger.Reconciliation.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    private func inflight(recorded: Bool) throws -> Ledger {
        var state = try Ledger(runID: .init("run"), leaseGeneration: 1, units: [.init(id: "unit", payload: Data([0xff]))])
        state = try state.applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        state = try state.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        if recorded { state = try state.applying(.recordResponse(unitID: "unit", page: 0, response: Data([4])), leaseGeneration: 1) }
        return state
    }
    private func resolution(_ state: Ledger, outcome: Ledger.Reconciliation.Outcome = .committed(response: Data([4]), cursor: Data([6]), artifact: Data([7]), completed: false)) throws -> Ledger.Reconciliation {
        try .init(runID: state.runID, unitID: "unit", page: 0, sourceGeneration: 1, resolvingGeneration: state.leaseGeneration,
            expectedRevision: state.revision, evidenceID: "host-evidence", outcome: outcome)
    }
}
