package id.finbro.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widget styled like the Home "Total Balance" card, growing with
 * its size (owner decision, 7 Okt 2026):
 * - small (default 4x2): label + update time, amount, the month's balance line;
 * - medium: + change vs month start, Income | Expense;
 * - large: + Available to Spend, the top budget and the next schedule.
 * Each section opens its screen ([TARGET_HOME], [TARGET_REPORTS],
 * [TARGET_BUDGET], [TARGET_RECURRING]) through [MainActivity].
 *
 * Masking is decided in Dart (`computeWidgetSnapshot`): while the app lock is
 * active (a PIN is set) the widget shows 'Rp ••••••' + 'Terkunci' — always,
 * without exception; the in-app hide-balance toggle shows 'Rp ••••••' +
 * 'Saldo disembunyikan'. A masked snapshot carries no chart and no details.
 * Kotlin never formats an amount.
 *
 * Data flow: while the app runs, `WidgetSync` (Dart) computes snapshots on
 * the app's connection and sends `render` over [WidgetChannel]. For system
 * updates ([onUpdate]: placement, 30-min period) [WidgetRefreshWorker] runs
 * the headless entrypoint `widgetBackgroundMain`, which renders the same way.
 * `render` stores the snapshot in SharedPreferences and calls [updateAll];
 * the tier and chart bitmap follow each widget's current size.
 */
class FinBroWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        render(context, manager, appWidgetIds)
        WidgetRefreshWorker.enqueue(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        // Resized: pick the tier and redraw the chart for the new size.
        render(context, manager, intArrayOf(appWidgetId))
    }

    override fun onEnabled(context: Context) {
        WidgetRefreshWorker.enqueue(context)
    }

    private enum class Tier(val fixedDp: Int) {
        // Height taken by everything except the chart (see finbro_widget.xml).
        SMALL(84),
        MEDIUM(146),
        LARGE(246),
    }

    companion object {
        private const val PREFS = "finbro_widget"
        private const val KEY_BALANCE = "balance_text"
        private const val KEY_UPDATED = "updated_text"
        private const val KEY_CHART = "chart"
        private const val KEY_NEGATIVE = "negative"

        /** Detail texts and tones sent by Dart (`WidgetDetails.toArguments`). */
        val DETAIL_KEYS = listOf(
            "changeText", "changeTone", "incomeText", "expenseText", "availableText", "availableTone",
            "budgetText", "budgetTone", "upcomingText", "upcomingTone",
        )

        /** Extra on the [MainActivity] intent naming the screen to open (Dart `WidgetTarget`). */
        const val EXTRA_TARGET = "id.finbro.app.widget_target"
        private const val TARGET_HOME = "home"
        private const val TARGET_REPORTS = "reports"
        private const val TARGET_BUDGET = "budget"
        private const val TARGET_RECURRING = "recurring"

        /** Smallest chart worth drawing; below it the next-smaller tier is used. */
        private const val MIN_CHART_DP = 40

        fun saveSnapshot(
            context: Context,
            balanceText: String,
            updatedText: String,
            chart: LongArray,
            negative: Boolean = false,
            details: Map<String, String?> = emptyMap(),
        ) {
            val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_BALANCE, balanceText)
                .putString(KEY_UPDATED, updatedText)
                .putString(KEY_CHART, chart.joinToString(","))
                .putBoolean(KEY_NEGATIVE, negative)
            for (key in DETAIL_KEYS) {
                val value = details[key]
                if (value == null) editor.remove(key) else editor.putString(key, value)
            }
            editor.apply()
        }

        /** Pushes the stored snapshot into every placed widget. */
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            render(context, manager, manager.getAppWidgetIds(ComponentName(context, FinBroWidgetProvider::class.java)))
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val balance = prefs.getString(KEY_BALANCE, null)
            val updated = prefs.getString(KEY_UPDATED, "") ?: ""
            val chart = prefs.getString(KEY_CHART, "")
                ?.split(',')
                ?.mapNotNull { it.toLongOrNull() }
                ?.toLongArray()
                ?: LongArray(0)
            val hasDetails = prefs.contains("incomeText")
            val density = context.resources.displayMetrics.density
            for (id in ids) {
                val (widthDp, heightDp) = sizeDp(manager.getAppWidgetOptions(id))
                val tier = if (hasDetails) tierFor(heightDp) else Tier.SMALL
                val views = RemoteViews(context.packageName, R.layout.finbro_widget)
                // Launchers re-apply an update onto the existing view when the
                // layout is unchanged, so every visibility, text and color is
                // set explicitly — a section shown before must never linger
                // (e.g. income/ATS staying visible after the balance is masked).
                // Without a snapshot yet the layout defaults (no amount) stay.
                if (balance != null) {
                    views.setTextViewText(R.id.finbro_balance, balance)
                    views.setTextColor(
                        R.id.finbro_balance,
                        context.getColor(if (prefs.getBoolean(KEY_NEGATIVE, false)) R.color.finbro_widget_negative else R.color.finbro_widget_text),
                    )
                    if (chart.isNotEmpty()) {
                        val chartW = (widthDp - 32).coerceAtLeast(40)
                        val chartH = (heightDp - tier.fixedDp).coerceAtLeast(24)
                        views.setImageViewBitmap(
                            R.id.finbro_chart,
                            WidgetChart.render(chart, (chartW * density).toInt(), (chartH * density).toInt(), density),
                        )
                        views.setViewVisibility(R.id.finbro_chart, View.VISIBLE)
                        views.setViewVisibility(R.id.finbro_status, View.GONE)
                        views.setTextViewText(R.id.finbro_updated, updated)
                    } else {
                        views.setViewVisibility(R.id.finbro_chart, View.GONE)
                        views.setViewVisibility(R.id.finbro_status, View.VISIBLE)
                        views.setTextViewText(R.id.finbro_status, updated)
                        views.setTextViewText(R.id.finbro_updated, "")
                    }
                }
                bindMedium(context, views, prefs, show = balance != null && tier != Tier.SMALL)
                bindLarge(context, views, prefs, show = balance != null && tier == Tier.LARGE)
                views.setOnClickPendingIntent(R.id.finbro_root, openIntent(context, TARGET_HOME, 0))
                views.setOnClickPendingIntent(R.id.finbro_stats, openIntent(context, TARGET_REPORTS, 1))
                views.setOnClickPendingIntent(R.id.finbro_ats_row, openIntent(context, TARGET_HOME, 0))
                views.setOnClickPendingIntent(R.id.finbro_budget_row, openIntent(context, TARGET_BUDGET, 2))
                views.setOnClickPendingIntent(R.id.finbro_upcoming_row, openIntent(context, TARGET_RECURRING, 3))
                manager.updateAppWidget(id, views)
            }
        }

        /** Change line + Income | Expense; hidden and emptied when ![show]. */
        private fun bindMedium(context: Context, views: RemoteViews, prefs: SharedPreferences, show: Boolean) {
            val change = if (show) prefs.getString("changeText", null) else null
            views.setTextViewText(R.id.finbro_change, change ?: "")
            views.setTextColor(R.id.finbro_change, toneColor(context, prefs.getString("changeTone", null), R.color.finbro_widget_muted))
            views.setViewVisibility(R.id.finbro_change, if (change != null) View.VISIBLE else View.GONE)
            views.setTextViewText(R.id.finbro_income, if (show) prefs.getString("incomeText", "") else "")
            views.setTextViewText(R.id.finbro_expense, if (show) prefs.getString("expenseText", "") else "")
            views.setViewVisibility(R.id.finbro_stats, if (show) View.VISIBLE else View.GONE)
        }

        /** Available to Spend, top budget, next schedule; hidden and emptied when ![show]. */
        private fun bindLarge(context: Context, views: RemoteViews, prefs: SharedPreferences, show: Boolean) {
            for ((view, key) in listOf(
                R.id.finbro_ats to "available",
                R.id.finbro_budget to "budget",
                R.id.finbro_upcoming to "upcoming",
            )) {
                views.setTextViewText(view, if (show) prefs.getString("${key}Text", "") else "")
                views.setTextColor(view, toneColor(context, prefs.getString("${key}Tone", null), R.color.finbro_widget_text))
            }
            views.setViewVisibility(R.id.finbro_extra, if (show) View.VISIBLE else View.GONE)
        }

        /** Dart `WidgetTone` → color; neutral uses [neutral]. */
        private fun toneColor(context: Context, tone: String?, neutral: Int): Int = context.getColor(
            when (tone) {
                "positive" -> R.color.finbro_widget_positive
                "warning" -> R.color.finbro_widget_warning
                "negative" -> R.color.finbro_widget_negative
                else -> neutral
            },
        )

        /** Largest tier whose rows still leave [MIN_CHART_DP] for the chart. */
        private fun tierFor(heightDp: Int): Tier = when {
            heightDp - Tier.LARGE.fixedDp >= MIN_CHART_DP -> Tier.LARGE
            heightDp - Tier.MEDIUM.fixedDp >= MIN_CHART_DP -> Tier.MEDIUM
            else -> Tier.SMALL
        }

        /**
         * Opens [MainActivity] on the existing task with the screen to show;
         * one request code per target so the PendingIntents stay distinct.
         */
        private fun openIntent(context: Context, target: String, requestCode: Int): PendingIntent =
            PendingIntent.getActivity(
                context,
                requestCode,
                Intent(context, MainActivity::class.java)
                    .putExtra(EXTRA_TARGET, target)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        /** Current portrait size of the widget in dp (min width, max height). */
        private fun sizeDp(options: Bundle): Pair<Int, Int> {
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).takeIf { it > 0 } ?: 250
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT).takeIf { it > 0 } ?: 110
            return Pair(width, height)
        }
    }
}
