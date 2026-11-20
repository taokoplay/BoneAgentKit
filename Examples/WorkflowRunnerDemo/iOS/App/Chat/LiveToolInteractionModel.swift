import Foundation
import Observation
import Synchronization
import BoneAgentTools

@Observable
@MainActor
final class LiveToolInteractionModel {
    struct Pending: Identifiable, Sendable {
        enum Content: Sendable {
            case question(BoneUserQuestion)
            case authorization(DemoToolAuthorizationRequest)
            case pdfPassword(DemoPDFPasswordRequest)
        }

        let id: UUID
        let content: Content
    }

    private struct ActiveRequest: Sendable {
        let id: UUID
        let continuation: LiveToolInteractionContinuation
        let deadline: ContinuousClock.Instant
        let timeout: Task<Void, Never>
    }

    private(set) var pending: Pending?
    @ObservationIgnored private var active: ActiveRequest?

    var handlers: DemoToolInteractionHandlers {
        DemoToolInteractionHandlers(
            ask: { [weak self] question in
                guard let self else { throw CancellationError() }
                return try await self.ask(question)
            },
            authorize: { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.requestAuthorization(request)
            },
            requestPDFPassword: { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.requestPDFPassword(request)
            }
        )
    }

    func cancel(requestID: UUID? = nil) {
        guard let active, requestID == nil || requestID == active.id else { return }
        finish(.failure(CancellationError()), requestID: active.id)
    }

    func answer(_ answer: BoneUserAnswer, requestID: UUID) {
        guard let pending, pending.id == requestID,
              case .question(let question) = pending.content else { return }
        guard answer.status != .cancelled else {
            cancel(requestID: requestID)
            return
        }
        guard let validated = try? answer.validated(for: question) else { return }
        finish(.success(.answer(validated)), requestID: requestID)
    }

    func authorize(_ approved: Bool, requestID: UUID) {
        guard let pending, pending.id == requestID,
              case .authorization = pending.content else { return }
        finish(.success(.authorization(approved)), requestID: requestID)
    }

    /// 提交当前 PDF 密码，密码只在本次等待的内存 continuation 中传递。
    /// - Parameters:
    ///   - password: 用户输入的 PDF 密码。
    ///   - requestID: 当前密码请求身份。
    func submitPDFPassword(_ password: String, requestID: UUID) {
        guard let pending, pending.id == requestID,
              case .pdfPassword = pending.content, !password.isEmpty else { return }
        finish(.success(.pdfPassword(password)), requestID: requestID)
    }

    private func ask(_ question: BoneUserQuestion) async throws -> BoneUserAnswer {
        try question.validated()
        let response = try await wait(for: Pending(id: UUID(), content: .question(question)))
        guard case .answer(let answer) = response else { throw CancellationError() }
        return answer
    }

    private func requestAuthorization(_ request: DemoToolAuthorizationRequest) async throws -> Bool {
        // Every wait gets its own presentation identity, even if a caller reuses a request.
        let response = try await wait(for: Pending(id: UUID(), content: .authorization(request)))
        guard case .authorization(let approved) = response else { throw CancellationError() }
        return approved
    }

    /// 展示 PDF 密码输入界面并返回一次性密码。
    /// - Parameter request: 不包含正文和密码的展示请求。
    /// - Returns: 当前调用使用的密码。
    private func requestPDFPassword(_ request: DemoPDFPasswordRequest) async throws -> String {
        let response = try await wait(for: Pending(id: UUID(), content: .pdfPassword(request)))
        guard case .pdfPassword(let password) = response else { throw CancellationError() }
        return password
    }

    private func wait(for request: Pending) async throws -> LiveToolInteractionResponse {
        try Task.checkCancellation()
        cancel()
        let continuation = LiveToolInteractionContinuation()
        defer {
            // An older waiter can finish after its replacement has already been installed.
            if active?.id == request.id {
                active?.timeout.cancel()
                active = nil
                pending = nil
            }
        }

        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { checked in
                guard continuation.install(checked) else { return }
                guard !Task.isCancelled else {
                    continuation.resolve(.failure(CancellationError()))
                    return
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.cancel(requestID: request.id)
                }
                active = ActiveRequest(id: request.id, continuation: continuation,
                                       deadline: deadline, timeout: timeout)
                pending = request
                // Cancellation can race both continuation installation and publishing the sheet.
                if Task.isCancelled { cancel(requestID: request.id) }
            }
        } onCancel: {
            // This runs on any executor, including before the continuation is installed.
            continuation.resolve(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return response
    }

    private func finish(_ result: Result<LiveToolInteractionResponse, any Error>, requestID: UUID) {
        guard let active, active.id == requestID else { return }
        self.active = nil
        pending = nil
        active.timeout.cancel()
        // Also reject late UI input if the main actor could not run the timeout promptly.
        let boundedResult: Result<LiveToolInteractionResponse, any Error> =
            ContinuousClock.now < active.deadline ? result : .failure(CancellationError())
        active.continuation.resolve(boundedResult)
    }

    deinit {
        active?.timeout.cancel()
        active?.continuation.resolve(.failure(CancellationError()))
    }
}

private enum LiveToolInteractionResponse: Sendable {
    case answer(BoneUserAnswer)
    case authorization(Bool)
    case pdfPassword(String)
}

/// The lock protects cancellation before/after installation and guarantees one resume.
private nonisolated final class LiveToolInteractionContinuation: Sendable {
    private struct State {
        var continuation: CheckedContinuation<LiveToolInteractionResponse, any Error>?
        var result: Result<LiveToolInteractionResponse, any Error>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<LiveToolInteractionResponse, any Error>) -> Bool {
        let earlyResult = state.withLock { state -> Result<LiveToolInteractionResponse, any Error>? in
            if let result = state.result { return result }
            precondition(state.continuation == nil)
            state.continuation = continuation
            return nil
        }
        if let earlyResult {
            continuation.resume(with: earlyResult)
            return false
        }
        return true
    }

    func resolve(_ result: Result<LiveToolInteractionResponse, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<LiveToolInteractionResponse, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}
