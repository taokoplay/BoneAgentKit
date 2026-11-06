import Foundation

/// Content-free, request-scoped observations. Usage is cumulative for this request, not a delta.
public enum BoneInferenceTelemetryEvent: Equatable, Sendable {
    case usage(BoneInferenceUsage)
    /// Only true when events are delivered on actual arrival, not replayed from a buffered response.
    case requestStarted(liveTiming: Bool)
    /// First nonempty generated text, reasoning text, or tool argument fragment; never a heartbeat/header.
    case firstOutputToken
    case responseFinished
}

public struct BoneInferenceTelemetrySink: Sendable {
    private let receiveClosure: @Sendable (BoneInferenceTelemetryEvent) async -> Void
    public init(_ receive: @escaping @Sendable (BoneInferenceTelemetryEvent) async -> Void) {
        receiveClosure = receive
    }
    public func receive(_ event: BoneInferenceTelemetryEvent) async { await receiveClosure(event) }
}

/// Optional seam for Providers/custom Engines. Agent installs one sink per invocation, including summaries.
/// No request Codable changes; detached work does not inherit this scope.
public enum BoneInferenceTelemetryReporting {
    @TaskLocal private static var sink: BoneInferenceTelemetrySink?
    public static func withSink<Value: Sendable>(_ sink: BoneInferenceTelemetrySink,
        operation: @Sendable () async throws -> Value) async rethrows -> Value {
        try await $sink.withValue(sink) { try await operation() }
    }
    public static func report(_ event: BoneInferenceTelemetryEvent) async { await sink?.receive(event) }
}
