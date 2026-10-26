import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/rhttp_adapter.dart';

// Opt in after building the patched native library. No credentials, persisted
// source data or comic contents are used. See doc/picacg_direct_connection.md.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native PicACG ECH API bridge and image hosts without app proxy',
    () async {
      final settings = {
        'picacgDirectConnection': true,
        'ehDirectConnection': false,
        'jmDirectConnection': false,
        'proxy': 'http://127.0.0.1:9',
        'sni': false,
        'ignoreBadCertificate': true,
        'enableDnsOverrides': false,
      };
      final saved = <String, dynamic>{};
      for (final entry in settings.entries) {
        saved[entry.key] = appdata.settings[entry.key];
        appdata.settings[entry.key] = entry.value;
      }
      try {
        await rhttp.Rhttp.init();
        await JsEngine().init();
        // The upstream source's dart:io hint must select the ECH adapter here.
        final dynamic response = await JsEngine().runCode('''
        Network.sendRequest('HEAD', 'https://picaapi.picacomic.com/',
          {'http_client': 'dart:io'}, null, {}).then(r => r.status)
      ''');
        expect(response, inInclusiveRange(200, 499));
        print('PicACG native JS API HEAD: $response');
        final sourcePath = Platform.environment['PICACG_SOURCE_PATH'];
        if (sourcePath != null) {
          final script = await File(sourcePath).readAsString();
          final dynamic status = await JsEngine().runCode('''(async () => {
          $script
          const source = new Picacg();
          source.loadSetting = key => source.settings[key]?.default;
          const result = await Network.get(
            'https://picaapi.picacomic.com/categories',
            source.buildHeaders('GET', 'categories'));
          return result.status;
        })()''');
          // 401 is expected when authentication is required. Neither 400 (bad
          // request/signature) nor a transport error demonstrates this contract.
          expect(status, anyOf(200, 401));
          print('PicACG upstream signed categories GET: $status');
        }
        final dio = Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = RHttpAdapter();
        for (final host in ['s3.picacomic.com', 'storage-b.picacomic.com']) {
          final result = await dio.head('https://$host/');
          expect(result.statusCode, inInclusiveRange(200, 499));
          print('PicACG native image host $host HEAD: ${result.statusCode}');
        }
        dio.close(force: true);
      } finally {
        JsEngine().dispose();
        for (final entry in saved.entries) {
          appdata.settings[entry.key] = entry.value;
        }
      }
    },
    skip: Platform.environment['PICACG_DIRECT_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
