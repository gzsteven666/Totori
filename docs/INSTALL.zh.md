# 在另一台 M 系列 Mac 安装 Totori

1. 打开 https://github.com/gzsteven666/Totori/releases/latest 。
2. 下载 `Totori-0.3.8-macOS-arm64.zip`，双击解压。不要下载自动生成的 Source code 作为安装包。
3. 将解压目录中的 `Totori.app` 拖入“应用程序”，再启动；保留 App 内部文件的原始结构。
4. 首次使用按引导开启辅助功能权限；需要读取访达选中项时，允许 Totori 控制访达。
5. 拖入一张副本图片转成 JPEG/WebP，再试视频与文档，检查公司的字体和文件是否符合预期。

系统要求：Apple Silicon（M1 或更新），macOS 13+。无需 Homebrew、Java、Python 或另装 LibreOffice。解压后约 1 GB，文档引擎占主要空间。

此版尚未使用 Apple Developer ID 签名或公证。如果被系统阻止，确认本包来源后，到“系统设置 → 隐私与安全性”查看“仍要打开”。不要关闭 Gatekeeper。若公司 MDM 不允许，应交由管理员批准。

更新：退出 Totori，再用新版替换“应用程序”中的 App。偏好保存在本机；另一台 Mac 会使用默认设置，拖拽格式快捷键为 Shift。旧 App 可保留到确认新版可用后再处理。

下载后可在终端进入解压目录，按 Release 的 `SHA256SUMS.txt` 核对安装压缩包。命令：`shasum -a 256 Totori-0.3.8-macOS-arm64.zip`，结果应与同版校验文件一致。

依赖许可证在 App 的 `Contents/Resources/ThirdPartyLicenses` 和内置 LibreOffice 的 `Contents/Resources` 中。对应编码工具源码随同版 Release 提供。
