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

  testWidgets(
    'Windows concurrent downloads can be paused then canceled safely',
    (tester) async {
      if (!Platform.isWindows) return;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstRequest = Completer<void>();
      final serverSubscription = server.listen((request) async {
        if (!firstRequest.isCompleted) firstRequest.complete();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..headers.contentLength = 1024 * 1024;
        try {
          for (var index = 0; index < 256; index++) {
            request.response.add(List<int>.filled(4096, index));
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await request.response.close();
        } on HttpException {
          // The client closing the response is the expected pause path.
        } on SocketException {
          // The client closing the response is the expected cancel path.
        }
      });

      const group = 'windows-pause-cancel-flow';
      final downloader = FileDownloader();
      final tasks = List.generate(
        12,
        (index) => DownloadTask(
          taskId: 'windows-pause-cancel-$index',
          url: 'http://${server.address.address}:${server.port}/slow-$index',
          filename: 'windows-pause-cancel-$index.bin',
          baseDirectory: BaseDirectory.temporary,
          group: group,
          allowPause: true,
        ),
      );

      try {
        final downloads = tasks.map(downloader.download).toList();
        await firstRequest.future.timeout(const Duration(seconds: 10));
        await downloader.pauseAll(group: group);
        await downloader.cancelAll(group: group);

        final results = await Future.wait(
          downloads,
        ).timeout(const Duration(seconds: 30));
        expect(
          results.every(
            (result) =>
                result.status == TaskStatus.paused ||
                result.status == TaskStatus.canceled,
          ),
          isTrue,
        );
        // Keep the runner alive through the native callback drain window.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      } finally {
        await downloader.cancelAll(group: group);
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
