import BoneAgentKit
import BoneAgentLocalModels
import CryptoKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaCompiledConstraintTests: XCTestCase {
    func testBuildsCompiledControlOnlyThroughCompiler() throws {
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: [2],
            constraint: .enumChoice(["yes", "no"])
        )
        let compiler = ConstraintCompilerFixture()

        let compiled = try BoneLlamaCompiledGenerationControl(
            control: control,
            compiler: compiler
        )

        XCTAssertEqual(compiled.stopTokenIDs, [2])
        XCTAssertEqual(compiled.sourceConstraint, control.constraint)
        XCTAssertEqual(compiled.compiledConstraint?.format, .gbnf)
        XCTAssertEqual(compiled.compiledConstraint?.rootRule, "root")
        XCTAssertEqual(compiled.compiledConstraint?.compilerIdentity, compiler.identity)
    }

    func testConstraintRequiresCompilerBeforeRuntimeGeneration() throws {
        let control = try BoneLlamaGenerationControl(constraint: .enumChoice(["ready"]))

        XCTAssertThrowsError(
            try BoneLlamaCompiledGenerationControl(control: control, compiler: nil)
        ) { error in
            XCTAssertEqual(error as? BoneLlamaAdapterError, .unsupportedGenerationControl)
        }
    }

    func testStopOnlyControlDoesNotRequireCompiler() throws {
        let control = try BoneLlamaGenerationControl(stopStrings: ["<eog>"])
        let compiled = try BoneLlamaCompiledGenerationControl(control: control, compiler: nil)

        XCTAssertEqual(compiled.stopStrings, ["<eog>"])
        XCTAssertNil(compiled.compiledConstraint)
        XCTAssertNil(compiled.sourceConstraint)
    }

    func testRejectsInvalidCompiledArtifacts() throws {
        let identity = try BoneLlamaConstraintCompilerIdentity(
            id: "bone.gbnf",
            version: "1",
            dialect: "gbnf-v1"
        )
        let validSource = "root ::= \"ok\""
        let validDigest = Self.digest(validSource)

        for make in [
            { try BoneLlamaCompiledConstraint(format: .gbnf, source: "", sourceDigest: validDigest, rootRule: "root", compilerIdentity: identity) },
            { try BoneLlamaCompiledConstraint(format: .gbnf, source: validSource, sourceDigest: String(repeating: "0", count: 64), rootRule: "root", compilerIdentity: identity) },
            { try BoneLlamaCompiledConstraint(format: .gbnf, source: validSource, sourceDigest: validDigest, rootRule: "bad rule", compilerIdentity: identity) },
            { try BoneLlamaCompiledConstraint(format: .gbnf, source: String(repeating: "x", count: BoneLlamaCompiledConstraint.maximumSourceByteCount + 1), sourceDigest: validDigest, rootRule: "root", compilerIdentity: identity) },
        ] {
            XCTAssertThrowsError(try make()) { error in
                XCTAssertEqual(error as? BoneLlamaAdapterError, .invalidGenerationControl)
            }
        }
    }

    func testCompilerIdentityRejectsEmptyOrOversizedComponents() {
        XCTAssertThrowsError(try BoneLlamaConstraintCompilerIdentity(id: "", version: "1", dialect: "gbnf-v1"))
        XCTAssertThrowsError(try BoneLlamaConstraintCompilerIdentity(id: "bone.gbnf", version: "", dialect: "gbnf-v1"))
        XCTAssertThrowsError(try BoneLlamaConstraintCompilerIdentity(
            id: String(repeating: "x", count: BoneLlamaConstraintCompilerIdentity.maximumComponentLength + 1),
            version: "1",
            dialect: "gbnf-v1"
        ))
    }

    private static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ConstraintCompilerFixture: BoneLlamaConstraintCompiling {
    let identity = try! BoneLlamaConstraintCompilerIdentity(
        id: "fixture.gbnf",
        version: "1",
        dialect: "gbnf-v1"
    )

    func compile(_ constraint: BoneLlamaGenerationConstraint) throws -> BoneLlamaCompiledConstraint {
        let source = "root ::= \"ok\""
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return try .init(
            format: .gbnf,
            source: source,
            sourceDigest: digest,
            rootRule: "root",
            compilerIdentity: identity
        )
    }
}
