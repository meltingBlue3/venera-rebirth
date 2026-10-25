# EhViewer 中国大陆直连方案调研

调研日期：2026-10-25。范围为源码与构建脚本审查，未安装 APK、未抓包，也未在中国大陆不同运营商网络实测。

## 结论

该分叉的方案是**在应用内替换 DNS 结果，直接连接目标 IP，并调整 TLS socket 的主机名，以尝试避免在 SNI 中暴露目标域名**。HTTP 请求仍使用原站域名，证书仍按原站域名验证。它不需要自建中转服务器；README 把恢复的功能称为“内置 Hosts 和域前置”，但当前补丁没有设置一个无关的掩护域名，更准确的描述是“内置地址／Cloudflare 别名解析 + 尝试省略域名 SNI”。实际 ClientHello 必须通过抓包确认，尤其需要区分 Android 版本。[README] [dns] [tls] [verify]

“直连”解决的是特定域名解析与 TLS 域名暴露问题；能否访问仍取决于目标 IP 可达、服务端接受这种握手并返回正确证书等条件。源码不能证明它在调研当天的所有大陆网络都能使用。

## 版本和构建入口

| 对象 | 本次读取的版本 |
| --- | --- |
| `UjuiUjuMandan/EhViewer` 主仓 `main` | `e138138002267c8de5138729b96e67025839e230`，提交日期 2026-10-07 |
| `EhViewer` 子模块 | `257bfe843ee4345420b4f01cb26001f0ff3b0761` |
| 子模块地址 | `https://codeberg.org/EhViewer/EhViewer` |
| 子模块声明的网络依赖 | Ktor `3.5.0`、OkHttp `5.3.2` |
| OkHttp `parent-5.3.2` 对应提交 | `75b9c267744cdd2e8b222d247052748ff0954304` |

主仓是补丁包装层，不是完整应用源码。CI 和发行工作流递归检出子模块，在其目录执行 `patches/apply.sh`，再构建补丁后的应用。因此需要把子模块与当前补丁一起阅读。[main-commit] [main-tree] [submodule] [versions] [okhttp-tag] [workflow]

`apply.sh` 实际执行：

1. 应用 `0001-anti-dpi.patch`，加入 Hosts、自定义 DNS、自定义 TLS factory，并配置 OkHttp。
2. 执行 `0002-disable-cronet.sh`，将网络引擎选择条件改为 `enableQuic`，并将其默认值改为 `false`。
3. 执行 `0004-increase-request-timeout.sh`，把请求总超时从 10 秒改为 30 秒。
4. 把应用 ID 改为 `moe.tarsin.ehviewer.cc`。

`0003-disable-autoupdate.sh` 虽然存在，但调用被注释，不能据此声称当前构建已禁用自动更新。[apply] [cronet-patch] [timeout-patch]

## 请求经过哪些步骤

以 `https://e-hentai.org/...` 为例，默认配置下的逻辑为：

```text
业务请求 URL：e-hentai.org
       ↓ Ktor / OkHttp
EhDns：查询 e-hentai.org.cdn.cloudflare.net，取得 IP
       ↓ Proxy.NO_PROXY
TCP：直接连接该 IP
       ↓ EhSSLSocketFactory
创建 TLS socket 的 host 参数：连接 IP，而非 e-hentai.org
       ↓ 平台 TLS 行为决定实际 SNI；证书仍验证 e-hentai.org
HTTPS：Host / :authority 仍为 e-hentai.org
       ↓
原站或其 Cloudflare 节点处理请求
```

上述请求链来自补丁的 DNS、TLS 和 OkHttp 配置；HTTP 域名保持方式与证书校验还核对了对应 OkHttp 版本。[dns] [tls] [okhttp-config] [http-host] [http2-authority] [verify]

### 1. 用应用内 Hosts 绕过部分原域名解析

`builtInHosts` 固定提供 `exhentai.org`、`api.github.com`、`github.com`、`raw.githubusercontent.com` 的地址。构建地址表时只保留 `blockedInCN false` 的项，`true` 项直接排除。这是维护者在代码里填写的静态标记，不是客户端运行时检测所在国家或探测封锁状态。[hosts] [dns]

`exhentai.org` 有 12 个内置 IPv4 地址。DNS 返回结果统一调用 `shuffled()`，作用是打乱候选地址顺序；补丁没有测速、探活或按延迟优选逻辑。地址是否仍有效需另行测试。[hosts] [dns]

### 2. 对指定域名查询 Cloudflare 后缀别名

对于 `e-hentai.org`、`api.e-hentai.org`、`upload.e-hentai.org`、`forums.e-hentai.org`、`exhentai.org`、`s.exhentai.org` 和 `testingcf.jsdelivr.net`，如没有内置 Hosts，解析器改查 `<原域名>.cdn.cloudflare.net`。`exhentai.org` 分支在没有内置条目时改查 `s.exhentai.org.cdn.cloudflare.net`，但当前存在内置地址表，所以直接返回表中的地址。这不是连接失败后自动切换到别名的机制。[dns]

