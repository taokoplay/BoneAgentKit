import Foundation
import Testing
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct LiveValidationTests {
    @Test func connectionUsesSharedModelInstructionsAndRejectsWrongAnswer() async throws {
        let settings = validationSettings()
        let probe = ValidationHTTPProbe(.text("任意回答"))
        let request = DemoValidationRequest(kind: .connection, settings: settings, input: DemoValidationKind.connection.task, expectedText: "")
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey, transport: validationTransport(probe))
        #expect(report.verdict == .failed)
        #expect(report.statistics.stepCount == 1)
        #expect(report.statistics.tokens.knownUsage?.inputTokens == 13)
        let body = try #require(await probe.bodies.first)
        #expect(body.model == settings.modelID)
        #expect(body.system == settings.systemPrompt)
        #expect(report.request.settings == settings)
        #expect(!report.text.contains(validationKey))
    }

    @Test func connectionPassesOnlyExactExpectedAnswer() async throws {
        let request = DemoValidationRequest(kind: .connection, settings: validationSettings(), input: DemoValidationKind.connection.task, expectedText: "")
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey,
            transport: validationTransport(ValidationHTTPProbe(.text("连接正常"))))
        #expect(report.verdict == .passed)
        #expect(report.checks.allSatisfy { $0.passed })
    }

    @Test(arguments: [("17*23", true), ("17*24", false)])
    func calculatorRequiresActualCorrectToolResult(expression: String, expectedPass: Bool) async throws {
        var settings = validationSettings(); settings.enablesCalculator = true
        let probe = ValidationHTTPProbe(.calculator(expression: expression, answer: "计算结果是 391。"))
        let request = DemoValidationRequest(kind: .calculator, settings: settings, input: DemoValidationKind.calculator.task, expectedText: "")
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey, transport: validationTransport(probe))
        #expect((report.verdict == .passed) == expectedPass)
        #expect(report.statistics.stepCount == 2)
        #expect(report.statistics.toolCallCount == 1)
        #expect(report.replies.last?.calculatorValues == [expectedPass ? 391 : 408])
        let bodies = await probe.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0].hasCalculator)
        #expect(bodies[1].toolResultValue == (expectedPass ? 391 : 408))
    }

    @Test func calculatorAnswerWithoutToolExecutionCannotPass() async throws {
        var settings = validationSettings(); settings.enablesCalculator = true
        let request = DemoValidationRequest(kind: .calculator, settings: settings, input: DemoValidationKind.calculator.task, expectedText: "")
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey,
            transport: validationTransport(ValidationHTTPProbe(.text("391"))))
        #expect(report.verdict == .failed)
        #expect(report.checks.first?.passed == false)
        #expect(report.statistics.toolCallCount == 0)
    }

    @Test(arguments: [("391,000", false), ("391，000", false), ("1,391", false), ("3910", false),
                      ("-391", false), ("391.25", false), ("计算完成，391", true), ("391，结果已确认。", true)])
    func calculatorChecksAWholeNumber(answer: String, expectedPass: Bool) async throws {
        var settings = validationSettings(); settings.enablesCalculator = true
        let request = DemoValidationRequest(kind: .calculator, settings: settings, input: DemoValidationKind.calculator.task, expectedText: "")
        let probe = ValidationHTTPProbe(.calculator(expression: "17*23", answer: answer))
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey, transport: validationTransport(probe))
        #expect((report.verdict == .passed) == expectedPass)
        #expect(report.checks[0].passed)
        #expect(report.checks[1].passed == expectedPass)
    }

    @Test func memoryMakesTwoActualRequestsAndSecondUsesConversationHistory() async throws {
        let request = DemoValidationRequest(kind: .memory, settings: validationSettings(), input: DemoValidationKind.memory.task, expectedText: "")
        let probe = ValidationHTTPProbe(.memory)
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey, transport: validationTransport(probe))
        #expect(report.verdict == .passed)
        #expect(report.statistics.roundCount == 2)
        #expect(report.statistics.stepCount == 2)
        #expect(report.inputs.count == 2)
        #expect(!report.inputs[1].contains(report.finalText))
        let bodies = await probe.bodies
        #expect(bodies[1].roles == ["system", "user", "assistant", "user"])
        #expect(bodies[1].firstUser == report.inputs[0])
        #expect(bodies[1].lastUser == request.input)
    }

    @Test(arguments: ["", "期望文字", "不会出现的文字"])
    func instructionCheckDistinguishesReviewPassAndFailure(expected: String) async throws {
        let request = DemoValidationRequest(kind: .instructions, settings: validationSettings(), input: "请介绍自己", expectedText: expected)
        let report = try await DemoLiveValidation.run(request, apiKey: validationKey,
            transport: validationTransport(ValidationHTTPProbe(.text("这是期望文字。"))))
        let verdict: DemoValidationVerdict = expected.isEmpty ? .needsReview : (expected == "期望文字" ? .passed : .failed)
        #expect(report.verdict == verdict)
    }

    @Test func missingCalculatorIsRejectedBeforeDispatch() async throws {
        let probe = ValidationHTTPProbe(.text("391"))
        let request = DemoValidationRequest(kind: .calculator, settings: validationSettings(), input: DemoValidationKind.calculator.task, expectedText: "")
        do {
            _ = try await DemoLiveValidation.run(request, apiKey: validationKey, transport: validationTransport(probe))
            Issue.record("An unavailable calculator was accepted")
        } catch let error as DemoValidationError { #expect(error == .missingCalculator) }
        #expect(await probe.bodies.isEmpty)
    }

    @Test func providerFailureDoesNotFallBackToSyntheticSuccess() async throws {
        let probe = ValidationHTTPProbe(.failure)
        let request = DemoValidationRequest(kind: .connection, settings: validationSettings(), input: DemoValidationKind.connection.task, expectedText: "")
        do {
            _ = try await DemoLiveValidation.run(request, apiKey: validationKey, transport: validationTransport(probe))
            Issue.record("Provider failure unexpectedly returned a report")
        } catch let error as DemoLiveChatFailure {
            #expect(error == .authentication)
            #expect(!error.message.contains(validationKey))
        }
        #expect(await probe.bodies.count == 1)
    }
}

