import 'dart:convert';
import 'dart:io';

/// The react-native-nitro-zxing `apps/example/scripts/qr-server.ts` protocol
/// on one keep-alive client: POST /reset → {ok}; GET /status (does not
/// advance); POST /scan {value} → {ok: value == current}, and when accepted
/// the server advances and pushes the next QR to its page.
class QrServerClient {
  QrServerClient(this.base)
    : _http = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  final Uri base;
  final HttpClient _http;

  Future<bool> reset() async =>
      (await _request('POST', '/reset', '{}'))['ok'] == true;

  /// Warms the connection without advancing the server.
  Future<void> status() => _request('GET', '/status');

  Future<bool> scan(String value) async =>
      (await _request('POST', '/scan', jsonEncode({'value': value})))['ok'] ==
      true;

  void close() => _http.close(force: true);

  /// The body is fully read so the connection is reused. No retry: a lost
  /// reply to an accepted POST would corrupt the count.
  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    String? body,
  ]) async {
    final uri = base.resolve(path);
    final req = await _http.openUrl(method, uri);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(body);
    }
    final res = await req.close().timeout(const Duration(seconds: 4));
    final text = await utf8.decoder.bind(res).join();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} from $path');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }
}