这里改的是**用于取得连接 IP 的 DNS 查询名**，没有把业务 URL 改成 Cloudflare 后缀。机制上的推断是：避开对原域名的特定 DNS 污染，并取得对应 Cloudflare 接入地址；后缀域名当下能否解析、地址是否可达，源码无法保证。

代码仍调用系统 DNS：Android 10 及以上用 `AndroidAsyncDns` 查询 IPv4／IPv6，旧系统使用 `Dns.SYSTEM`。虽然有一个名叫 `dohSkipDomains` 的列表，但此补丁没有 DoH 客户端、DoH URL 或加密 DNS 请求；不能把它称为“内置 DoH”。系统自身是否启用 Private DNS 属于设备配置。[dns]

### 3. 把 TLS factory 的 peer host 改为连接 IP

`EhSSLSocketFactory` 只改写在已有 TCP socket 上叠加 TLS 的 `createSocket(s, host, port, autoClose)`。如果 `host` 在 `dFEnabledDomains` 列表中，或字符串含有 `hath.network`，就将传给平台 TLS factory 的 `host` 换成 `socket.inetAddress.hostAddress`；其余域名照常传原域名。[tls]

名单包括 E／Ex 主站与相关 API、论坛、上传域名，以及 `ehgt.org` 的若干图片子域名、`github.com` 和 `api.github.com`。DNS 改写名单、内置 Hosts 名单和 TLS 改写名单并不相同，例如 `raw.githubusercontent.com` 只有内置 Hosts，`testingcf.jsdelivr.net` 在 DNS 别名名单中而不在此 TLS 名单中。[hosts] [dns]

**原理推断：**以 Conscrypt 实现为例，其 SNI 主机名检查明确排除数字 IP，仅对符合条件的主机名调用设置 SNI 的原生函数；因此将 peer host 改为 IP，可以使这类实现不发送原域名 SNI。TLS 建立后，HTTP 域名位于加密流量中，服务端仍可按真实站点处理请求。此处没有发送“另一个正常网站域名”的代码，也没有 ECH、TLS 分片、VPN 或自建反向代理实现。Conscrypt 证据说明该机制成立的实现条件，不代表所有 Android 构建都采用所引版本。[tls] [conscrypt-address] [conscrypt-native]

**平台限制：**OkHttp 建立 socket 后还会调用 `configureTlsExtensions`。5.3.2 的 Android 10 适配器只设置会话票据与 ALPN，不重新设置主机名；但反射适配器在 Android API ≤23 时会调用 `setHostname(原 URL 域名)`。所以不能仅凭 factory 替换就断言所有 Android 版本均无 SNI；Android 6 上尤其存在原域名被重新写回的可能，需要对实际 TLS provider 抓包验证。[verify] [android10] [android-old]

### 4. 保留 HTTPS 证书与原站 HTTP 域名

补丁使用 `SSLContext.getInstance("TLS").init(null, null, null)` 和系统默认 `TrustManagerFactory`，没有安装“信任所有证书”的 trust manager，也没有替换 hostname verifier。OkHttp 最终使用 `address.url.host` 验证证书主机名；因此把 TLS factory 的 host 换成 IP，不等于按 IP 校验证书，更不等于关闭证书校验。[tls] [verify]

OkHttp 的 HTTP/1 请求 `Host` 默认从原请求 URL 生成；HTTP/2 的 `:authority` 来自该 `Host`。这解释了为什么即使 DNS 查询名和 TLS 创建参数被调整，业务请求仍可以指向原站。[http-host] [http2-authority]

如果服务器要求正确的 SNI 才能返回原站证书，此方案仍会握手或校验失败。这属于方案对服务端行为的依赖，不能通过“已有 Hosts”解决。

## 默认开关与覆盖范围

补丁后的默认 `enable_quic=false` 会让共享客户端走 Ktor 的 OkHttp 引擎，并安装自定义 TLS factory；OkHttp 配置始终安装 `EhDns`，并明确指定 `Proxy.NO_PROXY`。这绕开该客户端的常规代理选择，但不代表能绕开系统 VPN 或网络层路由。[cronet-patch] [application] [okhttp-config]

开启 `enableQuic` 后，如果 Cronet 可用，客户端改走 Cronet，以上 OkHttp 的 DNS／TLS 补丁不覆盖这条路径；即使 Cronet 不可用回退到 OkHttp，补丁也因 `enableQuic=true` 而不安装自定义 TLS factory。客户端是 `lazy` 初始化，不能假设更改开关会立即重建已有客户端。[application] [okhttp-config]

Coil 图片加载显式复用同一个 `ktorClient`，因此该补丁覆盖使用此客户端的图片请求；不能据此扩展为整个 Android 系统、外部浏览器或所有 WebView 请求都具备相同直连能力。[image-client]

## 有效边界与待验证项

