import Foundation

@main
enum WorkflowRunnerDemo {
    static func main() async throws {
        if CommandLine.arguments.contains("--bounded-stream") {
            let report = try await DemoBoundedStreaming.run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        print("WorkflowRunnerDemo — synthetic engine, real Agent Loop, process-local persistence")
        for scenario in DemoScenarioID.allCases {
            let result = try await DemoScenarios.run(scenario)
            let details = result.metrics.map { "\($0.name)=\($0.value)" }.joined(separator: "，")
            print("PASS: \(scenario.title) — \(details)")
        }
        print("PASS: 7/7 demo scenarios")
    }
}
