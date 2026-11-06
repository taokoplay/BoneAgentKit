# 第三方参考来源登记

## 当前实现

Task 1 没有复制或嵌入第三方源码、注释或 Fixture。模型目录的公开声明数据在
`Sources/BoneAgentKit/Resources/AIProviderDefaults.json` 中以有限字段快照形式纳入，来源为
`models.dev/api.json` 及其 GitHub 生成源；对应 MIT 许可证原文保留在
`Sources/BoneAgentKit/Resources/ModelsDev-LICENSE.txt`。这批数据只用于可追溯的模型元数据展示与 Host 选择，不能当作官方执行验证，也不授予 SDK 能力。

来源与固定提交、展开规则和逐字段对照见 [ModelMetadataAndReasoning](ModelMetadataAndReasoning.md)
及 `.context/models-dev-audit/2026-10-09-cross-check.md`。

## 仅作思想参考

| 项目 | 参考范围 | 禁止事项 |
| --- | --- | --- |
| AgentRunKit | Agent 分层与运行时边界思想 | 不复制源码、注释、文档或测试材料 |
| SwiftHarnessAgent | Harness 与 Tool 抽象思想 | 不复制源码、注释、文档或测试材料 |
| SwiftLangChain | 链式推理与 Provider 抽象思想 | 不复制源码、注释、文档或测试材料 |
| [dsh-superagent-prototype](https://github.com/deepseek-ai/dsh-superagent-prototype/tree/8c32a9dc5d72c033816c6a8110b37f40cf94fba4) | DeepSeek Harness Team，MIT；只参考短预览、可读取资源与分页的通用思路。参考文件 `src/app/cards.ts`、`src/app/resources.ts`；本库依据自身 Tool/权限/UTF-8 约束独立实现 | 不复制源码、注释、文档、Fixture、领域模型或独特 API；不引入其 Node/DSH 依赖 |
| [pi-mono](https://github.com/badlogic/pi-mono/tree/2a32a605a9f18a5f0191f65358a2e764b2f69fc7) | 仅参考 coding-agent 的预处理/工具图片入口与 pi-ai 的三家 Provider 图片映射分层；本库按 Swift 不可变引用和显式模型预算独立实现 | 不复制源码、注释、Fixture 或具体 API；不引入 Node/图像库依赖 |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/tree/fcc0ad462172522aaf5c93a7b2e01f6b9f0b0159) | 仅参考 attachment 子系统的规范图片/请求变体分离，以及独立像素、字节、请求历史预算；本库由 Host 保管版本、SDK 按最终元数据复验 | 不复制实现、文档、Fixture 或插件架构；不把它的模型限制作为本库通用默认规则 |

这些名称仅用于来源治理记录，不代表本项目包含、链接或派生自对应代码。

## 内部来源

`Frameworks/AIProviderKit` 是用户自有 Git 历史中的现有代码，不属于上述第三方参考项目。后续迁移应通过 Git 历史保持可追溯，并继续遵守 BoneAgentKit 的公开命名边界。
