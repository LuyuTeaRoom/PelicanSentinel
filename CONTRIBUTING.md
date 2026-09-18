# 贡献指南

感谢你为 Pelican Sentinel 提交问题、文档或代码。当前项目是一个 macOS 13+ 菜单栏 MVP：使用固定提示词生成 SVG，保存本地历史，并支持五类模型连接。请让每个变更保持小而可核查。

## 开发环境

需要 macOS 13+、Apple Swift 工具链，以及 `swift`、`xcrun`、`iconutil` 和 `codesign`。项目使用系统框架，没有第三方 Swift package 依赖。Codex、API 或兼容服务的真实请求需要你自己的账号和凭据；默认检查不应发送模型请求。

开始前请阅读 [README](README.md) 和 [架构说明](docs/ARCHITECTURE.md)。Provider 协议、固定提示词、Keychain 边界、本地历史和 SVG 安全限制都是现有行为的一部分。协议样例或 fixture 通过不等于对应的真实服务已经验收。

## 本地检查

在项目根目录执行：

```sh
# Swift Testing 与本地 fixture 检查
./scripts/test.sh

# 公开源码副本 allowlist 边界（Python 标准库）
python3 -m unittest discover -s Tests/ReleaseTests -v

# Release 构建、本地 ad-hoc 签名和签名校验
./scripts/build-app.sh

# 无模型调用的菜单、设置与 WebKit 自检
"dist/Pelican Sentinel.app/Contents/MacOS/PelicanSentinel" \
  --self-check --output /tmp/pelican-sentinel-self-check
```

`test.sh` 主要验证可重复的本地行为；`ReleaseTests` 检查公开源码副本的文件边界；`build-app.sh` 会生成本地应用和图标；`--self-check` 需要可用的 macOS 图形会话，并使用独立数据，不代表真实 provider 连接。真实模型检查会消耗服务额度，只有在明确需要时才执行，并在变更说明中单独写明 provider、model、CLI 版本和验证范围。

构建脚本会生成本地产物。提交前请检查工作树，不要提交凭据、用户历史、原始模型响应、机器私有路径或仅用于验收的生成文件。

## 提交变更

- 一个 PR 聚焦一个行为、缺陷或文档主题；避免顺手重构和新增未使用的依赖。
- 新增或修改 provider 时，同时说明请求协议、认证边界、错误处理和未验证的真实服务范围。
- 修改本地存储、Keychain、SVG 解析或调度时，补充针对该行为的 fixture 测试，并说明失败路径和恢复边界。
- UI 变更请说明受影响的语言、菜单状态和必要的自检结果；不要把 fixture 截图描述成真实模型输出。
- PR 描述应区分自动测试、自检、真实模型检查和未执行的检查。提交前可参照 [PR 模板](.github/pull_request_template.md) 与 [安全政策](SECURITY.md)。

## 问题与安全报告

普通缺陷和功能建议请使用 `.github/ISSUE_TEMPLATE/` 中的表单。安全问题请先阅读 [SECURITY.md](SECURITY.md)，不要在公开问题中粘贴秘密或完整用户历史。
