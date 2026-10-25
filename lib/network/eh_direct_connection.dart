import 'dart:io';

/// EH's application-local routing policy. URLs, cookies and certificate names
/// stay unchanged; only address resolution and TLS SNI are adjusted.
class EhDirectConnection {
  EhDirectConnection({
    this.overrides = const {},
    Future<List<InternetAddress>> Function(String)? lookup,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final Map<String, List<String>> overrides;
  final Future<List<InternetAddress>> Function(String) _lookup;

  static const _domains = {
    'e-hentai.org',
    'api.e-hentai.org',
    'forums.e-hentai.org',
    'repo.e-hentai.org',
    'upload.e-hentai.org',
    'exhentai.org',
    's.exhentai.org',
    'ehgt.org',
    'gt0.ehgt.org',
    'gt1.ehgt.org',
    'gt2.ehgt.org',
    'gt3.ehgt.org',
    'ul.ehgt.org',
  };

  static const _cloudflareDomains = {
    'e-hentai.org',
    'api.e-hentai.org',
    'forums.e-hentai.org',
    'upload.e-hentai.org',
    's.exhentai.org',
  };

  // Address pool from UjuiUjuMandan/EhViewer, commit e138138 (GPL-3.0).
  // See doc/ehviewer_direct_connection_research.md for the source and limits.
  static const _exhentaiAddresses = [
    '178.175.128.251',
    '178.175.128.252',
    '178.175.128.253',
    '178.175.128.254',
    '178.175.129.251',
    '178.175.129.252',
    '178.175.129.253',
    '178.175.129.254',
    '178.175.132.19',
    '178.175.132.20',
    '178.175.132.21',
    '178.175.132.22',
  ];

  static bool appliesTo(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return _domains.contains(host) || isHathHost(host);
  }

  static bool isHathHost(String host) {
    host = host.toLowerCase();
    return host == 'hath.network' || host.endsWith('.hath.network');
  }

  Future<List<String>> resolve(String host) async {
    host = host.toLowerCase();
    // Explicit user overrides take priority over the built-in policy.
    if (overrides.containsKey(host)) return List.of(overrides[host]!);
    if (host == 'exhentai.org') {
      return List.of(_exhentaiAddresses)..shuffle();
    }
    final query = _cloudflareDomains.contains(host)
        ? '$host.cdn.cloudflare.net'
        : host;
    final addresses = await _lookup(query).timeout(const Duration(seconds: 15));
    return addresses.map((address) => address.address).toSet().toList()
      ..shuffle();
  }
}
