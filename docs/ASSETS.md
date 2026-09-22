# 素材与参考来源

| 文件 | 仓库内可核对的来源 |
| --- | --- |
| `Resources/PelicanLogo.svg` | 项目随源码保存的骑车鹈鹕矢量源文件；不依赖外部字体或图片下载 |
| `Resources/MenuBarLogo.svg` | 菜单栏使用的矢量源文件 |
| `Resources/AppIcon.icns` | 由 `scripts/make-icon.swift` 读取 `PelicanLogo.svg`，再由构建脚本调用 `iconutil` 生成 |
| `docs/images/menu-history.png`、`docs/images/menu-history-en.png` | 使用本机真实历史记录的独立副本，以应用自身 SwiftUI 视图分别渲染中英文菜单；主图对应 2026-09-22 08:40 开始、08:41 完成（UTC+08:00）的 Codex 请求，requested model 为 `gpt-6-astra`。用户选择公开这组展示图；它们不是自动评分或模型能力排名的证据 |

代码和项目品牌资源采用根目录的 MIT License，署名为 Pelican Sentinel contributors。仓库未包含第三方素材包或额外字体文件；首次绘制者及独立创作过程未在仓库中记录，上述说明仅确认现有源文件和生成关系。接受外部素材贡献时，须在此补充来源与对应授权。

除用户选择公开的 README 展示截图外，模型运行时生成的用户图片不随源码发布；不发布原始响应、历史 JSON、凭据或本机设置。MIT LICENSE 不代替模型服务对运行时输出的适用条款。

Provider 结构参考了 CodexBar 的设计思路，当前项目没有将其作为依赖或导入其凭据。具体参考范围见 [CODEXBAR_REFERENCE.md](CODEXBAR_REFERENCE.md)。

两张截图使用同一组最近四次真实结果。重建展示截图只读取已有 SVG 和预览，不调用模型，也不改动用户正在使用的历史或设置。
