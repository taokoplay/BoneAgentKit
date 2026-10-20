import Foundation

/// 显式私有调试出口；不是安全日志、错误或普通持久化模型。
public struct BoneInferenceFailureResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Completion: String, Sendable { case complete, byteLimit, timeLimit, interrupted }
    /// Transport 请求级关联 ID，与 Engine invocationID 不同；不包含服务端凭据。
    public let captureID: UUID
    public let statusCode: Int
    /// 仅受限白名单，仍属于私有调试数据，不应直接写入生产日志。
    public let headers: [String: String]
    /// 原始失败正文的前缀，可能包含服务端回显的敏感内容。
    public let body: Data
    public let completion: Completion
    public var isTruncated: Bool { completion != .complete }
    public var description: String { "BoneInferenceFailureResponse(status: \(statusCode), bytes: \(body.count), completion: \(completion.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["statusCode": statusCode, "bodyBytes": body.count, "completion": completion.rawValue]) }
}

/// 默认关闭；仅通过显式 handler 开启。回调同步、非抛错、锁外执行，应快速返回。
/// SDK 不会自动打印、落盘或把正文送入普通 diagnostics。Host 负责访问控制、到期与删除。
public struct BoneInferenceFailureCapture: Sendable {
    public let maximumBodyBytes: Int
    /// 仅限制默认 SSE 非 2xx 采集，不替代普通请求或注入 loader 的超时。
    public let maximumDuration: TimeInterval
    private let handler: (@Sendable (BoneInferenceFailureResponse) -> Void)?

    public init(
        maximumBodyBytes: Int = 16 * 1_024,
        maximumDuration: TimeInterval = 2,
        handler: (@Sendable (BoneInferenceFailureResponse) -> Void)? = nil
    ) {
        self.maximumBodyBytes = min(max(0, maximumBodyBytes), 64 * 1_024)
        self.maximumDuration = maximumDuration.isFinite ? min(max(0.01, maximumDuration), 10) : 2
        self.handler = handler
    }

    var isEnabled: Bool { handler != nil }
    func emit(id: UUID, statusCode: Int, headers: [String: String], body: Data, completion: BoneInferenceFailureResponse.Completion) {
        guard let handler, !(200...299).contains(statusCode) else { return }
        let allowed: Set<String> = ["content-type", "request-id", "x-request-id", "x-amzn-requestid", "x-goog-request-id", "cf-ray", "traceparent"]
        var filtered: [String: String] = [:]
        var seen: Set<String> = []
        for (key, value) in headers {
            // 重复（大小写不同）Header 不选择不确定的值；拒绝换行/控制字符和超长值。
            guard key.utf8.count <= 64 else { continue }
            let name = key.lowercased()
            guard allowed.contains(name) else { continue }
            guard seen.insert(name).inserted else { filtered.removeValue(forKey: name); continue }
            guard value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            filtered[name] = value
        }
        // Own the bounded bytes: a Data slice may otherwise retain the entire loader response.
        let count = min(body.count, maximumBodyBytes)
        let prefix = count == 0 ? Data() : body.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: count)
        }
        handler(.init(captureID: id, statusCode: statusCode, headers: filtered,
                      body: prefix,
                      completion: body.count > maximumBodyBytes ? .byteLimit : completion))
    }
}
