import Foundation

/// 日志级别。`.debug` 仅在调试模式开启时输出。
public enum BoneAgentLogLevel: Int, Codable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
}

/// Agent Runtime 的日志记录器。实现可以转发到 os.Logger、文件或测试收集器。
public protocol BoneAgentLogger: Sendable {
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?)
}

extension BoneAgentLogLevel: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct BoneAgentLogContext: Codable, Equatable, Sendable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func merged(with other: BoneAgentLogContext?) -> BoneAgentLogContext {
        guard let other else { return self }
        return BoneAgentLogContext(values.merging(other.values) { _, new in new })
    }
}

public struct BoneAgentLoggerConfiguration: Sendable {
    public var isDebugEnabled: Bool
    public var minimumLevel: BoneAgentLogLevel
    public var logger: BoneAgentLogger

    public init(
        isDebugEnabled: Bool = false,
        minimumLevel: BoneAgentLogLevel = .info,
        logger: BoneAgentLogger = BoneAgentConsoleLogger()
    ) {
        self.isDebugEnabled = isDebugEnabled
        self.minimumLevel = minimumLevel
        self.logger = logger
    }

    public func write(_ level: BoneAgentLogLevel, _ message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext? = nil) {
        guard (isDebugEnabled || level != .debug), level >= minimumLevel else { return }
        logger.log(level, message: message(), context: context)
    }
}

public struct BoneAgentConsoleLogger: BoneAgentLogger {
    public init() {}
    public func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?) {
        let suffix = context?.values.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ") ?? ""
        print("[BoneAgent][\(String(describing: level).uppercased())] \(message())\(suffix.isEmpty ? "" : " | \(suffix)")")
    }
}
