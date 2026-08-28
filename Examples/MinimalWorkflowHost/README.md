# MinimalWorkflowHost

独立于 ParsingBook 的第二 Host 编译与运行 Fixture，仅依赖：

```swift
import BoneAgentKit
import BoneAgentTesting
```

示例验证：

- `BoneInMemoryAgentPersistence` 创建、获取新 lease 并恢复冻结 Workflow Plan；
- 普通公开只读 Tool 不需要 Host 授权；
- 可逆私有写 Tool 必须持有并一次消费绑定的 `BoneAuthorizationGrant`；
- `BoneScriptedInferenceEngine` 提供纯合成模型结果，不联网、不读写文件。

运行：

```bash
zsh Tests/BoneAgentKit/run_minimal_workflow_host_example.sh
```
