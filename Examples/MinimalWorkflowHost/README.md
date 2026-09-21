# MinimalWorkflowHost

独立的 Host 编译与运行 Fixture，仅依赖：

```swift
import BoneAgentKit
import BoneAgentTesting
```

示例验证：

- `BoneInMemoryWorkflowPersistence` 创建、获取新 lease 并恢复冻结 Workflow Plan；
- 普通公开只读 Tool 不需要 Host 授权；
- 可逆私有写 Tool 必须持有并一次消费绑定的 `BoneAuthorizationGrant`；
- `BoneScriptedInferenceEngine` 提供纯合成模型结果，不联网、不读写文件。

从仓库根目录运行：

```bash
swift run --package-path Examples/MinimalWorkflowHost MinimalWorkflowHost
```

该独立 Package 是编译与合成运行 fixture，不是生产 App 或数据库验收。授权消费必须携带与 grant 相同的 nonce；示例不省略该绑定。
