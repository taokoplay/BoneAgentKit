# Workflow 与恢复

## 状态和冻结 Plan

首版采用确定性 Workflow + 局部 Agent Step，不支持任意 DAG。Run、Step、Attempt 分层管理，终态不可复活；`committed` Attempt 不得重跑，`outcomeUnknown` 和 `commitUncertain` 需要明确恢复决策。

`BoneWorkflowPlan` 在创建 Run 时冻结 workflow identity/revision、ordered steps、step kind/revision。恢复直接解码冻结 Plan，不重新调用当前版本 builder。Checkpoint compatibility 显式返回 `resumeCompatible`、`requiresRestart` 或 `requiresUserDecision`，未知格式与未来 revision 不静默恢复。

## Persistence

`BoneWorkflowPersistence` 将 Run 与 Checkpoint 作为同一原子提交单元，提供 create、load、CAS commit 和 acquireLease。所有推进同时受单调 revision 与 lease generation fencing 约束。Host Adapter 应在同一原子事务中完成；不能把 Run 和 Checkpoint 拆到两个无法协调的 Store。

## Agent Step

`BoneWorkflowAgentStepController` 在每次 inference response 和每个 Tool result 后先提交 checkpoint，再发布安全事件并进入下一项工作。授权等待、pause、resume、cancel、成功、失败和取消终态都可恢复；事件不是持久事实源。Agent 运行统一由 `BoneAgent.run` 提供。

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
