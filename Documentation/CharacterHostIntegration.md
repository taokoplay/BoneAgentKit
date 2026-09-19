# App Host 集成边界

## 责任边界

BoneAgentKit 提供供应商无关的推理、Agent、Tool、Workflow 与 Persistence 契约。具体 App Host 负责业务领域模型、数据来源、用户界面、业务规则、持久化实现、权限策略和产品级任务展示。

需要可恢复工作流时，典型链路为：

```text
App Host
→ Bone Workflow / Agent Step
→ Host-defined Tool Adapter
→ App Business Service
```

Agent、Tool、Skill 与 MCP 不应直接访问 Host 的数据库文件或全局状态。Host 通过显式 Adapter 和不透明引用向 Kit 暴露最小能力，Kit 不编码业务主键、存储位置或领域对象结构。

直接推理或短期查询可使用 `App Host → BoneAgent.run → Host Tool → Business Service`，不要求接入 Workflow。业务数据库、模型文件存储和 Agent 检查点是不同职责；已有业务数据库不等于已实现 `BoneWorkflowPersistence`。

## 不透明引用

Host 可以为业务对象签发随机、不透明、有限时效的引用。Resolver 应在 Host 本地重新检查 scope、revision、有效期和调用方权限；允许范围只能收窄。重复、跨 scope、跨 Run 或过期引用应 fail closed。

## Persistence Adapter

Host 通过 `BoneWorkflowPersistence` 实现 create、load、CAS commit 与 lease fencing。Run 与 Checkpoint 必须作为一致的原子提交单元；具体数据库和事务技术由 Host 自行选择，Kit 不作假设。

`acquireLease` 当前提供 revision CAS 下的 generation 接管，不提供 owner、到期时间或续租。Host 决定何时及由谁接管，旧 worker 的写入由 generation fencing 拒绝。`BoneInMemoryWorkflowPersistence` 仅用于进程内存储，不能跨进程恢复。

Adapter 可使用 [Host 持久化契约验收套件](Testing.md#host-持久化契约验收)。每场景必须隔离测试资源，不得直接使用生产数据库；缺失 reopen/独立连接能力时返回 skipped。真实恢复还需 Host 完成进程中断、事务、Effect Intent/Receipt 与对账等验收，不能用该套件替代。

Provider 凭据只应由 Host composition root 临时注入，不得进入 Checkpoint、日志、事件或安全报告。

## 模型使用记录

需要按对话留存“这次会话用了哪个模型”时，Host 通过初始化 `BoneAgent` 时传入的 `BoneAgentModelSnapshotSink` 接收每个 Run 的 `BoneAgentRunModelSnapshot`，再按自己的会话标识累加 `usageByResponse` 与计数并落盘。Kit 不持久化快照、不知道会话边界，也不提供跨 Run 聚合。

快照在 Run 返回值或错误抛出之前交付且只交付一次，因此成功分支与 `catch` 分支都可以安全地假设快照已到达。投递是 `await` 的：闭包内的耗时会计入 Run 自身时间并占用 Agent 的串行执行上下文，写库或写文件应放到 Host 自己的任务里。Kit 不为投递设超时，也不在投递期间释放 Run 占用：sink 挂死会让该 Agent 之后的每次 `run` 直接得到 `runAlreadyInProgress`，所以 sink 必须尽快返回。

快照的 `terminalState` 只描述 Agent Run 本身。使用 `runWorkflowStep` 时，快照在 `controller` 提交 step 终态之前就已投递，因此 step 的持久化失败会表现为“快照是 succeeded、调用方拿到错误”；会话记录不能把快照终态当作 workflow step 的权威终态，后者以 Host 的 checkpoint 为准。

Host 通过 `BoneAgentModelSnapshotContext` 按 Run 注入 Provider 身份、模型显示名与别名、能力 Profile、上下文限制、目录版本和生效的服务端推理策略，因为这些事实不在 `BoneInferenceEngine` 协议上。未提供的字段保持未知，Host 不得自行用显示名或默认值补全；显示名与别名只做空白归一，空串等于未提供，且只能写模型目录名称，不得把用户内容或对话文本传入。会话记录只应保存模型身份、证据来源、限制、参数回显、计数与用量，不得把 Prompt、响应正文或 Tool 内容一并写入。

## 灰度与产品状态

是否启用 Agent 路由、如何回退旧链路、如何展示任务、何时允许停止或重试，均由 Host 的 Feature Flag 和产品策略决定。事件流不是业务事实源；页面应以 Host 持久化事实和 Kit 稳定状态为准。

## 验证

生产接入应按实际启用的能力覆盖正常完成、空结果、失败和取消；若使用缓存或部分成功策略，应验证对应行为；若启用可恢复 Workflow，还应覆盖进程恢复和持久化冲突。命令行 Contract 与 Simulator 不能替代目标平台上的真实业务验证。
