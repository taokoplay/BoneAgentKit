# BoneAgentKit 项目记忆

初始化：2026-11-18。项目：BoneAgentKit；技术栈：Swift / Swift Package Manager。

## 已确认的项目约束

既有项目记忆以 [.bone-project-wiki 的记忆索引](.bone-project-wiki/memory/MEMORY.md) 为入口，按索引阅读原始记录；不要手工改写插件生成的索引。

## 长文件读取决策

- 2026-11-18，首期交付“定位并引用局部原文”，不承诺“覆盖并处理全文”。读取末页不是全文覆盖证明，扫描完全部字节也不是摘要正确性的证明；性能回归用真实磁盘文件并将导入与按页读取分别计量。
- 大附件使用进程内私有磁盘快照，不把正文塞进现有会话存档。需要跨重启恢复时必须另行设计可重新授权的持久资源身份，不能凭历史引用恢复权限。
- 拒绝大附件导入或拒绝开启保存，不得改动旧存档；用户主动关闭保存或重置会话仍清除旧存档。验证这一区别的 iOS 回归要保留默认模拟器签名，以便用隔离 Keychain 测试真实的设置保存流程。

## 统一文件资源平台决策

- 2026-11-19，用户确认文件能力需要覆盖 PDF 结构化解析、Office 文件解析、二进制有界读取、非 UTF-8 转码、压缩包读取和跨进程/重启恢复。实现采用“原始持久 Artifact + 解析 Derived View + 独立 Agent Tools”三层；不把多格式逻辑塞入现有 UTF-8 文本 Reader。
- 原始快照使用应用私有内容寻址存储；会话存档只保存不透明资源引用和解析选项，不通过历史路径重新取得授权。现有 `resource.readText` 的 UTF-8 offset 合同保持不变。


## 文件资源平台进展

- 2026-11-19，文件资源平台已实现 PDF、DOCX/XLSX/PPTX、ZIP/GZIP、二进制有界读取以及 UTF-8、UTF-16、GBK、GB18030 转码。Office 首期只覆盖 OOXML，不承诺旧式 `.doc/.xls/.ppt` 的完整解析。
- 2026-11-19，原始文件使用内容寻址 blob，文本和解析结果使用派生视图。资源 `version` 绑定原始 SHA-256、资源 kind 和实际解析编码，metadata 路径绑定版本，避免同一字节按不同编码导入时互相覆盖。ZIP 已校验 local header、data descriptor、CRC32、路径、符号链接、单条和累计展开预算。
- 2026-11-19，文件资源定向回归共 25 项通过。PDF 测试仍会产生一条 CoreGraphics 日志，但断言通过。Nowledge Mem 服务当前不可连接，未能完成跨工具记忆检索。
- 2026-11-19，导入解析失败时会清理本次创建的原始 blob 和未提交的 UTF-8 派生视图，已有 metadata 引用的共享 blob 会保留。资源工具 Host 工厂暂未新增，当前继续由 handler 注入 session scope、资源 scope、权限重验、预算和撤销检查。

## 文件资源平台本轮增强

- 2026-11-20，新增 `BoneFileResourceFormatInspection` 格式探测模型和 `resource.detectFormat` 工具，覆盖 UTF-8、UTF-16 LE/BE、GBK、GB18030、PDF、DOCX、XLSX、PPTX、ZIP、GZIP 与二进制资源，并返回 MIME、可信度、编码、保护状态、解析器信息和能力集合。
- 2026-11-20，新增 `BoneFileResourceToolFactory`，统一包装取消检查、Host 授权重验、资源引用校验和结果预算校验。资源引用本身不承担权限语义，Host 仍负责 session scope、resource scope、version、撤销和读取预算。
- 2026-11-20，文件窗口请求现在在构造阶段绑定资源类型、窗口类型和定位字段。PDF 空页被视为有效页，旧 inspection JSON 缺少 `format` 字段时仍保持可解码。
- 2026-11-20，Demo 只负责内置工具装配和集成测试，PDF、Office、压缩包、编码和二进制解析继续位于 BoneAgentTools 核心 SDK。Demo 资源组工具数量已同步为 16 个。
- 2026-11-20，持久派生视图缓存、PDF/Office/ZIP/GZIP 展开缓存、统一持久资源搜索、资源 GC/quota/usage API 和 100 MiB RSS/磁盘性能基准仍未实现。旧式 `.doc/.xls/.ppt` 完整排版解析、ZIP/旧式 Office 密码解密仍属于后续范围。真实跨进程子进程恢复测试已补齐，覆盖删除原始文件后的文本/二进制恢复和篡改 blob 后的 `expired` fail-closed。
- 2026-11-20，验证过程中 `omx setup` 因用户目录备份目录权限返回 EPERM，但 `omx doctor` 通过 19 项检查。Nowledge Mem 服务 `127.0.0.1:14242` 当前不可连接。

