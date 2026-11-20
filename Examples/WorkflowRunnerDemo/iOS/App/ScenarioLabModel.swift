import Foundation
import Observation

@Observable
@MainActor
final class ScenarioLabModel {
    private(set) var results: [DemoScenarioID: DemoScenarioResult] = [:]
    private(set) var errors: [DemoScenarioID: String] = [:]
    private(set) var running: DemoScenarioID?
    private(set) var runningAll = false

    var isBusy: Bool { running != nil || runningAll }
    var passedCount: Int { results.count }
    var summary: String {
        if isBusy { return "正在验证执行链…" }
        if !errors.isEmpty { return "\(errors.count) 项待检查" }
        if passedCount == DemoScenarioID.allCases.count { return "7 / 7 场景通过" }
        return "\(passedCount) / 7 已验证"
    }

    func run(_ scenario: DemoScenarioID) async {
        guard !isBusy else { return }
        await execute(scenario)
    }

    func runAll() async {
        guard !isBusy else { return }
        runningAll = true
        defer { runningAll = false }
        for scenario in DemoScenarioID.allCases {
            guard !Task.isCancelled else { break }
            await execute(scenario)
        }
    }

    private func execute(_ scenario: DemoScenarioID) async {
        running = scenario
        results[scenario] = nil
        errors[scenario] = nil
        defer { running = nil }
        do { results[scenario] = try await DemoScenarios.run(scenario) }
        catch is CancellationError { errors[scenario] = "本次验证已取消，可以重新运行。" }
        catch { errors[scenario] = "验证未通过：\(String(describing: error))" }
    }
}
