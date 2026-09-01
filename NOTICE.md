# BoneAgentKit Notice

## 生产代码

当前 BoneAgentKit 生产源码是本仓库内的 clean-room 实现。当前 Package 未声明或链接第三方 Swift Package、C/C++ binary target 或模型权重。

## Provider 渠道图片

`BoneAgentKit` Product 内置 42 个 Provider 渠道 PNG，用于在配置和选择界面识别渠道；图片由内部资源 Target 管理。Catalog 中的 `iconID` 是这些资源的稳定语义标识。

这些渠道图片不表示相应商标权利人赞助、认可或官方背书本项目，也不得被解释为独立的品牌资产授权。

`Sources/BoneAgentProviderAssets/Resources/ProviderIcons/` 下的 Provider PNG 以及图片中体现的名称、徽标和商标**不在仓库根目录 AGPL-3.0-only 授权范围内**。其版权和商标权归各自权利人所有；在来源、许可及商标使用要求逐项核实前，不授予复制、修改或再分发这些图片的权利。需要分发纯 AGPL 源码时，应排除这些图片或另行取得授权。

## 许可与待决事项

自 `0.2.0-alpha.2` 起，除上述 Provider PNG、第三方商标及另有明确许可声明的材料外，BoneAgentKit 源码和文档依据仓库根目录的 GNU Affero General Public License v3.0 only（SPDX: `AGPL-3.0-only`）授权。

`0.2.0-alpha.1` 及更早的既有 tag 保持其签发时的 proprietary 许可；本次变更不追溯改写历史版本。

- 修改后的网络服务若触发 AGPL 第 13 节，应向远程用户提供对应源码。
- 后续引入第三方实质代码、资产、binary target 或模型权重时，必须在本文件追加真实版权、许可证和来源信息。
