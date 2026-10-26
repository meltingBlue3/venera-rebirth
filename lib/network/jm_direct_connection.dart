import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rhttp/rhttp.dart' as rhttp;

/// JM routing is separate from EH: keep SNI and verify the original hostname.
class JmDirectConnection {
  JmDirectConnection({
    Future<Map<String, dynamic>> Function(String, String, int)? query,
    Future<List<InternetAddress>> Function(String)? lookup,
    DateTime Function()? now,
  }) : _query = query ?? _queryDns,
       _lookup = lookup ?? InternetAddress.lookup,
       _now = now ?? DateTime.now;

  static final instance = JmDirectConnection();

  static const bootstrapHosts = [
    'rup4a04-c03.tos-cn-beijing.bytepluses.com.cn',
    'rup4a04-c02.tos-cn-hongkong.bytepluses.com',
    'rup4a04-c01.tos-ap-southeast-1.bytepluses.com',
  ];
  static const apiHosts = [
    'www.cdnhjk.net',
    'www.cdngwc.cc',
    'www.cdngwc.net',
    'www.cdngwc.club',
    'www.cdntwice.org',
    'www.cdnsha.org',
    'www.cdnaspa.cc',
    'www.cdnntr.cc',
  ];
  static const imageHosts = [
    'cdn-msp.jmapiproxy1.cc',
    'cdn-msp.jmapiproxy2.cc',
    'cdn-msp2.jmapiproxy2.cc',
    'cdn-msp3.jmapiproxy2.cc',
    'cdn-msp.jmapinodeudzn.net',
    'cdn-msp3.jmapinodeudzn.net',
  ];

  final _apis = <String>{...apiHosts};
  final _images = <String>{...imageHosts};
  final _cache = <String, (DateTime, List<String>)>{};
  final _pending = <String, Future<List<String>>>{};
  final _workingImageHosts = <String, String>{};
  final Future<Map<String, dynamic>> Function(String, String, int) _query;
  final Future<List<InternetAddress>> Function(String) _lookup;
  final DateTime Function() _now;

  /// Called only by the JM compatibility layer after decoding its configuration.
  void register({
    Iterable<String> api = const [],
    Iterable<String> images = const [],
  }) {
    void add(Set<String> target, Iterable<String> values) {
      for (final value in values.take(32)) {
        final host = value.toLowerCase();
        if (target.length < 64 && isDomain(host)) target.add(host);
      }
    }

    add(_apis, api);
    add(_images, images);
  }

  static bool isDomain(String host) =>
      host.length <= 253 &&
      host.contains('.') &&
      InternetAddress.tryParse(host) == null &&
      host
          .split('.')
          .every(
            (label) => RegExp(
              r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
            ).hasMatch(label),
          );

  bool appliesTo(Uri uri) =>
      uri.scheme == 'https' &&
      (bootstrapHosts.contains(uri.host) ||
          _apis.contains(uri.host) ||
          _images.contains(uri.host));

  bool isImage(Uri uri) =>
      uri.scheme == 'https' &&
      _images.contains(uri.host) &&
      RegExp(r'^/media/(albums|photos|users)/').hasMatch(uri.path);

  List<Uri> imageCandidates(Uri uri) {
    if (!isImage(uri)) return [uri];
    return {
      if (_workingImageHosts[uri.host] case final host?) host,
      uri.host,
      ..._images,
    }.take(3).map((host) => uri.replace(host: host)).toList();
  }

  void imageSucceeded(Uri original, Uri used) {
    if (isImage(original) && isImage(used)) {
      _workingImageHosts[original.host] = used.host;
    }
  }

  Future<List<String>> resolve(String host) async {
    host = host.toLowerCase();
    final cached = _cache[host];
    if (cached != null && cached.$1.isAfter(_now())) return List.of(cached.$2);
    final pending = _pending[host];
    if (pending != null) return List.of(await pending);
    final future = _resolve(host);
    _pending[host] = future;
    try {
      return List.of(await future);
    } finally {
      _pending.remove(host);
    }
  }

  Future<List<String>> _resolve(String host) async {
    for (final provider in ['dns.alidns.com', 'doh.pub']) {
      final responses = await Future.wait(
        [1, 28].map((type) async {
          try {
            return await _query(
              provider,
              host,
              type,
            ).timeout(const Duration(seconds: 2));
          } catch (_) {
            return <String, dynamic>{};
          }
        }),
      );
      final addresses = <String>{};
      var ttl = 300;
      for (final response in responses) {
        if (response['Status'] != 0 || response['Answer'] is! List) continue;
        for (final answer in response['Answer'] as List) {
          if (answer is! Map) continue;
          // A cached address must not outlive an alias used to reach it.
          if ([1, 28, 5].contains(answer['type']) && answer['TTL'] is num) {
            ttl = (answer['TTL'] as num).toInt().clamp(0, ttl);
          }
          if (![1, 28].contains(answer['type'])) continue;
          final ip = InternetAddress.tryParse(answer['data'].toString());
          if (ip == null ||
              ip.isLoopback ||
              ip.isLinkLocal ||
              ip.isMulticast ||
              ip.address == '0.0.0.0' ||
              ip.address == '::') {
            continue;
          }
          addresses.add(ip.address);
        }
      }
      if (addresses.isNotEmpty) {
        if (_cache.length >= 128) _cache.remove(_cache.keys.first);
        _cache[host] = (_now().add(Duration(seconds: ttl)), addresses.toList());
        return addresses.toList();
      }
    }
    // Availability fallback if both encrypted resolvers are unreachable.
    return (await _lookup(host).timeout(
      const Duration(seconds: 2),
    )).map((address) => address.address).toList();
  }

  static Future<Map<String, dynamic>> _queryDns(
    String provider,
    String host,
    int type,
  ) async {
    final response = await rhttp.HttpRequest(
      method: rhttp.HttpMethod.get,
      url: Uri.https(
        provider,
        provider == 'doh.pub' ? '/dns-query' : '/resolve',
        {'name': host, 'type': '$type'},
      ).toString(),
      headers: const rhttp.HttpHeaders.rawMap({
        'accept': 'application/dns-json',
      }),
      expectBody: rhttp.HttpExpectBody.text,
      settings: rhttp.ClientSettings(
        proxySettings: const rhttp.ProxySettings.noProxy(),
        redirectSettings: const rhttp.RedirectSettings.none(),
        timeoutSettings: const rhttp.TimeoutSettings(
          timeout: Duration(seconds: 2),
        ),
        dnsSettings: rhttp.DnsSettings.static(
          overrides: {
            'dns.alidns.com': ['223.5.5.5', '223.6.6.6'],
            'doh.pub': ['1.12.12.12', '120.53.53.53'],
          },
        ),
      ),
    ).send();
    if (response is! rhttp.HttpTextResponse || response.statusCode != 200) {
      throw const FormatException('DNS-over-HTTPS request failed');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }
}
