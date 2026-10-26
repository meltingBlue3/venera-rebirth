import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rhttp/rhttp.dart' as rhttp;

/// PicACG's Cloudflare route keeps the URL, Host, signature and certificate
/// identity intact. ECH is required; a failed lookup never falls back to SNI.
class PicacgDirectConnection {
  PicacgDirectConnection({
    Future<Uint8List> Function(String, Uint8List)? query,
    DateTime Function()? now,
  }) : _query = query ?? _queryDns,
       _now = now ?? DateTime.now;

  static final instance = PicacgDirectConnection();

  // Exact hosts from picacg-qt's original service/image routes. Third-party
  // reverse proxies and arbitrary subdomains must retain their normal policy.
  static const hosts = {
    'picaapi.picacomic.com',
    's3.picacomic.com',
    's2.picacomic.com',
    'storage1.picacomic.com',
    'storage-b.picacomic.com',
    'img.picacomic.com',
    'storage.diwodiwo.xyz',
    'img.diwodiwo.xyz',
    'storage.tipatipa.xyz',
    'img.tipatipa.xyz',
    'img.safedataplj.com',
    'pica-pica.wikawika.xyz',
  };
  static const dohEndpoints = [
    'https://doh.pub/dns-query',
    'https://dns.alidns.com/dns-query',
    'https://cloudflare-dns.com/dns-query',
  ];
  static const echDomain = 'cloudflare-ech.com';
  // Bootstrap candidates used by picacg-qt, only when encrypted A lookup fails.
  static const fallbackAddresses = ['104.21.91.145', '188.114.98.153'];

  // These hosts use Cloudflare ECH. Some authenticated domestic resolvers
  // return unrelated addresses for blocked names, so HTTPS alone does not
  // make their A answers usable. Source: https://www.cloudflare.com/ips-v4/
  static final _cloudflareRanges =
      [
        '173.245.48.0/20',
        '103.21.244.0/22',
        '103.22.200.0/22',
        '103.31.4.0/22',
        '141.101.64.0/18',
        '108.162.192.0/18',
        '190.93.240.0/20',
        '188.114.96.0/20',
        '197.234.240.0/22',
        '198.41.128.0/17',
        '162.158.0.0/15',
        '104.16.0.0/13',
        '104.24.0.0/14',
        '172.64.0.0/13',
        '131.0.72.0/22',
      ].map((cidr) {
        final parts = cidr.split('/');
        final mask = (0xffffffff << (32 - int.parse(parts[1]))) & 0xffffffff;
        return (_ipv4Number(parts[0])!, mask);
      }).toList();

  static int? _ipv4Number(String address) {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null || parsed.type != InternetAddressType.IPv4) return null;
    return parsed.rawAddress.fold<int>(0, (value, byte) => (value << 8) | byte);
  }

  static bool _isCloudflareAddress(String address) {
    final value = _ipv4Number(address);
    return value != null &&
        _cloudflareRanges.any((range) => (value & range.$2) == range.$1);
  }

  static bool appliesTo(Uri uri) =>
      uri.scheme == 'https' && uri.port == 443 && hosts.contains(uri.host);

  final Future<Uint8List> Function(String, Uint8List) _query;
  final DateTime Function() _now;
  final _cache = <String, (DateTime, PicacgDnsAnswer)>{};
  final _pending = <String, Future<PicacgDnsAnswer>>{};

  void clear() => _cache.clear();

  Future<Uint8List> echConfigList() async {
    final answer = await _lookup(echDomain, 65);
    if (answer.echConfigList == null) {
      throw StateError('PicACG direct connection: no ECH configuration');
    }
    return Uint8List.fromList(answer.echConfigList!);
  }

  Future<List<String>> resolve(String host) async {
    if (!hosts.contains(host)) {
      throw StateError('Not a PicACG direct connection host: $host');
    }
    try {
      final answer = await _lookup(host, 1);
      if (answer.addresses.isNotEmpty) return List.of(answer.addresses);
    } catch (_) {
      // DNS bootstrap fallback still requires ECH and hostname verification.
    }
    return List.of(fallbackAddresses);
  }

  Future<PicacgDnsAnswer> _lookup(String host, int type) {
    final key = '$host/$type';
    final cached = _cache[key];
    if (cached != null && cached.$1.isAfter(_now())) {
      return Future.value(cached.$2);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final packet = PicacgDnsAnswer.question(host, type);
        for (final endpoint in dohEndpoints) {
          try {
            final bytes = await _query(endpoint, packet);
            var answer = PicacgDnsAnswer.parse(bytes, packet);
            if (type == 65 && answer.echConfigList == null) continue;
            if (type == 1) {
              final addresses = answer.addresses
                  .where(_isCloudflareAddress)
                  .toList();
              if (addresses.isEmpty) continue;
              answer = PicacgDnsAnswer(addresses, null, answer.ttl);
            }
            _cache[key] = (
              _now().add(Duration(seconds: answer.ttl.clamp(1, 900))),
              answer,
            );
            return answer;
          } catch (_) {
            // Try another authenticated resolver, never the system DNS.
          }
        }
        throw StateError(
          'PicACG direct connection: encrypted DNS lookup failed ($host)',
        );
      } finally {
        _pending.remove(key);
      }
    });
  }

  static Future<Uint8List> _queryDns(String endpoint, Uint8List packet) async {
    final response = await rhttp.Rhttp.requestBytes(
      method: rhttp.HttpMethod.post,
      url: endpoint,
      headers: const rhttp.HttpHeaders.rawMap({
        'accept': 'application/dns-message',
        'content-type': 'application/dns-message',
      }),
      body: rhttp.HttpBody.bytes(packet),
      settings: const rhttp.ClientSettings(
        proxySettings: rhttp.ProxySettings.noProxy(),
        redirectSettings: rhttp.RedirectSettings.none(),
        tlsSettings: rhttp.TlsSettings(sni: true, verifyCertificates: true),
        timeoutSettings: rhttp.TimeoutSettings(
          timeout: Duration(seconds: 5),
          connectTimeout: Duration(seconds: 4),
        ),
      ),
    );
    if (response.statusCode != 200 || response.body.length > 65535) {
      throw StateError('Invalid encrypted DNS response');
    }
    return response.body;
  }
}

