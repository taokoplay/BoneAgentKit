# BoneAgentKit 文档地图

按阅读目标选择入口。首次接入建议从“开始使用”依次阅读；历史基线和实施计划仅供维护者追溯，不是调用方的必读内容。

## 开始使用

| 文档 | 适用场景 |
| --- | --- |
| [5 分钟快速开始](GettingStarted.md) | 定义第一个 Engine、Tool 和 Agent |
| [Swift Package 接入](PackageIntegration.md) | 固定版本、选择 Product、验证依赖方向 |
| [Provider 与 Tool 扩展](ProviderIntegration.md) | 接入模型 SDK、Provider、Tool 和业务 Service |
| [MinimalWorkflowHost](../Examples/MinimalWorkflowHost/README.md) | 编译运行独立 Host Fixture |

## 核心概念

| 文档 | 内容 |
| --- | --- |
| [架构与模块边界](Architecture.md) | Agent Harness、模块职责和依赖方向 |
| [Tool Calling](ToolCalling.md) | 统一事实模型、Provider wire、调度与授权 |
| [Workflow 与恢复](WorkflowAndRecovery.md) | 状态机、CAS、lease、Effect 和恢复语义 |
| [App Host 集成边界](CharacterHostIntegration.md) | 不透明引用、Persistence Adapter 和产品职责 |

## 本地模型

| 文档 | 内容 |
| --- | --- |
| [本地模型基础设施](LocalModels.md) | Catalog、下载、存储、规划、Probe 和状态流 |
| [llama Adapter 设计](Plans/2026-09-01-bone-agent-llama-design.md) | 不绑定二进制的 Runtime seam |
| [llama.cpp Binary 设计](Plans/2026-09-01-bone-agent-llama-cpp-binary-design.md) | 独立 Binary Package 和 provenance 边界 |

## 运行与治理

| 文档 | 内容 |
| --- | --- |
| [Testing 与 Harness](Testing.md) | Product 隔离、测试矩阵、事件和排错 |
| [安全与隐私](SecurityAndPrivacy.md) | 数据边界、日志、Endpoint 和真实 Smoke |
| [公开 API 基线](../API_BASELINE.md) | 稳定范围、关键入口和兼容承诺 |
| [发布检查清单](../RELEASE_CHECKLIST.md) | 技术、安全、许可、迁移和回滚门禁 |
| [变更记录](../CHANGELOG.md) | 版本变化和版本列车 |
| [来源与许可](LicensingAndProvenance.md) | clean-room 证据、逐文件来源和审查状态 |
| [第三方参考来源](ThirdPartySources.md) | 思想参考和第三方材料登记 |

## 维护者资料

以下材料记录历史决策和实施过程，可能包含已经完成的阶段性约束：

- [现代化基线](ModernizationBaseline.md)
- [Provider 迁移契约](LegacyProviderMigration.md)
- [实施计划目录](Plans/)

## 文档约定

- README 维护对外入口，不承载完整历史；
- 本索引维护正式文档地图；
- 设计和实施计划进入 `Documentation/Plans/`；
- 公开说明不得包含调用项目名称、Host 专有实现或本机绝对路径；
- 相对链接和标题层级由 `Scripts/check-public-documentation.sh` 验证。
