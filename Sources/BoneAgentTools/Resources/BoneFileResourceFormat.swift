import Foundation

/// 文件格式探测的一级格式族。
public enum BoneFileResourceFormatFamily: String, Codable, CaseIterable, Sendable {
    case text
    case pdf
    case officeOpenXML
    case archive
    case binary
    case unknown
}

extension BoneFileResourceFormatFamily {
    /// 判断格式族是否与资源引用中的粗粒度类型一致。
    /// - Parameter kind: 资源引用中的类型。
    /// - Returns: 类型一致时返回 true。
    func matches(_ kind: BoneFileResourceKind) -> Bool {
        switch (self, kind) {
        case (.text, .text), (.pdf, .pdf), (.officeOpenXML, .officeOpenXML),
             (.archive, .archive), (.binary, .binary):
            return true
        default:
            return false
        }
    }
}

/// 文件格式探测的可信度等级。
public enum BoneFileResourceFormatConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

/// 格式视图支持的资源操作能力。
public enum BoneFileResourceCapability: String, Codable, CaseIterable, Sendable {
    case inspect
    case readWindow
    case readBytes
    case structuredRead
    case listEntries
    case search
}

/// 文件保护状态；密码和密钥由 Host 管理，不进入普通资源工具参数。
public enum BoneFileResourceProtectionStatus: String, Codable, CaseIterable, Sendable {
    case none
    case passwordRequired
    case encrypted
    case unsupported
}

/// 资源格式探测结果，描述可用能力和探测覆盖范围。
public struct BoneFileResourceFormatInspection: Codable, Equatable, Sendable {
    /// 格式所属的一级格式族。
    public let family: BoneFileResourceFormatFamily
    /// 具体格式名称，例如 utf8、pdf、docx、zip 或 gzip。
    public let subtype: String
    /// IANA MIME 类型或通用二进制 MIME 类型。
    public let mimeType: String
    /// 当前格式身份的探测可信度。
    public let confidence: BoneFileResourceFormatConfidence
    /// 文本格式已确认的实际编码，非文本格式为 nil。
    public let encoding: BoneFileResourceEncoding?
    /// 当前资源可以安全使用的读取能力集合。
    public let capabilities: [BoneFileResourceCapability]
    /// 当前资源是否受密码或加密保护。
    public let protectionStatus: BoneFileResourceProtectionStatus
    /// 解析器标识，未绑定专用解析器时为 nil。
    public let parserID: String?
    /// 解析器版本，未绑定专用解析器时为 nil。
    public let parserVersion: String?
    /// 探测过程中产生的稳定警告代码。
    public let warnings: [String]

    /// 创建并校验格式探测结果。
    /// - Parameters:
    ///   - family: 一级格式族。
    ///   - subtype: 具体格式名称。
    ///   - mimeType: MIME 类型。
    ///   - confidence: 探测可信度。
    ///   - encoding: 已确认的文本编码。
    ///   - capabilities: 可用资源能力。
    ///   - protectionStatus: 保护状态。
    ///   - parserID: 解析器标识。
    ///   - parserVersion: 解析器版本。
    ///   - warnings: 稳定警告代码。
    public init(family: BoneFileResourceFormatFamily,
                subtype: String,
                mimeType: String,
                confidence: BoneFileResourceFormatConfidence,
                encoding: BoneFileResourceEncoding? = nil,
                capabilities: [BoneFileResourceCapability],
                protectionStatus: BoneFileResourceProtectionStatus,
                parserID: String? = nil,
                parserVersion: String? = nil,
                warnings: [String] = []) throws {
        let normalizedSubtype = subtype.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMIMEType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSubtype.isEmpty, normalizedSubtype.utf8.count <= 64,
              !normalizedMIMEType.isEmpty, normalizedMIMEType.utf8.count <= 128,
              capabilities.count == Set(capabilities).count,
              warnings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw BoneFileResourceError.invalidRequest
        }
        guard family == .text ? encoding != nil : encoding == nil else {
            throw BoneFileResourceError.invalidRequest
        }
        self.family = family
        self.subtype = normalizedSubtype
        self.mimeType = normalizedMIMEType
        self.confidence = confidence
        self.encoding = encoding
        self.capabilities = capabilities
        self.protectionStatus = protectionStatus
        self.parserID = parserID
        self.parserVersion = parserVersion
        self.warnings = warnings
    }
}
