# Local Model Download Module Design

**Date:** 2026-09-01
**Status:** Approved

## Goal

在 `BoneAgentLocalRuntime` 中提供安全、可测试、可恢复的模型下载能力，复用现有 Catalog 与 Store，不引入具体推理 Runtime，也不把蜂窝确认、业务文案和产品推荐移入 Kit。

## Architecture

下载层分成三部分：

1. `BoneLocalModelDownloadTransport`：可注入的异步传输协议；生产实现使用 URLSession，测试使用确定性 fixture。
2. `BoneLocalModelDownloadCoordinator`：actor 状态机；负责同模型单任务、空间预检、下载源排序与受控切换、暂停/恢复/取消、完成后的 Store 校验安装。
3. `BoneLocalModelDownloadSecurityPolicy`：验证初始 URL 和每一次 HTTP 重定向只能进入当前 Source 的 HTTPS Host 白名单。

Coordinator 不保存 UI 文案。Host 观察类型化状态与错误，自行决定显示、蜂窝授权以及是否持久化 resume data。

## State and Data Flow

状态序列为：

```text
idle → preparing → downloading → paused → downloading → verifying → installed
                                  ↘ cancelled
                       any active state → failed
```

流程：

1. Host 传入模型、环境快照与下载策略。
2. Coordinator 检查模型未安装、无同模型活动任务、磁盘空间不少于 Artifact 大小加安全余量。
3. 按 `priority` 稳定排序 Source，Transport 只接收一个已验证 Source。
4. Transport 将下载内容落入 Store 同目录的 staging 文件，并持续发出字节进度。
5. 完成后 Coordinator 进入 `verifying`，调用 `BoneLocalModelStore.installDownloadedFile` 完成大小/SHA-256 与原子安装。
6. 网络瞬断、超时、DNS/连接失败和 HTTP 5xx 可切换到下一 Source；4xx、安全违规、取消、大小或哈希失败不自动切换。

## Pause, Resume, Cancel

- pause 请求 Transport 产生 opaque `Data`；Coordinator 进入 `.paused(resumeData:)`。
- resume 仅接受同一模型当前 paused 状态中的 resume data。
- Host 可以选择持久化 resume data；Kit 不写 UserDefaults。
- cancel 取消活动传输并删除 staging/partial 与内存中的 resume data，但不删除已安装模型。
- 若 Transport 或服务端无法生成 resume data，pause 返回类型化 `.resumeDataUnavailable`，而不是伪装成功。

## Security

- 初始 URL 必须是 HTTPS，并匹配 Source 的 `allowedHosts`。
- 每次重定向都重复同样校验；拒绝 HTTP 降级、未知 Host、端口/路径伪装。
- 日志、状态和错误不得包含下载 URL 查询参数、Token 或本地文件内容。
- Coordinator 只在已知 Artifact 大小基础上做磁盘预检，最终完整性由 Store 的大小和 SHA-256 再验证。
- 下载失败不会覆盖已安装模型。

## Public Boundaries

Kit 提供状态机、策略、安全规则、默认 URLSession Transport 与错误分类。Host 负责：

- 用户发起下载；
- 蜂窝网络授权；
- 中文/产品化错误文案；
- 前后台策略；
- resume data 的持久化位置；
- 下载并发数量和产品推荐。

本批不实现 Background URLSession、全局队列调度、Runtime Probe、llama.cpp 或 Foundation Models。

## Testing

- 纯单元测试验证源排序、空间不足、状态变化、受控切源、校验安装、暂停/恢复/取消。
- 安全策略测试覆盖可信重定向、未知 Host、HTTPS 降级和 wildcard 边界。
- 默认 URLSession Transport 通过自定义 URLProtocol 测试 HTTP 状态和重定向策略；若系统 URLProtocol 无法稳定生成 resume data，则该语义由注入式 fixture 验证。
- 完整 Package 必须通过默认测试、Swift 6 strict concurrency 和 warnings-as-errors。
