import XCTest
@testable import BoneAgentLocalModels

final class BoneLocalModelCatalogTests: XCTestCase {
    func testCatalogDecodesValidatedModelAndMultipleSources() throws {
        let catalog = try BoneLocalModelCatalog(data: manifestData())
        let model = try XCTUnwrap(catalog.model(id: "qwen-2b-q4"))

        XCTAssertEqual(catalog.catalogVersion, 3)
        XCTAssertEqual(model.format, .gguf)
        XCTAssertEqual(model.parameterCount, 2_000_000_000)
        XCTAssertEqual(model.artifact.sources.map(\.id), ["official", "mirror-cn"])
        XCTAssertEqual(model.contextLimits.contextWindowTokens, 32_768)
        XCTAssertEqual(model.recommendedContextTokens, 4_096)
    }

    func testCatalogDecodesOptionalInferenceCapabilityProfileAndKeepsLegacyCompatible() throws {
        let withProfile = modelJSON().replacingOccurrences(
            of: "\"artifact\": {",
            with: "\"inferenceCapabilityProfile\": {\"capabilities\":[\"text\",\"toolCalling\"],\"source\":\"official\",\"verifiedAt\":\"2026-09-02\"},\n          \"artifact\": {"
        )
        let model = try XCTUnwrap(BoneLocalModelCatalog(
            data: manifestData(models: withProfile)
        ).models.first)
        XCTAssertEqual(model.inferenceCapabilityProfile?.capabilities, [.text, .toolCalling])
        XCTAssertNil(try BoneLocalModelCatalog(data: manifestData()).models.first?.inferenceCapabilityProfile)
    }

    func testCatalogRejectsDuplicateModelID() {
        let model = modelJSON()
        XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: "\(model),\(model)"))) {
            XCTAssertEqual($0 as? BoneLocalModelCatalogError, .duplicateModelID("qwen-2b-q4"))
        }
    }

    func testCatalogRejectsUnsafeFileName() {
        XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: modelJSON(fileName: "../model.gguf")))) {
            XCTAssertEqual($0 as? BoneLocalModelCatalogError, .invalidArtifact(modelID: "qwen-2b-q4"))
        }
    }

    func testCatalogRejectsInsecureOrUntrustedDownloadSource() {
        XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: modelJSON(sourceURL: "http://models.example.com/model.gguf")))) {
            XCTAssertEqual($0 as? BoneLocalModelCatalogError, .invalidDownloadSource(modelID: "qwen-2b-q4", sourceID: "official"))
        }
    }

    func testCatalogRejectsInvalidChecksumAndRuntimeVersion() {
        XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: modelJSON(sha256: "bad")))) {
            XCTAssertEqual($0 as? BoneLocalModelCatalogError, .invalidArtifact(modelID: "qwen-2b-q4"))
        }
        XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: modelJSON(minimumRuntimeVersion: 2)))) {
            XCTAssertEqual($0 as? BoneLocalModelCatalogError, .runtimeVersionUnsupported(modelID: "qwen-2b-q4", required: 2, current: 1))
        }
    }

    func testCatalogRejectsDotSegmentModelIDsAndArtifactNames() {
        for id in [".", "..", "", "../escape", "nested/model", ".bone-install-staging", ".BONE-INSTALL-STAGING", ".Bone-Install-Staging", ".bone-download-staging", ".BONE-DOWNLOAD-STAGING"] {
            let json = modelJSON().replacingOccurrences(of: "\"id\": \"qwen-2b-q4\"", with: "\"id\": \"\(id)\"")
            XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: json)), id)
        }
        for name in [".", "..", "", "model.partial", "model.PARTIAL", "model.partial.download", "model.PARTIAL.DOWNLOAD"] {
            XCTAssertThrowsError(try BoneLocalModelCatalog(data: manifestData(models: modelJSON(fileName: name))), name)
        }
    }

    private func manifestData(models: String? = nil) -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "catalogVersion": 3,
          "runtimeVersion": 1,
          "models": [\(models ?? modelJSON())]
        }
        """.utf8)
    }

    private func modelJSON(
        fileName: String = "qwen-2b-q4.gguf",
        sha256: String = String(repeating: "a", count: 64),
        sourceURL: String = "https://models.example.com/qwen-2b-q4.gguf",
        minimumRuntimeVersion: Int = 1
    ) -> String {
        """
        {
          "id": "qwen-2b-q4",
          "displayName": "Qwen 2B Q4",
          "family": "Qwen",
          "format": "gguf",
          "parameterCount": 2000000000,
          "quantization": "Q4_K_M",
          "minimumMemoryBytes": 6442450944,
          "recommendedContextTokens": 4096,
          "minimumRuntimeVersion": \(minimumRuntimeVersion),
          "contextLimits": {
            "contextWindowTokens": 32768,
            "maximumInputTokens": 32256,
            "maximumOutputTokens": 4096,
            "source": "official",
            "verifiedAt": "2026-09-01",
            "documentationURL": "https://example.com/model-card"
          },
          "artifact": {
            "fileName": "\(fileName)",
            "expectedByteCount": 1024,
            "sha256": "\(sha256)",
            "sources": [
              {"id":"official","url":"\(sourceURL)","allowedHosts":["models.example.com"],"priority":10},
              {"id":"mirror-cn","url":"https://mirror.example.cn/qwen-2b-q4.gguf","allowedHosts":["mirror.example.cn"],"priority":20}
            ]
          },
          "license": {
            "name": "Apache-2.0",
            "url": "https://example.com/license",
            "modelCardURL": "https://example.com/model-card"
          }
        }
        """
    }
}
