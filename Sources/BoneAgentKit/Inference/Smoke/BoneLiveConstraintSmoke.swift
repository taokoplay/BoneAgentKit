import Dispatch
import Foundation

/// 真实 Provider Constraint Smoke 的执行器。场景使用固定、无副作用输入，报告不包含模型正文。
public enum BoneLiveConstraintSmoke {
    public static func run(
        provider: BoneInferenceProviderKind,
        modelID: String,
        invocation: BoneInferenceInvocationMode,
        engine: any BoneInferenceEngine,
        identity: BoneProviderCapabilityVerificationIdentity,
        iterations: Int
    ) async throws -> BoneLiveConstraintSmokeReport {
        guard (1...1_000).contains(iterations) else {
            throw BoneInferenceError.invalidGenerationOptions
        }
        let startNanoseconds = DispatchTime.now().uptimeNanoseconds
        var succeeded = 0
        var failures: [BoneLiveConstraintSmokeFailure: Int] = [:]

        for _ in 0..<iterations {
            try Task.checkCancellation()
            let request = BoneInferenceRequest(
                modelID: modelID,
                messages: [.init(role: .user, content: "Return the allowed decision value for this synthetic smoke test.")],
                generationOptions: .init(maximumOutputTokens: 64),
                outputConstraint: .enumChoice(["pass", "fail"])
            )
            do {
                let response: BoneInferenceResponse
                switch invocation {
                case .nonStreaming:
                    response = try await engine.infer(request: request)
                case .streaming:
                    guard let streaming = engine as? any BoneInferenceBufferedStreaming else {
                        throw BoneInferenceError.unsupportedCapability(.streaming)
                    }
                    response = try await streaming.inferUsingStream(request: request, options: .init())
                }
                guard case let .finish(value) = response,
                      ["pass", "fail"].contains(value.text) else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                succeeded += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[classify(error), default: 0] += 1
            }
        }

        let endNanoseconds = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = endNanoseconds >= startNanoseconds
            ? endNanoseconds - startNanoseconds
            : 0
        let milliseconds = Int(min(elapsedNanoseconds / 1_000_000, UInt64(Int.max)))
        return try .init(
            provider: provider,
            modelID: modelID,
            invocation: invocation,
            identity: identity,
            attemptedCount: iterations,
            succeededCount: succeeded,
            failureCounts: failures,
            durationMilliseconds: milliseconds,
            verifiedAt: utcDateString()
        )
    }

    private static func classify(_ error: Error) -> BoneLiveConstraintSmokeFailure {
        if let error = error as? BoneInferenceError {
            switch error {
            case .unsupportedCapability: return .unsupportedCapability
            case .invalidOutputConstraint: return .invalidConstraint
            default: return .other
            }
        }
        if let error = error as? BoneInferenceTransportError {
            switch error {
            case .invalidCredential: return .authentication
            case .invalidResponse: return .invalidResponse
            case .outputTruncated: return .outputTruncated
            case .safetyBlocked: return .safetyBlocked
            case .rateLimited: return .rateLimited
            case .quotaExceeded: return .quotaExceeded
            case .network: return .network
            default: return .other
            }
        }
        return .other
    }

    private static func utcDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
