# Android 开发

通用工具链、代码结构与检查流程见[开发指南](development.md)。Flutter 与 Rust 版本分别以 `pubspec.yaml`、`rust-toolchain.toml` 为准。

## 工具链

以下流程用于在 Windows、macOS 或 Linux 上准备 Android 开发环境；安装路径、环境变量设置方式及设备连接配置按所用系统调整。

1. 安装完整 JDK，以及 [Android SDK](https://developer.android.com/studio)。SDK 可通过 Android Studio 或独立命令行工具管理。
2. 根据工程配置和构建日志安装所需的 SDK Platform、Build Tools、NDK 与 CMake，具体配置见 `android/app/build.gradle`。不同插件可能需要不同版本，多个 NDK 可以并存。
3. 将 `ANDROID_HOME`、`JAVA_HOME` 分别设为本机 SDK 与 JDK 的安装目录，并将所需工具目录加入 `PATH`，使 `java`、`javac`、`sdkmanager` 和 `adb` 可用。

确认环境并接受 SDK 许可证：

```text
java -version
javac -version
flutter config --android-sdk "SDK_PATH"
flutter config --jdk-dir "JDK_PATH"
sdkmanager --licenses
flutter doctor -v
```

`SDK_PATH`、`JDK_PATH` 替换为本机实际安装目录。确认 `javac` 可用，避免把仅安装 Java 运行时误认为完整 JDK。许可证接受后，Gradle 也可能自动补装插件需要的 SDK 组件。

历史本地验证使用 JDK 21、Android SDK API 33–36、Build Tools 35 / 36、NDK 27.0 / 28.0 和 CMake 3.22.1；这不是所有平台都必须手动安装的固定清单。上游继承的 Android CI 使用 JDK 17，尚未在本分支重新验证其发布流程。

## 构建调试 APK

在仓库根目录执行：

```text
flutter pub get
flutter build apk --debug
```

调试版使用 Android 默认调试密钥，无需 `android/key.properties`。当前工程会输出通用包和按架构拆分的包：

| 文件（位于 `build/app/outputs/flutter-apk/`） | 架构 |
| --- | --- |
| `app-debug.apk` | ARM64、ARMv7、x86_64 通用包 |
| `app-arm64-v8a-debug.apk` | ARM64 |
| `app-armeabi-v7a-debug.apk` | ARMv7 |
| `app-x86_64-debug.apk` | x86_64 |

初始基线 APK 的最低 API 为 24，目标 API 为 36；后续以构建配置和实际产物为准。构建和真机验证范围见[验证基线](development.md#验证基线2026-10-25)。

内存有限时，可在当前终端会话中设置 `GRADLE_OPTS=-Dorg.gradle.workers.max=2` 和 `CARGO_BUILD_JOBS=2` 后再构建，以限制并行度。环境变量的设置语法取决于所用 shell。

首次构建需要较多下载和原生编译，后续可复用缓存。下载损坏、TLS 中断及 SDK 版本诊断见[首次构建与排错](development.md#首次构建与排错)。

## 真机安装与调试

在手机上开启 USB 调试，连接电脑，并在手机上授权当前电脑，然后确认设备：

```text
adb devices -l
flutter devices
```

ADB 状态应为 `device`；`unauthorized` 表示仍需在手机上授权。若未识别设备，按所用系统检查 USB 驱动或设备访问权限，参见[官方设备配置说明](https://developer.android.com/studio/run/device)。

使用列出的设备 ID 启动开发会话，或直接安装 APK：

```text
flutter run -d DEVICE_ID
adb -s DEVICE_ID install -r -t build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

`DEVICE_ID` 替换为本机输出的设备标识，APK 架构应与手机匹配。开发会话中可使用 `r` 热重载、`R` 热重启。单独安装 APK 后，也可从手机桌面启动应用。

调试签名与上游正式签名不同，即使包名相同也不能直接覆盖安装。遇到签名冲突时，先确认原安装来源和数据备份，再选择数据迁移或单独的调试包名；保留用户数据。

真机验证应同时记录目标页面、操作结果和该应用进程的启动日志。首页启动成功不等于搜索、阅读、下载与同步已完成回归。

## APK 检查

使用 Android SDK Build Tools 中的工具检查签名及包信息。以下以工具已加入 `PATH` 为例，也可按本机安装位置使用完整路径调用：

```text
apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-debug.apk
aapt dump badging build/app/outputs/flutter-apk/app-debug.apk
```

确认签名验证通过，包名、版本、最低 / 目标 API 及 CPU 架构与预期一致。涉及 JS 运行时或原生库的变更，还应确认 APK 包含 `assets/flutter_assets/assets/init.js` 及目标架构下的 `libqjs.so`、`librhttp.so` 等库。

## 正式发布签名

正式版通过 `android/key.properties` 配置独立发布密钥：

```properties
storeFile=RELEASE_KEYSTORE_PATH
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

将 `RELEASE_KEYSTORE_PATH` 替换为本机密钥文件的绝对路径，并填写其余签名信息；Windows 路径可使用正斜杠，避免 `.properties` 中的反斜杠转义。Android 目录已忽略 `key.properties`、`*.jks` 和 `*.keystore`。密钥放在其他目录时也应保存在版本控制之外。妥善备份本分支的发布密钥，后续更新需要保持签名身份一致。

配置本地发行签名后，可构建供他人安装的发布版：

```text
flutter build apk --release --no-pub
```

应用显示名称为 `Venera`，常规包名为 `com.github.wgh136.venera`。通用 APK
包含 ARM64、ARMv7、x86_64，适合分发给不同架构的设备。发行签名需要在后续
更新中沿用；本分支新建的密钥与上游应用及本地调试包的签名不同，不能直接覆盖安装。

发行前还需完成[本分支的发行配置核对](development.md#fork-与发行配置)。本地发行签名构建与 APK 分发，不代表更新地址、仓库身份和 CI 发布流程已经完成迁移。
