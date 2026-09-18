## 变更目的

<!-- 说明要解决的问题、用户可观察到的结果，以及关联的 issue（如有）。 -->

## 变更范围

<!-- 列出涉及的行为、provider、存储、UI、文档或测试。保持 PR 聚焦。 -->

## 验证

- [ ] `./scripts/test.sh`
- [ ] 如修改公开导出或脚本边界，运行 `python3 -m unittest discover -s Tests/ReleaseTests -v`
- [ ] `./scripts/build-app.sh`
- [ ] 如涉及菜单、设置或预览，运行无模型调用的 `--self-check`
- [ ] 如执行了真实 provider 检查，已单独记录 provider、model、CLI 版本、是否消耗额度和验证边界
- [ ] 已说明未执行的相关检查及原因

协议样例、fixture 和本地 HTTP 检查应与真实模型服务验证分开描述；不要把其中一种表述成所有 provider 均已验收。

## 用户影响与兼容性

<!-- 说明设置、历史、Keychain、导出文件、双语界面和失败恢复是否受影响。 -->

## 安全与隐私

- [ ] 未提交 API key、登录信息、Keychain 内容、用户历史、原始模型响应或机器私有路径
- [ ] 日志、截图和示例数据已经脱敏
- [ ] 如涉及安全问题，已按 [SECURITY.md](../SECURITY.md) 处理

## 文档与提交检查

- [ ] 需要时已更新 [README](../README.md)、[贡献指南](../CONTRIBUTING.md) 或 [变更记录](../CHANGELOG.md)
- [ ] 未加入未经证实的实时 provider、模型能力、排名、通知或发布承诺
- [ ] 生成文件和临时验收资料未纳入 PR
