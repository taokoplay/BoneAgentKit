import Foundation

/// 可复用的业务场景提示词段落；只承载可信的 Host 配置，不承载用户输入或工具结果。
public struct BonePromptSection: Codable, Equatable, Sendable {
    public let id: String
    public let content: String
    public let order: Int

    /// 创建一个业务提示词段落。
    /// - Parameters:
    ///   - id: 稳定的 ASCII 段落标识，用于调试、排序和版本迁移。
    ///   - content: 发送给模型的可信指令正文。
    ///   - order: 段落顺序，数值越小越靠前。
    public init(id: String, content: String, order: Int = 0) {
        self.id = id
        self.content = content
        self.order = order
    }
}

/// 兼容早期命名的业务提示词段落别名。
public typealias BoneAgentPromptSection = BonePromptSection

/// 供应商无关的业务场景提示词配置。
///
/// Profile 在会话创建或一次性 Run 开始时编译为前置 system 消息，之后沿用现有的
/// 上下文预算、Provider 映射、私有会话持久化和恢复流程。
public struct BonePromptProfile: Codable, Equatable, Sendable {
    public static let maximumProfileIDBytes = 128
    public static let maximumSectionCount = 64
    public static let maximumSectionIDBytes = 128
    public static let maximumSectionContentBytes = 16 * 1_024
    public static let maximumRenderedBytes = 64 * 1_024

    public let id: String
    public let version: UInt64
    public let sections: [BonePromptSection]

    /// 创建一个不可变的业务场景提示词配置。
    /// - Parameters:
    ///   - id: 场景标识，例如 `personal-assistant` 或 `software-developer`。
    ///   - version: 场景提示词版本，必须大于 0。
    ///   - sections: 有序的身份、目标、规则和输出风格段落。
    public init(id: String, version: UInt64 = 1, sections: [BonePromptSection]) {
        self.id = id
        self.version = version
        self.sections = sections
    }

    /// 提示词配置的稳定校验结果。
    /// - Returns: 可安全编译为 system 消息的同一份配置。
    /// - Throws: 配置标识、段落、数量或字节预算不符合约束时抛出错误。
    public func validated() throws -> Self {
        guard Self.isValidIdentifier(id, maximumBytes: Self.maximumProfileIDBytes) else {
            throw BonePromptProfileError.invalidProfileID
        }
        guard version > 0 else { throw BonePromptProfileError.invalidVersion }
        guard sections.count <= Self.maximumSectionCount else {
            throw BonePromptProfileError.tooManySections
        }

        var sectionIDs = Set<String>()
        for section in sections {
            guard Self.isValidIdentifier(section.id, maximumBytes: Self.maximumSectionIDBytes) else {
                throw BonePromptProfileError.invalidSectionID
            }
            guard sectionIDs.insert(section.id).inserted else {
                throw BonePromptProfileError.duplicateSectionID(section.id)
            }
            guard !section.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BonePromptProfileError.emptySectionContent
            }
            guard section.content.utf8.count <= Self.maximumSectionContentBytes else {
                throw BonePromptProfileError.sectionContentTooLarge
            }
        }
        return self
    }

    /// 将 Profile 编译为一个前置 system 消息。
    /// - Returns: 空 Profile 返回空数组，否则返回一个按稳定顺序合并的 system 消息。
    /// - Throws: Profile 未通过校验时抛出错误。
    public func systemMessages() throws -> [BoneInferenceMessage] {
        guard let message = try renderedSystemMessage() else { return [] }
        return [message]
    }

    /// 将 Profile 与调用方已有的前置 system 指令合并为一条消息。
    /// - Parameter messages: 已按调用方语义组装的消息序列。
    /// - Returns: Profile 位于最前方，所有前置 system 指令合并为一条消息的序列。
    /// - Throws: Profile 未通过校验时抛出错误。
    public func compose(messages: [BoneInferenceMessage]) throws -> [BoneInferenceMessage] {
        guard let profileContent = try renderedSystemContent() else { return messages }
        let leadingSystem = messages.prefix { $0.role == .system }
        let remainder = messages.dropFirst(leadingSystem.count)
        let existingText = leadingSystem.compactMap(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let content = existingText.isEmpty ? profileContent : profileContent + "\n" + existingText
        guard content.utf8.count <= Self.maximumRenderedBytes else {
            throw BonePromptProfileError.profileContentTooLarge
        }
        return [.init(role: .system, content: content)] + remainder
    }

    private func renderedSystemMessage() throws -> BoneInferenceMessage? {
        guard let content = try renderedSystemContent() else { return nil }
        return .init(role: .system, content: content)
    }

    private func renderedSystemContent() throws -> String? {
        let profile = try validated()
        guard !profile.sections.isEmpty else { return nil }
        let orderedSections = profile.sections.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
        }
        var text = ""
        text.reserveCapacity(orderedSections.reduce(0) { $0 + 6 + $1.id.utf8.count + $1.content.utf8.count })
        for (index, section) in orderedSections.enumerated() {
            text.append("## ")
            text.append(section.id)
            text.append("\n")
            text.append(section.content)
            text.append("\n")
            if index < orderedSections.index(before: orderedSections.endIndex) {
                text.append("\n")
            }
        }
        guard text.utf8.count <= Self.maximumRenderedBytes else {
            throw BonePromptProfileError.profileContentTooLarge
        }
        return text
    }

    private static func isValidIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                return true
            default:
                return false
            }
        }
    }
}

/// 兼容早期命名的业务提示词配置别名。
public typealias BoneAgentPromptProfile = BonePromptProfile

/// 业务提示词配置错误；不包含提示词正文，便于安全地记录诊断。
public enum BonePromptProfileError: Error, Equatable, Sendable {
    case invalidProfileID
    case invalidVersion
    case tooManySections
    case invalidSectionID
    case duplicateSectionID(String)
    case emptySectionContent
    case sectionContentTooLarge
    case profileContentTooLarge
}
