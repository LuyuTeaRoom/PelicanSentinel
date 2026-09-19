# 素材与参考来源

| 文件 | 仓库内可核对的来源 |
| --- | --- |
| `Resources/PelicanLogo.svg` | 项目随源码保存的骑车鹈鹕矢量源文件；不依赖外部字体或图片下载 |
| `Resources/MenuBarLogo.svg` | 菜单栏使用的矢量源文件 |
| `Resources/AppIcon.icns` | 由 `scripts/make-icon.swift` 读取 `PelicanLogo.svg`，再由构建脚本调用 `iconutil` 生成 |
| `docs/images/menu-history.png` | 应用自身 SwiftUI 视图的自检截图；使用 `SelfCheck.swift` 内的固定绘图样例，图片上标有 `SELF-CHECK FIXTURE`，不是模型能力证据 |

代码和随仓库发布的项目资源采用根目录的 MIT License，署名为 Pelican Sentinel contributors。仓库未包含第三方素材包或额外字体文件；首次绘制者及独立创作过程未在仓库中记录，上述说明仅确认现有源文件和生成关系。接受外部素材贡献时，须在此补充来源与对应授权。

模型运行时生成的用户图片不随源码发布；MIT LICENSE 不代替模型服务对运行时输出的适用条款。

Provider 结构参考了 CodexBar 的设计思路，当前项目没有将其作为依赖或导入其凭据。具体参考范围见 [CODEXBAR_REFERENCE.md](CODEXBAR_REFERENCE.md)。

英文 README 使用 `docs/images/menu-history-en.png`，来自同一无模型调用自检的英文菜单样例。
