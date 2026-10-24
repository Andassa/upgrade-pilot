import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:upgrade_pilot/src/ports/ports.dart';

/// HTTPS client restricted to an allow-list of hosts and path prefixes.
/// TLS certificates are verified by the platform; there is no telemetry.
final class AllowlistedHttp implements HttpPort {
  AllowlistedHttp({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.userAgent = 'upgrade-pilot',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final String userAgent;

  /// Host → allowed path prefixes.
  static const allowList = <String, List<String>>{
    'pub.dev': ['/api/packages/'],
    'storage.googleapis.com': ['/flutter_infra_release/'],
    'raw.githubusercontent.com': ['/Andassa/upgrade-pilot/'],
  };

  static bool isAllowed(Uri uri) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return false;
    if (uri.hasPort && uri.port != 443) return false;
    final prefixes = allowList[uri.host];
    if (prefixes == null) return false;
    final path = uri.path;
    if (path.contains('/../') || path.endsWith('/..')) return false;
    return prefixes.any(path.startsWith);
  }

  void _check(Uri uri) {
    if (!isAllowed(uri)) {
      throw NetworkException('URL not in the allow-list', uri: uri);
    }
  }

  @override
  Future<HttpReply> get(Uri uri) async {
    _check(uri);
    try {
      final response = await _client
          .get(uri, headers: {'user-agent': userAgent}).timeout(timeout);
      return HttpReply(response.statusCode, response.bodyBytes);
    } on TimeoutException {
      throw NetworkException('Request timed out', uri: uri);
    } on SocketException catch (e) {
      throw NetworkException(e.message, uri: uri);
    } on HandshakeException catch (e) {
      throw NetworkException('TLS error: ${e.message}', uri: uri);
    } on http.ClientException catch (e) {
      throw NetworkException(e.message, uri: uri);
    }
  }

  @override
  Future<int> download(
    Uri uri,
    String destination, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancellation,
  }) async {
    _check(uri);
    final request = http.Request('GET', uri)..headers['user-agent'] = userAgent;
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw NetworkException('Request timed out', uri: uri);
    } on SocketException catch (e) {
      throw NetworkException(e.message, uri: uri);
    } on http.ClientException catch (e) {
      throw NetworkException(e.message, uri: uri);
    }
    if (response.statusCode != 200) {
      throw NetworkException('HTTP ${response.statusCode}', uri: uri);
    }
    final file = File(destination);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        if (cancellation?.isCancelled ?? false) {
          throw const CancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, response.contentLength);
      }
    } on TimeoutException {
      throw NetworkException('Download stalled', uri: uri);
    } on FileSystemException catch (e) {
      throw FsException(
        e.osError?.errorCode == 28 ? 'No space left on device' : e.message,
        path: destination,
        noSpace: e.osError?.errorCode == 28,
      );
    } finally {
      await sink.close();
    }
    return received;
  }
}
