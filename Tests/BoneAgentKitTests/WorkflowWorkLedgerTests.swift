import Foundation
import XCTest
import BoneAgentKit

final class WorkflowWorkLedgerTests: XCTestCase {
    func testPageLifecycleAndOpaqueBytes() throws {
        var ledger = try fixture()
        ledger = try ledger.applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        XCTAssertEqual(try ledger.preflight(unitID: "unit"), .inFlight(page: 0, phase: .reserved))
        ledger = try ledger.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        ledger = try ledger.applying(.recordResponse(unitID: "unit", page: 0, response: Data([0xff])), leaseGeneration: 1)
        ledger = try ledger.applying(.commit(unitID: "unit", page: 0, cursor: Data([0x00]), artifact: Data([0xfe]), completed: false), leaseGeneration: 1)
        let unit = try ledger.unit(id: "unit")
        XCTAssertEqual(unit.payload, Data([0xff, 0x00]))
        XCTAssertEqual(unit.artifact, Data([0xfe]))
        XCTAssertEqual(unit.nextPage, 1)
        XCTAssertEqual(unit.requestCount, 1)
        XCTAssertEqual(try ledger.preflight(unitID: "unit"), .ready)
        XCTAssertThrowsError(try ledger.applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1))
    }

    func testKnownFailureKeepsPartialAndConsumesPageIdentity() throws {
        var ledger = try fixture()
        ledger = try ledger.applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        ledger = try ledger.applying(.finishKnownFailure(unitID: "unit", page: 0), leaseGeneration: 1)
        XCTAssertEqual(try ledger.unit(id: "unit").state, .partial)
        XCTAssertEqual(try ledger.unit(id: "unit").nextPage, 1)
        ledger = try ledger.applying(.reserve(unitID: "unit", page: 1), leaseGeneration: 1)
        XCTAssertEqual(try ledger.unit(id: "unit").requestCount, 2)
    }

    func testLeaseTakeoverKeepsInFlightAndRejectsReplay() throws {
        let old = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        let recovered = try old.advancingLease(expectedGeneration: 1, newGeneration: 2)
        XCTAssertEqual(try recovered.preflight(unitID: "unit"), .recoveryRequired(page: 0))
        XCTAssertThrowsError(try recovered.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1))
        XCTAssertThrowsError(try recovered.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 2))
        XCTAssertThrowsError(try recovered.applying(.reserve(unitID: "unit", page: 1), leaseGeneration: 2))
        XCTAssertEqual(try recovered.unit(id: "unit"), try old.unit(id: "unit"))
    }

    func testSplitIsAtomicAndParentCannotIssueMorePages() throws {
        let old = try fixture()
        let children = [try BoneWorkflowWorkLedger.Seed(id: "a", payload: Data([1])), try .init(id: "b", payload: Data([2]))]
        let split = try old.applying(.split(unitID: "unit", children: children), leaseGeneration: 1)
        XCTAssertEqual(try split.unit(id: "unit").state, .split)
        XCTAssertEqual(split.units.count, 3)
        XCTAssertThrowsError(try split.applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1))
        XCTAssertThrowsError(try old.applying(.split(unitID: "unit", children: [children[0], children[0]]), leaseGeneration: 1))
        XCTAssertEqual(old.units.count, 1)
    }

    func testInFlightPreventsSplitOrStop() throws {
        let ledger = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        let children = [try BoneWorkflowWorkLedger.Seed(id: "a", payload: Data([1])), try .init(id: "b", payload: Data([2]))]
        XCTAssertThrowsError(try ledger.applying(.split(unitID: "unit", children: children), leaseGeneration: 1))
        XCTAssertThrowsError(try ledger.applying(.stop(unitID: "unit", reason: .noProgress), leaseGeneration: 1))
    }

    func testStoreCASRejectsRepeatedCommandWithoutMutation() async throws {
        let store = BoneInMemoryWorkflowWorkLedgerStore()
        let initial = try fixture()
        _ = try await store.open(runID: initial.runID, leaseGeneration: 1, units: initial.units.map { try .init(id: $0.id, payload: $0.payload) })
        let saved = try await store.apply(runID: initial.runID, expectedRevision: 1, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
        do {
            _ = try await store.apply(runID: initial.runID, expectedRevision: 1, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
            XCTFail("Repeated revision must fail")
        } catch { XCTAssertEqual(error as? BoneWorkflowWorkLedgerError, .revisionConflict) }
        let after = try await store.load(runID: initial.runID)
        XCTAssertEqual(after, saved)
    }

    func testOutOfOrderAndRepeatedResponsesCannotOverwritePage() throws {
        var state = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        XCTAssertThrowsError(try state.applying(.recordResponse(unitID: "unit", page: 0, response: Data()), leaseGeneration: 1))
        XCTAssertThrowsError(try state.applying(.commit(unitID: "unit", page: 0, cursor: nil, artifact: Data(), completed: true), leaseGeneration: 1))
        state = try state.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        XCTAssertThrowsError(try state.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1))
        state = try state.applying(.recordResponse(unitID: "unit", page: 0, response: Data([1])), leaseGeneration: 1)
        XCTAssertThrowsError(try state.applying(.recordResponse(unitID: "unit", page: 0, response: Data([2])), leaseGeneration: 1))
        XCTAssertThrowsError(try state.applying(.finishKnownFailure(unitID: "unit", page: 0), leaseGeneration: 1))
        XCTAssertEqual(try state.unit(id: "unit").pages.last?.response, Data([1]))
    }

    func testAllOldPageMutationsRejectAfterTakeover() throws {
        var state = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        state = try state.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        state = try state.applying(.recordResponse(unitID: "unit", page: 0, response: Data([1])), leaseGeneration: 1)
        let recovered = try state.advancingLease(expectedGeneration: 1, newGeneration: 2)
        let commands: [BoneWorkflowWorkLedger.Command] = [
            .dispatch(unitID: "unit", page: 0), .recordResponse(unitID: "unit", page: 0, response: Data()),
            .commit(unitID: "unit", page: 0, cursor: nil, artifact: Data(), completed: true),
            .finishKnownFailure(unitID: "unit", page: 0), .stop(unitID: "unit", reason: .cursorLimit)
        ]
        for command in commands {
            XCTAssertThrowsError(try recovered.applying(command, leaseGeneration: 2)) {
                XCTAssertEqual($0 as? BoneWorkflowWorkLedgerError, .recoveryRequired)
            }
        }
        XCTAssertEqual(try recovered.unit(id: "unit"), try state.unit(id: "unit"))
    }

    func testTerminalStatesCannotReviveAndStopReasonsAreRetained() throws {
        for reason in [BoneWorkflowWorkLedger.StopReason.noProgress, .cursorLimit] {
            let state = try fixture().applying(.stop(unitID: "unit", reason: reason), leaseGeneration: 1)
            XCTAssertEqual(try state.preflight(unitID: "unit"), .terminal(.blocked))
            XCTAssertEqual(try state.unit(id: "unit").stopReason, reason)
            XCTAssertThrowsError(try state.applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1))
        }
        var completed = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        completed = try completed.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        completed = try completed.applying(.recordResponse(unitID: "unit", page: 0, response: Data()), leaseGeneration: 1)
        completed = try completed.applying(.commit(unitID: "unit", page: 0, cursor: nil, artifact: Data([1]), completed: true), leaseGeneration: 1)
        XCTAssertEqual(try completed.preflight(unitID: "unit"), .terminal(.completed))
        XCTAssertThrowsError(try completed.applying(.reserve(unitID: "unit", page: 1), leaseGeneration: 1))
    }

    func testFailureAndSplitPreservePreviouslyCommittedArtifact() throws {
        var state = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        state = try state.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        state = try state.applying(.recordResponse(unitID: "unit", page: 0, response: Data()), leaseGeneration: 1)
        state = try state.applying(.commit(unitID: "unit", page: 0, cursor: Data([4]), artifact: Data([5]), completed: false), leaseGeneration: 1)
        state = try state.applying(.reserve(unitID: "unit", page: 1), leaseGeneration: 1)
        state = try state.applying(.dispatch(unitID: "unit", page: 1), leaseGeneration: 1)
        state = try state.applying(.finishKnownFailure(unitID: "unit", page: 1), leaseGeneration: 1)
        XCTAssertEqual(try state.unit(id: "unit").artifact, Data([5]))
        XCTAssertEqual(try state.unit(id: "unit").cursor, Data([4]))
        state = try state.applying(.split(unitID: "unit", children: [.init(id: "a", payload: Data()), .init(id: "b", payload: Data())]), leaseGeneration: 1)
        XCTAssertEqual(try state.unit(id: "unit").artifact, Data([5]))
        XCTAssertEqual(try state.unit(id: "a").artifact, nil)
    }

    func testInvalidInputsAndOversizedDataFailWithoutChangingState() throws {
        XCTAssertThrowsError(try BoneWorkflowWorkLedger.Seed(id: " ", payload: Data()))
        let large = Data(repeating: 1, count: BoneWorkflowWorkLedger.maximumDataByteCount + 1)
        XCTAssertThrowsError(try BoneWorkflowWorkLedger.Seed(id: "x", payload: large))
        var state = try fixture().applying(.reserve(unitID: "unit", page: 0), leaseGeneration: 1)
        state = try state.applying(.dispatch(unitID: "unit", page: 0), leaseGeneration: 1)
        XCTAssertThrowsError(try state.applying(.recordResponse(unitID: "unit", page: 0, response: large), leaseGeneration: 1))
        XCTAssertEqual(try state.preflight(unitID: "unit"), .inFlight(page: 0, phase: .dispatched))
    }

    func testEncodedCommandsReplayWithoutBypassingValidation() throws {
        let initial = try fixture()
        let command = BoneWorkflowWorkLedger.Command.reserve(unitID: "unit", page: 3)
        let decoded = try JSONDecoder().decode(BoneWorkflowWorkLedger.Command.self, from: JSONEncoder().encode(command))
        XCTAssertThrowsError(try initial.applying(decoded, leaseGeneration: 1)) {
            XCTAssertEqual($0 as? BoneWorkflowWorkLedgerError, .pageConflict)
        }
    }

    func testOpenChecksOriginalPlanAndNeverResetsProgress() async throws {
        let store = BoneInMemoryWorkflowWorkLedgerStore()
        let initial = try fixture()
        _ = try await store.open(runID: initial.runID, leaseGeneration: 1, units: initial.preparedUnits)
        let saved = try await store.apply(runID: initial.runID, expectedRevision: 1, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
        let reopened = try await store.open(runID: initial.runID, leaseGeneration: 1, units: initial.preparedUnits)
        XCTAssertEqual(reopened, saved)
        do {
            _ = try await store.open(runID: initial.runID, leaseGeneration: 1, units: [.init(id: "unit", payload: Data([2]))])
            XCTFail("Payload plan drift must reject")
        } catch { XCTAssertEqual(error as? BoneWorkflowWorkLedgerError, .planMismatch) }
    }

    private func fixture() throws -> BoneWorkflowWorkLedger {
        try .init(runID: .init("run"), leaseGeneration: 1, units: [.init(id: "unit", payload: Data([0xff, 0x00]))])
    }
}
