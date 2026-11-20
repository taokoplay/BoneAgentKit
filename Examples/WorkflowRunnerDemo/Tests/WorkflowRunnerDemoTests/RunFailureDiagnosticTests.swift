import Foundation
import Testing
import BoneAgentKit
@testable import WorkflowRunnerDemo

struct RunFailureDiagnosticTests {
    struct BudgetCase: Sendable {
        let error: BoneRunBudgetError
        let expected: DemoRunFailureDiagnostic.Code
    }
    @Test(arguments: [
        BudgetCase(error: .inferenceCallLimitReached(limit: 6), expected: .inferenceCalls),
        BudgetCase(error: .toolCallLimitReached(limit: 8), expected: .toolCalls),
        BudgetCase(error: .inputByteLimitReached(limit: 512_000), expected: .inputBytes),
        BudgetCase(error: .outputByteLimitReached(limit: 256_000), expected: .outputBytes),
        BudgetCase(error: .turnLimitReached(limit: 6), expected: .turns),
        BudgetCase(error: .wallClockLimitReached, expected: .duration),
        BudgetCase(error: .concurrencyLimitReached(limit: 1), expected: .concurrency),
        BudgetCase(error: .estimatedCostLimitReached(limit: 0), expected: .cost)
    ])
    func budgetReasonsRemainDistinct(value: BudgetCase) {
        let record = makeRecord(error: value.error)
        #expect(record.code == value.expected)
        #expect(record.inferenceResponses == 2 && record.completedTools == 1 && record.networkConfirmations == 1)
        #expect(record.isValid && !record.message.isEmpty)
    }

    @Test func outputTruncationContextFailureAndStepLoopHaveDifferentRemedies() {
        let output = makeRecord(error: BoneInferenceTransportError.outputTruncated)
        let context = makeRecord(error: BoneAgentError.contextManagementFailed)
        let loop = makeRecord(error: BoneAgentError.stepLimitReached)
        #expect(output.code == .outputTruncated && output.message.contains("1024 Token"))
        #expect(context.code == .contextManagement && context.message.contains("上下文"))
        #expect(loop.code == .inferenceSteps && loop.message.contains("6 次"))
        #expect(Set([output.code, context.code, loop.code]).count == 3)
    }

    @Test func providerDiagnosticSurvivesFlatteningAndCancellationKeepsPriority() {
        let original = BoneAgentError.inferenceFailed
        let truncated = makeRecord(error: original, diagnostic: .outputTruncated)
        #expect(truncated.code == .outputTruncated)
        let cancelled = makeRecord(error: original, failure: .cancelled, diagnostic: .outputTruncated)
        #expect(cancelled.code == .cancelled)
    }

    @Test func safeFileHistorySurvivesNewStoreAndKeepsOnlyLatestTwenty() async throws {
        let directory = testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DemoFailureLogStore(directory: directory)
        let first = makeRecord(error: BoneAgentError.stepLimitReached)
        try await store.record(first)
        for _ in 0..<21 { try await store.record(makeRecord(error: BoneInferenceTransportError.outputTruncated)) }
        let reloaded = try await DemoFailureLogStore(directory: directory).records()
        #expect(reloaded.count == 20)
        #expect(!reloaded.contains { $0.id == first.id })
        #expect(reloaded.allSatisfy { $0.code == .outputTruncated && $0.isValid })
        let values = try directory.appendingPathComponent("failures.json").resourceValues(forKeys: [.fileSizeKey])
        #expect((values.fileSize ?? .max) <= DemoFailureLogStore.maximumBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("failures.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func arbitraryUpstreamPayloadAndIdentityCannotEnterFileOrSharedText() async throws {
        let directory = testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "SECRET-UPSTREAM-KEY-QUESTION-URL"
        let error = NSError(domain: marker, code: 123, userInfo: [NSLocalizedDescriptionKey: marker])
        let tool = try #require(DemoToolFailure.classify(error, toolID: marker))
        let record = DemoRunFailureDiagnostic(error: error, failure: .toolFailed, inferenceDiagnostic: nil,
            inferenceResponses: 1, toolPreparations: 1, completedTools: 0,
            networkConfirmations: 1, maximumReplyTokens: 1024, tool: tool)
        let store = DemoFailureLogStore(directory: directory)
        try await store.record(record)
        let data = try Data(contentsOf: directory.appendingPathComponent("failures.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains(marker))
        #expect(!record.text.contains(marker))
        #expect(record.tool?.tool == nil && record.tool?.reason == .unknown)
        let reloaded = try await store.records()
        #expect(reloaded == [record])
    }

    @Test func oversizedAndCorruptDiagnosticFilesAreRejected() async throws {
        let directory = testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("failures.json")
        let store = DemoFailureLogStore(directory: directory)
        try Data(repeating: 32, count: DemoFailureLogStore.maximumBytes + 1).write(to: file)
        await #expect(throws: DemoFailureLogError.self) { try await store.records() }
        try Data("invalid".utf8).write(to: file)
        await #expect(throws: DemoFailureLogError.self) { try await store.records() }
    }

    private func makeRecord(error: any Error, failure: DemoLiveChatFailure = .limitReached,
                            diagnostic: BoneAgentInferenceFailureDiagnostic? = nil) -> DemoRunFailureDiagnostic {
        .init(error: error, failure: failure, inferenceDiagnostic: diagnostic,
            inferenceResponses: 2, toolPreparations: 1, completedTools: 1,
            networkConfirmations: 1, maximumReplyTokens: 1024, tool: nil)
    }
    private func testDirectory() -> URL {
        let root = ProcessInfo.processInfo.environment["PI_SCRATCH_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("run-diagnostics-test-" + UUID().uuidString, isDirectory: true)
    }
}
