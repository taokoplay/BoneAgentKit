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
- 2026-11-20，持久派生视图缓存、PDF/Office/ZIP/GZIP 展开缓存、统一持久资源搜索、资源 GC/quota/usage API 和 100 MiB RSS/磁盘性能基准仍未实现。旧式 `.doc/.xls/.ppt` 完整排版解析、ZIP/旧式 Office 密码解密和 Demo 端文件能力接入仍属于后续范围。真实跨进程子进程恢复测试已补齐，覆盖删除原始文件后的文本/二进制恢复和篡改 blob 后的 `expired` fail-closed。
- 2026-11-20，验证过程中 `omx setup` 因用户目录备份目录权限返回 EPERM，但 `omx doctor` 通过 19 项检查。Nowledge Mem 服务 `127.0.0.1:14242` 当前不可连接。

## 文件资源平台本轮增强

- 2026-11-20，BoneAgentTools 核心 SDK 新增 `resource.readPDFLayout` 和 `resource.ocr`。PDF 布局按页返回媒体框、裁剪框、旋转、文本行、UTF-16 字符框、注释框和可选单页 PDF 数据，OCR 使用 PDFKit 渲染页面与 Apple Vision 识别文字，均受页范围和结果预算约束。
- 2026-11-20，PDF 密码只允许由 Host 在单次授权调用中临时提供，不进入 Tool Schema、资源引用、metadata 或结果 JSON。PDF 检查结果现在包含加密、锁定、复制权限和内容可访问权限，缺少密码和错误密码分别映射到固定错误。
- 2026-11-20，ZIP 条目增加 `isEncrypted`，加密条目可列出但读取返回 `protectedContent`。带 OLE Compound File 头的 `.docx`、`.xlsx`、`.pptx` 会识别为 `encrypted-office` 并关闭普通 OOXML 解析能力。当前不实现自定义 ZIP 或旧式 Office 密码解密。
- 2026-11-20，SDK 资源组工具目录从 14 个增至 16 个。Demo 仍只装配文本资源工具，因此没有复制或伪装 PDF/OCR 解析实现。
- 2026-11-20，本轮验证使用受限沙箱外的 SwiftPM 测试，因为受限沙箱在 manifest 阶段返回 `sandbox_apply: Operation not permitted`。Nowledge Mem 服务 `127.0.0.1:14242` 仍不可连接。
