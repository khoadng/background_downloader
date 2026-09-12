import 'dart:async';
import 'dart:io';

// USB reverse forwarding exposes only this loopback server to the test app.
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18765);
  var requests = 0;
  var bytes = 0;
  stdout.writeln('queue probe server listening on 127.0.0.1:18765');
  await for (final request in server) {
    if (request.uri.path == '/stats') {
      request.response.write('requests=$requests bytes=$bytes');
      await request.response.close();
      continue;
    }
    if (!request.uri.path.startsWith('/file/')) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }
    requests++;
    // Keep native queue pressure without transferring large payloads.
    unawaited(() async {
      try {
        final mode = request.uri.queryParameters['mode'];
        if (mode == 'broken') {
          request.response.contentLength = 65536;
          final socket = await request.response.detachSocket();
          socket.add(List.filled(32, 0x41));
          await socket.flush();
          await socket.close();
          return;
        }
        if (mode == 'slow') {
          const length = 65536;
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final start = range == null
              ? 0
              : int.parse(range.split('=')[1].split('-')[0]);
          request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          request.response.headers.set(HttpHeaders.etagHeader, '"probe"');
          if (range != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${length - 1}/$length',
            );
          }
          request.response.contentLength = length - start;
          for (var offset = start; offset < length;) {
            final size = (length - offset).clamp(0, 4096);
            request.response.add(List.filled(size, 0x41));
            await request.response.flush();
            offset += size;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await request.response.close();
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        request.response.contentLength = 64;
        request.response.add(List.filled(64, 0x41));
        await request.response.close();
        bytes += 64;
      } on IOException {
        // Expected when the host ends a trial by stopping the test app.
      }
    }());
  }
}
