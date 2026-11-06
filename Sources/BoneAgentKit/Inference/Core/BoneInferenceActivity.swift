import Foundation

/// Provider-observed activity, independent of reasoning text disclosure. No content payloads.
public enum BoneInferenceActivity: Equatable, Sendable {
    case resolvingImages, waitingForModel, reasoning, generatingResponse, generatingToolCall, validatingResponse
}

public struct BoneInferenceActivitySink: Sendable {
    private let receiveClosure: @Sendable (BoneInferenceActivity) async -> Void
    public init(_ receive: @escaping @Sendable (BoneInferenceActivity) async -> Void) {
        receiveClosure = receive
    }
    public func receive(_ activity: BoneInferenceActivity) async { await receiveClosure(activity) }
}

/// Optional observation for Engine implementations and direct Provider callers.
/// Task-local scope isolates concurrent requests and is inherited by structured/Task children,
/// not detached work. Report only actual observed stages; do not synthesize reasoning from timeouts.
/// The observer is not serialized into BoneInferenceRequest or retained by a Provider instance.
public enum BoneInferenceActivityReporting {
    @TaskLocal private static var sink: BoneInferenceActivitySink?

    public static func withSink<Value: Sendable>(
        _ sink: BoneInferenceActivitySink,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        try await $sink.withValue(sink) { try await operation() }
    }

    public static func report(_ activity: BoneInferenceActivity) async {
        await sink?.receive(activity)
    }
}
