import BoneAgentKit

/// Public answer fragments and content-free SDK observations for the active Run.
/// A draft is publishable only after send returns a completed reply.
enum DemoLiveChatUpdate: Sendable {
    case inferenceStarted
    case textDelta(String)
    case status(BoneAgentStatus)
    case tokens(BoneAgentTokenSnapshot)
    case contextCompacted(BoneContextCompactionReceipt)
    case contextFailure(BoneContextFailureDiagnostic)
}

typealias DemoLiveChatObserver = @Sendable (DemoLiveChatUpdate) async -> Void
