# ParsingBook CharacterAgentHost 接入

> 当前状态：本章描述已实现的 Host/Resolver/Bridge/Persistence seams 与目标装配方式。ParsingBook 生产 UI、`AICharacterRecognitionTaskManager`、真实 GRDB Store、任务中心 action handler 和 `.agent/.compare` Live Smoke 尚未接入该链；当前灰度 flags 默认关闭。不要把组件 Contract PASS 解读为生产角色 Agent 已启用。

## 责任边界

目标链路为：

```text
CharacterAgentHost
→ Bone Workflow / Agent Step
→ AnalyzeCatalogCharactersTool
→ AICharacterLightIndexExtractionAdapter
→ CharacterAgentWorkflowBridge
→ 现有 AICharacter 业务 Service
```

Kit 不拥有正文、角色 Parser、Evidence Grounder、数据库坐标、角色合并、手工字段保护、逐章业务持久化或 Task DB。Agent、Tool、Skill 与 MCP 不直接访问 SQL 或数据库文件。

## 不透明引用

`CharacterAgentReferenceStore` 为书籍和章节签发随机 Token。Token 绑定 Run、书籍 scope、允许 range、章节 revision、签发顺序和 uptime 过期点，不编码 bookId、siteIdent 或 catalogIndex。Resolver 在 App 本地重查同书同站点、章节存在性和 revision；range 只能收窄，重复、跨书、跨 Run 和过期引用 fail-closed。

## Bridge 与 Host

`CharacterAgentWorkflowBridge` 优先复用未完成业务 Task。只有正式 Store 已逐章 persisted 的章节计入成功；明确空角色可以完成；部分成功保留失败章节。成功、失败、缓存集合必须相互互斥并完整覆盖请求。自动证据索引禁止返回候选集合；候选写入必须消费用户确认。

`CharacterAgentHost` 将 Agent Run 与业务 Task ID 分离映射。`CharacterAgentPersistenceAdapter` 注入原子 create+mapping/load/CAS/lease 操作；业务 Task DB 仍是章节和角色事实源。Provider 凭据只由 App Factory 临时注入，不进入 Store。当前仓库只完成 seam 与 Harness Storage Contract，尚未把该 Adapter 装配到 `TaskDBManager` 的真实 GRDB transaction。

## 灰度与任务中心

Feature flags 设计用于控制 Agent 路由和全局任务投影。当前默认关闭且尚无生产 composition root 调用 `configureCharacterAgent`、`publishCharacterAgent` 或 `setActionHandler`。完成装配后，关闭 kill switch 必须回退 legacy 链并移除 Agent 卡片。同一书籍重叠章节 scope 只能有一个 writer lease，禁止新旧链并发写。任务中心只展示 persisted、failed、total 安全计数；停止动作等于 cancel，不等于 abandon。cancelled 独立于 failed。

## Smoke

`AssistantCharacterLiveSmokeMode` 与安全报告已定义 legacy、agent、compare，但当前 Runner 的执行实现仍只复用 legacy `AICharacterExtractionService`；`.agent`/`.compare` 只是未启用的模式契约，不是 Agent E2E 证据。用户确认联网和费用前 `providerRequests=0`。未来 compare 必须复用一次真实 Provider 响应，不重复模型请求。完成生产装配后，真机还需验证单章、空角色、部分成功、缓存、取消、强杀恢复和任务中心；命令行 Contract 与 Simulator 不能替代。
