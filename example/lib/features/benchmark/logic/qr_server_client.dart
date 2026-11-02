import 'package:nitro_http/nitro_http.dart';

/// The react-native-nitro-zxing `apps/example/scripts/qr-server.ts` protocol
/// on one keep-alive client: POST /reset → {ok}; GET /status (does not
/// advance); POST /scan {value} → {ok: value == current}, and when accepted
/// the server advances and pushes the next QR to its page.
///
/// Uses nitro_http (libcurl over nitro FFI): the request is sent from
/// libcurl's own thread the moment it is issued, so a report never waits
/// behind a frame decode on the calling worker isolate — only the reply does.
class QrServerClient {
  QrServerClient(Uri base)
    : _http = NitroHttpClient(
        settings: ClientSettings(
          baseUrl: base.toString(),
          connectTimeout: const Duration(seconds: 2),
          timeout: const Duration(seconds: 4),
          enableCompression: false,
        ),
      );

  // No RetryPolicy: a retried POST after a lost reply would corrupt the count.
  final NitroHttpClient _http;

  Future<bool> reset() async =>
      _ok(await _http.post('/reset', body: HttpBody.json({})), '/reset');

  /// Warms the connection without advancing the server.
  Future<void> status() async => _ok(await _http.get('/status'), '/status');

  Future<bool> scan(String value) async => _ok(
    await _http.post('/scan', body: HttpBody.json({'value': value})),
    '/scan',
  );

  void close() => _http.dispose();

  static bool _ok(HttpTextResponse res, String path) {
    if (res.statusCode != 200) {
      throw StateError('HTTP ${res.statusCode} from $path');
    }
    return (res.bodyToJson() as Map)['ok'] == true;
  }
}
