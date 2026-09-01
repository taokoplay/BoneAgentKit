import XCTest
@testable import BoneAgentProviderAssets

final class BoneAgentProviderAssetsTests: XCTestCase {
    private let iconIDs = [
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

    func testAllBundledProviderIconsAreAvailableAtEveryScale() throws {
        XCTAssertEqual(BoneAgentProviderAssets.availableIconIDs, Set(iconIDs))
        XCTAssertEqual(BoneAgentProviderAssets.availableIconIDs.count * 3, 42)

        for iconID in iconIDs {
            for scale in 1...3 {
                let data = try BoneAgentProviderAssets.iconData(iconID: iconID, scale: scale)
                XCTAssertFalse(data.isEmpty, "\(iconID)@\(scale)x")
                XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            }
        }
    }

    func testUnknownIconIDFailsClosed() {
        XCTAssertThrowsError(
            try BoneAgentProviderAssets.iconData(iconID: "icon_ai_unknown", scale: 2)
        ) { error in
            XCTAssertEqual(
                error as? BoneAgentProviderAssets.Error,
                .unknownIconID("icon_ai_unknown")
            )
        }
    }

    func testInvalidScaleFailsClosed() {
        XCTAssertThrowsError(
            try BoneAgentProviderAssets.iconData(iconID: "icon_ai_openAI", scale: 4)
        ) { error in
            XCTAssertEqual(error as? BoneAgentProviderAssets.Error, .invalidScale(4))
        }
    }
}
