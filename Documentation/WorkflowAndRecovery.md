# Workflow 与恢复

## 状态和冻结 Plan

首版采用确定性 Workflow + 局部 Agent Step，不支持任意 DAG。Run、Step、Attempt 分层管理，终态不可复活；`committed` Attempt 不得重跑，`outcomeUnknown` 和 `commitUncertain` 需要明确恢复决策。

`BoneWorkflowPlan` 在创建 Run 时冻结 workflow identity/revision、ordered steps、step kind/revision。恢复直接解码冻结 Plan，不重新调用当前版本 builder。Checkpoint compatibility 显式返回 `resumeCompatible`、`requiresRestart` 或 `requiresUserDecision`，未知格式与未来 revision 不静默恢复。

## Persistence

`BoneAgentPersistence` 将 Run 与 Checkpoint 作为同一原子提交单元，提供 create、load、CAS commit 和 acquireLease。所有推进同时受单调 revision 与 lease generation fencing 约束。Host Adapter 应在同一原子事务中完成；不能把 Run 和 Checkpoint 拆到两个无法协调的 Store。

## Agent Step

`BoneAgentWorkflowStepController` 在每次 inference response 和每个 Tool result 后先提交 checkpoint，再发布安全事件并进入下一项工作。授权等待、pause、resume、cancel、成功、失败和取消终态都可恢复；事件不是持久事实源。旧一次性 `BoneAgentKit.run` API 保持兼容。

## 副作用

有副作用的 Tool 遵循：

```text
Effect Intent
→ stable idempotency key
→ Authorization revalidation
→ Execute
→ Effect Receipt
→ atomic step commit
```

策略包括 naturallyIdempotent、idempotencyKeyRequired、reconcilable、compensatable、nonRecoverableRequiresUserDecision。副作用可能成功但 Receipt/Checkpoint 尚未写入的窗口必须先 reconcile，不能盲目重跑。无法查询的外部系统进入 `outcomeUnknown / recoveryRequired`；Kit 不保证 exactly-once。

cancel 意图必须先持久化。执行前可以取消；进入不可取消副作用提交区后必须完成 Receipt 或对账。App 被系统终止不会自动后台永久运行，下次启动 acquireLease 后恢复。

## 未知副作用与授权终止的错误处理

高风险 Tool 越过 `executionStarted` 后抛错（包括取消），管线返回 `outcomeUnknown`，Agent 返回 `toolOutcomeUnknown`；Tool 已返回但 Receipt 写入或提交未确认，分别返回 `recoveryRequired` / `toolRecoveryRequired`。这些错误不会被 `collectAll` 收集，必须停止后继工具与推理。Host 使用原 Effect identity 读取事实并先 reconcile，禁止把它们映射成“确定未执行”后创建新 identity 重试。

等待授权的 Step 可以取消或失败，终态 checkpoint 会清除 ticket 并在提交前校验。waiting 不能直接 `finish(.succeeded)`；必须先通过匹配 ticket 的 `resumeAfterAuthorization`，再进入成功路径。取消后的迟到 progress 不可复活终态。
