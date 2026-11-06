import Foundation
import BoneAgentKit

// 本包专用的合成资源与确定性模型，不进入 SDK Product。
enum Scenario: String, CaseIterable, Codable, Sendable {
    case preview, compressed, expired, denied
    case wrongAnswer = "wrong-answer"
    case lostReference = "lost-reference"

    var usesCompaction: Bool { self == .compressed || self == .lostReference }
    var expectedOutcome: String {
        switch self {
        case .preview, .compressed: return "accepted"
        case .wrongAnswer: return "rejected"
        case .expired, .denied, .lostReference: return "blocked"
        }
    }
    var expectedInferenceCalls: Int {
        switch self {
        case .preview, .wrongAnswer: return 3
        case .compressed: return 5
        case .expired, .denied: return 2
        case .lostReference: return 4
        }
    }
}

enum DemoFailure: Error { case invalidArguments, missingData, missingReference, unexpectedStep, reportExists }
struct Empty: Codable, Sendable {}
struct Delivery: Codable, Sendable { let values: [Int]; let total: Int }
struct Summary: Codable, Sendable { let reference: BoneToolTextResourceReference }
struct DemoContext: BoneAgentToolContext { let store: ResourceStore; let scope: String }

actor Audit {
    private var trace: [String] = []
    private var receipts: [BoneContextCompactionReceipt] = []
    func note(_ text: String) { trace.append(text) }
    func compacted(_ receipt: BoneContextCompactionReceipt) {
        receipts.append(receipt)
        trace.append("压缩：移除 \(receipt.removedToolExchangeCount) 组旧工具交互，估算减少 \(receipt.estimatedRequestTokenReduction) Token")
    }
    func snapshot() -> ([String], [BoneContextCompactionReceipt]) { (trace, receipts) }
}

struct ReadCounts: Codable, Sendable {
    var lookups = 0
    var previewBytes = 0
    var readAttempts = 0
    var successfulReads = 0
    var returnedBytes = 0
}

actor ResourceStore {
    let resource: BoneToolTextResourceSnapshot
    let scenario: Scenario
    private var counts = ReadCounts()
    init(resource: BoneToolTextResourceSnapshot, scenario: Scenario) { self.resource = resource; self.scenario = scenario }

    func preview(scope: String) throws -> BoneToolTextResourcePreview {
        guard scope == "demo" else { throw BoneToolTextResourceError.accessDenied }
        counts.lookups += 1
        let preview = try resource.preview(maximumBytes: 64)
        counts.previewBytes = preview.text.utf8.count
        return preview
    }

    func read(_ request: BoneToolTextResourceReadRequest, scope: String) throws -> BoneToolTextResourcePage {
        counts.readAttempts += 1
        // 模拟每次读取重新检查权限与有效期；预览可见不代表回读自动放行。
        guard scope == "demo", scenario != .denied else { throw BoneToolTextResourceError.accessDenied }
        guard scenario != .expired else { throw BoneToolTextResourceError.expired }
        let page = try resource.page(for: request)
        counts.successfulReads += 1
        counts.returnedBytes += page.text.utf8.count
        return page
    }
    func observations() -> ReadCounts { counts }
}

