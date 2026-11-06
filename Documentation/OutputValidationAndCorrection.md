# 输出校验与有界修正

## 入口与默认行为

`BoneInferenceValidatedOutputProcessor<Input, Value, Feedback>` 对**已经完整交付**的候选进行调用方校验。`Input`、`Value` 和 `Feedback` 分别表示原始候选、验收后的值和私有反馈，均只要求 `Sendable`，不绑定 JSON、Provider、业务实体或数据库。

它是独立的可选处理入口，不挂接 Engine、Agent 或 Tool 的默认路径，不改变 `BoneAgent.run` 的成功语义。`BoneInferenceOutputCorrectionPolicy()` 默认允许 **0 次修正**；只有显式配置并注入执行器时才可能执行修正。SDK 不内置修正 Prompt、不选择模型、不自动联网或落盘。

## 校验契约

校验闭包返回 `BoneInferenceOutputValidation<Value, Feedback>`：

- `.accepted(value)`：调用方规则通过，不证明语义绝对正确、业务已提交或持久化成功。
- `.rejected(report)`：已知且明确的不合格结果。报告包含固定 `issue`、`issueCount`、`allowsCorrection` 和可选的私有 `feedback`。

固定类别为 `invalidFormat`、`contractMismatch`、`missingRequiredOutput`、`invalidReference`、`other`。一份报告选择主要类别，详细问题由 Feedback 承载；`issueCount` 必须为 1…65,535，超界抛出 `BoneInferenceOutputRejection.Error.invalidIssueCount`，不静默截断。Feedback 和候选的容量由调用方控制。

`allowsCorrection` 默认 false。校验闭包抛出的错误直接传播，不自动转换成可修正拒绝。只有调用方明确识别出的格式或契约问题才能转成 `.rejected`；取消、网络、授权、存储故障或未知结果应保持错误通道。合法空值由校验器决定，SDK 不以空字符串、空数组或空对象推断成功或失败。

## 文本的本地修正

下面只接受 `Int` 可解析的整数文本。首次拒绝允许修剪外围空白；没有网络调用。

```swift
import Foundation
import BoneAgentKit

func parseInteger(_ text: String) async throws -> BoneInferenceOutputProcessingResult<Int, String> {
    let processor = BoneInferenceValidatedOutputProcessor<String, Int, String>()
    return try await processor.process(
        text,
        policy: try .init(maximumCorrectionAttempts: 1),
        validate: { candidate in
            if let value = Int(candidate) { return .accepted(value) }
            return .rejected(try .init(
                issue: .invalidFormat,
                allowsCorrection: true,
                feedback: "允许移除外围空白，不更改数字内容"
            ))
        },
        correct: { candidate, _, _ in
            candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    )
}
```

调用后通过 `result.validation` 处理接受值或最终拒绝；`result.receipt` 单独提供固定统计。再次不合格会返回拒绝，不要求一定修正成功。

## 结构化数据与私有反馈

校验器可以把 `Data` 转成自定义结构，并返回完全不同的反馈类型：

```swift
struct Selection: Decodable, Sendable {
    let values: [Int]
}

struct SelectionFeedback: Sendable {
    let minimumCount: Int
}

func validateSelection(_ data: Data) throws -> BoneInferenceOutputValidation<Selection, SelectionFeedback> {
    let selection: Selection
    do {
        selection = try JSONDecoder().decode(Selection.self, from: data)
    } catch is DecodingError {
        return .rejected(try .init(issue: .invalidFormat, allowsCorrection: true))
    }
    guard !selection.values.isEmpty else {
        return .rejected(try .init(
            issue: .missingRequiredOutput,
            allowsCorrection: true,
            feedback: SelectionFeedback(minimumCount: 1)
        ))
    }
    return .accepted(selection)
}
```

将该函数包装为 `validate: { try validateSelection($0) }`，即可使用 `BoneInferenceValidatedOutputProcessor<Data, Selection, SelectionFeedback>`。另一个允许空列表的调用方可以直接返回 `.accepted(selection)`，不需要修改 SDK。修正执行器可以读取最新反馈，再返回一份新的 `Data` 候选。

## 次数、取消与错误

`maximumCorrectionAttempts` 接受 0…`Int.max - 1`；负数和 `Int.max` 抛出 `BoneInferenceOutputCorrectionPolicy.Error.invalidMaximumCorrectionAttempts`。保留一个计数位置用于初始校验，避免极端配置溢出；实际使用建议从 1 开始。

处理顺序为：

```text
完整候选 → 校验 → 接受并返回
               → 拒绝 → 未允许修正／无执行器／次数耗尽 → 返回最后拒绝
                      → 占用一次额度 → 修正执行器 → 新候选重新校验
```

修正闭包参数是**当前候选、最新拒绝报告、从 1 开始的修正序号**。格式和业务规则共用同一个次数上限。执行器应只产生新候选，不应递归调用另一套自动修正器。次数保证只涵盖处理器直接调用执行器的次数，不能约束闭包内部隐藏的网络重试、嵌套处理器或跨调用行为。

所有校验和修正的异步边界前后检查取消。执行器或校验器抛错时原样向外传播，不重试、不回退，不返回处理结果或回执。SDK 自身的配置错误只有固定类别；调用方错误可能包含私有内容，SDK 不替调用方清洗错误，也不记录错误。

