package id.finbro.app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel `id.finbro.app/widget`, Dart→Kotlin side.
 *
 * `render`: store the snapshot computed in Dart and update every placed
 * widget. Registered on the app engine (MainActivity: `WidgetSync` renders
 * while the app runs) and on the headless widget engine ([WidgetCompute]).
 * The opposite direction (`refresh`, Kotlin→Dart) is only sent to the
 * headless engine.
 */
object WidgetChannel {
    const val NAME = "id.finbro.app/widget"

    fun register(messenger: BinaryMessenger, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "render" -> {
                    val balance = call.argument<String>("balanceText")
                    if (balance == null) {
                        result.error("invalid_arguments", "balanceText is missing", null)
                        return@setMethodCallHandler
                    }
                    FinBroWidgetProvider.saveSnapshot(
                        appContext,
                        balanceText = balance,
                        updatedText = call.argument<String>("updatedText") ?: "",
                    )
                    FinBroWidgetProvider.updateAll(appContext)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
