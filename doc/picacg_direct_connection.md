# PicACG 中国大陆直连

在「设置 → 网络」开启「PicACG 直连」，图源 API 地址保留
`https://picaapi.picacomic.com`。开关默认关闭；无需修改或重新安装图源。
开启后，已知 PicACG API 和图片主机绕过应用中配置的代理，使用加密 DNS
和 ECH。封面、阅读图片、头像及下载经过同一适配器，重定向按目标主机重新选路。
内置浏览器 / WebView 使用独立网络栈，不在本功能范围内。

## 连接策略

参考 [picacg-qt 的 ECH 与 RESOLVE 请求选项](https://github.com/tonquer/picacg-qt/blob/5c821da255ebed48a33d7396627989199317052a/src/server/req.py#L129-L156)
与[主机配置](https://github.com/tonquer/picacg-qt/blob/5c821da255ebed48a33d7396627989199317052a/src/config/global_config.py)。
本实现使用 Rust 原生 TLS，不需要运行 Python 或额外代理进程。

- 通过经 HTTPS 证书验证的 DoH 查询 `cloudflare-ech.com` 的 HTTPS（65）记录，
  提取 ECHConfigList；配置按 DNS TTL 缓存，最长 15 分钟，并合并并发查询。
  依次尝试腾讯、阿里、Cloudflare 的 DoH。配置缺失、过期后刷新失败或服务拒绝
  ECH 时显示网络错误，不回退为暴露原域名的普通 SNI。
- 连接地址通过 DoH A 记录获取，只接受 [Cloudflare 公布的 IPv4 网段](https://www.cloudflare.com/ips-v4/)
  中的结果。国内 DoH 也可能返回无法用于这些 ECH 主机的替代地址；非 Cloudflare
  结果会被丢弃并继续尝试下一解析器。解析失败或结果全部无效时使用参考项目的两个
  Cloudflare 引导候选 IP。可在现有「DNS Overrides」中为具体主机填写其他 IP，并开启覆盖。
  手动 IP 仍使用 ECH 和原域名证书验证，不需要关闭 SNI。
- 保留原 HTTPS URL、Host、路径、查询参数及图源签名。全局「忽略证书错误」
  和 SNI 关闭选项不会降低这条路径的验证要求。
- 只匹配代码中列出的精确主机与 HTTPS 443 端口；未知子域和第三方反代入口
  使用原有网络策略。跨域重定向移除 Authorization、Cookie 与 Host。
  不自动重放登录、收藏或点赞等请求。
- 账号、收藏、历史、漫画 / 章节 ID、图源文件和持久化格式均不改变。

ECH、Cloudflare 节点、运营商线路与服务端状态都可能变化；开启功能不能保证
所有大陆网络长期可用。应用层直连也不会改变操作系统 VPN / TUN 的路由。
错误发生在 ECH 查询时先检查 DoH 连通性；握手失败时可尝试更新手动 IP，
重新切换开关可清理配置缓存。API 可达与实际图片可读应分别检查。

## 维护与验证

入口：[PicACG 策略](../lib/network/picacg_direct_connection.dart)、
[共享适配器](../lib/network/rhttp_adapter.dart)、
[JS HTTP 桥接](../lib/foundation/js_engine.dart)。
原依赖没有 ECH 接口，因此使用保留许可证的
[rhttp 0.15.1 本地补丁包](../packages/rhttp/README.venera.md)，变更及原生构建要求见该文档。

```sh
flutter pub get
flutter analyze --no-pub lib test patch
flutter test --no-pub
flutter build windows --debug --no-pub
flutter build apk --debug --no-pub
git diff --check
```

`test/picacg_direct_connection_test.dart` 覆盖主机边界、DNS 报文校验、缓存与 TTL、
ECH / 证书 / 代理策略、手动 IP、图片重定向凭据清理及 POST 不重放。
`test/picacg_live_connection_test.dart` 是可选的原生匿名网络检查，只请求 API
和图片主机的 `HEAD /`，不读取真实账号或漫画内容。构建 Windows 调试版后，
在 PowerShell 中运行：

```powershell
$env:PATH = (Resolve-Path build/windows/x64/runner/Debug).Path + ';' + $env:PATH
$env:PICACG_DIRECT_LIVE_TESTS = '1'
flutter test --no-pub test/picacg_live_connection_test.dart
```

该检查故意设置不可用的应用代理，同时关闭全局 SNI、开启忽略证书错误，
以验证 PicACG 路径独立强制直连和有效 TLS。匿名根路径 400 / 401 表明已收到
HTTP 响应，不代表登录、搜索、阅读或下载已通过业务回归。

如需检查原图源签名请求，可另外设置 `PICACG_SOURCE_PATH` 为上游 `picacg.js`
的本地路径。测试仅在内存中创建图源实例，使用默认设置，无账号请求
`GET /categories`，接受 200 或要求认证的 401，不写入图源持久化数据。

### 验证记录（2026-10-26）

| 检查 | 结果 |
| --- | --- |
| `flutter pub get` | 退出 0，仅 rhttp 改为本地补丁包，其余锁定版本不变 |
| `flutter test --no-pub` | 首轮 37 项通过；真机修复后退出 0，39 项通过、13 项可选原生 / 在线测试跳过 |
| `flutter analyze --no-pub lib test patch` | 退出 1，仅原有 8 条弃用信息，无新增错误或警告 |
| `flutter analyze --no-pub packages/rhttp/lib` | 退出 0，无诊断 |
| Rust 测试与编译 | stable 工具链 2 项测试通过；`cargo +1.85.1 check --locked` 退出 0（均设置 `RUSTFLAGS='--cfg reqwest_unstable'`） |
| Windows x64 调试构建 | 退出 0，产物包含补丁版 rhttp 原生库 |
| Android 调试构建 | 退出 0，通用与 ARM64 / ARMv7 / x86_64 APK 已生成；签名、包信息、JS 资源与各架构 `librhttp.so` / `libqjs.so` 检查通过 |
| Windows 原生匿名连接 | 退出 0；API JS 桥接 `HEAD /` 为 400，上游图源签名 `GET /categories` 为 401；`s3` 为 200、`storage-b` 为 401 |

在线测试仅证明本机经补丁网络栈建立了要求 ECH 的 HTTPS 会话并收到响应，
未确认出口运营商及系统 VPN / TUN 状态，不能标记为大陆三网验证。
没有使用真实账号；登录、实际漫画阅读 / 下载、WebView、macOS、iOS 与 Linux
运行时尚未验证。上述首轮构建时未连接 Android 真机；后续真机结果见下节。

### Android 真机检查（2026-10-26）

使用 Android 15 / ARM64 手机，中国移动 5G 蜂窝网络；系统报告默认网络为
`cmnet`、没有活动 VPN，系统 HTTP 代理为空。本轮按用户选择只做无需登录的检查。
因手机原应用与本机调试包签名不同，使用独立包名
`com.github.wgh136.venera.picacgqa`、名称「Venera PicACG QA」安装，保留原应用数据。
测试应用使用相同 Dart / JS / Rust 实现，安装未修改的上游 PicACG 1.0.6 图源。

首轮发现 API 被自动解析到 `130.211.15.150`，图片主机也出现非 Cloudflare
地址和连接失败。保持同一构建、仅手动指定参考项目的 Cloudflare IP 后，API
即收到 HTTP 400。由此定位到自动选路采用了不适用的 DNS 结果，而非 Android
ECH 后端不可用。新增测试先复现该缺陷，再修复为过滤非 Cloudflare 地址并换解析器。

关闭所有手动 DNS 覆盖后，通过应用内 JS Evaluator、真实 JS HTTP 桥接与原生适配器复测：

| 项目 | 结果 |
| --- | --- |
| 关闭直连的 API 对照 | `HEAD /` 在 15 秒内未收到响应；这是本轮观察窗口，不代表永久不可达 |
| 开启直连，自动选路 | API `HEAD /` 为 400，约 2.5 秒；上游图源签名 `GET /categories` 为 401，约 2.6 秒 |
| 图片主机 | `s3` 根路径为 200，约 1.9 秒；`storage-b` 根路径为 401，约 5.6 秒 |
| 公开测试图片 | 参考项目测速图片的 `Range GET` 为 206，`Content-Type: image/jpeg`；重新打包的 APK 收到 65,536 字节，文件头为 `FF D8 FF E0` |
| 设置与冷启动 | 界面开关可开启并保存；重新打包安装、冷启动后开关保持开启 |
| 应用代理绕过 | 临时设为 `http://127.0.0.1:9` 后，普通网站请求失败，PicACG API 仍收到 400，图片仍收到 206；完成后恢复测试代理设置 |
| 进程日志 | 安装、启动与网络验证期间未发现 Fatal signal / FATAL EXCEPTION |

本轮回归：`flutter test --no-pub` 退出 0，39 项通过；源码分析退出 1，仍只有
原有 8 条弃用提示。修复后的 ARM64 调试包重新构建、签名检查和真机安装通过。
Android 原生工程中为隔离包名和显示名称所作的临时改动均已恢复。

400 / 401 是匿名或未认证请求的预期响应，证明传输可达，不能当作登录成功。
当前结果只覆盖这台手机、当时的移动线路；不覆盖联通、电信或其他网络时段。
没有验证真实账号登录、搜索、阅读器与整章下载流程，也没有迁移原应用的账号数据。
