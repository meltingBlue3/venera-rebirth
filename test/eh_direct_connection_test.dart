import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/eh_direct_connection.dart';
import 'package:venera/network/rhttp_adapter.dart';

void main() {
  test(
    'H@H direct downloads use HTTP/1.1 without changing other hosts',
    () async {
      appdata.settings['ehDirectConnection'] = true;
      final adapter = RHttpAdapter();
      final image = await adapter.settingsFor(Uri.https('node.hath.network'));
      expect(image.httpVersionPref, rhttp.HttpVersionPref.http1_1);
      final gallery = await adapter.settingsFor(Uri.https('e-hentai.org'));
      expect(gallery.httpVersionPref, rhttp.HttpVersionPref.all);
    },
  );
  final originalSettings = <String, dynamic>{};
  setUp(() {
    for (final key in [
      'ehDirectConnection',
      'proxy',
      'sni',
      'ignoreBadCertificate',
      'enableDnsOverrides',
      'dnsOverrides',
    ]) {
      originalSettings[key] = appdata.settings[key];
    }
    appdata.settings['ehDirectConnection'] = true;
    appdata.settings['proxy'] = 'http://127.0.0.1:1080';
    appdata.settings['sni'] = true;
    appdata.settings['ignoreBadCertificate'] = false;
    appdata.settings['enableDnsOverrides'] = false;
  });
  tearDown(() {
    for (final entry in originalSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });

  test('only EH hosts and actual H@H subdomains use direct routing', () {
    for (final host in [
      'e-hentai.org',
      'exhentai.org',
      'api.e-hentai.org',
      'gt3.ehgt.org',
      'a.b.hath.network',
      'hath.network',
    ]) {
      expect(EhDirectConnection.appliesTo(Uri.https(host)), isTrue);
    }
    for (final host in [
      'example.com',
      'github.com',
      'e-hentai.org.example.com',
      'fakehath.network',
      'hath.network.example.com',
      'evil-exhentai.org',
    ]) {
      expect(EhDirectConnection.appliesTo(Uri.https(host)), isFalse);
    }
    expect(
      EhDirectConnection.appliesTo(Uri.parse('file:///exhentai.org')),
      isFalse,
    );
    expect(
      EhDirectConnection.appliesTo(Uri.parse('http://a.hath.network:123/a')),
      isTrue,
    );
  });

  test('ExHentai uses the built-in pool without querying DNS', () async {
    final policy = EhDirectConnection(
      lookup: (_) => throw StateError('DNS called'),
    );
    final addresses = await policy.resolve('exhentai.org');
    expect(addresses, hasLength(12));
    expect(addresses.toSet(), hasLength(12));
    expect(addresses, containsAll(['178.175.128.251', '178.175.132.22']));
  });

  test('user DNS overrides win over both the pool and aliases', () async {
    final policy = EhDirectConnection(
      overrides: {
        'exhentai.org': ['192.0.2.1'],
        'e-hentai.org': ['2001:db8::1'],
      },
      lookup: (_) => throw StateError('DNS called'),
    );
    expect(await policy.resolve('exhentai.org'), ['192.0.2.1']);
    expect(await policy.resolve('E-HENTAI.ORG'), ['2001:db8::1']);
  });

  test(
    'only Cloudflare hosts get a DNS alias; IPv4 and IPv6 are retained',
    () async {
      final queries = <String>[];
      final policy = EhDirectConnection(
        lookup: (host) async {
          queries.add(host);
          return [InternetAddress('192.0.2.2'), InternetAddress('2001:db8::2')];
        },
      );
      expect(
        await policy.resolve('e-hentai.org'),
        unorderedEquals(['192.0.2.2', '2001:db8::2']),
      );
      await policy.resolve('s.exhentai.org');
      await policy.resolve('gt1.ehgt.org');
      await policy.resolve('a.hath.network');
      expect(queries, [
        'e-hentai.org.cdn.cloudflare.net',
        's.exhentai.org.cdn.cloudflare.net',
        'gt1.ehgt.org',
        'a.hath.network',
      ]);
    },
  );

  test(
    'direct mode disables SNI and proxy but keeps certificate verification',
    () async {
      appdata.settings['ignoreBadCertificate'] = true;
      final settings = await RHttpAdapter().settingsFor(
        Uri.https('exhentai.org'),
      );
      expect(settings.tlsSettings!.sni, isFalse);
      expect(settings.tlsSettings!.verifyCertificates, isTrue);
      expect(settings.proxySettings, const rhttp.ProxySettings.noProxy());
      final normal = await RHttpAdapter().settingsFor(Uri.https('example.com'));
      expect(normal.tlsSettings!.sni, isTrue);
      expect(normal.tlsSettings!.verifyCertificates, isFalse);
      expect(
        (normal.proxySettings as rhttp.StaticProxy).url,
        'http://127.0.0.1:1080',
      );
    },
  );

  test(
    'disabled mode preserves the original proxy and TLS options for EH',
    () async {
      appdata.settings['ehDirectConnection'] = false;
      final settings = await RHttpAdapter().settingsFor(
        Uri.https('exhentai.org'),
      );
      expect(settings.tlsSettings!.sni, isTrue);
      expect(
        (settings.proxySettings as rhttp.StaticProxy).url,
        'http://127.0.0.1:1080',
      );
    },
  );

  test(
    'each redirect recomputes routing and strips cross-origin credentials',
    () async {
      final requests = <rhttp.HttpRequest>[];
      final headerSnapshots = <Map<String, String>>[];
      final adapter = RHttpAdapter(
        send: (request) async {
          requests.add(request);
          headerSnapshots.add(
            Map.of((request.headers as rhttp.HttpHeaderRawMap).map),
          );
          return response(
            request,
            requests.length == 1 ? 302 : 200,
            requests.length == 1
                ? [('Location', 'https://example.com/image')]
                : [],
          );
        },
      );
      final result = await adapter.fetch(
        RequestOptions(
          path: 'https://exhentai.org/gallery',
          headers: {
            'Cookie': 'igneous=secret',
            'Authorization': 'secret',
            'Host': 'exhentai.org',
          },
        ),
        null,
        null,
      );
      await result.stream.drain<void>();
      expect(requests.map((r) => r.url), [
        'https://exhentai.org/gallery',
        'https://example.com/image',
      ]);
      expect(requests[0].settings!.tlsSettings!.sni, isFalse);
      expect(requests[1].settings!.tlsSettings!.sni, isTrue);
      expect(
        requests[0].settings!.proxySettings,
        const rhttp.ProxySettings.noProxy(),
      );
      expect(requests[1].settings!.proxySettings, isA<rhttp.StaticProxy>());
      expect(headerSnapshots[0]['cookie'], 'igneous=secret');
      for (final name in ['cookie', 'authorization', 'host']) {
        expect(headerSnapshots[1], isNot(contains(name)));
      }
      expect(
        result.redirects!.single.location,
        Uri.https('example.com', '/image'),
      );
    },
  );

  test('redirect into EH enables direct routing', () async {
    final requests = <rhttp.HttpRequest>[];
    final adapter = RHttpAdapter(
      send: (request) async {
        requests.add(request);
        return response(
          request,
          requests.length == 1 ? 301 : 200,
          requests.length == 1 ? [('location', 'https://exhentai.org/a')] : [],
        );
      },
    );
    final result = await adapter.fetch(
      RequestOptions(path: 'https://example.com/a'),
      null,
      null,
    );
    await result.stream.drain<void>();
    expect(requests[0].settings!.tlsSettings!.sni, isTrue);
    expect(requests[1].settings!.tlsSettings!.sni, isFalse);
  });

  test(
    'redirect cookies update before the next request using a test database',
    () async {
      final jar = CookieJarSql(':memory:');
      jar.saveFromResponse(Uri.https('exhentai.org'), [
        Cookie('session', 'old'),
      ]);
      final requests = <rhttp.HttpRequest>[];
      final adapter = RHttpAdapter(
        cookieJar: jar,
        send: (request) async {
          requests.add(request);
          if (requests.length == 1) {
            return response(request, 302, [
              ('location', '/next'),
              ('set-cookie', 'session=new; Path=/'),
            ]);
          }
          expect(
            (request.headers as rhttp.HttpHeaderRawMap).map['cookie'],
            'session=new',
          );
          return response(request, 200, []);
        },
      );
      final result = await adapter.fetch(
        RequestOptions(path: 'https://exhentai.org/start'),
        null,
        null,
      );
      await result.stream.drain<void>();
      expect(requests.last.url, 'https://exhentai.org/next');
    },
  );

  test('POST 302 becomes GET without body or content headers', () async {
    var count = 0;
    final adapter = RHttpAdapter(
      send: (request) async {
        if (++count == 1) {
          expect(request.method.value, 'POST');
          return response(request, 302, [('location', '/next')]);
        }
        expect(request.method.value, 'GET');
        expect(request.body, isNull);
        expect(
          (request.headers as rhttp.HttpHeaderRawMap).map,
          isNot(contains('content-type')),
        );
        return response(request, 200, []);
      },
    );
    final result = await adapter.fetch(
      RequestOptions(
        path: 'https://exhentai.org/start',
        method: 'POST',
        headers: {'content-type': 'application/json'},
      ),
      Stream.value(Uint8List.fromList([1])),
      null,
    );
    await result.stream.drain<void>();
    expect(count, 2);
  });

  test('307 does not replay a single-use upload stream', () async {
    var count = 0;
    final adapter = RHttpAdapter(
      send: (request) async {
        count++;
        return response(request, 307, [('location', '/next')]);
      },
    );
    final result = await adapter.fetch(
      RequestOptions(path: 'https://exhentai.org/upload', method: 'POST'),
      Stream.value(Uint8List.fromList([1])),
      null,
    );
    await result.stream.drain<void>();
    expect(result.statusCode, 307);
    expect(count, 1);
  });

  test(
    'followRedirects=false returns the redirect without following it',
    () async {
      var count = 0;
      final adapter = RHttpAdapter(
        send: (request) async {
          count++;
          return response(request, 302, [('location', '/next')]);
        },
      );
      final result = await adapter.fetch(
        RequestOptions(
          path: 'https://exhentai.org/start',
          followRedirects: false,
        ),
        null,
        null,
      );
      await result.stream.drain<void>();
      expect(result.statusCode, 302);
      expect(count, 1);
    },
  );

  test('redirect loops are bounded', () async {
    var count = 0;
    final adapter = RHttpAdapter(
      send: (request) async {
        count++;
        return response(request, 302, [('location', '/loop')]);
      },
    );
    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://exhentai.org/loop', maxRedirects: 2),
        null,
        null,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.message,
          'message',
          'Too many redirects',
        ),
      ),
    );
    expect(count, 3);
  });
}

rhttp.HttpStreamResponse response(
  rhttp.HttpRequest request,
  int status,
  List<(String, String)> headers,
) => rhttp.HttpStreamResponse(
  remoteIp: '127.0.0.1',
  request: request,
  version: rhttp.HttpVersion.http1_1,
  statusCode: status,
  headers: headers,
  body: const Stream.empty(),
);