| 场景 | 根据源码可以判断的能力与限制 |
| --- | --- |
| 原域名 DNS 污染 | 内置 Hosts 可避开对应查询；Cloudflare 后缀仅改变查询对象，仍依赖系统解析 |
| 按目标域名 SNI 干扰 | IP peerHost 具有规避意图；实际效果受 Android 版本及 TLS provider 影响 |
| 目标 IP／端口不可达 | DNS 与 SNI 调整不能恢复网络层可达性 |
| 服务端必须依赖 SNI | 可能返回错误证书或拒绝握手，证书校验仍应失败 |
| 登录、Cookie、访问权限、验证码或站点风控 | 补丁未提供绕过这些业务限制的实现 |
| 地址池过期或 Cloudflare 配置变化 | 当前补丁没有在线更新地址池或动态发现服务端配置的机制 |

以上后四项是根据改动范围作出的能力边界判断，不是本次复现得到的故障。若要评估当下可用性，应分别记录解析结果、TCP 可达性、ClientHello SNI、证书链／主机名验证以及首页、登录、图片请求结果；分 Android 版本与运营商验证，并使用测试账号。

本次已读取主仓当前补丁、应用入口及固定版本 OkHttp 实现；在隔离临时目录放入固定子模块版本的 `OkhttpExtensions.kt` 后，对 `0001-anti-dpi.patch` 执行 `git apply --check`，退出码为 0，确认该修改上下文可以匹配。未执行 APK 构建、安装、功能回归或大陆线路连通性检查；因此报告解释实现原理，不给出当前可用率承诺。

[README]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/README.md#L1-L28
[main-commit]: https://github.com/UjuiUjuMandan/EhViewer/commit/e138138002267c8de5138729b96e67025839e230
[main-tree]: https://api.github.com/repos/UjuiUjuMandan/EhViewer/git/trees/e138138002267c8de5138729b96e67025839e230
[submodule]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/.gitmodules#L1-L3
[versions]: https://codeberg.org/EhViewer/EhViewer/src/commit/257bfe843ee4345420b4f01cb26001f0ff3b0761/gradle/libs.versions.toml#L34-L37
[okhttp-tag]: https://api.github.com/repos/lysine-dev/okhttp/git/tags/381493df8a6f41259258da53f3e2f6547ff50ca5
[workflow]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/.github/workflows/releases.yml#L24-L60
[apply]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/apply.sh#L1-L8
[cronet-patch]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/0002-disable-cronet.sh#L1-L4
[timeout-patch]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/0004-increase-request-timeout.sh#L1
[hosts]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/0001-anti-dpi.patch#L12-L62
[dns]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/0001-anti-dpi.patch#L81-L135
[tls]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/0001-anti-dpi.patch#L156-L182
[okhttp-config]: https://github.com/UjuiUjuMandan/EhViewer/blob/e138138002267c8de5138729b96e67025839e230/patches/0001-anti-dpi.patch#L200-L210
[application]: https://codeberg.org/EhViewer/EhViewer/src/commit/257bfe843ee4345420b4f01cb26001f0ff3b0761/app/src/main/kotlin/com/hippo/ehviewer/EhApplication.kt#L221-L239
[image-client]: https://codeberg.org/EhViewer/EhViewer/src/commit/257bfe843ee4345420b4f01cb26001f0ff3b0761/app/src/main/kotlin/com/hippo/ehviewer/EhApplication.kt#L171-L179
[verify]: https://github.com/lysine-dev/okhttp/blob/75b9c267744cdd2e8b222d247052748ff0954304/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/connection/ConnectPlan.kt#L338-L395
[android10]: https://github.com/lysine-dev/okhttp/blob/75b9c267744cdd2e8b222d247052748ff0954304/okhttp/src/androidMain/kotlin/okhttp3/internal/platform/android/Android10SocketAdapter.kt#L55-L81
[android-old]: https://github.com/lysine-dev/okhttp/blob/75b9c267744cdd2e8b222d247052748ff0954304/okhttp/src/androidMain/kotlin/okhttp3/internal/platform/android/AndroidSocketAdapter.kt#L47-L68
[http-host]: https://github.com/lysine-dev/okhttp/blob/75b9c267744cdd2e8b222d247052748ff0954304/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/http/BridgeInterceptor.kt#L59-L61
[http2-authority]: https://github.com/lysine-dev/okhttp/blob/75b9c267744cdd2e8b222d247052748ff0954304/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/http2/Http2ExchangeCodec.kt#L166-L178
[conscrypt-address]: https://github.com/google/conscrypt/blob/48ee08228358c2289f422dd80b333b5ff33a7267/common/src/main/java/org/conscrypt/AddressUtils.java#L36-L46
[conscrypt-native]: https://github.com/google/conscrypt/blob/48ee08228358c2289f422dd80b333b5ff33a7267/common/src/main/java/org/conscrypt/NativeSsl.java#L525-L527
