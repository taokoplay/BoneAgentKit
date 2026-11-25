# 第三方参考来源登记

## 当前实现

Task 1 没有复制或嵌入第三方源码、注释或 Fixture。模型目录的公开声明数据在
`Sources/BoneAgentKit/Resources/AIProviderDefaults.json` 中以有限字段快照形式纳入，来源为
`models.dev/api.json` 及其 GitHub 生成源；对应 MIT 许可证原文保留在
`Sources/BoneAgentKit/Resources/ModelsDev-LICENSE.txt`。这批数据只用于可追溯的模型元数据展示与 Host 选择，不能当作官方执行验证，也不授予 SDK 能力。

来源与固定提交、展开规则和逐字段对照见 [ModelMetadataAndReasoning](ModelMetadataAndReasoning.md)
及 `.context/models-dev-audit/2026-10-09-cross-check.md`。

2026-11-25 的 Provider 兼容模型发现、响应字段归一化、endpoint fallback、超时和匿名读取逻辑均为 BoneAgentKit 自有实现。它们没有复制兼容网关的 SDK 或服务端代码。`models.dev` 快照只用于有限的展示元数据和 Host 选择，不能证明当前账号可用，也不能证明模型能力已经通过 Provider Smoke。

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

## 2026-11-12 设计调查记录

以下参考用于 [Runner 草案](Plans/2026-11-12-bone-agent-workflow-runner-design.md) 和 [Prompt 组装草案](Plans/2026-11-12-bone-agent-prompt-compositor-design.md)，不属于已接入的依赖或已实现能力。

| 调查对象 | 可追溯线索 | 本库采用的通用思路 |
| --- | --- | --- |
| DeepSeek Harness 本地安装产物 | 归档内 `@deepseek-ai/dsh-system-prompt/README.md`、`dsh-agent-loop/README.md`、`dsh-session-checkpoint-policy` 的静态调查报告 | 分节装配、运行事实与指令分开、持久化触发点明确列出 |
| PI-Desktop 本地安装产物 | `agent-runtime/sidecar.js` 的 Prompt 组装与宿主工具 RPC 线索，以及 `skills/plugin-development.md` 的明文契约 | 基础替换与追加分开；运行模式须落实到可见工具和实际执行限制 |

证据范围为此前安装包的明文说明与可读 JavaScript 静态调查，未固定产物哈希或完整源码提交，未做动态故障或权限验证。压缩代码和字符串只能作为定位线索，不据此断言某项目没有某项能力，也不把会话日志、Prompt 排序或缓存行为等同于本库的恢复/授权保证。

本次仅独立撰写设计文档；不复制原 Prompt、源码、注释、Fixture、独特编号表或 API 组合，不引入其运行时依赖。工具执行外置、完整模式系统、Skill/插件框架等调查项本次不实现。

## 内部来源

`Frameworks/AIProviderKit` 是用户自有 Git 历史中的现有代码，不属于上述第三方参考项目。后续迁移应通过 Git 历史保持可追溯，并继续遵守 BoneAgentKit 的公开命名边界。

## 搜索 API 契约核对（2026-11-16）

Agent Lab 的 DeepSeek 搜索适配依据 [官方 Search API Reference](https://api-docs.deepseek.com/api/search/) 与 [Search & Fetch 指南](https://api-docs.deepseek.com/guides/search/)独立实现：固定 POST `/v1/tools/search`、Bearer 认证、查询最多 128 个 Unicode 字符、结构化 `results`，本 Demo 仅请求标题/链接/短摘要（`need_content=false`），不模拟私有接口、不自动操作网页产品。官方文档声明不代表已验证任何账号权限、余额、在线质量或网站内容复用许可；本次回归使用自行编写的离线响应，不复制官方 Fixture，不新增第三方运行时依赖。
