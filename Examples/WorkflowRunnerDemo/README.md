# WorkflowRunnerDemo

独立 SwiftPM 命令行 Demo，用合成模型和真实 BoneAgentKit 执行链验证 [Runner](../../Documentation/Plans/2026-11-12-bone-agent-workflow-runner-design.md) 与 [Prompt 组装](../../Documentation/Plans/2026-11-12-bone-agent-prompt-compositor-design.md) 的关键设计。

所有 `Demo*` 类型仅位于此示例；尚未加入 SDK 正式 API。模型由 `BoneAgentTesting.BoneScriptedInferenceEngine` 提供固定响应，但工具调用、工具结果回填、能力校验、Step Controller、Run Controller 和底层内存 CAS 使用真实 SDK 实现。

需要在手机上点选测试时，使用 [Agent Lab iPhone App](iOS/README.md)。它统一“对话”和“实验室”，共用模型、助手说明与工具配置，提供模型回复、工具计算、连续对话和助手说明的真实请求检查；流式统计、上下文、会话保存、附件、结构化验收、Workflow 与本地模型文件保留。七个离线场景和 Prompt 组装继续用于本命令行与自动回归，不再作为手机独立入口；附带 [Demo logo](Brand/agent-lab-icon.png)。

## 运行

在仓库根目录执行，需要 macOS 13+ 和 Swift 工具链；回归测试使用 Swift Testing，需要 Swift 6+。

```bash
swift run --package-path Examples/WorkflowRunnerDemo WorkflowRunnerDemo
```

无需 API Key，不联网、不请求付费模型、不修改业务文件。运行数据与工具计数只驻留内存，正常完成后输出 `PASS: 7/7 demo scenarios`；断言失败会以非零状态退出。

## 有界观察流离线验证

```bash
swift run --package-path Examples/WorkflowRunnerDemo WorkflowRunnerDemo --bounded-stream
```

此模式使用合成流式 Engine 和真实 `BoneAgent.runObservedEvents`，不运行七个默认场景。它检查 128 个 Unicode 增量的完整交付、本流序号、事件与状态/Token 的 Run ID 关联、唯一完成结果，以及配置为 4 个事件的队列峰值，成功后输出仅含计数与布尔值的 JSON。任何契约检查失败均以非零状态退出。

实现位于 [DemoBoundedStreaming.swift](Sources/WorkflowRunnerDemo/DemoBoundedStreaming.swift)。所有 Demo 类型和呈现逻辑保留在示例中；正式 UI 由接入方实现。该验证不证明真实网络吞吐、进程 RSS 或线上模型能力。

## 演示场景

| 场景 | 实际检查 |
| --- | --- |
| 默认 Agent 流程 | 工具调用 → 真实读工具执行 → 结果进入第二次模型请求 → step succeeded → Run completed |
| 自定义 review 步骤 | 替换执行器，复用同一 checkpoint 桥接；Run 保持 running，交给 Host 决定业务终态 |
| planning 拦截写工具 | 只暴露 `demo.read`；即使脚本伪造写调用、Prompt 声称已批准，写计数仍为 0 |
| executing 保留授权要求 | 可以暴露写工具，但没有 Effect Store/调用授权时仍拒绝，写计数为 0 |
| dispatch 回执丢失 | 实际提交 dispatchPrepared 后抛错；新 Runner 返回 requiresRecovery，无重跑、无恢复写入 |
| step 终态回执丢失 | 工具执行和步骤终态已保存；新 Runner 换代后只完成 Run 收口，不重复推理或工具，不补造输出正文 |
| Prompt 替换与追加 | 基础指令替换，runtimeGuidance 与 append 保留；facts 只加入当前 user，组合后的请求确实进入 Engine |

合成模型的最终文本是预设结果，不代表模型理解或遵循了 Prompt。检查依据是收到的强类型请求、工具执行计数和保存的 checkpoint，而非响应文案。

## 自动回归

```bash
swift test --package-path Examples/WorkflowRunnerDemo \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

[WorkflowRunnerTests](Tests/WorkflowRunnerDemoTests/WorkflowRunnerTests.swift) 额外验证规划模式允许读取、未知执行器版本/多步骤/变更输入的零写入拒绝、响应与 Run 终态回执丢失、冻结范围不可扩权、过期 revision 拒绝，以及 checkpoint 中不保存 Prompt/输出正文。

[PromptCompositorTests](Tests/WorkflowRunnerDemoTests/PromptCompositorTests.swift) 验证 inherit/replace/清空 base/append、稳定排序、重复 ID、UTF-8 精确容量、CRLF 原样保留、运行数据 JSON 转义、非法输入及错误脱敏。

共享接入回归还覆盖真实 Provider 的 SSE 适配与多轮历史、上下文整理及可选摘要、私有状态导出恢复、存档中断标记、SDK 图片预处理/引用/预算、文本分页权限、结构化结果校验和有界修正、真实模型 Workflow 控制器、本地模型管理。所有自动测试均使用假凭据与注入传输，不发付费请求或下载模型。

## 阅读与修改

- [DemoMain.swift](Sources/WorkflowRunnerDemo/DemoMain.swift)：命令行入口；[DemoScenarios.swift](Sources/WorkflowRunnerDemo/DemoScenarios.swift) 为命令行与手机共用的七场景实现，可从 `customFlow` 查看如何替换步骤。
- [DemoWorkflowModels.swift](Sources/WorkflowRunnerDemo/DemoWorkflowModels.swift)：模式、能力交集、默认执行器与 checkpoint codec。
- [DemoWorkflowRunner.swift](Sources/WorkflowRunnerDemo/DemoWorkflowRunner.swift)：预检、启动、Step Store 桥接与受限恢复。
- [DemoFixtures.swift](Sources/WorkflowRunnerDemo/DemoFixtures.swift)：合成模型、读写计数和四类回执丢失故障注入。
- [DemoPromptCompositor.swift](Sources/WorkflowRunnerDemo/DemoPromptCompositor.swift)：纯值 Prompt 装配。默认 4096 字节只是 Demo 的容量选择。

## 原型边界

命令行七场景仅支持单步骤和非流式合成推理。自定义执行器是可信 Host 代码，不是系统沙箱；此原型不实现生产 Effect Store、真实授权 UI、交互式暂停、动态 DAG 或任意中途推理恢复。iPhone 真实模型与私有会话能力的范围见 [App 说明](iOS/README.md)。

`resume` 重建的是 Runner 对象，仍共享同一个进程内 Store；这不是跨进程崩溃恢复。`takeoverAuthorized` 是隔离 fixture 的 Host 授权声明，不是身份认证。工具、输入和策略版本由示例固定；生产接入必须由 Host 保证版本真实性、权限检查与实际副作用 fencing。

七场景的 checkpoint codec 和 Prompt 类型只实现设计中的受测子集：固定 synthetic-model、内存输入引用和 `sectionIDs`，没有完整 Prompt manifest。未知执行保持 requiresRecovery；没有保存的原始结果不会通过再次请求模型补回。测试通过只证明所覆盖的行为；iPhone 的可选聊天私有状态恢复与 Workflow 进程内检查点分别管理。
