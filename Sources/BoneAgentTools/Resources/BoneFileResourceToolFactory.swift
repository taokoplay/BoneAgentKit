import Foundation
import BoneAgentKit

/// 统一执行文件资源访问授权的 Host 工厂。
///
/// 工厂只接收不透明资源引用和 Host 上下文，调用方应在授权闭包中检查
/// session scope、资源版本、撤销状态和读取预算。
public struct BoneFileResourceAuthorizer<Context: BoneAgentToolContext>: Sendable {
    /// 授权闭包的入参和返回值。
    public typealias Handler = @Sendable (BoneFileResourceReference, Context) async throws -> Void

    private let handler: Handler

    /// 创建资源授权器。
    /// - Parameter authorize: Host 侧的授权重验闭包。
    public init(authorize: @escaping Handler) {
        handler = authorize
    }

    /// 重新验证当前请求是否仍允许访问资源。
    /// - Parameters:
    ///   - reference: 模型提交的不透明资源引用。
    ///   - context: 当前 Tool 执行上下文。
    public func authorize(_ reference: BoneFileResourceReference, context: Context) async throws {
        try await handler(reference, context)
    }
}

/// 文件资源工具统一构造入口。
public enum BoneFileResourceToolFactory {
    /// 创建带授权和结果校验的资源检查工具。
    /// - Parameters:
    ///   - authorizer: 每次调用前重新检查资源访问权限的授权器。
    ///   - inspect: Host 绑定的资源检查处理器。
    /// - Returns: 已绑定授权和结果校验的资源检查工具。
    public static func makeInspectTool<Context: BoneAgentToolContext>(
        authorizer: BoneFileResourceAuthorizer<Context>,
        inspect: @escaping BoneFileResourceInspectTool<Context>.Handler
    ) -> BoneFileResourceInspectTool<Context> {
        BoneFileResourceInspectTool { input, context in
            try Task.checkCancellation()
            try await authorizer.authorize(input.reference, context: context)
            let output = try await inspect(input, context)
            try Task.checkCancellation()
            return try output.validated(for: input.reference)
        }
    }

    /// 创建带授权和结果校验的结构化窗口读取工具。
    /// - Parameters:
    ///   - authorizer: 每次调用前重新检查资源访问权限的授权器。
    ///   - readWindow: Host 绑定的窗口读取处理器。
    /// - Returns: 已绑定授权和结果校验的窗口读取工具。
    public static func makeReadWindowTool<Context: BoneAgentToolContext>(
        authorizer: BoneFileResourceAuthorizer<Context>,
        readWindow: @escaping BoneFileResourceReadWindowTool<Context>.Handler
    ) -> BoneFileResourceReadWindowTool<Context> {
        BoneFileResourceReadWindowTool { input, context in
            try Task.checkCancellation()
            try await authorizer.authorize(input.reference, context: context)
            let output = try await readWindow(input, context)
            try Task.checkCancellation()
            return try output.validated(for: input)
        }
    }

    /// 创建带授权和结果校验的 Office 读取工具。
    /// - Parameters:
    ///   - authorizer: 每次调用前重新检查资源访问权限的授权器。
    ///   - readOffice: Host 绑定的 Office 读取处理器。
    /// - Returns: 已绑定授权和结果校验的 Office 读取工具。
    public static func makeReadOfficeTool<Context: BoneAgentToolContext>(
        authorizer: BoneFileResourceAuthorizer<Context>,
        readOffice: @escaping BoneFileResourceReadOfficeTool<Context>.Handler
    ) -> BoneFileResourceReadOfficeTool<Context> {
        BoneFileResourceReadOfficeTool { input, context in
            try Task.checkCancellation()
            try await authorizer.authorize(input.reference, context: context)
            let output = try await readOffice(input, context)
            try Task.checkCancellation()
            return try output.validated(for: input)
        }
    }

    /// 创建带授权和结果校验的归档目录工具。
    /// - Parameters:
    ///   - authorizer: 每次调用前重新检查资源访问权限的授权器。
    ///   - listEntries: Host 绑定的归档目录处理器。
    /// - Returns: 已绑定授权和结果校验的归档目录工具。
    public static func makeListEntriesTool<Context: BoneAgentToolContext>(
        authorizer: BoneFileResourceAuthorizer<Context>,
        listEntries: @escaping BoneFileResourceListEntriesTool<Context>.Handler
    ) -> BoneFileResourceListEntriesTool<Context> {
        BoneFileResourceListEntriesTool { input, context in
            try Task.checkCancellation()
            try await authorizer.authorize(input.reference, context: context)
            let output = try await listEntries(input, context)
            try Task.checkCancellation()
            return try output.validated(for: input)
        }
    }

    /// 创建带授权和结果校验的原始字节读取工具。
    /// - Parameters:
    ///   - authorizer: 每次调用前重新检查资源访问权限的授权器。
    ///   - readBytes: Host 绑定的字节读取处理器。
    /// - Returns: 已绑定授权和结果校验的字节读取工具。
    public static func makeReadBytesTool<Context: BoneAgentToolContext>(
        authorizer: BoneFileResourceAuthorizer<Context>,
        readBytes: @escaping BoneFileResourceReadBytesTool<Context>.Handler
    ) -> BoneFileResourceReadBytesTool<Context> {
        BoneFileResourceReadBytesTool { input, context in
            try Task.checkCancellation()
            try await authorizer.authorize(input.reference, context: context)
            let output = try await readBytes(input, context)
            try Task.checkCancellation()
            return try output.validated(for: input)
        }
    }

    /// 创建带授权和结果校验的格式探测工具。
    /// - Parameters:
    ///   - authorizer: 每次调用前重新检查资源访问权限的授权器。
    ///   - detectFormat: Host 绑定的格式探测处理器。
    /// - Returns: 已绑定授权和结果校验的格式探测工具。
    public static func makeDetectFormatTool<Context: BoneAgentToolContext>(
        authorizer: BoneFileResourceAuthorizer<Context>,
        detectFormat: @escaping BoneFileResourceDetectFormatTool<Context>.Handler
    ) -> BoneFileResourceDetectFormatTool<Context> {
        BoneFileResourceDetectFormatTool { input, context in
            try Task.checkCancellation()
            try await authorizer.authorize(input.reference, context: context)
            let output = try await detectFormat(input, context)
            try Task.checkCancellation()
            guard output.reference == input.reference else {
                throw BoneFileResourceError.referenceMismatch
            }
            return output
        }
    }
}
