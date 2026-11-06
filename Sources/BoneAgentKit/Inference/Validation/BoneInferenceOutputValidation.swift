/// 输出校验的固定问题分类；具体字段、标识与内容由调用方私有反馈承载。
public enum BoneInferenceOutputIssue: String, Codable, Equatable, Sendable {
    case invalidFormat
    case contractMismatch
    case missingRequiredOutput
    case invalidReference
    case other
}

/// 明确的校验拒绝，不是网络、授权或存储错误。
/// Feedback 只在内存参数与返回值中流转，不自动序列化或记录；调用方负责其容量及隐私。
public struct BoneInferenceOutputRejection<Feedback: Sendable>: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidIssueCount
    }

    /// 单份拒绝报告的计数上限；超过时应由调用方汇总，不静默截断。
    public static var maximumIssueCount: Int { 65_535 }

    public let issue: BoneInferenceOutputIssue
    public let issueCount: Int
    public let allowsCorrection: Bool
    public let feedback: Feedback?

    /// 创建已知拒绝。是否允许修正默认为 false，不能用它表达执行结果未知。
    public init(
        issue: BoneInferenceOutputIssue,
        issueCount: Int = 1,
        allowsCorrection: Bool = false,
        feedback: Feedback? = nil
    ) throws {
        guard (1...Self.maximumIssueCount).contains(issueCount) else {
            throw Error.invalidIssueCount
        }
        self.issue = issue
        self.issueCount = issueCount
        self.allowsCorrection = allowsCorrection
        self.feedback = feedback
    }
}

/// 调用方对一个完整结果的校验决定。accepted 不证明业务已提交或语义绝对正确。
/// 此类型可能携带私有值，不提供自动 Codable、日志或事件投递。
public enum BoneInferenceOutputValidation<Value: Sendable, Feedback: Sendable>: Sendable {
    case accepted(Value)
    case rejected(BoneInferenceOutputRejection<Feedback>)
}