## 文件资源平台本轮增强

- 2026-11-20，BoneAgentTools 核心 SDK 新增 `resource.readPDFLayout` 和 `resource.ocr`。PDF 布局按页返回媒体框、裁剪框、旋转、文本行、UTF-16 字符框、注释框和可选单页 PDF 数据，OCR 使用 PDFKit 渲染页面与 Apple Vision 识别文字，均受页范围和结果预算约束。
- 2026-11-20，PDF 密码只允许由 Host 在单次授权调用中临时提供，不进入 Tool Schema、资源引用、metadata 或结果 JSON。PDF 检查结果现在包含加密、锁定、复制权限和内容可访问权限，缺少密码和错误密码分别映射到固定错误。
- 2026-11-20，ZIP 条目增加 `isEncrypted`，加密条目可列出但读取返回 `protectedContent`。带 OLE Compound File 头的 `.docx`、`.xlsx`、`.pptx` 会识别为 `encrypted-office` 并关闭普通 OOXML 解析能力。当前不实现自定义 ZIP 或旧式 Office 密码解密。
- 2026-11-20，SDK 资源组工具目录从 14 个增至 16 个。Demo 的统一文件资源装配随后已扩展到完整 16 工具目录，解析仍由 BoneAgentTools SDK 提供。
- 2026-11-20，本轮验证使用受限沙箱外的 SwiftPM 测试，因为受限沙箱在 manifest 阶段返回 `sandbox_apply: Operation not permitted`。Nowledge Mem 服务 `127.0.0.1:14242` 仍不可连接。

## Workflow Agent execution snapshot 本轮进展

- 2026-11-20，Agent Step checkpoint 新增 Host-owned execution snapshot reference，引用绑定 run、step、attempt、checkpoint revision 和 lease generation。
- 2026-11-20，普通 checkpoint 只保存快照引用，不保存消息历史、Tool 参数、Tool result 或 Provider continuation；绑定快照后的下一次普通进度提交会清除旧引用。
- 2026-11-20，`BoneWorkflowAgentStepCheckpointStore` 新增快照与 checkpoint 的统一提交入口，旧三参数 Store 收到完整快照时在写入前明确拒绝，不进入未知提交状态。
- 2026-11-20，当前只提供快照模型、引用校验和 Store 协议，真实加密、认证、跨进程持久化、重启恢复和清理由 Host 实现，不能将 SDK 描述为已完成完整 Workflow 重启恢复。

## WorkflowRunnerDemo 统一文件资源接入

