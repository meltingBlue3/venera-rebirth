# 仓库开发约定

## 开始工作

1. 查看 `git status` 和相关差异，保留已有的未提交工作。
2. 根据任务定位入口，读相关实现与文档，再确定修改范围。
3. 完成相应验证，检查最终差异，并报告结果及未验证范围。

版本与依赖以 `pubspec.yaml`、`pubspec.lock`、`rust-toolchain.toml` 为准。依赖调整作为独立的、有明确目的的改动处理。

## 按任务阅读

- 环境、构建、测试或既有问题排查：读 [开发指南](doc/development.md)，其中包含代码地图、检查矩阵和带日期的验证基线。
- Android 工程、APK、真机或签名：读 [Android 开发](doc/android_development.md)。
- 新增 / 修改图源能力、JS 运行时桥接：读 [图源指南](doc/comic_source.md)与 [JS API](doc/js_api.md)，核对 `lib/foundation/comic_source/`、`lib/foundation/js_engine.dart`、`assets/init.js`。
- 本地漫画格式、导入或下载恢复：读 [本地导入](doc/import_comic.md)，再检查对应存储与导入实现。
- 命令行行为：读 [无界面模式](doc/headless_doc.md)，同时检查 `lib/main.dart` 与 `lib/headless.dart` 的实际参数处理。
- 版本、应用身份、更新地址或发行流程：先读开发指南的“Fork 与发行配置”，再核对各平台工程和工作流。

## 项目实现约定

- 沿用附近代码的状态管理与组件组织；`lib/components/`、图源和阅读器中的部分文件属于 `part` 库，修改前确认所属库及其 imports。
- 界面文案使用现有 `.tl` / `.tlParams` 等翻译入口，补齐 `assets/translation.json` 中相应语言的键。
- 图源桥接变更同时检查 Dart 接口、JS 宿主 API、返回模型与文档的契约。
- 保持图源 key、漫画 / 章节 ID、收藏、历史和持久化格式兼容；涉及数据格式变更时提供迁移与回归验证。
- 使用测试数据验证数据库、导入导出和同步；保留真实用户的漫画、账号与收藏数据。
- 阅读原生打包或补丁脚本后再运行，检查它们对受版本控制文件产生的临时改动。

## 验证与交付

- 仅格式化修改的 Dart 文件。获取依赖后，源码分析可用 `flutter analyze --no-pub lib test patch`，测试可用 `flutter test --no-pub`；按开发指南选择相关检查。
- 文档修改检查相对链接、引用路径和命令；文档改动本身无需重做完整原生构建。
- 原生配置变更验证目标平台构建；设备可用时检查安装、启动和相关页面。使用 `flutter devices` / `adb devices` 发现设备，文档中保留通用占位符。
- 交付前执行 `git diff --check`，审阅变更文件。把构建产物、签名密钥、账号凭据、个人路径与设备序列号留在本地。
- 报告实际运行的检查和退出结果，区分已有诊断与新增问题。构建成功、启动成功与功能回归分别说明。
- 更改用户行为、开发流程或图源契约时，同步维护对应文档。
