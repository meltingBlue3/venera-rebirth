# Venera Rebirth

Venera Rebirth 是 [Venera](https://github.com/venera-app/venera) 的维护分支，在原项目停止维护后继续修复问题、改善体验和开发功能。

项目使用 Flutter / Dart 开发，通过 JavaScript 图源脚本接入网络漫画，同时支持本地漫画阅读。

本仓库为 [meltingBlue3/venera-rebirth](https://github.com/meltingBlue3/venera-rebirth)。目前处于建立开发基线、接手维护的阶段；应用内部仍使用 `venera` 名称，部分更新和发行配置仍沿用上游设置，详见[开发指南](doc/development.md#fork-与发行配置)。上游下载渠道不代表本分支的发行版本。

## 功能

- 阅读本地图片目录，以及 CBZ、CB7、ZIP、7z 漫画压缩包。
- 安装 JavaScript 图源，浏览、搜索和阅读网络漫画。
- 管理收藏、阅读历史、追更和离线下载。
- 在图源支持时查看标签、评论，登录、评论或评分。
- 通过 WebDAV 同步应用数据。
- 使用无界面命令行模式执行数据同步、图源更新和追更检查。
- 使用明暗主题、简体中文、繁体中文和英文界面。

网络功能取决于已安装图源的实现与可用性。图源开发资料见[漫画源指南](doc/comic_source.md)和[JavaScript API](doc/js_api.md)。

## 平台与验证状态

仓库包含 Android、iOS、Windows、macOS 和 Linux 平台工程。

| 平台 | 本分支已完成的验证 |
| --- | --- |
| Linux x64 | 调试构建、应用启动和首页显示 |
| Android ARM64 | 调试 APK 构建、签名检查及 Android 15 真机启动 |
| Android ARMv7 / x86_64 | 调试 APK 构建与产物内容检查；尚未验证设备运行 |
| iOS / macOS / Windows / Linux ARM64 | 保留上游工程与工作流，尚未在本分支重新验证 |

以上是 2026-10-25 建立的初始基线，不代表所有业务功能已完成回归。检查命令、已知诊断及验证范围见[开发指南](doc/development.md#验证基线2026-10-25)。

## 从源码开始

先按 [pubspec.yaml](pubspec.yaml) 和 [rust-toolchain.toml](rust-toolchain.toml) 安装对应版本的 Flutter 与 Rust，再准备目标平台的原生构建工具。

```bash
git clone https://github.com/meltingBlue3/venera-rebirth.git
cd venera-rebirth
flutter pub get
flutter doctor -v
```

Linux 桌面开发：

```bash
flutter run -d linux
```

Android 调试构建：

```bash
flutter build apk --debug
```

Android 调试版使用本机默认调试密钥，无需 `android/key.properties`。调试包与上游正式包签名不同，不能直接覆盖安装；正式发布需要本分支自己的发布密钥。SDK、NDK、真机连接和签名步骤见 [Android 开发指南](doc/android_development.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [开发指南](doc/development.md) | 环境准备、Linux 开发、代码结构、检查流程和维护基线 |
| [Android 开发](doc/android_development.md) | SDK / JDK / NDK、APK、真机调试和签名 |
| [漫画源开发](doc/comic_source.md) | 编写与加载 JavaScript 图源 |
| [JavaScript API](doc/js_api.md) | 图源可调用的网络、HTML、转换及界面接口 |
| [本地漫画导入](doc/import_comic.md) | 目录结构、压缩包和下载目录恢复 |
| [无界面模式](doc/headless_doc.md) | 命令行同步、更新图源与检查订阅 |
| [AGENTS.md](AGENTS.md) | 开发代理在本仓库工作的约定 |

现有图源、API、导入和无界面模式文档继承自上游，后续修改相关实现时同步维护。

## 参与开发

仓库目前尚未启用 Issues，可通过 [Pull requests](https://github.com/meltingBlue3/venera-rebirth/pulls) 提交代码或文档改动。反馈缺陷时请注明平台、应用版本、复现步骤和相关日志。提交改动前，按[检查流程](doc/development.md#检查流程)执行与修改相关的验证，并说明实际测试范围。

## 许可与致谢

项目沿用 [GNU GPL v3 许可证](LICENSE)。感谢原项目 Venera 及其贡献者。

中文漫画标签翻译数据来自 [EhTagTranslation / Database](https://github.com/EhTagTranslation/Database)。

JM、哔咔和 EH / ExHentai 直连功能的实现与调研参考了以下开源项目，感谢各项目作者与贡献者：

- [hect0x7/JMComic-Crawler-Python](https://github.com/hect0x7/JMComic-Crawler-Python)：JM 动态域名发现、配置入口、候选 API 与图片域名。
- [tonquer/JMComic-qt](https://github.com/tonquer/JMComic-qt)：JM 的 DoH、解析覆盖与 ECH 方案研究；本项目 JM 当前采用加密 DNS 和入口换线，尚未实现 ECH 或 HTTP/3 专用选路。
- [tonquer/picacg-qt](https://github.com/tonquer/picacg-qt)：哔咔的 ECH、DoH 与连接 IP 方案，以及 API / 图片主机和备用 IP 配置参考。
- [UjuiUjuMandan/EhViewer](https://github.com/UjuiUjuMandan/EhViewer)：EH / ExHentai 的内置 IP 池、Cloudflare 别名解析和省略 SNI 的直连思路，主要参考其 `anti-dpi` 补丁。

调研中还参考了 [wgh136/PicaComic](https://github.com/wgh136/PicaComic) 的历史 hosts 与分流实现、[ComicSparks/pikapika](https://github.com/ComicSparks/pikapika) 的 API / 图片独立分流设计，以及 [raoxwup/haka_comic](https://github.com/raoxwup/haka_comic) 对原站与第三方中转入口的区分，感谢这些项目提供的对照与启发。

具体采用范围、固定提交来源与实现差异见 [JM 直连说明](doc/jm_direct_connection.md)、[哔咔直连说明](doc/picacg_direct_connection.md)和 [EH 直连说明](doc/eh_direct_connection.md)。

