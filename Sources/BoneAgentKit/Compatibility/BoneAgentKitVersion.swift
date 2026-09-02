/// BoneAgentKit 的运行时语义版本镜像。
///
/// Swift Package Manager 仍以 Git Tag 作为依赖解析的版本事实源；发布时必须让该常量、
/// README、CHANGELOG 与 Tag 保持一致。
public enum BoneAgentKitVersion: Sendable {
    public static let major = 0
    public static let minor = 2
    public static let patch = 0
    public static let prerelease = "alpha.5"

    /// 符合 Semantic Versioning 2.0.0 的完整版本字符串。
    public static let current = "0.2.0-alpha.5"
}
