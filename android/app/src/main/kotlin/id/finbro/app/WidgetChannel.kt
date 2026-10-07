package id.finbro.app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel `id.finbro.app/widget`, Dart→Kotlin.
 *
 * `render`: store the snapshot computed in Dart (balance text, caption, the
 * month's balance path for the chart, detail texts and tones for taller
 * widgets) and update every placed widget.
 * Registered on the app engine (MainActivity: `WidgetSync` renders while the
 * app runs), the WorkManager background engine and the headless widget
 * engine ([WidgetRefreshWorker]).
 *
 * `requestPin` (app engine): asks the launcher to add the widget
 * (Android 8+); returns false when the launcher cannot pin widgets.
 *
 * `takeLaunchTarget` (app engine): the widget section the app was opened
 * from, cleared on read ([MainActivity.takeWidgetTarget]). Kotlin→Dart
 * `open` tells a running app to read it.
 *
 * `done`: the headless widget entrypoint finished; [onDone] lets
 * [WidgetRefreshWorker] destroy its engine.
 */
object WidgetChannel {
    const val NAME = "id.finbro.app/widget"

    fun register(messenger: BinaryMessenger, context: Context, onDone: (() -> Unit)? = null) {
        val appContext = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "render" -> {
                    val balance = call.argument<String>("balanceText")
                    if (balance == null) {
                        result.error("invalid_arguments", "balanceText is missing", null)
                        return@setMethodCallHandler
                    }
                    val chart = call.argument<List<Number>>("chart")?.map { it.toLong() }?.toLongArray() ?: LongArray(0)
                    FinBroWidgetProvider.saveSnapshot(
                        appContext,
                        balanceText = balance,
                        updatedText = call.argument<String>("updatedText") ?: "",
                        chart = chart,
                        negative = call.argument<Boolean>("negative") ?: false,
                        details = FinBroWidgetProvider.DETAIL_KEYS.associateWith { call.argument<String>(it) },
                    )
                    FinBroWidgetProvider.updateAll(appContext)
                    result.success(null)
                }
                "requestPin" -> {
                    val manager = AppWidgetManager.getInstance(appContext)
                    val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.isRequestPinAppWidgetSupported
                    if (supported) {
                        manager.requestPinAppWidget(ComponentName(appContext, FinBroWidgetProvider::class.java), null, null)
                    }
                    result.success(supported)
                }
                "takeLaunchTarget" -> result.success(MainActivity.takeWidgetTarget())
                "done" -> {
                    onDone?.invoke()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
