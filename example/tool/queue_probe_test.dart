import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Host-side test of the installed headless debug probe. No Activity is opened.
// See queue_probe.md for build/install and USB loopback server prerequisites.
void main() {
  const package = 'com.bbflight.background_downloader_example';
  late String serial;

  Future<String> adb(List<String> arguments) async {
    final result = await Process.run('adb', ['-s', serial, ...arguments]);
    if (result.exitCode != 0) {
      throw StateError('adb $arguments: ${result.stderr}${result.stdout}');
    }
    return result.stdout as String;
  }

  setUpAll(() async {
    serial = Platform.environment['QUEUE_PROBE_DEVICE'] ?? '';
    if (serial.isEmpty) throw StateError('Set QUEUE_PROBE_DEVICE explicitly');
    expect(await adb(['get-state']), contains('device'));
    expect(await adb(['shell', 'pm', 'path', package]), contains('package:'));
  });

  for (final variant in ['cronet', 'cronet-repeat', 'platform-control']) {
    test(
      'interrupted transfers then healthy batch: $variant',
      () async {
        await adb(['shell', 'am', 'force-stop', package]);
        expect(
          await adb(['shell', 'pm', 'clear', package]),
          contains('Success'),
        );
        try {
          await adb([
            'shell',
            'am',
            'start-foreground-service',
            '-n',
            '$package/.QueueProbeService',
            '--ei',
            'count',
            '100',
            '--ez',
            'holdingQueue',
            'true',
            '--ez',
            'cronet',
            '${variant != 'platform-control'}',
            '--ez',
            'recovery',
            'true',
          ]);
          final deadline = DateTime.now().add(const Duration(seconds: 110));
          String journal = '';
          while (DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(seconds: 2));
            // The journal is created after recovery. Test existence before cat.
            final exists = await Process.run('adb', [
              '-s',
              serial,
              'shell',
              'run-as',
              package,
              'test',
              '-f',
              'files/queue_probe.jsonl',
            ]);
            if (exists.exitCode != 0) continue;
            journal = await adb([
              'shell',
              'run-as',
              package,
              'cat',
              'files/queue_probe.jsonl',
            ]);
            final records = const LineSplitter()
                .convert(journal)
                .where((line) => line.isNotEmpty)
                .map((line) => jsonDecode(line) as Map<String, dynamic>)
                .toList();
            expect(
              records.any(
                (r) => r['recovery'] == 'failed' || r['phase'] == 'failed',
              ),
              isFalse,
              reason: journal,
            );
            if (records.any((r) => r['phase'] == 'passed')) {
              expect(records.any((r) => r['recovery'] == 'passed'), isTrue);
              final end = records.last;
              expect(end['completed'], 100);
              expect(end['failed'], 0);
              return;
            }
          }
          fail('Probe timed out: $journal');
        } finally {
          await adb(['shell', 'am', 'force-stop', package]);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
