# 开发指南

本指南用于建立可重复的本地开发流程。Android 平台的具体配置见 [Android 开发](android_development.md)，日常代理协作约定见 [AGENTS.md](../AGENTS.md)。

## 环境准备

| 配置文件 | 负责的版本或约束 |
| --- | --- |
| [pubspec.yaml](../pubspec.yaml) | Flutter 版本、Dart SDK 范围、应用版本及 Dart 依赖 |
| [pubspec.lock](../pubspec.lock) | 已解析的依赖版本和 Git 依赖提交 |
| [rust-toolchain.toml](../rust-toolchain.toml) | Rust 工具链及预设交叉编译目标 |
| [analysis_options.yaml](../analysis_options.yaml) | Dart 分析规则 |

按配置文件选用工具链，不直接切换到最新版本。安装方法参见 [Flutter 官方文档](https://docs.flutter.dev/install)与 [Rust 官方文档](https://rust-lang.org/tools/install/)。

在仓库根目录确认环境并获取依赖：

```bash
flutter --version
rustup show
flutter doctor -v
flutter pub get
```

`rustup` 会根据项目配置准备工具链与目标；原生插件也可能安装额外目标。多个依赖来自指定提交的 Git 仓库，首次获取依赖需要访问 GitHub、pub.dev 及原生工具下载服务。保留锁文件，只有涉及依赖调整的任务才更新依赖版本。

`flutter doctor` 的目标平台检查应通过。仅开发 Linux 时，缺少 Android SDK 不影响 Linux 构建；开发 Android 则需要完成相应工具链和许可证配置。

## Linux 桌面开发

以下系统依赖适用于已验证的 Ubuntu 24.04 环境；其他发行版需要使用对应包名：

```bash
sudo apt-get update
sudo apt-get install -y build-essential clang cmake ninja-build pkg-config \
  libgtk-3-dev libwebkit2gtk-4.1-dev
```

GTK 用于桌面界面，WebKit 开发库用于桌面 WebView 插件。确认工具链后运行：

```bash
flutter doctor -v
flutter devices
flutter run -d linux
```

构建调试版：

```bash
flutter build linux --debug
```

Linux x64 调试产物位于 `build/linux/x64/debug/bundle/`，入口为该目录下的 `venera`。运行或分发时保留整个 bundle，包含其 `lib/` 与 `data/`。

## 代码入口与组织

| 位置 | 主要职责 |
| --- | --- |
| `lib/main.dart`、`lib/init.dart` | 界面 / 无界面入口、窗口与生命周期、服务初始化 |
| `lib/pages/` | 搜索、详情、阅读、收藏、下载和设置页面 |
| `lib/components/` | 通用界面组件；不少文件通过 `part` 组成同一个库 |
| `lib/foundation/` | 应用状态、图源、收藏、历史、本地漫画、缓存及图片提供器 |
| `lib/foundation/comic_source/` | 图源模型、解析与能力接口 |
| `lib/foundation/js_engine.dart`、`assets/init.js` | Dart 与 JavaScript 图源之间的运行时桥接 |
| `lib/network/` | 请求、Cookie、代理、图片加载与下载 |
| `lib/utils/` | 导入导出、同步、翻译和平台工具 |
| `assets/translation.json` | 界面翻译，配合 `lib/utils/translations.dart` 的 `.tl` 等扩展使用 |
| `test/` | 自动化测试 |
| 各平台目录、`debian/`、`patch/`、`.github/workflows/` | 原生工程、打包、补丁及 CI |

网络漫画的主要调用关系是：页面调用 Dart 图源接口，图源接口通过 QuickJS 执行 JavaScript 脚本，再经宿主网络接口获取数据并返回漫画模型。

修改图源能力或桥接接口时，同时核对 Dart 模型、`assets/init.js` 和 [JS API 文档](js_api.md)。修改界面文案时，使用现有翻译入口并检查各语言的翻译键。

收藏、历史、本地漫画和 Cookie 使用持久化数据，导入导出与 WebDAV 同步还会操作这些数据。相关变更需要考虑旧数据兼容与失败后的恢复，使用测试数据验证，保留真实用户数据。

## 检查流程

仅格式化本次修改的 Dart 文件：

```bash
dart format path/to/changed_file.dart
```

获取依赖后，常用检查命令为：

```bash
flutter analyze --no-pub lib test patch
flutter test --no-pub
git diff --check
```

需要复现全仓分析时执行 `flutter analyze --no-pub`。首次原生构建会生成内部 Dart 工具，在生成过程结束后再执行全仓分析，避免扫描到尚未初始化完的生成文件。

按改动选择验证范围：

| 改动 | 验证重点 |
| --- | --- |
| 文档 | 相对链接、引用路径、命令与配置的一致性、差异检查 |
| Dart 逻辑 | 修改文件格式、源码分析、相关测试；修复缺陷时补充能复现问题的回归测试 |
| 界面 / 阅读器 | 目标平台启动、相关页面交互、屏幕尺寸与阅读方向；适用时验证横竖屏 |
| 图源 / JS 桥接 / 网络 | 对应接口与模型的测试，以及受影响图源的实际调用 |
| 数据库 / 导入导出 / 同步 | 旧数据读取、新数据往返、迁移与异常恢复 |
| 平台配置 / 原生依赖 | 目标平台构建；Android APK 同时检查签名，设备可用时验证启动 |

提交或交付时列出执行过的检查、结果以及未验证范围。区分既有诊断与本次新增问题；分析命令仍因已有信息返回非零时，保留这一事实。

## 验证基线（2026-10-25）

这是接手维护时建立的历史记录，后续验证结果应注明日期和范围。

| 检查 | 结果与范围 |
| --- | --- |
| 依赖获取 | `flutter pub get` 成功，保留现有锁定版本 |
| 自动化测试 | `test/channel_test.dart` 的 5 个测试通过；尚未形成完整业务测试覆盖 |
| 源码分析 | `lib`、`test`、`patch` 分析无错误或警告，有 8 条弃用信息，命令返回非零 |
| Linux x64 | 调试构建成功，在虚拟显示环境中启动并检查首页；启动日志曾记录布局溢出提示 |
| Android APK | 调试构建成功，通用与 ARM64 APK 的签名、包信息及核心原生库检查通过 |
| Android 真机 | Android 15 / ARM64 设备完成安装、冷启动和首页显示检查，启动日志未发现崩溃 |

8 条弃用信息位于 `lib/components/image.dart`、`lib/pages/reader/comic_image.dart` 和 `lib/utils/io.dart`，涉及 `TickerMode.of` 与旧版 `Share` API。该记录不代替后续实际分析结果。

本次没有完成网络图源登录、搜索、阅读、下载、导入导出及 WebDAV 同步的全面回归。其他平台的发行包和签名发布流程也尚未重新验证。

## 首次构建与排错

首次构建会下载 Gradle、多个插件的 Maven 依赖、Flutter 引擎和 Rust 依赖，并按架构编译原生库。出现长时间无控制台输出时，先检查进程、下载进度或构建日志，区分下载等待与编译停滞。

- 下载失败：依据错误中的具体 URL 检查连通性；保留已完成的依赖缓存，重试失败项。
- ZIP 损坏：先核对官方大小、校验值和压缩包完整性，再重新安装对应 SDK 组件。
- 原生构建：读取日志所需的实际 NDK / CMake 版本；不同插件可能使用不同版本。
- 安装工具与 Gradle：SDK 安装仍在进行时保持其运行，避免并发清理共享临时目录。
- 调试报告：Gradle 在早期配置失败时可能生成 `android/build/reports/`；它是构建报告，处理前检查内容，保持交付差异只包含任务相关文件。

日志可能包含图源账号、Cookie 或同步服务信息，对外反馈前移除敏感数据。安装密钥、SDK 路径和设备序列号保留在本地配置中。

## Fork 与发行配置

仓库名称已是 Venera Rebirth，应用身份与发行流程尚未全部迁移：

| 位置 | 当前需要注意的事项 |
| --- | --- |
| `android/app/build.gradle` 及各平台工程 | 仍沿用上游应用身份；改变包名会影响安装、数据目录或系统集成，需要作为独立变更处理 |
| `lib/pages/settings/about.dart` | 关于页面、版本检查与下载跳转仍指向上游 |
| `doc/comic_source.md`、图源列表配置 | 使用上游图源仓库作为来源，与应用自身的发行地址分别维护 |
| `alt_store.json`、打包配置及相关脚本 | 含上游名称、链接或维护者信息，独立发行前逐项核对 |
| `.github/workflows/` | 继承上游分析、构建及发布工作流，需为本仓库核对触发条件、平台环境与 secrets |
| GitHub 仓库设置 | 初始检查时 Issues 尚未启用，问题反馈入口需要结合仓库设置维护 |

本次文档更新没有完成上述发行迁移。保留上游署名和 [LICENSE](../LICENSE)，明确区分上游版本与本分支版本。

应用版本既出现在 `pubspec.yaml`，也出现在 `lib/foundation/app.dart`；打包脚本和发行元数据还会引用版本。执行版本调整时同步检查这些位置。

打包脚本可能临时修改受版本控制的文件，例如 `patch/font.dart`、`debian/build.py` 和 `windows/build.py`。运行前阅读脚本，运行后检查差异并保留实际功能变更，避免混入临时字体、构建产物或发布凭据。
