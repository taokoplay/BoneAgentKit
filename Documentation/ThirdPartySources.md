# 第三方参考来源登记

## 当前实现

Task 1 没有复制或嵌入第三方源码、文档、注释、Fixture 或 LICENSE 文本。

## 仅作思想参考

| 项目 | 参考范围 | 禁止事项 |
| --- | --- | --- |
| AgentRunKit | Agent 分层与运行时边界思想 | 不复制源码、注释、文档或测试材料 |
| SwiftHarnessAgent | Harness 与 Tool 抽象思想 | 不复制源码、注释、文档或测试材料 |
| SwiftLangChain | 链式推理与 Provider 抽象思想 | 不复制源码、注释、文档或测试材料 |

这些名称仅用于来源治理记录，不代表本项目包含、链接或派生自对应代码。

## 内部来源

`Frameworks/AIProviderKit` 是用户自有 Git 历史中的现有代码，不属于上述第三方参考项目。后续迁移应通过 Git 历史保持可追溯，并继续遵守 BoneAgentKit 的公开命名边界。