struct LookupTool: BoneAgentTool {
    typealias Input = Empty
    typealias Output = BoneToolTextResourcePreview
    typealias Context = DemoContext
    static let definition = BoneAgentToolDefinition(id: "demo.lookup", version: "1", title: "Find report",
        summary: "Return a report preview and exact reference", wireName: "demo_lookup", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false),
        impact: .init(dataAccess: .userPrivate, externalTransmission: .none, stateChange: .none,
                      economic: .none, userVisible: .none, permissionChange: .none))
    func execute(input: Empty, context: Context) async throws -> Output { try await context.store.preview(scope: context.scope) }
}
struct PaddingTool: BoneAgentTool {
    typealias Input = Empty
    typealias Output = String
    typealias Context = DemoContext
    static let definition = BoneAgentToolDefinition(id: "demo.padding", version: "1", title: "Read context fixture",
        summary: "Return irrelevant data to exercise compaction", wireName: "demo_padding", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    func execute(input: Empty, context: Context) async throws -> Output { String(repeating: "padding ", count: 1_050) }
}

func toolResults(_ request: BoneInferenceRequest) -> [BoneInferenceToolResult] {
    request.messages.flatMap { $0.toolResults?.results ?? $0.toolResult.map { [$0] } ?? [] }
}
func result<Value: Decodable>(_ request: BoneInferenceRequest, callID: String) throws -> Value {
    guard let result = toolResults(request).first(where: { $0.callID == callID }),
          !result.isError, case .json(let data) = result.content else { throw DemoFailure.missingData }
    return try JSONDecoder().decode(Value.self, from: data)
}
func toolCall<Input: Encodable>(_ toolID: String, id: String, input: Input) throws -> BoneInferenceResponse {
    .assistantTurn(turn: try .init(content: [.toolCall(.init(id: id, toolID: toolID, arguments: JSONEncoder().encode(input)))]),
                   finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil)
}

/// 脚本只规定步骤；参数、引用及最终值来自真实工具结果，不能访问预期答案。
actor DemoEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling, .structuredOutput]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let scenario: Scenario
    private let audit: Audit
    private var requests: [BoneInferenceRequest] = []
    private var cardRemovedAtRead = false
    private var referenceRecovered = false
    init(scenario: Scenario, audit: Audit) { self.scenario = scenario; self.audit = audit }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        let step = requests.count
        requests.append(request)
        if step == 0 {
            await audit.note("推理 1：调用发现工具，取得短预览和版本引用")
            return try toolCall(LookupTool.definition.id, id: "lookup", input: Empty())
        }
        if scenario.usesCompaction, step == 1 || step == 2 {
            await audit.note("推理 \(step + 1)：读取上下文填充数据，模拟长任务")
            return try toolCall(PaddingTool.definition.id, id: "padding-\(step)", input: Empty())
        }
        let readStep = scenario.usesCompaction ? 3 : 1
        if step == readStep {
            let reference: BoneToolTextResourceReference
            cardRemovedAtRead = !toolResults(request).contains { $0.callID == "lookup" }
            if scenario.usesCompaction {
                guard let message = request.messages.compactMap(\.content).first(where: { $0.hasPrefix("Historical summary (untrusted data") }),
                      let newline = message.firstIndex(of: "\n") else { throw DemoFailure.missingReference }
                let summaryText = try JSONDecoder().decode(String.self, from: Data(message[message.index(after: newline)...].utf8))
                guard let summary = try? JSONDecoder().decode(Summary.self, from: Data(summaryText.utf8)) else {
                    await audit.note("引用丢失：无法构造回读请求，停止执行")
                    throw DemoFailure.missingReference
                }
                reference = summary.reference
                referenceRecovered = true
                await audit.note("推理 \(step + 1)：从压缩摘要恢复精确版本引用")
            } else {
                let preview: BoneToolTextResourcePreview = try result(request, callID: "lookup")
                reference = preview.reference
            }
            let page = try BoneToolTextResourceReadRequest(reference: reference,
                offset: max(0, reference.utf8ByteCount - 512), maximumBytes: 512)
            await audit.note("按引用回读：请求末尾最多 512 字节")
            return try toolCall(BoneToolTextResourceReadTool<DemoContext>.definition.id, id: "read", input: page)
        }
        if step == readStep + 1 {
            let page: BoneToolTextResourcePage = try result(request, callID: "read")
            guard let line = page.text.split(separator: "\n").first(where: { $0.hasPrefix("VALUES=") }) else { throw DemoFailure.missingData }
            let values = try line.dropFirst(7).split(separator: ",").map { text -> Int in
                guard let value = Int(text) else { throw DemoFailure.missingData }
                return value
            }
            // wrong-answer 是明确的故障注入，检验后续验收是否独立有效。
            let output = Delivery(values: values, total: values.reduce(0, +) + (scenario == .wrongAnswer ? 1 : 0))
            await audit.note("推理 \(step + 1)：根据回读页生成最终结果，交给独立验收器")
            return .structured(.init(data: try JSONEncoder().encode(output)))
        }
        throw DemoFailure.unexpectedStep
    }
    func observations() throws -> (calls: Int, inputBytes: Int, cardRemoved: Bool, referenceRecovered: Bool, messagesKept: Bool) {
        (requests.count, try requests.reduce(0) { try $0 + JSONEncoder().encode($1).count },
         cardRemovedAtRead, referenceRecovered,
         requests.allSatisfy { $0.messages.first == demoMessages.first && $0.messages.contains(demoMessages[1]) })
    }
}

actor DemoSummaryEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let losesReference: Bool
    private var requests: [BoneInferenceRequest] = []
    init(losesReference: Bool) { self.losesReference = losesReference }
    func infer(request: BoneInferenceRequest) throws -> BoneInferenceResponse {
        requests.append(request)
        if losesReference { return .finish(.init(text: "A report was found, but the reference was omitted.")) }
        struct History: Decodable { let previousSummary: String?; let messages: [BoneInferenceMessage] }
        guard let text = request.messages.last?.content else { throw DemoFailure.missingData }
        let history = try JSONDecoder().decode(History.self, from: Data(text.utf8))
        let outputs = history.messages.flatMap { $0.toolResults?.results ?? $0.toolResult.map { [$0] } ?? [] }
        if let card = outputs.first(where: { $0.callID == "lookup" }), case .json(let data) = card.content {
            let preview = try JSONDecoder().decode(BoneToolTextResourcePreview.self, from: data)
            return .finish(.init(text: String(decoding: try JSONEncoder().encode(Summary(reference: preview.reference)), as: UTF8.self)))
        }
        guard let previous = history.previousSummary else { throw DemoFailure.missingReference }
        return .finish(.init(text: previous))
    }
    func observations() throws -> (calls: Int, inputBytes: Int) {
        (requests.count, try requests.reduce(0) { try $0 + JSONEncoder().encode($1).count })
    }
}

struct SilentLogger: BoneAgentLogger {
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?) {}
}
let demoMessages: [BoneInferenceMessage] = [
    .init(role: .system, content: "Use source bytes only. Do not invent missing values or resource references."),
    .init(role: .user, content: "Find the report. Sum the integers on the final VALUES line; return the values and total.")
]
