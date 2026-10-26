# 中国大陆直连 JMComic 技术调研

调研日期：2026-10-26。范围是客户端网络实现、域名发现与故障恢复；没有请求漫画页面、搜索结果或图片内容，也没有做大陆电信、联通、移动的现场连通性测试。

## 结论

值得优先实施的是 **API 域名动态发现 + API/图片独立选路 + 有界失败回退**。DoH 可以处理部分 DNS 故障；保留原域名的 IP 覆盖可以用于诊断或临时恢复。遇到按 SNI 识别的连接问题时，两者都不能保证解决；ECH 是值得单独验证的增强路线，不能承诺任意域名、地区和运营商都有效。依据是下述上游实现与协议边界，属于工程建议，不是大陆可用性实测结论。[下载器配置](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_config.py#L184-L212)、[Qt 网络实现](https://github.com/tonquer/JMComic-qt/blob/c12629508bb43404ff667cb6f36f9d97f782390b/src/server/req.py#L137-L165)、[DoH 标准](https://www.rfc-editor.org/rfc/rfc8484.html)。

本文把“直连”限定为客户端直接连接 JM 的服务端或其提供的 CDN；通过海外服务器下载、HTTP/SOCKS 代理、第三方转发服务再返回内容不计入直连。域名含 `proxy` 本身不证明客户端使用了代理，必须检查实际连接路径。

## 证据与可信度

- **代码事实**：核对作者仓库的实际分支快照，说明“实现了什么”，不能证明该机制在用户网络有效。
- **维护者声明**：作者文档、发行记录或问题回复，保留适用范围与日期；用户报障只作个案证据。
- **工程推断/建议**：由前两者及协议推导，以下明确标出，不作为实测事实。

外部代码快照：

| 项目 | 本次固定提交 | 用途 |
| --- | --- | --- |
| hect0x7/JMComic-Crawler-Python | `fd8953025db5b844f1b7f025d063f544e61a2dbd` | API/Web 区别、动态域名、重试、图片域名 |
| tonquer/JMComic-qt | `c12629508bb43404ff667cb6f36f9d97f782390b` | ECH/DoH、HTTPS RR、IP 覆盖、协议选项 |
| wgh136/PicaComic | `155cf0c6d7018f9521f8c375b142bafd85e47a4d` | Flutter 客户端的历史分线与 TLS 实现对照 |

这些是本次访问时抓取的仓库树快照；不把当前分支等同于某个发行包的完整行为。

## 已有实现提供了哪些路线

### 1. 优先移动 API，并维护多入口

下载器把网页和移动 API 做成不同客户端，域名配置也按 `html`/`api` 分组；代码当前默认值是 `api`。文档声称移动端地区兼容性较好、网页端限制 IP 地区。这能支持“优先研究 API”的选择，但“APP 端不限 IP”是维护者的概括，不能推广成中国大陆永久可达的保证。[客户端配置说明](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/assets/docs/sources/option_file_syntax.md)、[默认实现](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_config.py#L508-L510)。

PicaComic 的 Flutter 实现同样以多个移动 API 地址供设置选择，图片加载另有实现。这是多入口设计的实际先例，所列域名只是代码快照，不是本次验证的可用地址。[API 基址](https://github.com/wgh136/PicaComic/blob/155cf0c6d7018f9521f8c375b142bafd85e47a4d/lib/network/jm_network/jm_network.dart#L84-L91)、[图片实现](https://github.com/wgh136/PicaComic/blob/155cf0c6d7018f9521f8c375b142bafd85e47a4d/lib/network/jm_network/jm_image.dart)。

### 2. 从配置服务器刷新 API 域名

下载器内置三处 BytePlus 对象存储配置入口（新加坡、香港、北京主机名），文件名为 `newsvr-2025.txt`。客户端解码配置并取 `Server` 列表；获取失败时遍历其他配置入口，只有当前使用内置列表时才用新列表替换，保留显式自定义配置。[配置入口](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_config.py#L197-L212)、[获取与更新实现](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_client_impl.py#L1336-L1390)。

网页域名还有发布页解析和永久跳转发现，但它们属于网页入口。当前作者文档明确废弃 `get_html_domain_all_via_github`：旧 GitHub 仓库已不再提供域名，兼容方法转发到发布页方法。不要复制旧教程中依赖 GitHub 域名页的方案。[域名策略文档](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/assets/docs/sources/tutorial/12_domain_strategy.md#L30-L73)。

**工程建议**：保留静态兜底和“最近一次成功列表”；异步刷新不能让冷启动缺少任何可用列表。多个引导地址本身也需要可达，配置返回的域名仍需本机检查，不能把配置文件下载成功等同于业务 API 可用。

### 3. 图片 CDN 独立选路

下载器有独立 `DOMAIN_IMAGE_LIST`，与四个 API 域名分开。其默认请求重试代码说明：路径请求可换 API 域名，已带完整域名的 URL（典型是图片）不会因此换域名。作者在图片失败讨论中也专门建议选择本机可访问的图片域名，说明“API 通但图片不通”必须单独处理。[图片列表](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_config.py#L187-L203)、[默认重试实现](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_client_impl.py#L72-L151)、[作者图片域名回复](https://github.com/hect0x7/JMComic-Crawler-Python/discussions/461)。

**工程建议**：API 与图片分别记录成功时间、延迟、错误和冷却期。只有已确认路径格式兼容的 CDN 候选才能替换图片 host；不可任意对 API 与图片域名互换。功能回归最终还需验证实际图片格式及解扰，单测 DNS、TLS、HTTP 200 不足以证明阅读正常。

### 4. DoH 与保留域名的 IP 覆盖

DoH 把 DNS 查询/应答放进 HTTPS，保护的是客户端与解析器之间的 DNS 传输；解析器选择会影响结果，并存在首次解析 DoH 服务器域名的引导问题。DoH 响应 HTTP 200 仍可能包含 NXDOMAIN/SERVFAIL，必须同时检查 DNS 响应码。[RFC 8484 §4.2.1、§10](https://www.rfc-editor.org/rfc/rfc8484.html)。

保留 `https://原域名/`，只在底层将连接目标改成某个 IP，是比把 URL 写成 IP 更合适的诊断方式。libcurl 的 `RESOLVE` 提供 host+port→IP 覆盖；`CONNECT_TO` 明确不改变 TLS SNI、证书校验名及应用协议所使用的主机名。[RESOLVE](https://curl.se/libcurl/c/CURLOPT_RESOLVE.html)、[CONNECT_TO](https://curl.se/libcurl/c/CURLOPT_CONNECT_TO.html)。

**协议限制**：普通 SNI 在 ClientHello 中表示域名，修改 DNS/IP 不等于隐藏这个域名；SNI 的 HostName 也不允许直接放 IP 字面量。直接用 IP URL 还会改变服务身份校验目标。RFC 9525 要求按参考身份校验 DNS-ID 或 IP-ID，不能靠忽略证书错误得到可信连接。[RFC 6066 §3](https://www.rfc-editor.org/rfc/rfc6066.html#section-3)、[RFC 9525 §6](https://www.rfc-editor.org/rfc/rfc9525.html#section-6)。

**工程建议**：先诊断 DNS，再决定是否启用 DoH/覆盖；按 TTL 更新，支持 A/AAAA，限制到目标服务域名。它们不能处理所有 IP 路由故障、服务端地区策略或按 SNI 识别的干扰。

### 5. ECH：已有可读代码，可作为独立实验

JMComic-qt 在历史 `v1.3.3` 发行记录中宣布引入 ECH、DoH 和 HTTP/3；当前发布线已有 `v1.3.7`。应分别核对发行声明与当前源代码，不能仅凭“有开关”宣称握手实际使用 ECH。[发行记录](https://github.com/tonquer/JMComic-qt/releases)。

当前固定快照可串起以下活动路径：

1. 登录界面初始化 ECH 配置，使用配置的多个 DoH 入口；成功时保存到 `QtOwner().echConfig`，失败后约 1 分钟重试，成功后约 15 分钟刷新。[配置获取与定时刷新](https://github.com/tonquer/JMComic-qt/blob/c12629508bb43404ff667cb6f36f9d97f782390b/src/view/user/login_new_view.py#L90-L130)。
2. 查询类型为 HTTPS RR（65），POST `application/dns-message`，从服务参数 key 5 取 ECHConfigList 并编码。[DNS 请求和响应解析](https://github.com/tonquer/JMComic-qt/blob/c12629508bb43404ff667cb6f36f9d97f782390b/src/server/req.py#L1093-L1179)。
3. API/图片等受支持请求根据开关把配置传给 `CurlOpt.ECH = ecl:...`；可另设 `RESOLVE` 指定 IP，HTTP/3 是另一个选项。服务器执行请求时复制该请求的 curl options 到会话。[请求配置](https://github.com/tonquer/JMComic-qt/blob/c12629508bb43404ff667cb6f36f9d97f782390b/src/server/req.py#L137-L165)、[实际请求入口](https://github.com/tonquer/JMComic-qt/blob/c12629508bb43404ff667cb6f36f9d97f782390b/src/server/server.py#L350-L368)。

该实现默认查询公共 `cloudflare-ech.com` 的配置，再用于符合条件的请求。这是该客户端采用的策略；本次未验证它适用于全部 JM API/图片 host，也未验证源站/CDN 当前握手接受情况。[ECH 域名配置](https://github.com/tonquer/JMComic-qt/blob/c12629508bb43404ff667cb6f36f9d97f782390b/src/config/global_config.py#L86-L90)。

libcurl 官方文档说明 ECH 需要 TLS 1.3，`ecl:` 是显式 ECHConfigList，库版本、TLS 后端与构建能力有要求；文档当前仍标为实验性。Cloudflare 也明确 ECH 需要客户端及服务端支持，配置通过 DNS HTTPS 记录分发。因此，**不能把 ECH 等同于关闭 SNI，也不能把 HTTP/3 等同于 ECH**。[libcurl ECH](https://curl.se/libcurl/c/CURLOPT_ECH.html)、[Cloudflare ECH](https://developers.cloudflare.com/ssl/edge-certificates/ech/)。

**工程建议**：先在独立原型中验证目标 host 的 HTTPS RR、ECH 配置获取、实际协商及失败回退，再决定是否接入本仓库。不能仅因库支持 TLS 1.3 就推断支持 ECH。特定 CDN 的 IP 覆盖也不能泛化成任意“优选 IP”都能提供目标站点服务。

### 6. 协议漂移与网络故障必须分开

JMComic-qt `v1.3.7` 发行说明包含“更新 JM3 接口”。这只证明该客户端作过协议升级，不能由此断言其他实现使用的旧接口已失效。[v1.3.7 发行记录](https://github.com/tonquer/JMComic-qt/releases/tag/v1.3.7)。

下载器还含 API 响应解码、请求头与 Cookie 初始化逻辑，说明 HTTP 传输连通只是第一层。**工程推断**：HTTP 200 后解密失败、返回模型变化、认证失败应归入协议/会话诊断，不宜无休止换 DNS 或域名。[API 初始化与 Cookie](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_client_impl.py#L1314-L1408)。

## 方案比较与顺序

以下收益与成本是工程判断，非本次大陆网络测试结果。

| 方案 | 主要处理的问题 | 无法保证解决 | 建议优先级 |
| --- | --- | --- | --- |
| 动态域名 + 最近成功缓存 + 静态兜底 | 域名轮换、单入口失效 | 全部入口不可达、协议变化 | 首先完成 |
| API/图片分别选路与失败回退 | 元数据能读、图片不能读 | 全部图片 host 不可达 | 首先完成 |
| 按域名 DoH | 本地解析异常 | IP/SNI 干扰、服务端拒绝 | 诊断后启用 |
| 保留域名的 IP 覆盖 | DNS 异常、部分节点差异 | SNI 问题、IP 过期、任意 CDN 映射 | 诊断工具/可撤销选项 |
| ECH + 可达解析/入口 | 部分暴露真实 ClientHello 名称的问题 | 不支持 ECH、IP 不通、配置过期 | 独立原型验证 |
| HTTP/3 | 传输路径与性能差异 | UDP 不可用、没有 ECH、协议错误 | 可选实验 |
| 删除 SNI、忽略证书、IP URL | 依赖特殊服务端行为 | 正确虚拟主机路由及可信身份 | 不作为默认设计 |
| 第三方转发/海外代下载 | 改变出口与网络路径 | 仍不属于本文定义的直连 | 分开讨论 |

历史 PicaComic 代码对部分 CDN/IP 放宽证书检查，是可核实的旧实现，不能作为新实现的 TLS 模板；新方案应保留服务身份校验。[历史校验代码](https://github.com/wgh136/PicaComic/blob/155cf0c6d7018f9521f8c375b142bafd85e47a4d/lib/network/http_client.dart#L94-L109)、[TLS 身份标准](https://www.rfc-editor.org/rfc/rfc9525.html)。

## 本仓库适配

以下基于本仓库 `8d7d3deec8bfab0e2a0b2c567bf4d81dc5cda4ce`，以及外部 `venera-app/venera-configs` 的 `jm.js` 提交 `40be5f6e14bb9303ea3b1c512932b91cdd01d0b8`。后者图源版本为 `1.4.0`、声明 JM 协议版本为 `2.0.16`；图源由应用另外安装，本仓库没有内置该脚本，因此不能推断用户已安装的版本。[固定图源源码](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L1-L30)。

### 已有能力与实际缺口

| 层次 | 当前实现 | 对直连方案的影响 |
| --- | --- | --- |
| 图源引导 | 从一处香港 BytePlus 配置取 `Server` 前四项；请求失败/非 200 时使用四个内置域名 | 已有动态入口，但没有多引导地址与最近成功列表缓存；成功响应的解密/JSON 错误不在请求的 try/catch 内 |
| API | 按 `apiDomain` 设置选择四路之一，GET/POST 对当前基址发请求 | 未见请求失败后自动切换候选；不能把“四路可选”等同于自动容错 |
| 图片 | 按 `imageStream` 调用 `/setting?app_img_shunt=…`，用返回的 `img_host` 生成封面、正文、头像 URL | API 与图片基址已分开，但没有图片 host 池和自动回退 |
| 图片处理 | `onImageLoad` 提供请求头与解扰；`onThumbnailLoad` 提供请求头 | 换 CDN 要保留请求头、路径、查询参数和解扰逻辑 |

以上来自图源的[引导与图片配置](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L106-L198)、[API 请求](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L255-L302)、[图片加载配置](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L826-L915)及[设置](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L993-L1042)，是静态源码结论，未做该版本运行回归。

还有两个启动/设置风险需要先处理：

- `JM.apiDomains` 只在刷新列表后赋值，未见静态初值；关闭“启动时刷新域名列表”后，新的运行时可能没有 API 列表。`init()` 的图片刷新也未被 await。应先同步装载兜底/缓存，再刷新远端，并向调用方暴露初始化完成或失败状态。[图源初始化与赋值](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L38-L53)、[初始化调用](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L119-L122)。宿主解析器也以延时回调触发图源初始化，不等待网络初始化完成，不能仅给图源内部增加 await 就宣称整个启动流程已有保障。[宿主解析器](../lib/foundation/comic_source/parser.dart)
- 本仓库的图源 select 设置仅保存值，不触发刷新回调；修改“图片分流”后，已有 `JM.imageUrl` 不会立即重新获取。后续应增加明确的“应用/刷新图片线路”动作，或在实际加载前检查设置变化。[图源设置页面](../lib/pages/comic_source_page.dart)、[图片刷新实现](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L186-L198)

宿主的网络边界也需要保留：

- `AppDio` 使用共享 `RHttpAdapter`；正常图源请求、封面与正文图片可以在这一层应用网络策略。JS 的 `fetch` 最终也调用宿主 `Network.fetchBytes`，不是浏览器网络栈。[AppDio](../lib/network/app_dio.dart)、[图片下载器](../lib/network/images.dart)、[JS fetch](../assets/init.js)
- 当前 EH 直连只匹配 EH 白名单和 H@H 域名，JM 不在其中。它会绕过应用代理并关闭 SNI；不要直接扩大名单，就把这套策略当作已经验证的 JM 直连。[网络适配器](../lib/network/rhttp_adapter.dart)、[EH 域名与解析策略](../lib/network/eh_direct_connection.dart)、[现有直连说明](eh_direct_connection.md)
- 对普通请求已有全局代理选择、DNS 覆盖和 SNI 开关。DNS 覆盖保持业务 URL；当前 SNI 开关会影响使用适配器的其他站点，不能当作 JM 专用开关。显式使用 `http_client: dart:io` 的非 EH 图源请求另走 Dart 客户端，需要另查覆盖范围。[网络设置](../lib/pages/settings/network.dart)、[代理实现](../lib/network/proxy.dart)、[JS 请求桥接](../lib/foundation/js_engine.dart)
- 当前锁定 `rhttp 0.15.1`、Rust `1.85.1`。宿主未接入 ECH 配置或 HTTPS RR 查询；这个结论不等于断言其全部底层依赖都没有 ECH 能力。引入新网络后端、升级原生依赖，应作为独立改动评估。[锁文件](../pubspec.lock)、[工具链](../rust-toolchain.toml)、[适配器配置](../lib/network/rhttp_adapter.dart)

### 现有版本可先尝试的操作

以下是基于代码的排查顺序，不是已实测成功的设置组合：

1. 确认应用使用“无代理”配置，并确认系统 VPN/TUN 的实际路由；应用“无代理”不能改变系统 VPN 路由。[代理配置](../lib/network/proxy.dart)
2. 在 JM 图源设置刷新域名列表并应用，保留“启动时刷新域名列表”开启；分别尝试 API 线路。记录失败阶段，不能仅凭首页显示判断成功。
3. API 通而图片不通时，单独切换“图片分流”。当前脚本可通过再次“刷新域名列表 → 应用”触发 `refreshImgUrl(true)`，或在开启启动刷新时重新初始化应用；等待刷新成功后重试图片。更改图片分流本身不会立即更新地址。[刷新按钮回调](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L159-L198)
4. 只有证据指向解析异常时，才针对实际失败 host 尝试可信解析得到的 IP 覆盖。保留 SNI 和证书校验；若 TCP/TLS 仍失败，继续检查路由/握手，不继续堆叠过期 IP。

### 建议的实施边界

**第一阶段优先改图源，成本较低**：初始化兜底与最近成功缓存、多引导地址、有总时限的 API 读取换线、图片配置即时刷新、API 与图片独立健康状态。正文可利用已有 `ImageLoadingConfig.onLoadFailed` 返回替代 URL 和完整加载配置；缩略图接口文档明确不支持这个失败回调，封面回退需要另作设计，不能声称正文方案自动覆盖封面。[图片加载器](../lib/network/images.dart)、[图源说明](comic_source.md)、[图源/JS API](js_api.md)

这些改动主要属于外部图源仓库，需明确维护和更新来源，防止用户更新图源后覆盖本地修改。保持 `key=jm`、漫画/章节 ID、账号与收藏数据格式，不用新图源身份解决线路问题。API 镜像间的 Cookie/登录状态要单独回归，收藏、评论等写入不做盲目重放。[图源标识](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L4-L19)、[登录与登出](https://github.com/venera-app/venera-configs/blob/40be5f6e14bb9303ea3b1c512932b91cdd01d0b8/jm.js#L345-L375)

**第二阶段按故障证据改宿主，成本中至高**：先验证目标 host 的 ECH 协商，再评估当前后端能否暴露所需能力。若要新增 JM 专用直连，应按 host/请求选择策略，并处理动态发现域名的信任边界、逐跳重定向、代理、证书与 WebView 覆盖范围；复用已有网络分层，但不复制 EH 固定 IP、Cloudflare 别名或无 SNI 假设。只做一次连通性请求不足以批准新后端，需要覆盖 API、封面、正文和下载。

本次只新增调研文档，没有实现上述功能，也没有修改网络设置、图源或依赖。

## 验证与交付建议

以下为后续实施验收清单，本次没有执行目标服务实测：

1. 记录日期、平台、地区和运营商；确认实际请求没有经过系统代理、应用代理或 TUN，避免把代理成功当直连成功。
2. 分别检查引导配置、API、图片 host；先核对 DNS 响应，再看 TCP/QUIC、TLS、HTTP、解码/模型。按阶段分类记录，不能只输出“网络错误”。
3. IP 覆盖测试仍用原域名 URL，维持证书校验；对比默认解析和指定解析的结果，避免把所有复位都归为 SNI 问题。
4. 用测试账号与测试数据做协议回归；验证 API 返回结构和图片解码，区分业务成功与仅 HTTP 200。
5. 人工注入首个域名超时、配置下载失败、图片首选 host 失败、缓存过期、ECH 不支持，核对总超时、冷却、回退及用户选择是否被保留。
6. 读取请求可有界重试；收藏等写入动作不要因模糊网络错误在多个入口盲目重放。日志只保留 host、阶段、耗时及脱敏错误，不记录账号、Cookie、完整内容 URL。

默认重试策略和高级插件已提供域名切换、失败次数记录等先例；本仓库宜选有总时限的策略，不照搬可能很长的“每域名重复多次再换域名”。[下载器默认重试](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/src/jmcomic/jm_client_impl.py#L72-L151)、[高级策略说明](https://github.com/hect0x7/JMComic-Crawler-Python/blob/fd8953025db5b844f1b7f025d063f544e61a2dbd/assets/docs/sources/tutorial/12_domain_strategy.md#L77-L98)。

## 本次调研限制

- 已联网核对开源代码、维护者文档/发行记录及协议文档；未访问或摘录漫画内容。
- 没有大陆三网、跨地区、IPv4/IPv6 或 Android/Windows 的 JM 实际请求矩阵；本文不发布“当前保证可用域名/IP”。
- 没有证明目标 host 当前启用 ECH，也没有验证特定二进制所带 TLS 后端、实际 ECH 协商状态和 HTTP/3 成功率。
- 动态域名配置协议、客户端接口与站点策略可能继续改变；固定提交是追溯依据，不是永久兼容承诺。
