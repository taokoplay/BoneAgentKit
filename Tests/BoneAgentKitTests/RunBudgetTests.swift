import XCTest
@testable import BoneAgentKit

final class RunBudgetTests: XCTestCase {
    private func budget() throws -> BoneRunBudget {
        try BoneRunBudget(maximumInferenceCalls: 2, maximumToolCalls: 1,
            maximumInputBytes: 10, maximumOutputBytes: 10, maximumTurns: 1,
            maximumWallClockSeconds: 5, maximumConcurrentToolCalls: 1,
            maximumEstimatedCostMicrounits: 10)
    }

    func testRejectedConcurrentReservationDoesNotConsumeCallOrInputBudget() async throws {
        let meter = BoneRunBudgetMeter(budget: try budget(), startedAtUptime: 100)
        try await meter.reserveConcurrentTool(nowUptime: 100)
        do { try await meter.reserveToolExecution(argumentsBytes: 10, nowUptime: 100); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BoneRunBudgetError, .concurrencyLimitReached(limit: 1)) }
        await meter.releaseConcurrentTool()
        try await meter.reserveToolExecution(argumentsBytes: 10, nowUptime: 100)
        await meter.releaseConcurrentTool()
        do { try await meter.reserveToolExecution(argumentsBytes: 0, nowUptime: 100); XCTFail("accepted attempts remain charged") }
        catch { XCTAssertEqual(error as? BoneRunBudgetError, .toolCallLimitReached(limit: 1)) }
    }

    func testRejectedInputReservationDoesNotLeakConcurrentSlot() async throws {
        let meter = BoneRunBudgetMeter(budget: try budget(), startedAtUptime: 100)
        do { try await meter.reserveToolExecution(argumentsBytes: 11, nowUptime: 100); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BoneRunBudgetError, .inputByteLimitReached(limit: 10)) }
        try await meter.reserveToolExecution(argumentsBytes: 10, nowUptime: 100)
    }

    func testRejectedInferenceDoesNotConsumeCallInputOrCost() async throws {
        let meter = BoneRunBudgetMeter(budget: try budget(), startedAtUptime: 100)
        do { try await meter.reserveInference(inputBytes: 10, estimatedCostMicrounits: 11, nowUptime: 100); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BoneRunBudgetError, .estimatedCostLimitReached(limit: 10)) }
        try await meter.reserveInference(inputBytes: 10, estimatedCostMicrounits: 10, nowUptime: 100)
        try await meter.reserveInference(inputBytes: 0, estimatedCostMicrounits: 0, nowUptime: 100)
    }

    func testRejectedInferenceTurnLeavesTurnAvailable() async throws {
        let meter = BoneRunBudgetMeter(budget: try budget(), startedAtUptime: 100)
        do { try await meter.reserveInferenceTurn(inputBytes: 11, estimatedCostMicrounits: 0, nowUptime: 100); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BoneRunBudgetError, .inputByteLimitReached(limit: 10)) }
        try await meter.reserveInferenceTurn(inputBytes: 10, estimatedCostMicrounits: 0, nowUptime: 100)
        do { try await meter.reserveInferenceTurn(inputBytes: 0, estimatedCostMicrounits: 0, nowUptime: 100); XCTFail("turn must be consumed") }
        catch { XCTAssertEqual(error as? BoneRunBudgetError, .turnLimitReached(limit: 1)) }
    }

    func testMonotonicDeadlineIsInclusiveAndRejectsInvalidReadings() async throws {
        let meter = BoneRunBudgetMeter(budget: try budget(), startedAtUptime: 100)
        try await meter.checkWallClock(nowUptime: 105)
        for now in [105.001, 99, .infinity, .nan] {
            do { try await meter.checkWallClock(nowUptime: now); XCTFail("must reject invalid or expired clock") }
            catch { XCTAssertEqual(error as? BoneRunBudgetError, .wallClockLimitReached) }
        }
    }
}
