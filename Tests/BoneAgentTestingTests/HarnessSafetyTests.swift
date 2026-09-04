import XCTest
import Foundation
import BoneAgentKit
import BoneAgentTesting

final class HarnessSafetyTests: XCTestCase {
    func testSafeReportUsesFixedWhitelistAndRejectsPrivacyCanary() throws {
        let canary = "PRIVATE-CANARY-7f1d"
        let report = try BoneAgentTestReport(
            scenarioID: "scenario-1",
            outcome: .passed,
            assertionCount: 4,
            checkpointCount: 3,
            crashBoundaryCount: 2,
            durationMilliseconds: 12,
            note: canary
        )
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(canary))
        XCTAssertFalse(text.lowercased().contains("prompt"))
        XCTAssertFalse(text.lowercased().contains("arguments"))
        XCTAssertFalse(text.lowercased().contains("response"))
        XCTAssertEqual(try BonePrivacyTestAssertion.forbiddenMatches(in: data, canaries: [canary]), [])
    }

    func testSafeReportRejectsFreeTextScenarioIDs() throws {
        for value in [
            "prompt=PRIVATE-CANARY-7f1d",
            "scenario with spaces",
            "https://example.invalid/path",
            String(repeating: "a", count: 129),
        ] {
            XCTAssertThrowsError(try BoneAgentTestReport(
                scenarioID: value,
                outcome: .passed,
                assertionCount: 1,
                checkpointCount: 0,
                crashBoundaryCount: 0,
                durationMilliseconds: 1
            ))
        }
    }

    func testSafeReportDecodeCannotBypassValidation() throws {
        let data = Data(#"{"schemaVersion":1,"scenarioID":"prompt=PRIVATE-CANARY-7f1d","outcome":"passed","assertionCount":1,"checkpointCount":0,"crashBoundaryCount":0,"durationMilliseconds":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BoneAgentTestReport.self, from: data))
    }

    func testPrivacyAssertionDetectsCanary() throws {
        let canary = "PRIVATE-CANARY-7f1d"
        XCTAssertEqual(
            try BonePrivacyTestAssertion.forbiddenMatches(in: Data("prefix-\(canary)-suffix".utf8), canaries: [canary]),
            [canary]
        )
    }

    func testScenarioIsInMemoryOnlyAndDoesNotConformToCodable() async throws {
        let scenario = BoneAgentTestScenario(id: "delay-order") { seed in
            [3, 1, 2].map { ($0, BoneDeterministicTestDelay.nanoseconds(seed: seed, ordinal: $0, upperBound: 1_000)) }
        }
        let first = await scenario.run(seed: 42)
        let second = await scenario.run(seed: 42)
        XCTAssertEqual(first.map(\.0), second.map(\.0))
        XCTAssertEqual(first.map(\.1), second.map(\.1))
        XCTAssertFalse(scenario is any Encodable)
        XCTAssertFalse(scenario is any Decodable)
    }

    func testCrashHarnessVisitsEveryCommitBoundaryDeterministically() async throws {
        let harness = BoneCrashBoundaryHarness(boundaries: [
            .beforePersistenceCommit,
            .afterPersistenceCommitBeforeEvent,
            .afterEventBeforeNextWork
        ])
        let first = try await harness.run { boundary in boundary.rawValue }
        let second = try await harness.run { boundary in boundary.rawValue }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.boundary), [
            .beforePersistenceCommit,
            .afterPersistenceCommitBeforeEvent,
            .afterEventBeforeNextWork
        ])
        XCTAssertTrue(first.allSatisfy(\.boundaryVisited))
    }

    func testFrameworkIndependentAssertionsReturnValuesInsteadOfXCTestFailures() {
        XCTAssertEqual(BoneTestAssertion.equal(2 + 2, 4, label: "math"), .passed(label: "math"))
        XCTAssertEqual(BoneTestAssertion.isTrue(false, label: "flag"), .failed(label: "flag"))
    }
}
