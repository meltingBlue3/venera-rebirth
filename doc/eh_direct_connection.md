# E-Hentai / ExHentai 直连

## 开启和使用

在「设置 → 网络」开启「E-Hentai / ExHentai 直连」。该选项默认关闭，已有用户不会自动切换网络路由。更改后新发起的请求使用当前设置，无需重启；已经开始的请求需要取消后重试，已有图片缓存仍可复用。

开启后，EH 主站、API、论坛、上传、指定缩略图域名和 `hath.network` 及其子域名绕过应用配置的代理直接连接。其他域名继续使用原有代理、DNS 和 TLS 设置。系统 VPN 的路由仍由系统决定。

此功能覆盖应用中的图源网络请求、封面、阅读图片、逐页下载和压缩包下载。需要先安装支持 E-Hentai / ExHentai 的图源；本功能不新增图源，不改变图源 key、漫画 ID、账号、收藏或历史格式。

内置 WebView 登录、Cloudflare 验证页及外部浏览器使用各自的网络栈，不受此开关控制。若浏览器登录无法直连，可使用图源已有的 Cookie 登录方式，或在登录时使用可用的网络连接。直连不改变站点的账号权限、验证码及访问限制。

## 地址与 TLS 策略

- `exhentai.org` 使用参考项目的 12 个内置 IPv4 地址，每次解析打乱顺序，没有在线测速。
- `e-hentai.org`、`api.e-hentai.org`、`forums.e-hentai.org`、`upload.e-hentai.org`、`s.exhentai.org` 改查 `<原域名>.cdn.cloudflare.net`，使用系统返回的 IPv4 / IPv6 地址。
- `repo.e-hentai.org`、`ehgt.org`、`gt0` 至 `gt3`、`ul.ehgt.org` 以及 H@H 域名保留系统解析。
- 在「DNS 覆盖」中启用并填写的同名条目优先于内置地址和 Cloudflare 别名，直连不要求启用手动 DNS 覆盖。
- 仅 EH 直连请求关闭 SNI，业务 URL、HTTP Host 和证书验证名保持原域名。直连请求始终校验证书，即使调试页开启了忽略证书错误也不会放宽。
- H@H 正文节点的直连请求固定使用 HTTP/1.1，以兼容部分节点在默认协议协商下返回 503 或提前关闭 TLS 流的情况；其他域名保持原有协议协商。

网络实现使用当前锁定的 rhttp 提供的 DNS resolver 和 `TlsSettings.sni=false`，没有复制 Android socket 包装器，因此不依赖 EhViewer 的 Android 版本适配。未引入 DoH、ECH、代理服务器或新依赖。参考实现与固定提交来源见 [EhViewer 调研报告](ehviewer_direct_connection_research.md)。

开关开启时，共享网络适配器逐跳处理重定向，每一跳重新选择代理与 SNI 设置；跨 origin 跳转移除 Cookie、Authorization 和手动 Host，目标站点的 Cookie 再按原有 Cookie 数据库读取。中间响应的 Cookie 会先保存，再请求下一跳。单次上传流不能重放，保留请求体的 307 / 308 等跳转会返回原响应；POST 的 301 / 302 和 303 按规则切换为无请求体请求。`followRedirects` 和 `maxRedirects` 仍生效。

EH 请求即使指定图源内部的 `http_client: dart:io`，开启直连后也会使用共享适配器，以应用上述 TLS 策略。普通域名显式使用 `dart:io` 时保持原实现，其内部跳转不经过共享适配器。

## 连接失败时

地址池过期、目标 IP / 端口不可达、Cloudflare 别名失效或服务器不接受无 SNI 握手时，直连仍可能失败。内置 IP 连接失败后不会自动改用别名或代理。可用手动 DNS 覆盖替换地址，或关闭直连后使用已有代理；不要通过关闭证书校验解决握手问题。

