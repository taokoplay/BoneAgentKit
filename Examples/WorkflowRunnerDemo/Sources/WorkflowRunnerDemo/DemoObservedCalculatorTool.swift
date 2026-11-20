import BoneAgentKit
import BoneAgentTools

/// Records only a completed numeric result, never model arguments or private text.
struct DemoObservedCalculatorTool: BoneAgentTool {
    typealias Context = BoneAgentEmptyContext
    typealias Input = BoneCalculatorTool<Context>.Input
    typealias Output = BoneCalculatorTool<Context>.Output
    let observe: @Sendable (Double) async -> Void

    static var definition: BoneAgentToolDefinition { BoneCalculatorTool<Context>.definition }

    func execute(input: Input, context: Context) async throws -> Output {
        let output = try await BoneCalculatorTool<Context>().execute(input: input, context: context)
        await observe(output.value)
        return output
    }
}
