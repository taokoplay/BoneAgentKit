import Foundation

/// 验证 Provider HTTP 状态和 JSON 根，不把响应正文带入错误。
public enum BoneInferenceProviderResponseValidator {
    public static func validatedJSONObject(
        _ response: BoneInferenceHTTPResponse
    ) throws -> [String: Any] {
        guard (200 ... 299).contains(response.statusCode) else {
            throw mappedError(statusCode: response.statusCode, data: response.data)
        }
        guard !response.data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: response.data),
              let json = object as? [String: Any]
        else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return json
    }

    public static func mappedError(statusCode: Int) -> BoneInferenceTransportError {
        switch statusCode {
        case 401, 403: return .invalidCredential
        case 402: return .quotaExceeded
        case 404: return .unsupportedModel
        case 429: return .rateLimited
        default: return .httpStatus(statusCode)
        }
    }

    static func mappedError(
        statusCode: Int,
        data: Data
    ) -> BoneInferenceTransportError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           isSafetyBlocked(object) {
            return .safetyBlocked
        }
        return mappedError(statusCode: statusCode)
    }

    private static func isSafetyBlocked(_ object: [String: Any]) -> Bool {
        if object["blocked"] as? Bool == true { return true }
        if let reason = object["blocked_reason"] as? String,
           ["prompt_blocked", "safety", "blocked"].contains(reason.lowercased()) {
            return true
        }
        guard let error = object["error"] as? [String: Any] else { return false }
        let blockedValues: Set<String> = [
            "safety_blocked",
            "content_policy",
            "content_policy_violation",
            "unsafe_content",
            "blocked",
        ]
        if let code = error["code"] as? String, blockedValues.contains(code.lowercased()) {
            return true
        }
        if let type = error["type"] as? String, blockedValues.contains(type.lowercased()) {
            return true
        }
        return false
    }
}