逐页下载时，封面域名失败不会再阻断正文下载：封面重试失败后，下载器继续获取正文，并将第一张成功下载的正文复制为本地封面。原封面成功时仍使用原封面；正文失败仍会报告错误。若没有封面也没有正文，则不创建完成记录。此处理不改变站点封面域名的连通性，也不改变任务持久化格式。

进度显示统计当前章节中所有已完成的图片，不会因前面某页正在重试而一直停在旧数字。断点记录仍保留原来的连续完成位置，恢复下载的格式与语义不变。

2026-10-25 真机排查曾复现 `ehgt.org` 封面连接重置，任务在获取正文图片列表前停止；固定其三个 IPv4 地址、恢复 SNI 和改用 HTTP/1.1 均未改善，而 E 站和普通 HTTPS 请求成功。不要把首页可访问等同于所有图片域名可访问。

绕过封面失败后，原任务成功取得正文列表，随后部分 H@H 节点出现 503、超时和 TLS 提前关闭。同一正文 URL 的设备对照中，默认连接返回 503，改用 HTTP/1.1 返回完整图片（HTTP 200）；保留 SNI 的对照也成功，因此不能将所有失败都归因于 SNI。当前仅对 H@H 直连固定 HTTP/1.1，保持既有 SNI 与证书验证策略。远端节点自身不可达、限流或暂时不可用时仍可能失败。

## 验证

常规测试覆盖域名边界、地址解析、开关与代理、证书设置、重定向跨域、Cookie 更新、请求体处理和跳转上限：

```bash
flutter test --no-pub
flutter analyze --no-pub lib test patch
git diff --check
```

本地原生 TLS 测试依赖 Linux 调试构建中的 rhttp 动态库、Python 3 和 OpenSSL。测试只连接回环地址，临时生成的证书和私钥在结束后删除，不使用真实账号或数据：

```bash
flutter build linux --debug --no-pub
RHTTP_NATIVE_TESTS=1 \
  LD_LIBRARY_PATH="$PWD/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  flutter test --no-pub test/eh_direct_tls_test.dart
```

下载任务回归使用临时数据库和本地 HTTP 图片服务，验证封面失败后的正文下载、章节封面回退、原封面保留、正文错误、空图片列表及乱序完成时的进度显示：

```bash
RHTTP_NATIVE_TESTS=1 \
  LD_LIBRARY_PATH="$PWD/build/linux/x64/debug/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  flutter test --no-pub test/image_download_task_test.dart
```

测试服务器记录 ClientHello SNI 和 HTTP Host，并验证正确证书成功、域名错误证书失败、不受信任证书失败、无关站点保留 SNI，并检查默认发送路径保留 DNS、代理和逐跳重定向策略。未设置 `RHTTP_NATIVE_TESTS=1` 时跳过这五项原生测试。

2026-10-25 已通过常规 18 项测试和 5 项 Linux 原生网络测试。源码分析只有开发指南记录的 8 条既有弃用信息，命令因此返回 1。Android 调试 APK 构建、真机安装、启动及网络设置页面显示检查通过。首次构建因 Rust 工具链清单下载发生 TLS 中断，重试成功，未更改锁定版本。当前环境的匿名网络探测中，E-Hentai 返回 HTTP 200，ExHentai 在测试内存 Cookie 数据库完成论坛 remoteapi 跳转后返回 HTTP 200。以上不代替中国大陆各运营商的实际连通性、真实账号登录与完整阅读下载回归。

下载修复后的补充验证（2026-10-25）：启用原生测试后全部 30 项测试通过（退出码 0），Android 调试 APK 构建、安装和启动通过；分析仍为 8 条既有弃用信息（退出码 1）。原先失败的真机任务已越过封面阶段，真机页面显示 81/493，检查到对应 81 张正文文件，瞬时速度约 71 KB/s；整本下载完成及所有 H@H 节点的可用性不在本次验证范围内。
