import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

// Real transport regression: failed/canceled/paused requests must not prevent
// subsequent downloads. Called only by the headless debug probe.
Future<void> checkRecovery(FileDownloader downloader) async {
  DownloadTask task(String id, String mode) => DownloadTask(
    taskId: id,
    url: 'http://127.0.0.1:18765/file/$id?mode=$mode',
    filename: '$id.bin',
    directory: 'queue-probe',
    allowPause: true,
    retries: 0,
    updates: Updates.statusAndProgress,
  );

  // More than Cronet's six connections per host: cleanup must release them.
  for (var index = 0; index < 8; index++) {
    final result = await downloader
        .download(task('broken-$index', 'broken'))
        .timeout(const Duration(seconds: 15));
    if (result.status != TaskStatus.failed) {
      throw StateError('Truncated transfer returned ${result.status}');
    }
  }

  for (final pause in [false, true]) {
    final current = task(pause ? 'pause-resume' : 'cancel', 'slow');
    final interrupted = Completer<void>();
    final paused = Completer<void>();
    var requested = false;
    final result = downloader.download(
      current,
      onProgress: (progress) {
        if (progress <= 0 || progress >= 1 || requested) return;
        requested = true;
        unawaited(() async {
          try {
            final accepted = pause
                ? await downloader.pause(current)
                : await downloader.cancelTaskWithId(current.taskId);
            if (!accepted) throw StateError('Interrupt rejected');
            if (pause) {
              await paused.future.timeout(const Duration(seconds: 10));
              if (!await downloader.resume(current)) {
                throw StateError('Resume rejected');
              }
            }
            interrupted.complete();
          } catch (error, stack) {
            interrupted.completeError(error, stack);
          }
        }());
      },
      onStatus: (status) {
        if (status == TaskStatus.paused && !paused.isCompleted) {
          paused.complete();
        }
      },
    );
    await interrupted.future.timeout(const Duration(seconds: 20));
    final update = await result.timeout(const Duration(seconds: 20));
    final expected = pause ? TaskStatus.complete : TaskStatus.canceled;
    if (update.status != expected) {
      throw StateError('Expected $expected, got ${update.status}');
    }
    if (pause) {
      final bytes = await File(await current.filePath()).readAsBytes();
      if (bytes.length != 65536 || bytes.any((byte) => byte != 0x41)) {
        throw StateError('Resumed payload is corrupt');
      }
    }
  }
}
