import Foundation

/// 只包含时长和协议，不包含 URL、Header 或正文的网络指标。
public struct BoneInferenceHTTPMetrics: Equatable, Sendable {
    public let dnsDuration: TimeInterval?
    public let connectDuration: TimeInterval?
    public let tlsDuration: TimeInterval?
    public let requestDuration: TimeInterval?
    public let firstByteDuration: TimeInterval?
    public let totalDuration: TimeInterval?
    public let networkProtocolName: String?

    public init(
        dnsDuration: TimeInterval? = nil,
        connectDuration: TimeInterval? = nil,
        tlsDuration: TimeInterval? = nil,
        requestDuration: TimeInterval? = nil,
        firstByteDuration: TimeInterval? = nil,
        totalDuration: TimeInterval? = nil,
        networkProtocolName: String? = nil
    ) {
        self.dnsDuration = dnsDuration
        self.connectDuration = connectDuration
        self.tlsDuration = tlsDuration
        self.requestDuration = requestDuration
        self.firstByteDuration = firstByteDuration
        self.totalDuration = totalDuration
        self.networkProtocolName = networkProtocolName
    }
}

/// 有界、脱敏的底层错误事实。
public struct BoneInferenceNetworkDiagnostic: Equatable, Sendable {
    public struct UnderlyingError: Equatable, Sendable {
        public let domain: String
        public let code: Int

        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }
    }

    public let domain: String
    public let code: Int
    public let underlying: [UnderlyingError]
    public let cfStreamDomain: Int?
    public let cfStreamCode: Int?
    /// 失败链路的脱敏阶段耗时；不含 URL、Header 或正文。
    public let metrics: BoneInferenceHTTPMetrics?

    public init(error: Error, metrics: BoneInferenceHTTPMetrics? = nil) {
        let nsError = error as NSError
        var underlying: [UnderlyingError] = []
        var cursor = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = cursor, underlying.count < 3 {
            underlying.append(.init(domain: current.domain, code: current.code))
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.init(
            domain: nsError.domain,
            code: nsError.code,
            underlying: underlying,
            cfStreamDomain: nsError.userInfo["_kCFStreamErrorDomainKey"] as? Int,
            cfStreamCode: nsError.userInfo["_kCFStreamErrorCodeKey"] as? Int,
            metrics: metrics
        )
    }

    public init(
        domain: String,
        code: Int,
        underlying: [UnderlyingError] = [],
        cfStreamDomain: Int? = nil,
        cfStreamCode: Int? = nil,
        metrics: BoneInferenceHTTPMetrics? = nil
    ) {
        self.domain = domain
        self.code = code
        self.underlying = Array(underlying.prefix(3))
        self.cfStreamDomain = cfStreamDomain
        self.cfStreamCode = cfStreamCode
        self.metrics = metrics
    }
}
