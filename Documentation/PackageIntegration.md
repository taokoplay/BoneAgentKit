# Swift Package 与独立仓库演进

## 当前形态

`BoneAgentKit` 已作为 ParsingBook 仓库内独立 Swift Package 维护：

```text
Frameworks/BoneAgentKit
```

本次 Package 化用于建立真实编译边界、私有 Resources、独立测试和可复用 API；不是独立 Git 仓库发布。

## 独立仓库门禁

只有满足以下条件才从 ParsingBook 提取为独立 Git 仓库：

1. 真实 Provider/App 沙箱验证完成；
2. 公共 API 稳定并有兼容策略；
3. 出现第二真实调用方，或已有明确接入计划；
4. Tests 不依赖 ParsingBook 业务类型；
5. Swift/Deployment Target、来源、安全、接入和版本策略完整；新项目可在 **15 分钟** 内完成最小接入。

这里的真实 Provider/App 沙箱验证必须证明至少一个**真实业务跑通**，不能只依赖 Scripted Harness。

独立 Package 和独立 Git 仓库是两个阶段。当前优先保持 Kit API 与 App 调用方可在一个提交中原子演进。

## 依赖方向

```text
UI ───────────────→ Business Service
Agent Adapter ────→ Business Service
Package ✕────────→ App Business Service
```

Package 不引用 App 数据库、UIKit、Keychain、GRDB、SwiftyJSON 或业务 Service。Provider Catalog JSON 与 icon 是 Package 自有静态资源；用户密钥、用户 Provider 和运行结果不进入 Resources。

正确的可退出性是：删除 Adapter 后，业务 Service 不受影响。如果删除 Adapter 会迫使数据库或业务领域重写，说明 App 逻辑已经泄漏进 Package，必须先移回项目层。
