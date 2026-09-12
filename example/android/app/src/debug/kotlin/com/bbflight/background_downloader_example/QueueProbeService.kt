package com.bbflight.background_downloader_example

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URL
import android.content.Context

/** Debug-only load probe. Starts no Activity and uses only this example's data. */
class QueueProbeService : Service() {
    private var engine: FlutterEngine? = null
    private val handler = Handler(Looper.getMainLooper())
    private var netLogEngine: Any? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        check(engine == null) { "Probe already running" }
        val count = intent?.getIntExtra("count", 100) ?: 100
        val holdingQueue = intent?.getBooleanExtra("holdingQueue", true) ?: true
        val cronet = intent?.getBooleanExtra("cronet", true) ?: true
        val recovery = intent?.getBooleanExtra("recovery", false) ?: false
        require(count in 1..30000)
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("queue_probe", "Local queue probe", NotificationManager.IMPORTANCE_LOW))
        startForeground(901, Notification.Builder(this, "queue_probe")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Local download queue probe")
            .setContentText("$count synthetic tasks over USB")
            .build())
        val flutter = FlutterEngine(this)
        engine = flutter
        MethodChannel(flutter.dartExecutor.binaryMessenger, "queue_probe").setMethodCallHandler { call, result ->
            when (call.method) {
                "config" -> result.success(mapOf("count" to count, "holdingQueue" to holdingQueue, "cronet" to cronet, "recovery" to recovery))
                "startNetLog" -> {
                    // Debug-only observation of the exact engine used by the plugin.
                    // No downloader production code or connection behavior is changed.
                    val factory = Class.forName("com.bbflight.background_downloader.TaskRunner\$CronetConnectionFactory")
                    val instance = factory.getDeclaredField("INSTANCE").apply { isAccessible = true }.get(null)
                    factory.getDeclaredMethod("open", Context::class.java, URL::class.java)
                        .apply { isAccessible = true }
                        .invoke(instance, this, URL("http://127.0.0.1:18765"))
                    netLogEngine = factory.getDeclaredField("engine").apply { isAccessible = true }.get(null)
                    Class.forName("org.chromium.net.CronetEngine")
                        .getMethod("startNetLogToFile", String::class.java, Boolean::class.javaPrimitiveType)
                        .invoke(netLogEngine, File(filesDir, "cronet-netlog.json").absolutePath, false)
                    result.success(null)
                }
                "report" -> {
                    val line = call.arguments as String
                    File(filesDir, "queue_probe.jsonl").appendText("$line\n")
                    Log.i("QueueProbe", line)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        flutter.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        for (seconds in listOf(15, 30)) {
            handler.postDelayed({
                val stacks = Thread.getAllStackTraces().entries
                    .sortedBy { it.key.name }
                    .joinToString("\n\n") { (thread, stack) ->
                        "${thread.name} id=${thread.id} state=${thread.state}\n" +
                            stack.joinToString("\n") { "  at $it" }
                    }
                File(filesDir, "threads-$seconds.txt").writeText(stacks)
                Log.i("QueueProbe", "Thread snapshot saved at $seconds seconds")
                if (seconds == 30 && netLogEngine != null) {
                    Class.forName("org.chromium.net.CronetEngine").getMethod("stopNetLog").invoke(netLogEngine)
                    netLogEngine = null
                }
            }, seconds * 1000L)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        engine?.destroy()
        engine = null
        super.onDestroy()
    }
}
