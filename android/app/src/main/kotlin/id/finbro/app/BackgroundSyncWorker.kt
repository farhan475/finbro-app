package id.finbro.app

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Periodic background job (WorkManager, every [INTERVAL_HOURS] h while the
 * battery is not low): recurring processing (instances, auto-confirm,
 * reminders), daily-check rescheduling, the widget refresh and a due folder
 * backup, also when FinBro is not opened.
 *
 * Like [WidgetCompute], it runs a headless Dart entrypoint
 * (`backgroundSyncMain` in lib/main.dart) on its own engine, which also gets
 * the [WidgetChannel] handler so Dart can render the widget. Dart reports
 * `done` on [CHANNEL]; the engine is destroyed then, after [TIMEOUT_MINUTES],
 * or when WorkManager stops the work. The flutter_community `workmanager`
 * plugin is not used: its worker engine only gets pub plugins, never this
 * app's own channels.
 *
 * Skipped while the app is visible: its lifecycle tasks do the same work on
 * every start/resume.
 */
class BackgroundSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (MainActivity.visible) return Result.success()
        val ok = try {
            withTimeoutOrNull(TimeUnit.MINUTES.toMillis(TIMEOUT_MINUTES)) { runDart() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Background sync failed", e)
            false
        }
        if (ok == null) Log.w(TAG, "Background sync timed out")
        return if (ok == true) Result.success() else Result.failure()
    }

    private suspend fun runDart(): Boolean = withContext(Dispatchers.Main) {
        val context = applicationContext
        val engine = FlutterEngine(context)
        try {
            val done = CompletableDeferred<Boolean>()
            val messenger = engine.dartExecutor.binaryMessenger
            WidgetChannel.register(messenger, context)
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                if (call.method == "done") {
                    done.complete(call.arguments == true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    DART_ENTRYPOINT,
                ),
            )
            done.await()
        } finally {
            engine.destroy()
        }
    }

    companion object {
        private const val UNIQUE_NAME = "finbro.background_sync"
        private const val CHANNEL = "id.finbro.app/background"
        private const val DART_ENTRYPOINT = "backgroundSyncMain"
        private const val TAG = "FinBroBackground"
        private const val INTERVAL_HOURS = 6L

        /** Below WorkManager's 10-minute execution limit. */
        private const val TIMEOUT_MINUTES = 9L

        /** Registers the periodic job; KEEP leaves an existing schedule as it is. */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(INTERVAL_HOURS, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiresBatteryNotLow(true).build())
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(UNIQUE_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
