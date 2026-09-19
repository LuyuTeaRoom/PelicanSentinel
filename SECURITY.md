# 安全政策

Pelican Sentinel 将 API 密钥保存到 macOS Keychain，并将请求记录和生成结果保存在本地。生成请求仍会发送给你选择的模型服务；请按服务方的账号和数据政策使用本项目。

## 报告安全问题

本仓库已启用 **Private vulnerability reporting**，请通过 [私密漏洞报告入口](https://github.com/LuyuTeaRoom/PelicanSentinel/security/advisories/new) 提交报告，并尽量提供受影响版本、复现步骤、影响范围和安全的最小复现材料。

如果私密报告入口不可用，请只创建一个不含漏洞细节、凭据、API key、原始响应或用户历史的公开 issue，说明需要维护者提供私下联系渠道。当前项目没有公开的安全邮箱，也没有承诺响应或修复时限；请不要猜测或发布联系人地址。

## 报告中不要包含

- API key、Codex 登录信息、Keychain 内容或其他凭据；
- 用户历史、原始模型响应、导出的图片或可识别个人的信息；
- 含用户名、机器路径、内部服务地址或其他敏感环境信息的完整日志。

必要时请用脱敏后的最小片段说明问题，并在公开 issue 中只保留复现所需的非敏感信息。普通 bug 请使用 [bug report 表单](.github/ISSUE_TEMPLATE/bug_report.yml)；该表单会要求确认已移除凭据和历史。

## 范围与边界

本政策覆盖仓库中的 macOS 应用、Provider 适配、SVG 处理、Keychain 使用、构建脚本和公开文档。项目当前是本地 MVP，没有声明独立的安全审计、长期支持版本、签名发布包或特定服务的安全保证。
