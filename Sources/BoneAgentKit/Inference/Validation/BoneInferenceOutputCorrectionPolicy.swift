/// 单次输出处理调用的修正上限；不代表跨调用或跨重启的持久额度。
public struct BoneInferenceOutputCorrectionPolicy: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidMaximumCorrectionAttempts
    }

    public let maximumCorrectionAttempts: Int

    /// 默认关闭修正。
    public init() {
        maximumCorrectionAttempts = 0
    }

    /// 允许 0...Int.max-1，保留初始校验的一个计数位置，避免统计溢出。
    /// 每次真正调用修正闭包前占用本次调用内的额度；建议从 1 开始。
    public init(maximumCorrectionAttempts: Int) throws {
        guard maximumCorrectionAttempts >= 0, maximumCorrectionAttempts < Int.max else {
            throw Error.invalidMaximumCorrectionAttempts
        }
        self.maximumCorrectionAttempts = maximumCorrectionAttempts
    }
}
