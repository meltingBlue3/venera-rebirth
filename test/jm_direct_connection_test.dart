import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/images.dart';
import 'package:venera/network/jm_direct_connection.dart';

void main() {
  final saved = <String, dynamic>{};
  setUp(() {
    for (final key in [
      'jmDirectConnection',
      'ehDirectConnection',
      'proxy',
      'sni',
      'ignoreBadCertificate',
      'enableDnsOverrides',
      'dnsOverrides',
    ]) {
      saved[key] = appdata.settings[key];
    }
    appdata.settings['jmDirectConnection'] = true;
    appdata.settings['ehDirectConnection'] = false;
    appdata.settings['proxy'] = 'http://127.0.0.1:1080';
    appdata.settings['sni'] = false;
    appdata.settings['ignoreBadCertificate'] = true;
    appdata.settings['enableDnsOverrides'] = false;
  });
  tearDown(() {
    for (final entry in saved.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });

  test(
    'JM routing keeps SNI and certificate verification while bypassing proxy',
    () async {
      final adapter = RHttpAdapter();
      final settings = await adapter.settingsFor(
        Uri.https(JmDirectConnection.apiHosts.first),
      );
      expect(settings.tlsSettings!.sni, isTrue);
      expect(settings.tlsSettings!.verifyCertificates, isTrue);
      expect(settings.proxySettings, const rhttp.ProxySettings.noProxy());
      expect(settings.timeoutSettings!.timeout, const Duration(seconds: 12));
      final normal = await adapter.settingsFor(Uri.https('example.com'));
      expect(normal.proxySettings, isA<rhttp.StaticProxy>());
      expect(normal.tlsSettings!.sni, isFalse);
      expect(normal.tlsSettings!.verifyCertificates, isFalse);
      appdata.settings['jmDirectConnection'] = false;
      expect(
        (await adapter.settingsFor(
          Uri.https(JmDirectConnection.apiHosts.first),
        )).proxySettings,
        isA<rhttp.StaticProxy>(),
      );
    },
  );

  test(
    'only exact HTTPS hosts are registered; images preserve path and query',
    () {
      final policy = JmDirectConnection();
      policy.register(
        api: ['api.example.org', 'localhost', '127.0.0.1', 'user@evil.org'],
        images: ['img.example.org'],
      );
      expect(policy.appliesTo(Uri.https('api.example.org')), isTrue);
      for (final url in [
        'http://api.example.org',
        'https://api.example.org.evil.org',
        'https://foo.cdngwc.cc',
        'https://127.0.0.1',
        'https://localhost',
      ]) {
        expect(policy.appliesTo(Uri.parse(url)), isFalse);
      }
      final uri = Uri.parse(
        'https://img.example.org/media/photos/123/01.webp?t=abc',
      );
      final candidates = policy.imageCandidates(uri);
      expect(candidates.length, 3);
      expect(candidates.first, uri);
      expect(
        candidates.every((v) => v.path == uri.path && v.query == uri.query),
        isTrue,
      );
      expect(
        policy.imageCandidates(Uri.https('img.example.org', '/other')),
        hasLength(1),
      );
      expect(
        policy.imageCandidates(Uri.https('unrelated.org', uri.path)),
        hasLength(1),
      );
    },
  );

  test(
    'DoH retains A/AAAA, coalesces concurrent queries and honors TTL',
    () async {
      var now = DateTime.utc(2026);
      final queries = <int>[];
      final gate = Completer<void>();
      final policy = JmDirectConnection(
        now: () => now,
        query: (provider, host, type) async {
          queries.add(type);
          await gate.future;
          return {
            'Status': 0,
            'Answer': [
              {
                'type': type,
                'TTL': 20,
                'data': type == 1 ? '192.0.2.1' : '2001:db8::1',
              },
              {'type': 5, 'TTL': 10, 'data': 'alias.example.org'},
              {'type': type, 'TTL': 10, 'data': 'not an IP'},
            ],
          };
        },
        lookup: (_) => throw StateError('Unexpected system DNS'),
      );
      final first = policy.resolve('api.example.org');
      final second = policy.resolve('api.example.org');
      gate.complete();
      expect(await first, ['192.0.2.1', '2001:db8::1']);
      expect(await second, ['192.0.2.1', '2001:db8::1']);
      await policy.resolve('api.example.org');
      expect(queries, [1, 28]);
      now = now.add(const Duration(seconds: 11));
      await policy.resolve('api.example.org');
      expect(queries, [1, 28, 1, 28]);
    },
  );

  test(
    'DoH providers fail over, reject invalid responses, then use system DNS',
    () async {
      final providers = <String>[];
      var systemQueries = 0;
      final policy = JmDirectConnection(
        query: (provider, host, type) async {
          providers.add(provider);
          if (provider == 'dns.alidns.com') {
            throw const FormatException('Bad JSON');
          }
          return {
            'Status': 3,
            'Answer': [
              {'type': 1, 'data': '192.0.2.1'},
            ],
          };
        },
        lookup: (_) async {
          systemQueries++;
          return [InternetAddress('192.0.2.2')];
        },
      );
      expect(await policy.resolve('api.example.org'), ['192.0.2.2']);
      expect(providers, [
        'dns.alidns.com',
        'dns.alidns.com',
        'doh.pub',
        'doh.pub',
      ]);
      expect(systemQueries, 1);
    },
  );

  test('explicit DNS overrides take precedence over DoH', () async {
    appdata.settings['enableDnsOverrides'] = true;
    appdata.settings['dnsOverrides'] = {
      JmDirectConnection.apiHosts.first: '192.0.2.9',
    };
    final settings = await RHttpAdapter().settingsFor(
      Uri.https(JmDirectConnection.apiHosts.first),
    );
    final dynamic dns = settings.dnsSettings;
    expect(await dns.resolver(JmDirectConnection.apiHosts.first), [
      '192.0.2.9',
    ]);
  });

  test(
    'redirects recompute JM routing and strip cross-origin credentials',
    () async {
      final requests = <rhttp.HttpRequest>[];
      final adapter = RHttpAdapter(
        send: (request) async {
          requests.add(request);
          return _response(
            request,
            requests.length == 1 ? 302 : 200,
            headers: requests.length == 1
                ? [('location', 'https://example.com/image')]
                : [],
          );
        },
      );
      final result = await adapter.fetch(
        RequestOptions(
          path: 'https://${JmDirectConnection.apiHosts.first}/setting',
          headers: {'Authorization': 'test', 'Cookie': 'session=test'},
        ),
        null,
        null,
      );
      await result.stream.drain<void>();
      expect(requests.first.settings!.tlsSettings!.sni, isTrue);
      expect(requests.last.settings!.proxySettings, isA<rhttp.StaticProxy>());
      final headers = (requests.last.headers as rhttp.HttpHeaderRawMap).map;
      expect(headers, isNot(contains('authorization')));
      expect(headers, isNot(contains('cookie')));
    },
  );

  test(
    'image failover discards a partial stream before trying another CDN',
    () async {
      final requests = <rhttp.HttpRequest>[];
      final dio = AppDio(BaseOptions(responseType: ResponseType.stream));
      dio.httpClientAdapter = RHttpAdapter(
        send: (request) async {
          requests.add(request);
          if (requests.length == 1) {
            return _response(
              request,
              200,
              body: (() async* {
                yield Uint8List.fromList([9, 9]);
                throw StateError('Connection closed mid-image');
              })(),
            );
          }
          return _response(
            request,
            200,
            body: Stream.value(Uint8List.fromList([1, 2, 3])),
          );
        },
      );
      final progress = await ImageDownloader.downloadImageBytes(
        dio,
        'https://${JmDirectConnection.imageHosts.first}/media/photos/123/01.webp?q=1',
        null,
        'jm',
      ).toList();
      expect(progress.last.imageBytes, [1, 2, 3]);
      expect(requests, hasLength(2));
      expect(Uri.parse(requests.last.url).path, '/media/photos/123/01.webp');
      expect(Uri.parse(requests.last.url).query, 'q=1');
    },
  );

  test(
    'image failures have at most three attempts and do not retry rate limiting',
    () async {
      var count = 0;
      var status = 503;
      final dio = AppDio(BaseOptions(responseType: ResponseType.stream));
      dio.httpClientAdapter = RHttpAdapter(
        send: (request) async {
          count++;
          return _response(request, status);
        },
      );
      Future<void> download() async {
        await ImageDownloader.downloadImageBytes(
          dio,
          'https://${JmDirectConnection.imageHosts.first}/media/albums/123.jpg',
          null,
          'jm',
        ).drain<void>();
      }

      await expectLater(download(), throwsA(isA<DioException>()));
      expect(count, 3);
      status = 429;
      count = 0;
      await expectLater(download(), throwsA(isA<DioException>()));
      expect(count, 1);
    },
  );

  test('other sources and image uploads never fail over', () async {
    for (final source in ['jm', 'other']) {
      var count = 0;
      final dio = AppDio(
        BaseOptions(
          responseType: ResponseType.stream,
          method: source == 'jm' ? 'POST' : 'GET',
        ),
      );
      dio.httpClientAdapter = RHttpAdapter(
        send: (request) async {
          count++;
          return _response(request, 503);
        },
      );
      await expectLater(
        ImageDownloader.downloadImageBytes(
          dio,
          'https://${JmDirectConnection.imageHosts.first}/media/albums/123.jpg',
          null,
          source,
        ).drain<void>(),
        throwsA(isA<DioException>()),
      );
      expect(count, 1);
    }
  });
}

rhttp.HttpStreamResponse _response(
  rhttp.HttpRequest request,
  int status, {
  Stream<Uint8List> body = const Stream.empty(),
  List<(String, String)> headers = const [],
}) => rhttp.HttpStreamResponse(
  remoteIp: '192.0.2.1',
  request: request,
  version: rhttp.HttpVersion.http1_1,
  statusCode: status,
  headers: headers,
  body: body,
);