- 2026-11-21，WorkflowRunnerDemo 已完整接入 BoneAgentTools 的统一文件资源能力。Demo 通过 `DemoFileResourceHost` 管理导入、内容寻址快照、精确引用授权、撤销、跨进程恢复和会话存档；工具装配覆盖 `resource.inspect`、`resource.detectFormat`、`resource.readWindow`、`resource.readOffice`、`resource.listEntries`、`resource.readBytes`、`resource.readPDFLayout` 与 `resource.ocr`。
- 2026-11-21，iOS Agent Lab 的聊天附件和实验室工具工作台均支持文件选择、删除、预览和发送。预览按资源类型执行有界分页，支持文本编码、PDF 布局/OCR/密码重试、Office 结构、ZIP/GZIP 条目和二进制窗口。PDF 布局预览使用单页原始 PDF 数据叠加文本行、字符框和注释框，单页数据上限为 4 MiB。
- 2026-11-21，统一文件资源引用已进入消息、任务草稿和会话归档，旧归档缺少新字段时保持兼容。正文不进入会话存档，存档只保存有界引用状态；资源快照删除原始文件后仍可恢复，篡改快照会 fail-closed。
- 2026-11-21，新增 Demo 文件资源 Host 回归测试，覆盖 GBK 文本、跨实例恢复、删除来源文件后的二进制分页和精确资源版本授权。WorkflowRunnerDemo SwiftPM 全量测试 225 项通过，iOS Simulator `BoneAgentLab` 构建通过。SwiftPM 测试需在受限沙箱外运行，因为本机 `sandbox-exec` 会在 manifest 阶段返回 `sandbox_apply: Operation not permitted`。
- 2026-11-21，Demo 接入仍沿用 SDK 的能力边界。首期 Office 只覆盖 DOCX/XLSX/PPTX OOXML，旧式 `.doc/.xls/.ppt` 完整排版解析、ZIP 加密解密和旧式 Office 密码解密未实现；持久派生视图缓存、统一持久搜索、资源 GC/quota/usage API 也未随 Demo 接入。

## Apple 系统工具能力边界

- 2026-11-21，BoneAgentTools 与 WorkflowRunnerDemo 已接入五类 Apple 工具：`calendar.manage`、`reminder.manage`、`notification.manage`、`photo.manage`、`contact.manage`。跨平台 SDK 只定义 DTO、Schema、ToolDefinition 和 Host handler，EventKit、Contacts、Photos、UserNotifications 只位于 iOS Host。
- 2026-11-21，Apple 查询操作不重复弹出写入确认，创建、修改、完成、删除、安排通知和保存图片必须经过 DemoToolEffectStore 的绑定授权与 effect pipeline。联系人写操作已纳入与其他 Apple 工具相同的审批分支，避免误走联网授权路径。
- 2026-11-21，联系人工具首期支持按姓名、组织、电话号码或邮箱搜索，以及获取、创建、修改和删除。返回值只包含姓名、组织、电话和邮箱，查询结果最多 50 条，联系方式最多 8 项。Host 使用公开 Contacts API，不读取头像、备注、地址或系统私有数据库。
- 2026-11-21，相册工具返回实际创建的 `PHAsset` 标识。输入只允许 Host 已登记的图片 ID，正文不进入工具参数；当前使用添加权限，不扫描完整相册。
- 2026-11-21，Apple Notes、系统通知中心历史、Mail 收件箱、Messages 历史和任意系统 App 自动化不纳入通用 CRUD 工具。原因是缺少稳定的公开数据 API，私有数据库或 UI 自动化会带来系统版本、隐私和审核风险。定位、分享、相机、邮件草稿和短信草稿适合作为用户主动触发的前台能力，HealthKit 需要独立专项。
- 2026-11-21，本轮修复后 WorkflowRunnerDemo SwiftPM 全量测试达到 232 项通过，Apple 工具定向测试 8 项通过，iOS Simulator `BoneAgentLab` 构建通过。构建使用临时 ModuleCache 和 DerivedData，日志中只保留 CoreSimulator 与 AppIntents 环境提示。

## Apple 系统工具前台交互增强

- 2026-11-21，新增的 `location.lookup`、`share.present` 和 `compose.present` 已从 SDK 契约接入 WorkflowRunnerDemo。定位使用 Core Location/MapKit 的一次性前台查询，分享使用系统分享面板，邮件和信息使用系统草稿编辑器。
- 2026-11-21，iOS Host 为定位、分享和邮件/信息编辑器增加请求身份、取消收敛和重复调用保护。取消会关闭当前系统 UI 并恢复当前工具调用，延迟到达的旧系统回调不会恢复后续请求。分享和草稿内容继续受 Host 已登记资源、系统能力检查和 Demo 授权确认约束。
- 2026-11-21，公开文档已同步八类 Apple 工具及其边界。Apple Notes、通知中心历史、Mail/Messages 历史、静默发送、任意系统 App 自动化仍不纳入通用工具集，相机和 HealthKit 保留为后续专项。
