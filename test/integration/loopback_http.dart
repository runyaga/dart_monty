import 'dart:async';
import 'dart:io';

/// A local HTTP endpoint for integration tests that exercise real I/O.
class LoopbackHttpServer {
  const LoopbackHttpServer._(this._server);

  static const _json =
      '{"ok":true,"message":"loopback HTTP test response body"}';
  static final _largeJson = '{"data":"${'x' * 65536}"}';

  final HttpServer _server;

  /// Starts a server on an ephemeral IPv4 loopback port.
  static Future<LoopbackHttpServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_respond(request)));

    return LoopbackHttpServer._(server);
  }

  /// The root URL for the server, without a trailing slash.
  String get baseUrl => 'http://${_server.address.address}:${_server.port}';

  /// Returns an absolute URL for [path] on this server.
  String url(String path) => '$baseUrl$path';

  /// Stops accepting requests and closes active connections.
  Future<void> close() => _server.close(force: true);

  static Future<void> _respond(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();

      return;
    }

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(request.uri.path == '/large' ? _largeJson : _json);
    await request.response.close();
  }
}
