import Foundation
import Observation
import BoneAgentKit

@Observable @MainActor
final class LiveValidationModel {
    private(set) var isRunning = false
    private(set) var stopRequested = false
    private(set) var report: DemoValidationReport?
    private(set) var errorMessage: String?
    private(set) var frozenRequest: DemoValidationRequest?
    private(set) var status: BoneAgentStatus?
    private(set) var tokenSnapshot: BoneAgentTokenSnapshot?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    var statusTitle: String {
        if stopRequested { return "正在停止测试…" }
        switch status?.phase {
        case .reasoning: return "模型正在思考…"
        case .generatingResponse: return "正在接收回答…"
        case .executingTools, .processingToolResults: return "正在使用工具…"
        default: return "正在请求模型…"
        }
    }

    func run(_ proposed: DemoValidationRequest, store: LiveChatSettingsStore, interactions: LiveToolInteractionModel,
             onFinished: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        report = nil
        frozenRequest = nil
        errorMessage = nil
        let request: DemoValidationRequest
        let key: String
        let searchKey: String
        do {
            request = try proposed.validated()
            key = try store.key(for: request.settings)
            _ = try request.settings.providerConfiguration(apiKey: key)
            searchKey = request.settings.enablesWebSearch ? try store.automaticSearchKey(for: request.settings) : ""
        } catch {
            errorMessage = Self.message(error)
            return
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        let isUITesting = store.isUITesting
        let transport: any BoneInferenceHTTPTransport = isUITesting
            ? LiveValidationUITestTransport(provider: request.settings.provider)
            : BoneInferenceURLSessionTransport()
        frozenRequest = request
        report = nil
        errorMessage = nil
        status = nil
        tokenSnapshot = nil
        stopRequested = false
        isRunning = true
        worker = Task {
            defer { isRunning = false; stopRequested = false; worker = nil; onFinished() }
            do {
                let completed = try await DemoLiveValidation.run(request, apiKey: key, transport: transport,
                    observer: { update in await self.receive(update, generation: currentGeneration) },
                    toolInteractions: interactions.handlers, searchAPIKey: searchKey,
                    webTransport: isUITesting ? LiveToolsUITestWebTransport() : nil)
                try Task.checkCancellation()
                guard !stopRequested, generation == currentGeneration else { throw CancellationError() }
                report = completed
            } catch { errorMessage = Self.message(error) }
        }
    }

    func stop(interactions: LiveToolInteractionModel) {
        guard isRunning, !stopRequested else { return }
        stopRequested = true
        interactions.cancel()
        worker?.cancel()
    }

    private func receive(_ update: DemoLiveChatUpdate, generation: UUID) {
        guard generation == self.generation, isRunning else { return }
        switch update {
        case .inferenceStarted, .textDelta: break
        case .status(let status): self.status = status; tokenSnapshot = status.tokens
        case .tokens(let snapshot): tokenSnapshot = snapshot
        case .contextCompacted, .contextFailure: break
        }
    }

    private static func message(_ error: Error) -> String {
        if error is CancellationError { return "测试已停止。不会自动重试。" }
        if let error = error as? DemoValidationError { return error.message }
        if let failure = error as? DemoLiveChatFailure {
            switch failure {
            case .cancelled: return "测试已停止。任务已保留，可以重新运行。"
            case .authentication: return "模型认证失败，请在设置里检查 API Key。"
            case .network: return "网络请求未完成，可稍后重新测试。"
            case .toolFailed: return "工具未完成，请检查工具选择或本次授权。"
            default: return failure.message
            }
        }
        if let error = error as? DemoChatConfigurationError { return error.message }
        if let error = error as? LiveChatKeychainError { return error.message }
        return "测试未完成，请检查设置后重新运行。"
    }
}
