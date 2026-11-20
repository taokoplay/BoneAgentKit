import Foundation
import BoneAgentKit
import BoneAgentTools

/// Real Provider / Conversation checks. No scripted engine or fallback is assembled here.
enum DemoValidationKind: String, CaseIterable, Identifiable, Sendable {
    case connection, calculator, memory, instructions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: "模型回复"
        case .calculator: "工具计算"
        case .memory: "连续对话"
        case .instructions: "助手说明"
        }
    }
    var symbol: String {
        switch self {
        case .connection: "bubble.left.and.text.bubble.right"
        case .calculator: "function"
        case .memory: "bubble.left.and.bubble.right"
        case .instructions: "text.bubble"
        }
    }
    var task: String {
        switch self {
        case .connection: "请确认收到这条测试请求。不要调用工具，只回复：连接正常"
        case .calculator: "请调用计算器计算 17 × 23，并在回答中写出计算结果。"
        case .memory: "刚才给你的校验编号是什么？请原样回复编号。"
        case .instructions: "请用一句话介绍你自己。"
        }
    }
    var explanation: String {
        switch self {
        case .connection: "检查模型是否只回复“连接正常”。"
        case .calculator: "检查计算器是否真的执行，并得到 391。"
        case .memory: "先发送随机编号，再检查模型能否在下一轮记住它。"
        case .instructions: "按当前助手说明回答；可填写回答中应包含的文字。"
        }
    }
}

struct DemoValidationRequest: Sendable {
    let kind: DemoValidationKind
    let settings: DemoLiveChatSettings
    let input: String
    let expectedText: String

    func validated() throws -> Self {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= DemoLiveChatSession.maximumUserMessageBytes,
              expected.utf8.count <= 1_024 else { throw DemoValidationError.invalidInput }
        let settings = try settings.validated()
        guard kind != .calculator || settings.enablesCalculator else { throw DemoValidationError.missingCalculator }
        return .init(kind: kind, settings: settings, input: input, expectedText: expected)
    }
}

enum DemoValidationError: Error, Sendable {
    case invalidInput, missingCalculator
    var message: String {
        switch self {
        case .invalidInput: "请检查任务和检查词的长度，再运行测试。"
        case .missingCalculator: "请先勾选计算器，再运行工具计算测试。"
        }
    }
}

enum DemoValidationVerdict: Sendable {
    case passed, failed, needsReview
    var title: String {
        switch self {
        case .passed: "检查通过"
        case .failed: "检查未通过"
        case .needsReview: "已完成，待你检查"
        }
    }
}

struct DemoValidationCheck: Identifiable, Sendable {
    let title: String
    let passed: Bool
    var id: String { title }
}

struct DemoValidationReport: Identifiable, Sendable {
    let id = UUID()
    let request: DemoValidationRequest
    let inputs: [String]
    let replies: [DemoLiveChatReply]
    let checks: [DemoValidationCheck]
    let verdict: DemoValidationVerdict
    let statistics: BoneAgentStatistics
    let elapsedSeconds: Double
    let completedAt: Date

    var finalText: String { replies.last?.text ?? "" }
    var text: String {
        var lines = [
            "\(request.kind.title) · \(verdict.title)",
            "模型：\(request.settings.provider.title) / \(request.settings.modelID)",
            "完成时间：\(completedAt.formatted())",
            "模型调用：\(statistics.stepCount)，工具调用：\(statistics.toolCallCount)",
            "耗时：\(elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) 秒",
            "", "助手说明：", request.settings.systemPrompt
        ]
        if !request.expectedText.isEmpty { lines += ["", "检查词：\(request.expectedText)"] }
        lines += ["", "检查结果："] + checks.map { "\($0.passed ? "通过" : "未通过") · \($0.title)" }
        for (index, input) in inputs.enumerated() {
            lines += ["", "第 \(index + 1) 轮请求：", input]
            if replies.indices.contains(index) { lines += ["回答：", replies[index].text] }
        }
        if let usage = statistics.tokens.knownUsage {
            lines += ["", "服务商已上报用量：输入 \(usage.inputTokens)，输出 \(usage.outputTokens)",
                      "用量覆盖：\(statistics.tokens.reportedResponseCount) / \(statistics.tokens.requestCount) 次请求"]
        } else { lines += ["", "服务商未提供 Token 用量。"] }
        if verdict == .needsReview { lines += ["未填写检查词，请对照助手说明检查回答是否符合要求。"] }
        return lines.joined(separator: "\n")
    }
}

struct DemoLiveValidation {
    static func run(
        _ proposed: DemoValidationRequest,
        apiKey: String,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport(),
        observer: @escaping DemoLiveChatObserver = { _ in },
        toolInteractions: DemoToolInteractionHandlers = .unavailable,
        searchAPIKey: String = "",
        webTransport: (any BoneWebHTTPTransport)? = nil
    ) async throws -> DemoValidationReport {
        let request = try proposed.validated()
        let started = ContinuousClock.now
        let session = try await DemoLiveChatSession.make(
            settings: request.settings, apiKey: apiKey, transport: transport, observer: observer,
            toolInteractions: toolInteractions, searchAPIKey: searchAPIKey, webTransport: webTransport
        )
        try Task.checkCancellation()
        var inputs: [String] = []
        var replies: [DemoLiveChatReply] = []
        var memoryCode: String?
        if request.kind == .memory {
            let code = UUID().uuidString
            memoryCode = code
            let first = "请记住本次校验编号：\(code)。下一轮会询问这个编号。本轮只需回复“已记住”。"
            inputs.append(first)
            replies.append(try await session.send(first))
            try Task.checkCancellation()
        }
        inputs.append(request.input)
        replies.append(try await session.send(request.input))
        try Task.checkCancellation()
        let statistics = await session.statistics()
        try Task.checkCancellation()
        let checks = evaluate(request: request, replies: replies, memoryCode: memoryCode)
        let verdict: DemoValidationVerdict
        if request.kind == .instructions && request.expectedText.isEmpty { verdict = .needsReview }
        else { verdict = checks.allSatisfy(\.passed) ? .passed : .failed }
        let duration = started.duration(to: .now).components
        try Task.checkCancellation()
        return .init(request: request, inputs: inputs, replies: replies, checks: checks, verdict: verdict,
                     statistics: statistics, elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                     completedAt: .now)
    }

    static func evaluate(request: DemoValidationRequest, replies: [DemoLiveChatReply], memoryCode: String?) -> [DemoValidationCheck] {
        let answer = replies.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch request.kind {
        case .connection:
            return [.init(title: "只回复“连接正常”", passed: answer == "连接正常")]
        case .calculator:
            let values = replies.flatMap(\.calculatorValues)
            let hasAnswer = answer.range(of: #"(?<![\p{N}.+\-])(?<![\p{N}][,，])391(?:\.0+)?(?![\p{N}.]|[,，][\p{N}])"#, options: .regularExpression) != nil
            return [.init(title: "计算器实际返回 391", passed: values.contains(391)),
                    .init(title: "回答中包含正确结果 391", passed: hasAnswer)]
        case .memory:
            return [.init(title: "完成两轮模型请求", passed: replies.count == 2),
                    .init(title: "第二轮回答包含本次随机编号", passed: memoryCode.map { answer.contains($0) } ?? false)]
        case .instructions:
            if request.expectedText.isEmpty { return [.init(title: "已收到模型回答", passed: !answer.isEmpty)] }
            return [.init(title: "回答包含“\(request.expectedText)”", passed: answer.contains(request.expectedText))]
        }
    }
}
