import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct Options {
    var scenario = Scenario.compressed
    var values = [17, 23, 60]
    var selfTest = false
    var json = false
    var help = false
    var reportPath: String?

    init(_ arguments: [String]) throws {
        var index = 0
        var seen = Set<String>()
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw DemoFailure.invalidArguments }
            index += 1
            switch flag {
            case "--self-test": selfTest = true
            case "--json": json = true
            case "--help", "-h": help = true
            case "--scenario", "--values", "--report":
                guard index < arguments.count else { throw DemoFailure.invalidArguments }
                let value = arguments[index]
                index += 1
                switch flag {
                case "--scenario":
                    guard let parsed = Scenario(rawValue: value) else { throw DemoFailure.invalidArguments }
                    scenario = parsed
                case "--values":
                    let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
                    guard (1...32).contains(pieces.count) else { throw DemoFailure.invalidArguments }
                    values = try pieces.map {
                        guard let number = Int($0.trimmingCharacters(in: .whitespaces)), (-100_000...100_000).contains(number) else {
                            throw DemoFailure.invalidArguments
                        }
                        return number
                    }
                default:
                    guard !value.isEmpty else { throw DemoFailure.invalidArguments }
                    reportPath = value
                }
            default: throw DemoFailure.invalidArguments
            }
        }
        guard !(selfTest && seen.contains("--scenario")) else { throw DemoFailure.invalidArguments }
    }
}

@main
struct ResourceReadingDemo {
    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help { print(usage); return }
            var results: [ScenarioReport] = []
            for scenario in options.selfTest ? Scenario.allCases : [options.scenario] {
                results.append(try await runScenario(scenario, values: options.values))
            }
            let report = RunReport(scenarios: results)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let path = options.reportPath {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // 报告只写用户显式指定的新文件，不覆盖原文件。
                try data.write(to: url, options: .withoutOverwriting)
            }
            if options.json { print(String(decoding: data, as: UTF8.self)) }
            else {
                print("BoneAgentKit 资源回读 Demo · 离线脚本模型 · 无联网/无费用")
                for result in results { show(result) }
                print("\n行为验收：\(results.filter(\.passed).count)/\(results.count) 通过（拒绝/阻止不计为任务交付成功）")
                if let path = options.reportPath { print("JSON 报告：\(path)") }
                print("此 Demo 验证执行与校验链，不证明真实模型的自主规划能力。")
            }
            guard report.allChecksPassed else { exit(1) }
            // 批量模式按预期行为验收；单场景模式同时用退出码表达任务结局。
            if !options.selfTest {
                switch results[0].taskOutcome {
                case "rejected": exit(2)
                case "blocked": exit(3)
                default: break
                }
            }
        } catch DemoFailure.invalidArguments {
            writeError("参数无效。\n" + usage)
            exit(64)
        } catch {
            writeError("Demo 未完成：初始化、运行或报告写入失败；已有报告不会覆盖。")
            exit(1)
        }
    }

    private static func show(_ result: ScenarioReport) {
        print("\n[\(result.scenario.rawValue)]")
        for (index, step) in result.trace.enumerated() { print("  \(index + 1). \(step)") }
        print("  原文 \(result.sourceUTF8Bytes) B → 预览 \(result.reads.previewBytes) B；实际回读 \(result.reads.returnedBytes) B")
        print("  业务推理 \(result.businessInferenceCalls) 次，摘要 \(result.summaryInferenceCalls) 次，回读成功 \(result.reads.successfulReads)/\(result.reads.readAttempts)")
        print("  预期合计 \(result.expectedTotal)，实际 \(result.actualTotal.map(String.init) ?? "无")；任务状态 \(result.taskOutcome)")
        print("  行为验收：\(result.passed ? "PASS" : "FAIL")")
        for check in result.checks where !check.passed { print("    未通过：\(check.name)") }
    }
    private static func writeError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    private static let usage = """
    用法：ResourceReadingDemo [--scenario 名称 | --self-test] [--values 整数列表] [--json] [--report 新文件路径]
      场景：preview、compressed（默认）、expired、denied、wrong-answer、lost-reference
      --values 示例：17,23,60；1～32 个整数，每个在 -100000～100000 之间
      --self-test 运行全部六个场景；按预期拒绝/停止也属于行为验收通过
      --json 输出可自动核对的 JSON；不混入人类可读步骤
      --report 将相同报告写入新文件，已有文件不会覆盖
      退出码：0 交付成功或批量行为验收通过；1 检查/运行失败；2 单场景答案被拒绝；3 单场景被阻止；64 参数错误
    """
}