private let validationKey = "unit-test-validation-key-not-real"
private func validationSettings() -> DemoLiveChatSettings {
    var settings = DemoLiveChatSettings()
    settings.provider = .customOpenAI
    settings.baseURL = "https://validation.invalid"
    settings.modelID = "manual-validation-model"
    settings.systemPrompt = "用简短中文回答。保留这段共享助手说明。"
    settings.usesStreaming = false
    settings.managesContext = false
    return settings
}
private func validationTransport(_ probe: ValidationHTTPProbe) -> BoneInferenceURLSessionTransport {
    .init(loader: { request in try await probe.load(request) }, sleeper: { _ in throw CancellationError() })
}

private actor ValidationHTTPProbe {
    enum Mode: Sendable { case text(String), calculator(expression: String, answer: String), memory, failure }
    struct Body: Sendable {
        let model: String?
        let system: String?
        let roles: [String]
        let firstUser: String?
        let lastUser: String?
        let hasCalculator: Bool
        let toolResultValue: Double?
    }
    let mode: Mode
    private(set) var bodies: [Body] = []
    init(_ mode: Mode) { self.mode = mode }

    func load(_ request: URLRequest) throws -> (Data, BoneInferenceHTTPResponseMetadata) {
        let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let messages = object["messages"] as? [[String: Any]] ?? []
        let users = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        let tools = object["tools"] as? [[String: Any]] ?? []
        let result = messages.first { $0["role"] as? String == "tool" }?["content"] as? String
        let numeric = result.flatMap { try? JSONDecoder().decode(ValidationNumeric.self, from: Data($0.utf8)).value }
        bodies.append(.init(model: object["model"] as? String,
            system: messages.first { $0["role"] as? String == "system" }?["content"] as? String,
            roles: messages.compactMap { $0["role"] as? String }, firstUser: users.first, lastUser: users.last,
            hasCalculator: tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "math_calculate" },
            toolResultValue: numeric))
        if case .failure = mode {
            return (Data("{\"error\":{\"message\":\"\(validationKey)\"}}".utf8), .init(statusCode: 401))
        }
        let message: [String: Any]
        let finish: String
        switch mode {
        case .calculator(let expression, _) where bodies.count == 1:
            let arguments = String(decoding: try JSONEncoder().encode(ValidationExpression(expression: expression)), as: UTF8.self)
            message = ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "validation-calc", "type": "function",
                "function": ["name": "math_calculate", "arguments": arguments]]]]
            finish = "tool_calls"
        default:
            let text: String
            switch mode {
            case .text(let value): text = value
            case .calculator(_, let answer): text = answer
            case .memory:
                let first = users.first ?? ""
                let range = first.range(of: #"[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}"#, options: .regularExpression)
                text = bodies.count == 1 ? "已记住" : range.map { String(first[$0]) } ?? "没有编号"
            case .failure: text = "unreachable"
            }
            message = ["role": "assistant", "content": text]
            finish = "stop"
        }
        let response: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": finish]],
            "usage": ["prompt_tokens": 13, "completion_tokens": 4, "total_tokens": 17]]
        return (try JSONSerialization.data(withJSONObject: response), .init(statusCode: 200, headers: ["Content-Type": "application/json"]))
    }
}
private struct ValidationNumeric: Decodable { let value: Double }
private struct ValidationExpression: Encodable { let expression: String }

struct LiveValidationCancellationTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellationAfterFinalResponseCannotPublishAPassingReport() async throws {
        let gate = ValidationCompletionGate()
        let request = DemoValidationRequest(kind: .connection, settings: validationSettings(),
                                            input: DemoValidationKind.connection.task, expectedText: "")
        let operation = Task {
            try await DemoLiveValidation.run(request, apiKey: validationKey,
                transport: validationTransport(ValidationHTTPProbe(.text("连接正常"))), observer: { update in
                    if case .tokens(let snapshot) = update, snapshot.terminalState == .succeeded {
                        await gate.pauseOnce()
                    }
                })
        }
        await gate.waitUntilPaused()
        operation.cancel()
        await gate.release()
        do {
            _ = try await operation.value
            Issue.record("A cancelled test returned a report")
        } catch is CancellationError {
        } catch let failure as DemoLiveChatFailure {
            #expect(failure == .cancelled)
        }
    }
}

private actor ValidationCompletionGate {
    private var hasPaused = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pauseOnce() async {
        guard !hasPaused else { return }
        hasPaused = true
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
        await withCheckedContinuation { next in
            if isReleased { next.resume() } else { continuation = next }
        }
    }
    func waitUntilPaused() async {
        if hasPaused { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
