import Foundation
import BoneAgentKit

/// Fixed codes only: no model field names/values, references, paths or text are retained.
enum DemoResourceReadIssue: String, Codable, Equatable, Sendable {
    case missingResourceID, missingReference, missingOffset, missingPageSize
    case invalidFieldType, unexpectedField, invalidResourceID, invalidShape
    case pageOutOfRange, pagePastEnd, offsetOutOfRange, pageSizeOutOfRange, offsetInsideUTF8
    case referenceMismatch, accessDenied, unavailable

    var message: String {
        switch self {
        case .missingResourceID: "读取参数缺少文件 ID。应复制附件的 firstRead 或上一页的 nextRead。"
        case .missingReference: "读取参数缺少精确文件引用。"
        case .missingOffset: "字节读取参数缺少起点；聊天任务应使用文件 ID 和页码。"
        case .missingPageSize: "字节读取参数缺少页大小；聊天任务由 App 固定分页。"
        case .invalidFieldType: "读取参数的字段类型不正确。文件 ID 应为文字，页码应为整数。"
        case .unexpectedField: "读取参数包含当前接口不接受的字段。请复制 firstRead、nextRead，或使用搜索命中的原始 offset；不要传 reference/maximumBytes。"
        case .invalidResourceID: "读取参数中的文件 ID 格式不正确。"
        case .invalidShape: "读取参数格式不符合当前分页接口。"
        case .pageOutOfRange: "读取页码超过允许范围。页码从 0 开始，继续时应复制 nextRead。"
        case .pagePastEnd: "模型请求了文件末尾之后的页面。nextRead 为空时应停止读取。"
        case .offsetOutOfRange: "读取起点超过文件字节范围。"
        case .pageSizeOutOfRange: "模型请求的字节页大小超出范围。聊天任务由 App 固定分页。"
        case .offsetInsideUTF8: "读取起点落在 UTF-8 字符内部。请复制 nextRead 或搜索命中的 matchOffset/snippetOffset。"
        case .referenceMismatch: "文件引用与当前保存的版本不一致，已停止读取。"
        case .accessDenied: "该文件未发送到当前会话，已阻止读取其他草稿或旧会话材料。"
        case .unavailable: "当前文件快照已不可用，请重新导入。"
        }
    }
    static func classify(_ error: any Error) -> Self? {
        if let error = error as? DemoResourcePageError {
            switch error {
            case .invalidResourceID: return .invalidResourceID
            case .invalidPage: return .pageOutOfRange
            case .pagePastEnd: return .pagePastEnd
            }
        }
        if let error = error as? BoneToolTextResourceError {
            switch error {
            case .accessDenied: return .accessDenied
            case .referenceMismatch: return .referenceMismatch
            case .unavailable, .expired: return .unavailable
            case .invalidOffset: return .offsetInsideUTF8
            default: return .invalidShape
            }
        }
        if let error = error as? DecodingError {
            switch error {
            case .keyNotFound(let key, _):
                switch key.stringValue {
                case "resourceID": return .missingResourceID
                case "reference": return .missingReference
                case "offset": return .missingOffset
                case "maximumBytes": return .missingPageSize
                default: return .invalidShape
                }
            case .typeMismatch, .valueNotFound: return .invalidFieldType
            case .dataCorrupted: return .invalidShape
            @unknown default: return .invalidShape
            }
        }
        return nil
    }
    static func schema(_ mismatch: BoneToolSchemaMismatch) -> Self {
        switch mismatch.rule {
        case .missingRequired:
            switch mismatch.path {
            case "$.resourceID": return .missingResourceID
            case "$.reference": return .missingReference
            case "$.offset": return .missingOffset
            case "$.maximumBytes": return .missingPageSize
            default: return .invalidShape
            }
        case .typeMismatch: return .invalidFieldType
        case .unexpectedProperty: return .unexpectedField
        case .numberRange:
            switch mismatch.path {
            case "$.page": return .pageOutOfRange
            case "$.offset": return .offsetOutOfRange
            case "$.maximumBytes": return .pageSizeOutOfRange
            default: return .invalidShape
            }
        default: return .invalidShape
        }
    }
}
