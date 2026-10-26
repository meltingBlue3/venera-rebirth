import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/js_engine.dart';

// Opt in with JM_DIRECT_LIVE_TESTS=1 and JM_SOURCE_PATH pointing to the
// upstream jm.js (see doc/jm_direct_connection.md). Only configuration and
// /setting are requested. No account, comic metadata or images are accessed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native JM source discovers domains and decrypts settings without proxy',
    () async {
      final sourcePath = Platform.environment['JM_SOURCE_PATH'];
      expect(
        sourcePath,
        isNotNull,
        reason: 'Set JM_SOURCE_PATH to upstream jm.js',
      );
      final saved = <String, dynamic>{};
      for (final key in [
        'jmDirectConnection',
        'ehDirectConnection',
        'proxy',
        'language',
      ]) {
        saved[key] = appdata.settings[key];
      }
      // A live successful request proves that the app proxy was bypassed.
      appdata.settings['proxy'] = 'http://127.0.0.1:9';
      appdata.settings['jmDirectConnection'] = true;
      appdata.settings['ehDirectConnection'] = false;
      appdata.settings['language'] = 'en-US';
      try {
        await rhttp.Rhttp.init();
        await JsEngine().init();
        final script = await File(sourcePath!).readAsString();
        final dynamic result = await JsEngine().runCode('''(async () => {
        $script
        const source = new JM();
        // Keep cache writes isolated from real user data and the UI lifecycle.
        // Crypto, HTTP, DNS and the compatibility layer use the real host APIs.
        const data = {};
        source.loadData = key => data[key];
        source.saveData = (key, value) => { data[key] = value; };
        source.loadSetting = key => ({apiDomain: '1', imageStream: '1',
            refreshDomainsOnStart: false, dailyCheckInTask: false})[key];
        JmNetwork.install(source);
        if (!source._jmNetworkInstalled) throw new Error('JM compatibility layer not installed');
        await source.refreshApiDomains(false);
        await source.refreshImgUrl(false);
        return {api: source.baseUrl, image: source.imageUrl};
      })()''');
        expect(result['api'], startsWith('https://'));
        expect(result['image'], startsWith('https://'));
        // Report hosts only; never print complete settings or response bodies.
        // ignore: avoid_print
        print(
          'JM native configuration OK: API=${Uri.parse(result['api']).host}, '
          'image=${Uri.parse(result['image']).host}',
        );
      } finally {
        JsEngine().dispose();
        for (final entry in saved.entries) {
          appdata.settings[entry.key] = entry.value;
        }
      }
    },
    skip: Platform.environment['JM_DIRECT_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
