// Serves the browser build over the LAN so it can be opened on a real phone.
//
//   dart run tool/serve_web.dart [port]
//
// Nothing to do with the app and nothing that ships: a phone on the same
// network is another machine, and opening a file:// path in mobile Safari does
// not work. Bound to every interface because of that, and served with no-store
// so a rebuilt bundle is never hidden behind the browser's copy of the last one.
import 'dart:io';

const Map<String, String> _types = <String, String>{
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

Future<void> main(List<String> args) async {
  final int port = args.isEmpty ? 8080 : int.parse(args.first);
  final Directory root = Directory('build/web');
  if (!root.existsSync()) {
    stderr.writeln('build/web is missing - run: flutter build web --release');
    exitCode = 1;
    return;
  }

  final HttpServer server = await HttpServer.bind(
    InternetAddress.anyIPv4,
    port,
  );
  stdout.writeln(
    'serving ' + root.absolute.path + ' on http://0.0.0.0:' + port.toString(),
  );

  await for (final HttpRequest request in server) {
    final String requested = Uri.decodeComponent(request.uri.path);
    // The deployed app lives under /arcanumweb/ and the bundle is built with
    // that as its base href, so the same prefix is stripped here. Without it
    // the local loop would serve a build the browser cannot use.
    final String path = requested.startsWith('/arcanumweb')
        ? requested.substring('/arcanumweb'.length)
        : requested;
    final String relative = path.isEmpty || path == '/' ? '/index.html' : path;
    File file = File(root.path + relative);
    // A single-page app answers an unknown path with the shell, which is what
    // a deep link needs; anything that really exists is served as itself.
    if (!file.existsSync()) file = File(root.path + '/index.html');

    try {
      final List<int> bytes = await file.readAsBytes();
      final String ext = file.path.substring(file.path.lastIndexOf('.'));
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.parse(
          _types[ext] ?? 'application/octet-stream',
        )
        ..headers.set('Cache-Control', 'no-store')
        ..add(bytes);
      await request.response.close();
      stdout.writeln('200 ' + relative);
    } catch (error) {
      request.response.statusCode = 404;
      await request.response.close();
      stdout.writeln('404 ' + relative + ' (' + error.toString() + ')');
    }
  }
}
