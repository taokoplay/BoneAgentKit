# BoneAgentKit Public Documentation Layout Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 BoneAgentKit 公开说明重构为清晰的开源 Swift SDK 门面和分层文档地图。

**Architecture:** README 只承载定位、安装、核心能力、边界和首要导航；`Documentation/INDEX.md` 承载完整分类索引。Shell 门禁验证敏感词、README 契约、相对链接和 Markdown 标题结构。

**Tech Stack:** Markdown、GitHub HTML、shields.io 静态徽标、Bash、Python 3、SwiftPM。

---

## Task 1: 建立文档结构门禁

**Files:**
- Modify: `Scripts/check-public-documentation.sh`

**Steps:**
1. 增加 README 必需 Token 检查，要求四个 Product、HTTPS URL、`0.2.0-alpha.3`、AGPL 链接。
2. 使用内嵌 Python 扫描跟踪 Markdown 的相对链接和标题层级。
3. 运行脚本观察旧 README 因结构契约失败。
4. 提交门禁与后续 README 实现放在同一文档功能提交，避免主分支中间态不可用。

## Task 2: 重构 README 首屏和主路径

**Files:**
- Modify: `README.md`

**Steps:**
1. 添加居中标题、定位和四个静态徽标。
2. 用 Product 表格替换密集开场，修正四 Product 数量。
3. 将 HTTPS 精确版本安装和最小目标依赖移动到能力说明之前。
4. 精简执行链、能力、Host 边界、限制和许可。
5. 运行文档门禁，确认 README 契约通过。

## Task 3: 建立完整文档地图

**Files:**
- Create: `Documentation/INDEX.md`
- Modify: `README.md`
- Modify: `Documentation/GettingStarted.md`
- Modify: `Documentation/LocalModels.md`

**Steps:**
1. 按开始使用、核心概念、运行与治理、本地模型、维护者资料分类全部正式文档。
2. README 只保留首要阅读路径并链接 INDEX。
3. 在 GettingStarted 与 LocalModels 增加简洁导语和前后导航。
4. 运行链接和标题门禁。

## Task 4: 完整验证和发布准备

**Files:**
- Modify: `CHANGELOG.md`

**Steps:**
1. 在 Unreleased 记录文档信息架构与门禁变化。
2. 运行 `./Scripts/check-public-documentation.sh`。
3. 运行 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`，预期 154 tests、0 failures。
4. 运行 `git diff --check` 和 tracked-tree 敏感扫描。
5. 创建单一 `docs` 提交；已发布 tag 不改写，新 tag 另行确认。
