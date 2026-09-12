import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'queue_probe_recovery.dart';

// Diagnostic entry point, built separately from the normal example UI.
// No external URLs, database tracking, or artwork. The host serves 64 bytes.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('queue_probe');
  final config = await channel.invokeMapMethod<String, dynamic>('config');
  final count = config!['count'] as int;
  final holdingQueue = config['holdingQueue'] as bool;
  final cronet = config['cronet'] as bool;
  final recovery = config['recovery'] as bool;
  if (cronet) await channel.invokeMethod<void>('startNetLog');
  final downloader = FileDownloader();
  await downloader.ready;
  if (holdingQueue) {
    await downloader.configure(
      globalConfig: (Config.holdingQueue, (5, null, null)),
    );
  }
  await downloader.configure(androidConfig: (Config.useCronet, cronet));
  if (recovery) {
    try {
      await checkRecovery(downloader);
      await channel.invokeMethod('report', jsonEncode({'recovery': 'passed'}));
    } catch (error, stack) {
      await channel.invokeMethod(
        'report',
        jsonEncode({
          'recovery': 'failed',
          'error': '$error',
          'stack': '$stack',
        }),
      );
      rethrow;
    }
  }
  final watch = Stopwatch()..start();
  var submitted = 0;
  var accepted = 0;
  var rejected = 0;
  var errors = 0;
  var completed = 0;
  var failed = 0;
  String? firstError;
  var phase = 'starting';

  Future<void> report() => channel.invokeMethod(
    'report',
    jsonEncode({
      'phase': phase,
      'count': count,
      'holdingQueue': holdingQueue,
      'cronet': cronet,
      'elapsedMs': watch.elapsedMilliseconds,
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'submitted': submitted,
      'accepted': accepted,
      'rejected': rejected,
      'enqueueErrors': errors,
      'completed': completed,
      'failed': failed,
      'firstError': firstError,
    }),
  );

  downloader.updates.listen((update) {
    if (update is TaskStatusUpdate) {
      if (update.status == TaskStatus.complete) completed++;
      if (update.status == TaskStatus.failed ||
          update.status == TaskStatus.notFound) {
        failed++;
        firstError ??= update.exception?.toString();
      }
    }
  });
  await report();
  Timer.periodic(const Duration(seconds: 2), (_) => unawaited(report()));
  phase = 'enqueueing';
  await Future.wait(
    List.generate(count, (index) async {
      submitted++;
      try {
        final ok = await downloader.enqueue(
          DownloadTask(
            taskId: 'probe-$index',
            url: 'http://127.0.0.1:18765/file/$index',
            filename: 'probe-$index.bin',
            directory: 'queue-probe',
            baseDirectory: BaseDirectory.applicationDocuments,
            allowPause: true,
            retries: 1,
            updates: Updates.statusAndProgress,
            metaData: jsonEncode({
              'thumbnailUrl': 'http://127.0.0.1:18765/thumb/$index',
              'fileSize': null,
              'siteUrl': 'http://127.0.0.1:18765',
              'group': null,
            }),
          ),
        );
        if (ok) {
          accepted++;
        } else {
          rejected++;
        }
      } catch (error) {
        errors++;
        firstError ??= error.toString();
      }
    }),
  );
  phase = 'submitted';
  await report();
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (completed + failed < accepted && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (completed != count || failed != 0 || rejected != 0 || errors != 0) {
    phase = 'failed';
    await report();
    throw StateError('Batch did not complete successfully');
  }
  for (var index = 0; index < count; index++) {
    final task = DownloadTask(
      url: 'http://127.0.0.1:18765/file/$index',
      filename: 'probe-$index.bin',
      directory: 'queue-probe',
      baseDirectory: BaseDirectory.applicationDocuments,
    );
    final bytes = await File(await task.filePath()).readAsBytes();
    if (bytes.length != 64 || bytes.any((byte) => byte != 0x41)) {
      phase = 'failed';
      firstError = 'Invalid payload for probe-$index';
      await report();
      throw StateError(firstError!);
    }
  }
  phase = 'passed';
  await report();
  // Leave the headless engine alive for the host's bounded observation window.
  // The host captures evidence before stopping/clearing this example app only.
}
