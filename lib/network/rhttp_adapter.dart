import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

import 'cookie_jar.dart';
import 'eh_direct_connection.dart';
import 'jm_direct_connection.dart';
import 'picacg_direct_connection.dart';
import 'proxy.dart';

class RHttpAdapter implements HttpClientAdapter {
  RHttpAdapter({this.send = _send, this.cookieJar, this.picacg});

  final Future<rhttp.HttpResponse> Function(rhttp.HttpRequest) send;
  final CookieJarSql? cookieJar;
  final PicacgDirectConnection? picacg;

  // Rhttp.send(BaseHttpRequest) rebuilds the request and drops its settings
  // unless passed separately. HttpRequest.send() retains the routing policy.
  static Future<rhttp.HttpResponse> _send(rhttp.HttpRequest request) =>
      request.send();

  Future<rhttp.ClientSettings> settingsFor(
    Uri uri, {
    bool followRedirects = true,
    int maxRedirects = 5,
  }) async {
    final direct =
        appdata.settings['ehDirectConnection'] == true &&
        EhDirectConnection.appliesTo(uri);
    final jmDirect =
        appdata.settings['jmDirectConnection'] == true &&
        JmDirectConnection.instance.appliesTo(uri);
    final picaDirect =
        appdata.settings['picacgDirectConnection'] == true &&
        PicacgDirectConnection.appliesTo(uri);
    final pica = picacg ?? PicacgDirectConnection.instance;
    final proxy = direct || jmDirect || picaDirect ? null : await getProxy();
    final overrides = _getOverrides();
    return rhttp.ClientSettings(
      // H@H nodes can reject negotiated HTTP/2 or close its TLS stream early.
      // HTTP/1.1 keeps image transfer compatible without relaxing TLS checks.
      httpVersionPref: direct && EhDirectConnection.isHathHost(uri.host)
          ? rhttp.HttpVersionPref.http1_1
          : rhttp.HttpVersionPref.all,
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      redirectSettings: followRedirects
          ? rhttp.RedirectSettings.limited(maxRedirects)
          : const rhttp.RedirectSettings.none(),
      timeoutSettings: rhttp.TimeoutSettings(
        timeout: jmDirect ? const Duration(seconds: 12) : null,
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: direct
          ? rhttp.DnsSettings.dynamic(
              resolver: EhDirectConnection(overrides: overrides).resolve,
            )
          : jmDirect
          ? rhttp.DnsSettings.dynamic(
              resolver: (host) async =>
                  overrides[host.toLowerCase()] ??
                  await JmDirectConnection.instance.resolve(host),
            )
          : picaDirect
          ? rhttp.DnsSettings.dynamic(
              resolver: (host) async =>
                  overrides[host.toLowerCase()] ?? await pica.resolve(host),
            )
          : rhttp.DnsSettings.static(overrides: overrides),
      tlsSettings: rhttp.TlsSettings(
        sni:
            picaDirect ||
            jmDirect ||
            (!direct && appdata.settings['sni'] != false),
        verifyCertificates:
            direct ||
            jmDirect ||
            picaDirect ||
            appdata.settings['ignoreBadCertificate'] != true,
        echConfigList: picaDirect ? await pica.echConfigList() : null,
      ),
    );
  }

  static Map<String, List<String>> _getOverrides() {
    if (appdata.settings['enableDnsOverrides'] != true) return {};
    final config = appdata.settings['dnsOverrides'];
    return {
      if (config is Map)
        for (final entry in config.entries)
          if (entry.key is String && entry.value is String)
            (entry.key as String).trim().toLowerCase(): [entry.value as String],
    };
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var uri = options.uri;
    var method = options.method;
    var body = requestStream;
    final headers = <String, String>{
      for (final entry in options.headers.entries)
        entry.key.toLowerCase(): entry.value.toString().trim(),
    };
    headers.putIfAbsent('user-agent', () => 'venera/v${App.version}');
    final jar = cookieJar ?? SingleInstanceCookieJar.instance;
    if ((appdata.settings['ehDirectConnection'] == true &&
            EhDirectConnection.appliesTo(uri)) ||
        (appdata.settings['jmDirectConnection'] == true &&
            JmDirectConnection.instance.appliesTo(uri)) ||
        (appdata.settings['picacgDirectConnection'] == true &&
            PicacgDirectConnection.appliesTo(uri))) {
      final cookies = jar?.loadForRequestCookieHeader(uri);
      if (cookies != null && cookies.isNotEmpty) {
        headers.putIfAbsent('cookie', () => cookies);
      }
    }
    final explicitCookies = _parseCookies(headers['cookie'] ?? '');
    for (final cookie in jar?.loadForRequest(uri) ?? []) {
      explicitCookies.remove(cookie.name);
    }
    final redirects = <RedirectRecord>[];
    // A client's TLS/proxy settings apply to every native redirect. Follow
    // redirects here while the feature is enabled so each target gets its own
    // policy, including redirects from unrelated sites into EH and back out.
    final routeRedirects =
        appdata.settings['ehDirectConnection'] == true ||
        appdata.settings['jmDirectConnection'] == true ||
        appdata.settings['picacgDirectConnection'] == true;
    final token = cancelFuture == null ? null : rhttp.CancelToken();
    var finished = false;
    var returnedStream = false;
    cancelFuture?.then((_) {
      if (!finished) unawaited(token!.cancel());
    });
    try {
      while (true) {
        final response = await send(
          rhttp.HttpRequest(
            method: rhttp.HttpMethod(method),
            url: uri.toString(),
            settings: await settingsFor(
              uri,
              followRedirects: !routeRedirects && options.followRedirects,
              maxRedirects: options.maxRedirects,
            ),
            expectBody: rhttp.HttpExpectBody.stream,
            body: body == null ? null : rhttp.HttpBody.stream(body),
            headers: rhttp.HttpHeaders.rawMap(Map.of(headers)),
            cancelToken: token,
          ),
        );
        if (response is! rhttp.HttpStreamResponse) {
          throw StateError('Invalid response type: ${response.runtimeType}');
        }
        final responseHeaders = <String, List<String>>{};
        for (final entry in response.headers) {
          (responseHeaders[entry.$1.toLowerCase()] ??= []).add(entry.$2);
        }
        final status = response.statusCode;
        final location = responseHeaders['location']?.firstOrNull;
        final isRedirect = {301, 302, 303, 307, 308}.contains(status);
        final dropBody =
            status == 303 ||
            ((status == 301 || status == 302) && method == 'POST');
        // Dio supplies a single-use body stream. As with reqwest, do not replay
        // it on a redirect that preserves the request body.
        if (!routeRedirects ||
            !options.followRedirects ||
            !isRedirect ||
            location == null ||
            (body != null && !dropBody)) {
          returnedStream = true;
          Stream<Uint8List> responseStream() async* {
            try {
              yield* response.body;
            } finally {
              finished = true;
            }
          }

          return ResponseBody(
            responseStream(),
            status,
            statusMessage: _getStatusMessage(status),
            headers: responseHeaders,
            isRedirect: isRedirect,
            redirects: redirects,
          );
        }
        final next = uri.resolve(location);
        if (next.scheme != 'https' && next.scheme != 'http') {
          await response.body.listen(null).cancel();
          throw DioException(
            requestOptions: options,
            message: 'Unsupported redirect scheme: ${next.scheme}',
          );
        }
        if (redirects.length >= options.maxRedirects) {
          await response.body.listen(null).cancel();
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: 'Too many redirects',
          );
        }
        jar?.saveFromResponseCookieHeader(
          uri,
          responseHeaders['set-cookie'] ?? [],
        );
        await response.body.listen(null).cancel();
        if (dropBody) {
          if (method != 'HEAD') method = 'GET';
          body = null;
          for (final name in [
            'content-length',
            'content-type',
            'transfer-encoding',
          ]) {
            headers.remove(name);
          }
        }
        if (next.host != uri.host ||
            next.port != uri.port ||
            next.scheme != uri.scheme) {
          explicitCookies.clear();
          for (final name in [
            'authorization',
            'proxy-authorization',
            'cookie',
            'host',
          ]) {
            headers.remove(name);
          }
        }
        final cookies = {
          ...explicitCookies,
          ..._parseCookies(jar?.loadForRequestCookieHeader(next) ?? ''),
        };
        headers.remove('cookie');
        if (cookies.isNotEmpty) {
          headers['cookie'] = cookies.entries
              .map((entry) => '${entry.key}=${entry.value}')
              .join('; ');
        }
        redirects.add(RedirectRecord(status, method, next));
        uri = next;
      }
    } finally {
      if (!returnedStream) finished = true;
    }
  }

  static Map<String, String> _parseCookies(String header) {
    final cookies = <String, String>{};
    for (final part in header.split(';')) {
      final separator = part.indexOf('=');
      if (separator > 0) {
        cookies[part.substring(0, separator).trim()] = part
            .substring(separator + 1)
            .trim();
      }
    }
    return cookies;
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}
