import Foundation

public protocol BoneLlamaRuntime: Sendable {
    var runtimeVersion: Int { get }

    func load(
        modelURL: URL,
        configuration: BoneLlamaRuntimeConfiguration
    ) async throws

    func generate(
        prompt: String,
        options: BoneLlamaGenerationOptions
    ) async throws -> BoneLlamaGenerationResult

    func smokeTest() async throws
    func cancel() async
    func unload() async
}

public typealias BoneLlamaRuntimeFactory = @Sendable () -> any BoneLlamaRuntime
