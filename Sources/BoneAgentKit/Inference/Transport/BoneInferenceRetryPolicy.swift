import Foundation

/// 仅供幂等模型发现 GET 使用的有限重试策略。
public enum BoneInferenceRetryPolicy {
    private static let retryableStatusCodes: Set<Int> = [502, 503, 504]
    private static let retryableNetworkCodes: Set<Int> = [
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.networkConnectionLost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
    ]
    private static let maximumDelaySeconds = 60.0

    public static func shouldRetry(
        method: String?,
        attempt: Int,
        statusCode: Int?,
        networkCode: Int?
    ) -> Bool {
        guard method?.uppercased() == "GET", attempt == 1 else { return false }
        if let statusCode { return retryableStatusCodes.contains(statusCode) }
        if let networkCode { return retryableNetworkCodes.contains(networkCode) }
        return false
    }

    public static func retryDelay(headerValue: String?, now: Date = Date()) -> TimeInterval {
        guard let value = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return 0
        }
        if let seconds = Double(value), seconds.isFinite {
            return min(max(0, seconds), maximumDelaySeconds)
        }
        if let date = HTTPDateParser.date(from: value) {
            return min(max(0, date.timeIntervalSince(now)), maximumDelaySeconds)
        }
        return 0
    }

    private enum HTTPDateParser {
        static func date(from value: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            return formatter.date(from: value)
        }
    }
}
