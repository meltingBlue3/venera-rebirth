import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/rhttp_adapter.dart';

// Opt in after building the native rhttp library. Certificates and private keys
// are generated only in a temporary directory and removed after the tests.
void main() {
  group('native EH TLS', () {
    late Directory fixtures;
    late Process server;
    late List<int> ports;
    final saved = <String, dynamic>{};

    setUpAll(() async {
      await rhttp.Rhttp.init();
      fixtures = await Directory.systemTemp.createTemp('venera-eh-tls-');
      for (final name in ['exhentai.org', 'wrong.invalid']) {
        final result = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-days',
          '1',
          '-subj',
          '/CN=$name',
          '-addext',
          'subjectAltName=DNS:$name',
          '-addext',
          'basicConstraints=critical,CA:FALSE',
          '-keyout',
          '${fixtures.path}/$name.key',
          '-out',
          '${fixtures.path}/$name.pem',
        ]);
        if (result.exitCode != 0) throw StateError(result.stderr.toString());
      }
      server = await Process.start('python3', [
        '-u',
        '-c',
        _server,
        fixtures.path,
      ]);
      ports =
          (jsonDecode(
                    await server.stdout
                        .transform(utf8.decoder)
                        .transform(const LineSplitter())
                        .first,
                  )
                  as List)
              .cast<int>();
      for (final key in [
        'ehDirectConnection',
        'proxy',
        'enableDnsOverrides',
        'dnsOverrides',
        'sni',
        'ignoreBadCertificate',
      ]) {
        saved[key] = appdata.settings[key];
      }
      appdata.settings['ehDirectConnection'] = true;
      appdata.settings['proxy'] = 'direct';
      appdata.settings['enableDnsOverrides'] = true;
      appdata.settings['dnsOverrides'] = {
        'exhentai.org': '127.0.0.1',
        'wrong.invalid': '127.0.0.1',
      };
      appdata.settings['sni'] = true;
      appdata.settings['ignoreBadCertificate'] = false;
    });

    tearDownAll(() async {
      for (final entry in saved.entries) {
        appdata.settings[entry.key] = entry.value;
      }
      server.kill();
      await server.exitCode;
      await fixtures.delete(recursive: true);
    });

    Future<ResponseBody> request(String host, int port, String? trusted) async {
      final certificate = trusted == null
          ? null
          : await File('${fixtures.path}/$trusted.pem').readAsString();
      final adapter = RHttpAdapter(
        send: (request) {
          final tls = request.settings!.tlsSettings!;
          return rhttp.Rhttp.send(
            request,
            settings: request.settings!.copyWith(
              tlsSettings: rhttp.TlsSettings(
                sni: tls.sni,
                verifyCertificates: tls.verifyCertificates,
                trustedRootCertificates: certificate == null
                    ? []
                    : [certificate],
              ),
            ),
          );
        },
      );
      return adapter.fetch(
        RequestOptions(path: 'https://$host:$port/probe'),
        null,
        null,
      );
    }

    test(
      'SNI is absent while HTTP Host and valid certificate name stay EH',
      () async {
        final result = await request('exhentai.org', ports[0], 'exhentai.org');
        final data = jsonDecode(await utf8.decodeStream(result.stream));
        expect(result.statusCode, 200);
        expect(data['sni'], isNull);
        expect(data['host'], 'exhentai.org:${ports[0]}');
      },
    );

    test(
      'trusted certificate for a different hostname is rejected without SNI',
      () async {
        await expectLater(
          request('exhentai.org', ports[1], 'wrong.invalid'),
          throwsA(isA<rhttp.RhttpInvalidCertificateException>()),
        );
      },
    );

    test('untrusted certificate is rejected without SNI', () async {
      await expectLater(
        request('exhentai.org', ports[0], null),
        throwsA(isA<rhttp.RhttpInvalidCertificateException>()),
      );
    });

    test('unrelated HTTPS request still sends SNI', () async {
      final result = await request('wrong.invalid', ports[1], 'wrong.invalid');
      final data = jsonDecode(await utf8.decodeStream(result.stream));
      expect(data['sni'], 'wrong.invalid');
    });

    test(
      'default transport retains DNS, proxy and redirect settings',
      () async {
        appdata.settings['proxy'] = 'http://127.0.0.1:1';
        final response = await RHttpAdapter().fetch(
          RequestOptions(path: 'http://exhentai.org:${ports[2]}/redirect'),
          null,
          null,
        );
        final data = jsonDecode(await utf8.decodeStream(response.stream));
        expect(data['host'], 'exhentai.org:${ports[2]}');
        expect(response.statusCode, 200);
        expect(response.redirects, hasLength(1));
        appdata.settings['proxy'] = 'direct';
      },
    );
  }, skip: Platform.environment['RHTTP_NATIVE_TESTS'] != '1');
}

const _server = r'''
import json, socket, ssl, sys, threading

def serve(name=None):
    context = None
    if name is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1] + '/' + name + '.pem', sys.argv[1] + '/' + name + '.key')
        context.set_servername_callback(lambda sock, name, ctx: setattr(sock, 'sni', name))
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    def run():
        while True:
            raw, _ = listener.accept()
            try:
                with (context.wrap_socket(raw, server_side=True) if context else raw) as conn:
                    data = b''
                    while b'\r\n\r\n' not in data:
                        block = conn.recv(4096)
                        if not block: break
                        data += block
                    if data.startswith(b'GET /redirect '):
                        conn.sendall(b'HTTP/1.1 302 Found\r\nLocation: /probe\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                        continue
                    host = next((line.split(':', 1)[1].strip() for line in data.decode().splitlines() if line.lower().startswith('host:')), None)
                    body = json.dumps({'sni': getattr(conn, 'sni', None), 'host': host}).encode()
                    conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
            except (ssl.SSLError, OSError):
                raw.close()
    threading.Thread(target=run, daemon=True).start()
    return listener.getsockname()[1]

print(json.dumps([serve('exhentai.org'), serve('wrong.invalid'), serve()]), flush=True)
threading.Event().wait()
''';
