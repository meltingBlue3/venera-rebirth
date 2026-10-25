# Android 开发

通用工具链、代码结构与检查流程见[开发指南](development.md)。Flutter 与 Rust 版本分别以 `pubspec.yaml`、`rust-toolchain.toml` 为准。

## 工具链

本地已验证的组合使用完整 JDK 21、Android SDK API 33–36、Build Tools 35 / 36、NDK 27.0 / 28.0 和 CMake 3.22.1。各插件可能分别使用这些版本；项目的具体配置见 `android/app/build.gradle` 及插件构建日志。上游继承的 Android CI 使用 JDK 17，尚未在本分支重新验证其发布流程。

从 [Android Developers](https://developer.android.com/studio) 安装命令行工具，将其放在 `$HOME/Android/Sdk/cmdline-tools/latest`。命令行构建无需先安装 Android Studio。

以下为 Ubuntu 的配置示例，SDK 与 JDK 路径按本机实际安装位置调整：

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

java -version
javac -version
flutter config --android-sdk "$ANDROID_HOME"
flutter config --jdk-dir "$JAVA_HOME"
sdkmanager --licenses
sdkmanager 'platform-tools' \
  'platforms;android-33' 'platforms;android-34' \
  'platforms;android-35' 'platforms;android-36' \
  'build-tools;35.0.0' 'build-tools;36.0.0' \
  'ndk;27.0.12077973' 'ndk;28.0.13004108' 'cmake;3.22.1'
flutter doctor -v
```

确认 `javac` 可用，避免把仅安装 Java 运行时误认为完整 JDK。多个 NDK 可以并存，许可证接受后 Gradle 也可能自动补装插件需要的版本。

## 构建调试 APK

在仓库根目录执行：

```bash
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

内存有限时，可为单次构建限制并行度；以下写法适用于 Linux shell：

```bash
GRADLE_OPTS='-Dorg.gradle.workers.max=2' CARGO_BUILD_JOBS=2 \
  flutter build apk --debug
```

首次构建需要较多下载和原生编译，后续可复用缓存。下载损坏、TLS 中断及 SDK 版本诊断见[首次构建与排错](development.md#首次构建与排错)。

## 真机安装与调试

在手机上开启 USB 调试，连接电脑，并在手机上授权当前电脑，然后确认设备：

```bash
adb devices -l
flutter devices
```

ADB 状态应为 `device`；`unauthorized` 表示仍需在手机上授权。Ubuntu 用户还需要 Android USB 设备规则及 `plugdev` 组权限，参见[官方设备配置说明](https://developer.android.com/studio/run/device)：

```bash
sudo apt-get install android-sdk-platform-tools-common
id
```

如用户尚不在 `plugdev` 组，完成组配置并重新登录后再检查。

使用列出的设备 ID 启动开发会话，或直接安装 APK：

```bash
flutter run -d DEVICE_ID
adb -s DEVICE_ID install -r -t build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

`DEVICE_ID` 替换为本机输出的设备标识，APK 架构应与手机匹配。开发会话中可使用 `r` 热重载、`R` 热重启。单独安装 APK 后，也可从手机桌面启动应用。

调试签名与上游正式签名不同，即使包名相同也不能直接覆盖安装。遇到签名冲突时，先确认原安装来源和数据备份，再选择数据迁移或单独的调试包名；保留用户数据。

真机验证应同时记录目标页面、操作结果和该应用进程的启动日志。首页启动成功不等于搜索、阅读、下载与同步已完成回归。

## APK 检查

按实际安装的 Build Tools 路径检查签名及包信息：

```bash
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs \
  build/app/outputs/flutter-apk/app-debug.apk
"$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging \
  build/app/outputs/flutter-apk/app-debug.apk
```

确认签名验证通过，包名、版本、最低 / 目标 API 及 CPU 架构与预期一致。涉及 JS 运行时或原生库的变更，还应确认 APK 包含 `assets/flutter_assets/assets/init.js` 及目标架构下的 `libqjs.so`、`librhttp.so` 等库。

## 正式发布签名

正式版通过 `android/key.properties` 配置独立发布密钥：

```properties
storeFile=/absolute/path/to/release.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

Android 目录已忽略 `key.properties`、`*.jks` 和 `*.keystore`。密钥放在其他目录时也应保存在版本控制之外。妥善备份本分支的发布密钥，后续更新需要保持签名身份一致。

发行前还需完成[本分支的发行配置核对](development.md#fork-与发行配置)。目前验证的是调试构建，尚未验证本分支的正式签名发布。
