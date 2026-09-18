# 公开版本验证记录

版本：v0.2.3（build 8）。本文件区分源码测试、界面渲染、真实模型请求和 GitHub 托管检查；它们不能互相替代。

## 可复现检查

在独立复制的公开源码目录执行：

```sh
./scripts/test.sh
python3 -m unittest discover -s Tests/ReleaseTests -v
./scripts/build-app.sh
"dist/Pelican Sentinel.app/Contents/MacOS/PelicanSentinel" \
  --self-check --output artifacts/public-self-check
```

测试使用隔离目录及协议样例；自检使用固定绘图样例、独立数据和临时 Keychain 条目，不调用真实模型。UI 检查需要 macOS 图形会话。构建脚本提供本地 ad-hoc 签名，不提供 Apple 公证。

## 首发准备状态

2026-09-18，在新的公开源码目录中完成下列检查，没有复用原开发目录的 `.build/`。环境为 Apple Silicon（arm64）、macOS 27.0、Apple Swift 6.4。

| 检查 | 结果 |
| --- | --- |
| Swift 测试 | 90 项通过：Core 56 项、App 34 项 |
| 公开导出边界 | 4 项通过：排除私有内容/旧历史、拒绝覆盖、拒绝符号链接、缺少必要文件时停止 |
| Release 构建与签名 | 通过；本地 ad-hoc 签名校验通过 |
| 实际界面与 SVG 渲染 | `SELF_CHECK_PASS`；覆盖双语菜单/设置、历史选择、保存恢复、预览重建和绝对单位 SVG 底部标注 |
| Codex 参数回归 | 假 CLI 捕获命令，验证包括浏览器/桌面/图像生成在内的工具禁用；本地 0.153.4 的完整命令 `--help` 解析成功，不代表真实生成语义已重验 |
| 公开文件安全检查 | Gitleaks 8.30.1 未发现规则命中；公开清单不包含个人绝对路径、原 `.git`、内部任务和用户运行数据 |
| 文档与 CI 配置 | 公开相对链接/图片、YAML 语法、工作流事件、只读权限及固定 action 提交检查通过 |

本次准备验收没有调用真实模型。密钥扫描通过表示没有规则命中，不是对所有潜在秘密的绝对保证。

CI 配置使用 `macos-15` 与 Xcode 16.4，固定 checkout action 的提交；默认不使用生成密钥、不调用模型。其工具链与本机 Apple Swift 6.4 不同，只有 GitHub 实际运行才能确认该环境的结果。

## 真实连接的验证边界

| 连接 | 已有证据 | 尚未证明 |
| --- | --- | --- |
| Codex | 开发阶段曾使用本地 CLI 0.153.4 完成真实请求；请求记录区分 requested/returned model | 不同公开 CLI 版本和其他账号都能使用相同模型或参数 |
| OpenAI / Claude / Gemini | 请求构造、响应解析、拒绝、截断、用量与失败处理的 fixture 测试 | 所有真实服务、账户和模型的生成可用性 |
| OpenAI 兼容接口 | 协议样例和本地 HTTP 服务检查 | 任意第三方兼容服务的全部扩展 |

## 尚需实机或账号环境的检查

- GitHub Actions：本地配置检查和本机测试不能表述为 GitHub runner 已通过；需推送仓库后查看实际运行。
- 通知送达、登录后启动、真实睡眠/唤醒，以及不同 macOS/Intel 环境。
- 菜单与设置的完整鼠标交互。原生视图渲染和动作逻辑测试不等于完整桌面点击验收。
- Developer ID 签名、公证与首次安装流程；当前只承诺源码构建。

外部模型调用需使用用户自行配置的凭据与额度；默认测试和 CI 不放置真实 API key，不执行付费生成。
