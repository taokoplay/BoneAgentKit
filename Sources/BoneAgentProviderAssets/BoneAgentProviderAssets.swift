import Foundation

/// BoneAgentKit 可选的内置 Provider 渠道图片入口。
///
/// 本模块只返回原始 PNG 数据，不依赖 UIKit 或 SwiftUI。`iconID` 与
/// `BoneInferenceProviderCatalog.Entry.iconID` 使用同一稳定语义标识。
public enum BoneAgentProviderAssets {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidScale(Int)
        case unknownIconID(String)
        case resourceMissing(iconID: String, scale: Int)
    }

    public static let availableIconIDs: Set<String> = [
        "icon_ai_agnes",
        "icon_ai_anthropic",
        "icon_ai_custom",
        "icon_ai_deepseek",
        "icon_ai_doubao",
        "icon_ai_google",
        "icon_ai_mimo",
        "icon_ai_minimax",
        "icon_ai_moonshot",
        "icon_ai_newapi",
        "icon_ai_openAI",
        "icon_ai_qwen",
        "icon_ai_siliconFlow",
        "icon_ai_zhipu",
    ]

    public static func iconData(iconID: String, scale: Int) throws -> Data {
        guard (1...3).contains(scale) else {
            throw Error.invalidScale(scale)
        }
        guard availableIconIDs.contains(iconID) else {
            throw Error.unknownIconID(iconID)
        }

        let suffix = scale == 1 ? "" : "@\(scale)x"
        guard let url = Bundle.module.url(
            forResource: "\(iconID)\(suffix)",
            withExtension: "png"
        ) else {
            throw Error.resourceMissing(iconID: iconID, scale: scale)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
