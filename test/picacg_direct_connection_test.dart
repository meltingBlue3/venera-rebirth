import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/picacg_direct_connection.dart';
import 'package:venera/network/rhttp_adapter.dart';

final _ech = Uint8List.fromList([0, 4, 0xfe, 0x0d, 0, 0]);

Uint8List _answer(
  Uint8List query, {
  int ttl = 120,
  List<int> address = const [104, 21, 91, 145],
}) {
  final type = query[query.length - 3];
  final rdata = type == 65 ? [0, 1, 0, 0, 5, 0, _ech.length, ..._ech] : address;
  return Uint8List.fromList([
    ...query.sublist(0, 2),
    0x81,
    0x80,
    0,
    1,
    0,
    1,
    0,
    0,
    0,
    0,
    ...query.sublist(12),
    0xc0,
    0x0c,
    0,
    type,
    0,
    1,
    0,
    0,
    ttl >> 8,
    ttl & 255,
    0,
    rdata.length,
    ...rdata,
  ]);
}

void main() {
  final saved = <String, dynamic>{};
  setUp(() {
    for (final key in [
      'picacgDirectConnection',
      'ehDirectConnection',
      'jmDirectConnection',
      'proxy',
      'sni',
      'ignoreBadCertificate',
      'enableDnsOverrides',
      'dnsOverrides',
    ]) {
      saved[key] = appdata.settings[key];
    }
    final settings = {
      'picacgDirectConnection': true,
      'ehDirectConnection': false,
      'jmDirectConnection': false,
      'proxy': 'http://127.0.0.1:9',
      'sni': false,
      'ignoreBadCertificate': true,
      'enableDnsOverrides': false,
    };
    for (final entry in settings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });
  tearDown(() {
    for (final entry in saved.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });

  test('routes only exact HTTPS service hosts on port 443', () {
    for (final host in PicacgDirectConnection.hosts) {
      expect(
        PicacgDirectConnection.appliesTo(Uri.https(host, '/static/a')),
        isTrue,
      );
    }
    for (final url in [
      'https://picaapi.picacomic.com.evil.test/',
      'https://evil.picacomic.com/',
      'https://picaapi.go2778.com/',
      'http://picaapi.picacomic.com/',
      'https://picaapi.picacomic.com:8443/',
      'https://bika-api.jpacg.cc/',
    ]) {
      expect(PicacgDirectConnection.appliesTo(Uri.parse(url)), isFalse);
    }
  });

  test('parses compressed answer names, A, ECH and TTL', () {
    for (final type in [1, 65]) {
      final query = PicacgDnsAnswer.question('cloudflare-ech.com', type);
      final answer = PicacgDnsAnswer.parse(_answer(query), query);
      expect(answer.ttl, 120);
      if (type == 1) {
        expect(answer.addresses, ['104.21.91.145']);
      } else {
        expect(answer.echConfigList, _ech);
      }
    }
  });

  test(
    'rejects truncation, wrong IDs/questions, DNS errors and bad lengths',
    () {
      final query = PicacgDnsAnswer.question('cloudflare-ech.com', 65);
      final valid = _answer(query);
      final cases = <Uint8List>[
        valid.sublist(0, valid.length - 1),
        Uint8List.fromList(valid)..[0] ^= 1,
        Uint8List.fromList(valid)..[13] ^= 1,
        Uint8List.fromList(valid)..[2] |= 2,
        Uint8List.fromList(valid)..[3] |= 3,
        Uint8List.fromList(valid)..[query.length + 11] = 255,
      ];
      for (final packet in cases) {
        expect(
          () => PicacgDnsAnswer.parse(packet, query),
          throwsFormatException,
        );
      }
    },
  );

  test('coalesces concurrent lookups and expires at DNS TTL', () async {
    var now = DateTime(2026);
    var count = 0;
    final policy = PicacgDirectConnection(
      now: () => now,
      query: (_, query) async {
        count++;
        await Future<void>.delayed(Duration.zero);
        return _answer(query, ttl: 60);
      },
    );
    await Future.wait(List.generate(10, (_) => policy.echConfigList()));
    expect(count, 1);
    await policy.echConfigList();
    expect(count, 1);
    now = now.add(const Duration(seconds: 60));
    await policy.echConfigList();
    expect(count, 2);
    policy.clear();
    await policy.echConfigList();
    expect(count, 3);
  });

  test('resolver fallback retains required ECH and is bounded', () async {
    var count = 0;
    final policy = PicacgDirectConnection(
      query: (_, query) async {
        count++;
        throw StateError('offline');
      },
    );
    await expectLater(policy.echConfigList(), throwsStateError);
    expect(count, PicacgDirectConnection.dohEndpoints.length);
    expect(
      await policy.resolve('s3.picacomic.com'),
      PicacgDirectConnection.fallbackAddresses,
    );
    await expectLater(policy.resolve('evil.test'), throwsStateError);
  });

  test(
    'rejects non-Cloudflare DoH answers and tries the next resolver',
    () async {
      final endpoints = <String>[];
      final policy = PicacgDirectConnection(
        query: (endpoint, q) async {
          endpoints.add(endpoint);
          return _answer(
            q,
            address: endpoints.length == 1
                ? [130, 211, 15, 150]
                : [104, 21, 91, 145],
          );
        },
      );
      expect(await policy.resolve('picaapi.picacomic.com'), ['104.21.91.145']);
      expect(endpoints, PicacgDirectConnection.dohEndpoints.take(2).toList());
      expect(await policy.resolve('picaapi.picacomic.com'), ['104.21.91.145']);
      expect(endpoints, hasLength(2));
    },
  );

  test(
    'uses bootstrap candidates when every resolver returns an invalid route',
    () async {
      final policy = PicacgDirectConnection(
        query: (_, q) async => _answer(q, address: [47, 88, 58, 234]),
      );
      expect(
        await policy.resolve('storage-b.picacomic.com'),
        PicacgDirectConnection.fallbackAddresses,
      );
    },
  );

  test(
    'ECH route overrides global TLS/proxy preferences and honors manual IP',
    () async {
      final policy = PicacgDirectConnection(query: (_, q) async => _answer(q));
      final adapter = RHttpAdapter(picacg: policy);
      final uri = Uri.https('picaapi.picacomic.com', '/auth/sign-in');
      final settings = await adapter.settingsFor(uri);
      expect(settings.proxySettings, const rhttp.ProxySettings.noProxy());
      expect(settings.tlsSettings!.sni, isTrue);
      expect(settings.tlsSettings!.verifyCertificates, isTrue);
      expect(settings.tlsSettings!.echConfigList, _ech);
      expect(await (settings.dnsSettings as dynamic).resolver(uri.host), [
        '104.21.91.145',
      ]);
      appdata.settings['enableDnsOverrides'] = true;
      appdata.settings['dnsOverrides'] = {uri.host: '1.2.3.4'};
      final overridden = await adapter.settingsFor(uri);
      expect(await (overridden.dnsSettings as dynamic).resolver(uri.host), [
        '1.2.3.4',
      ]);
      appdata.settings['picacgDirectConnection'] = false;
      final normal = await adapter.settingsFor(uri);
      expect(normal.tlsSettings!.echConfigList, isNull);
      expect(normal.proxySettings, isA<rhttp.StaticProxy>());
    },
  );

  test(
    'routes each image redirect and strips cross-origin credentials',
    () async {
      final requests = <rhttp.HttpRequest>[];
      final adapter = RHttpAdapter(
        picacg: PicacgDirectConnection(query: (_, q) async => _answer(q)),
        send: (req) async {
          requests.add(req);
          final index = requests.length - 1;
          return rhttp.HttpStreamResponse(
            remoteIp: null,
            request: req,
            statusCode: index == 2 ? 200 : 302,
            headers: [
              if (index == 0)
                ('location', 'https://storage-b.picacomic.com/static/a'),
              if (index == 1) ('location', 'https://example.com/a'),
            ],
            version: rhttp.HttpVersion.http1_1,
            body: const Stream.empty(),
          );
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      await dio.get(
        'https://s3.picacomic.com/static/a',
        options: Options(
          headers: {'Authorization': 'test-token', 'Cookie': 'test=value'},
        ),
      );
      expect(requests, hasLength(3));
      expect(requests[0].settings!.tlsSettings!.echConfigList, _ech);
      expect(requests[1].settings!.tlsSettings!.echConfigList, _ech);
      expect(requests[2].settings!.tlsSettings!.echConfigList, isNull);
      expect(requests[2].settings!.proxySettings, isA<rhttp.StaticProxy>());
      final headers = (requests[1].headers as rhttp.HttpHeaderRawMap).map;
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('cookie'), isFalse);
    },
  );

  test('does not replay signed POST after a transport failure', () async {
    var sent = 0;
    final uri = Uri.parse('https://picaapi.picacomic.com/auth/sign-in?x=1');
    final adapter = RHttpAdapter(
      picacg: PicacgDirectConnection(query: (_, q) async => _answer(q)),
      send: (req) async {
        sent++;
        expect(req.url, uri.toString());
        expect(req.method, rhttp.HttpMethod.post);
        expect(
          (req.headers as rhttp.HttpHeaderRawMap).map['signature'],
          'signed-original-path',
        );
        throw StateError('handshake failure');
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    await expectLater(
      dio.post(
        uri.toString(),
        data: {'test': 'fixture'},
        options: Options(headers: {'signature': 'signed-original-path'}),
      ),
      throwsA(isA<DioException>()),
    );
    expect(sent, 1);
  });

  test('never sends a normal TLS request when ECH discovery fails', () async {
    var sent = 0;
    final dio = Dio()
      ..httpClientAdapter = RHttpAdapter(
        picacg: PicacgDirectConnection(
          query: (_, _) async {
            throw StateError('DoH offline');
          },
        ),
        send: (_) async {
          sent++;
          throw StateError('must not send without ECH');
        },
      );
    await expectLater(
      dio.get('https://picaapi.picacomic.com/categories'),
      throwsA(isA<DioException>()),
    );
    expect(sent, 0);
  });
}
