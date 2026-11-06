/// 仅含固定元数据的处理回执；不是 Provider 请求数、费用、授权或持久化证明。
public struct BoneInferenceOutputProcessingReceipt: Encodable, Equatable, Sendable {
    public enum Outcome: Encodable, Equatable, Sendable {
        case accepted
        case rejected(BoneInferenceOutputIssue)
    }

    public let validationCount: Int
    public let correctionAttemptCount: Int
    public let outcome: Outcome
    public var usedCorrection: Bool { correctionAttemptCount > 0 }
}

/// 私有校验结果与独立统计；仅 receipt 适合固定元数据报告。
/// 操作性错误或取消时直接抛出，不返回此结果，也不包装调用方错误。
public struct BoneInferenceOutputProcessingResult<Value: Sendable, Feedback: Sendable>: Sendable {
    public let validation: BoneInferenceOutputValidation<Value, Feedback>
    public let receipt: BoneInferenceOutputProcessingReceipt
}

/// 对已完整取得的结果进行校验及有界修正，不拥有 Engine、Tool、预算或存储。
/// 输入可以是文本、数据或其他 Sendable 类型；调用方负责上游完整终态和业务校验。
/// 所有计数仅属于一次 process 调用；可并发复用实例，但不提供跨调用的幂等或持久限额。
public struct BoneInferenceValidatedOutputProcessor<Input: Sendable, Value: Sendable, Feedback: Sendable>: Sendable {
    public typealias Validator = @Sendable (Input) async throws -> BoneInferenceOutputValidation<Value, Feedback>
    /// 收到当前候选、最新拒绝与从 1 开始的修正序号，返回一个新候选。
    /// 执行器须负责预算、授权、持久准入和外部调用，不应嵌套自动修正或隐藏重试。
    public typealias Correction = @Sendable (Input, BoneInferenceOutputRejection<Feedback>, Int) async throws -> Input

    public init() {}

    /// 校验完整候选，只有明确且允许修正的拒绝才可能调用 correct。
    /// - Parameters:
    ///   - input: 已完整交付的候选；不能传入流式片段或未完成 Tool 参数。
    ///   - policy: 默认关闭修正；格式与业务拒绝共用同一上限。
    ///   - validate: 返回接受或明确拒绝；抛错直接传播，不触发修正。
    ///   - correct: 可选的本地或受控推理执行器；nil 时返回拒绝。
    /// - Returns: 最后一次校验决定与本次调用的统计，不自动写业务数据。
    /// - Throws: 原样传播闭包错误及协作式取消。不会强行终止不配合取消的外部操作。
    public func process(
        _ input: Input,
        policy: BoneInferenceOutputCorrectionPolicy = .init(),
        validate: Validator,
        correct: Correction? = nil
    ) async throws -> BoneInferenceOutputProcessingResult<Value, Feedback> {
        var candidate = input
        var validationCount = 0
        var correctionAttemptCount = 0

        while true {
            try Task.checkCancellation()
            validationCount += 1
            let validation = try await validate(candidate)
            try Task.checkCancellation()

            switch validation {
            case .accepted:
                return .init(validation: validation, receipt: .init(
                    validationCount: validationCount,
                    correctionAttemptCount: correctionAttemptCount,
                    outcome: .accepted
                ))
            case .rejected(let rejection):
                guard rejection.allowsCorrection,
                      correctionAttemptCount < policy.maximumCorrectionAttempts,
                      let correct else {
                    return .init(validation: validation, receipt: .init(
                        validationCount: validationCount,
                        correctionAttemptCount: correctionAttemptCount,
                        outcome: .rejected(rejection.issue)
                    ))
                }
                try Task.checkCancellation()
                correctionAttemptCount += 1
                candidate = try await correct(candidate, rejection, correctionAttemptCount)
                try Task.checkCancellation()
            }
        }
    }
}