取消是协作式的：外部代码若忽略取消，处理器只能在它返回后拒绝继续。超时、期限及响应保存由注入执行器负责；不将“已取消”当作远端未执行的证明。

## 预算与受控推理组合

修正执行器可以闭包捕获一个已配置的 `BoneRunBudgetMeter`、Engine、模型和请求构造器。以下函数展示一次文本推理的预算顺序，可由 `correct` 调用；它仅用于调用方已确认合法的无工具文本请求。

```swift
func requestCorrectionText(
    engine: any BoneInferenceEngine,
    request: BoneInferenceRequest,
    meter: BoneRunBudgetMeter,
    requestInputBytes: Int,
    estimatedCostMicrounits: Int64
) async throws -> String {
    try Task.checkCancellation()
    try await meter.reserveInference(
        inputBytes: requestInputBytes,
        estimatedCostMicrounits: estimatedCostMicrounits
    )
    try Task.checkCancellation()
    let response = try await engine.infer(request: request)
    // 先计已收到的完整响应，再判断是否可作为修正结果。
    try await meter.commitInference(outputBytes: JSONEncoder().encode(response).count)
    try Task.checkCancellation()
    let text: String
    switch response {
    case .finish(let finish):
        text = finish.text
    case let .assistantTurn(turn, reason, _, refusal, _):
        guard reason == .stop, refusal == nil, turn.toolCalls.isEmpty,
              turn.structuredOutputs.isEmpty, let content = turn.text else {
            throw BoneInferenceError.invalidResponse
        }
        text = content
    default:
        throw BoneInferenceError.invalidResponse
    }
    return text
}
```

调用方负责按照实际请求计算 `requestInputBytes`，包括提示词、历史和其他请求开销；费用估算使用实际模型费率，不能固定填 0 冒充真实费用预算。预留成功后的失败或取消不退款。示例在结果形态校验之前，以完整响应的编码大小调用 `commitInference`，与现有 Agent 计量方式一致；已返回但被拒绝的响应也消耗输出预算。该大小不是线上 wire 字节数。实际 Token Usage 和费用仍由既有推理结果／模型快照记录，不由输出处理器推断。

此示例不建立新的 Run，不额外计业务轮次；需要轮次管理时沿用既有 Agent 或调用方策略。若注入的执行器已经经过 Agent 的预算计量，不要在外层重复预留。授权、持久准入、响应保存和外部副作用必须先沿原执行管线完成；预算可用不等于获得授权。

## 完整结果与处理回执

上游 Provider 的拒绝、安全检查、截断规则、完整流式终态和 Tool Call／Result 配对保持原义。处理器是泛型入口，**无法自行证明任意 Input 是完整响应**：调用方必须在 Provider 完成检查后传入合适候选，不能把流式片段、半截 Tool 参数、拒绝或结果未知降级为普通可修正文本。不修改 Provider continuation，也不放宽已有协议验证。

`BoneInferenceOutputProcessingReceipt` 包含：

| 字段 | 含义 |
| --- | --- |
| `validationCount` | 本次调用完成返回前的校验次数 |
| `correctionAttemptCount` | 本次调用直接调用修正执行器的次数 |
| `outcome` | `.accepted` 或 `.rejected(固定问题类别)` |
| `usedCorrection` | 从 `correctionAttemptCount > 0` 推导，不单独编码 |

回执为 `Encodable`，没有自由文本和业务 ID。完整 `ProcessingResult`、`Validation` 和 `Rejection` 不提供自动 Codable，可能包含私有数据；不能将它们的调试描述当作安全日志。计数不代表实际 Provider 请求数、计费记录、授权或磁盘提交。抛错时不生成回执，失败请求事实由执行器既有记录追踪。

## 持久化与恢复边界

处理器实例无共享可变状态，可并发使用，但每次 `process` 都有独立额度。跨调用、App 重启和并发执行的全局次数由 Host 持久执行边界保障，SDK 不提供数据库或新的修正账本。

组合现有 Workflow 的顺序为：

```text
明确校验拒绝
→ Host 持久修正准入／预算
→ 既有授权与 Effect 受控执行
→ 保存完整响应
→ 重新校验
→ Host 验收通过后提交
```

收到响应与业务验收通过是两项事实。不合格缓存的读取、失效或保留由调用方决定，SDK 不自动删除、覆盖或刷新。结果未知继续沿既有恢复／对账机制处理，不能成为普通修正触发条件。

需要持久次数上限时，应在执行器内通过稳定请求身份和真实原子准入限制调用，再保存执行结果；不要在每次调用或重启后重建零计数并声称全局有界。不同 Store 之间没有自动原子事务。详见 [Workflow 与恢复](WorkflowAndRecovery.md) 和 [App Host 集成边界](CharacterHostIntegration.md)。

## 验证范围

`InferenceOutputValidationTests`、`InferenceOutputCorrectionTests`、`InferenceOutputValidationIntegrationTests` 覆盖默认关闭、通用类型组合、合法空结果、次数与反馈、取消边界、错误传播、并发隔离、固定回执隐私，以及本地文本修正和脚本引擎结构化修正。

这些离线测试不联网，不证明真实模型质量、Host 跨进程持久性或修正后的业务结果一定正确。SDK 未接入时既有调用不变；接入方应单独验证自己的验收规则和执行器。
