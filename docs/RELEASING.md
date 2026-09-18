# 发布流程

当前分发方式为源码构建。公开仓库应包含代码、测试、构建脚本、必要文档和项目资源，不包含个人运行数据或开发任务记录。

## 准备公开副本

在项目根目录执行，目标目录必须尚不存在：

```sh
python3 scripts/prepare-public-release.py artifacts/public-source/PelicanSentinel
```

脚本按白名单复制文件，输出 `release-manifest.json`，不复制 `.git` 历史、构建目录、运行数据、内部任务、原始 PRD/handoff 或私人验收日志。它不会删除、提交或修改原仓库的历史，也不会创建远端仓库或上传文件。

生成的是源码快照。需要公开历史时，只在审查后的副本中初始化新 Git 仓库；不要将原开发仓库的旧分支或标签一并推送。

## 发布前检查

1. 检查 `Resources/Info.plist` 的版本、README 与 CHANGELOG 是否一致。
2. 在公开副本中运行 `./scripts/test.sh`、`python3 -m unittest discover -s Tests/ReleaseTests -v` 和 `./scripts/build-app.sh`，不能复用原目录的 `.build/`。
3. 在 macOS 图形会话中执行 README 的 `--self-check`；这是固定样例检查，不请求真实模型。
4. 检查 README、图片、相对链接、素材来源，以及 LICENSE 中的署名。
5. 扫描公开文件与准备推送的 Git 历史。例：安装 Gitleaks 后，在尚未生成构建和自检产物的干净公开副本中运行 `gitleaks dir . --redact`，创建首个提交后运行 `gitleaks git . --log-opts=--all --redact`。不要将未脱敏报告上传。
6. 在 GitHub 上运行 CI，确认实际使用的工具链；本机成功不能替代托管 runner 的结果。

## 建立 GitHub 仓库时

- 选择公开仓库名称和维护者身份，检查 Git 提交署名。
- 启用 Private vulnerability reporting，使 SECURITY.md 中的私密报告入口可用。
- 确认 Secret scanning / push protection 的可用设置；不在 CI 中放置真实生成密钥。
- 将 macOS CI 设为合并前检查；首个工作流运行成功后再启用必需检查，避免引用不存在的检查项。
- 审查首次推送的提交、分支和标签范围；不要使用 `git push --mirror`。
- 依据 CHANGELOG 创建 Release。源码包不等于经过 Developer ID 签名和公证的二进制安装包。

GitHub 仓库创建、设置、推送、Release 发布及 Apple 签名/公证是需要账号的独立操作，本地准备脚本不会代为执行。

## 发布二进制时

当前构建脚本仅提供本地 ad-hoc 签名。若增加供普通用户下载的 `.app`，先建立独立的 Developer ID 签名与公证流程，并验证 Gatekeeper 首次打开行为；不要建议用户关闭系统保护作为默认安装方式。任何真实 API 验收都应单独确认账号、模型及额度范围，不能混入无凭据 CI。
