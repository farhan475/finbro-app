package id.finbro.app

import android.content.Context
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs the headless Dart compute for system-triggered widget updates
 * (widget placed, periodic `updatePeriodMillis`). The engine is created once
 * per process and cached (owner decision: a separate headless engine, never
 * recreated per update); a later [run] asks its Dart entrypoint to recompute
 * via the `refresh` channel call. The engine gets its own [WidgetChannel]
 * handler so the Dart side's `render` reaches the widget.
 *
 * Never crashes the host: any engine failure renders the masked state.
 */
internal object WidgetCompute {
    // The entrypoint is not in the root library (lib/main.dart), so it must be
    // resolved through its own library URI.
    private const val DART_LIBRARY = "package:finbro_app/core/widget/widget_background.dart"
    private const val DART_ENTRYPOINT = "widgetBackgroundMain"
    private const val TAG = "FinBroWidget"

    @Volatile
    private var engine: FlutterEngine? = null

    @Synchronized
    fun run(context: Context) {
        val appContext = context.applicationContext
        var created: FlutterEngine? = null
        try {
            val existing = engine
            if (existing != null) {
                MethodChannel(existing.dartExecutor.binaryMessenger, WidgetChannel.NAME)
                    .invokeMethod("refresh", null)
                return
            }
            created = FlutterEngine(appContext)
            WidgetChannel.register(created.dartExecutor.binaryMessenger, appContext)
            created.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    DART_LIBRARY,
                    DART_ENTRYPOINT,
                ),
            )
            engine = created
        } catch (e: Exception) {
            Log.w(TAG, "Widget compute failed", e)
            created?.destroy()
            // Never leave a stale amount on screen.
            FinBroWidgetProvider.saveSnapshot(appContext, "••••••", "Buka FinBro untuk memperbarui")
            FinBroWidgetProvider.updateAll(appContext)
        }
    }
}