/// Minimal bounds-checked DNS wire reader for A and HTTPS/ECH answers.
class PicacgDnsAnswer {
  PicacgDnsAnswer(this.addresses, this.echConfigList, this.ttl);

  final List<String> addresses;
  final Uint8List? echConfigList;
  final int ttl;

  static Uint8List question(String host, int type) {
    final id = Random.secure().nextInt(65536);
    return Uint8List.fromList([
      id >> 8,
      id & 255,
      1,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      for (final label in host.split('.')) ...[
        label.length,
        ...label.codeUnits,
      ],
      0,
      type >> 8,
      type & 255,
      0,
      1,
    ]);
  }

  static PicacgDnsAnswer parse(Uint8List packet, Uint8List query) {
    Never invalid() => throw const FormatException('Invalid DNS response');
    if (packet.length < query.length || packet.length < 12) invalid();
    final data = ByteData.sublistView(packet);
    int u16(int i) {
      if (i < 0 || i + 2 > packet.length) invalid();
      return data.getUint16(i);
    }

    if (u16(0) != ByteData.sublistView(query).getUint16(0) ||
        (u16(2) & 0xfa0f) != 0x8000 ||
        u16(4) != 1) {
      invalid();
    }
    // Require our exact question, including class/type, not an unrelated reply.
    for (var i = 12; i < query.length; i++) {
      if (packet[i] != query[i]) invalid();
    }
    int skipName(int offset, int end) {
      while (offset < end) {
        final length = packet[offset++];
        if (length == 0) return offset;
        if ((length & 0xc0) == 0xc0) {
          if (offset >= end ||
              ((length & 63) << 8 | packet[offset]) >= packet.length) {
            invalid();
          }
          return offset + 1;
        }
        if (length > 63 || offset + length > end) invalid();
        offset += length;
      }
      return invalid();
    }

    var offset = query.length;
    var ttl = 900;
    final addresses = <String>[];
    Uint8List? ech;
    for (var i = 0; i < u16(6); i++) {
      offset = skipName(offset, packet.length);
      if (offset + 10 > packet.length) invalid();
      final type = u16(offset);
      final dnsClass = u16(offset + 2);
      final recordTtl = data.getUint32(offset + 4);
      final length = u16(offset + 8);
      offset += 10;
      final end = offset + length;
      if (end > packet.length) invalid();
      if (dnsClass == 1 && type == 1 && length == 4) {
        addresses.add(
          InternetAddress.fromRawAddress(packet.sublist(offset, end)).address,
        );
        ttl = min(ttl, recordTtl);
      }
      if (dnsClass == 1 && type == 65 && length >= 3 && u16(offset) > 0) {
        var param = skipName(offset + 2, end);
        while (param < end) {
          if (param + 4 > end) invalid();
          final key = u16(param);
          final size = u16(param + 2);
          param += 4;
          if (param + size > end) invalid();
          if (key == 5 && size > 2) {
            ech ??= packet.sublist(param, param + size);
            ttl = min(ttl, recordTtl);
          }
          param += size;
        }
      }
      offset = end;
    }
    return PicacgDnsAnswer(addresses, ech, ttl);
  }
}
