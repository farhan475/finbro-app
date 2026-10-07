package id.finbro.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * Home-screen widget (4x1): Total Balance (IDR, all active accounts) and an
 * update caption. Masking is decided in Dart (`computeWidgetSnapshot`): while
 * the app lock is active (a PIN is set) the widget shows '••••••' +
 * 'Terkunci' — always, without exception; the in-app hide-balance toggle
 * shows '••••••' + 'Saldo disembunyikan'. Kotlin never formats an amount.
 *
 * Data flow: while the app runs, `WidgetSync` (Dart) computes snapshots on
 * the app's connection and sends `render` over [WidgetChannel]. For system
 * updates ([onUpdate]: placement, 30-min period) [WidgetCompute] runs the
 * headless entrypoint `widgetBackgroundMain`, which renders the same way.
 * `render` stores the snapshot in SharedPreferences and calls [updateAll].
 */
class FinBroWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        renderStored(context, manager)
        WidgetCompute.run(context)
    }

    override fun onEnabled(context: Context) {
        WidgetCompute.run(context)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) = Unit
    override fun onDisabled(context: Context) = Unit

    companion object {
        private const val PREFS = "finbro_widget"
        private const val KEY_BALANCE = "balance_text"
        private const val KEY_UPDATED = "updated_text"

        fun saveSnapshot(context: Context, balanceText: String, updatedText: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_BALANCE, balanceText)
                .putString(KEY_UPDATED, updatedText)
                .apply()
        }

        /** Pushes the stored snapshot into every placed widget. */
        fun updateAll(context: Context) {
            renderStored(context, AppWidgetManager.getInstance(context))
        }

        private fun renderStored(context: Context, manager: AppWidgetManager) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.finbro_widget).apply {
                // Without a snapshot yet the layout defaults (no amount) stay.
                prefs.getString(KEY_BALANCE, null)?.let { balance ->
                    setTextViewText(R.id.finbro_balance, balance)
                    setTextViewText(R.id.finbro_updated, prefs.getString(KEY_UPDATED, "") ?: "")
                }
                // Tapping the widget opens the app (MainActivity).
                setOnClickPendingIntent(
                    R.id.finbro_root,
                    PendingIntent.getActivity(
                        context,
                        0,
                        Intent(context, MainActivity::class.java),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            for (id in manager.getAppWidgetIds(ComponentName(context, FinBroWidgetProvider::class.java))) {
                manager.updateAppWidget(id, views)
            }
        }
    }
}
