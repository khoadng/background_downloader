import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows downloads preserve challenge headers and response bytes',
    (tester) async {
      if (!Platform.isWindows) return;

      const expectedBytes = <int>[0, 1, 2, 3, 254, 255];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestHandled = Completer<void>();
      final serverSubscription = server.listen((request) async {
        expect(request.headers.value(HttpHeaders.cookieHeader), 'session=ok');
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          'test-agent',
        );
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = expectedBytes.length
          ..add(expectedBytes);
        await request.response.close();
        requestHandled.complete();
      });

      final task = DownloadTask(
        taskId: 'windows-transport-flow',
        url: 'http://${server.address.address}:${server.port}/protected-file',
        filename: 'windows-transport-flow.bin',
        baseDirectory: BaseDirectory.temporary,
        headers: const {
          HttpHeaders.cookieHeader: 'session=ok',
          HttpHeaders.userAgentHeader: 'test-agent',
        },
      );

      try {
        final result = await FileDownloader().download(task);
        expect(result.status, TaskStatus.complete);
        await requestHandled.future.timeout(const Duration(seconds: 10));

        final file = File(await task.filePath());
        expect(await file.readAsBytes(), expectedBytes);
        await file.delete();
      } finally {
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
