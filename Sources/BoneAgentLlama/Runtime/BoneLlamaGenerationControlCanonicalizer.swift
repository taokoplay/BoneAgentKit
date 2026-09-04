import BoneAgentKit
import CryptoKit
import Foundation

/// 为 Llama 受控生成执行身份提供稳定且不泄露 Stop 明文的规范编码。
public enum BoneLlamaGenerationControlCanonicalizer {
    public static let formatVersion = 1

    public static func canonicalData(_ control: BoneLlamaGenerationControl) throws -> Data {
        var value = "{\"formatVersion\":" + String(formatVersion)
        value += ",\"stopTokenIDs\":["
        value += control.stopTokenIDs.map(String.init).joined(separator: ",")
        value += "],\"stopStringDigests\":["
        value += control.stopStrings.map { string in
            "\"" + sha256(Data(string.utf8)) + "\""
        }.joined(separator: ",")
        value += "],\"constraint\":"
        switch control.constraint {
        case nil:
            value += "null"
        case let .enumChoice(choices):
            value += "{\"type\":\"enumChoice\",\"values\":["
            value += choices.map { "\"" + sha256(Data($0.utf8)) + "\"" }.joined(separator: ",")
            value += "]}"
        case let .jsonSchema(schema):
            value += "{\"type\":\"jsonSchema\",\"formatVersion\":"
            value += String(BoneToolSchemaCanonicalEncoder.formatVersion)
            value += ",\"digest\":\""
            value += try BoneToolSchemaCanonicalEncoder.digest(schema)
            value += "\"}"
        }
        value += "}"
        return Data(value.utf8)
    }

    public static func digest(_ control: BoneLlamaGenerationControl) throws -> String {
        sha256(try canonicalData(control))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
