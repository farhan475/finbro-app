package id.finbro.app

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Recomputes the widget for system-triggered updates (widget placed or
 * resized, the 30-min `updatePeriodMillis`): runs the headless entrypoint
 * `widgetBackgroundMain` on a fresh engine, which reads the database from
 * disk, sends `render` and then `done`; the engine is destroyed afterwards.
 *
 * Running it as WorkManager work (instead of from the broadcast receiver)
 * keeps the process alive until Dart has rendered — a receiver's process can
 * be killed as soon as `onUpdate` returns, which left widgets on stale or
 * placeholder content.
 */
class WidgetRefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        try {
            if (withTimeoutOrNull(TimeUnit.SECONDS.toMillis(TIMEOUT_SECONDS)) { runDart() } == null) {
                Log.w(TAG, "Widget refresh timed out")
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Widget refresh failed", e)
            // Never leave a stale amount on screen.
            FinBroWidgetProvider.saveSnapshot(applicationContext, "Rp ••••••", "Buka FinBro untuk memperbarui", LongArray(0))
        }
        // A failed refresh is not retried: the next update or app start renders again.
        return Result.success()
    }

    private suspend fun runDart() = withContext(Dispatchers.Main) {
        val context = applicationContext
        val engine = FlutterEngine(context)
        try {
            val done = CompletableDeferred<Unit>()
            WidgetChannel.register(engine.dartExecutor.binaryMessenger, context) { done.complete(Unit) }
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    DART_LIBRARY,
                    DART_ENTRYPOINT,
                ),
            )
            done.await()
        } finally {
            engine.destroy()
        }
    }

    companion object {
        private const val UNIQUE_NAME = "finbro.widget_refresh"
        private const val TAG = "FinBroWidget"
        private const val TIMEOUT_SECONDS = 60L

        // The entrypoint is not in the root library (lib/main.dart), so it is
        // resolved through its own library URI.
        private const val DART_LIBRARY = "package:finbro_app/core/widget/widget_background.dart"
        private const val DART_ENTRYPOINT = "widgetBackgroundMain"

        /** Queues one refresh; a newer request replaces a pending or running one. */
        fun enqueue(context: Context) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_NAME,
                ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<WidgetRefreshWorker>().build(),
            )
        }
    }
}
