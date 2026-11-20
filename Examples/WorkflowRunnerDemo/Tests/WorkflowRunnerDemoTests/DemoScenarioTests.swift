import Testing
@testable import WorkflowRunnerDemo

struct DemoScenarioTests: Sendable {
    @Test(arguments: DemoScenarioID.allCases)
    func sharedScenarioProducesDisplayableEvidence(_ scenario: DemoScenarioID) async throws {
        let result = try await DemoScenarios.run(scenario)
        #expect(result.scenario == scenario)
        #expect(result.evidence.count >= 2)
        #expect(!result.metrics.isEmpty)
    }
}
