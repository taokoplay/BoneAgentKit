import Foundation
import XCTest
@testable import BoneAgentKit

final class ProviderCatalogTests: XCTestCase {
    func testBundledCatalogExposesSemanticIconIDsWithoutBundlingBrandAssets() throws {
        let catalog = try BoneInferenceProviderCatalog.bundled()
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.catalogVersion, 6)
        XCTAssertEqual(catalog.providers.count, 21)
        XCTAssertEqual(catalog.provider(ident: "openai")?.providerKind, .openAI)
        XCTAssertEqual(catalog.provider(ident: "openai")?.iconID, "icon_ai_openAI")
        XCTAssertFalse(try catalog.iconData(iconID: "icon_ai_openAI", scale: 1).isEmpty)
        XCTAssertFalse(try catalog.iconData(iconID: "icon_ai_openAI", scale: 3).isEmpty)

        let knownLimits: [(String, String, Int, Int?, Int?)] = [
            ("Anthropic", "claude-sonnet-4-5-20250929", 200_000, 200_000, 64_000),
            ("Anthropic", "claude-haiku-4-5-20251001", 200_000, 200_000, 64_000),
            ("OpenAI", "gpt-4.1-mini", 1_047_576, nil, 32_768),
            ("DeepSeek", "deepseek-v4-pro", 1_000_000, nil, 384_000),
            ("DeepSeek", "deepseek-v4-flash", 1_000_000, nil, 384_000),
            ("Google", "gemini-2.5-flash", 1_048_576, 1_048_576, 65_536),
            ("KimiAnthropic", "kimi-k2.6", 256_000, nil, nil),
            ("Zhipu", "glm-5.2", 1_000_000, nil, 128_000),
            ("Zhipu", "glm-5.1", 200_000, nil, 128_000),
            ("Qwen", "qwen3-max", 262_144, 258_048, 65_536),
            ("Qwen", "qwen3.5-plus", 1_000_000, 991_808, 65_536),
            ("Qwen", "qwen3-coder-plus", 1_000_000, 997_952, 65_536),
            ("MiMo", "mimo-v2.5-pro", 1_000_000, nil, nil),
            ("MiMo", "mimo-v2-pro", 1_000_000, nil, nil),
            ("MiMo", "mimo-v2.5", 1_000_000, nil, nil),
            ("MiMo", "mimo-v2-omni", 256_000, nil, nil),
            ("Agnes", "agnes-2.5-pro-alpha", 1_000_000, nil, 65_536),
        ]
        for (providerID, modelID, context, input, output) in knownLimits {
            let model = try XCTUnwrap(
                catalog.provider(ident: providerID)?.models.first(where: { $0.id == modelID })
            )
            let limits = try XCTUnwrap(model.tokenLimits)
            XCTAssertEqual(limits.contextWindowTokens, context)
            XCTAssertEqual(limits.maximumInputTokens, input)
            XCTAssertEqual(limits.maximumOutputTokens, output)
        }
        XCTAssertNil(
            catalog.provider(ident: "KimiCodingPlan")?.models
                .first(where: { $0.id == "kimi-for-coding" })?.tokenLimits
        )
    }

    func testCatalogRejectsUnsupportedSchema() throws {
        let changed = Data("""
        {"schemaVersion":2,"catalogVersion":1,"verifiedAt":"2026-08-24","providers":[]}
        """.utf8)
        XCTAssertThrowsError(try BoneInferenceProviderCatalog.decode(data: changed)) { error in
            XCTAssertEqual(error as? BoneInferenceProviderCatalog.Error, .unsupportedSchema(2))
        }
    }

    func testCatalogDecodesModelTokenLimits() throws {
        let catalog = try BoneInferenceProviderCatalog.decode(
            data: catalogData(tokenLimits: """
            {
              "contextWindowTokens": 200000,
              "maximumInputTokens": 180000,
              "maximumOutputTokens": 64000,
              "source": "official",
              "verifiedAt": "2026-08-28",
              "documentationURL": "https://docs.example.com/model"
            }
            """)
        )

        let limits = try XCTUnwrap(catalog.providers.first?.models.first?.tokenLimits)
        XCTAssertEqual(limits.contextWindowTokens, 200_000)
        XCTAssertEqual(limits.maximumInputTokens, 180_000)
        XCTAssertEqual(limits.maximumOutputTokens, 64_000)
        XCTAssertEqual(limits.source, .official)
        XCTAssertEqual(limits.verifiedAt, "2026-08-28")
        XCTAssertEqual(limits.documentationURL.absoluteString, "https://docs.example.com/model")
    }

    func testCatalogAllowsOfficiallyUnspecifiedInputOrOutputLimits() throws {
        let catalog = try BoneInferenceProviderCatalog.decode(
            data: catalogData(tokenLimits: """
            {"contextWindowTokens":256000,"source":"official","verifiedAt":"2026-08-28","documentationURL":"https://docs.example.com/model"}
            """)
        )
        let limits = try XCTUnwrap(catalog.providers.first?.models.first?.tokenLimits)
        XCTAssertNil(limits.maximumInputTokens)
        XCTAssertNil(limits.maximumOutputTokens)
    }

    func testCatalogRejectsInvalidModelTokenLimits() throws {
        let invalidLimits = [
            """
            {"contextWindowTokens":0,"maximumInputTokens":1,"maximumOutputTokens":1,"source":"official","verifiedAt":"2026-08-28","documentationURL":"https://docs.example.com/model"}
            """,
            """
            {"contextWindowTokens":100,"maximumInputTokens":101,"maximumOutputTokens":1,"source":"official","verifiedAt":"2026-08-28","documentationURL":"https://docs.example.com/model"}
            """,
            """
            {"contextWindowTokens":100,"maximumInputTokens":100,"maximumOutputTokens":1,"source":"guessed","verifiedAt":"2026-08-28","documentationURL":"https://docs.example.com/model"}
            """,
            """
            {"contextWindowTokens":100,"maximumInputTokens":100,"maximumOutputTokens":1,"source":"gateway","verifiedAt":"2026-08-28","documentationURL":"http://docs.example.com/model"}
            """,
        ]

        for limits in invalidLimits {
            XCTAssertThrowsError(try BoneInferenceProviderCatalog.decode(data: catalogData(tokenLimits: limits)))
        }
    }

    private func catalogData(tokenLimits: String) -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "catalogVersion": 1,
          "verifiedAt": "2026-08-28",
          "providers": [{
            "ident": "Test",
            "title": "Test",
            "icon": "icon_ai_openAI",
            "adapter": "openAI",
            "authenticationMode": "bearer",
            "defaultBaseURL": "https://api.example.com/v1",
            "modelCatalogMode": "local",
            "sortOrder": 1,
            "models": [{
              "id": "test-chat",
              "displayName": "Test Chat",
              "capabilities": ["chat"],
              "protocolVariant": "openAI",
              "tokenLimits": \(tokenLimits),
              "deprecated": false
            }]
          }]
        }
        """.utf8)
    }
}
