# Android native queue probe

Debug-only headless diagnostic using the real downloader. It installs as
`com.bbflight.background_downloader_example`, never as Boorusama. Do not use it
if that example package already contains data you want to preserve.

The pinned revision used for the initial build is
`e8ad9f9cce98cf2bd22d37a3b068e848b384716e`, matching Boorusama's override.

From `example/`:

```sh
fvm flutter build apk --debug --target lib/queue_probe.dart --target-platform android-arm64
fvm dart run tool/queue_probe_server.dart
```

In another terminal, with the intended device selected via `adb -s SERIAL`:

```sh
adb -s SERIAL install build/app/outputs/flutter-apk/app-debug.apk
adb -s SERIAL reverse tcp:18765 tcp:18765
adb -s SERIAL shell am start-foreground-service -n com.bbflight.background_downloader_example/.QueueProbeService --ei count 100
adb -s SERIAL shell dumpsys meminfo com.bbflight.background_downloader_example
adb -s SERIAL shell run-as com.bbflight.background_downloader_example cat files/queue_probe.jsonl
```

For the holding-queue comparison, run the same 100-task trial with
`--ez holdingQueue true` and then `--ez holdingQueue false`. Capture the journal
and force-stop/clear only the example package between runs, so each starts with
a fresh native process and no prior jobs. Both variants retain Cronet, the same
payload/delay, and eager submission. The journal records the selected variant.

The transport control uses `--ez cronet false` (default: true). Keep
`--ez holdingQueue true` for this comparison, with the same fresh-process reset.

For the connection-lifecycle regression, add `--ez recovery true`. Before the
batch it checks eight truncated responses, cancellation during body transfer,
and pause/resume with byte-for-byte payload validation. A successful batch
emits `phase: passed` only after checking every file's contents. Failed or
unfinished batches emit `phase: failed` after a bounded observation window.

The host-side `tool/queue_probe_test.dart` automates three fresh-process trials:
Cronet, a Cronet repeat, and the platform transport control. It requires the
probe APK installed, the loopback server running, and USB reverse configured
as above. It deliberately clears only the example package between trials.
Run through polytest from the tooling checkout:

```sh
QUEUE_PROBE_DEVICE=SERIAL fvm dart run polytest /path/to/background_downloader/example -- tool/queue_probe_test.dart
```

The test starts no Activity. Each trial checks the recovery sequence followed
by 100 valid files. Missing device/install prerequisites fail, not skip.
This is a real-device regression, not part of the default host-only test suite.

The debug service saves Java thread stacks to `files/threads-15.txt` and
`files/threads-30.txt`. With Cronet enabled it also captures
`files/cronet-netlog.json`, finalized at 30 seconds. NetLog uses debug-only
reflection to observe the plugin's existing engine, without production changes.
Capture these files through `adb shell run-as` before clearing the example.

The service starts no Activity. A notification keeps the headless process alive.
Each download requests 64 bytes from the computer's loopback server over USB,
with a one-second response delay to preserve queue pressure. No artwork or
external server is involved. Holding-queue concurrency is five; submission is
eager through `Future.wait`, with retries and progress/status updates enabled.

Observe one trial at a time: 100, 1,000, 5,000, then 30,000 tasks. Capture the
JSON journal, process memory, and PID-filtered logcat before ending each trial.
Use a bounded observation window and stop if device responsiveness deteriorates.
Record controlled stops separately from crashes. A stalled heartbeat alone is
not evidence of process death; confirm PID and Android exit/crash information.

Between trials, force-stop and clear **only the newly installed example
package**, after preserving its evidence. At the end, uninstall that package,
remove only the reverse mapping for port 18765, and stop the local server.

This isolates native queue/submission pressure. It does not reproduce
Boorusama's UI, retained task-update lists, filename generation, or large media
transfers. A successful run cannot rule out those other causes of the report.
